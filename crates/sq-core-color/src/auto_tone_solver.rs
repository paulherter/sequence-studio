// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AutoToneSolver.swift
//! Auto Tone maths (Basic Correction "Auto Tone"), pure and display-free. Input: the luma of the Program frame as
//! shown (BT.709 display-encoded, 0...1, may exceed 1), which already contains the effect's current Basic Correction.
//! The shown statistics are first un-toned through the current values, then the new values are solved absolutely from
//! the untouched picture. So pressing Auto Tone twice changes nothing.
//!
//! Solved: Exposure, Contrast, Whites, Blacks. Kept: Shadows, Highlights, Temperature, Tint, Saturation, Vibrance.
//! Rules: the brightest 0.5 % land at [`WHITE_TARGET`] at most and the darkest 0.5 % at [`BLACK_TARGET`] at least, so
//! nothing is pushed into clipping; Blacks only deepens and Whites only brightens; Contrast is used only when
//! Whites/Blacks cannot reach, up to [`MAX_CONTRAST`].

use crate::basic_tone_curves as curves;
use crate::basic_tone_curves::{inverse_oetf, oetf};
use crate::color_effect::{ColorEffectExt, ColorSectionKindExt};
use crate::input_color_space::ColorSpaceIdExt;
use sq_core_model::{BasicCorrection, BasicToneModel, ColorEffect, ColorSectionKind, ColorSpaceID};

/// Display value the darkest 0.5 % are brought to.
pub const BLACK_TARGET: f32 = 0.02;
/// Display value the brightest 0.5 % are brought to.
pub const WHITE_TARGET: f32 = 0.96;
/// Median (display-encoded) the exposure step aims for: brightening stops at the upper bound, darkening of a bright,
/// nearly clipped picture goes down to it.
pub const MID_BAND: (f32, f32) = (0.38, 0.55);
/// Largest Contrast Auto Tone sets.
pub const MAX_CONTRAST: f32 = 30.0;
const MAX_DARKEN: f32 = -2.0;
const CONTRAST_PIVOT: f32 = 0.45;

pub(crate) fn smooth(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// A gray of display value `y` through the tone part of `b` without Whites/Blacks (the value the levels see).
fn pre_levels(y: f32, b: &BasicCorrection) -> f32 {
    let mut t = y;
    let ev = b.exposure.clamp(-5.0, 5.0);
    if ev != 0.0 {
        t = oetf(inverse_oetf(t) * ev.exp2());
    }
    let con = b.contrast.clamp(-100.0, 100.0) / 100.0;
    if con != 0.0 {
        t = CONTRAST_PIVOT + (t - CONTRAST_PIVOT) * (if con >= 0.0 { 1.0 + 0.8 * con } else { 1.0 + 0.7 * con });
    }
    let s = b.shadows.clamp(-100.0, 100.0) / 100.0;
    if s != 0.0 {
        t *= 1.0 + (if s > 0.0 { 1.4 * s } else { s }) * (1.0 - smooth(0.0, 0.6, t));
    }
    let h = b.highlights.clamp(-100.0, 100.0) / 100.0;
    if h != 0.0 {
        t += 0.3 * h * smooth(0.3, 1.0, t);
    }
    t
}

fn levels_of(b: &BasicCorrection) -> (f32, f32) {
    let w = b.whites.clamp(-100.0, 100.0) / 100.0;
    let k = b.blacks.clamp(-100.0, 100.0) / 100.0;
    (-0.1 * k, 1.0 - 0.2 * w)
}

/// A gray of display value `y` through Basic Correction's tone maths (Temperature/Tint/Saturation do not move grays).
pub fn tone(y: f32, b: &BasicCorrection) -> f32 {
    if b.model == BasicToneModel::Lumetri {
        return curves::tone(y, b);
    }
    let (bp, wp) = levels_of(b);
    (pre_levels(y, b) - bp) / (wp - bp)
}

/// Inverse of [`tone`] (it is monotone): the display value before the Basic Correction.
pub fn untone(y: f32, b: &BasicCorrection) -> f32 {
    if b.exposure == 0.0
        && b.contrast == 0.0
        && b.shadows == 0.0
        && b.highlights == 0.0
        && b.whites == 0.0
        && b.blacks == 0.0
    {
        return y;
    }
    let mut lo: f32 = -1.0;
    let mut hi: f32 = 8.0;
    for _ in 0..48 {
        let m = (lo + hi) / 2.0;
        if tone(m, b) < y {
            lo = m;
        } else {
            hi = m;
        }
    }
    (lo + hi) / 2.0
}

/// Why Auto Tone cannot solve this Color effect from the shown picture (`None` = it can). The tone model is the Basic
/// Correction on a Rec.709 picture with nothing after it, so a Log/HDR source, an Input LUT, a switched-off Basic
/// Correction, or an active later section would be measured but not inverted.
pub fn block_reason(e: &ColorEffect, source: ColorSpaceID) -> Option<String> {
    if source != ColorSpaceID::Rec709 {
        return Some(format!(
            "Auto Tone works on Rec. 709 footage. This clip is interpreted as {}; grade it by hand.",
            source.display_name()
        ));
    }
    if !e.is_enabled(ColorSectionKind::BasicCorrection) {
        return Some("Turn on Basic to use Auto Tone.".to_string());
    }
    if !e.input_lut_is_neutral() {
        return Some("Auto Tone cannot measure through the Input LUT. Remove the LUT or grade by hand.".to_string());
    }
    for k in
        [ColorSectionKind::Creative, ColorSectionKind::Curves, ColorSectionKind::Wheels, ColorSectionKind::Vignette]
    {
        if e.is_enabled(k) && !e.is_neutral(k) {
            let title = k.title();
            return Some(format!("Auto Tone would measure {title} too. Reset or switch off {title} first."));
        }
    }
    None
}

/// The sorted finite luma values and the three percentiles (0.5 %, median, 99.5 %) un-toned through `current`
/// (and brightened by `gain`); `None` for too few samples or a flat frame.
fn percentiles(luma: &[f32], current: &BasicCorrection, linear_gain: f32) -> Option<(f32, f32, f32)> {
    let mut v: Vec<f32> = luma.iter().copied().filter(|x| x.is_finite()).collect();
    v.sort_by(f32::total_cmp);
    if v.len() < 16 {
        return None;
    }
    let gain = if linear_gain.is_finite() && linear_gain > 0.0 { linear_gain } else { 1.0 };
    let pct = |p: f32| -> f32 {
        let y = untone(v[((v.len() - 1) as f32 * p) as usize], current);
        if gain == 1.0 { y } else { oetf(inverse_oetf(y) * gain) }
    };
    let (lo, mid, hi) = (pct(0.005), pct(0.5), pct(0.995));
    if hi - lo >= 0.05 { Some((lo, mid, hi)) } else { None }
}

/// New Basic Correction (only Exposure, Contrast, Whites, Blacks differ from `current`), or `None` when there is
/// nothing to do (too few samples, a flat frame, or the values already are what Auto Tone would set).
/// `linear_gain`: how much a white-balance change made in the same step brightens grays (linear, before Exposure);
/// the picture is solved as if it were already applied.
pub fn solve_tone(luma: &[f32], current: &BasicCorrection, linear_gain: f32) -> Option<BasicCorrection> {
    if current.model == BasicToneModel::Lumetri {
        return solve_lumetri(luma, current, linear_gain);
    }
    let (lo, mid, hi) = percentiles(luma, current, linear_gain)?;

    // Exposure (linear gain): brighten so the bright end reaches white, but not past the midtone band; darken only a
    // bright picture that already touches white.
    fn ev(from: f32, to: f32) -> f32 {
        (inverse_oetf(to) / inverse_oetf(from.max(1e-4)).max(1e-6)).log2()
    }
    let mut e: f32 = 0.0;
    let mut darkened = false;
    if hi < WHITE_TARGET {
        e = 0.0_f32.max(ev(hi, WHITE_TARGET).min(if mid < MID_BAND.1 { ev(mid, MID_BAND.1) } else { 0.0 }));
    } else if mid > MID_BAND.1 {
        e = ev(mid, MID_BAND.1).max(MAX_DARKEN);
        darkened = true;
    }
    e = e.clamp(-5.0, 5.0);

    let mut b = *current;
    b.exposure = e;
    b.contrast = 0.0;
    b.whites = 0.0;
    b.blacks = 0.0;

    // Levels for a contrast k: lo -> BLACK_TARGET (Blacks deepens only), hi -> WHITE_TARGET (Whites brightens only).
    // feasible: within the slider reach without clamping.
    let solve_levels = |k: f32| -> (f32, f32, bool) {
        let mut t = b;
        t.contrast = (k - 1.0) / 0.8 * 100.0;
        let l = pre_levels(lo, &t);
        let h = pre_levels(hi, &t);
        let need_lo = l > BLACK_TARGET;
        let need_hi = !darkened && h < WHITE_TARGET;
        let mut bp: f32 = 0.0;
        let mut wp: f32 = 1.0;
        if need_lo && need_hi {
            let scale = (h - l) / (WHITE_TARGET - BLACK_TARGET);
            bp = l - BLACK_TARGET * scale;
            wp = bp + scale;
        } else if need_lo {
            bp = (l - BLACK_TARGET) / (1.0 - BLACK_TARGET);
        } else if need_hi {
            wp = h / WHITE_TARGET;
        }
        let feasible = bp <= 0.1 + 1e-6 && wp >= 0.8 - 1e-6;
        // Out of reach: deepen as far as Blacks goes, then place the bright end with the clamped black point (both
        // ends then land inside the targets, never beyond).
        bp = bp.min(0.1);
        if need_hi {
            wp = bp + (h - bp) / WHITE_TARGET;
        }
        wp = wp.clamp(0.8, 1.0);
        (bp, wp, feasible)
    };

    let mut k: f32 = 1.0;
    let mut sol = solve_levels(1.0);
    if !sol.2 && !darkened {
        // Contrast alone must not push either end past its target (it spreads around the pivot).
        let inside = |k: f32| -> bool {
            let mut t = b;
            t.contrast = (k - 1.0) / 0.8 * 100.0;
            pre_levels(lo, &t) >= BLACK_TARGET && pre_levels(hi, &t) <= WHITE_TARGET
        };
        let mut k_max = 1.0 + 0.8 * MAX_CONTRAST / 100.0;
        if !inside(k_max) {
            let (mut a, mut z) = (1.0_f32, k_max);
            for _ in 0..30 {
                let m = (a + z) / 2.0;
                if inside(m) {
                    a = m;
                } else {
                    z = m;
                }
            }
            k_max = a;
        }
        if solve_levels(k_max).2 {
            let (mut a, mut z) = (1.0_f32, k_max);
            for _ in 0..30 {
                let m = (a + z) / 2.0;
                if solve_levels(m).2 {
                    z = m;
                } else {
                    a = m;
                }
            }
            k = z;
        } else {
            k = k_max;
        }
        sol = solve_levels(k);
    }

    b.exposure = (e * 100.0).round() / 100.0;
    b.contrast = (((k - 1.0) / 0.8 * 100.0).clamp(0.0, MAX_CONTRAST) * 10.0).round() / 10.0;
    b.blacks = ((-sol.0 / 0.1 * 100.0).clamp(-100.0, 0.0) * 10.0).round() / 10.0;
    b.whites = (((1.0 - sol.1) / 0.2 * 100.0).clamp(0.0, 100.0) * 10.0).round() / 10.0;

    same_or_new(b, current)
}

fn same_or_new(b: BasicCorrection, current: &BasicCorrection) -> Option<BasicCorrection> {
    let same = (b.exposure - current.exposure).abs() < 0.02
        && (b.contrast - current.contrast).abs() < 0.5
        && (b.whites - current.whites).abs() < 0.5
        && (b.blacks - current.blacks).abs() < 0.5;
    if same { None } else { Some(b) }
}

/// Increasing `f` on `[a, z]`: the x where `f(x) = target`, clamped to the ends.
fn solve(a: f32, z: f32, target: f32, f: impl Fn(f32) -> f32) -> f32 {
    if f(a) >= target {
        return a;
    }
    if f(z) <= target {
        return z;
    }
    let (mut a, mut z) = (a, z);
    for _ in 0..40 {
        let m = (a + z) / 2.0;
        if f(m) < target {
            a = m;
        } else {
            z = m;
        }
    }
    (a + z) / 2.0
}

fn exposed(y: f32, ev: f32) -> f32 {
    if ev == 0.0 { y } else { oetf(curves::exposure(inverse_oetf(y), ev)) }
}

/// `solve_tone` for the Lumetri maths: the same rules, solved numerically through the tone curves (Whites is a gain,
/// Blacks a low hinge, Contrast an end-fixed S-curve, Exposure rolls into white).
fn solve_lumetri(luma: &[f32], current: &BasicCorrection, linear_gain: f32) -> Option<BasicCorrection> {
    let (lo, mid, hi) = percentiles(luma, current, linear_gain)?;

    let mut e: f32 = 0.0;
    let mut darkened = false;
    if hi < WHITE_TARGET {
        let to_white = solve(0.0, 5.0, WHITE_TARGET, |x| exposed(hi, x));
        let to_mid = if mid < MID_BAND.1 { solve(0.0, 5.0, MID_BAND.1, |x| exposed(mid, x)) } else { 0.0 };
        e = 0.0_f32.max(to_white.min(to_mid));
        e = (e * 100.0).floor() / 100.0;
    } else if mid > MID_BAND.1 {
        e = solve(MAX_DARKEN, 0.0, MID_BAND.1, |x| exposed(mid, x)).max(MAX_DARKEN);
        e = (e * 100.0).round() / 100.0;
        darkened = true;
    }

    let mut b = *current;
    b.exposure = e;
    b.contrast = 0.0;
    b.whites = 0.0;
    b.blacks = 0.0;
    let e_lo = exposed(lo, e);
    let e_hi = exposed(hi, e);
    let shown = |y: f32, t: &BasicCorrection| curves::tone_after_exposure(y, t);

    // Whites (0...100) brings the bright end to the white target, Blacks (-100...0) the dark end to the black target;
    // each barely touches the other's end, so a few alternating solves settle. feasible: both reached in range.
    let levels = |c: f32| -> (f32, f32, bool) {
        let mut t = b;
        t.contrast = c;
        let need_lo = shown(e_lo, &t) > BLACK_TARGET;
        let need_hi = !darkened && shown(e_hi, &t) < WHITE_TARGET;
        let mut w: f32 = 0.0;
        let mut k: f32 = 0.0;
        for _ in 0..6 {
            if need_hi {
                w = solve(0.0, 100.0, WHITE_TARGET, |x| {
                    let mut u = t;
                    u.whites = x;
                    u.blacks = k;
                    shown(e_hi, &u)
                });
            }
            if need_lo {
                k = -solve(0.0, 100.0, -BLACK_TARGET, |x| {
                    let mut u = t;
                    u.whites = w;
                    u.blacks = -x;
                    -shown(e_lo, &u)
                });
            }
        }
        let mut u = t;
        u.whites = w;
        u.blacks = k;
        let ok_hi = !need_hi || (shown(e_hi, &u) - WHITE_TARGET).abs() < 1e-3;
        let ok_lo = !need_lo || (shown(e_lo, &u) - BLACK_TARGET).abs() < 1e-3;
        (w, k, ok_hi && ok_lo)
    };

    let mut con: f32 = 0.0;
    let mut sol = levels(0.0);
    if !sol.2 && !darkened {
        // Contrast alone must not push either end past its target.
        let inside = |c: f32| -> bool {
            let mut t = b;
            t.contrast = c;
            shown(e_lo, &t) >= BLACK_TARGET && shown(e_hi, &t) <= WHITE_TARGET
        };
        let mut c_max = MAX_CONTRAST;
        if !inside(c_max) {
            let (mut a, mut z) = (0.0_f32, c_max);
            for _ in 0..30 {
                let m = (a + z) / 2.0;
                if inside(m) {
                    a = m;
                } else {
                    z = m;
                }
            }
            c_max = a;
        }
        if levels(c_max).2 {
            let (mut a, mut z) = (0.0_f32, c_max);
            for _ in 0..30 {
                let m = (a + z) / 2.0;
                if levels(m).2 {
                    z = m;
                } else {
                    a = m;
                }
            }
            con = z;
        } else {
            con = c_max;
        }
        con = (con * 10.0).floor() / 10.0;
        sol = levels(con);
    }

    b.contrast = con;
    // Round towards no clipping: Whites down, Blacks up (both towards 0).
    b.whites = (sol.0.clamp(0.0, 100.0) * 10.0).floor() / 10.0;
    b.blacks = (sol.1.clamp(-100.0, 0.0) * 10.0).ceil() / 10.0;

    same_or_new(b, current)
}

/// Conservative gray-world white balance: the mean of the near-gray mid-tone pixels (working-linear Rec.709, as
/// shown), to be made neutral by the white-balance solver. `None` when the frame is already neutral (so a second
/// press changes nothing), when the cast is strong (likely intended: sunset, tungsten mood) or when too few pixels
/// are gray.
pub fn neutral_sample(linear: &[[f32; 3]]) -> Option<[f32; 3]> {
    let mut sum = [0.0_f32; 3];
    let mut n = 0usize;
    let mut valid = 0usize;
    for p in linear.iter().filter(|p| p.iter().all(|c| c.is_finite())) {
        valid += 1;
        let y = oetf((0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]).max(0.0));
        if !(0.1..=0.9).contains(&y) {
            continue;
        }
        let mx = p[0].max(p[1]).max(p[2]);
        let mn = p[0].min(p[1]).min(p[2]);
        if !(mn >= 0.0 && mx > 0.0 && (mx - mn) / mx < 0.3) {
            continue;
        }
        for (s, c) in sum.iter_mut().zip(p) {
            *s += c;
        }
        n += 1;
    }
    if !(n >= 16 && n as f32 >= 0.1 * valid as f32 && sum[1] > 0.0) {
        return None;
    }
    let mean = sum.map(|s| s / n as f32);
    let cast = (mean[0] / mean[1] - 1.0).abs().max((mean[2] / mean[1] - 1.0).abs());
    if !(0.015..=0.25).contains(&cast) {
        return None;
    }
    Some(mean)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODELS: [BasicToneModel; 2] = [BasicToneModel::Legacy, BasicToneModel::Lumetri];

    fn basic(model: BasicToneModel) -> BasicCorrection {
        BasicCorrection { model, ..BasicCorrection::default() }
    }

    fn ramp(lo: f32, hi: f32) -> Vec<f32> {
        let n = 1000;
        (0..n).map(|i| lo + (hi - lo) * i as f32 / (n - 1) as f32).collect()
    }

    fn shown(raw: &[f32], b: &BasicCorrection) -> Vec<f32> {
        raw.iter().map(|&y| tone(y, b)).collect()
    }

    fn pct(v: &[f32], p: f32) -> f32 {
        let mut s = v.to_vec();
        s.sort_by(f32::total_cmp);
        s[((s.len() - 1) as f32 * p) as usize]
    }

    fn solve(raw: &[f32], b: &BasicCorrection) -> Option<BasicCorrection> {
        solve_tone(raw, b, 1.0)
    }

    #[test]
    fn tone_and_untone_round_trip() {
        for m in MODELS {
            let mut b = basic(m);
            b.exposure = 1.3;
            b.contrast = 25.0;
            b.shadows = 30.0;
            b.highlights = -40.0;
            b.whites = 20.0;
            b.blacks = -35.0;
            for i in 0..=24 {
                let y = i as f32 * 0.05;
                assert!((untone(tone(y, &b), &b) - y).abs() < 1e-4, "{m:?} {y}");
            }
            assert_eq!(tone(0.37, &basic(m)), 0.37, "neutral is the identity");
        }
    }

    #[test]
    fn dark_picture_is_brightened_without_clipping() {
        for m in MODELS {
            let raw = ramp(0.02, 0.4);
            let b = solve(&raw, &basic(m)).expect("solves");
            assert!(b.exposure > 0.3);
            let out = shown(&raw, &b);
            assert!((pct(&out, 0.995) - WHITE_TARGET).abs() < 0.01, "bright end lands just under white");
            assert!(pct(&out, 0.5) >= MID_BAND.0 - 0.01);
            assert!(out.iter().copied().fold(f32::MIN, f32::max) <= 1.0);
        }
    }

    #[test]
    fn bright_picture_is_darkened() {
        for m in MODELS {
            let raw = ramp(0.5, 0.98);
            let b = solve(&raw, &basic(m)).expect("solves");
            assert!(b.exposure < 0.0);
            assert!(pct(&shown(&raw, &b), 0.5) <= MID_BAND.1 + 0.01);
            assert!(b.whites >= 0.0 && b.blacks <= 0.0);
        }
    }

    #[test]
    fn low_contrast_picture_gets_stretched_and_some_contrast() {
        for m in MODELS {
            let raw = ramp(0.3, 0.6);
            let b = solve(&raw, &basic(m)).expect("solves");
            assert!(b.contrast > 0.0 && b.contrast <= MAX_CONTRAST);
            assert!(b.blacks < 0.0 && b.whites > 0.0);
            let out = shown(&raw, &b);
            let spread = pct(&out, 0.995) - pct(&out, 0.005);
            // The Lumetri-matched Contrast and Blacks are gentler than the legacy linear ones.
            assert!(spread > if m == BasicToneModel::Legacy { 0.55 } else { 0.5 }, "range was 0.3, now {spread}");
            assert!(pct(&out, 0.005) >= BLACK_TARGET - 0.005 && pct(&out, 0.995) <= WHITE_TARGET + 0.005);
        }
    }

    #[test]
    fn pressing_twice_changes_nothing() {
        for m in MODELS {
            for raw in [ramp(0.02, 0.4), ramp(0.5, 0.98), ramp(0.3, 0.6), ramp(0.1, 0.55), ramp(0.15, 0.97)] {
                let first = solve(&raw, &basic(m)).expect("solves");
                assert!(solve(&shown(&raw, &first), &first).is_none());
            }
        }
    }

    #[test]
    fn result_does_not_depend_on_the_starting_values() {
        for m in MODELS {
            let raw = ramp(0.08, 0.5);
            let from_neutral = solve(&raw, &basic(m)).expect("solves");
            let mut start = basic(m);
            start.exposure = -1.2;
            start.contrast = -30.0;
            start.whites = 40.0;
            start.blacks = 25.0;
            start.temperature = 12.0;
            start.saturation = 130.0;
            let from_graded = solve(&shown(&raw, &start), &start).expect("solves");
            assert!((from_graded.exposure - from_neutral.exposure).abs() <= 0.011);
            assert!((from_graded.contrast - from_neutral.contrast).abs() <= 0.11);
            assert!((from_graded.whites - from_neutral.whites).abs() <= 0.11);
            assert!((from_graded.blacks - from_neutral.blacks).abs() <= 0.11);
            assert!(from_graded.temperature == 12.0 && from_graded.saturation == 130.0, "color controls stay");
        }
    }

    #[test]
    fn shadows_and_highlights_are_kept() {
        for m in MODELS {
            let mut start = basic(m);
            start.shadows = 40.0;
            start.highlights = -30.0;
            let raw = ramp(0.05, 0.45);
            let b = solve(&shown(&raw, &start), &start).expect("solves");
            assert!(b.shadows == 40.0 && b.highlights == -30.0);
            assert!(pct(&shown(&raw, &b), 0.995) <= WHITE_TARGET + 0.005);
            assert!(solve(&shown(&raw, &b), &b).is_none());
        }
    }

    #[test]
    fn full_range_flat_and_empty_pictures_are_left_alone() {
        for m in MODELS {
            assert!(solve(&ramp(0.0, 1.0), &basic(m)).is_none());
            assert!(solve(&ramp(0.4, 0.42), &basic(m)).is_none(), "flat frame: nothing to stretch");
            assert!(solve(&[], &basic(m)).is_none());
            assert!(solve(&[f32::NAN, f32::INFINITY], &basic(m)).is_none());
        }
    }

    #[test]
    fn sliders_stay_in_range_and_nothing_clips() {
        for m in MODELS {
            let mut spiky = ramp(0.25, 0.6);
            spiky[0] = 0.0;
            spiky[1] = 1.0;
            let cases = [ramp(0.001, 0.07), ramp(0.0, 0.3), ramp(0.7, 1.0), ramp(0.45, 0.55), ramp(0.2, 1.4), spiky];
            for raw in cases {
                let Some(b) = solve(&raw, &basic(m)) else { continue };
                assert!(b.exposure.abs() <= 5.0 && (0.0..=MAX_CONTRAST).contains(&b.contrast));
                assert!((0.0..=100.0).contains(&b.whites) && (-100.0..=0.0).contains(&b.blacks));
                let out = shown(&raw, &b);
                let (hi_in, hi_out) = (pct(&raw, 0.995), pct(&out, 0.995));
                assert!(hi_out <= WHITE_TARGET.max(hi_in) + 0.005, "never pushes the bright end into clipping");
                assert!(
                    pct(&out, 0.005) >= BLACK_TARGET.min(pct(&raw, 0.005)) - 0.005,
                    "never crushes past the black target"
                );
            }
            let mut hot = basic(m);
            hot.exposure = 4.9;
            let c = solve(&shown(&ramp(0.0005, 0.01), &hot), &hot);
            assert!(c.map_or(0.0, |c| c.exposure) <= 5.0);
        }
    }

    #[test]
    fn white_balance_gain_is_taken_into_the_tone_solve() {
        for m in MODELS {
            let raw = ramp(0.05, 0.6);
            let gain = 1.3_f32;
            let b = solve_tone(&raw, &basic(m), gain).expect("solves");
            let brightened: Vec<f32> = raw.iter().map(|&y| oetf(inverse_oetf(y) * gain)).collect();
            let reference = solve(&brightened, &basic(m)).expect("solves");
            assert_eq!(b, reference);
            assert!(pct(&shown(&brightened, &b), 0.995) <= WHITE_TARGET + 0.005);
        }
    }

    #[test]
    fn blocked_for_non_rec709_sources_input_luts_switched_off_basic_and_later_stages() {
        use crate::input_color_space::ColorSpaceIdExt;
        use sq_core_model::{CurvePoint, LUTRef};
        let mut e = ColorEffect::new(1, Some(LUTRef::Automatic));
        assert!(block_reason(&e, ColorSpaceID::Rec709).is_none(), "automatic Input LUT on Rec.709 does nothing");
        for s in ColorSpaceID::ALL.into_iter().filter(|s| *s != ColorSpaceID::Rec709) {
            assert!(block_reason(&e, s).is_some(), "{s:?}");
        }
        let mut lut = e.clone();
        lut.input_lut = Some(LUTRef::File { path: "/x.cube".to_string() });
        assert!(block_reason(&lut, ColorSpaceID::Rec709).is_some());
        let mut off = e.clone();
        off.set_enabled(ColorSectionKind::BasicCorrection, false);
        assert!(block_reason(&off, ColorSpaceID::Rec709).is_some());
        let mut later = e.clone();
        later.creative.faded_film = 20.0;
        assert!(block_reason(&later, ColorSpaceID::Rec709).is_some());
        later.set_enabled(ColorSectionKind::Creative, false);
        assert!(block_reason(&later, ColorSpaceID::Rec709).is_none(), "a switched-off section is not in the picture");
        let mut curves = e.clone();
        curves.curves.master = vec![CurvePoint { x: 0.0, y: 0.1 }, CurvePoint { x: 1.0, y: 1.0 }];
        assert!(block_reason(&curves, ColorSpaceID::Rec709).is_some());
        let mut hue = e.clone();
        hue.hue_curves.hue_vs_sat = vec![CurvePoint { x: 0.0, y: 0.7 }, CurvePoint { x: 1.0, y: 0.5 }];
        assert!(block_reason(&hue, ColorSpaceID::Rec709).is_some());
        let mut wheels = e.clone();
        wheels.wheels.midtones_luma = 10.0;
        assert!(block_reason(&wheels, ColorSpaceID::Rec709).is_some());
        let mut vig = e.clone();
        vig.vignette.amount = -1.0;
        assert!(block_reason(&vig, ColorSpaceID::Rec709).is_some());
        e.basic.saturation = 140.0;
        e.basic.shadows = 30.0;
        assert!(block_reason(&e, ColorSpaceID::Rec709).is_none(), "Basic Correction's own values are un-toned");
    }

    #[test]
    fn neutral_sample_averages_near_grey_pixels_only() {
        let cast = [1.08_f32, 1.0, 0.9];
        let mut px: Vec<[f32; 3]> = (0..400)
            .map(|i| {
                let k = 0.05 + 0.4 * i as f32 / 400.0;
                cast.map(|c| c * k)
            })
            .collect();
        px.extend(std::iter::repeat_n([0.6, 0.02, 0.02], 100)); // a saturated red object
        let s = neutral_sample(&px).expect("samples");
        assert!((s[0] / s[1] - 1.08).abs() < 0.01 && (s[2] / s[1] - 0.9).abs() < 0.01, "the red object is ignored");
    }

    #[test]
    fn neutral_sample_skips_neutral_strong_cast_and_colourful_frames() {
        let neutral: Vec<[f32; 3]> = (0..400).map(|i| [0.02 + i as f32 / 1000.0; 3]).collect();
        assert!(neutral_sample(&neutral).is_none(), "already neutral");
        let strong: Vec<[f32; 3]> = (0..400).map(|i| [1.6, 1.0, 0.5].map(|c| c * (0.02 + i as f32 / 1000.0))).collect();
        assert!(neutral_sample(&strong).is_none(), "a strong cast is treated as intended (sunset, tungsten mood)");
        assert!(neutral_sample(&vec![[0.5, 0.05, 0.4]; 400]).is_none(), "no gray pixels");
        assert!(neutral_sample(&[]).is_none());
    }
}
