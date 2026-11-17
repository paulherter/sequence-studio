// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FormatVariants.swift, SequenceConform.swift (the ConformMode type) (saved types, moved down; filled by task S-2).
// The variant key helpers `shift_variant_keys`/`remap_variant_keys`: task M-1.

use crate::{AnimatedProperty, BakedEffect, Clip, ClipMask, GeneratorRef};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::{EncodeContext, Id, Seen, Time, Vec2};
use std::collections::BTreeMap;

/// Largest frame side a variant may have (`SequenceFormatPresets.maxDimension`).
const MAX_DIMENSION: i64 = 16_384;

/// How the old picture is placed in a new frame size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConformMode {
    /// The whole old frame stays visible inside the new one (bars on one axis).
    Fit,
    /// The old frame covers the new one, cropping one axis.
    Fill,
}

fn fill() -> ConformMode {
    ConformMode::Fill
}

fn valid_dimension<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    let v = i64::deserialize(d)?;
    if (1..=MAX_DIMENSION).contains(&v) {
        Ok(v)
    } else {
        Err(serde::de::Error::custom(format!("variant size {v} is not valid")))
    }
}

/// A format variant of a sequence (square, vertical, ...): the same edit at another frame size.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FormatVariant {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Width in pixels, 1...16384.
    #[serde(deserialize_with = "valid_dimension")]
    pub width: i64,
    /// Height in pixels, 1...16384.
    #[serde(deserialize_with = "valid_dimension")]
    pub height: i64,
    /// How the picture is placed in the new frame.
    #[serde(default = "fill")]
    pub conform: ConformMode,
}

type EffectParameters = BTreeMap<Id, BTreeMap<String, AnimatedProperty<f64>>>;

/// What one variant changes on a clip. Every part is optional; an unset part follows the base edit.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VariantOverride {
    /// Position.
    #[serde(default)]
    pub position: Option<AnimatedProperty<Vec2>>,
    /// Scale.
    #[serde(default)]
    pub scale: Option<AnimatedProperty<Vec2>>,
    /// Rotation.
    #[serde(default)]
    pub rotation: Option<AnimatedProperty<f64>>,
    /// Anchor.
    #[serde(default)]
    pub anchor: Option<AnimatedProperty<Vec2>>,
    /// Tilt around the horizontal axis (file version 84).
    #[serde(default)]
    pub tilt_x: Option<AnimatedProperty<f64>>,
    /// Tilt around the vertical axis (file version 84).
    #[serde(default)]
    pub tilt_y: Option<AnimatedProperty<f64>>,
    /// Own conform mode.
    #[serde(default)]
    pub conform: Option<ConformMode>,
    /// Own generator content (a text clip with a different layout).
    #[serde(default)]
    pub generator: Option<GeneratorRef>,
    /// Effect parameter overrides by effect id; keys that are no UUID are dropped.
    #[serde(default, deserialize_with = "effect_parameters")]
    pub effect_parameters: EffectParameters,
}

fn effect_parameters<'de, D: Deserializer<'de>>(d: D) -> Result<EffectParameters, D::Error> {
    let raw = BTreeMap::<String, BTreeMap<String, AnimatedProperty<f64>>>::deserialize(d)?;
    Ok(raw.into_iter().filter_map(|(k, v)| Id::parse(&k).map(|id| (id, v))).collect())
}

impl VariantOverride {
    /// Nothing is overridden.
    pub fn is_empty(&self) -> bool {
        self.position.is_none()
            && self.scale.is_none()
            && self.rotation.is_none()
            && self.anchor.is_none()
            && self.tilt_x.is_none()
            && self.tilt_y.is_none()
            && self.conform.is_none()
            && self.generator.is_none()
            && self.effect_parameters.values().all(BTreeMap::is_empty)
    }
}

impl VariantOverride {
    /// Every key time through `f` (keeps ids and easing).
    fn remapped(&self, f: &impl Fn(Time) -> Time) -> VariantOverride {
        VariantOverride {
            position: self.position.as_ref().map(|p| p.remapped(f)),
            scale: self.scale.as_ref().map(|p| p.remapped(f)),
            rotation: self.rotation.as_ref().map(|p| p.remapped(f)),
            anchor: self.anchor.as_ref().map(|p| p.remapped(f)),
            tilt_x: self.tilt_x.as_ref().map(|p| p.remapped(f)),
            tilt_y: self.tilt_y.as_ref().map(|p| p.remapped(f)),
            effect_parameters: self
                .effect_parameters
                .iter()
                .map(|(id, params)| (*id, params.iter().map(|(k, p)| (k.clone(), p.remapped(f))).collect()))
                .collect(),
            ..self.clone()
        }
    }
}

/// The keys `VariantOverride` writes: unset parts and empty effect maps are left out.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VariantOverrideOut<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    position: &'a Option<AnimatedProperty<Vec2>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scale: &'a Option<AnimatedProperty<Vec2>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rotation: &'a Option<AnimatedProperty<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    anchor: &'a Option<AnimatedProperty<Vec2>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tilt_x: &'a Option<AnimatedProperty<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tilt_y: &'a Option<AnimatedProperty<f64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    conform: &'a Option<ConformMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    generator: &'a Option<GeneratorRef>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    effect_parameters: BTreeMap<&'a Id, &'a BTreeMap<String, AnimatedProperty<f64>>>,
}

impl Serialize for VariantOverride {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        // Tilt keys need file version 84: the writer learns about them here.
        let tilt = self.tilt_x.is_some() || self.tilt_y.is_some();
        if tilt {
            EncodeContext::mark(Seen::Tilt);
        }
        VariantOverrideOut {
            position: &self.position,
            scale: &self.scale,
            rotation: &self.rotation,
            anchor: &self.anchor,
            tilt_x: &self.tilt_x,
            tilt_y: &self.tilt_y,
            conform: &self.conform,
            generator: &self.generator,
            effect_parameters: self.effect_parameters.iter().filter(|(_, v)| !v.is_empty()).collect(),
        }
        .serialize(s)
    }
}

/// The overrides of all variants of one clip, by variant id. Coded as a plain object keyed by the id text.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(transparent)]
pub struct VariantOverrides {
    /// Variant id to its overrides.
    pub items: BTreeMap<Id, VariantOverride>,
}

impl<'de> Deserialize<'de> for VariantOverrides {
    /// Keys that are no UUID and empty overrides are dropped.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = BTreeMap::<String, VariantOverride>::deserialize(d)?;
        let items = raw.into_iter().filter_map(|(k, v)| Id::parse(&k).filter(|_| !v.is_empty()).map(|id| (id, v)));
        Ok(VariantOverrides { items: items.collect() })
    }
}

impl Clip {
    /// Moves every key time the clip owns besides its animation and effects (baked effects, masks, Graphic items and the
    /// variant overrides) through `f`: the clip's own keys moved the same way.
    pub(crate) fn remap_variant_keys(&mut self, f: &impl Fn(Time) -> Time) {
        // Baked-effect records and mask keys follow the clip's keys on every path that moves them.
        if let Some(baked) = &mut self.baked_store {
            for b in baked.iter_mut() {
                *b = BakedEffect { effect: b.effect.remapped(f), motion: b.motion.remapped(f), ..b.clone() };
            }
        }
        if let Some(masks) = &mut self.mask_store {
            for m in masks.iter_mut() {
                *m = ClipMask {
                    path: m.path.remapped(f),
                    feather: m.feather.remapped(f),
                    opacity: m.opacity.remapped(f),
                    expansion: m.expansion.remapped(f),
                    ..m.clone()
                };
            }
        }
        if let Some(g) = &mut self.graphics_store {
            g.remap_item_keys(f); // the keys of a Graphic's items are clip-local too
        }
        if let Some(s) = &mut self.variant_store {
            for o in s.items.values_mut() {
                *o = o.remapped(f);
            }
        }
    }

    /// Moves every such key by `delta`.
    #[doc(hidden)]
    pub fn shift_variant_keys(&mut self, delta: Time) {
        if delta != Time::ZERO {
            self.remap_variant_keys(&|t| t + delta);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    const V1: &str = "00000000-0000-0000-0000-000000000001";

    #[test]
    fn variant_round_trips_and_conform_defaults_to_fill() {
        assert_round_trip::<FormatVariant>(json!({"id": V1, "name": "Square", "width": 1080, "height": 1080,
                                                  "conform": "fit"}));
        let v: FormatVariant =
            serde_json::from_value(json!({"id": V1, "name": "V", "width": 9, "height": 16})).unwrap();
        assert_eq!(v.conform, ConformMode::Fill);
    }

    #[test]
    fn variant_size_must_be_in_range() {
        for (w, h) in [(0, 10), (10, 0), (16_385, 10), (10, -1)] {
            let v = json!({"id": V1, "name": "V", "width": w, "height": h});
            assert!(serde_json::from_value::<FormatVariant>(v).is_err(), "{w}x{h}");
        }
        let max = json!({"id": V1, "name": "V", "width": 16_384, "height": 1});
        assert!(serde_json::from_value::<FormatVariant>(max).is_ok());
    }

    #[test]
    fn override_round_trips_and_drops_empty_effect_maps_on_write() {
        let o = json!({"position": {"value": {"x": 0.5, "y": 0.5}, "track": {"keys": []}}, "conform": "fit",
                       "effectParameters": {V1: {"amount": {"value": 2.0, "track": {"keys": []}}}}});
        let parsed: VariantOverride = serde_json::from_value(o).unwrap();
        assert!(!parsed.is_empty());
        let back = serde_json::to_value(&parsed).unwrap();
        assert_eq!(back["effectParameters"][V1]["amount"]["value"], json!(2.0));
        let empty: VariantOverride = serde_json::from_value(json!({"effectParameters": {V1: {}}})).unwrap();
        assert!(empty.is_empty());
        assert_eq!(serde_json::to_value(&empty).unwrap(), json!({}));
    }

    #[test]
    fn overrides_drop_bad_keys_and_empty_entries() {
        let o: VariantOverrides = serde_json::from_value(json!({V1: {"conform": "fit"}, "nope": {"conform": "fit"},
                                          "00000000-0000-0000-0000-000000000002": {}}))
        .unwrap();
        assert_eq!(o.items.len(), 1);
        assert_eq!(serde_json::to_value(&o).unwrap(), json!({V1: {"conform": "fit"}}));
    }

    #[test]
    fn tilt_is_reported_to_the_encode_scope() {
        let scope = EncodeContext::project_file();
        let o: VariantOverride = serde_json::from_value(json!({"conform": "fit"})).unwrap();
        serde_json::to_value(&o).unwrap();
        assert!(!scope.seen().tilt);
        let tilted = VariantOverride { tilt_x: Some(AnimatedProperty::new(1.0)), ..VariantOverride::default() };
        serde_json::to_value(&tilted).unwrap();
        assert!(scope.seen().tilt);
    }
}
