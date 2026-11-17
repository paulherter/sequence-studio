// Swift: AudioEngineTests.swift (AudioRenderCoreTests)
use super::*;
use crate::ring::{RingProducer, ring};
use std::time::Duration;

fn sine(range: std::ops::Range<usize>, phase: f64) -> Vec<f32> {
    range.map(|i| 0.5 * (2.0 * std::f64::consts::PI * 440.0 * i as f64 / 48_000.0 + phase).sin() as f32).collect()
}

fn push(p: &mut RingProducer, a: &[f32]) {
    p.push(a, a);
}

fn render(c: &mut RenderCore, n: usize) -> (Vec<f32>, bool) {
    let (mut l, mut r) = (vec![9.0f32; n], vec![9.0f32; n]);
    let s = c.render(&mut l, &mut r, 0);
    (l, s)
}

/// Feeder stand-in: a seek bumps the generation; `flush` = the feeder applying it (ring flush, then the lock-free gate).
struct FakeFeeder {
    producer: RingProducer,
    gate: Arc<FlushGeneration>,
    core: RenderCore,
    gen_: i64,
}

impl FakeFeeder {
    fn new(fade: usize) -> FakeFeeder {
        let (producer, consumer) = ring(1 << 14, fade, Duration::from_millis(100));
        let gate = Arc::new(FlushGeneration::default());
        let core = RenderCore::new(consumer, Arc::clone(&gate), fade, 48_000);
        FakeFeeder { producer, gate, core, gen_: 0 }
    }
    fn seek(&mut self) {
        self.gen_ += 1;
        self.core.shared().begin_priming(self.gen_);
    }
    fn flush(&mut self) {
        self.producer.flush();
        self.gate.value.store(self.gen_, Release);
    }
    fn play(&self, on: bool) {
        self.core.shared().playing.store(on, Release);
    }
}

fn max_step(x: &[f32]) -> f32 {
    x.windows(2).map(|w| (w[1] - w[0]).abs()).fold(0.0, f32::max)
}

#[test]
fn no_step_above_threshold_across_start_seek_rate_change_and_stop() {
    let mut f = FakeFeeder::new(240);
    let mut out: Vec<f32> = Vec::new();
    f.seek();
    f.flush();
    push(&mut f.producer, &sine(0..4096, 0.0));
    f.play(true);
    for _ in 0..4 {
        out.extend(render(&mut f.core, 512).0);
    }
    f.seek(); // one render before the feeder reacts plays old material
    out.extend(render(&mut f.core, 512).0);
    f.flush();
    push(&mut f.producer, &sine(10_000..14_096, std::f64::consts::PI));
    for _ in 0..4 {
        out.extend(render(&mut f.core, 512).0);
    }
    f.seek();
    f.flush();
    push(&mut f.producer, &sine(30_000..34_096, 1.3));
    for _ in 0..4 {
        out.extend(render(&mut f.core, 512).0);
    }
    f.play(false); // stop: 5 ms fade-out, then silence
    let (a, s1) = render(&mut f.core, 512);
    let (b, s2) = render(&mut f.core, 512);
    out.extend(&a);
    out.extend(&b);
    assert!(!s1 && s2 && b.iter().all(|&v| v == 0.0));
    assert!(a[240..].iter().all(|&v| v == 0.0));
    let natural = (0.5 * 2.0 * std::f64::consts::PI * 440.0 / 48_000.0) as f32;
    assert!(max_step(&out) < natural + 0.012, "max step {}", max_step(&out));
    assert_eq!(f.core.shared().underrun_count(), 0);
}

/// 375 Hz: 128 frames per period, so the 1024-frame grain steps of every stretch rate are whole periods.
fn steady_tone(i: usize) -> f32 {
    (0.5 * (2.0 * std::f64::consts::PI * 375.0 * i as f64 / 48_000.0 + 1.0).sin()) as f32
}

fn refill_tone(f: &mut FakeFeeder, next: &mut usize) {
    let room = f.producer.available_to_write();
    let a: Vec<f32> = (*next..*next + room).map(steady_tone).collect();
    push(&mut f.producer, &a);
    *next += room;
}

/// A rate change restarts the feeder where the reader stands; the stretch must keep the sound going through the switch.
#[test]
fn a_steady_tone_through_every_shuttle_step_has_no_click() {
    let mut f = FakeFeeder::new(240);
    let mut next = 0usize;
    f.seek();
    f.flush();
    refill_tone(&mut f, &mut next);
    f.play(true);
    let mut out: Vec<f32> = Vec::new();
    for speed in [1.0, 2.0, 4.0, 8.0, 2.0, 1.0] {
        f.core.shared().set_speed(speed);
        f.seek();
        let reader = next - f.producer.shared().available_to_read();
        f.flush();
        next = reader;
        refill_tone(&mut f, &mut next);
        for _ in 0..30 {
            out.extend(render(&mut f.core, 480).0);
            refill_tone(&mut f, &mut next);
        }
    }
    let natural = (0.5 * 2.0 * std::f64::consts::PI * 375.0 / 48_000.0) as f32;
    let step = max_step(&out[960..]);
    assert!(step < 1.2 * natural + 0.002, "max step {step} against the tone's own {natural}");
    assert!(out[960..].iter().any(|v| v.abs() > 0.4), "the tone is audible");
    assert_eq!(f.core.shared().underrun_count(), 0);
}

#[test]
fn priming_waits_silently_and_is_not_an_underrun() {
    let mut f = FakeFeeder::new(240);
    f.play(true);
    f.seek();
    assert!(render(&mut f.core, 512).1); // feeder has not flushed: silence (was not playing)
    f.flush();
    push(&mut f.producer, &[1.0; 100]);
    assert!(render(&mut f.core, 512).1); // flushed, less than one render call queued
    assert_eq!(f.core.ring_shared.consumed_frames(), 0);
    assert_eq!(f.core.shared().underrun_count(), 0);
    push(&mut f.producer, &[1.0; 1000]);
    let (o, silent) = render(&mut f.core, 512);
    assert!(!silent && o[511] == 1.0 && f.core.ring_shared.consumed_frames() == 512);
}

#[test]
fn shortage_while_playing_counts_an_underrun() {
    let mut f = FakeFeeder::new(0);
    f.seek();
    f.flush();
    push(&mut f.producer, &[1.0; 600]);
    f.play(true);
    render(&mut f.core, 512);
    assert_eq!(f.core.shared().underrun_count(), 0);
    let (o, _) = render(&mut f.core, 512);
    assert!(f.core.shared().underrun_count() == 1 && o[87] == 1.0 && o[88] == 0.0);
}

/// A stale flush (older generation) must not end priming: its audio would leak in before the new seek's flush.
#[test]
fn priming_waits_for_this_generations_flush_not_any_flush() {
    let mut f = FakeFeeder::new(0);
    f.seek();
    f.flush();
    push(&mut f.producer, &[1.0; 2000]);
    f.play(true);
    render(&mut f.core, 512);
    f.seek(); // generation 2 requested
    f.gen_ -= 1;
    f.flush();
    f.gen_ += 1; // a stale flush (generation 1) lands after the seek
    let (o, _) = render(&mut f.core, 512); // still priming: the (empty) old path, not an underrun
    assert!(o.iter().all(|&v| v == 0.0) && f.core.shared().underrun_count() == 0);
    f.flush();
    push(&mut f.producer, &[3.0; 2000]);
    assert!(render(&mut f.core, 512).0.iter().all(|&v| v == 3.0));
    assert_eq!(f.core.shared().underrun_count(), 0);
}

/// begin_priming racing the render thread's completion is never lost.
#[test]
fn newer_priming_during_priming_is_kept() {
    let mut f = FakeFeeder::new(0);
    f.play(true);
    f.seek();
    f.flush();
    push(&mut f.producer, &[1.0; 600]);
    f.seek(); // second seek before the first was primed
    assert!(render(&mut f.core, 512).1); // generation 1's flush does not complete priming
    f.flush();
    push(&mut f.producer, &[2.0; 1000]);
    assert!(render(&mut f.core, 512).0.iter().all(|&v| v == 2.0));
}

#[test]
fn render_stamps_feed_the_clock() {
    let mut f = FakeFeeder::new(0);
    f.seek();
    f.flush();
    push(&mut f.producer, &[1.0; 2000]);
    f.play(true);
    let (mut l, mut r) = (vec![0.0f32; 300], vec![0.0f32; 300]);
    f.core.render(&mut l, &mut r, 1234);
    assert_eq!(f.core.shared().last_render(), AudioRenderStamp { frames: 300, quantum: 300, host_nanos: 1234 });
}

#[test]
fn interleaved_fill_splits_long_callbacks_and_pads_extra_channels() {
    let mut f = FakeFeeder::new(0);
    f.seek();
    f.flush();
    let n = MAX_CHUNK_FRAMES + 100;
    let v: Vec<f32> = (0..n).map(|i| i as f32).collect();
    f.producer = {
        // a bigger ring for this test
        let (mut p, c) = ring(n * 2, 0, Duration::from_millis(100));
        f.core = RenderCore::new(c, Arc::clone(&f.gate), 0, 48_000);
        f.core.shared().begin_priming(1);
        p.push(&v, &v);
        p
    };
    f.play(true);
    let mut data = vec![-1.0f32; n * 3];
    f.core.fill_interleaved(&mut data, 3, 10);
    assert!((0..n).all(|j| data[j * 3] == j as f32 && data[j * 3 + 1] == j as f32 && data[j * 3 + 2] == 0.0));
    assert_eq!(f.core.shared().last_render().frames, n as i64);
}

struct Steady(f32);
impl SideVoice for Steady {
    fn render(&mut self, l: &mut [f32], r: &mut [f32]) -> bool {
        l.fill(self.0);
        r.fill(-self.0);
        false
    }
}

#[test]
fn a_side_voice_sounds_while_the_ring_is_stopped_and_adds_to_it_while_playing() {
    let mut f = FakeFeeder::new(0);
    f.core.set_side_voice(Some(Box::new(Steady(0.25))));
    let (mut l, mut r) = (vec![0.0f32; 64], vec![0.0f32; 64]);
    let silent = f.core.render(&mut l, &mut r, 0);
    assert!(!silent, "the voice is sound");
    assert!(l.iter().all(|v| *v == 0.25) && r.iter().all(|v| *v == -0.25), "stopped ring + voice = voice");
    f.core.set_side_voice(None);
    let (_, silent) = render(&mut f.core, 64);
    assert!(silent, "without the voice the stopped output is silence again");
}
