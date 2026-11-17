// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+TrimMode.swift (Trim mode: edit points and the three trim sides)

use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time};
use std::collections::BTreeSet;

use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;

/// Which side of an edit Trim mode changes. `Outgoing` ripples the end of the clip before the edit, `Incoming` ripples the
/// start of the clip after it, `Roll` moves the edit itself (sequence length unchanged).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrimSide {
    /// The clip before the edit.
    Outgoing,
    /// The clip after the edit.
    Incoming,
    /// The edit itself.
    Roll,
}

impl TrimSide {
    /// Ctrl+T in Trim mode: outgoing -> incoming -> roll -> outgoing; sides the edit does not have are skipped.
    pub fn next(self, p: &TrimPoint) -> TrimSide {
        let order = [TrimSide::Outgoing, TrimSide::Incoming, TrimSide::Roll];
        let i = order.iter().position(|s| *s == self).unwrap_or(0);
        for k in 1..=order.len() {
            let s = order[(i + k) % order.len()];
            if p.supports(s) {
                return s;
            }
        }
        self
    }
}

/// An edit point as Trim mode sees it: the clip ending and the clip starting at `time` on one track. A clip edge next to a
/// gap has only one side.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TrimPoint {
    /// The track.
    pub track: Id,
    /// The clip ending at `time`.
    pub outgoing: Option<Id>,
    /// The clip starting at `time`.
    pub incoming: Option<Id>,
    /// The edit's time.
    pub time: Time,
}

impl TrimPoint {
    /// The edit has this side.
    pub fn supports(&self, side: TrimSide) -> bool {
        match side {
            TrimSide::Outgoing => self.outgoing.is_some(),
            TrimSide::Incoming => self.incoming.is_some(),
            TrimSide::Roll => self.outgoing.is_some() && self.incoming.is_some(),
        }
    }

    /// The side a double-click picks: the one the pointer is on (`before` = left of the edit); a roll is never the default.
    pub fn default_side(&self, pointer_before: bool) -> TrimSide {
        if pointer_before && self.outgoing.is_some() {
            return TrimSide::Outgoing;
        }
        if !pointer_before && self.incoming.is_some() {
            return TrimSide::Incoming;
        }
        if self.outgoing.is_some() { TrimSide::Outgoing } else { TrimSide::Incoming }
    }
}

/// Trim mode: edit points and the atomic trim edit.
pub trait TimelineTrimModeExt {
    /// The edit point on `track` at `cut` (a clip ends and/or starts there); `None` when neither does.
    fn trim_point(&self, cut: Time, track: Id) -> Option<TrimPoint>;

    /// The edit point nearest to `t` on the given tracks (`None` = every unlocked track). Real cuts beat lone clip edges at
    /// the same distance; further ties go to the upper track. The sequence start is not an edit point.
    fn nearest_trim_point(&self, t: Time, tracks: Option<&[Id]>) -> Option<TrimPoint>;

    /// The same edit after it moved: its clips keep their ids, so time (and track) are re-read from them. A side whose clip
    /// is gone becomes `None`; `None` overall when no clip is left or when both still exist but no longer touch on one
    /// track.
    fn resolved(&self, p: &TrimPoint) -> Option<TrimPoint>;

    /// Frame times the two-up monitor shows: the last frame of the outgoing clip and the first frame of the incoming one
    /// (`None` for a side the edit does not have).
    fn trim_frames(&self, p: &TrimPoint) -> (Option<Time>, Option<Time>);

    /// Moves the edit `delta` later (negative = earlier) in the given mode and returns how far the edge actually moved:
    /// whole frames only (rounded toward zero), clamped by media handles and neighbors so a clip keeps at least one frame,
    /// 0 when blocked. One call is one atomic edit; linked partners follow. `Outgoing` / `Incoming` ripple, `Roll` keeps the
    /// sequence length. `ClipNotFound` when the point or the side's clips are gone or no longer adjacent (roll),
    /// `TrackLocked` for a locked track.
    fn trim_edit(
        &mut self,
        p: &TrimPoint,
        side: TrimSide,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
}

impl TimelineTrimModeExt for Timeline {
    fn trim_point(&self, cut: Time, track: Id) -> Option<TrimPoint> {
        let tr = self.tracks.iter().find(|t| t.id == track)?;
        let out = tr.clips().iter().find(|c| c.timeline().end() == cut);
        let inc = tr.clips().iter().find(|c| c.start == cut);
        if out.is_none() && inc.is_none() {
            return None;
        }
        Some(TrimPoint { track, outgoing: out.map(|c| c.id), incoming: inc.map(|c| c.id), time: cut })
    }

    fn nearest_trim_point(&self, t: Time, tracks: Option<&[Id]>) -> Option<TrimPoint> {
        let dist = |a: Time| if a > t { a - t } else { t - a };
        let mut best: Option<(TrimPoint, Time, bool)> = None;
        for tr in self.tracks.iter().filter(|tr| !tr.is_locked && tracks.is_none_or(|ids| ids.contains(&tr.id))) {
            let mut times: BTreeSet<Time> = BTreeSet::new();
            for c in tr.clips() {
                times.insert(c.start);
                times.insert(c.timeline().end());
            }
            for time in times.into_iter().filter(|time| *time > Time::ZERO) {
                let Some(p) = self.trim_point(time, tr.id) else { continue };
                let d = dist(time);
                let is_cut = p.outgoing.is_some() && p.incoming.is_some();
                if let Some(b) = &best
                    && !(d < b.1 || (d == b.1 && is_cut && !b.2))
                {
                    continue;
                }
                best = Some((p, d, is_cut));
            }
        }
        best.map(|b| b.0)
    }

    fn resolved(&self, p: &TrimPoint) -> Option<TrimPoint> {
        let find = |id: Option<Id>| {
            let id = id?;
            self.tracks.iter().find_map(|tr| tr.clips().iter().find(|c| c.id == id).map(|c| (tr.id, c)))
        };
        let (out, inc) = (find(p.outgoing), find(p.incoming));
        let mut r = p.clone();
        r.outgoing = out.map(|o| o.1.id);
        r.incoming = inc.map(|i| i.1.id);
        match (out, inc) {
            (Some(o), Some(i)) => {
                if o.0 != i.0 || o.1.timeline().end() != i.1.start {
                    return None;
                }
                r.track = o.0;
                r.time = i.1.start;
            }
            (Some(o), None) => {
                r.track = o.0;
                r.time = o.1.timeline().end();
            }
            (None, Some(i)) => {
                r.track = i.0;
                r.time = i.1.start;
            }
            (None, None) => return None,
        }
        Some(r)
    }

    fn trim_frames(&self, p: &TrimPoint) -> (Option<Time>, Option<Time>) {
        let all = || self.tracks.iter().flat_map(|t| t.clips());
        let out =
            p.outgoing.and_then(|id| all().find(|c| c.id == id)).map(|c| c.timeline().end() - self.frame_duration());
        let inc = p.incoming.and_then(|id| all().find(|c| c.id == id)).map(|c| c.start);
        (out, inc)
    }

    fn trim_edit(
        &mut self,
        p: &TrimPoint,
        side: TrimSide,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let r = self.resolved(p).ok_or(EditError::ClipNotFound)?;
        if !r.supports(side) {
            return Err(EditError::ClipNotFound);
        }
        let clip =
            |id: Option<Id>| id.and_then(|i| self.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == i)).cloned();
        let fd = self.frame_duration();
        // toward zero, in whole frames
        let whole = |t: Time| if t < Time::ZERO { -(fd * (-t).frame_index(fd)) } else { fd * t.frame_index(fd) };
        let floor_frames = |t: Time| fd * t.frame_index(fd).max(0);
        let mut d = whole(delta);
        let one = fd;
        match side {
            TrimSide::Outgoing => {
                let o = clip(r.outgoing).ok_or(EditError::ClipNotFound)?;
                if let Some(room) = o.tail_room() {
                    d = d.min(floor_frames(room));
                }
                // a clip under one frame (or its zones): no shortening, never a reversal
                d = d.max((o.minimum_duration(one) - o.duration()).min(Time::ZERO));
                if d == Time::ZERO {
                    return Ok(Time::ZERO);
                }
                self.magnetic_ripple_trim(o.id, ClipEdge::Tail, d, ids)
            }
            TrimSide::Incoming => {
                let i = clip(r.incoming).ok_or(EditError::ClipNotFound)?;
                if let Some(h) = i.head_handle() {
                    d = d.max(-floor_frames(h));
                }
                d = d.min((i.duration() - i.minimum_duration(one)).max(Time::ZERO));
                if d == Time::ZERO {
                    return Ok(Time::ZERO);
                }
                self.magnetic_ripple_trim(i.id, ClipEdge::Head, d, ids)
            }
            TrimSide::Roll => {
                let o = clip(r.outgoing).ok_or(EditError::ClipNotFound)?;
                let i = clip(r.incoming).ok_or(EditError::ClipNotFound)?;
                if let Some(room) = o.tail_room() {
                    d = d.min(floor_frames(room));
                }
                if let Some(h) = i.head_handle() {
                    d = d.max(-floor_frames(h));
                }
                d = d.min((i.duration() - i.minimum_duration(one)).max(Time::ZERO));
                d = d.max((o.minimum_duration(one) - o.duration()).min(Time::ZERO));
                if d == Time::ZERO {
                    return Ok(Time::ZERO);
                }
                self.magnetic_roll(o.id, d, ids)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::TimelineEditsExt as _;
    use crate::timeline_edits::fixtures::{fresh, timeline, track};
    use sq_core_model::{Clip, ClipSpeed, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn clip(start: i64, from: i64, frames: i64) -> Clip {
        let n = fresh();
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5_000_000),
            TrackKind::Video,
            TimeRange::new(f(from), f(frames)),
            f(start),
        );
        c.media_duration = Some(f(300));
        c
    }

    /// A 0..60, B 60..120, C 150..210 (gap 120..150) on one track; 30 frames of handle on each side of every clip.
    fn make() -> (Timeline, Clip, Clip, Clip) {
        let (a, b, c) = (clip(0, 30, 60), clip(60, 30, 60), clip(150, 30, 60));
        let t = timeline(vec![track(TrackKind::Video, vec![a.clone(), b.clone(), c.clone()])]);
        (t, a, b, c)
    }

    fn clip_of(t: &Timeline, id: Id) -> Option<Clip> {
        t.find(id).map(|m| m.clip)
    }

    #[test]
    fn nearest_point_prefers_the_cut_and_knows_lone_edges() {
        let (t, a, b, c) = make();
        let p = t.nearest_trim_point(f(58), None);
        assert_eq!(p.map(|p| (p.outgoing, p.incoming, p.time)), Some((Some(a.id), Some(b.id), f(60))));
        let q = t.nearest_trim_point(f(125), None); // B's tail beside a gap
        assert_eq!(q.map(|p| (p.outgoing, p.incoming, p.time)), Some((Some(b.id), None, f(120))));
        let r = t.nearest_trim_point(f(148), None);
        assert_eq!(r.map(|p| (p.outgoing, p.incoming)), Some((None, Some(c.id))));
    }

    #[test]
    fn zero_is_not_an_edit_point() {
        let (t, ..) = make();
        assert_eq!(t.nearest_trim_point(f(1), None).map(|p| p.time), Some(f(60)));
    }

    #[test]
    fn locked_tracks_are_skipped() {
        let (mut t, ..) = make();
        t.tracks[0].is_locked = true;
        assert_eq!(t.nearest_trim_point(f(60), None), None);
    }

    #[test]
    fn roll_keeps_the_length_and_moves_the_cut() {
        let (mut t, a, b, _) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_edit(&p, TrimSide::Roll, f(5), &mut SequentialIds::default()), Ok(f(5)));
        assert_eq!(clip_of(&t, a.id).map(|c| c.timeline().end()), Some(f(65)));
        assert_eq!(clip_of(&t, b.id).map(|c| (c.start, c.timeline().end())), Some((f(65), f(120))));
        assert_eq!(t.resolved(&p).map(|r| r.time), Some(f(65)));
    }

    #[test]
    fn ripple_outgoing_shifts_everything_after() {
        let (mut t, a, b, c) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_edit(&p, TrimSide::Outgoing, f(-5), &mut SequentialIds::default()), Ok(f(-5)));
        assert_eq!(clip_of(&t, a.id).map(|x| x.timeline().end()), Some(f(55)));
        assert_eq!(clip_of(&t, b.id).map(|x| x.start), Some(f(55)));
        assert_eq!(clip_of(&t, c.id).map(|x| x.start), Some(f(145)));
    }

    #[test]
    fn ripple_incoming_keeps_its_start_and_shortens_the_clip() {
        let (mut t, a, b, c) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert!(t.trim_edit(&p, TrimSide::Incoming, f(5), &mut SequentialIds::default()).is_ok());
        assert_eq!(clip_of(&t, a.id).map(|x| x.timeline().end()), Some(f(60)));
        assert_eq!(clip_of(&t, b.id).map(|x| (x.start, x.duration(), x.source.start)), Some((f(60), f(55), f(35))));
        assert_eq!(clip_of(&t, c.id).map(|x| x.start), Some(f(145)));
    }

    #[test]
    fn handles_clamp_the_move() {
        let (mut t, ..) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_edit(&p, TrimSide::Roll, f(-45), &mut SequentialIds::default()), Ok(f(-30))); // B has 30 frames of head handle
        assert_eq!(t.trim_edit(&p, TrimSide::Roll, f(100), &mut SequentialIds::default()), Ok(f(89))); // B (90 frames now) keeps one frame
    }

    #[test]
    fn a_missing_side_fails() {
        let (mut t, ..) = make();
        let p = t.nearest_trim_point(f(125), None).unwrap_or_else(|| unreachable!());
        assert!(t.trim_edit(&p, TrimSide::Roll, f(1), &mut SequentialIds::default()).is_err());
        assert!(t.trim_edit(&p, TrimSide::Incoming, f(1), &mut SequentialIds::default()).is_err());
    }

    #[test]
    fn monitor_frames_are_last_outgoing_and_first_incoming() {
        let (mut t, ..) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_frames(&p), (Some(f(59)), Some(f(60))));
        assert!(t.trim_edit(&p, TrimSide::Roll, f(5), &mut SequentialIds::default()).is_ok());
        assert_eq!(t.trim_frames(&p), (Some(f(64)), Some(f(65))));
        let lone = t.nearest_trim_point(f(125), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_frames(&lone).1, None);
    }

    #[test]
    fn side_cycle_skips_missing_sides() {
        let (t, ..) = make();
        let cut = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(TrimSide::Outgoing.next(&cut), TrimSide::Incoming);
        assert_eq!(TrimSide::Incoming.next(&cut), TrimSide::Roll);
        assert_eq!(TrimSide::Roll.next(&cut), TrimSide::Outgoing);
        let lone = t.nearest_trim_point(f(125), None).unwrap_or_else(|| unreachable!());
        assert_eq!(TrimSide::Outgoing.next(&lone), TrimSide::Outgoing);
        assert_eq!(lone.default_side(false), TrimSide::Outgoing);
        assert_eq!((cut.default_side(false), cut.default_side(true)), (TrimSide::Incoming, TrimSide::Outgoing));
    }

    #[test]
    fn a_deleted_side_degrades_and_the_other_side_still_trims() {
        let (mut t, a, b, c) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        t.tracks[0].remove(b.id);
        let r = t.resolved(&p);
        assert_eq!(r.map(|r| (r.incoming, r.outgoing, r.time)), Some((None, Some(a.id), f(60))));
        assert_eq!(t.trim_edit(&p, TrimSide::Outgoing, f(-5), &mut SequentialIds::default()), Ok(f(-5)));
        assert_eq!(clip_of(&t, c.id).map(|x| x.start), Some(f(145)));
        assert!(t.trim_edit(&p, TrimSide::Roll, f(1), &mut SequentialIds::default()).is_err());
    }

    #[test]
    fn both_sides_gone_leaves_the_mode() {
        let (mut t, a, b, _) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        t.tracks[0].remove(a.id);
        t.tracks[0].remove(b.id);
        assert_eq!(t.resolved(&p), None);
    }

    #[test]
    fn clips_that_no_longer_touch_leave_the_mode() {
        let (mut t, a, ..) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert!(t.trim(a.id, ClipEdge::Tail, f(-5)).is_ok()); // plain trim leaves a gap
        assert_eq!(t.resolved(&p), None);
        assert!(t.trim_edit(&p, TrimSide::Roll, f(1), &mut SequentialIds::default()).is_err());
    }

    #[test]
    fn roll_does_not_jump_to_another_neighbour() {
        let (mut t, _, b, c) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        t.tracks[0].remove(b.id);
        assert!(t.ripple_trim(c.id, ClipEdge::Head, Time::ZERO).is_ok());
        // A now ends at 60, nothing starts there: the roll must refuse instead of rolling A | C.
        assert!(t.trim_edit(&p, TrimSide::Roll, f(1), &mut SequentialIds::default()).is_err());
    }

    #[test]
    fn fractional_handles_give_whole_frames() {
        let a = clip(0, 30, 60);
        let mut b = clip(60, 30, 70);
        b.speed = ClipSpeed::new(7, 2); // 20 timeline frames, head handle 8.57 frames
        let mut t = timeline(vec![track(TrackKind::Video, vec![a, b])]);
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_edit(&p, TrimSide::Roll, f(-10), &mut SequentialIds::default()), Ok(f(-8)));
        let start = t.tracks[0].clips()[1].start;
        assert_eq!((start, start.frame_index(Time::new(1, 30))), (f(52), 52));
    }

    #[test]
    fn ripple_clamps_instead_of_emptying_the_clip() {
        let (mut t, a, ..) = make();
        let p = t.nearest_trim_point(f(60), None).unwrap_or_else(|| unreachable!());
        assert_eq!(t.trim_edit(&p, TrimSide::Outgoing, f(-100), &mut SequentialIds::default()), Ok(f(-59)));
        assert_eq!(clip_of(&t, a.id).map(|x| x.duration()), Some(f(1)));
    }
}
