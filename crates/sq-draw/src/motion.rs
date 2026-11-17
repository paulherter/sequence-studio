//! The motion system of the draw UI: duration and easing tokens, [`Animated`] values and the per-frame [`MotionBook`] that
//! keeps the on-demand redraw loop honest. Docs: `docs/rust/MOTION.md`.
//!
//! Rules: state changes are immediate (the model, hit tests and commands never wait); only what is drawn follows. An
//! animation is interruptible (a new target starts from the value on screen) and requests frames only while it runs; the
//! last frame is the one that samples the finished value, then nothing asks for frames. Reduce motion makes every duration 0.
//! Time is a steady-clock `f64` in seconds, passed in, so tests drive a fake clock.

use std::cell::RefCell;
use std::collections::HashMap;

/// Durations in seconds (the 80 / 120 / 180 / 240 ms ladder).
pub mod duration {
    /// Press, check, small state flips.
    pub const FAST: f64 = 0.08;
    /// Selection, panel focus line, tooltip fade (never hover: hover is instant).
    pub const BASE: f64 = 0.12;
    /// Popover, menu and dialog open (slightly longer than BASE; close uses FAST).
    pub const OPEN: f64 = 0.14;
    /// Larger moves: drag settle, zoom to fit, page turn.
    pub const MEDIUM: f64 = 0.18;
    /// Whole-view moves.
    pub const SLOW: f64 = 0.24;
    /// An exit takes this share of its enter (the system answers, so it leaves faster than it came).
    pub const EXIT_FACTOR: f64 = 2.0 / 3.0;
    /// Menu, popover and dialog close: 100 ms (`menu-out`), not two thirds of the 140 ms open.
    pub const OPEN_EXIT: f64 = 0.10;
    /// The exit time for an enter time: BASE (120 ms) leaves in 80 ms; the menu open ([`OPEN`]) leaves in 100 ms.
    pub fn exit(enter: f64) -> f64 {
        if (enter - OPEN).abs() < 1e-9 { OPEN_EXIT } else { enter * EXIT_FACTOR }
    }
}

/// Easing curves. `OutCubic` is the standard; `Spring` is a small overshoot for a dropped item only (never on controls).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ease {
    /// Constant speed (progress bars, fades that must not accelerate).
    Linear,
    /// Fast start, soft landing: the standard for everything that responds to input.
    OutCubic,
    /// Symmetric, for a move between two rest places.
    InOutCubic,
    /// Out-back with a 2.5 percent overshoot: drop settle.
    Spring,
    /// `cubic-bezier(.23, 1, .32, 1)`: the stone press release and the switch knob (HAUPTFENSTER section 12).
    OutStone,
}

impl Ease {
    /// The eased progress for linear progress `t` (clamped to 0 ..= 1); 0 maps to 0 and 1 to 1.
    pub fn apply(self, t: f64) -> f64 {
        let t = t.clamp(0.0, 1.0);
        match self {
            Ease::Linear => t,
            Ease::OutCubic => 1.0 - (1.0 - t).powi(3),
            Ease::InOutCubic => {
                if t < 0.5 {
                    4.0 * t * t * t
                } else {
                    1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
                }
            }
            Ease::Spring => {
                const C1: f64 = 0.6;
                const C3: f64 = C1 + 1.0;
                1.0 + C3 * (t - 1.0).powi(3) + C1 * (t - 1.0).powi(2)
            }
            Ease::OutStone if t <= 0.0 || t >= 1.0 => t,
            Ease::OutStone => cubic_bezier(0.23, 1.0, 0.32, 1.0, t),
        }
    }
}

/// The y of a CSS `cubic-bezier(x1, y1, x2, y2)` at progress `t` (x solved by bisection).
fn cubic_bezier(x1: f64, y1: f64, x2: f64, y2: f64, t: f64) -> f64 {
    let at = |a: f64, b: f64, s: f64| 3.0 * (1.0 - s).powi(2) * s * a + 3.0 * (1.0 - s) * s * s * b + s.powi(3);
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if at(x1, x2, mid) < t {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    at(y1, y2, (lo + hi) / 2.0)
}

/// A value that can be blended.
pub trait Lerp: Copy + PartialEq {
    /// `self + (to - self) * t`.
    fn lerp(self, to: Self, t: f64) -> Self;
}
impl Lerp for f64 {
    fn lerp(self, to: f64, t: f64) -> f64 {
        self + (to - self) * t
    }
}
impl Lerp for f32 {
    fn lerp(self, to: f32, t: f64) -> f32 {
        self + (to - self) * t as f32
    }
}
impl Lerp for (f64, f64) {
    fn lerp(self, to: Self, t: f64) -> Self {
        (self.0.lerp(to.0, t), self.1.lerp(to.1, t))
    }
}

/// A value on its way to a target: from where it was when the target changed, over a duration, with an easing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Animated<T: Lerp> {
    from: T,
    to: T,
    start: f64,
    duration: f64,
    ease: Ease,
}

impl<T: Lerp> Animated<T> {
    /// At rest at `value`.
    pub fn new(value: T) -> Animated<T> {
        Animated { from: value, to: value, start: 0.0, duration: 0.0, ease: Ease::OutCubic }
    }
    /// The target.
    pub fn target(&self) -> T {
        self.to
    }
    /// Moves toward `target` from the value shown at `now` (an interrupted move continues from where it is). The same
    /// target again changes nothing. A zero duration jumps.
    pub fn set(&mut self, target: T, now: f64, duration: f64, ease: Ease) {
        if target == self.to {
            return;
        }
        self.from = self.get(now);
        self.to = target;
        self.start = now;
        self.duration = duration.max(0.0);
        self.ease = ease;
    }
    /// Jumps to `value` with no animation.
    pub fn snap(&mut self, value: T) {
        *self = Animated::new(value);
    }
    /// The value at `now`.
    pub fn get(&self, now: f64) -> T {
        if self.duration <= 0.0 || now >= self.start + self.duration {
            return self.to;
        }
        if now <= self.start {
            return self.from;
        }
        self.from.lerp(self.to, self.ease.apply((now - self.start) / self.duration))
    }
    /// The move has not reached its end at `now`.
    pub fn is_running(&self, now: f64) -> bool {
        self.duration > 0.0 && now < self.start + self.duration
    }
}

/// Keyed 0 ..= 1 levels for the immediate-mode widgets (hover, press, selection, open): a widget says each frame where its
/// state is heading and gets the level to draw with. A key is first seen at its target (no fade-in at start-up). Entries
/// of controls that stopped being drawn are dropped once settled.
#[derive(Debug, Default)]
pub struct MotionBook {
    entries: HashMap<u64, Entry>,
    now: f64,
    reduce: bool,
    /// Headless runs (shots): every duration is 0, even an open's crossfade.
    snap: bool,
    running: bool,
}

#[derive(Debug)]
struct Entry {
    level: Animated<f32>,
    seen: f64,
    /// Kept only while drawn every frame (an open popover): when it stops being drawn the next open starts again from 0.
    ephemeral: bool,
}

impl MotionBook {
    /// An empty book.
    pub fn new() -> MotionBook {
        MotionBook::default()
    }
    /// Reduce motion: movement and springs become immediate; an opening popover or dialog keeps a short crossfade.
    pub fn set_reduce_motion(&mut self, on: bool) {
        self.reduce = on;
    }
    /// Snap: every duration becomes 0, crossfades too (headless shots draw one frame).
    pub fn set_snap(&mut self, on: bool) {
        self.snap = on;
    }
    /// Whether reduce motion (or snap) is on.
    pub fn reduce_motion(&self) -> bool {
        self.reduce || self.snap
    }
    /// A frame starts at `now`: forgets settled entries nobody asked for lately.
    pub fn begin_frame(&mut self, now: f64) {
        let previous = self.now;
        // A clock that runs backwards is another app on this thread (headless sweeps build one after the other, each with
        // a clock from zero): the entries of the old run keep their start in this run's future, so a dialog key reused
        // by the next app sat at level 0 until its clock caught up.
        if now < previous {
            self.entries.clear();
        }
        self.now = now;
        self.running = false;
        self.entries.retain(|_, e| {
            if e.ephemeral { e.seen >= previous } else { now - e.seen < 1.0 || e.level.is_running(now) }
        });
    }
    /// The frame clock.
    pub fn now(&self) -> f64 {
        self.now
    }
    /// Something outside the book moves (a scroll bounce): the loop must draw the next frame too.
    pub fn request_frame(&mut self) {
        self.running = true;
    }
    /// The level of `key` heading to `target` (0 or 1 for a flag): what to draw this frame.
    pub fn level(&mut self, key: u64, target: f32, duration: f64, ease: Ease) -> f32 {
        let now = self.now;
        let d = if self.reduce_motion() { 0.0 } else { duration };
        let e = self.entries.entry(key).or_insert_with(|| Entry {
            level: Animated::new(target),
            seen: now,
            ephemeral: false,
        });
        e.seen = now;
        e.level.set(target, now, d, ease);
        let v = e.level.get(now);
        if e.level.is_running(now) {
            self.running = true;
        }
        v
    }
    /// The open level (0 -> 1) of something drawn while it is open: first drawn it starts at 0 and rises to 1; when it stops
    /// being drawn for a frame the entry goes, so the next open rises again.
    pub fn open_level(&mut self, key: u64, duration: f64, ease: Ease) -> f32 {
        let now = self.now;
        let e =
            self.entries.entry(key).or_insert_with(|| Entry { level: Animated::new(0.0), seen: now, ephemeral: true });
        e.seen = now;
        // Reduce motion keeps the fade (a crossfade, no scale); only snap makes the open instant.
        e.level.set(1.0, now, if self.snap { 0.0 } else { duration }, ease);
        let v = e.level.get(now);
        if e.level.is_running(now) {
            self.running = true;
        }
        v
    }
    /// An animated value drawn this frame sat short of its end: the loop must draw the next frame. False once the last
    /// frame sampled every value finished, so an idle app asks for nothing.
    pub fn needs_frame(&self) -> bool {
        self.running
    }
    /// Entries kept (a test hook).
    pub fn len(&self) -> usize {
        self.entries.len()
    }
    /// No entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

thread_local! {
    static BOOK: RefCell<MotionBook> = RefCell::new(MotionBook::new());
}

/// Runs `f` on this thread's book (the UI is single-threaded).
pub fn with_book<R>(f: impl FnOnce(&mut MotionBook) -> R) -> R {
    BOOK.with(|b| f(&mut b.borrow_mut()))
}
/// The app calls this when a frame starts.
pub fn begin_frame(now: f64) {
    with_book(|b| b.begin_frame(now));
}
/// The frame clock of this thread (the time the app passed to [`begin_frame`]).
pub fn now() -> f64 {
    with_book(|b| b.now())
}
/// A motion that does not run through the book (a scroll fling or bounce) asks for the next frame.
pub fn request_frame() {
    with_book(|b| b.request_frame());
}
/// The loop asks this after a frame.
pub fn needs_frame() -> bool {
    with_book(|b| b.needs_frame())
}
/// Reduce motion is on (for animations that do not run through the book: the zoom ease).
pub fn reduce_motion() -> bool {
    with_book(|b| b.reduce_motion())
}
/// The OS or `SQ_REDUCE_MOTION` says reduce motion.
pub fn set_reduce_motion(on: bool) {
    with_book(|b| b.set_reduce_motion(on));
}
/// Headless runs: every duration is 0.
pub fn set_snap(on: bool) {
    with_book(|b| b.set_snap(on));
}
/// The scale an opening popover or dialog starts at.
pub const OPEN_SCALE: f32 = 0.97;

/// Roles that keep keys of different states of one rectangle apart.
pub mod role {
    /// Pressed.
    pub const PRESS: u32 = 2;
    /// Selected or active.
    pub const SELECT: u32 = 3;
    /// Panel focus line.
    pub const FOCUS: u32 = 4;
    /// Open popover, menu or dialog.
    pub const OPEN: u32 = 5;
}
/// A key from a rectangle in device pixels and a role, stable while the control stays put.
pub fn key_of(role: u32, x: f32, y: f32, w: f32, h: f32) -> u64 {
    let mut k = 0xcbf2_9ce4_8422_2325_u64 ^ u64::from(role);
    for v in [x, y, w, h] {
        k = (k ^ u64::from(v.round() as i32 as u32)).wrapping_mul(0x0100_0000_01b3);
    }
    k
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_open_level_rises_from_zero_and_starts_again_after_a_closed_frame() {
        let mut b = MotionBook::new();
        let at = |b: &mut MotionBook, now: f64, drawn: bool| {
            b.begin_frame(now);
            let v = drawn.then(|| b.open_level(9, duration::OPEN, Ease::Linear));
            (v, b.needs_frame())
        };
        assert_eq!(at(&mut b, 0.0, true), (Some(0.0), true));
        let (v, more) = at(&mut b, 0.07, true);
        assert!((v.unwrap_or(9.0) - 0.5).abs() < 1e-6 && more);
        assert_eq!(at(&mut b, 0.2, true), (Some(1.0), false));
        assert_eq!(at(&mut b, 0.3, false), (None, false));
        assert_eq!(at(&mut b, 0.4, false), (None, false));
        assert_eq!(at(&mut b, 0.5, true), (Some(0.0), true), "a second open rises again");
    }

    #[test]
    fn an_open_starts_at_scale_97_percent_never_from_zero() {
        assert_eq!(OPEN_SCALE, 0.97);
    }

    #[test]
    fn an_exit_is_faster_than_its_enter_at_every_rung() {
        for enter in [duration::FAST, duration::BASE, duration::OPEN, duration::MEDIUM, duration::SLOW] {
            assert!(duration::exit(enter) < enter);
        }
        assert!((duration::exit(duration::BASE) - duration::FAST).abs() < 1e-9);
    }

    #[test]
    fn eases_start_at_zero_and_end_at_one() {
        for e in [Ease::Linear, Ease::OutCubic, Ease::InOutCubic, Ease::Spring, Ease::OutStone] {
            assert!(e.apply(0.0).abs() < 1e-12 && (e.apply(1.0) - 1.0).abs() < 1e-12, "{e:?}");
        }
        assert!(Ease::OutCubic.apply(0.5) > 0.8);
        assert!(Ease::Spring.apply(0.7) > 1.0 && Ease::Spring.apply(0.7) < 1.05);
        assert!(Ease::OutCubic.apply(0.99) <= 1.0, "no bounce on controls");
    }

    #[test]
    fn the_stone_ease_is_the_css_curve_fast_start_no_overshoot() {
        // cubic-bezier(.23,1,.32,1): about 0.76 at a quarter, 0.97 at half, never above 1.
        assert!((Ease::OutStone.apply(0.25) - 0.77).abs() < 0.04, "{}", Ease::OutStone.apply(0.25));
        assert!(Ease::OutStone.apply(0.5) > 0.95);
        assert!((0..=100).all(|i| Ease::OutStone.apply(f64::from(i) / 100.0) <= 1.0 + 1e-9));
    }

    #[test]
    fn a_value_is_at_start_in_the_middle_and_at_the_end() {
        let mut a = Animated::new(0.0_f64);
        a.set(10.0, 5.0, 0.12, Ease::Linear);
        assert_eq!(a.get(5.0), 0.0);
        assert!((a.get(5.06) - 5.0).abs() < 1e-9);
        assert_eq!(a.get(5.12), 10.0);
        assert!(a.is_running(5.06) && !a.is_running(5.12));
    }

    #[test]
    fn an_interrupted_move_continues_from_where_it_is() {
        let mut a = Animated::new(0.0_f64);
        a.set(1.0, 0.0, 0.1, Ease::Linear);
        let mid = a.get(0.05);
        a.set(0.0, 0.05, 0.1, Ease::Linear);
        assert!((a.get(0.05) - mid).abs() < 1e-12, "no jump at the turn");
        assert!((a.get(0.1) - mid * 0.5).abs() < 1e-9);
        assert!(a.get(0.15).abs() < 1e-12);
    }

    #[test]
    fn the_same_target_does_not_restart() {
        let mut a = Animated::new(0.0_f64);
        a.set(1.0, 0.0, 0.1, Ease::Linear);
        a.set(1.0, 0.09, 0.1, Ease::Linear);
        assert_eq!(a.get(0.1), 1.0);
    }

    #[test]
    fn zero_duration_jumps() {
        let mut a = Animated::new(0.0_f32);
        a.set(1.0, 1.0, 0.0, Ease::OutCubic);
        assert_eq!(a.get(1.0), 1.0);
        assert!(!a.is_running(1.0));
    }

    /// One frame of a widget at fake time `now`: the state timeline of a flag fade.
    fn frame(b: &mut MotionBook, now: f64, hot: bool) -> (f32, bool) {
        b.begin_frame(now);
        let v = b.level(7, if hot { 1.0 } else { 0.0 }, duration::BASE, Ease::Linear);
        (v, b.needs_frame())
    }

    #[test]
    fn a_book_asks_for_frames_only_while_running_and_stops_after_the_last() {
        let mut b = MotionBook::new();
        assert_eq!(frame(&mut b, 0.0, false), (0.0, false), "first sight is at the target, idle");
        assert_eq!(frame(&mut b, 0.5, false), (0.0, false), "idle stays idle");
        let (v, more) = frame(&mut b, 1.0, true);
        assert_eq!((v, more), (0.0, true), "the move starts at 0 and wants the next frame");
        let (v, more) = frame(&mut b, 1.06, true);
        assert!((v - 0.5).abs() < 1e-6 && more);
        let (v, more) = frame(&mut b, 1.13, true);
        assert_eq!((v, more), (1.0, false), "the frame after the end shows the target and stops the loop");
        assert_eq!(frame(&mut b, 1.2, true), (1.0, false));
    }

    #[test]
    fn leaving_mid_fade_turns_around_without_a_jump() {
        let mut b = MotionBook::new();
        frame(&mut b, 0.0, false);
        let (up, _) = frame(&mut b, 0.5, true);
        let (mid, _) = frame(&mut b, 0.56, true);
        let (turn, more) = frame(&mut b, 0.56, false);
        assert!(up < mid && (turn - mid).abs() < 1e-6 && more);
        assert_eq!(frame(&mut b, 0.9, false), (0.0, false));
    }

    #[test]
    fn reduce_motion_makes_every_change_immediate() {
        let mut b = MotionBook::new();
        b.set_reduce_motion(true);
        frame(&mut b, 0.0, false);
        assert_eq!(frame(&mut b, 1.0, true), (1.0, false));
    }

    #[test]
    fn reduce_motion_opens_with_a_crossfade_and_snap_opens_at_once() {
        let mut b = MotionBook::new();
        b.set_reduce_motion(true);
        b.begin_frame(0.0);
        assert_eq!(b.open_level(7, 0.2, Ease::OutCubic), 0.0);
        b.begin_frame(0.1);
        let mid = b.open_level(7, 0.2, Ease::OutCubic);
        assert!(mid > 0.0 && mid < 1.0, "a fade, not a jump: {mid}");
        let mut s = MotionBook::new();
        s.set_snap(true);
        s.begin_frame(0.0);
        assert_eq!(s.open_level(7, 0.2, Ease::OutCubic), 1.0);
    }

    #[test]
    fn a_clock_that_restarts_forgets_the_entries_of_the_run_before() {
        let mut b = MotionBook::new();
        // The first app opened a dialog at t = 40 s and left it drawn; the next app's clock starts at zero again.
        b.begin_frame(40.0);
        b.open_level(0, duration::OPEN, Ease::Linear);
        b.begin_frame(41.0);
        assert_eq!(b.open_level(0, duration::OPEN, Ease::Linear), 1.0);
        b.begin_frame(0.5);
        assert_eq!(b.open_level(0, duration::OPEN, Ease::Linear), 0.0, "the same key opens afresh in the new run");
        b.begin_frame(0.5 + duration::OPEN);
        assert_eq!(b.open_level(0, duration::OPEN, Ease::Linear), 1.0, "and finishes on the new clock, not at 40 s");
    }

    #[test]
    fn settled_entries_of_vanished_controls_are_dropped() {
        let mut b = MotionBook::new();
        frame(&mut b, 0.0, false);
        assert_eq!(b.len(), 1);
        b.begin_frame(2.0);
        assert!(b.is_empty());
    }
}
