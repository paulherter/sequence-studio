// Swift: ColorStages.swift (ToneMath)
//! Shared per-pixel helpers of the color blocks. Everything works on a *tone signal* `t`: the Rec.709-encoded (gamma)
//! picture signal, 0...1 for SDR, unclamped beyond.

use sq_core_model::WheelValue;

use super::vec::Vec3;

/// Contrast pivot of the legacy tone model.
pub const CONTRAST_PIVOT: f32 = 0.45;

/// Smoothstep of `x` between `a` and `b`.
pub fn smooth(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Full-saturation, full-value RGB of a hue in degrees.
pub fn hue_rgb(hue_degrees: f32) -> Vec3 {
    let mut h = hue_degrees / 360.0;
    h -= h.floor();
    let ch = |o: f32| {
        let mut x = h + o;
        x -= x.floor();
        ((x * 6.0 - 3.0).abs() - 1.0).clamp(0.0, 1.0)
    };
    Vec3::new(ch(0.0), ch(2.0 / 3.0), ch(1.0 / 3.0))
}

/// Zero-mean RGB offset for a wheel position (neutral on the gray axis, so it tints without changing brightness).
pub fn wheel_offset(w: &WheelValue) -> Vec3 {
    if w.amount <= 0.0 {
        return Vec3::ZERO;
    }
    let c = hue_rgb(w.hue);
    w.amount.min(1.0) * (c - Vec3::splat((c.x + c.y + c.z) / 3.0))
}

/// 0...1: how "skin-like" a color is (hue between orange and yellow-orange, red-dominant).
pub fn skin_weight(t: Vec3) -> f32 {
    if !(t.x >= t.y && t.y >= t.z && t.x > t.z) {
        return 0.0;
    }
    let f = (t.y - t.z) / (t.x - t.z);
    smooth(0.10, 0.30, f) * (1.0 - smooth(0.70, 0.95, f))
}

/// Saturation (1 = neutral) and vibrance (-1...1). Vibrance lifts low-saturation colors more than saturated ones and
/// protects skin tones; negative vibrance mutes saturated colors first.
pub fn sat_vib(t: Vec3, sat: f32, vib: f32, luma: Vec3) -> Vec3 {
    let mut s = sat;
    if vib != 0.0 {
        let (mx, mn) = (t.max_elem(), t.min_elem());
        let sv = if mx > 1e-4 { ((mx - mn) / mx).clamp(0.0, 1.0) } else { 0.0 };
        if vib > 0.0 {
            s *= 1.0 + vib * (1.0 - sv) * (1.0 - 0.5 * skin_weight(t));
        } else {
            s *= 1.0 + vib * (0.3 + 0.7 * sv);
        }
    }
    if s == 1.0 {
        return t;
    }
    let y = luma.dot(t);
    Vec3::splat(y) + (t - Vec3::splat(y)) * s
}

/// Hue (turns, 0...1) of a tone-signal color from its channel maximum `mx` and spread `d`; 0 when the hue is undefined.
pub fn hue_turns(t: Vec3, mx: f32, d: f32) -> f32 {
    if d <= 1e-6 {
        return 0.0;
    }
    let mut h = if mx == t.x {
        (t.y - t.z) / d
    } else if mx == t.y {
        (t.z - t.x) / d + 2.0
    } else {
        (t.x - t.y) / d + 4.0
    };
    h /= 6.0;
    h - h.floor()
}

/// Rotates the chroma of `v` about the gray axis by `theta` radians (Rodrigues, axis (1,1,1)/sqrt(3)).
pub fn rotate_about_gray(v: Vec3, theta: f32) -> Vec3 {
    let m = (v.x + v.y + v.z) / 3.0;
    let dv = v - Vec3::splat(m);
    let cr = Vec3::new(dv.z - dv.y, dv.x - dv.z, dv.y - dv.x) * 0.57735027;
    Vec3::splat(m) + dv * theta.cos() + cr * theta.sin()
}
