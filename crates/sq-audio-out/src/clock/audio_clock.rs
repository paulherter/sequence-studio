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

fn ms(t: Time) -> i64 {
    i64::try_from(i128::from(t.value()) * 1000 / i128::from(t.timescale())).unwrap_or(0)
}

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
    /// Free run: while the output has not acknowledged the flush, the position follows the host time from
    /// `free_origin`, starting `free_lead` ns after the restart (see `AudioClock::PRIMING_BUDGET_NANOS`).
    free_origin: Time,
    free_lead: i64,
    /// The picture already moved on host time before the audio was acknowledged: the audio must be re-seeked.
    free_ran: bool,
    /// The audio was re-seeked once after a free run (never twice per restart).
    resynced: bool,
    resync_pending: bool,
    /// Counts restarts: a re-seek decided for an older restart is dropped.
    restart_count: u64,
    /// Feeder latency M (frames) seen at the first flush of the restart, to aim the re-seek.
    latency_hint: i64,
    /// After a re-seek: the audio clock took over; the picture is slewed onto it (`slew0` = picture ahead of audio in
    /// the direction of travel at the takeover, shrinking by 1/5 of the audio time elapsed since `slew_e0`).
    took_over: bool,
    slew0: Time,
    slew_e0: Time,
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
    /// output is priming with silence (a Bluetooth or HDMI device can need seconds): that is not a stall yet. It no
    /// longer holds the picture (`PRIMING_BUDGET_NANOS`), it only decides when the audio is given up for this Play.
    pub const PRIMING_TIMEOUT_NANOS: i64 = 5_000_000_000;
    /// How long the picture waits for the first audio block of a restart before it runs on the host time instead
    /// (rule: pre-roll up to 0.5 s, then instant). Normal outputs acknowledge a flush in 10-100 ms (WASAPI
    /// shared, CoreAudio, ALSA/Pulse with a 10-20 ms period), so they never reach it; 250 ms leaves the other half of
    /// the 0.5 s for the first decode. A slow device (Bluetooth or HDMI waking up, a virtual sink) then is re-seeked
    /// to the picture position once it consumes (`resync`), so picture and sound end up together.
    pub const PRIMING_BUDGET_NANOS: i64 = 250_000_000;
    /// Guess for the delay between a re-seek and the first block the awake device consumes (one callback period).
    const ACK_GUESS_NANOS: i64 = 20_000_000;

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
                    free_origin: Time::ZERO,
                    free_lead: Self::PRIMING_BUDGET_NANOS,
                    free_ran: false,
                    resynced: false,
                    resync_pending: false,
                    restart_count: 0,
                    latency_hint: 0,
                    took_over: false,
                    slew0: Time::ZERO,
                    slew_e0: Time::ZERO,
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

    #[cfg(test)]
    pub(super) fn restart_count(&self) -> u64 {
        lock(&self.state).restart_count
    }

    /// Position plus the watchdog verdict, from one reading.
    pub fn sample(&self) -> (Time, bool) {
        let ns = self.audio.host_nanoseconds();
        let mut s = lock(&self.state);
        let p = self.position(&mut s, ns);
        let pending = std::mem::take(&mut s.resync_pending).then_some(s.restart_count);
        let limit = if s.base.is_none() { Self::PRIMING_TIMEOUT_NANOS } else { Self::STALL_TIMEOUT_NANOS };
        // Reverse play that consumed everything down to frame 0 has nothing left to render: that is the end, not a stall.
        let stalled = !s.rate.is_paused()
            && s.generation != IN_FLIGHT
            && s.exhaust_nanos.is_none()
            && ns - s.progress_nanos > limit;
        drop(s);
        if let Some(count) = pending {
            self.resync(count);
        }
        (p, stalled)
    }

    /// The output started consuming after the picture had run on host time: restart the audio at the picture position
    /// (plus the output latency, so it is heard where the picture is by then). The picture keeps running on its host
    /// line meanwhile; the audio clock takes over at its acknowledgement. Skipped when a control call is busy (the
    /// render thread never waits for one) and retried by the next sample.
    pub(super) fn resync(&self, count: u64) {
        let Ok(_control) = self.control.try_lock() else {
            let mut s = lock(&self.state);
            if s.restart_count == count {
                s.resync_pending = true;
            }
            return;
        };
        let (p, r, hint) = {
            let s = lock(&self.state);
            // `restart_count` drops a decision that a start/seek/rate change/stop overtook between `sample` and here.
            if s.restart_count != count
                || !s.free_ran
                || s.rate.is_paused()
                || s.generation == IN_FLIGHT
                || s.resynced
                || s.base.is_some()
            {
                return;
            }
            (s.last_returned.unwrap_or(s.anchor), s.rate, s.latency_hint)
        };
        // Aim the audio at where the picture will be when it is heard: output latency, feeder latency and a guess for
        // the first block of the awake device. The remaining error is slewed out after the takeover.
        let mag = r.magnitude();
        let lead = scaled(self.audio.output_latency(), mag)
            + Time::new(hint, self.sample_rate)
            + scaled(Time::new(Self::ACK_GUESS_NANOS, 1_000_000_000), mag);
        let at = if r.is_reverse() { (p - lead).max(Time::ZERO) } else { p + lead };
        self.restart_at(at, r, Some(p));
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
        self.restart_at(position, rate, None);
    }

    /// `resync_from` = the picture position of a re-seek after a free run (the picture keeps running from there).
    fn restart_at(&self, position: Time, rate: PlaybackRate, resync_from: Option<Time>) {
        let was_running = {
            let mut s = lock(&self.state);
            let running = !s.rate.is_paused();
            s.anchor = position;
            s.rate = rate;
            s.base = None;
            s.last_returned = resync_from;
            s.exhaust_nanos = None;
            s.free_origin = resync_from.unwrap_or(position);
            s.free_lead = if resync_from.is_some() { 0 } else { Self::PRIMING_BUDGET_NANOS };
            s.free_ran = false;
            s.resynced = resync_from.is_some();
            s.resync_pending = false;
            s.took_over = false;
            s.restart_count += 1;
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

    /// Position while the audio is not acknowledged: held at the origin for the priming budget, then running on the
    /// host time (never backwards).
    fn free_line(s: &mut State, nanos: i64) -> Time {
        let d = nanos - s.restart_nanos - s.free_lead;
        if d <= 0 {
            return s.last_returned.unwrap_or(s.anchor);
        }
        if !s.resynced {
            if !s.free_ran {
                eprintln!(
                    "sq-audio: audio not consuming after {} ms, picture runs on the host clock",
                    s.free_lead / 1_000_000
                );
            }
            s.free_ran = true;
        }
        let mag = s.rate.magnitude();
        let elapsed = scaled(Time::new(d, 1_000_000_000), mag);
        let mut p =
            if s.rate.is_reverse() { (s.free_origin - elapsed).max(Time::ZERO) } else { s.free_origin + elapsed };
        if let Some(last) = s.last_returned {
            p = if s.rate.is_reverse() { p.min(last) } else { p.max(last) };
        }
        s.last_returned = Some(p);
        p
    }

    fn position(&self, s: &mut State, nanos: i64) -> Time {
        if s.rate.is_paused() {
            return s.anchor;
        }
        if s.generation == IN_FLIGHT {
            return s.last_returned.unwrap_or(s.anchor);
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
                    return Self::free_line(s, nanos); // feeder has not flushed yet
                }
                let (ack_epoch, ack_frames) = self.audio.consumed_at_epoch();
                if ack_epoch < f.epoch {
                    return Self::free_line(s, nanos); // consumer has not applied the flush
                }
                if s.free_ran && !s.resynced {
                    s.latency_hint = f.latency;
                    s.resync_pending = true;
                    return Self::free_line(s, nanos);
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
        // After a re-seek the audio line may still be behind the picture (elapsed < 0); the takeover happens now and
        // the difference is slewed out, so the picture neither stands still nor jumps.
        if elapsed <= Time::ZERO && !s.resynced {
            return s.last_returned.unwrap_or(s.anchor);
        }
        let rev = s.rate.is_reverse();
        let raw = if rev { (s.anchor - elapsed).max(Time::ZERO) } else { s.anchor + elapsed };
        let mut p = raw;
        if s.resynced {
            if !s.took_over {
                s.took_over = true;
                // Continue on the host line of this very call, so the takeover sample moves like the ones before it.
                let d = (nanos - s.restart_nanos - s.free_lead).max(0);
                let el = scaled(Time::new(d, 1_000_000_000), mag);
                let host_line = if rev { (s.free_origin - el).max(Time::ZERO) } else { s.free_origin + el };
                let last = s.last_returned.map_or(host_line, |l| if rev { l.min(host_line) } else { l.max(host_line) });
                s.slew0 = if rev { raw - last } else { last - raw };
                s.slew_e0 = elapsed;
                eprintln!(
                    "sq-audio: clock host -> audio takeover at {} ms host time, picture {:+} ms vs audio",
                    nanos / 1_000_000,
                    ms(s.slew0)
                );
            }
            let since = (elapsed - s.slew_e0).max(Time::ZERO);
            let c = Time::new(since.value(), since.timescale().saturating_mul(5));
            let d = if s.slew0 > Time::ZERO { (s.slew0 - c).max(Time::ZERO) } else { (s.slew0 + c).min(Time::ZERO) };
            p = if rev { (raw - d).max(Time::ZERO) } else { raw + d };
        }
        if let Some(last) = s.last_returned {
            p = if rev { p.min(last) } else { p.max(last) };
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
            s.resync_pending = false;
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
