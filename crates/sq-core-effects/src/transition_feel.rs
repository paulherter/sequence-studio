// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TransitionFeel.swift

//! Transition feel defaults: a NEW transition gets a "factory look" (a settling curve, plus a longer default length from
//! `TransitionKindExt::preset_duration`) written into the transition itself. Nothing changes for what is already stored: a
//! transition without an own curve or parameters keeps resolving to the kind's default easing and parameter defaults.

use crate::transition::{
    TimelineTransitions, TransitionChange, TransitionKindElement, TransitionKindExt, locate_transition,
};
use crate::transition_custom_curve::TransitionEasing;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{ClipEffect, EditError, EffectParamSpec, Timeline, Transition, TransitionKind, TransitionLayer};
use sq_core_time::{EasingCurve, Id};
use std::collections::BTreeMap;

/// Key of Zoom In / Out's Amount in `Transition::params`.
pub const ZOOM_AMOUNT_KEY: &str = "amount";

/// Zoom In / Out: how far the picture zooms, percent (100 = no move).
pub fn zoom_amount_spec() -> EffectParamSpec {
    EffectParamSpec::new(ZOOM_AMOUNT_KEY, "Amount", "%", 110.0, 100.0..=200.0, 0.5, 1)
}

/// Feel parts of `TransitionKind`.
pub trait TransitionKindFeel {
    /// Zoom In or Zoom Out.
    fn is_zoom_through(&self) -> bool;
    /// Stores parameters in `Transition::params` (element transitions, Zoom In / Out's Amount).
    fn has_params(self) -> bool;
    /// The curve a new transition of this kind starts with. Dissolve weights get a soft S, moves a long ease-out, Spin
    /// overshoots. Kinds not named keep the default easing.
    fn factory_easing(self) -> EasingCurve;
    /// The parameters a new transition of this kind starts with (`at_head`: on a clip's head = it plays in); `None` = none.
    fn factory_params(self, at_head: bool) -> Option<BTreeMap<String, f64>>;
}

impl TransitionKindFeel for TransitionKind {
    fn is_zoom_through(&self) -> bool {
        matches!(self, TransitionKind::ZoomIn | TransitionKind::ZoomOut)
    }

    fn has_params(self) -> bool {
        !self.element_params().is_empty()
    }

    fn factory_easing(self) -> EasingCurve {
        use TransitionKind::*;
        match self {
            CrossDissolve | LightNoise => EasingCurve::ease_in_out(),
            Push | Slide | Whip | ZoomPop | Iris | CrossZoom | Flash => EasingCurve::ease_out_100(),
            // A rotation may swing past its rest; a slide, push or zoom of a full frame must not (it would show what is behind).
            Spin => EasingCurve::overshoot(),
            _ => self.default_easing(),
        }
    }

    fn factory_params(self, at_head: bool) -> Option<BTreeMap<String, f64>> {
        let entry = |k: &str, v: f64| (k.to_string(), v);
        match self {
            TransitionKind::Move | TransitionKind::Zoom => {
                let curve = if at_head { MotionCurve::EaseOut100 } else { MotionCurve::EaseIn100 };
                Some(BTreeMap::from([entry(ClipEffect::MOTION_CURVE_KEY, curve.raw_value() as f64)]))
            }
            TransitionKind::Pop => Some(BTreeMap::from([
                entry(ClipEffect::MOTION_CURVE_KEY, MotionCurve::ContinuousBezier.raw_value() as f64),
                entry(ClipEffect::POP_FROM_KEY, 85.0),
                entry(ClipEffect::POP_PEAK_KEY, 105.0),
                entry(ClipEffect::POP_PEAK_AT_KEY, 40.0),
            ])),
            TransitionKind::ZoomIn | TransitionKind::ZoomOut => {
                Some(BTreeMap::from([entry(ZOOM_AMOUNT_KEY, zoom_amount_spec().default_value)]))
            }
            _ => None,
        }
    }
}

/// Zoom In / Out: the stored Amount as a scale (1.1 = 110 %); `None` = none stored (the older look).
pub(crate) fn zoom_amount_of(kind: TransitionKind, params: Option<&BTreeMap<String, f64>>) -> Option<f64> {
    if !kind.is_zoom_through() {
        return None;
    }
    let v = params?.get(ZOOM_AMOUNT_KEY).copied().filter(|v| v.is_finite())?;
    let r = zoom_amount_spec().range;
    Some(v.clamp(*r.start(), *r.end()) / 100.0)
}

/// Writes the factory easing (when `replacing_easing`) and params of `kind` into a style.
fn apply_look(
    kind: TransitionKind,
    easing: &mut Option<EasingCurve>,
    params: &mut Option<BTreeMap<String, f64>>,
    replacing_easing: bool,
    at_head: bool,
) {
    if replacing_easing {
        let f = kind.factory_easing();
        *easing = (kind.uses_easing() && f != kind.default_easing()).then_some(f);
    }
    *params = kind.factory_params(at_head);
}

/// Feel parts of `Transition`.
pub trait TransitionFeelExt {
    /// Zoom In / Out: the stored Amount as a scale (1.1 = 110 %); `None` = none stored.
    fn zoom_amount(&self) -> Option<f64>;
    /// The transition carries a written look and it is exactly its kind's factory look (curve and parameters). One without
    /// an own curve and parameters (every older one) does not.
    fn carries_factory_look(&self) -> bool;
    /// Makes this transition's look the factory look of its kind. `replacing_easing` false keeps an own curve.
    fn apply_factory_look(&mut self, replacing_easing: bool);
}

impl TransitionFeelExt for Transition {
    fn zoom_amount(&self) -> Option<f64> {
        zoom_amount_of(self.kind, self.params.as_ref())
    }

    fn carries_factory_look(&self) -> bool {
        if self.easing.is_none() && self.params.is_none() {
            return false;
        }
        let mut f = self.clone();
        f.apply_factory_look(true);
        f.easing == self.easing && f.params == self.params
    }

    fn apply_factory_look(&mut self, replacing_easing: bool) {
        let at_head = self.outgoing.is_none();
        apply_look(self.kind, &mut self.easing, &mut self.params, replacing_easing, at_head);
    }
}

/// Feel parts of `TransitionLayer`.
pub trait TransitionLayerFeel {
    /// Zoom In / Out: the stored Amount as a scale.
    fn zoom_amount(&self) -> Option<f64>;
    /// Makes this layer's look the factory look of its kind.
    fn apply_factory_look(&mut self, replacing_easing: bool);
    /// Sets one parameter (clamped to its range); an unknown key or a value that is not finite changes nothing.
    fn set_param(&mut self, key: &str, value: f64);
    /// As `TransitionFeelExt::carries_factory_look`.
    fn carries_factory_look(&self) -> bool;
    /// Changes the kind as `TimelineTransitionFeel::change_transition_kind`.
    fn change_kind(&mut self, new: TransitionKind);
}

impl TransitionLayerFeel for TransitionLayer {
    fn zoom_amount(&self) -> Option<f64> {
        zoom_amount_of(self.kind, self.params.as_ref())
    }

    fn apply_factory_look(&mut self, replacing_easing: bool) {
        apply_look(self.kind, &mut self.easing, &mut self.params, replacing_easing, true);
    }

    fn set_param(&mut self, key: &str, value: f64) {
        let Some(spec) = self.kind.element_param(key) else { return };
        if !value.is_finite() {
            return;
        }
        let p = self.params.get_or_insert_with(BTreeMap::new);
        p.insert(key.to_string(), value.clamp(*spec.range.start(), *spec.range.end()));
    }

    fn carries_factory_look(&self) -> bool {
        if self.easing.is_none() && self.params.is_none() {
            return false;
        }
        let mut f = self.clone();
        f.apply_factory_look(true);
        f.easing == self.easing && f.params == self.params
    }

    fn change_kind(&mut self, new: TransitionKind) {
        if new == self.kind {
            return;
        }
        let look = self.carries_factory_look();
        let amount = self.params.as_ref().and_then(|p| p.get(ZOOM_AMOUNT_KEY)).copied();
        let zoom = self.kind.is_zoom_through() && new.is_zoom_through();
        self.kind = new;
        self.params = None;
        if look {
            self.apply_factory_look(true);
        } else if let (true, Some(amount)) = (zoom, amount) {
            self.params = Some(BTreeMap::from([(ZOOM_AMOUNT_KEY.to_string(), amount)]));
        }
    }
}

/// Feel edits of a `Timeline`.
pub trait TimelineTransitionFeel {
    /// Gives transition `id` the factory look of its kind (a newly added transition, "Reset" without a user default).
    fn apply_factory_look(&mut self, id: Id, replacing_easing: bool) -> Result<(), EditError>;
    /// Changes the kind of transition `id` like `set_transition` with a kind (the curve stays, the parameters go). Only a
    /// transition that carries exactly its old kind's factory look gets the new kind's; one without an own curve stays
    /// without. Zoom In <-> Zoom Out keeps a stored Amount.
    fn change_transition_kind(&mut self, id: Id, to: TransitionKind) -> Result<(), EditError>;
}

impl TimelineTransitionFeel for Timeline {
    fn apply_factory_look(&mut self, id: Id, replacing_easing: bool) -> Result<(), EditError> {
        let (ti, ni) = locate_transition(self, id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        self.tracks[ti].transitions[ni].apply_factory_look(replacing_easing);
        Ok(())
    }

    fn change_transition_kind(&mut self, id: Id, to: TransitionKind) -> Result<(), EditError> {
        let (ti, ni) = locate_transition(self, id).ok_or(EditError::ClipNotFound)?;
        let old = self.tracks[ti].transitions[ni].clone();
        self.set_transition(id, &TransitionChange { kind: Some(to), ..TransitionChange::default() })?;
        if old.kind == to {
            return Ok(());
        }
        if old.carries_factory_look() {
            TimelineTransitionFeel::apply_factory_look(self, id, true)?;
        } else if let (true, Some(amount)) = (
            old.kind.is_zoom_through() && to.is_zoom_through(),
            old.params.as_ref().and_then(|p| p.get(ZOOM_AMOUNT_KEY)),
        ) {
            self.set_transition_params(id, &BTreeMap::from([(ZOOM_AMOUNT_KEY.to_string(), *amount)]), false)?;
        }
        Ok(())
    }
}
