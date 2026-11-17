// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Clock.swift
//! Timeline clock. Positions are rational `Time`; no floating point anywhere in the API.
//!
//! Model: a clock holds an anchor `(position, elapsed-at-anchor)` and a rate. `now()` is
//! `anchor_position + (elapsed - anchor_elapsed) * rate`, evaluated exactly in rational arithmetic. Changing the rate,
//! seeking, starting or stopping re-anchors, so position is always continuous across a rate change and `now()` never jumps.

use super::lock;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

/// A playback clock. Safe to call from any thread.
pub trait PlaybackClock: Send + Sync {
    /// Current timeline position (not snapped).
    fn now(&self) -> Time;
    fn rate(&self) -> PlaybackRate;
    /// Re-anchors at `position` and runs at `rate` (rate 0 holds the position).
    fn start(&self, position: Time, rate: PlaybackRate);
    /// Holds the clock (rate 0) and returns the position where it stopped.
    fn stop(&self) -> Time;
    /// Keeps the current position, continues at `rate`. Atomic re-anchor.
    fn set_rate(&self, rate: PlaybackRate);
    /// Jumps to `position`, keeping the current rate. Atomic re-anchor.
    fn seek(&self, position: Time);
}

/// Monotonic host time in nanoseconds since the first call in this process (same base for every caller). Real-time
/// safe: one clock read, no allocation after the first call.
pub fn host_nanos_now() -> i64 {
    static BASE: OnceLock<Instant> = OnceLock::new();
    i64::try_from(BASE.get_or_init(Instant::now).elapsed().as_nanos()).unwrap_or(i64::MAX)
}

/// `delta * rate`, exact. Rational product reduced by `Time`'s normalizing constructor.
pub fn scaled(delta: Time, rate: PlaybackRate) -> Time {
    if rate.num() == 0 || delta.value() == 0 {
        return Time::ZERO;
    }
    Time::scaled_int(delta, i64::from(rate.num()), i64::from(rate.den()))
}

/// Rounds `t` to the nearest multiple of 1/`timescale` (ties away from zero). Explicit, documented rounding.
pub fn rounded(t: Time, timescale: i64) -> Time {
    let n = i128::from(t.value()) * i128::from(timescale);
    let d = i128::from(t.timescale());
    let half = d / 2;
    let q = if n >= 0 { (n + half) / d } else { -((-n + half) / d) };
    Time::new(i64::try_from(q).unwrap_or(i64::MAX), timescale)
}

/// Anchor position, elapsed time at the anchor, rate.
#[derive(Clone, Copy)]
struct Anchor {
    position: Time,
    elapsed_at_anchor: Time,
    rate: PlaybackRate,
}

impl Anchor {
    const fn zero() -> Anchor {
        Anchor { position: Time::ZERO, elapsed_at_anchor: Time::ZERO, rate: PlaybackRate::ZERO }
    }

    fn position_at(&self, elapsed: Time) -> Time {
        self.position + scaled(elapsed - self.elapsed_at_anchor, self.rate)
    }
}

/// Test clock: time only moves when `advance` is called. Fully exact.
pub struct ManualClock {
    state: Mutex<(Anchor, Time)>,
}

impl ManualClock {
    pub fn new(position: Time, rate: PlaybackRate) -> ManualClock {
        ManualClock { state: Mutex::new((Anchor { position, elapsed_at_anchor: Time::ZERO, rate }, Time::ZERO)) }
    }

    /// Advances wall time by `delta` (>= 0). Position moves by `delta * rate`. Panics for a negative delta.
    pub fn advance(&self, delta: Time) {
        assert!(!delta.is_negative(), "ManualClock cannot run backwards in wall time");
        lock(&self.state).1 += delta;
    }
}

impl Default for ManualClock {
    fn default() -> ManualClock {
        ManualClock::new(Time::ZERO, PlaybackRate::ZERO)
    }
}

impl PlaybackClock for ManualClock {
    fn now(&self) -> Time {
        let s = lock(&self.state);
        s.0.position_at(s.1)
    }

    fn rate(&self) -> PlaybackRate {
        lock(&self.state).0.rate
    }

    fn start(&self, position: Time, rate: PlaybackRate) {
        let mut s = lock(&self.state);
        s.0 = Anchor { position, elapsed_at_anchor: s.1, rate };
    }

    fn stop(&self) -> Time {
        let mut s = lock(&self.state);
        let p = s.0.position_at(s.1);
        s.0 = Anchor { position: p, elapsed_at_anchor: s.1, rate: PlaybackRate::ZERO };
        p
    }

    fn set_rate(&self, rate: PlaybackRate) {
        let mut s = lock(&self.state);
        let p = s.0.position_at(s.1);
        s.0 = Anchor { position: p, elapsed_at_anchor: s.1, rate };
    }

    fn seek(&self, position: Time) {
        let mut s = lock(&self.state);
        s.0 = Anchor { position, elapsed_at_anchor: s.1, rate: s.0.rate };
    }
}

const NS_SCALE: i64 = 1_000_000_000;

/// Wall-clock based clock on a monotonic host time source.
///
/// Exactness: the source is integer nanoseconds, the elapsed time the exact rational `ns / 1e9`, and `now()` exact
/// rational arithmetic from there. The only rounding: when the clock re-anchors mid-run (`set_rate`, `stop`) the scaled
/// elapsed delta (elapsed ns x rate) is rounded to the nearest nanosecond (|error| <= 0.5 ns); the anchor position itself
/// stays exact, and a paused clock is never rounded. `start` and `seek` keep the caller's position exactly.
pub struct HostClock {
    state: Mutex<Anchor>,
    nanoseconds: Arc<dyn Fn() -> i64 + Send + Sync>,
}

impl HostClock {
    pub fn new() -> HostClock {
        HostClock::with_source(Arc::new(host_nanos_now))
    }

    /// Test seam: injectable monotonic nanosecond source.
    pub fn with_source(source: Arc<dyn Fn() -> i64 + Send + Sync>) -> HostClock {
        HostClock { state: Mutex::new(Anchor::zero()), nanoseconds: source }
    }

    fn elapsed(&self) -> Time {
        Time::new((self.nanoseconds)(), NS_SCALE)
    }

    /// Re-anchor position: the anchor stays exact; only the scaled elapsed delta is rounded to 1 ns, and not at all while
    /// paused (the delta is zero then).
    fn reanchored_position(a: &Anchor, at: Time) -> Time {
        a.position + rounded(scaled(at - a.elapsed_at_anchor, a.rate), NS_SCALE)
    }

    // The tick is read inside the lock in every method, so ticks are observed in lock order and a concurrent re-anchor
    // can never make `now()` go backwards.
}

impl Default for HostClock {
    fn default() -> HostClock {
        HostClock::new()
    }
}

impl PlaybackClock for HostClock {
    fn now(&self) -> Time {
        let s = lock(&self.state);
        s.position_at(self.elapsed())
    }

    fn rate(&self) -> PlaybackRate {
        lock(&self.state).rate
    }

    fn start(&self, position: Time, rate: PlaybackRate) {
        let mut s = lock(&self.state);
        *s = Anchor { position, elapsed_at_anchor: self.elapsed(), rate };
    }

    fn stop(&self) -> Time {
        let mut s = lock(&self.state);
        let e = self.elapsed();
        let p = Self::reanchored_position(&s, e);
        *s = Anchor { position: p, elapsed_at_anchor: e, rate: PlaybackRate::ZERO };
        p
    }

    fn set_rate(&self, rate: PlaybackRate) {
        let mut s = lock(&self.state);
        let e = self.elapsed();
        let p = Self::reanchored_position(&s, e);
        *s = Anchor { position: p, elapsed_at_anchor: e, rate };
    }

    fn seek(&self, position: Time) {
        let mut s = lock(&self.state);
        *s = Anchor { position, elapsed_at_anchor: self.elapsed(), rate: s.rate };
    }
}
