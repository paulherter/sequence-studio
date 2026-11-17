// Swift: SpeedRampEaseSource.swift, TransitionEaseSource.swift
//! The curve popover's sources for a speed transition of the Time Remapping band and for the easing of one transition.
//! Swift classes held the session; here a source borrows it for the time the popover edits.

use sq_core_effects::transition_custom_curve::TransitionEasing;
use sq_core_model::{EaseReading, EaseShape, SpeedKeys};

use crate::ec::prelude::*;
use sq_core_time::{EasingCurve, Id, Time};
use sq_editor_session::{EditorSession, TransitionStyleChange};
use sq_uikit::ease_curve_source::EaseCurveSource;

/// The transition a speed ramp source was opened for, by where it sits (start and length in clip time).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RampIdentity {
    start: Time,
    duration: Time,
}

/// The curve popover's source for one speed transition of the Time Remapping band (W4.4): reads the ramp's Bezier curve
/// and writes it through the session (one undo step per handle drag, one per preset chip).
pub struct SpeedRampEaseSource<'a> {
    pub session: &'a mut EditorSession,
    pub clip: Id,
    pub segment: usize,
    in_gesture: bool,
    emitted: bool,
    /// A key added or removed elsewhere shifts segment indices but not this ramp, so it is looked up again on every read
    /// and write. When an edit moved, resized or split it, nothing matches: the source then reads empty and writes nothing.
    identity: Option<RampIdentity>,
}

impl<'a> SpeedRampEaseSource<'a> {
    pub fn new(session: &'a mut EditorSession, clip: Id, segment: usize) -> SpeedRampEaseSource<'a> {
        let identity = Self::keys(session, clip).and_then(|k| {
            let seg = k.segments.get(segment)?;
            if !seg.is_ramp() {
                return None;
            }
            Some(RampIdentity { start: *k.boundaries().get(segment)?, duration: seg.duration })
        });
        SpeedRampEaseSource { session, clip, segment, in_gesture: false, emitted: false, identity }
    }

    fn keys(session: &EditorSession, clip: Id) -> Option<SpeedKeys> {
        session
            .active_timeline()?
            .tracks
            .iter()
            .flat_map(|t| t.clips().iter())
            .find(|c| c.id == clip)?
            .speed_keys
            .clone()
    }

    /// The ramp's current segment index, nil once it is gone.
    pub fn current_segment(&self) -> Option<usize> {
        let identity = self.identity?;
        let k = Self::keys(self.session, self.clip)?;
        let b = k.boundaries();
        (0..k.segments.len()).find(|&i| {
            k.segments[i].is_ramp() && b.get(i) == Some(&identity.start) && k.segments[i].duration == identity.duration
        })
    }

    /// True while the ramp the popover was opened on still exists.
    pub fn is_current(&self) -> bool {
        self.current_segment().is_some()
    }

    /// What the value part of a handle may be here: a speed transition stores no value outside 0...1.
    pub fn handle_value_range(&self) -> std::ops::RangeInclusive<f64> {
        0.0..=1.0
    }
}

impl EaseCurveSource for SpeedRampEaseSource<'_> {
    fn ease_reading(&self) -> EaseReading {
        let Some(i) = self.current_segment() else { return EaseReading::Empty };
        self.session.speed_ramp_ease(self.clip, i).map_or(EaseReading::Empty, EaseReading::Common)
    }

    fn apply_ease_shape(&mut self, shape: EaseShape) {
        let Some(i) = self.current_segment() else { return };
        let changed = self.session.set_speed_ramp_ease(&shape, self.clip, i, self.in_gesture && self.emitted);
        if self.in_gesture && changed {
            self.emitted = true;
        }
    }

    /// A speed transition stores no Hold (it would clear the curve) and no value outside 0...1 (`SpeedEase.normalized`).
    fn allows_hold(&self) -> bool {
        false
    }

    fn begin_gesture(&mut self) {
        self.in_gesture = true;
        self.emitted = false;
    }

    fn end_gesture(&mut self) {
        self.in_gesture = false;
        self.emitted = false;
    }

    fn session_easing_curves(&self) -> Vec<EasingCurve> {
        Vec::new()
    }

    fn observe_ease_inputs(&self) {}

    fn empty_ease_hint(&self) -> String {
        "Select a speed transition".to_string()
    }
}

/// What a transition source edits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransitionEaseTarget {
    Edge(Id),
    Layer(Id),
}

/// The curve popover's source for the easing of one transition: a clip-edge transition or a transition layer. Reads the
/// stored curve and writes a hand-drawn one back through the session (one undo step per handle drag, one per preset chip).
pub struct TransitionEaseSource<'a> {
    pub session: &'a mut EditorSession,
    pub target: TransitionEaseTarget,
    in_gesture: bool,
    emitted: bool,
}

impl<'a> TransitionEaseSource<'a> {
    pub fn new(session: &'a mut EditorSession, target: TransitionEaseTarget) -> TransitionEaseSource<'a> {
        TransitionEaseSource { session, target, in_gesture: false, emitted: false }
    }

    fn current(&self) -> Option<EasingCurve> {
        match self.target {
            TransitionEaseTarget::Edge(id) => self.session.transition_info(id).map(|i| i.transition.effective_easing()),
            TransitionEaseTarget::Layer(id) => {
                self.session.transition_layer_info(id).map(|i| i.transition.effective_easing())
            }
        }
    }
}

impl EaseCurveSource for TransitionEaseSource<'_> {
    fn ease_reading(&self) -> EaseReading {
        self.current().map_or(EaseReading::Empty, |c| EaseReading::Common(c.shape()))
    }

    fn allows_hold(&self) -> bool {
        false
    }

    fn apply_ease_shape(&mut self, shape: EaseShape) {
        // Hold would turn the transition into a cut: ignored (and `allows_hold` keeps the chip out of the popover).
        let Some(curve) = EasingCurve::transition_curve(&shape) else { return };
        if Some(&curve) == self.current().as_ref() {
            return;
        }
        let continues = self.in_gesture && self.emitted;
        match self.target {
            TransitionEaseTarget::Edge(id) => {
                let change = TransitionStyleChange { easing: Some(curve), ..TransitionStyleChange::default() };
                self.session.set_transition_style(id, &change, continues);
            }
            TransitionEaseTarget::Layer(id) => {
                let _ = self.session.set_transition_layer_style(id, "Easing", continues, |l| l.easing = Some(curve));
            }
        }
        if self.in_gesture {
            self.emitted = true;
        }
    }

    fn begin_gesture(&mut self) {
        self.in_gesture = true;
        self.emitted = false;
    }

    fn end_gesture(&mut self) {
        self.in_gesture = false;
        self.emitted = false;
    }

    fn session_easing_curves(&self) -> Vec<EasingCurve> {
        Vec::new()
    }

    fn observe_ease_inputs(&self) {}

    fn empty_ease_hint(&self) -> String {
        "Select a transition".to_string()
    }
}
