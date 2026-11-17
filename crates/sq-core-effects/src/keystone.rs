// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Keystone.swift
//! "Keystones": reusable keyframe building blocks (punch in, shake, slide in, pulse ...). A keystone is stored with
//! relative key times (0 ... `duration`) and normalized values, so it lands on any clip, at any length, in any sequence
//! size. Applied, it becomes ordinary keyframes on the clip (Motion/Opacity, added onto the clip's own values), so it
//! stays editable and nothing new goes into the project file. Library storage: the user library (`PresetKind.keystone`).

use crate::effect_preset::{Anchor, ApplyMode, ClipEffectPresetExt, EffectPreset};
use serde::{Deserialize, Serialize};
use sq_core_model::effect_defaults::{PayloadError, PayloadReadError};
use sq_core_model::{AnimatedProperty, Clip, EditError, Timeline, TrackKind, hidden_catalog};
use sq_core_time::{
    EaseHandle, EaseSide, EasingCurve, EncodeContext, Id, IdSource, Interpolation, Keyframe, KeyframeTrack,
    KeyframeValue, Time, Vec2,
};
use std::collections::BTreeSet;

/// A property a keystone can key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeystoneProperty {
    /// Position.
    Position,
    /// Scale.
    Scale,
    /// Rotation.
    Rotation,
    /// Opacity.
    Opacity,
}

/// Where a dropped keystone lands on the clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeystoneAnchor {
    /// Centered on the drop point (kept inside the clip).
    Free,
    /// At the clip's first frame wherever it is dropped (an "in" animation).
    ClipStart,
    /// Ending on the clip's last frame (an "out" animation).
    ClipEnd,
}

/// Where an applied keystone sits on its clip (clip-local) and which properties it keyed. The UI keeps it while the user
/// drags the keystone's edges (`restretch_keystone`); it is not saved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeystoneSpan {
    /// Start, clip-local.
    pub start: Time,
    /// Length.
    pub duration: Time,
    /// The properties it keyed.
    pub properties: BTreeSet<KeystoneProperty>,
}

impl KeystoneSpan {
    /// End, clip-local.
    pub fn end(&self) -> Time {
        self.start + self.duration
    }
}

/// A reusable keyframe building block.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Keystone {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Natural length; key times run 0 ... duration.
    pub duration: Time,
    /// Where a dropped keystone lands on the clip.
    pub anchor: KeystoneAnchor,
    /// Offset as a fraction of the frame (1 = one frame width/height), added onto the clip's Position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<KeyframeTrack<Vec2>>,
    /// Factor on the clip's Scale (1 = unchanged).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<KeyframeTrack<Vec2>>,
    /// Degrees added onto the clip's Rotation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotation: Option<KeyframeTrack<f64>>,
    /// Opacity 0 ... 1, multiplied onto the clip's own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<KeyframeTrack<f64>>,
    /// The keystone's own curve: when set it replaces every key's easing on apply (edited in the curve editor).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub easing: Option<EasingCurve>,
    /// A saved animation that played in a loop: it loops again where it is picked. `None` (absent from the payload) is
    /// once, as for every keystone saved before. Applying a keystone to a clip ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loops: Option<bool>,
}

/// Prefix of every built-in id (the ASCII of "keystone").
const BUILT_IN_PREFIX: &str = "6B657973-746F-6E65-0000-";

impl Keystone {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for keystone presets). 2: a key may be a Hold Ahead.
    /// Written only for such a keystone (`written_payload_version`), so every other one stays readable by builds that know
    /// version 1; those skip a version 2 preset.
    pub const PAYLOAD_VERSION: i64 = 2;

    /// A keystone without keys.
    pub fn new(id: Id, name: &str, duration: Time, anchor: KeystoneAnchor) -> Keystone {
        Keystone {
            id,
            name: name.to_string(),
            duration,
            anchor,
            position: None,
            scale: None,
            rotation: None,
            opacity: None,
            easing: None,
            loops: None,
        }
    }

    /// The version to store next to `payload()`.
    pub fn written_payload_version(&self) -> i64 {
        fn ahead<V>(t: &Option<KeyframeTrack<V>>) -> bool {
            t.as_ref().is_some_and(|t| t.keys.iter().any(|k| k.interpolation == Interpolation::HoldAhead))
        }
        if ahead(&self.position) || ahead(&self.scale) || ahead(&self.rotation) || ahead(&self.opacity) { 2 } else { 1 }
    }

    /// The properties that have keys.
    pub fn properties(&self) -> BTreeSet<KeystoneProperty> {
        fn keyed<V>(t: &Option<KeyframeTrack<V>>) -> bool {
            t.as_ref().is_some_and(|t| !t.keys.is_empty())
        }
        [
            (KeystoneProperty::Position, keyed(&self.position)),
            (KeystoneProperty::Scale, keyed(&self.scale)),
            (KeystoneProperty::Rotation, keyed(&self.rotation)),
            (KeystoneProperty::Opacity, keyed(&self.opacity)),
        ]
        .into_iter()
        .filter_map(|(p, on)| on.then_some(p))
        .collect()
    }

    /// A keystone from the keys of `properties` on `clip`: times relative to the earliest key, values normalized against
    /// the clip's value there (Position as a fraction of `frame_size`, Scale as a factor, Rotation as an offset; Opacity
    /// stays absolute). Easing is kept. `None` when the chosen properties have fewer than two key times.
    pub fn capture(
        clip: &Clip,
        properties: &BTreeSet<KeystoneProperty>,
        frame_size: Vec2,
        name: &str,
        ids: &mut dyn IdSource,
    ) -> Option<Keystone> {
        let a = &clip.animation;
        let mut times: Vec<Time> = Vec::new();
        let sources = [
            (KeystoneProperty::Position, a.position.track.keys.iter().map(|k| k.time).collect::<Vec<_>>()),
            (KeystoneProperty::Scale, a.scale.track.keys.iter().map(|k| k.time).collect()),
            (KeystoneProperty::Rotation, a.rotation.track.keys.iter().map(|k| k.time).collect()),
            (KeystoneProperty::Opacity, a.opacity.track.keys.iter().map(|k| k.time).collect()),
        ];
        for (p, t) in sources {
            if properties.contains(&p) {
                times.extend(t);
            }
        }
        let (origin, last) = (times.iter().min().copied()?, times.iter().max().copied()?);
        if last <= origin {
            return None;
        }

        let (w, h) = (
            if frame_size.x == 0.0 { 1.0 } else { frame_size.x },
            if frame_size.y == 0.0 { 1.0 } else { frame_size.y },
        );
        let ratio = |v: f64, b: f64| if b == 0.0 { v } else { v / b };
        let mut k = Keystone::new(ids.next_id(), name, last - origin, KeystoneAnchor::Free);
        k.position = take_keys(
            properties,
            KeystoneProperty::Position,
            &a.position,
            origin,
            &|v: Vec2, b: Vec2| Vec2::new((v.x - b.x) / w, (v.y - b.y) / h),
            ids,
        );
        // Spatial tangents are in pixels: they follow the same normalization.
        if let Some(p) = k.position.as_mut() {
            for q in p.keys.iter_mut() {
                q.in_tangent = Vec2::new(q.in_tangent.x / w, q.in_tangent.y / h);
                q.out_tangent = Vec2::new(q.out_tangent.x / w, q.out_tangent.y / h);
            }
        }
        k.scale = take_keys(
            properties,
            KeystoneProperty::Scale,
            &a.scale,
            origin,
            &|v: Vec2, b: Vec2| Vec2::new(ratio(v.x, b.x), ratio(v.y, b.y)),
            ids,
        );
        k.rotation =
            take_keys(properties, KeystoneProperty::Rotation, &a.rotation, origin, &|v: f64, b: f64| v - b, ids);
        k.opacity = take_keys(properties, KeystoneProperty::Opacity, &a.opacity, origin, &|v: f64, _: f64| v, ids);
        Some(k)
    }

    /// Where the keystone lands when dropped at clip-local `t` on a `clip_duration`-long clip (the drop ghost): its own
    /// length (at most the clip's), placed by `anchor` and kept inside the clip.
    pub fn placement(&self, t: Time, clip_duration: Time) -> KeystoneSpan {
        let d = self.duration.min(clip_duration);
        let start = match self.anchor {
            KeystoneAnchor::ClipStart => Time::ZERO,
            KeystoneAnchor::ClipEnd => clip_duration - d,
            KeystoneAnchor::Free => {
                let half = EffectPreset::scaled(d, Time::new(1, 1), Time::new(2, 1));
                (t - half).max(Time::ZERO).min(clip_duration - d)
            }
        };
        KeystoneSpan { start, duration: d, properties: self.properties() }
    }

    /// The id of built-in keystone `n`.
    pub fn built_in_id(n: i64) -> Id {
        let id = Id::parse(&format!("{BUILT_IN_PREFIX}{n:012}"));
        debug_assert!(id.is_some(), "built-in keystone number {n}");
        id.unwrap_or(Id::NIL)
    }

    /// The keystone ships with the app.
    pub fn is_built_in(&self) -> bool {
        self.id.to_string().to_uppercase().starts_with(BUILT_IN_PREFIX)
    }

    /// Hidden by the consolidation (`hidden_catalog`): a built-in that equals a marker, an effect, a command or a Move
    /// transition. Not listed, still applied when something holds it.
    pub fn is_hidden(id: Id) -> bool {
        hidden_catalog::is_active() && hidden_catalog::KEYSTONE_NUMBERS.iter().any(|n| Self::built_in_id(*n) == id)
    }

    /// The built-in with this name.
    pub fn built_in_named(name: &str) -> Option<Keystone> {
        Self::built_ins().into_iter().find(|k| k.name == name)
    }

    /// The built-in keystones, in panel order.
    pub fn built_ins() -> Vec<Keystone> {
        let ms = |v: i64| Time::new(v, 1000);
        let mut ids = BuiltInKeyIds(0);
        let ids = &mut ids;
        // Decelerating move (fast start, soft landing) and a symmetric ease.
        let (decel_out, decel_in) = (EaseHandle { dx: 0.1, dy: 0.6 }, EaseHandle { dx: 0.6, dy: 0.0 });
        let ease = EaseHandle { dx: 1.0 / 3.0, dy: 0.0 };
        let s = |v: f64| Vec2::new(v, v);
        let shake: [(i64, Vec2); 8] = [
            (0, Vec2::ZERO),
            (60, Vec2::new(0.012, -0.008)),
            (120, Vec2::new(-0.014, 0.006)),
            (180, Vec2::new(0.009, 0.011)),
            (240, Vec2::new(-0.007, -0.009)),
            (300, Vec2::new(0.005, 0.004)),
            (360, Vec2::new(-0.003, -0.002)),
            (420, Vec2::ZERO),
        ];
        let shake_keys: Vec<Keyframe<Vec2>> =
            shake.iter().map(|(t, v)| Keyframe::new(ids.next_id(), ms(*t), *v)).collect();
        let pulse = KeyframeTrack::with_keys(vec![
            eased_key(ids, Time::ZERO, s(1.0), None, Some(ease)),
            eased_key(ids, ms(250), s(1.08), Some(ease), Some(ease)),
            eased_key(ids, ms(500), s(1.0), Some(ease), None),
        ]);
        let slow_push = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, s(1.0)),
            Keyframe::new(ids.next_id(), Time::new(3, 1), s(1.1)),
        ]);
        let mk = |n: i64, name: &str, d: Time, anchor| Keystone::new(Self::built_in_id(n), name, d, anchor);
        let free = KeystoneAnchor::Free;
        let start = KeystoneAnchor::ClipStart;
        let end = KeystoneAnchor::ClipEnd;
        vec![
            Keystone {
                scale: Some(two_keys(ids, ms(400), s(1.0), s(1.2), decel_out, decel_in)),
                ..mk(1, "Punch In", ms(400), free)
            },
            Keystone {
                scale: Some(two_keys(ids, ms(400), s(1.2), s(1.0), decel_out, decel_in)),
                ..mk(2, "Punch Out", ms(400), free)
            },
            Keystone { position: Some(KeyframeTrack::with_keys(shake_keys)), ..mk(3, "Shake", ms(420), free) },
            Keystone { scale: Some(pulse), ..mk(4, "Pulse", ms(500), free) },
            Keystone {
                position: Some(two_keys(ids, ms(500), Vec2::new(-1.0, 0.0), Vec2::ZERO, decel_out, decel_in)),
                ..mk(5, "Slide In Left", ms(500), start)
            },
            Keystone {
                position: Some(two_keys(ids, ms(500), Vec2::new(1.0, 0.0), Vec2::ZERO, decel_out, decel_in)),
                ..mk(6, "Slide In Right", ms(500), start)
            },
            Keystone {
                position: Some(two_keys(ids, ms(500), Vec2::ZERO, Vec2::new(-1.0, 0.0), decel_in, decel_out)),
                ..mk(7, "Slide Out Left", ms(500), end)
            },
            Keystone {
                opacity: Some(two_keys(ids, ms(500), 0.0, 1.0, ease, ease)),
                ..mk(8, "Fade In", ms(500), start)
            },
            Keystone { opacity: Some(two_keys(ids, ms(500), 1.0, 0.0, ease, ease)), ..mk(9, "Fade Out", ms(500), end) },
            Keystone {
                scale: Some(two_keys(ids, ms(600), s(0.6), s(1.0), decel_out, decel_in)),
                rotation: Some(two_keys(ids, ms(600), -90.0, 0.0, decel_out, decel_in)),
                opacity: Some(two_keys(ids, ms(300), 0.0, 1.0, ease, ease)),
                ..mk(10, "Spin In", ms(600), start)
            },
            Keystone { scale: Some(slow_push), ..mk(11, "Slow Push", Time::new(3, 1), free) },
        ]
    }

    /// The JSON stored in `PresetItem.payload`, keys sorted.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        let _plain = EncodeContext::plain();
        // A `Value` keeps its object keys sorted (`preserve_order` is on in the app build: use `sq_core_time::json_sorted`).
        serde_json::to_vec(&sq_core_time::json_sorted::to_value(self)?)
    }

    /// Decodes a payload; a newer `version` than this build understands is refused.
    pub fn from_payload(payload: &[u8], version: i64) -> Result<Keystone, PayloadReadError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(PayloadError::NewerVersion { found: version, supported: Self::PAYLOAD_VERSION }.into());
        }
        serde_json::from_slice(payload).map_err(PayloadReadError::Json)
    }

    /// The keystone's keys placed at clip-local `start`, stretched to `duration`, denormalised for `frame_size`, with fresh
    /// ids and the keystone's own curve if it has one. Static values are the first key's.
    fn preset(
        &self,
        start: Time,
        duration: Time,
        frame_size: Vec2,
        clip_duration: Time,
        ids: &mut dyn IdSource,
    ) -> EffectPreset {
        let len = self.duration;
        let easing = self.easing.as_ref();
        let (w, h) = (frame_size.x, frame_size.y);
        let mut p = EffectPreset::new(Anchor::Start, clip_duration);
        p.position = place_keys(
            &self.position,
            &|k: &Keyframe<Vec2>| {
                let mut n = k.clone();
                n.value = Vec2::new(k.value.x * w, k.value.y * h);
                n.in_tangent = Vec2::new(k.in_tangent.x * w, k.in_tangent.y * h);
                n.out_tangent = Vec2::new(k.out_tangent.x * w, k.out_tangent.y * h);
                n
            },
            start,
            duration,
            len,
            easing,
            ids,
        );
        p.scale = place_keys(&self.scale, &|k: &Keyframe<Vec2>| k.clone(), start, duration, len, easing, ids);
        p.rotation = place_keys(&self.rotation, &|k: &Keyframe<f64>| k.clone(), start, duration, len, easing, ids);
        p.opacity = place_keys(&self.opacity, &|k: &Keyframe<f64>| k.clone(), start, duration, len, easing, ids);
        p
    }
}

/// A two-key eased track from `a` at 0 to `b` at `d`.
fn two_keys<V: KeyframeValue>(
    ids: &mut BuiltInKeyIds,
    d: Time,
    a: V,
    b: V,
    out: EaseHandle,
    in_h: EaseHandle,
) -> KeyframeTrack<V> {
    let mut k0 = Keyframe::new(ids.next_id(), Time::ZERO, a);
    k0.interpolation = Interpolation::Bezier;
    k0.out_handle = out;
    let mut k1 = Keyframe::new(ids.next_id(), d, b);
    k1.interpolation = Interpolation::Bezier;
    k1.in_handle = in_h;
    KeyframeTrack::with_keys(vec![k0, k1])
}

/// A Bezier key with the given handles.
fn eased_key(
    ids: &mut BuiltInKeyIds,
    t: Time,
    v: Vec2,
    in_h: Option<EaseHandle>,
    out_h: Option<EaseHandle>,
) -> Keyframe<Vec2> {
    let mut k = Keyframe::new(ids.next_id(), t, v);
    k.interpolation = Interpolation::Bezier;
    if let Some(h) = in_h {
        k.in_handle = h;
    }
    if let Some(h) = out_h {
        k.out_handle = h;
    }
    k
}

/// Sequential placeholder ids for the built-in keys (replaced by fresh ones whenever a keystone is applied).
struct BuiltInKeyIds(u64);

impl IdSource for BuiltInKeyIds {
    fn next_id(&mut self) -> Id {
        self.0 += 1;
        Id::fixed(self.0)
    }
}

/// The keys of one property as a keystone track: times relative to `origin`, values through `f(value, base)` where `base`
/// is the property's value at `origin`.
fn take_keys<V: KeyframeValue>(
    properties: &BTreeSet<KeystoneProperty>,
    p: KeystoneProperty,
    prop: &AnimatedProperty<V>,
    origin: Time,
    f: &dyn Fn(V, V) -> V,
    ids: &mut dyn IdSource,
) -> Option<KeyframeTrack<V>> {
    if !properties.contains(&p) || !prop.is_animated() {
        return None;
    }
    let base = prop.value_at_local(origin);
    Some(KeyframeTrack::with_keys(
        prop.track
            .keys
            .iter()
            .map(|k| {
                let mut n = k.clone();
                n.id = ids.next_id();
                n.time = k.time - origin;
                n.value = f(k.value.clone(), base.clone());
                n
            })
            .collect(),
    ))
}

/// A keystone track placed on a clip: key times stretched from `len` to `duration` and moved to `start`, new ids, the
/// keystone's own `easing` applied; the static value is the first key's.
fn place_keys<V: KeyframeValue>(
    track: &Option<KeyframeTrack<V>>,
    f: &dyn Fn(&Keyframe<V>) -> Keyframe<V>,
    start: Time,
    duration: Time,
    len: Time,
    easing: Option<&EasingCurve>,
    ids: &mut dyn IdSource,
) -> Option<AnimatedProperty<V>> {
    let track = track.as_ref()?;
    let first = track.keys.first()?;
    let placed = KeyframeTrack::with_keys(
        track
            .keys
            .iter()
            .map(|k| {
                let mut n = f(k);
                n.id = ids.next_id();
                n.time = start + if len > Time::ZERO { EffectPreset::scaled(k.time, duration, len) } else { k.time };
                if let Some(e) = easing {
                    e.apply(&mut n, EaseSide::Both);
                }
                n
            })
            .collect(),
    );
    Some(AnimatedProperty { value: f(first).value, track: placed })
}

/// Applying and restretching keystones on a clip (Swift `extension Clip` in Keystone.swift).
pub trait ClipKeystoneExt {
    /// Applies `keystone` as ordinary keys from clip-local `start` for `duration`, added onto the clip's own values
    /// (Position and Rotation add, Scale and Opacity multiply; see `ApplyMode::Relative`).
    fn apply_keystone(
        &mut self,
        keystone: &Keystone,
        start: Time,
        duration: Time,
        frame_size: Vec2,
        ids: &mut dyn IdSource,
    ) -> KeystoneSpan;
    /// Edge drag on an applied keystone: the keys of `span.properties` inside `span` move linearly into `new` (easing is
    /// normalized per segment, so it is kept). Keys outside `span` stay; a moved key wins at an identical time. False
    /// (nothing changes) for an empty old or new span.
    fn restretch_keystone(&mut self, span: &KeystoneSpan, new: &KeystoneSpan) -> bool;
}

fn remap<V: KeyframeValue>(p: &mut AnimatedProperty<V>, span: &KeystoneSpan, new: &KeystoneSpan) {
    p.track.edit_keys(|keys| {
        let (mut outside, mut moved) = (Vec::new(), Vec::new());
        for k in keys.drain(..) {
            if k.time >= span.start && k.time <= span.end() {
                let mut n = k;
                n.time = new.start + EffectPreset::scaled(n.time - span.start, new.duration, span.duration);
                moved.push(n);
            } else {
                outside.push(k);
            }
        }
        outside.extend(moved);
        *keys = outside;
    });
}

impl ClipKeystoneExt for Clip {
    fn apply_keystone(
        &mut self,
        keystone: &Keystone,
        start: Time,
        duration: Time,
        frame_size: Vec2,
        ids: &mut dyn IdSource,
    ) -> KeystoneSpan {
        let preset = keystone.preset(start, duration, frame_size, self.duration(), ids);
        self.apply_preset(&preset, ApplyMode::Relative, None, ids);
        KeystoneSpan { start, duration, properties: keystone.properties() }
    }

    fn restretch_keystone(&mut self, span: &KeystoneSpan, new: &KeystoneSpan) -> bool {
        if span.duration <= Time::ZERO || new.duration <= Time::ZERO {
            return false;
        }
        let a = &mut self.animation;
        if span.properties.contains(&KeystoneProperty::Position) {
            remap(&mut a.position, span, new);
        }
        if span.properties.contains(&KeystoneProperty::Scale) {
            remap(&mut a.scale, span, new);
        }
        if span.properties.contains(&KeystoneProperty::Rotation) {
            remap(&mut a.rotation, span, new);
        }
        if span.properties.contains(&KeystoneProperty::Opacity) {
            remap(&mut a.opacity, span, new);
        }
        true
    }
}

/// Applying keystones through the timeline (Swift `extension Timeline` in Keystone.swift).
pub trait TimelineKeystoneExt {
    /// Applies `keystone` to the video clip `id` (sequence frame size for Position). `ClipNotFound`, `WrongTrackKind`
    /// (audio) or `TrackLocked`; nothing changes then.
    fn apply_keystone(
        &mut self,
        keystone: &Keystone,
        id: Id,
        start: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<KeystoneSpan, EditError>;
    /// `ClipKeystoneExt::restretch_keystone` on clip `id`. `ClipNotFound`, `TrackLocked`, or `EmptyClip` for an empty span.
    fn restretch_keystone(&mut self, id: Id, span: &KeystoneSpan, new: &KeystoneSpan) -> Result<(), EditError>;
}

impl TimelineKeystoneExt for Timeline {
    fn apply_keystone(
        &mut self,
        keystone: &Keystone,
        id: Id,
        start: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<KeystoneSpan, EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[m.track].kind != TrackKind::Video {
            return Err(EditError::WrongTrackKind);
        }
        if self.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let mut c = m.clip;
        let frame = Vec2::new(self.format.display_width() as f64, self.format.height as f64);
        let span = c.apply_keystone(keystone, start, duration, frame, ids);
        self.tracks[m.track].replace(c);
        Ok(span)
    }

    fn restretch_keystone(&mut self, id: Id, span: &KeystoneSpan, new: &KeystoneSpan) -> Result<(), EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let mut c = m.clip;
        if !c.restretch_keystone(span, new) {
            return Err(EditError::EmptyClip);
        }
        self.tracks[m.track].replace(c);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn ms(n: i64) -> Time {
        Time::new(n, 1000)
    }

    const FRAME: Vec2 = Vec2 { x: 1920.0, y: 1080.0 };
    const EASE_OUT: EaseHandle = EaseHandle { dx: 0.6, dy: 0.0 };
    const EASE_IN: EaseHandle = EaseHandle { dx: 0.4, dy: 0.1 };

    fn clip(ids: &mut SequentialIds, kind: TrackKind) -> Clip {
        Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(Time::ZERO, s(6)), s(10))
    }

    fn key<V: KeyframeValue>(ids: &mut SequentialIds, t: Time, v: V) -> Keyframe<V> {
        Keyframe::new(ids.next_id(), t, v)
    }

    fn bez<V: KeyframeValue>(
        ids: &mut SequentialIds,
        t: Time,
        v: V,
        in_h: EaseHandle,
        out_h: EaseHandle,
    ) -> Keyframe<V> {
        let mut k = key(ids, t, v);
        k.interpolation = Interpolation::Bezier;
        k.in_handle = in_h;
        k.out_handle = out_h;
        k
    }

    /// Scale 1.5 to 1.8 and Position 100 to 292 px (x) between 2 s and 3 s, eased.
    fn animated_clip(ids: &mut SequentialIds) -> Clip {
        let mut c = clip(ids, TrackKind::Video);
        let lin = EaseHandle::LINEAR;
        c.animation.scale.track = KeyframeTrack::with_keys(vec![
            bez(ids, s(2), Vec2::new(1.5, 1.5), lin, EASE_OUT),
            bez(ids, s(3), Vec2::new(1.8, 1.8), EASE_IN, lin),
        ]);
        c.animation.position.track = KeyframeTrack::with_keys(vec![
            key(ids, s(2), Vec2::new(100.0, 50.0)),
            key(ids, s(3), Vec2::new(292.0, 50.0)),
        ]);
        c.animation.rotation.track = KeyframeTrack::with_keys(vec![key(ids, s(2), 10.0), key(ids, s(3), 40.0)]);
        c
    }

    fn props(p: &[KeystoneProperty]) -> BTreeSet<KeystoneProperty> {
        p.iter().copied().collect()
    }

    fn capture(c: &Clip, p: &[KeystoneProperty], ids: &mut SequentialIds) -> Option<Keystone> {
        Keystone::capture(c, &props(p), FRAME, "Mine", ids)
    }

    fn times<V>(p: &AnimatedProperty<V>) -> Vec<Time> {
        p.track.keys.iter().map(|k| k.time).collect()
    }

    #[test]
    fn capture_normalises_time_and_values() {
        let mut ids = SequentialIds::default();
        let c = animated_clip(&mut ids);
        use KeystoneProperty::*;
        let k = capture(&c, &[Scale, Position, Rotation], &mut ids).unwrap();
        assert_eq!((k.name.as_str(), k.duration), ("Mine", s(1)));
        let sc = k.scale.as_ref().unwrap();
        assert_eq!(sc.keys.iter().map(|k| k.time).collect::<Vec<_>>(), [Time::ZERO, s(1)]);
        assert_eq!(sc.keys[0].value, Vec2::new(1.0, 1.0));
        assert!((sc.keys[1].value.x - 1.2).abs() < 1e-12);
        assert!(sc.keys[0].out_handle == EASE_OUT && sc.keys[1].in_handle == EASE_IN);
        assert_eq!(sc.keys[0].interpolation, Interpolation::Bezier);
        let p = k.position.as_ref().unwrap();
        assert_eq!(p.keys[0].value, Vec2::ZERO);
        assert!((p.keys[1].value.x - 0.1).abs() < 1e-12 && p.keys[1].value.y == 0.0);
        assert_eq!(
            k.rotation.as_ref().map(|t| t.keys.iter().map(|k| k.value).collect::<Vec<_>>()),
            Some(vec![0.0, 30.0])
        );
        assert!(k.opacity.is_none());
    }

    #[test]
    fn capture_keeps_opacity_absolute_and_refuses_too_few_keys() {
        let mut ids = SequentialIds::default();
        let mut c = clip(&mut ids, TrackKind::Video);
        c.animation.opacity.track =
            KeyframeTrack::with_keys(vec![key(&mut ids, s(1), 0.0), key(&mut ids, ms(1500), 0.8)]);
        let k = capture(&c, &[KeystoneProperty::Opacity], &mut ids).unwrap();
        assert_eq!(
            k.opacity.as_ref().map(|t| t.keys.iter().map(|k| k.value).collect::<Vec<_>>()),
            Some(vec![0.0, 0.8])
        );
        assert_eq!(k.duration, ms(500));

        let plain = clip(&mut ids, TrackKind::Video);
        assert!(capture(&plain, &[KeystoneProperty::Scale, KeystoneProperty::Position], &mut ids).is_none());
        let animated = animated_clip(&mut ids);
        assert!(capture(&animated, &[KeystoneProperty::Opacity], &mut ids).is_none());
        let mut single = clip(&mut ids, TrackKind::Video);
        single.animation.rotation.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(1), 5.0)]);
        assert!(capture(&single, &[KeystoneProperty::Rotation], &mut ids).is_none());
    }

    #[test]
    fn apply_places_stretched_keys_and_keeps_easing() {
        let mut ids = SequentialIds::default();
        let src = animated_clip(&mut ids);
        let k = capture(&src, &[KeystoneProperty::Scale], &mut ids).unwrap();
        let mut c = clip(&mut ids, TrackKind::Video);
        let span = c.apply_keystone(&k, s(1), s(2), FRAME, &mut ids);
        assert_eq!(span, KeystoneSpan { start: s(1), duration: s(2), properties: props(&[KeystoneProperty::Scale]) });
        let keys = &c.animation.scale.track.keys;
        assert_eq!(keys.iter().map(|k| k.time).collect::<Vec<_>>(), [s(1), s(3)]);
        assert_eq!(keys[0].value, Vec2::new(1.0, 1.0));
        assert!((keys[1].value.x - 1.2).abs() < 1e-12);
        assert!(keys[0].out_handle == EASE_OUT && keys[1].in_handle == EASE_IN);
        assert!(c.animation.position.track.is_empty() && c.animation.rotation.track.is_empty());
    }

    #[test]
    fn apply_is_relative_to_the_clips_own_values() {
        let mut ids = SequentialIds::default();
        let src = animated_clip(&mut ids);
        use KeystoneProperty::*;
        let k = capture(&src, &[Scale, Position, Rotation], &mut ids).unwrap();
        let mut c = clip(&mut ids, TrackKind::Video);
        c.animation.scale = AnimatedProperty::new(Vec2::new(2.0, 2.0));
        c.animation.position = AnimatedProperty::new(Vec2::new(10.0, 20.0));
        c.animation.rotation = AnimatedProperty::new(5.0);
        c.apply_keystone(&k, Time::ZERO, k.duration, Vec2::new(3840.0, 2160.0), &mut ids);
        let sx: Vec<f64> = c.animation.scale.track.keys.iter().map(|k| (k.value.x * 1000.0).round()).collect();
        assert_eq!(sx, [2000.0, 2400.0]);
        let pos: Vec<Vec2> = c.animation.position.track.keys.iter().map(|k| k.value).collect();
        assert_eq!(pos, [Vec2::new(10.0, 20.0), Vec2::new(10.0 + 384.0, 20.0)]);
        let rot: Vec<f64> = c.animation.rotation.track.keys.iter().map(|k| k.value).collect();
        assert_eq!(rot, [5.0, 35.0]);
    }

    #[test]
    fn apply_twice_gives_fresh_key_ids() {
        let mut ids = SequentialIds::default();
        let k = Keystone::built_in_named("Shake").unwrap();
        let mut c = clip(&mut ids, TrackKind::Video);
        c.apply_keystone(&k, Time::ZERO, k.duration, FRAME, &mut ids);
        let first: BTreeSet<Id> = c.animation.position.track.keys.iter().map(|k| k.id).collect();
        c.apply_keystone(&k, s(3), k.duration, FRAME, &mut ids);
        let all: Vec<Id> = c.animation.position.track.keys.iter().map(|k| k.id).collect();
        assert_eq!(all.iter().collect::<BTreeSet<_>>().len(), all.len());
        assert!(first.iter().all(|i| all.contains(i)));
    }

    #[test]
    fn easing_override_replaces_every_keys_easing() {
        let mut ids = SequentialIds::default();
        let src = animated_clip(&mut ids);
        let mut k = capture(&src, &[KeystoneProperty::Scale, KeystoneProperty::Position], &mut ids).unwrap();
        let e = EasingCurve::premiere_default();
        k.easing = Some(e.clone());
        let mut c = clip(&mut ids, TrackKind::Video);
        c.apply_keystone(&k, Time::ZERO, k.duration, FRAME, &mut ids);
        for key in &c.animation.scale.track.keys {
            assert_eq!(key.interpolation, Interpolation::Bezier);
            assert!(key.out_handle == e.out_handle && key.in_handle == e.in_handle);
        }
        assert!(c.animation.position.track.keys.iter().all(|k| k.out_handle == e.out_handle));
    }

    #[test]
    fn placement_centres_on_the_drop_point_stays_inside_and_follows_the_anchor() {
        let mut ids = SequentialIds::default();
        let mut k = Keystone::new(ids.next_id(), "k", s(2), KeystoneAnchor::Free);
        k.rotation = Some(KeyframeTrack::with_keys(vec![key(&mut ids, Time::ZERO, 0.0), key(&mut ids, s(2), 9.0)]));
        let rot = props(&[KeystoneProperty::Rotation]);
        assert_eq!(k.placement(s(3), s(6)), KeystoneSpan { start: s(2), duration: s(2), properties: rot.clone() });
        assert_eq!(k.placement(ms(200), s(6)).start, Time::ZERO);
        assert_eq!(k.placement(s(6), s(6)).start, s(4));
        assert_eq!(k.placement(s(1), s(1)), KeystoneSpan { start: Time::ZERO, duration: s(1), properties: rot });
        k.anchor = KeystoneAnchor::ClipStart;
        assert_eq!(k.placement(s(4), s(6)).start, Time::ZERO);
        k.anchor = KeystoneAnchor::ClipEnd;
        assert_eq!(k.placement(s(1), s(6)).start, s(4));
    }

    #[test]
    fn restretch_scales_only_the_spans_keys_and_refuses_an_empty_span() {
        let mut ids = SequentialIds::default();
        let src = animated_clip(&mut ids);
        let k = capture(&src, &[KeystoneProperty::Scale], &mut ids).unwrap();
        let mut c = clip(&mut ids, TrackKind::Video);
        c.animation.rotation.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(1), 3.0)]);
        c.animation.scale.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(5), Vec2::new(3.0, 3.0))]);
        let span = c.apply_keystone(&k, s(1), s(1), FRAME, &mut ids);
        let wider = KeystoneSpan { start: s(1), duration: s(3), properties: span.properties.clone() };
        assert!(c.restretch_keystone(&span, &wider));
        assert_eq!(times(&c.animation.scale), [s(1), s(4), s(5)]);
        assert!(c.animation.scale.track.keys[0].out_handle == EASE_OUT);
        assert_eq!(times(&c.animation.rotation), [s(1)]);

        let empty =
            KeystoneSpan { start: Time::ZERO, duration: Time::ZERO, properties: props(&[KeystoneProperty::Scale]) };
        let mut plain = clip(&mut ids, TrackKind::Video);
        assert!(!plain.restretch_keystone(&KeystoneSpan { duration: s(1), ..empty.clone() }, &empty));
    }

    #[test]
    fn timeline_apply_uses_the_sequence_frame_and_checks_the_track() {
        let mut ids = SequentialIds::default();
        let (vc, ac) = (clip(&mut ids, TrackKind::Video), clip(&mut ids, TrackKind::Audio));
        let (mut v, mut a) = (Track::new(ids.next_id(), TrackKind::Video), Track::new(ids.next_id(), TrackKind::Audio));
        assert!(v.overwrite(vc.clone(), &mut ids).is_ok() && a.overwrite(ac.clone(), &mut ids).is_ok());
        let mut f = SequenceFormat::new(Time::new(1, 25));
        f.width = 1000;
        f.height = 500;
        let mut tl = Timeline::new(ids.next_id(), "t", f, vec![v, a]);
        let mut k = Keystone::new(ids.next_id(), "Slide", s(1), KeystoneAnchor::Free);
        k.position = Some(KeyframeTrack::with_keys(vec![
            key(&mut ids, Time::ZERO, Vec2::new(-1.0, 0.0)),
            key(&mut ids, s(1), Vec2::ZERO),
        ]));
        let span = tl.apply_keystone(&k, vc.id, Time::ZERO, s(1), &mut ids).unwrap();
        assert_eq!(span.properties, props(&[KeystoneProperty::Position]));
        let pos = |tl: &Timeline| tl.find(vc.id).unwrap().clip.animation.position.track.keys.clone();
        assert_eq!(pos(&tl).iter().map(|k| k.value).collect::<Vec<_>>(), [Vec2::new(-1000.0, 0.0), Vec2::ZERO]);
        assert_eq!(tl.apply_keystone(&k, ac.id, Time::ZERO, s(1), &mut ids), Err(EditError::WrongTrackKind));
        let wider = KeystoneSpan { start: Time::ZERO, duration: s(2), properties: span.properties.clone() };
        assert!(tl.restretch_keystone(vc.id, &span, &wider).is_ok());
        assert_eq!(pos(&tl).iter().map(|k| k.time).collect::<Vec<_>>(), [Time::ZERO, s(2)]);
    }

    #[test]
    fn built_ins_are_usable_and_hidden_numbers_follow_the_catalog() {
        let mut ids = SequentialIds::default();
        let built_ins = Keystone::built_ins();
        assert!(built_ins.len() >= 8);
        assert_eq!(built_ins.iter().map(|k| k.id).collect::<BTreeSet<_>>().len(), built_ins.len());
        assert_eq!(built_ins.iter().map(|k| k.name.as_str()).collect::<BTreeSet<_>>().len(), built_ins.len());
        for k in &built_ins {
            assert!(k.duration > Time::ZERO, "{}", k.name);
            assert!(!k.properties().is_empty(), "{}", k.name);
            assert!(k.is_built_in());
            let mut c = clip(&mut ids, TrackKind::Video);
            assert_eq!(c.apply_keystone(k, Time::ZERO, k.duration, FRAME, &mut ids).properties, k.properties());
        }
        assert_eq!(Keystone::built_in_id(1).to_string().to_uppercase(), "6B657973-746F-6E65-0000-000000000001");
        assert!(!Keystone::is_hidden(Keystone::built_in_id(10)));
        assert!(Keystone::is_hidden(Keystone::built_in_id(1)) || !hidden_catalog::is_active());
        assert!(!Keystone::is_hidden(ids.next_id()));
    }

    #[test]
    fn payload_round_trips_and_rejects_newer_versions() {
        let mut k = Keystone::built_in_named("Punch In").unwrap();
        k.easing = Some(EasingCurve::ease_in_out());
        let bytes = k.payload().unwrap();
        assert_eq!(Keystone::from_payload(&bytes, Keystone::PAYLOAD_VERSION).unwrap(), k);
        let newer = Keystone::from_payload(&bytes, 99);
        assert!(matches!(
            newer,
            Err(PayloadReadError::Version(PayloadError::NewerVersion { found: 99, supported: 2 }))
        ));
        assert_eq!(k.written_payload_version(), 1);
        k.scale.as_mut().unwrap().keys[0].interpolation = Interpolation::HoldAhead;
        assert_eq!(k.written_payload_version(), 2);
    }
}
