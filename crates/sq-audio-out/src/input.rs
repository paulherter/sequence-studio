// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/VoiceRecorder.swift (`AVMicrophoneCapture`: the system default input, 48 kHz mono 16-bit WAV)
//! Audio input: the default microphone through cpal, written to a 48 kHz mono 16-bit WAV file.
//!
//! `MicSource` is the seam (the real one is [`CpalMic`], tests use a fake), `MicTake` runs one take: it resamples what the
//! source delivers to 48 kHz and appends it to the file, `finish` patches the header and answers the length. Swift has no
//! level meter, device choice or latency compensation for voice-over (the system default input, a status line with the
//! running time); this is the same.

use std::fs::File;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

/// The rate of a take (Swift `AVSampleRateKey`).
pub const TAKE_RATE: u32 = 48_000;

/// Why a take could not run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MicError {
    /// No input device (or the system refuses this app the microphone).
    NoDevice,
    /// The stream or the file failed (the plain text).
    Failed(String),
}

/// Receives mono blocks at `MicSource::sample_rate`.
pub type MicSink = Box<dyn FnMut(&[f32]) + Send>;

/// A microphone. `start` delivers mono f32 blocks to `sink` (on any thread) until `stop`.
pub trait MicSource: Send {
    /// The rate of the blocks.
    fn sample_rate(&self) -> u32;
    fn start(&mut self, sink: MicSink) -> Result<(), MicError>;
    /// After `stop` no more blocks arrive.
    fn stop(&mut self);
}

/// 16-bit mono WAV, header patched when the take ends.
struct WavWriter {
    out: BufWriter<File>,
    frames: u64,
}

impl WavWriter {
    fn create(path: &Path, rate: u32) -> std::io::Result<WavWriter> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut out = BufWriter::new(File::create(path)?);
        out.write_all(&header(rate, 0))?;
        Ok(WavWriter { out, frames: 0 })
    }
    fn push(&mut self, block: &[i16]) -> std::io::Result<()> {
        for s in block {
            self.out.write_all(&s.to_le_bytes())?;
        }
        self.frames += block.len() as u64;
        Ok(())
    }
    fn finish(mut self, rate: u32) -> std::io::Result<u64> {
        self.out.flush()?;
        let mut file = self.out.into_inner().map_err(std::io::IntoInnerError::into_error)?;
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&header(rate, self.frames))?;
        file.flush()?;
        Ok(self.frames)
    }
}

/// The 44-byte RIFF header of `frames` mono 16-bit samples.
fn header(rate: u32, frames: u64) -> [u8; 44] {
    let data = u32::try_from(frames * 2).unwrap_or(u32::MAX - 36);
    let mut h = [0u8; 44];
    h[0..4].copy_from_slice(b"RIFF");
    h[4..8].copy_from_slice(&(36 + data).to_le_bytes());
    h[8..16].copy_from_slice(b"WAVEfmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM
    h[22..24].copy_from_slice(&1u16.to_le_bytes()); // mono
    h[24..28].copy_from_slice(&rate.to_le_bytes());
    h[28..32].copy_from_slice(&(rate * 2).to_le_bytes());
    h[32..34].copy_from_slice(&2u16.to_le_bytes());
    h[34..36].copy_from_slice(&16u16.to_le_bytes());
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&data.to_le_bytes());
    h
}

/// Linear resampler from the device rate to `TAKE_RATE`, block by block (keeps its phase between blocks).
struct Resampler {
    step: f64,
    pos: f64,
    last: f32,
}

impl Resampler {
    fn new(from: u32) -> Resampler {
        Resampler { step: f64::from(from) / f64::from(TAKE_RATE), pos: 0.0, last: 0.0 }
    }
    fn run(&mut self, input: &[f32], out: &mut Vec<i16>) {
        // `pos` counts from the sample before this block (`last`), so position 0 is `last`, 1 is input[0].
        let n = input.len() as f64;
        while self.pos < n {
            let i = self.pos.floor();
            let frac = (self.pos - i) as f32;
            let a = if i < 1.0 { self.last } else { input[i as usize - 1] };
            let b = input[i as usize];
            out.push(quantize(a + (b - a) * frac));
            self.pos += self.step;
        }
        self.pos -= n;
        if let Some(l) = input.last() {
            self.last = *l;
        }
    }
}

fn quantize(x: f32) -> i16 {
    (x.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

struct TakeState {
    wav: Option<WavWriter>,
    resampler: Resampler,
    scratch: Vec<i16>,
    failed: bool,
}

/// One take: a microphone written to a WAV file until `finish`.
pub struct MicTake {
    source: Box<dyn MicSource>,
    state: Arc<Mutex<TakeState>>,
    frames: Arc<AtomicU64>,
}

impl MicTake {
    /// Opens `path` and starts the source.
    pub fn start(mut source: Box<dyn MicSource>, path: &Path) -> Result<MicTake, MicError> {
        let wav = WavWriter::create(path, TAKE_RATE).map_err(|e| MicError::Failed(e.to_string()))?;
        let state = Arc::new(Mutex::new(TakeState {
            wav: Some(wav),
            resampler: Resampler::new(source.sample_rate()),
            scratch: Vec::new(),
            failed: false,
        }));
        let frames = Arc::new(AtomicU64::new(0));
        let (s, f) = (Arc::clone(&state), Arc::clone(&frames));
        source.start(Box::new(move |block| {
            let Ok(mut st) = s.lock() else { return };
            let st = &mut *st;
            st.scratch.clear();
            st.resampler.run(block, &mut st.scratch);
            if let Some(w) = st.wav.as_mut()
                && w.push(&st.scratch).is_err()
            {
                st.failed = true;
            }
            f.store(st.wav.as_ref().map_or(0, |w| w.frames), Relaxed);
        }))?;
        Ok(MicTake { source, state, frames })
    }

    /// Seconds recorded so far.
    pub fn elapsed(&self) -> f64 {
        self.frames.load(Relaxed) as f64 / f64::from(TAKE_RATE)
    }

    /// Stops the source, closes the file and answers its length in frames at `TAKE_RATE`.
    pub fn finish(mut self) -> Result<u64, MicError> {
        self.source.stop();
        let mut st = self.state.lock().map_err(|_| MicError::Failed("poisoned".into()))?;
        let failed = st.failed;
        let wav = st.wav.take().ok_or_else(|| MicError::Failed("closed".into()))?;
        let frames = wav.finish(TAKE_RATE).map_err(|e| MicError::Failed(e.to_string()))?;
        if failed { Err(MicError::Failed("write failed".into())) } else { Ok(frames) }
    }
}

/// The system default input through cpal. The stream lives on its own thread (it is not `Send` on every host).
#[derive(Default)]
pub struct CpalMic {
    rate: u32,
    quit: Option<Arc<AtomicBool>>,
    thread: Option<JoinHandle<()>>,
}

impl CpalMic {
    pub fn new() -> CpalMic {
        CpalMic::default()
    }

    /// True when the system has a default input device.
    pub fn available() -> bool {
        cpal::default_host().default_input_device().is_some()
    }
}

fn downmix<T: Copy>(data: &[T], channels: usize, to_f32: impl Fn(T) -> f32) -> Vec<f32> {
    data.chunks(channels.max(1)).map(|f| f.iter().map(|s| to_f32(*s)).sum::<f32>() / f.len() as f32).collect()
}

impl MicSource for CpalMic {
    fn sample_rate(&self) -> u32 {
        if self.rate == 0 { TAKE_RATE } else { self.rate }
    }

    fn start(&mut self, mut sink: MicSink) -> Result<(), MicError> {
        let (ready_tx, ready_rx) = channel::<Result<u32, MicError>>();
        let quit = Arc::new(AtomicBool::new(false));
        let q = Arc::clone(&quit);
        let thread = std::thread::Builder::new()
            .name("sq-audio-input".into())
            .spawn(move || run_input(&mut sink, &q, &ready_tx))
            .map_err(|e| MicError::Failed(e.to_string()))?;
        match ready_rx.recv() {
            Ok(Ok(rate)) => {
                self.rate = rate;
                self.quit = Some(quit);
                self.thread = Some(thread);
                Ok(())
            }
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => Err(MicError::Failed("input thread ended".into())),
        }
    }

    fn stop(&mut self) {
        if let Some(q) = self.quit.take() {
            q.store(true, Relaxed);
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for CpalMic {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run_input(sink: &mut MicSink, quit: &AtomicBool, ready: &Sender<Result<u32, MicError>>) {
    let host = cpal::default_host();
    let Some(device) = host.default_input_device() else {
        let _ = ready.send(Err(MicError::NoDevice));
        return;
    };
    let Ok(supported) = device.default_input_config() else {
        let _ = ready.send(Err(MicError::NoDevice));
        return;
    };
    let config = cpal::StreamConfig {
        channels: supported.channels(),
        sample_rate: supported.sample_rate(),
        buffer_size: cpal::BufferSize::Default,
    };
    let channels = usize::from(config.channels);
    let rate = config.sample_rate;
    // The stream callback owns the sink for the whole take: hand it over through a shared slot.
    let shared = Arc::new(Mutex::new(std::mem::replace(sink, Box::new(|_| {}))));
    let (a, b) = (Arc::clone(&shared), Arc::clone(&shared));
    let on_error = |_e: cpal::Error| {};
    let built = match supported.sample_format() {
        cpal::SampleFormat::I16 => device.build_input_stream(
            config,
            move |d: &[i16], _: &cpal::InputCallbackInfo| {
                if let Ok(mut s) = a.lock() {
                    s(&downmix(d, channels, |x| f32::from(x) / 32768.0));
                }
            },
            on_error,
            None,
        ),
        _ => device.build_input_stream(
            config,
            move |d: &[f32], _: &cpal::InputCallbackInfo| {
                if let Ok(mut s) = b.lock() {
                    s(&downmix(d, channels, |x| x));
                }
            },
            on_error,
            None,
        ),
    };
    let stream = match built {
        Ok(s) => s,
        Err(e) => {
            let _ = ready.send(Err(MicError::Failed(e.to_string())));
            return;
        }
    };
    if let Err(e) = stream.play() {
        let _ = ready.send(Err(MicError::Failed(e.to_string())));
        return;
    }
    let _ = ready.send(Ok(rate));
    while !quit.load(Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    drop(stream);
}

#[cfg(test)]
mod tests;
