// Swift: TimelineFeel.swift
//! How the timeline answers trackpad scroll, pinch and playback. `Normal` is the Premiere-like behavior every sequence
//! had before Fast Cut; `fast_cut()` is the Final Cut feel a magnetic (Fast Cut) sequence gets.

use crate::portable_theme::motion;
use crate::scroll_gesture_logic::{ScrollAxisRule, ScrollTuning};
use crate::timeline_zoom_animation::ScrollPhase;
use std::ops::RangeInclusive;

/// Scroll policy while playing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackFollow {
    /// The view jumps a page when the playhead reaches the right edge (`TimelineFollow::page_scroll`).
    Page,
    /// The playhead runs to the center, then stays there while the content scrolls under it
    /// (`TimelineFollow::continuous_scroll`, Final Cut's "Continuous Scrolling").
    Continuous,
}

/// The feel of one timeline.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TimelineFeel {
    /// Trackpad pixel deltas are multiplied by this (1 = the content stays under the fingers).
    pub trackpad_scroll_gain: f64,
    /// Axis rule for trackpad gestures.
    pub axis_rule: ScrollAxisRule,
    /// Elastic overscroll past the ends with a spring back (trackpad only; mouse wheels clamp).
    pub rubber_band: bool,
    /// A vertical trackpad swipe scrolls time when there is no vertical room (Premiere-ish). Off: it does nothing.
    pub vertical_swipe_scrolls_time: bool,
    /// Two-finger double tap (smart magnify) zooms to fit the whole sequence.
    pub double_tap_fits: bool,
    /// Scroll policy while playing.
    pub playback_follow: PlaybackFollow,
}

impl Default for TimelineFeel {
    /// Today's behavior, unchanged.
    fn default() -> TimelineFeel {
        TimelineFeel {
            trackpad_scroll_gain: ScrollTuning::TRACKPAD_SCROLL_GAIN,
            axis_rule: ScrollAxisRule::LockPerGesture,
            rubber_band: false,
            vertical_swipe_scrolls_time: true,
            double_tap_fits: false,
            playback_follow: PlaybackFollow::Page,
        }
    }
}

impl TimelineFeel {
    /// Today's behavior, unchanged.
    pub fn normal() -> TimelineFeel {
        TimelineFeel::default()
    }

    /// Final Cut feel: 1:1 tracking, free diagonal pans, rubber band ends, double tap fits. Playback pages like Final
    /// Cut's default; `Continuous` is ready for a toggle.
    pub fn fast_cut() -> TimelineFeel {
        TimelineFeel {
            trackpad_scroll_gain: 1.0,
            axis_rule: ScrollAxisRule::Predominant,
            rubber_band: true,
            vertical_swipe_scrolls_time: false,
            double_tap_fits: true,
            playback_follow: PlaybackFollow::Page,
        }
    }

    /// The feel for a sequence's edit mode (magnetic = Fast Cut).
    pub fn for_magnetic(magnetic: bool) -> TimelineFeel {
        if magnetic { Self::fast_cut() } else { Self::normal() }
    }
}

/// Elastic overscroll maths (pure). Positions are scroll offsets in points; `dimension` is the viewport size along
/// the axis, which bounds how far the content can be pulled past its end.
pub struct RubberBand;

impl RubberBand {
    /// Apple's scroll-view constant: a small pull past the end moves the content at about this fraction of the fingers.
    pub const COEFFICIENT: f64 = 0.55;
    /// Spring-back duration (seconds).
    pub const SPRING_DURATION: f64 = 0.3;

    /// Displayed overscroll for a finger overscroll `x` (sign kept): `(1 - 1 / (|x| c / d + 1)) d`, always below `d`.
    pub fn damp(x: f64, d: f64) -> f64 {
        if d <= 0.0 {
            return 0.0;
        }
        let y = (1.0 - 1.0 / (x.abs() * Self::COEFFICIENT / d + 1.0)) * d;
        if x < 0.0 { -y } else { y }
    }

    /// Inverse of `damp` (finger overscroll that shows `y`); `y` is limited to just under `d`.
    pub fn undamp(y: f64, d: f64) -> f64 {
        if d <= 0.0 {
            return 0.0;
        }
        let a = y.abs().min(d * 0.999_999);
        let x = (1.0 / (1.0 - a / d) - 1.0) * d / Self::COEFFICIENT;
        if y < 0.0 { -x } else { x }
    }

    /// Finger position behind a displayed `position` (equal inside `range`).
    fn raw(position: f64, range: &RangeInclusive<f64>, dimension: f64) -> f64 {
        if position < *range.start() {
            return *range.start() - Self::undamp(*range.start() - position, dimension);
        }
        if position > *range.end() {
            return *range.end() + Self::undamp(position - *range.end(), dimension);
        }
        position
    }

    /// Displayed position for a finger position `raw`.
    fn displayed(raw: f64, range: &RangeInclusive<f64>, dimension: f64) -> f64 {
        if raw < *range.start() {
            return *range.start() - Self::damp(*range.start() - raw, dimension);
        }
        if raw > *range.end() {
            return *range.end() + Self::damp(raw - *range.end(), dimension);
        }
        raw
    }

    /// Scrolls a displayed position by a finger delta: plain inside `range`, damped past its ends, and exactly
    /// reversible (pulling back by the same delta returns to the same place).
    pub fn scroll(position: f64, delta: f64, range: &RangeInclusive<f64>, dimension: f64) -> f64 {
        Self::displayed(Self::raw(position, range, dimension) + delta, range, dimension)
    }

    /// The end of `range` an overscrolled position springs back to, `None` inside the range.
    pub fn edge(position: f64, range: &RangeInclusive<f64>) -> Option<f64> {
        if position < *range.start() {
            return Some(*range.start());
        }
        if position > *range.end() {
            return Some(*range.end());
        }
        None
    }

    /// Spring-back state at `progress` (0...1 of `SPRING_DURATION`): ease-out from `from` to `to`, endpoints exact.
    pub fn spring_back(from: f64, to: f64, progress: f64) -> f64 {
        let p = progress.clamp(0.0, 1.0);
        if p >= 1.0 {
            return to;
        }
        if p <= 0.0 {
            return from;
        }
        from + (to - from) * motion::Curve::EaseOut.value(p)
    }
}

/// One scroll axis with rubber-band ends, fed every scroll event (pure). Fingers pull past an end with damping and
/// spring back on release; a momentum tail that runs into an end bounces once (up to `max_momentum_bounce`) and the
/// rest of that tail is dropped; a mouse wheel (no phase) clamps hard.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ElasticAxis {
    swallowing_momentum: bool,
}

/// Result of [`ElasticAxis::step`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ElasticStep {
    /// New displayed position.
    pub position: f64,
    /// The view should start a spring back.
    pub spring_back: bool,
}

impl ElasticAxis {
    /// A fresh axis.
    pub fn new() -> ElasticAxis {
        ElasticAxis::default()
    }

    /// True after a spring back was asked for, until the next gesture: the rest of the momentum tail is ignored.
    pub fn swallowing_momentum(&self) -> bool {
        self.swallowing_momentum
    }

    /// Furthest a momentum tail may carry the content past an end (points).
    pub fn max_momentum_bounce(dimension: f64) -> f64 {
        dimension * 0.05
    }

    /// New displayed position for `delta` (scroll-offset direction), and whether the view should start a spring back.
    pub fn step(
        &mut self,
        position: f64,
        delta: f64,
        range: &RangeInclusive<f64>,
        dimension: f64,
        phase: ScrollPhase,
        momentum_phase: ScrollPhase,
    ) -> ElasticStep {
        let step = |position: f64, spring_back: bool| ElasticStep { position, spring_back };
        if momentum_phase != ScrollPhase::None {
            if self.swallowing_momentum {
                if momentum_phase == ScrollPhase::Ended || momentum_phase == ScrollPhase::Cancelled {
                    self.swallowing_momentum = false;
                }
                return step(position, false);
            }
            let mut p = RubberBand::scroll(position, delta, range, dimension);
            if momentum_phase == ScrollPhase::Ended || momentum_phase == ScrollPhase::Cancelled {
                return step(p, RubberBand::edge(p, range).is_some());
            }
            if let Some(e) = RubberBand::edge(p, range) {
                let cap = Self::max_momentum_bounce(dimension);
                if (p - e).abs() >= cap {
                    p = e + if p < e { -cap } else { cap };
                    self.swallowing_momentum = true;
                    return step(p, true);
                }
            }
            return step(p, false);
        }
        match phase {
            ScrollPhase::None => {
                self.swallowing_momentum = false;
                step((position + delta).max(*range.start()).min(*range.end()), false)
            }
            ScrollPhase::MayBegin | ScrollPhase::Began => {
                self.swallowing_momentum = false;
                step(RubberBand::scroll(position, delta, range, dimension), false)
            }
            ScrollPhase::Changed | ScrollPhase::Stationary => {
                step(RubberBand::scroll(position, delta, range, dimension), false)
            }
            ScrollPhase::Ended | ScrollPhase::Cancelled => {
                let p = RubberBand::scroll(position, delta, range, dimension);
                let out = RubberBand::edge(p, range).is_some();
                self.swallowing_momentum = out;
                step(p, out)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scroll_gesture_logic::{ScrollAxis, ScrollAxisLock, ScrollAxisRule, ScrollTuning};
    use ScrollPhase as P;

    // --- presets

    #[test]
    fn normal_is_todays_behaviour() {
        let n = TimelineFeel::normal();
        assert_eq!(n.trackpad_scroll_gain, ScrollTuning::TRACKPAD_SCROLL_GAIN);
        assert_eq!(n.axis_rule, ScrollAxisRule::LockPerGesture);
        assert!(!n.rubber_band);
        assert!(n.vertical_swipe_scrolls_time);
        assert!(!n.double_tap_fits);
        assert_eq!(n.playback_follow, PlaybackFollow::Page);
        assert_eq!(TimelineFeel::default(), TimelineFeel::normal());
    }

    #[test]
    fn fast_cut_is_final_cut_like() {
        let f = TimelineFeel::fast_cut();
        assert_eq!(f.trackpad_scroll_gain, 1.0);
        assert_eq!(f.axis_rule, ScrollAxisRule::Predominant);
        assert!(f.rubber_band);
        assert!(!f.vertical_swipe_scrolls_time);
        assert!(f.double_tap_fits);
        assert_eq!(f.playback_follow, PlaybackFollow::Page);
        assert!(TimelineFeel::for_magnetic(true) == TimelineFeel::fast_cut());
        assert!(TimelineFeel::for_magnetic(false) == TimelineFeel::normal());
    }

    #[test]
    fn amounts_use_feel_gain() {
        let a = ScrollTuning::scroll_amounts_with_feel(10.0, 4.0, true, false, &TimelineFeel::fast_cut());
        assert!(a.0 == 10.0 && a.1 == 4.0);
        let n = ScrollTuning::scroll_amounts_with_feel(10.0, 4.0, true, false, &TimelineFeel::normal());
        assert!((n.0 - 16.0).abs() < 1e-9 && n.1 == 4.0);
        // Fast Cut: a trackpad swipe without vertical room never turns vertical motion into time.
        let h = ScrollTuning::scroll_amounts_with_feel(1.0, 9.0, true, true, &TimelineFeel::fast_cut());
        assert!(h.0 == 1.0 && h.1 == 0.0);
        // The mouse wheel keeps mapping vertical notches onto time in both feels.
        let w = ScrollTuning::scroll_amounts_with_feel(0.0, 1.0, false, true, &TimelineFeel::fast_cut());
        assert!(w.0 == 48.0 && w.1 == 0.0);
    }

    // --- predominant axis (free diagonal)

    #[test]
    fn predominant_locks_clearly_horizontal_swipe() {
        let mut l = ScrollAxisLock::new(ScrollAxisRule::Predominant);
        let r = l.filter(P::Began, P::None, 6.0, 2.0);
        assert!(l.axis() == Some(ScrollAxis::Horizontal) && r == (6.0, 0.0));
        let r2 = l.filter(P::Changed, P::None, 3.0, 5.0);
        assert_eq!(r2, (3.0, 0.0));
    }

    #[test]
    fn predominant_locks_clearly_vertical_swipe() {
        let mut l = ScrollAxisLock::new(ScrollAxisRule::Predominant);
        let r = l.filter(P::Began, P::None, 1.0, -6.0);
        assert!(l.axis() == Some(ScrollAxis::Vertical) && r == (0.0, -6.0));
    }

    #[test]
    fn diagonal_start_stays_free_for_whole_gesture_and_momentum() {
        let mut l = ScrollAxisLock::new(ScrollAxisRule::Predominant);
        let r = l.filter(P::Began, P::None, 4.0, 4.0);
        assert!(l.axis() == Some(ScrollAxis::Free) && r == (4.0, 4.0));
        let r2 = l.filter(P::Changed, P::None, 10.0, 0.5);
        assert_eq!(r2, (10.0, 0.5));
        l.filter(P::Ended, P::None, 0.0, 0.0);
        let m = l.filter(P::None, P::Changed, 2.0, 3.0);
        assert_eq!(m, (2.0, 3.0));
        l.filter(P::None, P::Ended, 0.0, 0.0);
        assert_eq!(l.axis(), None);
    }

    #[test]
    fn predominant_holds_back_until_threshold() {
        let mut l = ScrollAxisLock::new(ScrollAxisRule::Predominant);
        let r = l.filter(P::Began, P::None, 1.0, 0.5);
        assert!(r == (0.0, 0.0) && l.axis().is_none());
        let r2 = l.filter(P::Changed, P::None, 1.5, 2.0);
        // Accumulated 2.5 x 2.5: diagonal, everything held back is released.
        assert!(l.axis() == Some(ScrollAxis::Free) && r2 == (2.5, 2.5));
    }

    #[test]
    fn predominant_wheel_is_stateless() {
        let mut l = ScrollAxisLock::new(ScrollAxisRule::Predominant);
        let r = l.filter(P::None, P::None, 1.0, 2.0);
        assert!(r == (1.0, 2.0) && l.axis().is_none());
    }

    // --- rubber band

    #[test]
    fn damp_is_monotonic_bounded_and_invertible() {
        let d = 800.0;
        assert_eq!(RubberBand::damp(0.0, d), 0.0);
        let mut last = 0.0;
        let mut x = 10.0;
        while x <= 5000.0 {
            let y = RubberBand::damp(x, d);
            assert!(y > last && y < d);
            assert!((RubberBand::undamp(y, d) - x).abs() < 1e-6 * x + 1e-9);
            last = y;
            x += 10.0;
        }
        assert_eq!(RubberBand::damp(-100.0, d), -RubberBand::damp(100.0, d));
        // Small pulls follow the fingers at about coefficient speed.
        assert!((RubberBand::damp(1.0, d) - RubberBand::COEFFICIENT).abs() < 0.01);
    }

    /// Gestures (w71): the rubber band is a growing resistance, never a hard stop and never a jump.
    #[test]
    fn the_band_resists_more_the_further_it_is_pulled() {
        let d = 400.0;
        let mut last_gain = f64::INFINITY;
        let mut last = 0.0;
        for x in (1..=200).map(|n| f64::from(n) * 10.0) {
            let y = RubberBand::damp(x, d);
            let gain = (y - last) / 10.0;
            assert!(y > last && y < d, "grows, stays under the view size at {x}");
            assert!(gain < last_gain, "resistance grows: gain {gain} at {x}");
            (last, last_gain) = (y, gain);
        }
        assert!(RubberBand::damp(1.0, d) > 0.5, "starts almost 1:1");
    }

    #[test]
    fn scroll_inside_range_is_plain() {
        assert_eq!(RubberBand::scroll(100.0, 50.0, &(0.0..=1000.0), 800.0), 150.0);
    }

    #[test]
    fn scroll_past_edge_is_damped_and_returns_exactly() {
        let r = 0.0..=1000.0;
        let p = RubberBand::scroll(10.0, -110.0, &r, 800.0);
        // 10 points plain, 100 past the edge damped.
        assert!(p < 0.0 && p > -100.0);
        assert!((p + RubberBand::damp(100.0, 800.0)).abs() < 1e-9);
        let back = RubberBand::scroll(p, 110.0, &r, 800.0);
        assert!((back - 10.0).abs() < 1e-9);
        let far = RubberBand::scroll(990.0, 60.0, &r, 800.0);
        assert!(far > 1000.0 && far < 1050.0);
    }

    #[test]
    fn spring_back_eases_to_edge() {
        assert_eq!(RubberBand::spring_back(-40.0, 0.0, 0.0), -40.0);
        assert_eq!(RubberBand::spring_back(-40.0, 0.0, 1.0), 0.0);
        let mut last = -40.0;
        for i in 1..=10 {
            let v = RubberBand::spring_back(-40.0, 0.0, f64::from(i) / 10.0);
            assert!(v >= last);
            last = v;
        }
        assert_eq!(RubberBand::edge(-5.0, &(0.0..=10.0)), Some(0.0));
        assert_eq!(RubberBand::edge(15.0, &(0.0..=10.0)), Some(10.0));
        assert_eq!(RubberBand::edge(5.0, &(0.0..=10.0)), None);
    }

    // --- elastic gesture

    const DIM: f64 = 800.0;

    fn range() -> RangeInclusive<f64> {
        0.0..=1000.0
    }

    #[test]
    fn wheel_clamps_hard() {
        let mut e = ElasticAxis::new();
        let s = e.step(5.0, -50.0, &range(), DIM, P::None, P::None);
        assert!(s.position == 0.0 && !s.spring_back);
    }

    #[test]
    fn fingers_overscroll_then_release_springs_back() {
        let r = range();
        let mut e = ElasticAxis::new();
        let mut s = e.step(0.0, -30.0, &r, DIM, P::Began, P::None);
        assert!(s.position < 0.0 && !s.spring_back);
        s = e.step(s.position, -30.0, &r, DIM, P::Changed, P::None);
        assert!(s.position < 0.0 && !s.spring_back);
        let held = s.position;
        s = e.step(held, 0.0, &r, DIM, P::Ended, P::None);
        assert!(s.spring_back && s.position == held);
        // The momentum tail of that gesture is swallowed while it springs back.
        s = e.step(held, -20.0, &r, DIM, P::None, P::Began);
        assert!(s.position == held && !s.spring_back);
        s = e.step(held, -1.0, &r, DIM, P::None, P::Ended);
        assert_eq!(s.position, held);
    }

    #[test]
    fn release_inside_needs_no_spring() {
        let r = range();
        let mut e = ElasticAxis::new();
        e.step(500.0, 10.0, &r, DIM, P::Began, P::None);
        let s = e.step(510.0, 0.0, &r, DIM, P::Ended, P::None);
        assert!(!s.spring_back && s.position == 510.0);
    }

    #[test]
    fn momentum_into_edge_bounces_once() {
        let r = range();
        let mut e = ElasticAxis::new();
        e.step(100.0, -10.0, &r, DIM, P::Began, P::None);
        e.step(90.0, 0.0, &r, DIM, P::Ended, P::None);
        let mut s = e.step(90.0, -60.0, &r, DIM, P::None, P::Began);
        assert!(s.position == 30.0 && !s.spring_back);
        s = e.step(30.0, -50.0, &r, DIM, P::None, P::Changed);
        assert!(s.position < 0.0 && s.position > -20.0);
        let mut springs = i32::from(s.spring_back);
        let mut p = s.position;
        for _ in 0..20 {
            s = e.step(p, -20.0, &r, DIM, P::None, P::Changed);
            if s.spring_back {
                springs += 1;
            }
            p = s.position;
        }
        assert_eq!(springs, 1);
        assert!(p > -ElasticAxis::max_momentum_bounce(DIM) - 1e-9);
        s = e.step(p, 0.0, &r, DIM, P::None, P::Ended);
        assert!(!s.spring_back);
    }

    #[test]
    fn momentum_ending_outside_springs_back() {
        let r = range();
        let mut e = ElasticAxis::new();
        e.step(10.0, -1.0, &r, DIM, P::Began, P::None);
        e.step(9.0, 0.0, &r, DIM, P::Ended, P::None);
        let mut s = e.step(9.0, -12.0, &r, DIM, P::None, P::Changed);
        assert!(s.position < 0.0 && !s.spring_back);
        s = e.step(s.position, 0.0, &r, DIM, P::None, P::Ended);
        assert!(s.spring_back);
    }

    #[test]
    fn new_gesture_grabs_mid_bounce() {
        let r = range();
        let mut e = ElasticAxis::new();
        e.step(0.0, -40.0, &r, DIM, P::Began, P::None);
        e.step(-20.0, 0.0, &r, DIM, P::Ended, P::None);
        let s = e.step(-10.0, 5.0, &r, DIM, P::Began, P::None);
        assert!(s.position > -10.0 && s.position < 0.0 && !s.spring_back);
    }
}
