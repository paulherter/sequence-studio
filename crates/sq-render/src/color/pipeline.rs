// Swift: ColorPipeline.swift
//! The CPU reference of the per-clip color chain: decode, ops in order (with the conversion in its place), working-linear.
//! `process` is per pixel and allocation-free. The GPU passes of the compiled chain (Swift `gpuPasses`) are built by the
//! GPU layer from [`ColorPipeline::stages`], not here.

use std::sync::Arc;

use sq_core_model::{
    BasicCorrection, ColorQualifier, ColorWheels, CreativeLook, HSLSecondary, HueCurves, LayerMixMode, RGBCurves,
    StepPrimaries, StepWindow, Vignette, ZoneBoard,
};

use super::cube_lut::CubeLut;
use super::gamut::Gamut;
use super::graph_stages::{KeyTerm, PreparedKeyTerm, PreparedPrimaries, PreparedStepMatte};
use super::source_space::{SourceColorSpace, SourceSpaceExt};
use super::stages::{
    CurveTable, PreparedBasic, PreparedCreative, PreparedHslSecondary, PreparedHueCurves, PreparedVignette,
    PreparedWheels, PreparedZoneBoard,
};
use super::tone_mapping::ToneMapping;
use super::transfer::{bt709_inverse_oetf as inv_oetf, bt709_oetf as oetf};
use super::vec::{Mat3, Vec3};

/// One step of a clip's color chain (parameter level). The list order is the processing order; the single `Conversion`
/// marks where source-linear light becomes the display-referred tone signal (Input LUT or the built-in automatic
/// conversion): ops before it work on the source, ops after it on the display signal.
#[derive(Clone, Debug)]
pub enum ColorOp {
    /// The conversion, with an optional Input LUT.
    Conversion(Option<Arc<CubeLut>>),
    /// Basic Correction.
    Basic(BasicCorrection),
    /// Creative adjustments without the look LUT.
    Creative(CreativeLook),
    /// Look LUT with intensity 0...1 (expects and returns the display signal).
    Look(Arc<CubeLut>, f32),
    /// RGB curves.
    Curves(RGBCurves),
    /// Hue Saturation Curves.
    HueCurves(HueCurves),
    /// Color wheels.
    Wheels(ColorWheels),
    /// Color Range (HSL secondary): a qualified correction.
    HslSecondary(HSLSecondary),
    /// Zone Board.
    ZoneBoard(ZoneBoard),
    /// Vignette.
    Vignette(Vignette),
    /// Pro grade Step primaries.
    Primaries(StepPrimaries),
    /// Start of a limited Step: remembers the Step's input.
    StepBegin,
    /// End of a limited Step: mixes the Step's result over its input by the qualifier (on the input) and the window.
    /// `mix` (0...1) scales the matte. Must follow a `StepBegin` with no other begin / end between them.
    StepEnd {
        /// Qualifier on the Step's input.
        qualifier: Option<ColorQualifier>,
        /// Window on the pixel position.
        window: Option<StepWindow>,
        /// Matte scale.
        mix: f32,
    },
    /// Start of a column with Parallel / Layer Steps: remembers the column's input and clears the sum.
    GroupBegin,
    /// End of one branch of a column; the signal goes back to the column's input. A parallel branch adds its keyed, mixed
    /// result over the input to the sum; a layer branch lays its result over the sum by its key.
    BranchEnd {
        /// Layer branch (else parallel).
        layer: bool,
        /// Qualifier.
        qualifier: Option<ColorQualifier>,
        /// Window.
        window: Option<StepWindow>,
        /// Matte scale.
        mix: f32,
    },
    /// After the parallel branches: the sum becomes their average (`count` 0 = the input, nothing to average).
    GroupMerge {
        /// Number of parallel branches.
        count: usize,
    },
    /// End of the column: the signal is the sum.
    GroupEnd,
    /// One key wire into the key input of the next end: sets or combines the key register.
    KeyTerm(KeyTerm),
    /// Before `GroupEnd`: the column's result is mixed back over the column's input by the key register.
    KeyApply,
    /// Right before a layer `BranchEnd`: how the layer's result composites over what is below.
    LayerMix(LayerMixMode),
}

/// A compiled op kind: parameters turned into the prepared constants the CPU maths and the GPU uniforms both use.
#[derive(Clone, Debug)]
pub enum StageKind {
    /// The conversion.
    Conversion(Option<Arc<CubeLut>>),
    /// Basic Correction.
    Basic(PreparedBasic),
    /// Creative.
    Creative(PreparedCreative),
    /// Look LUT and intensity.
    Look(Arc<CubeLut>, f32),
    /// Curves.
    Curves(CurveTable),
    /// Hue curves.
    HueCurves(PreparedHueCurves),
    /// Wheels.
    Wheels(PreparedWheels),
    /// Color Range.
    HslSecondary(PreparedHslSecondary),
    /// Zone Board.
    ZoneBoard(PreparedZoneBoard),
    /// Vignette.
    Vignette(PreparedVignette),
    /// Step primaries.
    Primaries(PreparedPrimaries),
    /// Step begin.
    StepBegin,
    /// Step end.
    StepEnd(PreparedStepMatte),
    /// Group begin.
    GroupBegin,
    /// Branch end.
    BranchEnd(PreparedStepMatte, bool),
    /// 1 / count (0 = no parallel branch: the average is the column's input).
    GroupMerge(f32),
    /// Group end.
    GroupEnd,
    /// Key term.
    KeyTerm(PreparedKeyTerm),
    /// Key apply.
    KeyApply,
}

/// A compiled op.
#[derive(Clone, Debug)]
pub struct ColorStage {
    /// What the stage does.
    pub kind: StageKind,
    /// Before the conversion: the signal is source-linear light (wrapped through the tone signal).
    pub pre: bool,
}

/// Per-clip chain: decode, ops in order (with the conversion in its place), working-linear.
#[derive(Clone, Debug)]
pub struct ColorPipeline {
    source: SourceColorSpace,
    tone_mapping: ToneMapping,
    skips_tone_map: bool,
    ops: Vec<ColorOp>,
    stages: Vec<ColorStage>,
    to_rec709: Mat3,
}

impl ColorPipeline {
    /// A chain with `ops` (a missing conversion is inserted first).
    pub fn new(source: SourceColorSpace, ops: Vec<ColorOp>, tone_mapping: ToneMapping) -> ColorPipeline {
        let mut p = ColorPipeline {
            source,
            tone_mapping,
            skips_tone_map: false,
            ops,
            stages: Vec::new(),
            to_rec709: source.gamut().matrix(Gamut::rec709()),
        };
        p.compile();
        p
    }

    /// A chain with only a conversion LUT (or none) and an optional creative look.
    pub fn with_luts(
        source: SourceColorSpace,
        conversion_lut: Option<Arc<CubeLut>>,
        look: Option<(Arc<CubeLut>, f32)>,
        tone_mapping: ToneMapping,
    ) -> ColorPipeline {
        let mut ops = vec![ColorOp::Conversion(conversion_lut)];
        if let Some((lut, intensity)) = look {
            ops.push(ColorOp::Look(lut, intensity));
        }
        ColorPipeline::new(source, ops, tone_mapping)
    }

    /// The source color space.
    pub fn source(&self) -> SourceColorSpace {
        self.source
    }

    /// Changes the source and recompiles.
    pub fn set_source(&mut self, source: SourceColorSpace) {
        self.source = source;
        self.compile();
    }

    /// The tone map settings.
    pub fn tone_mapping(&self) -> &ToneMapping {
        &self.tone_mapping
    }

    /// Changes the tone map settings and recompiles.
    pub fn set_tone_mapping(&mut self, tone_mapping: ToneMapping) {
        self.tone_mapping = tone_mapping;
        self.compile();
    }

    /// HDR conform off: an HLG / PQ source is not tone-mapped in the automatic conversion; its highlights above SDR white
    /// clip. Log sources keep their roll-off.
    pub fn skips_tone_map(&self) -> bool {
        self.skips_tone_map
    }

    /// Sets `skips_tone_map` and recompiles.
    pub fn set_skips_tone_map(&mut self, skips: bool) {
        self.skips_tone_map = skips;
        self.compile();
    }

    /// The ops as given.
    pub fn ops(&self) -> &[ColorOp] {
        &self.ops
    }

    /// Replaces the ops and recompiles.
    pub fn set_ops(&mut self, ops: Vec<ColorOp>) {
        self.ops = ops;
        self.compile();
    }

    /// The compiled stages (the GPU layer plans its passes from these).
    pub fn stages(&self) -> &[ColorStage] {
        &self.stages
    }

    /// Source gamut to Rec.709 matrix.
    pub fn to_rec709(&self) -> &Mat3 {
        &self.to_rec709
    }

    fn compile(&mut self) {
        self.to_rec709 = self.source.gamut().matrix(Gamut::rec709());
        let mut ops: Vec<&ColorOp> = self.ops.iter().collect();
        let default_conversion = ColorOp::Conversion(None);
        if !ops.iter().any(|o| matches!(o, ColorOp::Conversion(_))) {
            ops.insert(0, &default_conversion);
        }
        let mut seen_conversion = false;
        let mut out: Vec<ColorStage> = Vec::new();
        let (mut keyed, mut blend) = (false, LayerMixMode::Normal);
        for op in ops {
            let pre = !seen_conversion;
            let gamut = if pre { self.source.gamut() } else { Gamut::rec709() };
            let kind = match op {
                ColorOp::Conversion(lut) => {
                    if seen_conversion {
                        continue; // only the first one converts
                    }
                    seen_conversion = true;
                    out.push(ColorStage { kind: StageKind::Conversion(lut.clone()), pre: false });
                    continue;
                }
                ColorOp::Basic(b) => StageKind::Basic(PreparedBasic::new(b, gamut)),
                ColorOp::Creative(c) => StageKind::Creative(PreparedCreative::new(c, gamut)),
                ColorOp::Look(lut, k) => StageKind::Look(Arc::clone(lut), *k),
                ColorOp::Curves(c) => StageKind::Curves(CurveTable::new(c)),
                ColorOp::HueCurves(h) => StageKind::HueCurves(PreparedHueCurves::new(h, gamut)),
                ColorOp::Wheels(w) => StageKind::Wheels(PreparedWheels::new(w, gamut)),
                ColorOp::HslSecondary(r) => StageKind::HslSecondary(PreparedHslSecondary::new(r, gamut)),
                ColorOp::ZoneBoard(z) => StageKind::ZoneBoard(PreparedZoneBoard::new(z, gamut)),
                ColorOp::Vignette(v) => StageKind::Vignette(PreparedVignette::new(v)),
                ColorOp::Primaries(p) => StageKind::Primaries(PreparedPrimaries::new(p)),
                ColorOp::StepBegin => StageKind::StepBegin,
                ColorOp::StepEnd { qualifier, window, mix } => {
                    let k = StageKind::StepEnd(PreparedStepMatte::new(
                        qualifier.as_ref(),
                        window.as_ref(),
                        *mix,
                        keyed,
                        LayerMixMode::Normal,
                    ));
                    keyed = false;
                    k
                }
                ColorOp::GroupBegin => StageKind::GroupBegin,
                ColorOp::BranchEnd { layer, qualifier, window, mix } => {
                    let b = if *layer { blend } else { LayerMixMode::Normal };
                    let k = StageKind::BranchEnd(
                        PreparedStepMatte::new(qualifier.as_ref(), window.as_ref(), *mix, keyed, b),
                        *layer,
                    );
                    keyed = false;
                    blend = LayerMixMode::Normal;
                    k
                }
                ColorOp::GroupMerge { count } => {
                    StageKind::GroupMerge(if *count > 0 { 1.0 / *count as f32 } else { 0.0 })
                }
                ColorOp::GroupEnd => StageKind::GroupEnd,
                ColorOp::KeyTerm(k) => {
                    keyed = true;
                    StageKind::KeyTerm(PreparedKeyTerm::new(k))
                }
                ColorOp::KeyApply => {
                    keyed = false;
                    StageKind::KeyApply
                }
                ColorOp::LayerMix(m) => {
                    blend = *m;
                    continue;
                }
            };
            out.push(ColorStage { kind, pre });
        }
        self.stages = out;
    }

    /// The conversion LUT, if any (diagnostics and tests).
    pub fn conversion_lut(&self) -> Option<&Arc<CubeLut>> {
        self.ops.iter().find_map(|o| if let ColorOp::Conversion(l) = o { Some(l.as_ref()) } else { None }).flatten()
    }

    /// First creative look LUT, if any (diagnostics and tests).
    pub fn creative_lut(&self) -> Option<&Arc<CubeLut>> {
        self.ops.iter().find_map(|o| if let ColorOp::Look(l, _) = o { Some(l) } else { None })
    }

    /// Intensity of the first creative look LUT (0 when there is none).
    pub fn creative_intensity(&self) -> f32 {
        self.ops.iter().find_map(|o| if let ColorOp::Look(_, k) = o { Some(*k) } else { None }).unwrap_or(0.0)
    }

    /// Nothing to do on top of plain Rec.709 (only an empty conversion on a Rec.709 source).
    pub fn is_identity(&self) -> bool {
        self.source == SourceColorSpace::Rec709 && self.ops.iter().all(|o| matches!(o, ColorOp::Conversion(None)))
    }

    /// Source-linear to display-referred tone signal (Rec.709 primaries, BT.709 encoded): the conversion step.
    fn convert(&self, linear: Vec3, lut: Option<&CubeLut>) -> Vec3 {
        if let Some(lut) = lut {
            return lut.lookup(self.source.encode(linear));
        }
        let mut c = if self.source == SourceColorSpace::Rec709 { linear } else { self.to_rec709.mul_vec(linear) };
        let peak = self.source.tone_map_peak();
        if self.source.gets_tone_map() && !(self.skips_tone_map && peak.is_some()) {
            c = self.tone_mapping.apply_peak(self.tone_mapping.trim(c), peak);
        }
        c.max(Vec3::ZERO).map(oetf)
    }

    /// Source-encoded to working-linear (Rec.709 primaries, D65), the vignette at the frame center.
    pub fn process(&self, source_encoded: Vec3) -> Vec3 {
        self.process_at(source_encoded, [0.5, 0.5], 16.0 / 9.0)
    }

    /// Source-encoded to working-linear (Rec.709 primaries, D65). `uv` (0...1, y down) and `aspect` (width / height)
    /// position the pixel for the vignette and the windows.
    pub fn process_at(&self, source_encoded: Vec3, uv: [f32; 2], aspect: f32) -> Vec3 {
        let mut c = self.source.decode(source_encoded);
        let mut n0 = c;
        let mut acc = Vec3::ZERO;
        let mut km = 1.0f32;
        for s in &self.stages {
            let pre = s.pre;
            match &s.kind {
                StageKind::Conversion(lut) => c = self.convert(c, lut.as_deref()),
                StageKind::Basic(p) => c = p.apply(c, pre),
                StageKind::Creative(p) => c = p.apply(c, pre),
                StageKind::Look(lut, k) => {
                    c = if pre { inv_oetf3(mix_look(lut, c.map(oetf), *k)) } else { mix_look(lut, c, *k) };
                }
                StageKind::Curves(t) => c = t.apply(c, pre),
                StageKind::HueCurves(p) => c = p.apply(c, pre),
                StageKind::Wheels(p) => c = p.apply(c, pre),
                StageKind::HslSecondary(p) => c = p.apply(c, pre),
                StageKind::ZoneBoard(p) => c = p.apply(c, pre),
                StageKind::Vignette(p) => c = p.apply(c, uv, aspect, pre),
                StageKind::Primaries(p) => c = p.apply(c, pre),
                StageKind::StepBegin => n0 = c,
                StageKind::StepEnd(m) => {
                    c = m.apply(c, n0, uv, aspect, pre, if m.keyed { km } else { 1.0 });
                    if m.keyed {
                        km = 1.0;
                    }
                }
                StageKind::GroupBegin => {
                    n0 = c;
                    acc = Vec3::ZERO;
                }
                StageKind::BranchEnd(m, layer) => {
                    let mut k = m.matte(n0, uv, aspect, pre);
                    if m.keyed {
                        k *= km;
                        km = 1.0;
                    }
                    if *layer {
                        acc = acc + (m.composite(c, acc) - acc) * k;
                    } else {
                        acc += n0 + (c - n0) * k;
                    }
                    c = n0;
                }
                StageKind::GroupMerge(inv) => acc = if *inv > 0.0 { acc * *inv } else { n0 },
                StageKind::GroupEnd => c = acc,
                StageKind::KeyTerm(t) => km = t.apply(km, n0, uv, aspect, pre),
                StageKind::KeyApply => {
                    acc = n0 + (acc - n0) * km;
                    km = 1.0;
                }
            }
        }
        inv_oetf3(c)
    }
}

fn inv_oetf3(v: Vec3) -> Vec3 {
    v.map(inv_oetf)
}

/// The look LUT at intensity `k` over the tone signal `t`.
fn mix_look(lut: &CubeLut, t: Vec3, k: f32) -> Vec3 {
    let graded = lut.lookup(t);
    if k >= 1.0 { graded } else { t + (graded - t) * k }
}
