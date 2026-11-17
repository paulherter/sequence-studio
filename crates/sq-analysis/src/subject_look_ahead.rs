// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectLookAhead.swift
//! One piece of work done ahead, on its own thread, for a key object (the frame the tracking model is asked next): the image
//! encoder of frame n+1 runs while frame n is in the memory attention and the decoder. One at a time: a start waits for the
//! one still running. The work must end on its own (the model's predictions have a deadline).
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;

struct Entry<K, V, E> {
    id: u64,
    key: K,
    result: Option<Result<V, E>>,
}

struct State<K, V, E> {
    /// Oldest first: the frame asked now (its work may be done) and the one after it (its work may run).
    entries: Vec<Entry<K, V, E>>,
    next_id: u64,
}

type Shared<K, V, E> = Arc<(Mutex<State<K, V, E>>, Condvar)>;

/// Work ahead for key objects, keyed by `K` (Swift identity of a class instance).
pub struct SubjectLookAhead<K, V, E> {
    /// Guards the entries; signaled when the work in flight ends.
    shared: Shared<K, V, E>,
}

impl<K, V, E> SubjectLookAhead<K, V, E>
where
    K: PartialEq + Send + 'static,
    V: Send + 'static,
    E: Send + 'static,
{
    /// Results held that were not taken yet.
    pub const KEPT: usize = 2;

    /// No work yet.
    pub fn new() -> SubjectLookAhead<K, V, E> {
        SubjectLookAhead { shared: Arc::new((Mutex::new(State { entries: Vec::new(), next_id: 0 }), Condvar::new())) }
    }

    fn lock(&self) -> MutexGuard<'_, State<K, V, E>> {
        self.shared.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Starts `work` for `key`, unless work for that key is already ahead. One at a time: waits for work that still runs.
    /// The oldest result not taken is dropped when more than `KEPT` would be held.
    pub fn start(&self, key: K, work: impl FnOnce() -> Result<V, E> + Send + 'static) {
        let mut s = self.lock();
        if s.entries.iter().any(|e| e.key == key) {
            return;
        }
        while s.entries.iter().any(|e| e.result.is_none()) {
            s = self.shared.1.wait(s).unwrap_or_else(|e| e.into_inner());
        }
        s.next_id += 1;
        let id = s.next_id;
        s.entries.push(Entry { id, key, result: None });
        if s.entries.len() > Self::KEPT {
            let drop_count = s.entries.len() - Self::KEPT;
            s.entries.drain(..drop_count);
        }
        let shared = Arc::clone(&self.shared);
        thread::spawn(move || {
            let r = work();
            let mut s = shared.0.lock().unwrap_or_else(|e| e.into_inner());
            // The entry may have been dropped meanwhile: then the result has no taker.
            if let Some(entry) = s.entries.iter_mut().find(|e| e.id == id) {
                entry.result = Some(r);
            }
            drop(s);
            shared.1.notify_all();
        });
    }

    /// The work's result for `key`, waited for; `Ok(None)` when nothing was started for `key`. Taken once.
    pub fn take(&self, key: &K) -> Result<Option<V>, E> {
        let mut s = self.lock();
        let Some(id) = s.entries.iter().find(|e| e.key == *key).map(|e| e.id) else {
            return Ok(None);
        };
        loop {
            let Some(at) = s.entries.iter().position(|e| e.id == id) else {
                return Ok(None);
            };
            if s.entries[at].result.is_some() {
                let entry = s.entries.remove(at);
                return entry.result.map_or(Ok(None), |r| r.map(Some));
            }
            s = self.shared.1.wait(s).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// Whether work for `key` was started and not taken yet.
    pub fn holds(&self, key: &K) -> bool {
        self.lock().entries.iter().any(|e| e.key == *key)
    }
}

impl<K, V, E> Default for SubjectLookAhead<K, V, E>
where
    K: PartialEq + Send + 'static,
    V: Send + 'static,
    E: Send + 'static,
{
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI32, Ordering};
    use std::thread::ThreadId;
    use std::time::Duration;

    type Ahead = SubjectLookAhead<u32, i32, &'static str>;

    #[test]
    fn takes_the_result_started_for_its_key_once() {
        let ahead = Ahead::new();
        ahead.start(1, || Ok(7));
        assert_eq!(ahead.take(&2), Ok(None));
        assert_eq!(ahead.take(&1), Ok(Some(7)));
        assert_eq!(ahead.take(&1), Ok(None));
    }

    #[test]
    fn runs_on_its_own_thread_and_take_waits_for_it() {
        let ahead = Ahead::new();
        let caller = thread::current().id();
        let ran: Arc<Mutex<Option<ThreadId>>> = Arc::new(Mutex::new(None));
        let ran_in = Arc::clone(&ran);
        ahead.start(1, move || {
            thread::sleep(Duration::from_millis(50));
            *ran_in.lock().unwrap_or_else(|e| e.into_inner()) = Some(thread::current().id());
            Ok(1)
        });
        assert!(ahead.holds(&1));
        assert_eq!(ahead.take(&1), Ok(Some(1)));
        let id = *ran.lock().unwrap_or_else(|e| e.into_inner());
        assert!(id.is_some_and(|t| t != caller));
    }

    #[test]
    fn a_second_start_for_the_same_key_does_not_run_again() {
        let ahead = Ahead::new();
        let runs = Arc::new(AtomicI32::new(0));
        for _ in 0..2 {
            let runs = Arc::clone(&runs);
            ahead.start(1, move || Ok(runs.fetch_add(1, Ordering::SeqCst) + 1));
        }
        assert_eq!(ahead.take(&1), Ok(Some(1)));
        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn the_result_asked_now_stays_while_the_next_one_runs_one_at_a_time() {
        let ahead = Ahead::new();
        let in_flight = Arc::new(AtomicI32::new(0));
        let most = Arc::new(AtomicI32::new(0));
        let work = |v: i32| {
            let (in_flight, most) = (Arc::clone(&in_flight), Arc::clone(&most));
            move || {
                let n = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                most.fetch_max(n, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(20));
                in_flight.fetch_sub(1, Ordering::SeqCst);
                Ok(v)
            }
        };
        // The lane: frame b looked ahead while frame a (looked ahead before) is answered.
        ahead.start(1, work(1));
        ahead.start(2, work(2));
        assert_eq!(ahead.take(&1), Ok(Some(1)));
        ahead.start(3, work(3));
        assert_eq!(ahead.take(&2), Ok(Some(2)));
        assert_eq!(ahead.take(&3), Ok(Some(3)));
        assert_eq!(most.load(Ordering::SeqCst), 1);
        // Never taken: only the last two are held.
        ahead.start(1, work(1));
        ahead.start(2, work(2));
        ahead.start(3, work(3));
        assert_eq!(ahead.take(&1), Ok(None));
        assert_eq!(ahead.take(&2), Ok(Some(2)));
        assert_eq!(ahead.take(&3), Ok(Some(3)));
    }

    #[test]
    fn an_error_of_the_work_is_returned_by_take() {
        let ahead = Ahead::new();
        ahead.start(1, || Err("boom"));
        assert_eq!(ahead.take(&1), Err("boom"));
    }
}
