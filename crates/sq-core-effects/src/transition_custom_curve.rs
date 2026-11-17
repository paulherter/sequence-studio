// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TransitionCustomCurve.swift, and the `EasingCurve` parts of Transition.swift / TransitionFeel.swift

//! "Custom" easing of a transition: a hand-drawn bezier (the same editor shape as keyframe / speed graphs) stored in the
//! transition's / layer's / preset's `EasingCurve`. No format change: `EasingCurve` already encodes interpolation and both
//! handles. Also the progress of a curve over normalized time, which the transitions evaluate.

use sq_core_model::{EaseShape, EasingCurveShape, easing_curve_from_shape};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, EasingCurve, Id, Interpolation};

/// Fixed id of the hand-drawn curve: equal shapes give equal curves, so nothing churns while a handle is dragged.
const TRANSITION_CUSTOM_ID: Id = Id::from_u128(0xC5);

/// Transition parts of `EasingCurve`.
pub trait TransitionEasing {
    /// The curves the Transition controls offer by name (hold would turn it into a cut at the end).
    fn transition_presets() -> Vec<EasingCurve>;
    /// A hand-drawn curve for a transition. `None` for hold.
    fn transition_custom(shape: &EaseShape) -> Option<EasingCurve>;
    /// What an edit of the curve editor stores: the named preset when the shape matches one, else a custom curve. `None` for
    /// hold.
    fn transition_curve(shape: &EaseShape) -> Option<EasingCurve>;
    /// The named preset with this curve's shape, `None` when it is a custom curve.
    fn matching_transition_preset(&self) -> Option<EasingCurve>;
    /// Runs past the end by about 10 % and comes back (`MotionCurve::BackOut`'s shape as one bezier):
    /// cubic-bezier(.34, 1.56, .64, 1).
    fn overshoot() -> EasingCurve;
    /// Eased progress for normalized time `t` (clamped to 0...1). Hold stays at 0 until the very end.
    fn progress(&self, t: f64) -> f64;
    /// Incoming weight of a dissolve at normalized time `t`. A drawn curve may overshoot (free Y); a mix weight must not.
    fn mix_weight(&self, t: f64) -> f64;
}

impl TransitionEasing for EasingCurve {
    fn transition_presets() -> Vec<EasingCurve> {
        vec![
            EasingCurve::linear(),
            EasingCurve::ease_in_out(),
            EasingCurve::ease_in(),
            EasingCurve::ease_out(),
            EasingCurve::fast_start(),
            EasingCurve::fast_end(),
            EasingCurve::ease_out_100(),
            EasingCurve::ease_in_100(),
            Self::overshoot(),
        ]
    }

    fn transition_custom(shape: &EaseShape) -> Option<EasingCurve> {
        (!shape.interpolation().is_hold())
            .then(|| easing_curve_from_shape(TRANSITION_CUSTOM_ID, shape, "Custom".to_string()))
    }

    fn transition_curve(shape: &EaseShape) -> Option<EasingCurve> {
        let custom = Self::transition_custom(shape)?;
        Some(custom.matching_transition_preset().unwrap_or(custom))
    }

    fn matching_transition_preset(&self) -> Option<EasingCurve> {
        let shape = self.shape();
        Self::transition_presets().into_iter().find(|p| p.shape().is_approximately_equal(&shape))
    }

    fn overshoot() -> EasingCurve {
        EasingCurve::new(
            Id::fixed(13),
            "Overshoot".to_string(),
            Interpolation::Bezier,
            EaseHandle { dx: 0.34, dy: 1.56 },
            EaseHandle { dx: 0.36, dy: 0.0 },
        )
    }

    fn progress(&self, t: f64) -> f64 {
        let t = t.clamp(0.0, 1.0);
        match self.interpolation() {
            Interpolation::Linear => t,
            Interpolation::Hold => {
                if t < 1.0 {
                    0.0
                } else {
                    1.0
                }
            }
            Interpolation::HoldAhead => {
                if t > 0.0 {
                    1.0
                } else {
                    0.0
                }
            }
            Interpolation::Bezier => {
                if t == 0.0 || t == 1.0 {
                    return t;
                }
                keyframe_math::bezier_progress(t, self.out_handle, self.in_handle)
            }
        }
    }

    fn mix_weight(&self, t: f64) -> f64 {
        self.progress(t).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transition::{TransitionExt, TransitionMix, TransitionPresetExt};
    use crate::transition_layer::TransitionLayerExt;
    use sq_core_model::effect_defaults::TransitionPreset;
    use sq_core_model::{Transition, TransitionKind, TransitionLayer};
    use sq_core_time::Time;

    fn drawn() -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.2, dy: 0.9 }, EaseHandle { dx: 0.7, dy: 0.1 })
    }

    #[test]
    fn custom_curve_carries_the_drawn_shape() {
        let c = EasingCurve::transition_custom(&drawn()).unwrap();
        assert!(c.shape() == drawn() && c.name == "Custom");
        assert_eq!(EasingCurve::transition_custom(&drawn()), Some(c), "stable identity: equal shapes, equal curves");
        assert!(
            EasingCurve::transition_custom(&EaseShape::HOLD).is_none(),
            "hold would turn the transition into a cut"
        );
    }

    #[test]
    fn presets_are_not_custom_and_drawn_curves_are() {
        for p in EasingCurve::transition_presets() {
            assert_eq!(p.matching_transition_preset(), Some(p.clone()));
        }
        let c = EasingCurve::transition_custom(&drawn()).unwrap();
        assert!(c.matching_transition_preset().is_none());
        // Dragging the handles back onto a preset shape is that preset again.
        let back = EasingCurve::transition_custom(&EasingCurve::ease_in_out().shape()).unwrap();
        assert_eq!(back.matching_transition_preset(), Some(EasingCurve::ease_in_out()));
    }

    #[test]
    fn curve_for_shape_is_the_preset_when_it_matches_else_custom() {
        assert_eq!(EasingCurve::transition_curve(&EasingCurve::fast_end().shape()), Some(EasingCurve::fast_end()));
        assert_eq!(EasingCurve::transition_curve(&drawn()).map(|c| c.shape()), Some(drawn()));
        assert!(EasingCurve::transition_curve(&EaseShape::HOLD).is_none());
        // A preset chip the transition cannot use (Premiere default etc.) still becomes a valid custom curve.
        let chip = EasingCurve::transition_curve(&EasingCurve::soft_landing().shape()).unwrap();
        assert_eq!(chip.shape(), EasingCurve::soft_landing().shape());
    }

    #[test]
    fn mix_weight_stays_in_unit_range_even_when_the_curve_overshoots() {
        let shape =
            EaseShape::new(Interpolation::Bezier, EaseHandle { dx: 0.3, dy: 1.6 }, EaseHandle { dx: 0.3, dy: -0.8 });
        let over = EasingCurve::transition_custom(&shape).unwrap();
        let mut saw_outside = false;
        for i in 0..=40 {
            let t = f64::from(i) / 40.0;
            let p = over.progress(t);
            saw_outside |= !(0.0..=1.0).contains(&p);
            assert!((0.0..=1.0).contains(&over.mix_weight(t)));
        }
        assert!(saw_outside);
        assert_eq!(EasingCurve::ease_in_out().mix_weight(0.37), EasingCurve::ease_in_out().progress(0.37));
    }

    #[test]
    fn preset_keeps_the_custom_curve() {
        let c = EasingCurve::transition_custom(&drawn()).unwrap();
        let mut tr = Transition::new(
            Id::from_u128(1),
            TransitionKind::Push,
            Time::new(12, 30),
            Some(Id::from_u128(2)),
            Some(Id::from_u128(3)),
        );
        tr.easing = Some(c.clone());
        let p = TransitionPreset::capture(&tr);
        assert_eq!(p.easing, c);
        let back = TransitionPreset::from_payload(&p.payload().unwrap(), TransitionPreset::PAYLOAD_VERSION).unwrap();
        assert!(back.easing == c && back.easing.shape() == drawn());
    }

    #[test]
    fn layer_keeps_the_custom_curve_and_plays_it_like_a_clip_edge() {
        let c = EasingCurve::transition_custom(&drawn()).unwrap();
        let mut l = TransitionLayer::new(TransitionKind::CrossDissolve, Time::new(30, 30));
        l.easing = Some(c.clone());
        assert_eq!(l.effective_easing(), c);
        assert_eq!(TransitionLayer::decode(&l.payload()).and_then(|l| l.easing), Some(c.clone()));
        let t = TransitionMix::video_weight(3, 12);
        assert_eq!(c.mix_weight(t), c.progress(t));
    }

    #[test]
    fn a_clip_edge_transition_resolves_to_the_curve() {
        use crate::transition::tests::{cut, resolved, video_pair};
        let c = EasingCurve::transition_custom(&drawn()).unwrap();
        let (mut t, a, b) = video_pair();
        let id =
            cut(&mut t, TransitionKind::CrossDissolve, &a, &b, 12, sq_core_model::TransitionAlignment::Center).unwrap();
        let change = crate::transition::TransitionChange { easing: Some(c.clone()), ..Default::default() };
        crate::transition::TimelineTransitions::set_transition(&mut t, id, &change).unwrap();
        // The resolved transition (what render and export read) carries the curve.
        assert_eq!(resolved(&t)[0].easing, c);
        assert_eq!(t.tracks[0].transitions[0].effective_easing().progress(0.4), c.progress(0.4));
    }
}
