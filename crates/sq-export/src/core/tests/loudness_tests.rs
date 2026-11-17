// Swift: LoudnessTests.swift, LoudnessDefaultsTests.swift, LoudnessLimitingTests.swift, AudioDeliveryTests.swift (pure
// parts), AudioDeliveryExtrasTests.swift (targets)

use super::BufferSource;
use crate::core::*;
use sq_core_time::Time;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

fn sine(amp: f32) -> SineAudioSource {
    SineAudioSource::new(48_000, 2, Time::new(4, 1), 1000, amp)
}

fn no_cancel() -> CancelToken {
    CancelToken::new()
}

#[test]
fn ends_within_half_lu_of_target() {
    for target in [-14.0, -16.0, -23.0] {
        let mut n =
            NormalizedAudioSource::make(Box::new(sine(0.05)), LoudnessNormalization::new(target, -1.0), &no_cancel())
                .unwrap();
        let m = LoudnessNormalizer::measure(&mut n, &no_cancel()).unwrap();
        assert!((m.integrated_lufs - target).abs() < 0.5, "{target}: {}", m.integrated_lufs);
        assert!(m.true_peak_db <= -1.0 + 0.05);
    }
}

#[test]
fn loud_source_is_attenuated() {
    let mut n =
        NormalizedAudioSource::make(Box::new(sine(0.9)), LoudnessNormalization::default(), &no_cancel()).unwrap();
    assert!(n.gain_db < 0.0);
    let m = LoudnessNormalizer::measure(&mut n, &no_cancel()).unwrap();
    assert!((m.integrated_lufs - -14.0).abs() < 0.5);
}

#[test]
fn ceiling_limits_gain() {
    // amplitude 0.25 = -12 dBFS; target -14 needs about +1.7 dB, but ceiling -20 dBTP allows only -8 dB.
    let mut n =
        NormalizedAudioSource::make(Box::new(sine(0.25)), LoudnessNormalization::new(-14.0, -20.0), &no_cancel())
            .unwrap();
    let m = LoudnessNormalizer::measure(&mut n, &no_cancel()).unwrap();
    assert!(m.true_peak_db <= -20.0 + 0.05);
    assert!(m.true_peak_db > -20.0 - 0.3); // limited exactly by the ceiling, not more
    assert!(m.integrated_lufs < -14.0 - 3.0); // target not reached
}

fn meas(l: f64, p: f64) -> LoudnessMeasurement {
    LoudnessMeasurement { integrated_lufs: l, true_peak_db: p }
}

#[test]
fn gain_math() {
    let s = LoudnessNormalization::new(-14.0, -1.0);
    assert_eq!(LoudnessNormalizer::gain_db(meas(-20.0, -10.0), s), 6.0);
    assert_eq!(LoudnessNormalizer::gain_db(meas(-20.0, -4.0), s), 3.0);
    assert_eq!(LoudnessNormalizer::gain_db(meas(-10.0, -0.5), s), -4.0);
    assert_eq!(LoudnessNormalizer::gain_db(meas(f64::NEG_INFINITY, f64::NEG_INFINITY), s), 0.0);
}

#[test]
fn default_ceiling_is_minus_one_dbtp() {
    assert_eq!(LoudnessNormalization::default().true_peak_ceiling_db, -1.0);
    for p in ExportPreset::all() {
        assert_eq!(p.loudness().true_peak_ceiling_db, -1.0);
    }
}

#[test]
fn platform_targets() {
    let t = |p: ExportPreset| p.loudness().target_lufs;
    assert_eq!(t(ExportPreset::social_preset(SocialPlatform::Tiktok, VideoCodec::H264)), -14.0);
    assert_eq!(t(ExportPreset::social_preset(SocialPlatform::Reels, VideoCodec::Hevc)), -14.0);
    assert_eq!(t(ExportPreset::YOUTUBE_1080), -14.0);
    assert_eq!(t(ExportPreset::YOUTUBE_4K), -14.0);
    assert_eq!(t(ExportPreset::PRORES), -23.0);
    assert_eq!(ExportPreset::DEFAULT.settings().audio.loudness, None);
}

#[test]
fn report_quiet_source() {
    let r = LoudnessReport::new(meas(-20.0, -12.0), LoudnessNormalization::new(-14.0, -1.0));
    assert_eq!(r.gain_db, 6.0);
    assert_eq!(r.output_lufs(), -14.0);
    assert_eq!(r.output_true_peak_db(), -6.0);
    assert!(!r.limited_by_ceiling);
}

#[test]
fn report_limited_by_ceiling() {
    let r = LoudnessReport::new(meas(-20.0, -4.0), LoudnessNormalization::new(-14.0, -1.0));
    assert_eq!(r.gain_db, 3.0);
    assert_eq!(r.output_lufs(), -17.0);
    assert_eq!(r.output_true_peak_db(), -1.0);
    assert!(r.limited_by_ceiling);
    assert!(r.summary().contains("-17.0 LUFS") && r.summary().contains("-1.0 dBTP"));
    assert_eq!(r.summary(), "-17.0 LUFS, -1.0 dBTP (gain +3.0 dB, limited by -1.0 dBTP ceiling)");
}

#[test]
fn report_silence_and_verification() {
    let r = LoudnessReport::new(meas(f64::NEG_INFINITY, f64::NEG_INFINITY), LoudnessNormalization::default());
    assert_eq!(r.gain_db, 0.0);
    assert!(r.summary().contains("silent"));
    let mut r = LoudnessReport::new(meas(-20.0, -12.0), LoudnessNormalization::new(-14.0, -1.0));
    assert_eq!(r.overshoot_db(), None);
    r.verified = Some(meas(-14.0, -0.5));
    assert_eq!(r.overshoot_db(), Some(0.5));
    assert!(r.summary().ends_with("; in the file -14.0 LUFS, -0.5 dBTP, 0.5 dB above the ceiling"));
    r.verified = Some(meas(-14.0, -0.97));
    assert_eq!(r.overshoot_db(), None);
}

/// 1 kHz sine at `base`, with a ~1 ms burst at `burst` every half second (a crest the limiter can take off).
struct PeakySource {
    base: f32,
    burst: f32,
    total: usize,
    pos: usize,
    passes: Arc<AtomicUsize>,
}

impl PeakySource {
    fn new(base: f32, burst: f32) -> (PeakySource, Arc<AtomicUsize>) {
        let passes = Arc::new(AtomicUsize::new(0));
        (PeakySource { base, burst, total: 6 * 48_000, pos: 0, passes: Arc::clone(&passes) }, passes)
    }
}

impl AudioSource for PeakySource {
    fn sample_rate(&self) -> i64 {
        48_000
    }
    fn channels(&self) -> usize {
        2
    }
    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        if self.pos >= self.total {
            self.passes.fetch_add(1, Ordering::SeqCst);
            return Ok(None);
        }
        let n = max_frames.min(self.total - self.pos);
        let mut s = vec![0.0f32; n * 2];
        for i in 0..n {
            let f = self.pos + i;
            let a = if f % 24_000 < 48 { self.burst } else { self.base };
            let v = a * (2.0 * std::f64::consts::PI * 1000.0 * f as f64 / 48_000.0).sin() as f32;
            s[i * 2] = v;
            s[i * 2 + 1] = v;
        }
        self.pos += n;
        Ok(Some(AudioChunk::new(s, 2)))
    }
    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for PeakySource {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.pos = 0;
        Ok(())
    }
}

#[test]
fn limiter_recovers_loudness_the_peak_cost_under_plain_gain() {
    let settings = LoudnessNormalization::new(-17.0, -1.0);
    let (mut src, _) = PeakySource::new(0.1, 0.8);
    let m = LoudnessNormalizer::measure(&mut src, &no_cancel()).unwrap();
    let plain = LoudnessNormalizer::gain_db(m, settings);
    assert!(m.integrated_lufs + plain < -17.0 - 1.5); // the premise: the ceiling alone leaves it too quiet

    let (base, _) = PeakySource::new(0.1, 0.8);
    let mut n = NormalizedAudioSource::make(Box::new(base), settings, &no_cancel()).unwrap();
    assert!(n.limiter_ceiling_db.is_some());
    assert!(n.gain_db > plain);
    let out = LoudnessNormalizer::measure(&mut n, &no_cancel()).unwrap();
    assert!((out.integrated_lufs - -17.0).abs() < 0.5, "got {}", out.integrated_lufs);
    assert!(out.true_peak_db <= -1.0 + LoudnessReport::VERIFY_TOLERANCE_DB, "peak {}", out.true_peak_db);
    // The source's own prediction matches what the chain really does.
    assert!((n.result.integrated_lufs - out.integrated_lufs).abs() < 0.05);
}

#[test]
fn search_is_bounded() {
    let (src, passes) = PeakySource::new(0.1, 0.8);
    NormalizedAudioSource::make(Box::new(src), LoudnessNormalization::new(-17.0, -1.0), &no_cancel()).unwrap();
    // One measuring pass plus at most `MAX_SEARCH_PASSES` limited passes.
    let p = passes.load(Ordering::SeqCst);
    assert!(p >= 2);
    assert!(p <= 1 + LoudnessNormalizer::MAX_SEARCH_PASSES);
}

#[test]
fn extra_gain_is_capped() {
    // A pure sine under a very low ceiling: the limiter can never win the loudness back, the search stops, and the gain
    // never runs more than `MAX_EXTRA_GAIN_DB` above the plain one.
    let (mut src, passes) = PeakySource::new(0.25, 0.25);
    let s = LoudnessNormalization::new(-14.0, -20.0);
    let m = LoudnessNormalizer::measure(&mut src, &no_cancel()).unwrap();
    let plain = LoudnessNormalizer::gain_db(m, s);
    let before = passes.load(Ordering::SeqCst);
    let plan = LoudnessNormalizer::plan(&mut src, m, s, &no_cancel()).unwrap();
    assert!(plan.gain_db <= plain + LoudnessNormalizer::MAX_EXTRA_GAIN_DB + 1e-9);
    assert!(passes.load(Ordering::SeqCst) - before <= 1 + LoudnessNormalizer::MAX_SEARCH_PASSES);
    let (base, _) = PeakySource::new(0.25, 0.25);
    let mut n = NormalizedAudioSource::make(Box::new(base), s, &no_cancel()).unwrap();
    let out = LoudnessNormalizer::measure(&mut n, &no_cancel()).unwrap();
    assert!(out.true_peak_db <= -20.0 + LoudnessReport::VERIFY_TOLERANCE_DB);
}

#[test]
fn no_extra_pass_when_the_target_is_reached() {
    let (src, passes) = PeakySource::new(0.9, 0.9); // loud: the gain is a cut, the ceiling plays no part
    let n = NormalizedAudioSource::make(Box::new(src), LoudnessNormalization::default(), &no_cancel()).unwrap();
    assert!(n.limiter_ceiling_db.is_none());
    assert_eq!(passes.load(Ordering::SeqCst), 1);
}

#[test]
fn report_names_the_limiter_and_the_real_result() {
    let s = LoudnessNormalization::new(-17.0, -1.0);
    let (src, _) = PeakySource::new(0.1, 0.8);
    let n = NormalizedAudioSource::make(Box::new(src), s, &no_cancel()).unwrap();
    let r = LoudnessReport::from_normalized(&n, s);
    assert!(r.limiter_used);
    assert!((r.output_lufs() - n.result.integrated_lufs).abs() < 1e-9);
    assert!(r.summary().contains("limiter"));
}

#[test]
fn preflight_predicts_the_limiter_assisted_loudness() {
    let settings = LoudnessNormalization::new(-17.0, -1.0);
    let (mut src, _) = PeakySource::new(0.1, 0.8);
    let a = AudioPreflight::analyze(&mut src, &no_cancel()).unwrap();
    let plain = AudioPreflight::evaluate(&a, settings, true, 0, None, AudioPreflight::LOUDNESS_TOLERANCE_LU);
    let (mut src2, _) = PeakySource::new(0.1, 0.8);
    let plan = AudioPreflight::predict(&mut src2, &a, settings, &no_cancel()).unwrap();
    assert!(plan.limiter_used);
    let planned = AudioPreflight::evaluate(&a, settings, true, 0, Some(&plan), AudioPreflight::LOUDNESS_TOLERANCE_LU);
    let find = |v: &[AudioFinding], k| v.iter().find(|f| f.kind == k).cloned().unwrap();
    let loud = find(&planned, AudioFindingKind::Loudness);
    assert!((plan.output_lufs() - -17.0).abs() < 0.5);
    assert!(loud.message.contains("peak limiter"));
    assert_ne!(loud.message, find(&plain, AudioFindingKind::Loudness).message);
    assert_eq!(find(&planned, AudioFindingKind::TruePeak).severity, AudioSeverity::Pass);
}

#[test]
fn empty_chunk_through_limiter_does_not_crash() {
    let mut chain = LoudnessChain::new(-3.0, Some(-1.0), 48_000);
    let mut chunk = AudioChunk::new(Vec::new(), 2);
    chain.apply(&mut chunk);
    assert!(chunk.samples.is_empty());
}

#[test]
fn cancel_stops_a_measuring_pass() {
    let c = CancelToken::new();
    c.cancel();
    let mut s = sine(0.1);
    assert_eq!(LoudnessNormalizer::measure(&mut s, &c), Err(ExportError::Cancelled));
}

fn tone(i: usize, amp: f32) -> f32 {
    (2.0 * std::f64::consts::PI * ((i % 48_000 * 440 % 48_000) as f64) / 48_000.0).sin() as f32 * amp
}

fn shaped(channels: usize, seconds: usize, f: impl Fn(usize, usize) -> f32) -> BufferSource {
    let mut s = Vec::with_capacity(channels * seconds * 48_000);
    for i in 0..seconds * 48_000 {
        for c in 0..channels {
            s.push(f(i, c));
        }
    }
    BufferSource::new(48_000, channels, s)
}

fn finding(v: &[AudioFinding], k: AudioFindingKind) -> Option<&AudioFinding> {
    v.iter().find(|f| f.kind == k)
}

const TARGET: LoudnessNormalization = LoudnessNormalization { target_lufs: -14.0, true_peak_ceiling_db: -1.0 };

#[test]
fn clean_tone_has_no_findings_except_level() {
    let mut s = shaped(2, 3, |i, c| tone(i, 0.2) * if c == 0 { 1.0 } else { 0.5 });
    let a = AudioPreflight::analyze(&mut s, &no_cancel()).unwrap();
    assert!(a.clipped_samples == 0 && a.gap_count == 0 && !a.is_dual_mono && !a.is_silent());
    assert!((a.duration_seconds - 3.0).abs() < 0.01);
    let f = AudioPreflight::evaluate(&a, TARGET, false, 0, None, 1.0);
    assert_eq!(finding(&f, AudioFindingKind::Clipping).unwrap().severity, AudioSeverity::Pass);
    assert_eq!(finding(&f, AudioFindingKind::Loudness).unwrap().severity, AudioSeverity::Fail); // far below -14 LUFS
    let n = AudioPreflight::evaluate(&a, TARGET, true, 0, None, 1.0);
    assert_eq!(finding(&n, AudioFindingKind::Loudness).unwrap().severity, AudioSeverity::Pass);
}

#[test]
fn loudness_range_is_measured_and_listed() {
    let mut s = shaped(2, 20, |i, _| tone(i, if i < 10 * 48_000 { 0.02 } else { 0.0632 })); // +10 dB step
    let a = AudioPreflight::analyze(&mut s, &no_cancel()).unwrap();
    assert!((a.loudness_range_lu.unwrap_or(0.0) - 10.0).abs() < 0.5);
    let f = AudioPreflight::evaluate(&a, TARGET, false, 0, None, 1.0);
    assert!(finding(&f, AudioFindingKind::LoudnessRange).unwrap().message.starts_with("Loudness range"));
}

#[test]
fn clipping_gap_and_dual_mono_are_found() {
    // 1 s tone at full scale, 2 s silence, 1 s tone: identical channels.
    let mut s =
        shaped(2, 4, |i, _| if !(48_000..144_000).contains(&i) { if i % 2 == 0 { 1.0 } else { -1.0 } } else { 0.0 });
    let a = AudioPreflight::analyze(&mut s, &no_cancel()).unwrap();
    assert!(a.clipped_samples > 0);
    assert_eq!(a.gap_count, 1);
    assert!((a.longest_gap_seconds - 2.0).abs() < 0.01);
    assert!(a.is_dual_mono);
    let f = AudioPreflight::evaluate(&a, TARGET, true, 2, None, 1.0);
    assert_eq!(finding(&f, AudioFindingKind::Clipping).unwrap().severity, AudioSeverity::Fail);
    assert_eq!(finding(&f, AudioFindingKind::Gaps).unwrap().severity, AudioSeverity::Warning);
    assert_eq!(finding(&f, AudioFindingKind::DualMono).unwrap().severity, AudioSeverity::Warning);
    let u = finding(&f, AudioFindingKind::Unsynced).unwrap();
    assert_eq!(u.severity, AudioSeverity::Warning);
    assert_eq!(u.message, "2 audio clips are out of sync with the picture");
    assert_eq!(finding(&f, AudioFindingKind::Gaps).unwrap().message, "1 gap of silence over 1 s (longest 2.0 s)");
}

#[test]
fn silent_mix_fails() {
    let mut s = shaped(2, 2, |_, _| 0.0);
    let a = AudioPreflight::analyze(&mut s, &no_cancel()).unwrap();
    assert!(a.is_silent());
    let f = AudioPreflight::evaluate(&a, TARGET, false, 0, None, 1.0);
    assert!(f[0].kind == AudioFindingKind::Silent && f[0].severity == AudioSeverity::Fail);
    assert_eq!(f.last().unwrap().message, "Audio and picture are in sync");
}

#[test]
fn audio_only_presets_and_settings() {
    let m4a = ExportPreset::AUDIO_M4A.settings();
    assert!(m4a.audio_only == Some(AudioFileFormat::M4a) && m4a.file_extension() == "m4a" && m4a.validate().is_empty());
    let wav = ExportPreset::AUDIO_WAV.settings();
    assert!(wav.audio_only == Some(AudioFileFormat::Wav) && wav.effective_audio().codec == AudioCodec::Pcm);
    assert_eq!(wav.file_extension(), "wav");
    let mut burn = m4a.clone();
    burn.captions = CaptionMode::BurnIn;
    burn.cover_image = Some(CoverImageFormat::Jpg);
    assert!(burn.for_delivery().captions == CaptionMode::None && burn.for_delivery().cover_image.is_none());
    let j = serde_json::to_string(&ExportSettings::default()).unwrap();
    assert!(!j.contains("audioOnly"));
}

#[test]
fn named_targets() {
    assert_eq!(AudioDeliveryTarget::Spotify.target_lufs(), -14.0);
    assert_eq!(AudioDeliveryTarget::Youtube.target_lufs(), -14.0);
    assert_eq!(AudioDeliveryTarget::Spotify.display_name(), "Spotify / YouTube (-14 LUFS)");
    assert!(!AudioDeliveryTarget::ALL.contains(&AudioDeliveryTarget::Youtube));
    assert_eq!(AudioDeliveryTarget::AppleMusic.target_lufs(), -16.0);
    assert_eq!(AudioDeliveryTarget::EbuR128.target_lufs(), -23.0);
    assert_eq!(AudioDeliveryTarget::EbuR128.tolerance_lu(), 0.5);
    assert!(AudioDeliveryTarget::ALL.iter().all(|t| t.true_peak_ceiling_db() == -1.0));
    assert_eq!(
        AudioDeliveryTarget::matching(LoudnessNormalization::new(-16.0, -1.0)),
        Some(AudioDeliveryTarget::AppleMusic)
    );
    assert_eq!(AudioDeliveryTarget::matching(LoudnessNormalization::new(-17.0, -1.0)), None);
    assert!(!AudioDeliveryTarget::loudness_range_available(59.9));
    assert!(AudioDeliveryTarget::loudness_range_available(60.0));
    assert_eq!(serde_json::to_string(&AudioDeliveryTarget::EbuR128).unwrap(), "\"ebuR128\"");
}

#[test]
fn ebu_tolerance_is_tighter() {
    let a = AudioAnalysis {
        integrated_lufs: -22.2,
        true_peak_db: -3.0,
        clipped_samples: 0,
        gap_count: 0,
        longest_gap_seconds: 0.0,
        is_dual_mono: false,
        duration_seconds: 120.0,
        loudness_range_lu: None,
    };
    let t = AudioDeliveryTarget::EbuR128;
    let loose = AudioPreflight::evaluate(&a, t.normalization(), false, 0, None, 1.0);
    let tight = AudioPreflight::evaluate(&a, t.normalization(), false, 0, None, t.tolerance_lu());
    assert_eq!(finding(&loose, AudioFindingKind::Loudness).unwrap().severity, AudioSeverity::Pass);
    assert_eq!(finding(&tight, AudioFindingKind::Loudness).unwrap().severity, AudioSeverity::Fail);
}

#[test]
fn caption_mode_sidecar_extension() {
    assert_eq!(CaptionMode::SidecarVtt.sidecar_extension(), Some("vtt"));
    assert_eq!(CaptionMode::SidecarSrt.sidecar_extension(), Some("srt"));
    assert_eq!(CaptionMode::SidecarItt.sidecar_extension(), Some("itt"));
    assert_eq!(CaptionMode::BurnIn.sidecar_extension(), None);
}
