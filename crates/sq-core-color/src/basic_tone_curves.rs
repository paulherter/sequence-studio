// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BasicToneCurves.swift
//! Basic Correction tone maths of the Lumetri-matched model (`BasicToneModel::Lumetri`), per channel on the Rec.709
//! signal `x` (0...1 = 0...100 IRE; values outside are continued so the curve never folds). Exposure works on linear
//! light. Amounts are the sliders / 100 (-1...1), exposure in stops.

use sq_core_model::BasicCorrection;

/// Contrast pivot on the Rec.709 signal (Premiere: 50 IRE).
pub const CONTRAST_PIVOT: f32 = 0.5;
/// Contrast slope at the pivot is `1 + k`: k = amount x this for positive amounts.
pub const CONTRAST_UP: f32 = 1.0;
/// Same for negative amounts.
pub const CONTRAST_DOWN: f32 = 0.5;
/// Largest move of the Highlights bump at +-100 (signal units, 0.14 = 14 IRE).
pub const HIGHLIGHTS_REACH: f32 = 0.14;
/// Largest move of the Shadows bump at +-100.
pub const SHADOWS_REACH: f32 = 0.14;
/// Whites gain at +-100, in stops.
pub const WHITES_STOPS: f32 = 0.35;
/// Blacks lift of the black point at +100 (0.2 = 20 IRE); the hinge falls off as (1 - x)^2.
pub const BLACKS_REACH: f32 = 0.2;
/// Exposure up: linear light below this knee is a plain gain, above it a shoulder rolls into white.
pub const EXPOSURE_KNEE: f32 = 0.18;

/// Exposure on linear light `l`: down = gain; up = gain below the knee, then a rational shoulder that maps linear 1
/// to exactly 1 (C1 at the knee). Source superwhites (linear > 1) continue with slope 1 from there:
/// `1 + g (l - 1)`, so they never come out darker than the input and rise with ev.
pub fn exposure(l: f32, ev: f32) -> f32 {
    if ev == 0.0 {
        return l;
    }
    let g = ev.exp2();
    let m = l * g;
    if !(ev > 0.0 && m > EXPOSURE_KNEE) {
        return m;
    }
    let s = EXPOSURE_KNEE;
    let w = g;
    let a = (w - 1.0) / (1.0 - s);
    let u = (m - s) / (w - s);
    if u <= 1.0 {
        return s + (1.0 - s) * u * (1.0 + a) / (1.0 + a * u);
    }
    1.0 + (m - w)
}

/// Schlick bias: 0 -> 0, 1 -> 1, slope 1/(1+k) at 0 and 1+k at 1.
fn bias(u: f32, k: f32) -> f32 {
    u / (k * (1.0 - u) + 1.0)
}

/// S-curve about the pivot: pivot, 0 and 1 stay; positive steepens the middle, negative flattens it.
pub fn contrast(x: f32, c: f32) -> f32 {
    if c == 0.0 {
        return x;
    }
    let k = if c >= 0.0 { c * CONTRAST_UP } else { c * CONTRAST_DOWN };
    let p = CONTRAST_PIVOT;
    if x < 0.0 {
        return x / (1.0 + k);
    }
    if x > 1.0 {
        return 1.0 + (x - 1.0) / (1.0 + k);
    }
    if x <= p {
        return p * bias(x / p, k);
    }
    1.0 - (1.0 - p) * bias((1.0 - x) / (1.0 - p), k)
}

/// Bump on the upper tones (peak at 2/3), black and white fixed; +100 compresses the very top.
pub fn highlights(x: f32, h: f32) -> f32 {
    if h == 0.0 || !(x > 0.0 && x < 1.0) {
        return x;
    }
    x + HIGHLIGHTS_REACH * h * 6.75 * x * x * (1.0 - x)
}

/// Bump on the lower tones (peak at 1/3), black and white fixed.
pub fn shadows(x: f32, s: f32) -> f32 {
    if s == 0.0 || !(x > 0.0 && x < 1.0) {
        return x;
    }
    x + SHADOWS_REACH * s * 6.75 * x * (1.0 - x) * (1.0 - x)
}

/// Gain about black.
pub fn whites(x: f32, w: f32) -> f32 {
    if w == 0.0 { x } else { x * (WHITES_STOPS * w).exp2() }
}

/// Black point move hinged low: `x + d (1 - x)^2` with d = 0.2 x amount; white and everything near it stay. Below 0
/// it continues with its slope at 0; negative amounts push the darkest tones below 0 (the display clips them).
pub fn blacks(x: f32, b: f32) -> f32 {
    if b == 0.0 || x.is_nan() || x >= 1.0 {
        return x;
    }
    let d = BLACKS_REACH * b;
    if x < 0.0 {
        return d + x * (1.0 - 2.0 * d);
    }
    x + d * (1.0 - x) * (1.0 - x)
}

// BT.709 OETF (same constants as the renderer's transfer functions).
const ALPHA: f32 = 1.0992968;
const BETA: f32 = 0.01805397;

/// BT.709 OETF: linear light to signal.
pub fn oetf(l: f32) -> f32 {
    if l < BETA { 4.5 * l } else { ALPHA * l.powf(0.45) - (ALPHA - 1.0) }
}

/// Inverse of [`oetf`].
pub fn inverse_oetf(v: f32) -> f32 {
    if v < 4.5 * BETA { v / 4.5 } else { ((v + ALPHA - 1.0) / ALPHA).powf(1.0 / 0.45) }
}

/// The tone part after Exposure (Contrast, Highlights, Shadows, Whites, Blacks) on one channel of the signal.
pub fn tone_after_exposure(x: f32, b: &BasicCorrection) -> f32 {
    fn n(v: f32) -> f32 {
        v.clamp(-100.0, 100.0) / 100.0
    }
    let mut t = contrast(x, n(b.contrast));
    t = highlights(t, n(b.highlights));
    t = shadows(t, n(b.shadows));
    t = whites(t, n(b.whites));
    blacks(t, n(b.blacks))
}

/// A gray of display value `y` through the whole tone part (Exposure on its linear light, then the curves).
pub fn tone(y: f32, b: &BasicCorrection) -> f32 {
    let ev = b.exposure.clamp(-5.0, 5.0);
    let t = if ev == 0.0 { y } else { oetf(exposure(inverse_oetf(y), ev)) };
    tone_after_exposure(t, b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid() -> Vec<f32> {
        (0..=200).map(|i| -0.5 + 0.01 * i as f32).collect()
    }
    const AMOUNTS: [f32; 10] = [-1.0, -0.75, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 0.75, 1.0];

    fn is_monotone(f: fn(f32, f32) -> f32, a: f32) -> bool {
        let mut prev = f32::NEG_INFINITY;
        for x in grid() {
            let y = f(x, a);
            if y.is_nan() || y <= prev {
                return false;
            }
            prev = y;
        }
        true
    }

    /// Grid point (0...1) where `f(x, 1) - x` is largest.
    fn peak(f: fn(f32, f32) -> f32) -> f32 {
        let (mut best, mut best_d) = (0.0, f32::NEG_INFINITY);
        for i in 0..=100 {
            let x = i as f32 * 0.01;
            let d = f(x, 1.0) - x;
            if d > best_d {
                best_d = d;
                best = x;
            }
        }
        best
    }

    #[test]
    fn oetf_constants_are_the_swift_literals() {
        assert_eq!(ALPHA, 1.09929682680944_f64 as f32);
        assert_eq!(BETA, 0.018053968510807_f64 as f32);
    }

    #[test]
    fn contrast_keeps_mid_grey_black_and_white() {
        for c in AMOUNTS {
            assert!((contrast(0.5, c) - 0.5).abs() < 1e-6, "mid gray stays at 50 IRE (c {c})");
            assert!(contrast(0.0, c).abs() < 1e-6 && (contrast(1.0, c) - 1.0).abs() < 1e-6, "ends stay (c {c})");
        }
        assert_eq!(contrast(0.3, 0.0), 0.3, "0 is the identity");
    }

    #[test]
    fn contrast_is_an_s_curve_up_and_an_inverse_s_curve_down() {
        let (lo, hi) = (contrast(0.25, 0.5), contrast(0.75, 0.5));
        assert!(lo < 0.25 && hi > 0.75);
        assert!(((0.25 - lo) - (hi - 0.75)).abs() < 1e-5);
        assert!((lo - 0.2).abs() < 1e-4, "+50 puts 25 IRE at 20 IRE");
        let (flo, fhi) = (contrast(0.25, -0.5), contrast(0.75, -0.5));
        assert!(flo > 0.25 && fhi < 0.75);
        assert!(contrast(0.1, 1.0) > 0.02 && contrast(0.9, 1.0) < 0.98);
        assert!(contrast(0.75, -1.0) - contrast(0.25, -1.0) > 0.3);
    }

    #[test]
    fn contrast_never_folds() {
        for c in AMOUNTS {
            assert!(is_monotone(contrast, c), "c {c}");
        }
    }

    #[test]
    fn highlights_and_shadows_keep_the_ends() {
        for a in AMOUNTS {
            assert!(highlights(0.0, a) == 0.0 && highlights(1.0, a) == 1.0);
            assert!(shadows(0.0, a) == 0.0 && shadows(1.0, a) == 1.0);
        }
    }

    #[test]
    fn shadows_barely_move_highlights_and_highlights_barely_move_shadows() {
        assert!(shadows(0.25, 0.5) - 0.25 > 0.04);
        assert!((shadows(0.9, 0.5) - 0.9).abs() < 0.01);
        assert!(shadows(0.25, -0.5) < 0.25 - 0.04);
        assert!(highlights(0.75, 0.5) - 0.75 > 0.03);
        assert!((highlights(0.1, 0.5) - 0.1).abs() < 0.01);
        assert!(highlights(0.75, -0.5) < 0.75 - 0.03);
        assert!((peak(shadows) - 1.0 / 3.0).abs() < 0.02 && (peak(highlights) - 2.0 / 3.0).abs() < 0.02);
    }

    #[test]
    fn highlights_and_shadows_never_fold_and_stay_in_range() {
        for a in AMOUNTS {
            assert!(is_monotone(highlights, a), "h {a}");
            assert!(is_monotone(shadows, a), "s {a}");
            for i in 0..=20 {
                let x = i as f32 * 0.05;
                assert!((0.0..=1.0).contains(&highlights(x, a)) && (0.0..=1.0).contains(&shadows(x, a)));
            }
        }
    }

    #[test]
    fn whites_is_a_gain_about_black() {
        assert_eq!(whites(0.0, 1.0), 0.0);
        assert!((whites(0.5, 1.0) / 0.5 - WHITES_STOPS.exp2()).abs() < 1e-5);
        assert!((whites(0.8, -1.0) / 0.8 - (-WHITES_STOPS).exp2()).abs() < 1e-5);
        assert_eq!(whites(0.4, 0.0), 0.4);
    }

    #[test]
    fn blacks_hinge_low_and_leave_highlights() {
        assert!((blacks(0.0, 1.0) - 0.2).abs() < 1e-6);
        assert!(blacks(0.5, 1.0) - 0.5 < 0.06);
        assert!((blacks(0.9, 1.0) - 0.9).abs() < 0.003);
        assert!(blacks(1.0, 1.0) == 1.0 && blacks(1.0, -1.0) == 1.0);
        assert!(blacks(0.14, -1.0) <= 0.0);
        assert!((blacks(0.5, -1.0) - 0.45).abs() < 0.01);
        for b in AMOUNTS {
            assert!(is_monotone(blacks, b), "b {b}");
        }
    }

    #[test]
    fn exposure_down_is_a_gain_and_up_rolls_off_into_white() {
        assert!((exposure(0.5, -1.0) - 0.25).abs() < 1e-6, "-1 halves linear light");
        assert!((exposure(0.05, 1.0) - 0.1).abs() < 1e-6, "below the knee +1 doubles");
        for ev in [0.1_f32, 0.5, 1.0, 2.0, 5.0] {
            assert!((exposure(1.0, ev) - 1.0).abs() < 1e-5, "white stays white at +{ev}");
            assert!(exposure(0.9, ev) < 1.0, "nothing below white clips at +{ev}");
            let mut prev = f32::NEG_INFINITY;
            for i in 0..=420 {
                let y = exposure(-0.2 + i as f32 * 0.01, ev);
                assert!(y > prev);
                prev = y;
            }
        }
        assert!((exposure(0.18, 1.0) / 0.18).log2() > 0.85);
        assert!((exposure(0.4, 0.0001) - 0.4).abs() < 1e-3, "continuous at 0");
    }

    #[test]
    fn exposure_up_never_darkens_and_is_monotone_in_stops() {
        assert!(exposure(2.0, 0.5) >= 2.0);
        assert!(exposure(1.1, 1.0) >= 1.1);
        for xi in 0..=80 {
            let x = xi as f32 * 0.05;
            let mut prev = x;
            for ei in 1..=100 {
                let ev = ei as f32 * 0.05;
                let y = exposure(x, ev);
                assert!(y >= x - 1e-5, "x {x} ev {ev} darkened to {y}");
                assert!(y >= prev - 1e-5, "x {x} not monotone at ev {ev}");
                prev = y;
            }
        }
        for ev in [0.5_f32, 1.0, 3.0] {
            assert!(exposure(1.6, ev) - exposure(1.5, ev) >= 0.1 - 1e-5);
        }
    }

    #[test]
    fn neutral_tone_is_the_identity_and_ranges_map_sensibly() {
        let b = BasicCorrection::default();
        assert_eq!(b.model, sq_core_model::BasicToneModel::Lumetri);
        for i in 0..=10 {
            let y = i as f32 * 0.1;
            assert_eq!(tone(y, &b), y);
        }
        let setters: [fn(&mut BasicCorrection, f32); 5] = [
            |b, v| b.contrast = v,
            |b, v| b.highlights = v,
            |b, v| b.shadows = v,
            |b, v| b.whites = v,
            |b, v| b.blacks = v,
        ];
        for set in setters {
            for v in [-100.0_f32, 100.0] {
                let mut t = BasicCorrection::default();
                set(&mut t, v);
                assert!((0.0..=1.0).contains(&tone(0.5, &t)));
            }
        }
    }
}
