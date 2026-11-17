// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: AudioRetimeTests (clip level; the transition-handle test needs the edit crate's transitions)
use super::tests::*;
use super::*;
use sq_core_model::{AnimatedProperty, ClipSpeed, Timeline, TrackKind};
use sq_media::memory_audio_source::MemoryAudioSource;

fn frames(n: i64) -> Time {
    Time::new(n, 48_000)
}

fn retimed_clip(media: Id, src: i64, src_len: i64, at: i64, percent: i64, reversed: bool, keeps_pitch: bool) -> Clip {
    let mut c =
        Clip::new(media, "c", media, TrackKind::Audio, TimeRange::new(frames(src), frames(src_len)), frames(at));
    c.speed = ClipSpeed::new(percent * 100, 10_000);
    c.reversed = reversed;
    c.keeps_pitch = keeps_pitch;
    c
}

fn render(t: &Timeline, src: &Arc<dyn AudioSource>, m: Id, from: i64, count: usize, block: usize) -> Vec<f32> {
    let mut f = feeder([(m, Arc::clone(src))].into(), t, block);
    mixed(&mut f, t, from, count).0
}

fn tl(c: Clip) -> Timeline {
    timeline_of(vec![track(1, vec![c])])
}

fn sine(n: usize, hz: f64) -> Arc<dyn AudioSource> {
    Arc::new(MemoryAudioSource::mono(
        (0..n).map(|i| (2.0 * std::f64::consts::PI * hz * i as f64 / 48_000.0).sin() as f32).collect(),
    ))
}

fn rising_crossings(x: &[f32]) -> usize {
    x.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count()
}

#[test]
fn double_speed_resamples_every_other_source() {
    let m = id(1);
    let t = tl(retimed_clip(m, 0, 2000, 0, 200, false, false));
    let o = render(&t, &ramp(5000, 0.0), m, 0, 1200, 4096);
    for (i, v) in o.iter().enumerate().take(1000) {
        assert_eq!(*v, (2 * i) as f32 + 1.0, "frame {i}");
    }
    assert!(o[1000] == 0.0 && o[1199] == 0.0);
}

#[test]
fn reverse_at_normal_speed_is_a_bit_exact_mirror() {
    let m = id(1);
    let t = tl(retimed_clip(m, 100, 100, 50, 100, true, true));
    let o = render(&t, &ramp(1000, 0.0), m, 0, 300, 4096);
    assert!(o[49] == 0.0 && o[150] == 0.0);
    for i in 0..100 {
        assert_eq!(o[50 + i], (200 - i) as f32, "frame {i}"); // source index 199 - i holds 200 - i
    }
}

#[test]
fn reverse_at_200() {
    let m = id(1);
    let t = tl(retimed_clip(m, 0, 200, 0, 200, true, false));
    let o = render(&t, &ramp(1000, 0.0), m, 0, 120, 4096);
    for (i, v) in o.iter().enumerate().take(100) {
        assert_eq!(*v, (200 - 2 * i) as f32, "frame {i}");
    }
}

#[test]
fn block_split_gives_identical_samples() {
    let m = id(1);
    for (pct, rev) in [(200, false), (50, false), (200, true), (33, true)] {
        let t = tl(retimed_clip(m, 4000, 24_000, 700, pct, rev, true));
        let src = sine(60_000, 300.0);
        let whole = render(&t, &src, m, 0, 8192, 8192);
        let mut pieces = Vec::new();
        for s in (0..8192usize).step_by(1000) {
            pieces.extend(render(&t, &src, m, s as i64, 1000.min(8192 - s), 1024));
        }
        assert_eq!(pieces, whole, "{pct}% reversed={rev}");
    }
}

#[test]
fn time_stretch_keeps_pitch_and_resample_changes_it() {
    let m = id(1);
    let src = sine(200_000, 440.0);
    let kept = tl(retimed_clip(m, 0, 96_000, 0, 200, false, true));
    let resampled = tl(retimed_clip(m, 0, 96_000, 0, 200, false, false));
    let a = render(&kept, &src, m, 0, 8192, 8192);
    let b = render(&resampled, &src, m, 0, 8192, 8192);
    // 85.3 ms: 440 Hz = 37.5 cycles.
    let (ca, cb) = (rising_crossings(&a[4096..8192]), rising_crossings(&b[4096..8192]));
    assert!((35..=40).contains(&ca), "pitch kept: {ca} cycles");
    assert!((72..=78).contains(&cb), "pitch doubled: {cb} cycles");
}

#[test]
fn slowed_down_stretch_keeps_level_and_pitch() {
    let m = id(1);
    let t = tl(retimed_clip(m, 0, 48_000, 0, 50, false, true)); // 2 s
    let o = render(&t, &sine(200_000, 440.0), m, 0, 8192, 8192);
    let mx = o[2048..].iter().map(|v| v.abs()).fold(0.0, f32::max);
    assert!(mx > 0.9 && mx < 1.1);
    let c = rising_crossings(&o[2048..8192]);
    assert!((54..=59).contains(&c), "cycles {c}"); // 128 ms * 440
}

#[test]
fn first_hop_has_no_fade_in() {
    let m = id(1);
    let t = tl(retimed_clip(m, 10_000, 20_000, 0, 200, false, true));
    let src: Arc<dyn AudioSource> = Arc::new(MemoryAudioSource::mono(vec![1.0; 100_000]));
    let o = render(&t, &src, m, 0, 4096, 4096);
    assert!(o[0] == 1.0 && o[500] == 1.0);
    assert!((o[3000] - 1.0).abs() < 1e-5);
}

/// Audio Gain is part of `Clip::volume`, which every path uses: retimed and reversed output is gain x volume, once.
#[test]
fn gain_times_volume_applies_once_when_retimed_and_reversed() {
    let m = id(1);
    for (speed, rev) in [(200, false), (200, true), (50, false), (100, true)] {
        let clip = |gain: f64, volume: f64| {
            let mut c = retimed_clip(m, 0, 4000, 0, speed, rev, false);
            c.audio_gain_db = gain;
            c.animation.volume = AnimatedProperty::new(volume);
            c
        };
        let r = |c: Clip| render(&tl(c), &ramp(8000, 0.0), m, 0, 1000, 4096);
        let (base, gained, both) = (r(clip(0.0, 1.0)), r(clip(6.0206, 1.0)), r(clip(6.0206, 0.5)));
        for i in (0..1000).step_by(37) {
            assert!(
                (gained[i] - base[i] * 2.0).abs() <= base[i].abs() * 1e-3 + 1e-4,
                "gain x2 at {i}, {speed}% rev {rev}"
            );
            assert!((both[i] - base[i]).abs() <= base[i].abs() * 1e-3 + 1e-4, "gain x volume once at {i}");
        }
        assert!(base.iter().any(|v| *v != 0.0));
    }
}
