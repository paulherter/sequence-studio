// SPDX-License-Identifier: GPL-3.0-or-later
//! Mixer thread: pulls the `Renderer` and fills the ring; handles seeks (renderer flush + ring flush + generation gate).

use super::{BLOCK_FRAMES, FlushGeneration, Renderer};
use crate::clock::{Flushed, lock};
use crate::ring::RingProducer;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::atomic::Ordering::Release;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub(super) enum MixerCmd {
    /// Restart production at `anchor` going at `rate`; `generation` is the one `seek` returned.
    Seek {
        generation: i64,
        anchor: Time,
        rate: PlaybackRate,
    },
    /// Stop producing (the output fades out what is in the ring).
    Stop,
    Quit,
}

pub(super) fn spawn(
    renderer: Box<dyn Renderer>,
    producer: RingProducer,
    gate: Arc<FlushGeneration>,
    flushed: Arc<Mutex<Flushed>>,
    rx: Receiver<MixerCmd>,
) -> std::io::Result<JoinHandle<()>> {
    thread::Builder::new().name("sq-audio-mixer".into()).spawn(move || run(renderer, producer, gate, flushed, rx))
}

fn run(
    mut renderer: Box<dyn Renderer>,
    mut producer: RingProducer,
    gate: Arc<FlushGeneration>,
    flushed: Arc<Mutex<Flushed>>,
    rx: Receiver<MixerCmd>,
) {
    let mut producing = false;
    let mut block = vec![0.0f32; BLOCK_FRAMES * 2];
    let mut l = vec![0.0f32; BLOCK_FRAMES];
    let mut r = vec![0.0f32; BLOCK_FRAMES];
    loop {
        loop {
            match rx.try_recv() {
                Ok(MixerCmd::Quit) | Err(TryRecvError::Disconnected) => return,
                Ok(MixerCmd::Stop) => producing = false,
                Ok(MixerCmd::Seek { generation, anchor, rate }) => {
                    renderer.flush(anchor, rate);
                    let latency = i64::from(renderer.latency_frames());
                    let epoch = producer.flush();
                    *lock(&flushed) = Flushed { generation, epoch, latency };
                    gate.value.store(generation, Release);
                    producing = !rate.is_paused();
                }
                Err(TryRecvError::Empty) => break,
            }
        }
        if producing && producer.available_to_write() >= BLOCK_FRAMES {
            renderer.render(&mut block);
            for ((l, r), frame) in l.iter_mut().zip(r.iter_mut()).zip(block.chunks(2)) {
                *l = frame[0];
                *r = frame[1];
            }
            producer.push(&l, &r);
        } else {
            // The callback unparks us after each pop; the timeout covers a missed wake-up and Windows timer granularity
            // (the 170 ms ring has headroom, g6 min fill 150 ms).
            thread::park_timeout(Duration::from_millis(4));
        }
    }
}
