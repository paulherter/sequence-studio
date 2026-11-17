// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/UltraKey.swift
//! The key family on the un-premultiplied working-linear color: Ultra Key (chroma) and Luma Key. CPU reference of
//! `applyChromaKey` in the compositor shader.
//!
//! Chroma, per pixel: hue and saturation of the color; `K` = how much it belongs to the key color (1 inside `half_width`
//! degrees of the key hue, falling to 0 over `soft` more degrees, weighted down for gray and near-black pixels). Keep
//! Highlights / Keep Shadows hold back the key on bright / dark pixels. Spill suppression desaturates the color towards its
//! luma in a wider zone around the key hue; then the color correction runs on what is kept. Luma: `K` = 1 below the
//! threshold of the encoded luma (above it for "brights"), falling to 0 over `luma_softness`. Both: pedestal, then the
//! matte tone (shrink / grow, contrast, midpoint) on the kept share 1 - K.

use super::simd::{Float3, Float4, SWIFT_FLOAT_PI};
use sq_core_effects::effects_evaluation::{ChromaKey, ChromaKeyMode, ChromaKeyOutput};

fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Contrast slope at contrast 1 is 1 + 9 = 10x (Swift `MatteRefine.contrastGain`).
const CONTRAST_GAIN: f64 = 9.0;
/// How much of the 0...1 range one full unit of shrink covers (Swift `MatteRefine.shrinkReach`).
const SHRINK_REACH: f64 = 0.9;

/// Per-pixel matte refinement of coverage `c` (Swift `MatteRefine.tone`) as the f32 variant (`toneF`).
// shortcut: lives here until sq-core-masks `matte_refine` gets `tone`; move it there then.
fn matte_tone_f(shrink: f64, contrast: f64, midpoint: f64, c: f32) -> f32 {
    let mut m = f64::from(c).clamp(0.0, 1.0);
    if shrink > 0.0 {
        let s = SHRINK_REACH * shrink.min(1.0);
        m = ((m - s) / (1.0 - s).max(1e-4)).clamp(0.0, 1.0);
    } else if shrink < 0.0 {
        let g = SHRINK_REACH * (-shrink).min(1.0);
        m = (m / (1.0 - g).max(1e-4)).min(1.0);
    }
    if contrast > 0.0 {
        m = ((m - midpoint) * (1.0 + CONTRAST_GAIN * contrast.min(1.0)) + midpoint).clamp(0.0, 1.0);
    }
    m as f32
}

/// Hue in degrees (0..<360), saturation and value (max channel) of linear rgb.
pub fn hsv(c: Float3) -> (f32, f32, f32) {
    let mx = c.x.max(c.y.max(c.z));
    let mn = c.x.min(c.y.min(c.z));
    let d = mx - mn;
    let mut h = 0.0f32;
    if d > 0.0 {
        if mx == c.x {
            h = ((c.y - c.z) / d) % 6.0;
        } else if mx == c.y {
            h = (c.z - c.x) / d + 2.0;
        } else {
            h = (c.x - c.y) / d + 4.0;
        }
        h *= 60.0;
        if h < 0.0 {
            h += 360.0;
        }
    }
    (h, if mx > 0.0 { d / mx } else { 0.0 }, mx)
}

/// Matte shaping of the keyed share `k`: the pedestal first drops weak keying, then the shared tone (shrink / grow, contrast,
/// midpoint) works on coverage 1 - k. All neutral returns `k` unchanged. Mirrors `shapeMatte` in the shader.
fn shape(k: f32, choke: f32, pedestal: f32, contrast: f32, midpoint: f32) -> f32 {
    let mut m = k;
    if pedestal > 0.0 {
        m = ((m - pedestal) / (1.0 - pedestal).max(1e-4)).clamp(0.0, 1.0);
    }
    if choke != 0.0 || contrast > 0.0 {
        m = 1.0 - matte_tone_f(f64::from(choke), f64::from(contrast), f64::from(midpoint), 1.0 - m);
    }
    m
}

/// Saturation, hue shift (rotation about the gray axis, radians) and brightness factor on linear rgb.
fn correct(c: Float3, saturation: f32, hue_radians: f32, luma: f32) -> Float3 {
    let mut o = c;
    let y = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722;
    o = Float3::splat(y) + (o - Float3::splat(y)) * saturation;
    if hue_radians != 0.0 {
        let cs = hue_radians.cos();
        let sn = hue_radians.sin();
        let ax = Float3::splat(0.57735027);
        let cross = Float3::new(ax.y * o.z - ax.z * o.y, ax.z * o.x - ax.x * o.z, ax.x * o.y - ax.y * o.x);
        o = o * cs + cross * sn + ax * (ax.dot(o) * (1.0 - cs));
    }
    o * luma
}

/// Applies one key of either mode: returns the color after spill suppression / color correction and `K`.
pub fn key(c: Float3, k: &ChromaKey) -> (Float3, f32) {
    let choke = k.choke as f32;
    let pedestal = k.pedestal as f32;
    let contrast = k.contrast as f32;
    let midpoint = k.midpoint as f32;
    if k.mode == ChromaKeyMode::Luma {
        let y = (c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722).clamp(0.0, 1.0).sqrt();
        let yy = if k.luma_keys_brights { 1.0 - y } else { y };
        let tt = if k.luma_keys_brights { 1.0 - k.luma_threshold as f32 } else { k.luma_threshold as f32 };
        let raw = 1.0 - smoothstep(tt, tt + (k.luma_softness as f32).max(1e-4), yy);
        return (c, shape(raw, choke, pedestal, contrast, midpoint));
    }
    let hue = k.hue as f32;
    let half_width = k.half_width as f32;
    let soft = k.soft as f32;
    let (h, s, v) = hsv(c);
    let mut dist = (h - hue).abs();
    dist = dist.min(360.0 - dist);
    let weight = smoothstep(0.08, 0.3, s) * smoothstep(0.001, 0.01, v);
    let inside = 1.0 - smoothstep(half_width, half_width + soft, dist);
    let mut raw = inside * weight;
    if k.keep_highlights > 0.0 || k.keep_shadows > 0.0 {
        let keep = (k.keep_highlights as f32 * smoothstep(0.5, 1.0, v)
            + k.keep_shadows as f32 * (1.0 - smoothstep(0.02, 0.3, v)))
        .min(1.0);
        raw *= 1.0 - keep;
    }
    let keyed = shape(raw, choke, pedestal, contrast, midpoint);
    let zone = 1.0 - smoothstep(half_width + soft, 2.0 * half_width + soft + k.spill_range as f32 * 40.0, dist);
    let w = k.spill as f32 * zone * weight * (1.0 - raw);
    let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722;
    let mut out = c + (Float3::splat(luma) - c) * w;
    if k.corrects_color() {
        let hue_radians = k.hue_shift as f32 * SWIFT_FLOAT_PI / 180.0;
        out = correct(out, k.saturation as f32, hue_radians, k.luma as f32);
    }
    (out, keyed)
}

/// All keys in order over un-premultiplied `rgb` with `alpha`.
pub fn apply(rgb: Float3, alpha: f32, keys: &[ChromaKey]) -> (Float3, f32) {
    let mut c = rgb;
    let mut a = alpha;
    let mut kept = 1.0f32;
    let mut matte = false;
    for k in keys.iter().take(ChromaKey::MAX_PER_LAYER) {
        if k.output == ChromaKeyOutput::Source {
            continue; // Source: the picture before keying
        }
        let (color, kk) = key(c, k);
        c = color;
        a *= 1.0 - kk;
        kept *= 1.0 - kk;
        if k.output == ChromaKeyOutput::Alpha {
            matte = true;
        }
    }
    // Matte view: the kept share as gray, the layer's own coverage unchanged.
    if matte { (Float3::splat(kept), alpha) } else { (c, a) }
}

/// The matte vector the shader reads for one key: shrink / grow, pedestal, output (0 composite, 1 alpha, 2 source), mode.
pub fn matte_vector(k: &ChromaKey) -> Float4 {
    Float4::new(k.choke as f32, k.pedestal as f32, k.output as i32 as f32, k.mode as i32 as f32)
}

/// Matte generation / clean-up vector: contrast, midpoint, keep highlights, keep shadows.
pub fn shape_vector(k: &ChromaKey) -> Float4 {
    Float4::new(k.contrast as f32, k.midpoint as f32, k.keep_highlights as f32, k.keep_shadows as f32)
}

/// Color vector: saturation, hue shift (radians), brightness, spill range.
pub fn color_vector(k: &ChromaKey) -> Float4 {
    Float4::new(k.saturation as f32, k.hue_shift as f32 * SWIFT_FLOAT_PI / 180.0, k.luma as f32, k.spill_range as f32)
}

/// The uniform vector the shader reads for one key: chroma = hue, half width, soft edge, spill; luma = threshold, softness,
/// keys-brights flag, 0.
pub fn vector(k: &ChromaKey) -> Float4 {
    if k.mode == ChromaKeyMode::Luma {
        return Float4::new(
            k.luma_threshold as f32,
            k.luma_softness as f32,
            if k.luma_keys_brights { 1.0 } else { 0.0 },
            0.0,
        );
    }
    Float4::new(k.hue as f32, k.half_width as f32, k.soft as f32, k.spill as f32)
}
