// Swift: TimelinePanel+Wheel.swift
//! Trackpad and wheel: `TimelineView.scrollWheel / magnify / smartMagnify`, translated. The same `sq-timeline-ui` rules
//! (`ScrollZoomState`, `ScrollAxisLock`, `PinchScrollGuard`, `ScrollTuning`, `ElasticAxis`) fed with the deltas of
//! `ScrollGesture`.

use crate::panel::TimelinePanel;
use sq_core_model::TimelineEditMode;
use sq_draw::InputModifiers;
use sq_draw::scroll::{GestureKind, ScrollCarry, ScrollGesture, ScrollPhase as DrawPhase};
use sq_draw::spring::ReleaseSpring;
use sq_timeline_ui::{
    ElasticAxis, PinchScrollGuard, RubberBand, ScrollAxisLock, ScrollPhase, ScrollTuning, ScrollZoomState,
    TimelineFeel, TimelineZoom,
};
use sq_uikit::controls_grid::CGPoint;

/// Position, time and smoothed velocity (points per second) of the last rubber-band event.
#[derive(Clone, Copy, Debug)]
pub(crate) struct PullTrack {
    at: f64,
    vx: f64,
    vy: f64,
}

/// A running spring back of a rubber-band overscroll, started at `start` (panel clock), seeded with the release velocity.
#[derive(Clone, Copy, Debug)]
pub(crate) struct SpringBack {
    to_x: f64,
    to_y: f64,
    x: ReleaseSpring,
    y: ReleaseSpring,
    start: f64,
}

/// The spring back as one state: transitions are `start`, `stop` and `sample` only.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) enum SpringState {
    #[default]
    Rest,
    Running(SpringBack),
}

/// Where the spring puts the view at a moment.
pub(crate) enum SpringSample {
    Moving(f64, f64),
    Done,
}

impl SpringState {
    pub(crate) fn is_running(&self) -> bool {
        matches!(self, SpringState::Running(_))
    }

    /// Starts from `from` toward `to` at `velocity` (scroll points per second); reduced motion lands at once.
    pub(crate) fn start(from: (f64, f64), to: (f64, f64), velocity: (f64, f64), now: f64) -> SpringState {
        if sq_draw::motion::reduce_motion() || (to.0 == from.0 && to.1 == from.1) {
            return SpringState::Rest;
        }
        let axis = |from: f64, to: f64, v: f64| ReleaseSpring::new(from - to, if from == to { 0.0 } else { v });
        SpringState::Running(SpringBack {
            to_x: to.0,
            to_y: to.1,
            x: axis(from.0, to.0, velocity.0),
            y: axis(from.1, to.1, velocity.1),
            start: now,
        })
    }

    /// A press or a new gesture stops it where it is.
    pub(crate) fn stop(&mut self) {
        *self = SpringState::Rest;
    }

    pub(crate) fn sample(&self, now: f64) -> SpringSample {
        let SpringState::Running(s) = self else { return SpringSample::Done };
        let t = now - s.start;
        if s.x.is_settled(t) && s.y.is_settled(t) {
            return SpringSample::Done;
        }
        SpringSample::Moving(s.to_x + s.x.offset(t), s.to_y + s.y.offset(t))
    }
}

/// The stored state of `TimelineView.scrollWheel / magnify`.
#[derive(Default)]
pub(crate) struct TimelineWheelState {
    scroll_zoom: ScrollZoomState,
    axis_lock: ScrollAxisLock,
    pinch_guard: PinchScrollGuard,
    elastic_x: ElasticAxis,
    elastic_y: ElasticAxis,
    spring_back: SpringState,
    /// The displayed position and velocity of the last rubber-band event (release velocity for the spring).
    pull: Option<PullTrack>,
    /// Fingers (or their momentum tail) are on a rubber-band scroll: the view may sit past its ends.
    elastic_tracking: bool,
    /// Sub-pixel parts of the scroll deltas not applied yet (carried into the next event).
    carry_x: ScrollCarry,
    carry_y: ScrollCarry,
}

impl TimelineWheelState {
    /// `clampScroll` leaves an overscroll alone while it is pulled or springs back.
    pub(crate) fn allows_overscroll(&self) -> bool {
        self.elastic_tracking || self.spring_back.is_running()
    }
}

impl TimelinePanel {
    pub(crate) fn feel(&self) -> TimelineFeel {
        TimelineFeel::for_magnetic(self.timeline.edit_mode() == TimelineEditMode::Magnetic)
    }

    /// A rubber band springs back: the host keeps drawing frames until it settles.
    pub fn is_springing_back(&self) -> bool {
        self.wheel.spring_back.is_running()
    }

    fn phase(p: DrawPhase) -> ScrollPhase {
        match p {
            DrawPhase::None => ScrollPhase::None,
            DrawPhase::MayBegin => ScrollPhase::MayBegin,
            DrawPhase::Began => ScrollPhase::Began,
            DrawPhase::Changed => ScrollPhase::Changed,
            DrawPhase::Stationary => ScrollPhase::Stationary,
            DrawPhase::Ended => ScrollPhase::Ended,
            DrawPhase::Cancelled => ScrollPhase::Cancelled,
        }
    }

    /// One wheel, trackpad scroll, pinch or two-finger double tap at `p` (panel points).
    pub(crate) fn scroll_wheel(&mut self, p: CGPoint, g: &ScrollGesture, mods: InputModifiers) {
        match g.kind {
            GestureKind::Magnify(m) => {
                self.magnify(p, m, g.phase);
                return;
            }
            GestureKind::SmartMagnify => {
                if self.feel().double_tap_fits {
                    self.zoom_to_fit(); // Fast Cut (Final Cut); the Normal view has no double tap
                }
                return;
            }
            GestureKind::Scroll => {}
        }
        let tune = self.feel();
        let phase = Self::phase(g.phase);
        let momentum = Self::phase(g.momentum_phase);
        let (dx, dy) = (g.delta_x, g.delta_y);
        // Command / Option zooms about the pointer; a momentum tail keeps the decision of its gesture.
        let held = mods.contains(InputModifiers::COMMAND) || mods.contains(InputModifiers::OPTION);
        if self.wheel.scroll_zoom.is_zoom(phase, momentum, held) {
            let d = if dy.abs() >= dx.abs() { dy } else { dx };
            let pps = self.geometry.points_per_second * TimelineZoom::scroll_factor(d, g.precise);
            self.set_zoom(pps, Some(p.x));
            return;
        }
        let mut d = (dx, dy);
        if g.precise {
            if self.wheel.axis_lock.rule != tune.axis_rule {
                self.wheel.axis_lock = ScrollAxisLock::new(tune.axis_rule);
            }
            d = self.wheel.axis_lock.filter(phase, momentum, d.0, d.1);
        }
        if self.wheel.pinch_guard.suppresses_vertical((self.clock)()) {
            d.1 = 0.0;
        }
        let horizontal_only = mods.contains(InputModifiers::SHIFT) || self.max_scroll_y() == 0.0;
        let a = ScrollTuning::scroll_amounts_with_feel(d.0, d.1, g.precise, horizontal_only, &tune);
        if tune.rubber_band && g.precise {
            self.elastic_scroll(-a.0, -a.1, phase, momentum);
            return;
        }
        if self.wheel.spring_back.is_running() || self.wheel.elastic_tracking {
            self.end_spring_back(true);
        }
        if a.0 == 0.0 && a.1 == 0.0 {
            return;
        }
        let scale = f64::from(self.scale);
        self.geometry.scroll_x -= self.wheel.carry_x.whole(a.0, scale);
        self.geometry.scroll_y -= self.wheel.carry_y.whole(a.1, scale);
        self.clamp_scroll();
    }

    /// Pinch: zoom about the pointer; its vertical residue does not scroll (`PinchScrollGuard`).
    fn magnify(&mut self, p: CGPoint, m: f64, phase: DrawPhase) {
        self.wheel.pinch_guard.magnify(Self::phase(phase), (self.clock)());
        let pps = self.geometry.points_per_second * TimelineZoom::pinch_factor(m);
        self.set_zoom(pps, Some(p.x));
    }

    // MARK: Rubber band (feel.rubber_band)

    /// `TimelineView.elasticScroll`: `dx`/`dy` are scroll-offset deltas. Vertical bounces only when the tracks overflow.
    fn elastic_scroll(&mut self, dx: f64, dy: f64, phase: ScrollPhase, momentum: ScrollPhase) {
        if momentum == ScrollPhase::None && (phase == ScrollPhase::Began || phase == ScrollPhase::MayBegin) {
            self.end_spring_back(false);
        }
        if self.wheel.spring_back.is_running() {
            return; // the momentum tail of a released overscroll
        }
        let before = (self.geometry.scroll_x, self.geometry.scroll_y);
        let which = if momentum == ScrollPhase::None { phase } else { momentum };
        self.wheel.elastic_tracking = matches!(
            which,
            ScrollPhase::MayBegin | ScrollPhase::Began | ScrollPhase::Changed | ScrollPhase::Stationary
        );
        let x = self.wheel.elastic_x.step(
            self.geometry.scroll_x,
            dx,
            &(0.0..=self.max_scroll_x()),
            self.content_viewport_width(),
            phase,
            momentum,
        );
        let mut y_position = self.geometry.scroll_y;
        let mut y_spring = false;
        let max_y = self.max_scroll_y();
        if max_y > 0.0 {
            let y = self.wheel.elastic_y.step(
                self.geometry.scroll_y,
                dy,
                &(0.0..=max_y),
                self.track_area_height(),
                phase,
                momentum,
            );
            y_position = y.position;
            y_spring = y.spring_back;
        }
        self.geometry.scroll_x = x.position;
        self.geometry.scroll_y = y_position;
        self.track_pull(before);
        if x.spring_back || y_spring {
            self.start_spring_back();
        }
        self.clamp_scroll();
    }

    /// Keeps the displayed speed of the rubber-band scroll: the release velocity that seeds the spring.
    fn track_pull(&mut self, before: (f64, f64)) {
        let now = (self.clock)();
        let (x, y) = (self.geometry.scroll_x, self.geometry.scroll_y);
        let prev = self.wheel.pull;
        let (mut vx, mut vy) = (0.0, 0.0);
        if let Some(p) = prev {
            let dt = now - p.at;
            if dt > 0.0 && dt <= 0.1 {
                // 60 percent of the newest sample, 40 percent of the history: steady against event jitter.
                vx = 0.6 * (x - before.0) / dt + 0.4 * p.vx;
                vy = 0.6 * (y - before.1) / dt + 0.4 * p.vy;
            }
        }
        self.wheel.pull = Some(PullTrack { at: now, vx, vy });
    }

    /// Springs an overscrolled view back to its ends (critically damped, seeded with the release velocity; driven by `tick`).
    fn start_spring_back(&mut self) {
        let (sx, sy) = (self.geometry.scroll_x, self.geometry.scroll_y);
        let tx = RubberBand::edge(sx, &(0.0..=self.max_scroll_x())).unwrap_or(sx);
        let ty = RubberBand::edge(sy, &(0.0..=self.max_scroll_y())).unwrap_or(sy);
        let now = (self.clock)();
        // A finger that rested before it lifted carries no speed.
        let v = self.wheel.pull.filter(|p| now - p.at <= 0.1).map_or((0.0, 0.0), |p| (p.vx, p.vy));
        self.end_spring_back(false);
        self.wheel.spring_back = SpringState::start((sx, sy), (tx, ty), v, now);
    }

    /// One frame of a running spring back (`TimelineView.springBackTick`).
    pub(crate) fn step_spring_back(&mut self) {
        if !self.wheel.spring_back.is_running() {
            return;
        }
        match self.wheel.spring_back.sample((self.clock)()) {
            SpringSample::Done => self.end_spring_back(true),
            SpringSample::Moving(x, y) => {
                self.geometry.scroll_x = x;
                self.geometry.scroll_y = y;
                self.interaction.geometry = self.geometry.clone();
            }
        }
    }

    /// Stops a running spring back; `settle` puts the view inside its range (the spring's end state).
    pub(crate) fn end_spring_back(&mut self, settle: bool) {
        self.wheel.spring_back.stop();
        self.wheel.pull = None;
        self.wheel.elastic_tracking = false;
        if settle {
            self.clamp_scroll();
        }
    }
}
