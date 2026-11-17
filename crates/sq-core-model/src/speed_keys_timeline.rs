// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeysTimeline.swift

use crate::{ClipSpeed, EditError, SpeedKeys, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

impl SpeedKeys {
    /// Cuts frames off the tail until every source time the track visits lies inside `0 ..= media` (`None` = unbounded
    /// above). Returns `None` when not even one frame fits. Every candidate is one slice of `self` (never a slice of a
    /// slice), so an eased ramp is re-pieced once, not per frame.
    #[doc(hidden)]
    pub fn fitting(&self, media: Option<Time>, fd: Time) -> Option<SpeedKeys> {
        let mut k = self.clone();
        let mut steps: i64 = 0;
        loop {
            let h = k.hull();
            if h.start >= Time::ZERO && media.is_none_or(|m| h.end() <= m) {
                return Some(k);
            }
            if !(k.duration() > fd && steps < 100_000) {
                return None;
            }
            steps += 1;
            k = self.sliced(Time::ZERO, self.duration() - fd * steps);
        }
    }

    /// A single constant segment as the plain constant-speed fields of a clip (`speed_keys` none), or `None` for a real
    /// track.
    pub(crate) fn as_constant(&self) -> Option<(ClipSpeed, bool, TimeRange)> {
        if self.segments.len() != 1 || self.segments[0].is_ramp() {
            return None;
        }
        let s = &self.segments[0];
        let span = s.from.scale(self.duration());
        let source =
            if s.reversed { TimeRange::new(self.origin - span, span) } else { TimeRange::new(self.origin, span) };
        Some((s.from, s.reversed, source))
    }
}

impl Timeline {
    /// Applies a speed-track edit to a clip and its linked partners (video and audio get the same segments, each its own
    /// origin) as one change. `edit` receives the clip's track (a constant clip is one segment) and returns the new track,
    /// or `None` for "nothing to do". The result is normalized; a single constant segment turns the clip back into a
    /// constant-speed clip (`speed_keys` none), so a track that was edited back to one speed equals an untouched clip.
    ///
    /// The clip's start stays. A clip that grows only grows into free space (neighbors stop it, like Rate Stretch); the
    /// media limits the tail the same way. Clip-local keyframes and effect keys stay on their timeline frames: only a
    /// constant speed change scales them. Returns the change of the clip's timeline duration.
    ///
    /// `refuse_shortening`: a track whose source would leave the media is refused (collision) instead of losing its tail.
    ///
    /// `keeping_keys` (the Effect Controls diamond): a track that only has keys without a speed change stays keyed instead
    /// of collapsing to a constant clip. A track that already is such a keyed uniform track never collapses either, so
    /// later edits keep those keys; only deleting them (or Remove Time Remapping) makes the clip plain again. A drag that
    /// replays its edit on every mouse move passes `keeping_keys` decided from the track at mouse-down, so its steps do
    /// not matter.
    pub fn edit_speed_keys(
        &mut self,
        id: Id,
        keeping_keys: bool,
        refuse_shortening: bool,
        edit: impl FnOnce(&SpeedKeys) -> Option<SpeedKeys>,
    ) -> Result<Time, EditError> {
        let group = self.retime_group(id)?;
        let fd = self.frame_duration();
        let primary = group[0].clip.clone();
        let base = SpeedKeys::of(&primary);
        let collapse = !keeping_keys && !(base.segments.len() > 1 && base.is_uniform());
        // An edit that changed nothing (e.g. a gesture on a segment that is not there) leaves the clip as it is.
        let Some(edited) = edit(&base).map(|e| e.normalized(collapse)).filter(|e| *e != base.normalized(false)) else {
            return Ok(Time::ZERO);
        };
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();

        // Shared length: the most restrictive member (free space after the clip).
        let mut limit = edited.duration();
        for m in &group {
            let next = self.tracks[m.track]
                .clips()
                .iter()
                .filter(|c| !ids.contains(&c.id) && c.start >= m.clip.timeline().end())
                .min_by_key(|c| c.start);
            if let Some(next) = next {
                limit = limit.min((next.start - m.clip.start).max(fd));
            }
        }
        let mut shared = edited;
        let n = limit.frame_index(fd).max(1);
        if shared.duration() > fd * n {
            shared = shared.sliced(Time::ZERO, fd * n);
        }

        let mut tracks_out = Vec::new();
        let mut new_duration = shared.duration();
        for m in &group {
            let own = SpeedKeys::of(&m.clip);
            let k = SpeedKeys::new(shared.segments.clone(), own.origin + (shared.origin - base.origin));
            let fit = k.fitting(m.clip.media_duration, fd).ok_or(EditError::Collision)?;
            // A value edit keeps the timeline length: refuse instead of cutting the tail off at the media end.
            if refuse_shortening && fit.duration() < k.duration() {
                return Err(EditError::Collision);
            }
            new_duration = new_duration.min(fit.duration());
            tracks_out.push((m.track, m.clip.clone(), fit));
        }
        let mut work = self.tracks.clone();
        for (track, mut c, keys) in tracks_out {
            let k = if keys.duration() > new_duration { keys.sliced(Time::ZERO, new_duration) } else { keys };
            if let Some((speed, reversed, source)) = k.as_constant() {
                c.speed_keys = None;
                c.speed = speed;
                c.reversed = reversed;
                c.source = source;
            } else {
                c.set_speed_keys(Some(k));
            }
            work[track].replace(c);
        }
        if !work.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(new_duration - primary.duration())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Clip, SequenceFormat, SpeedSegment, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds};

    const FD: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn clip(n: u128, start: i64, frames: i64, kind: TrackKind) -> Clip {
        let mut c =
            Clip::new(Id::from_u128(n), "c", Id::from_u128(100 + n), kind, TimeRange::new(f(0), f(frames)), f(start));
        c.media_duration = Some(f(6000));
        c
    }

    fn timeline(tracks: Vec<Vec<Clip>>) -> Timeline {
        let mut ids = SequentialIds::default();
        let tracks = tracks
            .into_iter()
            .map(|cs| {
                let mut t = Track::new(ids.next_id(), cs.first().map_or(TrackKind::Video, |c| c.kind));
                for c in cs {
                    t.overwrite(c, &mut ids).unwrap();
                }
                t
            })
            .collect();
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(FD), tracks)
    }

    fn double_speed(k: &SpeedKeys) -> Option<SpeedKeys> {
        Some(SpeedKeys::new(
            vec![SpeedSegment::constant(k.duration(), ClipSpeed::from_percent(200.0), false)],
            k.origin,
        ))
    }

    #[test]
    fn a_constant_edit_turns_back_into_the_plain_fields() {
        let mut tl = timeline(vec![vec![clip(1, 0, 60, TrackKind::Video)]]);
        let change = tl.edit_speed_keys(Id::from_u128(1), false, false, double_speed).unwrap();
        let c = tl.tracks[0].clip(Id::from_u128(1)).unwrap();
        assert!(c.speed_keys.is_none());
        assert_eq!(c.speed, ClipSpeed::from_percent(200.0));
        // The same 60 frames of timeline now play 120 frames of source.
        assert_eq!(c.duration(), f(60));
        assert_eq!(change, Time::ZERO);
        assert_eq!(c.source.duration, f(120));
    }

    #[test]
    fn a_nothing_edit_changes_nothing() {
        let mut tl = timeline(vec![vec![clip(1, 0, 60, TrackKind::Video)]]);
        let before = tl.clone();
        assert_eq!(tl.edit_speed_keys(Id::from_u128(1), false, false, |_| None), Ok(Time::ZERO));
        assert_eq!(tl.edit_speed_keys(Id::from_u128(1), false, false, |k| Some(k.clone())), Ok(Time::ZERO));
        assert_eq!(tl, before);
    }

    #[test]
    fn a_longer_track_stops_at_the_next_clip() {
        let mut tl = timeline(vec![vec![clip(1, 0, 60, TrackKind::Video), clip(2, 90, 30, TrackKind::Video)]]);
        let change = tl
            .edit_speed_keys(Id::from_u128(1), false, false, |k| {
                Some(SpeedKeys::new(
                    vec![SpeedSegment::constant(f(120), ClipSpeed::from_percent(50.0), false)],
                    k.origin,
                ))
            })
            .unwrap();
        assert_eq!(tl.tracks[0].clip(Id::from_u128(1)).unwrap().duration(), f(90));
        assert_eq!(change, f(30));
    }

    #[test]
    fn a_keyed_edit_installs_the_track_and_the_source_is_its_hull() {
        let mut tl = timeline(vec![vec![clip(1, 0, 60, TrackKind::Video)]]);
        tl.edit_speed_keys(Id::from_u128(1), false, false, |k| {
            k.splitting_key(1, f(1), FD).or_else(|| {
                let (two, _) = k.adding_key(f(30), FD)?;
                two.setting_speed(1, ClipSpeed::from_percent(200.0), FD).into()
            })
        })
        .unwrap();
        let c = tl.tracks[0].clip(Id::from_u128(1)).unwrap();
        let k = c.speed_keys.as_ref().unwrap();
        assert_eq!(k.segments.len(), 2);
        assert_eq!(c.source, k.hull());
        assert_eq!(c.duration(), k.duration());
    }

    #[test]
    fn linked_partners_get_the_same_segments_and_generators_are_refused() {
        let mut v = clip(1, 0, 60, TrackKind::Video);
        let mut a = clip(2, 0, 60, TrackKind::Audio);
        v.link = Some(Id::from_u128(77));
        a.link = Some(Id::from_u128(77));
        let mut tl = timeline(vec![vec![v], vec![a]]);
        tl.edit_speed_keys(Id::from_u128(1), true, false, |k| k.adding_key(f(30), FD).map(|(k, _)| k)).unwrap();
        let (cv, ca) = (tl.tracks[0].clip(Id::from_u128(1)).unwrap(), tl.tracks[1].clip(Id::from_u128(2)).unwrap());
        assert_eq!(cv.speed_keys.as_ref().unwrap().segments, ca.speed_keys.as_ref().unwrap().segments);

        let mut g = clip(3, 0, 60, TrackKind::Video);
        g.is_still = true;
        let mut tl = timeline(vec![vec![g]]);
        assert_eq!(tl.edit_speed_keys(Id::from_u128(3), false, false, double_speed), Err(EditError::SpeedUnsupported));
        assert_eq!(tl.edit_speed_keys(Id::from_u128(9), false, false, double_speed), Err(EditError::ClipNotFound));
    }

    #[test]
    fn fitting_cuts_the_tail_until_the_source_is_inside_the_media() {
        let k = SpeedKeys::new(vec![SpeedSegment::constant(f(60), ClipSpeed::NORMAL, false)], f(30));
        let fit = k.fitting(Some(f(60)), FD).unwrap();
        assert_eq!(fit.duration(), f(30));
        assert!(k.fitting(None, FD).is_some());
        assert!(
            SpeedKeys::new(vec![SpeedSegment::constant(f(60), ClipSpeed::NORMAL, false)], f(100))
                .fitting(Some(f(60)), FD)
                .is_none()
        );
    }
}
