// Swift: ExportQueue.swift (`ExportJobState`, plus the `cancelRequested` set made visible as `Cancelling`).
//
// The lifecycle of one export job and of the queue's worker, as two small enums with every transition in one place.
// No locks, no I/O: the queue holds these under its mutex and only calls `transition`/`Worker::*`. An invalid
// transition is rejected with `Invalid` (never a panic) and leaves the state unchanged.

use sq_core_time::Id;
use std::path::PathBuf;

use super::error::CancelToken;

/// Where a job stands.
#[derive(Clone, Debug, PartialEq)]
pub enum ExportJobState {
    /// Queued.
    Waiting,
    /// Being exported.
    Running,
    /// Stop asked while exporting; the encoder is winding down and the partial file is removed.
    Cancelling,
    /// Finished; the file.
    Done(PathBuf),
    /// Failed; the message.
    Failed(String),
    /// Cancelled.
    Cancelled,
}

/// What happens to a job.
#[derive(Clone, Debug, PartialEq)]
pub enum JobEvent {
    /// The worker picks the job up.
    Start,
    /// The user (or a shutdown) asks it to stop.
    RequestCancel,
    /// The export ended well; the file.
    Finish(PathBuf),
    /// The export ended with an error; the message.
    Fail(String),
    /// The export ended because it was stopped.
    Stopped,
}

/// A transition that the state does not allow.
#[derive(Clone, Debug, PartialEq)]
pub struct Invalid {
    pub from: ExportJobState,
    pub event: JobEvent,
}

impl ExportJobState {
    /// The one transition table. `Err` leaves the caller's state as it was.
    pub fn transition(&self, event: JobEvent) -> Result<ExportJobState, Invalid> {
        use ExportJobState as S;
        use JobEvent as E;
        let next = match (self, &event) {
            (S::Waiting, E::Start) => S::Running,
            // A waiting job has no file yet: it is dropped at once.
            (S::Waiting, E::RequestCancel) => S::Cancelled,
            (S::Running, E::RequestCancel) => S::Cancelling,
            // Asking twice is harmless.
            (S::Cancelling, E::RequestCancel) => S::Cancelling,
            // A finish wins over a late cancel request (the file exists), as in Swift.
            (S::Running | S::Cancelling, E::Finish(url)) => S::Done(url.clone()),
            (S::Running | S::Cancelling, E::Fail(why)) => S::Failed(why.clone()),
            (S::Running | S::Cancelling, E::Stopped) => S::Cancelled,
            _ => return Err(Invalid { from: self.clone(), event }),
        };
        Ok(next)
    }

    /// Waiting, running or cancelling: the job still belongs to the queue's work.
    pub fn is_active(&self) -> bool {
        matches!(self, ExportJobState::Waiting | ExportJobState::Running | ExportJobState::Cancelling)
    }

    /// The export is in progress (the encoder runs), also while it winds down.
    pub fn is_exporting(&self) -> bool {
        matches!(self, ExportJobState::Running | ExportJobState::Cancelling)
    }
}

/// Why the running job's token was cancelled.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    /// The user asked.
    User,
    /// The volume filled up.
    LowSpace,
}

/// The queue's worker (the thread inside `run_all`).
#[derive(Default)]
pub enum Worker {
    /// No `run_all` is active.
    #[default]
    Idle,
    /// `run_all` is active and between jobs (choosing the next one).
    Between,
    /// One job's encoder runs; its cancel token and why it was stopped, if it was.
    Running { id: Id, cancel: CancelToken, stop: Option<StopReason> },
}

impl Worker {
    /// `run_all` starts. False when one is already active (the second caller returns at once).
    pub fn begin(&mut self) -> bool {
        if matches!(self, Worker::Idle) {
            *self = Worker::Between;
            true
        } else {
            false
        }
    }

    /// The worker found no waiting job. Must happen under the same lock as that search, so a job enqueued
    /// right after is seen by the next `run_all` instead of being stranded.
    pub fn end(&mut self) {
        *self = Worker::Idle;
    }

    /// A job's encoder starts. False unless the worker is between jobs.
    pub fn start(&mut self, id: Id, cancel: CancelToken) -> bool {
        if matches!(self, Worker::Between) {
            *self = Worker::Running { id, cancel, stop: None };
            true
        } else {
            false
        }
    }

    /// The job's encoder returned; the stop reason, if any. `None` unless that job was the running one.
    pub fn finish(&mut self, id: Id) -> Option<Option<StopReason>> {
        match self {
            Worker::Running { id: r, stop, .. } if *r == id => {
                let stop = *stop;
                *self = Worker::Between;
                Some(stop)
            }
            _ => None,
        }
    }

    /// Cancels the token of job `id` for `reason` (the first reason sticks). False when `id` is not running.
    pub fn stop(&mut self, id: Id, reason: StopReason) -> bool {
        match self {
            Worker::Running { id: r, cancel, stop } if *r == id => {
                cancel.cancel();
                stop.get_or_insert(reason);
                true
            }
            _ => false,
        }
    }

    pub fn is_active(&self) -> bool {
        !matches!(self, Worker::Idle)
    }
}
