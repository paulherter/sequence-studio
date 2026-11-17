// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Edits.swift (non-ripple edits: trim, roll, slip, move)

use sq_core_model::{
    Clip, ClipEdge, CowVec, EditError, Member, Timeline, Track, clear_main_track_attachments, floored_to_frame,
};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// What a slip does with the clip's keyframes (animation, effects, masks): follow the media or stay on the timeline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SlipKeyframes {
    /// The keys move with the media so each stays on its source frame.
    FollowContent,
    /// The keys stay at their timeline position, over the new content.
    Stay,
}

/// Option-drag duplicate: identities of the copies (original id to copy id; missing = fresh) and the link the copied
/// group shares. Given by the caller so a replayed edit always yields the same ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopySpec {
    /// Original clip id to the id of its copy.
    pub ids: BTreeMap<Id, Id>,
    /// The link the copied group shares.
    pub link: Id,
}

/// The cut a roll moves and who rolls with it (Swift `roll(cut:leftPartnersOf:rightPartnersOf:...)`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RollCut {
    /// The clip whose tail is the cut (it must have a directly adjacent clip after it).
    pub left: Id,
    /// Members of this clip's link group ending on the same cut roll their own cut.
    pub left_partners_of: Id,
    /// Members of this clip's link group starting on the cut roll theirs.
    pub right_partners_of: Option<Id>,
    /// Extend Edit: stop one frame before a side would become empty instead of failing with `EmptyClip`, and a partner on
    /// the cut with no clip on the other side moves its own edge by the same amount.
    pub extend: bool,
    /// Partners without a neighbor on the cut follow, as in `extend`, without the emptying limits.
    pub partners_follow: bool,
}

/// Non-ripple edits: nothing outside the edited clips (and what they cover) shifts.
pub trait TimelineEditsExt {
    /// Plain trim. Head + = shorter, tail + = longer. Shortening leaves a gap; extending is clamped by the neighbor on the
    /// track, the media and timeline start 0. Linked partners get the same change; the applied amount is the most
    /// restrictive across the group. Returns how far the edge moved.
    fn trim(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError>;

    /// Moves the cut between `id` and the clip directly after it on the same track. Left tail and right head move by
    /// `delta`. Linked partners of either clip roll their own cut if it is at the same time position; a partner that ends
    /// (left clip's group) or starts (right clip's group) on the cut with no clip on the other side (a gap) moves its own
    /// edge by the same amount, as in Extend Edit, and its gap and media limit the whole edit. `Collision` when `id` has no
    /// directly adjacent clip after it.
    fn roll(&mut self, id: Id, delta: Time) -> Result<Time, EditError>;

    /// Rolls the cut described by `cut` by `delta`; see `RollCut`.
    #[doc(hidden)]
    fn roll_cut(&mut self, cut: &RollCut, delta: Time) -> Result<Time, EditError>;

    /// Changes which part of the media shows; position and duration stay. Clamped to the media, partners follow. `delta` is
    /// timeline time: the content follows the pointer, so a positive `delta` shows later source of a forward clip and
    /// earlier source of a reversed one (the source moves by `delta * speed`). `keyframes` says whether the clip's keys move
    /// with the media. Returns the applied `delta`.
    fn slip(&mut self, id: Id, delta: Time, keyframes: SlipKeyframes) -> Result<Time, EditError>;

    /// Moves a clip so it starts at `start` (optionally onto another track of the same kind, `target`) and moves linked
    /// partners by the same delta on their own tracks (`retarget`: partner clip to its destination track). Covered clips at
    /// the destination are cut or removed. Clamped so nothing starts before 0. With `copy` the originals stay and the copies
    /// get the ids and link of the spec. Returns the applied delta.
    fn move_clip(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        retarget: &BTreeMap<Id, Id>,
        copy: Option<&CopySpec>,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
}

fn require_unlocked(tl: &Timeline, group: &[Member]) -> Result<(), EditError> {
    if group.iter().any(|m| tl.tracks[m.track].is_locked) {
        return Err(EditError::TrackLocked);
    }
    Ok(())
}

/// Accepts `work` when every track is consistent and applies the Fast Cut main-track invariant.
fn commit(mut work: CowVec<Track>) -> Result<CowVec<Track>, EditError> {
    if !work.iter().all(Track::is_consistent) {
        return Err(EditError::Collision);
    }
    clear_main_track_attachments(&mut work);
    Ok(work)
}

fn limit(room: &mut Option<Time>, r: Time) {
    *room = Some(room.map_or(r, |x| x.min(r)));
}

impl TimelineEditsExt for Timeline {
    fn trim(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError> {
        let group = self.linked_group(id)?;
        require_unlocked(self, &group)?;
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let fd = self.frame_duration();
        let mut g = if edge == ClipEdge::Tail { delta } else { -delta }; // change of duration
        for m in &group {
            let c = &m.clip;
            g = c.clamping_shortening(g, fd); // intro + outro zones stay whole
            if g <= -c.duration() {
                return Err(EditError::EmptyClip);
            }
            if g <= Time::ZERO {
                continue;
            }
            let others: Vec<&Clip> = self.tracks[m.track].clips().iter().filter(|o| !ids.contains(&o.id)).collect();
            let mut room: Option<Time> = None;
            if edge == ClipEdge::Tail {
                if let Some(r) = c.tail_room() {
                    limit(&mut room, floored_to_frame(r, fd));
                }
                if let Some(next) = others.iter().find(|o| o.start >= c.timeline().end()) {
                    limit(&mut room, next.start - c.timeline().end());
                }
            } else {
                if let Some(h) = c.head_handle() {
                    limit(&mut room, floored_to_frame(h, fd));
                }
                limit(&mut room, c.start);
                let prev_end =
                    others.iter().filter(|o| o.timeline().end() <= c.start).map(|o| o.timeline().end()).max();
                limit(&mut room, c.start - prev_end.unwrap_or(Time::ZERO));
            }
            if let Some(room) = room
                && g > room
            {
                g = room.max(Time::ZERO);
            }
        }
        if g == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for m in &group {
            let mut c = m.clip.clone();
            if edge == ClipEdge::Head {
                c.start -= g;
                c.extend_head(g);
            } else {
                c.extend_tail(g);
            }
            work[m.track].replace(c);
        }
        self.tracks = commit(work)?;
        Ok(if edge == ClipEdge::Tail { g } else { -g })
    }

    fn roll(&mut self, id: Id, delta: Time) -> Result<Time, EditError> {
        let right = self.find(id).and_then(|m| {
            self.tracks[m.track].clips().iter().find(|c| c.start == m.clip.timeline().end()).map(|c| c.id)
        });
        self.roll_cut(
            &RollCut { left: id, left_partners_of: id, right_partners_of: right, extend: false, partners_follow: true },
            delta,
        )
    }

    fn roll_cut(&mut self, cut_spec: &RollCut, delta: Time) -> Result<Time, EditError> {
        let follow = cut_spec.extend || cut_spec.partners_follow;
        let first = self.find(cut_spec.left).ok_or(EditError::ClipNotFound)?;
        let left_group = self.linked_group(cut_spec.left_partners_of)?;
        let right_group = match cut_spec.right_partners_of {
            Some(r) => self.linked_group(r)?,
            None => Vec::new(),
        };
        require_unlocked(self, &left_group)?;
        require_unlocked(self, &right_group)?;
        let cut = first.clip.timeline().end();
        if !self.tracks[first.track].clips().iter().any(|c| c.start == cut) {
            return Err(EditError::Collision);
        }
        // One pair per track: (left clip, right clip) of the cut at `cut`; partners on the cut without a neighbor (extend).
        let mut pairs: Vec<(usize, Clip, Clip)> = Vec::new();
        let mut tails: Vec<(usize, Clip)> = Vec::new();
        let mut heads: Vec<(usize, Clip)> = Vec::new();
        let taken = |track: usize, pairs: &[(usize, Clip, Clip)], tails: &[(usize, Clip)], heads: &[(usize, Clip)]| {
            pairs.iter().any(|p| p.0 == track)
                || tails.iter().any(|p| p.0 == track)
                || heads.iter().any(|p| p.0 == track)
        };
        for m in left_group.iter().filter(|m| m.clip.timeline().end() == cut) {
            if taken(m.track, &pairs, &tails, &heads) {
                continue;
            }
            if let Some(r) = self.tracks[m.track].clips().iter().find(|c| c.start == cut) {
                pairs.push((m.track, m.clip.clone(), r.clone()));
            } else if follow {
                tails.push((m.track, m.clip.clone()));
            }
        }
        for m in right_group.iter().filter(|m| m.clip.start == cut) {
            if taken(m.track, &pairs, &tails, &heads) {
                continue;
            }
            if let Some(l) = self.tracks[m.track].clips().iter().find(|c| c.timeline().end() == cut) {
                pairs.push((m.track, l.clone(), m.clip.clone()));
            } else if follow {
                heads.push((m.track, m.clip.clone()));
            }
        }
        let fd = self.frame_duration();
        let mut d = delta;
        for (_, left, right) in &pairs {
            // media first, then refuse (or limit) emptying
            if d > Time::ZERO
                && let Some(r) = left.tail_room()
            {
                d = d.min(floored_to_frame(r, fd));
            }
            if d < Time::ZERO
                && let Some(h) = right.head_handle()
            {
                d = d.max(-floored_to_frame(h, fd));
            }
        }
        if cut_spec.extend {
            // Limits only on the side `d` points to, never past zero (a clip under one frame must not reverse the edit).
            for (_, left, right) in &pairs {
                if d < Time::ZERO {
                    d = d.max((left.minimum_duration(fd) - left.duration()).min(Time::ZERO));
                }
                if d > Time::ZERO {
                    d = d.min((right.duration() - right.minimum_duration(fd)).max(Time::ZERO));
                }
            }
        }
        if follow {
            for (ti, c) in &tails {
                if d > Time::ZERO {
                    if let Some(r) = c.tail_room() {
                        d = d.min(floored_to_frame(r, fd));
                    }
                    let next = self.tracks[*ti]
                        .clips()
                        .iter()
                        .filter(|o| o.start >= c.timeline().end() && o.id != c.id)
                        .map(|o| o.start)
                        .min();
                    if let Some(next) = next {
                        d = d.min(next - c.timeline().end());
                    }
                }
                if d < Time::ZERO {
                    d = d.max((c.minimum_duration(fd) - c.duration()).min(Time::ZERO));
                }
            }
            for (ti, c) in &heads {
                if d < Time::ZERO {
                    if let Some(h) = c.head_handle() {
                        d = d.max(Time::ZERO - floored_to_frame(h, fd));
                    }
                    let prev_end = self.tracks[*ti]
                        .clips()
                        .iter()
                        .filter(|o| o.timeline().end() <= c.start && o.id != c.id)
                        .map(|o| o.timeline().end())
                        .max()
                        .unwrap_or(Time::ZERO);
                    d = d.max(prev_end - c.start);
                }
                if d > Time::ZERO {
                    d = d.min((c.duration() - c.minimum_duration(fd)).max(Time::ZERO));
                }
            }
        }
        for (_, left, right) in &pairs {
            d = left.clamping_shortening(d, fd); // intro + outro zones stay whole
            if d > Time::ZERO && right.animation_zone_lengths().is_some() {
                d = d.min((right.duration() - right.minimum_duration(fd)).max(Time::ZERO));
            }
            if d <= -left.duration() || d >= right.duration() {
                return Err(EditError::EmptyClip);
            }
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for (ti, left, right) in pairs {
            let (mut l, mut r) = (left, right);
            l.extend_tail(d);
            r.start += d;
            r.extend_head(Time::ZERO - d);
            work[ti].replace(l);
            work[ti].replace(r);
        }
        for (ti, c) in tails {
            let mut n = c;
            n.extend_tail(d);
            work[ti].replace(n);
        }
        for (ti, c) in heads {
            let mut n = c;
            n.start += d;
            n.extend_head(Time::ZERO - d);
            work[ti].replace(n);
        }
        self.tracks = commit(work)?;
        Ok(d)
    }

    fn slip(&mut self, id: Id, delta: Time, keyframes: SlipKeyframes) -> Result<Time, EditError> {
        let group = self.linked_group(id)?;
        require_unlocked(self, &group)?;
        let mut d = delta;
        for m in &group {
            let c = &m.clip;
            if c.is_generator() || c.is_still {
                d = Time::ZERO; // nothing to slip
                continue;
            }
            if c.speed_keys.is_some() {
                d = Time::ZERO; // remapped: the source range is the speed track
                continue;
            }
            let before = c.speed.unscale(c.source.start); // room for earlier source
            let after = c.media_duration.map(|m| c.speed.unscale(m - c.source.end())); // room for later source
            if c.reversed {
                d = d.min(before);
                if let Some(after) = after {
                    d = d.max(Time::ZERO - after);
                }
            } else {
                d = d.max(Time::ZERO - before);
                if let Some(after) = after {
                    d = d.min(after);
                }
            }
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for m in &group {
            let mut c = m.clip.clone();
            let moved = c.speed.scale(d);
            c.source.start += if c.reversed { Time::ZERO - moved } else { moved };
            if keyframes == SlipKeyframes::FollowContent {
                // keys are clip-local: the content moved by -d inside the clip
                c.animation = c.animation.shifted(Time::ZERO - d);
                c.effects = c.effects.iter().map(|e| e.shifted(Time::ZERO - d)).collect();
                c.shift_variant_keys(Time::ZERO - d);
            }
            work[m.track].replace(c);
        }
        self.tracks = commit(work)?;
        Ok(d)
    }

    fn move_clip(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        retarget: &BTreeMap<Id, Id>,
        copy: Option<&CopySpec>,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let group = self.linked_group(id)?;
        require_unlocked(self, &group)?;
        let mut destinations: Vec<usize> = group.iter().map(|m| m.track).collect();
        if let Some(target) = target {
            let ti = self.tracks.iter().position(|t| t.id == target).ok_or(EditError::ClipNotFound)?;
            if self.tracks[ti].kind != group[0].clip.kind {
                return Err(EditError::WrongTrackKind);
            }
            if self.tracks[ti].is_locked {
                return Err(EditError::TrackLocked);
            }
            destinations[0] = ti;
        }
        // Linked partners may move to their own tracks (Premiere mirrors a video track change on the audio side).
        for (i, m) in group.iter().enumerate() {
            let Some(partner_target) = retarget.get(&m.clip.id) else { continue };
            let ti = self.tracks.iter().position(|t| t.id == *partner_target).ok_or(EditError::ClipNotFound)?;
            if self.tracks[ti].kind != m.clip.kind {
                return Err(EditError::WrongTrackKind);
            }
            if self.tracks[ti].is_locked {
                return Err(EditError::TrackLocked);
            }
            destinations[i] = ti;
        }
        let mut d = start - group[0].clip.start;
        for m in &group {
            d = d.max(Time::ZERO - m.clip.start);
        }
        if d == Time::ZERO && destinations.iter().copied().eq(group.iter().map(|m| m.track)) {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        // Copy (Option-drag): the originals stay, the copies get new identities and one new link per group.
        if copy.is_none() {
            for m in &group {
                work[m.track].remove(m.clip.id);
            }
        }
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        for (m, ti) in group.iter().zip(destinations) {
            let mut c = m.clip.clone();
            if let Some(copy) = copy {
                c.id = copy.ids.get(&m.clip.id).copied().unwrap_or_else(|| ids.next_id());
                if c.link.is_some() {
                    c.link = Some(copy.link);
                }
                c.bundle = None; // a copy never joins the original's bundle
            }
            c.start += d;
            work[ti].overwrite_relinking(c, &mut relinks, ids)?;
        }
        self.tracks = commit(work)?;
        Ok(d)
    }
}

/// Builders shared by the tests of the edit modules.
#[cfg(test)]
pub(crate) mod fixtures {
    use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{Id, Time, TimeRange};

    pub fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    pub fn r(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(s(a), s(b))
    }

    pub fn fresh() -> u128 {
        thread_local!(static NEXT: std::cell::Cell<u128> = const { std::cell::Cell::new(1_000_000) });
        NEXT.with(|c| {
            c.set(c.get() + 1);
            c.get()
        })
    }

    pub fn link() -> Id {
        Id::from_u128(fresh())
    }

    /// Ids that never repeat inside a test thread, also across several edits.
    pub struct FreshIds;

    impl sq_core_time::IdSource for FreshIds {
        fn next_id(&mut self) -> Id {
            Id::from_u128(fresh())
        }
    }

    /// A clip; `media` is the media length in seconds when limited.
    pub fn clip(start: i64, dur: i64, src: i64, kind: TrackKind, link: Option<Id>, media: Option<i64>) -> Clip {
        let n = fresh();
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5_000_000),
            kind,
            TimeRange::new(s(src), s(dur)),
            s(start),
        );
        c.link = link;
        c.media_duration = media.map(s);
        c
    }

    pub fn v(start: i64, dur: i64) -> Clip {
        clip(start, dur, 0, TrackKind::Video, None, None)
    }

    pub fn a(start: i64, dur: i64) -> Clip {
        clip(start, dur, 0, TrackKind::Audio, None, None)
    }

    pub fn track(kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(fresh()), kind);
        t.set_clips(clips);
        t
    }

    pub fn locked(mut t: Track) -> Track {
        t.is_locked = true;
        t
    }

    pub fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(fresh()), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    /// Start and end seconds of every clip of the track.
    pub fn spans(t: &Track) -> Vec<[i64; 2]> {
        let secs = |t: Time| t.value() / t.timescale();
        t.clips().iter().map(|c| [secs(c.start), secs(c.timeline().end())]).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::{SequentialIds, TimeRange};

    fn consistent(tl: &Timeline) -> bool {
        tl.tracks.iter().all(Track::is_consistent)
    }

    // MARK: Trim

    #[test]
    fn shorten_tail_leaves_gap() {
        let (a, b) = (v(0, 4), v(4, 2));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b])]);
        assert_eq!(tl.trim(a.id, ClipEdge::Tail, s(-1)), Ok(s(-1)));
        assert_eq!(tl.tracks[0].clips()[0].timeline(), r(0, 3));
        assert_eq!(tl.tracks[0].clips()[1].start, s(4));
    }

    #[test]
    fn head_trim_advances_start_and_source() {
        let a = clip(2, 4, 1, Video, None, None);
        let mut tl = timeline(vec![track(Video, vec![a.clone()])]);
        assert_eq!(tl.trim(a.id, ClipEdge::Head, s(1)), Ok(s(1)));
        let c = &tl.tracks[0].clips()[0];
        assert_eq!((c.start, c.source), (s(3), TimeRange::new(s(2), s(3))));
    }

    #[test]
    fn extend_tail_clamped_by_neighbour_and_media() {
        let (a, b) = (clip(0, 2, 0, Video, None, Some(10)), v(5, 1));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b])]);
        assert_eq!(tl.trim(a.id, ClipEdge::Tail, s(9)), Ok(s(3)));
        let c = clip(0, 2, 0, Video, None, Some(4));
        let mut t2 = timeline(vec![track(Video, vec![c.clone()])]);
        assert_eq!(t2.trim(c.id, ClipEdge::Tail, s(9)), Ok(s(2)));
    }

    #[test]
    fn extend_head_clamped_by_source_start_neighbour_and_zero() {
        let (a, p) = (clip(3, 2, 5, Video, None, None), v(0, 2));
        let mut tl = timeline(vec![track(Video, vec![p, a.clone()])]);
        assert_eq!(tl.trim(a.id, ClipEdge::Head, s(-9)), Ok(s(-1))); // neighbor end 2
        let b = clip(1, 2, 4, Video, None, None);
        let mut t2 = timeline(vec![track(Video, vec![b.clone()])]);
        assert_eq!(t2.trim(b.id, ClipEdge::Head, s(-9)), Ok(s(-1))); // timeline start 0
        let c = clip(5, 2, 1, Video, None, None);
        let mut t3 = timeline(vec![track(Video, vec![c.clone()])]);
        assert_eq!(t3.trim(c.id, ClipEdge::Head, s(-9)), Ok(s(-1))); // source start 0
    }

    #[test]
    fn trim_refuses_to_empty_a_clip() {
        let a = v(0, 2);
        let mut tl = timeline(vec![track(Video, vec![a.clone()])]);
        assert_eq!(tl.trim(a.id, ClipEdge::Tail, s(-2)), Err(EditError::EmptyClip));
    }

    #[test]
    fn partner_follows_and_most_restrictive_wins() {
        let l = link();
        let vc = clip(0, 2, 0, Video, Some(l), None);
        let au = clip(0, 2, 0, Audio, Some(l), Some(3));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        assert_eq!(tl.trim(vc.id, ClipEdge::Tail, s(5)), Ok(s(1)));
        assert_eq!(tl.tracks[0].clips()[0].source.duration, s(3));
        assert_eq!(tl.tracks[1].clips()[0].source.duration, s(3));
    }

    #[test]
    fn locked_partner_track_refuses_and_nothing_changes() {
        let l = link();
        let (vc, au) = (clip(0, 2, 0, Video, Some(l), None), clip(0, 2, 0, Audio, Some(l), None));
        let tl0 = timeline(vec![track(Video, vec![vc.clone()]), locked(track(Audio, vec![au]))]);
        let mut tl = tl0.clone();
        assert_eq!(tl.trim(vc.id, ClipEdge::Tail, s(1)), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
    }

    // MARK: Roll

    #[test]
    fn roll_moves_cut_both_ways() {
        let (a, b) = (clip(0, 3, 0, Video, None, Some(10)), clip(3, 3, 2, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b])]);
        assert_eq!(tl.roll(a.id, s(1)), Ok(s(1)));
        assert_eq!(tl.tracks[0].clips()[0].timeline().end(), s(4));
        assert_eq!((tl.tracks[0].clips()[1].start, tl.tracks[0].clips()[1].source.start), (s(4), s(3)));
        assert_eq!(tl.roll(a.id, s(-2)), Ok(s(-2)));
        assert_eq!((tl.tracks[0].clips()[1].start, tl.tracks[0].clips()[1].source.start), (s(2), s(1)));
        assert!(consistent(&tl));
    }

    #[test]
    fn roll_is_clamped_by_media() {
        let (a, b) = (clip(0, 3, 0, Video, None, Some(4)), clip(3, 3, 1, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b])]);
        assert_eq!(tl.roll(a.id, s(5)), Ok(s(1))); // left media
        assert_eq!(tl.roll(a.id, s(-5)), Ok(s(-2))); // right source start now 2
    }

    #[test]
    fn roll_refuses_emptying_and_needs_an_adjacent_clip() {
        let (a, b, c) = (v(0, 2), clip(2, 2, 5, Video, None, None), v(5, 1));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b.clone(), c])]);
        assert_eq!(tl.roll(a.id, s(2)), Err(EditError::EmptyClip));
        assert_eq!(tl.roll(a.id, s(-2)), Err(EditError::EmptyClip));
        assert_eq!(tl.roll(b.id, s(1)), Err(EditError::Collision));
    }

    #[test]
    fn partners_roll_when_they_have_the_same_cut() {
        let l = link();
        let vc = clip(0, 3, 0, Video, Some(l), Some(10));
        let au = clip(0, 3, 0, Audio, Some(l), Some(10));
        let (v2, au2) = (clip(3, 2, 2, Video, None, None), clip(3, 2, 2, Audio, None, None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone(), v2]), track(Audio, vec![au, au2])]);
        assert_eq!(tl.roll(vc.id, s(1)), Ok(s(1)));
        assert_eq!((tl.tracks[1].clips()[0].timeline().end(), tl.tracks[1].clips()[1].start), (s(4), s(4)));
    }

    #[test]
    fn partner_without_neighbour_follows_with_its_own_edge() {
        let l = link();
        let vc = clip(0, 3, 0, Video, Some(l), Some(10));
        let au = clip(0, 3, 0, Audio, Some(l), Some(10));
        let mut tl =
            timeline(vec![track(Video, vec![vc.clone(), clip(3, 2, 2, Video, None, None)]), track(Audio, vec![au])]);
        assert_eq!(tl.roll(vc.id, s(1)), Ok(s(1)));
        assert_eq!(tl.tracks[1].clips()[0].timeline().end(), s(4)); // stays in sync with the cut
        assert_eq!(tl.roll(vc.id, s(-2)), Ok(s(-2)));
        assert_eq!(tl.tracks[1].clips()[0].timeline().end(), s(2));
    }

    #[test]
    fn right_clip_partner_with_gap_before_it_follows() {
        let l = link();
        let a = clip(0, 10, 0, Video, None, Some(20));
        let b = clip(10, 4, 2, Video, Some(l), None);
        let b_audio = clip(10, 4, 2, Audio, Some(l), None);
        let a_audio = clip(0, 8, 0, Audio, None, Some(20));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b]), track(Audio, vec![a_audio, b_audio])]);
        assert_eq!(tl.roll(a.id, s(-1)), Ok(s(-1)));
        assert_eq!(tl.tracks[0].clips()[1].start, s(9));
        assert_eq!(tl.tracks[1].clips()[1].start, s(9)); // b follows B, its head moved too
        assert!(consistent(&tl));
    }

    #[test]
    fn partner_media_and_gap_limit_the_roll() {
        let l = link();
        let vc = clip(0, 3, 0, Video, Some(l), Some(10));
        let au = clip(0, 3, 0, Audio, Some(l), Some(4));
        let mut tl =
            timeline(vec![track(Video, vec![vc.clone(), clip(3, 2, 2, Video, None, None)]), track(Audio, vec![au])]);
        assert_eq!(tl.roll(vc.id, s(5)), Ok(s(1))); // audio has one second of media left
        let au2 = clip(0, 3, 0, Audio, Some(l), Some(10));
        let next = a(4, 1);
        let mut tl2 = timeline(vec![
            track(Video, vec![vc.clone(), clip(3, 2, 2, Video, None, None)]),
            track(Audio, vec![au2, next]),
        ]);
        assert_eq!(tl2.roll(vc.id, s(3)), Ok(s(1))); // the next audio clip starts at 4
        assert!(consistent(&tl2));
    }

    #[test]
    fn roll_on_a_locked_track_refuses() {
        let (x, y) = (v(0, 2), v(2, 2));
        let tl0 = timeline(vec![locked(track(Video, vec![x.clone(), y]))]);
        let mut tl = tl0.clone();
        assert_eq!(tl.roll(x.id, s(1)), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
    }

    // MARK: Slip

    #[test]
    fn slip_moves_the_source_and_clamps() {
        let x = clip(2, 3, 1, Video, None, Some(8));
        let mut tl = timeline(vec![track(Video, vec![x.clone()])]);
        assert_eq!(tl.slip(x.id, s(2), SlipKeyframes::FollowContent), Ok(s(2)));
        assert_eq!((tl.tracks[0].clips()[0].source.start, tl.tracks[0].clips()[0].start), (s(3), s(2)));
        assert_eq!(tl.slip(x.id, s(9), SlipKeyframes::FollowContent), Ok(s(2))); // 8 - 3 - 3
        assert_eq!(tl.slip(x.id, s(-9), SlipKeyframes::FollowContent), Ok(s(-5))); // back to 0
    }

    #[test]
    fn slip_partner_follows_with_tightest_clamp() {
        let l = link();
        let (vc, au) = (clip(0, 2, 1, Video, Some(l), None), clip(0, 2, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        assert_eq!(tl.slip(vc.id, s(-1), SlipKeyframes::Stay), Ok(s(0))); // audio at 0
        assert_eq!(tl.slip(vc.id, s(2), SlipKeyframes::Stay), Ok(s(2)));
        assert_eq!(tl.tracks[1].clips()[0].source.start, s(2));
    }

    #[test]
    fn slip_on_a_locked_track_refuses() {
        let x = clip(0, 2, 1, Video, None, None);
        let tl0 = timeline(vec![locked(track(Video, vec![x.clone()]))]);
        let mut tl = tl0.clone();
        assert_eq!(tl.slip(x.id, s(1), SlipKeyframes::FollowContent), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
    }

    // MARK: Move

    #[test]
    fn move_into_gap() {
        let x = v(0, 2);
        let mut tl = timeline(vec![track(Video, vec![x.clone(), v(6, 1)])]);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.move_clip(x.id, s(3), None, &BTreeMap::new(), None, &mut ids), Ok(s(3)));
        assert_eq!(tl.tracks[0].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [s(3), s(6)]);
    }

    #[test]
    fn move_overwrites_covered_clips() {
        let (x, b) = (v(0, 2), v(3, 4));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), b])]);
        let mut ids = SequentialIds::default();
        tl.move_clip(x.id, s(4), None, &BTreeMap::new(), None, &mut ids).ok();
        let cs = tl.tracks[0].clips();
        assert_eq!(cs.len(), 3);
        assert_eq!(cs[0].timeline(), TimeRange::new(s(3), s(1)));
        assert_eq!((cs[1].id, cs[1].start), (x.id, s(4)));
        assert_eq!((cs[2].timeline(), cs[2].source.start), (TimeRange::new(s(6), s(1)), s(3)));
        assert!(consistent(&tl));
    }

    #[test]
    fn move_is_clamped_at_zero_including_partners() {
        let l = link();
        let (vc, au) = (clip(4, 2, 0, Video, Some(l), None), clip(2, 2, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.move_clip(vc.id, s(-5), None, &BTreeMap::new(), None, &mut ids), Ok(s(-2)));
        assert_eq!((tl.tracks[0].clips()[0].start, tl.tracks[1].clips()[0].start), (s(2), s(0)));
    }

    #[test]
    fn primary_changes_track_and_partner_keeps_its_own() {
        let l = link();
        let (vc, au) = (clip(0, 2, 0, Video, Some(l), None), clip(0, 2, 0, Audio, Some(l), None));
        let (v1, v2) = (track(Video, vec![vc.clone()]), track(Video, vec![]));
        let v2_id = v2.id;
        let mut tl = timeline(vec![v1, v2, track(Audio, vec![au])]);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.move_clip(vc.id, s(5), Some(v2_id), &BTreeMap::new(), None, &mut ids), Ok(s(5)));
        assert!(tl.tracks[0].clips().is_empty());
        assert_eq!(tl.tracks[1].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [s(5)]);
        assert_eq!(tl.tracks[2].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [s(5)]);
    }

    #[test]
    fn wrong_kind_and_locked_targets_are_refused() {
        let x = v(0, 2);
        let (audio, locked_v) = (track(Audio, vec![]), locked(track(Video, vec![])));
        let (audio_id, locked_id) = (audio.id, locked_v.id);
        let tl0 = timeline(vec![track(Video, vec![x.clone()]), audio, locked_v]);
        let mut tl = tl0.clone();
        let mut ids = SequentialIds::default();
        let none = BTreeMap::new();
        assert_eq!(tl.move_clip(x.id, s(1), Some(audio_id), &none, None, &mut ids), Err(EditError::WrongTrackKind));
        assert_eq!(tl.move_clip(x.id, s(1), Some(locked_id), &none, None, &mut ids), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
    }

    #[test]
    fn move_with_a_locked_partner_track_refuses_and_an_unknown_clip_is_not_found() {
        let l = link();
        let (vc, au) = (clip(0, 2, 0, Video, Some(l), None), clip(0, 2, 0, Audio, Some(l), None));
        let tl0 = timeline(vec![track(Video, vec![vc.clone()]), locked(track(Audio, vec![au]))]);
        let mut tl = tl0.clone();
        let mut ids = SequentialIds::default();
        let none = BTreeMap::new();
        assert_eq!(tl.move_clip(vc.id, s(3), None, &none, None, &mut ids), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
        assert_eq!(tl.move_clip(Id::from_u128(7), s(1), None, &none, None, &mut ids), Err(EditError::ClipNotFound));
    }

    #[test]
    fn copy_keeps_the_originals_and_gives_the_copies_their_ids() {
        let l = link();
        let (vc, au) = (clip(0, 2, 0, Video, Some(l), None), clip(0, 2, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au.clone()])]);
        let spec = CopySpec { ids: BTreeMap::from([(vc.id, Id::from_u128(41))]), link: Id::from_u128(50) };
        let mut ids = SequentialIds::default();
        assert_eq!(tl.move_clip(vc.id, s(5), None, &BTreeMap::new(), Some(&spec), &mut ids), Ok(s(5)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [5, 7]]);
        assert_eq!(tl.tracks[0].clips()[1].id, Id::from_u128(41));
        assert_eq!(tl.tracks[0].clips()[1].link, Some(Id::from_u128(50)));
        assert_eq!(tl.tracks[1].clips()[0].id, au.id);
    }
}
