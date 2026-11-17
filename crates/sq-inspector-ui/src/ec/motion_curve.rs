// Swift: EffectControlsMotionCurve.swift
//! FB-T3: the Custom curve of a motion effect (Move, Zoom, Pop, Fade, Shake), edited in the effect itself with the same
//! curve popover as keyframes (button next to the Curve pop-up). Editing selects Custom; the Hold chip selects Hold.

use sq_core_model::EaseReading;
use sq_core_model::motion_easing::{CubicBezierEase, MotionCurve};
use sq_core_model::{AnimatedProperty, ClipEffect, EaseShape, EffectCatalog};
use sq_core_time::{EasingCurve, Id, Interpolation};
use sq_uikit::ease_curve_source::EaseCurveSource;

use crate::ec::effect_controls_model::core::EffectControlsModel;

fn bez(c: &EasingCurve) -> EaseShape {
    EaseShape::new(Interpolation::Bezier, c.out_handle, c.in_handle)
}

impl EffectControlsModel {
    /// The motion effect `effect` on the shown clip, if it has a Curve.
    fn motion_curve_effect(&self, effect: Id) -> Option<&ClipEffect> {
        let e = self.clip.as_ref()?.effects.iter().find(|e| e.id == effect)?;
        if !e.is_motion_preset() || EffectCatalog::param(&e.kind, ClipEffect::MOTION_CURVE_KEY).is_none() {
            return None;
        }
        Some(e)
    }

    /// The curve the editor shows: the Custom bezier when Custom is picked, else the picked curve's shape where it has one.
    pub fn motion_curve_shape(&self, effect: Id) -> Option<EaseShape> {
        let e = self.motion_curve_effect(effect)?;
        let raw = e.parameters.get(ClipEffect::MOTION_CURVE_KEY).map_or(0.0, |p| p.value).round() as i64;
        let kind = MotionCurve::from_raw(raw).unwrap_or(MotionCurve::PremiereDefault);
        // Same curves `MotionCurve::ease` evaluates, so the editor starts from what plays.
        Some(match kind {
            MotionCurve::Hold => EaseShape::HOLD,
            MotionCurve::Linear | MotionCurve::AutoBezier => EaseShape::LINEAR,
            MotionCurve::PremiereDefault => bez(&EasingCurve::premiere_default()),
            MotionCurve::ContinuousBezier => bez(&EasingCurve::ease_in_out()),
            MotionCurve::EaseIn => bez(&EasingCurve::ease_in()),
            MotionCurve::EaseOut => bez(&EasingCurve::ease_out()),
            MotionCurve::EaseOut100 => bez(&EasingCurve::ease_out_100()),
            MotionCurve::EaseIn100 => bez(&EasingCurve::ease_in_100()),
            MotionCurve::FastStart => bez(&EasingCurve::fast_start()),
            // Custom, and the families that are not one bezier: the effect's own Custom curve.
            _ => e.custom_curve().unwrap_or(CubicBezierEase::DEFAULT).shape(),
        })
    }

    /// Writes `shape` as the effect's Custom curve and picks Custom (Hold picks Hold). A drag is one undo step.
    pub fn set_motion_curve(&mut self, effect: Id, shape: &EaseShape) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == effect) else { return };
        if !c.effects[i].is_motion_preset() {
            return;
        }
        if shape.interpolation().is_hold() {
            c.effects[i].parameters.insert(
                ClipEffect::MOTION_CURVE_KEY.to_string(),
                AnimatedProperty::new(MotionCurve::Hold.raw_value() as f64),
            );
        } else {
            c.effects[i].set_custom_curve(CubicBezierEase::from_shape(shape));
            c.effects[i].parameters.insert(
                ClipEffect::MOTION_CURVE_KEY.to_string(),
                AnimatedProperty::new(MotionCurve::Custom.raw_value() as f64),
            );
        }
        self.commit(c, "Edit Curves", None);
    }
}

/// The curve popover's source for one motion effect's Curve.
pub struct MotionCurveEaseSource<'a> {
    pub model: &'a mut EffectControlsModel,
    pub effect: Id,
}

impl EaseCurveSource for MotionCurveEaseSource<'_> {
    fn ease_reading(&self) -> EaseReading {
        self.model.motion_curve_shape(self.effect).map_or(EaseReading::Empty, EaseReading::Common)
    }
    fn apply_ease_shape(&mut self, shape: EaseShape) {
        self.model.set_motion_curve(self.effect, &shape);
    }
    fn begin_gesture(&mut self) {
        self.model.begin_gesture();
    }
    fn end_gesture(&mut self) {
        self.model.end_gesture();
    }
    fn session_easing_curves(&self) -> Vec<EasingCurve> {
        self.model.easing_library.user_curves().to_vec()
    }
    fn observe_ease_inputs(&self) {}
    fn empty_ease_hint(&self) -> String {
        "Select a motion effect".to_string()
    }
}
