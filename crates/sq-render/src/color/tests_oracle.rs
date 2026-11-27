//! Compares the Rust color pipeline with the float dumps of the frozen Swift code
//! (`oracle/sq-render/color/golden/color.tsv`, regenerate with `oracle/sq-render/color/run.sh`).
//! Tolerance: `|a - b| <= REL_TOL * max(1, |b|)` per float; NaN matches NaN. The goldens are recorded on the Mac; other
//! platforms use another libm whose `powf` differs by ulps, which the PQ exponents (about 80x) amplify, so they get a
//! looser bound.

use std::collections::HashMap;
use std::sync::Arc;

use sq_core_model::{
    BasicCorrection, BasicToneModel, ColorQualifier, ColorSpaceID, ColorWheels, CreativeLook, CurvePoint, HSLMaskMode,
    HSLSecondary, HueCurves, KeyMixMode, LayerMixMode, RGBCurves, StepPrimaries, StepWindow, StepWindowShape, Vignette,
    WheelValue, ZoneBoard, ZoneSetting,
};

use super::cube_lut::{CubeLut, LutInterpolation};
use super::gamut::{Gamut, WhitePoint};
use super::hdr_conform::{ConformKind, HdrConform, WhiteReference};
use super::look_thumbnail as lt;
use super::output::{OutputTarget, SoftGamutCompression};
use super::pipeline::{ColorOp, ColorPipeline};
use super::source_space::SourceSpaceExt;
use super::stages::PreparedBasic;
use super::tone_mapping::ToneMapping;
use super::vec::{Mat3, Vec3};
use super::white_balance::WhiteBalanceSolver;
use super::{auto_tone::AutoTone, graph_stages::KeyTerm, testing::Lcg};

/// Relative tolerance: 1e-6 where the goldens were recorded (macOS), 2e-4 with another libm.
const REL_TOL: f32 = if cfg!(target_os = "macos") { 1e-6 } else { 2e-4 };

const GOLDEN: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../oracle/sq-render/color/golden/color.tsv");

fn f(tok: &str) -> f32 {
    f32::from_bits(u32::from_str_radix(tok, 16).expect("hex float"))
}

fn v3(toks: &[&str]) -> Vec3 {
    Vec3::new(f(toks[0]), f(toks[1]), f(toks[2]))
}

fn words(s: &str) -> Vec<&str> {
    s.split(' ').filter(|w| !w.is_empty()).collect()
}

fn mat(toks: &[&str]) -> Mat3 {
    Mat3::from_cols(v3(&toks[0..3]), v3(&toks[3..6]), v3(&toks[6..9]))
}

#[derive(Default)]
struct Check {
    max_err: f32,
    failures: Vec<String>,
    count: usize,
}

impl Check {
    fn float(&mut self, what: &str, got: f32, want: f32) {
        self.count += 1;
        if got.is_nan() && want.is_nan() || got == want {
            return;
        }
        let err = (got - want).abs();
        let tol = REL_TOL * want.abs().max(1.0);
        if err.is_nan() || err > tol {
            if self.failures.len() < 12 {
                self.failures.push(format!("{what}: got {got:e} want {want:e}"));
            }
            self.failures.push(String::new());
        } else {
            self.max_err = self.max_err.max(err / want.abs().max(1.0));
        }
    }

    fn vec(&mut self, what: &str, got: Vec3, want: Vec3) {
        for i in 0..3 {
            self.float(what, got[i], want[i]);
        }
    }

    fn mat(&mut self, what: &str, got: &Mat3, want: &Mat3) {
        for c in 0..3 {
            self.vec(what, got.cols[c], want.cols[c]);
        }
    }
}

// MARK: configs (mirror oracle/sq-render/color/swift-dump/main.swift)

fn wheel(hue: f32, amount: f32) -> WheelValue {
    WheelValue { hue, amount }
}

fn pts(p: &[(f32, f32)]) -> Vec<CurvePoint> {
    p.iter().map(|&(x, y)| CurvePoint { x, y }).collect()
}

fn basic_a(legacy: bool) -> BasicCorrection {
    BasicCorrection {
        model: if legacy { BasicToneModel::Legacy } else { BasicToneModel::Lumetri },
        temperature: 20.0,
        tint: -10.0,
        exposure: 0.5,
        contrast: 20.0,
        highlights: -30.0,
        shadows: 25.0,
        whites: 10.0,
        blacks: -15.0,
        saturation: 120.0,
        vibrance: 30.0,
    }
}

fn creative_a() -> CreativeLook {
    CreativeLook {
        faded_film: 30.0,
        saturation: 90.0,
        vibrance: -20.0,
        shadow_tint: wheel(200.0, 0.5),
        highlight_tint: wheel(30.0, 0.6),
        tint_balance: 20.0,
        ..CreativeLook::default()
    }
}

fn curves_a() -> RGBCurves {
    RGBCurves {
        master: pts(&[(0.0, 0.0), (0.3, 0.25), (0.7, 0.8), (1.0, 1.0)]),
        red: pts(&[(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)]),
        ..RGBCurves::default()
    }
}

fn hue_curves_a() -> HueCurves {
    HueCurves {
        hue_vs_sat: pts(&[(0.0, 0.5), (0.08, 0.8), (0.5, 0.4), (1.0, 0.5)]),
        hue_vs_hue: pts(&[(0.0, 0.5), (0.6, 0.7), (1.0, 0.5)]),
        hue_vs_luma: pts(&[(0.0, 0.5), (0.25, 0.35), (1.0, 0.5)]),
        luma_vs_sat: pts(&[(0.0, 0.5), (0.5, 0.7), (1.0, 0.5)]),
        sat_vs_sat: pts(&[(0.0, 0.5), (1.0, 0.8)]),
    }
}

fn wheels_a() -> ColorWheels {
    ColorWheels {
        shadows: wheel(240.0, 0.4),
        midtones: wheel(120.0, 0.3),
        highlights: wheel(30.0, 0.5),
        shadows_luma: 10.0,
        midtones_luma: -20.0,
        highlights_luma: 15.0,
        saturation: 110.0,
    }
}

fn hsl_range() -> HSLSecondary {
    HSLSecondary {
        hue_center: 30.0,
        hue_width: 60.0,
        sat_min: 20.0,
        sat_max: 100.0,
        lum_min: 10.0,
        lum_max: 90.0,
        softness: 30.0,
        hue_shift: 15.0,
        saturation: 130.0,
        exposure: 0.3,
        temperature: 20.0,
        tint: -10.0,
        ..HSLSecondary::default()
    }
}

fn hsl_volume() -> HSLSecondary {
    HSLSecondary {
        mask_mode: HSLMaskMode::Volume,
        hue_center: 200.0,
        volume_sat: 60.0,
        volume_lum: 50.0,
        volume_radius: 50.0,
        softness: 40.0,
        saturation: 70.0,
        hue_shift: -20.0,
        exposure: -0.4,
        ..HSLSecondary::default()
    }
}

fn zone_a() -> ZoneBoard {
    ZoneBoard {
        shadows: ZoneSetting { puck_x: 0.3, puck_y: 0.6, saturation: 0.6, exposure: 0.4 },
        highlights: ZoneSetting { puck_x: 0.7, puck_y: 0.4, saturation: 0.45, exposure: 0.6 },
        global: ZoneSetting { puck_x: 0.5, puck_y: 0.55, saturation: 0.5, exposure: 0.52 },
        ..ZoneBoard::default()
    }
}

fn vignette_a(roundness: f32) -> Vignette {
    Vignette { amount: -1.5, midpoint: 40.0, roundness, feather: 60.0 }
}

fn primaries_a() -> StepPrimaries {
    let mut p = StepPrimaries::default();
    for (t, v) in [
        (&mut p.lift, [0.02, -0.01, 0.03]),
        (&mut p.gamma, [1.1, 0.9, 1.0]),
        (&mut p.gain, [1.05, 1.0, 0.95]),
        (&mut p.offset, [0.01, 0.0, -0.01]),
    ] {
        (t.r, t.g, t.b) = (v[0], v[1], v[2]);
    }
    p.contrast = 1.1;
    p.pivot = 0.435;
    p.saturation = 1.2;
    p
}

fn qualifier_a() -> ColorQualifier {
    ColorQualifier {
        hue_center: 25.0,
        hue_width: 50.0,
        sat_min: 10.0,
        sat_max: 100.0,
        softness: 20.0,
        ..ColorQualifier::default()
    }
}

fn window_a(shape: StepWindowShape) -> StepWindow {
    StepWindow {
        shape,
        center_x: 0.45,
        center_y: 0.55,
        width: 0.5,
        height: 0.4,
        rotation: 20.0,
        softness: 0.3,
        ..StepWindow::default()
    }
}

/// `.cube` text from integer formulas (exact binary fractions, so both languages print the same digits).
fn cube_text(n: usize, flags: &str) -> String {
    let mut s = format!("{flags}LUT_3D_SIZE {n}\n");
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let v = |k: usize| ((r * (k + 3) + g * (k + 1) * 2 + b * (5 - k) + k) % 17) as f32 / 16.0;
                s += &format!("{} {} {}\n", v(0), v(1), v(2));
            }
        }
    }
    s
}

fn lut_a() -> Arc<CubeLut> {
    Arc::new(CubeLut::parse(&cube_text(5, "")).expect("lut a"))
}

fn lut_b() -> Arc<CubeLut> {
    Arc::new(
        CubeLut::parse("LUT_1D_SIZE 4\n0 0.0625 0.5\n0.25 0.375 0.5625\n0.75 0.5 0.4375\n1 0.9375 1\n").expect("lut b"),
    )
}

fn space(name: &str) -> ColorSpaceID {
    serde_json::from_str(&format!("\"{name}\"")).expect("space name")
}

fn key(q: Option<ColorQualifier>, w: Option<StepWindow>, outside: bool, mode: Option<KeyMixMode>) -> ColorOp {
    ColorOp::KeyTerm(KeyTerm { qualifier: q, window: w, outside, mode })
}

fn pipeline(name: &str) -> ColorPipeline {
    use ColorOp as O;
    use ColorSpaceID as S;
    let tm = ToneMapping::default();
    let new = |s: S, ops: Vec<ColorOp>| ColorPipeline::new(s, ops, tm);
    if let Some(s) = name.strip_prefix("src_") {
        return new(space(s), vec![O::Conversion(None)]);
    }
    if let Some(s) = name.strip_prefix("skip_") {
        let mut p = new(space(s), vec![O::Conversion(None)]);
        p.set_skips_tone_map(true);
        return p;
    }
    if let Some(s) = name.strip_prefix("trim_") {
        return ColorPipeline::new(space(s), vec![O::Conversion(None)], ToneMapping::new(0.6, 1.0, true));
    }
    let ew = |layer, q, w, mix| O::BranchEnd { layer, qualifier: q, window: w, mix };
    match name {
        "A" => new(
            S::SLog3SGamut3Cine,
            vec![
                O::Basic(basic_a(false)),
                O::Conversion(None),
                O::Creative(creative_a()),
                O::Curves(curves_a()),
                O::HueCurves(hue_curves_a()),
                O::Wheels(wheels_a()),
                O::HslSecondary(hsl_range()),
                O::ZoneBoard(zone_a()),
                O::Vignette(vignette_a(-30.0)),
            ],
        ),
        "A2" => new(
            S::VLogVGamut,
            vec![
                O::Conversion(None),
                O::Basic(basic_a(false)),
                O::Creative(creative_a()),
                O::Curves(curves_a()),
                O::HueCurves(hue_curves_a()),
                O::Wheels(wheels_a()),
                O::HslSecondary(hsl_volume()),
                O::ZoneBoard(zone_a()),
                O::Vignette(vignette_a(40.0)),
            ],
        ),
        "B" => new(
            S::LogC3WideGamut3,
            vec![
                O::Basic(basic_a(true)),
                O::Wheels(wheels_a()),
                O::HueCurves(hue_curves_a()),
                O::HslSecondary(hsl_range()),
                O::ZoneBoard(zone_a()),
                O::Creative(creative_a()),
                O::Curves(curves_a()),
                O::Vignette(vignette_a(0.0)),
                O::Conversion(Some(lut_a())),
                O::Look(lut_b(), 0.6),
                O::Basic(basic_a(true)),
            ],
        ),
        "B2" => new(S::HlgBT2020, vec![O::Conversion(None), O::Look(lut_a(), 1.0), O::Basic(basic_a(true))]),
        "C" => new(
            S::Rec709,
            vec![
                O::Conversion(None),
                O::HslSecondary(hsl_volume()),
                O::Primaries(primaries_a()),
                O::StepBegin,
                O::Wheels(wheels_a()),
                O::StepEnd {
                    qualifier: Some(qualifier_a()),
                    window: Some(window_a(StepWindowShape::Rectangle)),
                    mix: 0.8,
                },
                O::Vignette(vignette_a(-30.0)),
            ],
        ),
        "C2" => new(
            S::AppleLog,
            vec![
                O::Conversion(None),
                O::StepBegin,
                O::Primaries(primaries_a()),
                O::StepEnd { qualifier: None, window: Some(window_a(StepWindowShape::Ellipse)), mix: 1.0 },
                O::StepBegin,
                O::Curves(curves_a()),
                O::StepEnd {
                    qualifier: Some(qualifier_a()),
                    window: Some(window_a(StepWindowShape::Linear)),
                    mix: 1.0,
                },
            ],
        ),
        "D" => new(
            S::Rec709,
            vec![
                O::Conversion(None),
                O::GroupBegin,
                O::Primaries(primaries_a()),
                ew(false, Some(qualifier_a()), None, 1.0),
                key(Some(qualifier_a()), Some(window_a(StepWindowShape::Rectangle)), false, None),
                O::Wheels(wheels_a()),
                ew(false, None, Some(window_a(StepWindowShape::Ellipse)), 0.7),
                O::GroupMerge { count: 2 },
                O::Curves(curves_a()),
                O::LayerMix(LayerMixMode::Screen),
                ew(true, Some(qualifier_a()), None, 0.9),
                key(None, Some(window_a(StepWindowShape::Ellipse)), true, Some(KeyMixMode::Multiply)),
                key(Some(qualifier_a()), None, false, Some(KeyMixMode::Add)),
                O::KeyApply,
                O::GroupEnd,
            ],
        ),
        "D2" => new(
            S::Rec709,
            vec![
                O::Conversion(None),
                O::GroupBegin,
                O::GroupMerge { count: 0 },
                O::Primaries(primaries_a()),
                O::LayerMix(LayerMixMode::Multiply),
                ew(true, None, None, 0.5),
                O::LayerMix(LayerMixMode::Darken),
                ew(true, None, None, 1.0),
                O::GroupEnd,
            ],
        ),
        other => panic!("unknown pipeline {other}"),
    }
}

fn gamut_by_name(n: &str) -> &'static Gamut {
    match n {
        "rec709" => Gamut::rec709(),
        "bt2020" => Gamut::bt2020(),
        "sGamut3Cine" => Gamut::s_gamut3_cine(),
        "vGamut" => Gamut::v_gamut(),
        "dGamut" => Gamut::d_gamut(),
        "cinemaGamut" => Gamut::cinema_gamut(),
        "sqWide" => Gamut::sq_wide(),
        "displayP3" => Gamut::display_p3(),
        "arriWideGamut3" => Gamut::arri_wide_gamut3(),
        "arriWideGamut4" => Gamut::arri_wide_gamut4(),
        "redWideGamutRGB" => Gamut::red_wide_gamut_rgb(),
        "blackmagicWideGamut" => Gamut::blackmagic_wide_gamut(),
        "fGamutC" => Gamut::f_gamut_c(),
        "acesAP1" => Gamut::aces_ap1(),
        other => panic!("unknown gamut {other}"),
    }
}

fn lut_named(n: &str) -> CubeLut {
    let a = |flags: &str| CubeLut::parse(&cube_text(5, flags)).expect("lut");
    match n {
        "tetra" => a(""),
        "tri" => a("").with_interpolation(LutInterpolation::Trilinear),
        "oned" => (*lut_b()).clone(),
        "video" => a("LUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n"),
        "domain" => a("DOMAIN_MIN -0.5 -0.5 -0.5\nDOMAIN_MAX 2 1.5 1\n"),
        other => panic!("unknown lut {other}"),
    }
}

fn tone_mapping_named(n: &str) -> ToneMapping {
    match n {
        "def" => ToneMapping::default(),
        "trim" => ToneMapping::new(0.6, 1.0, true),
        _ => ToneMapping::new(0.95, -2.0, false),
    }
}

fn conform_kind(n: &str) -> ConformKind {
    match n {
        "hlg2sdr" => ConformKind::HlgToSdr,
        "pq2sdr" => ConformKind::PqToSdr,
        "sdr2hlg75" => ConformKind::SdrToHlg(WhiteReference::Percent75),
        "sdr2hlg100" => ConformKind::SdrToHlg(WhiteReference::Percent100),
        "sdr2pq" => ConformKind::SdrToPq { peak_nits: 1000.0 },
        "hlg2pq" => ConformKind::HlgToPq,
        _ => ConformKind::PqToHlg,
    }
}

fn auto_images() -> Vec<Vec<Vec3>> {
    let mut r = Lcg(4242);
    let dark = (0..1500).map(|_| r.rgb() * 0.35).collect();
    let cast = (0..1500)
        .map(|_| {
            let v = r.next_f32() * 0.6;
            Vec3::new(v * 1.15, v, v * 0.85)
        })
        .collect();
    let mixed = (0..1500).map(|i| if i % 3 == 0 { Vec3::splat(r.next_f32() * 0.8) } else { r.rgb() }).collect();
    vec![dark, cast, mixed]
}

fn basic_fields(b: &BasicCorrection) -> [f32; 10] {
    [
        b.temperature,
        b.tint,
        b.exposure,
        b.contrast,
        b.highlights,
        b.shadows,
        b.whites,
        b.blacks,
        b.saturation,
        b.vibrance,
    ]
}

#[test]
fn matches_the_swift_float_dumps() {
    let text = std::fs::read_to_string(GOLDEN).expect("golden file (run oracle/sq-render/color/run.sh)");
    let mut chk = Check::default();
    let mut pipes: HashMap<String, ColorPipeline> = HashMap::new();
    let (mut wb_index, mut counts) = (0usize, HashMap::<String, usize>::new());
    for ln in text.lines() {
        let c: Vec<&str> = ln.split('\t').collect();
        let op = c[0];
        *counts.entry(op.to_string()).or_default() += 1;
        let label = format!("{op} {}", c.get(1).copied().unwrap_or(""));
        match op {
            "dec" | "enc" => {
                let s = space(c[1]);
                let v = v3(&words(c[2]));
                let got = if op == "dec" { s.decode(v) } else { s.encode(v) };
                chk.vec(&format!("{label} {:?}", c[2]), got, v3(&words(c[4])));
            }
            "gamut" => {
                let g = gamut_by_name(c[1]);
                chk.mat(&label, &g.rgb_to_xyz, &mat(&words(c[2])));
                chk.mat(&label, &g.xyz_to_rgb, &mat(&words(c[3])));
                chk.vec(&label, g.luma_row, v3(&words(c[4])));
                chk.mat(&label, &g.matrix(Gamut::rec709()), &mat(&words(c[5])));
                chk.mat(&label, &g.matrix(Gamut::bt2020()), &mat(&words(c[6])));
            }
            "xy" => {
                let w = words(c[1]);
                let xy = WhitePoint::xy(w[0].parse().expect("cct"), w[1].parse().expect("duv"));
                let want = [c[3], c[4]].map(|t| f64::from_bits(u64::from_str_radix(t, 16).expect("hex")));
                for i in 0..2 {
                    chk.count += 1;
                    if (xy[i] - want[i]).abs() > 1e-12 {
                        chk.failures.push(format!("xy {}: {} vs {}", c[1], xy[i], want[i]));
                    }
                }
            }
            "wbmat" => {
                let g = [Gamut::rec709(), Gamut::bt2020(), Gamut::s_gamut3_cine()][wb_index / 5];
                wb_index += 1;
                let w = words(c[1]);
                let b = BasicCorrection {
                    temperature: w[0].parse().expect("t"),
                    tint: w[1].parse().expect("n"),
                    ..BasicCorrection::default()
                };
                chk.mat(&label, &PreparedBasic::new(&b, g).wb, &mat(&words(c[4])));
            }
            "tmap" => {
                let tm = tone_mapping_named(c[1]);
                let peak = Some(f(c[2])).filter(|p| *p >= 0.0);
                let v = v3(&words(c[3]));
                chk.vec(&format!("{label} peak {peak:?}"), tm.apply_peak(tm.trim(v), peak), v3(&words(c[5])));
            }
            "soft" => {
                let v = v3(&words(c[1]));
                chk.vec(&label, SoftGamutCompression::compress(v), v3(&words(c[3])));
            }
            "outt" => {
                let t: OutputTarget = serde_json::from_str(&format!("\"{}\"", c[1])).expect("target");
                chk.vec(&label, t.encode(v3(&words(c[2])), Gamut::bt2020()), v3(&words(c[4])));
            }
            "lut" => chk.vec(&label, lut_named(c[1]).lookup(v3(&words(c[2]))), v3(&words(c[4]))),
            "pipe" => {
                let p = pipes.entry(c[1].to_string()).or_insert_with(|| pipeline(c[1]));
                let uv = words(c[3]);
                let got = p.process_at(v3(&words(c[2])), [f(uv[0]), f(uv[1])], f(c[4]));
                chk.vec(&format!("{label} in {}", c[2]), got, v3(&words(c[6])));
            }
            "hdr" => {
                let got = HdrConform::convert(v3(&words(c[2])), conform_kind(c[1]), &ToneMapping::new(0.8, 0.0, true));
                chk.vec(&label, got, v3(&words(c[4])));
            }
            "wbsolve" => {
                let pk = v3(&words(c[1]));
                let tn = words(c[2]);
                let got = WhiteBalanceSolver::solve(pk, f(tn[0]), f(tn[1]));
                if c[4] == "nil" {
                    chk.count += 1;
                    assert!(got.is_none(), "{label}");
                } else {
                    let r = got.expect("solves");
                    chk.float(&label, r.temperature, f(c[4]));
                    chk.float(&label, r.tint, f(c[5]));
                }
            }
            "autotone" => {
                let i: usize = c[1].parse().expect("index");
                let cur = if i == 2 {
                    BasicCorrection { exposure: 0.4, contrast: 10.0, ..BasicCorrection::default() }
                } else {
                    BasicCorrection::default()
                };
                let got = AutoTone::solve(&auto_images()[i], &cur);
                if c[3] == "nil" {
                    chk.count += 1;
                    assert!(got.is_none(), "{label}");
                } else {
                    let g = basic_fields(&got.expect("auto tone result"));
                    for (k, t) in words(c[3]).iter().enumerate() {
                        chk.float(&format!("{label} field {k}"), g[k], f(t));
                    }
                }
            }
            "thumb" => {
                let lut = match c[1] {
                    "lutA" => Some((lut_a(), 0.8)),
                    "lutB" => Some((lut_b(), 1.0)),
                    _ => None,
                };
                let got = lt::render(lut.as_ref().map(|l| &l.0), lut.as_ref().map_or(1.0, |l| l.1), 64, 36);
                let want: Vec<u8> = c[3].split(',').map(|b| u8::from_str_radix(b, 16).expect("byte")).collect();
                let off = got.iter().zip(&want).filter(|(a, b)| a != b).count();
                let big = got.iter().zip(&want).filter(|(a, b)| (i32::from(**a) - i32::from(**b)).abs() > 1).count();
                chk.count += 1;
                assert!(
                    got.len() == want.len() && big == 0 && off * 200 <= want.len(),
                    "thumb {}: {off} bytes differ, {big} by more than 1",
                    c[1]
                );
            }
            other => panic!("unknown golden op {other}"),
        }
    }
    sq_os::outln!("oracle: {} floats checked over {counts:?}, max relative error {:e}", chk.count, chk.max_err);
    assert!(
        chk.failures.is_empty(),
        "{} mismatches, first ones:\n{}",
        chk.failures.iter().filter(|s| s.is_empty()).count(),
        chk.failures.join("\n")
    );
}
