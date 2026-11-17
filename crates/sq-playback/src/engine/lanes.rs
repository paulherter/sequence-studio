// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: the detached decode `Task`s of WinProgramEngine.decode (one task chain per decoder, serialized by the decoder lock)
//! Decode lanes: a few worker threads run decode jobs. Jobs of one decoder run one at a time in submission order (FIFO,
//! the decoder is `&mut`-like); jobs of different decoders run in parallel, oldest first. A job that finds its work stale
//! when its turn comes returns at once, so a scrub that queued ten decodes only decodes the newest.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

/// Stops decode jobs of a media: set on relink / media change, checked by the job before and during its decode.
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> CancelToken {
        CancelToken::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

type Job = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct State {
    queues: HashMap<u64, VecDeque<(u64, Job)>>,
    running: HashSet<u64>,
    next_seq: u64,
    shutdown: bool,
}

struct Shared {
    state: Mutex<State>,
    wake: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The design's decode lanes: at most `workers` (<= 4) decode at once.
pub struct LanePool {
    shared: Arc<Shared>,
    threads: Vec<JoinHandle<()>>,
}

impl LanePool {
    pub const MAX_WORKERS: usize = 4;

    pub fn new(workers: usize) -> LanePool {
        let shared = Arc::new(Shared { state: Mutex::new(State::default()), wake: Condvar::new() });
        let threads = (0..workers.clamp(1, Self::MAX_WORKERS))
            .filter_map(|n| {
                let s = Arc::clone(&shared);
                std::thread::Builder::new().name(format!("sq-decode-{n}")).spawn(move || worker(&s)).ok()
            })
            .collect();
        LanePool { shared, threads }
    }

    /// Queues `job` behind the earlier jobs of `decoder`.
    pub fn submit(&self, decoder: u64, job: impl FnOnce() + Send + 'static) {
        let mut s = self.shared.lock();
        if s.shutdown {
            return;
        }
        let seq = s.next_seq;
        s.next_seq += 1;
        s.queues.entry(decoder).or_default().push_back((seq, Box::new(job)));
        drop(s);
        self.shared.wake.notify_one();
    }

    /// Jobs queued or running (tests).
    pub fn pending(&self) -> usize {
        let s = self.shared.lock();
        s.queues.values().map(VecDeque::len).sum::<usize>() + s.running.len()
    }
}

fn worker(shared: &Shared) {
    let mut s = shared.lock();
    loop {
        if s.shutdown {
            return;
        }
        let pick = s
            .queues
            .iter()
            .filter(|(id, q)| !q.is_empty() && !s.running.contains(id))
            .min_by_key(|(_, q)| q.front().map_or(u64::MAX, |j| j.0))
            .map(|(id, _)| *id);
        let Some(id) = pick else {
            s = shared.wake.wait(s).unwrap_or_else(PoisonError::into_inner);
            continue;
        };
        let job = s.queues.get_mut(&id).and_then(VecDeque::pop_front).map(|j| j.1);
        if s.queues.get(&id).is_some_and(VecDeque::is_empty) {
            s.queues.remove(&id);
        }
        s.running.insert(id);
        drop(s);
        if let Some(job) = job {
            // A panicking job must not take the lane's thread (and the decoder's queue) with it.
            let _ = sq_core_time::caught_panic::catching(job);
        }
        s = shared.lock();
        s.running.remove(&id);
        shared.wake.notify_all();
    }
}

impl Drop for LanePool {
    fn drop(&mut self) {
        {
            let mut s = self.shared.lock();
            s.shutdown = true;
            s.queues.clear();
        }
        self.shared.wake.notify_all();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn jobs_of_one_decoder_run_in_order_and_one_at_a_time() {
        let pool = LanePool::new(4);
        let (tx, rx) = mpsc::channel();
        let active = Arc::new(AtomicUsize::new(0));
        for n in 0..8 {
            let (tx, active) = (tx.clone(), Arc::clone(&active));
            pool.submit(1, move || {
                assert_eq!(active.fetch_add(1, Ordering::SeqCst), 0, "two jobs of one decoder at once");
                std::thread::sleep(Duration::from_millis(2));
                active.fetch_sub(1, Ordering::SeqCst);
                let _ = tx.send(n);
            });
        }
        let got: Vec<i32> = (0..8).filter_map(|_| rx.recv_timeout(Duration::from_secs(5)).ok()).collect();
        assert_eq!(got, (0..8).collect::<Vec<_>>());
    }

    #[test]
    fn different_decoders_run_in_parallel() {
        let pool = LanePool::new(2);
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let (tx, rx) = mpsc::channel();
        for id in 0..2u64 {
            let (b, tx) = (Arc::clone(&barrier), tx.clone());
            pool.submit(id, move || {
                b.wait();
                let _ = tx.send(id);
            });
        }
        assert!(rx.recv_timeout(Duration::from_secs(5)).is_ok() && rx.recv_timeout(Duration::from_secs(5)).is_ok());
    }

    #[test]
    fn a_panicking_job_keeps_the_lane_alive() {
        let pool = LanePool::new(1);
        let (tx, rx) = mpsc::channel();
        pool.submit(7, || panic!("decoder blew up"));
        pool.submit(7, move || {
            let _ = tx.send(());
        });
        assert!(rx.recv_timeout(Duration::from_secs(5)).is_ok());
    }

    #[test]
    fn cancel_token_is_shared() {
        let t = CancelToken::new();
        let u = t.clone();
        assert!(!u.is_cancelled());
        t.cancel();
        assert!(u.is_cancelled());
    }
}
