// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioEngine.swift (the portable shape), spikes/g6-audio (cpal stream, mixer thread)
//! Audio output: a cpal stream fed from a lock-free ring by a mixer thread that pulls a `Renderer`.
//!
//! Threads:
//! - callback (cpal): `RenderCore::fill_interleaved` only (try-lock on its own state, atomics, no allocation);
//! - mixer: renders 1024-frame blocks from the `Renderer` into the ring, parked until the callback frees room;
//! - device: owns the cpal stream (it is not `Send` everywhere), turns stream errors into `OutputEvent`s and rebuilds the
//!   stream when the device was invalidated.
//!
//! The clock is `AudioClock` (position from frames consumed, exact rational) over this output; the stamps it interpolates
//! with are delay-locked smoothed in the callback, so jittery WASAPI callback times do not move the clock backwards.

mod device;
pub mod devices;
mod mixer;
mod player;
mod render_core;
mod stretch;
#[cfg(test)]
mod stretch_clock_tests;

pub use render_core::{FlushGeneration, MAX_CHUNK_FRAMES, RenderCore, RenderShared, SideVoice};

use crate::clock::{AudioClock, AudioPlaying, PlaybackClock};
use crate::ring::ring;
use device::DeviceMsg;
use mixer::MixerCmd;
use player::DevicePlayer;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::atomic::AtomicU64;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// Frames the mixer renders per block.
pub const BLOCK_FRAMES: usize = 1024;

/// Highest shuttle speed the app plays (L or J pressed four times).
const MAX_SHUTTLE_RATE: usize = 8;

/// Ring length in frames. At |rate| the shuttle stretch pops `|rate| x HOP` ring frames in one burst per grain, and the
/// mixer thread may wake late (Windows timers), so the ring keeps four such grains of the top speed in stock; at 1x the
/// 170 ms of `OutputConfig::ring_ms` is the larger of the two only for short rings.
fn ring_frames_for(cfg: &OutputConfig) -> usize {
    let straight = cfg.sample_rate as usize * cfg.ring_ms as usize / 1000;
    straight.max(4 * MAX_SHUTTLE_RATE * stretch::HOP).max(4 * BLOCK_FRAMES)
}

/// Device and ring settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutputConfig {
    /// Sample rate asked from the device (48000).
    pub sample_rate: u32,
    /// Output channels (2; other counts are not supported yet).
    pub channels: u16,
    /// Fixed device buffer, `None` = the device default.
    pub buffer_frames: Option<u32>,
    /// Ring length in milliseconds (170).
    pub ring_ms: u32,
}

impl Default for OutputConfig {
    fn default() -> OutputConfig {
        OutputConfig { sample_rate: 48_000, channels: 2, buffer_frames: None, ring_ms: 170 }
    }
}

/// Produces the mix. Runs on the mixer thread, never on the audio callback.
pub trait Renderer: Send {
    /// Fills `out` (interleaved stereo, `BLOCK_FRAMES` frames) with the next block of the current anchor.
    fn render(&mut self, out: &mut [f32]);
    /// Restarts production at `anchor` going at `rate` (negative = reverse). Called before the first `render` of an anchor.
    fn flush(&mut self, anchor: Time, rate: PlaybackRate);
    /// Frames between the timeline position and the first sample `render` returns after `flush` (resampler delay, M of the
    /// clock). Read right after `flush`.
    fn latency_frames(&self) -> u32 {
        0
    }
}

/// What happened to the output underneath.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputEvent {
    /// The stream was rerouted by the system and still runs: latency and position must be re-read.
    DeviceChanged,
    /// The device or format changed and the stream was dropped: the output is being rebuilt.
    StreamInvalidated,
    /// No device came back within ten seconds (keeps retrying).
    DeviceLost,
    /// The ring ran dry this many times since the last report.
    Underrun(u32),
    /// A new stream is running; the clock re-anchored at its last position.
    Rebuilt { latency: Duration },
}

/// Why the output could not be opened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioOutError {
    NoDevice,
    UnsupportedChannels(u16),
    Build(String),
    Thread(String),
}

impl std::fmt::Display for AudioOutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AudioOutError::NoDevice => f.write_str("no default audio output device"),
            AudioOutError::UnsupportedChannels(n) => write!(f, "{n} output channels are not supported (stereo only)"),
            AudioOutError::Build(e) => write!(f, "could not open the audio stream: {e}"),
            AudioOutError::Thread(e) => write!(f, "could not start an audio thread: {e}"),
        }
    }
}

impl std::error::Error for AudioOutError {}

/// Counters of the output since it was opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutputStats {
    pub callbacks: u64,
    pub underruns: u64,
    /// Smallest ring fill (frames) at the start of a playing callback.
    pub min_fill_frames: Option<u64>,
    pub ring_frames: usize,
}

/// Lock-free reads of the audio clock. Clone + Send + Sync.
#[derive(Clone)]
pub struct AudioClockHandle {
    clock: Arc<AudioClock>,
}

impl AudioClockHandle {
    /// Heard timeline position: smoothed, monotonic per anchor, holds at the anchor until the restart is acknowledged.
    pub fn now(&self) -> Time {
        self.clock.now()
    }

    /// Running, but no audio was consumed for 250 ms (5 s while priming): the engine should fall back to the host clock.
    pub fn stalled(&self) -> bool {
        self.clock.sample().1
    }

    /// The clock as a `PlaybackClock` (for `SwitchingClock`).
    pub fn playback_clock(&self) -> Arc<AudioClock> {
        Arc::clone(&self.clock)
    }
}

/// The running output.
pub struct AudioOut {
    clock: Arc<AudioClock>,
    player: Arc<DevicePlayer>,
    device_tx: Sender<DeviceMsg>,
    mixer_tx: Sender<MixerCmd>,
    device: Option<JoinHandle<()>>,
    mixer: Option<JoinHandle<()>>,
    ring_frames: usize,
    core: Arc<Mutex<RenderCore>>,
}

/// Test and bench runs on a machine someone sits at (offscreen shots, `--play-bench`, `--play-start`) set `SQ_AUDIO_NULL=1`:
/// no output device is opened, so nothing reaches the speakers and playback runs on the host clock.
pub fn null_sink_requested() -> bool {
    std::env::var_os("SQ_AUDIO_NULL").is_some()
}

impl AudioOut {
    /// Opens the default output device and starts the mixer and device threads. `events` receives `OutputEvent`s.
    /// With `SQ_AUDIO_NULL` set it opens nothing and answers `NoDevice` (see [`null_sink_requested`]).
    pub fn open(
        cfg: OutputConfig,
        renderer: Box<dyn Renderer>,
        events: Sender<OutputEvent>,
    ) -> Result<AudioOut, AudioOutError> {
        if null_sink_requested() {
            return Err(AudioOutError::NoDevice);
        }
        if cfg.channels != 2 {
            return Err(AudioOutError::UnsupportedChannels(cfg.channels));
        }
        let ring_frames = ring_frames_for(&cfg);
        let fade_frames = (cfg.sample_rate as usize * 5 / 1000).max(1);
        let (producer, consumer) = ring(ring_frames, fade_frames, Duration::from_millis(100));
        let gate = Arc::new(FlushGeneration::default());
        let core = RenderCore::new(consumer, Arc::clone(&gate), fade_frames, cfg.sample_rate);
        let render = core.shared();
        let ring_shared = producer.shared();
        let flushed = Arc::new(Mutex::new(crate::clock::Flushed::default()));
        let latency_ns = Arc::new(AtomicU64::new(0));

        let (mixer_tx, mixer_rx) = channel();
        let mixer = mixer::spawn(renderer, producer, gate, Arc::clone(&flushed), mixer_rx)
            .map_err(|e| AudioOutError::Thread(e.to_string()))?;
        let mixer_thread = mixer.thread().clone();

        let player = Arc::new(DevicePlayer::new(
            i64::from(cfg.sample_rate),
            render,
            ring_shared,
            mixer_tx.clone(),
            mixer_thread.clone(),
            flushed,
            Arc::clone(&latency_ns),
        ));
        let core = Arc::new(Mutex::new(core));
        let (device_tx, device_rx) = channel();
        let device = device::spawn(device::DeviceSetup {
            cfg,
            core: Arc::clone(&core),
            latency_ns,
            mixer: mixer_thread,
            events,
            player: Arc::clone(&player),
            tx: device_tx.clone(),
            rx: device_rx,
        });
        let device = match device {
            Ok(d) => d,
            Err(e) => {
                let _ = mixer_tx.send(MixerCmd::Quit);
                mixer.thread().unpark();
                let _ = mixer.join();
                return Err(e);
            }
        };
        let clock = AudioClock::new(Arc::clone(&player) as Arc<dyn AudioPlaying>);
        Ok(AudioOut { clock, player, device_tx, mixer_tx, device: Some(device), mixer: Some(mixer), ring_frames, core })
    }

    /// Sets or removes the voice summed into the output next to the play ring (scrub grains). The callback skips one
    /// block at most while this holds the core.
    pub fn set_side_voice(&self, voice: Option<Box<dyn SideVoice>>) {
        self.core.lock().unwrap_or_else(std::sync::PoisonError::into_inner).set_side_voice(voice);
    }

    /// Builds the stream again on the preferred output (`devices::set_preferred`), as after a lost device.
    pub fn rebuild_output(&self) {
        let _ = self.device_tx.send(DeviceMsg::Invalidated);
    }

    /// Flush + ack + 5 ms fade-in at `anchor`; rate 0 = stop (fade-out). The clock holds at `anchor` until the first
    /// audio of the new anchor was consumed.
    pub fn restart(&self, anchor: Time, rate: PlaybackRate) {
        self.clock.start(anchor, rate);
    }

    /// Fades out and holds; returns the position where it stopped.
    pub fn stop(&self) -> Time {
        self.clock.stop()
    }

    pub fn clock(&self) -> AudioClockHandle {
        AudioClockHandle { clock: Arc::clone(&self.clock) }
    }

    /// Device presentation latency (`playback - callback`), refreshed on every callback.
    pub fn latency(&self) -> Duration {
        self.player.latency()
    }

    /// A probe for the per-frame bench trace: the smallest ring fill (frames) since its last call (`None` when idle).
    pub fn interval_fill_probe(&self) -> Arc<dyn Fn() -> Option<u64> + Send + Sync> {
        let player = Arc::clone(&self.player);
        Arc::new(move || player.take_interval_min_fill())
    }

    pub fn stats(&self) -> OutputStats {
        self.player.stats(self.ring_frames)
    }

    /// The output as `AudioPlaying` (for `SwitchingClock` and tools that read the raw counters).
    pub fn audio(&self) -> Arc<dyn AudioPlaying> {
        Arc::clone(&self.player) as Arc<dyn AudioPlaying>
    }
}

impl Drop for AudioOut {
    fn drop(&mut self) {
        let _ = self.clock.stop();
        let _ = self.device_tx.send(DeviceMsg::Quit);
        let _ = self.mixer_tx.send(MixerCmd::Quit);
        if let Some(m) = &self.mixer {
            m.thread().unpark();
        }
        if let Some(d) = self.device.take() {
            let _ = d.join();
        }
        if let Some(m) = self.mixer.take() {
            let _ = m.join();
        }
    }
}
