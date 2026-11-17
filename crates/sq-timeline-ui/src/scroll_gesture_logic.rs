// Swift: ScrollGestureLogic.swift
//! Tuning of timeline scrolling, the per-gesture axis lock and the pinch-residue guard.

use crate::timeline_feel::TimelineFeel;
use crate::timeline_zoom_animation::ScrollPhase;

/// Tuning of timeline scrolling, in one place.
pub struct ScrollTuning;

impl ScrollTuning {
    /// Horizontal trackpad pixel deltas are multiplied by this (Premiere-like reach per swipe).
    pub const TRACKPAD_SCROLL_GAIN: f64 = 1.6;
    /// One mouse-wheel notch in points (a notch reports ~1 pt).
    pub const WHEEL_NOTCH: f64 = 48.0;
    /// A trackpad gesture decides its axis once the accumulated movement passes this many points.
    pub const AXIS_LOCK_THRESHOLD: f64 = 2.0;
    /// Vertical wins only when |dy| exceeds |dx| times this; diagonal-ish swipes stay horizontal.
    pub const VERTICAL_BIAS: f64 = 1.5;
    /// Predominant-axis rule (Fast Cut): one axis locks only when it moved this many times further than the other;
    /// anything in between is a free diagonal pan (AppKit scroll-view style).
    pub const PREDOMINANT_RATIO: f64 = 2.0;
    /// Scroll events this long after a pinch ends still count as pinch residue (seconds).
    pub const PINCH_TAIL: f64 = 0.25;

    /// Scroll distance (x, y) for one event after axis lock/pinch filtering. Positive result = content moves with the
    /// fingers (callers negate for scroll offsets).
    pub fn scroll_amounts(dx: f64, dy: f64, precise: bool, horizontal_only: bool) -> (f64, f64) {
        Self::scroll_amounts_with_feel(dx, dy, precise, horizontal_only, &TimelineFeel::normal())
    }

    /// As above with the gain and vertical-swipe rule of `feel`. A trackpad swipe in a feel where vertical motion does
    /// not scroll time drops the vertical part when there is no vertical room; mouse wheels always map it onto time.
    pub fn scroll_amounts_with_feel(
        dx: f64,
        dy: f64,
        precise: bool,
        horizontal_only: bool,
        feel: &TimelineFeel,
    ) -> (f64, f64) {
        let kx = if precise { feel.trackpad_scroll_gain } else { Self::WHEEL_NOTCH };
        let ky = if precise { 1.0 } else { Self::WHEEL_NOTCH };
        if horizontal_only {
            if precise && !feel.vertical_swipe_scrolls_time {
                return (dx * kx, 0.0);
            }
            return ((if dx.abs() > dy.abs() { dx } else { dy }) * kx, 0.0);
        }
        (dx * kx, dy * ky)
    }
}

/// The axis a scroll gesture locked to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAxis {
    /// Horizontal only.
    Horizontal,
    /// Vertical only.
    Vertical,
    /// Both axes.
    Free,
}

/// How a gesture picks its axis.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAxisRule {
    /// Every gesture picks one axis; diagonal-ish starts count as horizontal (`ScrollTuning::VERTICAL_BIAS`).
    LockPerGesture,
    /// Lock only when one axis dominates by `ScrollTuning::PREDOMINANT_RATIO`, else pan freely.
    Predominant,
}

/// Per-gesture axis lock for trackpad scrolling: the first movement of a gesture picks horizontal or vertical, the
/// other axis is dropped until the gesture (including its momentum tail) ends. Mouse wheel events (no phase) pass.
/// `Predominant` (Fast Cut) locks only a clearly straight start and leaves a diagonal start free in both axes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollAxisLock {
    /// The rule in force.
    pub rule: ScrollAxisRule,
    axis: Option<ScrollAxis>,
    acc_x: f64,
    acc_y: f64,
}

impl Default for ScrollAxisLock {
    fn default() -> ScrollAxisLock {
        ScrollAxisLock::new(ScrollAxisRule::LockPerGesture)
    }
}

impl ScrollAxisLock {
    /// A lock with `rule`.
    pub fn new(rule: ScrollAxisRule) -> ScrollAxisLock {
        ScrollAxisLock { rule, axis: None, acc_x: 0.0, acc_y: 0.0 }
    }

    /// The locked axis, `None` before the gesture decided.
    pub fn axis(&self) -> Option<ScrollAxis> {
        self.axis
    }

    /// Filters one scroll event; returns (dx, dy).
    pub fn filter(&mut self, phase: ScrollPhase, momentum_phase: ScrollPhase, dx: f64, dy: f64) -> (f64, f64) {
        if momentum_phase != ScrollPhase::None {
            if momentum_phase == ScrollPhase::Began
                || momentum_phase == ScrollPhase::Changed
                || momentum_phase == ScrollPhase::Stationary
            {
                return self.apply(dx, dy);
            }
            let r = self.apply(dx, dy); // ended / canceled: last tail event
            self.reset();
            return r;
        }
        match phase {
            ScrollPhase::None => {
                self.reset();
                (dx, dy) // mouse wheel: stateless
            }
            ScrollPhase::MayBegin | ScrollPhase::Began => {
                self.reset();
                self.apply(dx, dy)
            }
            ScrollPhase::Changed | ScrollPhase::Stationary | ScrollPhase::Ended | ScrollPhase::Cancelled => {
                self.apply(dx, dy)
            }
        }
    }

    fn reset(&mut self) {
        self.axis = None;
        self.acc_x = 0.0;
        self.acc_y = 0.0;
    }

    fn apply(&mut self, dx: f64, dy: f64) -> (f64, f64) {
        if self.axis.is_none() {
            self.acc_x += dx;
            self.acc_y += dy;
            if self.acc_x.abs().max(self.acc_y.abs()) <= ScrollTuning::AXIS_LOCK_THRESHOLD {
                return (0.0, 0.0);
            }
            self.axis = Some(Self::pick(self.acc_x, self.acc_y, self.rule));
            // Release what was held back, on the chosen axis only.
            return Self::pass(self.axis, self.acc_x, self.acc_y);
        }
        Self::pass(self.axis, dx, dy)
    }

    pub(crate) fn pick(acc_x: f64, acc_y: f64, rule: ScrollAxisRule) -> ScrollAxis {
        match rule {
            ScrollAxisRule::LockPerGesture => {
                if acc_y.abs() > acc_x.abs() * ScrollTuning::VERTICAL_BIAS {
                    ScrollAxis::Vertical
                } else {
                    ScrollAxis::Horizontal
                }
            }
            ScrollAxisRule::Predominant => {
                if acc_x.abs() >= acc_y.abs() * ScrollTuning::PREDOMINANT_RATIO {
                    return ScrollAxis::Horizontal;
                }
                if acc_y.abs() >= acc_x.abs() * ScrollTuning::PREDOMINANT_RATIO {
                    return ScrollAxis::Vertical;
                }
                ScrollAxis::Free
            }
        }
    }

    fn pass(axis: Option<ScrollAxis>, dx: f64, dy: f64) -> (f64, f64) {
        match axis {
            Some(ScrollAxis::Vertical) => (0.0, dy),
            Some(ScrollAxis::Free) => (dx, dy),
            Some(ScrollAxis::Horizontal) | None => (dx, 0.0),
        }
    }
}

/// While a pinch (magnify) is active, and shortly after, the vertical part of scroll events is residue of the pinch.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PinchScrollGuard {
    active: bool,
    ended_at: Option<f64>,
}

impl PinchScrollGuard {
    /// A fresh guard.
    pub fn new() -> PinchScrollGuard {
        PinchScrollGuard::default()
    }

    /// Feed every magnify event; `now` is a monotonic clock in seconds.
    pub fn magnify(&mut self, phase: ScrollPhase, now: f64) {
        match phase {
            ScrollPhase::Began | ScrollPhase::Changed | ScrollPhase::MayBegin | ScrollPhase::Stationary => {
                self.active = true;
                self.ended_at = None;
            }
            ScrollPhase::Ended | ScrollPhase::Cancelled => {
                self.active = false;
                self.ended_at = Some(now);
            }
            ScrollPhase::None => {
                self.active = true;
                self.ended_at = Some(now); // a phase-less magnify: treat as an instant gesture
            }
        }
    }

    /// True while the vertical part of a scroll event is pinch residue.
    pub fn suppresses_vertical(&self, now: f64) -> bool {
        if self.active {
            return true;
        }
        if let Some(e) = self.ended_at {
            return now - e < ScrollTuning::PINCH_TAIL;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ScrollPhase as P;

    #[test]
    fn constants() {
        assert_eq!(ScrollTuning::TRACKPAD_SCROLL_GAIN, 1.6);
        assert_eq!(ScrollTuning::WHEEL_NOTCH, 48.0);
    }

    #[test]
    fn amounts_trackpad_gain_horizontal_only() {
        let a = ScrollTuning::scroll_amounts(10.0, 10.0, true, false);
        assert!((a.0 - 16.0).abs() < 1e-9 && a.1 == 10.0);
        let w = ScrollTuning::scroll_amounts(1.0, 2.0, false, false);
        assert!(w.0 == 48.0 && w.1 == 96.0);
        let h = ScrollTuning::scroll_amounts(1.0, 3.0, false, true);
        assert!(h.0 == 144.0 && h.1 == 0.0);
        let h2 = ScrollTuning::scroll_amounts(5.0, 1.0, true, true);
        assert!((h2.0 - 8.0).abs() < 1e-9 && h2.1 == 0.0);
    }

    #[test]
    fn horizontal_swipe_drops_vertical_whole_gesture_and_momentum() {
        let mut l = ScrollAxisLock::default();
        let mut r = l.filter(P::Began, P::None, 5.0, 1.0);
        assert_eq!(r, (5.0, 0.0)); // released on lock
        r = l.filter(P::Changed, P::None, 8.0, 6.0);
        assert_eq!(r, (8.0, 0.0));
        l.filter(P::Ended, P::None, 0.0, 0.0);
        r = l.filter(P::None, P::Began, 3.0, 2.0);
        assert_eq!(r, (3.0, 0.0));
        r = l.filter(P::None, P::Ended, 1.0, 1.0);
        assert_eq!(r, (1.0, 0.0));
        assert_eq!(l.axis(), None);
    }

    #[test]
    fn vertical_needs_bias() {
        let mut l = ScrollAxisLock::default();
        l.filter(P::Began, P::None, 3.0, 4.0); // 4 < 3*1.5: stays horizontal
        assert_eq!(l.axis(), Some(ScrollAxis::Horizontal));
        l = ScrollAxisLock::default();
        let r = l.filter(P::Began, P::None, 1.0, 4.0);
        assert!(l.axis() == Some(ScrollAxis::Vertical) && r == (0.0, 4.0));
    }

    #[test]
    fn accumulates_below_threshold_and_new_gesture_resets() {
        let mut l = ScrollAxisLock::default();
        let mut r = l.filter(P::Began, P::None, 0.0, 1.0);
        assert!(r == (0.0, 0.0) && l.axis().is_none());
        r = l.filter(P::Changed, P::None, 0.0, 2.0);
        assert!(l.axis() == Some(ScrollAxis::Vertical) && r.1 == 3.0);
        r = l.filter(P::Began, P::None, 4.0, 0.0);
        assert!(l.axis() == Some(ScrollAxis::Horizontal) && r.0 == 4.0);
    }

    #[test]
    fn mouse_wheel_stateless() {
        let mut l = ScrollAxisLock::default();
        l.filter(P::Began, P::None, 5.0, 0.0);
        let r = l.filter(P::None, P::None, 1.0, 2.0);
        assert!(r == (1.0, 2.0) && l.axis().is_none());
    }

    #[test]
    fn pinch_guard_window() {
        let mut g = PinchScrollGuard::new();
        assert!(!g.suppresses_vertical(0.0));
        g.magnify(P::Began, 1.0);
        assert!(g.suppresses_vertical(5.0)); // still active
        g.magnify(P::Ended, 6.0);
        assert!(g.suppresses_vertical(6.2));
        assert!(!g.suppresses_vertical(6.26));
    }
}
