// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioRenderCore.swift
//! Real-time side of the output, separated from the hardware so it can be tested headless.
//!
//! `RenderCore::fill_interleaved` runs on the audio callback: it only copies from the ring and touches atomics (no locks,
//! no allocation).
//! - Playing: pops from the ring; a short pop is silence (zero-filled by the ring) and counts one underrun.
//! - Priming (after `begin_priming(generation)`): until the feeder has flushed for THAT generation (lock-free
//!   `FlushGeneration`) and the ring holds a whole render call, the old material keeps playing if output was running (so the
//!   ring's crossfade has a tail), otherwise silence. Shortage while priming is not an underrun. A newer `begin_priming`
//!   during priming is never lost (sequence counter, the render thread only records what it completed).
//! - Stopped: the next `fade_frames` frames are popped with a raised-cosine fade-out, then silence (ring not consumed).
//!
//! - |rate| != 1: the ring stream (always 1x) goes through `ShuttleStretch`, which pulls |rate| ring frames per output
//!   frame. The ring's consumed counter, and with it the audio clock, therefore runs |rate| times faster than the device.
//!
//! Every consuming call publishes an `AudioRenderStamp` (seqlock) for the clock's interpolation and watchdog. The stamp's
//! host time is the delay-locked smoothed callback time (`StampSmoother`).

use super::stretch::ShuttleStretch;
use crate::clock::{AudioRenderStamp, StampSmoother};
use crate::ring::{RingConsumer, RingShared, raised_cosine};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering::*, fence};

/// The generation the feeder (mixer thread) has flushed the ring for, published lock-free to the render core.
#[derive(Debug, Default)]
pub struct FlushGeneration {
    pub value: AtomicI64,
}

/// Frames per chunk the callback processes at once; a longer device buffer is processed in several chunks.
pub const MAX_CHUNK_FRAMES: usize = 8192;

/// Ring frames the stretch stage asks for per source call at most (the Swift sink's chunk): keeps one call below what the
/// priming check and the ring can serve.
const SOURCE_CHUNK: usize = 4096;

/// Control-side view of the render core (any thread).
pub struct RenderShared {
    /// Output pulls from the ring while true; false = fade out, then silence.
    pub playing: AtomicBool,
    /// |rate| as `f64` bits: the speed of the shuttle stretch (1 = the ring is played straight).
    speed_bits: AtomicU64,
    reset_stretch: AtomicBool,
    prime_seq: AtomicU64,
    prime_target: AtomicI64,
    underruns: AtomicU64,
    callbacks: AtomicU64,
    min_fill: AtomicU64,
    /// Like `min_fill`, but read and restarted by [`RenderShared::take_interval_min_fill`] (the per-frame bench trace).
    interval_min_fill: AtomicU64,
    /// Set by the first [`RenderShared::take_interval_min_fill`]: the callback tracks the interval minimum only once a reader exists.
    interval_trace: AtomicBool,
    // Stamp seqlock (odd = render thread writing).
    stamp_seq: AtomicU64,
    stamp_frames: AtomicI64,
    stamp_quantum: AtomicI64,
    stamp_nanos: AtomicI64,
}

impl RenderShared {
    fn new() -> RenderShared {
        RenderShared {
            playing: AtomicBool::new(false),
            speed_bits: AtomicU64::new(1.0f64.to_bits()),
            reset_stretch: AtomicBool::new(false),
            prime_seq: AtomicU64::new(0),
            prime_target: AtomicI64::new(0),
            underruns: AtomicU64::new(0),
            callbacks: AtomicU64::new(0),
            min_fill: AtomicU64::new(u64::MAX),
            interval_min_fill: AtomicU64::new(u64::MAX),
            interval_trace: AtomicBool::new(false),
            stamp_seq: AtomicU64::new(0),
            stamp_frames: AtomicI64::new(0),
            stamp_quantum: AtomicI64::new(0),
            stamp_nanos: AtomicI64::new(0),
        }
    }

    /// Render calls that found the ring short while playing (after priming).
    pub fn underrun_count(&self) -> u64 {
        self.underruns.load(Relaxed)
    }

    /// Callbacks served so far.
    pub fn callback_count(&self) -> u64 {
        self.callbacks.load(Relaxed)
    }

    /// Smallest ring fill (frames) seen at the start of a playing call; `None` before the first.
    pub fn min_fill(&self) -> Option<u64> {
        Some(self.min_fill.load(Relaxed)).filter(|&v| v != u64::MAX)
    }

    /// Smallest ring fill (frames) since the last call, then starts over; `None` when no playing callback ran meanwhile.
    pub fn take_interval_min_fill(&self) -> Option<u64> {
        self.interval_trace.store(true, Relaxed);
        Some(self.interval_min_fill.swap(u64::MAX, Relaxed)).filter(|&v| v != u64::MAX)
    }

    /// Speed (|rate|, 1 = straight) the callback plays the ring at. A change drops the stretch's buffered audio.
    pub fn set_speed(&self, speed: f64) {
        let old = f64::from_bits(self.speed_bits.swap(speed.to_bits(), AcqRel));
        if old.to_bits() != speed.to_bits() {
            self.request_stretch_reset();
        }
    }

    pub fn speed(&self) -> f64 {
        f64::from_bits(self.speed_bits.load(Acquire))
    }

    /// True while the output goes through the stretch stage (adds its latency).
    pub fn stretching(&self) -> bool {
        self.speed().to_bits() != 1.0f64.to_bits()
    }

    /// The next callback drops the stretch's buffered audio (seek, rate change).
    pub fn request_stretch_reset(&self) {
        self.reset_stretch.store(true, Release);
    }

    /// Call after the feeder seek that returned `generation`: output waits for that generation's flush.
    pub fn begin_priming(&self, generation: i64) {
        self.prime_target.store(generation, Release);
        self.prime_seq.fetch_add(1, Release);
    }

    /// The last consuming render call.
    pub fn last_render(&self) -> AudioRenderStamp {
        loop {
            let s1 = self.stamp_seq.load(Acquire);
            if s1 & 1 == 1 {
                std::hint::spin_loop();
                continue;
            }
            let st = AudioRenderStamp {
                frames: self.stamp_frames.load(Relaxed),
                quantum: self.stamp_quantum.load(Relaxed),
                host_nanos: self.stamp_nanos.load(Relaxed),
            };
            fence(Acquire);
            if self.stamp_seq.load(Relaxed) == s1 {
                return st;
            }
        }
    }

    fn publish_stamp(&self, frames: i64, quantum: i64, nanos: i64) {
        self.stamp_seq.fetch_add(1, AcqRel);
        self.stamp_frames.store(frames, Relaxed);
        self.stamp_quantum.store(quantum, Relaxed);
        self.stamp_nanos.store(nanos, Relaxed);
        self.stamp_seq.fetch_add(1, Release);
    }
}

/// A second voice summed into the output on the callback, next to the ring: it plays when the ring is stopped too (the
/// scrub grains of the Program monitor). `render` runs on the audio callback: no locks, no allocation.
pub trait SideVoice: Send {
    /// Overwrites `l.len()` frames (and the same of `r`) with this voice. True when it is pure silence.
    fn render(&mut self, l: &mut [f32], r: &mut [f32]) -> bool;
}

/// Callback-owned render state (single consumer).
pub struct RenderCore {
    shared: Arc<RenderShared>,
    ring: RingConsumer,
    ring_shared: Arc<RingShared>,
    flush_generation: Arc<FlushGeneration>,
    fade_frames: usize,
    ramp: Vec<f32>,
    smoother: StampSmoother,
    /// Taken out while it renders (its source is `render_main`); `None` only inside that call.
    stretch: Option<Box<ShuttleStretch>>,
    /// The last callback went through the stretch (its grain state is valid).
    stretch_live: bool,
    // Render thread only.
    primed_seq: u64,
    was_playing: bool,
    fade_out_pos: usize,
    // Scratch for de-interleaving, allocated once.
    scratch_l: Vec<f32>,
    scratch_r: Vec<f32>,
    side: Option<Box<dyn SideVoice>>,
    side_l: Vec<f32>,
    side_r: Vec<f32>,
}

impl RenderCore {
    pub fn new(
        ring: RingConsumer,
        flush_generation: Arc<FlushGeneration>,
        fade_frames: usize,
        sample_rate: u32,
    ) -> RenderCore {
        let ring_shared = ring.shared();
        RenderCore {
            shared: Arc::new(RenderShared::new()),
            ring,
            ring_shared,
            flush_generation,
            fade_frames,
            ramp: raised_cosine(fade_frames),
            smoother: StampSmoother::new(sample_rate, 0.3),
            stretch: Some(Box::default()),
            stretch_live: false,
            primed_seq: 0,
            was_playing: false,
            fade_out_pos: fade_frames,
            scratch_l: vec![0.0; MAX_CHUNK_FRAMES],
            scratch_r: vec![0.0; MAX_CHUNK_FRAMES],
            side: None,
            side_l: vec![0.0; MAX_CHUNK_FRAMES],
            side_r: vec![0.0; MAX_CHUNK_FRAMES],
        }
    }

    /// Sets or removes the side voice that is summed into every callback.
    pub fn set_side_voice(&mut self, voice: Option<Box<dyn SideVoice>>) {
        self.side = voice;
    }

    pub fn shared(&self) -> Arc<RenderShared> {
        Arc::clone(&self.shared)
    }

    /// Fills `l.len().min(r.len())` frames. `host_nanos` is the raw callback time; it is smoothed here. Returns true when
    /// the output is pure silence.
    pub fn render(&mut self, l: &mut [f32], r: &mut [f32], host_nanos: i64) -> bool {
        let count = l.len().min(r.len());
        let t = self.smoother.filter(host_nanos, count);
        self.render_at(l, r, t)
    }

    /// Fills an interleaved device buffer of `channels` channels (the first two carry the mix, the rest are silent).
    /// Callbacks longer than `MAX_CHUNK_FRAMES` are processed in chunks. Never allocates.
    pub fn fill_interleaved(&mut self, data: &mut [f32], channels: usize, host_nanos: i64) {
        let channels = channels.max(1);
        let total = data.len() / channels;
        let t = self.smoother.filter(host_nanos, total);
        let mut sl = std::mem::take(&mut self.scratch_l);
        let mut sr = std::mem::take(&mut self.scratch_r);
        for chunk in data.chunks_mut(MAX_CHUNK_FRAMES * channels) {
            let n = chunk.len() / channels;
            self.render_at(&mut sl[..n], &mut sr[..n], t);
            for j in 0..n {
                let frame = &mut chunk[j * channels..(j + 1) * channels];
                frame.fill(0.0);
                frame[0] = sl[j];
                if channels > 1 {
                    frame[1] = sr[j];
                }
            }
        }
        self.scratch_l = sl;
        self.scratch_r = sr;
    }

    /// The ring's output plus the side voice. Silent only when both are.
    fn render_at(&mut self, l: &mut [f32], r: &mut [f32], t: i64) -> bool {
        let mut silent = self.render_ring(l, r, t);
        let Some(side) = self.side.as_mut() else { return silent };
        let total = l.len().min(r.len());
        let mut at = 0;
        while at < total {
            let n = (total - at).min(self.side_l.len());
            if !side.render(&mut self.side_l[..n], &mut self.side_r[..n]) {
                silent = false;
                for j in 0..n {
                    l[at + j] += self.side_l[j];
                    r[at + j] += self.side_r[j];
                }
            }
            at += n;
        }
        silent
    }

    /// The ring at the current speed: straight at 1x, through the shuttle stretch otherwise.
    fn render_ring(&mut self, l: &mut [f32], r: &mut [f32], t: i64) -> bool {
        self.shared.callbacks.fetch_add(1, Relaxed);
        let reset = self.shared.reset_stretch.swap(false, AcqRel);
        let count = l.len().min(r.len());
        if !self.shared.stretching() {
            let silent = self.render_main(l, r, t);
            if self.stretch_live
                && let Some(st) = self.stretch.as_mut()
            {
                self.stretch_live = !st.drain_into(l, r, count);
                return false;
            }
            return silent;
        }
        let speed = self.shared.speed();
        let Some(mut st) = self.stretch.take() else { return self.render_main(l, r, t) };
        if !self.stretch_live {
            st.restart();
            self.stretch_live = true;
        } else if reset {
            st.reset_input();
        }
        // A callback that only drained buffered grains made no source call: that is sound, not silence.
        let (mut calls, mut silent_calls) = (0usize, 0usize);
        st.render(speed, l, r, count, &mut |sl: &mut [f32], sr: &mut [f32]| {
            let total = sl.len().min(sr.len());
            let mut at = 0;
            while at < total {
                let n = (total - at).min(SOURCE_CHUNK);
                calls += 1;
                if self.render_main(&mut sl[at..at + n], &mut sr[at..at + n], t) {
                    silent_calls += 1;
                }
                at += n;
            }
        });
        self.stretch = Some(st);
        calls > 0 && silent_calls == calls
    }

    fn render_main(&mut self, l: &mut [f32], r: &mut [f32], t: i64) -> bool {
        let count = l.len().min(r.len());
        if !self.shared.playing.load(Acquire) {
            if self.was_playing {
                self.was_playing = false;
                self.fade_out_pos = 0;
            }
            if self.fade_out_pos >= self.fade_frames {
                return Self::silence(l, r, count);
            }
            let n = count.min(self.fade_frames - self.fade_out_pos);
            let got = self.ring.pop(&mut l[..n], &mut r[..n]);
            for j in 0..n {
                let g = 1.0 - self.ramp[self.fade_out_pos + j];
                l[j] *= g;
                r[j] *= g;
            }
            self.fade_out_pos += n;
            l[n..count].fill(0.0);
            r[n..count].fill(0.0);
            self.stamp(got, t);
            return false;
        }
        let seq = self.shared.prime_seq.load(Acquire);
        if seq != self.primed_seq {
            let target = self.shared.prime_target.load(Acquire);
            if self.flush_generation.value.load(Acquire) < target {
                // Feeder has not flushed for the seek yet.
                if !self.was_playing {
                    return Self::silence(l, r, count);
                }
                let got = self.ring.pop(&mut l[..count], &mut r[..count]); // old material, shortage not counted
                self.stamp(got, t);
                return false;
            }
            if self.ring_shared.available_to_read() < count {
                return Self::silence(l, r, count);
            }
            self.primed_seq = seq;
        }
        self.was_playing = true;
        self.fade_out_pos = self.fade_frames;
        let fill = self.ring_shared.available_to_read() as u64;
        self.shared.min_fill.fetch_min(fill, Relaxed);
        if self.shared.interval_trace.load(Relaxed) {
            self.shared.interval_min_fill.fetch_min(fill, Relaxed);
        }
        let got = self.ring.pop(&mut l[..count], &mut r[..count]);
        if got < count {
            self.shared.underruns.fetch_add(1, Relaxed);
        }
        self.stamp(got, t);
        false
    }

    fn stamp(&self, got: usize, nanos: i64) {
        if got == 0 {
            return;
        }
        self.shared.publish_stamp(self.ring_shared.consumed_frames(), got as i64, nanos);
    }

    fn silence(l: &mut [f32], r: &mut [f32], count: usize) -> bool {
        l[..count].fill(0.0);
        r[..count].fill(0.0);
        true
    }
}

#[cfg(test)]
mod tests;
