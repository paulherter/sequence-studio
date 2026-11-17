// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+BatchRipple.swift (one-sweep batch ripple)
//
// "Remove Silences", filler words, accepted proposed cuts: many cuts closed in one pass. The result equals `extract` once
// per cut from the last to the first, at O(clips + cuts * log cuts) instead of one full copy and scan of every track per
// cut.

use sq_core_model::{Clip, EditError, Timeline, Track};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Sorted, disjoint, non-empty cuts in the coordinates before the edit and where each point lands once they are all
/// closed: a point inside a cut lands where that cut began, a point at or after a cut moves left by its length (the per-cut
/// rule of `shift_markers` and `CaptionTrack::close_span`, composed).
#[derive(Clone, Debug)]
pub struct RippleMap {
    /// The cuts, sorted and disjoint.
    pub cuts: Vec<TimeRange>,
    /// `removed[k]`: total length of `cuts[0..k]` (count + 1 entries).
    pub removed: Vec<Time>,
}

impl RippleMap {
    /// The map of `cuts` (sorted, disjoint).
    pub fn new(cuts: &[TimeRange]) -> RippleMap {
        let mut removed = vec![Time::ZERO];
        let mut sum = Time::ZERO;
        for c in cuts {
            sum += c.duration;
            removed.push(sum);
        }
        RippleMap { cuts: cuts.to_vec(), removed }
    }

    /// Total length of all cuts.
    pub fn total(&self) -> Time {
        self.removed.last().copied().unwrap_or(Time::ZERO)
    }

    /// How many cuts end at or before `t`.
    pub fn ended_by(&self, t: Time) -> usize {
        self.cuts.partition_point(|c| c.end() <= t)
    }

    /// Where the point `t` lands.
    pub fn map(&self, t: Time) -> Time {
        let k = self.ended_by(t);
        if let Some(c) = self.cuts.get(k)
            && c.start < t
        {
            return c.start - self.removed[k];
        }
        t - self.removed[k]
    }
}

/// Batch ripple.
pub trait TimelineBatchRippleExt {
    /// Extracts every cut from the tracks at `targets` in one sweep and closes the captions, markers and In/Out the way
    /// `extract` does. `cuts` must be sorted, disjoint and not touching, and no unlocked sync-locked track may be missing
    /// from `targets`: then everything that moves is also cut, nothing holds a cut open, and every cut closes completely.
    /// Returns the time removed. A result that no longer fits (times rounded off every frame grid) fails with `Collision`
    /// and changes nothing.
    #[doc(hidden)]
    fn extract_all(&mut self, cuts: &[TimeRange], targets: &[usize], ids: &mut dyn IdSource)
    -> Result<Time, EditError>;

    /// True when `extract_all` may stand in for one `extract` per cut on these targets: cuts sorted, non-empty, at or after
    /// 0, overlapping none (touching is fine: closing both equals closing their union), and every unlocked sync-locked
    /// track targeted.
    #[doc(hidden)]
    fn batch_ripple_applies(&self, sorted: &[TimeRange], targets: &[usize]) -> bool;

    /// `shift_markers` for many closed spans at once: `f` is their composed point map (`RippleMap::map`); a range marker
    /// maps both ends.
    #[doc(hidden)]
    fn shift_markers_through(&mut self, f: &dyn Fn(Time) -> Time);

    /// `shift_in_out` for many closed spans at once: `f` is their composed point map.
    #[doc(hidden)]
    fn shift_in_out_through(&mut self, f: &dyn Fn(Time) -> Time);
}

/// `clear` of every cut, then the shift that closes them, in one pass. Pieces are cut from each clip exactly as the
/// sequential path cuts them (last cut first, the left part keeps the id and link, a right part gets a new id and the link
/// of `relinks[cut]`, shared with the pieces other tracks cut there), so keys, speed and transitions come out the same.
/// Returns each surviving clip's start before the shift.
fn extract_all_on_track(
    track: &mut Track,
    map: &RippleMap,
    relinks: &mut [BTreeMap<Id, Id>],
    ids: &mut dyn IdSource,
) -> BTreeMap<Id, Time> {
    let mut origin: BTreeMap<Id, Time> = BTreeMap::new();
    let cuts = &map.cuts;
    let mut out: Vec<Clip> = Vec::with_capacity(track.clips().len());
    let mut retarget: BTreeMap<Id, Id> = BTreeMap::new();
    let mut lo = 0;
    let shifted = |c: Clip| {
        let mut c = c;
        c.start = c.start - map.removed[map.ended_by(c.start)];
        c
    };
    for c in track.clips().to_vec() {
        let end = c.timeline().end();
        while lo < cuts.len() && cuts[lo].end() <= c.start {
            lo += 1;
        }
        let mut hi = lo;
        while hi < cuts.len() && cuts[hi].start < end {
            hi += 1;
        }
        if hi == lo {
            origin.insert(c.id, c.start);
            out.push(shifted(c));
            continue;
        }
        let mut pieces: Vec<Clip> = Vec::new();
        let mut cur = Some(c);
        for j in (lo..hi).rev() {
            let Some(k) = cur.clone() else { break };
            let hole = cuts[j];
            if !k.timeline().overlaps(&hole) {
                continue;
            }
            let keeps_left = hole.start > k.start;
            let left = if keeps_left { k.cropped(TimeRange::from_end(k.start, hole.start)) } else { None };
            if hole.end() < k.timeline().end()
                && let Some(mut right) = k.cropped(TimeRange::from_end(hole.end(), k.timeline().end()))
            {
                if keeps_left {
                    let old = right.id;
                    right.id = ids.next_id();
                    right.relink(&mut relinks[j], ids);
                    // The first cut (from the end) moves the old tail's transitions; later ones find none left.
                    retarget.entry(old).or_insert(right.id);
                }
                pieces.push(right);
            }
            cur = left;
        }
        if let Some(k) = cur {
            pieces.push(k);
        }
        for p in pieces.into_iter().rev() {
            origin.insert(p.id, p.start);
            out.push(shifted(p));
        }
    }
    track.set_clips(out);
    if !retarget.is_empty() {
        for tr in &mut track.transitions {
            if let Some(n) = tr.outgoing.and_then(|o| retarget.get(&o)) {
                tr.outgoing = Some(*n);
            }
        }
    }
    origin
}

impl TimelineBatchRippleExt for Timeline {
    fn extract_all(
        &mut self,
        cuts: &[TimeRange],
        targets: &[usize],
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        if cuts.is_empty() {
            return Ok(Time::ZERO);
        }
        let map = RippleMap::new(cuts);
        let mut work = self.tracks.clone();
        let mut relinks: Vec<BTreeMap<Id, Id>> = vec![BTreeMap::new(); cuts.len()];
        let mut origin: Vec<BTreeMap<Id, Time>> = Vec::new();
        for &i in targets {
            origin.push(extract_all_on_track(&mut work[i], &map, &mut relinks, ids));
        }
        // As `extract` does per cut (last first): a clip that starts at or after a cut and still holds the old link of a
        // clip that cut split belongs to its right piece and takes that piece's new link.
        let mut by_link: BTreeMap<Id, Vec<(usize, Id)>> = BTreeMap::new();
        for j in (0..relinks.len()).rev() {
            for (l, nl) in &relinks[j] {
                by_link.entry(*l).or_default().push((j, *nl));
            }
        }
        if !by_link.is_empty() {
            for (n, &i) in targets.iter().enumerate() {
                let mut changed = false;
                let moved: Vec<Clip> = work[i]
                    .clips()
                    .iter()
                    .map(|c| {
                        let mut c = c.clone();
                        let hits = c.link.and_then(|l| by_link.get(&l));
                        if let (Some(hits), Some(o)) = (hits, origin[n].get(&c.id))
                            && let Some(h) = hits.iter().find(|h| *o >= map.cuts[h.0].end())
                        {
                            c.link = Some(h.1);
                            changed = true;
                        }
                        c
                    })
                    .collect();
                if changed {
                    work[i].set_clips(moved);
                }
            }
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        for cap in self.caption_tracks.iter_mut().filter(|c| c.follows_ripple()) {
            cap.close_spans(&|t| map.map(t));
        }
        self.shift_markers_through(&|t| map.map(t));
        self.shift_in_out_through(&|t| map.map(t));
        Ok(map.total())
    }

    fn batch_ripple_applies(&self, sorted: &[TimeRange], targets: &[usize]) -> bool {
        if !sorted.iter().all(|c| !c.is_empty() && c.start >= Time::ZERO)
            || !sorted.windows(2).all(|w| w[0].end() <= w[1].start)
        {
            return false;
        }
        let t: BTreeSet<usize> = targets.iter().copied().collect();
        if !(0..self.tracks.len()).all(|i| !self.tracks[i].follows_ripple() || t.contains(&i)) {
            return false;
        }
        // `extract` also cuts and relinks untargeted partners of a cut clip; the batch sweep does not, so those go the long way.
        let links: BTreeSet<Id> =
            targets.iter().flat_map(|i| self.tracks[*i].clips().iter().filter_map(|c| c.link)).collect();
        (0..self.tracks.len()).all(|i| {
            t.contains(&i)
                || self.tracks[i].is_locked
                || !self.tracks[i].clips().iter().any(|c| c.link.is_some_and(|l| links.contains(&l)))
        })
    }

    fn shift_markers_through(&mut self, f: &dyn Fn(Time) -> Time) {
        for m in &mut self.markers {
            if m.duration > Time::ZERO {
                let (s, e) = (f(m.time), f(m.time + m.duration));
                m.time = s;
                m.duration = (e - s).max(Time::ZERO);
            } else {
                m.time = f(m.time);
            }
        }
        self.markers.sort_by(|a, b| a.time.cmp(&b.time).then(a.id.cmp(&b.id)));
    }

    fn shift_in_out_through(&mut self, f: &dyn Fn(Time) -> Time) {
        let Some(r) = self.in_out else { return };
        let out_only = self.explicit_marks().0.is_none();
        let start = if out_only { r.start } else { f(r.start) };
        let end = f(r.end());
        self.in_out = (end > start).then(|| TimeRange::from_end(start, end));
        if self.in_out.is_none() {
            self.in_out_kind = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use crate::timeline_range_edits::TimelineRangeEditsExt as _;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    fn r(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(s(a), s(b))
    }

    /// A linked V/A pair across 0...20 plus a second video track.
    fn sample() -> Timeline {
        let l = link();
        let mut tl = timeline(vec![
            track(Video, vec![clip(0, 20, 0, Video, Some(l), Some(40))]),
            track(Audio, vec![clip(0, 20, 0, Audio, Some(l), Some(40))]),
            track(Video, vec![v(1, 3), v(12, 6)]),
        ]);
        tl.markers = vec![];
        tl
    }

    #[test]
    fn ripple_map_moves_points_like_per_cut_closing() {
        let m = RippleMap::new(&[r(2, 4), r(6, 7)]);
        assert_eq!(m.total(), s(3));
        assert_eq!(m.map(s(1)), s(1));
        assert_eq!(m.map(s(3)), s(2)); // inside a cut: where it began
        assert_eq!(m.map(s(5)), s(3));
        assert_eq!(m.map(s(7)), s(4));
        assert_eq!(m.map(s(10)), s(7));
    }

    #[test]
    fn the_sweep_equals_one_extract_per_cut_from_the_last() {
        let cuts = [r(2, 4), r(6, 7), r(15, 17)];
        let mut swept = sample();
        let all: Vec<usize> = (0..swept.tracks.len()).collect();
        assert!(swept.batch_ripple_applies(&cuts, &all));
        let mut ids = SequentialIds::default();
        assert_eq!(swept.extract_all(&cuts, &all, &mut ids), Ok(s(5)));
        let mut seq = sample();
        let track_ids: Vec<Id> = seq.tracks.iter().map(|t| t.id).collect();
        for c in cuts.iter().rev() {
            assert!(seq.extract(*c, &track_ids, &mut SequentialIds::default()).is_ok());
        }
        for (a, b) in swept.tracks.iter().zip(&seq.tracks) {
            assert_eq!(spans(a), spans(b));
        }
        assert_eq!(spans(&swept.tracks[0]), [[0, 2], [2, 4], [4, 12], [12, 15]]);
    }

    #[test]
    fn markers_and_in_out_follow_the_composed_map() {
        let mut tl = sample();
        let mut m = |t: i64, n: u128| {
            tl.markers.push(sq_core_model::Marker {
                id: Id::from_u128(n),
                time: s(t),
                name: String::new(),
                color: Default::default(),
                comment: String::new(),
                duration: Time::ZERO,
            })
        };
        m(3, 1);
        m(10, 2);
        let all: Vec<usize> = (0..tl.tracks.len()).collect();
        assert!(tl.extract_all(&[r(2, 4), r(6, 7)], &all, &mut SequentialIds::default()).is_ok());
        assert_eq!(tl.markers.iter().map(|m| m.time).collect::<Vec<_>>(), [s(2), s(7)]);
    }

    #[test]
    fn the_sweep_needs_sorted_disjoint_cuts_and_every_ripple_track_targeted() {
        let tl = sample();
        let all = [0, 1, 2];
        assert!(!tl.batch_ripple_applies(&[r(4, 6), r(2, 3)], &all));
        assert!(!tl.batch_ripple_applies(&[r(2, 5), r(4, 6)], &all));
        assert!(!tl.batch_ripple_applies(&[r(2, 2)], &all));
        assert!(!tl.batch_ripple_applies(&[r(2, 4)], &[0, 1])); // the second video track would be missing
        assert!(tl.batch_ripple_applies(&[r(2, 4), r(4, 6)], &all)); // touching is fine
    }
}
