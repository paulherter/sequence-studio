// Swift: ClipColorPipeline.swift
//! Builds the per-layer [`ColorPipeline`] from a clip's color settings and its media's detected properties, plus the LUT
//! provider that loads and caches the referenced `.cube` files.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::SystemTime;

use sq_core_color::{ColorGraphExt, ColorGraphWiringExt, ColorStepExt, CreativeLookExt, NeutralExt};
use sq_core_model::{
    ClipColor, ColorEffect, ColorGraph, ColorSectionKind, ColorSpaceID, ColorStep, GraphPort, KeyMixMode, LUTRef,
    LayerMixMode, LogMode, MediaInfo, StepKind, TargetSpace,
};
use sq_core_time::Id;

use super::cube_lut::CubeLut;
use super::graph_stages::KeyTerm;
use super::pipeline::{ColorOp, ColorPipeline};
use super::tone_mapping::ToneMapping;

/// Blocks one fused GPU pass of a group can hold (Swift `ColorPipelineGPU.maxGroupSections`).
const MAX_GROUP_SECTIONS: usize = 24;
/// Curve tables one pass can hold (Swift `ColorPipelineGPU.maxCurves`; a Hue Saturation Curves block takes 2).
const MAX_CURVES: usize = 3;

/// Identity of a LUT file's contents (modification date + size) so edits on disk are noticed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LutStamp {
    /// Modification time.
    pub modified: Option<SystemTime>,
    /// Size in bytes.
    pub size: u64,
}

impl LutStamp {
    /// The stamp of a file, or `None` when it cannot be read.
    pub fn of_file(path: &str) -> Option<LutStamp> {
        let m = std::fs::metadata(path).ok()?;
        Some(LutStamp { modified: m.modified().ok(), size: m.len() })
    }
}

/// Loads parsed LUTs for a reference. Only `File` and `Embedded` are loadable; `Automatic` yields `None`.
pub trait LutProvider: Send + Sync {
    /// The parsed LUT.
    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>>;
    /// Identity of the LUT's file contents; `None` = not file-backed.
    fn stamp(&self, _r: &LUTRef) -> Option<LutStamp> {
        None
    }
}

/// Loads the bytes of a file by path.
type FileLoader = Box<dyn Fn(&str) -> Option<Vec<u8>> + Send + Sync>;
/// Loads the bytes of an embedded LUT by media id.
type EmbeddedLoader = Box<dyn Fn(Id) -> Option<Vec<u8>> + Send + Sync>;
/// Reads the stamp of a file by path.
type StampReader = Box<dyn Fn(&str) -> Option<LutStamp> + Send + Sync>;

type Cache = HashMap<LUTRef, (Option<LutStamp>, Arc<CubeLut>)>;

/// Parses each referenced LUT once (successes only; failed loads are retried) and serves it from memory afterwards.
/// The loaders return raw `.cube` bytes: a file read for `File`, and for `Embedded` the app layer's glue.
pub struct CachingLutProvider {
    cache: Mutex<Cache>,
    file: FileLoader,
    embedded: EmbeddedLoader,
    stamp_reader: StampReader,
}

impl CachingLutProvider {
    /// Provider with a file loader (default: read the file), an embedded-LUT loader and a stamp reader.
    pub fn new(file: Option<FileLoader>, embedded: EmbeddedLoader, stamp: Option<StampReader>) -> CachingLutProvider {
        CachingLutProvider {
            cache: Mutex::new(HashMap::new()),
            file: file.unwrap_or_else(|| Box::new(|p| std::fs::read(p).ok())),
            embedded,
            stamp_reader: stamp.unwrap_or_else(|| Box::new(LutStamp::of_file)),
        }
    }

    /// Drops everything (e.g. after a LUT file changed on disk).
    pub fn remove_all(&self) {
        self.cache.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }

    /// A cached LUT, only while the file still has the stamp it was read with.
    fn cached(&self, r: &LUTRef, stamp: Option<LutStamp>) -> Option<Arc<CubeLut>> {
        let cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        cache.get(r).filter(|e| e.0 == stamp).map(|e| Arc::clone(&e.1))
    }
}

impl LutProvider for CachingLutProvider {
    fn stamp(&self, r: &LUTRef) -> Option<LutStamp> {
        if let LUTRef::File { path } = r { (self.stamp_reader)(path) } else { None }
    }

    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
        let stamp = self.stamp(r);
        let data = match r {
            LUTRef::Automatic => return None,
            LUTRef::File { path } => {
                if let Some(hit) = self.cached(r, stamp) {
                    return Some(hit);
                }
                (self.file)(path)
            }
            LUTRef::Embedded { media } => {
                if let Some(hit) = self.cached(r, None) {
                    return Some(hit);
                }
                (self.embedded)(*media)
            }
        };
        // I/O and parsing happen outside the lock; failures are not cached (the file may appear or be fixed later).
        let lut = Arc::new(CubeLut::parse(&String::from_utf8_lossy(&data?)).ok()?);
        let mut cache = self.cache.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = cache.get(r).filter(|e| e.0 == stamp) {
            return Some(Arc::clone(&existing.1));
        }
        cache.insert(r.clone(), (stamp, Arc::clone(&lut)));
        Some(lut)
    }
}

/// The source space the render uses: the override, else the media's, else Rec.709; log sources count as Rec.709 when the
/// log mode is off.
pub(crate) fn effective_source(c: &ClipColor, media_space: Option<ColorSpaceID>) -> ColorSpaceID {
    use sq_core_color::ColorSpaceIdExt as _;
    let id = c.source.or(media_space).unwrap_or(ColorSpaceID::Rec709);
    if c.log_mode == LogMode::Off && id.is_log() { ColorSpaceID::Rec709 } else { id }
}

fn target_is_hdr(t: TargetSpace) -> bool {
    matches!(t, TargetSpace::Rec2020PQ | TargetSpace::Rec2020HLG)
}

/// Builds the per-layer pipeline from a clip's Color effects and its media's detected properties.
/// - Source: `source` override, else the media's color space, else Rec.709.
/// - Effects in list order. Inside one effect: Basic Correction sliders, Input LUT, Creative (look, then adjustments),
///   Curves (RGB, then Hue Saturation), Wheels, Color Range, Zone Board, Vignette. Disabled or neutral sections are skipped.
/// - The first effect's Input LUT is the conversion step and is always emitted (a disabled Basic Correction or "none" =
///   the built-in conversion). `File`/`Embedded` = that LUT; `Automatic` = the media's embedded camera LUT when
///   `use_embedded_lut`, the media has one, and the effective source is S-Log3. So the first effect's sliders work on the
///   source signal, everything after it on display-referred Rec.709.
/// - Later effects: their Input LUT is an ordinary look at `input_lut_intensity`. Creative look LUT: intensity 0...100 to
///   0...1. A LUT that fails to load is treated as absent.
pub fn pipeline_from_clip_color(
    c: &ClipColor,
    media_id: Id,
    media_info: Option<&MediaInfo>,
    provider: Option<&dyn LutProvider>,
) -> ColorPipeline {
    let id = effective_source(c, media_info.map(MediaInfo::color_space));
    // An HDR target (Rec.2020 PQ / HLG) keeps the HDR range (the output stage encodes it), as does conform off.
    let skips_tone_map = (!c.hdr_conform || target_is_hdr(c.target_space))
        && matches!(id, ColorSpaceID::HlgBT2020 | ColorSpaceID::PqBT2020);
    let uses_input_lut = c.log_mode == LogMode::CameraLUT;
    let conversion_lut = |r: Option<&LUTRef>| -> Option<Arc<CubeLut>> {
        match r? {
            r @ (LUTRef::File { .. } | LUTRef::Embedded { .. }) => provider?.lut(r),
            LUTRef::Automatic => {
                if c.use_embedded_lut
                    && media_info.is_some_and(|m| m.embedded_lut_name.is_some())
                    && id == ColorSpaceID::SLog3SGamut3Cine
                {
                    provider?.lut(&LUTRef::Embedded { media: media_id })
                } else {
                    None
                }
            }
        }
    };
    let mut ops: Vec<ColorOp> = Vec::new();
    if let Some(g) = &c.graph {
        let lut = if uses_input_lut { conversion_lut(g.input_lut.as_ref()) } else { None };
        ops.push(ColorOp::Conversion(lut));
        ops.extend(graph_ops(g, provider));
    } else {
        for (n, e) in c.effects().iter().enumerate() {
            effect_ops(e, n == 0, uses_input_lut, &conversion_lut, provider, &mut ops);
        }
    }
    let mut p = ColorPipeline::new(id, ops, ToneMapping::default());
    p.set_skips_tone_map(skips_tone_map);
    p
}

fn effect_ops(
    e: &ColorEffect,
    first: bool,
    uses_input_lut: bool,
    conversion_lut: &dyn Fn(Option<&LUTRef>) -> Option<Arc<CubeLut>>,
    provider: Option<&dyn LutProvider>,
    ops: &mut Vec<ColorOp>,
) {
    let basic_on = e.is_enabled(ColorSectionKind::BasicCorrection);
    if basic_on && !e.basic.is_neutral() {
        ops.push(ColorOp::Basic(e.basic));
    }
    if first {
        let lut = if basic_on && uses_input_lut { conversion_lut(e.input_lut.as_ref()) } else { None };
        ops.push(ColorOp::Conversion(lut));
    } else if basic_on
        && let Some(r) = e.input_lut.as_ref().filter(|r| **r != LUTRef::Automatic && e.input_lut_intensity > 0.0)
        && let Some(lut) = provider.and_then(|p| p.lut(r))
    {
        ops.push(ColorOp::Look(lut, e.input_lut_intensity.clamp(0.0, 100.0) / 100.0));
    }
    if e.is_enabled(ColorSectionKind::Creative) {
        // Saved grades with Shadow / Highlight tints still render exactly as before; `has_tone` skips the pass while both
        // tints are neutral.
        let k = &e.creative;
        if k.has_look()
            && let Some(lut) = k.look.as_ref().and_then(|r| provider.and_then(|p| p.lut(r)))
        {
            ops.push(ColorOp::Look(lut, k.intensity.clamp(0.0, 100.0) / 100.0));
        }
        if k.has_tone() {
            ops.push(ColorOp::Creative(k.clone()));
        }
    }
    if e.is_enabled(ColorSectionKind::Curves) && !e.curves.is_neutral() {
        ops.push(ColorOp::Curves(e.curves.clone()));
    }
    if e.is_enabled(ColorSectionKind::Curves) && !e.hue_curves.is_neutral() {
        ops.push(ColorOp::HueCurves(e.hue_curves.clone()));
    }
    if e.is_enabled(ColorSectionKind::Wheels) && !e.wheels.is_neutral() {
        ops.push(ColorOp::Wheels(e.wheels.clone()));
    }
    if e.is_enabled(ColorSectionKind::HslSecondary)
        && let Some(r) = e.hsl_secondary.as_ref().filter(|r| !r.is_correction_neutral())
    {
        ops.push(ColorOp::HslSecondary(r.clone()));
    }
    if e.is_enabled(ColorSectionKind::ZoneBoard)
        && let Some(z) = e.zone_board.as_ref().filter(|z| !z.is_neutral())
    {
        ops.push(ColorOp::ZoneBoard(*z));
    }
    if e.is_enabled(ColorSectionKind::Vignette) && !e.vignette.is_neutral() {
        ops.push(ColorOp::Vignette(e.vignette));
    }
}

fn look_op(r: Option<&LUTRef>, intensity: f32, provider: Option<&dyn LutProvider>, out: &mut Vec<ColorOp>) {
    let Some(r) = r.filter(|r| **r != LUTRef::Automatic && intensity > 0.0) else { return };
    if let Some(lut) = provider.and_then(|p| p.lut(r)) {
        out.push(ColorOp::Look(lut, intensity.min(100.0) / 100.0));
    }
}

fn step_body(s: &ColorStep, provider: Option<&dyn LutProvider>) -> Vec<ColorOp> {
    let mut out = Vec::new();
    if !s.primaries.is_neutral() {
        out.push(ColorOp::Primaries(s.primaries.clone()));
    }
    if !s.curves.is_neutral() {
        out.push(ColorOp::Curves(s.curves.clone()));
    }
    if !s.hue_curves.is_neutral() {
        out.push(ColorOp::HueCurves(s.hue_curves.clone()));
    }
    look_op(s.lut.as_ref(), s.lut_intensity, provider, &mut out);
    out
}

fn key_term(d: &ColorStep, mode: Option<KeyMixMode>) -> ColorOp {
    ColorOp::KeyTerm(KeyTerm { qualifier: d.qualifier.clone(), window: d.window.clone(), outside: d.key_outside, mode })
}

/// The Pro grade after its In LUT conversion (display signal): each enabled, non-neutral Step as primaries, curves, hue
/// curves, Step LUT (the LUT grades on top of the Step's balance), wrapped in a begin / end pair when a qualifier or
/// window limits it; then the Out LUT. A LUT that fails to load is treated as absent.
///
/// A column with Parallel or Layer Steps becomes one group (`GroupBegin`): its parallel branches (the serial Step too) are
/// averaged, the Layer Steps go over that average in order. A group lives in one GPU pass (24 blocks, one LUT, 3 curve
/// tables): a branch that would not fit is left out.
///
/// Key wires (`ColorGraph::key_links`): the key output of a donor Step (its qualifier and window, read inverted with
/// `key_outside`) limits the Step it feeds (one `KeyTerm` before the Step's end); the keys into a mixer box combine by the
/// stack head's `key_mix` and limit the whole stack (`KeyApply`). A Layer Step composites by its `layer_mix`.
pub fn graph_ops(g: &ColorGraph, provider: Option<&dyn LutProvider>) -> Vec<ColorOp> {
    let mut ops: Vec<ColorOp> = Vec::new();
    // The key wire into the key input of Step `s` (a Step's key input holds one wire).
    let step_key = |s: &ColorStep| -> Vec<ColorOp> {
        g.key_donors(GraphPort::Step(s.id)).iter().take(1).map(|d| key_term(d, None)).collect()
    };
    for column in g.columns() {
        let followers: Vec<&ColorStep> = column.iter().skip(1).filter(|s| s.enabled).collect();
        let parallels: Vec<&ColorStep> = std::iter::once(&column[0])
            .chain(followers.iter().copied().filter(|s| s.kind == StepKind::Parallel))
            .filter(|s| s.enabled)
            .collect();
        let layers: Vec<&ColorStep> =
            followers.iter().copied().filter(|s| s.kind == StepKind::Layer && !s.is_neutral() && s.mix > 0.0).collect();
        let mixer_keys: Vec<ColorOp> = if column.len() > 1 {
            g.key_donors(GraphPort::Mixer(column[0].id))
                .iter()
                .enumerate()
                .map(|(i, d)| key_term(d, if i == 0 { None } else { Some(column[0].key_mix) }))
                .collect()
        } else {
            Vec::new()
        };
        if layers.is_empty() && parallels.len() <= 1 && mixer_keys.is_empty() {
            if let Some(s) = parallels.first()
                && s.enabled
                && !s.is_neutral()
                && s.mix > 0.0
            {
                let key = step_key(s);
                let limited = s.qualifier.is_some() || s.window.is_some() || s.mix < 100.0 || !key.is_empty();
                if limited {
                    ops.push(ColorOp::StepBegin);
                }
                ops.extend(step_body(s, provider));
                ops.extend(key);
                if limited {
                    ops.push(ColorOp::StepEnd {
                        qualifier: s.qualifier.clone(),
                        window: s.window.clone(),
                        mix: s.mix / 100.0,
                    });
                }
            }
            continue;
        }
        // The capacity of the one pass the group lives in (group begin, merge and end take three blocks).
        let (mut sections, mut curves, mut luts) = (3usize, 0usize, 0usize);
        let mut plan = |steps: &[&ColorStep]| -> Vec<(ColorStep, Vec<ColorOp>)> {
            let mut out = Vec::new();
            for s in steps {
                let mut b = step_body(s, provider);
                b.extend(step_key(s));
                let (mut c, mut l) = (0, 0);
                for o in &b {
                    match o {
                        ColorOp::Curves(_) => c += 1,
                        ColorOp::HueCurves(_) => c += 2,
                        ColorOp::Look(..) => l += 1,
                        _ => {}
                    }
                }
                if sections + b.len() < MAX_GROUP_SECTIONS && curves + c <= MAX_CURVES && luts + l <= 1 {
                    sections += b.len() + 1;
                    curves += c;
                    luts += l;
                    out.push(((*s).clone(), b));
                }
            }
            out
        };
        let par = plan(&parallels);
        let lay = plan(&layers);
        let room = MAX_GROUP_SECTIONS.saturating_sub(sections + 1);
        ops.push(ColorOp::GroupBegin);
        let par_count = par.len();
        for (s, b) in par {
            ops.extend(b);
            ops.push(ColorOp::BranchEnd { layer: false, qualifier: s.qualifier, window: s.window, mix: s.mix / 100.0 });
        }
        ops.push(ColorOp::GroupMerge { count: par_count });
        for (s, b) in lay {
            ops.extend(b);
            if s.layer_mix != LayerMixMode::Normal {
                ops.push(ColorOp::LayerMix(s.layer_mix));
            }
            ops.push(ColorOp::BranchEnd { layer: true, qualifier: s.qualifier, window: s.window, mix: s.mix / 100.0 });
        }
        let keys: Vec<ColorOp> = mixer_keys.into_iter().take(room).collect();
        if !keys.is_empty() {
            ops.extend(keys);
            ops.push(ColorOp::KeyApply);
        }
        ops.push(ColorOp::GroupEnd);
    }
    look_op(g.output_lut.as_ref(), g.output_lut_intensity, provider, &mut ops);
    ops
}
