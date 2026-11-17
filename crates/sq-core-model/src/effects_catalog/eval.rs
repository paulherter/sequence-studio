// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsEvaluation.swift (the parameter readers of `ClipEffect`), ShapeGenerator.swift (generator-owned kinds)

use crate::keyframes_hue::hue_wrap;
use crate::{ClipEffect, EffectCatalog, EffectColor, EffectParamKind, GeneratorRef};
use sq_core_time::{Time, Vec2};

impl ClipEffect {
    /// Slider, checkbox or choice value at clip-local `t`, clamped to the catalog range (catalog default when missing).
    pub fn scalar(&self, key: &str, t: Time) -> f64 {
        let spec = EffectCatalog::param(&self.kind, key);
        let is_hue = spec.as_ref().is_some_and(|s| s.is_hue);
        let stored =
            self.parameters.get(key).map(|p| if is_hue { p.hue_value_at_local(t) } else { p.value_at_local(t) });
        let mut v = stored.unwrap_or_else(|| spec.as_ref().map_or(0.0, |s| s.default_value));
        // A hue is a place on a circle: an out-of-range key (an imported 370) is that color, not the 360 the range clamp
        // would make of it.
        if is_hue {
            v = hue_wrap(v);
        }
        Self::sanitized(v, &self.kind, key)
    }

    /// `v` as a parameter may hold it: NaN becomes the catalog default, the catalog range clamps, infinity without a range
    /// becomes 0. A NaN from a file or the agent API would pass min/max unchanged and trap later in integer conversions.
    pub fn sanitized(v: f64, kind: &str, key: &str) -> f64 {
        let spec = EffectCatalog::param(kind, key);
        let v = if v.is_nan() { spec.as_ref().map_or(0.0, |s| s.default_value) } else { v };
        match spec {
            Some(s) => v.clamp(*s.range.start(), *s.range.end()),
            None if v.is_finite() => v,
            None => 0.0,
        }
    }

    /// Checkbox state at clip-local `t` (on from 0.5, so a v23 0/1 slider reads the same).
    pub fn flag(&self, key: &str, t: Time) -> bool {
        EffectParamKind::Checkbox.is_on(self.scalar(key, t))
    }

    /// Choice index at clip-local `t`.
    pub fn choice(&self, key: &str, t: Time) -> i64 {
        let kind = EffectCatalog::param(&self.kind, key).map_or(EffectParamKind::Choice(Vec::new()), |p| p.kind);
        kind.choice_index(self.scalar(key, t))
    }

    /// Color at clip-local `t`, channels clamped to 0...1 (catalog default, else black, when missing).
    pub fn color(&self, key: &str, t: Time) -> EffectColor {
        if let Some(p) = self.colors.get(key) {
            return p.value_at_local(t).clamped();
        }
        match EffectCatalog::param(&self.kind, key).map(|p| p.kind) {
            Some(EffectParamKind::Color(d)) => d,
            _ => EffectColor::BLACK,
        }
    }

    /// Point at clip-local `t` (catalog default, else zero, when missing).
    pub fn point(&self, key: &str, t: Time) -> Vec2 {
        if let Some(p) = self.points.get(key) {
            return p.value_at_local(t);
        }
        match EffectCatalog::param(&self.kind, key).map(|p| p.kind) {
            Some(EffectParamKind::Point(d)) => d,
            _ => Vec2::ZERO,
        }
    }
}

impl ClipEffect {
    /// One noise seed per instant (rational: 1/25 and 2/50 are the same instant), well mixed so neighboring frames differ.
    pub fn noise_seed(t: Time) -> u32 {
        let mut h = (t.value() as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
            ^ (t.timescale() as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
        h ^= h >> 31;
        h = h.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        h ^= h >> 29;
        h as u32
    }
}

impl EffectCatalog {
    /// True for an effect created with its generator clip (one per clip): never added, duplicated, removed or pasted onto
    /// another clip by the generic effect commands. Reset to defaults is fine.
    pub fn is_generator_owned(kind: &str) -> bool {
        Self::owning_generator(kind).is_some()
    }

    /// The `GeneratorRef::kind` a generator-owned effect belongs to; `None` for an ordinary effect.
    pub fn owning_generator(kind: &str) -> Option<&'static str> {
        (kind == ClipEffect::SHAPE_EFFECT_KIND).then_some(GeneratorRef::SHAPE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_noise_seed_is_the_same_for_the_same_instant_and_differs_between_frames() {
        assert_eq!(ClipEffect::noise_seed(Time::new(1, 25)), ClipEffect::noise_seed(Time::new(2, 50)));
        let seeds: Vec<u32> = (0..50).map(|n| ClipEffect::noise_seed(Time::new(n, 25))).collect();
        let mut unique = seeds.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), seeds.len(), "neighboring frames get different grain");
    }
}
