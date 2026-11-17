// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/MaskData.swift (the parts that need no compositor uniforms), GPUCompositor+Effects.swift (`maskScope`,
// `matteTexture` packing)
//! The clip-mask data of a draw (clip masks, subject mattes, Magic mattes, Picture masks, color range masks): the `float2`
//! entries the layer shaders read (`Parts/Mask.slang`), and the mask scope kernel that limits an effect to the masks.

use super::scratch::half;
use sq_core_masks::{MaskShape, SubjectMatte};
use sq_core_model::{MaskMode, MaskSource, MatteChannel};
use sq_core_time::Id;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::collections::HashMap;
use std::sync::Arc;

/// Most distinct mattes one draw reads (one texture's channels).
pub const MAX_MATTES: usize = 4;

/// The matte each mask reads and the distinct ones (at most 4: one texture's channels): `(distinct, slot)`, `slot` per mask
/// being an index into `distinct`, `None` = no matte. Mattes are the same when they share storage (same `Arc`ed values).
pub fn matte_slots<'a>(
    masks: &[MaskShape],
    matte: Option<&'a SubjectMatte>,
    mattes: &'a HashMap<Id, Arc<SubjectMatte>>,
) -> (Vec<&'a SubjectMatte>, Vec<Option<usize>>) {
    let mut distinct: Vec<&SubjectMatte> = Vec::new();
    let mut slots = Vec::with_capacity(masks.len());
    for m in masks {
        let source = match m.source {
            MaskSource::Subject => matte,
            MaskSource::Magic => m.matte_key.and_then(|k| mattes.get(&k)).map(|a| &**a),
            // Path masks have no matte; Picture masks read the level's matte images; color range reads the picture's pixel.
            MaskSource::Path | MaskSource::Picture | MaskSource::ColorRange => None,
        };
        let Some(x) = source else {
            slots.push(None);
            continue;
        };
        if let Some(i) = distinct.iter().position(|d| std::ptr::eq(*d, x)) {
            slots.push(Some(i));
        } else if distinct.len() < MAX_MATTES {
            distinct.push(x);
            slots.push(Some(distinct.len() - 1));
        } else {
            slots.push(None);
        }
    }
    (distinct, slots)
}

/// Where a draw's px (centered) land on the level's canvas: the affine map plus the perspective tilt.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScreenMap {
    pub row0: [f32; 2],
    pub row1: [f32; 2],
    pub translation: [f32; 2],
    pub canvas: [f32; 2],
    /// Perspective tilt of the draw (x / y radians, camera distance px; z = 0 flat). The affine part gives the pre-tilt place;
    /// the shader turns its offset from `center` through the tilt.
    pub tilt: [f32; 3],
    pub center: [f32; 2],
}

/// Where a draw sits on its canvas: the placement fields of the compositor's uniforms that `ScreenMap` is made from.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    pub canvas: [f32; 2],
    /// Offset from the canvas center, px, y down.
    pub position: [f32; 2],
    /// Offset from the layer center, px.
    pub anchor: [f32; 2],
    pub scale: [f32; 2],
    pub rot_cos: f32,
    pub rot_sin: f32,
    /// x / y radians, camera distance px (z = 0: flat).
    pub tilt: [f32; 3],
}

impl ScreenMap {
    /// The map of a final draw, as `compositeVertex` places the layer: canvas / 2 + position + R * S * (local - anchor).
    pub fn from_placement(p: &Placement) -> ScreenMap {
        let (c, s, sx, sy) = (p.rot_cos, p.rot_sin, p.scale[0], p.scale[1]);
        let row0 = [c * sx, -s * sy];
        let row1 = [s * sx, c * sy];
        let center = [p.canvas[0] * 0.5 + p.position[0], p.canvas[1] * 0.5 + p.position[1]];
        let translation = [
            center[0] - (row0[0] * p.anchor[0] + row0[1] * p.anchor[1]),
            center[1] - (row1[0] * p.anchor[0] + row1[1] * p.anchor[1]),
        ];
        ScreenMap { row0, row1, translation, canvas: p.canvas, tilt: p.tilt, center }
    }

    /// The same map for a pass whose px are `factor` layer px (effect passes at reduced size).
    pub fn scaled(&self, factor: f32) -> ScreenMap {
        ScreenMap {
            row0: [self.row0[0] * factor, self.row0[1] * factor],
            row1: [self.row1[0] * factor, self.row1[1] * factor],
            ..*self
        }
    }
}

/// The shader id of a mask mode.
pub fn mode_id(m: MaskMode) -> f32 {
    match m {
        MaskMode::Add => 0.0,
        MaskMode::Subtract => 1.0,
        MaskMode::Intersect => 2.0,
        MaskMode::Difference => 3.0,
    }
}

/// How `mask_entries` reads a draw: its frame and the matte / Picture inputs bound to it.
pub struct MaskInputs<'a> {
    /// The frame the polygons are fractions of, layer px.
    pub frame: [f32; 2],
    /// Pixel scale of feather and expansion (`1 / pf` for reduced-size passes).
    pub edge_scale: f32,
    /// Where the draw lands on the canvas (Picture masks need it).
    pub screen: Option<&'a ScreenMap>,
    /// Per mask: the Picture image (0, 1) it reads, `None` = none.
    pub picture_slot: &'a [Option<usize>],
    /// Per mask: the matte channel it reads (`matte_slots`).
    pub matte_slot: &'a [Option<usize>],
    /// The matte texture is bound.
    pub has_matte: bool,
}

/// The mask data entries. Layout (float2 entries): per mask (start, count), (mode, inverted), (feather, expansion), (opacity,
/// source); then all polygons' points (centered px of the frame).
pub fn mask_entries(masks: &[MaskShape], inputs: &MaskInputs<'_>) -> Vec<[f32; 2]> {
    const CHANNEL_FLAG: [f32; 4] = [1.0, 3.0, 4.0, 5.0];
    let mut header: Vec<[f32; 2]> = Vec::with_capacity(masks.len() * 4);
    let mut points: Vec<[f32; 2]> = Vec::new();
    let base = masks.len() * 4;
    for (k, m) in masks.iter().enumerate() {
        let start = base + points.len();
        match m.source {
            MaskSource::ColorRange => {
                let c = &m.color_range;
                points.extend([
                    [c.red as f32, c.green as f32],
                    [c.blue as f32, c.tolerance as f32],
                    [c.softness as f32, 0.0],
                ]);
            }
            MaskSource::Picture => {
                if let (Some(_), Some(s)) = (inputs.picture_slot[k], inputs.screen) {
                    points.extend([
                        s.row0,
                        s.row1,
                        s.translation,
                        [1.0 / s.canvas[0].max(1.0), 1.0 / s.canvas[1].max(1.0)],
                        s.center,
                        [s.tilt[0], s.tilt[1]],
                        [s.tilt[2], 0.0],
                    ]);
                }
            }
            _ => {
                let f = inputs.frame;
                points
                    .extend(m.polygon.iter().map(|v| [v.x as f32 * f[0] - f[0] * 0.5, v.y as f32 * f[1] - f[1] * 0.5]));
            }
        }
        let flat = matches!(m.source, MaskSource::Picture | MaskSource::ColorRange);
        header.push([start as f32, if flat { 0.0 } else { m.polygon.len() as f32 }]);
        header.push([mode_id(m.mode), if m.inverted { 1.0 } else { 0.0 }]);
        // Mattes come with their edge already applied (subject: shader-free; Magic: the matte store).
        header.push([m.feather.max(0.0) as f32 * inputs.edge_scale, m.expansion as f32 * inputs.edge_scale]);
        let flag = match m.source {
            MaskSource::ColorRange => 10.0,
            MaskSource::Picture => match inputs.picture_slot[k] {
                Some(p) => (6 + 2 * p + usize::from(m.picture_channel == MatteChannel::Brightness)) as f32,
                None => 2.0,
            },
            MaskSource::Path => 0.0,
            _ => match inputs.matte_slot[k] {
                Some(s) if inputs.has_matte => CHANNEL_FLAG[s],
                _ => 2.0,
            },
        };
        header.push([m.opacity.clamp(0.0, 1.0) as f32, flag]);
    }
    header.extend(points);
    header
}

/// A matte with no value reaching one 8-bit step.
pub fn is_blank(m: &SubjectMatte) -> bool {
    let top = m.values.iter().copied().fold(0.0f32, f32::max);
    top < 0.5 / 255.0
}

/// `MaskCoverage.opacityMasks`: a Magic mask without its matte, or with a blank one, is left out.
pub fn opacity_masks(masks: &[MaskShape], mattes: &HashMap<Id, Arc<SubjectMatte>>) -> Vec<MaskShape> {
    masks
        .iter()
        .filter(|m| {
            m.source != MaskSource::Magic || m.matte_key.and_then(|k| mattes.get(&k)).is_some_and(|x| !is_blank(x))
        })
        .cloned()
        .collect()
}

/// Up to 4 mattes in the r/g/b/a channels of one `Rgba16Float` image at the largest one's size (one matte: r only): the size
/// and the half-float texels. Smaller mattes are resampled bilinearly to that size.
pub fn pack_mattes(mattes: &[&SubjectMatte]) -> Option<(usize, usize, Vec<u16>)> {
    let big = mattes.iter().max_by_key(|m| m.width() * m.height())?;
    let (w, h) = (big.width(), big.height());
    let mut px = vec![0u16; w * h * 4];
    for (c, m) in mattes.iter().take(MAX_MATTES).enumerate() {
        for y in 0..h {
            for x in 0..w {
                let v = if m.width() == w && m.height() == h {
                    m.values[y * w + x]
                } else {
                    sample(m, (x as f32 + 0.5) / w as f32, (y as f32 + 0.5) / h as f32)
                };
                px[(y * w + x) * 4 + c] = half(v);
            }
        }
    }
    Some((w, h, px))
}

/// Bilinear value of `m` at the frame fractions `(u, v)`.
fn sample(m: &SubjectMatte, u: f32, v: f32) -> f32 {
    let (w, h) = (m.width() as i64, m.height() as i64);
    let (fx, fy) = (u * w as f32 - 0.5, v * h as f32 - 0.5);
    let (x0, y0) = (fx.floor(), fy.floor());
    let (tx, ty) = (fx - x0, fy - y0);
    let at = |x: f32, y: f32| {
        m.values[(y as i64).clamp(0, h - 1) as usize * w as usize + (x as i64).clamp(0, w - 1) as usize]
    };
    let top = at(x0, y0) * (1.0 - tx) + at(x0 + 1.0, y0) * tx;
    let bottom = at(x0, y0 + 1.0) * (1.0 - tx) + at(x0 + 1.0, y0 + 1.0) * tx;
    top * (1.0 - ty) + bottom * ty
}

/// The textures `mask_scope` reads besides the two images.
#[derive(Default)]
pub struct MaskTextures<'a> {
    /// The packed mattes (`pack_mattes`).
    pub matte: Option<&'a GpuTexture>,
    /// The Picture mask images (0, 1).
    pub pictures: [Option<&'a GpuTexture>; 2],
}

#[allow(clippy::too_many_arguments)]
/// `Compositor.encodeMaskScope`: `out` = `pre` where the masks do not cover, `post` where they do. `composite` is the
/// `CompositeU` block (size, maskSize and scale set to the pass's frame), `mask_data` the entries of `mask_entries`.
pub fn mask_scope(
    gpu: &Gpu,
    cmds: &mut GpuCommands,
    composite: &[u8],
    mask_data: &wgpu::Buffer,
    textures: &MaskTextures<'_>,
    pre: &GpuTexture,
    post: &GpuTexture,
    out: &GpuTexture,
) -> Result<(), GpuError> {
    let mut enc = cmds.compute();
    enc.set_pipeline(&gpu.compute_pipeline("MaskScope", "maskScopeMix", PixelFormat::Rgba16Float)?);
    enc.set_input(pre, 0)?;
    enc.set_input(post, 1)?;
    for (slot, texture) in [(3, textures.matte), (4, textures.pictures[0]), (5, textures.pictures[1])] {
        if let Some(t) = texture {
            enc.set_input(t, slot)?;
        }
    }
    enc.set_output(out);
    enc.set_constants(composite, 0)?;
    enc.set_buffer(mask_data, 2)?;
    enc.dispatch(out.width(), out.height())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Vec2;

    fn square() -> MaskShape {
        MaskShape::new(vec![Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.25), Vec2::new(0.75, 0.75), Vec2::new(0.25, 0.75)])
    }

    fn inputs<'a>(slot: &'a [Option<usize>], matte: &'a [Option<usize>]) -> MaskInputs<'a> {
        MaskInputs {
            frame: [100.0, 50.0],
            edge_scale: 0.5,
            screen: None,
            picture_slot: slot,
            matte_slot: matte,
            has_matte: false,
        }
    }

    #[test]
    fn a_path_mask_has_a_header_and_centered_points() {
        let mut m = square();
        m.feather = 4.0;
        m.expansion = -2.0;
        m.opacity = 0.5;
        m.inverted = true;
        m.mode = MaskMode::Subtract;
        let e = mask_entries(&[m], &inputs(&[None], &[None]));
        assert_eq!(e.len(), 4 + 4);
        assert_eq!(e[0], [4.0, 4.0]); // points start after the header, 4 vertices
        assert_eq!(e[1], [1.0, 1.0]);
        assert_eq!(e[2], [2.0, -1.0]); // feather and expansion at half scale
        assert_eq!(e[3], [0.5, 0.0]);
        assert_eq!(e[4], [-25.0, -12.5]);
        assert_eq!(e[6], [25.0, 12.5]);
    }

    #[test]
    fn a_subject_mask_without_its_bound_matte_stays_uncovered_flag_two() {
        let mut m = square();
        m.source = MaskSource::Subject;
        assert_eq!(mask_entries(&[m.clone()], &inputs(&[None], &[Some(1)]))[3][1], 2.0);
        let with = MaskInputs { has_matte: true, ..inputs(&[None], &[Some(1)]) };
        assert_eq!(mask_entries(&[m], &with)[3][1], 3.0);
    }

    #[test]
    fn mattes_are_distinct_by_storage_and_capped_at_four() {
        let a = SubjectMatte::new(2, 2, vec![1.0; 4]);
        let mut m = square();
        m.source = MaskSource::Subject;
        let none = HashMap::new();
        let (distinct, slots) = matte_slots(&[m.clone(), m.clone()], Some(&a), &none);
        assert_eq!((distinct.len(), slots), (1, vec![Some(0), Some(0)]));
        let (unused, slots) = matte_slots(&[square()], Some(&a), &none);
        assert_eq!((unused.len(), slots), (0, vec![None]));
    }

    #[test]
    fn blank_magic_mattes_leave_their_mask_out() {
        let key = Id::from_u128(7);
        let mut m = square();
        m.source = MaskSource::Magic;
        m.matte_key = Some(key);
        let blank = HashMap::from([(key, Arc::new(SubjectMatte::new(2, 2, vec![0.0; 4])))]);
        let filled = HashMap::from([(key, Arc::new(SubjectMatte::new(2, 2, vec![0.0, 0.0, 0.0, 1.0])))]);
        assert!(opacity_masks(&[m.clone()], &blank).is_empty());
        assert!(opacity_masks(&[m.clone()], &HashMap::new()).is_empty());
        assert_eq!(opacity_masks(&[m, square()], &filled).len(), 2);
    }

    #[test]
    fn packing_puts_each_matte_in_its_channel_at_the_largest_size() {
        let big = SubjectMatte::new(4, 4, vec![1.0; 16]);
        let small = SubjectMatte::new(2, 2, vec![0.5; 4]);
        let (w, h, px) = pack_mattes(&[&big, &small]).unwrap_or_default();
        assert_eq!((w, h), (4, 4));
        assert_eq!((px[0], px[1], px[2]), (half(1.0), half(0.5), 0));
    }
}
