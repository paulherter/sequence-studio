// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/EffectChainPlan.swift (`configure`, `cutToMaskRect`, `cropVector`, `maskedGrade*`), Effects/FilmLookPlan.swift
// (`applyWeave`), Effects/MaskData.swift (`screenFromLocal`)
//! The writes the effect chain makes into the compositor's `CompositeU` block: per-segment masks and keys, the cut to the
//! mask rectangle, Gate Weave, the screen map of a final draw, and the clip color a masked Color effect is graded with.

use super::mask_data::{Placement, ScreenMap};
use crate::compositor::Uniforms;
use crate::effects::ultra_key;
use sq_core_color::GateWeave;
use sq_core_effects::effects_evaluation::{ChromaKey, CropInsets, EffectSegment};
use sq_core_model::{ClipColor, ColorEffect, ColorSpaceID};
use sq_core_time::Id;
use std::hash::{Hash, Hasher};

/// The media identity every masked Color effect's pipeline is keyed under (it has no media of its own).
pub const MASKED_GRADE_MEDIA: Id = Id::NIL;

/// The clip color a masked Color effect is graded with: Rec.709 in, the neutral first effect, then the effect.
pub fn masked_grade_color(grade: &ColorEffect) -> ClipColor {
    ClipColor::new(Some(ColorSpaceID::Rec709), false, vec![ColorEffect::new(0, None), grade.clone()])
}

/// The resolver's fallback slot: keyed by the LUTs the effect references (never by `ColorEffect::id`, which is only the
/// effect's index inside its clip), so a clip loading its LUT can never fall back to another clip's LUT.
pub fn masked_grade_owner(grade: &ColorEffect) -> Id {
    let hash = |salt: u64| {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        salt.hash(&mut h);
        grade.input_lut.hash(&mut h);
        grade.creative.look.hash(&mut h);
        h.finish()
    };
    Id::from_u128(u128::from(hash(0)) << 64 | u128::from(hash(1)))
}

/// Crop insets as the shader's (left, top, right, bottom).
pub fn crop_vector(c: &CropInsets) -> [f32; 4] {
    [c.left as f32, c.top as f32, c.right as f32, c.bottom as f32]
}

fn f4(v: crate::effects::simd::Float4) -> [f32; 4] {
    [v.x, v.y, v.z, v.w]
}

/// Writes one segment's masks and keys into the uniforms. `reduction` > 1: the pass draws at 1/reduction size.
/// `legacy_radius`: the layer's own `corner_radius`; when the segment says the same, the radius written by `prepare_layer`
/// stays as it is (bit-identical to before effects existed).
pub fn configure(
    u: &mut Uniforms,
    seg: &EffectSegment,
    radius_factor: f64,
    reduction: f32,
    legacy_radius: Option<f64>,
) {
    let m = &seg.masks;
    if !m.crop.is_identity() {
        u.crop = crop_vector(&m.crop);
    }
    u.round_first = u32::from(m.round_first && !m.crop.is_identity() && m.corner_radius > 0.0);
    u.crop_feather = m.feather.max(0.0) as f32 * radius_factor as f32 / reduction;
    if legacy_radius != Some(m.corner_radius) {
        u.corner_radius = m.corner_radius as f32 * radius_factor as f32 / reduction;
    }
    u.key_count = seg.keys.len().min(ChromaKey::MAX_PER_LAYER) as u32;
    if let Some(k) = seg.keys.first() {
        u.key0 = f4(ultra_key::vector(k));
        u.matte0 = f4(ultra_key::matte_vector(k));
        u.shape0 = f4(ultra_key::shape_vector(k));
        u.cc0 = f4(ultra_key::color_vector(k));
    }
    if let Some(k) = seg.keys.get(1) {
        u.key1 = f4(ultra_key::vector(k));
        u.matte1 = f4(ultra_key::matte_vector(k));
        u.shape1 = f4(ultra_key::shape_vector(k));
        u.cc1 = f4(ultra_key::color_vector(k));
    }
}

/// After a Repeat Edge Pixels blur the image holds the extended picture everywhere: the draw keeps only the clip's frame
/// (the mask rectangle), antialiased at full size. A crop or rounded corners of the pass already cut inside that frame; a
/// pass without them gets a vanishing crop so the shader's edge mask runs on the frame rectangle.
pub fn cut_to_mask_rect(u: &mut Uniforms) {
    if u.crop == [0.0; 4] && u.corner_radius == 0.0 {
        u.crop = [1e-6; 4];
    }
}

/// Gate Weave moves, turns and slightly enlarges the layer's final draw (canvas px; the offsets are 1080-line px).
pub fn apply_weave(weave: &GateWeave, u: &mut Uniforms) {
    let s = f64::from(u.canvas[1]) / 1080.0;
    u.position[0] += (weave.offset_x * s) as f32;
    u.position[1] += (weave.offset_y * s) as f32;
    let a = f64::from(u.rot_sin).atan2(f64::from(u.rot_cos)) + weave.rotation * std::f64::consts::PI / 180.0;
    u.rot_cos = a.cos() as f32;
    u.rot_sin = a.sin() as f32;
    // Overscan relative to the layer as it appears on the canvas.
    let w = f64::from(u.size[0] * u.scale[0]);
    let h = f64::from(u.size[1] * u.scale[1]);
    let k = weave.overscan(w, h, s) as f32;
    u.scale[0] *= k;
    u.scale[1] *= k;
}

/// The map of a final draw's uniforms, as `compositeVertex` places the layer.
pub fn screen_from_local(u: &Uniforms) -> ScreenMap {
    ScreenMap::from_placement(&Placement {
        canvas: u.canvas,
        position: u.position,
        anchor: u.anchor,
        scale: u.scale,
        rot_cos: u.rot_cos,
        rot_sin: u.rot_sin,
        tilt: u.tilt,
    })
}

/// `u` for a draw of an upright `w` x `h` image: no transform, full opacity, no masks.
pub fn upright(u: &Uniforms, w: u32, h: u32) -> Uniforms {
    let mut u1 = u.clone();
    u1.canvas = [w as f32, h as f32];
    u1.size = u1.canvas;
    u1.position = [0.0; 2];
    u1.anchor = [0.0; 2];
    u1.scale = [1.0, 1.0];
    u1.rot_cos = 1.0;
    u1.rot_sin = 0.0;
    u1.opacity = 1.0;
    u1.blend = 0;
    u1.tilt = [0.0; 3];
    u1.mask_count = 0;
    u1
}
