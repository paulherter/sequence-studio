// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/StyleFilters.swift
//! FB-T2 style filters (Vignette, Film Grain, RGB Split, Radial Blur, Flip, Invert, Posterize, Tint, Brightness & Contrast,
//! Twirl, Wave Warp, Spherize, Strobe Light, Alpha Adjust and the rest of the kernel families). Four kernel families:
//! per-pixel color ops, warps (one bilinear tap at a moved position), RGB Split and Radial Blur (plus Lens and Glitch).
//! `plan` turns a filter into one family plus uniforms; the CPU references below read the same uniforms with the same maths,
//! so preview, export and reference agree. Color ops run on display-encoded (BT.709 OETF), un-premultiplied values.
//! The MSL text of the kernels is not here (the Slang kernels replace it, see NOTES-effects.md).

use super::image_filters::FilterUniforms as U;
use super::image_filters::{Frame, Image, hash01};
use super::simd::{Float2, Float3, Float4, Int4, SWIFT_FLOAT_PI as PI};
use sq_core_effects::effects_evaluation::ImageFilter;
use sq_core_masks::StabilizerEdgeFill;
use sq_core_time::Vec2;

/// Which kernel family runs a style filter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    /// Per-pixel color op.
    Pixel,
    /// One bilinear tap at a moved position.
    Warp,
    /// RGB Split.
    RgbSplit,
    /// Radial Blur.
    RadialBlur,
    /// Lens Distortion.
    Lens,
    /// Glitch Displace.
    Glitch,
}

// Op codes (uniform i.w) of the pixel and warp families; mirrored in the kernels.
const OP_VIGNETTE: i32 = 1;
const OP_INVERT: i32 = 3;
const OP_POSTERIZE: i32 = 4;
const OP_TINT: i32 = 5;
const OP_BRIGHTNESS: i32 = 6;
const OP_STROBE: i32 = 7;
const OP_ALPHA: i32 = 8;
const OP_LEAK: i32 = 9;
const OP_GRADIENT: i32 = 10;
const OP_FLIP: i32 = 20;
const OP_TWIRL: i32 = 21;
const OP_WAVE: i32 = 22;
const OP_SPHERIZE: i32 = 23;
const OP_STAGE: i32 = 24;
const OP_HALFTONE: i32 = 11;
const OP_TILE: i32 = 25;
const OP_KALEIDO: i32 = 26;
const OP_FEATHER: i32 = 12;
const OP_ROLLING: i32 = 27;
const OP_CORNER: i32 = 28;
const OP_STAGE_FILL: i32 = 29;

const FAR: Float2 = Float2::new(-1e6, -1e6);
const LUMA_WEIGHTS: Float3 = Float3::new(0.2126, 0.7152, 0.0722);
const HALF: Float2 = Float2::new(0.5, 0.5);
const ONE3: Float3 = Float3::new(1.0, 1.0, 1.0);

/// Taps of a Radial Blur: about one per px of the longest smear (half at Low quality), 2...256.
fn radial_taps(smear: f32, high: bool) -> i32 {
    256.min(2.max((smear * if high { 1.0 } else { 0.5 }).ceil() as i64 + 1)) as i32
}

fn f3(v: [f64; 3]) -> Float3 {
    Float3::from_f64(v)
}

fn flag(b: bool) -> i32 {
    i32::from(b)
}

/// The family and uniforms for `f` on a picture `frame` (texture px) where one texture px is `pf` clip px; `None` for a filter
/// that is not a style filter.
pub fn plan(f: &ImageFilter, frame: &Frame, pf: f64) -> Option<(Family, U)> {
    use ImageFilter as F;
    let mut u = U::new(frame.center, frame.size);
    let p = pf as f32;
    let tex = |v: &Vec2| frame.center + Float2::new(v.x as f32, v.y as f32) / p;
    // Longest distance from `c` to a corner of the picture.
    let reach = |c: Float2| {
        let o = frame.origin();
        let e = o + frame.size;
        [o, Float2::new(e.x, o.y), Float2::new(o.x, e.y), e].iter().map(|k| (*k - c).length()).fold(0.0f32, f32::max)
    };
    match f {
        F::Vignette { amount, midpoint, roundness, feather } => {
            u.a = Float4::new(*amount as f32, *midpoint as f32, *roundness as f32, *feather as f32);
            u.i.w = OP_VIGNETTE;
            Some((Family::Pixel, u))
        }
        F::Invert { channel, blend } => {
            u.a.x = *blend as f32;
            u.i.x = *channel as i32;
            u.i.w = OP_INVERT;
            Some((Family::Pixel, u))
        }
        F::Posterize { levels } => {
            u.a.x = (*levels).max(2) as f32;
            u.i.w = OP_POSTERIZE;
            Some((Family::Pixel, u))
        }
        F::Tint { black, white, amount } => {
            let (b, w) = (f3(*black), f3(*white));
            u.a = Float4::new(b.x, b.y, b.z, *amount as f32);
            u.b = Float4::new(w.x, w.y, w.z, 0.0);
            u.i.w = OP_TINT;
            Some((Family::Pixel, u))
        }
        F::BrightnessContrast { brightness, contrast } => {
            let slope = ((contrast.min(1.0) * 0.98 + 1.0) * std::f64::consts::PI / 4.0).tan() as f32;
            u.a = Float4::new(*brightness as f32, slope, 0.0, 0.0);
            u.i.w = OP_BRIGHTNESS;
            Some((Family::Pixel, u))
        }
        F::Strobe { color, blend, op, transparent } => {
            let c = f3(*color);
            u.a = Float4::new(c.x, c.y, c.z, *blend as f32);
            u.i.x = *op as i32;
            u.i.y = flag(*transparent);
            u.i.w = OP_STROBE;
            Some((Family::Pixel, u))
        }
        F::AlphaAdjust { opacity, ignore, invert, mask_only } => {
            u.a.x = *opacity as f32;
            u.i = Int4::new(flag(*ignore), flag(*invert), flag(*mask_only), OP_ALPHA);
            Some((Family::Pixel, u))
        }
        F::Flip { horizontal, vertical } => {
            u.i = Int4::new(flag(*horizontal), flag(*vertical), 0, OP_FLIP);
            Some((Family::Warp, u))
        }
        F::Twirl { center, angle, radius } => {
            u.center = tex(center);
            u.a = Float4::new(
                (*angle * std::f64::consts::PI / 180.0) as f32,
                *radius as f32 * frame.size.x.max(frame.size.y),
                0.0,
                0.0,
            );
            u.i.w = OP_TWIRL;
            Some((Family::Warp, u))
        }
        F::WaveWarp { wave_type, height, width, direction, phase, pinning } => {
            let a = direction * std::f64::consts::PI / 180.0;
            u.a = Float4::new(*height as f32 / p, (*width).max(1e-3) as f32 / p, a.sin() as f32, (-a.cos()) as f32);
            u.b.x = *phase as f32;
            u.i = Int4::new(*wave_type as i32, *pinning as i32, 0, OP_WAVE);
            Some((Family::Warp, u))
        }
        F::Spherize { center, radius, strength } => {
            u.center = tex(center);
            u.a = Float4::new(*radius as f32 / p, *strength as f32, 0.0, 0.0);
            u.i.w = OP_SPHERIZE;
            Some((Family::Warp, u))
        }
        F::StageWarp { a, b, c, d, tx, ty, opacity } => {
            // Masked Transform: source = center + M (q - center) + t / pf, times opacity (b.z).
            u.a = Float4::new(*a as f32, *b as f32, *c as f32, *d as f32);
            u.b = Float4::new(*tx as f32 / p, *ty as f32 / p, *opacity as f32, 0.0);
            u.i.w = OP_STAGE;
            Some((Family::Warp, u))
        }
        F::StageFill { a, b, c, d, tx, ty, fill } => {
            // The Stabilizer's correction with a filled border: OP_STAGE's map, then a read outside the clip's frame is folded
            // back over its edge (i.x = 1 mirror, 2 mirror and blur wide).
            u.a = Float4::new(*a as f32, *b as f32, *c as f32, *d as f32);
            u.b = Float4::new(*tx as f32 / p, *ty as f32 / p, 1.0, 0.0);
            u.i = Int4::new(if *fill == StabilizerEdgeFill::Blur { 2 } else { 1 }, 0, 0, OP_STAGE_FILL);
            Some((Family::Warp, u))
        }
        F::RollingShutter { shear, along_x } => {
            // Rows shifted back: a.xy = the shear in texture px across the scan extent (a.z), i.x = scan along x.
            let extent = if *along_x { frame.size.x } else { frame.size.y };
            u.a = Float4::new(shear.x as f32 * extent, shear.y as f32 * extent, extent, 0.0);
            u.i = Int4::new(flag(*along_x), 0, 0, OP_ROLLING);
            Some((Family::Warp, u))
        }
        F::StabilizeWarp { shear, along_x, perspective } => {
            // The Rolling Shutter warp, with the residual perspective read first: c, d = the inverse of (I + perspective) in
            // texture px about the frame center (m00 m01 m02 m10 | m11 m12 m20 m21, m22 = 1), i.y = 1. A singular map leaves
            // the perspective out.
            let extent = if *along_x { frame.size.x } else { frame.size.y };
            u.a = Float4::new(shear.x as f32 * extent, shear.y as f32 * extent, extent, 0.0);
            u.i = Int4::new(flag(*along_x), 0, 0, OP_ROLLING);
            if let Some(m) = perspective_inverse(perspective, pf) {
                u.c = Float4::new(m[0] as f32, m[1] as f32, m[2] as f32, m[3] as f32);
                u.d = Float4::new(m[4] as f32, m[5] as f32, m[6] as f32, m[7] as f32);
                u.i.y = 1;
            }
            Some((Family::Warp, u))
        }
        F::CornerPin { top_left, top_right, bottom_right, bottom_left } => {
            // Inverse homography (output -> picture) about the frame center, h33 = 1: a = (h11, h12, h13, h21),
            // b = (h22, h23, h31, h32). i.x = 1: the quadrilateral is degenerate, the result is empty.
            let hw = f64::from(frame.size.x) / 2.0;
            let hh = f64::from(frame.size.y) / 2.0;
            let k = 1.0 / pf;
            let src = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]];
            let moved = [top_left, top_right, bottom_right, bottom_left];
            let dst: Vec<[f64; 2]> = src.iter().zip(moved).map(|(s, m)| [s[0] + m.x * k, s[1] + m.y * k]).collect();
            if let Some(h) = homography(&dst, &src) {
                u.a = Float4::new(h[0] as f32, h[1] as f32, h[2] as f32, h[3] as f32);
                u.b = Float4::new(h[4] as f32, h[5] as f32, h[6] as f32, h[7] as f32);
            } else {
                u.i.x = 1;
            }
            u.i.w = OP_CORNER;
            Some((Family::Warp, u))
        }
        F::RgbSplit { dx, dy, radial, mix } => {
            u.a = Float4::new(*dx as f32 / p, *dy as f32 / p, *mix as f32, frame.size.length() / 2.0);
            u.i.x = flag(*radial);
            Some((Family::RgbSplit, u))
        }
        F::RadialBlur { center, amount, zoom, high } => {
            u.center = tex(center);
            let r = reach(u.center);
            let smear =
                if *zoom { (*amount / 100.0) as f32 * r } else { (*amount * std::f64::consts::PI / 180.0) as f32 * r };
            u.a.x = if *zoom { (*amount / 100.0) as f32 } else { (*amount * std::f64::consts::PI / 180.0) as f32 };
            u.i = Int4::new(flag(*zoom), radial_taps(smear, *high), 0, 0);
            Some((Family::RadialBlur, u))
        }
        F::LensDistortion { curvature, decenter, fill_alpha, fill, auto_scale, exact_model } => {
            // a = (k, half diagonal px, frame origin); b = fill (premultiplied working-linear, opaque) or zero = transparent;
            // i.x = the zoom about the lens center (f32 bits; 1 unless Auto Scale), i.z = 1: the exact model (F7.15), 0: the
            // look of effects saved before it. Auto Scale needs the exact model.
            let exact = *exact_model || *auto_scale;
            u.center = frame.center + Float2::new(decenter.x as f32, decenter.y as f32) * frame.size / 2.0;
            let o = frame.origin();
            u.a = Float4::new((-curvature * 0.6) as f32, frame.size.length() / 2.0, o.x, o.y);
            if !*fill_alpha {
                u.b = Float4::new(dec(fill[0] as f32), dec(fill[1] as f32), dec(fill[2] as f32), 1.0);
            }
            let zoom = if *auto_scale { lens_auto_zoom(&u) } else { 1.0 };
            u.i.x = zoom.to_bits() as i32;
            u.i.y = flag(*auto_scale);
            u.i.z = flag(exact);
            Some((Family::Lens, u))
        }
        F::Halftone { size, angle, softness, color, blend } => {
            // center = frame center (the screen turns around it), a = (pitch px, angle rad, softness, blend), i.x = color mode.
            u.a = Float4::new(
                (*size).max(0.5) as f32 / p,
                (*angle * std::f64::consts::PI / 180.0) as f32,
                *softness as f32,
                *blend as f32,
            );
            u.i.x = flag(*color);
            u.i.w = OP_HALFTONE;
            Some((Family::Pixel, u))
        }
        F::Tile { columns, rows, offset, mirror } => {
            u.a = Float4::new(*columns as f32, *rows as f32, offset.x as f32, offset.y as f32);
            u.b.x = if *mirror { 1.0 } else { 0.0 };
            u.i.w = OP_TILE;
            Some((Family::Warp, u))
        }
        F::Kaleidoscope { center, segments, angle, zoom } => {
            u.center = tex(center);
            u.a = Float4::new(
                (2.0 * std::f64::consts::PI / (*segments).max(2) as f64) as f32,
                (*angle * std::f64::consts::PI / 180.0) as f32,
                (1.0 / zoom.max(0.01)) as f32,
                0.0,
            );
            u.i.w = OP_KALEIDO;
            Some((Family::Warp, u))
        }
        F::EdgeFeather { amount } => {
            // center + frame give the picture's rectangle; a.x = feather width in texture px.
            u.a.x = (*amount).max(0.001) as f32 / p;
            u.i.w = OP_FEATHER;
            Some((Family::Pixel, u))
        }
        F::Glitch { amount, block, split, density, seed } => {
            // a = (max shift px, band height px, chroma split px, density), i.x = seed.
            u.a = Float4::new(*amount as f32 / p, (*block).max(1.0) as f32 / p, *split as f32 / p, *density as f32);
            u.i.x = *seed as i32;
            Some((Family::Glitch, u))
        }
        F::LightLeak { color1, color2, intensity, center, size, angle } => {
            // center = the leak's center px, frame = gradient direction, a = (color 1, intensity), b = (color 2, radius px).
            u.center = frame.center + Float2::new(center.x as f32, center.y as f32) * frame.size / 2.0;
            u.frame = Float2::new(angle.cos() as f32, angle.sin() as f32);
            let (c1, c2) = (f3(*color1), f3(*color2));
            u.a = Float4::new(c1.x, c1.y, c1.z, *intensity as f32);
            u.b = Float4::new(c2.x, c2.y, c2.z, (*size as f32 * frame.size.length()).max(1e-3));
            u.i.w = OP_LEAK;
            Some((Family::Pixel, u))
        }
        F::Gradient { color1, color2, start, end, radial, blend } => {
            // center = start px, frame = (end - start) px, a = (color 1, blend), b = (color 2, 0), i.x = radial.
            u.center = tex(start);
            u.frame = Float2::new((end.x - start.x) as f32, (end.y - start.y) as f32) / p;
            let (c1, c2) = (f3(*color1), f3(*color2));
            u.a = Float4::new(c1.x, c1.y, c1.z, *blend as f32);
            u.b = Float4::new(c2.x, c2.y, c2.z, 0.0);
            u.i.x = flag(*radial);
            u.i.w = OP_GRADIENT;
            Some((Family::Pixel, u))
        }
        _ => None,
    }
}

// MARK: Shared maths (mirrored line by line in the kernels)

/// The 3 x 3 projective map (h33 = 1, returned as h11 h12 h13 h21 h22 h23 h31 h32) that takes each `from[i]` to `to[i]`;
/// `None` when the four points are degenerate (collinear or collapsed).
pub fn homography(from: &[[f64; 2]], to: &[[f64; 2]]) -> Option<[f64; 8]> {
    let mut m = [[0.0f64; 9]; 8];
    for i in 0..4 {
        let (x, y) = (from[i][0], from[i][1]);
        let (xx, yy) = (to[i][0], to[i][1]);
        m[2 * i] = [x, y, 1.0, 0.0, 0.0, 0.0, -x * xx, -y * xx, xx];
        m[2 * i + 1] = [0.0, 0.0, 0.0, x, y, 1.0, -x * yy, -y * yy, yy];
    }
    for c in 0..8 {
        let mut piv = c;
        for r in c..8 {
            if m[r][c].abs() > m[piv][c].abs() {
                piv = r;
            }
        }
        if !(m[piv][c].abs() > 1e-9) {
            return None;
        }
        m.swap(c, piv);
        for r in 0..8 {
            if r != c {
                let f = m[r][c] / m[c][c];
                if f != 0.0 {
                    let pivot_row = m[c];
                    for (v, p) in m[r][c..].iter_mut().zip(&pivot_row[c..]) {
                        *v -= f * p;
                    }
                }
            }
        }
    }
    let mut h = [0.0; 8];
    for (i, v) in h.iter_mut().enumerate() {
        *v = m[i][8] / m[i][i];
    }
    Some(h)
}

/// The inverse of the map (I + `v`) of a Stabilizer perspective correction (clip px about the center) in texture px (`pf` clip
/// px per texture px), scaled so m22 = 1; `None` when singular. Row-major without m22.
pub fn perspective_inverse(v: &[f64], pf: f64) -> Option<[f64; 8]> {
    if v.len() != 8 || !v.iter().any(|x| *x != 0.0) {
        return None;
    }
    let a = [1.0 + v[0], v[1], v[2], v[3], 1.0 + v[4], v[5], v[6], v[7], 1.0];
    let c0 = a[4] * a[8] - a[5] * a[7];
    let c1 = a[5] * a[6] - a[3] * a[8];
    let c2 = a[3] * a[7] - a[4] * a[6];
    let det = a[0] * c0 + a[1] * c1 + a[2] * c2;
    if !(det.abs() > 1e-12) {
        return None;
    }
    let inv = [
        c0,
        a[2] * a[7] - a[1] * a[8],
        a[1] * a[5] - a[2] * a[4],
        c1,
        a[0] * a[8] - a[2] * a[6],
        a[2] * a[3] - a[0] * a[5],
        c2,
        a[1] * a[6] - a[0] * a[7],
        a[0] * a[4] - a[1] * a[3],
    ]
    .map(|x| x / det);
    // Conjugate with the clip <- texture scale diag(pf, pf, 1): the shifts shrink, the perspective terms grow.
    let mut m = [inv[0], inv[1], inv[2] / pf, inv[3], inv[4], inv[5] / pf, inv[6] * pf, inv[7] * pf, inv[8]];
    if !(m[8].abs() > 1e-12) {
        return None;
    }
    let d = m[8];
    m = m.map(|x| x / d);
    if m.iter().all(|x| x.is_finite()) { Some([m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]]) } else { None }
}

/// Corner Warp: where the picture is read from at `q`; far outside (transparent) behind the vanishing line or when the
/// quadrilateral is degenerate.
pub fn corner_source(q: Float2, u: &U) -> Float2 {
    if u.i.x != 0 {
        return FAR;
    }
    let d = q - u.center;
    let den = u.b.z * d.x + u.b.w * d.y + 1.0;
    if !(den > 1e-6) {
        return FAR;
    }
    u.center + Float2::new((u.a.x * d.x + u.a.y * d.y + u.a.z) / den, (u.a.w * d.x + u.b.x * d.y + u.b.y) / den)
}

/// BT.709 OETF of a linear value.
pub fn enc(x: f32) -> f32 {
    let v = x.max(0.0);
    if v < 0.018053968 { v * 4.5 } else { 1.099_296_8 * v.powf(0.45) - 0.099_296_82 }
}

/// Inverse of `enc`.
pub fn dec(e: f32) -> f32 {
    let v = e.max(0.0);
    if v < 0.081_242_86 { v / 4.5 } else { ((v + 0.099_296_82) / 1.099_296_8).powf(1.0 / 0.45) }
}

fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Vignette falloff 0 (center) ... 1 (edge) at texture position `q`.
pub fn vignette_falloff(q: Float2, u: &U) -> f32 {
    let d = q - u.center;
    let e = d / (u.frame * 0.5);
    let circle = d / ((u.frame.x * u.frame.y).sqrt() * 0.5);
    let r = if u.a.z >= 0.0 {
        (e + (circle - e) * u.a.z).length()
    } else {
        let n = 2.0 + 8.0 * -u.a.z;
        (e.x.abs().powf(n) + e.y.abs().powf(n)).powf(1.0 / n)
    };
    let m = 0.35 + 0.9 * u.a.y;
    let w = 0.05 + 0.6 * u.a.w;
    smoothstep(m - w, m + w, r)
}

/// Per-pixel family: `p` premultiplied working-linear at texture position `q`.
pub fn pixel(p: Float4, q: Float2, u: &U) -> Float4 {
    let op = u.i.w;
    if op == OP_VIGNETTE && u.a.x < 0.0 {
        let k = (u.a.x * vignette_falloff(q, u)).exp2();
        return Float4::new(p.x * k, p.y * k, p.z * k, p.w);
    }
    if op == OP_FEATHER {
        let o = u.center - u.frame * 0.5;
        let d = (q.x - o.x).min(o.x + u.frame.x - q.x).min((q.y - o.y).min(o.y + u.frame.y - q.y));
        return p * smoothstep(0.0, u.a.x, d.max(0.0));
    }
    if op == OP_ALPHA {
        let c = if p.w > 0.0 { p.xyz() / p.w } else { Float3::ZERO };
        let mut a = if u.i.x != 0 { 1.0 } else { p.w };
        if u.i.y != 0 {
            a = 1.0 - a;
        }
        a *= u.a.x;
        let col = if u.i.z != 0 { ONE3 } else { c };
        let o = col * a;
        return Float4::new(o.x, o.y, o.z, a);
    }
    if op == OP_STROBE && u.i.y != 0 {
        return p * u.a.w;
    }
    if op == OP_INVERT && u.i.x == 4 {
        let a = p.w + ((1.0 - p.w) - p.w) * (1.0 - u.a.x);
        let c = if p.w > 0.0 { p.xyz() / p.w } else { Float3::ZERO };
        let o = c * a;
        return Float4::new(o.x, o.y, o.z, a);
    }
    if !(p.w > 0.0) {
        return p;
    }
    let lin = p.xyz() / p.w;
    let e = Float3::new(enc(lin.x), enc(lin.y), enc(lin.z));

    let o: Float3 = match op {
        OP_VIGNETTE => {
            let f = vignette_falloff(q, u);
            let k = (-u.a.x * f).exp2();
            (ONE3 - (ONE3 - e.min(Float3::splat(1.0))) * k).max(e)
        }
        OP_INVERT => {
            let mut inv = e;
            let ce = e.clamp(Float3::splat(0.0), Float3::splat(1.0));
            if u.i.x == 0 {
                inv = ONE3 - ce;
            } else {
                let ch = (u.i.x - 1) as usize;
                inv.set(ch, 1.0 - ce[ch]);
            }
            inv + (e - inv) * u.a.x
        }
        OP_POSTERIZE => {
            let l = u.a.x - 1.0;
            let ce = e.clamp(Float3::splat(0.0), Float3::splat(1.0));
            Float3::new((ce.x * l).round(), (ce.y * l).round(), (ce.z * l).round()) / l
        }
        OP_TINT => {
            let y = e.dot(LUMA_WEIGHTS).clamp(0.0, 1.0);
            let black = Float3::new(u.a.x, u.a.y, u.a.z);
            let white = Float3::new(u.b.x, u.b.y, u.b.z);
            let target = black + (white - black) * y;
            e + (target - e) * u.a.w
        }
        OP_BRIGHTNESS => (e - 0.5) * u.a.y + 0.5 + u.a.x * 0.4,
        OP_LEAK => {
            let d = (q - u.center) / u.b.w;
            let g = u.a.w * (-2.0 * d.dot(d)).exp();
            let t = (0.5 + 0.5 * d.dot(u.frame)).clamp(0.0, 1.0);
            let c1 = Float3::new(u.a.x, u.a.y, u.a.z);
            let c2 = Float3::new(u.b.x, u.b.y, u.b.z);
            let light = ((c1 + (c2 - c1) * t) * g).min(Float3::splat(1.0));
            e + light * (ONE3 - e).max(Float3::ZERO)
        }
        OP_GRADIENT => {
            let d = q - u.center;
            let len2 = u.frame.dot(u.frame);
            let mut t = 0.0f32;
            if len2 > 1e-12 {
                t = if u.i.x != 0 { d.length() / len2.sqrt() } else { d.dot(u.frame) / len2 };
            }
            t = t.clamp(0.0, 1.0);
            let c1 = Float3::new(u.a.x, u.a.y, u.a.z);
            let c2 = Float3::new(u.b.x, u.b.y, u.b.z);
            e + ((c1 + (c2 - c1) * t) - e) * u.a.w
        }
        OP_HALFTONE => {
            let y = e.dot(LUMA_WEIGHTS).clamp(0.0, 1.0);
            let m = halftone_coverage(q, y, u);
            let target = if u.i.x != 0 { e * m } else { Float3::splat(m) };
            e + (target - e) * u.a.w
        }
        OP_STROBE => {
            let s = Float3::new(u.a.x, u.a.y, u.a.z);
            let r = match u.i.x {
                1 => e + s,
                2 => e * s,
                3 => ONE3 - (ONE3 - e) * (ONE3 - s),
                4 => (e - s).abs(),
                _ => s,
            };
            r + (e - r) * u.a.w
        }
        _ => return p,
    };
    Float4::new(dec(o.x) * p.w, dec(o.y) * p.w, dec(o.z) * p.w, p.w)
}

/// Halftone: how much light a pixel of luma `y` lets through at texture position `q` (1 = paper / full color).
pub fn halftone_coverage(q: Float2, y: f32, u: &U) -> f32 {
    let d = q - u.center;
    let c = u.a.y.cos();
    let s = u.a.y.sin();
    let r = Float2::new(c * d.x + s * d.y, -s * d.x + c * d.y) / u.a.x;
    let f = r - Float2::new(r.x.floor(), r.y.floor()) - Float2::new(0.5, 0.5);
    let rn = f.length() / std::f32::consts::FRAC_1_SQRT_2;
    let soft = 0.02 + 0.3 * u.a.z;
    let colour = u.i.x != 0;
    let rho = (if colour { y } else { 1.0 - y }).sqrt() * (1.0 + 2.0 * soft) - soft;
    let edge = smoothstep(rho - soft, rho + soft, rn);
    if colour { 1.0 - edge } else { edge }
}

fn wave(x: f32, kind: i32) -> f32 {
    match kind {
        1 => {
            if x - x.floor() < 0.5 {
                1.0
            } else {
                -1.0
            }
        }
        2 => {
            let f = x - 0.25 - (x - 0.25).floor();
            4.0 * (f - 0.5).abs() - 1.0
        }
        3 => {
            let f = x + 0.5 - (x + 0.5).floor();
            2.0 * f - 1.0
        }
        _ => (2.0 * PI * x).sin(),
    }
}

fn fold(v: f32) -> f32 {
    let m = v - 2.0 * (v / 2.0).floor();
    if m > 1.0 { 2.0 - m } else { m }
}

/// Warp family: where the picture at texture position `q` is read from.
pub fn warp_source(q: Float2, u: &U) -> Float2 {
    match u.i.w {
        OP_FLIP => Float2::new(
            if u.i.x != 0 { 2.0 * u.center.x - q.x } else { q.x },
            if u.i.y != 0 { 2.0 * u.center.y - q.y } else { q.y },
        ),
        OP_TWIRL => {
            let d = q - u.center;
            let r = d.length();
            let big = u.a.y;
            if !(r < big && big > 0.0) {
                return q;
            }
            let k = 1.0 - r / big;
            let th = -u.a.x * k * k;
            let (c, s) = (th.cos(), th.sin());
            u.center + Float2::new(c * d.x - s * d.y, s * d.x + c * d.y)
        }
        OP_WAVE => {
            let o = u.center - u.frame * 0.5;
            let dir = Float2::new(u.a.z, u.a.w);
            let across = Float2::new(-u.a.w, u.a.z);
            let x = (q - o).dot(dir) / u.a.y + u.b.x;
            let mut pin = 1.0f32;
            let n = (q - o) / u.frame;
            let ex = smoothstep(0.0, 0.1, n.x.min(1.0 - n.x));
            let ey = smoothstep(0.0, 0.1, n.y.min(1.0 - n.y));
            match u.i.y {
                1 => pin = ex * ey,
                2 => pin = ey,
                3 => pin = ex,
                _ => {}
            }
            q - across * (u.a.x * wave(x, u.i.x) * pin)
        }
        OP_SPHERIZE => {
            let d = q - u.center;
            let r = d.length();
            let big = u.a.x;
            if !(r < big && r > 0.0) {
                return q;
            }
            let n = r / big;
            let s = u.a.y;
            let f = if s > 0.0 { n + (2.0 / PI * n.asin() - n) * s } else { n + ((n * PI / 2.0).sin() - n) * -s };
            u.center + d * (f / n)
        }
        OP_TILE => {
            let o = u.center - u.frame * 0.5;
            let t = (q - o) / u.frame * Float2::new(u.a.x, u.a.y) + Float2::new(u.a.z, u.a.w);
            let mut f = t - Float2::new(t.x.floor(), t.y.floor());
            if u.b.x != 0.0 {
                f = Float2::new(fold(t.x), fold(t.y));
            }
            o + f * u.frame
        }
        OP_KALEIDO => {
            let d = q - u.center;
            let r = d.length();
            if !(r > 0.0) {
                return q;
            }
            let w = u.a.x;
            let th = d.y.atan2(d.x);
            let m = th - w * (th / w).floor();
            let a = (m - w / 2.0).abs() + u.a.y;
            u.center + Float2::new(a.cos(), a.sin()) * (r * u.a.z)
        }
        OP_STAGE => {
            let d = q - u.center;
            u.center + Float2::new(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y) + Float2::new(u.b.x, u.b.y)
        }
        OP_CORNER => corner_source(q, u),
        OP_STAGE_FILL => {
            let d = q - u.center;
            fold_into_frame(
                u.center
                    + Float2::new(u.a.x * d.x + u.a.y * d.y, u.a.z * d.x + u.a.w * d.y)
                    + Float2::new(u.b.x, u.b.y),
                u,
            )
        }
        OP_ROLLING => {
            let mut q = q;
            if u.i.y != 0 {
                // residual perspective first (Stabilizer warp)
                let d = q - u.center;
                let den = u.d.z * d.x + u.d.w * d.y + 1.0;
                if !(den > 1e-6) {
                    return FAR;
                }
                q = u.center
                    + Float2::new((u.c.x * d.x + u.c.y * d.y + u.c.z) / den, (u.c.w * d.x + u.d.x * d.y + u.d.y) / den);
            }
            // The ideal point q was recorded at r = q + s * v with v the scan position of r itself (-0.5 ... 0.5), so
            // v = v(q) / (1 - s_scan / extent). The picture edge is held: no empty sliver where a row was shifted out.
            let s = Float2::new(u.a.x, u.a.y);
            let ext = u.a.z.max(1.0);
            let along_x = u.i.x != 0;
            let v0 = (if along_x { q.x - u.center.x } else { q.y - u.center.y }) / ext;
            let v = v0 / (1.0 - (if along_x { s.x } else { s.y }) / ext).max(0.5);
            let lo = u.center - u.frame * 0.5 + HALF;
            let hi = u.center + u.frame * 0.5 - HALF;
            (q + s * v).max(lo).min(lo.max(hi))
        }
        _ => q,
    }
}

/// `s` mirrored back into the clip's frame (reflected over each edge, repeating): the mirror-repeat addressing of Edge Fill.
pub fn fold_into_frame(s: Float2, u: &U) -> Float2 {
    let lo = u.center - u.frame * 0.5;
    let t = (s - lo) / u.frame;
    // Held half a texel inside the frame: a read right at the fold line would blend with the transparent outside.
    let hi = lo + u.frame - HALF;
    let inner = lo + HALF;
    (lo + Float2::new(fold(t.x), fold(t.y)) * u.frame).max(inner).min(inner.max(hi))
}

/// What a warp multiplies its tap by (a stage's opacity; 1 for the others).
pub fn warp_gain(u: &U) -> f32 {
    if u.i.w == OP_STAGE { u.b.z } else { 1.0 }
}

/// True where a warp leaves the texel as it is: the Rolling Shutter pass outside the clip's own frame (the working texture is
/// larger than the frame when a Drop Shadow, Glow or blur sits above; that margin is not picture).
pub fn warp_passes_through(q: Float2, u: &U) -> bool {
    if u.i.w != OP_ROLLING && u.i.w != OP_STAGE_FILL {
        return false;
    }
    let d = (q - u.center).abs();
    d.x > u.frame.x * 0.5 || d.y > u.frame.y * 0.5
}

/// Lens Distortion as saved before F7.15 (no `lensModel` key): where the picture at `q` is read from.
pub fn lens_legacy_source(q: Float2, u: &U) -> Float2 {
    let d = q - u.center;
    let r = d.length() / u.a.y;
    let k = u.a.x;
    let f = if k >= 0.0 { 1.0 + k * r * r } else { 1.0 / (1.0 - k * r * r) };
    u.center + d * f
}

/// Lens Distortion: where the picture at texture position `q` (inside the picture) is read from, and how many source px one
/// output px spans there (x = along the radius, y = across it). With rho = the zoomed distance from the lens center in half
/// diagonals, k >= 0 (barrel) reads at rho (1 + k rho^2); k < 0 (pincushion) reads at the x that solves x (1 + |k| x^2) = rho,
/// the exact inverse of the barrel with the same strength (Newton from x0 = rho / (1 + |k| rho^2)).
pub fn lens_map(q: Float2, u: &U) -> (Float2, Float2) {
    let zoom = f32::from_bits(u.i.x as u32);
    let d = q - u.center;
    let rho = d.length() / u.a.y * zoom;
    let k = u.a.x;
    let (f, g);
    if k >= 0.0 {
        f = 1.0 + k * rho * rho;
        g = 1.0 + 3.0 * k * rho * rho;
    } else {
        let a = -k;
        let mut x = rho / (1.0 + a * rho * rho);
        for _ in 0..4 {
            x -= (x * (1.0 + a * x * x) - rho) / (1.0 + 3.0 * a * x * x);
        }
        f = if rho > 1e-6 { x / rho } else { 1.0 };
        g = 1.0 / (1.0 + 3.0 * a * x * x);
    }
    (u.center + d * (zoom * f), Float2::new(zoom * g, zoom * f))
}

/// Where a lens tap at `q` reads from.
pub fn lens_source(q: Float2, u: &U) -> Float2 {
    lens_map(q, u).0
}

/// Auto Scale: the largest zoom about the lens center (0.05...4) at which every point of the picture's border still reads
/// inside the picture, so no empty edge shows (a barrel zooms in, a pincushion zooms out until an edge touches). The read
/// distance grows with the zoom, so bisection finds it.
pub fn lens_auto_zoom(u: &U) -> f32 {
    let o = Float2::new(u.a.z, u.a.w);
    let n = 32;
    let mut border = Vec::new();
    for i in 0..=n {
        let t = i as f32 / n as f32;
        border.push(o + Float2::new(t * u.frame.x, 0.0));
        border.push(o + Float2::new(t * u.frame.x, u.frame.y));
        border.push(o + Float2::new(0.0, t * u.frame.y));
        border.push(o + Float2::new(u.frame.x, t * u.frame.y));
    }
    let fits = |zoom: f32| {
        let mut v = *u;
        v.i.x = zoom.to_bits() as i32;
        border.iter().all(|b| in_picture(lens_source(*b, &v), &v))
    };
    let (mut lo, mut hi) = (0.05f32, 4.0f32);
    if fits(hi) {
        return hi;
    }
    for _ in 0..24 {
        let mid = (lo + hi) / 2.0;
        if fits(mid) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    lo
}

fn cubic_weights(t: f32) -> Float4 {
    Float4::new(
        ((-0.5 * t + 1.0) * t - 0.5) * t,
        (1.5 * t - 2.5) * t * t + 1.0,
        ((-1.5 * t + 2.0) * t + 0.5) * t,
        (0.5 * t - 0.5) * t * t,
    )
}

/// Where a lens tap at `p` reads and how much of it is picture: faded into the fill `u.b` over the last half px outside the
/// border (what a bilinear tap does there); with Auto Scale (`i.y`) held inside the picture instead.
fn lens_hold(p: Float2, u: &U) -> (Float2, f32) {
    let o = Float2::new(u.a.z, u.a.w);
    let e = o + u.frame;
    if u.i.y != 0 {
        return (p.clamp(o + 0.5, e - 0.5), 1.0);
    }
    let m = ((p - o).min(e - p) + 0.5).clamp(Float2::ZERO, Float2::splat(1.0));
    (p, m.x * m.y)
}

/// One sharp lens tap: Catmull-Rom over the 12 texels of the 4 x 4 block without its corners (their weights are below 0.6 %
/// each; the rest is renormalized), which the GPU reads as five bilinear fetches. Texels are held at the picture's edge (no
/// ringing against the empty outside).
fn lens_tap(img: &Image, p: Float2, u: &U) -> Float4 {
    let o = Float2::new(u.a.z, u.a.w);
    let e = o + u.frame;
    let (p, cover) = lens_hold(p, u);
    if cover <= 0.0 {
        return u.b;
    }
    let lo = (o - 0.5).ceil();
    let hi = (e - 0.5).floor();
    let q = p - 0.5;
    let b = q.floor();
    let wx = cubic_weights(q.x - b.x);
    let wy = cubic_weights(q.y - b.y);
    let mut acc = Float4::ZERO;
    for j in 0..4usize {
        for i in 0..4usize {
            if (i == 0 || i == 3) && (j == 0 || j == 3) {
                continue;
            }
            let t = (b + Float2::new(i as f32 - 1.0, j as f32 - 1.0)).clamp(lo, hi);
            acc += img.at(t.x as i64, t.y as i64) * (wx[i] * wy[j]);
        }
    }
    acc /= 1.0 - (wx[0] + wx[3]) * (wy[0] + wy[3]);
    acc * cover + u.b * (1.0 - cover)
}

/// One soft lens tap (bilinear), held and faded like `lens_tap`.
fn lens_tap_linear(img: &Image, p: Float2, u: &U) -> Float4 {
    let o = Float2::new(u.a.z, u.a.w);
    let e = o + u.frame;
    let (p, cover) = lens_hold(p, u);
    if cover <= 0.0 {
        return u.b;
    }
    let lo = (o - 0.5).ceil() + 0.5;
    let hi = (e - 0.5).floor() + 0.5;
    img.sample(p.clamp(lo, hi)) * cover + u.b * (1.0 - cover)
}

/// Where the footprint taps start and where they have fully replaced the sharp tap (source px per output px).
const LENS_SHRINK_START: f32 = 1.15;
const LENS_SHRINK_FULL: f32 = 1.4;

/// The lens' resampling: one sharp tap where the picture is magnified or barely shrunk; where one output px spans more than
/// `LENS_SHRINK_FULL` source px, four bilinear taps spread over its footprint (along and across the radius) so fine detail
/// does not shimmer; a blend of both in between. At most 9 fetches per pixel. Never negative.
pub fn lens_sample(img: &Image, q: Float2, u: &U) -> Float4 {
    let (s, stretch) = lens_map(q, u);
    let o = Float2::new(u.a.z, u.a.w);
    let e = o + u.frame;
    if u.i.y == 0 && (s.x < o.x - 3.0 || s.y < o.y - 3.0 || s.x > e.x + 3.0 || s.y > e.y + 3.0) {
        return u.b;
    }
    let t = ((stretch.x.max(stretch.y) - LENS_SHRINK_START) / (LENS_SHRINK_FULL - LENS_SHRINK_START)).clamp(0.0, 1.0);
    let mut c = Float4::ZERO;
    if t < 1.0 {
        c += lens_tap(img, s, u) * (1.0 - t);
    }
    if t > 0.0 {
        let spread = (stretch - 1.0).clamp(Float2::ZERO, Float2::splat(2.0)) * 0.5;
        let d = q - u.center;
        let len = d.length();
        let er = if len > 1e-6 { d / len } else { Float2::new(1.0, 0.0) };
        let et = Float2::new(-er.y, er.x);
        let a = er * spread.x;
        let b = et * spread.y;
        c += (lens_tap_linear(img, s + a + b, u)
            + lens_tap_linear(img, s + a - b, u)
            + lens_tap_linear(img, s - a + b, u)
            + lens_tap_linear(img, s - a - b, u))
            * (0.25 * t);
    }
    premultiplied_held(c)
}

/// The sharp tap's negative lobes overshoot at a hard alpha edge (alpha above 1 or below 0). The picture's color follows its
/// alpha there: above 1 the color is scaled by the same factor as alpha is cut, below 0 nothing is left, so color never
/// exceeds alpha (a bright halo over the edge). Opaque colors above 1 (HDR) stay.
pub fn premultiplied_held(c: Float4) -> Float4 {
    if c.w <= 0.0 {
        return Float4::ZERO;
    }
    let k = if c.w > 1.0 { 1.0 / c.w } else { 1.0 };
    Float4::new(c.x.max(0.0) * k, c.y.max(0.0) * k, c.z.max(0.0) * k, c.w.min(1.0))
}

/// True when `q` lies inside the picture rectangle (edges included).
pub fn in_picture(q: Float2, u: &U) -> bool {
    let o = Float2::new(u.a.z, u.a.w);
    q.x >= o.x && q.y >= o.y && q.x <= o.x + u.frame.x && q.y <= o.y + u.frame.y
}

/// Glitch Displace: horizontal shift (texture px) of the band holding texture row `y`.
pub fn glitch_shift(y: f32, u: &U) -> f32 {
    let band = ((y - (u.center.y - u.frame.y * 0.5)) / u.a.y) as i32;
    let id = band as u32;
    let seed = u.i.x as u32;
    if !(hash01(id, 0, seed, 0) < u.a.w) {
        return 0.0;
    }
    (hash01(id, 1, seed, 1) * 2.0 - 1.0) * u.a.x
}

// MARK: CPU references

/// The reference result of `f` (`None` when it is not a style filter).
pub fn reference(f: &ImageFilter, img: &Image, frame: &Frame, pf: f64) -> Option<Image> {
    let (family, u) = plan(f, frame, pf)?;
    let center_of = |x: usize, y: usize| Float2::new(x as f32 + 0.5, y as f32 + 0.5);
    Some(match family {
        Family::Pixel => img.map(|x, y, p| pixel(p, center_of(x, y), &u)),
        Family::Warp => {
            let g = warp_gain(&u);
            img.map(|x, y, p| {
                let q = center_of(x, y);
                if warp_passes_through(q, &u) { p } else { img.sample(warp_source(q, &u)) * g }
            })
        }
        Family::Lens => img.map(|x, y, p| {
            let q = center_of(x, y);
            if !in_picture(q, &u) {
                return p;
            }
            if u.i.z == 0 {
                let s = lens_legacy_source(q, &u);
                return if u.b.w > 0.0 && !in_picture(s, &u) { u.b } else { img.sample(s) };
            }
            lens_sample(img, q, &u)
        }),
        Family::RgbSplit => img.map(|x, y, p| {
            let q = center_of(x, y);
            let mut d = Float2::new(u.a.x, u.a.y);
            if u.i.x != 0 {
                d = (q - u.center) * d.length() / u.a.w;
            }
            let r = img.sample(q - d);
            let b = img.sample(q + d);
            let s = Float4::new(r.x, p.y, b.z, r.w.max(p.w.max(b.w)));
            s + (p - s) * u.a.z
        }),
        Family::Glitch => img.map(|x, y, _| {
            let q = center_of(x, y);
            let sx = glitch_shift(q.y, &u);
            let r = img.sample(q + Float2::new(sx - u.a.z, 0.0));
            let g = img.sample(q + Float2::new(sx, 0.0));
            let b = img.sample(q + Float2::new(sx + u.a.z, 0.0));
            Float4::new(r.x, g.y, b.z, r.w.max(g.w.max(b.w)))
        }),
        Family::RadialBlur => {
            let n = u.i.y;
            img.map(|x, y, _| {
                let q = center_of(x, y);
                let d = q - u.center;
                let mut acc = Float4::ZERO;
                for k in 0..n {
                    let t = (k as f32 / (n - 1) as f32 - 0.5) * u.a.x;
                    let s = if u.i.x != 0 {
                        u.center + d * (1.0 + t)
                    } else {
                        let (c, sn) = (t.cos(), t.sin());
                        u.center + Float2::new(c * d.x - sn * d.y, sn * d.x + c * d.y)
                    };
                    acc += img.sample(s);
                }
                acc / n as f32
            })
        }
    })
}
