// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: the detached decode `Task`s of WinProgramEngine.decode (one task chain per decoder, serialized by the decoder lock)
//! Decode lanes: a few worker threads run decode jobs. Jobs of one decoder run one at a time in submission order (FIFO,
//! the decoder is `&mut`-like); jobs of different decoders run in parallel, oldest first. A job that finds its work stale
//! when its turn comes returns at once, so a scrub that queued ten decodes only decodes the newest.

use std::collections::{HashMap, VecDeque};
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
    queues: HashMap<u64, VecDeque<(u64, bool, Job)>>,
    /// The decoders that run a job now, and whether it is urgent.
    running: HashMap<u64, bool>,
    next_seq: u64,
    shutdown: bool,
}

struct Shared {
    /// Worker threads; one of them is kept free of background jobs (`worker`).
    workers: usize,
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
        let count = Self::worker_count(workers, std::env::var("SQ_DECODE_WORKERS").ok().as_deref());
        let shared = Arc::new(Shared { workers: count, state: Mutex::new(State::default()), wake: Condvar::new() });
        let threads = (0..count)
            .filter_map(|n| {
                let s = Arc::clone(&shared);
                std::thread::Builder::new()
                    .name(format!("sq-decode-{n}"))
                    .spawn(move || {
                        sq_os::thread::set_current_thread_role(sq_os::thread::Role::Decode);
                        worker(&s);
                    })
                    .ok()
            })
            .collect();
        LanePool { shared, threads }
    }

    /// Pool size: `workers` capped at `MAX_WORKERS`. The bench-only `SQ_DECODE_WORKERS=n` (A/B runs, plan B1) replaces both
    /// the request and the cap (1 to 32); unset or unparsable it changes nothing.
    pub fn worker_count(workers: usize, env: Option<&str>) -> usize {
        match env.and_then(|v| v.trim().parse::<usize>().ok()) {
            Some(n) => n.clamp(1, 32),
            None => workers.clamp(1, Self::MAX_WORKERS),
        }
    }

    /// Queues an urgent `job` (a picture the frame on screen needs) behind the earlier jobs of `decoder`.
    pub fn submit(&self, decoder: u64, job: impl FnOnce() + Send + 'static) {
        self.submit_with(decoder, true, job);
    }

    /// Queues `job` behind the earlier jobs of `decoder`. A background job (a clip about to cut in, a fill) never takes the last
    /// free worker and waits behind every urgent one: a 4K software GOP decode of a cut-in seconds ahead held all four
    /// workers for 1-2 s and the playhead's own one-frame decode queued behind them for up to 360 ms.
    pub fn submit_with(&self, decoder: u64, urgent: bool, job: impl FnOnce() + Send + 'static) {
        let mut s = self.shared.lock();
        if s.shutdown {
            return;
        }
        let seq = s.next_seq;
        s.next_seq += 1;
        s.queues.entry(decoder).or_default().push_back((seq, urgent, Box::new(job)));
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
        let background_running = s.running.values().filter(|u| !**u).count();
        let background_ok = shared.workers <= 1 || background_running + 1 < shared.workers;
        let pick = s
            .queues
            .iter()
            .filter(|(id, q)| {
                !q.is_empty() && !s.running.contains_key(id) && (background_ok || q.front().is_some_and(|j| j.1))
            })
            .min_by_key(|(_, q)| (!q.front().is_some_and(|j| j.1), q.front().map_or(u64::MAX, |j| j.0)))
            .map(|(id, _)| *id);
        let Some(id) = pick else {
            s = shared.wake.wait(s).unwrap_or_else(PoisonError::into_inner);
            continue;
        };
        let popped = s.queues.get_mut(&id).and_then(VecDeque::pop_front);
        let urgent = popped.as_ref().is_some_and(|j| j.1);
        let job = popped.map(|j| j.2);
        if s.queues.get(&id).is_some_and(VecDeque::is_empty) {
            s.queues.remove(&id);
        }
        s.running.insert(id, urgent);
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
    fn the_bench_override_replaces_the_request_and_the_cap_only_when_it_parses() {
        assert_eq!(LanePool::worker_count(4, None), 4);
        assert_eq!(LanePool::worker_count(9, None), LanePool::MAX_WORKERS);
        assert_eq!(LanePool::worker_count(4, Some("8")), 8);
        assert_eq!(LanePool::worker_count(4, Some(" 2 ")), 2);
        assert_eq!(LanePool::worker_count(4, Some("0")), 1);
        assert_eq!(LanePool::worker_count(4, Some("99")), 32);
        assert_eq!(LanePool::worker_count(4, Some("many")), 4);
    }

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
    fn an_urgent_job_does_not_wait_behind_background_jobs_for_a_worker() {
        let pool = LanePool::new(2);
        let (release, gate) = mpsc::channel::<()>();
        let gate = Arc::new(Mutex::new(gate));
        let started = Arc::new(AtomicUsize::new(0));
        // Three long background jobs on three decoders: only one may run, the other worker stays free.
        for id in 0..3u64 {
            let (gate, started) = (Arc::clone(&gate), Arc::clone(&started));
            pool.submit_with(id, false, move || {
                started.fetch_add(1, Ordering::SeqCst);
                let _ = gate.lock().map(|g| g.recv_timeout(Duration::from_secs(5)));
            });
        }
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(started.load(Ordering::SeqCst), 1, "background jobs took the last free worker");
        let (tx, rx) = mpsc::channel();
        pool.submit(9, move || {
            let _ = tx.send(());
        });
        assert!(rx.recv_timeout(Duration::from_secs(2)).is_ok(), "the urgent job waited behind background jobs");
        drop(release);
    }

    #[test]
    fn a_background_front_job_behind_an_urgent_one_does_not_pass_the_reserve() {
        let pool = LanePool::new(2);
        let (release, gate) = mpsc::channel::<()>();
        let gate = Arc::new(Mutex::new(gate));
        let started = Arc::new(AtomicUsize::new(0));
        let hold = |gate: Arc<Mutex<mpsc::Receiver<()>>>, started: Arc<AtomicUsize>| {
            move || {
                started.fetch_add(1, Ordering::SeqCst);
                let _ = gate.lock().map(|g| g.recv_timeout(Duration::from_secs(5)));
            }
        };
        // Decoder 1 runs a background job (the one allowed). Decoder 2 queues [background, urgent]: its front is background.
        pool.submit_with(1, false, hold(Arc::clone(&gate), Arc::clone(&started)));
        std::thread::sleep(Duration::from_millis(50));
        pool.submit_with(2, false, hold(Arc::clone(&gate), Arc::clone(&started)));
        pool.submit_with(2, true, || {});
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(started.load(Ordering::SeqCst), 1, "a second background job took the reserved worker");
        let (tx, rx) = mpsc::channel();
        pool.submit(3, move || {
            let _ = tx.send(());
        });
        assert!(rx.recv_timeout(Duration::from_secs(2)).is_ok(), "the urgent job of another decoder waited");
        drop(release);
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
