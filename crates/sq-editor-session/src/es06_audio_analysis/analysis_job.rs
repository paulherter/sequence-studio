// Swift: AnalysisJob.swift
//! One background analysis at a time (Stabilize, Auto Reframe, Find Scene Changes), with the UI-facing lifecycle the
//! Stabilizer bug (2026-10-07) lacked: Cancel ends the run for the UI immediately (even when the work only notices
//! cancellation later), a late result or progress tick of a canceled run never reaches a newer run, failures are
//! reported as failures (not "canceled"), and progress is passed on only when the whole percent changes (each tick
//! refreshes Effect Controls).
//!
//! The Swift class owns a `Task`; here the job is the state machine and the work runs on a worker: [`AnalysisJob::start`]
//! hands out the [`AnalysisJobCtx`] (cancel token, progress reporter, generation), the worker posts its progress and its
//! end as messages, and the owner feeds them to [`AnalysisJob::tick`] / [`AnalysisJob::end`], which answer what to show.

use std::fmt::Display;
use std::sync::Arc;

use sq_analysis::analysis_turn::CancelToken;

/// How a background analysis run ended. Reported exactly once per run.
// Swift: AnalysisJob.swift:5
#[derive(Clone, Debug, PartialEq)]
pub enum AnalysisJobEnding<Outcome> {
    Done(Outcome),
    /// Cancel was pressed: reported at once, whatever the work still does (its result is dropped).
    Cancelled,
    /// The work failed with something other than a cancel: the message to show.
    Failed(String),
}

/// Why the work of a run did not produce an outcome.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AnalysisJobError {
    Cancelled,
    Failed(String),
}

impl From<sq_analysis::analysis_turn::Cancelled> for AnalysisJobError {
    fn from(_: sq_analysis::analysis_turn::Cancelled) -> Self {
        AnalysisJobError::Cancelled
    }
}

impl<Outcome> From<Result<Outcome, AnalysisJobError>> for AnalysisJobEnding<Outcome> {
    fn from(r: Result<Outcome, AnalysisJobError>) -> Self {
        match r {
            Ok(o) => AnalysisJobEnding::Done(o),
            Err(AnalysisJobError::Cancelled) => AnalysisJobEnding::Cancelled,
            Err(AnalysisJobError::Failed(why)) => AnalysisJobEnding::Failed(why),
        }
    }
}

/// The work of a run: gets the run's context, returns the outcome.
// Swift: AnalysisJob.swift:18
pub type AnalysisJobWork<Outcome> = Box<dyn FnOnce(&AnalysisJobCtx) -> Result<Outcome, AnalysisJobError> + Send>;

/// What a running job hands its worker: the generation it belongs to, the cancel token and the progress reporter.
#[derive(Clone)]
pub struct AnalysisJobCtx {
    /// The run this belongs to; messages carry it so a late one of an older run is ignored.
    pub generation: u64,
    /// Set by `cancel`; the work checks it between steps.
    pub cancel: CancelToken,
    report: Arc<dyn Fn(u64, f64) + Send + Sync>,
}

impl AnalysisJobCtx {
    /// Reports progress 0...1 (any thread); the owner turns it into whole percent steps.
    pub fn progress(&self, p: f64) {
        (self.report)(self.generation, p);
    }
}

/// One background analysis at a time.
// Swift: AnalysisJob.swift:16
pub struct AnalysisJob {
    state: JobState,
    generation: u64,
}

/// A percent that belongs to the run only while it runs: it cannot be stale after the end.
enum JobState {
    Idle,
    Running { cancel: CancelToken, last_percent: i64 },
}

impl Default for AnalysisJob {
    fn default() -> Self {
        Self::new()
    }
}

impl AnalysisJob {
    // Swift: AnalysisJob.swift:25
    pub fn new() -> AnalysisJob {
        AnalysisJob { state: JobState::Idle, generation: 0 }
    }

    // Swift: AnalysisJob.swift:27
    pub fn is_running(&self) -> bool {
        matches!(self.state, JobState::Running { .. })
    }

    /// Starts a run. `None` (nothing started) while a run is going. `report(generation, p)` is called from the worker
    /// with the raw progress; feed it back through [`Self::tick`].
    // Swift: AnalysisJob.swift:32
    pub fn start(&mut self, report: Arc<dyn Fn(u64, f64) + Send + Sync>) -> Option<AnalysisJobCtx> {
        if self.is_running() {
            return None;
        }
        self.generation = self.generation.wrapping_add(1);
        let cancel = CancelToken::new();
        self.state = JobState::Running { cancel: cancel.clone(), last_percent: -1 };
        Some(AnalysisJobCtx { generation: self.generation, cancel, report })
    }

    /// Cancels the running work and reports `Cancelled` now. `None` when idle.
    // Swift: AnalysisJob.swift:59
    pub fn cancel<Outcome>(&mut self) -> Option<AnalysisJobEnding<Outcome>> {
        let JobState::Running { cancel, .. } = &self.state else { return None };
        cancel.cancel();
        let g = self.generation;
        self.end(g, AnalysisJobEnding::Cancelled)
    }

    /// Whether `generation` is the run that is going now (a canceled run's late result is not).
    pub fn is_current(&self, generation: u64) -> bool {
        generation == self.generation && self.is_running()
    }

    /// A progress tick of run `generation`: the whole-percent value (0...1) to show, `None` when it is stale or the
    /// percent did not change.
    pub fn tick(&mut self, generation: u64, p: f64) -> Option<f64> {
        let JobState::Running { last_percent, .. } = &mut self.state else { return None };
        if generation != self.generation {
            return None;
        }
        let pct = (p.clamp(0.0, 1.0) * 100.0).floor() as i64;
        if pct == *last_percent {
            return None;
        }
        *last_percent = pct;
        Some(pct as f64 / 100.0)
    }

    /// The end of run `generation`: the ending to report, `None` for the late end of a canceled run.
    pub fn end<Outcome>(
        &mut self,
        generation: u64,
        ending: AnalysisJobEnding<Outcome>,
    ) -> Option<AnalysisJobEnding<Outcome>> {
        if generation != self.generation || !self.is_running() {
            return None;
        }
        self.state = JobState::Idle;
        self.generation = self.generation.wrapping_add(1);
        Some(ending)
    }

    /// The text of a failure; "Unknown error." when the error has none.
    // Swift: AnalysisJob.swift:82
    pub fn message(error: &dyn Display) -> String {
        let text = error.to_string();
        if text.is_empty() { "Unknown error.".to_string() } else { text }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn report() -> Arc<dyn Fn(u64, f64) + Send + Sync> {
        Arc::new(|_, _| {})
    }

    #[test]
    fn one_run_at_a_time_and_cancel_ends_it_once() {
        let mut job = AnalysisJob::new();
        let ctx = job.start(report()).expect("starts");
        assert!(job.is_running() && job.start(report()).is_none());
        let ending = job.cancel::<i32>();
        assert_eq!(ending, Some(AnalysisJobEnding::Cancelled));
        assert!(ctx.cancel.is_cancelled() && !job.is_running());
        // The canceled work still finishes later: its end and progress are ignored.
        assert_eq!(job.end(ctx.generation, AnalysisJobEnding::Done(1)), None);
        assert_eq!(job.tick(ctx.generation, 0.5), None);
        assert_eq!(job.cancel::<i32>(), None);
    }

    #[test]
    fn a_late_tick_of_an_old_run_never_reaches_a_newer_one() {
        let mut job = AnalysisJob::new();
        let old = job.start(report()).expect("starts");
        job.cancel::<()>();
        let new = job.start(report()).expect("starts again");
        assert_ne!(old.generation, new.generation);
        assert_eq!(job.tick(old.generation, 0.9), None);
        assert_eq!(job.end(old.generation, AnalysisJobEnding::Done(())), None);
        assert!(job.is_running());
        assert_eq!(job.end(new.generation, AnalysisJobEnding::Done(())), Some(AnalysisJobEnding::Done(())));
    }

    #[test]
    fn progress_passes_whole_percent_steps_only() {
        let mut job = AnalysisJob::new();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        let ctx = job.start(Arc::new(move |g, p| sink.lock().expect("lock").push((g, p)))).expect("starts");
        ctx.progress(0.123);
        assert_eq!(seen.lock().expect("lock").as_slice(), &[(ctx.generation, 0.123)]);
        assert_eq!(job.tick(ctx.generation, 0.123), Some(0.12));
        assert_eq!(job.tick(ctx.generation, 0.129), None);
        assert_eq!(job.tick(ctx.generation, 0.13), Some(0.13));
        assert_eq!(job.tick(ctx.generation, 7.0), Some(1.0));
    }

    #[test]
    fn failures_are_reported_as_failures() {
        let e: AnalysisJobEnding<()> = Err(AnalysisJobError::Failed("disk".into())).into();
        assert_eq!(e, AnalysisJobEnding::Failed("disk".into()));
        let c: AnalysisJobEnding<()> = Err(AnalysisJobError::from(sq_analysis::analysis_turn::Cancelled)).into();
        assert_eq!(c, AnalysisJobEnding::Cancelled);
        assert_eq!(AnalysisJob::message(&""), "Unknown error.");
        assert_eq!(AnalysisJob::message(&"x"), "x");
    }
}
