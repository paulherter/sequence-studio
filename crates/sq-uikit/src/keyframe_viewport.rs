//! Port of `SQUIKit/Sources/SQUIKit/KeyframeViewport.swift`.
//! `EffectControlsSplit.load/save` read and write `UserDefaults`; the pure part is `width_from_stored`.

use crate::keyframe_graph_editing::GraphAxis;
use crate::keyframe_graph_geometry::GraphFit;
use sq_core_time::Time;

/// The visible part of the clip in the Effect Controls keyframe area (clip-local seconds). Lanes, ruler, clip bar,
/// speed graph and zoom bar all map time through the same viewport, so they always line up. Pure value type.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyframeViewport {
    pub start: f64,
    pub span: f64,
}

impl KeyframeViewport {
    pub fn new(start: f64, span: f64) -> KeyframeViewport {
        KeyframeViewport { start, span }
    }

    pub fn full(duration: f64) -> KeyframeViewport {
        KeyframeViewport::new(0.0, duration.max(0.0))
    }

    pub fn end(&self) -> f64 {
        self.start + self.span
    }

    /// `start ... max(start, end)` as (lower, upper).
    pub fn range(&self) -> (f64, f64) {
        (self.start, self.start.max(self.end()))
    }

    pub fn is_full(&self, duration: f64) -> bool {
        self.start <= 1e-9 && self.span >= duration - 1e-9
    }

    /// Span in 1...duration (never below `min_span`), start so the window stays inside the clip.
    pub fn clamped(&self, duration: f64, min_span: f64) -> KeyframeViewport {
        if duration <= 0.0 {
            return KeyframeViewport::full(0.0);
        }
        let s = self.span.max(min_span.min(duration)).min(duration);
        let st = self.start.max(0.0).min(duration - s);
        KeyframeViewport::new(st, s)
    }

    /// `factor` > 1 zooms in, < 1 out. The anchor keeps its position on screen.
    pub fn zoomed(&self, factor: f64, anchor: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        if !(factor > 0.0 && factor.is_finite() && self.span > 0.0) {
            return *self;
        }
        let frac = ((anchor - self.start) / self.span).clamp(0.0, 1.0);
        let new_span = self.span / factor;
        KeyframeViewport::new(anchor - frac * new_span, new_span).clamped(duration, min_span)
    }

    pub fn panned(&self, seconds: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        KeyframeViewport::new(self.start + seconds, self.span).clamped(duration, min_span)
    }

    /// Scrolls just enough to bring `seconds` into view (a small margin from the edges).
    pub fn revealing(&self, seconds: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        let margin = self.span * 0.1;
        if seconds < self.start + margin {
            return KeyframeViewport::new(seconds - margin, self.span).clamped(duration, min_span);
        }
        if seconds > self.end() - margin {
            return KeyframeViewport::new(seconds + margin - self.span, self.span).clamped(duration, min_span);
        }
        *self
    }

    // MARK: Zoom scrollbar (two round handles, Premiere)

    /// Handle positions as fractions of the clip (0...1), as (lo, hi).
    pub fn handles(&self, duration: f64) -> (f64, f64) {
        if duration <= 0.0 {
            return (0.0, 1.0);
        }
        ((self.start / duration).clamp(0.0, 1.0), (self.end() / duration).clamp(0.0, 1.0))
    }

    /// Dragging the left handle: the right edge stays.
    pub fn setting_lower_handle(&self, fraction: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        let e = self.end();
        let lo = (fraction * duration).max(0.0).min(e - min_span.min(duration));
        KeyframeViewport::new(lo, e - lo).clamped(duration, min_span)
    }

    /// Dragging the right handle: the left edge stays.
    pub fn setting_upper_handle(&self, fraction: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        let hi = (fraction * duration).max(self.start + min_span.min(duration)).min(duration);
        KeyframeViewport::new(self.start, hi - self.start).clamped(duration, min_span)
    }

    /// Moves the window (size unchanged) so its center sits at `fraction` of the clip.
    pub fn centered(&self, fraction: f64, duration: f64, min_span: f64) -> KeyframeViewport {
        KeyframeViewport::new(fraction * duration - self.span / 2.0, self.span).clamped(duration, min_span)
    }
}

/// Shift-snapping of the Effect Controls playhead to keyframes.
pub struct KeyframeSnap;

impl KeyframeSnap {
    /// Pointer distance (points) within which the playhead sticks to a keyframe.
    pub const THRESHOLD_POINTS: f64 = 8.0;

    /// The candidate nearest to `t` when it lies within `threshold_seconds`, else `t`. Returns an exact candidate time.
    pub fn snapped(t: Time, candidates: &[Time], threshold_seconds: f64) -> Time {
        let ts = t.value() as f64 / t.timescale() as f64;
        let mut best: Option<(Time, f64)> = None;
        for &c in candidates {
            let d = (c.value() as f64 / c.timescale() as f64 - ts).abs();
            if d <= threshold_seconds && best.is_none_or(|b| d < b.1) {
                best = Some((c, d));
            }
        }
        best.map_or(t, |b| b.0)
    }
}

/// Width of the properties column (left of the divider) and its limits. Persisted by the panel.
pub struct EffectControlsSplit;

impl EffectControlsSplit {
    pub const DEFAULT_WIDTH: f64 = 326.0;
    pub const MIN_LABEL_WIDTH: f64 = 326.0;
    pub const MIN_LANES_WIDTH: f64 = 160.0;
    pub const DEFAULTS_KEY: &'static str = "effectControls.labelWidth";

    /// `width` limited to [MIN_LABEL_WIDTH, total - MIN_LANES_WIDTH]; never wider than the panel itself.
    pub fn clamp(width: f64, total: f64) -> f64 {
        let upper = Self::MIN_LABEL_WIDTH.max(total - Self::MIN_LANES_WIDTH);
        width.max(Self::MIN_LABEL_WIDTH).min(upper).min(total.max(0.0))
    }

    /// The width to use for a stored value (`UserDefaults.double`, 0 when unset): the default unless it is a usable width.
    pub fn width_from_stored(stored: f64) -> f64 {
        if stored >= Self::MIN_LABEL_WIDTH && stored.is_finite() { stored } else { Self::DEFAULT_WIDTH }
    }
}

/// Axis lock of a speed / value graph handle drag.
pub struct GraphAxisLock;

impl GraphAxisLock {
    /// Movement (points) before the direction is decided; the handle does not move until then.
    pub const DECISION_DISTANCE: f64 = 5.0;
    /// Vertical only when the movement is clearly vertical: |dy| at least this many times |dx|.
    pub const VERTICAL_RATIO: f64 = 1.5;

    pub fn decide(dx: f64, dy: f64) -> Option<GraphAxis> {
        if dx.hypot(dy) < Self::DECISION_DISTANCE {
            return None;
        }
        Some(if dy.abs() >= Self::VERTICAL_RATIO * dx.abs() { GraphAxis::Vertical } else { GraphAxis::Horizontal })
    }
}

/// Where an axis label sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphLabelPlace {
    Top,
    Bottom,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GraphAxisLabel {
    pub place: GraphLabelPlace,
    pub value: f64,
}

/// The few axis labels of the graph: top and bottom of the visible range (Premiere style), not one per grid line.
pub struct GraphAxisLabels;

impl GraphAxisLabels {
    pub fn labels(fit: &GraphFit) -> Vec<GraphAxisLabel> {
        vec![
            GraphAxisLabel { place: GraphLabelPlace::Top, value: *fit.value.end() },
            GraphAxisLabel { place: GraphLabelPlace::Bottom, value: *fit.value.start() },
        ]
    }

    pub fn format(v: f64, scale: f64) -> String {
        let x = v * scale;
        let a = x.abs();
        if a >= 100.0 {
            format!("{x:.0}")
        } else if a >= 1.0 {
            format!("{x:.1}")
        } else {
            format!("{x:.2}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_viewport_and_clamping() {
        let v = KeyframeViewport::full(10.0);
        assert!(v.is_full(10.0));
        assert_eq!(KeyframeViewport::new(-3.0, 2.0).clamped(10.0, 1.0), KeyframeViewport::new(0.0, 2.0));
        assert_eq!(KeyframeViewport::new(9.0, 3.0).clamped(10.0, 1.0), KeyframeViewport::new(7.0, 3.0));
        assert_eq!(KeyframeViewport::new(2.0, 0.1).clamped(10.0, 1.0), KeyframeViewport::new(2.0, 1.0));
        assert_eq!(KeyframeViewport::new(2.0, 5.0).clamped(0.0, 1.0), KeyframeViewport::full(0.0));
    }

    #[test]
    fn zoom_keeps_the_anchor_on_screen() {
        let v = KeyframeViewport::new(0.0, 10.0).zoomed(2.0, 5.0, 10.0, 1.0);
        assert_eq!(v, KeyframeViewport::new(2.5, 5.0));
        assert_eq!(KeyframeViewport::new(0.0, 10.0).zoomed(0.0, 5.0, 10.0, 1.0), KeyframeViewport::new(0.0, 10.0));
    }

    #[test]
    fn reveal_pan_and_handles() {
        let v = KeyframeViewport::new(2.0, 4.0);
        assert_eq!(v.revealing(3.0, 10.0, 1.0), v);
        assert_eq!(v.revealing(9.0, 10.0, 1.0), KeyframeViewport::new(5.4 + 0.0, 4.0).clamped(10.0, 1.0));
        assert_eq!(v.panned(20.0, 10.0, 1.0), KeyframeViewport::new(6.0, 4.0));
        assert_eq!(v.handles(10.0), (0.2, 0.6));
        assert_eq!(v.handles(0.0), (0.0, 1.0));
        assert_eq!(v.setting_lower_handle(0.5, 10.0, 1.0), KeyframeViewport::new(5.0, 1.0));
        assert_eq!(v.setting_upper_handle(0.1, 10.0, 1.0), KeyframeViewport::new(2.0, 1.0));
        assert_eq!(v.centered(0.5, 10.0, 1.0), KeyframeViewport::new(3.0, 4.0));
    }

    #[test]
    fn snapping_picks_the_nearest_candidate_within_the_threshold() {
        let c = [Time::new(10, 10), Time::new(12, 10), Time::new(30, 10)];
        assert_eq!(KeyframeSnap::snapped(Time::new(13, 10), &c, 0.15), Time::new(12, 10));
        assert_eq!(KeyframeSnap::snapped(Time::new(20, 10), &c, 0.15), Time::new(20, 10));
        assert_eq!(KeyframeSnap::snapped(Time::new(105, 100), &c, 0.15), Time::new(10, 10));
    }

    #[test]
    fn split_width_is_clamped_and_loaded() {
        assert_eq!(EffectControlsSplit::clamp(300.0, 800.0), 326.0);
        assert_eq!(EffectControlsSplit::clamp(700.0, 800.0), 640.0);
        assert_eq!(EffectControlsSplit::clamp(400.0, 300.0), 300.0);
        assert_eq!(EffectControlsSplit::width_from_stored(0.0), 326.0);
        assert_eq!(EffectControlsSplit::width_from_stored(500.0), 500.0);
        assert_eq!(EffectControlsSplit::width_from_stored(f64::INFINITY), 326.0);
    }

    #[test]
    fn axis_lock_waits_then_prefers_horizontal() {
        assert_eq!(GraphAxisLock::decide(2.0, 2.0), None);
        assert_eq!(GraphAxisLock::decide(5.0, 7.0), Some(GraphAxis::Horizontal));
        assert_eq!(GraphAxisLock::decide(4.0, 6.0), Some(GraphAxis::Vertical));
    }

    #[test]
    fn axis_labels_format_by_magnitude() {
        assert_eq!(GraphAxisLabels::format(123.456, 1.0), "123");
        assert_eq!(GraphAxisLabels::format(12.34, 1.0), "12.3");
        assert_eq!(GraphAxisLabels::format(0.456, 1.0), "0.46");
        assert_eq!(GraphAxisLabels::format(0.5, 100.0), "50.0");
    }
}
