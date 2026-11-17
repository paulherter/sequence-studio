// Swift: ImportScheduling.swift
//! When an import of many files puts its finished items into the bin. The in-order prefix of finished files goes in as
//! it grows: the first one at once, then at most every `interval` (each commit reloads the grid), and the rest when
//! everything is done. Only the in-order prefix: the bin keeps the input order, the same as one commit at the end would.
//! Pure value logic. An "instant" is a `Duration` since any fixed monotonic origin the caller picks.

use std::collections::HashMap;
use std::hash::Hash;
use std::ops::Range;
use std::time::Duration;

/// Commit schedule of one import.
#[derive(Clone, Debug)]
pub struct ImportCommitPlan {
    count: usize,
    interval: Duration,
    committed: usize,
    done: Vec<bool>,
    ready: usize,
    last_commit: Option<Duration>,
}

impl ImportCommitPlan {
    /// The default gap between two commits.
    pub const DEFAULT_INTERVAL: Duration = Duration::from_millis(250);

    /// A plan for `count` files (negative counts are 0).
    pub fn new(count: i64, interval: Duration) -> ImportCommitPlan {
        let count = usize::try_from(count.max(0)).unwrap_or(0);
        ImportCommitPlan { count, interval, committed: 0, done: vec![false; count], ready: 0, last_commit: None }
    }

    /// Items `0..committed` are handed out.
    pub fn committed(&self) -> usize {
        self.committed
    }

    /// True when every item is handed out.
    pub fn is_complete(&self) -> bool {
        self.committed == self.count
    }

    /// Item `index` finished (imported or failed). Returns the range to commit now, if any.
    pub fn finished(&mut self, index: i64, now: Duration) -> Option<Range<usize>> {
        let index = usize::try_from(index).ok().filter(|i| *i < self.count)?;
        if self.done[index] {
            return None;
        }
        self.done[index] = true;
        while self.ready < self.count && self.done[self.ready] {
            self.ready += 1;
        }
        if self.ready <= self.committed {
            return None;
        }
        let due = self.committed == 0
            || self.ready == self.count
            || self.last_commit.is_none_or(|l| now.saturating_sub(l) >= self.interval);
        if !due {
            return None;
        }
        self.last_commit = Some(now);
        Some(self.take())
    }

    /// Whatever in-order prefix is ready, regardless of the interval (end of the import, or a timer).
    pub fn flush(&mut self) -> Option<Range<usize>> {
        (self.ready > self.committed).then(|| self.take())
    }

    fn take(&mut self) -> Range<usize> {
        let r = self.committed..self.ready;
        self.committed = self.ready;
        r
    }
}

/// Requests served visible-first: what is on screen (in screen order) before anything else, the rest oldest first.
/// For poster frames of a bin with hundreds of items. Enqueue / remove are O(1); `next` looks at the visible list (a
/// screenful) and then the FIFO.
#[derive(Clone, Debug)]
pub struct VisibleFirstQueue<Id: Hash + Eq + Clone> {
    order: Vec<Id>,
    head: usize,
    /// Waiting requests -> position in `order` of their entry (an id served or removed and enqueued again gets a new one).
    waiting: HashMap<Id, usize>,
    visible: Vec<Id>,
}

impl<Id: Hash + Eq + Clone> Default for VisibleFirstQueue<Id> {
    fn default() -> Self {
        VisibleFirstQueue { order: Vec::new(), head: 0, waiting: HashMap::new(), visible: Vec::new() }
    }
}

impl<Id: Hash + Eq + Clone> VisibleFirstQueue<Id> {
    /// An empty queue.
    pub fn new() -> Self {
        Self::default()
    }

    /// Waiting requests.
    pub fn count(&self) -> usize {
        self.waiting.len()
    }

    /// True when nothing waits.
    pub fn is_empty(&self) -> bool {
        self.waiting.is_empty()
    }

    /// True when `id` waits.
    pub fn contains(&self, id: &Id) -> bool {
        self.waiting.contains_key(id)
    }

    /// Adds a request; one already waiting keeps its place.
    pub fn enqueue(&mut self, id: Id) {
        if self.waiting.contains_key(&id) {
            return;
        }
        self.waiting.insert(id.clone(), self.order.len());
        self.order.push(id);
    }

    /// Drops a waiting request.
    pub fn remove(&mut self, id: &Id) {
        self.waiting.remove(id);
    }

    /// The ids on screen now, in screen order (top-left first). Replaces the previous list.
    pub fn set_visible(&mut self, ids: Vec<Id>) {
        self.visible = ids;
    }

    /// The next request to serve, removed from the queue (Swift `next()`).
    pub fn pop_next(&mut self) -> Option<Id> {
        if let Some(id) = self.visible.iter().find(|id| self.waiting.contains_key(*id)).cloned() {
            self.waiting.remove(&id);
            return Some(id);
        }
        while self.head < self.order.len() {
            let i = self.head;
            self.head += 1;
            let id = self.order[i].clone();
            if self.waiting.get(&id) == Some(&i) {
                self.waiting.remove(&id);
                self.compact();
                return Some(id);
            }
        }
        self.compact();
        None
    }

    fn compact(&mut self) {
        if self.head <= 1024 || self.head * 2 <= self.order.len() {
            return;
        }
        self.order.drain(..self.head);
        for pos in self.waiting.values_mut() {
            *pos -= self.head;
        }
        self.head = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(ms: u64) -> Duration {
        Duration::from_millis(ms)
    }
    fn plan(count: i64) -> ImportCommitPlan {
        ImportCommitPlan::new(count, ImportCommitPlan::DEFAULT_INTERVAL)
    }

    #[test]
    fn first_finished_prefix_commits_at_once() {
        let mut p = plan(5);
        assert_eq!(p.finished(0, at(10)), Some(0..1)); // the bin shows something right away
        assert_eq!(p.committed(), 1);
    }

    #[test]
    fn only_the_in_order_prefix_commits() {
        let mut p = plan(4);
        assert_eq!(p.finished(2, at(10)), None); // 0 and 1 still probing: order in the bin stays the input order
        assert_eq!(p.finished(1, at(20)), None);
        assert_eq!(p.finished(0, at(30)), Some(0..3));
        assert_eq!(p.finished(3, at(40)), Some(3..4)); // the last one always commits (nothing left to wait for)
        assert!(p.is_complete());
    }

    #[test]
    fn later_commits_wait_for_the_interval() {
        let mut p = plan(10);
        assert_eq!(p.finished(0, at(0)), Some(0..1));
        assert_eq!(p.finished(1, at(100)), None);
        assert_eq!(p.finished(2, at(200)), None);
        assert_eq!(p.finished(3, at(260)), Some(1..4));
        assert_eq!(p.finished(4, at(300)), None);
        assert_eq!(p.flush(), Some(4..5)); // end of import / timer: whatever is ready
        assert_eq!(p.flush(), None);
    }

    #[test]
    fn flush_holds_back_items_behind_an_unfinished_one() {
        let mut p = plan(3);
        let _ = p.finished(1, at(0));
        let _ = p.finished(2, at(0));
        assert_eq!(p.flush(), None);
        assert_eq!(p.finished(0, at(1)), Some(0..3));
    }

    #[test]
    fn duplicate_and_out_of_range_reports_are_ignored() {
        let mut p = plan(2);
        assert_eq!(p.finished(0, at(0)), Some(0..1));
        assert_eq!(p.finished(0, at(500)), None);
        assert_eq!(p.finished(7, at(500)), None);
        assert_eq!(p.finished(-1, at(500)), None);
        assert!(!p.is_complete());
    }

    #[test]
    fn serves_in_arrival_order_without_visibility() {
        let mut q = VisibleFirstQueue::new();
        for i in [3, 1, 2] {
            q.enqueue(i);
        }
        assert_eq!([q.pop_next(), q.pop_next(), q.pop_next(), q.pop_next()], [Some(3), Some(1), Some(2), None]);
    }

    #[test]
    fn visible_items_jump_the_queue_in_screen_order() {
        let mut q = VisibleFirstQueue::new();
        for i in 0..10 {
            q.enqueue(i);
        }
        q.set_visible(vec![8, 6, 7]); // scrolled down: these are on screen, top-left first
        assert_eq!([q.pop_next(), q.pop_next(), q.pop_next()], [Some(8), Some(6), Some(7)]);
        assert_eq!([q.pop_next(), q.pop_next()], [Some(0), Some(1)]); // then the rest, oldest request first
    }

    #[test]
    fn enqueue_is_idempotent_and_keeps_the_first_place() {
        let mut q = VisibleFirstQueue::new();
        for id in ["a", "b", "a"] {
            q.enqueue(id);
        }
        assert_eq!(q.count(), 2);
        assert_eq!([q.pop_next(), q.pop_next()], [Some("a"), Some("b")]);
    }

    #[test]
    fn visible_but_not_requested_is_not_served() {
        let mut q = VisibleFirstQueue::new();
        q.set_visible(vec![1, 2]);
        q.enqueue(5);
        assert_eq!([q.pop_next(), q.pop_next()], [Some(5), None]);
        q.enqueue(2); // requested later while on screen: first
        q.enqueue(9);
        assert_eq!(q.pop_next(), Some(2));
    }

    #[test]
    fn remove_drops_a_waiting_request() {
        let mut q = VisibleFirstQueue::new();
        for i in 0..3 {
            q.enqueue(i);
        }
        q.remove(&1);
        assert!(q.contains(&0) && !q.contains(&1));
        assert_eq!([q.pop_next(), q.pop_next()], [Some(0), Some(2)]);
        assert!(q.is_empty());
    }

    #[test]
    fn many_items_stay_cheap() {
        let mut q = VisibleFirstQueue::new();
        for i in 0..20_000 {
            q.enqueue(i);
        }
        q.set_visible((19_990..20_000).collect());
        assert_eq!(q.pop_next(), Some(19_990));
        let mut n = 1;
        while q.pop_next().is_some() {
            n += 1;
        }
        assert_eq!(n, 20_000);
    }
}
