// Swift: ColorStages.swift
//! Per-pixel maths of the Lumetri-like color blocks, prepared once from the saved parameters (the CPU reference of the
//! shader code). A block after the Input LUT receives the tone signal `t` directly (display-referred). A block before it
//! receives source-linear light and is wrapped (`t = OETF(linear)`, maths, `linear = OETF^-1(t)`), so the same controls
//! feel the same in both positions (`pre` = true).

use sq_core_color::basic_tone_curves as curves;
use sq_core_color::{BoardZone, HSLSecondaryExt, NeutralExt, ZoneBoardExt, ZoneSettingExt};
use sq_core_model::curve_math::{self, Spline};
use sq_core_model::{
    BasicCorrection, BasicToneModel, ColorWheels, CreativeLook, CurvePoint, HSLMaskMode, HSLSecondary, HueCurves,
    RGBCurves, Vignette, ZoneBoard,
};

use super::gamut::{Gamut, WhitePoint};
use super::tone_math::{CONTRAST_PIVOT, hue_turns, rotate_about_gray, sat_vib, smooth, wheel_offset};
use super::transfer::{bt709_inverse_oetf as inv_oetf, bt709_oetf as oetf};
use super::vec::{Mat3, Vec3};

fn clamp(v: f32, lo: f32, hi: f32) -> f32 {
    v.clamp(lo, hi)
}

fn oetf3(v: Vec3) -> Vec3 {
    v.map(oetf)
}

fn inv_oetf3(v: Vec3) -> Vec3 {
    v.map(inv_oetf)
}

// MARK: Basic Correction

/// Lumetri Basic Correction: White Balance (Temperature, Tint) and Exposure act on linear light; Contrast, Highlights,
/// Shadows, Whites, Blacks on the tone signal; then Saturation and Vibrance. Two tone models: `Lumetri` (new grades) runs
/// the `basic_tone_curves` per channel, `Legacy` (projects saved before it) keeps the old luma-masked maths.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedBasic {
    pub(crate) lumetri: bool,
    pub(crate) ev: f32,
    pub(crate) con: f32,
    pub(crate) hi: f32,
    pub(crate) sh: f32,
    pub(crate) wh: f32,
    pub(crate) bl: f32,
    /// White balance matrix (identity when off).
    pub wb: Mat3,
    pub(crate) has_wb: bool,
    pub(crate) exposure_scale: f32,
    pub(crate) has_exposure: bool,
    pub(crate) contrast_k: f32,
    pub(crate) highlights: f32,
    pub(crate) shadows: f32,
    pub(crate) black_point: f32,
    pub(crate) white_point: f32,
    pub(crate) has_contrast: bool,
    pub(crate) has_highlights: bool,
    pub(crate) has_shadows: bool,
    pub(crate) has_levels: bool,
    pub(crate) saturation: f32,
    pub(crate) vibrance: f32,
    pub(crate) luma: Vec3,
}

/// 1e6 / 6504 K, the white balance reference in mired.
const CCT_REFERENCE: f64 = 1e6 / 6504.0;

impl PreparedBasic {
    /// `gamut`: the primaries the block's linear signal is in (the source gamut before the Input LUT, Rec.709 after it).
    pub fn new(c: &BasicCorrection, gamut: &Gamut) -> PreparedBasic {
        let temp = clamp(c.temperature, -100.0, 100.0);
        let tint = clamp(c.tint, -100.0, 100.0);
        let has_wb = temp != 0.0 || tint != 0.0;
        let wb = if has_wb {
            let mired = CCT_REFERENCE - f64::from(temp);
            // Positive tint -> magenta image: the assumed scene white is greenish (Duv > 0).
            let scene = WhitePoint::xy(1e6 / mired, f64::from(tint) * 0.0002);
            let reference = WhitePoint::xy(1e6 / CCT_REFERENCE, 0.0);
            let a = WhitePoint::bradford(WhitePoint::xyz(scene), WhitePoint::xyz(reference));
            gamut.rgb_to_xyz_double.inverse().mul_mat(&a).mul_mat(&gamut.rgb_to_xyz_double).to_f32()
        } else {
            Mat3::IDENTITY
        };
        let ev = clamp(c.exposure, -5.0, 5.0);
        let con = clamp(c.contrast, -100.0, 100.0) / 100.0;
        let h = clamp(c.highlights, -100.0, 100.0) / 100.0;
        let s = clamp(c.shadows, -100.0, 100.0) / 100.0;
        let w = clamp(c.whites, -100.0, 100.0) / 100.0;
        let b = clamp(c.blacks, -100.0, 100.0) / 100.0;
        PreparedBasic {
            lumetri: c.model == BasicToneModel::Lumetri,
            ev,
            con,
            hi: h,
            sh: s,
            wh: w,
            bl: b,
            wb,
            has_wb,
            exposure_scale: ev.exp2(),
            has_exposure: ev != 0.0,
            contrast_k: if con >= 0.0 { 1.0 + 0.8 * con } else { 1.0 + 0.7 * con },
            highlights: 0.3 * h,
            shadows: if s > 0.0 { 1.4 * s } else { s },
            black_point: -0.1 * b,
            white_point: 1.0 - 0.2 * w,
            has_contrast: con != 0.0,
            has_highlights: h != 0.0,
            has_shadows: s != 0.0,
            has_levels: w != 0.0 || b != 0.0,
            saturation: clamp(c.saturation, 0.0, 200.0) / 100.0,
            vibrance: clamp(c.vibrance, -100.0, 100.0) / 100.0,
            luma: gamut.luma_row,
        }
    }

    fn has_linear(&self) -> bool {
        self.has_wb || self.has_exposure
    }

    fn has_tone_stage(&self) -> bool {
        self.has_contrast
            || self.has_shadows
            || self.has_highlights
            || self.has_levels
            || self.saturation != 1.0
            || self.vibrance != 0.0
    }

    /// `pre`: the signal is source-linear light (block before the Input LUT); otherwise it is the tone signal.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut x = c;
        if self.has_linear() {
            let mut lin = if pre { x } else { inv_oetf3(x) };
            if self.has_wb {
                lin = self.wb.mul_vec(lin);
            }
            if self.has_exposure {
                if self.lumetri && self.ev > 0.0 {
                    lin = Vec3::new(
                        curves::exposure(lin.x, self.ev),
                        curves::exposure(lin.y, self.ev),
                        curves::exposure(lin.z, self.ev),
                    );
                } else {
                    lin *= self.exposure_scale;
                }
            }
            x = if pre { lin } else { oetf3(lin) };
        }
        if self.has_tone_stage() {
            let mut t = if pre { oetf3(x) } else { x };
            t = if self.lumetri { t.map(|v| self.lumetri_tone(v)) } else { self.legacy_tone(t) };
            t = sat_vib(t, self.saturation, self.vibrance, self.luma);
            x = if pre { inv_oetf3(t) } else { t };
        }
        x
    }

    /// Legacy tone part (model 0): linear contrast, luma-masked Shadows/Highlights, global levels.
    fn legacy_tone(&self, c: Vec3) -> Vec3 {
        let mut t = c;
        if self.has_contrast {
            t = Vec3::splat(CONTRAST_PIVOT) + (t - Vec3::splat(CONTRAST_PIVOT)) * self.contrast_k;
        }
        // Shadows scale the dark end multiplicatively (black stays black); Highlights add a soft-masked offset.
        if self.has_shadows {
            let y = self.luma.dot(t);
            t *= 1.0 + self.shadows * (1.0 - smooth(0.0, 0.6, y));
        }
        if self.has_highlights {
            let y = self.luma.dot(t);
            t += Vec3::splat(self.highlights * smooth(0.3, 1.0, y));
        }
        if self.has_levels {
            t = (t - Vec3::splat(self.black_point)) / (self.white_point - self.black_point);
        }
        t
    }

    /// One channel of the Lumetri tone part (same order as `basic_tone_curves::tone_after_exposure`).
    fn lumetri_tone(&self, x: f32) -> f32 {
        let mut t = x;
        if self.has_contrast {
            t = curves::contrast(t, self.con);
        }
        if self.has_highlights {
            t = curves::highlights(t, self.hi);
        }
        if self.has_shadows {
            t = curves::shadows(t, self.sh);
        }
        if self.has_levels {
            t = curves::blacks(curves::whites(t, self.wh), self.bl);
        }
        t
    }
}

// MARK: Creative (tone part; the look LUT is a separate op)

/// Creative adjustments without the look LUT: Faded Film, Vibrance, Saturation, Shadow/Highlight Tint.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedCreative {
    pub(crate) fade: f32,
    pub(crate) saturation: f32,
    pub(crate) vibrance: f32,
    pub(crate) shadow_tint: Vec3,
    pub(crate) highlight_tint: Vec3,
    pub(crate) balance: f32,
    pub(crate) has_tint: bool,
    pub(crate) luma: Vec3,
}

impl PreparedCreative {
    /// Prepares the block.
    pub fn new(c: &CreativeLook, gamut: &Gamut) -> PreparedCreative {
        PreparedCreative {
            fade: 0.16 * clamp(c.faded_film, 0.0, 100.0) / 100.0,
            saturation: clamp(c.saturation, 0.0, 200.0) / 100.0,
            vibrance: clamp(c.vibrance, -100.0, 100.0) / 100.0,
            shadow_tint: 0.25 * wheel_offset(&c.shadow_tint),
            highlight_tint: 0.25 * wheel_offset(&c.highlight_tint),
            balance: clamp(c.tint_balance, -100.0, 100.0) / 100.0,
            has_tint: !c.shadow_tint.is_neutral() || !c.highlight_tint.is_neutral(),
            luma: gamut.luma_row,
        }
    }

    /// Applies the block.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut t = if pre { oetf3(c) } else { c };
        if self.fade != 0.0 {
            t = t * (1.0 - self.fade) + Vec3::splat(self.fade * 0.85);
        }
        if self.has_tint {
            let y = self.luma.dot(t);
            let ms = 1.0 - smooth(0.15 + 0.25 * self.balance, 0.65 + 0.25 * self.balance, y);
            let mh = smooth(0.35 + 0.25 * self.balance, 0.85 + 0.25 * self.balance, y);
            t += ms * self.shadow_tint + mh * self.highlight_tint;
        }
        t = sat_vib(t, self.saturation, self.vibrance, self.luma);
        if pre { inv_oetf3(t) } else { t }
    }
}

// MARK: Wheels

/// Three-way color wheels: lift (shadows, additive), gamma (midtones, power) and gain (highlights, multiplicative),
/// weighted by soft luminance masks.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedWheels {
    pub(crate) lift: Vec3,
    pub(crate) gamma_exponent: Vec3,
    pub(crate) has_gamma: bool,
    pub(crate) gain: Vec3,
    pub(crate) saturation: f32,
    pub(crate) luma: Vec3,
}

impl PreparedWheels {
    /// Prepares the block.
    pub fn new(w: &ColorWheels, gamut: &Gamut) -> PreparedWheels {
        let n = |v: f32| clamp(v, -100.0, 100.0) / 100.0;
        let m = 0.5 * wheel_offset(&w.midtones) + Vec3::splat(0.45 * n(w.midtones_luma));
        PreparedWheels {
            lift: 0.22 * wheel_offset(&w.shadows) + Vec3::splat(0.15 * n(w.shadows_luma)),
            gamma_exponent: Vec3::new((-m.x).exp2(), (-m.y).exp2(), (-m.z).exp2()),
            has_gamma: !w.midtones.is_neutral() || w.midtones_luma != 0.0,
            gain: 0.3 * wheel_offset(&w.highlights) + Vec3::splat(0.25 * n(w.highlights_luma)),
            saturation: clamp(w.saturation, 0.0, 200.0) / 100.0,
            luma: gamut.luma_row,
        }
    }

    /// Applies the block. Each stage takes its luminance mask from the running signal, so the chain is a composition of
    /// monotone maps: at the slider limits the gray ramp never folds.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut t = if pre { oetf3(c) } else { c };
        t += (1.0 - smooth(0.0, 0.5, self.luma.dot(t))) * self.lift;
        if self.has_gamma {
            let y = self.luma.dot(t);
            let wm = smooth(0.0, 0.5, y) * (1.0 - smooth(0.5, 1.0, y));
            let g = self.gamma_exponent;
            let p = Vec3::new(t.x.max(0.0).powf(g.x), t.y.max(0.0).powf(g.y), t.z.max(0.0).powf(g.z));
            t += (p - t) * wm;
        }
        t = t * (Vec3::ONE + smooth(0.35, 1.15, self.luma.dot(t)) * self.gain);
        t = sat_vib(t, self.saturation, 0.0, self.luma);
        if pre { inv_oetf3(t) } else { t }
    }
}

// MARK: Vignette

/// Vignette on the signal.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedVignette {
    pub(crate) amount: f32,
    pub(crate) start: f32,
    pub(crate) feather: f32,
    pub(crate) exponent: f32,
    pub(crate) aspect_mix: f32,
}

impl PreparedVignette {
    /// Prepares the block.
    pub fn new(v: &Vignette) -> PreparedVignette {
        let mid = clamp(v.midpoint, 0.0, 100.0) / 100.0;
        let r = clamp(v.roundness, -100.0, 100.0) / 100.0;
        PreparedVignette {
            amount: clamp(v.amount, -5.0, 5.0),
            start: 1.3 - 1.1 * mid,
            feather: 0.1 + 1.4 * clamp(v.feather, 0.0, 100.0) / 100.0,
            exponent: 2.0 + 2.0 * (-r).max(0.0),
            aspect_mix: r.max(0.0),
        }
    }

    /// `uv`: 0...1 position in the frame (y down); `aspect`: frame width / height.
    pub fn apply(&self, c: Vec3, uv: [f32; 2], aspect: f32, pre: bool) -> Vec3 {
        let px = (uv[0] - 0.5) * 2.0 * (1.0 + (aspect - 1.0) * self.aspect_mix);
        let py = (uv[1] - 0.5) * 2.0;
        let e = if self.exponent > 2.0001 {
            (px.abs().powf(self.exponent) + py.abs().powf(self.exponent)).powf(1.0 / self.exponent)
        } else {
            (px * px + py * py).sqrt()
        };
        let m = smooth(self.start, self.start + self.feather, e);
        // A gain of 2^(amount*m) stops on linear light is 2^(0.45*amount*m) on the gamma-encoded signal.
        if pre { c * (self.amount * m).exp2() } else { c * (0.45 * self.amount * m).exp2() }
    }
}

// MARK: Hue Saturation Curves

/// Lumetri Hue Saturation Curves. Five curves (Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat) all sample the
/// color that enters the block, then adjust it together: hue shift (up to +-60 degrees), saturation (x0...x2 around the
/// luma) and luma (+-1 stop). The hue-keyed adjustments fade out towards gray. y = 0.5 is "no change".
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedHueCurves {
    /// Rows 0...63 hold (hueVsSat, hueVsHue, hueVsLuma, lumaVsSat), rows 64...127 hold (satVsSat, 0, 0, 0).
    pub table: Vec<[f32; 4]>,
    pub(crate) luma: Vec3,
}

/// Samples per curve.
pub const HUE_CURVE_COUNT: usize = 64;
const MAX_HUE_SHIFT: f32 = std::f32::consts::PI / 3.0;

impl PreparedHueCurves {
    /// Prepares the block.
    pub fn new(h: &HueCurves, gamut: &Gamut) -> PreparedHueCurves {
        let n = HUE_CURVE_COUNT;
        let hs = Self::periodic(&h.hue_vs_sat, n);
        let hh = Self::periodic(&h.hue_vs_hue, n);
        let hl = Self::periodic(&h.hue_vs_luma, n);
        let ls = Self::linear(&h.luma_vs_sat, n);
        let ss = Self::linear(&h.sat_vs_sat, n);
        let mut rows = vec![[0.0; 4]; 2 * n];
        for k in 0..n {
            rows[k] = [hs[k], hh[k], hl[k], ls[k]];
            rows[n + k] = [ss[k], 0.0, 0.0, 0.0];
        }
        PreparedHueCurves { table: rows, luma: gamut.luma_row }
    }

    /// Control points as the maths sees them: clamped to 0...1, sorted, points closer than 1e-4 merged (the later wins).
    pub fn clean(pts: &[CurvePoint]) -> Vec<CurvePoint> {
        let mut p: Vec<CurvePoint> =
            pts.iter().map(|q| CurvePoint { x: clamp(q.x, 0.0, 1.0), y: clamp(q.y, 0.0, 1.0) }).collect();
        p.sort_by(|a, b| a.x.total_cmp(&b.x));
        let mut out: Vec<CurvePoint> = Vec::new();
        for q in p {
            match out.last_mut() {
                Some(l) if q.x - l.x < 1e-4 => *l = q,
                _ => out.push(q),
            }
        }
        out
    }

    /// n samples at x = k/n of a curve that wraps around (hue). The curve is one period [0, 1): a point at x = 1 is dropped.
    /// The period is repeated to both sides and sampled in the middle copy, so the seam is as smooth as any other part.
    /// One point = a flat curve at its y, none = flat 0.5 (never the diagonal).
    pub fn periodic(pts: &[CurvePoint], n: usize) -> Vec<f32> {
        let p = Self::clean(pts);
        let Some(first) = p.first() else { return vec![0.5; n] };
        let period: Vec<CurvePoint> = p.iter().copied().filter(|q| q.x < 1.0).collect();
        if period.len() < 2 {
            return vec![period.first().unwrap_or(first).y; n];
        }
        let copy = |shift: f32| period.iter().map(move |q| CurvePoint { x: (q.x + shift) / 3.0, y: q.y });
        let ext: Vec<CurvePoint> = copy(0.0).chain(copy(1.0)).chain(copy(2.0)).collect();
        let spline = Spline::new(ext);
        (0..n).map(|k| spline.value((k as f32 / n as f32 + 1.0) / 3.0)).collect()
    }

    /// n samples at x = k/(n-1) of a curve over 0...1 (luma, saturation). One point = flat at its y, none = flat 0.5.
    pub fn linear(pts: &[CurvePoint], n: usize) -> Vec<f32> {
        let p = Self::clean(pts);
        if p.len() < 2 {
            return vec![p.first().map_or(0.5, |q| q.y); n];
        }
        let spline = Spline::new(p);
        (0..n).map(|k| spline.value(k as f32 / (n - 1) as f32)).collect()
    }

    fn hue_sample(&self, column: usize, h: f32) -> f32 {
        let n = HUE_CURVE_COUNT;
        let p = h * n as f32;
        let i = (p as usize).min(n - 1);
        let f = p - i as f32;
        let (a, b) = (self.table[i][column], self.table[(i + 1) % n][column]);
        a + (b - a) * f
    }

    fn linear_sample(&self, row0: usize, column: usize, x: f32) -> f32 {
        let n = HUE_CURVE_COUNT;
        let p = x.clamp(0.0, 1.0) * (n - 1) as f32;
        let i = (p as usize).min(n - 2);
        let f = p - i as f32;
        let (a, b) = (self.table[row0 + i][column], self.table[row0 + i + 1][column]);
        a + (b - a) * f
    }

    /// Applies the block.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut t = if pre { oetf3(c) } else { c };
        let (mx, mn) = (t.max_elem(), t.min_elem());
        let d = mx - mn;
        let hue = hue_turns(t, mx, d);
        let w = smooth(0.005, 0.05, d);
        let sv = if mx > 1e-4 { (d / mx).clamp(0.0, 1.0) } else { 0.0 };
        let y0 = self.luma.dot(t);
        let (vs, vh, vl) = (self.hue_sample(0, hue), self.hue_sample(1, hue), self.hue_sample(2, hue));
        let ls = self.linear_sample(0, 3, y0);
        let ss = self.linear_sample(HUE_CURVE_COUNT, 0, sv);
        // Hue: rotate the chroma about the gray axis.
        let theta = (vh - 0.5) * 2.0 * MAX_HUE_SHIFT * w;
        if theta != 0.0 {
            t = rotate_about_gray(t, theta);
        }
        let s = (1.0 + (2.0 * vs - 1.0) * w) * (2.0 * ls) * (2.0 * ss);
        if s != 1.0 {
            let y = self.luma.dot(t);
            t = Vec3::splat(y) + (t - Vec3::splat(y)) * s.max(0.0);
        }
        let g = ((vl - 0.5) * 2.0 * w).exp2();
        if g != 1.0 {
            t *= g;
        }
        if pre { inv_oetf3(t) } else { t }
    }
}

// MARK: Color Range (HSL secondary)

/// Color Range: a soft mask from the color that enters the block (hue distance to the center, HSV saturation, luma, each
/// with a smoothstep edge of `softness`) mixes in a correction (white balance and exposure gains, a hue rotation about the
/// gray axis, saturation about the luma). Hue in turns (0...1), saturation and luma 0...1.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedHslSecondary {
    pub(crate) center: f32,
    pub(crate) half_width: f32,
    pub(crate) hue_soft: f32,
    pub(crate) all_hues: bool,
    pub(crate) sat_lo: f32,
    pub(crate) sat_hi: f32,
    pub(crate) sat_soft: f32,
    pub(crate) lum_lo: f32,
    pub(crate) lum_hi: f32,
    pub(crate) lum_soft: f32,
    pub(crate) invert: bool,
    pub(crate) gains: Vec3,
    pub(crate) theta: f32,
    pub(crate) saturation: f32,
    pub(crate) luma: Vec3,
    /// Color-volume mode: the mask is a soft ball around `volume_center` in the volume (s cos h, s sin h, luma).
    pub(crate) volume: bool,
    pub(crate) volume_center: Vec3,
    pub(crate) volume_radius: f32,
    pub(crate) volume_edge: f32,
}

const MAX_HUE_SOFT: f32 = 60.0 / 360.0;
const MAX_RANGE_SOFT: f32 = 0.25;
const MIN_SOFT: f32 = 1e-3;
/// Radius of the color-volume ball at 100 percent (the volume is about 2 wide).
const MAX_VOLUME_RADIUS: f32 = 1.0;

impl PreparedHslSecondary {
    /// Prepares the block.
    pub fn new(range: &HSLSecondary, gamut: &Gamut) -> PreparedHslSecondary {
        let r = range.clamped();
        let k = r.softness / 100.0;
        let sat_soft = (k * MAX_RANGE_SOFT).max(MIN_SOFT);
        // Temperature warms (red up, blue down), tint goes magenta (green down); exposure in stops of linear light is
        // 0.45 x stops on the gamma-encoded signal (as the vignette).
        let tmp = r.temperature / 100.0;
        let tnt = r.tint / 100.0;
        let ev = 0.45 * r.exposure;
        let ang = r.hue_center / 360.0 * 2.0 * std::f32::consts::PI;
        let vs = r.volume_sat / 100.0;
        PreparedHslSecondary {
            center: r.hue_center / 360.0,
            half_width: r.hue_width / 720.0,
            hue_soft: (k * MAX_HUE_SOFT).max(MIN_SOFT),
            all_hues: r.hue_width >= 360.0,
            sat_lo: r.sat_min / 100.0,
            sat_hi: r.sat_max / 100.0,
            sat_soft,
            lum_lo: r.lum_min / 100.0,
            lum_hi: r.lum_max / 100.0,
            lum_soft: sat_soft,
            invert: r.invert,
            gains: Vec3::new(
                (ev + 0.25 * tmp + 0.1 * tnt).exp2(),
                (ev - 0.2 * tnt).exp2(),
                (ev - 0.25 * tmp + 0.1 * tnt).exp2(),
            ),
            theta: r.hue_shift * std::f32::consts::PI / 180.0,
            saturation: r.saturation / 100.0,
            luma: gamut.luma_row,
            volume: r.mask_mode == HSLMaskMode::Volume,
            volume_center: Vec3::new(vs * ang.cos(), vs * ang.sin(), r.volume_lum / 100.0),
            volume_radius: r.volume_radius / 100.0 * MAX_VOLUME_RADIUS,
            volume_edge: (k * MAX_VOLUME_RADIUS * 0.5).max(MIN_SOFT),
        }
    }

    /// Position of a tone-signal color in the color volume: HSV saturation on the hue circle, luma up. Grays sit on the
    /// axis whatever their (undefined) hue, so the ball is continuous there.
    fn volume_point(&self, t: Vec3) -> Vec3 {
        let (mx, mn) = (t.max_elem(), t.min_elem());
        let d = mx - mn;
        let sv = if mx > 1e-4 { (d / mx).clamp(0.0, 1.0) } else { 0.0 };
        let ang = hue_turns(t, mx, d) * 2.0 * std::f32::consts::PI;
        Vec3::new(sv * ang.cos(), sv * ang.sin(), self.luma.dot(t))
    }

    /// 0...1: how much of the correction this tone-signal color gets.
    pub fn mask(&self, t: Vec3) -> f32 {
        if self.volume {
            let m = 1.0
                - smooth(
                    self.volume_radius,
                    self.volume_radius + self.volume_edge,
                    (self.volume_point(t) - self.volume_center).length(),
                );
            return if self.invert { 1.0 - m } else { m };
        }
        let (mx, mn) = (t.max_elem(), t.min_elem());
        let d = mx - mn;
        let mut wh = 1.0;
        if !self.all_hues {
            let hue = hue_turns(t, mx, d);
            let mut dh = hue - self.center;
            dh -= (dh + 0.5).floor();
            wh = (1.0 - smooth(self.half_width, self.half_width + self.hue_soft, dh.abs())) * smooth(0.005, 0.05, d);
        }
        let sv = if mx > 1e-4 { (d / mx).clamp(0.0, 1.0) } else { 0.0 };
        let ws = smooth(self.sat_lo - self.sat_soft, self.sat_lo, sv)
            * (1.0 - smooth(self.sat_hi, self.sat_hi + self.sat_soft, sv));
        let y = self.luma.dot(t);
        // Luma min 0 % / max 100 % are open ends: below-black and super-white values stay in the range.
        let wl = (if self.lum_lo > 0.0 { smooth(self.lum_lo - self.lum_soft, self.lum_lo, y) } else { 1.0 })
            * (if self.lum_hi < 1.0 { 1.0 - smooth(self.lum_hi, self.lum_hi + self.lum_soft, y) } else { 1.0 });
        let m = wh * ws * wl;
        if self.invert { 1.0 - m } else { m }
    }

    /// Applies the block.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let t = if pre { oetf3(c) } else { c };
        let w = self.mask(t);
        if w <= 0.0 {
            return c;
        }
        let mut o = t * self.gains;
        if self.theta != 0.0 {
            o = rotate_about_gray(o, self.theta);
        }
        if self.saturation != 1.0 {
            let y = self.luma.dot(o);
            o = Vec3::splat(y) + (o - Vec3::splat(y)) * self.saturation;
        }
        let out = t + (o - t) * w;
        if pre { inv_oetf3(out) } else { out }
    }
}

// MARK: Zone Board

/// Zone Board: four zones (Global, Shadows, Midtones, Highlights) on the tone signal. Per zone a color puck (a zero-mean
/// tint like the wheels), a saturation factor and an exposure in stops. Order: exposure, tint, saturation.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedZoneBoard {
    pub(crate) offsets: [Vec3; 4],
    pub(crate) saturations: [f32; 4],
    pub(crate) gains: [f32; 4],
    pub(crate) luma: Vec3,
}

/// Strongest tint per zone at the rim of the puck square.
const TINT_SCALE: [f32; 4] = [0.15, 0.22, 0.2, 0.25];

impl PreparedZoneBoard {
    /// Prepares the block.
    pub fn new(board: &ZoneBoard, gamut: &Gamut) -> PreparedZoneBoard {
        let b = board.clamped();
        let mut z = PreparedZoneBoard {
            offsets: [Vec3::ZERO; 4],
            saturations: [1.0; 4],
            gains: [1.0; 4],
            luma: gamut.luma_row,
        };
        for (i, zone) in BoardZone::ALL.into_iter().enumerate() {
            let v = b.zone(zone);
            z.offsets[i] = TINT_SCALE[i] * wheel_offset(&v.wheel_value());
            z.saturations[i] = v.saturation_factor();
            // Exposure in stops of linear light is 0.45 x stops on the gamma-encoded signal (as the vignette).
            z.gains[i] = (0.45 * v.exposure_stops()).exp2();
        }
        z
    }

    /// Weights of Global, Shadows, Midtones, Highlights for a tone-signal luma.
    pub fn weights(y: f32) -> [f32; 4] {
        let sh = 1.0 - smooth(0.0, 0.5, y);
        let mid = smooth(0.0, 0.5, y) * (1.0 - smooth(0.5, 1.0, y));
        let hi = smooth(0.35, 1.15, y);
        [1.0, sh, mid, hi]
    }

    /// Applies the block.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let mut t = if pre { oetf3(c) } else { c };
        let w = Self::weights(self.luma.dot(t));
        let (mut gain, mut sat, mut off) = (1.0f32, 1.0f32, Vec3::ZERO);
        for (z, wz) in w.into_iter().enumerate() {
            gain *= 1.0 + wz * (self.gains[z] - 1.0);
            sat += wz * (self.saturations[z] - 1.0);
            off += wz * self.offsets[z];
        }
        t = t * gain + off;
        if sat != 1.0 {
            let y = self.luma.dot(t);
            t = Vec3::splat(y) + (t - Vec3::splat(y)) * sat.max(0.0);
        }
        if pre { inv_oetf3(t) } else { t }
    }
}

// MARK: Curves

/// Samples per curve table.
pub const CURVE_TABLE_COUNT: usize = 64;

/// Monotone cubic (Fritsch-Carlson) through control points, sampled into a table (master composed with each channel).
#[derive(Clone, Debug, PartialEq)]
pub struct CurveTable {
    /// One RGB entry per sample.
    pub table: Vec<Vec3>,
    /// The curves are the diagonal.
    pub is_identity: bool,
}

impl CurveTable {
    /// Samples the curves.
    pub fn new(curves: &RGBCurves) -> CurveTable {
        let master = curve_math::sample(&curves.master, CURVE_TABLE_COUNT);
        let sr = Spline::new(curve_math::normalized(&curves.red));
        let sg = Spline::new(curve_math::normalized(&curves.green));
        let sb = Spline::new(curve_math::normalized(&curves.blue));
        let table = master.iter().map(|&m| Vec3::new(sr.value(m), sg.value(m), sb.value(m))).collect();
        CurveTable { table, is_identity: curves.is_neutral() }
    }

    /// Applies the curves.
    pub fn apply(&self, c: Vec3, pre: bool) -> Vec3 {
        let t = if pre { oetf3(c) } else { c };
        let mut o = t;
        for ch in 0..3 {
            let x = t[ch].clamp(0.0, 1.0);
            let p = x * (CURVE_TABLE_COUNT - 1) as f32;
            let i = (p as usize).min(CURVE_TABLE_COUNT - 2);
            let f = p - i as f32;
            let v = self.table[i][ch] + (self.table[i + 1][ch] - self.table[i][ch]) * f;
            o[ch] = v + (t[ch] - x);
        }
        if pre { inv_oetf3(o) } else { o }
    }
}
