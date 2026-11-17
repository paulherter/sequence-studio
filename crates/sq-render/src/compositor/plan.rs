// Swift: ColorPipelineGPU+Plan.swift
//! The color chain's pass plan: which sections run in which dispatch, with which constants. No GPU calls: the same on
//! every backend (the Slang `colorChain` kernels read these blocks).

use std::sync::Arc;

use sq_core_color::basic_tone_curves as tone;

use super::block::Block;
use crate::color::graph_stages::{PreparedKeyTerm, PreparedStepMatte, PreparedWindow};
use crate::color::pipeline::{ColorPipeline, StageKind};
use crate::color::stages::{CURVE_TABLE_COUNT, PreparedHslSecondary};
use crate::color::vec::{Mat3, Vec3};
use crate::color::{CubeKind, CubeLut, LutInterpolation, SourceColorSpace, SourceSpaceExt};
use sq_core_model::ColorSpaceID as Cs;

/// Header of one pass (`ColorHeader`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    /// count, start domain, end domain, source.
    pub ints: [u32; 4],
    /// x: the texture is a quarter-turned picture (vignette geometry is upright); yz: dispatch origin.
    pub extra: [u32; 4],
}

/// One block of a pass (`Sec`, 128 bytes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sec {
    /// kind, pre, flags, extra.
    pub head: [u32; 4],
    pub a: [f32; 4],
    pub b: [f32; 4],
    pub c: [f32; 4],
    pub d: [f32; 4],
    pub m: [[f32; 3]; 3],
}

impl Default for Sec {
    fn default() -> Sec {
        Sec { head: [0; 4], a: [0.0; 4], b: [0.0; 4], c: [0.0; 4], d: [0.0; 4], m: IDENTITY }
    }
}

const IDENTITY: [[f32; 3]; 3] = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

impl Header {
    /// The 32 bytes of `ColorHeader`.
    pub(crate) fn write(&self, b: &mut Block) {
        b.uvec4(self.ints).uvec4(self.extra);
    }
}

impl Sec {
    /// The 128 bytes of `Sec`.
    pub(crate) fn write(&self, b: &mut Block) {
        b.uvec4(self.head).vec4(self.a).vec4(self.b).vec4(self.c).vec4(self.d).mat3(self.m);
    }
}

/// One compute dispatch: up to `MAX_SECTIONS` blocks (a column: `MAX_GROUP_SECTIONS`) with at most one LUT and `MAX_CURVES`
/// curve tables.
#[derive(Clone, Debug)]
pub struct Pass {
    pub header: Header,
    pub sections: Vec<Sec>,
    pub curves: Vec<[f32; 4]>,
    pub lut: Option<Arc<CubeLut>>,
}

pub const MAX_SECTIONS: usize = 8;
/// A column with Parallel / Layer Steps keeps its registers in one pass: it may fill a pass up to this many blocks (a `Sec`
/// is 128 B). Its LUT and curve budget is the pass's.
pub const MAX_GROUP_SECTIONS: usize = 24;
/// Curve tables per pass (a Hue Saturation Curves block takes 2).
pub const MAX_CURVES: usize = 3;

pub const KIND_CONVERSION: u32 = 0;
pub const KIND_BASIC: u32 = 1;
pub const KIND_CREATIVE: u32 = 2;
pub const KIND_LOOK: u32 = 3;
pub const KIND_CURVES: u32 = 4;
pub const KIND_WHEELS: u32 = 5;
pub const KIND_VIGNETTE: u32 = 6;
pub const KIND_HUE_CURVES: u32 = 7;
pub const KIND_HSL_SECONDARY: u32 = 8;
pub const KIND_PRIMARIES: u32 = 9;
pub const KIND_STEP_BEGIN: u32 = 10;
pub const KIND_STEP_END: u32 = 11;
pub const KIND_GROUP_BEGIN: u32 = 12;
pub const KIND_BRANCH_END: u32 = 13;
pub const KIND_GROUP_MERGE: u32 = 14;
pub const KIND_GROUP_END: u32 = 15;
pub const KIND_KEY_TERM: u32 = 16;
pub const KIND_KEY_APPLY: u32 = 17;
pub const KIND_ZONE_BOARD: u32 = 18;

const LUT_PRESENT: u32 = 1;
const LUT_1D: u32 = 2;
const LUT_IN: u32 = 4;
const LUT_OUT: u32 = 8;
const LUT_TRILINEAR: u32 = 16;

fn v4(v: Vec3, w: f32) -> [f32; 4] {
    [v.x, v.y, v.z, w]
}

fn cols(m: &Mat3) -> [[f32; 3]; 3] {
    m.cols.map(|c| [c.x, c.y, c.z])
}

fn lut_fields(s: &mut Sec, l: &CubeLut) {
    let mut f = LUT_PRESENT | if l.kind == CubeKind::Lut1D { LUT_1D } else { 0 };
    if l.in_video_range {
        f |= LUT_IN;
    }
    if l.out_video_range {
        f |= LUT_OUT;
    }
    if l.interpolation == LutInterpolation::Trilinear {
        f |= LUT_TRILINEAR;
    }
    s.head[2] = f;
    s.head[3] = l.size as u32;
    s.a = v4(l.domain_min, 0.0);
    s.b = v4(l.domain_max, 1.0);
}

/// `Sec.c.w` of the conversion section: 1 / 0 = soft gamut compression on / off, -1 = conform off (no trim, no tone map).
fn conversion_tone_map_flag(p: &ColorPipeline) -> f32 {
    if p.skips_tone_map() && p.source().tone_map_peak().is_some() {
        -1.0
    } else if p.tone_mapping().compresses_gamut {
        1.0
    } else {
        0.0
    }
}

/// Transfer index in the shader's `map3` (decode = index, encode = index + 10; 2 = Rec.709). The gamut travels as a matrix,
/// so sources that share a curve share an index. Indices 0...9 are taken; the vendor logs decode at 20...26 and encode at
/// 30...36 (always +10). Callers test `transfer < 30u`.
pub fn shader_index(s: SourceColorSpace) -> u32 {
    match s {
        Cs::SLog3SGamut3Cine => 0,
        Cs::HlgBT2020 => 1,
        Cs::Rec709 => 2,
        Cs::VLogVGamut => 3,
        Cs::AppleLog => 4,
        Cs::PqBT2020 => 5,
        Cs::DLogDGamut => 6,
        Cs::CanonLogCinemaGamut | Cs::CanonLogBT2020 | Cs::CanonLogBT709 => 7,
        Cs::CanonLog2CinemaGamut | Cs::CanonLog2BT2020 | Cs::CanonLog2BT709 => 8,
        Cs::CanonLog3CinemaGamut | Cs::CanonLog3BT2020 | Cs::CanonLog3BT709 => 9,
        Cs::LogC3WideGamut3 => 20,
        Cs::LogC4WideGamut4 => 21,
        Cs::Log3G10RedWideGamut => 22,
        Cs::BmdFilmGen5WideGamut => 23,
        Cs::NLogBT2020 => 24,
        Cs::FLog2FGamutC => 25,
        Cs::AcesCCTAP1 => 26,
    }
}

/// The qualifier layout of a Color Range block (center, half width, hue edge, all hues / sat lo, sat hi, sat edge, invert /
/// luma lo, luma hi, luma edge, `mix_c`), written into `a..d`.
fn qualifier(s: &mut Sec, q: &Option<PreparedHslSecondary>) {
    if let Some(r) = q {
        s.a = [r.center, r.half_width, r.hue_soft, f32::from(u8::from(r.all_hues))];
        s.b = [r.sat_lo, r.sat_hi, r.sat_soft, f32::from(u8::from(r.invert))];
        s.c = [r.lum_lo, r.lum_hi, r.lum_soft, 1.0];
        s.d = v4(r.luma, 0.0);
    }
}

fn window(s: &mut Sec, w: &Option<PreparedWindow>) {
    if let Some(w) = w {
        s.m = cols(&w.matrix());
    }
}

/// A Step end / branch end: flags, qualifier, window and the mix in `d.w`.
fn step_matte(s: &mut Sec, mt: &PreparedStepMatte, extra_flags: u32) {
    s.head[2] = mt.flags() | extra_flags;
    qualifier(s, &mt.qualifier);
    window(s, &mt.window);
    s.d[3] = mt.mix;
}

fn key_term(s: &mut Sec, k: &PreparedKeyTerm) {
    s.head[2] = k.flags();
    qualifier(s, &k.qualifier);
    window(s, &k.window);
}

/// The blocks and resources a stage needs.
struct Built {
    sec: Sec,
    lut: Option<Arc<CubeLut>>,
    curves: Vec<[f32; 4]>,
}

fn section(p: &ColorPipeline, kind: &StageKind, pre: bool) -> Built {
    let mut sec = Sec { head: [0, u32::from(pre), 0, 0], ..Sec::default() };
    let mut lut = None;
    let mut curves = Vec::new();
    match kind {
        StageKind::Conversion(l) => {
            sec.head[0] = KIND_CONVERSION;
            sec.m = cols(p.to_rec709());
            // peak 0 = exponential roll-off; z = export gain; w = gamut compression, -1 = no tone map
            sec.c = [
                p.tone_mapping().knee(),
                p.source().tone_map_peak().unwrap_or(0.0),
                p.tone_mapping().exposure_gain(),
                conversion_tone_map_flag(p),
            ];
            if let Some(l) = l {
                lut_fields(&mut sec, l);
                lut = Some(Arc::clone(l));
            }
        }
        StageKind::Basic(b) => {
            sec.head[0] = KIND_BASIC;
            let mut f = 0u32;
            for (on, bit) in [
                (b.has_wb, 1),
                (b.has_exposure, 2),
                (b.has_contrast, 4),
                (b.has_shadows, 8),
                (b.has_highlights, 64),
                (b.has_levels, 16),
            ] {
                if on {
                    f |= bit;
                }
            }
            if b.saturation != 1.0 || b.vibrance != 0.0 {
                f |= 32;
            }
            sec.head[2] = f;
            if b.lumetri {
                // head.w 1 = Lumetri tone model (BasicToneCurves): a = (exposure gain, contrast k, highlights bump, shadows
                // bump), b = (blacks lift, whites gain, sat, vib), c.w = exposure shoulder on, d = (contrast pivot, exposure knee).
                sec.head[3] = 1;
                let k = if b.con >= 0.0 { b.con * tone::CONTRAST_UP } else { b.con * tone::CONTRAST_DOWN };
                sec.a = [b.exposure_scale, k, tone::HIGHLIGHTS_REACH * b.hi, tone::SHADOWS_REACH * b.sh];
                sec.b = [tone::BLACKS_REACH * b.bl, (tone::WHITES_STOPS * b.wh).exp2(), b.saturation, b.vibrance];
                sec.c = v4(b.luma, if b.ev > 0.0 { 1.0 } else { 0.0 });
                sec.d = [tone::CONTRAST_PIVOT, tone::EXPOSURE_KNEE, 0.0, 0.0];
            } else {
                sec.a = [b.exposure_scale, b.contrast_k, b.highlights, b.shadows];
                sec.b = [b.black_point, b.white_point, b.saturation, b.vibrance];
                sec.c = v4(b.luma, 0.0);
            }
            sec.m = cols(&b.wb);
        }
        StageKind::Creative(c) => {
            sec.head[0] = KIND_CREATIVE;
            sec.head[2] = u32::from(c.has_tint);
            sec.a = [c.fade, c.saturation, c.vibrance, c.balance];
            sec.b = v4(c.shadow_tint, 0.0);
            sec.c = v4(c.highlight_tint, 0.0);
            sec.d = v4(c.luma, 0.0);
        }
        StageKind::Look(l, k) => {
            sec.head[0] = KIND_LOOK;
            lut_fields(&mut sec, l);
            sec.c = [*k, 0.0, 0.0, 0.0];
            lut = Some(Arc::clone(l));
        }
        StageKind::Curves(t) => {
            sec.head[0] = KIND_CURVES;
            curves = t.table.iter().map(|v| v4(*v, 0.0)).collect();
        }
        StageKind::HueCurves(h) => {
            sec.head[0] = KIND_HUE_CURVES;
            sec.d = v4(h.luma, 0.0);
            curves = h.table.clone();
        }
        StageKind::Wheels(w) => {
            sec.head[0] = KIND_WHEELS;
            sec.head[2] = u32::from(w.has_gamma);
            sec.a = v4(w.lift, w.saturation);
            sec.b = v4(w.gamma_exponent, 0.0);
            sec.c = v4(w.gain, 0.0);
            sec.d = v4(w.luma, 0.0);
        }
        StageKind::HslSecondary(r) => {
            // a = (center, half width, hue edge, all hues), b = (sat lo, sat hi, sat edge, invert), c = (luma lo, luma hi,
            // luma edge, saturation), d = (luma row, hue rotation), m = diagonal gains. Color volume (head.w = 1): a = (ball
            // center, radius), b = (edge, 0, 0, invert).
            sec.head[0] = KIND_HSL_SECONDARY;
            sec.a = [r.center, r.half_width, r.hue_soft, f32::from(u8::from(r.all_hues))];
            sec.b = [r.sat_lo, r.sat_hi, r.sat_soft, f32::from(u8::from(r.invert))];
            sec.c = [r.lum_lo, r.lum_hi, r.lum_soft, r.saturation];
            if r.volume {
                sec.head[3] = 1;
                sec.a = v4(r.volume_center, r.volume_radius);
                sec.b = [r.volume_edge, 0.0, 0.0, f32::from(u8::from(r.invert))];
            }
            sec.d = v4(r.luma, r.theta);
            sec.m = [[r.gains.x, 0.0, 0.0], [0.0, r.gains.y, 0.0], [0.0, 0.0, r.gains.z]];
        }
        StageKind::ZoneBoard(z) => {
            // a...d = (tint offset, saturation factor) of Global, Shadows, Midtones, Highlights; m = (exposure gains, luma row).
            sec.head[0] = KIND_ZONE_BOARD;
            sec.a = v4(z.offsets[0], z.saturations[0]);
            sec.b = v4(z.offsets[1], z.saturations[1]);
            sec.c = v4(z.offsets[2], z.saturations[2]);
            sec.d = v4(z.offsets[3], z.saturations[3]);
            sec.m = [[z.gains[0], z.gains[1], z.gains[2]], [z.gains[3], z.luma.x, z.luma.y], [z.luma.z, 0.0, 0.0]];
        }
        StageKind::Vignette(v) => {
            sec.head[0] = KIND_VIGNETTE;
            sec.a = [v.amount, v.start, v.feather, v.exponent];
            sec.b = [v.aspect_mix, 0.0, 0.0, 0.0];
        }
        StageKind::Primaries(q) => {
            // a = (lift, contrast), b = (gamma, pivot), c = (gain, saturation), d = (offset, 0).
            sec.head[0] = KIND_PRIMARIES;
            sec.head[2] = q.flags();
            sec.a = v4(q.lift, q.contrast);
            sec.b = v4(q.gamma, q.pivot);
            sec.c = v4(q.gain, q.saturation);
            sec.d = v4(q.offset, 0.0);
        }
        StageKind::StepBegin => sec.head[0] = KIND_STEP_BEGIN,
        StageKind::StepEnd(mt) => {
            // a...d = the qualifier in the Color Range layout, m = the window.
            sec.head[0] = KIND_STEP_END;
            step_matte(&mut sec, mt, 0);
        }
        StageKind::GroupBegin => sec.head[0] = KIND_GROUP_BEGIN,
        StageKind::BranchEnd(mt, layer) => {
            // Like a Step end; flag bit 3 = layer.
            sec.head[0] = KIND_BRANCH_END;
            step_matte(&mut sec, mt, if *layer { 8 } else { 0 });
        }
        StageKind::KeyTerm(k) => {
            // Like a Step end's matte: a...d = the qualifier, m = the window; flags in the term.
            sec.head[0] = KIND_KEY_TERM;
            key_term(&mut sec, k);
        }
        StageKind::KeyApply => sec.head[0] = KIND_KEY_APPLY,
        StageKind::GroupMerge(inv) => {
            sec.head[0] = KIND_GROUP_MERGE;
            sec.head[2] = if *inv > 0.0 { 0 } else { 1 };
            sec.a[0] = *inv;
        }
        StageKind::GroupEnd => sec.head[0] = KIND_GROUP_END,
    }
    Built { sec, lut, curves }
}

/// What a limited Step (begin ... end) or a column (group begin ... end) needs: sections, curve tables and whether it
/// carries a LUT. It must fit one pass.
fn needs(p: &ColorPipeline, from: usize, end: fn(&StageKind) -> bool) -> (usize, usize, bool) {
    let (mut n, mut curves, mut lut) = (0, 0, false);
    for st in &p.stages()[from..] {
        n += 1;
        match &st.kind {
            StageKind::Curves(_) => curves += 1,
            StageKind::HueCurves(_) => curves += 2,
            StageKind::Look(..) | StageKind::Conversion(Some(_)) => lut = true,
            _ => {}
        }
        if end(&st.kind) {
            break;
        }
    }
    (n, curves, lut)
}

/// Splits the compiled chain into passes. Between passes the texture holds the running signal: source-linear light before
/// the conversion, the display tone signal after it; the last pass ends in working-linear. `skip_identities` drops blocks
/// that change nothing (see [`skipping_identities`]).
pub fn passes(p: &ColorPipeline, skip_identities: bool) -> Vec<Pass> {
    let source = shader_index(p.source());
    let mut out: Vec<Pass> = Vec::new();
    let mut domain = 0u32; // 0 source-encoded, 1 source-linear, 2 display
    let fresh = |domain: u32| Pass {
        header: Header { ints: [0, domain, 0, source], extra: [0; 4] },
        sections: Vec::new(),
        curves: Vec::new(),
        lut: None,
    };
    let mut cur = fresh(domain);
    let close = |cur: &mut Pass, out: &mut Vec<Pass>, domain: &mut u32, last: bool| {
        cur.header.ints[0] = cur.sections.len() as u32;
        cur.header.ints[2] = if last {
            3
        } else if *domain == 0 {
            1
        } else {
            *domain
        };
        let next = if *domain == 0 { 1 } else { *domain };
        out.push(std::mem::replace(cur, fresh(next)));
        *domain = next;
    };
    let mut in_group = false;
    for (index, st) in p.stages().iter().enumerate() {
        let curve_count = |cur: &Pass| cur.curves.len() / CURVE_TABLE_COUNT;
        match &st.kind {
            StageKind::GroupBegin => {
                let (n, c, lut) = needs(p, index, |k| matches!(k, StageKind::GroupEnd));
                if !cur.sections.is_empty()
                    && (cur.sections.len() + n > MAX_GROUP_SECTIONS
                        || curve_count(&cur) + c > MAX_CURVES
                        || (lut && cur.lut.is_some()))
                {
                    close(&mut cur, &mut out, &mut domain, false);
                }
                in_group = true;
            }
            StageKind::StepBegin => {
                let (n, c, lut) = needs(p, index, |k| matches!(k, StageKind::StepEnd(_)));
                if !cur.sections.is_empty()
                    && (cur.sections.len() + n > MAX_SECTIONS
                        || curve_count(&cur) + c > MAX_CURVES
                        || (lut && cur.lut.is_some()))
                {
                    close(&mut cur, &mut out, &mut domain, false);
                }
            }
            _ => {}
        }
        let mut built = section(p, &st.kind, st.pre);
        if !in_group
            && (cur.sections.len() >= MAX_SECTIONS
                || (built.lut.is_some() && cur.lut.is_some())
                || (!built.curves.is_empty()
                    && curve_count(&cur) + built.curves.len() / CURVE_TABLE_COUNT > MAX_CURVES))
        {
            close(&mut cur, &mut out, &mut domain, false);
        }
        if matches!(st.kind, StageKind::GroupEnd) {
            in_group = false;
        }
        if !built.curves.is_empty() {
            built.sec.head[3] = curve_count(&cur) as u32;
            cur.curves.append(&mut built.curves);
        }
        if built.lut.is_some() {
            cur.lut = built.lut;
        }
        cur.sections.push(built.sec);
        if matches!(st.kind, StageKind::Conversion(_)) {
            domain = 2;
        }
    }
    close(&mut cur, &mut out, &mut domain, true);
    if skip_identities { skipping_identities(out) } else { out }
}

/// Drops blocks that leave every value bit for bit as it is (on the GPU, in float, incl. -0, inf, NaN), and passes left
/// without blocks that neither change domain nor end the chain (a half texture read and written back is the same texture).
/// Pass boundaries are kept: each one rounds to half, so merging passes would move pixels.
/// - Basic with no flags: the block returns its input untouched (pre or post).
/// - Creative after the conversion with no fade, no tint, saturation 1, vibrance 0.
/// - Vignette with amount 0: `c * exp2(0)` is `c * 1`.
///
/// Not dropped: a look at intensity 0 and neutral wheels (`t + 0` turns -0 into +0), neutral curves (table interpolation is
/// not exact), pre-conversion creative (BT.709 round trip).
pub fn skipping_identities(passes: Vec<Pass>) -> Vec<Pass> {
    let count = passes.len();
    let mut out = Vec::new();
    for (i, mut p) in passes.into_iter().enumerate() {
        p.sections.retain(|s| match s.head[0] {
            KIND_BASIC => s.head[2] != 0,
            KIND_CREATIVE => !(s.head[1] == 0 && s.head[2] == 0 && s.a[0] == 0.0 && s.a[1] == 1.0 && s.a[2] == 0.0),
            KIND_VIGNETTE => s.a[0] != 0.0,
            _ => true,
        });
        p.header.ints[0] = p.sections.len() as u32;
        if p.sections.is_empty() && i > 0 && i < count - 1 && p.header.ints[1] == p.header.ints[2] {
            continue;
        }
        out.push(p);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::ColorOp;
    use sq_core_model::{BasicCorrection, RGBCurves, StepPrimaries, Vignette};

    fn lut() -> Arc<CubeLut> {
        let n = 2;
        let table = (0..8).map(|i| Vec3::new((i & 1) as f32, ((i >> 1) & 1) as f32, ((i >> 2) & 1) as f32)).collect();
        Arc::new(
            CubeLut::new("", CubeKind::Lut3D, n, (Vec3::ZERO, Vec3::ONE), table, (false, false)).expect("valid table"),
        )
    }

    fn pipeline(source: SourceColorSpace, ops: Vec<ColorOp>) -> ColorPipeline {
        ColorPipeline::new(source, ops, crate::color::ToneMapping::default())
    }

    #[test]
    fn passes_split_at_second_lut_and_resource_limits() {
        // Swift ColorPipelineGPUTests.passesSplitAtSecondLUTAndResourceLimits.
        let p = pipeline(
            Cs::Rec709,
            vec![ColorOp::Look(lut(), 1.0), ColorOp::Conversion(Some(lut())), ColorOp::Look(lut(), 1.0)],
        );
        let passes = passes(&p, true);
        assert_eq!(passes.len(), 3);
        assert_eq!(passes.iter().map(|p| p.header.ints[1]).collect::<Vec<_>>(), [0, 1, 2], "start domains");
        assert_eq!(passes.iter().map(|p| p.header.ints[2]).collect::<Vec<_>>(), [1, 2, 3], "end domains");
        let mut ops = vec![ColorOp::Conversion(None)];
        ops.extend((0..7).map(|_| ColorOp::Curves(RGBCurves::default())));
        assert_eq!(super::passes(&pipeline(Cs::Rec709, ops), true).len(), 3, "3 curve tables per pass");
        let single = super::passes(&pipeline(Cs::Rec709, vec![]), true);
        assert!(single.len() == 1 && single[0].header.ints[0] == 1);
    }

    #[test]
    fn more_than_eight_blocks_need_a_second_pass() {
        let mut ops = vec![ColorOp::Conversion(None)];
        ops.extend((0..9).map(|_| ColorOp::Vignette(Vignette { amount: -0.5, ..Vignette::default() })));
        let p = super::passes(&pipeline(Cs::Rec709, ops), true);
        assert_eq!(p.iter().map(|p| p.sections.len()).collect::<Vec<_>>(), [8, 2]);
        assert_eq!(p[1].header.ints[1], 2, "the second pass starts in the display domain");
    }

    #[test]
    fn every_limited_step_stays_in_one_pass() {
        // Swift ColorGraphRenderTests.passesKeepEveryLimitedStepInOnePass.
        let mut ops = vec![ColorOp::Conversion(None)];
        for _ in 0..6 {
            ops.push(ColorOp::StepBegin);
            ops.push(ColorOp::Primaries(StepPrimaries::default()));
            ops.push(ColorOp::Curves(RGBCurves::default()));
            ops.push(ColorOp::StepEnd { qualifier: None, window: None, mix: 1.0 });
        }
        let p = super::passes(&pipeline(Cs::SLog3SGamut3Cine, ops), true);
        assert!(p.len() > 1);
        for pass in &p {
            let mut open = false;
            for s in &pass.sections {
                if s.head[0] == KIND_STEP_BEGIN {
                    assert!(!open);
                    open = true;
                }
                if s.head[0] == KIND_STEP_END {
                    assert!(open);
                    open = false;
                }
            }
            assert!(!open, "a Step crosses a pass boundary");
        }
    }

    #[test]
    fn identity_blocks_are_skipped_on_request() {
        let ops = vec![
            ColorOp::Conversion(None),
            ColorOp::Basic(BasicCorrection::default()),
            ColorOp::Vignette(Vignette::default()),
        ];
        let p = pipeline(Cs::Rec709, ops);
        let kinds = |skip| {
            super::passes(&p, skip).iter().flat_map(|p| p.sections.iter().map(|s| s.head[0])).collect::<Vec<_>>()
        };
        assert_eq!(kinds(false), [KIND_CONVERSION, KIND_BASIC, KIND_VIGNETTE]);
        assert_eq!(kinds(true), [KIND_CONVERSION]);
    }

    #[test]
    fn the_lumetri_basic_block_carries_the_tone_curve_constants() {
        let b = BasicCorrection { exposure: 0.5, contrast: 25.0, ..BasicCorrection::default() };
        let p = pipeline(Cs::Rec709, vec![ColorOp::Conversion(None), ColorOp::Basic(b)]);
        let passes = super::passes(&p, true);
        let basic = passes[0].sections.iter().find(|s| s.head[0] == KIND_BASIC).expect("basic block");
        assert_eq!(basic.head[3], 1, "Lumetri tone model");
        assert!(basic.head[2] & 2 != 0 && basic.head[2] & 4 != 0, "exposure and contrast flags");
        assert_eq!(basic.d[0], tone::CONTRAST_PIVOT);
        assert_eq!(basic.d[1], tone::EXPOSURE_KNEE);
        assert_eq!(basic.c[3], 1.0, "exposure shoulder on for a positive exposure");
        assert_eq!(basic.a[1], 0.25 * tone::CONTRAST_UP);
    }

    #[test]
    fn transfer_indices_follow_the_shader_map() {
        assert_eq!(shader_index(Cs::Rec709), 2);
        assert_eq!(shader_index(Cs::CanonLog3BT709), 9);
        assert_eq!(shader_index(Cs::CanonLog3CinemaGamut), 9);
        assert_eq!(shader_index(Cs::LogC3WideGamut3), 20);
        assert_eq!(shader_index(Cs::AcesCCTAP1), 26);
    }

    #[test]
    fn blocks_serialize_to_their_slang_sizes() {
        let mut b = Block::new();
        Sec::default().write(&mut b);
        assert_eq!(b.len(), 128, "Sec: head, 4 vectors, 3 matrix columns");
        let mut h = Block::new();
        Header { ints: [0; 4], extra: [0; 4] }.write(&mut h);
        assert_eq!(h.len(), 32);
    }
}
