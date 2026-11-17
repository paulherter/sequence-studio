//! Effects, audio, transitions, blend modes and keys through the mapper. Swift: MapperTests.swift (second half).
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{ItemSpec, PRFixture, SECOND as S, Source};
use sq_core_audio::audio_effects::{AUDIO_NOISE_REDUCTION_KIND, NOISE_AMOUNT_REDUCTION_KEY};
use sq_core_color::ClipEffectColorExt;
use sq_core_effects::adjustment_clip::ADJUSTMENT_KIND;
use sq_core_model::{
    BlendMode, COLOR_KIND, Clip, ClipEffect, ClipFootageColor, ColorSpaceID, EffectColor, LUTRef, MediaFingerprint,
    MediaRef, TrackKind, TransitionKind,
};
use sq_core_time::{Id, SequentialIds, Time, Vec2};
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::primport_report::{PRImportReport, Status};
use sq_premiere_import::prmapper::{PRImportResult, PRMapper};
use std::collections::BTreeMap;

fn uhd(path: &str) -> MediaRef {
    let info: sq_core_model::MediaInfo = serde_json::from_value(serde_json::json!({
        "duration": {"value": 60, "timescale": 1},
        "video": {"width": 3840, "height": 2160, "codec": "hvc1", "bitDepth": 10, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false}
    }))
    .unwrap();
    let mut r = MediaRef::new(Id::from_u128(0x77), "a", path, MediaFingerprint::new(1));
    r.duration = Some(Time::new(60, 1));
    r.info = Some(info);
    r
}

fn map_with(f: &PRFixture, media: &BTreeMap<String, MediaRef>) -> PRImportResult {
    PRMapper::map(&PRReader::read(&f.data()).unwrap(), "Test", media, false, &mut SequentialIds::default())
}

fn map(f: &PRFixture) -> PRImportResult {
    map_with(f, &BTreeMap::new())
}

fn clips(r: &PRImportResult, kind: TrackKind) -> Vec<Clip> {
    r.project
        .timelines
        .iter()
        .find(|t| t.name == "Main")
        .unwrap()
        .tracks
        .iter()
        .filter(|t| t.kind == kind)
        .flat_map(|t| t.clips().to_vec())
        .collect()
}

fn video(r: &PRImportResult) -> Vec<Clip> {
    clips(r, TrackKind::Video)
}

fn item(start: i64, end: i64, in_point: i64, out_point: i64, source: Source) -> ItemSpec {
    ItemSpec::new(start, end, in_point, out_point, source)
}

fn pv(e: &ClipEffect, key: &str) -> Option<f64> {
    e.parameters.get(key).map(|p| p.value)
}

fn kinds(c: &Clip) -> Vec<&str> {
    c.effects.iter().map(|e| e.kind.as_str()).collect()
}

fn rgb_black() -> EffectColor {
    EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 }
}

fn utf16_path(p: &str) -> String {
    let bytes: Vec<u8> = p.encode_utf16().chain(std::iter::once(0)).flat_map(u16::to_le_bytes).collect();
    sq_core_time::base64::encode(&bytes)
}

#[test]
fn effects_map_to_clip_effects() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let p = f.p(1, "40.");
    let blur = f.component("AE.ADBE Gaussian Blur 2", &[p]);
    let sp = [f.p(1, "18374686479671623680"), f.p(2, "127.5"), f.p(3, "135."), f.p(4, "10."), f.p(5, "177.")];
    let shadow = f.component("AE.ADBE Drop Shadow", &sp);
    let look = utf16_path("/L/Look.cube");
    let lp = [
        f.p(3, "true"),
        f.p(7, "-3."),
        f.p(8, "1."),
        f.p(13, "-6.88"),
        f.p(20, "50."),
        f.p(23, "true"),
        f.p(26, "80."),
        f.p(130, "28"),
        f.blob_param(24, &look, ""),
    ];
    let lumetri = f.component("AE.ADBE Lumetri", &lp);
    let gp = [f.pt(1, "0.5:0.5"), f.pt(2, "0.75:0.5"), f.p(11, "true"), f.p(3, "120."), f.p(8, "80.")];
    let geo = f.component("AE.ADBE Geometry2", &gp);
    let cp = [f.p(8, "10."), f.p(11, "5.")];
    let crop = f.component("AE.ADBE Motion", &cp);
    let mirror = f.component("AE.ADBE Wave Warp", &[]);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&crop, &blur, &shadow, &lumetri, &geo, &mirror]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), uhd("/f/a.mov"))]));
    let c = &video(&r)[0];
    let find = |kind: &str| c.effects.iter().find(|e| e.kind == kind);
    let crop = find(ClipEffect::CROP_KIND).unwrap();
    assert_eq!(pv(crop, ClipEffect::CROP_LEFT_KEY), Some(10.0));
    assert_eq!(pv(crop, ClipEffect::CROP_BOTTOM_KEY), Some(5.0));
    // Premiere Blurriness 40 -> SQ Blurriness 40 (the effect itself maps it to sigma).
    assert_eq!(pv(find(ClipEffect::GAUSSIAN_BLUR_KIND).unwrap(), ClipEffect::BLURRINESS_KEY), Some(40.0));
    let ds = find(ClipEffect::DROP_SHADOW_KIND).unwrap();
    assert_eq!(pv(ds, ClipEffect::SHADOW_OPACITY_KEY), Some(50.0));
    assert_eq!(pv(ds, ClipEffect::SHADOW_SOFTNESS_KEY), Some(177.0));
    assert_eq!(ds.colors.get(ClipEffect::SHADOW_COLOR_KEY).map(|c| c.value), Some(rgb_black()));
    let grade = find(COLOR_KIND).unwrap();
    let basic = grade.color_effect(None, 1).basic;
    assert!(
        basic.temperature == -3.0
            && basic.tint == 1.0
            && (basic.highlights + 6.88).abs() < 1e-4
            && basic.saturation == 50.0
    );
    // Creative look: the .cube path (UTF-16LE, NUL-terminated) and its intensity.
    let creative = grade.color_effect(None, 1).creative;
    assert!(creative.look == Some(LUTRef::File { path: "/L/Look.cube".into() }) && creative.intensity == 80.0);
    // Look color space 28: the LUT output is re-encoded (power 2.4 / 1.961) as a master curve.
    let master = grade.color_effect(None, 1).curves.master;
    assert!(
        master.first().is_some_and(|p| p.x == 0.0 && p.y == 0.0)
            && master.last().is_some_and(|p| p.x == 1.0 && p.y == 1.0)
    );
    let mid = master.iter().find(|p| p.x == 0.55).unwrap();
    assert!((f64::from(mid.y) - 0.55f64.powf(2.4 / 1.961)).abs() < 1e-5);
    assert_eq!(
        c.footage_color,
        ClipFootageColor { source: Some(ColorSpaceID::Rec709), use_embedded_lut: false, ..ClipFootageColor::default() }
    );
    let stage = find(ClipEffect::TRANSFORM_KIND).unwrap();
    assert_eq!(pv(stage, ClipEffect::STAGE_POSITION_X_KEY), Some(960.0)); // 0.75 * 3840 - 1920
    assert_eq!(pv(stage, ClipEffect::STAGE_ANCHOR_X_KEY), Some(0.0));
    assert_eq!(pv(stage, ClipEffect::STAGE_SCALE_KEY), Some(120.0));
    assert_eq!(pv(stage, ClipEffect::STAGE_OPACITY_KEY), Some(80.0));
    assert_eq!(r.report.status_of("AE.ADBE Wave Warp"), Some(Status::Dropped));
    assert_eq!(r.report.status_of("AE.ADBE Gaussian Blur 2"), Some(Status::Mapped));
}

#[test]
fn gaussian_blur_repeat_edge_pixels_maps_to_the_checkbox() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let on_params = [f.p(1, "40."), f.p(2, "0"), f.p(3, "true")];
    let off_params = [f.p(1, "40."), f.p(2, "0"), f.p(3, "false")];
    let on = f.component("AE.ADBE Gaussian Blur 2", &on_params);
    let off = f.component("AE.ADBE Gaussian Blur 2", &off_params);
    let a = f.item(item(0, S, 0, S, Source::Media(m.clone())).components(&[&on]));
    let b = f.item(item(S, 2 * S, 0, S, Source::Media(m)).components(&[&off]));
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let r = map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), uhd("/f/a.mov"))]));
    let flags: Vec<Option<f64>> = video(&r)
        .iter()
        .map(|c| {
            c.effects
                .iter()
                .find(|e| e.kind == ClipEffect::GAUSSIAN_BLUR_KIND)
                .and_then(|e| pv(e, ClipEffect::REPEAT_EDGE_PIXELS_KEY))
        })
        .collect();
    assert_eq!(flags[0], Some(1.0));
    assert!(flags[1].is_none_or(|v| v == 0.0));
}

#[test]
fn adjustment_layer_becomes_adjustment_clip() {
    let mut f = PRFixture::new();
    let gp = [f.param(
        Some(2),
        "0.5:0.5",
        Some("0,0.5:0.5,0,0,0,0,0,0;254016000000,0.25:0.5,0,0,0,0,0,0"),
        "PointComponentParam",
    )];
    let geo = f.component("AE.ADBE Geometry2", &gp);
    let mp = [f.pt(1, "0.75:0.5"), f.p(2, "90.")];
    let mirror = f.component("AE.ADBE Mirror", &mp);
    let lp = [f.p(11, "1.5")];
    let lum = f.component("AE.ADBE Lumetri", &lp);
    let text = f.component("AE.ADBE Text", &[]);
    let adj = f.item(item(S, 2 * S, 0, S, Source::Graphic).components(&[&text, &geo, &mirror, &lum]).adjustment());
    let t = f.track(&[adj]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let c = &video(&r)[0];
    assert!(
        c.generator.as_ref().is_some_and(|g| g.kind == ADJUSTMENT_KIND)
            && c.start == Time::new(1, 1)
            && c.duration() == Time::new(1, 1)
    );
    assert_eq!(kinds(c), vec![ClipEffect::TRANSFORM_KIND, ClipEffect::MIRROR_KIND, COLOR_KIND]);
    let m = &c.effects[1];
    assert_eq!(m.points.get(ClipEffect::MIRROR_CENTER_KEY).map(|p| p.value), Some(Vec2::new(0.25 * 1080.0, 0.0)));
    assert_eq!(pv(m, ClipEffect::MIRROR_ANGLE_KEY), Some(90.0));
    assert!(c.effects[0].parameters.get(ClipEffect::STAGE_POSITION_X_KEY).is_some_and(|p| p.is_animated()));
    assert_eq!(c.effects[2].color_effect(None, 1).basic.exposure, 1.5);
    assert_eq!(r.report.status_of("Adjustment layer"), Some(Status::Mapped));
}

/// AE.ADBE Shape path blob (param 1) as in the maintainer's files: UInt32 2, UInt32 point count, per point a Float32 0 and
/// three (x, y) Float32 pairs (vertex and its two tangents, px), then one byte 1 (closed).
fn shape_path_blob(width: f32, height: f32) -> String {
    let mut d = Vec::new();
    d.extend_from_slice(&2u32.to_le_bytes());
    d.extend_from_slice(&4u32.to_le_bytes());
    for (x, y) in [(0.0f32, 0.0f32), (width, 0.0), (width, height), (0.0, height)] {
        d.extend_from_slice(&0f32.to_bits().to_le_bytes());
        for _ in 0..3 {
            d.extend_from_slice(&x.to_bits().to_le_bytes());
            d.extend_from_slice(&y.to_bits().to_le_bytes());
        }
    }
    d.push(1);
    sq_core_time::base64::encode(&d)
}

/// The Mister Horse carrier Shape of a 1080 x 1920 sequence: a 1920 x 1080 rectangle at 177.78 %, anchored on its center.
fn carrier_shape(f: &mut PRFixture, width: f32, height: f32, scale: &str) -> String {
    let blob = shape_path_blob(width, height);
    let params = [
        f.blob_param(1, &blob, ""),
        f.pt(4, "0.5:0.5"),
        f.p(5, scale),
        f.p(6, scale),
        f.p(7, "true"),
        f.p(8, "0."),
        f.pt(10, "0.8888888955116272:0.28125"),
    ];
    f.component("AE.ADBE Shape", &params)
}

fn adjustment_with(f: &mut PRFixture, comps: &[String]) -> PRImportResult {
    let names: Vec<&str> = comps.iter().map(String::as_str).collect();
    let it = f.item(item(0, S, 0, S, Source::Graphic).components(&names).adjustment());
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    map(f)
}

/// All 140 adjustment-flagged graphics in the maintainer's projects are Mister Horse carriers: two Text layers and a Shape
/// covering the frame. Premiere draws none of it and the effects reach the whole frame, as SQ's adjustment layer does:
/// nothing is lost, nothing is reported.
#[test]
fn adjustment_layer_with_a_frame_sized_carrier_is_not_a_loss() {
    let mut f = PRFixture::new();
    let comps = [f.component("AE.ADBE Text", &[]), carrier_shape(&mut f, 1920.0, 1080.0, "177.777770996094")];
    let r = adjustment_with(&mut f, &comps);
    assert_eq!(r.report.status_of("Adjustment layer area"), None);
    assert_eq!(r.report.status_of("Adjustment layer"), Some(Status::Mapped));
    assert_eq!(r.report.count_of("AE.ADBE Shape"), 0);
}

/// Without a frame-covering layer Premiere limits the effects to the shape / text; SQ's adjustment layer covers the frame,
/// so that difference is reported (text only, a small shape, a shape with an unreadable path).
#[test]
fn adjustment_layer_without_a_frame_sized_carrier_is_reported() {
    for kind in 0..3 {
        let mut f = PRFixture::new();
        let comps = match kind {
            0 => vec![f.component("AE.ADBE Text", &[])],
            1 => vec![carrier_shape(&mut f, 400.0, 300.0, "100.")],
            _ => vec![f.component("AE.ADBE Shape", &[])],
        };
        let r = adjustment_with(&mut f, &comps);
        assert_eq!(r.report.status_of("Adjustment layer area"), Some(Status::Approximated));
        assert!(
            r.report.entries().iter().any(|e| e.feature == "Adjustment layer area"
                && e.note.contains("effect area not limited to the shape/text"))
        );
    }
}

#[test]
fn slide_preset_drops_mirror_and_maps_directional_blur() {
    let mut f = PRFixture::new();
    let gp = [f.p(3, "200."), f.p(11, "true")];
    let geo = f.component("AE.ADBE Geometry2", &gp);
    let mp = [f.pt(1, "0.75:0.5")];
    let mirror = f.component("AE.ADBE Mirror", &mp);
    let bp = [f.p(1, "90."), f.p(2, "30.")];
    let blur = f.component("AE.ADBE Motion Blur", &bp);
    let r = adjustment_with(&mut f, &[geo, mirror, blur]);
    let fx = &video(&r)[0].effects;
    assert_eq!(
        fx.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(),
        vec![ClipEffect::TRANSFORM_KIND, ClipEffect::DIRECTIONAL_BLUR_KIND]
    );
    assert!(
        pv(&fx[1], ClipEffect::BLUR_DIRECTION_KEY) == Some(90.0)
            && pv(&fx[1], ClipEffect::BLUR_LENGTH_KEY) == Some(30.0)
    );
    assert_eq!(r.report.status_of("AE.ADBE Mirror"), Some(Status::Dropped));
}

#[test]
fn colour_matte_becomes_solid_clip() {
    let mut f = PRFixture::new();
    let p = f.p(0, "50.");
    let op = f.component("AE.ADBE Opacity", &[p]);
    let it = f.item(
        item(0, S, 0, S, Source::Matte(Some("3382d40001000000".into()))).components(&[&op]).name("Farbfl\u{E4}che"),
    );
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let g = video(&r)[0].generator.clone().unwrap();
    assert_eq!(g.kind, "solid");
    assert_eq!(g.payload, vec![0x33, 0x82, 0xd4]);
    assert_eq!(r.report.status_of("Color matte"), Some(Status::Mapped));
}

fn audio_params(f: &mut PRFixture, level: &str) -> Vec<String> {
    vec![f.param(None, "false", None, "AudioComponentParam"), f.param(None, level, None, "AudioComponentParam")]
}

#[test]
fn audio_volume_and_linking() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    // Premiere level is linear with 1.0 = +15 dB: 0.1 is -5 dB.
    let vp = audio_params(&mut f, "0.1");
    let vol = f.audio_component("Volume", "Internal Volume Stereo", &vp);
    let np = audio_params(&mut f, "0.05");
    let nr = f.audio_component("Noise Reduction", "c6762838-e451-4d22-9c90-b0eaa734605a", &np);
    let v = f.item(item(0, S, 0, S, Source::Media(m.clone())));
    let a = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&vol, &nr]).audio());
    let (vt, at) = (f.track(&[v]), f.audio_track(&[a]));
    f.sequence("Main", &[vt], &[at]);
    let r = map(&f);
    let (vc, ac) = (&video(&r)[0], &clips(&r, TrackKind::Audio)[0]);
    assert!(vc.link.is_some() && vc.link == ac.link);
    assert!((ac.animation.volume.value - 10f64.powf(-5.0 / 20.0)).abs() < 1e-9);
    let nr_fx = ac.effects.iter().find(|e| e.kind == AUDIO_NOISE_REDUCTION_KIND).unwrap();
    assert!((pv(nr_fx, NOISE_AMOUNT_REDUCTION_KEY).unwrap_or(-1.0) - 5.0).abs() < 1e-9);
}

/// Right-click > Audio Gain lives in `AudioClip/Gain` (linear): -20 dB = 0.1. It multiplies the Volume level.
#[test]
fn audio_gain_is_imported() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let a = f.item(item(0, S, 0, S, Source::Media(m.clone())).audio().gain(0.1));
    let vp = audio_params(&mut f, "0.1");
    let vol = f.audio_component("Volume", "Internal Volume Stereo", &vp);
    let b = f.item(item(S, 2 * S, 0, S, Source::Media(m)).components(&[&vol]).audio().gain(0.1));
    let t = f.audio_track(&[a, b]);
    f.sequence("Main", &[], &[t]);
    let cs = clips(&map(&f), TrackKind::Audio);
    // Audio Gain -> Clip.audioGainDB (SQ's Audio Gain, before the effects); the Volume level stays the volume.
    assert!((cs[0].audio_gain_db - -20.0).abs() < 1e-9 && (cs[0].animation.volume.value - 1.0).abs() < 1e-9);
    assert!(
        (cs[1].audio_gain_db - -20.0).abs() < 1e-9
            && (cs[1].animation.volume.value - 10f64.powf(-5.0 / 20.0)).abs() < 1e-9
    );
}

#[test]
fn cross_dissolve_becomes_transition() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let a = f.item(item(0, 2 * S, 0, 2 * S, Source::Media(m.clone())));
    let b = f.item(item(2 * S, 4 * S, 5 * S, 7 * S, Source::Media(m)));
    let tr = f.transition(2 * S - S / 2, 2 * S + S / 2, "AE.ADBE Cross Dissolve New");
    let t = f.track_with(&[a, b], &[tr], false, false);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let track = &r.project.timelines[0].tracks[0];
    let tr = &track.transitions[0];
    assert!(tr.kind == TransitionKind::CrossDissolve && tr.duration == Time::new(1, 1));
    assert!(tr.outgoing == Some(track.clips()[0].id) && tr.incoming == Some(track.clips()[1].id));
}

/// Audio crossfades (TCL C8L): Constant Power / Gain keep their kind; other fades become Constant Power, not a video dissolve.
#[test]
fn audio_transitions_keep_audio_kinds() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.wav", "a.wav");
    let mut tracks = Vec::new();
    for name in ["AE.ADBE Constant Power", "AE.ADBE Constant Gain", "AE.ADBE Custom Fade"] {
        let a = f.item(item(0, 2 * S, 0, 2 * S, Source::Media(m.clone())));
        let b = f.item(item(2 * S, 4 * S, 5 * S, 7 * S, Source::Media(m.clone())));
        let tr = f.transition(2 * S - S / 2, 2 * S + S / 2, name);
        tracks.push(f.track_with(&[a, b], &[tr], true, false));
    }
    f.sequence("Main", &[], &tracks);
    let r = map(&f);
    let kinds: Vec<TransitionKind> =
        r.project.timelines[0].tracks.iter().filter_map(|t| t.transitions.first().map(|x| x.kind)).collect();
    assert_eq!(kinds, vec![TransitionKind::ConstantPower, TransitionKind::ConstantGain, TransitionKind::ConstantPower]);
    assert_eq!(r.report.status_of("Transition AE.ADBE Custom Fade"), Some(Status::Approximated));
}

fn blend_clip(code: i64, index: Option<i64>) -> (Clip, PRImportResult) {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let mut ps = vec![f.p(1, "100."), f.p(2, &code.to_string())];
    if let Some(i) = index {
        ps.push(f.p(3, &i.to_string()));
    }
    let opacity = f.component("AE.ADBE Opacity", &ps);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&opacity]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    (video(&r)[0].clone(), r)
}

/// Measured on the maintainer's projects: (code, menu index) pairs 18/0 Normal, 22/10 Add, 11/9 Color Dodge, 17/4 Color Burn,
/// 12/13 Soft Light.
#[test]
fn blend_mode_is_read_from_opacity_menu_index() {
    let table = [
        (18, 0, BlendMode::Normal),
        (22, 10, BlendMode::Add),
        (11, 9, BlendMode::ColorDodge),
        (17, 4, BlendMode::ColorBurn),
        (12, 13, BlendMode::SoftLight),
        (0, 8, BlendMode::Screen),
        (0, 3, BlendMode::Multiply),
        (0, 12, BlendMode::Overlay),
        (0, 19, BlendMode::Difference),
        (0, 20, BlendMode::Exclusion),
        (0, 2, BlendMode::Darken),
        (0, 7, BlendMode::Lighten),
    ];
    for (code, idx, mode) in table {
        let (c, r) = blend_clip(code, Some(idx));
        assert_eq!(c.blend_mode, mode);
        if mode != BlendMode::Normal {
            assert_eq!(r.report.status_of("Opacity blend mode"), Some(Status::Mapped));
        }
    }
}

#[test]
fn blend_mode_falls_back_to_code_without_index() {
    assert_eq!(blend_clip(22, None).0.blend_mode, BlendMode::Add);
    assert_eq!(blend_clip(18, None).0.blend_mode, BlendMode::Normal);
}

#[test]
fn every_menu_index_maps_to_the_full_set() {
    let table = [
        (1, BlendMode::Dissolve),
        (6, BlendMode::DarkerColor),
        (11, BlendMode::LighterColor),
        (15, BlendMode::VividLight),
        (16, BlendMode::LinearLight),
        (17, BlendMode::PinLight),
        (18, BlendMode::HardMix),
        (21, BlendMode::Subtract),
        (22, BlendMode::Divide),
        (23, BlendMode::Hue),
        (24, BlendMode::Saturation),
        (25, BlendMode::Color),
        (26, BlendMode::Luminosity),
    ];
    for (idx, mode) in table {
        let (c, r) = blend_clip(0, Some(idx));
        assert_eq!(c.blend_mode, mode, "index {idx}");
        assert_eq!(r.report.status_of("Opacity blend mode"), Some(Status::Mapped));
    }
}

#[test]
fn unknown_blend_index_stays_normal_and_is_reported() {
    let (c, r) = blend_clip(19, Some(40));
    assert_eq!(c.blend_mode, BlendMode::Normal);
    assert_eq!(r.report.status_of("Opacity blend mode"), Some(Status::Dropped));
}

fn lumetri_media_clip(params: &[(i64, &str)]) -> PRImportResult {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let ps: Vec<String> = params.iter().map(|(id, v)| f.p(*id, v)).collect();
    let lumetri = f.component("AE.ADBE Lumetri", &ps);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&lumetri]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    map(&f)
}

#[test]
fn lumetri_sharpen_becomes_sharpen_after_colour() {
    let r = lumetri_media_clip(&[(3, "true"), (7, "-3."), (23, "true"), (29, "20.")]);
    let fx = &video(&r)[0].effects;
    assert_eq!(fx.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(), vec![COLOR_KIND, ClipEffect::SHARPEN_KIND]);
    assert_eq!(pv(&fx[1], ClipEffect::SHARPEN_AMOUNT_KEY), Some(20.0));
    assert_eq!(r.report.status_of("Lumetri sharpen"), Some(Status::Approximated));
}

#[test]
fn lumetri_negative_or_zero_sharpen_adds_nothing() {
    for value in ["0.", "-30."] {
        let r = lumetri_media_clip(&[(3, "true"), (7, "-3."), (29, value)]);
        assert!(!video(&r)[0].effects.iter().any(|e| e.kind == ClipEffect::SHARPEN_KIND));
    }
}

#[test]
fn mosaic_tint_flip_and_noise_map() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let mp = [f.p(1, "63"), f.p(2, "106"), f.p(3, "true")];
    let mosaic = f.component("AE.ADBE Mosaic", &mp);
    let tp = [f.p(1, "18374686479671623680"), f.p(2, "18374966859414961920"), f.p(3, "60.")];
    let tint = f.component("AE.ADBE Tint", &tp);
    let flip = f.component("AE.ADBE Horizontal Flip", &[]);
    let np = [f.p(3, "40."), f.p(8, "50."), f.p(10, "50.")];
    let noise = f.component("AE.ADBE_Noise_FX", &np);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&mosaic, &tint, &flip, &noise]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let fx = &video(&r)[0].effects;
    assert_eq!(
        fx.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(),
        vec![ClipEffect::MOSAIC_KIND, ClipEffect::TINT_KIND, ClipEffect::HORIZONTAL_FLIP_KIND, ClipEffect::NOISE_KIND]
    );
    assert!(
        pv(&fx[0], ClipEffect::MOSAIC_COLUMNS_KEY) == Some(63.0)
            && pv(&fx[0], ClipEffect::MOSAIC_ROWS_KEY) == Some(106.0)
    );
    assert_eq!(pv(&fx[0], ClipEffect::MOSAIC_SHARP_KEY), Some(1.0));
    assert_eq!(pv(&fx[1], ClipEffect::TINT_AMOUNT_KEY), Some(60.0));
    assert_eq!(fx[1].colors.get(ClipEffect::TINT_BLACK_KEY).map(|c| c.value), Some(rgb_black()));
    assert_eq!(
        fx[1].colors.get(ClipEffect::TINT_WHITE_KEY).map(|c| c.value),
        Some(EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 })
    );
    assert!(pv(&fx[3], ClipEffect::NOISE_AMOUNT_KEY).unwrap_or(0.0) > 0.0);
    assert_eq!(r.report.status_of("AE.ADBE Mosaic"), Some(Status::Mapped));
    assert_eq!(r.report.status_of("AE.ADBE Tint"), Some(Status::Mapped));
    assert_eq!(r.report.status_of("AE.ADBE Horizontal Flip"), Some(Status::Mapped));
    assert_eq!(r.report.status_of("AE.ADBE_Noise_FX"), Some(Status::Approximated));
}

/// Param ids as in the maintainer's two Ultra Key instances (key color #4FB120, Premiere's defaults elsewhere).
fn ultra_key(colour: &str, output: &str) -> (Vec<ClipEffect>, PRImportReport) {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let values: [(i64, &str); 19] = [
        (1, output),
        (2, "3"),
        (3, colour),
        (5, "45."),
        (6, "10."),
        (7, "50."),
        (8, "100."),
        (9, "10."),
        (12, "10."),
        (13, "0."),
        (14, "30."),
        (15, "40."),
        (18, "25."),
        (19, "50."),
        (20, "60."),
        (21, "50."),
        (24, "80."),
        (25, "5."),
        (26, "100."),
    ];
    let ps: Vec<String> = values.iter().map(|(id, v)| f.p(*id, v)).collect();
    let key = f.component("AE.ADBE Ultra Key", &ps);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&key]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    (video(&r)[0].effects.clone(), r.report)
}

#[test]
fn ultra_key_maps_hue_and_shared_controls() {
    let (fx, report) = ultra_key("18374773344059793408", "1");
    let e = &fx[0];
    assert!(fx.len() == 1 && e.kind == ClipEffect::ULTRA_KEY_KIND);
    let v = |k: &str| pv(e, k).unwrap_or(f64::NAN);
    assert!((v(ClipEffect::KEY_HUE_KEY) - 100.55).abs() < 0.01); // hue of #4FB120
    assert!(v(ClipEffect::PEDESTAL_KEY) == 10.0 && v(ClipEffect::CHOKE_KEY) == 10.0);
    assert!(v(ClipEffect::KEY_CONTRAST_KEY) == 30.0 && v(ClipEffect::KEY_MIDPOINT_KEY) == 40.0);
    assert!(v(ClipEffect::SPILL_KEY) == 60.0 && v(ClipEffect::SPILL_RANGE_KEY) == 50.0); // Premiere Spill is id 20; 18 is Desaturate
    assert!(
        v(ClipEffect::KEY_SATURATION_KEY) == 80.0
            && v(ClipEffect::KEY_HUE_SHIFT_KEY) == 5.0
            && v(ClipEffect::KEY_LUMA_KEY) == 100.0
    );
    assert_eq!(v(ClipEffect::KEY_OUTPUT_KEY), 1.0);
    // Matte generation is SQ's own formulation: the Green Screen preset's starting values, not Premiere's numbers.
    assert!(v(ClipEffect::TOLERANCE_KEY) == 45.0 && v(ClipEffect::SOFTEN_KEY) == 20.0);
    assert_eq!(report.status_of("AE.ADBE Ultra Key"), Some(Status::Approximated));
}

#[test]
fn ultra_key_without_a_key_colour_is_dropped() {
    let (fx, report) = ultra_key("18374686479671623680", "0"); // Premiere's default: black, keys nothing
    assert!(fx.is_empty());
    assert_eq!(report.status_of("AE.ADBE Ultra Key"), Some(Status::Dropped));
}

/// Ramp param ids as in the maintainer's instance: points are 0...1 of the frame.
#[test]
fn ramp_becomes_gradient() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let ps = [
        f.p(1, "0.5:0"),
        f.p(2, "18374686479671623680"),
        f.p(3, "0.5:1"),
        f.p(4, "18374966859414961920"),
        f.p(5, "1"),
        f.p(6, "0."),
        f.p(7, "25."),
    ];
    let ramp = f.component("AE.ADBE Ramp", &ps);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&ramp]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let e = &video(&r)[0].effects[0];
    assert_eq!(e.kind, ClipEffect::GRADIENT_KIND);
    let (a, b) = (e.points[ClipEffect::GRADIENT_START_KEY].value, e.points[ClipEffect::GRADIENT_END_KEY].value);
    assert!(a.x == 0.0 && b.x == 0.0 && a.y < 0.0 && a.y == -b.y); // px from the frame center, top to bottom
    assert_eq!(e.colors[ClipEffect::GRADIENT_COLOR1_KEY].value, rgb_black());
    assert_eq!(
        e.colors[ClipEffect::GRADIENT_COLOR2_KEY].value,
        EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 }
    );
    assert_eq!(pv(e, ClipEffect::GRADIENT_TYPE_KEY), Some(1.0));
    assert_eq!(pv(e, ClipEffect::GRADIENT_BLEND_KEY), Some(75.0));
    assert_eq!(r.report.status_of("AE.ADBE Ramp"), Some(Status::Mapped));
}

/// Ramp color keys stay keys (they used to be dropped).
#[test]
fn ramp_color_keys_are_kept() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let keys = "0,18374686479671623680,0,0,0,0,0,0;254016000000,18446744069414584320,0,0,0,0,0,0";
    let ps = [
        f.p(1, "0.5:0"),
        f.pk(2, "18374686479671623680", keys),
        f.p(3, "0.5:1"),
        f.p(4, "18446744069414584320"),
        f.p(5, "0"),
        f.p(6, "0."),
        f.p(7, "0."),
    ];
    let ramp = f.component("AE.ADBE Ramp", &ps);
    let it = f.item(item(0, S, 0, S, Source::Media(m)).components(&[&ramp]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    assert_eq!(video(&r)[0].effects[0].colors[ClipEffect::GRADIENT_COLOR1_KEY].track.keys.len(), 2);
    assert_eq!(r.report.status_of("AE.ADBE Ramp"), Some(Status::Mapped));
}
