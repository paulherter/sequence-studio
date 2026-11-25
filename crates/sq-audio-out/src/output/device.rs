// SPDX-License-Identifier: GPL-3.0-or-later
//! Device thread: owns the cpal stream, reports stream errors and rebuilds the stream when the device was invalidated.
//!
//! What cpal 0.18 reports (g6 REPORT, read from its source): CoreAudio emits `StreamInvalidated` (rate change, device
//! gone) or `DeviceChanged` (rerouted, still running); WASAPI never rebinds, a changed or removed default device gives
//! `StreamInvalidated` / `DeviceNotAvailable`. We rebuild on the first two and re-anchor on the third.

use super::{AudioOutError, OutputConfig, OutputEvent, player::DevicePlayer, render_core::RenderCore};
use crate::clock::host_nanos_now;
use cpal::traits::{DeviceTrait, StreamTrait};
use cpal::{BufferSize, StreamConfig};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle, Thread};
use std::time::{Duration, Instant};

pub(super) enum DeviceMsg {
    /// Stream rerouted by the system, still running.
    Changed,
    /// The stream is dead (device removed or format changed): rebuild.
    Invalidated,
    Quit,
}

pub(super) struct DeviceSetup {
    pub cfg: OutputConfig,
    pub core: Arc<Mutex<RenderCore>>,
    pub latency_ns: Arc<AtomicU64>,
    pub mixer: Thread,
    pub events: Sender<OutputEvent>,
    pub player: Arc<DevicePlayer>,
    pub tx: Sender<DeviceMsg>,
    pub rx: Receiver<DeviceMsg>,
}

/// Starts the device thread and waits until the first stream plays (or failed).
pub(super) fn spawn(setup: DeviceSetup) -> Result<JoinHandle<()>, AudioOutError> {
    let (ready_tx, ready_rx) = channel();
    let handle = thread::Builder::new()
        .name("sq-audio-device".into())
        .spawn(move || run(setup, ready_tx))
        .map_err(|e| AudioOutError::Thread(e.to_string()))?;
    match ready_rx.recv() {
        Ok(Ok(())) => Ok(handle),
        Ok(Err(e)) => {
            let _ = handle.join();
            Err(e)
        }
        Err(_) => Err(AudioOutError::Thread("device thread ended before the stream was up".into())),
    }
}

fn build(s: &DeviceSetup) -> Result<cpal::Stream, AudioOutError> {
    let host = cpal::default_host();
    let dev = super::devices::pick(&host).ok_or(AudioOutError::NoDevice)?;
    let config = StreamConfig {
        channels: s.cfg.channels,
        sample_rate: s.cfg.sample_rate,
        buffer_size: s.cfg.buffer_frames.map(BufferSize::Fixed).unwrap_or(BufferSize::Default),
    };
    let channels = usize::from(s.cfg.channels);
    let core = Arc::clone(&s.core);
    let latency = Arc::clone(&s.latency_ns);
    let mixer = s.mixer.clone();
    let err_tx = s.tx.clone();
    let stream = dev
        .build_output_stream(
            config,
            move |data: &mut [f32], info: &cpal::OutputCallbackInfo| {
                let _cb = sq_os::trace::span_args("audio", "audio callback", || {
                    format!("frames={}", data.len() / channels.max(1))
                });
                let raw = host_nanos_now();
                let ts = info.timestamp();
                let lat = ts.playback.saturating_duration_since(ts.callback).as_nanos();
                latency.store(u64::try_from(lat).unwrap_or(u64::MAX), Relaxed);
                // The core is only ever touched here, one callback at a time: `try_lock` is a single atomic and never
                // blocks. (Held across a rebuild by the same `Arc`, hence the mutex instead of moving it.)
                match core.try_lock() {
                    Ok(mut c) => c.fill_interleaved(data, channels, raw),
                    Err(_) => data.fill(0.0),
                }
                mixer.unpark();
            },
            move |e: cpal::Error| {
                use cpal::ErrorKind;
                let _ = match e.kind() {
                    ErrorKind::DeviceChanged => err_tx.send(DeviceMsg::Changed),
                    ErrorKind::StreamInvalidated | ErrorKind::DeviceNotAvailable => err_tx.send(DeviceMsg::Invalidated),
                    _ => Ok(()),
                };
            },
            None,
        )
        .map_err(|e| AudioOutError::Build(e.to_string()))?;
    stream.play().map_err(|e| AudioOutError::Build(e.to_string()))?;
    Ok(stream)
}

fn run(setup: DeviceSetup, ready: Sender<Result<(), AudioOutError>>) {
    let mut stream = match build(&setup) {
        Ok(s) => {
            let _ = ready.send(Ok(()));
            Some(s)
        }
        Err(e) => {
            let _ = ready.send(Err(e));
            return;
        }
    };
    let mut reported_underruns = 0u64;
    let mut seen_choice = super::devices::changes();
    loop {
        match setup.rx.recv_timeout(Duration::from_millis(100)) {
            Ok(DeviceMsg::Quit) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(DeviceMsg::Changed) => {
                let _ = setup.events.send(OutputEvent::DeviceChanged);
                setup.player.fire_restart();
            }
            Ok(DeviceMsg::Invalidated) => {
                let _ = setup.events.send(OutputEvent::StreamInvalidated);
                drop(stream.take());
                match rebuild(&setup) {
                    Some(s) => stream = Some(s),
                    None => break, // asked to quit while waiting for a device
                }
                let latency = Duration::from_nanos(setup.latency_ns.load(Relaxed));
                let _ = setup.events.send(OutputEvent::Rebuilt { latency });
                setup.player.fire_restart();
            }
            Err(RecvTimeoutError::Timeout) => {
                // The user picked another output in Preferences: rebuild the stream on it.
                let choice = super::devices::changes();
                if choice != seen_choice {
                    seen_choice = choice;
                    let _ = setup.tx.send(DeviceMsg::Invalidated);
                }
                let u = setup.player.underruns();
                if u > reported_underruns {
                    let _ = setup
                        .events
                        .send(OutputEvent::Underrun(u32::try_from(u - reported_underruns).unwrap_or(u32::MAX)));
                    reported_underruns = u;
                }
            }
        }
    }
    drop(stream);
}

/// Builds a new stream, retrying every 500 ms until a device is there. `None` = quit requested meanwhile.
fn rebuild(setup: &DeviceSetup) -> Option<cpal::Stream> {
    let started = Instant::now();
    let mut lost_reported = false;
    loop {
        if let Ok(s) = build(setup) {
            // Errors the dead stream queued must not trigger another rebuild.
            while let Ok(m) = setup.rx.try_recv() {
                if matches!(m, DeviceMsg::Quit) {
                    return None;
                }
            }
            return Some(s);
        }
        if !lost_reported && started.elapsed() > Duration::from_secs(10) {
            lost_reported = true;
            let _ = setup.events.send(OutputEvent::DeviceLost);
        }
        match setup.rx.recv_timeout(Duration::from_millis(500)) {
            Ok(DeviceMsg::Quit) | Err(RecvTimeoutError::Disconnected) => return None,
            _ => {}
        }
    }
}
