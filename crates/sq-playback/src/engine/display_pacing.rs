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
use std::collections::VecDeque;
use std::sync::Mutex;
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
    /// The window's newest present slot (`PresentSlots`) and the time it was reported.
    slot: Mutex<Option<(DisplayTick, i64)>>,
    /// Drawables the window acquired so far (the sequence number of a present), and the glass times reported for them.
    acquired: AtomicU64,
    glass: Mutex<Vec<(u64, i64)>>,
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
            slot: Mutex::new(None),
            acquired: AtomicU64::new(0),
            glass: Mutex::new(Vec::new()),
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

    /// The `Instant` of `us` microseconds on this timing's epoch.
    pub fn at(&self, us: i64) -> Instant {
        self.epoch + Duration::from_micros(u64::try_from(us).unwrap_or(0))
    }

    /// The window acquired a drawable: its sequence number (0 for the first).
    pub fn note_acquired(&self) -> u64 {
        self.acquired.fetch_add(1, Ordering::Relaxed)
    }

    /// How many drawables were acquired; the newest one has the sequence number one less.
    pub fn acquired(&self) -> u64 {
        self.acquired.load(Ordering::Relaxed)
    }

    /// The display showed the drawable `seq` at `at` (a real present timestamp: Mac `presentedTime`).
    pub fn glass_report(&self, seq: u64, at: Instant) {
        let us = self.micros(at);
        let mut g = self.glass.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if g.len() >= 4096 {
            g.remove(0);
        }
        g.push((seq, us));
    }

    /// The glass times reported since the last call, as `(sequence number, microseconds on this timing's epoch)`.
    pub fn drain_glass(&self) -> Vec<(u64, i64)> {
        std::mem::take(&mut *self.glass.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
    }

    /// The window presented a frame; `tick` is its next present slot (`PresentSlots::presented`).
    pub fn slot_tick(&self, tick: DisplayTick) {
        let seen = self.micros(Instant::now());
        *self.slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((tick, seen));
    }

    /// A vsync time (`present_us` of the display link's newest tick) and the refresh interval, while a link runs.
    pub fn grid(&self) -> Option<(i64, i64)> {
        let t = self.read().filter(|t| t.present_us.is_some())?;
        Some((t.present_us?, t.interval_us))
    }

    /// The ticks the frame choice follows: the window's present slots while it presents (the glass sequence), else
    /// [`read`](Self::read).
    pub fn read_paced(&self) -> Option<DisplayTick> {
        let slot = *self.slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((tick, seen)) = slot
            && tick.interval_us > 0
            && self.micros(Instant::now()) - seen <= tick.interval_us * STALE_INTERVALS
        {
            return Some(tick);
        }
        self.read()
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

/// Which glass slot each present of the window takes. The window presents through a queue (Fifo, a few images ahead): a
/// present returns long before its image reaches the glass, and how far ahead the CPU runs changes with every late turn, so
/// the time a present was made says little about what the viewer sees when. Images leave the queue one per vsync, in order:
/// an image shows at the first vsync it is ready for, and never before the one ahead of it has had its. This follows that,
/// so the frame choice is made for slots on the vsync grid (a pure function of the slot count) instead of for jittered turn
/// times: a frame no longer flips between 4 and 5 presents at a boundary when a turn is a few milliseconds late.
#[derive(Default)]
pub struct PresentSlots {
    last_glass_us: Option<i64>,
    last_seq: u64,
    /// The earliest vsync each recent present could show at (sequence number, time), to read how deep the queue really is.
    firsts: VecDeque<(u64, i64)>,
    /// How many vsyncs after its earliest slot each recent present really reached the glass (from glass reports).
    depths: VecDeque<i64>,
}

impl PresentSlots {
    /// The GPU needs about this long after a present returns before the image can be scanned out.
    const READY_MARGIN_US: i64 = 2_000;
    /// The present queue plus the image on the glass, as far as a run without glass times assumes.
    const MAX_QUEUE_SLOTS: i64 = 3;
    /// Recent presents remembered for the measured queue depth (glass reports arrive a few presents late).
    const HISTORY: usize = 16;

    /// How many vsyncs after the earliest slot a present may land: the model's guess without glass times, the deepest
    /// queue the display really showed lately (plus one, for a vsync it skips) with them. The queue of a Metal layer was
    /// measured 3 to 4 vsyncs deep, so a fixed cap of 3 put every slot one vsync too early (run6: 40 % of slots exact).
    fn queue_cap(&self) -> i64 {
        // The median, not the maximum: one stall depth must not lift the run-away bound for the next `HISTORY` presents.
        let mut sorted: Vec<i64> = self.depths.iter().copied().collect();
        sorted.sort_unstable();
        sorted.get(sorted.len() / 2).map_or(Self::MAX_QUEUE_SLOTS, |d| (d + 1).max(Self::MAX_QUEUE_SLOTS))
    }

    /// The display really showed present `seq` at `glass_us` (a present timestamp, a few slots after the present): the chain
    /// takes the truth, so the margin guess and every slot the model could not see are corrected. A report that is far from
    /// the model (a sequence number that does not belong to a present of this window) is ignored.
    pub fn glass_seen(&mut self, seq: u64, glass_us: i64, interval_us: i64) {
        let interval = interval_us.max(1);
        if let Some(&(_, first)) = self.firsts.iter().find(|(s, _)| *s == seq) {
            let depth = (glass_us - first + interval / 2).div_euclid(interval);
            // A wild report (not a present of this window) is no depth.
            if (0..=16).contains(&depth) {
                if self.depths.len() >= Self::HISTORY {
                    self.depths.pop_front();
                }
                self.depths.push_back(depth);
            }
        }
        let Some(last) = self.last_glass_us else { return };
        if seq > self.last_seq {
            return;
        }
        let estimate = glass_us + i64::try_from(self.last_seq - seq).unwrap_or(0) * interval_us;
        if (estimate - last).abs() <= 3 * interval_us {
            self.last_glass_us = Some(estimate);
        }
    }

    /// The slot the newest present was given and the earliest vsync it could have shown at (us, the timing's epoch), for the
    /// window's per-present log: the glass time that arrives later says how far the model was off.
    pub fn newest_slot(&self) -> Option<(i64, i64)> {
        Some((self.last_glass_us?, self.firsts.back()?.1))
    }

    /// A present (number `seq`) returned at `at_us`; `grid` is a vsync time (any) of the display. Returns the tick for the NEXT present: it
    /// lands one slot after this one, so its frame is chosen for that slot's glass time (`present_us`), with the virtual
    /// tick one refresh before it (the lead is exactly one refresh).
    /// shortcut: without a `grid` (no display link: Windows, Linux) the first slot is the ready time itself, so while the
    /// queue is empty the slots follow the turns' jitter; upgrade with present timestamps from DXGI / Wayland presentation-time.
    pub fn presented(&mut self, seq: u64, at_us: i64, interval_us: i64, grid: Option<i64>) -> DisplayTick {
        let interval = interval_us.max(1);
        let ready = at_us + Self::READY_MARGIN_US;
        let first = match grid {
            Some(g) => {
                g + (ready - g).div_euclid(interval) * interval
                    + if (ready - g).rem_euclid(interval) > 0 { interval } else { 0 }
            }
            None => ready,
        };
        // An idle window (nothing queued for a long time) starts the chain again.
        let chain = self.last_glass_us.filter(|l| *l + interval * STALE_INTERVALS >= at_us).map(|l| l + interval);
        // Without glass times to correct it the chain must not run away: a queue holds a few images, so a slot never lies
        // more than `queue_cap` after the time the image is ready (presents that did not wait for the vsync).
        let glass = chain.map_or(first, |c| c.max(first)).min(first + self.queue_cap() * interval);
        if self.firsts.len() >= Self::HISTORY * 4 {
            self.firsts.pop_front();
        }
        self.firsts.push_back((seq, first));
        self.last_glass_us = Some(glass);
        self.last_seq = seq;
        let next = glass + interval;
        DisplayTick { at_us: next - interval, interval_us: interval, callback_us: 0, present_us: Some(next) }
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

/// While playing, the window loop's timer period as a share of the refresh interval. A timer at exactly the refresh drifts
/// against the vsync, so the CPU runs ahead of the queue and behind it by turns (and with it the glass slot of each frame);
/// slightly faster, the queue stays full and every draw waits for the vsync that frees its drawable.
pub const LOOP_PERIOD_PERCENT: i64 = 98;
/// The same where the display reports real present times (Mac): the timer runs far ahead of the refresh, so the present queue
/// is always full and every draw waits in the acquire for the vsync that frees a drawable. A timer 2 % ahead filled the queue
/// 1 image per 50 refreshes, so each late turn (8 % of them were a whole refresh late) emptied it and the display missed a
/// vsync (run7b: 3 % of the refreshes, and a queue 3 to 5 refreshes deep).
pub const LOOP_PERIOD_SATURATED_PERCENT: i64 = 50;

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

/// Display-synchronized frame counting (mpv's `video-sync=display-*`). Each display refresh moves the video on by exactly
/// one refresh of media time (`interval * rate`); the frame a refresh shows is `floor(video / frame duration)`, so 30 fps on
/// 120 Hz holds every frame 4 refreshes, 60 Hz 2, and 144 Hz the 5/5/5/5/4 pattern of the ratio, whatever the turn times
/// and the clock's noise do. The refreshes are counted from the present slots: a slot that lies two refreshes after the
/// last one counts two (a missed vsync is still elapsed time, the frames after it stay on the grid). The playback clock
/// only corrects the count when it is more than `DRIFT_FRAMES` of a frame away: by one refresh at a time, rarely.
struct RefreshCount {
    /// Media time at refresh 0, and the shift that puts the frame boundaries midway between two refreshes.
    v0: Time,
    phase: Time,
    /// Media time per refresh (negative when playing backward).
    step: Time,
    interval_us: i64,
    rate: PlaybackRate,
    /// The slot time (us) of the last tick, and the refreshes counted up to it.
    last_us: i64,
    count: i64,
}

/// The count follows the clock until it is this far (in 1/100 frames) behind or ahead; farther than `JUMP_FRAMES` frames
/// is a seek or a loop wrap and starts the count again.
const DRIFT_PERCENT: i64 = 50;
const JUMP_FRAMES: i64 = 3;

impl RefreshCount {
    fn start(led: Time, slot_us: i64, interval_us: i64, rate: PlaybackRate) -> RefreshCount {
        let step = scaled(micros(interval_us), rate);
        let half = Time::scaled_int(if step.is_negative() { -step } else { step }, 1, 2);
        // The residual of the start inside a refresh step becomes half a step: the frame boundaries fall between two
        // refreshes, and the shift stays below one step (a frame holds a whole number of refreshes, or the ratio has
        // no phase to keep).
        let abs_step = if step.is_negative() { -step } else { step };
        let residual = led - abs_step * led.frame_index(abs_step);
        // Never behind the clock: the shift is forward, less than one step.
        let mut phase = half - residual;
        while phase < Time::ZERO {
            phase += abs_step;
        }
        while phase >= abs_step {
            phase -= abs_step;
        }
        RefreshCount { v0: led, phase, step, interval_us, rate, last_us: slot_us, count: 0 }
    }

    /// The continuous video position for the refresh whose slot is `slot_us`, for the clock-led position `led`.
    fn sample(
        slot: &mut Option<RefreshCount>,
        led: Time,
        slot_us: i64,
        interval_us: i64,
        rate: PlaybackRate,
        fd: Time,
    ) -> Time {
        let fresh = |slot: &mut Option<RefreshCount>| {
            *slot = Some(RefreshCount::start(led, slot_us, interval_us, rate));
        };
        let steady =
            slot.as_ref().is_some_and(|c| c.rate == rate && (c.interval_us - interval_us).abs() * 50 <= interval_us);
        if !steady {
            fresh(slot);
        }
        let Some(c) = slot.as_mut() else { return led };
        let dp = slot_us - c.last_us;
        c.last_us = slot_us;
        // Slots are not monotone (glass reports pull the chain back, the queue cap can shrink): a step back counts
        // negative refreshes, so the count always equals the net distance. Dropping it while `last_us` moves back
        // would count 10,11,10,11 as 2 refreshes for 1.
        c.count += (dp + c.interval_us / 2).div_euclid(c.interval_us.max(1));
        let video = c.v0 + c.step * c.count + c.phase;
        let drift = led - video;
        let far = if drift.is_negative() { -drift } else { drift };
        if far > fd * JUMP_FRAMES {
            fresh(slot);
            return slot.as_ref().map_or(led, |c| c.v0 + c.phase);
        }
        if far * 100 > fd * DRIFT_PERCENT {
            let one = if c.step.is_negative() { -c.step } else { c.step };
            c.v0 = if drift.is_negative() { c.v0 - one } else { c.v0 + one };
        }
        c.v0 + c.step * c.count + c.phase
    }
}

/// What the engine asks once per loop while playing: the frame position to show.
#[derive(Default)]
pub struct DisplayPacer {
    lead: DisplayLead,
    phase: FramePhaseLock,
    refresh: Option<RefreshCount>,
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
        // A present slot's virtual tick lies ahead of now (negative): the clock then is read forward from now.
        let late = (host_now_us - tick.at_us).clamp(-tick.interval_us * STALE_INTERVALS, tick.interval_us);
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
        // Counting refreshes needs a slot time (a present slot, a display link's present time); the window loop's estimated
        // ticks have none and keep the phase lock.
        let phased = match tick.present_us {
            Some(slot) => RefreshCount::sample(&mut self.refresh, led, slot, tick.interval_us, rate, fd),
            None => self.phase.sample(led, fd, rate.is_reverse()),
        };
        let mut p = fd * phased.frame_index(fd);
        // A frame never flips back one step at a boundary (a seek or a loop wrap moves further than that).
        if let Some(h) = self.held {
            let back = if rate.is_reverse() { p - h } else { h - p };
            if back > Time::ZERO && back <= fd {
                p = h;
            }
        }
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

    // MARK: Window presents through a queue on a fake display (the real-window cadence of 30 fps on 120 Hz was 57 % nominal)

    /// 30 fps played on a display refreshing every `interval_us`, through a window that presents on a jittered timer into a
    /// two-image Fifo queue (what the real window does). `slots`: the engine follows the present slots; otherwise the display
    /// link's ticks (one per vsync, as before). Returns how many vsyncs each timeline frame was on the glass, after the
    /// first two seconds.
    fn glass_holds(interval_us: i64, slots: bool, jitter_us: i64, seed: u64) -> Vec<i64> {
        const PHASE: i64 = 1_234;
        const DRAW_US: i64 = 3_000;
        const QUEUE: usize = 2;
        let mut rng = seed;
        let mut rand = |n: i64| -> i64 {
            rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((rng >> 33) as i64) % n.max(1)
        };
        let end = 20_000_000;
        let (mut pacer, mut ps) = (DisplayPacer::default(), PresentSlots::default());
        let mut slot_tick: Option<DisplayTick> = None;
        let mut published = 0i64;
        let mut glass: Vec<(i64, i64)> = Vec::new(); // (glass time, picture)
        // The UI: next turn time, and a draw in progress (start, end, picture).
        // The loop's timer runs a little faster than the refresh, so the queue fills and the acquire waits for the vsync.
        let timer_interval = interval_us * LOOP_PERIOD_PERCENT / 100;
        let mut turn = 0i64;
        let mut base = 0i64;
        let mut drawing: Option<(i64, i64)> = None; // (present time, picture)
        let mut reported = 0usize;
        let mut now = 0i64;
        while now < end {
            now += 500;
            // Engine thread.
            let link = if now + interval_us >= PHASE {
                let k = (now + interval_us - PHASE) / interval_us;
                Some(DisplayTick {
                    at_us: k * interval_us + PHASE - interval_us,
                    interval_us,
                    callback_us: 0,
                    present_us: Some(k * interval_us + PHASE),
                })
            } else {
                None
            };
            let tick = if slots { slot_tick.or(link) } else { link };
            if tick.is_some() {
                published = pacer.position(tick, now, micros(now), PlaybackRate::FORWARD, FD30).frame_index(FD30);
            }
            // The UI: a draw ends and presents.
            if let Some((at, picture)) = drawing.filter(|(at, _)| *at <= now) {
                let ready = at + 1_000;
                let first = PHASE + (ready - PHASE + interval_us - 1).div_euclid(interval_us) * interval_us;
                let last = glass.last().map_or(i64::MIN / 2, |g| g.0);
                glass.push((first.max(last + interval_us), picture));
                let seq = glass.len() as u64 - 1;
                while reported < glass.len() && glass[reported].0 <= at {
                    ps.glass_seen(reported as u64, glass[reported].0, interval_us);
                    reported += 1;
                }
                slot_tick = Some(ps.presented(seq, at, interval_us, Some(PHASE)));
                drawing = None;
                base += timer_interval;
                turn = (base + rand(2 * jitter_us + 1) - jitter_us).max(now);
            }
            // A turn starts when due and an image is free (the queue blocks the acquire).
            if drawing.is_none() && now >= turn {
                let pending = glass.iter().filter(|g| g.0 > now).count();
                if pending < QUEUE {
                    drawing = Some((now + DRAW_US + rand(2_000), published));
                }
            }
        }
        // The glass: per vsync the image whose slot it is, else the one before.
        let mut shown = Vec::new();
        let mut current = 0;
        let mut next = 0;
        let mut k = 0i64;
        while PHASE + k * interval_us < end - 200_000 {
            let v = PHASE + k * interval_us;
            while next < glass.len() && glass[next].0 <= v {
                current = glass[next].1;
                next += 1;
            }
            if v > 2_000_000 {
                shown.push(current);
            }
            k += 1;
        }
        let mut holds = Vec::new();
        let mut run = 1;
        for w in shown.windows(2) {
            if w[0] == w[1] {
                run += 1;
            } else {
                holds.push(run);
                run = 1;
            }
        }
        holds
    }

    fn nominal_share(holds: &[i64], interval_us: i64) -> f64 {
        let ratio = 1_000_000.0 / 30.0 / interval_us as f64;
        let (lo, hi) = (ratio.floor() as i64, ratio.ceil() as i64);
        holds.iter().filter(|h| (lo..=hi).contains(h)).count() as f64 / holds.len() as f64
    }

    #[test]
    fn thirty_fps_through_a_present_queue_holds_the_nominal_vsync_count() {
        for (name, interval) in [("120 Hz", 8_333), ("60 Hz", 16_667), ("144 Hz", 6_944)] {
            for (seed, jitter) in [(1, 2_500), (2, 2_500), (3, 4_000), (4, 4_000)] {
                let (hs, hl) = (glass_holds(interval, true, jitter, seed), glass_holds(interval, false, jitter, seed));
                let (via_slots, via_link) = (nominal_share(&hs, interval), nominal_share(&hl, interval));
                let hist = |h: &[i64]| {
                    let mut m = std::collections::BTreeMap::new();
                    for x in h {
                        *m.entry(*x).or_insert(0) += 1;
                    }
                    m
                };
                eprintln!(
                    "{name} seed {seed}: present slots {via_slots:.3} {:?}, display link ticks {via_link:.3} {:?}",
                    hist(&hs),
                    hist(&hl)
                );
                assert!(via_slots >= 0.95, "{name} seed {seed}: {via_slots:.3} at the nominal hold");
            }
        }
    }

    #[test]
    fn present_slots_follow_the_vsync_grid_one_per_present_and_restart_after_idle() {
        let mut s = PresentSlots::default();
        let i = 8_333;
        // Presents 3 ms apart (the queue running ahead) still take one slot each.
        assert_eq!(s.newest_slot(), None);
        let a = s.presented(0, 10_000, i, Some(0));
        assert_eq!(
            s.newest_slot(),
            Some((a.present_us.unwrap() - i, 2 * i)),
            "the slot of this present and its earliest vsync"
        );
        let b = s.presented(1, 13_000, i, Some(0));
        let c = s.presented(2, 16_000, i, Some(0));
        assert_eq!(b.present_us.unwrap() - a.present_us.unwrap(), i);
        assert_eq!(c.present_us.unwrap() - b.present_us.unwrap(), i);
        assert_eq!(a.present_us.unwrap() % i, 0, "slots lie on the grid");
        assert_eq!(a.present_us.unwrap() - a.at_us, i, "the lead is one refresh");
        // A present after a long idle starts from its own time, not from the old chain.
        let d = s.presented(3, 5_000_000, i, Some(0));
        assert!(d.present_us.unwrap() - 5_000_000 < 4 * i, "{:?}", d);
    }

    #[test]
    fn a_real_glass_time_corrects_a_chain_that_ran_ahead() {
        let mut s = PresentSlots::default();
        let i = 8_333;
        let mut next = 0;
        for n in 0..6 {
            next = s.presented(n, 10_000 + n as i64 * 3_000, i, Some(0)).present_us.unwrap();
        }
        // The display showed present 3 one slot earlier than the model thought: without the report the next slot would be
        // model + i; with it the chain moves back one slot.
        let model = next;
        s.glass_seen(3, model - 4 * i, i);
        let after = s.presented(6, 28_000, i, Some(0)).present_us.unwrap();
        assert_eq!(after, model, "{after} vs {model}");
        // A wild report is ignored.
        s.glass_seen(2, 99_999_999, i);
    }

    #[test]
    fn without_glass_times_ten_minutes_of_fast_presents_do_not_run_the_slots_away() {
        let mut s = PresentSlots::default();
        let i = 8_333;
        let mut worst = 0;
        // Presents every 3 ms (faster than the refresh, nothing waits for the vsync) for ten minutes, no glass reports.
        for n in 0..200_000u64 {
            let at = 10_000 + n as i64 * 3_000;
            let t = s.presented(n, at, i, Some(0));
            worst = worst.max(t.present_us.unwrap() - at);
        }
        assert!(worst <= 6 * i, "slot {worst} us after its present");
    }

    /// A display that shows one image per vsync from a swap chain holding `depth(n)` images, and reports each
    /// glass time when the display shows it. Returns the share of presents whose predicted slot (made at the present
    /// before) equals the real one, after a warm-up.
    fn queue_run(depth: impl Fn(u64) -> i64) -> f64 {
        let (i, margin) = (8_333_i64, 2_000_i64);
        let mut s = PresentSlots::default();
        let (mut real, mut reported, mut predicted) = (Vec::<i64>::new(), 0usize, None::<i64>);
        let (mut hit, mut total) = (0, 0);
        let mut t = 10_000_i64;
        for n in 0..1_200u64 {
            // The loop turns run at 98 % of the refresh, with a few milliseconds of jitter.
            t += i * 98 / 100 + ((n * 7919) % 5) as i64 * 400 - 800;
            // The swap chain holds back a turn until the image `depth` presents ago has left the glass.
            if let Some(l) = (n as usize).checked_sub(depth(n) as usize).and_then(|k| real.get(k)) {
                t = t.max(*l);
            }
            let first = (t + margin + i - 1).div_euclid(i) * i;
            let after = real.last().map_or(0, |l| l + i);
            real.push(after.max(first));
            if n >= 60 {
                total += 1;
                if predicted == Some(real[n as usize]) {
                    hit += 1;
                }
            }
            // Reports of presents the display showed by now arrive with this present.
            while reported < real.len() && real[reported] <= t {
                s.glass_seen(reported as u64, real[reported], i);
                reported += 1;
            }
            let tick = s.presented(n, t, i, Some(0));
            // `presented` returns the slot of the NEXT present.
            predicted = tick.present_us;
        }
        f64::from(hit) / f64::from(total)
    }

    #[test]
    fn present_slots_match_the_glass_of_a_queue_that_is_four_to_six_images_deep_and_changes_depth() {
        // The queue (images ahead of the glass, so slots after the earliest one) is 3, then 4, then 3 and 5 by turns: the
        // cap of three slots of a run without glass times must not bind once the display reports where images landed.
        let exact = queue_run(|n| {
            if n < 300 {
                4
            } else if n < 700 {
                5
            } else if (n / 60) % 2 == 0 {
                4
            } else {
                6
            }
        });
        assert!(exact >= 0.95, "{exact:.3} of the slots equal the real glass time");
        assert!(queue_run(|_| 6) >= 0.99);
    }

    /// 30 fps through the refresh counter of the pacer on a display of `hz` (its real period is a little longer than the
    /// rounded interval the window reports), with jittered poll times and `missed_per_mille` refreshes the display missed
    /// (their slot jumps two refreshes). Returns the vsync counts of every frame on the glass, and the largest distance
    /// (in frames) between the shown frame's middle and the media time of its refresh.
    fn counted_holds(hz: f64, missed_per_mille: u64, clock_jitter_us: i64, seconds: i64, seed: u64) -> (Vec<i64>, f64) {
        let real = 1e6 / hz;
        let interval = real.round() as i64;
        let mut rng = seed;
        let mut rand = |n: i64| -> i64 {
            rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((rng >> 33) as i64) % n.max(1)
        };
        let mut pacer = DisplayPacer::default();
        let (mut shown, mut worst) = (Vec::new(), 0f64);
        let mut current = 0i64;
        let total = (seconds as f64 * hz) as i64;
        for k in 1..total {
            let glass = (k as f64 * real).round() as i64;
            if k > 60 && rand(1000) < missed_per_mille as i64 {
                // The display missed this refresh: the previous image stays, and no slot is given for it.
                shown.push(current);
                continue;
            }
            let tick =
                DisplayTick { at_us: glass - interval, interval_us: interval, callback_us: 0, present_us: Some(glass) };
            let now = tick.at_us + 500 + rand(interval / 2);
            // The clock reads a few milliseconds off now and then (an audio device that reports in blocks).
            let clock = micros(now + rand(2 * clock_jitter_us + 1) - clock_jitter_us);
            let p = pacer.position(Some(tick), now, clock, PlaybackRate::FORWARD, FD30);
            current = p.frame_index(FD30);
            let middle = FD30 * current + FD30.halved();
            let off = (middle - micros(glass)).value() as f64 / (middle - micros(glass)).timescale() as f64;
            worst = worst.max(off.abs() * 30.0);
            shown.push(current);
        }
        let mut holds = Vec::new();
        let mut run = 1;
        for w in shown[120..].windows(2) {
            if w[0] == w[1] {
                run += 1;
            } else {
                holds.push(run);
                run = 1;
            }
        }
        (holds, worst)
    }

    #[test]
    fn counting_refreshes_holds_every_frame_the_nominal_count_on_120_60_and_144_hz_and_stays_within_a_frame_of_the_clock()
     {
        for hz in [120.0, 60.0, 144.0, 119.88] {
            for seed in 1..=3u64 {
                // Ten minutes, a few missed refreshes (3 in 1000).
                let (holds, worst) = counted_holds(hz, 3, 4_000, 600, seed);
                let share = nominal_share(&holds, (1e6 / hz).round() as i64);
                assert!(share >= 0.98, "{hz} Hz seed {seed}: {share:.4} nominal");
                assert!(worst <= 1.0, "{hz} Hz seed {seed}: the picture is {worst:.2} frames from the clock");
            }
        }
        // No missed refresh: every hold is nominal (4 at 120 Hz).
        let (holds, _) = counted_holds(120.0, 0, 4_000, 60, 9);
        assert!(holds.iter().all(|h| *h == 4), "{:?}", holds.iter().filter(|h| **h != 4).collect::<Vec<_>>());
    }

    fn tabs(t: Time) -> Time {
        if t.is_negative() { -t } else { t }
    }

    fn sample_at(slot: &mut Option<RefreshCount>, slot_us: i64, interval: i64, fd: Time) -> Time {
        RefreshCount::sample(slot, micros(slot_us), slot_us, interval, PlaybackRate::FORWARD, fd)
    }

    #[test]
    fn refresh_count_does_not_double_count_a_chain_that_steps_back() {
        let (iv, fd) = (8_333, FD30);
        let mut slot = None;
        let net = |slots: &[i64], slot: &mut Option<RefreshCount>| {
            for s in slots {
                // The clock is held at the first slot, so only the count moves the position.
                RefreshCount::sample(slot, micros(1_000_000), *s, iv, PlaybackRate::FORWARD, fd);
            }
            slot.as_ref().unwrap().count
        };
        let base = 1_000_000;
        let chain: Vec<i64> = [0, 1, 0, 1, 0, 1, 0, 1].iter().map(|k| base + k * iv).collect();
        assert_eq!(net(&chain, &mut slot), 1, "10,11,10,11 is one refresh");
        let mut slot = None;
        let chain: Vec<i64> = [0, 1, 2, 3, 2, 3, 4].iter().map(|k| base + k * iv).collect();
        assert_eq!(net(&chain, &mut slot), 4);
    }

    #[test]
    fn queue_cap_ignores_one_stall_depth() {
        let mut s = PresentSlots::default();
        for _ in 0..15 {
            s.depths.push_back(3);
        }
        s.depths.push_back(12);
        assert_eq!(s.queue_cap(), 4);
        let empty = PresentSlots::default();
        assert_eq!(empty.queue_cap(), PresentSlots::MAX_QUEUE_SLOTS);
    }

    /// Frame holds (refreshes per frame) of a clip of `fd` on a display of `interval_us`, slots exact, clock = slot time.
    fn holds_of(fd: Time, interval_us: i64, real_us: f64, seconds: i64) -> (Vec<i64>, Time) {
        let mut slot = None;
        let (mut last, mut run, mut holds) = (i64::MIN, 0, Vec::new());
        let n = (seconds as f64 * 1e6 / real_us) as i64;
        let mut off = Time::ZERO;
        for k in 0..n {
            let t = (k as f64 * real_us).round() as i64 + 5_000_000;
            let v = sample_at(&mut slot, t, interval_us, fd);
            let f = v.frame_index(fd);
            assert!(f >= last, "frame went back at refresh {k}");
            if f == last {
                run += 1;
            } else {
                if last != i64::MIN && k > 120 {
                    holds.push(run);
                }
                run = 1;
                last = f;
            }
            off = v - micros(t);
        }
        (holds, off)
    }

    #[test]
    fn refresh_count_holds_the_nominal_count_for_film_rates_on_60_and_120_hz() {
        let cases: [(Time, f64, i64); 6] = [
            (Time::new(1001, 24_000), 120.0, 5),
            (Time::new(1, 25), 120.0, 4),
            (Time::new(1001, 30_000), 120.0, 4),
            (Time::new(1001, 24_000), 60.0, 2),
            (Time::new(1, 25), 60.0, 2),
            (Time::new(1001, 30_000), 60.0, 2),
        ];
        for (fd, hz, base) in cases {
            let real = 1e6 / hz;
            let (holds, _) = holds_of(fd, real.round() as i64, real, 120);
            let ratio = (fd.value() as f64 / fd.timescale() as f64) * hz;
            let lo = ratio.floor() as i64;
            assert!(lo == base || lo + 1 == base || ratio.fract() > 0.0, "case table");
            let ok = holds.iter().filter(|h| **h == lo || **h == lo + 1).count();
            assert!(
                ok == holds.len(),
                "{fd:?} at {hz} Hz: holds off {lo}/{}: {:?}",
                lo + 1,
                holds.iter().filter(|h| **h != lo && **h != lo + 1).collect::<Vec<_>>()
            );
            if ratio.fract() == 0.0 {
                assert!(holds.iter().all(|h| *h == lo));
            }
        }
    }

    #[test]
    fn refresh_count_follows_a_clock_whose_interval_was_truncated() {
        // 8333.33 us is truncated to 8333: ten minutes later the video is still within one frame of the clock.
        let (_, off) = holds_of(FD30, 8_333, 1e6 / 120.0, 600);
        assert!(tabs(off) < FD30, "{off:?}");
    }

    #[test]
    fn refresh_count_restarts_on_a_120_to_60_hz_change_a_seek_and_a_pause() {
        let fd = FD30;
        let mut slot = None;
        for k in 0..60 {
            sample_at(&mut slot, 1_000_000 + k * 8_333, 8_333, fd);
        }
        // 120 -> 60 Hz: the interval changed by far more than 2 %: a fresh count, no jump of the picture.
        let t = 1_000_000 + 60 * 8_333;
        let v = sample_at(&mut slot, t, 16_667, fd);
        assert_eq!(slot.as_ref().unwrap().count, 0);
        assert!(tabs(v - micros(t)) <= fd);
        // A seek (the clock far from the count): restarts at the clock.
        let seek = micros(90_000_000);
        let v = RefreshCount::sample(&mut slot, seek, t + 16_667, 16_667, PlaybackRate::FORWARD, fd);
        assert!(tabs(v - seek) <= fd);
        // A pause of a second, then resume at the same clock position: counts one second of refreshes only if the clock moved.
        let resumed = RefreshCount::sample(&mut slot, seek, t + 1_016_667, 16_667, PlaybackRate::FORWARD, fd);
        assert!(tabs(resumed - seek) <= fd, "{resumed:?}");
    }
}
