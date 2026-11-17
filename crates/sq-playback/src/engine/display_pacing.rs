// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/DisplayLead.swift (DisplayLead) and FramePacing.swift (FramePhaseLock)
//! Display lead and frame phase lock, pure. While playing, the engine picks the video frame for the position the clock will
//! have when the frame reaches the glass (the lead), and keeps the frame changes of steady play midway between two display
//! ticks, so 24/25/30 fps content on a 60/120 Hz panel shows evenly spaced frames instead of 2:3 repeats.
//!
//! Present timestamps: a platform display link (`DisplayTiming::link_tick`, CVDisplayLink on the Mac, see
//! `sq-platform-mac`) reports each refresh with the host time its frame reaches the glass, as Swift reads the link's
//! target timestamp; the lead is that distance. Where no link runs (winit has no present timestamps; Windows and Linux
//! have no source yet), the window loop reports its frame ticks (`DisplayTiming::tick`) and the lead is estimated as one
//! refresh interval plus the measured time the frame callback took.
//! `PlayStart` is the Swift clock start laid out on the display (the engine holds the clock until it says go).
//! `DisplayLead` also has Swift's `prime` floor, `bounds` (the picture never leads out of the play range) and the loop
//! wrap (`wrapped`, `loop_wrap`); the engine wraps the clock itself at the loop's end.

use sq_core_edit::playback::PlaybackRate;
use sq_core_time::{Time, TimeRange};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// The window loop's frame ticks, shared with the engine thread (lock-free reads).
pub struct DisplayTiming {
    epoch: Instant,
    interval_us: AtomicU64,
    callback_us: AtomicU64,
    last_tick_us: AtomicI64,
    /// The display link's newest report: when it ran, and when its frame reaches the glass (`i64::MIN`: no link).
    link_at_us: AtomicI64,
    present_us: AtomicI64,
}

/// One report of [`DisplayTiming`], in microseconds on its own epoch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisplayTick {
    pub at_us: i64,
    pub interval_us: i64,
    pub callback_us: i64,
    /// Host time the frame this tick draws reaches the glass, from a display link (`None`: estimated).
    pub present_us: Option<i64>,
}

impl Default for DisplayTiming {
    fn default() -> DisplayTiming {
        DisplayTiming {
            epoch: Instant::now(),
            interval_us: AtomicU64::new(0),
            callback_us: AtomicU64::new(0),
            last_tick_us: AtomicI64::new(i64::MIN),
            link_at_us: AtomicI64::new(i64::MIN),
            present_us: AtomicI64::new(i64::MIN),
        }
    }
}

impl DisplayTiming {
    /// Microseconds since this timing's epoch.
    pub fn micros(&self, at: Instant) -> i64 {
        i64::try_from(at.saturating_duration_since(self.epoch).as_micros()).unwrap_or(i64::MAX)
    }

    /// The window loop ran a frame at `at`, on a display that refreshes every `interval`; `callback` is how long the
    /// previous frame callback took (smoothed here).
    pub fn tick(&self, at: Instant, interval: Duration, callback: Duration) {
        let new = u64::try_from(callback.as_micros()).unwrap_or(0).min(50_000);
        let old = self.callback_us.load(Ordering::Relaxed);
        self.callback_us.store(if old == 0 { new } else { (old * 3 + new) / 4 }, Ordering::Relaxed);
        self.interval_us.store(u64::try_from(interval.as_micros()).unwrap_or(0), Ordering::Relaxed);
        self.last_tick_us.store(self.micros(at), Ordering::Release);
    }

    /// A display link ran at `at` for a frame that reaches the glass at `present`; the link refreshes every `interval`.
    pub fn link_tick(&self, at: Instant, present: Instant, interval: Duration) {
        self.interval_us.store(u64::try_from(interval.as_micros()).unwrap_or(0), Ordering::Relaxed);
        self.present_us.store(self.micros(present), Ordering::Relaxed);
        self.link_at_us.store(self.micros(at), Ordering::Release);
    }

    pub fn read(&self) -> Option<DisplayTick> {
        let interval_us = i64::try_from(self.interval_us.load(Ordering::Relaxed)).unwrap_or(0);
        let callback_us = i64::try_from(self.callback_us.load(Ordering::Relaxed)).unwrap_or(0);
        let link = self.link_at_us.load(Ordering::Acquire);
        let now = self.micros(Instant::now());
        // A link that reported within a few refreshes is the display; an idle link falls back to the window loop's ticks.
        if link != i64::MIN && interval_us > 0 && now - link <= interval_us * STALE_INTERVALS {
            let present = self.present_us.load(Ordering::Relaxed);
            return Some(DisplayTick { at_us: link, interval_us, callback_us, present_us: Some(present) });
        }
        let at_us = self.last_tick_us.load(Ordering::Acquire);
        (at_us != i64::MIN && interval_us > 0).then_some(DisplayTick {
            at_us,
            interval_us,
            callback_us,
            present_us: None,
        })
    }
}

const QUANTUM: Time = Time::new(1, 1_000_000);
/// A bad estimate cannot jump the picture further than this.
/// The floor holds the picture for a clock at most this many frames behind, for at most this many ticks.
const FLOOR_FRAMES: i64 = 6;
const FLOOR_TICKS_LIMIT: u32 = 30;
/// A clock at most this long (at 1x) past a loop's end left it by playing: it continues that far into the loop.
const LOOP_OVERRUN: Time = Time::new(300_000, 1_000_000);

/// `t` inside the loop `r`: a position past its end continues from its start, one before its start from its end.
pub fn wrapped(t: Time, r: TimeRange) -> Time {
    let (start, end) = (r.start, r.end());
    if t >= end {
        let over = t - end;
        return if over < r.duration { start + over } else { start };
    }
    if t < start {
        let under = start - t;
        return if under < r.duration { end - under } else { start };
    }
    t
}

/// Where a running clock outside the loop `r` continues (Swift `RenderLoop.locksFramePhase`): past the end it keeps its
/// overshoot from the start, far past it (play began behind the loop) at the start; before the start (the audio clock
/// stops at 0, so a loop from 0 wraps at 0 too) from the end. `None`: the clock is inside.
pub fn loop_wrap(now: Time, r: TimeRange, rate: PlaybackRate) -> Option<Time> {
    let slack = scaled(LOOP_OVERRUN, rate);
    if rate.is_forward() && now >= r.end() {
        return Some(if now - r.end() <= slack { wrapped(now, r) } else { r.start });
    }
    if rate.is_reverse() && (now < r.start || (r.start == Time::ZERO && now <= Time::ZERO)) {
        let back = if r.start - now <= -slack { (r.start - now).max(QUANTUM) } else { QUANTUM };
        return Some((r.end() - back).max(r.start));
    }
    None
}

const MAXIMUM_LEAD_US: i64 = 150_000;
/// The applied lead changes by 1/`RAMP_DIVISOR` of the distance played.
const RAMP_DIVISOR: i64 = 8;
/// A tick report older than this many intervals is not a running display (idle window): the clock decides alone.
const STALE_INTERVALS: i64 = 4;

fn micros(us: i64) -> Time {
    Time::new(us, 1_000_000)
}

fn scaled(t: Time, r: PlaybackRate) -> Time {
    Time::scaled_int(t, i64::from(r.num()), i64::from(r.den().max(1)))
}

/// The lead: how far ahead of the clock the picture is picked, moving toward the wanted lead by a share of the distance played.
struct DisplayLead {
    previous: Option<Time>,
    applied: Time,
    reverse: bool,
    /// The next playing tick starts with the full lead (a play start laid out on the display, Swift `prime`).
    primed: bool,
    /// The picture does not go behind this position (the last frame the play start showed) until the clock is past it.
    floor: Option<Time>,
    floor_ticks: u32,
}

impl Default for DisplayLead {
    fn default() -> DisplayLead {
        DisplayLead { previous: None, applied: Time::ZERO, reverse: false, primed: false, floor: None, floor_ticks: 0 }
    }
}

impl Default for FramePhaseLock {
    fn default() -> FramePhaseLock {
        FramePhaseLock { offset: Time::ZERO, previous: None }
    }
}

impl DisplayLead {
    /// A play start laid out on the display ends: the lead is full from the first tick, and the picture stays on `floor`,
    /// the last position the play start showed, while a clock that started late is behind it.
    fn prime(&mut self, floor: Option<Time>) {
        *self = DisplayLead { primed: true, floor, ..DisplayLead::default() };
    }

    /// `p` (a led position for the clock at `now`) held inside `hold`, the play range of a non-looping engine.
    fn held(p: Time, now: Time, reverse: bool, fd: Time, hold: Option<TimeRange>) -> Time {
        let Some(b) = hold else { return p };
        if reverse {
            return if now >= b.start && p < b.start { b.start } else { p };
        }
        if now < b.end() && p >= b.end() { now.max(b.end() - fd) } else { p }
    }

    fn position(&mut self, now: Time, rate: PlaybackRate, host_lead: Time, fd: Time, hold: Option<TimeRange>) -> Time {
        let reverse = rate.is_reverse();
        let full = scaled(host_lead, rate);
        let wanted = if reverse { -full } else { full };
        if self.previous.is_none() || self.reverse != reverse {
            self.applied = if self.primed && self.previous.is_none() { wanted } else { Time::ZERO };
            self.previous = Some(now);
            self.reverse = reverse;
        }
        self.primed = false;
        let moved = now - self.previous.unwrap_or(now);
        self.previous = Some(now);
        if self.applied != wanted {
            let distance = if moved.is_negative() { -moved } else { moved };
            let step = Time::scaled_int(distance, 1, RAMP_DIVISOR).snapped(QUANTUM);
            self.applied =
                if self.applied < wanted { wanted.min(self.applied + step) } else { wanted.max(self.applied - step) };
        }
        let mut p = Self::held(if reverse { now - self.applied } else { now + self.applied }, now, reverse, fd, hold);
        if let Some(f) = self.floor {
            self.floor_ticks += 1;
            let behind = if reverse { p - f } else { f - p };
            // Far behind is not a late clock: a seek or a loop wrap moved it.
            if behind <= Time::ZERO || behind > fd * FLOOR_FRAMES || self.floor_ticks > FLOOR_TICKS_LIMIT {
                self.floor = None;
            } else {
                p = f;
            }
        }
        p
    }
}

/// Keeps the frame changes of steady play midway between display ticks. The frame a tick shows is `grid(clock + offset)`; at
/// every tick that moves one frame on, `offset` is nudged so the boundary just crossed lies halfway between this tick's clock
/// sample and the previous one (gain 1/4 of the difference, at most half a frame either way).
pub struct FramePhaseLock {
    offset: Time,
    previous: Option<Time>,
}

impl FramePhaseLock {
    pub fn offset(&self) -> Time {
        self.offset
    }

    pub fn sample(&mut self, now: Time, fd: Time, reverse: bool) -> Time {
        if fd <= Time::ZERO {
            return now;
        }
        let s = now + self.offset;
        let Some(p) = self.previous else {
            self.previous = Some(s);
            return s;
        };
        self.previous = Some(s);
        let (fp, fs) = (p.frame_index(fd), s.frame_index(fd));
        if fs - fp != if reverse { -1 } else { 1 } {
            return s;
        }
        let boundary = fd * if reverse { fp } else { fs };
        let (b, a) = if reverse { (p - boundary, boundary - s) } else { (boundary - p, s - boundary) };
        let mut delta = Time::scaled_int(if reverse { a - b } else { b - a }, 1, 4).snapped(QUANTUM);
        let limit = fd.halved();
        if self.offset + delta > limit {
            delta = limit - self.offset;
        }
        if self.offset + delta < -limit {
            delta = -limit - self.offset;
        }
        self.offset += delta;
        self.previous = Some(s + delta);
        s
    }
}

/// What the engine asks once per loop while playing: the frame position to show.
#[derive(Default)]
pub struct DisplayPacer {
    lead: DisplayLead,
    phase: FramePhaseLock,
    last_tick_us: Option<i64>,
    held: Option<Time>,
    last_lead_us: i64,
    /// The play range the picture never leads out of (unless it loops); survives `reset`.
    bounds: Option<TimeRange>,
    loops: bool,
}

impl DisplayPacer {
    pub fn reset(&mut self) {
        *self = DisplayPacer { bounds: self.bounds, loops: self.loops, ..DisplayPacer::default() };
    }

    /// The play range and whether the engine loops inside it (a loop wraps the led position, it is not held).
    pub fn set_bounds(&mut self, bounds: Option<TimeRange>, loops: bool) {
        self.bounds = bounds;
        self.loops = loops;
    }

    /// The clock was started by a play start laid out on the display: the lead is full from the first playing tick (the
    /// play start's `last_host_lead`) and the picture stays on `floor` while a late clock is behind it.
    pub fn prime(&mut self, floor: Option<Time>, host_lead: Time) {
        self.reset();
        self.lead.prime(floor);
        self.last_lead_us = host_lead.value() * 1_000_000 / host_lead.timescale().max(1);
    }

    pub fn phase_offset(&self) -> Time {
        self.phase.offset()
    }

    /// The position (on the frame grid) to show for the clock at `clock` (read `host_now_us` on the tick's epoch). Without
    /// a running display (`tick` None or stale): the frame the clock is inside of, as before. Between two display ticks the
    /// picture of the last tick stays: a frame changes when a display tick could show it.
    pub fn position(
        &mut self,
        tick: Option<DisplayTick>,
        host_now_us: i64,
        clock: Time,
        rate: PlaybackRate,
        fd: Time,
    ) -> Time {
        let plain = || fd * clock.frame_index(fd);
        let Some(tick) = tick.filter(|t| host_now_us - t.at_us <= t.interval_us * STALE_INTERVALS && fd > Time::ZERO)
        else {
            self.reset();
            return plain();
        };
        if self.last_tick_us == Some(tick.at_us)
            && let Some(h) = self.held
        {
            return h;
        }
        self.last_tick_us = Some(tick.at_us);
        // The clock when the tick ran (this loop may notice it a little late).
        let late = (host_now_us - tick.at_us).clamp(0, tick.interval_us);
        let at_tick = clock - scaled(micros(late), rate);
        // Swift `DisplayLead.hostLead`: the distance from this tick to the frame's presentation, a late (passed) target
        // reuses the last lead; without a link the lead is one interval plus the callback's time.
        let lead_us = match tick.present_us {
            Some(p) if p > tick.at_us => (p - tick.at_us).min(MAXIMUM_LEAD_US),
            Some(_) => self.last_lead_us,
            None => (tick.interval_us + tick.callback_us).clamp(0, MAXIMUM_LEAD_US),
        };
        self.last_lead_us = lead_us;
        let hold = if self.loops { None } else { self.bounds };
        let led = self.lead.position(at_tick, rate, micros(lead_us), fd, hold);
        let phased = self.phase.sample(led, fd, rate.is_reverse());
        let p = fd * phased.frame_index(fd);
        self.held = Some(p);
        p
    }
}

/// What a play start tick decides (Swift `PlayStart.Step`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PlayStep {
    /// Not laid out yet: the start frame stays.
    Hold,
    /// The position whose frame this tick shows; `anchored`: this tick laid the start out (`host_start` is set).
    Led { position: Time, anchored: bool },
    /// No display time (no link, a bad timestamp): start the clock now, at the start position.
    StartNow,
}

/// Play start on a display (Swift `PlayStart`, DisplayLead.swift:150). The clock stays parked on the start position while
/// the display link lays the start out: once the link ticks steadily, the start is placed in host time so that every
/// tick's presentation time falls in the middle of a frame (the same phase on every play start), and the frames from the
/// start position are picked for their presentation times, one after the other. The engine starts the clock at
/// `host_start`. Host times are seconds on the display timing's epoch. Pure.
#[derive(Clone, Debug, PartialEq)]
pub struct PlayStart {
    start: Time,
    rate: PlaybackRate,
    host_start: Option<f64>,
    last_led: Option<Time>,
    last_host_lead: Time,
    immediate: bool,
    ticks: u32,
    last_present_at: Option<f64>,
}

impl PlayStart {
    /// The start is laid out by this tick at the latest, steady link or not.
    pub const ANCHOR_BY_TICK: u32 = 4;
    /// A measured tick interval within this share of the expected one counts as steady.
    const INTERVAL_TOLERANCE: f64 = 0.2;
    /// The clock start lies at least this far after the tick that lays it out (the engine needs to get there).
    const START_MARGIN: f64 = 0.004;

    pub fn new(start: Time, rate: PlaybackRate) -> PlayStart {
        PlayStart {
            start,
            rate,
            host_start: None,
            last_led: None,
            last_host_lead: Time::ZERO,
            immediate: false,
            ticks: 0,
            last_present_at: None,
        }
    }

    pub fn host_start(&self) -> Option<f64> {
        self.host_start
    }

    /// The last led position handed out (the floor of the lead that takes over).
    pub fn last_led(&self) -> Option<Time> {
        self.last_led
    }

    /// The host lead of the last tick.
    pub fn last_host_lead(&self) -> Time {
        self.last_host_lead
    }

    /// No display time: the clock starts at once.
    pub fn immediate(&self) -> bool {
        self.immediate
    }

    pub fn start(&self) -> Time {
        self.start
    }

    fn speed(&self) -> f64 {
        if self.rate.den() == 0 {
            1.0
        } else {
            (f64::from(self.rate.num().unsigned_abs()) / f64::from(self.rate.den())).max(0.0001)
        }
    }

    fn run(&self, host_seconds: f64) -> Time {
        scaled(micros((host_seconds * 1_000_000.0).round() as i64), self.rate)
    }

    /// Where the clock is started at host time `h`: the start position until the laid-out start time, then on from it.
    pub fn clock_position(&self, h: f64) -> Time {
        match self.host_start {
            Some(hs) if h > hs => self.start + self.run(h - hs),
            _ => self.start,
        }
    }

    /// One display tick: `present_at` is when its frame reaches the glass, `host_now` the tick's time, `link_interval` the
    /// refresh interval the link is expected to run at.
    pub fn tick(&mut self, present_at: Option<f64>, host_now: f64, fd: Time, link_interval: f64) -> PlayStep {
        let Some(present_at) = present_at.filter(|p| p.is_finite() && host_now.is_finite() && *p > host_now) else {
            self.immediate = true;
            return PlayStep::StartNow;
        };
        if fd.value() <= 0 {
            self.immediate = true;
            return PlayStep::StartNow;
        }
        self.last_host_lead =
            micros((((present_at - host_now).min(MAXIMUM_LEAD_US as f64 / 1e6)) * 1e6).round() as i64);
        if let Some(hs) = self.host_start {
            let v = self.start + self.run((present_at - hs).max(0.0));
            self.last_led = Some(v);
            return PlayStep::Led { position: v, anchored: false };
        }
        self.ticks += 1;
        let last = self.last_present_at.replace(present_at);
        // The link's interval as it runs now: the expected one, or twice as fast (a 60 Hz floor for 30 fps).
        let mut interval = None;
        if let Some(last) = last.filter(|_| link_interval > 0.0) {
            let measured = present_at - last;
            interval = [link_interval, link_interval / 2.0]
                .into_iter()
                .find(|e| (measured - e).abs() <= e * Self::INTERVAL_TOLERANCE);
        }
        if interval.is_none() && self.ticks < Self::ANCHOR_BY_TICK {
            return PlayStep::Hold;
        }
        let frame = fd.value() as f64 / fd.timescale() as f64;
        let speed = self.speed();
        // Ticks fall in the middle of a frame (or of the part of it one tick shows).
        let per_tick = interval.unwrap_or(if link_interval > 0.0 { link_interval } else { frame / speed });
        let half = (per_tick * speed).min(frame) / 2.0;
        // Forward the start frame is on the glass already: this tick shows the next one when the clock start that implies
        // is still ahead. In reverse the frame before the start position begins right at it.
        let mut distance = half;
        if self.rate.is_forward() && present_at - (frame + half) / speed >= host_now + Self::START_MARGIN {
            distance = frame + half;
        }
        let hs = present_at - distance / speed;
        self.host_start = Some(hs);
        let v = self.start + self.run(present_at - hs);
        self.last_led = Some(v);
        PlayStep::Led { position: v, anchored: true }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD30: Time = Time::new(1, 30);

    /// Simulates `seconds` of 1x play of 30 fps content on a display ticking every `interval_us` with jitter, the engine
    /// loop sampling every 2 ms. Returns the host times (ms) at which the shown frame changed, as the display sees them
    /// (one reading per tick).
    fn run(interval_us: i64, jitter_us: i64, seconds: i64, pacing: bool) -> Vec<f64> {
        let mut pacer = DisplayPacer::default();
        let mut last_tick = 0i64;
        let mut next_tick = interval_us;
        let (mut shown, mut seen, mut changes) = (-1i64, -1i64, Vec::new());
        let mut seed = 12345u64;
        let mut host = 0i64;
        while host < seconds * 1_000_000 {
            host += 2_000;
            if host >= next_tick {
                last_tick = host;
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let j = ((seed >> 33) as i64 % (2 * jitter_us + 1)) - jitter_us;
                next_tick += interval_us;
                // The display reads the newest picture at its tick (jittered).
                let _ = j;
                if shown != seen {
                    changes.push((host + j) as f64 / 1e3);
                    seen = shown;
                }
            }
            let clock = micros(host);
            let tick =
                pacing.then_some(DisplayTick { at_us: last_tick, interval_us, callback_us: 1_000, present_us: None });
            let p = pacer.position(tick, host, clock, PlaybackRate::FORWARD, FD30);
            shown = p.frame_index(FD30);
        }
        changes
    }

    fn p95_gap(changes: &[f64]) -> f64 {
        let mut g: Vec<f64> = changes.windows(2).map(|w| w[1] - w[0]).collect();
        g.sort_by(f64::total_cmp);
        g[g.len() * 95 / 100]
    }

    #[test]
    fn thirty_fps_on_sixty_hz_shows_even_frames_with_the_lock() {
        let locked = p95_gap(&run(16_667, 1_500, 6, true));
        assert!(locked < 36.0, "p95 gap {locked} ms");
    }

    #[test]
    fn a_stale_tick_falls_back_to_the_clock_frame() {
        let mut p = DisplayPacer::default();
        let tick = DisplayTick { at_us: 0, interval_us: 16_667, callback_us: 0, present_us: None };
        let clock = Time::new(5, 100);
        assert_eq!(p.position(Some(tick), 1_000_000, clock, PlaybackRate::FORWARD, FD30), FD30 * 1);
        assert_eq!(p.position(None, 0, clock, PlaybackRate::FORWARD, FD30), FD30 * 1);
    }

    #[test]
    fn the_lead_ramps_in_and_never_passes_the_wanted_lead() {
        let mut l = DisplayLead::default();
        let rate = PlaybackRate::FORWARD;
        let mut last = Time::ZERO;
        for n in 0..200 {
            let now = micros(n * 16_667);
            let p = l.position(now, rate, micros(18_000), FD30, None);
            assert!(p - now <= micros(18_000), "lead {:?}", p - now);
            last = p - now;
        }
        assert_eq!(last, micros(18_000));
    }

    #[test]
    fn reverse_leads_backward_and_the_phase_offset_stays_inside_half_a_frame() {
        let mut p = DisplayPacer::default();
        let mut last_tick = 0;
        for n in 1..300i64 {
            let host = n * 16_667;
            last_tick = host;
            let clock = Time::new(10, 1) - micros(host);
            let tick = DisplayTick { at_us: last_tick, interval_us: 16_667, callback_us: 1_000, present_us: None };
            let shown = p.position(Some(tick), host, clock, PlaybackRate::REVERSE, FD30);
            assert!(shown <= clock + FD30, "reverse picture ahead of the clock: {shown:?} vs {clock:?}");
        }
        assert!(last_tick > 0);
        assert!(p.phase_offset().halved() <= FD30.halved());
    }

    // MARK: PlayStart on a fake display clock (Swift DisplayLeadTests "Play start timed to the display")

    fn secs(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    fn frame(t: Time) -> i64 {
        t.frame_index(FD30)
    }

    /// A display link ticking every `interval` s whose frames are shown `ahead` s after the tick; the clock is a host clock
    /// started at the first tick at or after the play start's host time (`late` s later). Returns the position per tick.
    fn run_start(rate: PlaybackRate, first_tick: f64, interval: f64, late: f64, ticks: usize) -> Vec<Time> {
        let start = Time::new(10, 1);
        let ahead = 0.0833;
        let mut ps = PlayStart::new(start, rate);
        let mut lead = DisplayLead::default();
        let mut began: Option<(f64, Time)> = None;
        let mut out = Vec::new();
        let speed = f64::from(rate.num().abs()) / f64::from(rate.den());
        for k in 0..ticks {
            let h = first_tick + k as f64 * interval;
            let p = h + ahead;
            if began.is_none()
                && let Some(hs) = ps.host_start()
                && hs + late <= h
            {
                began = Some((h, ps.clock_position(h)));
                lead.prime(ps.last_led());
            }
            if let Some((at, from)) = began {
                let now = from + scaled(micros(((h - at) * 1e6).round() as i64), rate);
                out.push(lead.position(now, rate, micros(((p - h) * 1e6).round() as i64), FD30, None));
            } else {
                match ps.tick(Some(p), h, FD30, 1.0 / (30.0 * speed.max(1.0))) {
                    PlayStep::Led { position, .. } => out.push(position),
                    PlayStep::Hold | PlayStep::StartNow => out.push(start),
                }
            }
        }
        out
    }

    #[test]
    fn play_start_shows_every_frame_in_order() {
        for phase in [0.0, 0.004, 0.011, 0.019, 0.027, 0.0329] {
            let picked = run_start(PlaybackRate::FORWARD, 100.0 + phase, 1.0 / 30.0, 0.0, 30);
            let frames: Vec<i64> = picked.iter().map(|p| frame(*p)).collect();
            assert_eq!(frames[0], 300, "phase {phase}");
            for w in frames.windows(2) {
                assert!(w[1] == w[0] + 1 || (w[1] == w[0] && w[0] == 300), "phase {phase}: {frames:?}");
            }
            assert!(*frames.last().unwrap_or(&0) >= 325, "phase {phase}: {frames:?}");
        }
    }

    #[test]
    fn play_start_locks_the_phase_mid_frame() {
        for phase in [0.0, 0.004, 0.011, 0.019, 0.027, 0.0329] {
            let picked = run_start(PlaybackRate::FORWARD, 100.0 + phase, 1.0 / 30.0, 0.0, 30);
            // The picks the play start itself made (before the clock began) are mid-frame; the start frame is excluded.
            let mid = secs(FD30) / 2.0;
            let anchored: Vec<_> = picked.iter().filter(|p| **p > Time::new(10, 1)).take(2).collect();
            assert!(!anchored.is_empty());
            for p in anchored {
                let in_frame = secs(*p - FD30 * frame(*p));
                assert!((in_frame - mid).abs() < 0.0005, "phase {phase}: {in_frame}");
            }
        }
    }

    #[test]
    fn play_start_holds_the_picture_when_the_clock_starts_late() {
        let picked = run_start(PlaybackRate::FORWARD, 100.0, 1.0 / 30.0, 0.05, 30);
        let frames: Vec<i64> = picked.iter().map(|p| frame(*p)).collect();
        for w in frames.windows(2) {
            assert!(w[1] == w[0] + 1 || w[1] == w[0], "{frames:?}");
        }
        assert!(*frames.last().unwrap_or(&0) >= 320, "{frames:?}");
    }

    #[test]
    fn play_start_in_reverse_goes_back_one_frame_per_tick() {
        for phase in [0.0, 0.009, 0.021] {
            let picked = run_start(PlaybackRate::REVERSE, 100.0 + phase, 1.0 / 30.0, 0.0, 30);
            let frames: Vec<i64> = picked.iter().map(|p| frame(*p)).collect();
            assert_eq!(frames[0], 300);
            for w in frames.windows(2) {
                assert!(w[1] == w[0] - 1 || (w[1] == w[0] && w[0] == 300), "phase {phase}: {frames:?}");
            }
            assert!(*frames.last().unwrap_or(&0) <= 275, "phase {phase}: {frames:?}");
        }
    }

    #[test]
    fn play_start_on_a_link_at_twice_the_frame_rate() {
        let picked = run_start(PlaybackRate::FORWARD, 100.003, 1.0 / 60.0, 0.0, 40);
        let frames: Vec<i64> = picked.iter().map(|p| frame(*p)).collect();
        for w in frames.windows(2) {
            assert!(w[1] == w[0] + 1 || w[1] == w[0], "{frames:?}");
        }
        assert!(*frames.last().unwrap_or(&0) >= 315, "{frames:?}");
    }

    #[test]
    fn play_start_waits_for_a_steady_link_at_most_four_ticks() {
        let mut ps = PlayStart::new(Time::new(10, 1), PlaybackRate::FORWARD);
        let mut anchored_at = None;
        for k in 0..6 {
            let h = 100.0 + f64::from(k) / 120.0;
            if let PlayStep::Led { anchored: true, .. } = ps.tick(Some(h + 0.03), h, FD30, 1.0 / 30.0) {
                anchored_at = Some(k);
            }
        }
        assert_eq!(anchored_at, Some(3));
        assert!(ps.host_start().is_some());
    }

    #[test]
    fn play_start_without_a_timestamp_starts_at_once() {
        let mut ps = PlayStart::new(Time::new(10, 1), PlaybackRate::FORWARD);
        assert_eq!(ps.tick(None, 100.0, FD30, 1.0 / 30.0), PlayStep::StartNow);
        assert!(ps.immediate());
        assert_eq!(ps.clock_position(100.5), Time::new(10, 1));
    }

    #[test]
    fn the_clock_never_starts_before_the_start_position() {
        let mut ps = PlayStart::new(Time::new(10, 1), PlaybackRate::FORWARD);
        ps.tick(Some(100.0833), 100.0, FD30, 1.0 / 30.0);
        ps.tick(Some(100.1166), 100.0333, FD30, 1.0 / 30.0);
        let hs = ps.host_start().expect("laid out");
        assert!(hs > 100.0333 && hs < 100.1166);
        assert_eq!(ps.clock_position(hs - 0.02), Time::new(10, 1));
        assert!((secs(ps.clock_position(hs + 0.02)) - 10.02).abs() < 0.00001);
    }

    #[test]
    fn a_link_report_gives_the_lead_its_present_distance() {
        let timing = DisplayTiming::default();
        let at = Instant::now();
        timing.link_tick(at, at + Duration::from_millis(40), Duration::from_micros(16_667));
        let tick = timing.read().expect("a link tick");
        assert_eq!(tick.present_us.map(|p| p - tick.at_us), Some(40_000));
        let mut pacer = DisplayPacer::default();
        let clock = Time::new(5, 1);
        let host_now = tick.at_us;
        // 40 ms of lead at 1x on a 30 fps grid: the frame 40 ms ahead of the clock.
        let shown = pacer.position(Some(tick), host_now, clock, PlaybackRate::FORWARD, FD30);
        assert!(shown > clock - FD30 && shown <= clock + FD30 * 2, "{shown:?}");
    }

    // MARK: Bounds, floor and loop wrap (Swift DisplayLeadTests)

    fn range(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(Time::new(a, 30), Time::new(b, 30))
    }

    #[test]
    fn the_picture_never_leads_out_of_the_play_range_it_is_still_inside() {
        let mut l = DisplayLead::default();
        let hold = Some(range(0, 30));
        let mut now = Time::new(25, 30);
        let mut last = Time::ZERO;
        for _ in 0..60 {
            last = l.position(now, PlaybackRate::FORWARD, micros(100_000), FD30, hold);
            assert!(last < Time::new(30, 30), "led out of the range: {last:?} at {now:?}");
            now += micros(16_667);
            if now >= Time::new(30, 30) {
                break;
            }
        }
        assert!(last >= Time::new(25, 30));
        // Without the hold (a loop) the same lead runs past the end.
        let mut l = DisplayLead::default();
        let p = (0..40).map(|n| {
            l.position(Time::new(29, 30) + micros(n * 1_000), PlaybackRate::FORWARD, micros(100_000), FD30, None)
        });
        assert!(p.max().is_some_and(|m| m >= Time::new(30, 30)));
    }

    #[test]
    fn reverse_is_held_at_the_range_start() {
        let mut l = DisplayLead::default();
        let hold = Some(range(10, 30));
        let mut now = Time::new(12, 30);
        for _ in 0..30 {
            let p = l.position(now, PlaybackRate::REVERSE, micros(100_000), FD30, hold);
            assert!(p >= Time::new(10, 30), "led out of the range: {p:?}");
            now -= micros(16_667);
            if now < Time::new(10, 30) {
                break;
            }
        }
    }

    #[test]
    fn a_primed_lead_keeps_the_floor_until_the_clock_passes_it_and_drops_it_far_behind() {
        let mut l = DisplayLead::default();
        let floor = Time::new(12, 30);
        l.prime(Some(floor));
        // The clock started late: still two frames behind the floor, the picture holds.
        assert_eq!(l.position(Time::new(10, 30), PlaybackRate::FORWARD, micros(33_333), FD30, None), floor);
        // A seek or loop wrap moved the clock far behind: no floor.
        let mut l = DisplayLead::default();
        l.prime(Some(floor));
        assert!(l.position(Time::ZERO, PlaybackRate::FORWARD, micros(33_333), FD30, None) < floor);
    }

    #[test]
    fn wrapped_continues_at_the_other_end() {
        let r = range(30, 60);
        assert_eq!(wrapped(Time::new(62, 30), r), Time::new(32, 30));
        assert_eq!(wrapped(Time::new(28, 30), r), Time::new(58, 30));
        assert_eq!(wrapped(Time::new(45, 30), r), Time::new(45, 30));
        assert_eq!(wrapped(Time::new(200, 30), r), Time::new(30, 30), "far past: the beginning");
    }

    #[test]
    fn loop_wrap_keeps_the_overshoot_and_restarts_far_outside() {
        let r = range(30, 60);
        let fwd = PlaybackRate::FORWARD;
        assert_eq!(loop_wrap(Time::new(59, 30), r, fwd), None);
        assert_eq!(loop_wrap(Time::new(61, 30), r, fwd), Some(Time::new(31, 30)));
        assert_eq!(loop_wrap(Time::new(75, 30), r, fwd), Some(Time::new(30, 30)));
        assert_eq!(loop_wrap(Time::new(29, 30), r, PlaybackRate::REVERSE), Some(Time::new(59, 30)));
        assert_eq!(loop_wrap(Time::new(40, 30), r, PlaybackRate::REVERSE), None);
    }
}
