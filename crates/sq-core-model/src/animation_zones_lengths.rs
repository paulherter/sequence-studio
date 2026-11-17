// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnimationZones+Lengths.swift, Clip+AnimationFloor.swift

use crate::anchored_animation::{AnimationSet, KeyframeTemplate};
use crate::labels::TEXT_GENERATOR;
use crate::{AnimationZones, Clip, EditError, GeneratorRef, Project, ZoneMiddle};
use serde::Deserialize;
use sq_core_time::{Id, Time};

impl Clip {
    /// Lengths of the intro and outro zones: a text clip's anchored in / out animations (a looping intro is not a zone),
    /// or the clip's own `zones`. `None` when the clip has none.
    pub fn animation_zone_lengths(&self) -> Option<(Time, Time)> {
        if let Some(g) = self.generator.as_ref().filter(|g| g.kind == TEXT_GENERATOR)
            && let Some(l) = text_zone_lengths(g)
        {
            return Some(l);
        }
        self.zones.as_ref().map(|z| (z.intro_end, z.outro_length))
    }

    /// The shortest this clip may be: its zones side by side, at least one `frame`.
    pub fn minimum_duration(&self, frame: Time) -> Time {
        match self.animation_zone_lengths() {
            Some((intro, outro)) => frame.max(intro + outro),
            None => frame,
        }
    }

    /// `g` (change of duration, negative = shorter) held back so the clip stays at least `minimum_duration`; a clip that
    /// is already shorter than its zones does not shrink further.
    #[doc(hidden)]
    pub fn clamping_shortening(&self, g: Time, frame: Time) -> Time {
        if g >= Time::ZERO || self.animation_zone_lengths().is_none() {
            return g;
        }
        g.max((self.minimum_duration(frame) - self.duration()).min(Time::ZERO))
    }
}

/// Reads the in / out lengths straight from a text payload (`{"template": ..., "animations": AnimationSet}`, owned by
/// the text crate) so the model needs no text types.
///
/// shortcut: decoded on every call (Swift memoizes per payload); upgrade when a profile shows the trim paths slow.
fn text_zone_lengths(g: &GeneratorRef) -> Option<(Time, Time)> {
    #[derive(Deserialize)]
    struct Payload {
        animations: Option<AnimationSet>,
    }
    let set = serde_json::from_slice::<Payload>(&g.payload).ok()?.animations?;
    let len = |t: &Option<KeyframeTemplate>| match t {
        Some(t) if !t.loops && !t.tracks.is_empty() => t.duration.max(Time::ZERO),
        _ => Time::ZERO,
    };
    let (a, b) = (len(&set.animation_in), len(&set.animation_out));
    (a > Time::ZERO || b > Time::ZERO).then_some((a, b))
}

impl Project {
    /// Sets the lengths of a clip's intro and outro zones (the first N seconds are the in animation, the last M the out
    /// animation). Each is at least 0 and together at most the clip's duration: the intro is limited first, the outro takes
    /// what is left. Keys are not moved: the zones only decide what a later trim keeps, and the clip can no longer be
    /// trimmed below intro + outro. A clip without zones gets them. Errors: `ClipNotFound`, `TrackLocked`.
    pub fn set_animation_zone_lengths(&mut self, intro: Time, outro: Time, clip: Id) -> Result<(), EditError> {
        self.modify_clip_for_zones(clip, |c| {
            let duration = c.duration();
            let i = intro.max(Time::ZERO).min(duration);
            let o = outro.max(Time::ZERO).min(duration - i);
            let mut z =
                c.zones.clone().unwrap_or_else(|| AnimationZones::new(Time::ZERO, Time::ZERO, ZoneMiddle::Hold, None));
            z.intro_end = i;
            z.outro_length = o;
            c.zones = Some(z);
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Clip, TrackKind};
    use sq_core_time::TimeRange;

    fn project() -> (Project, Id) {
        let clip = Clip::new(
            Id::from_u128(1),
            "G",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(10, 1)),
            Time::ZERO,
        );
        let track = serde_json::json!({"id": Id::from_u128(9), "kind": "video", "clips": [serde_json::to_value(&clip).unwrap()]});
        let timeline = serde_json::json!({"id": Id::from_u128(8), "name": "S", "tracks": [track],
            "format": {"width": 1920, "height": 1080, "frameDuration": {"value": 1, "timescale": 30}, "audioSampleRate": 48000}});
        let p = serde_json::from_value(
            serde_json::json!({"id": Id::from_u128(7), "name": "P", "media": [], "timelines": [timeline]}),
        );
        (p.unwrap(), clip.id)
    }

    fn zones(p: &Project, id: Id) -> Option<AnimationZones> {
        p.timelines[0].tracks[0].clip(id).and_then(|c| c.zones.clone())
    }

    #[test]
    fn sets_both_lengths() {
        let (mut p, id) = project();
        p.set_animation_zone_lengths(Time::new(2, 1), Time::new(3, 1), id).unwrap();
        let z = zones(&p, id).unwrap();
        assert_eq!((z.intro_end, z.outro_length), (Time::new(2, 1), Time::new(3, 1)));
    }

    #[test]
    fn zones_never_exceed_the_clip() {
        let (mut p, id) = project();
        p.set_animation_zone_lengths(Time::new(8, 1), Time::new(9, 1), id).unwrap();
        let z = zones(&p, id).unwrap();
        assert_eq!((z.intro_end, z.outro_length), (Time::new(8, 1), Time::new(2, 1)));
        p.set_animation_zone_lengths(Time::new(-1, 1), Time::new(1, 1), id).unwrap();
        assert_eq!(zones(&p, id).unwrap().intro_end, Time::ZERO);
    }

    fn fade(num: i64, den: i64, anchor: &str, loops: bool) -> serde_json::Value {
        let mut t = serde_json::json!({"anchor": anchor, "duration": {"value": num, "timescale": den},
            "tracks": [{"property": "opacity", "track": {"keys": []}}]});
        if loops {
            t["loops"] = serde_json::json!(true);
        }
        t
    }

    fn text_clip(seconds: i64, animations: serde_json::Value) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1),
            "T",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(seconds)),
            Time::ZERO,
        );
        let payload = serde_json::to_vec(&serde_json::json!({ "animations": animations })).unwrap();
        c.generator = Some(GeneratorRef { kind: "text".into(), payload, payload_version: 1 });
        c
    }

    #[test]
    fn lengths_come_from_the_payload_and_raise_the_floor() {
        let fd = Time::new(1, 30);
        let c = text_clip(
            5,
            serde_json::json!({"animationIn": fade(1, 2, "start", false), "animationOut": fade(3, 4, "end", false)}),
        );
        assert_eq!(c.animation_zone_lengths(), Some((Time::new(1, 2), Time::new(3, 4))));
        assert_eq!(c.minimum_duration(fd), Time::new(5, 4));
    }

    #[test]
    fn no_animations_means_one_frame_and_a_looping_intro_is_no_zone() {
        let fd = Time::new(1, 30);
        let c = text_clip(5, serde_json::json!({}));
        assert_eq!((c.animation_zone_lengths(), c.minimum_duration(fd)), (None, fd));
        let looping = text_clip(5, serde_json::json!({"animationIn": fade(1, 1, "start", true)}));
        assert_eq!(looping.animation_zone_lengths(), None);
    }

    #[test]
    fn a_clip_without_a_text_payload_uses_its_own_zones() {
        let (mut p, id) = project();
        p.set_animation_zone_lengths(Time::new(2, 1), Time::new(3, 1), id).unwrap();
        let c = p.timelines[0].tracks[0].clip(id).unwrap();
        assert_eq!(c.minimum_duration(Time::new(1, 30)), Time::new(5, 1));
    }

    #[test]
    fn shortening_stops_at_in_plus_out_and_never_shrinks_a_clip_below_its_zones() {
        let fd = Time::new(1, 30);
        let c = text_clip(
            5,
            serde_json::json!({"animationIn": fade(1, 1, "start", false), "animationOut": fade(1, 1, "end", false)}),
        );
        assert_eq!(c.clamping_shortening(Time::seconds(-4), fd), Time::seconds(-3));
        assert_eq!(c.clamping_shortening(Time::seconds(2), fd), Time::seconds(2), "lengthening is free");
        let short = text_clip(
            1,
            serde_json::json!({"animationIn": fade(1, 1, "start", false), "animationOut": fade(1, 1, "end", false)}),
        );
        assert_eq!(short.clamping_shortening(Time::seconds(-1), fd), Time::ZERO);
        let plain = text_clip(5, serde_json::json!({}));
        assert_eq!(plain.clamping_shortening(Time::seconds(-9), fd), Time::seconds(-9));
    }
}
