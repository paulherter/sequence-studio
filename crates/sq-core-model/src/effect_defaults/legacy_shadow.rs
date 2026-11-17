// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile+V24.swift (`ClipEffect.upgradingLegacyShadowColor`)

use crate::{AnimatedProperty, ClipEffect, EffectColor};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, IdSource, Interpolation, Keyframe, KeyframeTrack, Time};

/// How one legacy channel moves between two consecutive merged key times `a` and `b` (no channel has a key between).
#[derive(Clone, Copy, PartialEq)]
enum LegacyShape {
    Constant,
    Hold,
    Eased(EaseHandle, EaseHandle),
    Unrepresentable,
}

impl LegacyShape {
    fn of(p: &AnimatedProperty<f64>, a: Time, b: Time) -> LegacyShape {
        let keys = &p.track.keys;
        let (Some(ka), Some(kb)) = (keys.iter().rev().find(|k| k.time <= a), keys.iter().find(|k| k.time >= b)) else {
            return LegacyShape::Constant; // before the first or after the last key: flat
        };
        if ka.value == kb.value {
            return LegacyShape::Constant;
        }
        if ka.interpolation == Interpolation::Hold {
            return if kb.time == b { LegacyShape::Hold } else { LegacyShape::Constant };
        }
        if ka.time == a && kb.time == b {
            return LegacyShape::Eased(ka.out_handle, kb.in_handle);
        }
        // Part of a longer segment: only a straight one stays straight when cut.
        if ka.out_handle == EaseHandle::LINEAR && kb.in_handle == EaseHandle::LINEAR {
            LegacyShape::Eased(EaseHandle::LINEAR, EaseHandle::LINEAR)
        } else {
            LegacyShape::Unrepresentable
        }
    }
}

impl ClipEffect {
    /// A v23 Drop Shadow still holding its color as three 0...255 channel parameters.
    pub fn has_legacy_shadow_color(&self) -> bool {
        self.kind == Self::DROP_SHADOW_KIND
            && [Self::SHADOW_RED_KEY, Self::SHADOW_GREEN_KEY, Self::SHADOW_BLUE_KEY]
                .iter()
                .any(|k| self.parameters.contains_key(*k))
    }

    /// A v23 Drop Shadow with its three 0...255 channel parameters folded into the color parameter `shadowColor` (channel /
    /// 255, alpha 1; the evaluation clamps to 0...1 like the old one clamped to 0...255); anything else is returned
    /// unchanged. Public so other stored effects (presets, clipboards) can upgrade the same way.
    ///
    /// Static channels give a static color. With keys, the color gets a key at every time any channel had one, with each
    /// channel's value there. Between two such times the color takes the one shape every changing channel shares (hold,
    /// linear, or the same ease handles), which reproduces the old result at every instant. Where the changing channels
    /// differ (say red hold and green linear, or different handles, or an eased channel cut by another channel's key), that
    /// stretch is sampled every 1/30 s (at most 300 samples) into linear keys: exact at those samples, linear in between.
    /// New keys take their ids from `ids`.
    pub fn upgrading_legacy_shadow_color(&self, ids: &mut dyn IdSource) -> ClipEffect {
        if !self.has_legacy_shadow_color() {
            return self.clone();
        }
        let names = [Self::SHADOW_RED_KEY, Self::SHADOW_GREEN_KEY, Self::SHADOW_BLUE_KEY];
        let channels: Vec<AnimatedProperty<f64>> = names
            .iter()
            .map(|k| self.parameters.get(*k).cloned().unwrap_or_else(|| AnimatedProperty::new(0.0)))
            .collect();
        let colour = |t: Option<Time>| {
            let v: Vec<f64> =
                channels.iter().map(|p| t.map_or_else(|| p.value, |t| p.value_at_local(t)) / 255.0).collect();
            EffectColor { red: v[0], green: v[1], blue: v[2], alpha: 1.0 }
        };
        let mut out = self.clone();
        for k in names {
            out.parameters.remove(k);
        }
        let mut prop = AnimatedProperty::new(colour(None));
        let mut times: Vec<Time> = channels.iter().flat_map(|c| c.track.keys.iter().map(|k| k.time)).collect();
        times.sort();
        times.dedup();
        if let Some(&first) = times.first() {
            // The static fallback mirrors the curve's start so removing all keys later shows the same color.
            prop.value = colour(Some(first));
            let mut built: Vec<Keyframe<EffectColor>> =
                times.iter().map(|&t| Keyframe::new(ids.next_id(), t, colour(Some(t)))).collect();
            let mut samples = Vec::new();
            for i in 0..built.len() - 1 {
                let (a, b) = (built[i].time, built[i + 1].time);
                let mut changing: Vec<LegacyShape> = Vec::new();
                for shape in channels.iter().map(|c| LegacyShape::of(c, a, b)) {
                    if shape != LegacyShape::Constant && !changing.contains(&shape) {
                        changing.push(shape);
                    }
                }
                let shape = match changing.as_slice() {
                    [] => Some(LegacyShape::Constant),
                    [one] => Some(*one),
                    _ => None,
                };
                match shape {
                    Some(LegacyShape::Hold) => built[i].interpolation = Interpolation::Hold,
                    Some(LegacyShape::Eased(o, in_h)) => {
                        built[i].out_handle = o;
                        built[i + 1].in_handle = in_h;
                        built[i].interpolation = if o == EaseHandle::LINEAR && in_h == EaseHandle::LINEAR {
                            Interpolation::Linear
                        } else {
                            Interpolation::Bezier
                        };
                    }
                    Some(LegacyShape::Constant) => {}
                    Some(LegacyShape::Unrepresentable) | None => {
                        let d = b - a;
                        let n = (keyframe_math::seconds(d) * 30.0).ceil().clamp(1.0, 300.0) as i64;
                        for j in 1..n {
                            let t = a + Time::scaled_int(d, j, n);
                            samples.push(Keyframe::new(ids.next_id(), t, colour(Some(t))));
                        }
                    }
                }
            }
            prop.track = KeyframeTrack::default();
            for k in built.into_iter().chain(samples) {
                prop.track.insert(k);
            }
        }
        out.colors.insert(Self::SHADOW_COLOR_KEY.to_string(), prop);
        out
    }
}
