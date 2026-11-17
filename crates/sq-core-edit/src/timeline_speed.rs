// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Speed.swift (Rate Stretch, SpeedChange; `set_speed` and `set_duration` live in sq-core-model)

use sq_core_model::{Clip, ClipEdge, ClipSpeed, EditError, TimeInterpolation, Timeline, media_frames};
use sq_core_time::{Id, Time};
use std::collections::{BTreeMap, BTreeSet};

/// One Speed/Duration dialog result (or script/replay step): what to change on a clip and its linked partners.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpeedChange {
    /// New speed. Ignored when `duration` is set.
    pub speed: Option<ClipSpeed>,
    /// New timeline duration; the speed follows (Premiere: the duration field).
    pub duration: Option<Time>,
    /// Play backwards (`None` = unchanged).
    pub reversed: Option<bool>,
    /// Keep the pitch (`None` = unchanged).
    pub keeps_pitch: Option<bool>,
    /// Ripple Edit, Shifting Trailing Clips.
    pub ripple: bool,
    /// Speed typed with the link between speed and duration broken: the clip keeps its length and shows more or less media.
    pub holding_duration: bool,
    /// Time Interpolation (Frame Sampling / Frame Blending), stored on the clip. `None` = unchanged.
    pub time_interpolation: Option<TimeInterpolation>,
}

/// Rate Stretch, and the dialog-level speed verbs.
pub trait TimelineSpeedExt {
    /// Rate Stretch: moves an edge like a trim, but the source range stays and the speed changes so the clip fills the new
    /// length. The clip can only grow into free space (neighbors and time 0 limit it); nothing ripples. `delta` is the edge
    /// movement in timeline time (tail + = longer, head + = shorter). Returns how far the edge moved.
    fn rate_stretch(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError>;

    /// Applies `change` to the clip (and its linked partners). Returns the change of the clip's timeline duration.
    fn apply_speed_change(&mut self, change: &SpeedChange, id: Id) -> Result<Time, EditError>;

    /// Time Interpolation of a clip and its linked partners.
    fn set_time_interpolation(&mut self, id: Id, ti: TimeInterpolation) -> Result<(), EditError>;

    /// Applies `change` to every clip of `ids` (a linked pair counts once). Refuses the whole edit when any clip cannot be
    /// retimed or a track is locked; the timeline is unchanged then.
    fn apply_speed_change_to_all(&mut self, change: &SpeedChange, ids: &[Id]) -> Result<(), EditError>;
}

/// The group at one primary length: one speed, each member's own length (whole frames).
struct RatePlan {
    speed: ClipSpeed,
    lengths: BTreeMap<Id, Time>,
}

/// Whole frames of `t` (nearest).
fn frames(t: Time, fd: Time) -> i64 {
    t.snapped(fd).frame_index(fd)
}

impl TimelineSpeedExt for Timeline {
    fn rate_stretch(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError> {
        let group = self.retime_group(id)?;
        let fd = self.frame_duration();
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let primary = group[0].clip.clone();
        let change = if edge == ClipEdge::Tail { delta } else { Time::ZERO - delta };
        // The group at primary length `n` frames. `None` when a member would leave its free space.
        let layout = |n: i64| -> Option<RatePlan> {
            let tl = fd * n;
            let speed = ClipSpeed::from_source_over(primary.retime_span(), tl);
            let per_frame = speed.scale(fd);
            let mut lengths: BTreeMap<Id, Time> = BTreeMap::new();
            for m in &group {
                let c = &m.clip;
                // The primary gets exactly `n` unless the speed range clamped the speed.
                let mut k = frames(speed.unscale(c.retime_span()), fd).max(1);
                if let Some(keys) = &c.speed_keys {
                    k = keys.clamped_duration(fd * k, fd).frame_index(fd);
                }
                // Media: the source kept may round up past the media end by part of a frame; it is cut to whole frames.
                // Under one frame of media at this speed: this length does not fit (a longer one, slower, may).
                if let Some(room) = media_frames(c, per_frame) {
                    if room < 1 {
                        return None;
                    }
                    k = k.min(room);
                }
                let others = self.tracks[m.track].clips().iter().filter(|o| !ids.contains(&o.id));
                if edge == ClipEdge::Tail {
                    let next = others.filter(|o| o.start >= c.timeline().end()).map(|o| o.start).min();
                    if let Some(next) = next
                        && k > (next - c.start).frame_index(fd).max(1)
                    {
                        return None;
                    }
                } else {
                    let prev_end = others.filter(|o| o.timeline().end() <= c.start).map(|o| o.timeline().end()).max();
                    if k > (c.timeline().end() - prev_end.unwrap_or(Time::ZERO)).frame_index(fd).max(1) {
                        return None;
                    }
                }
                lengths.insert(c.id, fd * k);
            }
            Some(RatePlan { speed, lengths })
        };
        // The longest primary length up to the request at which every member fits (fitting only gets easier as the group
        // shrinks: every member gets shorter and needs less room).
        let wanted = frames(primary.duration() + change, fd).max(1);
        let mut plan = layout(wanted);
        let current = frames(primary.duration(), fd).max(1);
        if plan.is_none() && wanted < current && layout(current).is_some() {
            // Shrinking can only fail on media (a partner runs out at the higher speed), which eases as the length grows:
            // the shortest length between the request and now that fits.
            let (mut lo, mut hi) = (wanted, current);
            while lo < hi {
                let mid = lo + (hi - lo) / 2;
                if layout(mid).is_some() {
                    hi = mid;
                } else {
                    lo = mid + 1;
                }
            }
            plan = layout(hi);
        }
        if plan.is_none() {
            let (mut lo, mut hi) = (1_i64, wanted);
            if wanted > current && layout(current).is_some() {
                lo = current; // growing: the current length still fits
            }
            let mut best = layout(lo);
            while lo < hi {
                let mid = lo + (hi - lo + 1) / 2;
                if let Some(p) = layout(mid) {
                    best = Some(p);
                    lo = mid;
                } else {
                    hi = mid - 1;
                }
            }
            plan = best;
        }
        let plan = plan.ok_or(EditError::Collision)?;
        let new_duration = *plan.lengths.get(&primary.id).ok_or(EditError::Collision)?;
        let speed = plan.speed;
        let applied =
            if edge == ClipEdge::Tail { new_duration - primary.duration() } else { primary.duration() - new_duration };
        if applied == Time::ZERO && speed == primary.speed && primary.speed_keys.is_none() {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for m in &group {
            let mut c: Clip = m.clip.clone();
            let length = *plan.lengths.get(&c.id).ok_or(EditError::Collision)?;
            if let Some(keys) = c.speed_keys.clone() {
                let scaled = keys.scaled(length, fd);
                c.set_speed_keys(Some(scaled.fitting(c.media_duration, fd).unwrap_or(scaled)));
            } else {
                c.speed = speed;
                let src_dur = speed.scale(length);
                if c.reversed {
                    c.source.start = c.source.end() - src_dur;
                }
                c.source.duration = src_dur;
            }
            c.rescale_keys(m.clip.duration(), length, false);
            if edge == ClipEdge::Head {
                c.start = m.clip.timeline().end() - length;
            }
            work[m.track].replace(c);
        }
        if !work.iter().all(sq_core_model::Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(applied)
    }

    fn apply_speed_change(&mut self, change: &SpeedChange, id: Id) -> Result<Time, EditError> {
        let c = self.find(id).ok_or(EditError::ClipNotFound)?.clip;
        let mut work = self.clone();
        let result = if let Some(d) = change.duration {
            work.set_duration(id, d, change.reversed, change.keeps_pitch, change.ripple)?
        } else {
            work.set_speed(
                id,
                change.speed.unwrap_or_else(|| c.average_speed()),
                change.reversed,
                change.keeps_pitch,
                change.ripple,
                change.holding_duration,
            )?
        };
        if let Some(ti) = change.time_interpolation {
            work.set_time_interpolation(id, ti)?;
        }
        *self = work;
        Ok(result)
    }

    fn set_time_interpolation(&mut self, id: Id, ti: TimeInterpolation) -> Result<(), EditError> {
        let group = self.retime_group(id)?;
        for m in group.iter().filter(|m| m.clip.time_interpolation != ti) {
            let mut c = m.clip.clone();
            c.time_interpolation = ti;
            self.tracks[m.track].replace(c);
        }
        Ok(())
    }

    fn apply_speed_change_to_all(&mut self, change: &SpeedChange, ids: &[Id]) -> Result<(), EditError> {
        let mut work = self.clone();
        let mut done: BTreeSet<Id> = BTreeSet::new();
        for id in ids {
            if done.contains(id) {
                continue;
            }
            done.extend(work.linked_group(*id)?.iter().map(|m| m.clip.id));
            work.apply_speed_change(change, *id)?;
        }
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};

    #[test]
    fn rate_stretch_fills_the_new_length_by_changing_the_speed() {
        let x = clip(0, 4, 0, Video, None, Some(100));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), v(20, 2)])]);
        assert_eq!(tl.rate_stretch(x.id, ClipEdge::Tail, s(4)), Ok(s(4)));
        let c = &tl.tracks[0].clips()[0];
        assert_eq!((c.timeline(), c.source, c.speed), (r(0, 8), x.source, ClipSpeed::new(1, 2)));
        // the neighbor limits growth: 12 seconds of room before the clip at 20
        assert_eq!(tl.rate_stretch(x.id, ClipEdge::Tail, s(100)), Ok(s(12)));
        assert_eq!(tl.tracks[0].clips()[0].timeline().end(), s(20));
    }

    #[test]
    fn rate_stretch_on_the_head_keeps_the_end_and_moves_the_start() {
        let x = clip(10, 4, 0, Video, None, Some(100));
        let mut tl = timeline(vec![track(Video, vec![x.clone()])]);
        assert_eq!(tl.rate_stretch(x.id, ClipEdge::Head, s(-4)), Ok(s(-4))); // the edge moved earlier
        let c = &tl.tracks[0].clips()[0];
        assert_eq!((c.timeline(), c.speed), (r(6, 14), ClipSpeed::new(1, 2)));
        assert_eq!(tl.rate_stretch(x.id, ClipEdge::Head, s(-100)), Ok(s(-6))); // time 0 limits it
    }

    #[test]
    fn rate_stretch_refuses_generators_and_locked_tracks() {
        let x = v(0, 2);
        let tl0 = timeline(vec![locked(track(Video, vec![x.clone()]))]);
        let mut tl = tl0.clone();
        assert_eq!(tl.rate_stretch(x.id, ClipEdge::Tail, s(1)), Err(EditError::TrackLocked));
        assert_eq!(tl, tl0);
    }

    #[test]
    fn a_speed_change_applies_to_the_clip_and_its_partner_once() {
        let l = link();
        let (vc, au) = (clip(0, 4, 0, Video, Some(l), Some(100)), clip(0, 4, 0, Audio, Some(l), Some(100)));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au.clone()])]);
        let change = SpeedChange { speed: Some(ClipSpeed::new(2, 1)), ..Default::default() };
        assert_eq!(tl.apply_speed_change_to_all(&change, &[vc.id, au.id]), Ok(()));
        for t in &tl.tracks {
            assert_eq!((t.clips()[0].duration(), t.clips()[0].speed), (s(2), ClipSpeed::new(2, 1)));
        }
        let by_duration = SpeedChange { duration: Some(s(8)), ..Default::default() };
        assert_eq!(tl.apply_speed_change(&by_duration, vc.id), Ok(s(6)));
        assert_eq!(tl.tracks[0].clips()[0].speed, ClipSpeed::new(1, 2));
    }

    #[test]
    fn time_interpolation_goes_to_the_whole_group() {
        let l = link();
        let (vc, au) = (clip(0, 4, 0, Video, Some(l), None), clip(0, 4, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        let change = SpeedChange {
            time_interpolation: Some(TimeInterpolation::FrameBlend),
            speed: Some(ClipSpeed::NORMAL),
            ..Default::default()
        };
        assert_eq!(tl.apply_speed_change(&change, vc.id), Ok(Time::ZERO));
        assert!(tl.tracks.iter().all(|t| t.clips()[0].time_interpolation == TimeInterpolation::FrameBlend));
    }
}
