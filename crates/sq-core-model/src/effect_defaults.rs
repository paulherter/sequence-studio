// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectDefaults.swift
//! FB-W: the user's own starting values for effects and transitions ("Use as Default" in Effect Controls). Lives in the
//! user library (never in a project), so every project and every new instance picks it up.
//!
//! - Effects: one default per effect kind. Key times are clip-local, i.e. relative to the clip's first frame, and land
//!   at the same offsets on the clip a new instance is added to. Color and generator-owned kinds have none.
//! - Transitions: one default per kind (kind, length, easing, direction, softness, motion blur, element parameters),
//!   used at every place a transition of that kind is added: cuts, clip starts and clip ends. The place decides the
//!   alignment.
//! - Order: a preset wins over a default (it is applied on top); a Style Kit's motion settings apply after the default.

mod legacy_shadow;

use crate::{
    AnimatedProperty, Clip, ClipEffect, EffectCatalog, TransitionAlignment, TransitionDirection, TransitionKind,
};
use serde::{Deserialize, Serialize};
use sq_core_time::{EasingCurve, EncodeContext, Id, IdSource, KeyframeTrack, KeyframeValue, Time};
use std::collections::BTreeMap;
use std::fmt;

/// The user's default effects and transitions.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct EffectDefaults {
    /// By effect kind. Ids inside are meaningless (every use gets fresh ones).
    pub effects: BTreeMap<String, ClipEffect>,
    /// By `TransitionKind` stored name.
    pub transitions: BTreeMap<String, TransitionPreset>,
}

/// A saved transition: kind, length, alignment, easing and the style a kind uses (direction, softness, motion blur). Stored
/// with effective values, so a preset looks the same even if a kind's defaults change later. Payload of `.transition`
/// library presets. (Swift: EffectPreset.swift.)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransitionPreset {
    /// Style.
    pub kind: TransitionKind,
    /// Requested duration.
    pub duration: Time,
    /// Never `Custom` (a custom offset is specific to one cut): that is saved as `Center`.
    pub alignment: TransitionAlignment,
    /// Progress curve.
    pub easing: EasingCurve,
    /// Direction.
    pub direction: TransitionDirection,
    /// Soft Wipe edge.
    pub softness: f64,
    /// Motion blur shutter in frames.
    pub motion_blur: f64,
    /// An element transition's parameters (`Transition::params`); `None` for every other kind and in older presets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<BTreeMap<String, f64>>,
    /// Travels the other way; `None` = not reversed and in older presets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reversed: Option<bool>,
    /// Border width; `None` = none and in older presets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub border_width: Option<f64>,
    /// Border color as display-encoded RGB bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub border_color: Option<Vec<u8>>,
}

impl TransitionPreset {
    /// Version of the payload format.
    pub const PAYLOAD_VERSION: i64 = 1;

    /// The bytes stored in the user library.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        let _plain = EncodeContext::plain();
        serde_json::to_vec(self)
    }

    /// Reads a library payload of `version`. A hand-edited file must not smuggle in a per-cut (`Custom`) alignment.
    pub fn from_payload(payload: &[u8], version: i64) -> Result<TransitionPreset, PayloadReadError> {
        EffectDefaults::check_payload_version_of(version, Self::PAYLOAD_VERSION)?;
        let mut p: TransitionPreset = serde_json::from_slice(payload).map_err(PayloadReadError::Json)?;
        if p.alignment == TransitionAlignment::Custom {
            p.alignment = TransitionAlignment::Center;
        }
        Ok(p)
    }
}

/// Why a library payload could not be read.
#[derive(Debug)]
pub enum PayloadReadError {
    /// Written by a newer build.
    Version(PayloadError),
    /// Not valid JSON of the expected shape.
    Json(serde_json::Error),
}

impl From<PayloadError> for PayloadReadError {
    fn from(e: PayloadError) -> Self {
        PayloadReadError::Version(e)
    }
}

impl fmt::Display for PayloadReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PayloadReadError::Version(e) => e.fmt(f),
            PayloadReadError::Json(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for PayloadReadError {}

/// A payload this build cannot read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadError {
    /// Written by a newer build.
    NewerVersion {
        /// The payload's version.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
}

impl fmt::Display for PayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let PayloadError::NewerVersion { found, supported } = self;
        write!(f, "payload version {found} is newer than the supported {supported}")
    }
}

impl std::error::Error for PayloadError {}

impl EffectDefaults {
    /// Version of the payload format.
    pub const PAYLOAD_VERSION: i64 = 1;

    /// No effect and no transition default.
    pub fn is_empty(&self) -> bool {
        self.effects.is_empty() && self.transitions.is_empty()
    }

    /// There is a default for effect `kind`.
    pub fn has_default_effect(&self, kind: &str) -> bool {
        self.effects.contains_key(kind)
    }

    /// The default of effect `kind`.
    pub fn effect(&self, kind: &str) -> Option<&ClipEffect> {
        self.effects.get(kind)
    }

    /// Forgets the default of effect `kind`.
    pub fn remove_default_effect(&mut self, kind: &str) {
        self.effects.remove(kind);
    }

    /// There is a default for the transition kind with this stored name.
    pub fn has_default_transition(&self, kind: &str) -> bool {
        self.transitions.contains_key(kind)
    }

    /// Forgets the default of the transition kind with this stored name.
    pub fn remove_default_transition(&mut self, kind: &str) {
        self.transitions.remove(kind);
    }

    /// The bytes stored in the user library.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        let _plain = EncodeContext::plain();
        serde_json::to_vec(self)
    }

    /// Whether a payload of `version` can be read.
    pub fn check_payload_version(version: i64) -> Result<(), PayloadError> {
        Self::check_payload_version_of(version, Self::PAYLOAD_VERSION)
    }

    fn check_payload_version_of(version: i64, supported: i64) -> Result<(), PayloadError> {
        if version <= supported { Ok(()) } else { Err(PayloadError::NewerVersion { found: version, supported }) }
    }

    /// Reads a library payload of `version`: legacy Drop Shadow colors are upgraded and a `Custom` transition alignment is
    /// saved as `Center`. New key ids come from `ids`.
    pub fn from_payload(
        payload: &[u8],
        version: i64,
        ids: &mut dyn IdSource,
    ) -> Result<EffectDefaults, PayloadReadError> {
        Self::check_payload_version(version)?;
        let mut d: EffectDefaults = serde_json::from_slice(payload).map_err(PayloadReadError::Json)?;
        for e in d.effects.values_mut() {
            *e = e.upgrading_legacy_shadow_color(ids);
        }
        for p in d.transitions.values_mut().filter(|p| p.alignment == TransitionAlignment::Custom) {
            p.alignment = TransitionAlignment::Center;
        }
        Ok(d)
    }

    /// Known effect kinds except Color (a grade belongs to its footage) and generator-owned looks.
    pub fn can_have_default(kind: &str) -> bool {
        kind != ClipEffect::COLOR_KIND
            && EffectCatalog::spec_for(kind).is_some()
            && !EffectCatalog::is_generator_owned(kind)
    }

    /// Makes `effect`'s values the default of its kind. `keep_keyframes` false: every parameter is frozen at clip-local `t`
    /// (the value shown at the playhead). False for a kind that cannot have a default.
    pub fn set_default_effect(
        &mut self,
        effect: &ClipEffect,
        keep_keyframes: bool,
        t: Time,
        ids: &mut dyn IdSource,
    ) -> bool {
        if !Self::can_have_default(&effect.kind) {
            return false;
        }
        let mut e = if keep_keyframes { effect.clone() } else { effect.frozen_at_local(t) };
        e.id = ids.next_id();
        e.enabled = true;
        self.effects.insert(effect.kind.clone(), e);
        true
    }

    /// A new instance of `kind`: the user default (fresh ids for the effect and every key) laid over the factory values, so
    /// parameters added to the catalog since start at factory and ones it dropped are ignored. Factory when there is no
    /// default; `None` for an unknown kind.
    pub fn make_effect(&self, kind: &str, ids: &mut dyn IdSource) -> Option<ClipEffect> {
        let mut out = ClipEffect::make(ids.next_id(), kind)?;
        let Some(saved) = self.effects.get(kind).filter(|_| Self::can_have_default(kind)) else { return Some(out) };
        for (key, slot) in out.parameters.iter_mut() {
            if let Some(p) = saved.parameters.get(key) {
                *slot = p.with_fresh_key_ids(ids);
            }
        }
        for (key, slot) in out.colors.iter_mut() {
            if let Some(p) = saved.colors.get(key) {
                *slot = p.with_fresh_key_ids(ids);
            }
        }
        for (key, slot) in out.points.iter_mut() {
            if let Some(p) = saved.points.get(key) {
                *slot = p.with_fresh_key_ids(ids);
            }
        }
        Some(out)
    }

    /// The default of the transition `kind`.
    pub fn transition(&self, kind: TransitionKind) -> Option<&TransitionPreset> {
        self.transitions.get(&transition_name(kind))
    }

    /// Makes `preset` (its look and requested length) the default of its kind.
    pub fn set_default_transition(&mut self, preset: TransitionPreset) {
        self.transitions.insert(transition_name(preset.kind), preset);
    }
}

/// The stored name of a transition kind (the key of `EffectDefaults::transitions`).
fn transition_name(kind: TransitionKind) -> String {
    serde_json::to_value(kind).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

impl Clip {
    /// "Reset" of an applied effect: its values go back to the user default of its kind (keys included), else to the factory
    /// values. Stays where it is with its id, and is switched on again. False for an unknown id.
    pub fn reset_effect(&mut self, id: Id, defaults: Option<&EffectDefaults>, ids: &mut dyn IdSource) -> bool {
        let Some(i) = self.effects.iter().position(|e| e.id == id) else { return false };
        let none = EffectDefaults::default();
        let Some(fresh) = defaults.unwrap_or(&none).make_effect(&self.effects[i].kind, ids) else { return false };
        let e = &mut self.effects[i];
        e.parameters = fresh.parameters;
        e.colors = fresh.colors;
        e.points = fresh.points;
        e.enabled = true;
        true
    }
}

impl<V: KeyframeValue> AnimatedProperty<V> {
    /// Same value and keys, every key with a new id.
    pub fn with_fresh_key_ids(&self, ids: &mut dyn IdSource) -> AnimatedProperty<V> {
        let mut c = self.clone();
        c.track = KeyframeTrack::with_keys(
            self.track
                .keys
                .iter()
                .map(|k| {
                    let mut k = k.clone();
                    k.id = ids.next_id();
                    k
                })
                .collect(),
        );
        c
    }

    /// Same value and the same keys (time, value, easing) whatever their ids.
    pub fn same_curve(&self, other: &AnimatedProperty<V>) -> bool {
        let plain = |p: &AnimatedProperty<V>| {
            p.track
                .keys
                .iter()
                .map(|k| {
                    let mut k = k.clone();
                    k.id = Id::NIL;
                    k
                })
                .collect::<Vec<_>>()
        };
        self.value == other.value && plain(self) == plain(other)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EffectColor, TrackKind};
    use sq_core_time::{EaseHandle, Interpolation, Keyframe, SequentialIds, TimeRange};

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn clip() -> Clip {
        Clip::new(Id::from_u128(900), "c", Id::from_u128(901), TrackKind::Video, TimeRange::new(f(30), f(60)), f(0))
    }

    fn keyed() -> AnimatedProperty<f64> {
        let mut p = AnimatedProperty::new(1.0);
        p.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0),
            Keyframe::new(Id::from_u128(2), Time::new(1, 1), 5.0),
        ]);
        p
    }

    /// A Gaussian Blur with Blurriness 0 -> 40 over the first 10 frames (clip-local), eased out.
    fn animated_blur(ids: &mut SequentialIds) -> ClipEffect {
        let mut e =
            ClipEffect::make(Id::from_u128(500), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        let mut first = Keyframe::new(ids.next_id(), Time::ZERO, 0.0);
        first.interpolation = Interpolation::Bezier;
        first.out_handle = EaseHandle { dx: 0.6, dy: 0.0 };
        let mut p = AnimatedProperty::new(0.0);
        p.track = KeyframeTrack::with_keys(vec![first, Keyframe::new(ids.next_id(), f(10), 40.0)]);
        e.parameters.insert(ClipEffect::BLURRINESS_KEY.to_string(), p);
        e
    }

    fn sample_preset() -> TransitionPreset {
        TransitionPreset {
            kind: TransitionKind::CrossDissolve,
            duration: f(8),
            alignment: TransitionAlignment::Center,
            easing: EasingCurve::linear(),
            direction: TransitionDirection::Left,
            softness: 0.1,
            motion_blur: 0.0,
            params: None,
            reversed: None,
            border_width: None,
            border_color: None,
        }
    }

    #[test]
    fn fresh_key_ids_keep_the_curve() {
        let mut ids = SequentialIds::default();
        ids.next_id(); // 1 and 2 are the ids of `keyed()`; start behind them
        ids.next_id();
        let p = keyed();
        let q = p.with_fresh_key_ids(&mut ids);
        assert_ne!(p, q);
        assert!(p.same_curve(&q));
        assert_eq!(q.track.keys.iter().map(|k| k.id).collect::<Vec<_>>(), vec![Id::from_u128(3), Id::from_u128(4)]);
        let mut other = q.clone();
        other.track.keys[1].value = 6.0;
        assert!(!p.same_curve(&other));
    }

    #[test]
    fn defaults_round_trip_through_the_payload_and_reject_newer_versions() {
        let mut ids = SequentialIds::default();
        let mut d = EffectDefaults::default();
        assert!(d.is_empty());
        assert!(d.set_default_effect(&animated_blur(&mut ids), true, Time::ZERO, &mut ids));
        d.set_default_transition(sample_preset());
        assert!(d.has_default_effect("gaussianBlur") && d.has_default_transition("crossDissolve"));
        assert_eq!(d.transition(TransitionKind::CrossDissolve), Some(&sample_preset()));
        let data = d.payload().unwrap_or_default();
        let back = EffectDefaults::from_payload(&data, EffectDefaults::PAYLOAD_VERSION, &mut ids);
        assert_eq!(back.ok(), Some(d.clone()));
        assert!(matches!(
            EffectDefaults::from_payload(&data, 2, &mut ids),
            Err(PayloadReadError::Version(PayloadError::NewerVersion { found: 2, supported: 1 }))
        ));
        d.remove_default_effect("gaussianBlur");
        d.remove_default_transition("crossDissolve");
        assert!(d.is_empty() && d.effect("gaussianBlur").is_none());
    }

    #[test]
    fn a_custom_transition_alignment_in_a_payload_becomes_center() {
        let json = br#"{"effects":{},"transitions":{"push":{"kind":"push","duration":{"value":8,"timescale":30},"alignment":"custom",
            "easing":{"id":"00000000-0000-0000-0000-000000000001","name":"Linear","interpolation":"linear",
            "outHandle":{"dx":0.3333333333333333,"dy":0.3333333333333333},"inHandle":{"dx":0.3333333333333333,"dy":0.3333333333333333}},
            "direction":"left","softness":0.1,"motionBlur":0}}}"#;
        let d = EffectDefaults::from_payload(json, 1, &mut SequentialIds::default());
        assert_eq!(
            d.ok().and_then(|d| d.transition(TransitionKind::Push).map(|p| p.alignment)),
            Some(TransitionAlignment::Center)
        );
    }

    #[test]
    fn colour_and_generator_owned_kinds_cannot_have_a_default() {
        let mut ids = SequentialIds::default();
        assert!(!EffectDefaults::can_have_default(ClipEffect::COLOR_KIND));
        assert!(!EffectDefaults::can_have_default("noSuchEffect"));
        assert!(!EffectDefaults::can_have_default(ClipEffect::SHAPE_EFFECT_KIND));
        assert!(EffectDefaults::can_have_default(ClipEffect::GAUSSIAN_BLUR_KIND));
        let mut d = EffectDefaults::default();
        let color = ClipEffect::new(Id::from_u128(7), ClipEffect::COLOR_KIND);
        assert!(!d.set_default_effect(&color, true, Time::ZERO, &mut ids));
        assert!(d.is_empty());
    }

    #[test]
    fn keyframes_come_along_with_fresh_ids_and_stay_clip_local() {
        let mut ids = SequentialIds::default();
        let src = animated_blur(&mut ids);
        let mut d = EffectDefaults::default();
        d.set_default_effect(&src, true, Time::ZERO, &mut ids);
        let key = ClipEffect::BLURRINESS_KEY;
        let saved = d
            .effect("gaussianBlur")
            .and_then(|e| e.parameters.get(key))
            .cloned()
            .unwrap_or_else(|| AnimatedProperty::new(-1.0));
        assert_eq!(saved.track.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![Time::ZERO, f(10)]);
        let a = d.make_effect("gaussianBlur", &mut ids).unwrap_or_else(|| panic!("a"));
        let b = d.make_effect("gaussianBlur", &mut ids).unwrap_or_else(|| panic!("b"));
        let (pa, pb) = (&a.parameters[key], &b.parameters[key]);
        assert_eq!(pa.track.keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![0.0, 40.0]);
        assert_eq!(pa.track.keys[0].out_handle, EaseHandle { dx: 0.6, dy: 0.0 });
        let id_set = |p: &AnimatedProperty<f64>| p.track.keys.iter().map(|k| k.id).collect::<Vec<_>>();
        assert!(id_set(pa).iter().all(|i| !id_set(pb).contains(i) && !id_set(&saved).contains(i)));
        assert!(a.id != b.id);
    }

    #[test]
    fn without_keyframes_the_value_at_the_given_time_is_kept() {
        let mut ids = SequentialIds::default();
        let mut d = EffectDefaults::default();
        d.set_default_effect(&animated_blur(&mut ids), false, f(10), &mut ids);
        let p = d.effect("gaussianBlur").and_then(|e| e.parameters.get(ClipEffect::BLURRINESS_KEY));
        assert_eq!(p.map(|p| (p.is_animated(), p.value)), Some((false, 40.0)));
    }

    #[test]
    fn parameters_the_catalog_no_longer_knows_are_dropped_and_new_ones_start_at_factory() {
        let mut ids = SequentialIds::default();
        let mut e =
            ClipEffect::make(Id::from_u128(5), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        e.parameters.insert("gone".into(), AnimatedProperty::new(3.0));
        e.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), AnimatedProperty::new(7.0));
        let d = EffectDefaults { effects: [("gaussianBlur".to_string(), e)].into(), ..EffectDefaults::default() };
        let made = d.make_effect("gaussianBlur", &mut ids).unwrap_or_else(|| panic!("made"));
        assert!(!made.parameters.contains_key("gone"));
        assert_eq!(made.parameters[ClipEffect::BLURRINESS_KEY].value, 7.0);
        let factory = ClipEffect::default_parameters("gaussianBlur");
        assert_eq!(made.parameters.keys().collect::<Vec<_>>(), factory.keys().collect::<Vec<_>>());
        assert!(d.make_effect("noSuchEffect", &mut ids).is_none());
    }

    #[test]
    fn a_lens_distortion_default_from_before_the_model_key_still_makes_new_effects_with_it() {
        let mut ids = SequentialIds::default();
        let kind = ClipEffect::LENS_DISTORTION_KIND;
        let mut old = ClipEffect::make(Id::from_u128(5), kind).unwrap_or_else(|| panic!("lens"));
        old.parameters.insert(ClipEffect::LENS_CURVATURE_KEY.into(), AnimatedProperty::new(-30.0));
        old.parameters.remove(ClipEffect::LENS_MODEL_KEY);
        let d = EffectDefaults { effects: [(kind.to_string(), old)].into(), ..EffectDefaults::default() };
        let made = d.make_effect(kind, &mut ids).unwrap_or_else(|| panic!("made"));
        assert_eq!(made.parameters[ClipEffect::LENS_MODEL_KEY].value, 1.0);
        assert_eq!(made.parameters[ClipEffect::LENS_CURVATURE_KEY].value, -30.0);
        let data = d.payload().unwrap_or_default();
        let back = EffectDefaults::from_payload(&data, 1, &mut ids).unwrap_or_default();
        let made = back.make_effect(kind, &mut ids).unwrap_or_else(|| panic!("made"));
        assert_eq!(made.parameters[ClipEffect::LENS_MODEL_KEY].value, 1.0);
    }

    #[test]
    fn reset_goes_to_the_saved_default_else_factory() {
        let mut ids = SequentialIds::default();
        let key = ClipEffect::BLURRINESS_KEY;
        let mut src = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        src.parameters.insert(key.into(), AnimatedProperty::new(12.0));
        let mut d = EffectDefaults::default();
        d.set_default_effect(&src, true, Time::ZERO, &mut ids);

        let mut c = clip();
        let mut e = animated_blur(&mut ids);
        e.parameters.insert(key.into(), AnimatedProperty::new(99.0));
        e.enabled = false;
        let id = e.id;
        c.effects.push(e);
        assert!(c.reset_effect(id, Some(&d), &mut ids));
        assert!(c.effects[0].id == id && c.effects[0].enabled);
        assert_eq!(c.effects[0].parameters[key].value, 12.0);

        d.remove_default_effect("gaussianBlur");
        assert!(c.reset_effect(id, Some(&d), &mut ids));
        assert_eq!(c.effects[0].parameters, ClipEffect::default_parameters("gaussianBlur"));
        assert!(!c.reset_effect(Id::from_u128(12345), None, &mut ids));
    }

    #[test]
    fn reset_restores_the_defaults_keyframes() {
        let mut ids = SequentialIds::default();
        let mut d = EffectDefaults::default();
        d.set_default_effect(&animated_blur(&mut ids), true, Time::ZERO, &mut ids);
        let mut c = clip();
        let mut e = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        e.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), AnimatedProperty::new(5.0));
        let id = e.id;
        c.effects.push(e);
        assert!(c.reset_effect(id, Some(&d), &mut ids));
        let values: Vec<f64> =
            c.effects[0].parameters[ClipEffect::BLURRINESS_KEY].track.keys.iter().map(|k| k.value).collect();
        assert_eq!(values, vec![0.0, 40.0]);
    }

    /// A v23 Drop Shadow: red 0 -> 255 over 2 s (linear), green static 51, blue absent.
    fn legacy_shadow() -> ClipEffect {
        let mut e = ClipEffect::new(Id::from_u128(30), ClipEffect::DROP_SHADOW_KIND);
        let mut red = AnimatedProperty::new(0.0);
        red.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(31), Time::ZERO, 0.0),
            Keyframe::new(Id::from_u128(32), Time::new(2, 1), 255.0),
        ]);
        e.parameters.insert(ClipEffect::SHADOW_RED_KEY.into(), red);
        e.parameters.insert(ClipEffect::SHADOW_GREEN_KEY.into(), AnimatedProperty::new(51.0));
        e
    }

    #[test]
    fn a_legacy_shadow_color_folds_into_one_color_parameter() {
        let mut ids = SequentialIds::default();
        let e = legacy_shadow();
        assert!(e.has_legacy_shadow_color());
        let up = e.upgrading_legacy_shadow_color(&mut ids);
        assert!(!up.has_legacy_shadow_color() && !up.parameters.contains_key(ClipEffect::SHADOW_RED_KEY));
        let c = &up.colors[ClipEffect::SHADOW_COLOR_KEY];
        // Keys at the two times any channel had one; red and green share the linear shape, so no extra samples.
        assert_eq!(c.track.keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![Time::ZERO, Time::new(2, 1)]);
        let mid = c.value_at_local(Time::new(1, 1));
        assert!((mid.red - 0.5).abs() < 1e-9 && (mid.green - 0.2).abs() < 1e-9 && mid.blue == 0.0 && mid.alpha == 1.0);
        // A static shadow gives a static color; another kind stays as it is.
        let mut plain = ClipEffect::new(Id::from_u128(33), ClipEffect::DROP_SHADOW_KIND);
        plain.parameters.insert(ClipEffect::SHADOW_BLUE_KEY.into(), AnimatedProperty::new(255.0));
        let up = plain.upgrading_legacy_shadow_color(&mut ids);
        assert_eq!(
            up.colors[ClipEffect::SHADOW_COLOR_KEY].value,
            EffectColor { red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0 }
        );
        assert!(!up.colors[ClipEffect::SHADOW_COLOR_KEY].is_animated());
        let blur = ClipEffect::new(Id::from_u128(34), ClipEffect::GAUSSIAN_BLUR_KIND);
        assert_eq!(blur.upgrading_legacy_shadow_color(&mut ids), blur);
    }

    #[test]
    fn channels_that_move_differently_are_sampled() {
        let mut ids = SequentialIds::default();
        let mut e = legacy_shadow();
        // Green holds 51 -> 255 (a Hold key) while red is linear: the shapes differ, the stretch is sampled every 1/30 s.
        let mut green = AnimatedProperty::new(51.0);
        let mut hold = Keyframe::new(Id::from_u128(40), Time::ZERO, 51.0);
        hold.interpolation = Interpolation::Hold;
        green.track = KeyframeTrack::with_keys(vec![hold, Keyframe::new(Id::from_u128(41), Time::new(2, 1), 255.0)]);
        e.parameters.insert(ClipEffect::SHADOW_GREEN_KEY.into(), green);
        let up = e.upgrading_legacy_shadow_color(&mut ids);
        let keys = &up.colors[ClipEffect::SHADOW_COLOR_KEY].track.keys;
        assert_eq!(keys.len(), 2 + 59, "60 steps of 1/30 s between 0 and 2 s: 59 inner samples");
    }
}
