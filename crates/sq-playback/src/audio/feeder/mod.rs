// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift, AudioFeeder+Preferences.swift
//! Mixes `Timeline::audio_segments` from `AudioSource`s into blocks at the mixer rate (48 kHz), in play direction.
//!
//! Per-track buses: every audio track mixes (with its clip volume) into its own bus, optionally runs through its own
//! `RealtimeAudioFX` (preset per track via `set_tracks` / `set_preset`), is delay-compensated and only then summed. Clip
//! and track volume live here; the FX instances get a unity `VolumeAutomation` so volume is never applied twice. Order:
//! clip volume -> track FX -> track fader gain (`apply_post_fader`, ramped per block; pan stays per segment before the
//! FX). `mix` (scrub, no track FX) applies the fader per segment.
//!
//! Nested sequences: segments of a nested audio clip mix into the bus of the top-level track that holds the nested clip.
//! Latency: every track is delayed to the maximum FX latency `M`, so the output is `M` samples behind the timeline
//! position (`output_latency_samples`, reported through `Renderer::latency_frames`).
//!
//! Reverse: each bus is time-reversed first and then runs in play order with the FX bypassed. Every flush (seek) resets
//! all FX state and delay lines. Master: a sequence with a `DeliveryTarget` runs the sum through a zero-latency
//! `MasterLimiter`; Sequence Volume scales the sum just before it.
//!
//! Threads: the feeder (`AudioFeeder`) lives on the mixer thread (it is a `Renderer`); everything else is reachable from
//! other threads through `FeederHandle`. The ring, flush epochs and the clock belong to `sq-audio-out`.

mod blocks;
mod config;
#[cfg(test)]
mod extra_tests;
mod handle;
mod nest;
#[cfg(test)]
mod retime_tests;
mod segments;
#[cfg(test)]
mod tests;

pub use handle::FeederHandle;

use super::retimer::AudioRetimer;
use super::time_map::AudioTimeMap;
use super::track_mix::{AUDIO_TAGS, FaderKey, Gains};
use blocks::Stereo;
use config::BusSet;
use sq_audio_out::output::Renderer;
use sq_audiofx::clip_audio_fxchain::ClipAudioFXChain;
use sq_audiofx::gain::AudioFXError;
use sq_audiofx::limiter::MasterLimiter;
use sq_core_audio::{AudioFXSlot, AudioFXStep};
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{AudioTag, Clip};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::memory_audio_source::AudioSource;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use handle::{Resolver, SharedSilences};

/// The mixer rate. `RealtimeAudioFX` and the clip chains run at 48 kHz only.
pub const SAMPLE_RATE: i64 = 48_000;

/// Builds a clip effect chain. Tests replace it with one that fails to prove the feeder fails closed.
pub(crate) type ChainFactory = Box<dyn Fn(&[AudioFXSlot], usize) -> Result<ClipAudioFXChain, AudioFXError> + Send>;

/// The effect chain of every clip with audio effects that played in the last block, keyed by nest path + clip id.
struct ClipFx {
    chain: ClipAudioFXChain,
    /// Frame a contiguous next block starts at; any other start resets the chain.
    next_frame: i64,
    serial: u64,
    steps: Vec<AudioFXStep>,
    end_steps: Vec<AudioFXStep>,
}

impl ClipFx {
    fn new(chain: ClipAudioFXChain) -> ClipFx {
        ClipFx { chain, next_frame: i64::MIN, serial: 0, steps: Vec::new(), end_steps: Vec::new() }
    }
}

/// The clip id plus a hash of its nest path (the same clip seen through two nest instances gets two chains).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct ClipFxKey {
    clip: Id,
    nests: u64,
}

/// A nested clip with audio effects: its inner segments are mixed into one buffer, run through its chain, then get the
/// nest's Volume and the faders above it. `depth` is its index in `AudioSegment::nests`.
#[derive(Clone, Copy, Debug)]
struct NestGroup {
    key: ClipFxKey,
    depth: usize,
}

/// The block mixer. See the module docs.
pub struct AudioFeeder {
    shared: Arc<handle::Shared>,
    resolver: Resolver,
    pub(crate) block_frames: usize,
    sources: HashMap<Id, Arc<dyn AudioSource>>,
    /// A source that failed to open is not retried before this long has passed (or `media_changed`).
    pub(crate) open_retry_interval: Duration,
    failed_opens: HashMap<Id, Instant>,
    logged_failures: std::collections::HashSet<Id>,
    /// Fader gain each bus ended the previous block with: a change is ramped linearly across the next block.
    fader_state: HashMap<FaderKey, Gains>,
    /// Post-effects fader gain of each top-level track bus: where the previous block ended.
    post_fader_state: HashMap<Id, f32>,
    /// Sequence Volume of the last block (ramp start).
    master_level_state: Option<f32>,
    /// Time maps of remapped clip chains, built once and reused for every block; a changed clip rebuilds.
    time_maps: HashMap<Vec<Id>, (Vec<Clip>, Arc<AudioTimeMap>)>,
    /// Live duck ranges of the current block and the same expanded by the duck timing (one expanded buffer per nest level:
    /// an effected nest's pass runs while the outer pass still holds its expanded ranges).
    duck_ranges: Vec<TimeRange>,
    duck_expanded: Vec<Vec<TimeRange>>,
    retimer: AudioRetimer,
    scratch: Vec<f32>,
    out: Stereo,
    bus_bufs: Vec<Stereo>,
    /// Role buses: one stereo sum per `AUDIO_TAGS` entry.
    role_buffers: Vec<Stereo>,
    /// Gain each role bus ended the previous block with (ramped across the next one).
    role_gain_state: HashMap<AudioTag, f32>,
    applied_generation: i64,
    clip_fx: HashMap<ClipFxKey, ClipFx>,
    clip_fx_serial: u64,
    nest_buffers: Vec<Stereo>,
    fx_l: Vec<f32>,
    fx_r: Vec<f32>,
    limiter: Option<MasterLimiter>,
    pub(crate) make_chain: ChainFactory,
    /// Test seam: false = the per-block timeline walk (the reference the duck index must match).
    pub(crate) uses_duck_index: bool,
}

impl AudioFeeder {
    /// A feeder for `timeline`; `block_frames` is the mix block (1024 for playback). Source rate must be 48 kHz.
    pub fn new(timeline: sq_core_model::Timeline, block_frames: usize, resolver: Resolver) -> AudioFeeder {
        let shared = Arc::new(handle::Shared::new(timeline, block_frames, Arc::clone(&resolver)));
        let zeros = || vec![0.0f32; block_frames];
        AudioFeeder {
            shared,
            resolver,
            block_frames,
            sources: HashMap::new(),
            open_retry_interval: Duration::from_secs(5),
            failed_opens: HashMap::new(),
            logged_failures: Default::default(),
            fader_state: HashMap::new(),
            post_fader_state: HashMap::new(),
            master_level_state: None,
            time_maps: HashMap::new(),
            duck_ranges: Vec::with_capacity(64),
            duck_expanded: (0..4).map(|_| Vec::with_capacity(64)).collect(),
            retimer: AudioRetimer::new(block_frames),
            scratch: zeros(),
            out: Stereo::new(block_frames),
            bus_bufs: Vec::new(),
            role_buffers: AUDIO_TAGS.iter().map(|_| Stereo::new(block_frames)).collect(),
            role_gain_state: HashMap::new(),
            applied_generation: 0,
            clip_fx: HashMap::new(),
            clip_fx_serial: 0,
            nest_buffers: (0..4).map(|_| Stereo::new(block_frames)).collect(),
            fx_l: zeros(),
            fx_r: zeros(),
            limiter: None,
            make_chain: Box::new(|layout, frames| ClipAudioFXChain::new(layout.to_vec(), 2, frames, None)),
            uses_duck_index: true,
        }
    }

    /// The control surface for other threads.
    pub fn handle(&self) -> FeederHandle {
        FeederHandle::new(Arc::clone(&self.shared))
    }

    /// Mixes the next block into `left`/`right` (at most `block_frames` frames of them are used) and moves the position on.
    /// Applies a pending seek first (FX/delay reset, committed latency). Returns the frames produced: fewer than asked
    /// only when reverse play reaches the timeline start (0 there).
    pub fn next_block(&mut self, left: &mut [f32], right: &mut [f32]) -> usize {
        let want = left.len().min(right.len()).min(self.block_frames);
        let (timeline, duck_index, sequences, pos, reverse, generation, mut buses, ceiling) = {
            let c = config::lock(&self.shared.control);
            (
                Arc::clone(&c.timeline),
                Arc::clone(&c.duck_index),
                Arc::clone(&c.sequences),
                c.position,
                c.reverse,
                c.generation,
                c.buses.clone(),
                c.limiter_ceiling_db,
            )
        };
        if self.limiter.as_ref().map(|l| l.ceiling_db) != ceiling {
            self.limiter = ceiling.map(|c| MasterLimiter::new(SAMPLE_RATE, c));
        }
        if generation != self.applied_generation {
            buses = self.apply_flush(generation);
        }
        let (start, count) = if reverse {
            let start = (pos - want as i64).max(0);
            (start, (pos - start) as usize)
        } else {
            (pos, want)
        };
        if count == 0 {
            return 0;
        }
        let ctx = segments::MixCtx {
            timeline: &timeline,
            sequences: &sequences,
            duck_index: self.uses_duck_index.then_some(&*duck_index),
        };
        self.render_block(&ctx, &buses, start, count, reverse);
        left[..count].copy_from_slice(&self.out.l[..count]);
        right[..count].copy_from_slice(&self.out.r[..count]);
        // The generation check and the position update are one step with respect to `seek`.
        let mut c = config::lock(&self.shared.control);
        if c.generation == generation {
            c.position = if reverse { start } else { pos + count as i64 };
        }
        count
    }

    /// Producer-side flush for `generation`: a changed max latency is adopted here only (new FX start, delays re-sized);
    /// FX, delay lines, clip chains, the limiter and the role ramps belong to the old position and restart.
    fn apply_flush(&mut self, generation: i64) -> BusSet {
        let set = {
            let mut cfg = config::lock(&self.shared.config);
            let set = cfg.rebuild(self.block_frames, true);
            config::lock(&self.shared.control).buses = set.clone();
            set
        };
        self.applied_generation = generation;
        for b in &set.list {
            b.reset();
        }
        self.clip_fx.clear();
        if let Some(l) = &mut self.limiter {
            l.reset();
        }
        self.role_gain_state.clear();
        set
    }

    /// The committed latency in frames (valid from the last applied seek).
    pub fn output_latency_samples(&self) -> usize {
        config::lock(&self.shared.control).buses.latency
    }
}

/// The feeder as the mixer thread's `Renderer`: `flush` seeks, `render` produces `BLOCK_FRAMES` interleaved frames.
impl Renderer for AudioFeeder {
    fn render(&mut self, out: &mut [f32]) {
        let frames = out.len() / 2;
        let (mut l, mut r) = (vec![0.0f32; self.block_frames.min(frames)], vec![0.0f32; self.block_frames.min(frames)]);
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(self.block_frames);
            let got = self.next_block(&mut l[..n], &mut r[..n]);
            for i in 0..n {
                let (a, b) = if i < got { (l[i], r[i]) } else { (0.0, 0.0) };
                out[(done + i) * 2] = a;
                out[(done + i) * 2 + 1] = b;
            }
            done += n;
        }
    }

    fn flush(&mut self, anchor: Time, rate: PlaybackRate) {
        let frame = round_frame(anchor, SAMPLE_RATE);
        let generation = self.handle().seek(frame, rate.is_reverse());
        self.apply_flush(generation);
    }

    fn latency_frames(&self) -> u32 {
        u32::try_from(self.output_latency_samples()).unwrap_or(0)
    }
}

/// Smallest frame index `f` with `f / rate >= t`.
pub fn ceil_frame(t: Time, rate: i64) -> i64 {
    let num = i128::from(t.value()) * i128::from(rate);
    let den = i128::from(t.timescale());
    let q = num / den;
    (if num % den > 0 { q + 1 } else { q }) as i64
}

/// Nearest frame index (ties round up).
pub fn round_frame(t: Time, rate: i64) -> i64 {
    let num = i128::from(t.value()) * i128::from(rate) * 2 + i128::from(t.timescale());
    let den = i128::from(t.timescale()) * 2;
    let mut q = num / den;
    if num % den < 0 {
        q -= 1;
    }
    q as i64
}
