// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: AudioDeClickFeederTests, LiveDuckingSilenceFeederTests, SpeedKeysAudioTests (Bleep needs the edit crate's
// `bleep`; the live-ducking tests of AudioFeederMasterTests ride on the same duck path)
use super::tests::*;
use super::*;
use crate::audio::WaveformSilences;
use sq_core_audio::live_ducking::LiveDucking;
use sq_core_model::{ClipSpeed, SequenceFormat, SpeedKeys, SpeedSegment, Timeline, TrackKind};
use sq_media::memory_audio_source::MemoryAudioSource;

fn pct(p: f64) -> ClipSpeed {
    ClipSpeed::from_percent(p)
}

fn seg(duration: Time, from: f64, to: Option<f64>, reversed: bool) -> SpeedSegment {
    SpeedSegment::new(duration, pct(from), to.map(pct), reversed, None)
}

fn max_step(x: &[f32]) -> f32 {
    x.windows(2).map(|w| (w[1] - w[0]).abs()).fold(0.0, f32::max)
}

// MARK: de-click

/// Two loud DC clips of opposite sign, butted together: a hard cut with a full-scale jump.
fn hard_cut() -> (Timeline, Sources) {
    let (a, b) = (id(1), id(2));
    let t = timeline_of(vec![track(1, vec![clip(a, 0, 2000, frames(1000)), clip(b, 0, 2000, frames(3000))])]);
    (t, [(a, constant(0.8, 4000)), (b, constant(-0.8, 4000))].into())
}

fn faded(t: &Timeline, s: &Sources, fade: i64, block: usize) -> AudioFeeder {
    let f = feeder(s.clone(), t, block);
    f.handle().set_declick_frames(fade);
    f
}

#[test]
fn without_fade_the_hard_cut_jumps() {
    let (t, s) = hard_cut();
    let o = mixed(&mut faded(&t, &s, 0, 8192), &t, 0, 5000).0;
    assert!(max_step(&o) >= 1.6 - 0.001); // 0.8 -> -0.8 in one sample
}

#[test]
fn with_fade_no_discontinuity_at_cut_or_clip_edges() {
    let (t, s) = hard_cut();
    let o = mixed(&mut faded(&t, &s, 144, 8192), &t, 0, 5000).0;
    assert!(max_step(&o) <= 0.8 / 144.0 + 1e-6);
    assert!(o[2999] == 0.0 && o[3000] == 0.0, "silent on both sides of the cut");
    assert!(o[1000] == 0.0 && o[4999] == 0.0, "outer edges too");
    assert!(o[1500] == 0.8 && o[3500] == -0.8, "interior untouched");
}

#[test]
fn de_click_block_split_gives_identical_samples() {
    // Playback blocks and export blocks differ in size; the samples must not.
    let (t, s) = hard_cut();
    let whole = mixed(&mut faded(&t, &s, 144, 8192), &t, 0, 5000).0;
    let mut f = faded(&t, &s, 144, 700);
    let mut pieces = Vec::new();
    for st in (0..5000usize).step_by(700) {
        pieces.extend(mixed(&mut f, &t, st as i64, 700.min(5000 - st)).0);
    }
    assert_eq!(pieces, whole);
}

#[test]
fn the_block_path_fades_too() {
    // The feeder thread path (playback and export) goes through the same mix as `mix`.
    let (t, s) = hard_cut();
    let mut f = faded(&t, &s, 144, 1000);
    f.handle().seek(0, false);
    let l = pull(&mut f, 5);
    assert!(max_step(&l) <= 0.8 / 144.0 + 1e-6);
    assert!(l[2999] == 0.0 && l[3000] == 0.0);
}

// MARK: live ducking with dialogue pauses

fn duck_timeline(d: Id, m: Id) -> Timeline {
    let len = TimeRange::new(Time::ZERO, Time::new(20, 1));
    let mk = |n: u128, media: Id, role| {
        let mut c = Clip::new(id(100 + n), "c", media, TrackKind::Audio, len, Time::ZERO);
        c.audio_tag = None;
        let mut t = track(n, vec![c]);
        t.audio_role = Some(role);
        t
    };
    Timeline::new(
        id(9999),
        "t",
        SequenceFormat::new(Time::new(1, 30)),
        vec![mk(1, d, AudioTag::Dialogue), mk(2, m, AudioTag::Music)],
    )
}

/// Mixer where dialogue is silent (only the music is heard) and music is a constant 0.5.
fn duck_feeder(t: &Timeline, d: Id, m: Id) -> AudioFeeder {
    let f = feeder([(d, constant(0.0, 20 * 48_000)), (m, constant(0.5, 20 * 48_000))].into(), t, 1024);
    f.handle().set_live_ducking(Some(LiveDucking::new(12.0, sq_core_audio::ducking::Ducking::DEFAULT_FADE)));
    f
}

fn sample(f: &mut AudioFeeder, t: &Timeline, seconds: f64) -> f32 {
    mixed(f, t, (seconds * 48_000.0) as i64, 256).0[128]
}

#[test]
fn a_pause_in_the_dialogue_releases_the_music() {
    let (d, m) = (id(1), id(2));
    let t = duck_timeline(d, m);
    let mut f = duck_feeder(&t, d, m);
    let s = WaveformSilences::new(true);
    s.set_waveform(Some(Arc::new(crate::audio::silences::test_waveform())), d);
    f.handle().set_dialogue_silences(Some(Arc::new(s)));
    let ducked = 0.5 * 10f32.powf(-12.0 / 20.0);
    assert!((sample(&mut f, &t, 2.0) - ducked).abs() < 1e-4);
    assert!((sample(&mut f, &t, 6.5) - 0.5).abs() < 1e-4);
    assert!((sample(&mut f, &t, 10.0) - ducked).abs() < 1e-4);
}

#[test]
fn without_silence_data_the_whole_clip_ducks() {
    let (d, m) = (id(1), id(2));
    let t = duck_timeline(d, m);
    let mut f = duck_feeder(&t, d, m);
    f.handle().set_dialogue_silences(Some(Arc::new(WaveformSilences::new(true)))); // waveform not read yet
    let ducked = 0.5 * 10f32.powf(-12.0 / 20.0);
    assert!((sample(&mut f, &t, 6.5) - ducked).abs() < 1e-4);
}

#[test]
fn the_duck_index_and_the_timeline_walk_agree() {
    let (d, m) = (id(1), id(2));
    let t = duck_timeline(d, m);
    let mut a = duck_feeder(&t, d, m);
    let mut b = duck_feeder(&t, d, m);
    b.uses_duck_index = false;
    a.handle().seek(48_000, false);
    b.handle().seek(48_000, false);
    assert_eq!(pull(&mut a, 3), pull(&mut b, 3));
}

// MARK: speed tracks

/// An audio clip with a speed track.
fn keyed_clip(media: Id, segs: Vec<SpeedSegment>, origin: Time, keeps_pitch: bool, at: Time) -> Clip {
    let mut c = Clip::new(media, "k", media, TrackKind::Audio, TimeRange::new(origin, Time::new(1, 1)), at);
    c.keeps_pitch = keeps_pitch;
    c.set_speed_keys(Some(SpeedKeys::new(segs, origin)));
    c
}

fn render_keyed(c: &Clip, src: &Arc<dyn AudioSource>, from: i64, count: usize, block: usize) -> Vec<f32> {
    let t = timeline_of(vec![track(1, vec![c.clone()])]);
    let mut f = feeder([(c.media, Arc::clone(src))].into(), &t, block);
    mixed(&mut f, &t, from, count).0
}

fn sine(n: usize, hz: f64) -> Arc<dyn AudioSource> {
    Arc::new(MemoryAudioSource::mono(
        (0..n).map(|i| (2.0 * std::f64::consts::PI * hz * i as f64 / 48_000.0).sin() as f32).collect(),
    ))
}

#[test]
fn keyed_resample_follows_the_two_segments() {
    let m = id(1);
    let c = keyed_clip(
        m,
        vec![seg(Time::new(1, 48), 100.0, None, false), seg(Time::new(1, 48), 200.0, None, false)],
        Time::ZERO,
        false,
        Time::ZERO,
    );
    let o = render_keyed(&c, &ramp(10_000, 0.0), 0, 2100, 4096);
    for (i, v) in o.iter().enumerate().take(1000) {
        assert!((v - (i + 1) as f32).abs() < 1e-3, "frame {i}");
    }
    for j in 0..900 {
        assert!((o[1000 + j] - (1000 + 2 * j + 1) as f32).abs() < 1e-3, "frame {}", 1000 + j);
    }
}

#[test]
fn source_follows_the_ramp_closed_form() {
    // 100 % -> 300 % over 2000 output frames: source(o) = o + o^2 / 2000 (in frames).
    let m = id(1);
    let c = keyed_clip(m, vec![seg(Time::new(2000, 48_000), 100.0, Some(300.0), false)], Time::ZERO, false, Time::ZERO);
    let o = render_keyed(&c, &ramp(20_000, 0.0), 0, 2000, 4096);
    for i in (0..2000).step_by(97) {
        let want = i as f64 + (i * i) as f64 / 2000.0 + 1.0;
        assert!((f64::from(o[i]) - want).abs() < 0.01, "frame {i}");
    }
}

fn crossings(x: &[f32]) -> usize {
    x.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count()
}

#[test]
fn pitch_is_kept_across_a_ramp_only_when_asked() {
    let m = id(1);
    let segs = vec![seg(Time::new(1, 1), 100.0, None, false), seg(Time::new(1, 1), 200.0, None, false)];
    let src = sine(200_000, 440.0);
    let kept = render_keyed(&keyed_clip(m, segs.clone(), Time::ZERO, true, Time::ZERO), &src, 0, 96_000, 96_000);
    let vari = render_keyed(&keyed_clip(m, segs, Time::ZERO, false, Time::ZERO), &src, 0, 96_000, 96_000);
    // Second second: 440 Hz kept vs 880 Hz when the pitch follows the speed.
    let secs = 40_000.0 / 48_000.0;
    assert!((crossings(&kept[52_000..92_000]) as f64 / secs - 440.0).abs() < 30.0);
    assert!((crossings(&vari[52_000..92_000]) as f64 / secs - 880.0).abs() < 40.0);
}

#[test]
fn keyed_block_split_gives_identical_samples() {
    let m = id(1);
    let segs = vec![
        seg(Time::new(1, 4), 80.0, None, false),
        seg(Time::new(1, 4), 80.0, Some(300.0), false),
        seg(Time::new(1, 4), 300.0, None, false),
    ];
    for keeps in [true, false] {
        let c = keyed_clip(m, segs.clone(), Time::new(4000, 48_000), keeps, Time::new(700, 48_000));
        let src = sine(120_000, 300.0);
        let whole = render_keyed(&c, &src, 0, 8192, 8192);
        let mut pieces = Vec::new();
        for s in (0..8192usize).step_by(1000) {
            pieces.extend(render_keyed(&c, &src, s as i64, 1000.min(8192 - s), 1024));
        }
        assert_eq!(pieces, whole, "keeps_pitch {keeps}");
    }
}

#[test]
fn one_segment_track_matches_the_constant_clip() {
    let m = id(1);
    let mut plain = Clip::new(
        m,
        "p",
        m,
        TrackKind::Audio,
        TimeRange::new(Time::new(2000, 48_000), Time::new(4000, 48_000)),
        Time::ZERO,
    );
    plain.speed = pct(200.0);
    plain.keeps_pitch = false;
    let src = ramp(20_000, 0.0);
    let want = render_keyed(&plain, &src, 0, 2100, 4096);
    plain.set_speed_keys(Some(SpeedKeys::of(&plain)));
    let got = render_keyed(&plain, &src, 0, 2100, 4096);
    for i in 0..2100 {
        assert!((got[i] - want[i]).abs() < 1e-3, "frame {i}");
    }
}

#[test]
fn reversed_segment_plays_backwards() {
    let m = id(1);
    let c = keyed_clip(
        m,
        vec![seg(Time::new(1000, 48_000), 100.0, None, false), seg(Time::new(500, 48_000), 100.0, None, true)],
        Time::ZERO,
        false,
        Time::ZERO,
    );
    let o = render_keyed(&c, &ramp(5000, 0.0), 0, 1600, 4096);
    assert!((o[999] - 1000.0).abs() < 1e-3);
    assert!(o[1100] < o[1010] && o[1010] < o[999] + 1.0);
}

// MARK: gain, fader and pan change the played samples (the Premiere-import gap: gain, track volume, pan, mute)

fn level_of(edit: impl Fn(&mut Clip, &mut sq_core_model::Track)) -> (f32, f32) {
    let m = id(1);
    let mut c = clip(m, 0, 1000, Time::ZERO);
    let mut tr = track(1, vec![]);
    edit(&mut c, &mut tr);
    tr.set_clips(vec![c]);
    let t = timeline_of(vec![tr]);
    let o = mixed(&mut feeder([(m, constant(1.0, 1000))].into(), &t, 1024), &t, 0, 64);
    (o.0[40], o.1[40])
}

#[test]
fn clip_audio_gain_scales_the_played_samples() {
    assert_eq!(level_of(|_, _| {}), (1.0, 1.0));
    let (l, r) = level_of(|c, _| c.audio_gain_db = -6.0);
    assert!((l - 10f32.powf(-6.0 / 20.0)).abs() < 1e-4 && l == r, "{l} {r}");
    let (l, _) = level_of(|c, _| c.audio_gain_db = 6.0);
    assert!((l - 10f32.powf(6.0 / 20.0)).abs() < 1e-4, "{l}");
}

#[test]
fn track_volume_scales_the_played_samples_and_the_floor_mutes() {
    let (l, r) = level_of(|_, t| t.volume_db = -6.0);
    assert!((l - 10f32.powf(-6.0 / 20.0)).abs() < 1e-4 && l == r, "{l} {r}");
    assert_eq!(level_of(|_, t| t.volume_db = sq_core_model::TrackPan::MIN_VOLUME_DB), (0.0, 0.0));
}

#[test]
fn track_pan_moves_the_played_samples_between_the_sides() {
    // Swift TrackPan.channelGains for a mono source (the test media): equal power, unity at the center, never above unity.
    let (l, r) = level_of(|_, t| t.pan = -1.0);
    assert!((l - 1.0).abs() < 1e-4 && r.abs() < 1e-6, "hard left: {l} {r}");
    let (l, r) = level_of(|_, t| t.pan = 1.0);
    assert!((r - 1.0).abs() < 1e-4 && l.abs() < 1e-6, "hard right: {l} {r}");
    let (l, r) = level_of(|_, t| t.pan = 0.5);
    assert!((l - 0.541_196).abs() < 1e-4 && (r - 1.0).abs() < 1e-4, "half right: {l} {r}");
    let (l, r) = level_of(|_, t| t.pan = 0.0);
    assert!((l - 1.0).abs() < 1e-4 && (r - 1.0).abs() < 1e-4, "center is unity: {l} {r}");
}

#[test]
fn a_muted_track_plays_silence() {
    assert_eq!(level_of(|_, t| t.is_muted = true), (0.0, 0.0));
}
