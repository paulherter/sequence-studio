//! Scroll input and physics (Swift `ScrollGesture`, `ScrollBody`, `ScrollerBar`): the device data behind a scroll event, the
//! Windows wheel route, and one scrolling axis with the feel of Apple's trackpad scrolling, written once for Mac and Windows.
//! Time is always passed in (`UiCx::now`), there is no global clock and no registry of moving bodies: the app asks each panel's
//! [`ScrollBody::needs_frames`]. Formulas are the published ones (UIScrollView rubber band and deceleration rate).

use crate::canvas::Canvas;
use crate::input::InputEvent;
use crate::motion;
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use std::cell::Cell;

thread_local! {
    static CONTENT_EPOCH: Cell<u64> = const { Cell::new(0) };
}

/// Counts every time a [`ScrollBody`] showed a panel a different offset than the one before (wheel, trackpad, fling,
/// key, scroll into view, a layout pull-back). The app loop compares it across a frame: when it moved, content slid under
/// a resting pointer and the hosts hit-test again at the pointer, so no hover stays on the row that was there. One shared
/// signal means every scrolling list and panel gets this with no wiring of its own (the UI is single-threaded).
pub fn content_epoch() -> u64 {
    CONTENT_EPOCH.with(Cell::get)
}

/// A trackpad gesture phase (`NSEvent.Phase`); mouse wheels and Windows report `None`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    /// No phase (a wheel).
    None,
    /// Fingers touched, may begin.
    MayBegin,
    /// The gesture began.
    Began,
    /// The gesture moves.
    Changed,
    /// The fingers rest.
    Stationary,
    /// The gesture ended.
    Ended,
    /// The gesture was canceled.
    Cancelled,
}

/// What a [`ScrollGesture`] carries besides scrolling.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GestureKind {
    /// A scroll.
    Scroll,
    /// `NSEvent.magnification` (0.1 = 10 % bigger).
    Magnify(f64),
    /// A two-finger double tap.
    SmartMagnify,
}

/// The device data behind one `InputEvent::Scroll`, in the units and signs AppKit's `scrollingDeltaX/Y` use:
/// `precise` (trackpad) deltas are points, else (mouse wheel) lines, about 1 a notch; positive `delta_y` = content moves
/// down. A pinch rides the same route as a scroll of zero pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollGesture {
    /// Scroll, pinch or smart zoom.
    pub kind: GestureKind,
    /// Horizontal delta.
    pub delta_x: f64,
    /// Vertical delta.
    pub delta_y: f64,
    /// Trackpad (points) or wheel (lines).
    pub precise: bool,
    /// Gesture phase.
    pub phase: ScrollPhase,
    /// Momentum phase.
    pub momentum_phase: ScrollPhase,
    /// The host's own messages already carry any inertia (Windows precision touchpads send their glide as further wheel
    /// messages): a release makes no synthetic fling, the offset ends where the messages left it.
    pub host_inertia: bool,
}

impl Default for ScrollGesture {
    fn default() -> Self {
        ScrollGesture {
            kind: GestureKind::Scroll,
            delta_x: 0.0,
            delta_y: 0.0,
            precise: false,
            phase: ScrollPhase::None,
            momentum_phase: ScrollPhase::None,
            host_inertia: false,
        }
    }
}

impl ScrollGesture {
    /// Host pixels of one mouse-wheel notch (Windows: WHEEL_DELTA 120 -> 40 px).
    pub const WHEEL_PIXELS_PER_NOTCH: f64 = 40.0;

    /// A plain mouse wheel derived from the event's pixels.
    pub fn wheel(pixels_x: f32, pixels_y: f32) -> ScrollGesture {
        ScrollGesture {
            delta_x: pixels_x as f64 / Self::WHEEL_PIXELS_PER_NOTCH,
            delta_y: pixels_y as f64 / Self::WHEEL_PIXELS_PER_NOTCH,
            ..Self::default()
        }
    }
    /// Whether this is a scroll (not a pinch).
    pub fn is_scroll(&self) -> bool {
        self.kind == GestureKind::Scroll
    }
}

/// The Windows wheel route: `WM_MOUSEWHEEL` / `WM_MOUSEHWHEEL` to a [`ScrollGesture`] with the Mac meaning. A delta that is
/// not a whole `WHEEL_DELTA` (120) is a precision touchpad: `precise`, in points, with phases made up from the timing (the
/// end comes from [`WinScroll::idle`]). Ctrl + precise wheel messages are a pinch. Mouse notches are lines.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct WinScroll {
    last_at: Option<f64>,
    pinch: bool,
}

impl WinScroll {
    /// One `WHEEL_DELTA`.
    pub const WHEEL_DELTA: i32 = 120;
    /// A precision touchpad gesture ends after this long without a message.
    pub const IDLE_END: f64 = 0.12;
    /// Points of one `WHEEL_DELTA` from a precision touchpad (the 40 px a mouse notch scrolls).
    pub const POINTS_PER_WHEEL_DELTA: f64 = 40.0;
    /// Magnification of one `WHEEL_DELTA` of a pinch.
    pub const MAGNIFY_PER_WHEEL_DELTA: f64 = 0.1;

    /// A precise gesture is running (its end is still to come from `idle`).
    pub fn is_active(&self) -> bool {
        self.last_at.is_some()
    }

    /// One wheel message: `delta` the signed `WHEEL_DELTA` units, `control` Ctrl held.
    pub fn wheel(&mut self, delta: i32, horizontal: bool, control: bool, now: f64) -> ScrollGesture {
        let running = self.last_at.is_some_and(|l| now - l <= Self::IDLE_END);
        let d = delta as f64 / Self::WHEEL_DELTA as f64;
        if !running && delta % Self::WHEEL_DELTA == 0 {
            self.last_at = None;
            return ScrollGesture {
                delta_x: if horizontal { -d } else { 0.0 },
                delta_y: if horizontal { 0.0 } else { d },
                ..Default::default()
            };
        }
        if !running {
            self.pinch = control && !horizontal;
        }
        self.last_at = Some(now);
        let phase = if running { ScrollPhase::Changed } else { ScrollPhase::Began };
        if self.pinch {
            return ScrollGesture {
                kind: GestureKind::Magnify(d * Self::MAGNIFY_PER_WHEEL_DELTA),
                precise: true,
                phase,
                host_inertia: true,
                ..Default::default()
            };
        }
        let p = d * Self::POINTS_PER_WHEEL_DELTA;
        ScrollGesture {
            delta_x: if horizontal { -p } else { 0.0 },
            delta_y: if horizontal { 0.0 } else { p },
            precise: true,
            phase,
            host_inertia: true,
            ..Default::default()
        }
    }

    /// Call once per frame: the end of a precise gesture after `IDLE_END` without a message, else `None`.
    pub fn idle(&mut self, now: f64) -> Option<ScrollGesture> {
        self.last_at.filter(|l| now - l > Self::IDLE_END)?;
        self.last_at = None;
        let kind = if self.pinch { GestureKind::Magnify(0.0) } else { GestureKind::Scroll };
        Some(ScrollGesture { kind, precise: true, phase: ScrollPhase::Ended, host_inertia: true, ..Default::default() })
    }

    /// The pixels of `InputEvent::Scroll` for lists: a touchpad its points at `scale`, a mouse notch 40 px.
    pub fn pixels(g: &ScrollGesture, scale: f32) -> (f32, f32) {
        if !g.is_scroll() {
            return (0.0, 0.0);
        }
        let k = if g.precise { scale as f64 } else { ScrollGesture::WHEEL_PIXELS_PER_NOTCH };
        ((g.delta_x * k) as f32, (g.delta_y * k) as f32)
    }
}

/// Where a trackpad gesture goes: the place of its Began. A gesture's later events (moves, the end, the momentum tail, on
/// Windows the made-up end) are routed to that place and not to whatever is under the pointer by then, so the list that
/// started a stretch always gets the end that lets it spring back (bug 39: a list left out of range until its next input).
/// A wheel notch has no gesture and goes where the pointer is.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScrollTarget {
    /// The captured place and the time of the gesture's last event.
    held: Option<((f32, f32), f64)>,
}

impl ScrollTarget {
    /// A momentum tail starts within this long after the fingers lift; later events are a new gesture.
    pub const TAIL_GAP: f64 = 0.5;

    /// The place `g` (the pointer at `at`) is delivered to, at `now`.
    pub fn route(&mut self, g: &ScrollGesture, at: (f32, f32), now: f64) -> (f32, f32) {
        let phased = g.phase != ScrollPhase::None || g.momentum_phase != ScrollPhase::None;
        if !g.is_scroll() || !g.precise || !phased {
            return at;
        }
        let starts = g.phase == ScrollPhase::Began || g.phase == ScrollPhase::MayBegin;
        let fresh = self.held.is_none_or(|(_, last)| now - last > Self::TAIL_GAP);
        let place = match self.held {
            Some((p, _)) if !starts && !fresh => p,
            _ => at,
        };
        let over = matches!(g.momentum_phase, ScrollPhase::Ended | ScrollPhase::Cancelled);
        self.held = if over { None } else { Some((place, now)) };
        place
    }
}

/// Scroll deltas rounded to whole device pixels with the remainder carried into the next event: a slow trackpad drag of 0.3 px
/// steps still moves, and the content cache can shift whole pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScrollCarry {
    /// What is carried to the next call.
    pub remainder: f64,
}

impl ScrollCarry {
    /// `d` points (plus the carried remainder) as whole device pixels at `scale` pixels per point, in points.
    pub fn whole(&mut self, d: f64, scale: f64) -> f64 {
        let s = scale.max(1.0);
        let want = d + self.remainder;
        let applied = (want * s).round() / s;
        self.remainder = want - applied;
        applied
    }
    /// Forgets the remainder.
    pub fn reset(&mut self) {
        self.remainder = 0.0;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Idle,
    Tracking,
    Momentum,
    Glide,
    Spring,
    Ease,
}

/// One scrolling axis with the feel of Apple's trackpad scrolling:
/// fingers pull the content 1:1 inside its range and past an end through the rubber band
/// `f(x, d) = (1 - 1 / (x * 0.55 / d + 1)) * d`; lifting past an end springs back (critically damped); a fling keeps going
/// (system momentum events are used as they come, else the body decelerates by 0.998 per ms) and bounces off an end; a mouse
/// wheel eases to its target and never bounces. Positions are points along the axis, `0 ..= max_offset`. Content that fits
/// does not bounce. Physics only (f64); no media time.
#[derive(Clone, Debug)]
pub struct ScrollBody {
    mode: Mode,
    pos: f64,
    raw: f64,
    samples: Vec<(f64, f64)>,
    last_momentum_at: Option<f64>,
    glide: (f64, f64, f64),
    ease: (f64, f64, f64),
    spring: (f64, f64, f64, f64),
    /// Scrollable length (content minus viewport); unbounded until the panel says.
    pub max_offset: f64,
    /// Viewport length along the axis (the rubber band scale).
    pub extent: f64,
    /// The system delivers the momentum tail of a fling as scroll events (Mac); else the body synthesizes it.
    pub system_momentum: bool,
    /// The running gesture's host carries inertia in its own messages ([`ScrollGesture::host_inertia`]): no synthetic fling.
    host_inertia: bool,
    last_active: f64,
    /// The clock of the last scroll message (a gesture whose end never came is released after [`Self::TRACKING_STALE`]).
    last_event: f64,
    /// The latest time the body was advanced to; an older time never rewinds a bounce.
    clock: f64,
    scroller_dragging: bool,
    scroller_hover: bool,
    scroller_grab: f64,
    /// The offset the last [`Self::offset`] read handed to a panel (see [`content_epoch`]).
    reported: f64,
}

impl Default for ScrollBody {
    fn default() -> Self {
        ScrollBody::new(0.0)
    }
}

impl ScrollBody {
    /// UIScrollView's rubber band constant.
    pub const RUBBER_COEFFICIENT: f64 = 0.55;
    /// Velocity decay per millisecond of a fling.
    pub const DECELERATION_PER_MS: f64 = 0.998;
    /// Spring back speed (1/s).
    pub const SPRING_OMEGA: f64 = 11.0;
    /// Share of the speed that reaches the edge a fling bounces off.
    pub const EDGE_IMPACT: f64 = 0.5;
    /// A fling below this speed (pt/s) at lift-off does not glide.
    pub const MIN_FLING_SPEED: f64 = 120.0;
    /// Time constant (s) of the mouse wheel's ease.
    pub const EASE_TIME: f64 = 0.06;
    /// A trackpad gesture without a message for this long (s) counts as lifted: some devices and windows never send the
    /// end (the pointer left the list, X11 sends no phases), and a body must not stay stretched past an end.
    pub const TRACKING_STALE: f64 = 1.0;
    /// System momentum silent for this long (s) is over (its end message was lost).
    pub const MOMENTUM_STALE: f64 = 0.5;
    const VELOCITY_WINDOW: f64 = 0.1;
    const STALE_AFTER: f64 = 0.15;

    /// A body at `offset`.
    pub fn new(offset: f64) -> ScrollBody {
        ScrollBody {
            mode: Mode::Idle,
            pos: offset,
            raw: 0.0,
            samples: Vec::new(),
            last_momentum_at: None,
            glide: (0.0, 0.0, 0.0),
            ease: (0.0, 0.0, 0.0),
            spring: (0.0, 0.0, 0.0, 0.0),
            max_offset: f64::INFINITY,
            extent: 600.0,
            system_momentum: false,
            host_inertia: false,
            last_active: -100.0,
            last_event: -100.0,
            clock: f64::NEG_INFINITY,
            scroller_dragging: false,
            scroller_hover: false,
            scroller_grab: 0.0,
            reported: offset,
        }
    }

    /// The offset at `now` (advances the body to the clock).
    pub fn offset(&mut self, now: f64) -> f64 {
        self.advance(now);
        let o = self.idle_clamped();
        // Below a thousandth of a point no row can change under the pointer.
        if (o - self.reported).abs() > 1e-3 {
            self.reported = o;
            CONTENT_EPOCH.with(|e| e.set(e.get().wrapping_add(1)));
        }
        o
    }
    /// The position to draw and hit-test with this frame: a fling, bounce or wheel ease runs up to the frame clock
    /// ([`motion::begin_frame`]) and, while one runs, the loop is asked for the next frame ([`motion::request_frame`]).
    /// Panels read this, so a bounce springs back and settles with no input and no per-panel wiring.
    pub fn position(&mut self) -> f64 {
        let o = self.offset(motion::now());
        if self.wants_frame() {
            motion::request_frame();
        }
        o
    }
    /// The scrollable length and the viewport length of the current content (a panel says it every frame, so content that
    /// shrank under a scrolled list pulls the offset back at once).
    pub fn set_range(&mut self, max_offset: f64, extent: f64) {
        self.max_offset = max_offset;
        self.extent = extent.max(1.0);
    }
    /// A motion runs, or fingers hold the content past an end (their end may never come): the next frame must be drawn.
    fn wants_frame(&self) -> bool {
        let top = self.max_offset.max(0.0);
        self.is_animating() || (self.mode == Mode::Tracking && (self.pos < 0.0 || self.pos > top))
    }
    fn idle_clamped(&mut self) -> f64 {
        if self.mode == Mode::Idle {
            self.pos = self.pos.clamp(0.0, self.max_offset.max(0.0));
        }
        self.pos
    }

    /// A fling or bounce runs.
    pub fn is_animating(&self) -> bool {
        matches!(self.mode, Mode::Glide | Mode::Spring | Mode::Ease)
    }
    /// Frames are still needed: a fling or bounce runs, or the scroller is visible and fades.
    pub fn needs_frames(&self, now: f64) -> bool {
        self.is_animating()
            || self.scroller_dragging
            || now - self.last_active < ScrollerBar::VISIBLE_FOR + ScrollerBar::FADE
    }
    fn touch(&mut self, now: f64) {
        self.last_active = now;
    }

    /// The panel sets the offset (reset, scroll into view). A plain clamp of where the body is (a layout pass) leaves a
    /// running bounce alone.
    pub fn assign(&mut self, v: f64) {
        if self.mode != Mode::Idle && (v - self.pos.clamp(0.0, self.max_offset.max(0.0))).abs() < 0.01 {
            return;
        }
        self.mode = Mode::Idle;
        self.samples.clear();
        self.pos = v;
    }

    /// One scroll message. `delta` moves the offset (positive = later content).
    pub fn scroll(&mut self, delta: f64, g: &ScrollGesture, now: f64) {
        self.advance(now);
        if !delta.is_finite() {
            return;
        }
        self.last_event = now;
        if delta != 0.0 {
            self.touch(now);
        }
        let top = self.max_offset.max(0.0);
        if !g.precise {
            if delta != 0.0 {
                let from = if self.mode == Mode::Ease { self.ease.1 } else { self.pos.clamp(0.0, top) };
                let p0 = self.pos.clamp(0.0, top);
                let target = (from + delta).clamp(0.0, top);
                self.ease = (p0, target, now);
                self.samples.clear();
                if (target - p0).abs() < 0.25 {
                    self.pos = target;
                    self.mode = Mode::Idle;
                } else {
                    self.mode = Mode::Ease;
                }
            }
            return;
        }
        if g.momentum_phase != ScrollPhase::None {
            self.momentum(delta, g.momentum_phase, now, top);
            return;
        }
        match g.phase {
            ScrollPhase::MayBegin => self.stop(),
            ScrollPhase::Began | ScrollPhase::Changed | ScrollPhase::Stationary => {
                self.host_inertia = g.host_inertia;
                if self.mode != Mode::Tracking {
                    self.begin_tracking();
                }
                self.track(delta, now, top);
            }
            ScrollPhase::Ended | ScrollPhase::Cancelled => {
                if self.mode == Mode::Tracking {
                    self.host_inertia |= g.host_inertia;
                    self.track(delta, now, top);
                    self.release(now, top);
                } else if delta != 0.0 {
                    self.stop();
                    self.pos = (self.pos + delta).clamp(0.0, top);
                }
            }
            ScrollPhase::None => {
                if delta != 0.0 {
                    self.stop();
                    self.pos = (self.pos + delta).clamp(0.0, top);
                }
            }
        }
    }

    /// Convenience for `InputEvent::Scroll`: `dy` in host pixels with AppKit signs (positive = content down), `scale` the
    /// pixels per point, `gesture` what the host published (`UiCx::gesture`) or a wheel from the pixels.
    #[allow(clippy::too_many_arguments)]
    pub fn wheel(
        &mut self,
        gesture: Option<ScrollGesture>,
        dx: f32,
        dy: f32,
        scale: f64,
        max_offset: f64,
        extent: f64,
        now: f64,
    ) {
        self.max_offset = max_offset;
        self.extent = extent.max(1.0);
        let g = gesture.unwrap_or_else(|| ScrollGesture::wheel(dx, dy));
        self.scroll(-(dy as f64) / scale, &g, now);
    }

    /// For panels whose host already converted to points: `dy` with AppKit signs (positive = content down).
    pub fn feed(&mut self, gesture: Option<ScrollGesture>, dy: f64, max_offset: f64, extent: f64, now: f64) {
        self.max_offset = max_offset;
        self.extent = extent.max(1.0);
        let g = gesture.unwrap_or(ScrollGesture { delta_y: if dy < 0.0 { -1.0 } else { 1.0 }, ..Default::default() });
        self.scroll(-dy, &g, now);
    }

    fn stop(&mut self) {
        self.mode = Mode::Idle;
        self.samples.clear();
    }

    fn begin_tracking(&mut self) {
        let top = self.max_offset.max(0.0);
        self.raw = if self.pos < 0.0 {
            -Self::unrubber(-self.pos, self.extent)
        } else if self.pos > top {
            top + Self::unrubber(self.pos - top, self.extent)
        } else {
            self.pos
        };
        self.mode = Mode::Tracking;
        self.samples.clear();
    }

    fn track(&mut self, delta: f64, now: f64, top: f64) {
        if delta != 0.0 {
            self.raw += delta;
            self.samples.push((now, delta));
            self.samples.retain(|s| now - s.0 <= Self::VELOCITY_WINDOW * 2.0);
        }
        if top <= 0.0 {
            self.raw = 0.0;
        }
        self.pos = Self::display(self.raw, top, self.extent);
    }

    fn release(&mut self, now: f64, top: f64) {
        let v = self.finger_velocity(now);
        self.samples.clear();
        if self.pos < 0.0 {
            self.start_spring(0.0, self.pos, 0.0, now);
        } else if self.pos > top {
            self.start_spring(top, self.pos - top, 0.0, now);
        } else if !self.system_momentum && !self.host_inertia && v.abs() >= Self::MIN_FLING_SPEED {
            self.mode = Mode::Glide;
            self.glide = (self.pos, v, now);
        } else {
            self.mode = Mode::Idle;
        }
    }

    /// Points per second over the window before the last message; 0 when the fingers rested before lifting.
    fn finger_velocity(&self, now: f64) -> f64 {
        let Some(&(last, _)) = self.samples.last() else { return 0.0 };
        if now - last > Self::STALE_AFTER {
            return 0.0;
        }
        let recent: Vec<&(f64, f64)> = self.samples.iter().filter(|s| last - s.0 <= Self::VELOCITY_WINDOW).collect();
        if recent.len() < 2 {
            return 0.0;
        }
        let dt = last - recent[0].0;
        if dt <= 0.004 {
            return 0.0;
        }
        recent.iter().skip(1).map(|s| s.1).sum::<f64>() / dt
    }

    /// System momentum (Mac): used as delivered inside the range; at an end it turns into a bounce.
    fn momentum(&mut self, delta: f64, phase: ScrollPhase, now: f64, top: f64) {
        if self.mode == Mode::Spring {
            return;
        }
        if matches!(phase, ScrollPhase::Ended | ScrollPhase::Cancelled) {
            if self.mode == Mode::Momentum {
                self.mode = Mode::Idle;
            }
            self.last_momentum_at = None;
            return;
        }
        if self.mode != Mode::Momentum {
            self.mode = Mode::Momentum;
            self.last_momentum_at = None;
        }
        let next = self.pos + delta;
        let prev_at = self.last_momentum_at;
        self.last_momentum_at = Some(now);
        if next < 0.0 || next > top {
            let edge = if next < 0.0 { 0.0 } else { top };
            let dt = prev_at.map_or(1.0 / 60.0, |t| (now - t).max(1.0 / 240.0));
            self.pos = edge;
            if top > 0.0 {
                self.start_spring(edge, 0.0, delta / dt * Self::EDGE_IMPACT, now);
            } else {
                self.mode = Mode::Idle;
            }
            return;
        }
        self.pos = next;
    }

    fn start_spring(&mut self, edge: f64, x0: f64, v0: f64, now: f64) {
        self.spring = (edge, x0, v0, now);
        self.mode = Mode::Spring;
    }

    /// Runs the glide, ease or spring to `now`. An older `now` than the last one does nothing (no rewind).
    pub fn advance(&mut self, now: f64) {
        if now < self.clock {
            return;
        }
        self.clock = now;
        self.expire_lost_end(now);
        self.step(now);
    }

    /// A gesture or momentum whose end never came: released as of its timeout (as if the end had arrived then, so a panel
    /// that was hidden meanwhile comes back at the edge, not stretched).
    fn expire_lost_end(&mut self, now: f64) {
        match self.mode {
            Mode::Tracking if now - self.last_event > Self::TRACKING_STALE => {
                let top = self.max_offset.max(0.0);
                self.release(self.last_event + Self::TRACKING_STALE, top);
            }
            Mode::Momentum if now - self.last_event > Self::MOMENTUM_STALE => {
                self.mode = Mode::Idle;
                self.last_momentum_at = None;
            }
            _ => {}
        }
    }

    fn step(&mut self, now: f64) {
        match self.mode {
            Mode::Glide => {
                let (p0, v0, t0) = self.glide;
                let k = -Self::DECELERATION_PER_MS.ln() * 1000.0;
                let decay = (-k * (now - t0).max(0.0)).exp();
                let p = p0 + v0 * (1.0 - decay) / k;
                let v = v0 * decay;
                let top = self.max_offset.max(0.0);
                if p < 0.0 || p > top {
                    let edge = if p < 0.0 { 0.0 } else { top };
                    self.pos = edge;
                    if top > 0.0 {
                        self.start_spring(edge, 0.0, v * Self::EDGE_IMPACT, now);
                    } else {
                        self.mode = Mode::Idle;
                    }
                } else if v.abs() < 2.0 {
                    self.pos = p;
                    self.mode = Mode::Idle;
                } else {
                    self.pos = p;
                }
            }
            Mode::Ease => {
                let (p0, target, t0) = self.ease;
                let p = target + (p0 - target) * (-(now - t0).max(0.0) / Self::EASE_TIME).exp();
                if (target - p).abs() < 0.25 {
                    self.pos = target;
                    self.mode = Mode::Idle;
                } else {
                    self.pos = p;
                }
            }
            Mode::Spring => {
                let (edge, x0, v0, t0) = self.spring;
                let w = Self::SPRING_OMEGA;
                let t = (now - t0).max(0.0);
                let e = (-w * t).exp();
                let x = (x0 + (v0 + w * x0) * t) * e;
                let c = v0 + w * x0;
                let speed = (c - w * (x0 + c * t)) * e;
                if x.abs() < 0.2 && (speed.abs() < 2.0 || t > 3.0) {
                    self.pos = edge;
                    self.mode = Mode::Idle;
                } else {
                    self.pos = edge + x;
                }
            }
            _ => {}
        }
    }

    /// The resisted distance for a pull of `x` past an end on a viewport of `d`.
    pub fn rubber(x: f64, d: f64) -> f64 {
        if x <= 0.0 || d <= 0.0 {
            return 0.0;
        }
        (1.0 - 1.0 / (x * Self::RUBBER_COEFFICIENT / d + 1.0)) * d
    }

    /// The pull that shows `y` of overscroll (inverse of [`rubber`](Self::rubber)).
    pub fn unrubber(y: f64, d: f64) -> f64 {
        if y <= 0.0 || d <= 0.0 {
            return 0.0;
        }
        let q = (y / d).min(0.999);
        d / Self::RUBBER_COEFFICIENT * (1.0 / (1.0 - q) - 1.0)
    }

    fn display(raw: f64, top: f64, d: f64) -> f64 {
        if top <= 0.0 {
            0.0
        } else if raw < 0.0 {
            -Self::rubber(-raw, d)
        } else if raw > top {
            top + Self::rubber(raw - top, d)
        } else {
            raw
        }
    }

    // Overlay scroller

    /// 0...1 opacity of the knob at `now`.
    pub fn scroller_alpha(&self, now: f64) -> f32 {
        if self.scroller_dragging {
            return 1.0;
        }
        let t = now - self.last_active - ScrollerBar::VISIBLE_FOR;
        if t <= 0.0 { 1.0 } else { (1.0 - t / ScrollerBar::FADE).max(0.0) as f32 }
    }

    /// Draws the knob over the list's `viewport` (points) after its content.
    pub fn draw_scroller(&mut self, c: &mut Canvas, viewport: CGRect, content: f64, t: &DrawTheme, now: f64) {
        let o = self.offset(now);
        if self.needs_frames(now) {
            motion::request_frame();
        }
        let a = self.scroller_alpha(now);
        if a <= 0.01 {
            return;
        }
        let Some(k) = ScrollerBar::knob(viewport, content, o, self.scroller_dragging || self.scroller_hover) else {
            return;
        };
        let color = if self.scroller_dragging { t.label2() } else { t.label3() };
        c.fill_rounded(k, k.width / 2.0, color.with_alpha(a * 0.9));
    }

    /// Mouse events on the scroller: true when it took the event (a drag of the knob, a click on the track).
    pub fn scroller_event(&mut self, e: &InputEvent, scale: f32, viewport: CGRect, content: f64, now: f64) -> bool {
        let s = scale.max(0.01) as f64;
        let pt = |x: f32, y: f32| CGPoint { x: x as f64 / s, y: y as f64 / s };
        let track = CGRect::new(
            viewport.max_x() - ScrollerBar::TRACK_WIDTH,
            viewport.y,
            ScrollerBar::TRACK_WIDTH,
            viewport.height,
        );
        if content <= viewport.height + 0.5 {
            self.scroller_dragging = false;
            return false;
        }
        match *e {
            InputEvent::MouseMoved { x, y } => {
                self.scroller_hover = track.contains(pt(x, y));
                if self.scroller_hover {
                    self.touch(now);
                }
                false
            }
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                if self.mode == Mode::Glide {
                    // A press catches a running fling at once, where it is on screen (the click then lands on that row).
                    self.advance(now);
                    self.stop();
                }
                if !track.contains(p) || !(self.scroller_alpha(now) > 0.05 || self.scroller_hover) {
                    return false;
                }
                let off = self.offset(now);
                let k = ScrollerBar::knob(viewport, content, off, true);
                self.scroller_dragging = true;
                self.scroller_grab = k.map_or(0.0, |k| if k.contains(p) { p.y - k.y } else { k.height / 2.0 });
                self.stop();
                self.drag_to(p.y, viewport, content, now);
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                if !self.scroller_dragging {
                    return false;
                }
                self.drag_to(pt(x, y).y, viewport, content, now);
                true
            }
            InputEvent::MouseUp { .. } => {
                if !self.scroller_dragging {
                    return false;
                }
                self.scroller_dragging = false;
                self.touch(now);
                true
            }
            _ => false,
        }
    }

    fn drag_to(&mut self, y: f64, viewport: CGRect, content: f64, now: f64) {
        let track = viewport.inset_by(0.0, 2.0);
        let h = (track.height * viewport.height / content).max(ScrollerBar::MIN_KNOB).min(track.height);
        let room = (track.height - h).max(1.0);
        let f = ((y - self.scroller_grab - track.y) / room).clamp(0.0, 1.0);
        self.mode = Mode::Idle;
        self.pos = f * (content - viewport.height);
        self.touch(now);
    }
}

/// The overlay scroller of the shared lists: a thin knob at the right edge that fades in while the list scrolls or the pointer
/// is over its edge, fades out after a moment, and can be dragged. State lives in the list's [`ScrollBody`].
pub struct ScrollerBar;

impl ScrollerBar {
    /// Seconds the knob stays fully visible after the last scroll or pointer move.
    pub const VISIBLE_FOR: f64 = 0.8;
    /// Fade-out seconds.
    pub const FADE: f64 = 0.3;
    /// Width of the hit track.
    pub const TRACK_WIDTH: f64 = 12.0;
    /// Shortest knob.
    pub const MIN_KNOB: f64 = 28.0;

    /// The knob rectangle (points) for a scroll position, `None` when the content fits.
    pub fn knob(v: CGRect, content: f64, offset: f64, wide: bool) -> Option<CGRect> {
        if content <= v.height + 0.5 || v.height <= 0.0 {
            return None;
        }
        let track = v.inset_by(0.0, 2.0);
        let h = (track.height * v.height / content).max(Self::MIN_KNOB).min(track.height);
        let f = (offset / (content - v.height)).clamp(0.0, 1.0);
        let w = if wide { 10.0 } else { 6.0 };
        Some(CGRect::new(v.max_x() - 2.0 - w, track.y + (track.height - h) * f, w, h))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pad(phase: ScrollPhase) -> ScrollGesture {
        ScrollGesture { precise: true, phase, ..Default::default() }
    }
    fn pad_momentum(m: ScrollPhase) -> ScrollGesture {
        ScrollGesture { precise: true, momentum_phase: m, ..Default::default() }
    }
    fn wheel(dy: f64) -> ScrollGesture {
        ScrollGesture { delta_y: dy, ..Default::default() }
    }
    #[test]
    fn a_read_of_a_moved_offset_counts_as_content_moving_and_a_resting_one_does_not() {
        let mut b = body(400.0, false);
        let start = content_epoch();
        b.offset(0.0);
        assert_eq!(content_epoch(), start, "a body that never moved reports nothing");
        b.assign(60.0);
        b.offset(0.1);
        assert_eq!(content_epoch(), start + 1, "a panel set the offset: the next read reports the move");
        b.offset(0.2);
        b.offset(0.3);
        assert_eq!(content_epoch(), start + 1, "reads of the same offset report nothing");
        b.scroll(20.0, &wheel(1.0), 1.0);
        b.advance(2.0);
        b.offset(2.0);
        assert_eq!(content_epoch(), start + 2, "a wheel ease that landed is one more move");
    }
    fn body(max: f64, system: bool) -> ScrollBody {
        ScrollBody { max_offset: max, extent: 400.0, system_momentum: system, ..ScrollBody::new(0.0) }
    }
    /// Runs the frames of `seconds` at 60 Hz from `t0`.
    fn run(b: &mut ScrollBody, t0: f64, seconds: f64) -> f64 {
        let mut t = t0;
        while t < t0 + seconds {
            t += 1.0 / 60.0;
            b.advance(t);
        }
        t
    }
    fn now(b: &mut ScrollBody, t: f64) -> f64 {
        b.advance(t);
        b.position()
    }

    /// What a panel does each frame: the loop's clock moves, the panel reads the body.
    fn frame(b: &mut ScrollBody, t: f64) -> f64 {
        motion::begin_frame(t);
        b.position()
    }
    /// Frames at 60 Hz from `t0` until `t0 + seconds`; the first time the position was in range and no frame was asked
    /// for any more, or `None`.
    fn settled_after(b: &mut ScrollBody, t0: f64, seconds: f64) -> Option<f64> {
        let mut t = t0;
        while t < t0 + seconds {
            t += 1.0 / 60.0;
            let p = frame(b, t);
            if (0.0..=b.max_offset).contains(&p) && !motion::needs_frame() {
                return Some(t - t0);
            }
        }
        None
    }
    fn pull(b: &mut ScrollBody, delta: f64, at: f64) {
        b.scroll(0.0, &pad(ScrollPhase::Began), at);
        b.scroll(delta, &pad(ScrollPhase::Changed), at + 0.01);
    }

    #[test]
    fn overscroll_at_the_top_springs_back_with_only_frames_and_no_more_input() {
        let mut b = body(1000.0, false);
        pull(&mut b, -300.0, 10.0);
        assert!(frame(&mut b, 10.02) < 0.0, "the rubber band shows while the fingers pull");
        b.scroll(0.0, &pad(ScrollPhase::Ended), 10.5);
        let after = settled_after(&mut b, 10.5, 2.0).expect("the offset returns into bounds");
        assert!(after < 1.0, "springs back within a second, took {after}");
        assert_eq!(frame(&mut b, 20.0), 0.0);
    }

    #[test]
    fn overscroll_at_the_bottom_springs_back_with_only_frames_and_no_more_input() {
        let mut b = body(1000.0, false);
        pull(&mut b, 1300.0, 10.0);
        assert!(frame(&mut b, 10.02) > 1000.0);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 10.5);
        let after = settled_after(&mut b, 10.5, 2.0).expect("the offset returns into bounds");
        assert!(after < 1.0, "took {after}");
        assert_eq!(frame(&mut b, 20.0), 1000.0);
    }

    #[test]
    fn a_fling_into_the_top_with_system_momentum_ends_in_bounds_at_both_ends() {
        for (start, delta, edge) in [(50.0, -40.0, 0.0), (950.0, 40.0, 1000.0)] {
            let mut b = body(1000.0, true);
            b.assign(start);
            b.scroll(0.0, &pad(ScrollPhase::Began), 1.0);
            b.scroll(delta, &pad(ScrollPhase::Changed), 1.01);
            b.scroll(0.0, &pad(ScrollPhase::Ended), 1.02);
            for i in 0..8 {
                let phase = if i == 0 { ScrollPhase::Began } else { ScrollPhase::Changed };
                b.scroll(delta, &pad_momentum(phase), 1.03 + f64::from(i) * 0.016);
            }
            b.scroll(0.0, &pad_momentum(ScrollPhase::Ended), 1.5);
            settled_after(&mut b, 1.5, 2.0).expect("the offset returns into bounds");
            assert_eq!(frame(&mut b, 10.0), edge);
        }
    }

    #[test]
    fn a_gesture_whose_end_never_comes_is_released_and_a_hidden_panel_comes_back_in_bounds() {
        let mut b = body(1000.0, false);
        pull(&mut b, -300.0, 10.0);
        // The panel stays drawn: the held stretch asks for frames, then the timeout lets it go and it springs back.
        assert!(frame(&mut b, 10.5) < 0.0 && motion::needs_frame());
        settled_after(&mut b, 10.5, 3.0).expect("the stretch does not stay");
        // The panel was hidden (no frame at all) from the gesture on: the first frame after it shows the edge.
        let mut hidden = body(1000.0, false);
        pull(&mut hidden, -300.0, 10.0);
        assert_eq!(frame(&mut hidden, 60.0), 0.0, "an out-of-range offset is not restored");
        let mut hidden_bottom = body(1000.0, false);
        pull(&mut hidden_bottom, 1300.0, 10.0);
        assert_eq!(frame(&mut hidden_bottom, 60.0), 1000.0);
    }

    #[test]
    fn a_bounce_that_runs_while_the_panel_is_hidden_is_over_when_it_comes_back() {
        let mut b = body(1000.0, false);
        pull(&mut b, -300.0, 10.0);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 10.2);
        assert_eq!(frame(&mut b, 30.0), 0.0);
        assert!(!motion::needs_frame());
    }

    #[test]
    fn a_wheel_notch_reaches_its_target_by_frames_alone_and_never_leaves_the_range() {
        let mut b = body(1000.0, false);
        b.scroll(120.0, &wheel(3.0), 5.0);
        assert!(frame(&mut b, 5.0) < 120.0 && motion::needs_frame());
        settled_after(&mut b, 5.0, 1.0).expect("the ease ends");
        assert_eq!(frame(&mut b, 6.5), 120.0);
        b.scroll(-500.0, &wheel(-5.0), 7.0);
        settled_after(&mut b, 7.0, 1.0).expect("the ease ends");
        assert_eq!(frame(&mut b, 8.5), 0.0, "a wheel clamps at the top");
        b.scroll(5000.0, &wheel(40.0), 9.0);
        settled_after(&mut b, 9.0, 1.0).expect("the ease ends");
        assert_eq!(frame(&mut b, 10.5), 1000.0, "a wheel clamps at the bottom");
    }

    /// Bug w47 (FINAL-WIN-4 row 3): a burst of 8 messages of delta 30 must move exactly 80 px, whatever the spacing.
    fn windows_burst(count: i32, delta: i32, gap: f64, max: f64) -> f64 {
        let mut win = WinScroll::default();
        let mut b = body(max, false);
        let mut t = 2.0;
        for _ in 0..count {
            let g = win.wheel(delta, false, false, t);
            let (_, dy) = WinScroll::pixels(&g, 1.0);
            b.wheel(Some(g), 0.0, -dy, 1.0, max, 400.0, t);
            t += gap;
        }
        t += 0.3;
        if let Some(end) = win.idle(t) {
            b.scroll(0.0, &end, t);
        }
        settled_after(&mut b, t, 3.0).expect("the offset settles");
        frame(&mut b, t + 3.0)
    }

    #[test]
    fn a_windows_wheel_burst_scrolls_exactly_the_delivered_distance() {
        for gap in [0.008, 0.025, 0.05, 0.1] {
            assert_eq!(windows_burst(8, 30, gap, 1000.0), 80.0, "gap {gap}");
        }
        assert_eq!(windows_burst(3, 120, 0.01, 1000.0), 120.0);
        assert_eq!(windows_burst(8, -30, 0.01, 1000.0), 0.0, "the top holds");
        assert_eq!(windows_burst(40, 30, 0.01, 100.0), 100.0, "the bottom holds");
    }

    #[test]
    fn a_windows_touchpad_overscroll_ends_with_the_made_up_end_and_springs_back() {
        let mut win = WinScroll::default();
        let mut b = body(1000.0, false);
        let mut t = 3.0;
        for _ in 0..10 {
            // A touchpad message: not a whole WHEEL_DELTA.
            let g = win.wheel(37, false, false, t);
            b.scroll(-g.delta_y * 4.0, &g, t);
            t += 0.016;
        }
        assert!(frame(&mut b, t) < 0.0, "the rubber band shows at the top");
        let end = win.idle(t + 0.2).expect("the gesture goes quiet");
        b.scroll(0.0, &end, t + 0.2);
        settled_after(&mut b, t + 0.2, 2.0).expect("the offset returns into bounds");
    }

    #[test]
    fn an_offset_out_of_range_is_never_stored_when_idle() {
        let mut b = body(1000.0, false);
        b.assign(5000.0);
        assert_eq!(frame(&mut b, 1.0), 1000.0);
        b.assign(-80.0);
        assert_eq!(frame(&mut b, 2.0), 0.0);
    }

    #[test]
    fn an_older_clock_never_rewinds_a_bounce() {
        let mut b = body(1000.0, false);
        pull(&mut b, -300.0, 10.0);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 10.2);
        let later = frame(&mut b, 10.4);
        assert_eq!(frame(&mut b, 10.3), later);
    }

    #[test]
    fn rubber_band_resists_and_stays_below_the_viewport() {
        assert_eq!(ScrollBody::rubber(0.0, 400.0), 0.0);
        let (a, b) = (ScrollBody::rubber(100.0, 400.0), ScrollBody::rubber(1000.0, 400.0));
        assert!(a > 0.0 && a < 100.0);
        assert!(b > a && b < 400.0);
        assert!((ScrollBody::unrubber(a, 400.0) - 100.0).abs() < 1e-6);
    }

    #[test]
    fn fingers_inside_the_range_move_one_to_one() {
        let mut b = body(1000.0, false);
        b.scroll(10.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(15.0, &pad(ScrollPhase::Changed), 0.01);
        assert_eq!(now(&mut b, 0.01), 25.0);
    }

    #[test]
    fn pulling_past_the_top_resists_then_release_springs_back() {
        let mut b = body(1000.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(-200.0, &pad(ScrollPhase::Changed), 0.01);
        let pulled = now(&mut b, 0.01);
        assert!(pulled < 0.0 && pulled > -200.0);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.5);
        assert!(b.is_animating());
        let t = run(&mut b, 0.5, 1.5);
        assert_eq!(now(&mut b, t), 0.0);
        assert!(!b.is_animating());
    }

    #[test]
    fn spring_never_overshoots_the_edge_from_rest() {
        let mut b = body(1000.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(300.0, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.5);
        let (mut t, mut last) = (0.5, now(&mut b, 0.5));
        while t < 3.0 {
            t += 1.0 / 60.0;
            let o = now(&mut b, t);
            assert!(o <= last + 1e-9 && o.is_finite() && o >= 0.0);
            last = o;
        }
    }

    #[test]
    fn a_fling_without_system_momentum_glides_and_settles() {
        let mut b = body(100_000.0, false);
        let mut t = 0.0;
        b.scroll(0.0, &pad(ScrollPhase::Began), t);
        for _ in 0..6 {
            t += 1.0 / 60.0;
            b.scroll(20.0, &pad(ScrollPhase::Changed), t);
        }
        let lift = now(&mut b, t);
        b.scroll(0.0, &pad(ScrollPhase::Ended), t + 0.01);
        assert!(b.is_animating());
        let end = run(&mut b, t + 0.01, 6.0);
        let fin = now(&mut b, end);
        assert!(fin > lift + 300.0 && fin < lift + 900.0, "travelled roughly v/2 = 600 pt, got {}", fin - lift);
        assert!(!b.is_animating());
    }

    #[test]
    fn a_press_during_a_fling_stops_it_where_it_is() {
        let mut b = body(100_000.0, false);
        let mut t = 0.0;
        b.scroll(0.0, &pad(ScrollPhase::Began), t);
        for _ in 0..6 {
            t += 1.0 / 60.0;
            b.scroll(20.0, &pad(ScrollPhase::Changed), t);
        }
        b.scroll(0.0, &pad(ScrollPhase::Ended), t + 0.01);
        let t = run(&mut b, t + 0.01, 0.2);
        assert!(b.is_animating());
        let view = CGRect { x: 0.0, y: 0.0, width: 300.0, height: 400.0 };
        let press = InputEvent::MouseDown { x: 50.0, y: 50.0, modifiers: crate::input::InputModifiers::NONE };
        b.scroller_event(&press, 1.0, view, 100_400.0, t);
        let at = b.position();
        assert!(!b.is_animating(), "the fling stops on the press");
        assert_eq!(now(&mut b, t + 1.0), at, "and stays where it was");
    }

    #[test]
    fn a_stalled_finger_lifts_without_a_fling() {
        let mut b = body(1000.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(30.0, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(30.0, &pad(ScrollPhase::Changed), 0.02);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.6);
        assert!(!b.is_animating());
    }

    #[test]
    fn a_fling_into_the_end_bounces_and_comes_back() {
        let mut b = body(500.0, false);
        let mut t = 0.0;
        b.scroll(0.0, &pad(ScrollPhase::Began), t);
        for _ in 0..8 {
            t += 1.0 / 60.0;
            b.scroll(40.0, &pad(ScrollPhase::Changed), t);
        }
        b.scroll(0.0, &pad(ScrollPhase::Ended), t + 0.01);
        let (mut peak, mut n) = (0.0f64, 0);
        t += 0.01;
        while n < 600 {
            n += 1;
            t += 1.0 / 60.0;
            peak = peak.max(now(&mut b, t));
            if !b.is_animating() {
                break;
            }
        }
        assert!(peak > 500.0, "stretched past the end");
        assert_eq!(now(&mut b, t), 500.0, "and rested on it");
    }

    #[test]
    fn system_momentum_is_used_as_delivered_then_bounces_at_the_end() {
        let mut b = body(100.0, true);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(50.0, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.02);
        assert!(!b.is_animating(), "the system sends the tail");
        b.scroll(30.0, &pad_momentum(ScrollPhase::Began), 0.03);
        assert_eq!(now(&mut b, 0.03), 80.0);
        b.scroll(30.0, &pad_momentum(ScrollPhase::Changed), 0.05);
        assert!(b.is_animating());
        b.scroll(20.0, &pad_momentum(ScrollPhase::Changed), 0.07);
        let t = run(&mut b, 0.07, 2.0);
        assert_eq!(now(&mut b, t), 100.0);
    }

    #[test]
    fn a_mouse_wheel_eases_to_its_target_clamped_and_never_bounces() {
        let mut b = body(100.0, false);
        b.scroll(-50.0, &wheel(5.0), 0.0);
        assert_eq!(now(&mut b, 0.0), 0.0);
        b.scroll(40.0, &wheel(-1.0), 0.1);
        let mid = now(&mut b, 0.1 + ScrollBody::EASE_TIME);
        assert!(mid > 20.0 && mid < 30.0, "63 % of the notch after one time constant, got {mid}");
        b.scroll(500.0, &wheel(-5.0), 0.2);
        assert_eq!(now(&mut b, 2.0), 100.0);
        assert!(!b.is_animating());
    }

    #[test]
    fn a_content_that_fits_does_not_bounce() {
        let mut b = body(0.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(-100.0, &pad(ScrollPhase::Changed), 0.01);
        assert_eq!(now(&mut b, 0.01), 0.0);
    }

    #[test]
    fn a_new_gesture_takes_over_a_running_spring() {
        let mut b = body(1000.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(-300.0, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.5);
        b.advance(0.6);
        let mid = now(&mut b, 0.6);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.6);
        assert!(!b.is_animating());
        b.scroll(0.0, &pad(ScrollPhase::Changed), 0.61);
        assert!((now(&mut b, 0.61) - mid).abs() < 0.01, "picks up where the band is");
    }

    #[test]
    fn layout_clamp_does_not_kill_a_bounce() {
        let mut b = body(1000.0, false);
        b.scroll(0.0, &pad(ScrollPhase::Began), 0.0);
        b.scroll(-300.0, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.5);
        b.assign(0.0);
        assert!(b.is_animating());
    }

    #[test]
    fn no_nan_on_odd_input() {
        let mut b = body(1000.0, false);
        b.scroll(f64::NAN, &pad(ScrollPhase::Changed), 0.0);
        b.scroll(f64::INFINITY, &pad(ScrollPhase::Changed), 0.01);
        b.scroll(0.0, &pad(ScrollPhase::Ended), 0.02);
        b.advance(5.0);
        assert!(now(&mut b, 5.0).is_finite());
    }

    const VIEW: CGRect = CGRect { x: 0.0, y: 0.0, width: 300.0, height: 400.0 };

    #[test]
    fn knob_is_proportional_and_follows_the_offset() {
        assert!(ScrollerBar::knob(VIEW, 400.0, 0.0, false).is_none(), "fits: none");
        let top = ScrollerBar::knob(VIEW, 800.0, 0.0, false).unwrap_or_default();
        let end = ScrollerBar::knob(VIEW, 800.0, 400.0, false).unwrap_or_default();
        assert!((top.height - 198.0).abs() < 1.0);
        assert!(top.y == 2.0 && (end.max_y() - 398.0).abs() < 1e-9);
        assert!(top.max_x() < VIEW.max_x());
    }

    #[test]
    fn knob_fades_after_the_scroll_stops() {
        let mut b = ScrollBody::new(0.0);
        b.scroll(5.0, &wheel(-1.0), 10.0);
        assert_eq!(b.scroller_alpha(10.5), 1.0);
        assert_eq!(b.scroller_alpha(10.0 + ScrollerBar::VISIBLE_FOR + ScrollerBar::FADE + 0.01), 0.0);
        assert!(b.needs_frames(10.5));
        b.advance(20.0);
        assert!(!b.needs_frames(20.0));
    }

    #[test]
    fn dragging_the_knob_sets_the_offset() {
        let mut b = ScrollBody { max_offset: 400.0, ..ScrollBody::new(0.0) };
        let now = 5.0;
        b.touch(now);
        let k = ScrollerBar::knob(VIEW, 800.0, 0.0, true).unwrap_or_default();
        let (x, y) = ((VIEW.max_x() - 5.0) as f32, k.mid_y() as f32);
        assert!(b.scroller_event(
            &InputEvent::MouseDown { x, y, modifiers: Default::default() },
            1.0,
            VIEW,
            800.0,
            now
        ));
        assert!(b.scroller_event(&InputEvent::dragged(x, (k.mid_y() + 100.0) as f32), 1.0, VIEW, 800.0, now));
        assert!(b.position() > 150.0 && b.position() < 250.0, "100 of 202 free track points");
        assert!(b.scroller_event(&InputEvent::MouseUp { x, y }, 1.0, VIEW, 800.0, now));
        assert!(!b.scroller_event(
            &InputEvent::MouseDown { x: 10.0, y: 10.0, modifiers: Default::default() },
            1.0,
            VIEW,
            800.0,
            now
        ));
    }

    #[test]
    fn without_a_host_gesture_the_wheel_comes_from_the_pixels() {
        assert_eq!(ScrollGesture::wheel(0.0, 40.0), ScrollGesture { delta_y: 1.0, ..Default::default() });
    }

    /// Replays the real winit event list of a trackpad flick (Pointer phases and momentum) into a body at its top.
    fn flick_at_top(b: &mut ScrollBody, scale: f32, until: f64) -> (f64, f64) {
        use crate::input::InputModifiers;
        use crate::pointer::{Pointer, flick_events};
        use winit::dpi::PhysicalPosition;
        use winit::event::MouseScrollDelta;
        let mut p = Pointer::default();
        let (mut worst, mut t) = (0.0f64, 0.0);
        for e in flick_events(900.0, 8) {
            if e.at > until {
                break;
            }
            let d = MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, e.pixels));
            let (ev, g) = p.wheel(d, e.phase, InputModifiers::NONE, scale, e.at);
            let crate::input::InputEvent::Scroll { dx, dy, .. } = ev else { unreachable!() };
            b.wheel(Some(g), dx, dy, f64::from(scale), 400.0, 400.0, e.at);
            t = e.at;
            worst = worst.min(b.offset(e.at));
        }
        (worst, t)
    }

    #[test]
    fn a_real_flick_at_the_top_shows_a_gap_then_springs_back_to_zero() {
        let mut b = body(400.0, true);
        let (worst, t) = flick_at_top(&mut b, 2.0, f64::MAX);
        assert!(worst < -1.0, "the content is pulled past the top during the gesture: {worst}");
        let end = run(&mut b, t, 3.0);
        assert_eq!(b.offset(end), 0.0, "back at the top after the settle");
        assert!(!b.is_animating());
        // Reopen: a fresh body starts in bounds, and a second flick behaves the same.
        let mut again = body(400.0, true);
        assert_eq!(again.offset(0.0), 0.0);
        let t2 = flick_at_top(&mut again, 2.0, f64::MAX).1;
        let end2 = run(&mut again, t2, 3.0);
        assert_eq!(again.offset(end2), 0.0);
    }

    #[test]
    fn a_real_flick_cut_in_the_middle_of_the_momentum_never_rests_out_of_range() {
        for cut in [0.03, 0.06, 0.1, 0.2, 0.4] {
            let mut b = body(400.0, true);
            let (_, t) = flick_at_top(&mut b, 2.0, cut);
            let end = run(&mut b, t, 3.0);
            assert_eq!(b.offset(end), 0.0, "cut at {cut}");
        }
    }

    /// Replays phase-less winit wheel events (`(time, lines)`, positive = pull down at the top) through the Windows route
    /// (`Pointer::win_wheel`, then `win_idle` on every 60 Hz frame as the app loop does) into a body at its top.
    /// Returns the most negative offset seen and the time of the last frame.
    fn win_route(b: &mut ScrollBody, scale: f32, events: &[(f64, f32)], seconds: f64) -> (f64, f64) {
        use crate::input::{InputEvent, InputModifiers};
        use crate::pointer::Pointer;
        use winit::event::MouseScrollDelta;
        let mut p = Pointer::default();
        let (mut worst, mut t, mut i) = (0.0f64, 0.0, 0);
        while t < seconds {
            while i < events.len() && events[i].0 <= t {
                let (at, lines) = events[i];
                let (ev, g) = p.win_wheel(MouseScrollDelta::LineDelta(0.0, lines), InputModifiers::NONE, scale, at);
                let InputEvent::Scroll { dx, dy, .. } = ev else { unreachable!() };
                b.wheel(Some(g), dx, dy, f64::from(scale), 400.0, 400.0, at);
                worst = worst.min(b.offset(at));
                i += 1;
            }
            if let Some((ev, g)) = p.win_idle(InputModifiers::NONE, scale, t) {
                let InputEvent::Scroll { dx, dy, .. } = ev else { unreachable!() };
                b.wheel(Some(g), dx, dy, f64::from(scale), 400.0, 400.0, t);
            }
            worst = worst.min(frame(b, t));
            t += 1.0 / 60.0;
        }
        (worst, t)
    }

    #[test]
    fn a_phaseless_windows_touchpad_flick_at_the_top_springs_back_to_zero() {
        // 8 touchpad messages of 0.31 notch 8 ms apart, then inertia messages decaying every 16 ms (no Ended, no flag).
        for scale in [1.0, 1.5, 2.0] {
            let mut ev: Vec<(f64, f32)> = (0..8).map(|k| (f64::from(k) * 0.008, 0.31)).collect();
            let (mut t, mut v) = (0.08, 0.6f32);
            for _ in 0..40 {
                t += 0.016;
                v *= 0.9;
                ev.push((t, v));
            }
            let mut b = body(400.0, false);
            let (worst, _) = win_route(&mut b, scale, &ev, 0.5);
            assert!(worst < -1.0, "the gap shows during the flick at {scale}: {worst}");
            let (_, end) = win_route(&mut b, scale, &[], 3.0);
            assert_eq!(b.offset(end), 0.0, "back at the top at {scale}");
            assert!(!b.is_animating());
        }
    }

    #[test]
    fn a_phaseless_burst_cut_at_any_moment_never_rests_out_of_range() {
        // A burst, then silence at every point (also a stall longer than IDLE_END in the middle: two gestures).
        for cut in [1, 2, 4, 8, 12, 20, 30] {
            let ev: Vec<(f64, f32)> = (0..cut).map(|k| (f64::from(k) * 0.016, 0.4)).collect();
            let mut b = body(400.0, false);
            win_route(&mut b, 2.0, &ev, 0.016 * f64::from(cut) + 0.05);
            let (_, end) = win_route(&mut b, 2.0, &[], 3.0);
            assert_eq!(b.offset(end), 0.0, "cut after {cut} messages");
        }
        let stalled: Vec<(f64, f32)> = (0..6)
            .map(|k| (f64::from(k) * 0.016, 0.4))
            .chain((0..6).map(|k| (0.5 + f64::from(k) * 0.016, 0.4)))
            .collect();
        let mut b = body(400.0, false);
        let (worst, _) = win_route(&mut b, 2.0, &stalled, 3.0);
        assert!(worst < -1.0);
        assert_eq!(b.offset(3.0), 0.0);
    }

    #[test]
    fn a_phaseless_mouse_wheel_notch_burst_at_the_top_never_leaves_the_range() {
        let ev: Vec<(f64, f32)> = (0..10).map(|k| (f64::from(k) * 0.03, 1.0)).collect();
        let mut b = body(400.0, false);
        let (worst, end) = win_route(&mut b, 1.5, &ev, 1.0);
        assert_eq!(worst, 0.0, "a notch never rubber-bands");
        assert_eq!(b.offset(end), 0.0);
    }

    #[test]
    fn a_gesture_keeps_its_first_place_through_the_end_and_the_tail() {
        let mut t = ScrollTarget::default();
        let (a, b) = ((10.0, 10.0), (500.0, 10.0));
        assert_eq!(t.route(&pad(ScrollPhase::Began), a, 1.0), a);
        assert_eq!(t.route(&pad(ScrollPhase::Changed), b, 1.01), a, "the pointer moved to another list");
        assert_eq!(t.route(&pad(ScrollPhase::Ended), b, 1.02), a, "the end goes to the list that began");
        assert_eq!(t.route(&pad_momentum(ScrollPhase::Began), b, 1.05), a);
        assert_eq!(t.route(&pad_momentum(ScrollPhase::Ended), b, 1.5), a);
        assert_eq!(t.route(&pad(ScrollPhase::Began), b, 1.6), b, "a new touch goes where the pointer is");
        assert_eq!(t.route(&pad(ScrollPhase::Ended), a, 1.7), b);
        assert_eq!(t.route(&pad(ScrollPhase::Changed), a, 9.0), a, "a stale place is dropped");
        assert_eq!(t.route(&wheel(1.0), b, 9.1), b, "a notch goes under the pointer");
    }

    #[test]
    fn a_list_flicked_then_left_by_the_pointer_springs_back_and_the_other_is_untouched() {
        // Mac route (phases + momentum) and Windows route (made-up end), A at the top, the pointer moves onto B mid-gesture.
        let (pa, pb) = ((10.0, 10.0), (500.0, 10.0));
        let mut route = ScrollTarget::default();
        let mut deliver =
            |g: ScrollGesture, at: (f32, f32), dy: f64, t: f64, a: &mut ScrollBody, b: &mut ScrollBody| {
                let to = route.route(&g, at, t);
                let target = if to == pa { a } else { b };
                target.scroll(-dy, &g, t);
            };
        let mut win = WinScroll::default();
        let mut t = 0.0;
        for route_is_win in [false, true] {
            let (mut a, mut b) = (body(400.0, !route_is_win), body(400.0, !route_is_win));
            t += 10.0;
            for k in 0..10 {
                let at = if k < 3 { pa } else { pb };
                let g = if route_is_win {
                    win.wheel(37, false, false, t)
                } else {
                    pad(if k == 0 { ScrollPhase::Began } else { ScrollPhase::Changed })
                };
                deliver(g, at, 20.0, t, &mut a, &mut b);
                t += 0.016;
            }
            assert!(a.offset(t) < 0.0, "A is stretched");
            let end = if route_is_win { win.idle(t + 0.2).unwrap() } else { pad(ScrollPhase::Ended) };
            t += 0.2;
            deliver(end, pb, 0.0, t, &mut a, &mut b);
            let end_t = run(&mut a, t, 3.0);
            assert_eq!(a.offset(end_t), 0.0, "A springs back (windows: {route_is_win})");
            assert_eq!(b.offset(end_t), 0.0, "B was never touched (windows: {route_is_win})");
        }
    }

    // Swift ScrollGestureTests.ScrollCarryTests
    #[test]
    fn carry_slow_deltas_add_up_to_whole_pixels() {
        let mut c = ScrollCarry::default();
        let total: f64 = (0..10).map(|_| c.whole(0.3, 1.0)).sum();
        assert!((total - 3.0).abs() < 0.0001 && c.remainder.abs() < 0.5);
    }

    #[test]
    fn carry_retina_carries_half_pixels_and_negative_deltas() {
        let mut c = ScrollCarry::default();
        assert_eq!(c.whole(0.2, 2.0), 0.0);
        assert_eq!(c.whole(0.2, 2.0), 0.5, "0.4 pt rounds to one device pixel = 0.5 pt");
        assert!((c.remainder + 0.1).abs() < 0.0001);
        let mut n = ScrollCarry::default();
        assert_eq!(n.whole(-0.6, 1.0), -1.0);
        assert!((n.remainder - 0.4).abs() < 0.0001);
    }

    // Swift WinScrollTests
    #[test]
    fn mouse_notches_are_lines_with_the_old_pixels() {
        let mut s = WinScroll::default();
        let up = s.wheel(120, false, false, 0.0);
        assert_eq!(up, ScrollGesture { delta_y: 1.0, ..Default::default() });
        assert_eq!(WinScroll::pixels(&up, 1.5), (0.0, 40.0));
        assert_eq!(up, ScrollGesture::wheel(0.0, 40.0));
        let right = s.wheel(240, true, false, 0.01);
        assert!(right.delta_x == -2.0 && right.delta_y == 0.0 && !right.precise);
        assert!(!s.is_active() && s.idle(5.0).is_none());
        assert!(s.wheel(-120, false, true, 1.0).is_scroll());
    }

    #[test]
    fn touchpad_scroll_is_precise_with_made_up_phases() {
        let mut s = WinScroll::default();
        let a = s.wheel(30, false, false, 0.0);
        assert!(a.precise && a.phase == ScrollPhase::Began && a.delta_y == 10.0);
        assert_eq!(WinScroll::pixels(&a, 2.0), (0.0, 20.0));
        let b = s.wheel(120, false, false, 0.05);
        assert!(b.precise && b.phase == ScrollPhase::Changed && b.delta_y == 40.0);
        let c = s.wheel(-15, true, false, 0.1);
        assert!(c.phase == ScrollPhase::Changed && c.delta_x == 5.0 && c.delta_y == 0.0);
        assert!(s.idle(0.15).is_none());
        assert_eq!(
            s.idle(0.3),
            Some(ScrollGesture { precise: true, phase: ScrollPhase::Ended, host_inertia: true, ..Default::default() })
        );
        assert!(!s.is_active() && s.idle(1.0).is_none());
        assert!(!s.wheel(120, false, false, 2.0).precise, "after the end a notch is a mouse again");
    }

    #[test]
    fn ctrl_touchpad_is_a_pinch() {
        let mut s = WinScroll::default();
        let a = s.wheel(60, false, true, 0.0);
        assert_eq!(
            a,
            ScrollGesture {
                kind: GestureKind::Magnify(0.05),
                precise: true,
                phase: ScrollPhase::Began,
                host_inertia: true,
                ..Default::default()
            }
        );
        assert_eq!(WinScroll::pixels(&a, 1.0), (0.0, 0.0));
        let b = s.wheel(-12, false, true, 0.02);
        assert!(
            matches!(b.kind, GestureKind::Magnify(m) if (m + 0.01).abs() < 1e-12) && b.phase == ScrollPhase::Changed
        );
        assert_eq!(
            s.idle(0.5),
            Some(ScrollGesture {
                kind: GestureKind::Magnify(0.0),
                precise: true,
                phase: ScrollPhase::Ended,
                host_inertia: true,
                ..Default::default()
            })
        );
    }
}
