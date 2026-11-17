//! Ports of LogModeConformTests (log mode and HDR conform switches of the clip builder, HDRConform maths) and AutoToneTests.

use std::sync::Arc;

use sq_core_color::auto_tone_solver::{self, WHITE_TARGET};
use sq_core_model::{BasicCorrection, ClipColor, ColorSpaceID, LUTRef, LogMode, MediaInfo, TargetSpace};
use sq_core_time::{Id, Time};

use super::auto_tone::AutoTone;
use super::clip_pipeline::{LutProvider, pipeline_from_clip_color};
use super::cube_lut::CubeLut;
use super::gamut::Gamut;
use super::hdr_conform::{ConformKind, HdrConform, WhiteReference};
use super::pipeline::ColorPipeline;
use super::source_space::{SourceColorSpace as S, SourceSpaceExt};
use super::stages::PreparedBasic;
use super::testing::{constant_lut, dist};
use super::tone_mapping::ToneMapping;
use super::transfer as tf;
use super::vec::Vec3;

struct Embedded(Arc<CubeLut>);

impl LutProvider for Embedded {
    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
        matches!(r, LUTRef::Embedded { .. }).then(|| Arc::clone(&self.0))
    }
}

fn media_info(space: ColorSpaceID, lut: Option<&str>) -> MediaInfo {
    MediaInfo {
        duration: Time::new(1, 1),
        video: None,
        audio: None,
        detected_color_space: Some(space),
        embedded_lut_name: lut.map(String::from),
        is_still: false,
        sound_probed: None,
        created: None,
        camera_model: None,
        shoot_probed: None,
    }
}

fn build(c: &ClipColor, m: &MediaInfo, p: Option<&dyn LutProvider>) -> ColorPipeline {
    pipeline_from_clip_color(c, Id::fixed(5), Some(m), p)
}

fn slog() -> MediaInfo {
    media_info(ColorSpaceID::SLog3SGamut3Cine, Some("Look"))
}

fn hlg() -> MediaInfo {
    media_info(ColorSpaceID::HlgBT2020, None)
}

#[test]
fn log_mode_built_in_and_off() {
    let p = Embedded(Arc::new(constant_lut(0.25)));
    let mut c = ClipColor::default();
    assert!(build(&c, &slog(), Some(&p)).conversion_lut().is_some());
    c.log_mode = LogMode::BuiltIn;
    let built_in = build(&c, &slog(), Some(&p));
    assert!(built_in.conversion_lut().is_none() && built_in.source() == S::SLog3SGamut3Cine);
    c.log_mode = LogMode::Off;
    let off = build(&c, &slog(), Some(&p));
    assert!(off.source() == S::Rec709 && off.conversion_lut().is_none() && off.is_identity());
    assert_eq!(build(&c, &hlg(), None).source(), S::HlgBT2020, "off does not touch HDR sources");
}

#[test]
fn conform_off_skips_the_tone_map_of_hdr_sources_only() {
    let bright = Vec3::splat(0.9);
    let mut c = ClipColor::default();
    let mapped = build(&c, &hlg(), None);
    c.hdr_conform = false;
    let raw = build(&c, &hlg(), None);
    assert!(!mapped.skips_tone_map() && raw.skips_tone_map());
    assert!(raw.process(bright).x > mapped.process(bright).x);
    assert!(!build(&c, &slog(), None).skips_tone_map(), "log sources keep their roll-off");
    c.hdr_conform = true;
    assert!(!pipeline_from_clip_color(&c, Id::fixed(5), None, None).skips_tone_map());
}

#[test]
fn an_hdr_target_keeps_the_hdr_range_of_hdr_sources_only() {
    let bright = Vec3::splat(0.9);
    for t in [TargetSpace::Rec2020PQ, TargetSpace::Rec2020HLG] {
        let mut c = ClipColor::default();
        c.target_space = t;
        let hdr = build(&c, &hlg(), None);
        let sdr = build(&ClipColor::default(), &hlg(), None);
        assert!(hdr.skips_tone_map() && hdr.process(bright).x > sdr.process(bright).x);
        assert!(!build(&c, &slog(), None).skips_tone_map());
    }
    let mut c = ClipColor::default();
    c.target_space = TargetSpace::Rec2020;
    assert!(!build(&c, &hlg(), None).skips_tone_map());
}

#[test]
fn hdr_conform_math() {
    let tm = ToneMapping::default();
    let hlg_ref = tf::hlg_encode(Vec3::ONE);
    assert!((tf::pq_decode(HdrConform::convert(hlg_ref, ConformKind::HlgToPq, &tm).x) - 1.0).abs() < 1e-3);
    let pq = Vec3::splat(2.0).map(tf::pq_encode);
    let back = HdrConform::convert(HdrConform::convert(pq, ConformKind::PqToHlg, &tm), ConformKind::HlgToPq, &tm);
    assert!(dist(back, pq) < 1e-3);
    assert!(HdrConform::convert(Vec3::splat(20.0).map(tf::pq_encode), ConformKind::PqToHlg, &tm).x <= 1.0001);
    let at75 = HdrConform::convert(Vec3::ONE, ConformKind::SdrToHlg(WhiteReference::Percent75), &tm);
    let at100 = HdrConform::convert(Vec3::ONE, ConformKind::SdrToHlg(WhiteReference::Percent100), &tm);
    assert!((at75.x - 0.75).abs() < 5e-3 && (at100.x - 1.0).abs() < 5e-3);
    let p = HdrConform::convert(Vec3::ONE, ConformKind::SdrToPq { peak_nits: 400.0 }, &tm);
    assert!((tf::pq_decode(p.x) * tf::PQ_REFERENCE_WHITE - 400.0).abs() < 2.0);
    assert!(HdrConform::convert(Vec3::ONE, ConformKind::SdrToPq { peak_nits: 0.0 }, &tm).x > 0.0);
    let sig = tf::hlg_encode(Vec3::splat(2.0));
    let expected = tm.apply_peak(Vec3::splat(2.0), S::HlgBT2020.tone_map_peak());
    assert!(dist(HdrConform::convert(sig, ConformKind::HlgToSdr, &tm), expected) < 1e-3);
}

#[test]
fn conform_kind_for_pairs_of_transfers() {
    use ColorSpaceID::{AppleLog, HlgBT2020, PqBT2020, Rec709};
    let k = HdrConform::kind;
    assert_eq!(k(HlgBT2020, TargetSpace::Rec709), Some(ConformKind::HlgToSdr));
    assert_eq!(k(PqBT2020, TargetSpace::Rec709), Some(ConformKind::PqToSdr));
    assert_eq!(k(Rec709, TargetSpace::Rec2020HLG), Some(ConformKind::SdrToHlg(WhiteReference::Percent75)));
    assert_eq!(k(Rec709, TargetSpace::Rec2020PQ), Some(ConformKind::SdrToPq { peak_nits: 203.0 }));
    assert_eq!(k(HlgBT2020, TargetSpace::Rec2020PQ), Some(ConformKind::HlgToPq));
    assert_eq!(k(PqBT2020, TargetSpace::Rec2020HLG), Some(ConformKind::PqToHlg));
    assert_eq!(k(HlgBT2020, TargetSpace::Rec2020HLG), None);
    assert_eq!(k(Rec709, TargetSpace::Rec709), None);
    assert_eq!(k(AppleLog, TargetSpace::Rec2020PQ), None, "log goes through its own conversion");
}

// MARK: Auto Tone

fn apply(b: &BasicCorrection, linear: &[Vec3]) -> Vec<Vec3> {
    let p = PreparedBasic::new(b, Gamut::rec709());
    linear.iter().map(|l| p.apply(l.map(tf::bt709_oetf), false).map(tf::bt709_inverse_oetf)).collect()
}

fn greys(lo: f32, hi: f32, cast: Vec3) -> Vec<Vec3> {
    let n = 600;
    (0..n).map(|i| cast * tf::bt709_inverse_oetf(lo + (hi - lo) * i as f32 / (n - 1) as f32)).collect()
}

#[test]
fn auto_tone_core_model_matches_basic_correction() {
    let b = BasicCorrection {
        exposure: 0.7,
        contrast: 35.0,
        shadows: -25.0,
        highlights: 45.0,
        whites: 30.0,
        blacks: -60.0,
        ..BasicCorrection::default()
    };
    let p = PreparedBasic::new(&b, Gamut::rec709());
    for i in 0..=22 {
        let y = i as f32 * 0.05;
        assert!((auto_tone_solver::tone(y, &b) - p.apply(Vec3::splat(y), false).y).abs() < 2e-4, "y {y}");
    }
    // The first effect's Basic Correction works on source-linear light (pre); for Rec.709 that is the same picture.
    let b = BasicCorrection {
        exposure: -0.6,
        contrast: 20.0,
        shadows: 15.0,
        whites: 40.0,
        blacks: -20.0,
        ..BasicCorrection::default()
    };
    let p = PreparedBasic::new(&b, Gamut::rec709());
    let mut y = 0.02f32;
    while y <= 1.0 {
        let pre = tf::bt709_oetf(p.apply(Vec3::splat(tf::bt709_inverse_oetf(y)), true).y);
        assert!((auto_tone_solver::tone(y, &b) - pre).abs() < 2e-4);
        y += 0.07;
    }
}

#[test]
fn auto_tone_dark_frame_is_brightened_and_stable() {
    let frame = greys(0.03, 0.4, Vec3::ONE);
    let b = AutoTone::solve(&frame, &BasicCorrection::default()).expect("solves");
    assert!(b.exposure > 0.3 && b.temperature == 0.0 && b.tint == 0.0);
    assert!(AutoTone::solve(&apply(&b, &frame), &b).is_none());
}

#[test]
fn auto_tone_casts_are_neutralised_once_only() {
    let frame = greys(0.02, 0.97, Vec3::new(1.07, 1.0, 0.9));
    let b = AutoTone::solve(&frame, &BasicCorrection::default()).expect("solves");
    assert!(b.temperature < 0.0, "a warm cast is cooled");
    let shown = apply(&b, &frame);
    let mid = shown[shown.len() / 2];
    assert!((mid.x / mid.y - 1.0).abs() < 0.02 && (mid.z / mid.y - 1.0).abs() < 0.02);
    if let Some(again) = AutoTone::solve(&shown, &b) {
        assert!((again.temperature - b.temperature).abs() <= 1.0 && (again.tint - b.tint).abs() <= 1.0);
        assert!((again.exposure - b.exposure).abs() <= 0.03);
    }
    for cast in [Vec3::new(1.1, 1.0, 0.85), Vec3::new(0.88, 1.0, 1.15)] {
        let frame = greys(0.04, 0.85, cast);
        let b = AutoTone::solve(&frame, &BasicCorrection::default()).expect("solves");
        assert!(b.temperature != 0.0 || b.tint != 0.0);
        let shown = apply(&b, &frame);
        let mut l: Vec<f32> =
            shown.iter().map(|p| tf::bt709_oetf(Vec3::new(0.2126, 0.7152, 0.0722).dot(*p).max(0.0))).collect();
        l.sort_by(f32::total_cmp);
        assert!(
            l[((l.len() - 1) as f32 * 0.995) as usize] <= WHITE_TARGET + 0.01,
            "highlights do not clip after the white balance"
        );
        let mid = shown[shown.len() / 2];
        assert!((mid.x / mid.y - 1.0).abs() < 0.02 && (mid.z / mid.y - 1.0).abs() < 0.02);
        if let Some(again) = AutoTone::solve(&shown, &b) {
            assert!((again.exposure - b.exposure).abs() <= 0.02);
            assert!(
                (again.contrast - b.contrast).abs() <= 0.5
                    && (again.whites - b.whites).abs() <= 0.5
                    && (again.blacks - b.blacks).abs() <= 0.5
            );
            assert!(again.temperature == b.temperature && again.tint == b.tint);
        }
    }
}

#[test]
fn auto_tone_strong_cast_and_full_range_frames_are_left_alone() {
    let cur = BasicCorrection::default();
    assert!(AutoTone::solve(&greys(0.0, 1.0, Vec3::ONE), &cur).is_none());
    assert!(AutoTone::solve(&greys(0.0, 1.0, Vec3::new(1.6, 1.0, 0.5)), &cur).is_none());
    assert!(AutoTone::solve(&[], &cur).is_none());
}

/// The working space is scene-linear light (1.0 = 203 nit), so the HLG <-> PQ conform of an HDR sequence is "decode both to the
/// same linear light": a clip of either transfer lands on the value the explicit `HdrConform` route gives, an SDR clip in an HDR
/// sequence stays at its linear value (reference white = 1.0), and an SDR sequence tone-maps HDR clips (`HlgToSdr` / `PqToSdr`).
#[test]
fn hdr_sequence_conform_matches_the_explicit_route() {
    let tm = ToneMapping::default();
    let mut c = ClipColor::default();
    c.target_space = TargetSpace::Rec2020PQ;
    let hlg_pipe = build(&c, &hlg(), None);
    let pq_pipe = build(&c, &media_info(ColorSpaceID::PqBT2020, None), None);
    for light in [0.25_f32, 1.0, 2.0, 4.0] {
        // Neutral gray in HLG: sequence output equals the light the HLG -> PQ conform encodes (decode the PQ code again).
        let hlg_sig = tf::hlg_encode(Vec3::splat(light));
        let got = hlg_pipe.process(hlg_sig).x;
        let via_pq = tf::pq_decode(HdrConform::convert(hlg_sig, ConformKind::HlgToPq, &tm).x);
        assert!((got - via_pq).abs() < 2e-3 * light.max(1.0), "hlg {light}: {got} vs {via_pq}");
        assert!((got - light).abs() < 2e-3 * light.max(1.0), "hlg {light}: {got}");
        // Same light in PQ, and the PQ -> HLG route comes back to it (peak 1000 nit = 4.93 holds in HLG's range).
        let pq_sig = Vec3::splat(light).map(tf::pq_encode);
        let got = pq_pipe.process(pq_sig).x;
        let via_hlg = tf::hlg_decode(HdrConform::convert(pq_sig, ConformKind::PqToHlg, &tm)).x;
        assert!((got - via_hlg).abs() < 2e-3 * light.max(1.0), "pq {light}: {got} vs {via_hlg}");
    }
    // SDR in an HDR sequence: linear value unchanged, white = 1.0 (PQ code 573 limited, HLG signal 0.75).
    let sdr = build(&c, &media_info(ColorSpaceID::Rec709, None), None);
    assert!((sdr.process(Vec3::ONE).x - 1.0).abs() < 2e-3);
    let sdr_pq = HdrConform::convert(Vec3::ONE, ConformKind::SdrToPq { peak_nits: tf::PQ_REFERENCE_WHITE }, &tm).x;
    assert!((tf::pq_decode(sdr_pq) - 1.0).abs() < 1e-3);
    let white_code = (64.0 + sdr_pq * 876.0).round();
    assert!((572.0..=574.0).contains(&white_code), "{white_code}");
    // SDR sequence: both HDR clips are tone-mapped (peak 4x white does not exceed 1 + roll-off).
    let mut sd = ClipColor::default();
    sd.target_space = TargetSpace::Rec709;
    let tm_hlg = build(&sd, &hlg(), None).process(tf::hlg_encode(Vec3::splat(4.0))).x;
    assert!(tm_hlg < 4.0 && tm_hlg > 0.5, "{tm_hlg}");
}
