//! Snapshot-based undo/redo for any value-type state.
// Swift: History.swift

use std::collections::BTreeSet;
use std::convert::Infallible;

use sq_core_time::Id;

#[derive(Debug, Clone)]
struct Entry<S> {
    name: String,
    state: S,
    /// Names data kept outside the state (the session's side effects of this step); follows the step through undo
    /// and redo and is gone when the step is trimmed, dropped or withdrawn.
    tag: Option<Id>,
}

/// Snapshot-based undo/redo for any value-type state.
#[derive(Debug, Clone)]
pub struct History<S: Clone + PartialEq> {
    current: S,
    undo_stack: Vec<Entry<S>>,
    redo_stack: Vec<Entry<S>>,
    saved: S,
    last_key: Option<String>,
    /// The redo steps a coalesced step (a gesture) replaced when it began, kept while that step is the newest and can
    /// still merge: a gesture that is canceled back to its start gives them back, as if it had never begun.
    held_redo: Vec<Entry<S>>,
    /// The oldest undo steps that gesture's step pushed over the `limit`, given back the same way.
    held_oldest: Vec<Entry<S>>,
    /// Undo entries dropped by the `limit` trim. Depths are counted from the very first step, so a depth taken
    /// before a trim still names the same step afterwards (clamped to the oldest entry still held).
    dropped: usize,
    /// Tags of undo steps taken out of the stack with their change still in effect (a gesture canceled back to its start,
    /// `rewind`), newest first. The owner of the tagged data undoes it and takes the list with `take_withdrawn_tags`.
    withdrawn: Vec<Id>,
    /// Tags of the steps `squash` merged (and the tag of the step they merged into), oldest first: the owner combines
    /// their data under a new tag of the merged step.
    folded: Vec<Id>,
    limit: usize,
}

impl<S: Clone + PartialEq> History<S> {
    /// A history at `initial` with room for `limit` undo steps (at least 1; Swift's default is 200).
    pub fn new(initial: S, limit: usize) -> Self {
        History {
            saved: initial.clone(),
            current: initial,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            last_key: None,
            held_redo: Vec::new(),
            held_oldest: Vec::new(),
            dropped: 0,
            withdrawn: Vec::new(),
            folded: Vec::new(),
            limit: limit.max(1),
        }
    }

    /// A history with the default limit of 200 steps.
    pub fn with_default_limit(initial: S) -> Self {
        Self::new(initial, 200)
    }

    /// The state the history is at.
    pub fn current(&self) -> &S {
        &self.current
    }

    /// The undo limit.
    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Whether there is a step to undo.
    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    /// Whether there is a step to redo.
    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// Name of the step Undo takes.
    pub fn undo_name(&self) -> Option<&str> {
        self.undo_stack.last().map(|e| e.name.as_str())
    }

    /// Name of the step Redo takes.
    pub fn redo_name(&self) -> Option<&str> {
        self.redo_stack.last().map(|e| e.name.as_str())
    }

    /// Whether the current state differs from the saved one.
    pub fn is_dirty(&self) -> bool {
        self.current != self.saved
    }

    /// Names of the undo steps still held, oldest first (the History panel's list; trimmed steps are not in it).
    pub fn undo_names(&self) -> Vec<&str> {
        self.undo_stack.iter().map(|e| e.name.as_str()).collect()
    }

    /// Names of the redo steps, the one Redo takes first at the start.
    pub fn redo_names(&self) -> Vec<&str> {
        self.redo_stack.iter().rev().map(|e| e.name.as_str()).collect()
    }

    /// Marks the current state as saved.
    pub fn mark_saved(&mut self) {
        self.saved = self.current.clone();
    }

    /// Marks `state` (what was written) as the saved one, even when undo or redo moved on while the write ran.
    pub fn mark_saved_state(&mut self, state: S) {
        self.saved = state;
    }

    /// Runs `change` on a copy of the state and records a named undo step when it changed something.
    pub fn commit(&mut self, name: &str, change: impl FnOnce(&mut S)) {
        self.commit_coalescing(name, None, change);
    }

    /// Like `commit`, but the change may fail; the state stays untouched then.
    pub fn try_commit<E>(&mut self, name: &str, change: impl FnOnce(&mut S) -> Result<(), E>) -> Result<(), E> {
        self.try_commit_coalescing(name, None, change)
    }

    /// Consecutive commits with the same non-nil `key` merge into one undo step. A merged commit that brings the state
    /// back to where the step began (a gesture canceled with Esc) drops the step: there is nothing left to undo, and
    /// what could be redone before the gesture can be redone again.
    pub fn commit_coalescing(&mut self, name: &str, key: Option<&str>, change: impl FnOnce(&mut S)) {
        let done: Result<(), Infallible> = self.try_commit_coalescing(name, key, |s| {
            change(s);
            Ok(())
        });
        let Ok(()) = done;
    }

    /// `commit_coalescing` with a change that may fail.
    pub fn try_commit_coalescing<E>(
        &mut self,
        name: &str,
        key: Option<&str>,
        change: impl FnOnce(&mut S) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut next = self.current.clone();
        change(&mut next)?;
        if next == self.current {
            return Ok(());
        }
        let merges = key.is_some() && key == self.last_key.as_deref() && !self.undo_stack.is_empty();
        if merges {
            let Some(last) = self.undo_stack.last_mut() else { return Ok(()) };
            if last.state == next {
                if let Some(t) = last.tag {
                    self.withdrawn.push(t);
                }
                self.undo_stack.pop();
                let held_oldest = std::mem::take(&mut self.held_oldest);
                self.dropped -= held_oldest.len();
                self.undo_stack.splice(0..0, held_oldest);
                self.redo_stack = std::mem::take(&mut self.held_redo);
                self.set_last_key(None);
                self.current = next;
                return Ok(());
            }
            last.name = name.to_string();
        } else {
            self.undo_stack.push(Entry { name: name.to_string(), state: self.current.clone(), tag: None });
            let over = self.undo_stack.len().saturating_sub(self.limit);
            let oldest: Vec<Entry<S>> = self.undo_stack.iter().take(over).cloned().collect();
            if over > 0 {
                self.dropped += over;
                self.undo_stack.drain(..over);
            }
            self.set_last_key(None);
            if key.is_some() {
                self.held_redo = self.redo_stack.clone();
                self.held_oldest = oldest;
            }
        }
        self.set_last_key(key.map(str::to_string));
        self.redo_stack.clear();
        self.current = next;
        Ok(())
    }

    /// Setting the key to nil lets go of what a gesture kept aside for a cancel.
    fn set_last_key(&mut self, key: Option<String>) {
        if key.is_none() {
            self.held_redo.clear();
            self.held_oldest.clear();
        }
        self.last_key = key;
    }

    /// Applies `change` to the current state, every undo and redo state and the saved state: a background
    /// refinement (e.g. detected media properties) that is not an edit. Adds no undo step; dirty stays as it was.
    pub fn amend_all(&mut self, mut change: impl FnMut(&mut S)) {
        change(&mut self.current);
        change(&mut self.saved);
        for e in self
            .undo_stack
            .iter_mut()
            .chain(&mut self.redo_stack)
            .chain(&mut self.held_redo)
            .chain(&mut self.held_oldest)
        {
            change(&mut e.state);
        }
    }

    /// Whether the newest step is a gesture holding redo steps it would give back if canceled.
    pub fn holds_redo(&self) -> bool {
        !self.held_redo.is_empty()
    }

    /// The gesture is over (mouse up): its step merges no further commit and can no longer be canceled away, so what
    /// it held back for a cancel (redo steps, steps over the limit) is let go now, not at the next commit.
    pub fn end_coalescing(&mut self) {
        self.set_last_key(None);
    }

    /// Tag of the step Undo would take.
    pub fn undo_tag(&self) -> Option<Id> {
        self.undo_stack.last().and_then(|e| e.tag)
    }

    /// Tag of the step Redo would take.
    pub fn redo_tag(&self) -> Option<Id> {
        self.redo_stack.last().and_then(|e| e.tag)
    }

    /// Every tag still held by an undo or redo step.
    pub fn live_tags(&self) -> BTreeSet<Id> {
        let all = self.undo_stack.iter().chain(&self.redo_stack).chain(&self.held_redo).chain(&self.held_oldest);
        all.filter_map(|e| e.tag).collect()
    }

    /// The tags of steps withdrawn since the last call (newest first); their data must be undone by the caller.
    pub fn take_withdrawn_tags(&mut self) -> Vec<Id> {
        std::mem::take(&mut self.withdrawn)
    }

    /// The tags of steps merged by `squash` since the last call (oldest first); the caller tags the merged step anew.
    pub fn take_folded_tags(&mut self) -> Vec<Id> {
        std::mem::take(&mut self.folded)
    }

    /// Renames the undo steps made since `depth` (a value of `undo_depth` taken earlier); returns how many. The API
    /// calls the steps an import made "Agent: Import" so the agent can undo them.
    pub fn rename_steps_since(&mut self, depth: usize, name: &str) -> usize {
        let from = depth.saturating_sub(self.dropped).min(self.undo_stack.len());
        for e in &mut self.undo_stack[from..] {
            e.name = name.to_string();
        }
        self.undo_stack.len() - from
    }

    /// Tags the newest undo step (false when there is none).
    pub fn tag_newest_step(&mut self, tag: Id) -> bool {
        let Some(last) = self.undo_stack.last_mut() else { return false };
        last.tag = Some(tag);
        true
    }

    /// A step that changes nothing in the state (its effect lives outside it): named, tagged, clears Redo.
    pub fn push_marker(&mut self, name: &str, tag: Id) {
        self.undo_stack.push(Entry { name: name.to_string(), state: self.current.clone(), tag: Some(tag) });
        if self.undo_stack.len() > self.limit {
            let over = self.undo_stack.len() - self.limit;
            self.dropped += over;
            self.undo_stack.drain(..over);
        }
        self.redo_stack.clear();
        self.set_last_key(None);
    }

    /// Number of undo steps.
    pub fn undo_depth(&self) -> usize {
        self.undo_stack.len() + self.dropped
    }

    /// Goes back to `depth` undo steps and forgets everything above (no redo entries are left): for an edit that is
    /// withdrawn before it was ever finished (an empty text box).
    pub fn rewind(&mut self, to_depth: usize) {
        let depth = to_depth.saturating_sub(self.dropped);
        if self.undo_stack.len() <= depth {
            return;
        }
        self.current = self.undo_stack[depth].state.clone();
        self.withdrawn.extend(self.undo_stack[depth..].iter().rev().filter_map(|e| e.tag));
        self.undo_stack.truncate(depth);
        self.redo_stack.clear();
        self.set_last_key(None);
    }

    /// Folds the undo steps above `depth` into one named step (state before the first of them).
    pub fn squash(&mut self, from_depth: usize, name: &str) {
        let depth = from_depth.saturating_sub(self.dropped);
        if self.undo_stack.len() <= depth {
            return;
        }
        self.undo_stack[depth].name = name.to_string();
        if self.undo_stack.len() > depth + 1 {
            let tags: Vec<Id> = self.undo_stack[depth..].iter().filter_map(|e| e.tag).collect();
            if !tags.is_empty() {
                self.folded.extend(tags);
                self.undo_stack[depth].tag = None;
            }
            self.undo_stack.truncate(depth + 1);
        }
        self.set_last_key(None);
    }

    /// Steps back one undo step; false when there is none.
    pub fn undo(&mut self) -> bool {
        let Some(e) = self.undo_stack.pop() else { return false };
        let state = std::mem::replace(&mut self.current, e.state);
        self.redo_stack.push(Entry { name: e.name, state, tag: e.tag });
        self.set_last_key(None);
        true
    }

    /// Steps forward one redo step; false when there is none.
    pub fn redo(&mut self) -> bool {
        let Some(e) = self.redo_stack.pop() else { return false };
        let state = std::mem::replace(&mut self.current, e.state);
        self.undo_stack.push(Entry { name: e.name, state, tag: e.tag });
        self.set_last_key(None);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(initial: i64) -> History<i64> {
        History::with_default_limit(initial)
    }

    #[test]
    fn no_op_commit_adds_nothing() {
        let mut h = h(1);
        h.commit("Nothing", |_| {});
        h.commit("Same", |s| *s = 1);
        assert!(!h.can_undo());
        assert!(!h.is_dirty());
    }

    #[test]
    fn throw_leaves_state_untouched() {
        let mut h = h(1);
        h.commit("Inc", |s| *s += 1);
        h.undo();
        let r = h.try_commit("Bad", |s| {
            *s = 99;
            Err("boom")
        });
        assert_eq!(r, Err("boom"));
        assert_eq!(*h.current(), 1);
        assert!(!h.can_undo());
        assert!(h.can_redo());
    }

    #[test]
    fn new_commit_clears_redo() {
        let mut h = h(0);
        h.commit("A", |s| *s = 1);
        h.undo();
        assert!(h.can_redo());
        h.commit("B", |s| *s = 2);
        assert!(!h.can_redo());
        assert_eq!(h.redo_name(), None);
        assert!(!h.redo());
    }

    #[test]
    fn undo_redo_on_empty_return_false() {
        let mut h = h(0);
        assert!(!h.undo());
        assert!(!h.redo());
    }

    #[test]
    fn coalescing_merges_same_key() {
        let mut h = h(0);
        h.commit_coalescing("Move", Some("drag"), |s| *s = 1);
        h.commit_coalescing("Move 2", Some("drag"), |s| *s = 2);
        h.commit_coalescing("Move 3", Some("drag"), |s| *s = 3);
        assert_eq!(h.undo_name(), Some("Move 3"));
        assert!(h.undo());
        assert_eq!(*h.current(), 0);
        assert!(!h.can_undo());
    }

    #[test]
    fn coalescing_breaks_on_other_key_or_undo() {
        let mut h = h(0);
        h.commit_coalescing("A", Some("x"), |s| *s = 1);
        h.commit_coalescing("B", Some("y"), |s| *s = 2);
        h.commit("C", |s| *s = 3);
        h.commit_coalescing("D", Some("y"), |s| *s = 4);
        assert_eq!(*h.current(), 4);
        for _ in 0..4 {
            h.undo();
        }
        assert_eq!(*h.current(), 0);
        assert!(!h.can_undo());

        let mut g = self::h(0);
        g.commit_coalescing("A", Some("x"), |s| *s = 1);
        g.undo();
        g.redo();
        g.commit_coalescing("A2", Some("x"), |s| *s = 2);
        g.undo();
        assert_eq!(*g.current(), 1);
    }

    // Swift CoreFindingsTests: squashDepthSurvivesHistoryTrim / rewindDepthSurvivesHistoryTrim.
    #[test]
    fn squash_depth_survives_history_trim() {
        let mut h = History::new(0, 3);
        h.commit("a", |s| *s = 1);
        let depth = h.undo_depth();
        for (n, v) in [("b", 2), ("c", 3), ("d", 4)] {
            h.commit(n, |s| *s = v); // the 3-step limit drops the oldest entry; `depth` still means "before b"
        }
        h.squash(depth, "squashed");
        assert_eq!(h.undo_name(), Some("squashed"));
        h.undo();
        assert_eq!(*h.current(), 1); // one undo reverts b, c and d together
    }

    #[test]
    fn rewind_depth_survives_history_trim() {
        let mut h = History::new(0, 3);
        h.commit("a", |s| *s = 1);
        let depth = h.undo_depth();
        for (n, v) in [("b", 2), ("c", 3), ("d", 4)] {
            h.commit(n, |s| *s = v);
        }
        h.rewind(depth);
        assert_eq!(*h.current(), 1);
    }

    #[test]
    fn limit_drops_oldest() {
        let mut h = History::new(0, 3);
        for i in 1..=5 {
            h.commit(&format!("c{i}"), |s| *s = i);
        }
        let mut steps = 0;
        while h.undo() {
            steps += 1;
        }
        assert_eq!(steps, 3);
        assert_eq!(*h.current(), 2);
    }

    #[test]
    fn dirty_tracking() {
        let mut h = h(0);
        assert!(!h.is_dirty());
        h.commit("A", |s| *s = 1);
        assert!(h.is_dirty());
        h.mark_saved();
        assert!(!h.is_dirty());
        h.commit("B", |s| *s = 2);
        assert!(h.is_dirty());
        h.undo();
        assert!(!h.is_dirty());
        h.undo();
        assert!(h.is_dirty());
        h.redo();
        assert!(!h.is_dirty());
    }

    #[test]
    fn amend_all_changes_every_state_without_an_undo_step_or_dirt() {
        let mut h = h(1);
        h.commit("inc", |s| *s += 1);
        h.commit("inc", |s| *s += 1);
        h.mark_saved();
        h.undo();
        h.amend_all(|s| *s += 100);
        assert_eq!(*h.current(), 102);
        assert!(h.is_dirty());
        h.redo();
        assert_eq!(*h.current(), 103);
        h.undo();
        h.undo();
        assert_eq!(*h.current(), 101);
        assert_eq!(h.undo_name(), None);
    }

    #[test]
    fn coalesced_commit_back_to_the_start_drops_the_step() {
        let mut h = h(1);
        h.commit("Before", |s| *s = 5);
        h.commit_coalescing("Change Opacity", Some("g"), |s| *s = 6);
        h.commit_coalescing("Change Opacity", Some("g"), |s| *s = 7);
        h.commit_coalescing("Cancel", Some("g"), |s| *s = 5);
        assert_eq!(*h.current(), 5);
        assert_eq!(h.undo_name(), Some("Before"));
        assert!(!h.can_redo());
        h.undo();
        assert_eq!(*h.current(), 1);
    }

    #[test]
    fn a_canceled_gesture_gives_the_redo_steps_back() {
        let mut h = h(1);
        h.commit("A", |s| *s = 2);
        h.commit("B", |s| *s = 3);
        h.undo();
        h.undo();
        h.redo();
        h.commit_coalescing("Drag", Some("g"), |s| *s = 10);
        assert!(!h.can_redo());
        h.amend_all(|s| *s += 100);
        h.commit_coalescing("Drag", Some("g"), |s| *s = 111);
        h.commit_coalescing("Drag", Some("g"), |s| *s = 102);
        assert!(*h.current() == 102 && h.undo_name() == Some("A") && h.redo_name() == Some("B"));
        h.redo();
        assert_eq!(*h.current(), 103);
        h.undo();
        h.commit_coalescing("Drag", Some("g"), |s| *s = 110);
        h.commit("Other", |s| *s = 120);
        assert!(!h.can_redo());
        h.undo();
        h.undo();
        assert!(*h.current() == 102 && h.redo_name() == Some("Drag"));
        h.commit_coalescing("Drag", Some("k"), |s| *s = 110);
        h.undo();
        h.commit_coalescing("Drag", Some("k"), |s| *s = 111);
        assert!(h.undo_name() == Some("Drag") && !h.can_redo());
    }

    #[test]
    fn an_ended_gesture_lets_its_held_redo_go() {
        let mut h = h(1);
        h.commit("A", |s| *s = 2);
        h.commit("B", |s| *s = 3);
        h.undo();
        h.commit_coalescing("Drag", Some("g"), |s| *s = 10);
        assert!(h.holds_redo());
        h.end_coalescing();
        assert!(!h.holds_redo());
        h.commit_coalescing("Drag", Some("g"), |s| *s = 2);
        assert!(h.undo_name() == Some("Drag") && !h.can_redo());
        h.undo();
        assert_eq!(*h.current(), 10);
        h.undo();
        assert_eq!(*h.current(), 2);
    }

    #[test]
    fn a_canceled_gesture_at_the_limit_gives_the_oldest_step_back() {
        let mut h = History::new(0, 3);
        for i in 1..=3 {
            h.commit(&format!("c{i}"), |s| *s = i);
        }
        let depth = h.undo_depth();
        h.commit_coalescing("Drag", Some("g"), |s| *s = 10);
        assert_eq!(h.undo_depth(), depth + 1);
        h.amend_all(|s| *s += 100);
        h.commit_coalescing("Drag", Some("g"), |s| *s = 103);
        assert!(h.undo_depth() == depth && h.undo_name() == Some("c3"));
        let mut steps = 0;
        while h.undo() {
            steps += 1;
        }
        assert!(steps == 3 && *h.current() == 100);
        let mut k = History::new(0, 3);
        for i in 1..=3 {
            k.commit(&format!("c{i}"), |s| *s = i);
        }
        k.commit_coalescing("Drag", Some("g"), |s| *s = 10);
        k.end_coalescing();
        k.commit_coalescing("Drag", Some("g"), |s| *s = 3);
        steps = 0;
        while k.undo() {
            steps += 1;
        }
        assert!(steps == 3 && *k.current() == 2);
    }

    #[test]
    fn coalesced_commit_back_to_the_start_does_not_merge_the_next_gesture() {
        let mut h = h(1);
        h.commit_coalescing("A", Some("g"), |s| *s = 2);
        h.commit_coalescing("A", Some("g"), |s| *s = 1);
        assert!(!h.can_undo());
        h.commit_coalescing("B", Some("g"), |s| *s = 3);
        h.commit_coalescing("B", Some("g"), |s| *s = 4);
        assert_eq!(h.undo_name(), Some("B"));
        h.undo();
        assert!(*h.current() == 1 && !h.can_undo());
    }

    #[test]
    fn amend_all_keeps_clean_state_clean() {
        let mut h = h(1);
        h.amend_all(|s| *s += 1);
        assert!(*h.current() == 2 && !h.is_dirty() && !h.can_undo());
    }

    fn two() -> History<i64> {
        let mut h = h(0);
        h.commit("A", |s| *s = 1);
        h
    }

    #[test]
    fn rewind_drops_steps_without_redo() {
        let mut h = two();
        h.commit("B", |s| *s = 2);
        h.commit("C", |s| *s = 3);
        assert_eq!(h.undo_depth(), 3);
        h.rewind(1);
        assert!(*h.current() == 1 && h.undo_depth() == 1 && h.undo_name() == Some("A"));
        assert!(!h.can_redo());
    }

    #[test]
    fn rewind_to_the_current_depth_changes_nothing() {
        let mut h = two();
        h.rewind(1);
        assert!(*h.current() == 1 && h.undo_depth() == 1);
        h.rewind(5);
        assert!(*h.current() == 1 && h.undo_depth() == 1);
    }

    #[test]
    fn squash_folds_steps_above_depth_into_one() {
        let mut h = two();
        h.commit("B", |s| *s = 2);
        h.commit("C", |s| *s = 3);
        h.squash(1, "Add Text");
        assert!(*h.current() == 3 && h.undo_depth() == 2 && h.undo_name() == Some("Add Text"));
        h.undo();
        assert_eq!(*h.current(), 1);
    }

    #[test]
    fn squash_of_a_single_step_only_renames() {
        let mut h = two();
        h.squash(0, "Renamed");
        assert!(h.undo_depth() == 1 && h.undo_name() == Some("Renamed") && *h.current() == 1);
    }

    #[test]
    fn a_marker_is_a_step_without_a_change() {
        let mut h = h(0);
        let t = Id::from_u128(1);
        h.push_marker("Delete", t);
        assert!(h.can_undo() && h.undo_name() == Some("Delete") && h.undo_tag() == Some(t) && *h.current() == 0);
        h.undo();
        assert!(!h.can_undo() && h.redo_tag() == Some(t));
        h.redo();
        assert_eq!(h.undo_tag(), Some(t));
    }

    #[test]
    fn a_tag_follows_a_step_and_goes_with_it() {
        let mut h = History::new(0, 2);
        h.commit("A", |s| *s = 1);
        let t = Id::from_u128(1);
        assert!(h.tag_newest_step(t) && h.live_tags() == BTreeSet::from([t]));
        h.undo();
        h.commit("B", |s| *s = 2);
        assert!(h.live_tags().is_empty());
        h.push_marker("M", Id::from_u128(2));
        h.commit("C", |s| *s = 3);
        h.commit("D", |s| *s = 4);
        assert!(h.live_tags().is_empty());
    }

    #[test]
    fn rewind_drops_tags() {
        let mut h = h(0);
        h.commit("A", |s| *s = 1);
        h.tag_newest_step(Id::from_u128(1));
        h.rewind(0);
        assert!(h.live_tags().is_empty());
    }

    #[test]
    fn rewind_reports_the_tags_it_withdrew() {
        let mut h = h(0);
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        h.commit("A", |s| *s = 1);
        h.tag_newest_step(a);
        h.commit("B", |s| *s = 2);
        h.tag_newest_step(b);
        h.rewind(0);
        assert_eq!(h.take_withdrawn_tags(), vec![b, a]);
        assert!(h.take_withdrawn_tags().is_empty());
    }

    #[test]
    fn a_canceled_gesture_reports_its_tag() {
        let mut h = h(0);
        h.commit_coalescing("Drag", Some("g"), |s| *s = 1);
        let t = Id::from_u128(1);
        h.tag_newest_step(t);
        h.commit_coalescing("Drag", Some("g"), |s| *s = 0);
        assert!(!h.can_undo() && h.take_withdrawn_tags() == vec![t]);
    }

    #[test]
    fn squash_reports_the_tags_it_merged() {
        let mut h = h(0);
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        h.commit("A", |s| *s = 1);
        h.tag_newest_step(a);
        h.commit("B", |s| *s = 2);
        h.tag_newest_step(b);
        h.commit("C", |s| *s = 3);
        h.squash(0, "All");
        assert!(h.undo_depth() == 1 && h.take_folded_tags() == vec![a, b]);
        assert!(h.undo_tag().is_none() && h.live_tags().is_empty());
    }

    #[test]
    fn squash_without_tags_reports_nothing() {
        let mut h = h(0);
        h.commit("A", |s| *s = 1);
        h.commit("B", |s| *s = 2);
        h.squash(0, "All");
        assert!(h.take_folded_tags().is_empty());
    }

    /// Deterministic xorshift so the property tests need no RNG crate.
    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self, n: u64) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 % n
        }
    }

    /// Undo directly after a commit gives back the exact previous state, redo the exact next one, for random
    /// sequences of plain, coalesced, undo, redo and amend operations on a vector state.
    #[test]
    fn undo_after_do_restores_the_snapshot() {
        for seed in 1..=40u64 {
            let mut rng = Lcg(seed * 7919);
            let mut h = History::new(vec![0i64], 5);
            for _ in 0..300 {
                let before = h.current().clone();
                match rng.next(6) {
                    0 | 1 => {
                        let v = rng.next(4) as i64;
                        h.commit("edit", |s| s.push(v));
                        if *h.current() != before {
                            let after = h.current().clone();
                            assert!(h.undo());
                            assert_eq!(*h.current(), before);
                            assert!(h.redo());
                            assert_eq!(*h.current(), after);
                        }
                    }
                    2 => {
                        let key = ["a", "b"][rng.next(2) as usize];
                        h.commit_coalescing("drag", Some(key), |s| s.push(9));
                    }
                    3 => {
                        h.undo();
                    }
                    4 => {
                        h.redo();
                    }
                    _ => h.end_coalescing(),
                }
            }
            // Undoing everything and redoing everything meets the same end state.
            let end = h.current().clone();
            let mut steps = 0;
            while h.undo() {
                steps += 1;
            }
            for _ in 0..steps {
                assert!(h.redo());
            }
            assert_eq!(*h.current(), end);
        }
    }

    /// A model of the stack (plain commits only) agrees with the history after any undo/redo walk.
    #[test]
    fn undo_redo_walk_matches_a_plain_stack_model() {
        let mut rng = Lcg(12345);
        let mut h = History::new(0i64, 1000);
        let mut states = vec![0i64];
        let mut at = 0usize;
        for i in 1..=400i64 {
            match rng.next(3) {
                0 => {
                    h.commit("c", |s| *s = i);
                    states.truncate(at + 1);
                    states.push(i);
                    at += 1;
                }
                1 => {
                    assert_eq!(h.undo(), at > 0);
                    at = at.saturating_sub(1);
                }
                _ => {
                    let can = at + 1 < states.len();
                    assert_eq!(h.redo(), can);
                    if can {
                        at += 1;
                    }
                }
            }
            assert_eq!(*h.current(), states[at]);
            assert_eq!(h.undo_depth(), at);
            assert_eq!(h.can_redo(), at + 1 < states.len());
        }
    }
}
