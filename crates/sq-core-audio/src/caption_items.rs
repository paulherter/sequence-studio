// Swift: Captions.swift (the `CaptionTrack` verbs, written on the sorted item list)
//! Caption track verbs on the sorted item list of one track. Swift keeps `items` private to `CaptionTrack`; the model keeps
//! it private too, so these are methods of `Vec<CaptionItem>`. The track wrapper (`CaptionTrack::with_items`) is listed
//! in NOTES.md. Everything that reads the track's own look takes it as arguments.

use crate::caption_item::CaptionItemExt;
use crate::caption_words::{CaptionNeighbor, CaptionWordEditExt, relative_words};
use sq_core_model::{CaptionItem, CaptionPosition, CaptionWord, ClipEdge, EditError};
use sq_core_time::{Id, IdSource, Time, TimeRange, word_segmentation};
use std::collections::BTreeSet;

/// Sorted by start, never overlapping: the item list of a caption track.
pub trait CaptionItemsExt {
    /// The item with `id`.
    fn item(&self, id: Id) -> Option<&CaptionItem>;
    /// Replaces all items. Fails with `EmptyClip` for an empty range, `Collision` for overlaps. Unsorted input is sorted.
    fn replace_all(&mut self, new: Vec<CaptionItem>) -> Result<(), EditError>;
    /// Edits the text only; timing is untouched.
    fn set_lines(&mut self, id: Id, lines: Vec<String>) -> bool;
    /// Moves an item so it starts at `start`, keeping its duration. Clamped by the neighbors and 0. Returns the applied
    /// start, or `None` if the item is unknown.
    fn move_item(&mut self, id: Id, start: Time) -> Option<Time>;
    /// Moves one edge to `t`. Clamped by the neighbors, 0 and `min_duration` (the item never gets shorter; one that is
    /// already shorter, squeezed by its neighbors, just cannot shrink further). The neighbors always win: the result never
    /// overlaps them, however short the item is. Returns the new range, or `None` if the item is unknown.
    fn trim(&mut self, id: Id, edge: ClipEdge, t: Time, min_duration: Time) -> Option<TimeRange>;
    /// Removes the item.
    fn remove_item(&mut self, id: Id);
    /// Splits at `t` (strictly inside the item). The words are shared out by the time proportion, at least one word each
    /// side while the item has two or more. Both halves keep style and animation. Returns the new ids.
    fn split_at(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Option<(Id, Id)>;
    /// The cut itself: the first `k` words stay in the left half (`t` strictly inside the item).
    fn split_item(&mut self, i: usize, t: Time, left_words: usize, ids: &mut dyn IdSource) -> (Id, Id);
    /// Merges the items from the earliest to the latest of `ids` (everything in between is included) into the earliest one:
    /// text joined by a space on one line, range from the first start to the last end.
    fn merge(&mut self, ids: &BTreeSet<Id>) -> Option<Id>;
    /// New empty caption starting at `at` (not inside another item) up to `duration`, cut short by the next item. A new
    /// caption follows the track's style (`track_style`, `track_animation`); without one it takes its neighbor's look.
    fn add(
        &mut self,
        at: Time,
        duration: Time,
        track_look: (&str, &str),
        fallback_look: (&str, &str),
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// The track style: applied to every caption that has no style of its own.
    fn set_style(&mut self, style_ref: &str, animation_ref: Option<&str>);
    /// Gives the captions their own style (`style_ref`), or hands them back to the track style (`None`).
    fn set_item_style(&mut self, ids: &BTreeSet<Id>, style_ref: Option<&str>, track_style: &str, track_animation: &str);
    /// Gives the captions their own animation (they then also stop following the track look, so a track change leaves the
    /// animation alone), or with `None` hands them back to the track look. Stored in the existing `animation_ref`.
    fn set_item_animation(
        &mut self,
        ids: &BTreeSet<Id>,
        animation_ref: Option<&str>,
        track_style: &str,
        track_animation: &str,
    );
    /// Hands the captions back to the track look completely: style, animation and position (sparse overrides cleared).
    fn reset_items_to_track_look(&mut self, ids: &BTreeSet<Id>, track_style: &str, track_animation: &str);
    /// Captions that deviate from the track look (own style, animation or position).
    fn overridden_count(&self) -> usize;
    /// Gives the captions their own position, or `None` hands them back to the kit position.
    fn set_item_position(&mut self, ids: &BTreeSet<Id>, position: Option<CaptionPosition>);
    /// Replaces `find` in every line; returns the number of replacements. The caption ranges are untouched and the word
    /// timings follow the text, one match at a time so only the words a match touches are refitted.
    fn replace_text(&mut self, find: &str, new: &str, case_sensitive: bool) -> usize;
    /// Ripple-closes `span`: material after it moves left by its duration, items inside it are cut out (fully covered ones
    /// vanish, straddling ones shrink). Items never overlap afterwards.
    fn close_span(&mut self, span: &TimeRange);
    /// `close_span` for many spans at once: `f` is their composed point map.
    fn close_spans(&mut self, f: &dyn Fn(Time) -> Time);
    /// Ripple-opens a gap of `length` at `pivot`: items starting at or after it move right with their words; an item
    /// that starts before the pivot stays as it is (an insert never stretches a caption).
    fn open_gap(&mut self, pivot: Time, length: Time);
    /// Replaces word `index` by the words of `text` (several when it holds spaces, none when it is empty: the word is
    /// deleted; the caption goes with its last word). Returns how many words stand there now, `None` for unknown input.
    fn set_word(&mut self, id: Id, index: usize, text: &str) -> Option<usize>;
    /// Inserts the words of `text` before word `index` (`tokens.len()` = at the end). Returns the number inserted.
    fn insert_word(&mut self, id: Id, index: usize, text: &str) -> Option<usize>;
    /// Splits so that word `k` starts the second caption. The cut never lands inside a word: it is the frame (`snap`)
    /// nearest to where that word starts or to where the word before ends, when that frame lies in the pause between the
    /// two; else it is the word boundary itself, off the frame grid. So no word is cut short. The halves touch.
    fn split_before_word(
        &mut self,
        id: Id,
        k: usize,
        snap: &dyn Fn(Time) -> Time,
        ids: &mut dyn IdSource,
    ) -> Option<(Id, Id)>;
    /// The item before or after `id`.
    fn neighbor_of(&self, id: Id, side: CaptionNeighbor) -> Option<&CaptionItem>;
    /// Moves one edge of word `index` to timeline time `t`. Nothing ripples: the edge stops at the neighboring word and at
    /// the caption's own edges, and the word keeps at least `min_duration` (one already shorter cannot shrink). With
    /// `rolling`, an edge that touches the neighboring word takes that word's edge along. A caption without timings gets
    /// them here, from its spread words. Returns the word's new range on the timeline.
    fn retime_word(
        &mut self,
        id: Id,
        index: usize,
        edge: ClipEdge,
        t: Time,
        min_duration: Time,
        rolling: bool,
    ) -> Option<TimeRange>;
}

/// After a ripple: the word times of `old` pass through the same time map as the material, and are stored relative to the
/// (already set) new range. Items without usable timings are left alone.
fn map_words(item: &mut CaptionItem, old: &CaptionItem, f: &dyn Fn(Time) -> Time) {
    if !old.has_word_timings() {
        return;
    }
    let moved: Vec<CaptionWord> = old
        .effective_words()
        .into_iter()
        .map(|w| CaptionWord {
            text: w.text,
            range: TimeRange::from_end(f(w.range.start), f(w.range.end())),
            confidence: w.confidence,
        })
        .collect();
    item.words = relative_words(&moved, &item.range);
}

fn remap(items: &mut Vec<CaptionItem>, f: &dyn Fn(Time) -> Time) {
    let old = std::mem::take(items);
    *items = old
        .iter()
        .filter_map(|item| {
            let mut c = item.clone();
            let r = TimeRange::from_end(f(item.range.start), f(item.range.end()));
            if r.is_empty() {
                return None;
            }
            c.range = r;
            map_words(&mut c, item, f);
            Some(c)
        })
        .collect();
}

impl CaptionItemsExt for Vec<CaptionItem> {
    fn item(&self, id: Id) -> Option<&CaptionItem> {
        self.iter().find(|i| i.id == id)
    }

    fn replace_all(&mut self, new: Vec<CaptionItem>) -> Result<(), EditError> {
        let mut sorted = new;
        sorted.sort_by_key(|i| i.range.start);
        if !sorted.iter().all(|i| !i.range.is_empty() && i.range.start >= Time::ZERO) {
            return Err(EditError::EmptyClip);
        }
        if !sorted.windows(2).all(|w| w[0].range.end() <= w[1].range.start) {
            return Err(EditError::Collision);
        }
        *self = sorted;
        Ok(())
    }

    fn set_lines(&mut self, id: Id, lines: Vec<String>) -> bool {
        let Some(i) = self.iter().position(|x| x.id == id) else { return false };
        self[i].lines = lines;
        true
    }

    fn move_item(&mut self, id: Id, start: Time) -> Option<Time> {
        let i = self.iter().position(|x| x.id == id)?;
        let dur = self[i].range.duration;
        let lo = if i > 0 { self[i - 1].range.end() } else { Time::ZERO };
        let mut s = start.max(lo);
        if i + 1 < self.len() {
            s = s.min(self[i + 1].range.start - dur);
        }
        s = s.max(lo);
        self[i].range = TimeRange::new(s, dur);
        Some(s)
    }

    fn trim(&mut self, id: Id, edge: ClipEdge, t: Time, min_duration: Time) -> Option<TimeRange> {
        let i = self.iter().position(|x| x.id == id)?;
        let r = self[i].range;
        match edge {
            ClipEdge::Head => {
                let lo = if i > 0 { self[i - 1].range.end() } else { Time::ZERO };
                let hi = r.start.max(r.end() - min_duration);
                let new_start = lo.max(t.min(hi));
                self[i].shift_word_origin(new_start - r.start); // word times are relative to the start
                self[i].range = TimeRange::from_end(new_start, r.end());
            }
            ClipEdge::Tail => {
                let mut e = t.max(r.end().min(r.start + min_duration));
                if i + 1 < self.len() {
                    e = e.min(self[i + 1].range.start); // the neighbor wins over min_duration
                }
                self[i].range = TimeRange::from_end(r.start, e);
            }
        }
        Some(self[i].range)
    }

    fn remove_item(&mut self, id: Id) {
        self.retain(|x| x.id != id);
    }

    fn split_at(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Option<(Id, Id)> {
        let i = self.iter().position(|x| x.id == id)?;
        let r = self[i].range;
        if !(t > r.start && t < r.end()) {
            return None;
        }
        let n = self[i].tokens().len();
        let k = if n < 2 {
            n
        } else if self[i].has_word_timings() {
            // With timings the cut falls where the speech does: the words that end at or before the cut stay left.
            let ending = self[i].effective_words().iter().filter(|w| w.range.end() <= t).count();
            ending.max(1).min(n - 1)
        } else {
            let secs = |x: Time| x.value() as f64 / x.timescale() as f64;
            let frac = secs(t - r.start) / secs(r.end() - r.start);
            ((n as f64 * frac).round() as usize).max(1).min(n - 1)
        };
        Some(self.split_item(i, t, k, ids))
    }

    fn split_item(&mut self, i: usize, t: Time, k: usize, ids: &mut dyn IdSource) -> (Id, Id) {
        let r = self[i].range;
        let (mut left, mut right) = (self[i].clone(), self[i].clone());
        left.range = TimeRange::from_end(r.start, t);
        right.range = TimeRange::from_end(t, r.end());
        // Keep the original line breaks where the cut allows: walk the lines, the first k words go left.
        let (mut left_lines, mut right_lines) = (Vec::new(), Vec::new());
        let mut used = 0;
        for line in &self[i].lines {
            let w = word_segmentation::words(line);
            if w.is_empty() {
                continue;
            }
            let take = k.saturating_sub(used).min(w.len());
            if take > 0 {
                left_lines.push(word_segmentation::join(&w[..take]));
            }
            if take < w.len() {
                right_lines.push(word_segmentation::join(&w[take..]));
            }
            used += take;
        }
        left.lines = if left_lines.is_empty() { vec![String::new()] } else { left_lines };
        right.lines = if right_lines.is_empty() { vec![String::new()] } else { right_lines };
        // The word timings go with their words; without timings each half spreads its own.
        if self[i].has_word_timings() {
            let eff = self[i].effective_words(); // absolute, already clamped into the caption
            let cut = k.min(eff.len());
            left.words = relative_words(&eff[..cut], &left.range);
            right.words = relative_words(&eff[cut..], &right.range);
        } else {
            left.words = Vec::new();
            right.words = Vec::new();
        }
        right.id = ids.next_id();
        let (lid, rid) = (left.id, right.id);
        self[i] = left;
        self.insert(i + 1, right);
        (lid, rid)
    }

    fn merge(&mut self, ids: &BTreeSet<Id>) -> Option<Id> {
        let idx: Vec<usize> = (0..self.len()).filter(|i| ids.contains(&self[*i].id)).collect();
        let (lo, hi) = (*idx.first()?, *idx.last()?);
        if lo >= hi {
            return None;
        }
        let mut m = self[lo].clone();
        let text =
            self[lo..=hi].iter().map(|i| i.lines.join(" ")).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ");
        m.lines = vec![text];
        // Timings survive when any part has them: a part without them contributes its spread words (what it showed before
        // the merge), so no word moves. Only when no part is timed does the merged caption spread again.
        m.range = TimeRange::from_end(self[lo].range.start, self[hi].range.end());
        m.words = if self[lo..=hi].iter().any(|i| i.has_word_timings()) {
            let all: Vec<CaptionWord> = self[lo..=hi].iter().flat_map(|i| i.effective_words()).collect();
            relative_words(&all, &m.range)
        } else {
            Vec::new()
        };
        let id = m.id;
        self.splice(lo..=hi, [m]);
        Some(id)
    }

    fn add(
        &mut self,
        at: Time,
        duration: Time,
        track_look: (&str, &str),
        fallback_look: (&str, &str),
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let ((track_style, track_animation), (style, animation)) = (track_look, fallback_look);
        if at < Time::ZERO || duration <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        if self.iter().any(|i| i.range.contains(at)) {
            return Err(EditError::Collision);
        }
        let mut end = at + duration;
        if let Some(next) = self.iter().find(|i| i.range.start >= at) {
            end = end.min(next.range.start);
        }
        if end <= at {
            return Err(EditError::Collision);
        }
        let reference = self.iter().rev().find(|i| i.range.end() <= at).or_else(|| self.first());
        let style_ref =
            if track_style.is_empty() { reference.map_or(style, |r| r.style_ref.as_str()) } else { track_style };
        let animation_ref = if track_animation.is_empty() {
            reference.map_or(animation, |r| r.animation_ref.as_str())
        } else {
            track_animation
        };
        let item = CaptionItem {
            id: ids.next_id(),
            lines: vec![String::new()],
            range: TimeRange::from_end(at, end),
            style_ref: style_ref.to_string(),
            animation_ref: animation_ref.to_string(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        };
        let id = item.id;
        self.push(item);
        self.sort_by_key(|i| i.range.start);
        Ok(id)
    }

    fn set_style(&mut self, style_ref: &str, animation_ref: Option<&str>) {
        for i in self.iter_mut().filter(|i| !i.style_overridden) {
            i.style_ref = style_ref.to_string();
            if let Some(a) = animation_ref {
                i.animation_ref = a.to_string();
            }
        }
    }

    fn set_item_style(
        &mut self,
        ids: &BTreeSet<Id>,
        style_ref: Option<&str>,
        track_style: &str,
        track_animation: &str,
    ) {
        // A track without a style of its own ("" = each caption keeps what it has): hand back to what the captions that
        // follow the track draw with.
        let follower = self.iter().find(|i| !i.style_overridden && !ids.contains(&i.id)).cloned();
        let style =
            if track_style.is_empty() { follower.as_ref().map_or("", |f| f.style_ref.as_str()) } else { track_style };
        let animation = if track_animation.is_empty() {
            follower.as_ref().map_or("", |f| f.animation_ref.as_str())
        } else {
            track_animation
        };
        for i in self.iter_mut().filter(|i| ids.contains(&i.id)) {
            if let Some(s) = style_ref {
                i.style_ref = s.to_string();
                i.style_overridden = true;
            } else {
                i.style_overridden = false;
                if !style.is_empty() {
                    i.style_ref = style.to_string();
                }
                if !animation.is_empty() {
                    i.animation_ref = animation.to_string();
                }
            }
        }
    }

    fn set_item_animation(
        &mut self,
        ids: &BTreeSet<Id>,
        animation_ref: Option<&str>,
        track_style: &str,
        track_animation: &str,
    ) {
        for i in self.iter_mut().filter(|i| ids.contains(&i.id)) {
            if let Some(a) = animation_ref {
                i.animation_ref = a.to_string();
                i.style_overridden = true;
            } else {
                i.style_overridden = false;
                if !track_style.is_empty() {
                    i.style_ref = track_style.to_string();
                }
                if !track_animation.is_empty() {
                    i.animation_ref = track_animation.to_string();
                }
            }
        }
    }

    fn reset_items_to_track_look(&mut self, ids: &BTreeSet<Id>, track_style: &str, track_animation: &str) {
        self.set_item_style(ids, None, track_style, track_animation);
        self.set_item_position(ids, None);
    }

    fn overridden_count(&self) -> usize {
        self.iter().filter(|i| i.style_overridden || i.position.is_some()).count()
    }

    fn set_item_position(&mut self, ids: &BTreeSet<Id>, position: Option<CaptionPosition>) {
        for i in self.iter_mut().filter(|i| ids.contains(&i.id)) {
            i.position = position;
        }
    }

    fn replace_text(&mut self, find: &str, new: &str, case_sensitive: bool) -> usize {
        if find.is_empty() {
            return 0;
        }
        let mut count = 0;
        let mut emptied = BTreeSet::new();
        for item in self.iter_mut() {
            let found = item.text_matches(find, case_sensitive);
            if found.is_empty() {
                continue;
            }
            // Back to front: a line that empties and disappears does not shift the matches still to come.
            for m in found.iter().rev() {
                item.replace_characters(m.range.clone(), m.line, new);
            }
            count += found.len();
            if item.tokens().is_empty() {
                emptied.insert(item.id);
            }
        }
        // A caption left without words goes, as when its last word is deleted.
        if !emptied.is_empty() {
            self.retain(|i| !emptied.contains(&i.id));
        }
        count
    }

    fn close_span(&mut self, span: &TimeRange) {
        if span.is_empty() {
            return;
        }
        let (start, end, dur) = (span.start, span.end(), span.duration);
        remap(self, &move |t| {
            if t <= start {
                t
            } else if t >= end {
                t - dur
            } else {
                start
            }
        });
    }

    fn close_spans(&mut self, f: &dyn Fn(Time) -> Time) {
        remap(self, f);
    }

    fn open_gap(&mut self, pivot: Time, length: Time) {
        if length <= Time::ZERO {
            return;
        }
        let g = move |t: Time| if t >= pivot { t + length } else { t };
        for item in self.iter_mut().filter(|i| i.range.start >= pivot) {
            let old = item.clone();
            item.range = TimeRange::new(old.range.start + length, old.range.duration);
            map_words(item, &old, &g);
        }
    }

    fn set_word(&mut self, id: Id, index: usize, text: &str) -> Option<usize> {
        let new = word_segmentation::words(text);
        let i = self.iter().position(|x| x.id == id)?;
        if index >= self[i].tokens().len() {
            return None;
        }
        self[i].replace_tokens(index..index + 1, &new);
        if self[i].tokens().is_empty() {
            self.remove(i);
        }
        Some(new.len())
    }

    fn insert_word(&mut self, id: Id, index: usize, text: &str) -> Option<usize> {
        let new = word_segmentation::words(text);
        let i = self.iter().position(|x| x.id == id)?;
        if index > self[i].tokens().len() {
            return None;
        }
        if !new.is_empty() {
            self[i].replace_tokens(index..index, &new);
        }
        Some(new.len())
    }

    fn split_before_word(
        &mut self,
        id: Id,
        k: usize,
        snap: &dyn Fn(Time) -> Time,
        ids: &mut dyn IdSource,
    ) -> Option<(Id, Id)> {
        let i = self.iter().position(|x| x.id == id)?;
        let r = self[i].range;
        let eff = self[i].effective_words();
        if k == 0 || k >= eff.len() {
            return None;
        }
        let lo = eff[k - 1].range.end();
        let hi = eff[k].range.start.max(lo);
        let fits = |t: &Time| *t > r.start && *t < r.end() && *t >= lo && *t <= hi;
        let t = [snap(hi), snap(lo), hi, lo].into_iter().find(fits)?;
        Some(self.split_item(i, t, k, ids))
    }

    fn neighbor_of(&self, id: Id, side: CaptionNeighbor) -> Option<&CaptionItem> {
        let i = self.iter().position(|x| x.id == id)?;
        match side {
            CaptionNeighbor::Next => self.get(i + 1),
            CaptionNeighbor::Previous => i.checked_sub(1).and_then(|j| self.get(j)),
        }
    }

    fn retime_word(
        &mut self,
        id: Id,
        index: usize,
        edge: ClipEdge,
        t: Time,
        min_duration: Time,
        rolling: bool,
    ) -> Option<TimeRange> {
        let i = self.iter().position(|x| x.id == id)?;
        let origin = self[i].range.start;
        let d = self[i].range.duration;
        let mut w = relative_words(&self[i].effective_words(), &self[i].range);
        if index >= w.len() {
            return None;
        }
        let cur = w[index].range;
        let rel = t - origin;
        match edge {
            ClipEdge::Head => {
                let prev = if index > 0 { Some(w[index - 1].range) } else { None };
                let rolls = rolling && prev.is_some_and(|p| p.end() >= cur.start);
                let lo = prev.map_or(Time::ZERO, |p| if rolls { p.end().min(p.start + min_duration) } else { p.end() });
                let hi = cur.start.max(cur.end() - min_duration);
                let s = rel.max(lo).min(hi);
                w[index].range = TimeRange::from_end(s, cur.end());
                if let (true, Some(p)) = (rolls, prev) {
                    w[index - 1].range = TimeRange::from_end(p.start.min(s), s);
                }
            }
            ClipEdge::Tail => {
                let next = w.get(index + 1).map(|x| x.range);
                let rolls = rolling && next.is_some_and(|n| n.start <= cur.end());
                let hi = next
                    .map_or(d.max(cur.end()), |n| if rolls { n.start.max(n.end() - min_duration) } else { n.start });
                let lo = cur.end().min(cur.start + min_duration);
                let e = rel.min(hi).max(lo);
                w[index].range = TimeRange::from_end(cur.start, e);
                if let (true, Some(n)) = (rolls, next) {
                    w[index + 1].range = TimeRange::from_end(e, n.end().max(e));
                }
            }
        }
        let out = TimeRange::from_end(origin + w[index].range.start, origin + w[index].range.end());
        self[i].words = w;
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_item::tests::{item, range, t, word};
    use sq_core_time::SequentialIds;

    fn ids() -> SequentialIds {
        SequentialIds::default()
    }
    fn texts(v: &[CaptionItem]) -> Vec<String> {
        v.iter().map(|i| i.text()).collect()
    }
    fn two() -> Vec<CaptionItem> {
        vec![item(&["first"], range(0, 1000)), item(&["second one"], range(2000, 3000))]
    }

    #[test]
    fn replace_all_sorts_and_refuses_empty_and_overlapping_items() {
        let mut v = Vec::new();
        assert_eq!(v.replace_all(vec![item(&["b"], range(2000, 3000)), item(&["a"], range(0, 1000))]), Ok(()));
        assert_eq!(texts(&v), vec!["a", "b"]);
        assert_eq!(v.replace_all(vec![item(&["x"], range(0, 0))]), Err(EditError::EmptyClip));
        assert_eq!(
            v.replace_all(vec![item(&["x"], range(0, 1000)), item(&["y"], range(500, 1500))]),
            Err(EditError::Collision)
        );
        assert_eq!(texts(&v), vec!["a", "b"]); // unchanged after a refused call
    }

    #[test]
    fn move_is_clamped_by_neighbors_and_zero() {
        let mut v = two();
        let id = v[1].id;
        assert_eq!(v.move_item(id, t(500)), Some(t(1000)));
        assert_eq!(v.move_item(id, t(9000)), Some(t(9000)));
        let first = v[0].id;
        assert_eq!(v.move_item(first, t(-5)), Some(t(0)));
        assert_eq!(v.move_item(first, t(8500)), Some(t(8000))); // the next item starts at 9000
    }

    #[test]
    fn trim_head_shifts_word_origin_and_neighbors_win_at_the_tail() {
        let mut v = two();
        v[1].words = vec![word("second", 0, 400), word("one", 500, 900)];
        let id = v[1].id;
        assert_eq!(v.trim(id, ClipEdge::Head, t(2200), t(100)), Some(range(2200, 3000)));
        assert_eq!(v[1].words[0].range, range(-200, 200));
        let first = v[0].id;
        assert_eq!(v.trim(first, ClipEdge::Tail, t(5000), t(100)), Some(range(0, 2200)));
        assert_eq!(v.trim(first, ClipEdge::Tail, t(10), t(100)), Some(range(0, 100)));
        assert_eq!(v.trim(Id::from_u128(1), ClipEdge::Tail, t(0), t(1)), None);
    }

    #[test]
    fn split_shares_words_by_timing_and_by_proportion() {
        let mut v = vec![item(&["one two", "three four"], range(0, 4000))];
        v[0].words =
            vec![word("one", 0, 500), word("two", 500, 1000), word("three", 2500, 3000), word("four", 3000, 4000)];
        let id = v[0].id;
        let (l, r) = v.split_at(id, t(1500), &mut ids()).unwrap_or_else(|| panic!("split"));
        assert_eq!((texts(&v), v[0].id, v[1].id), (vec!["one two".to_string(), "three four".to_string()], l, r));
        assert_eq!((v[0].range, v[1].range), (range(0, 1500), range(1500, 4000)));
        assert_eq!(v[1].words[0].range, range(1000, 1500));
        // Untimed: the proportion of the cut decides.
        let mut u = vec![item(&["a b c d"], range(0, 4000))];
        let uid = u[0].id;
        assert!(u.split_at(uid, t(1000), &mut ids()).is_some());
        assert_eq!(texts(&u), vec!["a", "b c d"]);
        assert!(u.split_at(uid, t(0), &mut ids()).is_none()); // not strictly inside
    }

    #[test]
    fn merge_joins_text_range_and_words() {
        let mut v = two();
        v[0].words = vec![word("first", 0, 900)];
        let ids_set: BTreeSet<Id> = v.iter().map(|i| i.id).collect();
        let first_id = v[0].id;
        assert_eq!(v.merge(&ids_set), Some(first_id));
        assert_eq!(v.len(), 1);
        assert_eq!((v[0].text(), v[0].range), ("first second one".to_string(), range(0, 3000)));
        assert_eq!(v[0].words.len(), 3); // the untimed part contributes its spread words
        assert_eq!(v.merge(&BTreeSet::new()), None);
    }

    #[test]
    fn add_cuts_short_at_the_next_caption_and_follows_the_track_style() {
        let mut v = two();
        v[0].style_ref = "bold".to_string();
        let mut src_ids = ids();
        let id = v.add(t(1200), t(5000), ("", ""), ("d", "a"), &mut src_ids);
        let Ok(id) = id else { panic!("add failed") };
        let added = v.item(id).cloned();
        assert_eq!(
            added.as_ref().map(|i| (i.range, i.style_ref.as_str(), i.animation_ref.as_str())),
            Some((range(1200, 2000), "bold", ""))
        ); // the neighbor has no animation: its empty one is taken
        assert_eq!(v.add(t(500), t(100), ("", ""), ("", ""), &mut src_ids), Err(EditError::Collision));
        assert_eq!(v.add(t(-1), t(100), ("", ""), ("", ""), &mut src_ids), Err(EditError::EmptyClip));
        let other = v.add(t(9000), t(100), ("track", "anim"), ("", ""), &mut src_ids).unwrap_or(Id::NIL);
        assert_eq!(v.item(other).map(|i| (i.style_ref.as_str(), i.animation_ref.as_str())), Some(("track", "anim")));
    }

    #[test]
    fn style_overrides_and_hand_back() {
        let mut v = two();
        v.set_style("s", Some("a"));
        assert!(v.iter().all(|i| i.style_ref == "s" && i.animation_ref == "a"));
        let one: BTreeSet<Id> = [v[0].id].into();
        v.set_item_style(&one, Some("own"), "s", "a");
        assert_eq!((v[0].style_ref.as_str(), v[0].style_overridden), ("own", true));
        v.set_style("s2", None);
        assert_eq!((v[0].style_ref.as_str(), v[1].style_ref.as_str()), ("own", "s2"));
        assert_eq!(v.overridden_count(), 1);
        v.reset_items_to_track_look(&one, "s2", "a");
        assert_eq!((v[0].style_ref.as_str(), v[0].style_overridden, v.overridden_count()), ("s2", false, 0));
        v.set_item_animation(&one, Some("pop"), "s2", "a");
        assert_eq!((v[0].animation_ref.as_str(), v[0].style_overridden), ("pop", true));
    }

    #[test]
    fn replace_text_counts_matches_and_drops_emptied_captions() {
        let mut v = vec![item(&["um, hello um"], range(0, 1000)), item(&["um"], range(2000, 3000))];
        assert_eq!(v.replace_text("um", "", true), 3);
        assert_eq!(texts(&v), vec![", hello "]);
        assert_eq!(v.replace_text("", "x", true), 0);
    }

    #[test]
    fn close_span_and_open_gap_move_captions_and_their_words() {
        let mut v =
            vec![item(&["a"], range(0, 1000)), item(&["b c"], range(3000, 4000)), item(&["x"], range(1200, 1800))];
        v.sort_by_key(|i| i.range.start);
        v[2].words = vec![word("b", 0, 400), word("c", 400, 1000)];
        v.close_span(&range(1000, 3000));
        assert_eq!(v.iter().map(|i| i.range).collect::<Vec<_>>(), vec![range(0, 1000), range(1000, 2000)]); // the covered one vanished
        assert_eq!(v[1].words[1].range, range(400, 1000));
        v.open_gap(t(500), t(1000));
        assert_eq!(v.iter().map(|i| i.range).collect::<Vec<_>>(), vec![range(0, 1000), range(2000, 3000)]);
        v.open_gap(t(0), t(0));
        assert_eq!(v[1].range, range(2000, 3000));
    }

    #[test]
    fn word_verbs_set_insert_and_delete() {
        let mut v = vec![item(&["one two"], range(0, 2000))];
        let id = v[0].id;
        assert_eq!(v.set_word(id, 1, "deux trois"), Some(2));
        assert_eq!(v[0].text(), "one deux trois");
        assert_eq!(v.insert_word(id, 3, "four"), Some(1));
        assert_eq!(v[0].text(), "one deux trois four");
        assert_eq!(v.set_word(id, 9, "x"), None);
        assert_eq!(v.insert_word(id, 9, "x"), None);
        for _ in 0..4 {
            v.set_word(id, 0, "");
        }
        assert!(v.is_empty()); // the caption goes with its last word
    }

    #[test]
    fn split_before_word_cuts_in_the_pause_and_keeps_the_halves_touching() {
        let mut v = vec![item(&["one two"], range(0, 3000))];
        v[0].words = vec![word("one", 0, 1000), word("two", 2000, 3000)];
        let id = v[0].id;
        let snap = |x: Time| x.snapped(Time::new(1, 30));
        assert!(v.split_before_word(id, 1, &snap, &mut ids()).is_some());
        assert_eq!(v[0].range.end(), v[1].range.start);
        assert_eq!(texts(&v), vec!["one", "two"]);
        assert!(v.split_before_word(v[0].id, 0, &snap, &mut ids()).is_none());
    }

    #[test]
    fn neighbors_and_word_retiming() {
        let v = two();
        let (a, b) = (v[0].id, v[1].id);
        assert_eq!(v.neighbor_of(a, CaptionNeighbor::Next).map(|i| i.id), Some(b));
        assert_eq!(v.neighbor_of(a, CaptionNeighbor::Previous).map(|i| i.id), None);
        let mut c = vec![item(&["a b"], range(1000, 3000))];
        c[0].words = vec![word("a", 0, 900), word("b", 900, 2000)];
        let id = c[0].id;
        // Rolling: the boundary between the two words moves.
        assert_eq!(c.retime_word(id, 1, ClipEdge::Head, t(1500), t(100), true), Some(range(1500, 3000)));
        assert_eq!(c[0].words[0].range, range(0, 500));
        // Not rolling: the edge stops at the neighbor.
        let r = c.retime_word(id, 1, ClipEdge::Head, t(1100), t(100), false);
        assert_eq!(r, Some(range(1500, 3000)));
        assert_eq!(c.retime_word(id, 9, ClipEdge::Head, t(0), t(100), true), None);
    }
}
