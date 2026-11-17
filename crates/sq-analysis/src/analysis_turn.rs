// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnalysisTurn.swift
//! One analysis at a time, first come first served: a holder runs its whole job, the next one waits. A WebM analysis hands
//! the lane one frame per job; two of them on a 1-wide lane would alternate frame by frame, both decoders and both frame
//! states alive, both finishing late. Holding the turn for the whole analysis makes the second one start when the first is
//! done, as two native analyses do.
//!
//! Swift waits suspended on a continuation; there is no executor yet (PORTING section 9), so a waiting caller blocks its
//! thread, and cancellation is a `CancelToken` the waiter polls.
use std::collections::VecDeque;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

/// The work was canceled (Swift `CancellationError`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cancelled;

impl fmt::Display for Cancelled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("canceled")
    }
}

impl std::error::Error for Cancelled {}

/// Cancellation of a task (Swift `Task.isCancelled`); clones share the flag.
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A token that is not canceled.
    pub fn new() -> CancelToken {
        CancelToken::default()
    }

    /// Cancels every clone.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether `cancel` was called.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// `Err(Cancelled)` once canceled (Swift `Task.checkCancellation`).
    pub fn check(&self) -> Result<(), Cancelled> {
        if self.is_cancelled() { Err(Cancelled) } else { Ok(()) }
    }
}

#[derive(Default)]
struct State {
    held: bool,
    waiters: VecDeque<u64>,
    /// The waiter the turn was handed to and that has not taken it yet.
    granted: Option<u64>,
    next_id: u64,
}

/// One analysis at a time, first come first served.
#[derive(Default)]
pub struct AnalysisTurn {
    state: Mutex<State>,
    changed: Condvar,
}

/// How often a waiting caller looks at its token.
// shortcut: polling at 2 ms, upgrade when the executor (gate G5) can wake a waiter on cancel.
const POLL: Duration = Duration::from_millis(2);

/// Passes the turn on when the job ends, also when it panics.
struct Pass<'a>(&'a AnalysisTurn);

impl Drop for Pass<'_> {
    fn drop(&mut self) {
        let mut s = self.0.lock();
        match s.waiters.pop_front() {
            None => s.held = false,
            Some(next) => s.granted = Some(next), // the turn stays held, now by that waiter
        }
        drop(s);
        self.0.changed.notify_all();
    }
}

impl AnalysisTurn {
    /// A free turn.
    pub fn new() -> AnalysisTurn {
        AnalysisTurn::default()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Jobs waiting for the turn (tests).
    pub fn waiting_count(&self) -> usize {
        self.lock().waiters.len()
    }

    /// Waits for the turn, runs `body`, passes the turn on. Canceled while waiting: `Err(Cancelled)`, nothing ran.
    pub fn run<T>(&self, cancel: &CancelToken, body: impl FnOnce() -> T) -> Result<T, Cancelled> {
        let mut s = self.lock();
        s.next_id += 1;
        let id = s.next_id;
        if cancel.is_cancelled() {
            return Err(Cancelled);
        }
        if !s.held {
            s.held = true;
        } else {
            s.waiters.push_back(id);
            loop {
                if s.granted == Some(id) {
                    s.granted = None;
                    break;
                }
                if cancel.is_cancelled() {
                    s.waiters.retain(|w| *w != id);
                    return Err(Cancelled);
                }
                s = self.changed.wait_timeout(s, POLL).unwrap_or_else(|e| e.into_inner()).0;
            }
        }
        drop(s);
        let _pass = Pass(self);
        Ok(body())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use std::thread;
    use std::time::Duration;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// Two jobs that each pause between their steps never interleave: the second starts after the first ended.
    #[test]
    fn jobs_do_not_alternate() {
        let turn = Arc::new(AnalysisTurn::new());
        let log = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut handles = Vec::new();
        for name in ["a", "b"] {
            let (turn, log) = (Arc::clone(&turn), Arc::clone(&log));
            handles.push(thread::spawn(move || {
                let _ = turn.run(&CancelToken::new(), || {
                    for i in 0..5 {
                        log.lock().unwrap_or_else(|e| e.into_inner()).push(format!("{name}{i}"));
                        thread::sleep(ms(2));
                    }
                });
            }));
            thread::sleep(ms(20)); // a is queued first
        }
        for h in handles {
            let _ = h.join();
        }
        let got = log.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(got, ["a0", "a1", "a2", "a3", "a4", "b0", "b1", "b2", "b3", "b4"]);
    }

    #[test]
    fn canceled_waiter_never_runs_and_passes_nothing_on() {
        let turn = Arc::new(AnalysisTurn::new());
        let log = Arc::new(Mutex::new(Vec::<&'static str>::new()));
        let (release, started) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
        let first = {
            let (turn, log, release, started) =
                (Arc::clone(&turn), Arc::clone(&log), Arc::clone(&release), Arc::clone(&started));
            thread::spawn(move || {
                let _ = turn.run(&CancelToken::new(), || {
                    started.store(true, Ordering::SeqCst);
                    while !release.load(Ordering::SeqCst) {
                        thread::sleep(ms(2));
                    }
                    log.lock().unwrap_or_else(|e| e.into_inner()).push("first");
                });
            })
        };
        while !started.load(Ordering::SeqCst) {
            thread::sleep(ms(2));
        }
        let token = CancelToken::new();
        let waiter = {
            let (turn, log, token) = (Arc::clone(&turn), Arc::clone(&log), token.clone());
            thread::spawn(move || turn.run(&token, || log.lock().unwrap_or_else(|e| e.into_inner()).push("waiter")))
        };
        // A condition, not a time: the waiter is queued behind the first job.
        while turn.waiting_count() == 0 {
            thread::sleep(ms(2));
        }
        token.cancel();
        assert_eq!(waiter.join().ok(), Some(Err(Cancelled)));
        release.store(true, Ordering::SeqCst);
        let _ = first.join();
        // The turn was passed on, not lost.
        let third = turn.run(&CancelToken::new(), || log.lock().unwrap_or_else(|e| e.into_inner()).push("third"));
        assert_eq!(third, Ok(()));
        assert_eq!(*log.lock().unwrap_or_else(|e| e.into_inner()), ["first", "third"]);
    }

    #[test]
    fn a_failing_job_still_passes_the_turn() {
        let turn = AnalysisTurn::new();
        let failed = turn.run(&CancelToken::new(), || Err::<i32, &str>("boom"));
        assert_eq!(failed, Ok(Err("boom")));
        assert_eq!(turn.run(&CancelToken::new(), || 3), Ok(3));
    }

    #[test]
    fn a_panicking_job_still_passes_the_turn() {
        let turn = Arc::new(AnalysisTurn::new());
        let t = Arc::clone(&turn);
        let r = thread::spawn(move || t.run(&CancelToken::new(), || -> i32 { panic!("boom") })).join();
        assert!(r.is_err());
        assert_eq!(turn.run(&CancelToken::new(), || 3), Ok(3));
    }

    #[test]
    fn a_job_canceled_before_it_starts_does_not_run() {
        let token = CancelToken::new();
        token.cancel();
        assert_eq!(AnalysisTurn::new().run(&token, || 1), Err(Cancelled));
    }
}
