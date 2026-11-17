// Swift: TimelineZoom.swift (ZoomAnimation, ScrollZoomState, PlayheadHit) and TimelineZoomAnimation.swift
//! Short ease for key, zoom-tool click and `\` zoom changes (pure; the view drives it with a 60 Hz timer), the scroll-wheel
//! zoom decision and the playhead-line hit test.

use crate::portable_theme::motion;
use crate::timeline_zoom::TimelineZoom;

/// How the scroll follows the scale during a [`ZoomAnimation`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ZoomMode {
    /// The time under this x (content coordinates, 0 = left edge of the content area) stays fixed.
    Anchored {
        /// Anchor x.
        x: f64,
    },
    /// No anchor (fit / restore): the time at the left edge moves linearly from start to end.
    Free,
}

/// Short ease for key, zoom-tool click and `\` zoom changes. The scale is interpolated in log space so every frame is the
/// same zoom ratio apart, which keeps the anchored time exact: scroll_x comes from `TimelineZoom::anchored_scroll` for
/// the interpolated scale each frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ZoomAnimation {
    /// Scale at progress 0.
    pub from_scale: f64,
    /// Scale at progress 1.
    pub to_scale: f64,
    /// Scroll at progress 0.
    pub from_scroll: f64,
    /// Scroll at progress 1.
    pub to_scroll: f64,
    /// Anchoring.
    pub mode: ZoomMode,
}

impl ZoomAnimation {
    /// Duration in seconds.
    pub const DURATION: f64 = motion::FAST;
    /// Timer rate.
    pub const FRAME_RATE: f64 = 60.0;

    /// Frames a full animation takes at `FRAME_RATE`.
    pub fn frame_count() -> i64 {
        (Self::DURATION * Self::FRAME_RATE).round() as i64
    }

    /// A new animation.
    pub fn new(from_scale: f64, from_scroll: f64, to_scale: f64, to_scroll: f64, mode: ZoomMode) -> ZoomAnimation {
        ZoomAnimation { from_scale, to_scale, from_scroll, to_scroll, mode }
    }

    /// Ease-out cubic (`Theme.Motion.Curve.easeOut`): fast start, soft landing. 0 -> 0, 1 -> 1, monotonic.
    pub fn ease(t: f64) -> f64 {
        motion::Curve::EaseOut.value(t)
    }

    /// State (scale, scroll_x) at `progress` (0...1 of the duration, linear time). Endpoints are exact.
    pub fn state(&self, progress: f64) -> (f64, f64) {
        let p = progress.clamp(0.0, 1.0);
        if p >= 1.0 {
            return (self.to_scale, self.to_scroll);
        }
        if p <= 0.0 {
            return (self.from_scale, self.from_scroll);
        }
        let e = Self::ease(p);
        let scale = self.from_scale * (self.to_scale / self.from_scale).powf(e);
        match self.mode {
            ZoomMode::Anchored { x } => {
                (scale, TimelineZoom::anchored_scroll(self.from_scale, scale, self.from_scroll, x))
            }
            ZoomMode::Free => {
                let a = self.from_scroll / self.from_scale;
                let b = self.to_scroll / self.to_scale;
                (scale, (a + (b - a) * e) * scale)
            }
        }
    }

    /// Progress after `elapsed` seconds.
    pub fn progress(elapsed: f64) -> f64 {
        (elapsed / Self::DURATION).clamp(0.0, 1.0)
    }
}

/// Scroll gesture phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    /// No phase (mouse wheel).
    None,
    /// May begin.
    MayBegin,
    /// Began.
    Began,
    /// Changed.
    Changed,
    /// Stationary.
    Stationary,
    /// Ended.
    Ended,
    /// Cancelled.
    Cancelled,
}

/// Decides whether a `scrollWheel` event zooms. Option/Cmd zooms; if the key is released while the trackpad momentum
/// tail still runs, the tail keeps zooming (instead of turning into a sideways scroll), until the momentum ends.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScrollZoomState {
    zooming: bool,
}

impl ScrollZoomState {
    /// A fresh state.
    pub fn new() -> ScrollZoomState {
        ScrollZoomState::default()
    }

    /// True while a zoom gesture is in flight.
    pub fn zooming(&self) -> bool {
        self.zooming
    }

    /// Feed every scroll event; returns true when it is a zoom event.
    pub fn is_zoom(&mut self, phase: ScrollPhase, momentum_phase: ScrollPhase, modifier_held: bool) -> bool {
        if momentum_phase != ScrollPhase::None {
            // Momentum tail: the modifier no longer matters, the gesture's decision stands.
            let result = self.zooming;
            if momentum_phase == ScrollPhase::Ended || momentum_phase == ScrollPhase::Cancelled {
                self.zooming = false;
            }
            return result;
        }
        match phase {
            ScrollPhase::None => {
                self.zooming = false; // mouse wheel: stateless
                modifier_held
            }
            ScrollPhase::MayBegin | ScrollPhase::Began => {
                self.zooming = modifier_held;
                self.zooming
            }
            ScrollPhase::Changed | ScrollPhase::Stationary => {
                self.zooming = modifier_held; // releasing the key with fingers down returns to scrolling
                self.zooming
            }
            ScrollPhase::Ended | ScrollPhase::Cancelled => {
                // Fingers lifted: the momentum tail (if any) follows this decision; the key may already be up.
                self.zooming
            }
        }
    }
}

/// Playhead line hit-test in the track area (drag it like the ruler scrub).
/// Priority: the line wins only when the pointer is within `TOLERANCE` of it; everywhere else clips, trim handles
/// and the rest keep the click, so a trim handle 5 pt from the line still trims. A handle within the 4 pt band
/// loses to the playhead (the line is exactly hit).
pub struct PlayheadHit;

impl PlayheadHit {
    /// Half width of the hit band.
    pub const TOLERANCE: f64 = 4.0;

    /// `content_left`/`content_top`/`content_bottom`: the track area in view coordinates (below the ruler, right of the headers).
    pub fn is_on_line(
        point_x: f64,
        point_y: f64,
        playhead_x: f64,
        content_left: f64,
        content_top: f64,
        content_bottom: f64,
    ) -> bool {
        if !(point_x >= content_left && point_y >= content_top && point_y < content_bottom) {
            return false;
        }
        (point_x - playhead_x).abs() <= Self::TOLERANCE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ScrollPhase as P;

    fn anim() -> ZoomAnimation {
        ZoomAnimation::new(10.0, 300.0, 25.0, 900.0, ZoomMode::Anchored { x: 200.0 })
    }

    #[test]
    fn frame_count_at_60hz() {
        assert_eq!(ZoomAnimation::frame_count(), 7); // 0.12 s * 60 = 7.2 -> 7
    }

    #[test]
    fn endpoints_exact() {
        let a = anim();
        assert_eq!(a.state(0.0), (10.0, 300.0));
        assert_eq!(a.state(1.0), (25.0, 900.0));
        assert_eq!(a.state(2.0), (25.0, 900.0));
        assert!(ZoomAnimation::ease(0.0) == 0.0 && ZoomAnimation::ease(1.0) == 1.0);
    }

    #[test]
    fn monotonic_scale_and_ease() {
        let a = anim();
        let (mut last, mut last_scale) = (-1.0, 0.0);
        for i in 0..=60 {
            let p = f64::from(i) / 60.0;
            let e = ZoomAnimation::ease(p);
            assert!(e >= last);
            last = e;
            let s = a.state(p).0;
            assert!(s >= last_scale);
            last_scale = s;
        }
        assert!(ZoomAnimation::ease(0.5) > 0.5); // ease-out: ahead of linear
    }

    #[test]
    fn log_space_keeps_ratio_per_ease() {
        let s = anim().state(0.5);
        let e = ZoomAnimation::ease(0.5);
        assert!((s.0 - 10.0 * 2.5_f64.powf(e)).abs() < 1e-9);
    }

    #[test]
    fn anchored_time_invariant() {
        let t0 = (200.0 + 300.0) / 10.0;
        for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let s = anim().state(p);
            assert!(((200.0 + s.1) / s.0 - t0).abs() < 1e-9);
        }
    }

    #[test]
    fn free_mode_endpoints_and_monotonic_left_edge() {
        let a = ZoomAnimation::new(50.0, 5000.0, 2.0, 0.0, ZoomMode::Free);
        assert!(a.state(0.0) == (50.0, 5000.0) && a.state(1.0) == (2.0, 0.0));
        let mut last = f64::INFINITY;
        for i in 0..=20 {
            let s = a.state(f64::from(i) / 20.0);
            let left = s.1 / s.0;
            assert!(left <= last + 1e-9);
            last = left;
        }
    }

    #[test]
    fn progress_clamps() {
        assert_eq!(ZoomAnimation::progress(0.06), 0.5);
        assert!(ZoomAnimation::progress(1.0) == 1.0 && ZoomAnimation::progress(-1.0) == 0.0);
    }

    fn run(events: &[(ScrollPhase, ScrollPhase, bool)]) -> Vec<bool> {
        let mut s = ScrollZoomState::new();
        events.iter().map(|e| s.is_zoom(e.0, e.1, e.2)).collect()
    }

    #[test]
    fn released_during_momentum_keeps_zooming() {
        let r = run(&[
            (P::Began, P::None, true),
            (P::Changed, P::None, true),
            (P::Ended, P::None, true),
            (P::None, P::Began, false),
            (P::None, P::Changed, false),
            (P::None, P::Ended, false),
        ]);
        assert_eq!(r, vec![true; 6]);
    }

    #[test]
    fn zoom_ends_after_momentum_ended() {
        let r = run(&[
            (P::Began, P::None, true),
            (P::Ended, P::None, true),
            (P::None, P::Changed, false),
            (P::None, P::Ended, false),
            (P::Began, P::None, false),
        ]);
        assert_eq!(r, vec![true, true, true, true, false]);
    }

    #[test]
    fn plain_scroll_never_zooms_even_if_key_pressed_in_momentum() {
        let r = run(&[
            (P::Began, P::None, false),
            (P::Changed, P::None, false),
            (P::Ended, P::None, false),
            (P::None, P::Began, true),
            (P::None, P::Changed, true),
            (P::None, P::Ended, true),
        ]);
        assert_eq!(r, vec![false; 6]);
    }

    #[test]
    fn release_with_fingers_down_returns_to_scroll() {
        assert_eq!(run(&[(P::Began, P::None, true), (P::Changed, P::None, false)]), vec![true, false]);
    }

    #[test]
    fn mouse_wheel_is_stateless() {
        let r = run(&[(P::None, P::None, true), (P::None, P::None, false), (P::None, P::None, true)]);
        assert_eq!(r, vec![true, false, true]);
    }

    #[test]
    fn cancelled_momentum_resets() {
        let r = run(&[
            (P::Began, P::None, true),
            (P::Ended, P::None, true),
            (P::None, P::Cancelled, false),
            (P::None, P::Changed, false),
        ]);
        assert_eq!(r, vec![true, true, true, false]);
    }

    fn hit(x: f64, y: f64) -> bool {
        PlayheadHit::is_on_line(x, y, 500.0, 100.0, 30.0, 400.0)
    }

    #[test]
    fn tolerance_band() {
        assert!(hit(500.0, 100.0) && hit(496.0, 100.0) && hit(504.0, 100.0));
        assert!(!hit(495.9, 100.0) && !hit(504.1, 100.0));
    }

    #[test]
    fn outside_track_area_never_hits() {
        assert!(!hit(500.0, 20.0)); // ruler
        assert!(!hit(500.0, 400.0)); // zoom bar / below
        assert!(!PlayheadHit::is_on_line(50.0, 100.0, 50.0, 100.0, 30.0, 400.0)); // scrolled under the headers
    }
}
