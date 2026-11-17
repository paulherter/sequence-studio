// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: AudioFeederTests, AudioFeederMasterTests, AudioFeederRoleBusTests, AudioFeederScrubMonoTests (portable
// parts), AudioMixerFuzzTests (null test against an f64 reference).
use super::*;
use crate::audio::Sequences;
use sq_audiofx::gain::GainMath;
use sq_audiofx::presets::TrackAudioPreset;
use sq_core_model::{AnimatedProperty, TrackKind};
use sq_core_model::{ChannelLayout, DeliveryPlatform, DeliveryTarget, SequenceFormat, Timeline, Track, TrackPan};
use sq_core_time::{Keyframe, KeyframeTrack};
use sq_media::media_error::MediaError;
use sq_media::memory_audio_source::MemoryAudioSource;

const RATE: i64 = 48_000;

pub(super) fn id(n: u128) -> Id {
    Id::from_u128(n)
}

pub(super) fn frames(n: i64) -> Time {
    Time::new(n, RATE)
}

/// Source whose frame i holds `i + 1 + offset` (never 0, exactly representable).
pub(super) fn ramp(n: usize, offset: f32) -> Arc<dyn AudioSource> {
    Arc::new(MemoryAudioSource::mono((0..n).map(|i| i as f32 + 1.0 + offset).collect()))
}

pub(super) fn constant(v: f32, n: usize) -> Arc<dyn AudioSource> {
    Arc::new(MemoryAudioSource::mono(vec![v; n]))
}

pub(super) fn clip_vol(media: Id, src: i64, len: i64, at: Time, volume: f64) -> Clip {
    let mut c = Clip::new(media, "c", media, TrackKind::Audio, TimeRange::new(frames(src), frames(len)), at);
    c.id = id(media.to_string().len() as u128 + src as u128 + at.value() as u128 + 1000);
    c.animation.volume = AnimatedProperty::new(volume);
    c
}

pub(super) fn clip(media: Id, src: i64, len: i64, at: Time) -> Clip {
    clip_vol(media, src, len, at, 1.0)
}

pub(super) fn track(n: u128, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(id(n), TrackKind::Audio);
    t.set_clips(clips);
    t
}

pub(super) fn timeline_of(tracks: Vec<Track>) -> Timeline {
    Timeline::new(id(9999), "t", SequenceFormat::new(Time::new(1001, 30_000)), tracks)
}

pub(super) type Sources = HashMap<Id, Arc<dyn AudioSource>>;

pub(super) fn feeder(sources: Sources, t: &Timeline, block: usize) -> AudioFeeder {
    AudioFeeder::new(t.clone(), block, Arc::new(move |m| sources.get(&m).cloned().ok_or(MediaError::Unreadable)))
}

pub(super) fn mixed(f: &mut AudioFeeder, t: &Timeline, from: i64, count: usize) -> (Vec<f32>, Vec<f32>) {
    let (mut l, mut r) = (vec![9.0f32; count], vec![9.0f32; count]);
    f.mix(t, &Sequences::new(), from, &mut l, &mut r, false);
    (l, r)
}

/// `blocks` consecutive blocks of the left channel.
pub(super) fn pull(f: &mut AudioFeeder, blocks: usize) -> Vec<f32> {
    let mut out = Vec::new();
    for _ in 0..blocks {
        let (mut l, mut r) = (vec![0.0f32; f.block_frames], vec![0.0f32; f.block_frames]);
        let n = f.next_block(&mut l, &mut r);
        out.extend_from_slice(&l[..n]);
    }
    out
}

fn ramp_vals(range: std::ops::Range<i64>) -> Vec<f32> {
    range.map(|i| i as f32 + 1.0).collect()
}

#[test]
fn clip_boundaries_are_sample_exact() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 10, 50, frames(100))])]);
    let mut f = feeder([(m, ramp(1000, 0.0))].into(), &t, 1024);
    let o = mixed(&mut f, &t, 0, 256);
    for i in 0..256usize {
        let expected = if (100..150).contains(&i) { (i - 100 + 10) as f32 + 1.0 } else { 0.0 };
        assert!(o.0[i] == expected && o.1[i] == expected, "frame {i}");
    }
}

#[test]
fn non_grid_clip_start_rounds_consistently_across_blocks() {
    // 1001/30000 s = 1601.6 frames: first sample at or after the start is frame 1602, source offset rounds to 10.
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 10, 3000, Time::new(1001, 30_000))])]);
    let mut big = feeder([(m, ramp(5000, 0.0))].into(), &t, 4096);
    let whole = mixed(&mut big, &t, 0, 4096).0;
    assert_eq!(whole[1601], 0.0);
    assert_ne!(whole[1602], 0.0);
    let mut small = feeder([(m, ramp(5000, 0.0))].into(), &t, 1000);
    let mut pieces = Vec::new();
    for s in (0..4000).step_by(1000) {
        pieces.extend(mixed(&mut small, &t, s, 1000).0);
    }
    assert_eq!(pieces, whole[..4000]);
    // Source mapping is gapless: consecutive frames inside the clip advance by exactly 1.
    assert!(whole[1602..4096].windows(2).all(|w| w[1] - w[0] == 1.0));
}

#[test]
fn forward_blocks_are_contiguous() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 5000, Time::ZERO)])]);
    let mut f = feeder([(m, ramp(5000, 0.0))].into(), &t, 1000);
    f.handle().seek(500, false);
    assert_eq!(pull(&mut f, 3), ramp_vals(500..3500));
    assert_eq!(f.handle().position(), 3500);
}

#[test]
fn reverse_blocks_run_backwards_and_are_reversed() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 4000, Time::ZERO)])]);
    let mut f = feeder([(m, ramp(4000, 0.0))].into(), &t, 1000);
    f.handle().seek(3000, true);
    let got = pull(&mut f, 3);
    assert_eq!(f.handle().position(), 0);
    assert!(pull(&mut f, 1).is_empty(), "timeline start reached");
    // Output sample k is timeline frame 2999 - k, across block seams too.
    assert_eq!(got, (0..3000).map(|k| (2999 - k) as f32 + 1.0).collect::<Vec<_>>());
}

#[test]
fn reverse_last_block_is_short() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 4000, Time::ZERO)])]);
    let mut f = feeder([(m, ramp(4000, 0.0))].into(), &t, 1000);
    f.handle().seek(1500, true);
    let got = pull(&mut f, 3);
    assert_eq!(got, (0..1500).map(|k| (1499 - k) as f32 + 1.0).collect::<Vec<_>>());
}

#[test]
fn mute_and_solo() {
    let (a, b) = (id(1), id(2));
    let src: Sources = [(a, ramp(1000, 0.0)), (b, ramp(1000, 1000.0))].into();
    let tl = |mute_a: bool, solo_b: bool, mute_b: bool| {
        let mut ta = track(1, vec![clip(a, 0, 100, Time::ZERO)]);
        ta.is_muted = mute_a;
        let mut tb = track(2, vec![clip(b, 0, 100, Time::ZERO)]);
        tb.is_muted = mute_b;
        tb.is_solo = solo_b;
        timeline_of(vec![ta, tb])
    };
    let go = |t: &Timeline, n: usize| mixed(&mut feeder(src.clone(), t, 1024), t, 0, n).0;
    assert_eq!(go(&tl(false, false, false), 4), [1002.0, 1004.0, 1006.0, 1008.0]); // (i+1) + (i+1001)
    assert_eq!(go(&tl(true, false, false), 2), [1001.0, 1002.0]);
    assert_eq!(go(&tl(false, true, false), 2), [1001.0, 1002.0]);
    assert_eq!(go(&tl(false, true, true), 2), [0.0, 0.0]); // mute beats solo
}

#[test]
fn constant_clip_volume_is_applied() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip_vol(m, 0, 100, Time::ZERO, 0.5)])]);
    let o = mixed(&mut feeder([(m, ramp(100, 0.0))].into(), &t, 1024), &t, 0, 4);
    assert_eq!(o.0, [0.5, 1.0, 1.5, 2.0]);
    assert_eq!(o.0, o.1);
}

fn volume_line(m: Id, len: i64) -> Clip {
    let mut c = clip(m, 0, len, Time::ZERO);
    let kt = KeyframeTrack::with_keys(vec![
        Keyframe::new(id(501), Time::ZERO, 0.0),
        Keyframe::new(id(502), frames(len), 1.0),
    ]);
    c.animation.volume = AnimatedProperty { value: 1.0, track: kt };
    c
}

#[test]
fn animated_volume_follows_keyframes() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![volume_line(m, 1024)])]);
    let o = mixed(&mut feeder([(m, constant(1.0, 1024))].into(), &t, 1024), &t, 0, 1024).0;
    assert_eq!(o[0], 0.0);
    assert!((o[512] - 0.5).abs() < 0.01);
    assert!((o[1023] - 1023.0 / 1024.0).abs() < 0.01);
    assert!(o.windows(2).all(|w| w[1] >= w[0]));
}

#[test]
fn failing_source_is_silence_not_fatal() {
    let (ok, bad) = (id(1), id(2));
    let t =
        timeline_of(vec![track(1, vec![clip(bad, 0, 100, Time::ZERO)]), track(2, vec![clip(ok, 0, 100, Time::ZERO)])]);
    let mut f = feeder([(ok, ramp(100, 0.0))].into(), &t, 1024);
    assert_eq!(mixed(&mut f, &t, 0, 2).0, [1.0, 2.0]);
    assert!(f.handle().failed_reads() >= 1);
}

#[test]
fn source_shorter_than_clip_zero_fills_tail() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 100, Time::ZERO)])]);
    let o = mixed(&mut feeder([(m, ramp(3, 0.0))].into(), &t, 1024), &t, 0, 6).0;
    assert_eq!(o, [1.0, 2.0, 3.0, 0.0, 0.0, 0.0]);
}

#[test]
fn volume_ramp_is_identical_for_split_and_reverse_blocks() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![volume_line(m, 2000)])]);
    let src: Sources = [(m, constant(1.0, 2000))].into();
    let whole = mixed(&mut feeder(src.clone(), &t, 2000), &t, 0, 2000).0;
    let mut split = feeder(src.clone(), &t, 300);
    let mut pieces = Vec::new();
    for s in (0..2000).step_by(300) {
        pieces.extend(mixed(&mut split, &t, s, 300.min(2000 - s as usize)).0);
    }
    assert_eq!(pieces, whole);
    let mut rev = feeder(src, &t, 300);
    rev.handle().seek(2000, true);
    let got = pull(&mut rev, 7);
    assert_eq!(got, whole.iter().rev().copied().collect::<Vec<_>>());
}

#[test]
fn a_seek_applies_before_the_next_block() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 100_000, Time::ZERO)])]);
    let mut f = feeder([(m, ramp(100_000, 0.0))].into(), &t, 1000);
    f.handle().seek(0, false);
    pull(&mut f, 2);
    f.handle().seek(50_000, false);
    assert_eq!(pull(&mut f, 2), ramp_vals(50_000..52_000));
}

#[test]
fn renderer_flush_seeks_and_reports_latency() {
    let m = id(1);
    let t = timeline_of(vec![track(1, vec![clip(m, 0, 100_000, Time::ZERO)])]);
    let mut f = feeder([(m, ramp(100_000, 0.0))].into(), &t, 1024);
    f.flush(Time::new(1000, RATE), PlaybackRate::FORWARD);
    assert_eq!(f.latency_frames(), 0);
    let mut out = vec![0.0f32; 2048];
    f.render(&mut out);
    assert_eq!(out[0], 1001.0);
    assert_eq!(out[2], 1002.0);
    assert_eq!(out[1], out[0]);
}

// MARK: master

fn master_timeline(m: Id, gain_db: f64, role: Option<AudioTag>, target: Option<DeliveryTarget>) -> Timeline {
    let mut c = Clip::new(m, "c", m, TrackKind::Audio, TimeRange::new(Time::ZERO, frames(20_000)), Time::ZERO);
    c.audio_gain_db = gain_db;
    let mut tr = track(1, vec![c]);
    tr.audio_role = role;
    let mut t = timeline_of(vec![tr]);
    t.delivery_target = target;
    t
}

/// Seeks to 0 and plays `n` frames (whole blocks).
fn played(f: &mut AudioFeeder, n: usize) -> Vec<f32> {
    f.handle().seek(0, false);
    let mut v = pull(f, n.div_ceil(f.block_frames));
    v.truncate(n);
    v
}

fn youtube() -> DeliveryTarget {
    DeliveryTarget { platform: DeliveryPlatform::Youtube, target_lufs: -14.0, true_peak_db: -1.0 }
}

#[test]
fn without_a_delivery_target_the_mix_is_not_limited() {
    let m = id(1);
    let t = master_timeline(m, 6.0206, None, None);
    let p = played(&mut feeder([(m, constant(0.5, 30_000))].into(), &t, 1024), 2048);
    assert!(p[500..].iter().all(|v| (v - 1.0).abs() < 1e-3));
}

#[test]
fn a_delivery_target_limits_the_master_at_its_true_peak_ceiling() {
    let m = id(1);
    let ceiling = GainMath::linear_from_db(-1.0) as f32;
    let t = master_timeline(m, 6.0206, None, Some(youtube()));
    let p = played(&mut feeder([(m, constant(0.5, 30_000))].into(), &t, 1024), 2048);
    assert!(p.iter().all(|v| *v <= ceiling));
    assert!(p[500..].iter().all(|v| (v - ceiling).abs() < 1e-4));
}

#[test]
fn quiet_material_passes_the_limiter_untouched() {
    let m = id(1);
    let t = master_timeline(m, 0.0, None, Some(youtube()));
    let p = played(&mut feeder([(m, constant(0.5, 30_000))].into(), &t, 1024), 2048);
    assert!(p.iter().all(|v| *v == 0.5));
}

#[test]
fn changing_the_target_moves_the_ceiling() {
    let m = id(1);
    let t = master_timeline(m, 6.0206, None, Some(youtube()));
    let mut f = feeder([(m, constant(0.5, 30_000))].into(), &t, 1024);
    played(&mut f, 1024);
    let mut t2 = t.clone();
    t2.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Youtube, target_lufs: -14.0, true_peak_db: -6.0206 });
    f.handle().set_timeline(t2, None);
    assert!(played(&mut f, 2048)[500..].iter().all(|v| (v - 0.5).abs() < 1e-3));
    f.handle().set_timeline(master_timeline(m, 6.0206, None, None), None);
    assert!(played(&mut f, 2048)[500..].iter().all(|v| (v - 1.0).abs() < 1e-3));
}

#[test]
fn a_track_role_gives_the_track_its_voiced_preset() {
    let m = id(1);
    let t = master_timeline(m, 0.0, Some(AudioTag::Music), None);
    let tid = t.tracks[0].id;
    let f = feeder([(m, constant(0.5, 30_000))].into(), &t, 1024);
    assert_eq!(f.handle().effective_preset(tid), Some(TrackAudioPreset::for_role(AudioTag::Music)));
    let mut t2 = t.clone();
    t2.tracks[0].audio_role = Some(AudioTag::Dialogue);
    f.handle().set_timeline(t2.clone(), None);
    assert_eq!(f.handle().effective_preset(tid), Some(TrackAudioPreset::for_role(AudioTag::Dialogue)));
    t2.tracks[0].audio_role = None;
    f.handle().set_timeline(t2, None);
    assert_eq!(f.handle().effective_preset(tid), None);
}

#[test]
fn an_explicit_preset_wins_over_the_role() {
    let m = id(1);
    let t = master_timeline(m, 0.0, Some(AudioTag::Sfx), None);
    let tid = t.tracks[0].id;
    let f = feeder([(m, constant(0.5, 30_000))].into(), &t, 1024);
    f.handle().set_preset(tid, Some(TrackAudioPreset::voice()));
    assert_eq!(f.handle().effective_preset(tid), Some(TrackAudioPreset::voice()));
    f.handle().set_preset(tid, None);
    assert_eq!(f.handle().effective_preset(tid), Some(TrackAudioPreset::for_role(AudioTag::Sfx)));
}

#[test]
fn the_role_runs_through_the_track_fx() {
    // SFX: flat EQ, 0 dB level and makeup, threshold -14 dBFS: a quiet constant stays under it and passes unchanged.
    let m = id(1);
    let plain_t = master_timeline(m, 0.0, None, None);
    let sfx_t = master_timeline(m, 0.0, Some(AudioTag::Sfx), None);
    let plain = played(&mut feeder([(m, constant(0.05, 30_000))].into(), &plain_t, 1024), 4096);
    let sfx = played(&mut feeder([(m, constant(0.05, 30_000))].into(), &sfx_t, 1024), 4096);
    let ratio = f64::from(sfx[3000] / plain[3000]);
    assert!(GainMath::db_from_linear(ratio).abs() < 0.3);
}

// MARK: role buses

fn role_setup(gains: HashMap<AudioTag, f64>) -> AudioFeeder {
    let (a, b) = (id(1), id(2));
    let mk = |m: Id, role| {
        let c = Clip::new(m, "c", m, TrackKind::Audio, TimeRange::new(Time::ZERO, frames(20_000)), Time::ZERO);
        let mut t = track(m.to_string().len() as u128 + if role == AudioTag::Music { 7 } else { 3 }, vec![c]);
        t.audio_role = Some(role);
        t
    };
    let mut t1 = mk(a, AudioTag::Dialogue);
    t1.id = id(11);
    let mut t2 = mk(b, AudioTag::Music);
    t2.id = id(12);
    let tl = Timeline::new(id(9999), "t", SequenceFormat::new(Time::new(1, 30)), vec![t1, t2]);
    let f = feeder([(a, constant(0.3, 30_000)), (b, constant(0.1, 30_000))].into(), &tl, 1024);
    f.handle().set_role_bus_gains_db(gains);
    f
}

#[test]
fn zero_db_buses_are_bit_identical_to_no_buses() {
    let base = played(&mut role_setup(HashMap::new()), 3000);
    let zero =
        played(&mut role_setup([(AudioTag::Dialogue, 0.0), (AudioTag::Music, 0.0), (AudioTag::Sfx, 0.0)].into()), 3000);
    assert_eq!(base, zero);
    assert!(base.iter().any(|v| *v != 0.0));
}

#[test]
fn bus_gain_scales_the_role_sum_only() {
    let dialogue_only = played(&mut role_setup([(AudioTag::Music, -100.0)].into()), 3000);
    let both = played(&mut role_setup(HashMap::new()), 3000);
    let down = played(&mut role_setup([(AudioTag::Dialogue, -6.0206), (AudioTag::Music, -100.0)].into()), 3000);
    let music_only = played(&mut role_setup([(AudioTag::Dialogue, -100.0)].into()), 3000);
    for i in [1000, 2000] {
        assert!((down[i] - dialogue_only[i] * 0.5).abs() < 1e-3);
        assert!((both[i] - dialogue_only[i] - music_only[i]).abs() < 1e-3);
        assert_ne!(music_only[i], 0.0);
    }
}

#[test]
fn played_twice_is_bit_equal() {
    let gains: HashMap<AudioTag, f64> = [(AudioTag::Dialogue, -3.0), (AudioTag::Music, -9.0)].into();
    assert_eq!(played(&mut role_setup(gains.clone()), 2048), played(&mut role_setup(gains), 2048));
}

#[test]
fn first_change_ramps_from_unity() {
    let mut f = role_setup(HashMap::new());
    f.handle().seek(0, false);
    let mut l = pull(&mut f, 1);
    f.handle().set_role_bus_gains_db([(AudioTag::Dialogue, -12.0), (AudioTag::Music, -12.0)].into());
    l.extend(pull(&mut f, 1));
    // The second block starts at the unity level and ends below it: no hard step at its first sample.
    assert!((l[1024] - l[1023]).abs() < 0.01);
    assert!(l[2047] < l[1024] * 0.5);
}

#[test]
fn seek_resets_role_gain_state() {
    let mut f = role_setup([(AudioTag::Dialogue, -12.0)].into());
    played(&mut f, 2048);
    f.handle().set_role_bus_gains_db(HashMap::new());
    let reused = played(&mut f, 2048);
    assert_eq!(reused, played(&mut role_setup(HashMap::new()), 2048));
}

// MARK: channel layout

fn scrubbed(layout: ChannelLayout) -> (Vec<f32>, Vec<f32>) {
    let m = id(1);
    let c = Clip::new(m, "c", m, TrackKind::Audio, TimeRange::new(Time::ZERO, frames(20_000)), Time::ZERO);
    let mut t = Timeline::new(id(9999), "t", SequenceFormat::new(Time::new(1, 30)), vec![track(1, vec![c])]);
    t.set_channel_layout(layout);
    let src: Arc<dyn AudioSource> = Arc::new(MemoryAudioSource::new(vec![0.5; 30_000], vec![0.0; 30_000]));
    mixed(&mut feeder([(m, src)].into(), &t, 1024), &t, 0, 2048)
}

#[test]
fn mono_scrub_folds_hard_left_to_half_on_both_sides() {
    let (l, r) = scrubbed(ChannelLayout::Mono);
    assert_eq!(l, r);
    assert!((l[100] - 0.25).abs() < 1e-6);
}

#[test]
fn stereo_scrub_is_untouched() {
    let (l, r) = scrubbed(ChannelLayout::Stereo);
    assert!((l[100] - 0.5).abs() < 1e-6);
    assert_eq!(r[100], 0.0);
}

// MARK: null test against an f64 reference

/// Deterministic pseudo-random in [-1, 1) (xorshift), no `rand` dependency.
pub(super) fn noise(seed: u64, n: usize) -> Vec<f32> {
    let mut s = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            ((s >> 40) as f32 / (1u64 << 23) as f32) - 1.0
        })
        .collect()
}

fn dbfs(x: f64) -> f64 {
    20.0 * x.max(1e-30).log10()
}

/// `tracks` stereo tracks with their own volume line and fader, mixed by the feeder in f32, against the same mix in f64 with
/// the same track order: rms < -140 dBFS and peak < -120 dBFS.
fn null_test(tracks: usize) {
    let n = 4096usize;
    let amp = 0.9 / tracks as f32;
    let mut sources: Sources = HashMap::new();
    let mut trs = Vec::new();
    let mut want_l = vec![0.0f64; n];
    for k in 0..tracks {
        let media = id(100 + k as u128);
        let data: Vec<f32> = noise(k as u64 + 1, n).iter().map(|v| v * amp).collect();
        let vol = 0.25 + 0.75 * (k as f64 / tracks as f64);
        let mut c = clip_vol(media, 0, n as i64, Time::ZERO, vol);
        c.id = id(200 + k as u128);
        let mut t = track(1 + k as u128, vec![c]);
        t.volume_db = -(k as f64) * 0.5;
        let (gl, _) = TrackPan::channel_gains(t.volume_db, 0.0, false);
        for i in 0..n {
            want_l[i] += f64::from(data[i]) * vol * gl; // fixed sum order: track 0, 1, 2, ...
        }
        sources.insert(media, Arc::new(MemoryAudioSource::mono(data)));
        trs.push(t);
    }
    let t = timeline_of(trs);
    let mut f = feeder(sources, &t, 1024);
    let (got_l, _) = mixed(&mut f, &t, 0, n);
    let (mut sum, mut peak) = (0.0f64, 0.0f64);
    for i in 0..n {
        let e = f64::from(got_l[i]) - want_l[i];
        sum += e * e;
        peak = peak.max(e.abs());
    }
    let rms = (sum / n as f64).sqrt();
    assert!(dbfs(rms) < -140.0, "{tracks} tracks: rms {} dBFS", dbfs(rms));
    assert!(dbfs(peak) < -120.0, "{tracks} tracks: peak {} dBFS", dbfs(peak));
}

#[test]
fn mix_of_up_to_24_tracks_nulls_against_an_f64_reference() {
    for tracks in [1, 2, 8, 16, 24] {
        null_test(tracks);
    }
}

/// Setting the timeline opens its audio files on a worker; the first render takes them and opens nothing on the mix
/// thread (the first Play after an open or a sequence switch used to probe each file before the first sound).
#[test]
fn set_timeline_opens_sources_ahead_of_the_first_block() {
    use std::sync::Mutex;
    let opened: Arc<Mutex<Vec<(Id, std::thread::ThreadId)>>> = Arc::default();
    let log = Arc::clone(&opened);
    let resolver: Resolver = Arc::new(move |m| {
        log.lock().unwrap().push((m, std::thread::current().id()));
        Ok(constant(0.5, 96_000))
    });
    let t =
        timeline_of(vec![track(1, vec![clip(id(7), 0, 48_000, Time::ZERO), clip(id(8), 0, 48_000, frames(48_000))])]);
    let mut f = AudioFeeder::new(timeline_of(vec![]), 256, resolver);
    f.handle().set_timeline(t.clone(), None);
    let end = Instant::now() + Duration::from_secs(5);
    while opened.lock().unwrap().len() < 2 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(opened.lock().unwrap().len(), 2, "both files open before any block");
    let (l, _) = mixed(&mut f, &t, 0, 128);
    assert!(l.iter().all(|v| (*v - 0.5).abs() < 1e-6));
    let calls = opened.lock().unwrap().clone();
    assert_eq!(calls.len(), 2, "the first block opens nothing again");
    assert!(calls.iter().all(|(_, th)| *th != std::thread::current().id()), "opened off the mix thread");
}

/// A big camera file takes a while to open: Play found the open still running on the worker, opened the file a second time on
/// the mix thread and held every track's block meanwhile. The mix thread waits for the open that is running.
#[test]
fn a_slow_open_running_ahead_is_waited_for_and_not_opened_again_on_the_mix_thread() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let opens = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&opens);
    let resolver: Resolver = Arc::new(move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(300));
        Ok(constant(0.5, 96_000))
    });
    let t = timeline_of(vec![track(1, vec![clip(id(7), 0, 48_000, Time::ZERO)])]);
    let mut f = AudioFeeder::new(timeline_of(vec![]), 256, resolver);
    f.handle().set_timeline(t.clone(), None);
    let end = Instant::now() + Duration::from_secs(5);
    while opens.load(Ordering::SeqCst) < 1 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    // The worker is inside the open now; the first Play block arrives.
    let (l, _) = mixed(&mut f, &t, 0, 128);
    assert!(l.iter().all(|v| (*v - 0.5).abs() < 1e-6), "the first block carries the clip, not silence");
    assert_eq!(opens.load(Ordering::SeqCst), 1, "the file was opened once, by the worker");
}

/// A relink cancels what was opened ahead: the changed media is reopened from the new file.
#[test]
fn media_changed_drops_prewarmed_sources() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let opens = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&opens);
    let resolver: Resolver = Arc::new(move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        Ok(constant(0.5, 96_000))
    });
    let t = timeline_of(vec![track(1, vec![clip(id(7), 0, 48_000, Time::ZERO)])]);
    let mut f = AudioFeeder::new(timeline_of(vec![]), 256, resolver);
    f.handle().set_timeline(t.clone(), None);
    let end = Instant::now() + Duration::from_secs(5);
    while opens.load(Ordering::SeqCst) < 1 && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    f.handle().media_changed(&std::iter::once(id(7)).collect());
    let _ = mixed(&mut f, &t, 0, 128);
    assert_eq!(opens.load(Ordering::SeqCst), 2, "reopened after the media changed");
}

/// An edit pushes the same timeline again and again: files opened ahead are not opened a second time.
#[test]
fn pushing_the_timeline_again_does_not_reopen_sources() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let opens = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&opens);
    let resolver: Resolver = Arc::new(move |_| {
        counter.fetch_add(1, Ordering::SeqCst);
        Ok(constant(0.5, 96_000))
    });
    let t = timeline_of(vec![track(1, vec![clip(id(7), 0, 48_000, Time::ZERO)])]);
    let f = AudioFeeder::new(timeline_of(vec![]), 256, resolver);
    for _ in 0..3 {
        f.handle().set_timeline(t.clone(), None);
        std::thread::sleep(Duration::from_millis(60));
    }
    assert_eq!(opens.load(Ordering::SeqCst), 1);
}

// MARK: track tweaks stored in the project

fn tone(hz: f64, amp: f32, n: usize) -> Arc<dyn AudioSource> {
    let v = (0..n).map(|i| amp * (2.0 * std::f64::consts::PI * hz * i as f64 / RATE as f64).sin() as f32).collect();
    Arc::new(MemoryAudioSource::mono(v))
}

fn rms_db(v: &[f32]) -> f64 {
    GainMath::db_from_linear((v.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>() / v.len() as f64).sqrt())
}

/// A track with a tone and `preset` stored on it (no role): what playback and export both read.
fn tweaked(preset: &TrackAudioPreset, hz: f64, amp: f32) -> (Timeline, Sources) {
    use sq_audiofx::track_preset::TrackPresetExt;
    let m = id(1);
    let mut t = master_timeline(m, 0.0, None, None);
    t.tracks[0].set_audio_preset(Some(preset));
    (t, [(m, tone(hz, amp, 40_000))].into())
}

fn compressing(bypass: bool) -> TrackAudioPreset {
    let mut p = TrackAudioPreset::new(
        "x",
        "x",
        sq_audiofx::presets::MultibandCompressorSettings::new(
            vec![120.0, 900.0, 4500.0],
            vec![sq_audiofx::presets::MultibandBand::new(-20.0, 4.0, 1.0, 50.0); 4],
        ),
    )
    .with_noise_reduction(0.0);
    p.compressor.bypass = bypass;
    p
}

#[test]
fn a_stored_compressor_on_or_off_changes_the_mix_by_the_expected_gain_reduction() {
    let render = |bypass| {
        let (t, s) = tweaked(&compressing(bypass), 1000.0, 0.5);
        played(&mut feeder(s, &t, 1024), 16_384)
    };
    let (off, on) = (render(true), render(false));
    assert_ne!(on, off, "the compressor reaches the mix");
    let reduction = rms_db(&off[8000..]) - rms_db(&on[8000..]);
    // -6 dBFS peak over a -20 dB threshold at 4:1 is about 10 dB of reduction; the detector and band split give a range.
    assert!((4.0..14.0).contains(&reduction), "gain reduction {reduction} dB");
}

#[test]
fn a_stored_eq_on_or_off_changes_the_spectrum() {
    let render = |eq_on| {
        let mut p = compressing(true);
        p.compressor.bypass = false;
        p.compressor.eq_on = eq_on;
        for b in &mut p.compressor.bands {
            *b = sq_audiofx::presets::MultibandBand::with_gain(0.0, 1.0, 10.0, 100.0, 0.0);
        }
        p.compressor.bands[0].gain_db = 9.0;
        let (t, s) = tweaked(&p, 60.0, 0.1);
        played(&mut feeder(s, &t, 1024), 16_384)
    };
    let (flat, boosted) = (render(false), render(true));
    let lift = rms_db(&boosted[8000..]) - rms_db(&flat[8000..]);
    assert!((6.0..12.0).contains(&lift), "the low band lifts by about 9 dB, got {lift}");
}

#[test]
fn playback_and_export_run_the_same_chain_on_the_same_input() {
    let mut p = compressing(false);
    p.noise_reduction = 0.0;
    let (t, s) = tweaked(&p, 1000.0, 0.5);
    // Playback pulls the device's block size, the export its own: the same stored chain must give the same samples.
    let playback = played(&mut feeder(s.clone(), &t, 512), 8192);
    let export = played(&mut feeder(s, &t, 2048), 8192);
    let worst = playback.iter().zip(&export).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
    assert!(worst < 1e-4, "playback and export differ by {worst}");
    assert!(playback.iter().any(|v| v.abs() > 0.01));
}
