// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioClock.swift
//! Audio master clock: the position is derived from the frames the audio output actually consumed.
//!
//! `position = anchor + direction x max(0, (heard - base - M) / sample_rate - output_latency x |rate|)`
//! where `base` = the `consumed_at_epoch` frames of the flush that started this anchor, `M` = the feeder latency published
//! with that flush (`flushed().latency`) and `heard` interpolates between render calls: the last call's first frame plus
//! `|rate| x sample_rate x (host now - call time)`, clamped to the frames that call consumed (`last_render`). So `now()`
//! moves smoothly instead of in callback-sized steps, and it never runs backwards within an anchor (mirrored in reverse).
//! Until the flush is acknowledged by the consumer (and the first audible sample has left the output) the clock holds at
//! the anchor: video waits for audio, never runs ahead. Arithmetic is exact rational on the 48 kHz grid; the only
//! roundings are the hardware latency measurement and the interpolation (whole frames). The call times in the stamp are
//! already delay-locked smoothed by the output (see `StampSmoother`).
//!
//! Drives its `AudioPlaying`: `start`/`set_rate`/`seek` while running restart the feeder at the new anchor (flush + 5 ms
//! crossfade), `stop` fades the output out. A seek while paused only moves the anchor; the next `start` restarts.
//! Control calls are serialized by their own lock and call the audio object outside the state lock, so `now()` (render
//! thread) only ever waits for short state updates.
//!
//! Watchdog: `sample()` reports `stalled` when running and no render call consumed audio for the stall timeout.

use super::{AudioPlaying, PlaybackClock, lock, scaled};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::{Arc, Mutex, Weak};

/// Generation sentinel while a restart is in flight.
const IN_FLIGHT: i64 = i64::MAX;

#[derive(Clone, Copy)]
struct State {
    anchor: Time,
    rate: PlaybackRate,
    /// Feeder generation of the current anchor (`IN_FLIGHT` while a restart is in flight).
    generation: i64,
    /// `consumed_at_epoch` frames of its flush, once acknowledged.
    base: Option<i64>,
    /// M valid for that flush.
    latency: i64,
    /// Snapshot at the restart.
    output_latency: Time,
    restart_nanos: i64,
    seen_frames: i64,
    progress_nanos: i64,
    /// Monotonic guard within one anchor.
    last_returned: Option<Time>,
    /// Reverse: host time at which the audio down to the timeline start was all consumed.
    exhaust_nanos: Option<i64>,
}

pub struct AudioClock {
    state: Mutex<State>,
    control: Mutex<()>,
    audio: Arc<dyn AudioPlaying>,
    sample_rate: i64,
}

impl AudioClock {
    pub const STALL_TIMEOUT_NANOS: i64 = 250_000_000;
    /// Before the first audio of a restart was consumed the feeder may still be opening a cold or network file and the
    /// output is priming with silence: that is not a stall yet.
    pub const PRIMING_TIMEOUT_NANOS: i64 = 2_000_000_000;

    pub fn new(audio: Arc<dyn AudioPlaying>) -> Arc<AudioClock> {
        let sample_rate = audio.sample_rate();
        Arc::new_cyclic(|weak: &Weak<AudioClock>| {
            let w = Weak::clone(weak);
            audio.set_restart_handler(Some(Arc::new(move || {
                if let Some(c) = w.upgrade() {
                    c.reanchor();
                }
            })));
            AudioClock {
                state: Mutex::new(State {
                    anchor: Time::ZERO,
                    rate: PlaybackRate::ZERO,
                    generation: 0,
                    base: None,
                    latency: 0,
                    output_latency: Time::ZERO,
                    restart_nanos: 0,
                    seen_frames: 0,
                    progress_nanos: 0,
                    last_returned: None,
                    exhaust_nanos: None,
                }),
                control: Mutex::new(()),
                audio,
                sample_rate,
            }
        })
    }

    pub fn audio(&self) -> &Arc<dyn AudioPlaying> {
        &self.audio
    }

    /// Position plus the watchdog verdict, from one reading.
    pub fn sample(&self) -> (Time, bool) {
        let ns = self.audio.host_nanoseconds();
        let mut s = lock(&self.state);
        let p = self.position(&mut s, ns);
        let limit = if s.base.is_none() { Self::PRIMING_TIMEOUT_NANOS } else { Self::STALL_TIMEOUT_NANOS };
        // Reverse play that consumed everything down to frame 0 has nothing left to render: that is the end, not a stall.
        let stalled = !s.rate.is_paused()
            && s.generation != IN_FLIGHT
            && s.exhaust_nanos.is_none()
            && ns - s.progress_nanos > limit;
        (p, stalled)
    }

    /// Output restarted underneath (device change): re-seek at the current position, keeping the rate.
    pub fn reanchor(&self) {
        let _control = lock(&self.control);
        let r = lock(&self.state).rate;
        if r.is_paused() {
            return;
        }
        self.restart(self.now(), r);
    }

    /// Under `control`. The audio calls run outside `state`; meanwhile the clock holds at the new anchor.
    fn restart(&self, position: Time, rate: PlaybackRate) {
        let was_running = {
            let mut s = lock(&self.state);
            let running = !s.rate.is_paused();
            s.anchor = position;
            s.rate = rate;
            s.base = None;
            s.last_returned = None;
            s.exhaust_nanos = None;
            s.generation = IN_FLIGHT;
            running
        };
        if rate.is_paused() {
            lock(&self.state).generation = 0;
            if was_running {
                self.audio.stop();
            }
            return;
        }
        self.audio.set_rate(rate);
        let gen_ = self.audio.seek(position);
        self.audio.start();
        let latency = self.audio.output_latency();
        let ns = self.audio.host_nanoseconds();
        let stamp = self.audio.last_render();
        let mut s = lock(&self.state);
        s.generation = gen_;
        s.output_latency = latency;
        s.restart_nanos = ns;
        s.progress_nanos = ns;
        s.seen_frames = stamp.frames;
    }

    fn position(&self, s: &mut State, nanos: i64) -> Time {
        if s.rate.is_paused() || s.generation == IN_FLIGHT {
            return s.anchor;
        }
        let stamp = self.audio.last_render();
        if stamp.frames != s.seen_frames {
            s.seen_frames = stamp.frames;
            s.progress_nanos = stamp.host_nanos.max(s.restart_nanos);
        }
        let base = match s.base {
            Some(b) => b,
            None => {
                let f = self.audio.flushed();
                if f.generation < s.generation {
                    return s.anchor; // feeder has not flushed yet
                }
                let (ack_epoch, ack_frames) = self.audio.consumed_at_epoch();
                if ack_epoch < f.epoch {
                    return s.anchor; // consumer has not applied the flush
                }
                s.base = Some(ack_frames);
                s.latency = f.latency;
                ack_frames
            }
        };
        let mag = s.rate.magnitude();
        let consumed = self.audio.consumed_frames();
        let mut heard = consumed;
        if stamp.frames == consumed && stamp.quantum > 0 {
            heard = consumed - stamp.quantum;
            let dt = nanos - stamp.host_nanos;
            if dt > 0 {
                let f = i128::from(dt) * i128::from(mag.num()) * i128::from(self.sample_rate)
                    / (i128::from(mag.den()) * 1_000_000_000);
                heard += stamp.quantum.min(i64::try_from(f).unwrap_or(i64::MAX));
            }
        }
        // Reverse: the feeder produces nothing below frame 0, so after the audio from the anchor down to the start was all
        // consumed nothing more is rendered, and the output latency would keep the position above frame 0 forever (the
        // watchdog would fail the audio). From then on the clock keeps running on host time for the rest of the latency:
        // it decays to 0 exactly when the last audio is heard.
        let mut extra = Time::ZERO;
        if s.rate.is_reverse() {
            // frames from the anchor down to 0 (floor)
            let total = i64::try_from(
                i128::from(s.anchor.value()) * i128::from(self.sample_rate) / i128::from(s.anchor.timescale()),
            )
            .unwrap_or(i64::MAX);
            if heard - base >= total {
                heard = base + total;
                let exhaust = *s.exhaust_nanos.get_or_insert(nanos);
                extra = scaled(Time::new((nanos - exhaust).max(0), 1_000_000_000), mag);
            }
        }
        let elapsed = Time::new(heard - base - s.latency, self.sample_rate) - scaled(s.output_latency, mag) + extra;
        if elapsed <= Time::ZERO {
            return s.anchor;
        }
        let mut p = if s.rate.is_reverse() { (s.anchor - elapsed).max(Time::ZERO) } else { s.anchor + elapsed };
        if let Some(last) = s.last_returned {
            p = if s.rate.is_reverse() { p.min(last) } else { p.max(last) };
        }
        s.last_returned = Some(p);
        p
    }
}

impl PlaybackClock for AudioClock {
    fn now(&self) -> Time {
        self.sample().0
    }

    fn rate(&self) -> PlaybackRate {
        lock(&self.state).rate
    }

    fn start(&self, position: Time, rate: PlaybackRate) {
        let _control = lock(&self.control);
        self.restart(position, rate);
    }

    fn stop(&self) -> Time {
        let _control = lock(&self.control);
        let ns = self.audio.host_nanoseconds();
        let (p, was_running) = {
            let mut s = lock(&self.state);
            let p = self.position(&mut s, ns);
            let running = !s.rate.is_paused();
            s.anchor = p;
            s.rate = PlaybackRate::ZERO;
            s.base = None;
            s.last_returned = None;
            s.exhaust_nanos = None;
            (p, running)
        };
        if was_running {
            self.audio.stop();
        }
        p
    }

    fn set_rate(&self, rate: PlaybackRate) {
        let _control = lock(&self.control);
        if rate == lock(&self.state).rate {
            return;
        }
        self.restart(self.now(), rate);
    }

    fn seek(&self, position: Time) {
        let _control = lock(&self.control);
        let r = lock(&self.state).rate;
        if r.is_paused() {
            let mut s = lock(&self.state);
            s.anchor = position;
            s.last_returned = None;
        } else {
            self.restart(position, r);
        }
    }
}

struct Current {
    audio_active: bool,
    audio_failed: bool,
}

/// The engine's clock: forwards to the host clock or the audio clock and hands the position over on a switch.
/// Control calls and switches are serialized (`ops`), so a `stop`/`seek` from the render thread never lands on a clock
/// that is being switched away. `now()` falls back to the host clock when the audio clock's watchdog reports a stall
/// (`audio_failed` is set until `clear_audio_failure()`).
pub struct SwitchingClock {
    current: Mutex<Current>,
    ops: Mutex<()>,
    host: Arc<dyn PlaybackClock>,
    audio: Option<Arc<AudioClock>>,
}

impl SwitchingClock {
    pub fn new(host: Arc<dyn PlaybackClock>, audio: Option<Arc<AudioClock>>) -> SwitchingClock {
        SwitchingClock {
            current: Mutex::new(Current { audio_active: false, audio_failed: false }),
            ops: Mutex::new(()),
            host,
            audio,
        }
    }

    pub fn is_audio(&self) -> bool {
        lock(&self.current).audio_active
    }

    pub fn audio_failed(&self) -> bool {
        lock(&self.current).audio_failed
    }

    pub fn clear_audio_failure(&self) {
        lock(&self.current).audio_failed = false;
    }

    fn active(&self) -> Arc<dyn PlaybackClock> {
        match (&self.audio, lock(&self.current).audio_active) {
            (Some(a), true) => Arc::clone(a) as Arc<dyn PlaybackClock>,
            _ => Arc::clone(&self.host),
        }
    }

    /// Makes the audio clock (true) or the host clock (false) active, continuing at the old clock's position and rate.
    pub fn use_audio(&self, on: bool) {
        let _ops = lock(&self.ops);
        let Some(audio) = &self.audio else { return };
        if lock(&self.current).audio_active == on {
            return;
        }
        let (from, to): (Arc<dyn PlaybackClock>, Arc<dyn PlaybackClock>) = if on {
            (Arc::clone(&self.host), Arc::clone(audio) as Arc<dyn PlaybackClock>)
        } else {
            (Arc::clone(audio) as Arc<dyn PlaybackClock>, Arc::clone(&self.host))
        };
        let r = from.rate();
        let p = from.stop();
        to.start(p, r);
        lock(&self.current).audio_active = on;
    }
}

impl PlaybackClock for SwitchingClock {
    fn now(&self) -> Time {
        let Some(a) = self.audio.as_ref().filter(|_| lock(&self.current).audio_active) else {
            return self.active().now();
        };
        let (p, stalled) = a.sample();
        if !stalled {
            return p;
        }
        let _ops = lock(&self.ops);
        if !lock(&self.current).audio_active {
            return self.host.now();
        }
        let r = a.rate();
        let at = a.stop();
        self.host.start(at, r);
        let mut c = lock(&self.current);
        c.audio_active = false;
        c.audio_failed = true;
        at
    }

    fn rate(&self) -> PlaybackRate {
        self.active().rate()
    }

    fn start(&self, position: Time, rate: PlaybackRate) {
        let _ops = lock(&self.ops);
        // Play retries the audio after a stall (Swift `PlaybackEngine.play`: clearAudioFailure, then back to the audio
        // clock). Without it one slow file open on the mix thread left the rest of the session silent.
        if !rate.is_paused() && self.audio.is_some() {
            let retry = {
                let mut c = lock(&self.current);
                let retry = c.audio_failed && !c.audio_active;
                if retry {
                    c.audio_failed = false;
                    c.audio_active = true;
                }
                retry
            };
            if retry {
                self.host.stop();
            }
        }
        self.active().start(position, rate);
    }

    fn stop(&self) -> Time {
        let _ops = lock(&self.ops);
        self.active().stop()
    }

    fn set_rate(&self, rate: PlaybackRate) {
        let _ops = lock(&self.ops);
        self.active().set_rate(rate);
    }

    fn seek(&self, position: Time) {
        let _ops = lock(&self.ops);
        self.active().seek(position);
    }
}
