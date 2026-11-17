// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline.swift (ripple delete, ripple trim, insert), Captions.swift (ripple support), Timeline+Markers.swift
// (shiftMarkers), SourceEditPlacement.swift (explicitMarks)
//
// Ripple edits work timeline-wide like Premiere: every track with sync lock on shifts together, locked tracks never shift,
// and an edit that touches a locked track is refused.

use crate::clip_attachment::clear_main_track_attachments;
use crate::{Clip, ClipEdge, EditError, InOutKind, Member, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Clamp report of a ripple: the limiting track (index) and how much less the edit did.
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RippleClamp {
    /// Index of the track that kept the most gap open.
    pub track: usize,
    /// How much less the edit did.
    pub shortfall: Time,
}

/// `t` rounded down to a whole number of frames; `t` itself for a frame duration that is not positive.
pub fn floored_to_frame(t: Time, frame_duration: Time) -> Time {
    if frame_duration <= Time::ZERO {
        return t;
    }
    frame_duration * t.frame_index(frame_duration)
}

impl Timeline {
    // MARK: Ripple support (used by the timeline-wide edits; only unlocked, sync-locked tracks follow)

    /// Captions, sequence markers and the In/Out range follow a ripple that closes `span`; captions inside it are cut out
    /// (a deliberate delete of the span).
    #[doc(hidden)]
    pub fn close_caption_span(&mut self, span: TimeRange) {
        for t in self.caption_tracks.iter_mut().filter(|t| t.follows_ripple()) {
            t.close_span(span);
        }
        self.shift_markers(span.end(), -span.duration);
        self.shift_in_out(span.end(), -span.duration);
    }

    /// `close_caption_span` for a ripple that has to close its span as a side effect (Fast Cut keeps V1 gapless): a
    /// caption inside the span is pulled in to its start instead of dropped (`CaptionTrack::close_span_keeping`).
    #[doc(hidden)]
    pub fn close_caption_span_keeping(&mut self, span: TimeRange) {
        for t in self.caption_tracks.iter_mut().filter(|t| t.follows_ripple()) {
            t.close_span_keeping(span);
        }
        self.shift_markers(span.end(), -span.duration);
        self.shift_in_out(span.end(), -span.duration);
    }

    /// How far a ripple that closes a span ending at `pivot` can go before it would drop or shorten a ripple-following
    /// caption: the time from the latest end of a caption that starts before `pivot` up to `pivot` (a caption reaching
    /// past `pivot` leaves no room). `None` = no caption before `pivot`, no limit. A ripple that closes its span as a side
    /// effect (speed change, trim, gap close) stays inside this room, like it stays inside a clip's room on another track;
    /// only a deliberate delete of the span (`close_caption_span` after a range or clip delete) may remove captions.
    #[doc(hidden)]
    pub fn caption_room_before(&self, pivot: Time) -> Option<Time> {
        self.caption_tracks
            .iter()
            .filter(|t| t.follows_ripple())
            .flat_map(|t| t.items().iter())
            .filter(|i| i.range.start < pivot)
            .map(|i| i.range.end())
            .max()
            .map(|end| (pivot - end).max(Time::ZERO))
    }

    /// Mirror of `caption_room_before` for a span that starts at `start` (a head trim): how far it can reach to the right
    /// before it would take in a caption. `None` = no caption after `start`.
    #[doc(hidden)]
    pub fn caption_room_after(&self, start: Time) -> Option<Time> {
        self.caption_tracks
            .iter()
            .filter(|t| t.follows_ripple())
            .flat_map(|t| t.items().iter())
            .filter(|i| i.range.end() > start)
            .map(|i| (i.range.start - start).max(Time::ZERO))
            .min()
    }

    /// `d` (a ripple shift, negative = close) limited so the span `[pivot + d, pivot)` that closes holds no caption, and
    /// floored to whole frames. `d` unchanged when it opens a gap or no caption is in the way.
    #[doc(hidden)]
    pub fn limit_close_by_captions(&self, pivot: Time, d: Time) -> Time {
        if d >= Time::ZERO {
            return d;
        }
        match self.caption_room_before(pivot) {
            Some(room) => d.max(Time::ZERO - floored_to_frame(room, self.frame_duration())),
            None => d,
        }
    }

    /// Captions, sequence markers and the In/Out range follow a ripple that opens a gap of `length` at `pivot`.
    #[doc(hidden)]
    pub fn open_caption_gap(&mut self, pivot: Time, length: Time) {
        for t in self.caption_tracks.iter_mut().filter(|t| t.follows_ripple()) {
            t.open_gap(pivot, length);
        }
        self.shift_markers(pivot, length);
        self.shift_in_out(pivot, length);
    }

    /// Ripple helper. Insert: `delta > 0`, markers at or after `edit_point` move later. Delete of [a, b): `edit_point = b`,
    /// `delta = a - b`; markers inside the removed span collapse to `a`, later ones move earlier; a marker with a duration
    /// keeps its end through the same rule.
    pub fn shift_markers(&mut self, edit_point: Time, delta: Time) {
        let floor = edit_point + delta.min(Time::ZERO);
        let moved = |t: Time| {
            if t >= edit_point {
                t + delta
            } else if t >= floor {
                floor
            } else {
                t
            }
        };
        for m in &mut self.markers {
            if delta < Time::ZERO && m.duration > Time::ZERO {
                let (s, e) = (moved(m.time), moved(m.time + m.duration));
                m.time = s;
                m.duration = (e - s).max(Time::ZERO);
            } else if m.time >= floor {
                m.time = moved(m.time);
            }
        }
        self.markers.sort_by(|a, b| a.time.cmp(&b.time).then(a.id.cmp(&b.id)));
    }

    /// The explicit sequence marks (stored Out = one frame past the Out frame).
    pub fn explicit_marks(&self) -> (Option<Time>, Option<Time>) {
        let Some(io) = self.in_out else { return (None, None) };
        match self.in_out_kind {
            Some(InOutKind::InOnly) => (Some(io.start), None),
            Some(InOutKind::OutOnly) => (None, Some(io.end())),
            Some(InOutKind::Both) => (Some(io.start), Some(io.end())),
            None if io.end() >= self.duration() => (Some(io.start), None),
            None => (Some(io.start), Some(io.end())),
        }
    }

    /// Same point rule as `shift_markers`: points at or after `edit_point` move by `delta`; points inside a removed span
    /// collapse to its start. A range that collapses to nothing is cleared.
    #[doc(hidden)]
    pub fn shift_in_out(&mut self, edit_point: Time, delta: Time) {
        let Some(r) = self.in_out else { return };
        let floor = edit_point + delta.min(Time::ZERO);
        let shifted = |p: Time| {
            if p >= edit_point {
                p + delta
            } else if p >= floor {
                floor
            } else {
                p
            }
        };
        let out_only = self.explicit_marks().0.is_none();
        let start = if out_only { r.start } else { shifted(r.start) };
        let end = shifted(r.end());
        self.in_out = (end > start).then(|| TimeRange::from_end(start, end));
        if self.in_out.is_none() {
            self.in_out_kind = None;
        }
    }

    // MARK: Ripple delete

    /// Deletes clips (and their linked partners) and closes the gap on all tracks that follow ripple. Other tracks can
    /// block the gap: it closes only as far as nothing collides. Returns the total time closed, summed over the deleted
    /// clips.
    pub fn ripple_delete(&mut self, ids: &[Id]) -> Result<Time, EditError> {
        Ok(self.ripple_delete_detailed(ids)?.0)
    }

    /// `ripple_delete`, also naming the clamp: the track (index) that kept the most gap open and the total shortfall.
    #[doc(hidden)]
    pub fn ripple_delete_detailed(&mut self, ids: &[Id]) -> Result<(Time, Option<RippleClamp>), EditError> {
        let mut work = self.clone();
        let mut primaries = Vec::new();
        for id in ids {
            primaries.push(work.find(*id).ok_or(EditError::ClipNotFound)?.clip);
        }
        primaries.sort_by_key(|c| std::cmp::Reverse(c.start)); // right to left: earlier pivots stay valid
        let mut closed = Time::ZERO;
        let mut clamp: Option<RippleClamp> = None;
        for p in primaries {
            if work.find(p.id).is_none() {
                continue; // already gone with a linked partner
            }
            let (c, one) = work.ripple_delete_one(p.id)?;
            closed += c;
            if let Some(c) = one {
                clamp = Some(RippleClamp {
                    track: clamp.map_or(c.track, |k| k.track),
                    shortfall: clamp.map_or(Time::ZERO, |k| k.shortfall) + c.shortfall,
                });
            }
        }
        *self = work;
        Ok((closed, clamp))
    }

    /// Removes the group and closes the gap by ONE amount on every involved track, so later material stays in sync
    /// (Premiere): the span of the group's union. Each track closes from its own member's end (tracks without a member from
    /// the group's latest end). If any track lacks room, all close less. `clamp`: the track with the least room and how much
    /// less than the span was closed.
    #[doc(hidden)]
    pub fn ripple_delete_one(&mut self, id: Id) -> Result<(Time, Option<RippleClamp>), EditError> {
        let group = self.linked_group(id)?;
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let involved = self.involved_tracks(&group)?;
        let min_start = group.iter().map(|m| m.clip.start).min().unwrap_or(Time::ZERO);
        let max_end = group.iter().map(|m| m.clip.timeline().end()).max().unwrap_or(Time::ZERO);
        let span = max_end - min_start;
        let mut pivot: BTreeMap<usize, Time> = involved.iter().map(|i| (*i, max_end)).collect();
        // A track with several members shifts from the latest member's end, whichever member was clicked.
        let mut own: BTreeMap<usize, Time> = BTreeMap::new();
        for m in &group {
            let end = m.clip.timeline().end();
            let e = own.entry(m.track).or_insert(end);
            *e = (*e).max(end);
        }
        pivot.extend(own);
        let pivot = Timeline::following_straddlers(&self.tracks, &pivot, &ids);
        let mut shortfall = Time::ZERO;
        let mut limiting = None;
        for i in &involved {
            if let Some(room) = self.tracks[*i].left_room(pivot[i], &ids)
                && span - room > shortfall
            {
                shortfall = span - room;
                limiting = Some(*i);
            }
        }
        for m in &group {
            self.tracks[m.track].remove(m.clip.id);
        }
        let d = (span - shortfall).max(Time::ZERO);
        let none = BTreeSet::new();
        for i in &involved {
            self.tracks[*i].shift(pivot[i], -d, &none);
        }
        // Times off every frame grid can need more than Int64 and round: a shift that no longer lands exactly is refused.
        if !self.tracks.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        // Deliberate delete: every clip track is empty in the closed span (`left_room`), so only the deleted clips lived
        // there and the captions inside it go with them.
        self.close_caption_span(TimeRange::new(max_end - d, d));
        Ok((d, limiting.map(|track| RippleClamp { track, shortfall: span - d })))
    }

    // MARK: Ripple trim

    /// Moves `edge` of a clip by `delta` (timeline direction: tail + = longer, head + = shorter) and ripples the rest of
    /// the sequence. Linked partners follow. The clip's start stays put, like Premiere. Clamped by the media, by collisions
    /// on other tracks when shortening, and refuses to empty a clip. Returns how far the edge actually moved.
    pub fn ripple_trim(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError> {
        Ok(self.ripple_trim_many(&[(id, delta)], edge)?.0)
    }

    /// Ripple-trims several clips (each with its linked partners) as ONE edit with ONE amount `G`, so every track, the
    /// captions, markers and In/Out shift by the same amount and nothing desyncs.
    ///
    /// Picks with a zero amount are dropped (their clips just ride the ripple). The primary is the pick with the smallest
    /// amount, i.e. the edit nearest the playhead for Q/W; ties break by edge time, so the result does not depend on track
    /// order. Only picks whose edge sits at the primary's edge with the same amount are trimmed; the others straddle the
    /// removed span and behave like any other clip there (they stay put and limit the trim through the room check). `G` is
    /// clamped by every member's media and by the room on every affected track; a smaller head trim moves the pivot left,
    /// so the room check repeats until stable. Pivots: member tracks shift what follows their member's original end; every
    /// other ripple track shifts from the edit point (tail: the primary's end; head: its start plus the removed span).
    ///
    /// Returns `(moved, limited_by, shortfall)`. `limited_by`: the track whose clips shortened the trim (not the media).
    /// `shortfall`: how much less the edge moved because of that track (zero when not limited by a clip).
    #[doc(hidden)]
    pub fn ripple_trim_many(
        &mut self,
        picks: &[(Id, Time)],
        edge: ClipEdge,
    ) -> Result<(Time, Option<usize>, Time), EditError> {
        let amount = |delta: Time| if edge == ClipEdge::Tail { delta } else { -delta }; // change of duration
        let edge_time = |c: &Clip| if edge == ClipEdge::Head { c.start } else { c.timeline().end() };
        let mut cands: Vec<(Clip, Time)> = Vec::new();
        for (id, delta) in picks {
            let m = self.find(*id).ok_or(EditError::ClipNotFound)?;
            let g = amount(*delta);
            if g != Time::ZERO || picks.len() == 1 {
                cands.push((m.clip, g));
            }
        }
        let abs = |g: Time| if g < Time::ZERO { -g } else { g };
        let mut primary: Option<&(Clip, Time)> = None;
        for c in &cands {
            let less = |a: &(Clip, Time), b: &(Clip, Time)| {
                let (x, y) = (abs(a.1), abs(b.1));
                if x != y { x < y } else { edge_time(&a.0) < edge_time(&b.0) }
            };
            if primary.is_none_or(|p| less(c, p)) {
                primary = Some(c);
            }
        }
        let Some(primary) = primary else { return Ok((Time::ZERO, None, Time::ZERO)) };
        let (primary_clip, mut g) = (primary.0.clone(), primary.1);
        let mut kept: Vec<&(Clip, Time)> =
            cands.iter().filter(|c| c.1 == g && edge_time(&c.0) == edge_time(&primary_clip)).collect();
        kept.sort_by(|a, b| a.0.start.cmp(&b.0.start).then(a.0.id.cmp(&b.0.id)));

        let frame = self.frame_duration();
        let mut members: Vec<Member> = Vec::new();
        let mut owned = BTreeSet::new();
        for k in kept {
            let group = self.linked_group(k.0.id)?;
            if group.iter().any(|m| owned.contains(&m.track)) {
                continue; // same group or a clashing one
            }
            if group.iter().any(|m| self.tracks[m.track].is_locked) {
                return Err(EditError::TrackLocked);
            }
            owned.extend(group.iter().map(|m| m.track));
            members.extend(group);
        }
        for m in &members {
            let c = &m.clip;
            g = c.clamping_shortening(g, frame);
            if g <= -c.duration() {
                return Err(EditError::EmptyClip);
            }
            let room = if edge == ClipEdge::Tail { c.tail_room() } else { c.head_handle() }
                .map(|r| floored_to_frame(r, frame));
            if let Some(room) = room
                && g > room
            {
                g = room;
            }
        }
        let ids: BTreeSet<Id> = members.iter().map(|m| m.clip.id).collect();
        let others: Vec<usize> =
            (0..self.tracks.len()).filter(|i| self.tracks[*i].follows_ripple() && !owned.contains(i)).collect();
        // Other tracks shift from the edit point; for a head trim that depends on how much is removed.
        let cut = |g: Time| {
            if edge == ClipEdge::Head {
                primary_clip.start + (-g).max(Time::ZERO)
            } else {
                primary_clip.timeline().end()
            }
        };
        // Pivot per shifting track: a member's track from its member's end, the others from the edit point, each moved
        // left to a straddling split-edit partner (`following_straddlers`).
        let pivots = |tracks: &[crate::Track], g: Time| {
            let mut p: BTreeMap<usize, Time> = members.iter().map(|m| (m.track, m.clip.timeline().end())).collect();
            for i in &others {
                p.insert(*i, cut(g));
            }
            Timeline::following_straddlers(tracks, &p, &ids)
        };
        // The span a trim closes is not a delete: a caption inside it stays and stops the trim there, like a clip on another
        // track does (the head trim's span starts at the clip start, the tail trim's ends at the clip end).
        if g < Time::ZERO {
            g = if edge == ClipEdge::Head {
                match self.caption_room_after(primary_clip.start) {
                    Some(room) => g.max(Time::ZERO - floored_to_frame(room, frame)),
                    None => g,
                }
            } else {
                self.limit_close_by_captions(primary_clip.timeline().end(), g)
            };
        }
        let mut limited_by = None;
        let before_room = g;
        let mut stable = false;
        while !stable && g < Time::ZERO {
            stable = true;
            let p = pivots(&self.tracks, g);
            let mut checks: Vec<(usize, Time)> = members.iter().map(|m| (m.track, m.clip.timeline().end())).collect();
            checks.extend(others.iter().map(|i| (*i, p[i])));
            for (i, pivot) in checks {
                if let Some(room) = self.tracks[i].left_room(pivot, &ids)
                    && g < -room
                {
                    g = -room;
                    limited_by = Some(i);
                    stable = false;
                }
            }
        }
        let shortfall = if limited_by.is_none() { Time::ZERO } else { g - before_room };
        if g == Time::ZERO {
            return Ok((Time::ZERO, limited_by, shortfall));
        }

        let mut work = self.tracks.clone();
        let mut own_pivot: BTreeMap<usize, Time> = BTreeMap::new(); // one shift per track, from its member's end
        for m in &members {
            let mut c = m.clip.clone();
            if edge == ClipEdge::Head {
                c.extend_head(g);
            } else {
                c.extend_tail(g);
            }
            work[m.track].replace(c);
            own_pivot.insert(m.track, m.clip.timeline().end());
        }
        for (i, p) in &own_pivot {
            work[*i].shift(*p, g, &ids);
        }
        let p = pivots(&self.tracks, g);
        for i in &others {
            work[*i].shift(p[i], g, &ids);
        }
        if !work.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        let at = edge_time(&primary_clip);
        if g < Time::ZERO {
            let start = if edge == ClipEdge::Head { at } else { at + g };
            self.close_caption_span(TimeRange::new(start, -g));
        } else {
            self.open_caption_gap(at, g);
        }
        Ok((if edge == ClipEdge::Tail { g } else { -g }, limited_by, shortfall))
    }

    // MARK: Insert

    /// Insert edit: places clips (each on its target track), splits and pushes everything at or after `t` later by the span
    /// of the placements on all ripple tracks. Other tracks get a gap. Placements keep their start offsets relative to the
    /// earliest placement start (J/L cuts): the earliest lands at `t`, the others at `t` plus their offset. Span = earliest
    /// start to latest end. A time before 0 returns `Collision`; nothing changes then.
    pub fn insert(&mut self, placements: &[(Clip, Id)], t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let first = placements.iter().map(|p| p.0.start).min().ok_or(EditError::EmptyClip)?;
        if t < Time::ZERO {
            return Err(EditError::Collision);
        }
        let d =
            placements.iter().map(|p| (p.0.start - first) + p.0.timeline().duration).max().filter(|d| *d > Time::ZERO);
        let d = d.ok_or(EditError::EmptyClip)?;
        let mut work = self.tracks.clone();
        let mut targets = BTreeSet::new();
        for (clip, track) in placements {
            let i = work.iter().position(|x| x.id == *track).ok_or(EditError::ClipNotFound)?;
            if work[i].is_locked {
                return Err(EditError::TrackLocked);
            }
            if clip.kind != work[i].kind {
                return Err(EditError::WrongTrackKind);
            }
            targets.insert(i);
        }
        let mut relinks = BTreeMap::new();
        let none = BTreeSet::new();
        for (i, track) in work.iter_mut().enumerate() {
            if targets.contains(&i) || track.follows_ripple() {
                track.split_relinking(t, &mut relinks, ids)?;
                track.shift(t, d, &none);
            }
        }
        for (clip, track) in placements {
            let mut c = clip.clone();
            c.start = t + (clip.start - first);
            let i = work.iter().position(|x| x.id == *track).ok_or(EditError::ClipNotFound)?;
            work[i].overwrite_relinking(c, &mut relinks, ids)?;
        }
        if !work.iter().all(|x| x.is_consistent()) {
            return Err(EditError::Collision);
        }
        clear_main_track_attachments(&mut work);
        self.tracks = work;
        self.open_caption_gap(t, d);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::TestIds;
    use crate::{SequenceFormat, Track, TrackKind};
    use serde_json::json;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn range(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(s(a), s(b))
    }

    /// A clip with a fresh id from a counter; `media` is the media length in seconds when limited.
    fn clip(start: i64, dur: i64, src: i64, kind: TrackKind, link: Option<u128>, media: Option<i64>) -> Clip {
        thread_local!(static NEXT: std::cell::Cell<u128> = const { std::cell::Cell::new(1000) });
        let n = NEXT.with(|c| {
            c.set(c.get() + 1);
            c.get()
        });
        let mut c =
            Clip::new(Id::from_u128(n), "c", Id::from_u128(n + 5000), kind, TimeRange::new(s(src), s(dur)), s(start));
        c.link = link.map(Id::from_u128);
        c.media_duration = media.map(s);
        c
    }

    fn v(start: i64, dur: i64) -> Clip {
        clip(start, dur, 0, TrackKind::Video, None, None)
    }

    fn a(start: i64, dur: i64) -> Clip {
        clip(start, dur, 0, TrackKind::Audio, None, None)
    }

    fn track(kind: TrackKind, clips: Vec<Clip>) -> Track {
        thread_local!(static NEXT: std::cell::Cell<u128> = const { std::cell::Cell::new(9000) });
        let n = NEXT.with(|c| {
            c.set(c.get() + 1);
            c.get()
        });
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }

    fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn starts(t: &Track) -> Vec<Time> {
        t.clips().iter().map(|c| c.start).collect()
    }

    fn ranges(t: &Track) -> Vec<TimeRange> {
        t.clips().iter().map(|c| c.timeline()).collect()
    }

    fn consistent(t: &Timeline) -> bool {
        t.tracks.iter().all(Track::is_consistent)
    }

    // MARK: Ripple delete

    #[test]
    fn delete_shifts_all_sync_locked_tracks() {
        let x = v(2, 3);
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v(0, 2), x.clone(), v(5, 2)]),
            track(TrackKind::Video, vec![v(6, 2)]),
            track(TrackKind::Audio, vec![a(8, 1)]),
        ]);
        assert_eq!(tl.ripple_delete(&[x.id]), Ok(s(3)));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(2)]);
        assert_eq!(starts(&tl.tracks[1]), [s(3)]);
        assert_eq!(starts(&tl.tracks[2]), [s(5)]);
    }

    #[test]
    fn delete_leaves_locked_and_unsynced_tracks() {
        let x = v(0, 2);
        let mut locked = track(TrackKind::Video, vec![v(4, 1)]);
        locked.is_locked = true;
        let mut unsynced = track(TrackKind::Video, vec![v(5, 1)]);
        unsynced.sync_lock = false;
        let mut tl = timeline(vec![track(TrackKind::Video, vec![x.clone(), v(2, 2)]), locked, unsynced]);
        assert!(tl.ripple_delete(&[x.id]).is_ok());
        assert_eq!(starts(&tl.tracks[0]), [s(0)]);
        assert_eq!(starts(&tl.tracks[1]), [s(4)]);
        assert_eq!(starts(&tl.tracks[2]), [s(5)]);
    }

    #[test]
    fn delete_blocked_by_a_clip_on_another_track_closes_partially() {
        let x = v(2, 4);
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v(0, 2), x.clone(), v(6, 2)]),
            track(TrackKind::Video, vec![v(1, 4), v(6, 1)]), // straddles into the deleted range, ends at 5
        ]);
        assert_eq!(tl.ripple_delete(&[x.id]), Ok(s(1))); // v2 gap between 5 and 6 is 1
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(5)]);
        assert_eq!(starts(&tl.tracks[1]), [s(1), s(5)]);
        assert!(consistent(&tl));
    }

    #[test]
    fn delete_takes_the_linked_partner_along() {
        let (vc, ac) =
            (clip(1, 2, 0, TrackKind::Video, Some(77), None), clip(1, 2, 0, TrackKind::Audio, Some(77), None));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v(0, 1), vc.clone(), v(3, 1)]),
            track(TrackKind::Audio, vec![ac, a(3, 1)]),
        ]);
        assert!(tl.ripple_delete(&[vc.id]).is_ok());
        assert_eq!((tl.tracks[0].clips().len(), tl.tracks[1].clips().len()), (2, 1));
        assert_eq!(starts(&tl.tracks[1]), [s(1)]);
    }

    #[test]
    fn delete_on_a_locked_own_track_is_refused_and_changes_nothing() {
        let x = v(0, 2);
        let mut locked = track(TrackKind::Video, vec![x.clone(), v(2, 1)]);
        locked.is_locked = true;
        let mut tl = timeline(vec![locked, track(TrackKind::Video, vec![v(3, 1)])]);
        let before = tl.clone();
        assert_eq!(tl.ripple_delete(&[x.id]), Err(EditError::TrackLocked));
        assert_eq!(tl, before);
    }

    #[test]
    fn delete_of_several_clips_works_right_to_left() {
        let (x, y) = (v(0, 1), v(2, 1));
        let mut tl = timeline(vec![track(TrackKind::Video, vec![x.clone(), v(1, 1), y.clone(), v(3, 1)])]);
        assert!(tl.ripple_delete(&[x.id, y.id]).is_ok());
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(1)]);
    }

    #[test]
    fn delete_closes_one_amount_by_the_group_span() {
        let (v1, a1) =
            (clip(10, 10, 0, TrackKind::Video, Some(1), None), clip(8, 12, 0, TrackKind::Audio, Some(1), None));
        let (v2, a2) =
            (clip(20, 10, 0, TrackKind::Video, Some(2), None), clip(20, 10, 0, TrackKind::Audio, Some(2), None));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v1.clone(), v2.clone()]),
            track(TrackKind::Audio, vec![a1, a2.clone()]),
        ]);
        assert_eq!(tl.ripple_delete(&[v1.id]), Ok(s(12)));
        assert_eq!(tl.find(v2.id).map(|m| m.clip.start), Some(s(8)));
        assert_eq!(tl.find(a2.id).map(|m| m.clip.start), Some(s(8)));
    }

    #[test]
    fn delete_shrinks_the_common_amount_on_a_collision() {
        let (v1, a1) =
            (clip(10, 10, 0, TrackKind::Video, Some(1), None), clip(8, 12, 0, TrackKind::Audio, Some(1), None));
        let (v2, a2) = (v(20, 10), a(20, 10));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v1.clone(), v2.clone()]),
            track(TrackKind::Audio, vec![a1, a2.clone()]),
            track(TrackKind::Video, vec![v(5, 10), v(25, 5)]), // ends at 15, sync-locked
        ]);
        assert_eq!(tl.ripple_delete(&[v1.id]), Ok(s(10))); // third track: 25 - 15 = 10 room
        assert_eq!(tl.find(v2.id).map(|m| m.clip.start), Some(s(10)));
        assert_eq!(tl.find(a2.id).map(|m| m.clip.start), Some(s(10)));
    }

    #[test]
    fn delete_also_closes_captions_markers_and_the_in_out_range() {
        let x = v(2, 2);
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 2), x.clone(), v(4, 4)])]);
        tl.caption_tracks = vec![
            serde_json::from_value(json!({"id": Id::from_u128(1), "items": [
                {"id": Id::from_u128(2), "lines": ["a one two"], "range": {"start": {"value": 5, "timescale": 1}, "duration": {"value": 1, "timescale": 1}}},
                {"id": Id::from_u128(3), "lines": ["inside"], "range": {"start": {"value": 2, "timescale": 1}, "duration": {"value": 1, "timescale": 1}}}]}))
            .unwrap_or_else(|e| panic!("{e}")),
        ];
        tl.markers = serde_json::from_value(json!([
            {"id": Id::from_u128(7), "time": {"value": 3, "timescale": 1}, "name": "m"},
            {"id": Id::from_u128(8), "time": {"value": 6, "timescale": 1}, "name": "n"}]))
        .unwrap_or_default();
        tl.in_out = Some(range(3, 7));
        assert_eq!(tl.ripple_delete(&[x.id]), Ok(s(2)));
        let items = tl.caption_tracks[0].items();
        assert_eq!(items.len(), 1, "the caption inside the removed span is dropped");
        assert_eq!(items[0].range, range(3, 4));
        assert_eq!(tl.markers.iter().map(|m| m.time).collect::<Vec<_>>(), [s(2), s(4)]);
        assert_eq!(tl.in_out, Some(range(2, 5)));
    }

    fn captions(items: &[(i64, i64)]) -> crate::CaptionTrack {
        let list: Vec<_> = items
            .iter()
            .enumerate()
            .map(|(n, (a, b))| json!({"id": Id::from_u128(100 + n as u128), "lines": ["c"], "range": {"start": {"value": a, "timescale": 1}, "duration": {"value": b - a, "timescale": 1}}}))
            .collect();
        serde_json::from_value(json!({"id": Id::from_u128(1), "items": list})).unwrap_or_else(|e| panic!("{e}"))
    }

    fn caption_ranges(tl: &Timeline) -> Vec<TimeRange> {
        tl.caption_tracks[0].items().iter().map(|i| i.range).collect()
    }

    #[test]
    fn caption_room_is_measured_from_the_latest_caption_end_before_the_pivot() {
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 2)])]);
        assert_eq!(tl.caption_room_before(s(10)), None);
        tl.caption_tracks = vec![captions(&[(1, 3), (4, 6), (12, 14)])];
        assert_eq!(tl.caption_room_before(s(10)), Some(s(4)));
        assert_eq!(tl.caption_room_before(s(5)), Some(Time::ZERO), "a caption reaching past the pivot leaves no room");
        assert_eq!(tl.caption_room_before(s(1)), None);
        assert_eq!(tl.caption_room_after(s(6)), Some(s(6)));
        assert_eq!(tl.caption_room_after(s(5)), Some(Time::ZERO));
        assert_eq!(tl.caption_room_after(s(14)), None);
        tl.caption_tracks[0].sync_lock = false;
        assert_eq!(tl.caption_room_before(s(10)), None, "a caption track that does not ripple never limits");
    }

    #[test]
    fn a_tail_trim_stops_at_a_caption_and_never_drops_it_and_undo_restores_everything() {
        let x = clip(0, 4, 0, TrackKind::Video, None, Some(10));
        let mut tl = timeline(vec![track(TrackKind::Video, vec![x.clone(), v(4, 2)])]);
        tl.caption_tracks = vec![captions(&[(2, 3), (5, 6)])];
        let before = tl.clone();
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(-2)), Ok(s(-1)), "the caption ends at 3: only 1 s is free");
        assert_eq!(tl.tracks[0].clips()[0].timeline(), TimeRange::new(s(0), s(3)));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(3)]);
        assert_eq!(caption_ranges(&tl), [range(2, 3), range(4, 5)], "kept, and the later one rides the ripple");
        let after = tl.clone();
        tl = before.clone(); // undo = the snapshot taken before the edit
        assert_eq!(tl, before);
        assert_ne!(after, before);
    }

    #[test]
    fn a_head_trim_stops_at_a_caption_in_the_removed_head() {
        let x = clip(2, 4, 10, TrackKind::Video, None, None);
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 2), x.clone(), v(6, 1)])]);
        tl.caption_tracks = vec![captions(&[(3, 4)])];
        assert_eq!(
            tl.ripple_trim(x.id, ClipEdge::Head, s(2)),
            Ok(s(1)),
            "the caption starts 1 s into the removed head"
        );
        assert_eq!(caption_ranges(&tl), [range(2, 3)], "kept, and it rides the 1 s that closed");
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(2), s(5)]);
    }

    // MARK: Ripple trim

    #[test]
    fn tail_shortening_pulls_all_tracks() {
        let x = clip(0, 4, 0, TrackKind::Video, None, Some(10));
        let mut tl =
            timeline(vec![track(TrackKind::Video, vec![x.clone(), v(4, 2)]), track(TrackKind::Video, vec![v(5, 1)])]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(-1)), Ok(s(-1)));
        assert_eq!(tl.tracks[0].clips()[0].timeline(), TimeRange::new(s(0), s(3)));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(3)]);
        assert_eq!(starts(&tl.tracks[1]), [s(4)]);
    }

    #[test]
    fn tail_extension_pushes_and_stops_at_the_media_end() {
        let x = clip(0, 4, 0, TrackKind::Video, None, Some(6));
        let mut tl =
            timeline(vec![track(TrackKind::Video, vec![x.clone(), v(4, 2)]), track(TrackKind::Video, vec![v(5, 1)])]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(5)), Ok(s(2)));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(6)]);
        assert_eq!(starts(&tl.tracks[1]), [s(7)]);
    }

    #[test]
    fn head_trim_keeps_the_start_and_advances_the_source() {
        let x = clip(2, 4, 10, TrackKind::Video, None, None);
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![v(0, 2), x.clone(), v(6, 1)]),
            track(TrackKind::Video, vec![v(7, 1)]),
        ]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Head, s(1)), Ok(s(1)));
        let c = &tl.tracks[0].clips()[1];
        assert_eq!((c.start, c.source), (s(2), TimeRange::new(s(11), s(3))));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(2), s(5)]);
        assert_eq!(starts(&tl.tracks[1]), [s(6)]);
    }

    #[test]
    fn head_extension_is_limited_by_the_source_start() {
        let x = clip(2, 2, 1, TrackKind::Video, None, None);
        let mut tl = timeline(vec![track(TrackKind::Video, vec![x.clone(), v(4, 1)])]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Head, s(-3)), Ok(s(-1)));
        assert_eq!(tl.tracks[0].clips()[0].source, TimeRange::new(s(0), s(3)));
        assert_eq!(starts(&tl.tracks[0]), [s(2), s(5)]);
    }

    #[test]
    fn shortening_is_blocked_by_another_track() {
        let x = clip(0, 4, 0, TrackKind::Video, None, Some(10));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![x.clone(), v(4, 2)]),
            track(TrackKind::Video, vec![v(0, 3), v(4, 1)]),
        ]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(-3)), Ok(s(-1)));
        assert!(consistent(&tl));
    }

    #[test]
    fn the_linked_partner_trims_too() {
        let (vc, ac) =
            (clip(0, 4, 0, TrackKind::Video, Some(5), Some(10)), clip(0, 4, 0, TrackKind::Audio, Some(5), Some(10)));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![vc.clone(), v(4, 1)]),
            track(TrackKind::Audio, vec![ac, a(4, 1)]),
        ]);
        assert!(tl.ripple_trim(vc.id, ClipEdge::Tail, s(-2)).is_ok());
        assert_eq!(tl.tracks[1].clips()[0].source.duration, s(2));
        assert_eq!(starts(&tl.tracks[1]), [s(0), s(2)]);
    }

    #[test]
    fn emptying_and_locked_tracks_are_refused() {
        let x = v(0, 2);
        let mut tl = timeline(vec![track(TrackKind::Video, vec![x.clone()])]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(-2)), Err(EditError::EmptyClip));
        let mut locked = track(TrackKind::Video, vec![x.clone()]);
        locked.is_locked = true;
        let mut tl = timeline(vec![locked]);
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Tail, s(1)), Err(EditError::TrackLocked));
    }

    #[test]
    fn head_extension_opens_the_gap_at_the_edit_point_for_captions_and_markers() {
        let x = clip(0, 8, 102, TrackKind::Video, None, Some(200));
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![x.clone(), v(8, 2)]),
            track(TrackKind::Video, vec![clip(4, 2, 106, TrackKind::Video, None, None)]),
        ]);
        let item = |n: u128, text: &str, a: i64, b: i64| json!({"id": Id::from_u128(n), "lines": [text], "range": {"start": {"value": a, "timescale": 1}, "duration": {"value": b - a, "timescale": 1}}});
        tl.caption_tracks = vec![
            serde_json::from_value(
                json!({"id": Id::from_u128(1), "items": [item(2, "six", 4, 5), item(3, "nine", 7, 8)]}),
            )
            .unwrap_or_else(|e| panic!("{e}")),
        ];
        tl.markers = serde_json::from_value(
            json!([{"id": Id::from_u128(7), "time": {"value": 4, "timescale": 1}, "name": "m"}]),
        )
        .unwrap_or_default();
        assert_eq!(tl.ripple_trim(x.id, ClipEdge::Head, s(-2)), Ok(s(-2)));
        assert_eq!(tl.tracks[0].clips()[0].source, TimeRange::new(s(100), s(10)));
        assert_eq!(starts(&tl.tracks[0]), [s(0), s(10)]);
        assert_eq!(starts(&tl.tracks[1]), [s(6)]);
        assert_eq!(
            tl.caption_tracks[0].items().iter().map(|i| i.range).collect::<Vec<_>>(),
            [range(6, 7), range(9, 10)]
        );
        assert_eq!(tl.markers.iter().map(|m| m.time).collect::<Vec<_>>(), [s(6)]);
    }

    #[test]
    fn a_pivot_follows_the_longest_member_so_the_unlinked_clip_stays_after_the_partner() {
        let setup = || {
            let (vc, ac) =
                (clip(10, 10, 0, TrackKind::Video, Some(3), None), clip(8, 7, 0, TrackKind::Audio, Some(3), None));
            let c = a(15, 3);
            (
                timeline(vec![
                    track(TrackKind::Video, vec![vc.clone()]),
                    track(TrackKind::Audio, vec![ac.clone(), c.clone()]),
                ]),
                vc,
                ac,
                c,
            )
        };
        let (mut tl, vc, ac, c) = setup();
        assert_eq!(tl.ripple_trim(vc.id, ClipEdge::Tail, s(2)), Ok(s(2)));
        assert_eq!(tl.find(ac.id).map(|m| m.clip.timeline()), Some(range(8, 17)));
        assert_eq!(tl.find(c.id).map(|m| m.clip.timeline()), Some(range(17, 20)));
        let (mut tl, vc, ac, c) = setup();
        assert_eq!(tl.ripple_trim(vc.id, ClipEdge::Tail, s(-2)), Ok(s(-2)));
        assert_eq!(tl.find(ac.id).map(|m| m.clip.timeline()), Some(range(8, 13)));
        assert_eq!(tl.find(c.id).map(|m| m.clip.timeline()), Some(range(13, 16)));
    }

    #[test]
    fn a_ripple_trim_at_speed_shifts_later_clips_by_the_timeline_change() {
        let fr = |n: i64| Time::new(n, 30);
        let mut fast = Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, fr(60)),
            Time::ZERO,
        );
        fast.speed = crate::ClipSpeed::from_percent(200.0);
        let mut later = Clip::new(
            Id::from_u128(3),
            "c",
            Id::from_u128(4),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, fr(30)),
            fr(40),
        );
        later.media_duration = None;
        let mut tl = timeline(vec![track(TrackKind::Video, vec![fast.clone(), later])]);
        assert!(tl.ripple_trim(fast.id, ClipEdge::Tail, -fr(10)).is_ok());
        assert_eq!((tl.tracks[0].clips()[0].duration(), tl.tracks[0].clips()[1].start), (fr(20), fr(30)));
    }

    // MARK: Split edits (J/L cuts)

    /// V2: unlinked title. V1/A1: pair A and pair B, linked per pair. Returns the timeline and the clip ids by name.
    fn split_timeline(
        title: (i64, i64),
        av: (i64, i64),
        aa: (i64, i64),
        bv: (i64, i64),
        ba: (i64, i64),
    ) -> (Timeline, impl Fn(&Timeline, &str) -> Clip) {
        let named = |n: &str, kind, r: (i64, i64), link| {
            let mut c = clip(r.0, r.1 - r.0, 30, kind, link, Some(200));
            c.name = n.to_string();
            c
        };
        let mut v1 = Track::new(Id::from_u128(41), TrackKind::Video);
        let mut v2 = Track::new(Id::from_u128(42), TrackKind::Video);
        let mut a1 = Track::new(Id::from_u128(43), TrackKind::Audio);
        v1.set_clips(vec![named("Av", TrackKind::Video, av, Some(1)), named("Bv", TrackKind::Video, bv, Some(2))]);
        a1.set_clips(vec![named("Aa", TrackKind::Audio, aa, Some(1)), named("Ba", TrackKind::Audio, ba, Some(2))]);
        v2.set_clips(vec![named("title", TrackKind::Video, title, None)]);
        let find = |t: &Timeline, n: &str| {
            t.tracks.iter().flat_map(|x| x.clips()).find(|c| c.name == n).cloned().unwrap_or_else(|| v(0, 1))
        };
        (timeline(vec![v1, v2, a1]), find)
    }

    #[test]
    fn delete_before_a_j_cut_moves_the_straddling_sound() {
        let (mut t, named) = split_timeline((10, 20), (0, 10), (0, 6), (20, 30), (17, 30));
        let r = t.ripple_delete_detailed(&[named(&t, "title").id]);
        assert_eq!(r, Ok((s(10), None)));
        assert_eq!((named(&t, "Bv").start, named(&t, "Ba").start), (s(10), s(7)));
        assert!(consistent(&t));
    }

    #[test]
    fn delete_before_a_j_cut_clamps_on_the_sound_track() {
        let (mut t, named) = split_timeline((10, 20), (0, 10), (0, 10), (20, 30), (17, 30));
        let r = t.ripple_delete_detailed(&[named(&t, "title").id]);
        assert_eq!(r.map(|(c, k)| (c, k.map(|k| k.shortfall))), Ok((s(7), Some(s(3)))));
        assert_eq!((named(&t, "Bv").start, named(&t, "Ba").start), (s(13), s(10)));
        assert!(consistent(&t));
    }

    #[test]
    fn delete_next_to_an_l_cut_moves_the_straddling_picture() {
        let (mut t, named) = split_timeline((5, 12), (0, 5), (0, 5), (10, 20), (13, 20));
        let r = t.ripple_delete_detailed(&[named(&t, "title").id]);
        assert_eq!(r.map(|(c, _)| c), Ok(s(5)));
        assert_eq!((named(&t, "Bv").start, named(&t, "Ba").start), (s(5), s(8)));
        assert!(consistent(&t));
    }

    #[test]
    fn deleting_the_l_cut_pair_keeps_the_next_pair_in_sync() {
        let (mut t, named) = split_timeline((40, 41), (0, 10), (0, 12), (10, 20), (12, 20));
        assert!(t.ripple_delete(&[named(&t, "Av").id]).is_ok());
        assert_eq!((named(&t, "Bv").start, named(&t, "Ba").start), (s(0), s(2)));
        assert!(consistent(&t));
    }

    #[test]
    fn trim_next_to_an_l_cut_moves_the_straddling_picture() {
        let (mut t, named) = split_timeline((3, 12), (0, 3), (0, 3), (10, 20), (13, 20));
        let moved = t.ripple_trim(named(&t, "title").id, ClipEdge::Tail, s(-7)).unwrap_or(Time::ZERO);
        assert_eq!(named(&t, "Ba").start - named(&t, "Bv").start, s(3));
        assert_eq!(named(&t, "title").timeline().end(), s(12) + moved);
        assert_eq!(named(&t, "Bv").start, s(10) + moved);
        assert!(consistent(&t));
    }

    #[test]
    fn trim_before_a_j_cut_moves_the_straddling_sound() {
        let (mut t, named) = split_timeline((5, 20), (0, 5), (0, 5), (20, 30), (17, 30));
        assert_eq!(t.ripple_trim(named(&t, "title").id, ClipEdge::Tail, s(-10)), Ok(s(-10)));
        assert_eq!((named(&t, "Bv").start, named(&t, "Ba").start), (s(10), s(7)));
        assert!(consistent(&t));
    }

    #[test]
    fn a_text_clip_cannot_be_ripple_trimmed_below_its_zones() {
        let mut c = v(0, 5);
        c.zones = Some(crate::AnimationZones::new(s(1), s(1), crate::ZoneMiddle::Hold, None));
        let mut tl = timeline(vec![track(TrackKind::Video, vec![c.clone()])]);
        assert_eq!(tl.ripple_trim(c.id, ClipEdge::Tail, s(-4)), Ok(s(-3)));
        assert_eq!(tl.tracks[0].clips()[0].duration(), s(2));
    }

    // MARK: Insert

    #[test]
    fn insert_splits_and_pushes_other_tracks_but_not_locked_ones() {
        let mut locked = track(TrackKind::Video, vec![v(3, 1)]);
        locked.is_locked = true;
        let mut tl = timeline(vec![
            track(TrackKind::Video, vec![clip(0, 10, 50, TrackKind::Video, None, None)]),
            track(TrackKind::Video, vec![v(2, 6)]),
            locked,
        ]);
        let target = tl.tracks[0].id;
        assert_eq!(tl.insert(&[(v(0, 3), target)], s(4), &mut TestIds(800)), Ok(()));
        assert_eq!(ranges(&tl.tracks[0]), [range(0, 4), range(4, 7), range(7, 13)]);
        assert_eq!(ranges(&tl.tracks[1]), [range(2, 4), range(7, 11)]);
        assert_eq!(starts(&tl.tracks[2]), [s(3)]);
        assert_eq!(tl.tracks[1].clips()[1].source.start, s(2));
    }

    /// An insert never changes the length of a caption (the old rule stretched the one under the insert point: a 1.5 s
    /// caption became 5.5 s). Captions that start at or after the point move by the insert; the one under it stays.
    #[test]
    fn an_insert_never_changes_the_length_of_a_caption() {
        // (insert point, expected caption ranges) for captions at 2..4 and 6..8 and a 4 s insert.
        let cases = [
            (1, vec![range(6, 8), range(10, 12)]),
            (2, vec![range(6, 8), range(10, 12)]),
            (3, vec![range(2, 4), range(10, 12)]),
            (5, vec![range(2, 4), range(10, 12)]),
            (7, vec![range(2, 4), range(6, 8)]),
            (9, vec![range(2, 4), range(6, 8)]),
        ];
        for (point, expected) in cases {
            let mut tl = timeline(vec![track(TrackKind::Video, vec![clip(0, 20, 0, TrackKind::Video, None, None)])]);
            tl.caption_tracks = vec![captions(&[(2, 4), (6, 8)])];
            let target = tl.tracks[0].id;
            assert_eq!(tl.insert(&[(v(0, 4), target)], s(point), &mut TestIds(800)), Ok(()), "point {point}");
            let got = caption_ranges(&tl);
            let lens: Vec<_> = got.iter().map(|r| r.duration).collect();
            assert_eq!(lens, vec![s(2), s(2)], "lengths never change, insert at {point}");
            assert_eq!(got, expected, "insert at {point}");
        }
    }

    #[test]
    fn insert_relinks_the_right_halves() {
        let (vc, ac) =
            (clip(0, 10, 0, TrackKind::Video, Some(9), None), clip(0, 10, 0, TrackKind::Audio, Some(9), None));
        let mut tl =
            timeline(vec![track(TrackKind::Video, vec![vc.clone()]), track(TrackKind::Audio, vec![ac.clone()])]);
        let target = tl.tracks[0].id;
        assert_eq!(tl.insert(&[(v(0, 2), target)], s(5), &mut TestIds(800)), Ok(()));
        let right = |t: &Track| t.clips().iter().find(|c| c.start == s(7)).cloned();
        let (vr, ar) = (right(&tl.tracks[0]), right(&tl.tracks[1]));
        let (vr, ar) = (vr.unwrap_or_else(|| v(0, 1)), ar.unwrap_or_else(|| v(0, 1)));
        let group = |id| tl.linked_group(id).map(|g| g.iter().map(|m| m.clip.id).collect::<BTreeSet<_>>());
        assert_eq!(group(vc.id), Ok(BTreeSet::from([vc.id, ac.id])));
        assert_eq!(group(vr.id), Ok(BTreeSet::from([vr.id, ar.id])));
        assert_ne!(vr.link, vc.link);
    }

    #[test]
    fn insert_refuses_bad_input_and_changes_nothing() {
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 4)]), track(TrackKind::Audio, vec![])]);
        let (video, audio) = (tl.tracks[0].id, tl.tracks[1].id);
        let before = tl.clone();
        let ids = &mut TestIds(800);
        assert_eq!(tl.insert(&[], s(1), ids), Err(EditError::EmptyClip));
        assert_eq!(tl.insert(&[(v(0, 1), video)], s(-1), ids), Err(EditError::Collision));
        assert_eq!(tl.insert(&[(v(0, 1), audio)], s(1), ids), Err(EditError::WrongTrackKind));
        assert_eq!(tl.insert(&[(v(0, 1), Id::from_u128(1))], s(1), ids), Err(EditError::ClipNotFound));
        assert_eq!(tl, before);
    }

    #[test]
    fn insert_keeps_the_offsets_of_a_j_cut_and_clears_main_track_attachments() {
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 10)]), track(TrackKind::Audio, vec![])]);
        let (video, audio) = (tl.tracks[0].id, tl.tracks[1].id);
        let mut picture = v(4, 3);
        picture.attachment = Some(crate::ClipAttachment::new(Id::from_u128(5), Time::ZERO));
        let sound = a(2, 6);
        assert_eq!(tl.insert(&[(picture, video), (sound, audio)], s(5), &mut TestIds(800)), Ok(()));
        assert_eq!(tl.tracks[1].clips()[0].timeline(), range(5, 11));
        let placed = tl.tracks[0].clips().iter().find(|c| c.start == s(7)).cloned();
        assert_eq!(placed.map(|c| c.attachment), Some(None));
    }

    #[test]
    fn markers_in_out_and_explicit_marks_follow_the_point_rule() {
        let mut tl = timeline(vec![track(TrackKind::Video, vec![v(0, 20)])]);
        tl.in_out = Some(range(4, 12));
        tl.in_out_kind = Some(InOutKind::Both);
        assert_eq!(tl.explicit_marks(), (Some(s(4)), Some(s(12))));
        tl.in_out_kind = None;
        assert_eq!(tl.explicit_marks(), (Some(s(4)), Some(s(12))));
        tl.in_out = Some(range(4, 20));
        assert_eq!(tl.explicit_marks(), (Some(s(4)), None), "an unknown kind reaching the sequence end is In only");
        tl.in_out_kind = Some(InOutKind::OutOnly);
        tl.shift_in_out(s(10), s(-4));
        assert_eq!(tl.in_out, Some(range(4, 16)), "an Out-only range keeps its start");
        tl.in_out_kind = Some(InOutKind::Both);
        tl.shift_in_out(s(16), s(-12));
        assert_eq!((tl.in_out, tl.in_out_kind), (None, None), "a range that collapses is cleared");
    }
}
