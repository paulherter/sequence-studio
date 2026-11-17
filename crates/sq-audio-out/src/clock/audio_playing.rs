// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioPlaying.swift (the portable subset; timeline, meter, scrub and channel monitor belong to the feeder, task A2)
//! Audio output as seen by `AudioClock` and the playback engine.

use super::lock;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::{Arc, Mutex};

/// The last render call that consumed audio: `frames` = frames consumed after it, `quantum` = frames it consumed and
/// `host_nanos` = the host time (`host_nanoseconds()` base) when it ran. The clock interpolates between calls with it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioRenderStamp {
    pub frames: i64,
    pub quantum: i64,
    pub host_nanos: i64,
}

/// Feeder flush bookkeeping: generation applied, ring epoch issued for it, `latency` frames valid from it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Flushed {
    pub generation: i64,
    pub epoch: i64,
    pub latency: i64,
}

/// Handler called (any thread, no locks held) after the output was restarted underneath, e.g. a device change.
pub type RestartHandler = Arc<dyn Fn() + Send + Sync>;

/// Audio output as seen by `AudioClock`. `AudioOut` is the real implementation (cpal); `ManualAudio` models the
/// feeder/ring protocol for headless tests.
///
/// Only `AudioClock` should call `set_rate`/`seek`/`start`/`stop` while it is the engine's clock: it owns the anchor and
/// relies on every flush being one it requested.
pub trait AudioPlaying: Send + Sync {
    /// Mixer rate (48 kHz): the rate of `consumed_frames` and of the feeder's timeline frames.
    fn sample_rate(&self) -> i64;
    /// Brings the output up (hardware, feeder thread). Idempotent. Errors when there is no usable output device.
    fn prepare(&self) -> Result<(), Unavailable>;
    /// Output pulls from the ring (after the pending seek is primed). Never blocks.
    fn start(&self);
    /// Output fades out (5 ms) and then renders silence; the ring is no longer consumed. Never blocks.
    fn stop(&self);
    /// Direction and speed (|rate|) for the next `seek`; updates `output_latency`. Does not flush.
    fn set_rate(&self, rate: PlaybackRate);
    /// Restarts production at `position` in the current direction (flush + 5 ms crossfade). Returns the generation.
    fn seek(&self, position: Time) -> i64;
    fn flushed(&self) -> Flushed;
    /// Ring consumer acknowledgement: latest applied flush epoch and `consumed_frames` at that moment.
    fn consumed_at_epoch(&self) -> (i64, i64);
    /// Frames delivered to the output since creation (the audio master clock counter).
    fn consumed_frames(&self) -> i64;
    /// Last consuming render call (for interpolation between calls and the stall watchdog).
    fn last_render(&self) -> AudioRenderStamp;
    /// Monotonic host time in nanoseconds, same base as `last_render().host_nanos`.
    fn host_nanoseconds(&self) -> i64;
    /// Output-side latency in output time, unscaled by rate.
    fn output_latency(&self) -> Time;
    /// Render calls that found the ring short while playing (after priming).
    fn underrun_count(&self) -> u64;
    /// Called after the output was restarted underneath: the clock re-seeks at its current position.
    fn set_restart_handler(&self, handler: Option<RestartHandler>);
}

/// There is no usable output device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unavailable;

impl std::fmt::Display for Unavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("no usable audio output")
    }
}

impl std::error::Error for Unavailable {}

struct ManualState {
    generation: i64,
    epoch: i64,
    flushed: Flushed,
    ack: (i64, i64),
    consumed: i64,
    stamp: AudioRenderStamp,
    nanos: i64,
    playing: bool,
    prepared: bool,
    prepare_fails: bool,
    rate: PlaybackRate,
    last_seek: Option<Time>,
    latency_samples: i64,
    output_latency: Time,
    time_pitch_latency: Time,
    restart: Option<RestartHandler>,
}

/// Headless `AudioPlaying`: models the feeder (flush on seek, generation, latency M) and the ring consumer (flush
/// acknowledgement, consumed counter) plus a manual host time. Nothing moves unless the test calls `render` /
/// `apply_flush` / `advance_time`.
pub struct ManualAudio {
    state: Mutex<ManualState>,
    sample_rate: i64,
    auto_flush: bool,
}

impl ManualAudio {
    /// 48 kHz, no latency, auto flush.
    pub fn new() -> ManualAudio {
        ManualAudio::with(0, Time::ZERO, Time::ZERO, true)
    }

    /// `time_pitch_latency` is added to `output_latency` while |rate| != 1 (a time stretcher is not bypassed).
    /// With `auto_flush` (the default elsewhere), `render` applies a pending feeder flush first (the feeder is always ahead).
    pub fn with(latency_samples: i64, output_latency: Time, time_pitch_latency: Time, auto_flush: bool) -> ManualAudio {
        ManualAudio {
            state: Mutex::new(ManualState {
                generation: 0,
                epoch: 0,
                flushed: Flushed::default(),
                ack: (0, 0),
                consumed: 0,
                stamp: AudioRenderStamp::default(),
                nanos: 0,
                playing: false,
                prepared: false,
                prepare_fails: false,
                rate: PlaybackRate::ZERO,
                last_seek: None,
                latency_samples,
                output_latency,
                time_pitch_latency,
                restart: None,
            }),
            sample_rate: 48_000,
            auto_flush,
        }
    }

    /// Feeder side: applies the latest seek (issues a ring epoch, publishes `flushed` with the current M).
    pub fn apply_flush(&self) {
        let mut s = lock(&self.state);
        if s.flushed.generation == s.generation {
            return;
        }
        s.epoch += 1;
        s.flushed = Flushed { generation: s.generation, epoch: s.epoch, latency: s.latency_samples };
    }

    /// Consumer side: one render call of `frames` timeline frames at the current host time. Applies an issued flush
    /// (acknowledgement), then counts the frames as consumed while playing. Host time then moves by the call's duration
    /// (`frames / (|rate| x sample_rate)`, rounded up to whole ns), i.e. the next call is due.
    pub fn render(&self, frames: i64) {
        self.render_with(frames, true);
    }

    /// Like `render`, `advance` = false leaves host time where it is (the test moves it itself).
    pub fn render_with(&self, frames: i64, advance: bool) {
        if self.auto_flush {
            self.apply_flush();
        }
        let mut s = lock(&self.state);
        if !s.playing {
            return;
        }
        if s.ack.0 < s.epoch {
            s.ack = (s.epoch, s.consumed);
        }
        s.consumed += frames;
        s.stamp = AudioRenderStamp { frames: s.consumed, quantum: frames, host_nanos: s.nanos };
        if advance && !s.rate.is_paused() {
            let m = s.rate.magnitude();
            let num = i128::from(frames) * 1_000_000_000 * i128::from(m.den());
            let den = i128::from(self.sample_rate) * i128::from(m.num());
            s.nanos += i64::try_from((num + den - 1) / den).unwrap_or(i64::MAX);
        }
    }

    pub fn advance_time(&self, nanoseconds: i64) {
        lock(&self.state).nanos += nanoseconds;
    }

    pub fn set_fails_to_prepare(&self, fails: bool) {
        lock(&self.state).prepare_fails = fails;
    }

    /// Invokes the restart handler, as a device configuration change would.
    pub fn simulate_restart(&self) {
        let handler = lock(&self.state).restart.clone();
        if let Some(h) = handler {
            h();
        }
    }

    pub fn is_playing(&self) -> bool {
        lock(&self.state).playing
    }

    pub fn is_prepared(&self) -> bool {
        lock(&self.state).prepared
    }

    pub fn current_rate(&self) -> PlaybackRate {
        lock(&self.state).rate
    }

    pub fn last_seek(&self) -> Option<Time> {
        lock(&self.state).last_seek
    }
}

impl Default for ManualAudio {
    fn default() -> ManualAudio {
        ManualAudio::new()
    }
}

impl AudioPlaying for ManualAudio {
    fn sample_rate(&self) -> i64 {
        self.sample_rate
    }

    fn prepare(&self) -> Result<(), Unavailable> {
        let mut s = lock(&self.state);
        if s.prepare_fails {
            return Err(Unavailable);
        }
        s.prepared = true;
        Ok(())
    }

    fn start(&self) {
        lock(&self.state).playing = true;
    }

    fn stop(&self) {
        lock(&self.state).playing = false;
    }

    fn set_rate(&self, rate: PlaybackRate) {
        lock(&self.state).rate = rate;
    }

    fn seek(&self, position: Time) -> i64 {
        let mut s = lock(&self.state);
        s.generation += 1;
        s.last_seek = Some(position);
        s.generation
    }

    fn flushed(&self) -> Flushed {
        lock(&self.state).flushed
    }

    fn consumed_at_epoch(&self) -> (i64, i64) {
        lock(&self.state).ack
    }

    fn consumed_frames(&self) -> i64 {
        lock(&self.state).consumed
    }

    fn last_render(&self) -> AudioRenderStamp {
        lock(&self.state).stamp
    }

    fn host_nanoseconds(&self) -> i64 {
        lock(&self.state).nanos
    }

    fn output_latency(&self) -> Time {
        let s = lock(&self.state);
        let bypass = s.rate.is_paused() || s.rate.magnitude() == PlaybackRate::FORWARD;
        s.output_latency + if bypass { Time::ZERO } else { s.time_pitch_latency }
    }

    fn underrun_count(&self) -> u64 {
        0
    }

    fn set_restart_handler(&self, handler: Option<RestartHandler>) {
        lock(&self.state).restart = handler;
    }
}
