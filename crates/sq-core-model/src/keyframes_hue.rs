// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesHue.swift (ported by task M-3)

use crate::{AnimatedProperty, Clip, ClipEffect, EffectCatalog};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{Id, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time};

// Hue parameters (degrees round the color circle) take the short way between keys, so 350 -> 10 passes through 0
// instead of sweeping through every other hue. Angles that mean a turn (Rotation, Direction, Mirror Angle) stay
// linear. Nothing new is stored: the catalog says which parameters are hues (`EffectParamSpec.isHue`).

/// Signed step from `a` to `b` on the circle, -180...180. An exact half turn keeps the keyed direction.
pub fn hue_short_delta(a: f64, b: f64) -> f64 {
    let d = b - a;
    if d.abs() == 180.0 { d } else { ieee_remainder(d, 360.0) }
}

/// `v` folded into 0...360 (values already there stay untouched, so 360 stays 360).
pub fn hue_wrap(v: f64) -> f64 {
    if !v.is_finite() || !(v < 0.0 || v > 360.0) {
        return v;
    }
    v - 360.0 * (v / 360.0).floor()
}

// shortcut: exact (as C `remainder`) while |x / y| stays below 2^44, far beyond any hue in degrees; upgrade if
// hue values can be astronomically large.
fn ieee_remainder(x: f64, y: f64) -> f64 {
    x - y * (x / y).round_ties_even()
}

impl AnimatedProperty<f64> {
    /// Value at clip-local `t` of a hue in degrees: each segment runs the shorter way round the circle, keeping its
    /// easing. Key values come back exactly, also the one a Hold or Hold Ahead shows over its whole segment (a step
    /// does not travel, so nothing is folded: a Hold Ahead before a key on 0 reads 0, not 360, and a held 370 reads
    /// 370 on the key and after it); values on the way between two keys lie in 0...360.
    pub fn hue_value_at_local(&self, t: Time) -> f64 {
        let keys = &self.track.keys;
        let (Some(first), Some(last)) = (keys.first(), keys.last()) else { return self.value };
        if t <= first.time {
            return first.value;
        }
        let Some(i) = self.track.segment_index(t) else { return last.value };
        let a = &keys[i];
        if t == a.time {
            return a.value;
        }
        let mut b = keys[i + 1].clone();
        if a.interpolation == Interpolation::Hold {
            return a.value;
        }
        if a.interpolation == Interpolation::HoldAhead {
            return b.value;
        }
        b.value = a.value + hue_short_delta(a.value, b.value);
        hue_wrap(KeyframeTrack::segment_value(a, &b, keyframe_math::ratio(t - a.time, b.time - a.time)))
    }
}

/// The hue and amount keys of every Color wheel (the Look tints and the Color Wheels): each pair is one puck on the disc
/// (Swift `ColorGradeFields.pucks`).
const COLOR_PUCKS: [(&str, &str); 5] = [
    (ClipEffect::COLOR_SHADOW_TINT_HUE_KEY, ClipEffect::COLOR_SHADOW_TINT_AMOUNT_KEY),
    (ClipEffect::COLOR_HIGHLIGHT_TINT_HUE_KEY, ClipEffect::COLOR_HIGHLIGHT_TINT_AMOUNT_KEY),
    (ClipEffect::COLOR_WHEEL_SHADOWS_HUE_KEY, ClipEffect::COLOR_WHEEL_SHADOWS_AMOUNT_KEY),
    (ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY, ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY),
    (ClipEffect::COLOR_WHEEL_HIGHLIGHTS_HUE_KEY, ClipEffect::COLOR_WHEEL_HIGHLIGHTS_AMOUNT_KEY),
];

impl ClipEffect {
    /// Unclamped value of parameter `key` at clip-local `t` as the picture shows it: hues the short way round, Color wheels
    /// on the disc. `None` when the parameter is not stored. For Effect Controls readouts and new keys.
    pub fn shown_value(&self, key: &str, t: Time) -> Option<f64> {
        if self.kind == Self::COLOR_KIND {
            return self.color_shown_value(key, t);
        }
        let p = self.parameters.get(key)?;
        let hue = EffectCatalog::param(&self.kind, key).is_some_and(|s| s.is_hue);
        Some(if hue { p.hue_value_at_local(t) } else { p.value_at_local(t) })
    }

    /// The value parameter `key` of this Color effect shows at clip-local `t` (wheels on the disc, hues the short way).
    fn color_shown_value(&self, key: &str, t: Time) -> Option<f64> {
        let puck = COLOR_PUCKS.iter().find(|(h, a)| *h == key || *a == key);
        if let Some((hue, amount)) = puck.and_then(|&(h, a)| self.puck_value(h, a, t)) {
            return Some(if puck.is_some_and(|p| p.0 == key) { hue } else { amount });
        }
        let p = self.parameters.get(key)?;
        let hue = EffectCatalog::param(Self::COLOR_KIND, key).is_some_and(|s| s.is_hue);
        Some(if hue { p.hue_value_at_local(t) } else { p.value_at_local(t) })
    }

    /// Hue (degrees) and amount of a wheel at clip-local `t` when the puck moves on the disc there; `None` = evaluate each
    /// track on its own (not both keyed, keys at different times, different easing, or `t` on a key).
    fn puck_value(&self, hue_key: &str, amount_key: &str, t: Time) -> Option<(f64, f64)> {
        let (h, a) = (self.parameters.get(hue_key)?, self.parameters.get(amount_key)?);
        let (i, j) = (h.track.segment_index(t)?, a.track.segment_index(t)?);
        let (h0, h1, a0, a1) = (&h.track.keys[i], &h.track.keys[i + 1], &a.track.keys[j], &a.track.keys[j + 1]);
        if h0.time != a0.time || h1.time != a1.time || t == h0.time {
            return None;
        }
        if h0.interpolation.is_hold() || a0.interpolation.is_hold() {
            // A Hold Ahead shows the next key already.
            let ahead = h0.interpolation == Interpolation::HoldAhead || a0.interpolation == Interpolation::HoldAhead;
            return Some(if ahead { (h1.value, a1.value) } else { (h0.value, a0.value) });
        }
        if h0.out_handle != a0.out_handle || h1.in_handle != a1.in_handle {
            return None;
        }
        let (mut k0, mut k1) = (h0.clone(), h1.clone());
        k0.value = 0.0;
        k1.value = 1.0;
        let f = KeyframeTrack::segment_value(&k0, &k1, keyframe_math::ratio(t - h0.time, h1.time - h0.time));
        let (r0, r1) = (h0.value.to_radians(), h1.value.to_radians());
        let x = f64::lerp(&(r0.cos() * a0.value), &(r1.cos() * a1.value), f);
        let y = f64::lerp(&(r0.sin() * a0.value), &(r1.sin() * a1.value), f);
        let amount = x.hypot(y);
        if amount <= 1e-9 {
            return Some((h.hue_value_at_local(t), 0.0));
        }
        Some((hue_wrap(y.atan2(x).to_degrees()), amount))
    }

    /// After an edit at `t` (`before` = this effect before it): a wheel whose hue or amount got a new or changed key at `t`
    /// while its partner is animated without a key there gets the partner keyed at the value it showed, so the puck does not
    /// jump and the segment stays on the disc. New keys take their ids from `ids`.
    fn key_wheel_partners(&mut self, t: Time, before: &ClipEffect, ids: &mut dyn sq_core_time::IdSource) {
        for (hue_key, amount_key) in COLOR_PUCKS {
            let animated = |k: &str| self.parameters.get(k).is_some_and(|p| p.is_animated());
            if !animated(hue_key) || !animated(amount_key) {
                continue;
            }
            for (edited, partner) in [(hue_key, amount_key), (amount_key, hue_key)] {
                let key_at = |e: &ClipEffect, k: &str| {
                    e.parameters.get(k).and_then(|p| p.track.keys.iter().find(|x| x.time == t).cloned())
                };
                let Some(now) = key_at(self, edited) else { continue };
                if key_at(before, edited).is_some_and(|was| was.value == now.value) || key_at(self, partner).is_some() {
                    continue;
                }
                let Some(v) = before.color_shown_value(partner, t) else { continue };
                if let Some(p) = self.parameters.get_mut(partner) {
                    p.track.insert(Keyframe::new(ids.next_id(), t, v));
                }
            }
        }
    }
}

impl Clip {
    /// After a key edit at clip-local `t` on parameter `key` of effect `id` (`before` = the clip before the edit): a parameter
    /// left without keys keeps the value it showed at `t` (hue the short way, wheel on the disc, not the straight-line
    /// value), and an animated wheel partner gets a key at `t` with its shown value so the puck does not jump. For per-row
    /// edits in Effect Controls (stopwatch off, key delete, add key, value edit).
    pub fn follow_shown_values(
        &mut self,
        id: Id,
        key: &str,
        t: Time,
        before: &Clip,
        ids: &mut dyn sq_core_time::IdSource,
    ) {
        let Some(i) = self.effects.iter().position(|e| e.id == id) else { return };
        let Some(b) = before.effects.iter().find(|e| e.id == id) else { return };
        let now_static = self.effects[i].parameters.get(key).is_some_and(|p| !p.is_animated());
        let was_animated = b.parameters.get(key).is_some_and(|p| p.is_animated());
        let shown = b.shown_value(key, t).filter(|_| now_static && was_animated);
        if let (Some(v), Some(p)) = (shown, self.effects[i].parameters.get_mut(key)) {
            p.value = v;
        }
        if self.effects[i].kind == ClipEffect::COLOR_KIND {
            self.effects[i].key_wheel_partners(t, b, ids);
        }
    }
}

/// Hue chaining of a scalar track.
pub trait HueUnwrap {
    /// Key values chained along the short arcs (350, 10, 30 becomes 350, 370, 390), so a straight or eased segment
    /// in this track is exactly the short-arc hue segment. Times, handles and interpolation stay. For drawing graphs.
    fn hue_unwrapped(&self) -> KeyframeTrack<f64>;
}

impl HueUnwrap for KeyframeTrack<f64> {
    fn hue_unwrapped(&self) -> KeyframeTrack<f64> {
        let mut t = self.clone();
        for i in 1..t.keys.len() {
            t.keys[i].value = t.keys[i - 1].value + hue_short_delta(self.keys[i - 1].value, self.keys[i].value);
        }
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframes_editing::test_support::{key, t};
    use sq_core_time::SequentialIds;

    fn hue(keys: Vec<sq_core_time::Keyframe<f64>>) -> AnimatedProperty<f64> {
        AnimatedProperty { value: 0.0, track: KeyframeTrack::with_keys(keys) }
    }

    #[test]
    fn short_delta_takes_the_short_way_and_keeps_an_exact_half_turn() {
        assert_eq!(hue_short_delta(350.0, 10.0), 20.0);
        assert_eq!(hue_short_delta(10.0, 350.0), -20.0);
        assert_eq!(hue_short_delta(0.0, 180.0), 180.0);
        assert_eq!(hue_short_delta(180.0, 0.0), -180.0);
        assert_eq!(hue_short_delta(0.0, 540.0), -180.0);
        assert_eq!(hue_short_delta(0.0, 90.0), 90.0);
    }

    #[test]
    fn wrap_folds_into_the_circle_and_leaves_360_alone() {
        assert_eq!(hue_wrap(370.0), 10.0);
        assert_eq!(hue_wrap(-10.0), 350.0);
        assert_eq!(hue_wrap(360.0), 360.0);
        assert_eq!(hue_wrap(0.0), 0.0);
        assert!(hue_wrap(f64::NAN).is_nan());
    }

    #[test]
    fn hue_value_passes_through_zero_and_keeps_key_values_exact() {
        let p = hue(vec![key(1, 0, 350.0), key(2, 2, 10.0)]);
        assert_eq!(p.hue_value_at_local(t(0)), 350.0);
        assert!((p.hue_value_at_local(t(1)) - 0.0).abs() < 1e-9 || (p.hue_value_at_local(t(1)) - 360.0).abs() < 1e-9);
        assert_eq!(p.hue_value_at_local(t(2)), 10.0);
        assert_eq!(p.hue_value_at_local(t(5)), 10.0);
        assert_eq!(p.hue_value_at_local(t(-3)), 350.0);
        let empty = AnimatedProperty { value: 42.0, track: KeyframeTrack::new() };
        assert_eq!(empty.hue_value_at_local(t(1)), 42.0);
    }

    #[test]
    fn steps_do_not_travel() {
        let mut a = key(1, 0, 370.0);
        a.interpolation = Interpolation::Hold;
        let p = hue(vec![a, key(2, 2, 0.0)]);
        assert_eq!(p.hue_value_at_local(t(1)), 370.0);
        let mut a = key(1, 0, 10.0);
        a.interpolation = Interpolation::HoldAhead;
        let p = hue(vec![a, key(2, 2, 0.0)]);
        assert_eq!(p.hue_value_at_local(t(1)), 0.0);
    }

    #[test]
    fn unwrapped_chains_the_short_arcs() {
        let tr = KeyframeTrack::with_keys(vec![key(1, 0, 350.0), key(2, 1, 10.0), key(3, 2, 30.0)]);
        assert_eq!(tr.hue_unwrapped().keys.iter().map(|k| k.value).collect::<Vec<_>>(), vec![350.0, 370.0, 390.0]);
    }

    fn secs(v: f64) -> Time {
        Time::new((v * 1000.0) as i64, 1000)
    }

    fn prop(keys: &[(f64, f64)]) -> AnimatedProperty<f64> {
        let mut p = AnimatedProperty::new(keys[0].1);
        for (i, &(t, v)) in keys.iter().enumerate() {
            p.track.insert(Keyframe::new(Id::from_u128(i as u128 + 1), secs(t), v));
        }
        p
    }

    /// A Color effect with the Midtones wheel keyed (hue and amount).
    fn wheel(hues: &[(f64, f64)], amounts: &[(f64, f64)]) -> ClipEffect {
        let mut fx = ClipEffect::new(Id::from_u128(77), ClipEffect::COLOR_KIND);
        fx.parameters.insert(ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY.into(), prop(hues));
        fx.parameters.insert(ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY.into(), prop(amounts));
        fx
    }

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn shown_value_follows_the_picture() {
        let mut key = ClipEffect::new(Id::from_u128(1), ClipEffect::ULTRA_KEY_KIND);
        key.parameters.insert(ClipEffect::KEY_HUE_KEY.into(), prop(&[(0.0, 350.0), (2.0, 10.0)]));
        assert!(key.shown_value(ClipEffect::KEY_HUE_KEY, secs(1.5)).is_some_and(|v| near(v, 5.0)));
        let mut mirror = ClipEffect::new(Id::from_u128(2), ClipEffect::MIRROR_KIND);
        mirror.parameters.insert(ClipEffect::MIRROR_ANGLE_KEY.into(), prop(&[(0.0, 350.0), (2.0, 10.0)]));
        assert!(mirror.shown_value(ClipEffect::MIRROR_ANGLE_KEY, secs(1.0)).is_some_and(|v| near(v, 180.0)));
        let w = wheel(&[(0.0, 0.0), (2.0, 180.0)], &[(0.0, 0.5), (2.0, 0.5)]);
        // Opposite hues cross the disc's center: the amount shown halfway is 0, not the stored 0.5.
        assert!(w.shown_value(ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY, secs(1.0)).is_some_and(|v| near(v, 0.0)));
        assert_eq!(w.shown_value(ClipEffect::ULTRA_KEY_KIND, Time::ZERO), None);
    }

    #[test]
    fn the_catalog_marks_only_hues() {
        let hue = |kind, key| EffectCatalog::param(kind, key).map(|p| p.is_hue);
        assert_eq!(hue(ClipEffect::ULTRA_KEY_KIND, ClipEffect::KEY_HUE_KEY), Some(true));
        assert_eq!(hue(ClipEffect::MIRROR_KIND, ClipEffect::MIRROR_ANGLE_KEY), Some(false));
        assert_eq!(hue(ClipEffect::DIRECTIONAL_BLUR_KIND, ClipEffect::BLUR_DIRECTION_KEY), Some(false));
        assert_eq!(hue(ClipEffect::COLOR_KIND, ClipEffect::COLOR_WHEEL_SHADOWS_HUE_KEY), Some(true));
    }

    fn clip_with(fx: ClipEffect) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(900),
            "c",
            Id::from_u128(901),
            crate::TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::new(10, 1)),
            Time::ZERO,
        );
        c.effects.push(fx);
        c
    }

    #[test]
    fn stopwatch_off_freezes_the_shown_hue() {
        let mut key = ClipEffect::new(Id::from_u128(1), ClipEffect::ULTRA_KEY_KIND);
        key.parameters.insert(ClipEffect::KEY_HUE_KEY.into(), prop(&[(0.0, 350.0), (2.0, 10.0)]));
        let mut c = clip_with(key);
        let before = c.clone();
        if let Some(p) = c.effects[0].parameters.get_mut(ClipEffect::KEY_HUE_KEY) {
            p.track = KeyframeTrack::default();
        }
        c.follow_shown_values(
            Id::from_u128(1),
            ClipEffect::KEY_HUE_KEY,
            secs(1.5),
            &before,
            &mut SequentialIds::default(),
        );
        assert!(near(c.effects[0].parameters[ClipEffect::KEY_HUE_KEY].value, 5.0));
    }

    #[test]
    fn adding_a_row_key_on_a_wheel_keys_its_partner() {
        let mut c = clip_with(wheel(&[(0.0, 0.0), (2.0, 180.0)], &[(0.0, 0.5), (2.0, 0.5)]));
        let (id, t) = (Id::from_u128(77), secs(0.5));
        let before = c.clone();
        let shown = c.effects[0].shown_value(ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY, t).unwrap_or(f64::NAN);
        if let Some(p) = c.effects[0].parameters.get_mut(ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY) {
            p.track.insert(Keyframe::new(Id::from_u128(50), t, shown));
        }
        let mut ids = SequentialIds::default();
        c.follow_shown_values(id, ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY, t, &before, &mut ids);
        let amount = &c.effects[0].parameters[ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY];
        assert!(amount.track.keys.iter().any(|k| k.time == t && near(k.value, 0.25)));
    }
}
