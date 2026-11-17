//! Port of ClipColorPipelineTests.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use sq_core_color::ClipColorExt as _;
use sq_core_model::{
    BasicCorrection, ClipColor, ColorSectionKind, ColorSpaceID, CreativeLook, CurvePoint, HSLSecondary, HueCurves,
    LUTRef, MediaInfo, WheelValue,
};
use sq_core_time::{Id, Time};

use super::clip_pipeline::{CachingLutProvider, LutProvider, pipeline_from_clip_color};
use super::cube_lut::CubeLut;
use super::pipeline::{ColorOp, ColorPipeline};
use super::source_space::SourceColorSpace as S;
use super::stages::{CURVE_TABLE_COUNT, HUE_CURVE_COUNT};
use super::testing::{constant_lut, dist};
use super::tone_mapping::ToneMapping;
use super::transfer::bt709_inverse_oetf;
use super::vec::Vec3;

#[derive(Default)]
struct StubProvider(Mutex<HashMap<LUTRef, Arc<CubeLut>>>);

impl StubProvider {
    fn set(&self, r: LUTRef, title: &str, v: f32) {
        let mut l = constant_lut(v);
        l.title = title.to_string();
        self.0.lock().expect("lock").insert(r, Arc::new(l));
    }
}

impl LutProvider for StubProvider {
    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
        self.0.lock().expect("lock").get(r).cloned()
    }
}

fn media() -> Id {
    Id::fixed(77)
}

fn info(space: ColorSpaceID, lut: Option<&str>) -> MediaInfo {
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

fn slog() -> MediaInfo {
    info(ColorSpaceID::SLog3SGamut3Cine, Some("Look"))
}

fn slog_no_lut() -> MediaInfo {
    info(ColorSpaceID::SLog3SGamut3Cine, None)
}

fn provider() -> StubProvider {
    let p = StubProvider::default();
    p.set(LUTRef::Embedded { media: media() }, "embedded", 0.25);
    p
}

fn build(c: &ClipColor, m: Option<&MediaInfo>, p: Option<&dyn LutProvider>) -> ColorPipeline {
    pipeline_from_clip_color(c, media(), m, p)
}

fn edit(c: &mut ClipColor, f: impl FnOnce(&mut sq_core_model::ColorEffect)) {
    c.edit_effects(|fx| f(&mut fx[0]));
}

#[test]
fn source_comes_from_media_or_override() {
    let mut c = ClipColor::default();
    assert_eq!(build(&c, Some(&slog_no_lut()), None).source(), S::SLog3SGamut3Cine);
    assert_eq!(build(&c, None, None).source(), S::Rec709);
    c.source = Some(ColorSpaceID::HlgBT2020);
    assert_eq!(build(&c, Some(&slog_no_lut()), None).source(), S::HlgBT2020);
}

#[test]
fn slog3_clip_with_embedded_lut_on_and_off() {
    let p = provider();
    let mut c = ClipColor::default();
    let on = build(&c, Some(&slog()), Some(&p));
    assert_eq!(on.conversion_lut().map(|l| l.title.as_str()), Some("embedded"));
    let px = Vec3::new(0.4, 0.45, 0.5);
    let expected = Vec3::splat(bt709_inverse_oetf(0.25));
    assert!(dist(on.process(px), expected) < 1e-5);
    c.use_embedded_lut = false;
    let off = build(&c, Some(&slog()), Some(&p));
    assert!(off.conversion_lut().is_none());
    assert!(dist(off.process(px), expected) > 1e-3);
    let mut c = ClipColor::default();
    edit(&mut c, |e| e.input_lut = None);
    assert!(build(&c, Some(&slog()), Some(&p)).conversion_lut().is_none());
    let mut c = ClipColor::default();
    edit(&mut c, |e| e.set_enabled(ColorSectionKind::BasicCorrection, false));
    assert!(build(&c, Some(&slog()), Some(&p)).conversion_lut().is_none());
    assert!(build(&ClipColor::default(), Some(&slog_no_lut()), Some(&p)).conversion_lut().is_none());
    assert!(build(&ClipColor::default(), Some(&slog()), None).conversion_lut().is_none());
}

#[test]
fn saved_tints_still_render() {
    let mut c = ClipColor::default();
    let px = Vec3::splat(0.3);
    let base = build(&c, Some(&slog_no_lut()), None).process(px);
    edit(&mut c, |e| {
        e.creative.shadow_tint = WheelValue { hue: 240.0, amount: 1.0 };
        e.creative.highlight_tint = WheelValue { hue: 30.0, amount: 1.0 };
    });
    assert!(dist(build(&c, Some(&slog_no_lut()), None).process(px), base) > 1e-4);
}

#[test]
fn embedded_lut_is_skipped_when_the_source_is_overridden_away_from_slog3() {
    let mut c = ClipColor::default();
    c.source = Some(ColorSpaceID::Rec709);
    assert!(build(&c, Some(&slog()), Some(&provider())).conversion_lut().is_none());
    edit(&mut c, |e| e.input_lut = Some(LUTRef::Embedded { media: media() }));
    assert!(build(&c, Some(&slog()), Some(&provider())).conversion_lut().is_some());
}

#[test]
fn file_luts_and_creative_intensity() {
    let p = StubProvider::default();
    let (conv, look, missing) = (
        LUTRef::File { path: "/c.cube".into() },
        LUTRef::File { path: "/k.cube".into() },
        LUTRef::File { path: "/missing.cube".into() },
    );
    p.set(conv.clone(), "conv", 0.3);
    p.set(look.clone(), "look", 0.9);
    let mut c = ClipColor::default();
    let k = CreativeLook { look: Some(look.clone()), intensity: 50.0, ..CreativeLook::default() };
    edit(&mut c, |e| {
        e.input_lut = Some(conv);
        e.creative = k.clone();
    });
    let pipe = build(&c, Some(&slog()), Some(&p));
    assert_eq!(pipe.conversion_lut().map(|l| l.title.as_str()), Some("conv"));
    assert_eq!(pipe.creative_lut().map(|l| l.title.as_str()), Some("look"));
    assert_eq!(pipe.creative_intensity(), 0.5);
    assert!(dist(pipe.process(Vec3::splat(0.4)), Vec3::splat(bt709_inverse_oetf(0.6))) < 1e-5);
    edit(&mut c, |e| e.creative.intensity = 700.0);
    assert_eq!(build(&c, Some(&slog()), Some(&p)).creative_intensity(), 1.0);
    edit(&mut c, |e| e.set_enabled(ColorSectionKind::Creative, false));
    assert!(build(&c, Some(&slog()), Some(&p)).creative_lut().is_none());
    edit(&mut c, |e| {
        e.set_enabled(ColorSectionKind::Creative, true);
        e.creative.look = Some(missing);
    });
    assert!(build(&c, Some(&slog()), Some(&p)).creative_lut().is_none());
}

fn kinds(c: &ClipColor) -> Vec<&'static str> {
    build(c, None, None)
        .ops()
        .iter()
        .map(|o| match o {
            ColorOp::Conversion(_) => "conv",
            ColorOp::Basic(_) => "basic",
            ColorOp::Creative(_) => "creative",
            ColorOp::Look(..) => "look",
            ColorOp::Curves(_) => "curves",
            ColorOp::HueCurves(_) => "hue",
            ColorOp::Wheels(_) => "wheels",
            ColorOp::HslSecondary(_) => "range",
            ColorOp::ZoneBoard(_) => "board",
            ColorOp::Vignette(_) => "vignette",
            _ => "step",
        })
        .collect()
}

#[test]
fn section_order_is_processing_order() {
    let mut c = ClipColor::default();
    edit(&mut c, |e| e.basic = BasicCorrection { exposure: 1.0, ..BasicCorrection::default() });
    assert_eq!(kinds(&c), ["basic", "conv"]);
    edit(&mut c, |e| {
        e.vignette.amount = -2.0;
        e.curves.master = [(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)].map(|(x, y)| CurvePoint { x, y }).to_vec();
        e.creative.faded_film = 20.0;
    });
    assert_eq!(
        kinds(&c),
        ["basic", "conv", "creative", "curves", "vignette"],
        "neutral sections (the wheels) are skipped"
    );
    edit(&mut c, |e| e.wheels.saturation = 120.0);
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "wheels", "vignette"]);
    edit(&mut c, |e| {
        e.hue_curves.hue_vs_sat = [(0.0, 0.5), (0.3, 0.8), (1.0, 0.5)].map(|(x, y)| CurvePoint { x, y }).to_vec()
    });
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "hue", "wheels", "vignette"]);
    edit(&mut c, |e| e.set_enabled(ColorSectionKind::Curves, false));
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "wheels", "vignette"], "one switch gates both curve kinds");
    edit(&mut c, |e| {
        e.set_enabled(ColorSectionKind::Curves, true);
        e.hue_curves = HueCurves::default();
        e.hsl_secondary = Some(HSLSecondary::default());
    });
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "wheels", "vignette"]);
    edit(&mut c, |e| e.hsl_secondary = Some(HSLSecondary { saturation: 60.0, ..HSLSecondary::default() }));
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "wheels", "range", "vignette"]);
    edit(&mut c, |e| e.set_enabled(ColorSectionKind::HslSecondary, false));
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "wheels", "vignette"]);
    edit(&mut c, |e| {
        e.set_enabled(ColorSectionKind::HslSecondary, true);
        e.hsl_secondary = None;
    });
    let id = c.add_effect();
    c.edit_effects(|fx| {
        let e = fx.iter_mut().find(|e| e.id == id).expect("new effect");
        e.basic = BasicCorrection { contrast: 10.0, ..BasicCorrection::default() };
        e.vignette.amount = 1.0;
    });
    assert_eq!(kinds(&c), ["basic", "conv", "creative", "curves", "wheels", "vignette", "basic", "vignette"]);
}

#[test]
fn second_effect_input_lut_is_a_look_with_intensity() {
    let p = StubProvider::default();
    let l = LUTRef::File { path: "/l.cube".into() };
    p.set(l.clone(), "look", 0.9);
    let mut c = ClipColor::default();
    let id = c.add_effect();
    c.edit_effects(|fx| {
        let e = fx.iter_mut().find(|e| e.id == id).expect("new effect");
        e.input_lut = Some(l);
        e.input_lut_intensity = 25.0;
    });
    let pipe = build(&c, None, Some(&p));
    assert_eq!(pipe.creative_lut().map(|l| l.title.as_str()), Some("look"));
    assert_eq!(pipe.creative_intensity(), 0.25);
    assert!(pipe.conversion_lut().is_none());
    c.edit_effects(|fx| fx[1].set_enabled(ColorSectionKind::BasicCorrection, false));
    assert!(build(&c, None, Some(&p)).creative_lut().is_none());
}

#[test]
fn disabled_input_lut_still_converts_automatically() {
    let p = StubProvider::default();
    let r = LUTRef::File { path: "/c.cube".into() };
    p.set(r.clone(), "conv", 0.3);
    let mut c = ClipColor::default();
    edit(&mut c, |e| {
        e.input_lut = Some(r);
        e.set_enabled(ColorSectionKind::BasicCorrection, false);
    });
    let pipe = build(&c, Some(&slog_no_lut()), Some(&p));
    assert!(pipe.conversion_lut().is_none() && pipe.stages().len() == 1);
}

#[test]
fn correction_blocks_match_the_direct_pipeline() {
    let b =
        BasicCorrection { exposure: 1.0, saturation: 80.0, contrast: 25.0, whites: 15.0, ..BasicCorrection::default() };
    let mut c = ClipColor::default();
    edit(&mut c, |e| e.basic = b);
    let pipe = build(&c, None, None);
    let direct =
        ColorPipeline::new(S::Rec709, vec![ColorOp::Basic(b), ColorOp::Conversion(None)], ToneMapping::default());
    let px = Vec3::new(0.3, 0.5, 0.2);
    assert!(dist(pipe.process(px), direct.process(px)) < 1e-7);
    edit(&mut c, |e| e.set_enabled(ColorSectionKind::BasicCorrection, false));
    assert!(build(&c, None, None).is_identity());
}

#[test]
fn caching_provider_loads_once_per_ref_and_retries_failures() {
    let count = Arc::new(AtomicUsize::new(0));
    let cube = b"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".to_vec();
    let counter = Arc::clone(&count);
    let provider = CachingLutProvider::new(
        Some(Box::new(move |path| {
            counter.fetch_add(1, Ordering::SeqCst);
            (path == "/a.cube").then(|| cube.clone())
        })),
        Box::new(|_| None),
        None,
    );
    let (a, b) = (LUTRef::File { path: "/a.cube".into() }, LUTRef::File { path: "/b.cube".into() });
    assert!(provider.lut(&a).is_some());
    assert!(provider.lut(&a).is_some());
    assert!(provider.lut(&b).is_none());
    assert!(provider.lut(&b).is_none());
    assert_eq!(count.load(Ordering::SeqCst), 3, "a once, b twice: failures are not cached");
    assert!(provider.lut(&LUTRef::Automatic).is_none());
    provider.remove_all();
    let _ = provider.lut(&a);
    assert_eq!(count.load(Ordering::SeqCst), 4);
}

#[test]
fn table_sizes_match_the_shaders() {
    assert_eq!((CURVE_TABLE_COUNT, HUE_CURVE_COUNT), (64, 64));
}

/// Swift ColorInspectorView "Interpret As": the picture changes with the chosen source space.
#[test]
fn interpret_as_changes_the_rendered_pixel() {
    let px = Vec3::new(0.4, 0.45, 0.5);
    let mut c = ClipColor::default();
    let detected = build(&c, Some(&slog_no_lut()), None).process(px);
    c.source = Some(ColorSpaceID::Rec709);
    let as_709 = build(&c, Some(&slog_no_lut()), None);
    assert!(dist(as_709.process(px), detected) > 0.05, "S-Log3 read as Rec.709 looks different from its own curve");
    assert!(dist(as_709.process(px), build(&ClipColor::default(), None, None).process(px)) < 1e-6);
}
