// SPDX-License-Identifier: GPL-3.0-or-later
//! `AudioPlaying` over the ring, the render core's shared state and the mixer thread.

use super::mixer::MixerCmd;
use super::stretch::HOP;
use super::{OutputStats, RenderShared};
use crate::clock::{AudioPlaying, AudioRenderStamp, Flushed, RestartHandler, Unavailable, host_nanos_now, lock};
use crate::ring::RingShared;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering::*};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::Thread;
use std::time::Duration;

pub(super) struct DevicePlayer {
    sample_rate: i64,
    render: Arc<RenderShared>,
    ring: Arc<RingShared>,
    tx: Sender<MixerCmd>,
    mixer: Thread,
    generation: AtomicI64,
    rate: Mutex<PlaybackRate>,
    flushed: Arc<Mutex<Flushed>>,
    latency_ns: Arc<AtomicU64>,
    restart: Mutex<Option<RestartHandler>>,
}

impl DevicePlayer {
    pub(super) fn new(
        sample_rate: i64,
        render: Arc<RenderShared>,
        ring: Arc<RingShared>,
        tx: Sender<MixerCmd>,
        mixer: Thread,
        flushed: Arc<Mutex<Flushed>>,
        latency_ns: Arc<AtomicU64>,
    ) -> DevicePlayer {
        DevicePlayer {
            sample_rate,
            render,
            ring,
            tx,
            mixer,
            generation: AtomicI64::new(0),
            rate: Mutex::new(PlaybackRate::ZERO),
            flushed,
            latency_ns,
            restart: Mutex::new(None),
        }
    }

    pub(super) fn latency(&self) -> Duration {
        Duration::from_nanos(self.latency_ns.load(Relaxed))
    }

    pub(super) fn stats(&self, ring_frames: usize) -> OutputStats {
        OutputStats {
            callbacks: self.render.callback_count(),
            underruns: self.render.underrun_count(),
            min_fill_frames: self.render.min_fill(),
            ring_frames,
        }
    }

    pub(super) fn take_interval_min_fill(&self) -> Option<u64> {
        self.render.take_interval_min_fill()
    }

    pub(super) fn underruns(&self) -> u64 {
        self.render.underrun_count()
    }

    /// Calls the restart handler (the clock re-seeks at its current position). No lock is held during the call.
    pub(super) fn fire_restart(&self) {
        let handler = lock(&self.restart).clone();
        if let Some(h) = handler {
            h();
        }
    }

    fn send(&self, cmd: MixerCmd) {
        let _ = self.tx.send(cmd);
        self.mixer.unpark();
    }
}

impl AudioPlaying for DevicePlayer {
    fn sample_rate(&self) -> i64 {
        self.sample_rate
    }

    fn prepare(&self) -> Result<(), Unavailable> {
        Ok(()) // the stream is up once `AudioOut::open` returned
    }

    fn start(&self) {
        self.render.playing.store(true, Release);
    }

    fn stop(&self) {
        self.render.playing.store(false, Release);
        self.send(MixerCmd::Stop);
    }

    fn set_rate(&self, rate: PlaybackRate) {
        *lock(&self.rate) = rate;
        // The ring is always 1x: the callback plays it |rate| times faster, pitch kept (paused keeps the last speed).
        if !rate.is_paused() {
            let m = rate.magnitude();
            self.render.set_speed(f64::from(m.num()) / f64::from(m.den()));
        }
    }

    fn seek(&self, position: Time) -> i64 {
        let generation = self.generation.fetch_add(1, AcqRel) + 1;
        self.render.begin_priming(generation);
        self.render.request_stretch_reset();
        let rate = *lock(&self.rate);
        self.send(MixerCmd::Seek { generation, anchor: position, rate });
        generation
    }

    fn flushed(&self) -> Flushed {
        *lock(&self.flushed)
    }

    fn consumed_at_epoch(&self) -> (i64, i64) {
        self.ring.consumed_at_epoch()
    }

    fn consumed_frames(&self) -> i64 {
        self.ring.consumed_frames()
    }

    fn last_render(&self) -> AudioRenderStamp {
        self.render.last_render()
    }

    fn host_nanoseconds(&self) -> i64 {
        host_nanos_now()
    }

    fn output_latency(&self) -> Time {
        let device = Time::new(i64::try_from(self.latency_ns.load(Relaxed)).unwrap_or(i64::MAX), 1_000_000_000);
        if self.render.stretching() { device + Time::new(HOP as i64, self.sample_rate) } else { device }
    }

    fn underrun_count(&self) -> u64 {
        self.render.underrun_count()
    }

    fn set_restart_handler(&self, handler: Option<RestartHandler>) {
        *lock(&self.restart) = handler;
    }
}
