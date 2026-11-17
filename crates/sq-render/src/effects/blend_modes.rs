// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/BlendModes.swift
//! Opacity blend modes: the CPU maths the compositor shader is tested against.
//!
//! Everything is premultiplied and works in the compositor's working-linear space (Rec.709 primaries, scene-linear).
//! With source `S = (Cs, as)` and destination `D = (Cd, ad)`, `cs` and `cd` the un-premultiplied colors:
//! `rgb = Cs (1 - ad) + Cd (1 - as) + as ad B(cd, cs)`, `a = as + ad (1 - as)`. Add is not clamped. The Component modes and
//! Darker/Lighter Color use the W3C SetLum/SetSat/ClipColor construction with Rec.709 luminance weights. Dissolve replaces
//! the source's coverage by a fixed per-pixel pattern (`dissolve_threshold`).

use super::simd::{Float3, Float4};
use sq_core_model::BlendMode;

/// The shader id of a footage-fill draw (`RenderLayer.stencil`); not a `BlendMode`, never stored.
pub const STENCIL_SHADER_ID: u32 = 27;

/// Rec.709 luminance weights (linear light).
pub const LUMA_WEIGHTS: Float3 = Float3::new(0.2126, 0.7152, 0.0722);

/// The id the shader switches on (0 = normal). Ids are stable within one build only (not stored).
pub fn shader_id(m: BlendMode) -> u32 {
    use BlendMode::*;
    match m {
        Normal => 0,
        Multiply => 1,
        Screen => 2,
        Add => 3,
        Overlay => 4,
        Darken => 5,
        Lighten => 6,
        ColorDodge => 7,
        ColorBurn => 8,
        LinearBurn => 9,
        HardLight => 10,
        SoftLight => 11,
        Difference => 12,
        Exclusion => 13,
        Dissolve => 14,
        VividLight => 15,
        LinearLight => 16,
        PinLight => 17,
        HardMix => 18,
        Subtract => 19,
        Divide => 20,
        DarkerColor => 21,
        LighterColor => 22,
        Hue => 23,
        Saturation => 24,
        Color => 25,
        Luminosity => 26,
    }
}

/// CPU reference of the stencil draw: the destination kept by the matte's coverage `s.w` (already times `opacity`),
/// `opacity` of it mixed with the untouched destination: `d * (1 - opacity + s.w)`.
pub fn stencil(source: Float4, destination: Float4, opacity: f32) -> Float4 {
    destination * (1.0 - opacity + source.w)
}

/// Rec.709 luminance.
pub fn lum(c: Float3) -> f32 {
    c.x * LUMA_WEIGHTS.x + c.y * LUMA_WEIGHTS.y + c.z * LUMA_WEIGHTS.z
}

fn clip_color(c: Float3) -> Float3 {
    let l = lum(c);
    let n = c.x.min(c.y.min(c.z));
    let x = c.x.max(c.y.max(c.z));
    let mut out = c;
    if n < 0.0 {
        out = (out - l) * (l / (l - n).max(1e-6)) + l;
    }
    if l < 1.0 && x > 1.0 {
        out = (out - l) * ((1.0 - l) / (x - l).max(1e-6)) + l;
    }
    out
}

fn set_lum(c: Float3, l: f32) -> Float3 {
    clip_color(c + (l - lum(c)))
}

fn sat(c: Float3) -> f32 {
    c.x.max(c.y.max(c.z)) - c.x.min(c.y.min(c.z))
}

/// The color with its saturation (max - min) set to `s`, keeping which channel is largest/middle/smallest.
fn set_sat(c: Float3, s: f32) -> Float3 {
    let mx = c.x.max(c.y.max(c.z));
    let mn = c.x.min(c.y.min(c.z));
    let range = mx - mn;
    if range > 0.0 { (c - mn) * (s / range) } else { Float3::ZERO }
}

/// B(cd, cs) for the whole color (cd = backdrop, cs = source).
pub fn channel(m: BlendMode, cd: Float3, cs: Float3) -> Float3 {
    use BlendMode::*;
    match m {
        DarkerColor => {
            if lum(cs) < lum(cd) {
                cs
            } else {
                cd
            }
        }
        LighterColor => {
            if lum(cs) > lum(cd) {
                cs
            } else {
                cd
            }
        }
        Hue => set_lum(set_sat(cs, sat(cd)), lum(cd)),
        Saturation => set_lum(set_sat(cd, sat(cs)), lum(cd)),
        Color => set_lum(cs, lum(cd)),
        Luminosity => set_lum(cd, lum(cs)),
        _ => Float3::new(scalar(m, cd.x, cs.x), scalar(m, cd.y, cs.y), scalar(m, cd.z, cs.z)),
    }
}

/// One channel of B(cd, cs) for the separable modes (W3C compositing spec / Photoshop definitions). Color Dodge and Color
/// Burn saturate at 1 and 0. Non-separable modes return `cs`.
pub fn scalar(m: BlendMode, cd: f32, cs: f32) -> f32 {
    use BlendMode::*;
    match m {
        Normal | Dissolve => cs,
        Multiply => cd * cs,
        Screen => cd + cs - cd * cs,
        Add => cd + cs,
        Overlay => scalar(HardLight, cs, cd),
        Darken => cd.min(cs),
        Lighten => cd.max(cs),
        ColorDodge => {
            if cd <= 0.0 {
                0.0
            } else if cs >= 1.0 {
                1.0
            } else {
                1.0f32.min(cd / (1.0 - cs))
            }
        }
        ColorBurn => {
            if cd >= 1.0 {
                1.0
            } else if cs <= 0.0 {
                0.0
            } else {
                1.0 - 1.0f32.min((1.0 - cd) / cs)
            }
        }
        LinearBurn => (cd + cs - 1.0).max(0.0),
        HardLight => {
            if cs <= 0.5 {
                cd * 2.0 * cs
            } else {
                scalar(Screen, cd, 2.0 * cs - 1.0)
            }
        }
        SoftLight => {
            if cs <= 0.5 {
                return cd - (1.0 - 2.0 * cs) * cd * (1.0 - cd);
            }
            let d = if cd <= 0.25 { ((16.0 * cd - 12.0) * cd + 4.0) * cd } else { cd.max(0.0).sqrt() };
            cd + (2.0 * cs - 1.0) * (d - cd)
        }
        Difference => (cd - cs).abs(),
        Exclusion => cd + cs - 2.0 * cd * cs,
        VividLight => {
            if cs <= 0.5 {
                scalar(ColorBurn, cd, 2.0 * cs)
            } else {
                scalar(ColorDodge, cd, 2.0 * cs - 1.0)
            }
        }
        LinearLight => (cd + 2.0 * cs - 1.0).max(0.0),
        PinLight => {
            if cs <= 0.5 {
                cd.min(2.0 * cs)
            } else {
                cd.max(2.0 * cs - 1.0)
            }
        }
        HardMix => {
            if cd + cs >= 1.0 {
                1.0
            } else {
                0.0
            }
        }
        Subtract => (cd - cs).max(0.0),
        Divide => {
            if cs <= 0.0 {
                return if cd > 0.0 { 1.0 } else { 0.0 };
            }
            (cd / cs).min(1.0f32.max(cd))
        }
        DarkerColor | LighterColor | Hue | Saturation | Color | Luminosity => cs,
    }
}

/// The fixed per-pixel threshold of Dissolve in [0, 1): a 32-bit integer hash (lowbias32) of the pixel position, top 24
/// bits. The shader runs the same integer ops, so CPU and GPU pick the same pixels.
pub fn dissolve_threshold(x: i64, y: i64) -> f32 {
    let mut h = (x as u32).wrapping_mul(0x9E37_79B9) ^ (y as u32).wrapping_mul(0x85EB_CA6B);
    h ^= h >> 16;
    h = h.wrapping_mul(0x7FEB_352D);
    h ^= h >> 15;
    h = h.wrapping_mul(0x846C_A68B);
    h ^= h >> 16;
    (h >> 8) as f32 / 16_777_216.0
}

/// Source over destination, both premultiplied rgba. `x`, `y`: the pixel (only Dissolve reads it).
pub fn blend(m: BlendMode, source: Float4, destination: Float4, x: i64, y: i64) -> Float4 {
    let mut s = source;
    let d = destination;
    if m == BlendMode::Dissolve {
        let cs = if s.w > 0.0 { s.xyz() / s.w } else { Float3::ZERO };
        s = if dissolve_threshold(x, y) < s.w { Float4::new(cs.x, cs.y, cs.z, 1.0) } else { Float4::ZERO };
    }
    let sc = s.xyz();
    let dc = d.xyz();
    let cs = if s.w > 0.0 { sc / s.w } else { Float3::ZERO };
    let cd = if d.w > 0.0 { dc / d.w } else { Float3::ZERO };
    let b = channel(m, cd, cs);
    let rgb = sc * (1.0 - d.w) + dc * (1.0 - s.w) + b * (s.w * d.w);
    Float4::new(rgb.x, rgb.y, rgb.z, s.w + d.w * (1.0 - s.w))
}
