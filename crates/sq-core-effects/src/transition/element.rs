// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ElementTransitions.swift

//! Element transitions (Move, Zoom, Pop) act once at a clip edge: a one-sided transition on the head (In) or the tail (Out)
//! of a clip. While the clip shows, every element transition on it becomes a synthesized motion effect (mode In or Out,
//! duration = the resolved span) at the end of its effect list. Nothing is written into the clip. Parameters use the
//! motion-effect keys; Motion Blur (shutter in frames) becomes the effect's Shutter Angle.

use super::TrackTransitions;
use crate::transition_feel::{TransitionKindFeel, zoom_amount_spec};
use sq_core_model::{
    AnimatedProperty, Clip, ClipEffect, EffectCatalog, EffectParamSpec, Track, Transition, TransitionKind,
};
use sq_core_time::Time;
use sq_core_time::keyframes_model::keyframe_math;

/// Set only on the motion effect an element transition synthesizes: its span in seconds, used as the In / Out length without
/// the 60 s limit of the effect's Duration. Never stored.
pub const ELEMENT_SPAN_KEY: &str = "elementSpan";

/// The element kinds.
pub const ELEMENT_KINDS: [TransitionKind; 3] = [TransitionKind::Move, TransitionKind::Zoom, TransitionKind::Pop];

/// The four keys of a motion effect's Custom curve (`ClipEffect::CURVE_X1_KEY` ...).
pub(crate) const CUSTOM_CURVE_KEYS: [&str; 4] =
    [ClipEffect::CURVE_X1_KEY, ClipEffect::CURVE_Y1_KEY, ClipEffect::CURVE_X2_KEY, ClipEffect::CURVE_Y2_KEY];

/// Stored value of the motion mode In.
// shortcut: raw `MotionMode` values (In = 0, Out = 1); use the enum when motion_effects.rs has it.
const MODE_IN: f64 = 0.0;
const MODE_OUT: f64 = 1.0;

/// Element parts of `TransitionKind`.
pub trait TransitionKindElement: Sized {
    /// The motion effect an element transition evaluates as.
    fn element_effect_kind(self) -> Option<&'static str>;
    /// The parameters a transition shows (Effect Controls) and stores (`Transition::params`): an element transition's (mode
    /// and durations come from the transition itself, Pop's Settle is 100 %) and Zoom In / Out's Amount.
    fn element_params(self) -> Vec<EffectParamSpec>;
    /// One parameter of `element_params`.
    fn element_param(self, key: &str) -> Option<EffectParamSpec>;
    /// Zoom's single value: the scale at the clip edge (the clip rests at 100 %).
    fn zoom_edge_spec() -> EffectParamSpec;
}

impl TransitionKindElement for TransitionKind {
    fn element_effect_kind(self) -> Option<&'static str> {
        match self {
            TransitionKind::Move => Some(ClipEffect::MOVE_KIND),
            TransitionKind::Zoom => Some(ClipEffect::ZOOM_KIND),
            TransitionKind::Pop => Some(ClipEffect::POP_KIND),
            _ => None,
        }
    }

    fn element_params(self) -> Vec<EffectParamSpec> {
        if self.is_zoom_through() {
            return vec![zoom_amount_spec()];
        }
        let Some(spec) = self.element_effect_kind().and_then(EffectCatalog::spec_for) else { return Vec::new() };
        let skip = [
            ClipEffect::MOTION_MODE_KEY,
            ClipEffect::MOTION_DURATION_KEY,
            ClipEffect::MOTION_OUT_DURATION_KEY,
            ClipEffect::POP_SETTLE_KEY,
        ];
        let mut out: Vec<EffectParamSpec> =
            spec.params.into_iter().filter(|p| !skip.contains(&p.key.as_str())).collect();
        if self == TransitionKind::Zoom {
            out.retain(|p| p.key != ClipEffect::ZOOM_FROM_KEY && p.key != ClipEffect::ZOOM_TO_KEY);
            out.push(Self::zoom_edge_spec());
        }
        out
    }

    fn element_param(self, key: &str) -> Option<EffectParamSpec> {
        self.element_params().into_iter().find(|p| p.key == key)
    }

    fn zoom_edge_spec() -> EffectParamSpec {
        EffectParamSpec::new(ClipEffect::ZOOM_FROM_KEY, "Scale at Edge", "%", 110.0, 0.0..=10_000.0, 0.5, 1)
    }
}

/// Element parts of `Transition`.
pub trait TransitionElementExt {
    /// Value of element parameter `key` (the default when unset), clamped to its range; 0 for an unknown key.
    fn param(&self, key: &str) -> f64;
    /// The motion effect this element transition plays on its clip for a resolved span of `seconds`: In at the head, Out at
    /// the tail. `None` for any other kind.
    fn element_effect(&self, seconds: f64, motion_blur: f64) -> Option<ClipEffect>;
}

impl TransitionElementExt for Transition {
    fn param(&self, key: &str) -> f64 {
        let stored = self.params.as_ref().and_then(|p| p.get(key)).copied();
        match self.kind.element_param(key) {
            None => stored.unwrap_or(0.0),
            Some(spec) => stored.unwrap_or(spec.default_value).clamp(*spec.range.start(), *spec.range.end()),
        }
    }

    fn element_effect(&self, seconds: f64, motion_blur: f64) -> Option<ClipEffect> {
        let mut e = ClipEffect::make(self.id, self.kind.element_effect_kind()?)?;
        let at_head = self.outgoing.is_none();
        let mut set = |k: &str, v: f64| {
            e.parameters.insert(k.to_string(), AnimatedProperty::new(v));
        };
        set(ClipEffect::MOTION_MODE_KEY, if at_head { MODE_IN } else { MODE_OUT });
        let span = seconds.max(1e-6);
        set(ClipEffect::MOTION_DURATION_KEY, span.clamp(0.01, 60.0));
        set(ClipEffect::MOTION_OUT_DURATION_KEY, 0.0);
        set(ELEMENT_SPAN_KEY, span);
        for p in self.kind.element_params() {
            if p.key == ClipEffect::ZOOM_FROM_KEY && self.kind == TransitionKind::Zoom {
                continue;
            }
            // Unset Direction / Rotation pop-ups keep the angle and the signed strength (Left / None look the same).
            let unset = self.params.as_ref().is_none_or(|m| !m.contains_key(&p.key));
            if (p.key == ClipEffect::MOVE_SIDE_KEY || p.key == ClipEffect::MOVE_SPIN_KEY) && unset {
                continue;
            }
            set(&p.key, self.param(&p.key));
        }
        for k in CUSTOM_CURVE_KEYS {
            if let Some(v) = self.params.as_ref().and_then(|p| p.get(k)) {
                set(k, *v);
            }
        }
        // Move's fade stays inside the span: the effect switches off at its end, a longer fade would jump to full there.
        if self.kind == TransitionKind::Move {
            set(ClipEffect::MOVE_FADE_LENGTH_KEY, self.param(ClipEffect::MOVE_FADE_LENGTH_KEY).min(span));
        }
        if self.kind == TransitionKind::Zoom {
            let edge = self.param(ClipEffect::ZOOM_FROM_KEY);
            set(ClipEffect::ZOOM_FROM_KEY, if at_head { edge } else { 100.0 });
            set(ClipEffect::ZOOM_TO_KEY, if at_head { 100.0 } else { edge });
        }
        if self.kind == TransitionKind::Pop {
            set(ClipEffect::POP_SETTLE_KEY, 100.0);
        }
        let shutter = (motion_blur.max(0.0) * 360.0).min(360.0);
        if shutter > 0.0 {
            set(ClipEffect::STAGE_SHUTTER_ANGLE_KEY, shutter);
        }
        Some(e)
    }
}

/// Element transitions as seen by a track.
pub trait TrackElementTransitions {
    /// `c` with the motion effects of the element transitions on it that can reach `t` (their span, widened by a frame for
    /// the motion-blur shutter). The stored clip is never changed.
    fn clip_with_element_transitions(&self, c: &Clip, t: Time, fd: Time) -> Clip;
}

impl TrackElementTransitions for Track {
    fn clip_with_element_transitions(&self, c: &Clip, t: Time, fd: Time) -> Clip {
        let mut out = c.clone();
        for tr in self
            .transitions
            .iter()
            .filter(|tr| tr.kind.is_element() && (tr.incoming == Some(c.id) || tr.outgoing == Some(c.id)))
        {
            let Some(r) = self.resolve(tr, fd) else { continue };
            if t < r.span.start - fd || t >= r.span.end() + fd {
                continue;
            }
            if let Some(e) = tr.element_effect(keyframe_math::seconds(r.span.duration), r.motion_blur) {
                out.effects.push(e);
            }
        }
        out
    }
}
