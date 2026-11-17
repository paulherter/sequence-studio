// Swift: EaseCurveSource.swift
//! What the curve popover edits.

use sq_core_model::{EaseReading, EaseShape};
use sq_core_time::{EasingCurve, SpringEasing};
use std::ops::RangeInclusive;

/// Something the curve popover can read and write: selected keyframe segments (Effect Controls) or a speed transition of the
/// Time Remapping band. `observe_ease_inputs` reads every observable value the reading depends on (for observation tracking).
/// Runs on the UI thread.
pub trait EaseCurveSource {
    /// What the selection shows.
    fn ease_reading(&self) -> EaseReading;
    /// Writes a shape to the selection.
    fn apply_ease_shape(&mut self, shape: EaseShape);
    /// A drag starts (one undo step).
    fn begin_gesture(&mut self);
    /// The drag ends.
    fn end_gesture(&mut self);
    /// Curves saved this session that the chips offer too.
    fn session_easing_curves(&self) -> Vec<EasingCurve>;
    /// Reads every observable value `ease_reading` depends on.
    fn observe_ease_inputs(&self);
    /// Text when there is nothing to ease.
    fn empty_ease_hint(&self) -> String;
    /// Whether spring presets can be baked here (keyframe segments yes, speed transitions no).
    fn can_bake_spring(&self) -> bool {
        false
    }
    /// Bakes a spring; the default does nothing.
    fn apply_spring(&mut self, _spring: &SpringEasing) {}
    /// Whether a Hold curve can be applied here (a transition refuses it: it would be a cut). Decides the Hold chip.
    fn allows_hold(&self) -> bool {
        true
    }
    /// What the value part of a handle may be here (the editor's vertical drag stops there). Below 0 and above 1 the
    /// curve winds up or overshoots; a speed transition of the band stores 0...1 only.
    fn handle_value_range(&self) -> RangeInclusive<f64> {
        -2.0..=3.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Empty;

    impl EaseCurveSource for Empty {
        fn ease_reading(&self) -> EaseReading {
            EaseReading::Empty
        }
        fn apply_ease_shape(&mut self, _shape: EaseShape) {}
        fn begin_gesture(&mut self) {}
        fn end_gesture(&mut self) {}
        fn session_easing_curves(&self) -> Vec<EasingCurve> {
            Vec::new()
        }
        fn observe_ease_inputs(&self) {}
        fn empty_ease_hint(&self) -> String {
            "Select keyframes".to_string()
        }
    }

    #[test]
    fn defaults_allow_hold_and_overshoot_but_no_spring() {
        let s = Empty;
        assert!(!s.can_bake_spring() && s.allows_hold());
        assert_eq!(s.handle_value_range(), -2.0..=3.0);
    }
}
