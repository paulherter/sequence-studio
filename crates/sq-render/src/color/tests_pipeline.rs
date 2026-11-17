//! Ports of ColorPipelineTests, ToneMappingPeakTests, HDRTrimTests, WhiteBalanceSolverTests, LookThumbnailTests, the
//! output-gamut part of LUTInterpolationAndOutputTests and the gamut part of TransferAndGamutTests.

use std::sync::Arc;

use sq_core_model::BasicCorrection;

use super::gamut::{Gamut, WhitePoint};
use super::look_thumbnail as lt;
use super::output::{OutputTarget, SoftGamutCompression, rec709_encode};
use super::pipeline::{ColorOp, ColorPipeline};
use super::source_space::{SourceColorSpace as S, SourceSpaceExt};
use super::stages::PreparedBasic;
use super::testing::{Lcg, constant_lut, dist, identity_lut, lut_from};
use super::tone_mapping::ToneMapping;
use super::transfer as tf;
use super::vec::Vec3;
use super::white_balance::WhiteBalanceSolver;

fn pipe(source: S) -> ColorPipeline {
    ColorPipeline::new(source, vec![ColorOp::Conversion(None)], ToneMapping::default())
}

#[test]
fn rec709_invariant_round_trip() {
    let p = pipe(S::Rec709);
    let mut rng = Lcg(5);
    let mut samples = vec![Vec3::ZERO, Vec3::ONE, Vec3::new(0.01, 0.02, 0.03), Vec3::new(0.081, 0.5, 0.99)];
    samples.extend((0..1000).map(|_| rng.rgb()));
    for s in samples {
        assert!(dist(rec709_encode(p.process(s)), s) <= 1e-5, "{s:?}");
    }
}

#[test]
fn slog3_grey_gives_018_and_hlg_is_bounded() {
    let v = (420.0f32 - 64.0) / 876.0;
    assert!(dist(pipe(S::SLog3SGamut3Cine).process(Vec3::splat(v)), Vec3::splat(0.18)) < 1e-4);
    let p = pipe(S::HlgBT2020);
    assert!((S::HlgBT2020.decode(Vec3::splat(0.75)).x - 1.0).abs() < 1e-4);
    let want = p.tone_mapping().map_max_peak(1.0, S::HlgBT2020.tone_map_peak());
    assert!(dist(p.process(Vec3::splat(0.75)), Vec3::splat(want)) < 1e-4);
    assert!(dist(p.process(Vec3::splat(0.38)), Vec3::splat(26.0 / 203.0)) < 2e-3);
    for s in [
        Vec3::ONE,
        Vec3::new(1.0, 0.0, 0.0),
        Vec3::new(0.0, 1.0, 0.0),
        Vec3::new(0.0, 0.0, 1.0),
        Vec3::new(0.9, 1.0, 0.2),
    ] {
        let w = p.process(s);
        assert!(w.max_elem() <= 1.0 + 1e-6);
        assert!(rec709_encode(w).max_elem() <= 1.0);
    }
}

#[test]
fn hlg_grey_ramp_on_rec709_is_monotonic_and_rolled_off() {
    let p = pipe(S::HlgBT2020);
    let mut last = -1.0f32;
    let mut outs = Vec::new();
    for i in 0..=200 {
        let o = rec709_encode(p.process(Vec3::splat(i as f32 / 200.0))).x;
        assert!(o >= last - 1e-6 && o <= 1.0, "i={i}");
        last = o;
        outs.push(o);
    }
    assert!(outs[0] < 1e-4);
    assert!(outs[200] - outs[150] > 0.02);
    assert!(outs[200] - outs[190] > 1e-3);
}

#[test]
fn conversion_luts() {
    let p =
        ColorPipeline::with_luts(S::SLog3SGamut3Cine, Some(Arc::new(identity_lut(17))), None, ToneMapping::default());
    for v in [0.05f32, 0.3, 0.488, 0.7, 0.9] {
        let s = Vec3::new(v, v * 0.8, v * 0.6);
        assert!(dist(rec709_encode(p.process(s)), s) < 1e-5, "v={v}");
    }
    let inv = lut_from(17, |c| Vec3::ONE - c);
    let p = ColorPipeline::with_luts(S::SLog3SGamut3Cine, Some(Arc::new(inv)), None, ToneMapping::default());
    assert!((rec709_encode(p.process(Vec3::splat(0.5))).x - 0.5).abs() < 1e-5);
}

#[test]
fn exposure_is_a_linear_gain_before_and_after_the_conversion() {
    // 0.2 encoded = 0.059 linear: x2 stays below the Lumetri model's shoulder knee (0.18), where Exposure is a gain.
    let b = BasicCorrection { exposure: 1.0, ..BasicCorrection::default() };
    let lin = tf::bt709_inverse_oetf(0.2);
    for ops in [vec![ColorOp::Basic(b), ColorOp::Conversion(None)], vec![ColorOp::Conversion(None), ColorOp::Basic(b)]]
    {
        let o = ColorPipeline::new(S::Rec709, ops, ToneMapping::default()).process(Vec3::splat(0.2));
        assert!((o.x - 2.0 * lin).abs() < 1e-5);
    }
}

#[test]
fn conversion_is_inserted_when_missing_and_only_the_first_counts() {
    let b = BasicCorrection { exposure: 1.0, ..BasicCorrection::default() };
    assert_eq!(ColorPipeline::new(S::Rec709, vec![ColorOp::Basic(b)], ToneMapping::default()).stages().len(), 2);
    let twice = ColorPipeline::new(
        S::Rec709,
        vec![ColorOp::Conversion(None), ColorOp::Conversion(Some(Arc::new(constant_lut(0.5))))],
        ToneMapping::default(),
    );
    assert_eq!(twice.stages().len(), 1);
}

#[test]
fn look_intensity_and_position() {
    let red = Arc::new(lut_from(2, |_| Vec3::new(1.0, 0.0, 0.0)));
    let s = Vec3::new(0.2, 0.4, 0.6);
    let out = |k: f32| {
        rec709_encode(
            ColorPipeline::with_luts(S::Rec709, None, Some((Arc::clone(&red), k)), ToneMapping::default()).process(s),
        )
    };
    assert!(dist(out(0.0), s) < 1e-5);
    assert!(dist(out(1.0), Vec3::new(1.0, 0.0, 0.0)) < 1e-5);
    assert!(dist(out(0.5), (s + Vec3::new(1.0, 0.0, 0.0)) / 2.0) < 1e-5);
    let lut = Arc::new(lut_from(9, |c| Vec3::new(c.y, c.z * 0.8 + 0.1, 1.0 - c.x * 0.7)));
    let a = ColorPipeline::new(
        S::Rec709,
        vec![ColorOp::Look(Arc::clone(&lut), 0.7), ColorOp::Conversion(None)],
        ToneMapping::default(),
    );
    let b =
        ColorPipeline::new(S::Rec709, vec![ColorOp::Conversion(None), ColorOp::Look(lut, 0.7)], ToneMapping::default());
    for s in [Vec3::new(0.2, 0.4, 0.6), Vec3::new(0.9, 0.1, 0.5)] {
        assert!(dist(a.process(s), b.process(s)) < 1e-5);
    }
}

#[test]
fn output_clamps_and_tags() {
    assert_eq!(rec709_encode(Vec3::new(2.0, -1.0, 0.5)).x, 1.0);
    assert_eq!(rec709_encode(Vec3::new(2.0, -1.0, 0.5)).y, 0.0);
}

#[test]
fn tone_map_peak_curve() {
    let tm = ToneMapping::default();
    let peak = 1000.0f32 / 203.0;
    assert!((S::HlgBT2020.tone_map_peak().unwrap_or(0.0) - 1000.0 / 203.0).abs() < 0.01);
    assert_eq!(S::PqBT2020.tone_map_peak(), Some(1000.0 / tf::PQ_REFERENCE_WHITE));
    for s in [S::Rec709, S::SLog3SGamut3Cine, S::VLogVGamut, S::AppleLog, S::DLogDGamut] {
        assert_eq!(s.tone_map_peak(), None);
    }
    for m in [0.0, 0.1, 0.5, tm.knee()] {
        assert_eq!(tm.map_max_peak(m, Some(peak)), m);
    }
    assert!((tm.map_max_peak(peak, Some(peak)) - 1.0).abs() < 1e-6);
    assert_eq!(tm.map_max_peak(peak * 2.0, Some(peak)), 1.0);
    assert_eq!(tm.map_max_peak(3.0, None), tm.map_max(3.0));
    let h = 1e-3;
    let slope = (tm.map_max_peak(tm.knee() + h, Some(peak)) - tm.map_max_peak(tm.knee(), Some(peak))) / h;
    assert!((slope - 1.0).abs() < 0.01);
    let mut last = -1.0;
    for i in 0..=1000 {
        let v = tm.map_max_peak(i as f32 / 1000.0 * peak, Some(peak));
        assert!(v > last);
        last = v;
    }
    let o = tm.apply_peak(Vec3::new(4.0, 2.0, 1.0), Some(peak));
    assert!((o.x - tm.map_max_peak(4.0, Some(peak))).abs() < 1e-6);
    assert!((o.y / o.x - 0.5).abs() < 1e-6 && (o.z / o.x - 0.25).abs() < 1e-6);
}

#[test]
fn hdr_trim() {
    let c = Vec3::new(1.4, -0.05, 0.3);
    assert_eq!(ToneMapping::default().trim(c), c);
    assert_eq!(ToneMapping::default().exposure_gain(), 1.0);
    assert_eq!(ToneMapping::new(0.8, 1.0, false).trim(Vec3::new(0.2, 0.1, 0.05)), Vec3::new(0.4, 0.2, 0.1));
    let dark = ToneMapping::new(0.8, -1.0, false);
    assert!(dark.apply(dark.trim(Vec3::splat(0.6))).x < ToneMapping::default().apply(Vec3::splat(0.6)).x);
    let g = ToneMapping::new(0.8, 0.0, true);
    let c = g.trim(Vec3::new(0.8, -0.2, 0.3));
    assert!(c.x == 0.8 && c.y > -0.2);
    assert_eq!(g.trim(Vec3::new(0.5, 0.4, 0.3)), Vec3::new(0.5, 0.4, 0.3));
    let base = pipe(S::HlgBT2020);
    let mut bright = base.clone();
    bright.set_tone_mapping(ToneMapping::new(0.8, 1.0, false));
    let px = Vec3::splat(0.4);
    assert!(bright.process(px).x > base.process(px).x);
    let mut sdr = pipe(S::Rec709);
    let before = sdr.process(px);
    sdr.set_tone_mapping(ToneMapping::new(0.8, 2.0, false));
    assert_eq!(sdr.process(px), before);
}

fn wb(t: f32, n: f32) -> super::vec::Mat3 {
    PreparedBasic::new(&BasicCorrection { temperature: t, tint: n, ..BasicCorrection::default() }, Gamut::rec709()).wb
}

#[test]
fn white_balance_solver() {
    let r = WhiteBalanceSolver::solve(Vec3::splat(0.4), 12.0, -7.0).expect("solves");
    assert!((r.temperature - 12.0).abs() < 0.5 && (r.tint + 7.0).abs() < 0.5);
    let spread = |v: Vec3| (v.max_elem() - v.min_elem()) / v.y.max(1e-4);
    for (ct, cn) in [(30.0f32, 10.0f32), (-40.0, 0.0), (0.0, -25.0), (60.0, 30.0), (-80.0, -50.0)] {
        let picked = wb(ct, cn).mul_vec(Vec3::splat(0.35));
        let r = WhiteBalanceSolver::solve(picked, 0.0, 0.0).expect("solves");
        assert!(spread(wb(r.temperature, r.tint).mul_vec(picked)) < 0.01, "cast ({ct}, {cn}) -> {r:?}");
        if ct.abs() <= 60.0 && cn.abs() <= 30.0 {
            assert!((r.temperature + ct).abs() < 10.0 && (r.tint + cn).abs() < 10.0);
        }
    }
    let r = WhiteBalanceSolver::solve(Vec3::new(0.9, 0.2, 0.01), 90.0, 90.0).expect("solves");
    assert!(r.temperature.abs() <= 100.0 && r.tint.abs() <= 100.0);
    assert!(WhiteBalanceSolver::solve(Vec3::ZERO, 0.0, 0.0).is_none());
    assert!(WhiteBalanceSolver::solve(Vec3::new(f32::NAN, 1.0, 1.0), 0.0, 0.0).is_none());
}

#[test]
fn look_thumbnails() {
    let (w, h) = (lt::WIDTH, lt::HEIGHT);
    let px = lt::test_picture(w, h);
    assert!(w == 256 && h == 144 && px.len() == w * h);
    let top = px[2 * w + w / 2];
    let horizon = px[(h as f32 * 0.4) as usize * w + w / 2];
    assert!(top.z > top.x && top.z > top.y);
    assert!(horizon.x + horizon.y + horizon.z > top.x + top.y + top.z);
    let row = (h - 2) * w;
    let steps: std::collections::BTreeSet<i32> = (0..w).map(|x| (px[row + x].x * 10.0).round() as i32).collect();
    assert_eq!(steps, (0..=10).collect());
    let mid = (h as f32 * 0.6) as usize * w;
    let cell = w / 7;
    let skin = px[mid + cell / 2];
    assert!(skin.x > skin.y && skin.y > skin.z);
    for i in 1..=6 {
        let c = px[mid + i * cell + cell / 2];
        assert!(c.max_elem() - c.min_elem() > 0.6, "chip {i}");
    }
    let (w, h) = (64, 36);
    let plain = lt::render(None, 1.0, w, h);
    let looked = lt::render(Some(&Arc::new(identity_lut(17))), 1.0, w, h);
    let worst = plain.iter().zip(&looked).map(|(a, b)| (i32::from(*a) - i32::from(*b)).abs()).max().unwrap_or(0);
    assert!(worst <= 1, "max difference {worst}/255");
    let swapped = Arc::new(lut_from(9, |c| Vec3::new(c.z, c.y, c.x)));
    let full = lt::render(Some(&swapped), 1.0, w, h);
    let none = lt::render(Some(&swapped), 0.0, w, h);
    assert!(plain.iter().zip(&full).map(|(a, b)| (i32::from(*a) - i32::from(*b)).abs()).max().unwrap_or(0) > 100);
    assert!(plain.iter().zip(&none).map(|(a, b)| (i32::from(*a) - i32::from(*b)).abs()).max().unwrap_or(0) <= 1);
    let i = (2 * w + w / 2) * 4;
    assert!(full[i] > full[i + 2]);
}

#[test]
fn output_gamut_and_soft_compression() {
    for v in [Vec3::new(0.2, 0.5, 0.8), Vec3::splat(0.5), Vec3::new(1.0, 0.3, 0.3), Vec3::ZERO] {
        assert!(dist(SoftGamutCompression::compress(v), v) < 1e-6);
    }
    for i in 0..=40 {
        let out = SoftGamutCompression::compress(Vec3::new(0.8, 0.4, -(i as f32) * 0.01));
        assert!(out.min_elem() >= 0.0 && out.x == 0.8);
    }
    let a = SoftGamutCompression::compress(Vec3::new(0.8, 0.4, 0.0));
    let b = SoftGamutCompression::compress(Vec3::new(0.8, 0.4, -0.001));
    assert!(dist(a, b) < 0.01);
    let green = Vec3::new(0.1, 0.8, 0.1);
    assert!(Gamut::bt2020().matrix(Gamut::display_p3()).mul_vec(green).min_elem() < 0.0);
    let enc = OutputTarget::DisplayP3.encode(green, Gamut::bt2020());
    assert!(enc.min_elem() >= 0.0 && enc.max_elem() <= 1.0);
    let enc2020 = OutputTarget::Rec2020.encode(green, Gamut::bt2020());
    assert!(dist(enc2020, green.map(tf::bt709_oetf)) < 1e-5);
    let c = Vec3::new(0.2, 0.3, 0.4);
    assert!(dist(OutputTarget::Rec709.encode(c, Gamut::rec709()), rec709_encode(c)) < 1e-5);
}

#[test]
fn gamut_matrices_match_the_published_values() {
    let check = |m: super::vec::Mat3, rows: [[f32; 3]; 3], eps: f32| {
        for (r, row) in rows.iter().enumerate() {
            for (c, want) in row.iter().enumerate() {
                assert!((m.cols[c][r] - want).abs() < eps, "r{r} c{c}");
            }
        }
    };
    check(
        Gamut::rec709().rgb_to_xyz,
        [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]],
        1e-4,
    );
    check(
        Gamut::bt2020().matrix(Gamut::rec709()),
        [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]],
        1e-3,
    );
    check(
        Gamut::s_gamut3_cine().matrix(Gamut::rec709()),
        [[1.62695, -0.54014, -0.08681], [-0.17852, 1.41794, -0.23943], [-0.04444, -0.19592, 1.24036]],
        1e-4,
    );
    for g in [Gamut::rec709(), Gamut::bt2020(), Gamut::s_gamut3_cine()] {
        assert!((g.luma_row.x + g.luma_row.y + g.luma_row.z - 1.0).abs() < 1e-5);
        for h in [Gamut::rec709(), Gamut::bt2020(), Gamut::s_gamut3_cine()] {
            assert!(dist(g.matrix(h).mul_vec(Vec3::ONE), Vec3::ONE) < 1e-5);
        }
    }
}

#[test]
fn bradford_and_cct_locus() {
    let d65 = WhitePoint::xyz([0.3127, 0.3290]);
    let i = WhitePoint::bradford(d65, d65).mul_vec([0.3, 0.4, 0.5]);
    assert!((i[0] - 0.3).abs() < 1e-12 && (i[1] - 0.4).abs() < 1e-12 && (i[2] - 0.5).abs() < 1e-12);
    let d50 = WhitePoint::xyz([0.3457, 0.3585]);
    let m = WhitePoint::bradford(d65, d50).mul_vec(d65);
    assert!((0..3).all(|k| (m[k] - d50[k]).abs() < 1e-9));
    let xy = WhitePoint::xy(6504.0, 0.0);
    assert!((xy[0] - 0.3135).abs() < 2e-3 && (xy[1] - 0.3237).abs() < 2e-3);
    assert!(WhitePoint::xy(3000.0, 0.0)[0] > xy[0]);
    assert!(WhitePoint::xy(6504.0, 0.01)[1] > xy[1]);
}
