// Swift: ShuttleStretchTests.swift
use super::*;

/// 375 Hz at 48 kHz: 128 frames per period, so a 2x grain step (2048 frames) is a whole number of periods and the
/// overlap-add sums in phase.
fn tone(i: usize) -> f32 {
    (2.0 * std::f64::consts::PI * 375.0 * i as f64 / 48_000.0).sin() as f32
}

/// Renders `frames` output frames at `rate` from a continuous tone; returns the output and the input frames pulled.
fn run(rate: f64, frames: usize) -> (Vec<f32>, usize) {
    let mut s = ShuttleStretch::new();
    let (mut l, mut r) = (vec![0.0f32; frames], vec![0.0f32; frames]);
    let mut pulled = 0usize;
    s.render(rate, &mut l, &mut r, frames, &mut |a: &mut [f32], b: &mut [f32]| {
        for (x, y) in a.iter_mut().zip(b.iter_mut()) {
            *x = tone(pulled);
            *y = *x;
            pulled += 1;
        }
    });
    (l, pulled)
}

fn rising_crossings(x: &[f32]) -> usize {
    x.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count()
}

#[test]
fn consumes_rate_times_the_output_frames_from_the_source() {
    for (rate, expect) in [(0.5, 24_000usize), (1.0, 48_000), (2.0, 96_000), (4.0, 192_000), (8.0, 384_000)] {
        let (_, pulled) = run(rate, 48_000);
        // The grains pull in whole steps of `rate * HOP` plus the 2 * HOP window.
        let slack = (rate as usize + 2) * HOP + 1;
        assert!(pulled.abs_diff(expect) <= slack, "rate {rate}: pulled {pulled}, expected about {expect}");
    }
}

#[test]
fn rate_one_reproduces_the_input_after_the_first_hop() {
    let (out, _) = run(1.0, 8 * HOP);
    for (i, o) in out.iter().enumerate().skip(HOP) {
        assert!((o - tone(i)).abs() < 1e-4, "frame {i}: {o} vs {}", tone(i));
    }
}

#[test]
fn keeps_the_pitch_at_double_speed() {
    let (out, _) = run(2.0, 48_000);
    let n = rising_crossings(&out[HOP..]);
    // One second of 375 Hz is 375 rising crossings; resampling at 2x would give 750.
    assert!((360..=390).contains(&n), "{n} crossings");
}

#[test]
fn restart_forgets_everything_and_continues_the_straight_stream() {
    let mut s = ShuttleStretch::new();
    let (mut l, mut r) = (vec![0.0f32; 100], vec![0.0f32; 100]);
    s.render(2.0, &mut l, &mut r, 100, &mut |a: &mut [f32], b: &mut [f32]| {
        a.fill(0.5);
        b.fill(0.5);
    });
    s.restart();
    let mut pulled = 0usize;
    s.render(2.0, &mut l, &mut r, 100, &mut |a: &mut [f32], b: &mut [f32]| {
        pulled += a.len();
        a.fill(0.25);
        b.fill(0.25);
    });
    assert_eq!(pulled, 2 * HOP, "the first grain after a restart reads a fresh window");
    // Seeded: the first output frames are the input itself, not a rise from zero.
    assert!(l.iter().all(|v| (v - 0.25).abs() < 1e-5), "{:?}", &l[..4]);
}

#[test]
fn reset_input_keeps_the_grain_in_flight() {
    let mut s = ShuttleStretch::new();
    let (mut l, mut r) = (vec![0.0f32; 2 * HOP], vec![0.0f32; 2 * HOP]);
    let mut steady = |a: &mut [f32], b: &mut [f32]| {
        a.fill(0.5);
        b.fill(0.5);
    };
    s.restart();
    s.render(2.0, &mut l, &mut r, 2 * HOP, &mut steady);
    s.reset_input();
    let mut pulled = 0usize;
    s.render(4.0, &mut l[..300], &mut r[..300], 300, &mut |a: &mut [f32], b: &mut [f32]| {
        pulled += a.len();
        a.fill(0.5);
        b.fill(0.5);
    });
    assert!(pulled > 0, "the input is fetched again");
    // The output stays at the tone's level: it neither drops to zero nor jumps.
    assert!(l[..300].iter().all(|v| (v - 0.5).abs() < 1e-3), "{:?}", &l[..4]);
}

#[test]
fn leaving_the_stretch_continues_a_steady_level_into_the_straight_stream() {
    let mut s = ShuttleStretch::new();
    let (mut l, mut r) = (vec![0.0f32; 1500], vec![0.0f32; 1500]);
    s.restart();
    s.render(2.0, &mut l, &mut r, 1500, &mut |a: &mut [f32], b: &mut [f32]| {
        a.fill(0.5);
        b.fill(0.5);
    });
    let mut done = false;
    for _ in 0..6 {
        let (mut sl, mut sr) = (vec![0.5f32; 480], vec![0.5f32; 480]);
        done = s.drain_into(&mut sl, &mut sr, 480);
        assert!(sl.iter().all(|v| (v - 0.5).abs() < 1e-3), "steady in, steady out");
        if done {
            break;
        }
    }
    assert!(done, "the fall is over after about two grains");
}

#[test]
fn leaving_a_paused_stretch_starts_the_straight_stream_at_once() {
    let mut s = ShuttleStretch::new();
    s.restart();
    let (mut sl, mut sr) = (vec![0.5f32; 480], vec![0.5f32; 480]);
    assert!(s.drain_into(&mut sl, &mut sr, 480));
    assert!(sl.iter().all(|v| *v == 0.5));
}

#[test]
fn extreme_rates_are_clamped_and_stay_inside_the_buffers() {
    for rate in [0.0, 1e-9, 1000.0] {
        let (out, _) = run(rate, 4 * HOP);
        assert!(out.iter().all(|v| v.is_finite()));
    }
}
