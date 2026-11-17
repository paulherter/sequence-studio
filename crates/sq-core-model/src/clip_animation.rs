// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipAnimation.swift

use crate::Clip;
use serde::ser::SerializeMap;
use serde::{Deserialize, Serialize, Serializer};
use sq_core_time::{EncodeContext, Keyframe, KeyframeTrack, KeyframeValue, Seen, Time, Vec2};

/// A value with an optional keyframe track; the track wins where it has keys.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(bound(serialize = "V: Serialize", deserialize = "V: KeyframeValue"))]
pub struct AnimatedProperty<V> {
    /// Static value, used while the track is empty.
    pub value: V,
    /// Keys (clip-local times).
    #[serde(default)]
    pub track: KeyframeTrack<V>,
}

impl<V> AnimatedProperty<V> {
    /// A static value without keys.
    pub fn new(value: V) -> Self {
        AnimatedProperty { value, track: KeyframeTrack::default() }
    }
}

impl<V: KeyframeValue> AnimatedProperty<V> {
    /// Has keys.
    pub fn is_animated(&self) -> bool {
        !self.track.is_empty()
    }

    /// Value at clip-local time `t`: the track where it has keys, else the static value.
    pub fn value_at_local(&self, t: Time) -> V {
        self.track.value(t).unwrap_or_else(|| self.value.clone())
    }

    /// Key times through `f` (a retime). Keys that end up falling are mirrored, mixed orders are sorted.
    #[doc(hidden)]
    pub fn remapped(&self, f: impl Fn(Time) -> Time) -> Self {
        let mut c = self.clone();
        let keys: Vec<_> = self
            .track
            .keys
            .iter()
            .cloned()
            .map(|mut k| {
                k.time = f(k.time);
                k
            })
            .collect();
        if keys.len() < 2 || keys.windows(2).all(|w| w[0].time <= w[1].time) {
            c.track.keys = keys;
        } else if keys.windows(2).all(|w| w[0].time >= w[1].time) {
            c.track.keys = Self::mirrored(keys);
        } else {
            let mut keys = keys;
            keys.sort_by_key(|k| k.time);
            c.track.keys = keys;
        }
        c
    }

    /// Rising time order, sides swapped; key i + 1 led the segment i ... i + 1, so each key takes the mirrored
    /// shape of its right neighbor and the last keeps the old first shape.
    fn mirrored(old: Vec<Keyframe<V>>) -> Vec<Keyframe<V>> {
        let mut r: Vec<Keyframe<V>> = old
            .into_iter()
            .rev()
            .map(|mut k| {
                std::mem::swap(&mut k.in_handle, &mut k.out_handle);
                std::mem::swap(&mut k.in_tangent, &mut k.out_tangent);
                k
            })
            .collect();
        let last = r[0].interpolation;
        for i in 0..r.len() - 1 {
            r[i].interpolation = r[i + 1].interpolation.mirrored();
        }
        let n = r.len();
        r[n - 1].interpolation = last;
        r
    }

    /// Every key moved by `delta`.
    pub fn shifted(&self, delta: Time) -> Self {
        let mut c = self.clone();
        for k in &mut c.track.keys {
            k.time += delta;
        }
        c
    }
}

/// The evaluated Motion and Opacity of a clip at one instant.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClipTransform {
    /// Offset from the frame center.
    pub position: Vec2,
    /// Scale per axis.
    pub scale: Vec2,
    /// Degrees, clockwise.
    pub rotation: f64,
    /// 0...1.
    pub opacity: f64,
    /// Anchor point.
    pub anchor: Vec2,
    /// Perspective tilt around x.
    pub tilt_x: f64,
    /// Perspective tilt around y.
    pub tilt_y: f64,
}

impl ClipTransform {
    /// The layer is turned out of its plane.
    pub fn is_tilted(&self) -> bool {
        self.tilt_x != 0.0 || self.tilt_y != 0.0
    }

    /// No change.
    pub const IDENTITY: ClipTransform = ClipTransform {
        position: Vec2::ZERO,
        scale: Vec2::new(1.0, 1.0),
        rotation: 0.0,
        opacity: 1.0,
        anchor: Vec2::ZERO,
        tilt_x: 0.0,
        tilt_y: 0.0,
    };
}

/// Animatable transform, opacity and volume of a clip. Missing keys decode as the defaults.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ClipAnimation {
    /// Position.
    pub position: AnimatedProperty<Vec2>,
    /// Scale.
    pub scale: AnimatedProperty<Vec2>,
    /// Rotation in degrees.
    pub rotation: AnimatedProperty<f64>,
    /// Opacity 0...1.
    pub opacity: AnimatedProperty<f64>,
    /// Anchor point.
    pub anchor: AnimatedProperty<Vec2>,
    /// Linear volume.
    pub volume: AnimatedProperty<f64>,
    /// Motion blur shutter angle; written only when open or keyed.
    pub shutter_angle: AnimatedProperty<f64>,
    /// Anti-flicker strength; written only when set or keyed.
    pub anti_flicker: AnimatedProperty<f64>,
    /// Perspective tilt x; written only when a tilt is set or keyed (v84).
    pub tilt_x: AnimatedProperty<f64>,
    /// Perspective tilt y.
    pub tilt_y: AnimatedProperty<f64>,
    /// Corner radius of files before v9; the clip decoder turns it into a Rounded Corners effect.
    #[doc(hidden)]
    #[serde(rename = "cornerRadius")]
    pub legacy_corner_radius: Option<AnimatedProperty<f64>>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten)]
    pub unknown: crate::UnknownKeys,
}

impl Default for ClipAnimation {
    fn default() -> Self {
        ClipAnimation {
            position: AnimatedProperty::new(Vec2::ZERO),
            scale: AnimatedProperty::new(Vec2::new(1.0, 1.0)),
            rotation: AnimatedProperty::new(0.0),
            opacity: AnimatedProperty::new(1.0),
            anchor: AnimatedProperty::new(Vec2::ZERO),
            volume: AnimatedProperty::new(1.0),
            shutter_angle: AnimatedProperty::new(0.0),
            anti_flicker: AnimatedProperty::new(0.0),
            tilt_x: AnimatedProperty::new(0.0),
            tilt_y: AnimatedProperty::new(0.0),
            legacy_corner_radius: None,
            unknown: crate::UnknownKeys::default(),
        }
    }
}

impl ClipAnimation {
    /// Every property through `remapped(f)`.
    #[doc(hidden)]
    pub fn remapped(&self, f: impl Fn(Time) -> Time) -> ClipAnimation {
        let mut a = self.clone();
        a.position = self.position.remapped(&f);
        a.scale = self.scale.remapped(&f);
        a.rotation = self.rotation.remapped(&f);
        a.opacity = self.opacity.remapped(&f);
        a.anchor = self.anchor.remapped(&f);
        a.volume = self.volume.remapped(&f);
        a.shutter_angle = self.shutter_angle.remapped(&f);
        a.anti_flicker = self.anti_flicker.remapped(&f);
        a.tilt_x = self.tilt_x.remapped(&f);
        a.tilt_y = self.tilt_y.remapped(&f);
        a
    }

    /// Every property through `shifted(delta)`.
    #[doc(hidden)]
    pub fn shifted(&self, delta: Time) -> ClipAnimation {
        let mut a = self.clone();
        a.position = self.position.shifted(delta);
        a.scale = self.scale.shifted(delta);
        a.rotation = self.rotation.shifted(delta);
        a.opacity = self.opacity.shifted(delta);
        a.anchor = self.anchor.shifted(delta);
        a.volume = self.volume.shifted(delta);
        a.shutter_angle = self.shutter_angle.shifted(delta);
        a.anti_flicker = self.anti_flicker.shifted(delta);
        a.tilt_x = self.tilt_x.shifted(delta);
        a.tilt_y = self.tilt_y.shifted(delta);
        a
    }

    /// Anti-flicker is above 0 or keyed: the file then needs v92.
    pub fn is_anti_flicker_set_or_keyed(&self) -> bool {
        self.anti_flicker.value != 0.0 || self.anti_flicker.is_animated()
    }

    /// The filter strength at a clip-local time, clamped to 0...1.
    pub fn anti_flicker_strength_at_local(&self, t: Time) -> f64 {
        self.anti_flicker.value_at_local(t).clamp(0.0, 1.0)
    }

    /// A tilt is set away from 0 or keyed: the file then needs v84.
    pub fn is_tilt_set_or_keyed(&self) -> bool {
        self.tilt_x.value != 0.0 || self.tilt_x.is_animated() || self.tilt_y.value != 0.0 || self.tilt_y.is_animated()
    }

    /// Motion's Shutter Angle is open at some point (or keyed): the file then needs v40.
    pub fn is_shutter_open_or_keyed(&self) -> bool {
        self.shutter_angle.value != 0.0 || self.shutter_angle.is_animated()
    }
}

/// Largest perspective turn either way; at 90 degrees the plane would be edge-on (a line). The masks crate owns
/// `PerspectiveTilt`; this is the same clamp for `Clip::transform`.
const MAX_TILT_DEGREES: f64 = 89.0;

fn clamped_tilt(degrees: f64) -> f64 {
    if degrees.is_finite() { degrees.clamp(-MAX_TILT_DEGREES, MAX_TILT_DEGREES) } else { 0.0 }
}

impl Clip {
    /// Transform at timeline time `t`, from the tracks where present, else the static values.
    /// Scale is clamped to >= 0 and opacity to 0...1; rotation and position are returned as evaluated.
    pub fn transform(&self, t: Time) -> ClipTransform {
        let l = t - self.start;
        let a = &self.animation;
        let s = a.scale.value_at_local(l);
        // fx toggle off: the section renders at its defaults (no evaluation at all), the stored values stay.
        let opacity = if self.opacity_enabled { a.opacity.value_at_local(l).clamp(0.0, 1.0) } else { 1.0 };
        if !self.motion_enabled {
            return ClipTransform { opacity, ..ClipTransform::IDENTITY };
        }
        ClipTransform {
            position: a.position.value_at_local(l),
            scale: Vec2::new(s.x.max(0.0), s.y.max(0.0)),
            rotation: a.rotation.value_at_local(l),
            opacity,
            anchor: a.anchor.value_at_local(l),
            tilt_x: clamped_tilt(a.tilt_x.value_at_local(l)),
            tilt_y: clamped_tilt(a.tilt_y.value_at_local(l)),
        }
    }

    /// Linear gain at timeline time `t` (volume line times Audio Gain), never negative.
    pub fn volume(&self, t: Time) -> f64 {
        let v = self.animation.volume.value_at_local(t - self.start).max(0.0);
        if self.audio_gain_db == 0.0 { v } else { v * 10.0_f64.powf(self.audio_gain_db / 20.0) }
    }
}

/// Shutter, anti-flicker and tilt are written only when used; tilt marks `Seen::Tilt` (v84).
impl Serialize for ClipAnimation {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut c = s.serialize_map(None)?;
        c.serialize_entry("position", &self.position)?;
        c.serialize_entry("scale", &self.scale)?;
        c.serialize_entry("rotation", &self.rotation)?;
        c.serialize_entry("opacity", &self.opacity)?;
        c.serialize_entry("anchor", &self.anchor)?;
        c.serialize_entry("volume", &self.volume)?;
        if self.is_shutter_open_or_keyed() {
            c.serialize_entry("shutterAngle", &self.shutter_angle)?;
        }
        if self.is_anti_flicker_set_or_keyed() {
            c.serialize_entry("antiFlicker", &self.anti_flicker)?;
        }
        if self.is_tilt_set_or_keyed() {
            c.serialize_entry("tiltX", &self.tilt_x)?;
            c.serialize_entry("tiltY", &self.tilt_y)?;
            EncodeContext::mark(Seen::Tilt);
        }
        for key in self.unknown.keys() {
            if let Some(value) = self.unknown.get(key) {
                c.serialize_entry(key, value)?;
            }
        }
        c.end()
    }
}

/// A minimal clip for the tests of this crate (Swift tests build clips with `Clip(name:media:kind:source:start:)`).
#[cfg(test)]
pub(crate) mod test_util {
    use crate::{Clip, TrackKind};
    use sq_core_time::Id;

    /// A clip of `dur` seconds at second `start`.
    pub(crate) fn clip(kind: TrackKind, start: i64, dur: i64) -> Clip {
        let kind = if kind == TrackKind::Video { "video" } else { "audio" };
        serde_json::from_value(serde_json::json!({"id": Id::from_u128(1), "name": "c", "media": Id::from_u128(2),
            "kind": kind,
            "source": {"start": {"value": 0, "timescale": 1}, "duration": {"value": dur, "timescale": 1}},
            "start": {"value": start, "timescale": 1}}))
        .unwrap_or_else(|e| panic!("test clip: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{EaseHandle, Id, Interpolation};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(start: i64, dur: i64) -> Clip {
        crate::clip_animation::test_util::clip(crate::TrackKind::Video, start, dur)
    }

    fn key(t: i64, v: f64) -> Keyframe<f64> {
        Keyframe::new(Id::from_u128(1000 + t as u128), s(t), v)
    }

    #[test]
    fn defaults_are_static_identity() {
        let t = clip(0, 10).transform(s(3));
        assert_eq!(t, ClipTransform::IDENTITY);
        assert!(!t.is_tilted());
    }

    #[test]
    fn static_value_without_keys() {
        let mut c = clip(0, 10);
        c.animation.rotation.value = 45.0;
        assert_eq!(c.transform(s(5)).rotation, 45.0);
    }

    #[test]
    fn tracks_use_clip_local_time() {
        let mut c = clip(10, 10);
        c.animation.position.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(1), s(0), Vec2::new(0.0, 0.0)),
            Keyframe::new(Id::from_u128(2), s(4), Vec2::new(40.0, 0.0)),
        ]);
        assert_eq!(c.transform(s(12)).position, Vec2::new(20.0, 0.0)); // timeline 12 = local 2
        assert_eq!(c.transform(s(5)).position, Vec2::new(0.0, 0.0)); // before the clip: clamped to the first key
    }

    #[test]
    fn rotation_unbounded() {
        let mut c = clip(0, 10);
        c.animation.rotation.track = KeyframeTrack::with_keys(vec![key(0, 0.0), key(4, 720.0)]);
        assert_eq!(c.transform(s(4)).rotation, 720.0);
        assert_eq!(c.transform(s(1)).rotation, 180.0);
        c.animation.rotation.track = KeyframeTrack::with_keys(vec![key(0, 0.0), key(4, -1080.0)]);
        assert_eq!(c.transform(s(4)).rotation, -1080.0);
    }

    #[test]
    fn scale_clamped_at_zero_not_wrapped() {
        let mut c = clip(0, 10);
        c.animation.scale.value = Vec2::new(-2.0, 3.0);
        assert_eq!(c.transform(s(1)).scale, Vec2::new(0.0, 3.0));
        c.animation.scale.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(1), s(0), Vec2::new(1.0, 1.0)),
            Keyframe::new(Id::from_u128(2), s(2), Vec2::new(-3.0, 5.0)),
        ]);
        let v = c.transform(s(1)).scale;
        assert!(v.x == 0.0 && v.y == 3.0);
        assert_eq!(c.transform(s(2)).scale, Vec2::new(0.0, 5.0));
        c.animation.scale.value = Vec2::new(500.0, 500.0); // no upper limit
        c.animation.scale.track = KeyframeTrack::default();
        assert_eq!(c.transform(s(0)).scale, Vec2::new(500.0, 500.0));
    }

    #[test]
    fn opacity_and_volume_clamped() {
        let mut c = clip(0, 10);
        c.animation.opacity.value = 1.5;
        c.animation.volume.value = -1.0;
        assert_eq!(c.transform(s(0)).opacity, 1.0);
        assert_eq!(c.volume(s(0)), 0.0);
        c.animation.volume.value = 4.0; // +12 dB headroom allowed
        assert_eq!(c.volume(s(0)), 4.0);
        c.audio_gain_db = 20.0;
        assert!((c.volume(s(0)) - 40.0).abs() < 1e-9);
    }

    #[test]
    fn fx_toggles_render_the_section_at_its_defaults() {
        let mut c = clip(0, 10);
        c.animation.position.value = Vec2::new(5.0, 5.0);
        c.animation.opacity.value = 0.25;
        c.motion_enabled = false;
        assert_eq!(c.transform(s(0)), ClipTransform { opacity: 0.25, ..ClipTransform::IDENTITY });
        c.opacity_enabled = false;
        assert_eq!(c.transform(s(0)), ClipTransform::IDENTITY);
    }

    #[test]
    fn tilt_is_clamped_and_non_finite_is_flat() {
        let mut c = clip(0, 10);
        c.animation.tilt_x.value = 120.0;
        c.animation.tilt_y.value = f64::NAN;
        let t = c.transform(s(0));
        assert_eq!((t.tilt_x, t.tilt_y), (89.0, 0.0));
        assert!(t.is_tilted());
    }

    #[test]
    fn set_or_keyed_flags_and_anti_flicker_strength() {
        let mut a = ClipAnimation::default();
        assert!(!a.is_tilt_set_or_keyed() && !a.is_shutter_open_or_keyed() && !a.is_anti_flicker_set_or_keyed());
        a.anti_flicker.value = 3.0;
        assert!(a.is_anti_flicker_set_or_keyed());
        assert_eq!(a.anti_flicker_strength_at_local(s(0)), 1.0);
        a.tilt_y.track = KeyframeTrack::with_keys(vec![key(0, 0.0)]);
        a.shutter_angle.value = 180.0;
        assert!(a.is_tilt_set_or_keyed() && a.is_shutter_open_or_keyed());
    }

    #[test]
    fn codable_round_trip_with_keyframes() {
        let mut c = clip(0, 10);
        let mut k = Keyframe::new(Id::from_u128(1), s(0), Vec2::new(1.0, 2.0));
        k.interpolation = Interpolation::Bezier;
        k.out_handle = EaseHandle { dx: 0.2, dy: 0.9 };
        c.animation.position.track =
            KeyframeTrack::with_keys(vec![k, Keyframe::new(Id::from_u128(2), s(2), Vec2::new(3.0, 4.0))]);
        c.animation.volume.value = 0.5;
        let back: Clip = serde_json::from_value(serde_json::to_value(&c).unwrap()).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn remapped_mirrors_falling_keys_and_swaps_sides() {
        let mut a = Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0);
        a.interpolation = Interpolation::Hold;
        a.out_handle = EaseHandle { dx: 0.5, dy: 0.0 };
        let b = Keyframe::new(Id::from_u128(2), Time::new(1, 1), 1.0);
        let p = AnimatedProperty { value: 0.0, track: KeyframeTrack::with_keys(vec![a, b]) };
        let r = p.remapped(|t| Time::new(1, 1) - t);
        assert_eq!(r.track.keys[0].id, Id::from_u128(2));
        assert_eq!(r.track.keys[0].interpolation, Interpolation::HoldAhead);
        assert_eq!(r.track.keys[1].in_handle, EaseHandle { dx: 0.5, dy: 0.0 });
        assert_eq!(p.shifted(Time::new(2, 1)).track.keys[1].time, Time::new(3, 1));
    }
}
