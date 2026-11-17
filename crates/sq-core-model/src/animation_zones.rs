// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnimationZones.swift

use crate::{Clip, ClipEdge, EditError, Project};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time};

// Animation zones: an intro zone at the clip start and an outro zone at its end keep their absolute length when the clip is
// trimmed or stretched; the middle holds or stretches. Auto-detected from the first/last keyframes and works on any clip,
// with or without a title template. Stored on the clip (`Clip::zones`, v58) as lengths, so a trim never has to rewrite them.
//
// Two users of the same record:
// - Any keyed clip: a trim moves the outro keys with the clip end and leaves the intro keys at the clip start
//   (`Clip::extend_head` / `extend_tail`, through `key_time`).
// - A nested template clip: the inner sequence is played through `content_time` instead of the source range
//   (`Clip::inner_time`).

/// What the middle of a clip does when the clip is trimmed or stretched (Swift `AnimationZones.Middle`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ZoneMiddle {
    /// The middle holds its content.
    Hold,
    /// The middle stretches.
    Stretch,
}

/// Intro and outro zones that keep their absolute length when the clip is trimmed or stretched.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnimationZones {
    /// End of the intro zone, clip-local.
    pub intro_end: Time,
    /// Length of the outro zone at the clip end.
    pub outro_length: Time,
    /// What the middle does.
    pub middle: ZoneMiddle,
    /// Length of the inside sequence of a nested template clip; `None` for any other clip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub design_duration: Option<Time>,
}

impl AnimationZones {
    /// Zones with `intro_end` and `outro_length` held at 0 or more.
    pub fn new(
        intro_end: Time,
        outro_length: Time,
        middle: ZoneMiddle,
        design_duration: Option<Time>,
    ) -> AnimationZones {
        AnimationZones {
            intro_end: intro_end.max(Time::ZERO),
            outro_length: outro_length.max(Time::ZERO),
            middle,
            design_duration,
        }
    }

    /// Zones given as positions inside content of `design_duration` (`intro_end`, `outro_start`).
    pub fn with_outro_start(
        intro_end: Time,
        outro_start: Time,
        design_duration: Time,
        middle: ZoneMiddle,
    ) -> AnimationZones {
        AnimationZones::new(intro_end, design_duration - outro_start, middle, Some(design_duration))
    }

    /// Start of the outro zone in a clip of `duration`.
    pub fn outro_start(&self, duration: Time) -> Time {
        duration - self.outro_length
    }

    /// Auto-detect: keys in the first half of `duration` belong to the intro (it ends at the last of them), keys in the
    /// second half to the outro (it starts at the first of them). `None` without keys or for an empty duration.
    pub fn detect(
        key_times: &[Time],
        duration: Time,
        middle: ZoneMiddle,
        design_duration: Option<Time>,
    ) -> Option<AnimationZones> {
        if duration <= Time::ZERO || key_times.is_empty() {
            return None;
        }
        let half = duration.halved();
        let intro =
            key_times.iter().filter(|t| **t <= half).max().map_or(Time::ZERO, |t| (*t).max(Time::ZERO).min(duration));
        let outro = key_times.iter().filter(|t| **t > half).min().map_or(duration, |t| (*t).min(duration));
        Some(AnimationZones::new(intro, duration - outro, middle, design_duration))
    }

    /// Content time (nested template) shown at clip-local `local` in a clip of `duration`. Intro: 1:1 from the start.
    /// Outro: 1:1 ending at the content end. Middle: `middle`. A clip shorter than both zones cuts the intro; the outro
    /// always plays whole. Without `design_duration` the clip's own time is returned.
    pub fn content_time(&self, local: Time, duration: Time) -> Time {
        let Some(design) = self.design_duration else { return local };
        let (out_outer, out_inner) = (self.outro_start(duration), self.outro_start(design));
        if local >= out_outer {
            return out_inner + (local - out_outer);
        }
        if local <= self.intro_end {
            return local;
        }
        match self.middle {
            ZoneMiddle::Hold => local.min(out_inner),
            ZoneMiddle::Stretch => {
                let (span_outer, span_inner) = (out_outer - self.intro_end, out_inner - self.intro_end);
                if !(span_outer > Time::ZERO && span_inner > Time::ZERO) {
                    return local.min(out_inner.max(self.intro_end));
                }
                self.intro_end + Time::scaled(local - self.intro_end, span_inner, span_outer)
            }
        }
    }

    /// Where a clip-local key at `t` goes when a trim changes the clip from `old` to `new` duration at `edge`. Intro keys
    /// stay, outro keys keep their distance to the clip end, middle keys hold their frames (`Hold`) or scale into the new
    /// middle (`Stretch`).
    pub fn key_time(&self, t: Time, old: Time, new: Time, edge: ClipEdge) -> Time {
        let g = new - old;
        if t <= self.intro_end {
            return t;
        }
        if t >= self.outro_start(old) {
            return t + g;
        }
        let unscaled = if edge == ClipEdge::Head { t + g } else { t };
        match self.middle {
            ZoneMiddle::Hold => unscaled,
            ZoneMiddle::Stretch => {
                let (a, b) = (self.outro_start(old) - self.intro_end, self.outro_start(new) - self.intro_end);
                if !(a > Time::ZERO && b > Time::ZERO) {
                    return unscaled;
                }
                self.intro_end + Time::scaled(t - self.intro_end, b, a)
            }
        }
    }
}

impl Clip {
    /// A nested clip whose inner sequence plays through its zones (an applied title template).
    pub fn plays_through_zones(&self) -> bool {
        self.sequence.is_some()
            && self.zones.as_ref().is_some_and(|z| z.design_duration.is_some())
            && self.hold_frame.is_none()
    }

    /// Moves the clip-local keys for a trim from `old` to `new` duration at `edge` through the zones.
    pub(crate) fn remap_keys_through_zones(&mut self, z: &AnimationZones, old: Time, new: Time, edge: ClipEdge) {
        let f = |t: Time| z.key_time(t, old, new, edge);
        self.animation = self.animation.remapped(f);
        self.effects = self.effects.iter().map(|e| e.remapped(f)).collect();
        self.remap_variant_keys(&f);
    }
}

impl Project {
    /// Sets (`None`: removes) the animation zones of a clip. Errors: `ClipNotFound`, `TrackLocked`.
    pub fn set_animation_zones(&mut self, zones: Option<AnimationZones>, clip: Id) -> Result<(), EditError> {
        self.modify_clip_for_zones(clip, |c| {
            c.zones = zones;
            Ok(())
        })
    }

    /// Finds the clip, checks its track is unlocked, edits it and puts it back.
    pub fn modify_clip_for_zones<E: From<EditError>>(
        &mut self,
        id: Id,
        body: impl FnOnce(&mut Clip) -> Result<(), E>,
    ) -> Result<(), E> {
        for timeline in &mut self.timelines {
            for track in &mut timeline.tracks {
                let Some(mut c) = track.clip(id).cloned() else { continue };
                if track.is_locked {
                    return Err(EditError::TrackLocked.into());
                }
                body(&mut c)?;
                track.replace(c);
                return Ok(());
            }
        }
        Err(EditError::ClipNotFound.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    #[test]
    fn new_holds_the_lengths_at_zero_or_more() {
        let z = AnimationZones::new(s(-1), s(-2), ZoneMiddle::Hold, None);
        assert_eq!((z.intro_end, z.outro_length), (Time::ZERO, Time::ZERO));
        let by_start = AnimationZones::with_outro_start(s(1), s(8), s(10), ZoneMiddle::Stretch);
        assert_eq!((by_start.outro_length, by_start.design_duration), (s(2), Some(s(10))));
    }

    #[test]
    fn detect_splits_the_keys_at_the_middle() {
        let z = AnimationZones::detect(&[s(1), s(2), s(8), s(9)], s(10), ZoneMiddle::Hold, None).unwrap();
        assert_eq!((z.intro_end, z.outro_length), (s(2), s(2)));
        let intro_only = AnimationZones::detect(&[s(1)], s(10), ZoneMiddle::Hold, None).unwrap();
        assert_eq!((intro_only.intro_end, intro_only.outro_length), (s(1), Time::ZERO));
        let outro_only = AnimationZones::detect(&[s(7)], s(10), ZoneMiddle::Hold, None).unwrap();
        assert_eq!((outro_only.intro_end, outro_only.outro_length), (Time::ZERO, s(3)));
        assert!(AnimationZones::detect(&[], s(10), ZoneMiddle::Hold, None).is_none());
        assert!(AnimationZones::detect(&[s(1)], Time::ZERO, ZoneMiddle::Hold, None).is_none());
    }

    #[test]
    fn keys_keep_intro_and_outro_and_move_or_scale_the_middle() {
        let hold = AnimationZones::new(s(1), s(2), ZoneMiddle::Hold, None);
        // Clip 10 s grows by 4 s at the tail: intro stays, outro keys keep their distance to the end, middle holds.
        assert_eq!(hold.key_time(s(1), s(10), s(14), ClipEdge::Tail), s(1));
        assert_eq!(hold.key_time(s(9), s(10), s(14), ClipEdge::Tail), s(13));
        assert_eq!(hold.key_time(s(5), s(10), s(14), ClipEdge::Tail), s(5));
        assert_eq!(hold.key_time(s(5), s(10), s(14), ClipEdge::Head), s(9));
        let stretch = AnimationZones::new(s(1), s(2), ZoneMiddle::Stretch, None);
        // Middle 1..8 (7 s) becomes 1..12 (11 s).
        assert_eq!(stretch.key_time(s(5), s(10), s(14), ClipEdge::Tail), s(1) + Time::scaled(s(4), s(11), s(7)));
    }

    #[test]
    fn content_time_plays_intro_and_outro_whole() {
        let z = AnimationZones::with_outro_start(s(2), s(8), s(10), ZoneMiddle::Hold);
        // A 14 s clip of 10 s content.
        assert_eq!(z.content_time(s(1), s(14)), s(1));
        assert_eq!(z.content_time(s(5), s(14)), s(5));
        assert_eq!(z.content_time(s(9), s(14)), s(8), "the middle holds on the outro's first frame");
        assert_eq!(z.content_time(s(13), s(14)), s(9));
        let st = AnimationZones::with_outro_start(s(2), s(8), s(10), ZoneMiddle::Stretch);
        assert_eq!(st.content_time(s(7), s(14)), s(2) + Time::scaled(s(5), s(6), s(10)));
        let plain = AnimationZones::new(s(1), s(1), ZoneMiddle::Hold, None);
        assert_eq!(plain.content_time(s(5), s(14)), s(5));
    }

    fn project_with_clip(locked: bool) -> (Project, Id) {
        let clip = Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            crate::TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, s(10)),
            Time::ZERO,
        );
        let track = serde_json::json!({"id": Id::from_u128(9), "kind": "video", "isLocked": locked,
            "clips": [serde_json::to_value(&clip).unwrap()]});
        let timeline = serde_json::json!({"id": Id::from_u128(8), "name": "S", "tracks": [track],
            "format": {"width": 1920, "height": 1080, "frameDuration": {"value": 1, "timescale": 30}, "audioSampleRate": 48000}});
        let project = serde_json::from_value(
            serde_json::json!({"id": Id::from_u128(7), "name": "P", "media": [], "timelines": [timeline]}),
        );
        (project.unwrap(), clip.id)
    }

    #[test]
    fn project_sets_and_clears_zones_and_refuses_locked_tracks() {
        let (mut p, id) = project_with_clip(false);
        let z = AnimationZones::new(s(1), s(2), ZoneMiddle::Hold, None);
        p.set_animation_zones(Some(z.clone()), id).unwrap();
        assert_eq!(p.timelines[0].tracks[0].clip(id).unwrap().zones, Some(z));
        p.set_animation_zones(None, id).unwrap();
        assert_eq!(p.timelines[0].tracks[0].clip(id).unwrap().zones, None);
        assert_eq!(p.set_animation_zones(None, Id::from_u128(99)), Err(EditError::ClipNotFound));
        let (mut locked, id) = project_with_clip(true);
        assert_eq!(locked.set_animation_zones(None, id), Err(EditError::TrackLocked));
    }

    #[test]
    fn plays_through_zones_needs_a_nested_clip_with_a_design_duration() {
        let mut c = Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            crate::TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, s(10)),
            Time::ZERO,
        );
        c.zones = Some(AnimationZones::new(s(1), s(1), ZoneMiddle::Hold, Some(s(10))));
        assert!(!c.plays_through_zones());
        c.sequence = Some(Id::from_u128(3));
        assert!(c.plays_through_zones());
        c.hold_frame = Some(s(1));
        assert!(!c.plays_through_zones());
    }

    #[test]
    fn round_trips_with_and_without_design_duration() {
        let zones = json!({"introEnd": {"value": 1, "timescale": 1}, "outroLength": {"value": 2, "timescale": 1},
                           "middle": "stretch"});
        assert_round_trip::<AnimationZones>(zones.clone());
        let mut with = zones;
        with["designDuration"] = json!({"value": 5, "timescale": 1});
        assert_round_trip::<AnimationZones>(with);
    }
}
