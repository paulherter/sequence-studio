// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorMatch.swift
//! Color Match (Premiere Lumetri "Color Wheels & Match" > Apply Match). The reference is measured once ("Set
//! Reference": the Program frame at the playhead, usually on another shot) and stored with the Color effect as
//! statistics, so the match never needs the reference shot again. "Match" measures the clip's own frame and sets the
//! Color Wheels (three wheels, their luma sliders, Wheels Saturation) so the clip's shadow, midtone and highlight color
//! and its colorfulness come out like the reference's. Pure maths, display-free.

use crate::auto_tone_solver::{self, smooth};
use crate::color_effect::{ColorEffectExt, NeutralExt};
use crate::color_match_oklab::{ColorMatchTargets, Oklab};
use crate::input_color_space::ColorSpaceIdExt;
use crate::vec3::{V3, add, clamp3, length_squared, max_of, min_of, mul, scale, sub, sum};
use sq_core_model::{
    BasicCorrection, ColorEffect, ColorMatchReference, ColorMatchStats, ColorSectionKind, ColorSpaceID, ColorWheels,
    Project, WheelValue,
};

/// Measuring a frame into [`ColorMatchStats`].
pub trait ColorMatchStatsExt: Sized {
    /// Rec.709 luma weights.
    const LUMA: V3;
    /// Shadow, midtone and highlight weights of a luma value: they sum to 1.
    fn band_weights(y: f32) -> V3;
    /// Measures a frame of display-encoded pixels; `None` for fewer than 16 finite pixels.
    fn measure(display: &[V3]) -> Option<Self>;
    /// The three band means.
    fn bands(&self) -> [V3; 3];
}

impl ColorMatchStatsExt for ColorMatchStats {
    const LUMA: V3 = [0.2126, 0.7152, 0.0722];

    fn band_weights(y: f32) -> V3 {
        let s = 1.0 - smooth(0.0, 0.5, y);
        let h = smooth(0.5, 1.0, y);
        [s, (1.0 - s - h).max(0.0), h]
    }

    fn measure(display: &[V3]) -> Option<ColorMatchStats> {
        let mut band_sum = [[0.0_f32; 3]; 3];
        let mut w: V3 = [0.0; 3];
        let mut chroma: f32 = 0.0;
        let mut n = 0usize;
        for p in display.iter().filter(|p| p.iter().all(|c| c.is_finite())) {
            let c = clamp3(*p, 0.0, 1.5);
            let y = sum(mul(Self::LUMA, c));
            let b = Self::band_weights(y);
            for i in 0..3 {
                band_sum[i] = add(band_sum[i], scale(c, b[i]));
            }
            w = add(w, b);
            let d = sub(c, [y; 3]);
            chroma += length_squared(d).sqrt();
            n += 1;
        }
        if n < 16 {
            return None;
        }
        let mean = |i: usize, wi: f32| -> V3 {
            if wi > 1e-4 { band_sum[i].map(|s| s / wi) } else { [[0.1, 0.45, 0.85][i]; 3] }
        };
        Some(ColorMatchStats {
            shadows: mean(0, w[0]),
            midtones: mean(1, w[1]),
            highlights: mean(2, w[2]),
            weights: w.map(|x| x / n as f32),
            chroma: chroma / n as f32,
        })
    }

    fn bands(&self) -> [V3; 3] {
        [self.shadows, self.midtones, self.highlights]
    }
}

/// Whether the project holds a stored Color Match reference.
pub trait ProjectColorMatchExt {
    /// Any Color effect carries a Color Match reference (file version 43).
    fn contains_color_match(&self) -> bool;
}

impl ProjectColorMatchExt for Project {
    fn contains_color_match(&self) -> bool {
        self.timelines.iter().any(|t| {
            t.tracks.iter().any(|tr| {
                tr.clips()
                    .iter()
                    .any(|c| c.effects.iter().any(|e| e.grade.as_ref().is_some_and(|g| g.match_reference.is_some())))
            })
        })
    }
}

/// The maths of the Color Wheels section.
pub mod color_wheels_model {
    use super::*;

    /// The fully saturated color of a hue in degrees.
    pub(crate) fn hue_rgb(hue_degrees: f32) -> V3 {
        let mut h = hue_degrees / 360.0;
        h -= h.floor();
        let ch = |o: f32| -> f32 {
            let mut x = h + o;
            x -= x.floor();
            ((x * 6.0 - 3.0).abs() - 1.0).clamp(0.0, 1.0)
        };
        [ch(0.0), ch(2.0 / 3.0), ch(1.0 / 3.0)]
    }

    /// The RGB offset a wheel puck stands for (sums to zero).
    pub fn offset(w: &WheelValue) -> V3 {
        if w.amount <= 0.0 || w.amount.is_nan() {
            return [0.0; 3];
        }
        let c = hue_rgb(w.hue);
        let mean = [sum(c) / 3.0; 3];
        scale(sub(c, mean), w.amount.min(1.0))
    }

    /// The wheel whose offset is closest to `v` (inverse of [`offset`]).
    pub fn wheel(v: V3) -> WheelValue {
        let z = sub(v, [sum(v) / 3.0; 3]);
        let (mx, mn) = (max_of(z), min_of(z));
        if mx - mn <= 1e-6 || (mx - mn).is_nan() {
            return WheelValue::default();
        }
        // HSV hue of z (adding gray does not change it).
        let mut h = if mx == z[0] {
            (z[1] - z[2]) / (mx - mn)
        } else if mx == z[1] {
            2.0 + (z[2] - z[0]) / (mx - mn)
        } else {
            4.0 + (z[0] - z[1]) / (mx - mn)
        };
        h *= 60.0;
        if h < 0.0 {
            h += 360.0;
        }
        let c = hue_rgb(h);
        let unit = sub(c, [sum(c) / 3.0; 3]);
        let len = length_squared(unit).sqrt();
        let amount = (length_squared(z).sqrt() / len.max(1e-6)).min(1.0);
        WheelValue { hue: h, amount }
    }

    /// The wheels reduced to the numbers the pixel maths needs.
    pub(crate) struct Prepared {
        lift: V3,
        gamma_exponent: V3,
        has_gamma: bool,
        gain: V3,
        saturation: f32,
    }

    impl Prepared {
        pub(crate) fn new(w: &ColorWheels) -> Prepared {
            fn n(v: f32) -> f32 {
                v.clamp(-100.0, 100.0) / 100.0
            }
            let lift = add(scale(offset(&w.shadows), 0.22), [0.15 * n(w.shadows_luma); 3]);
            let m = add(scale(offset(&w.midtones), 0.5), [0.45 * n(w.midtones_luma); 3]);
            Prepared {
                lift,
                gamma_exponent: m.map(|x| (-x).exp2()),
                has_gamma: !w.midtones.is_neutral() || w.midtones_luma != 0.0,
                gain: add(scale(offset(&w.highlights), 0.3), [0.25 * n(w.highlights_luma); 3]),
                saturation: w.saturation.clamp(0.0, 200.0) / 100.0,
            }
        }

        pub(crate) fn apply(&self, c: V3) -> V3 {
            let luma = ColorMatchStats::LUMA;
            let mut t = c;
            t = add(t, scale(self.lift, 1.0 - smooth(0.0, 0.5, sum(mul(luma, t)))));
            if self.has_gamma {
                let y = sum(mul(luma, t));
                let wm = smooth(0.0, 0.5, y) * (1.0 - smooth(0.5, 1.0, y));
                let p = [
                    t[0].max(0.0).powf(self.gamma_exponent[0]),
                    t[1].max(0.0).powf(self.gamma_exponent[1]),
                    t[2].max(0.0).powf(self.gamma_exponent[2]),
                ];
                t = add(t, scale(sub(p, t), wm));
            }
            t = mul(t, add([1.0; 3], scale(self.gain, smooth(0.35, 1.15, sum(mul(luma, t))))));
            if self.saturation != 1.0 {
                let y = sum(mul(luma, t));
                t = add([y; 3], scale(sub(t, [y; 3]), self.saturation));
            }
            t
        }
    }

    /// The wheels applied to one display-encoded color.
    pub fn apply(c: V3, w: &ColorWheels) -> V3 {
        if NeutralExt::is_neutral(w) { c } else { Prepared::new(w).apply(c) }
    }

    /// The color that `apply` turns into `y` (fixed-point iteration).
    pub(crate) fn unapply(y: V3, p: &Prepared) -> V3 {
        let mut x = y;
        for _ in 0..24 {
            let d = sub(y, p.apply(x));
            x = add(x, d);
            if length_squared(d) < 1e-10 {
                break;
            }
        }
        x
    }
}

/// Solves the Color Wheels that make a clip look like a reference.
pub mod color_match_solver {
    use super::color_wheels_model::{self as model, Prepared};
    use super::*;

    const REGULARISATION: f32 = 0.02;
    const MAX_SAMPLES: usize = 1600;
    const FIT_SAMPLES: usize = 400;
    const PIXEL_WEIGHT: f32 = 0.5;

    /// Why Match cannot run on this Color effect (`None` = it can).
    pub fn block_reason(
        e: &ColorEffect,
        source: ColorSpaceID,
        reference: Option<&ColorMatchReference>,
    ) -> Option<String> {
        if source != ColorSpaceID::Rec709 {
            return Some(format!(
                "Match works on Rec. 709 footage. This clip is interpreted as {}; grade it by hand.",
                source.display_name()
            ));
        }
        if !e.is_enabled(ColorSectionKind::Wheels) {
            return Some("Turn on Wheels & Match to use Match.".to_string());
        }
        if e.is_enabled(ColorSectionKind::Vignette) && !ColorEffectExt::is_neutral(e, ColorSectionKind::Vignette) {
            return Some("Match would measure the Vignette too. Reset or switch off Vignette first.".to_string());
        }
        if reference.is_none() {
            return Some(
                "Set a reference frame first: park the playhead on the shot to match and press Set Reference."
                    .to_string(),
            );
        }
        None
    }

    fn u1() -> V3 {
        [2.0, -1.0, -1.0].map(|x| x / 6.0_f32.sqrt())
    }

    fn u2() -> V3 {
        [0.0, 1.0, -1.0].map(|x| x / 2.0_f32.sqrt())
    }

    fn wheels(p: &[f32], base: &ColorWheels) -> ColorWheels {
        let mut w = base.clone();
        let (a, b) = (u1(), u2());
        let off = |i: usize| add(scale(a, p[i]), scale(b, p[i + 1]));
        w.shadows_luma = (p[0] * 100.0).clamp(-100.0, 100.0);
        w.shadows = model::wheel(off(1));
        w.midtones_luma = (p[3] * 100.0).clamp(-100.0, 100.0);
        w.midtones = model::wheel(off(4));
        w.highlights_luma = (p[6] * 100.0).clamp(-100.0, 100.0);
        w.highlights = model::wheel(off(7));
        w.saturation = (100.0 * (1.0 + p[9])).clamp(0.0, 200.0);
        w
    }

    fn rounded(w: &ColorWheels) -> ColorWheels {
        fn r(v: f32, s: f32) -> f32 {
            (v * s).round() / s
        }
        fn rw(v: &WheelValue) -> WheelValue {
            let a = r(v.amount, 100.0);
            if a <= 0.0 { WheelValue::default() } else { WheelValue { hue: r(v.hue, 10.0) % 360.0, amount: a } }
        }
        let mut o = w.clone();
        o.shadows = rw(&w.shadows);
        o.midtones = rw(&w.midtones);
        o.highlights = rw(&w.highlights);
        o.shadows_luma = r(w.shadows_luma, 10.0);
        o.midtones_luma = r(w.midtones_luma, 10.0);
        o.highlights_luma = r(w.highlights_luma, 10.0);
        o.saturation = r(w.saturation, 10.0);
        o
    }

    /// The wheels that bring the clip's picture (`display`, with `current` wheels already applied) to `reference`;
    /// `None` when there are too few pixels or the wheels already are what Match would set.
    pub fn solve(display: &[V3], current: &ColorWheels, reference: &ColorMatchStats) -> Option<ColorWheels> {
        let finite: Vec<V3> = display.iter().filter(|p| p.iter().all(|c| c.is_finite())).copied().collect();
        if finite.len() < 16 {
            return None;
        }
        let stride = (finite.len() / MAX_SAMPLES).max(1);
        let mut px: Vec<V3> = finite.iter().step_by(stride).copied().collect();
        if !NeutralExt::is_neutral(current) {
            let prep = Prepared::new(current);
            px = px.into_iter().map(|p| model::unapply(p, &prep)).collect();
        }
        let clip_stats = ColorMatchStats::measure(&px)?;

        // Per-color Oklab targets (band shifts, chroma, hue-cast clamp, skin protection), fitted by running the wheels
        // model on a few hundred samples. Each band counts by the reference's share of it, not by the clip's pixel count.
        let fit_stride = (px.len() / FIT_SAMPLES).max(1);
        let samples: Vec<V3> = px.iter().step_by(fit_stride).copied().collect();
        let plan = ColorMatchTargets::new(&clip_stats, reference, &samples);
        let targets: Vec<V3> = samples.iter().map(|s| plan.target(Oklab::from_display(*s), *s)).collect();
        let band_share = [
            reference.weights[0] / clip_stats.weights[0].max(0.02),
            reference.weights[1] / clip_stats.weights[1].max(0.02),
            reference.weights[2] / clip_stats.weights[2].max(0.02),
        ];
        let mut sample_weight: Vec<f32> = samples
            .iter()
            .map(|c| {
                sum(mul(
                    ColorMatchStats::band_weights(sum(mul(ColorMatchStats::LUMA, clamp3(*c, 0.0, 1.5)))),
                    band_share,
                ))
            })
            .collect();
        let total = sample_weight.iter().fold(0.0_f32, |a, b| a + b).max(1e-6);
        sample_weight = sample_weight.into_iter().map(|w| PIXEL_WEIGHT * (w / total).sqrt()).collect();
        // The band means and colorfulness the targets add up to (the reference's, less what skin and the hue clamp hold
        // back): matched directly as well, so the wheels land the bands even where they cannot follow every color.
        let target_display: Vec<V3> = targets.iter().copied().map(Oklab::to_display).collect();
        let goal = ColorMatchStats::measure(&target_display)?;
        let goal_bands = goal.bands();
        let band_scale = reference.weights.map(f32::sqrt);
        let count = samples.len() * 3 + 20;

        let residual = |p: &[f32]| -> Vec<f32> {
            let prep = Prepared::new(&wheels(p, current));
            let mut r: Vec<f32> = Vec::with_capacity(count);
            let shown: Vec<V3> = samples.iter().map(|s| prep.apply(*s)).collect();
            for i in 0..samples.len() {
                let d = scale(sub(Oklab::from_display(shown[i]), targets[i]), sample_weight[i]);
                r.extend_from_slice(&d);
            }
            if let Some(s) = ColorMatchStats::measure(&shown) {
                for (b, band) in s.bands().iter().enumerate() {
                    let d = scale(sub(*band, goal_bands[b]), band_scale[b]);
                    r.extend_from_slice(&d);
                }
                r.push(s.chroma - goal.chroma);
            } else {
                r.extend_from_slice(&[0.0; 10]);
            }
            for v in p {
                r.push(REGULARISATION * v);
            }
            r
        };
        let cost = |r: &[f32]| -> f32 { r.iter().fold(0.0_f32, |a, b| a + b * b) };

        let n = 10;
        let mut p = vec![0.0_f32; n];
        let mut r = residual(&p);
        let mut c = cost(&r);
        let mut mu: f32 = 1e-3;
        for _ in 0..30 {
            // Numeric Jacobian (forward differences).
            let h: f32 = 1e-3;
            let mut jac = vec![vec![0.0_f32; n]; r.len()];
            for j in 0..n {
                let mut q = p.clone();
                q[j] += h;
                let rq = residual(&q);
                for k in 0..r.len() {
                    jac[k][j] = (rq[k] - r[k]) / h;
                }
            }
            let mut a = vec![vec![0.0_f32; n]; n];
            let mut g = vec![0.0_f32; n];
            for k in 0..r.len() {
                for i in 0..n {
                    g[i] += jac[k][i] * r[k];
                    for j in 0..n {
                        a[i][j] += jac[k][i] * jac[k][j];
                    }
                }
            }
            let mut improved = false;
            for _ in 0..8 {
                let mut m = a.clone();
                for i in 0..n {
                    m[i][i] += mu * a[i][i].max(1e-6) + 1e-9;
                }
                let neg_g: Vec<f32> = g.iter().map(|x| -x).collect();
                let Some(step) = solve_linear(&m, &neg_g) else {
                    mu *= 10.0;
                    continue;
                };
                let q: Vec<f32> = p.iter().zip(&step).map(|(a, b)| (a + b).clamp(-1.0, 1.0)).collect();
                let rq = residual(&q);
                let cq = cost(&rq);
                if cq < c {
                    let gain = c - cq;
                    p = q;
                    r = rq;
                    c = cq;
                    mu = (mu / 3.0).max(1e-6);
                    improved = true;
                    if gain < 1e-9 {
                        improved = false;
                    }
                    break;
                }
                mu *= 10.0;
            }
            if !improved {
                break;
            }
        }
        let out = rounded(&wheels(&p, current));
        if out == rounded(current) { None } else { Some(out) }
    }

    /// What Match sets on a clip: an Exposure step (when the clip's grade lets one stand in) and the Color Wheels.
    #[derive(Clone, Debug, PartialEq)]
    pub struct ColorMatchResult {
        /// New Exposure, `None` = unchanged.
        pub exposure: Option<f32>,
        /// New Color Wheels.
        pub wheels: ColorWheels,
    }

    /// The samples of a picture without letterbox black (a pixel with no channel at 1/255 or more).
    pub fn picture_samples(display: &[V3]) -> Vec<V3> {
        display.iter().filter(|p| max_of(**p) >= 1.0 / 255.0).copied().collect()
    }

    /// The Color Wheels as they show in the picture: switched off, they are neutral.
    pub fn wheels_in_picture(e: &ColorEffect) -> ColorWheels {
        if e.is_enabled(ColorSectionKind::Wheels) { e.wheels.clone() } else { ColorWheels::default() }
    }

    fn mean_luma(s: &ColorMatchStats) -> f32 {
        let luma = ColorMatchStats::LUMA;
        sum(mul(luma, s.shadows)) * s.weights[0]
            + sum(mul(luma, s.midtones)) * s.weights[1]
            + sum(mul(luma, s.highlights)) * s.weights[2]
    }

    /// An Exposure step can stand in for the tone difference: Basic is on, nothing before the wheels changes the tone.
    fn exposure_stage_applies(e: &ColorEffect) -> bool {
        e.is_enabled(ColorSectionKind::BasicCorrection)
            && e.input_lut_is_neutral()
            && [ColorSectionKind::Creative, ColorSectionKind::Curves]
                .iter()
                .all(|k| !e.is_enabled(*k) || ColorEffectExt::is_neutral(e, *k))
    }

    /// The pixels as they look with Basic Correction `to` instead of `from` (a gray-axis gain on each pixel).
    pub(crate) fn exposed(px: &[V3], from: &BasicCorrection, to: &BasicCorrection) -> Vec<V3> {
        if from == to {
            return px.to_vec();
        }
        px.iter()
            .map(|c| {
                let y = sum(mul(ColorMatchStats::LUMA, *c));
                let y2 = auto_tone_solver::tone(auto_tone_solver::untone(y, from), to);
                if y > 1e-4 { scale(*c, y2 / y) } else { add(*c, [y2 - y; 3]) }
            })
            .collect()
    }

    /// Match for a clip: measures `display` (the clip's picture as shown, wheels included), plans an Exposure step when
    /// the grade allows it and solves the wheels on the result. `None` when nothing would change.
    pub fn solve_clip(display: &[V3], e: &ColorEffect, reference: &ColorMatchStats) -> Option<ColorMatchResult> {
        let finite: Vec<V3> = display.iter().filter(|p| p.iter().all(|c| c.is_finite())).copied().collect();
        if finite.len() < 16 {
            return None;
        }
        let step = (finite.len() / MAX_SAMPLES).max(1);
        let mut px: Vec<V3> = finite.iter().step_by(step).copied().collect();
        let shown_wheels = wheels_in_picture(e);
        if !NeutralExt::is_neutral(&shown_wheels) {
            let prep = Prepared::new(&shown_wheels);
            px = px.into_iter().map(|p| model::unapply(p, &prep)).collect();
        }
        let mut exposure: Option<f32> = None;
        if exposure_stage_applies(e) {
            let target = mean_luma(reference);
            let base: Vec<f32> =
                px.iter().map(|p| auto_tone_solver::untone(sum(mul(ColorMatchStats::LUMA, *p)), &e.basic)).collect();
            let mean = |ev: f32| -> f32 {
                let mut b = e.basic;
                b.exposure = ev;
                base.iter().fold(0.0_f32, |acc, y| acc + auto_tone_solver::tone(*y, &b).clamp(0.0, 1.0))
                    / base.len() as f32
            };
            let (mut lo, mut hi) = (-5.0_f32, 5.0_f32);
            for _ in 0..40 {
                let m = (lo + hi) / 2.0;
                if mean(m) < target {
                    lo = m;
                } else {
                    hi = m;
                }
            }
            let ev = (((lo + hi) / 2.0) * 100.0).round() / 100.0;
            if ev != e.basic.exposure {
                let mut b = e.basic;
                b.exposure = ev;
                px = exposed(&px, &e.basic, &b);
                exposure = Some(ev);
            }
        }
        let wheels = solve(&px, &ColorWheels::default(), reference).unwrap_or_default();
        let unchanged =
            exposure.is_none() && rounded(&wheels) == rounded(&shown_wheels) && e.is_enabled(ColorSectionKind::Wheels);
        if unchanged { None } else { Some(ColorMatchResult { exposure, wheels }) }
    }

    /// Gaussian elimination with partial pivoting; `None` for a singular matrix.
    pub(crate) fn solve_linear(m: &[Vec<f32>], b: &[f32]) -> Option<Vec<f32>> {
        let n = b.len();
        let mut a = m.to_vec();
        let mut x = b.to_vec();
        for col in 0..n {
            let mut piv = col;
            for row in col + 1..n {
                if a[row][col].abs() > a[piv][col].abs() {
                    piv = row;
                }
            }
            if a[piv][col].abs().is_nan() || a[piv][col].abs() <= 1e-12 {
                return None;
            }
            if piv != col {
                a.swap(piv, col);
                x.swap(piv, col);
            }
            for row in col + 1..n {
                let f = a[row][col] / a[col][col];
                if f == 0.0 {
                    continue;
                }
                let pivot_row = a[col].clone();
                for (v, p) in a[row].iter_mut().zip(&pivot_row).skip(col) {
                    *v -= f * p;
                }
                x[row] -= f * x[col];
            }
        }
        let mut out = vec![0.0_f32; n];
        for row in (0..n).rev() {
            let mut s = x[row];
            for k in row + 1..n {
                s -= a[row][k] * out[k];
            }
            out[row] = s / a[row][row];
        }
        Some(out)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::color_match_solver as solver;
    use super::color_wheels_model as wheels_model;
    use super::*;
    use sq_core_time::Time;

    /// A deterministic picture: a luma ramp with mild, varied color.
    pub(crate) fn picture(n: usize, cast: V3) -> Vec<V3> {
        let mut s: u32 = 12345;
        let mut r = move || -> f32 {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (s >> 8) as f32 / (1u32 << 24) as f32
        };
        (0..n)
            .map(|i| {
                let y = 0.03 + 0.92 * i as f32 / n as f32;
                let c = add([y + 0.08 * (r() - 0.5), y + 0.08 * (r() - 0.5), y + 0.08 * (r() - 0.5)], cast);
                clamp3(c, 0.0, 1.0)
            })
            .collect()
    }

    fn graded() -> ColorWheels {
        ColorWheels {
            shadows: WheelValue { hue: 210.0, amount: 0.35 },
            highlights: WheelValue { hue: 35.0, amount: 0.3 },
            midtones_luma: 12.0,
            saturation: 125.0,
            ..ColorWheels::default()
        }
    }

    pub(crate) fn max_abs(v: V3) -> f32 {
        v[0].abs().max(v[1].abs()).max(v[2].abs())
    }

    pub(crate) fn max_band_error(a: &ColorMatchStats, b: &ColorMatchStats) -> f32 {
        a.bands().iter().zip(b.bands().iter()).map(|(x, y)| max_abs(sub(*x, *y))).fold(f32::MIN, f32::max)
    }

    fn after(src: &[V3], w: &ColorWheels) -> Vec<V3> {
        src.iter().map(|p| wheels_model::apply(*p, w)).collect()
    }

    #[test]
    fn measure_splits_into_bands_that_sum_to_one() {
        let s = ColorMatchStats::measure(&picture(2400, [0.0; 3])).expect("measures");
        assert!((sum(s.weights) - 1.0).abs() < 1e-4);
        assert!(s.shadows[0] < s.midtones[0] && s.midtones[0] < s.highlights[0]);
        assert!(s.chroma < 0.05);
        assert!(ColorMatchStats::measure(&[[1.0; 3]; 4]).is_none());
    }

    #[test]
    fn wheel_offset_round_trips_through_hue_and_amount() {
        let mut hue = 0.0_f32;
        while hue < 360.0 {
            let w = WheelValue { hue, amount: 0.6 };
            let back = wheels_model::wheel(wheels_model::offset(&w));
            assert!((back.amount - 0.6).abs() < 1e-3);
            assert!(max_abs(sub(wheels_model::offset(&back), wheels_model::offset(&w))) < 1e-4);
            hue += 23.0;
        }
    }

    #[test]
    fn match_reproduces_a_graded_reference() {
        let src = picture(2400, [0.0; 3]);
        let reference = ColorMatchStats::measure(&after(&src, &graded())).expect("measures");
        let w = solver::solve(&src, &ColorWheels::default(), &reference).expect("solves");
        let got = ColorMatchStats::measure(&after(&src, &w)).expect("measures");
        assert!(max_band_error(&got, &reference) < 0.012);
        assert!((got.chroma - reference.chroma).abs() < 0.01);
        // Warm highlights and cool shadows come back as such.
        assert!(w.highlights.amount > 0.05 && (w.highlights.hue < 90.0 || w.highlights.hue > 330.0));
        assert!(w.shadows.amount > 0.05 && w.shadows.hue > 150.0 && w.shadows.hue < 270.0);
    }

    #[test]
    fn match_removes_a_cast() {
        let reference = ColorMatchStats::measure(&picture(2400, [0.0; 3])).expect("measures");
        let tinted = picture(2400, [0.04, 0.0, -0.04]);
        let w = solver::solve(&tinted, &ColorWheels::default(), &reference).expect("solves");
        let got = ColorMatchStats::measure(&after(&tinted, &w)).expect("measures");
        let before = ColorMatchStats::measure(&tinted).expect("measures");
        assert!(max_band_error(&got, &reference) < max_band_error(&before, &reference) / 3.0);
    }

    #[test]
    fn pressing_match_twice_changes_nothing() {
        let src = picture(2400, [0.0; 3]);
        let reference = ColorMatchStats::measure(&after(&src, &graded())).expect("measures");
        let w = solver::solve(&src, &ColorWheels::default(), &reference).expect("solves");
        let shown = after(&src, &w);
        if let Some(again) = solver::solve(&shown, &w, &reference) {
            // Only rounding-level differences are allowed.
            // Same as the Swift test: the solver's shadows step lands one 1.0 step apart on Windows (libm differences, as in the Swift
            // test); loosen there, tighten when the solver is made platform-stable.
            let luma_tolerance = if cfg!(target_os = "macos") { 0.5 } else { 1.0 };
            assert!(
                (again.shadows_luma - w.shadows_luma).abs() <= luma_tolerance
                    && (again.saturation - w.saturation).abs() <= 0.5
            );
            assert!((again.highlights.amount - w.highlights.amount).abs() <= 0.02);
        }
    }

    #[test]
    fn matching_a_picture_to_itself_does_nothing() {
        let src = picture(2400, [0.0; 3]);
        let reference = ColorMatchStats::measure(&src).expect("measures");
        assert!(solver::solve(&src, &ColorWheels::default(), &reference).is_none());
        assert!(solver::solve(&src[..8], &ColorWheels::default(), &reference).is_none());
    }

    #[test]
    fn block_reasons() {
        let mut e = ColorEffect::new(1, None);
        let stats = ColorMatchStats::measure(&picture(2400, [0.0; 3])).expect("measures");
        let reference = ColorMatchReference { clip: None, time: Time::new(0, 1), label: "R".to_string(), stats };
        assert!(solver::block_reason(&e, ColorSpaceID::Rec709, Some(&reference)).is_none());
        assert!(solver::block_reason(&e, ColorSpaceID::Rec709, None).is_some());
        assert!(solver::block_reason(&e, ColorSpaceID::AppleLog, Some(&reference)).is_some());
        e.set_enabled(ColorSectionKind::Wheels, false);
        assert!(solver::block_reason(&e, ColorSpaceID::Rec709, Some(&reference)).is_some());
    }

    #[test]
    fn letterbox_black_is_left_out_of_the_samples() {
        let px = [[0.0; 3], [0.0; 3], [0.5, 0.4, 0.3], [0.001, 0.0, 0.0], [0.2, 0.2, 0.2]];
        assert_eq!(solver::picture_samples(&px), [[0.5, 0.4, 0.3], [0.2, 0.2, 0.2]]);
    }

    #[test]
    fn wheels_in_picture_are_neutral_when_switched_off() {
        let mut e = ColorEffect::new(1, Some(sq_core_model::LUTRef::Automatic));
        e.wheels.midtones_luma = 30.0;
        assert_eq!(solver::wheels_in_picture(&e).midtones_luma, 30.0);
        e.set_enabled(ColorSectionKind::Wheels, false);
        assert!(NeutralExt::is_neutral(&solver::wheels_in_picture(&e)));
    }

    /// A darker, warmer copy of the reference comes back to the reference's tone and color within tolerance.
    #[test]
    fn a_darker_warmer_clip_is_matched_to_its_reference() {
        let reference = picture(2400, [0.0; 3]);
        let target: Vec<V3> =
            reference.iter().map(|p| clamp3([p[0] * 0.7, p[1] * 0.6, p[2] * 0.5], 0.0, 1.0)).collect();
        let ref_stats = ColorMatchStats::measure(&solver::picture_samples(&reference)).expect("measures");
        let before = ColorMatchStats::measure(&target).expect("measures");
        let effect = ColorEffect::new(1, Some(sq_core_model::LUTRef::Automatic));
        let r = solver::solve_clip(&solver::picture_samples(&target), &effect, &ref_stats).expect("solves");
        let ev = r.exposure.expect("an Exposure step");
        assert!(ev > 0.3 && ev < 1.5, "brightened by an Exposure step");
        let mut graded = effect.basic;
        graded.exposure = ev;
        let shown: Vec<V3> = solver::exposed(&target, &effect.basic, &graded)
            .into_iter()
            .map(|p| wheels_model::apply(p, &r.wheels))
            .collect();
        let after = ColorMatchStats::measure(&shown).expect("measures");
        let luma = ColorMatchStats::LUMA;
        // Brightness of every band within 0.02, warmth (R - B of the midtones) within 0.04.
        for (a, r) in after.bands().iter().zip(ref_stats.bands().iter()) {
            let d = (sum(mul(luma, *a)) - sum(mul(luma, *r))).abs();
            assert!(d < 0.02, "band luma off by {d}");
        }
        let warmth = |s: &ColorMatchStats| s.midtones[0] - s.midtones[2];
        let off = (warmth(&after) - warmth(&ref_stats)).abs();
        assert!(off < 0.04, "warmth off by {off}");
        assert!(off < (warmth(&before) - warmth(&ref_stats)).abs() / 2.0);
        assert!(max_band_error(&after, &ref_stats) < max_band_error(&before, &ref_stats) / 3.0);
        // Matching the result again changes (almost) nothing.
        let mut again = effect.clone();
        again.basic = graded;
        again.wheels = r.wheels.clone();
        if let Some(r2) = solver::solve_clip(&shown, &again, &ref_stats) {
            assert!((r2.exposure.unwrap_or(ev) - ev).abs() <= 0.05);
            assert!((r2.wheels.midtones_luma - r.wheels.midtones_luma).abs() <= 1.5);
        }
    }

    #[test]
    fn a_matching_picture_needs_nothing() {
        let p = picture(2400, [0.0; 3]);
        let s = ColorMatchStats::measure(&p).expect("measures");
        assert!(solver::solve_clip(&p, &ColorEffect::new(1, Some(sq_core_model::LUTRef::Automatic)), &s).is_none());
    }
}
