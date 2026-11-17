//! The audio clock over the REAL render core, ring and `DevicePlayer` (only the device callback and the mixer thread are
//! played by the test). `ManualAudio` models a stretcher that is not there on the real output; these tests catch the
//! missing stage: at 2x the device must consume two ring frames per output frame, or the clock runs at 1x (seen on Windows
//! with a real audio device, where L L L stayed at about 1x).

use super::mixer::MixerCmd;
use super::player::DevicePlayer;
use super::{FlushGeneration, OutputConfig, RenderCore};
use crate::clock::{AudioClock, AudioPlaying, Flushed, ManualClock, PlaybackClock, SwitchingClock, host_nanos_now};
use crate::ring::{RingProducer, ring};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::atomic::{AtomicU64, Ordering::*};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Rig {
    clock: Arc<AudioClock>,
    core: RenderCore,
    producer: RingProducer,
    gate: Arc<FlushGeneration>,
    flushed: Arc<Mutex<Flushed>>,
    rx: Receiver<MixerCmd>,
    silent_callbacks: usize,
}

impl Rig {
    fn new() -> Rig {
        let (producer, consumer) =
            ring(super::ring_frames_for(&OutputConfig::default()), 240, Duration::from_millis(100));
        let gate = Arc::new(FlushGeneration::default());
        let core = RenderCore::new(consumer, Arc::clone(&gate), 240, 48_000);
        let flushed = Arc::new(Mutex::new(Flushed::default()));
        let (tx, rx) = channel();
        let player = Arc::new(DevicePlayer::new(
            48_000,
            core.shared(),
            producer.shared(),
            tx,
            std::thread::current(),
            Arc::clone(&flushed),
            Arc::new(AtomicU64::new(0)),
        ));
        let clock = AudioClock::new(player as Arc<dyn AudioPlaying>);
        Rig { clock, core, producer, gate, flushed, rx, silent_callbacks: 0 }
    }

    /// The mixer thread: applies a pending seek, then keeps the ring full with a steady tone.
    fn mix(&mut self) {
        while let Ok(cmd) = self.rx.try_recv() {
            if let MixerCmd::Seek { generation, .. } = cmd {
                let epoch = self.producer.flush();
                *self.flushed.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Flushed { generation, epoch, latency: 0 };
                self.gate.value.store(generation, Release);
            }
        }
        let room = self.producer.available_to_write();
        let tone: Vec<f32> = (0..room).map(|i| 0.25 * (i as f32 * 0.05).sin()).collect();
        self.producer.push(&tone, &tone);
    }

    /// `callbacks` device callbacks of 480 frames (10 ms of output each).
    fn play(&mut self, callbacks: usize) {
        for _ in 0..callbacks {
            self.mix();
            let (mut l, mut r) = (vec![0.0f32; 480], vec![0.0f32; 480]);
            if self.core.render(&mut l, &mut r, host_nanos_now()) {
                self.silent_callbacks += 1;
            }
            self.mix();
        }
    }

    fn seconds(&self) -> f64 {
        let t = self.clock.now();
        t.value() as f64 / t.timescale() as f64
    }
}

fn rate(n: i32) -> PlaybackRate {
    PlaybackRate::whole(n)
}

/// Seconds the clock moved during one second of output, after the 100 ms the restart needs to be heard.
fn advance_per_output_second(rig: &mut Rig) -> f64 {
    rig.play(10);
    let before = rig.seconds();
    rig.play(100);
    rig.seconds() - before
}

#[test]
fn clock_follows_the_rate_through_the_real_render_path() {
    for (r, expect) in [(1, 1.0), (2, 2.0), (4, 4.0), (8, 8.0)] {
        let mut rig = Rig::new();
        rig.clock.start(Time::new(10, 1), rate(r));
        let moved = advance_per_output_second(&mut rig);
        assert!(
            (moved - expect).abs() < 0.12 * expect,
            "rate {r}: the clock moved {moved} s in 1 s, expected {expect}"
        );
        assert!(!rig.clock.sample().1, "rate {r}: no stall");
        assert_eq!(rig.core.shared().underrun_count(), 0, "rate {r}: the ring never ran dry");
    }
}

#[test]
fn l_l_l_climbs_one_two_four_without_restarting_the_output() {
    let mut rig = Rig::new();
    rig.clock.start(Time::new(10, 1), rate(1));
    let mut moved = Vec::new();
    for r in [1, 2, 4, 8] {
        if r != 1 {
            rig.clock.set_rate(rate(r));
        }
        moved.push(advance_per_output_second(&mut rig));
    }
    for (m, expect) in moved.iter().zip([1.0, 2.0, 4.0, 8.0]) {
        assert!((m - expect).abs() < 0.15 * expect, "moved {moved:?}, expected 1, 2, 4, 8");
    }
}

#[test]
fn the_stretch_keeps_the_sound_audible_and_continuous() {
    let mut rig = Rig::new();
    rig.clock.start(Time::new(0, 1), rate(2));
    rig.play(100);
    assert!(rig.silent_callbacks < 12, "{} silent callbacks of 100", rig.silent_callbacks);
}

#[test]
fn handing_over_from_the_host_clock_keeps_the_rate() {
    let rig_clock = Rig::new();
    let host = Arc::new(ManualClock::new(Time::new(5, 1), rate(2)));
    let mut rig = rig_clock;
    let sw = SwitchingClock::new(Arc::clone(&host) as Arc<dyn PlaybackClock>, Some(Arc::clone(&rig.clock)));
    sw.start(Time::new(5, 1), rate(2));
    assert!(!sw.is_audio());
    sw.use_audio(true);
    assert!(sw.is_audio() && sw.rate() == rate(2));
    let moved = advance_per_output_second(&mut rig);
    assert!((moved - 2.0).abs() < 0.25, "after the host to audio switch the clock moved {moved} s per second at 2x");
}
