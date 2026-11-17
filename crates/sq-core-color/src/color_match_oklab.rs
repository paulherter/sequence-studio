// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorMatchOklab.swift
//! Color Match measured perceptually. Both clips' stored band means are compared in Oklab (Bjorn Ottosson, "A
//! perceptual color space for image processing", 2020: the published matrices), each tone band gets its own shift,
//! skin hues keep only a fifth of the change, clearly colored pixels turn by at most a few degrees of hue, and the
//! result is fitted onto the ordinary Color Wheels by running the real wheels model on a few hundred sample colors, so
//! it stays an editable grade. The stored `ColorMatchStats` are unchanged (display RGB).

use crate::auto_tone_solver::smooth;
use crate::color_match::ColorMatchStatsExt;
use crate::vec3::{V3, add, clamp3, mul, scale, sub, sum};
use sq_core_model::ColorMatchStats;
use std::f32::consts::PI;

/// Oklab conversions on `[L, a, b]` triples.
pub struct Oklab;

fn signed_pow(v: f32, e: f32) -> f32 {
    if v < 0.0 { -(-v).powf(e) } else { v.powf(e) }
}

impl Oklab {
    /// Linear sRGB to Oklab.
    pub fn from_linear(c: V3) -> V3 {
        let l = 0.412_221_46 * c[0] + 0.536_332_55 * c[1] + 0.051_445_995 * c[2];
        let m = 0.211_903_5 * c[0] + 0.680_699_5 * c[1] + 0.107_396_96 * c[2];
        let s = 0.088_302_46 * c[0] + 0.281_718_85 * c[1] + 0.629_978_7 * c[2];
        let (l_, m_, s_) = (l.cbrt(), m.cbrt(), s.cbrt());
        [
            0.210_454_26 * l_ + 0.793_617_8 * m_ - 0.004_072_047 * s_,
            1.977_998_5 * l_ - 2.428_592_2 * m_ + 0.450_593_7 * s_,
            0.025_904_037 * l_ + 0.782_771_77 * m_ - 0.808_675_77 * s_,
        ]
    }

    /// Oklab to linear sRGB.
    pub fn to_linear(lab: V3) -> V3 {
        let l_ = lab[0] + 0.396_337_78 * lab[1] + 0.215_803_76 * lab[2];
        let m_ = lab[0] - 0.105_561_346 * lab[1] - 0.063_854_17 * lab[2];
        let s_ = lab[0] - 0.089_484_18 * lab[1] - 1.291_485_5 * lab[2];
        let (l, m, s) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_);
        [
            4.076_741_7 * l - 3.307_711_6 * m + 0.230_969_94 * s,
            -1.268_438 * l + 2.609_757_4 * m - 0.341_319_38 * s,
            -0.0041960863 * l - 0.703_418_6 * m + 1.707_614_7 * s,
        ]
    }

    /// Display-encoded RGB (gamma 2.4 approximation) to Oklab.
    pub fn from_display(c: V3) -> V3 {
        Self::from_linear(c.map(|x| signed_pow(x, 2.4)))
    }

    /// Oklab to display-encoded RGB.
    pub fn to_display(lab: V3) -> V3 {
        Self::to_linear(lab).map(|x| signed_pow(x, 1.0 / 2.4))
    }
}

/// The per-band Oklab shifts that take a clip's stats to a reference's, and the per-color target they imply.
pub(crate) struct ColorMatchTargets {
    shift: Vec<V3>,
    chroma_scale: f32,
    clip_cast: Vec<[f32; 2]>,
}

impl ColorMatchTargets {
    /// Skin keeps this share of the change.
    pub(crate) const SKIN_KEEP: f32 = 0.2;
    /// A clearly colored object turns by at most this many degrees of hue.
    pub(crate) const MAX_HUE_CAST_DEGREES: f32 = 8.0;

    pub(crate) fn new(clip: &ColorMatchStats, reference: &ColorMatchStats, samples: &[V3]) -> ColorMatchTargets {
        // The stored chroma counts a cast as color, so the chroma scale starts at 1 and is found by the calibration
        // below, after the band shifts have taken the cast out.
        let mut k: f32 = 1.0;
        let clip_lab: Vec<V3> = clip.bands().into_iter().map(Oklab::from_display).collect();
        let ref_lab: Vec<V3> = reference.bands().into_iter().map(Oklab::from_display).collect();
        let clip_cast = clip_lab.iter().map(|l| [l[1] / l[0].max(0.05), l[2] / l[0].max(0.05)]).collect();
        let shift =
            clip_lab.iter().zip(&ref_lab).map(|(c, r)| [r[0] - c[0], r[1] - k * c[1], r[2] - k * c[2]]).collect();
        let mut me = ColorMatchTargets { shift, chroma_scale: k, clip_cast };
        // The samples are a subset of the measured clip: aim at the reference plus the subset's own offset from the clip.
        if samples.len() < 16 {
            return me;
        }
        let Some(base) = ColorMatchStats::measure(samples) else { return me };
        let base_lab: Vec<V3> = base.bands().into_iter().map(Oklab::from_display).collect();
        let want_lab: Vec<V3> = (0..3).map(|i| sub(add(ref_lab[i], base_lab[i]), clip_lab[i])).collect();
        let want_chroma =
            if clip.chroma > 1e-4 { reference.chroma * base.chroma / clip.chroma } else { reference.chroma };
        let labs: Vec<V3> = samples.iter().copied().map(Oklab::from_display).collect();
        for _ in 0..3 {
            let shown: Vec<V3> = (0..samples.len()).map(|i| Oklab::to_display(me.plain(labs[i], samples[i]))).collect();
            let Some(s) = ColorMatchStats::measure(&shown) else { break };
            let got: Vec<V3> = s.bands().into_iter().map(Oklab::from_display).collect();
            for b in 0..3 {
                me.shift[b] = add(me.shift[b], sub(want_lab[b], got[b]));
            }
            if s.chroma > 1e-4 {
                let k2 = (k * want_chroma / s.chroma).clamp(0.25, 4.0);
                // Keep the band means where they are while the chroma scale changes.
                for (shift, lab) in me.shift.iter_mut().zip(&clip_lab) {
                    shift[1] -= (k2 - k) * lab[1];
                    shift[2] -= (k2 - k) * lab[2];
                }
                k = k2;
                me.chroma_scale = k;
            }
        }
        me
    }

    /// How much a Lab color looks like skin (hue between orange and yellow-orange, enough chroma): 0...1.
    pub(crate) fn skin_weight(lab: V3) -> f32 {
        let c = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
        if c.is_nan() || c <= 0.02 {
            return 0.0;
        }
        let mut h = lab[2].atan2(lab[1]) * 180.0 / PI;
        if h < 0.0 {
            h += 360.0;
        }
        smooth(15.0, 25.0, h) * (1.0 - smooth(70.0, 80.0, h)) * smooth(0.02, 0.04, c)
    }

    fn bands(display: V3) -> V3 {
        ColorMatchStats::band_weights(sum(mul(ColorMatchStats::LUMA, clamp3(display, 0.0, 1.5))))
    }

    /// The color after the band shifts, without skin protection or the hue clamp.
    pub(crate) fn plain(&self, lab: V3, display: V3) -> V3 {
        let bw = Self::bands(display);
        let d = add(add(scale(self.shift[0], bw[0]), scale(self.shift[1], bw[1])), scale(self.shift[2], bw[2]));
        [lab[0] + d[0], self.chroma_scale * lab[1] + d[1], self.chroma_scale * lab[2] + d[2]]
    }

    /// How far the color's chroma stands out from the clip's own cast at its tone.
    fn stand_out(&self, lab: V3, display: V3) -> f32 {
        let bw = Self::bands(display);
        let cast_y = (bw[0] * self.clip_cast[0][0] + bw[1] * self.clip_cast[1][0] + bw[2] * self.clip_cast[2][0])
            * lab[0].max(0.0);
        let cast_z = (bw[0] * self.clip_cast[0][1] + bw[1] * self.clip_cast[1][1] + bw[2] * self.clip_cast[2][1])
            * lab[0].max(0.0);
        let r = [lab[1] - cast_y, lab[2] - cast_z];
        (r[0] * r[0] + r[1] * r[1]).sqrt()
    }

    /// The Lab color a pixel is aimed at.
    pub(crate) fn target(&self, lab: V3, display: V3) -> V3 {
        let mut t = self.plain(lab, display);
        let rel = self.stand_out(lab, display);
        // Hue-cast clamp: a clearly colored object turns by at most `MAX_HUE_CAST_DEGREES`; below that the allowed
        // turn widens smoothly towards any angle (pixels that are just the cast take it all).
        let c0 = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
        let c1 = (t[1] * t[1] + t[2] * t[2]).sqrt();
        let hold = smooth(0.04, 0.07, rel);
        if hold > 0.0 && c0 > 1e-4 && c1 > 1e-5 {
            let h0 = lab[2].atan2(lab[1]);
            let mut dh = t[2].atan2(t[1]) - h0;
            if dh > PI {
                dh -= 2.0 * PI;
            } else if dh < -PI {
                dh += 2.0 * PI;
            }
            let lim = Self::MAX_HUE_CAST_DEGREES * PI / 180.0;
            let allowed = lim + (PI - lim) * (1.0 - hold);
            if dh.abs() > allowed {
                let h = h0 + if dh > 0.0 { allowed } else { -allowed };
                t[1] = c1 * h.cos();
                t[2] = c1 * h.sin();
            }
        }
        // Skin keeps a fifth of the change (interpolating keeps the hue turn within the clamp).
        let s = Self::skin_weight(lab) * smooth(0.03, 0.05, rel);
        if s > 0.0 {
            t = add(lab, scale(sub(t, lab), 1.0 - (1.0 - Self::SKIN_KEEP) * s));
        }
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color_match::color_match_solver as solver;
    use crate::color_match::color_wheels_model as wheels_model;
    use crate::color_match::tests::{max_abs, max_band_error, picture};
    use sq_core_model::ColorWheels;

    fn near(a: V3, b: V3, tol: f32) -> bool {
        (a[0] - b[0]).abs() <= tol && (a[1] - b[1]).abs() <= tol && (a[2] - b[2]).abs() <= tol
    }

    /// Patch of one color with small deterministic noise and a luma spread.
    fn patch(c: V3, n: usize, shift: V3) -> Vec<V3> {
        let mut s: u32 = 777;
        let mut r = move || -> f32 {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (s >> 8) as f32 / (1u32 << 24) as f32
        };
        (0..n)
            .map(|i| {
                let k = 0.75 + 0.5 * i as f32 / n as f32;
                let noise = [0.02 * (r() - 0.5), 0.02 * (r() - 0.5), 0.02 * (r() - 0.5)];
                clamp3(add(add(scale(c, k), noise), shift), 0.0, 1.0)
            })
            .collect()
    }

    fn mean_move(px: &[V3], w: &ColorWheels) -> f32 {
        let total = px.iter().fold(0.0_f32, |acc, p| {
            let d = sub(Oklab::from_display(wheels_model::apply(*p, w)), Oklab::from_display(*p));
            acc + length_squared_of(d).sqrt()
        });
        total / px.len() as f32
    }

    fn length_squared_of(d: V3) -> f32 {
        sum(mul(d, d))
    }

    /// A gray scene with a colored object (about a fifth of the picture).
    fn scene(object: V3, shift: V3) -> Vec<V3> {
        let mut v: Vec<V3> = picture(1600, [0.0; 3]).into_iter().map(|p| clamp3(add(p, shift), 0.0, 1.0)).collect();
        v.extend(patch(object, 500, shift));
        v
    }

    #[test]
    fn oklab_of_white_grey_and_red_matches_the_published_values() {
        assert!(near(Oklab::from_display([1.0; 3]), [1.0, 0.0, 0.0], 1e-3));
        let g = Oklab::from_display([0.5; 3]);
        assert!(g[1].abs() < 1e-3 && g[2].abs() < 1e-3);
        // Linear sRGB red (display 1,0,0 is linear 1,0,0): L 0.628, a 0.225, b 0.126.
        assert!(near(Oklab::from_display([1.0, 0.0, 0.0]), [0.628, 0.225, 0.126], 2e-3));
        let c = [0.3, 0.6, 0.2];
        assert!(near(Oklab::to_display(Oklab::from_display(c)), c, 1e-4));
    }

    #[test]
    fn neutral_input_gives_identity() {
        let grey = patch([0.5; 3], 1200, [0.0; 3]);
        let reference = ColorMatchStats::measure(&grey).expect("measures");
        assert!(solver::solve(&grey, &ColorWheels::default(), &reference).is_none());
        let plan = ColorMatchTargets::new(&reference, &reference, &[]);
        for p in grey.iter().take(50) {
            assert!(near(plan.target(Oklab::from_display(*p), *p), Oklab::from_display(*p), 1e-5));
        }
    }

    #[test]
    fn skin_hues_are_recognised_and_others_are_not() {
        let skin = |c| ColorMatchTargets::skin_weight(Oklab::from_display(c));
        assert!(skin([0.82, 0.62, 0.50]) > 0.9);
        assert!(skin([0.62, 0.42, 0.32]) > 0.9);
        assert_eq!(skin([0.30, 0.55, 0.22]), 0.0);
        assert_eq!(skin([0.25, 0.36, 0.62]), 0.0);
        assert_eq!(skin([0.5; 3]), 0.0);
    }

    #[test]
    fn a_skin_object_moves_less_than_a_green_object_for_the_same_cast() {
        let shift = [-0.04, 0.0, 0.05];
        let skin_colour = [0.78, 0.58, 0.46];
        let green_colour = [0.36, 0.56, 0.30];
        let skin_ref = ColorMatchStats::measure(&scene(skin_colour, shift)).expect("measures");
        let green_ref = ColorMatchStats::measure(&scene(green_colour, shift)).expect("measures");
        let ws = solver::solve(&scene(skin_colour, [0.0; 3]), &ColorWheels::default(), &skin_ref).expect("solves");
        let wg = solver::solve(&scene(green_colour, [0.0; 3]), &ColorWheels::default(), &green_ref).expect("solves");
        let ms = mean_move(&patch(skin_colour, 1200, [0.0; 3]), &ws);
        let mg = mean_move(&patch(green_colour, 1200, [0.0; 3]), &wg);
        assert!(ms < mg, "skin {ms} green {mg}");
        // The plan itself keeps a fifth of the change on skin.
        let clip = ColorMatchStats::measure(&scene(skin_colour, [0.0; 3])).expect("measures");
        let plan = ColorMatchTargets::new(&clip, &skin_ref, &[]);
        let lab = Oklab::from_display(skin_colour);
        let full = sub(plan.plain(lab, skin_colour), lab);
        let kept = sub(plan.target(lab, skin_colour), lab);
        assert!(length_squared_of(kept).sqrt() < 0.3 * length_squared_of(full).sqrt());
    }

    #[test]
    fn match_on_a_coloured_scene_moves_the_bands_towards_the_reference() {
        // Clip: a cooler, darker copy of a scene with a green and a skin object; reference: the scene itself.
        let mut ref_pic = scene([0.36, 0.56, 0.30], [0.0; 3]);
        ref_pic.extend(patch([0.78, 0.58, 0.46], 300, [0.0; 3]));
        let clip_pic: Vec<V3> =
            ref_pic.iter().map(|p| clamp3([p[0] * 0.85 - 0.02, p[1] * 0.9, p[2] * 0.95 + 0.04], 0.0, 1.0)).collect();
        let reference = ColorMatchStats::measure(&ref_pic).expect("measures");
        let before = ColorMatchStats::measure(&clip_pic).expect("measures");
        let w = solver::solve(&clip_pic, &ColorWheels::default(), &reference).expect("solves");
        let shown: Vec<V3> = clip_pic.iter().map(|p| wheels_model::apply(*p, &w)).collect();
        let after = ColorMatchStats::measure(&shown).expect("measures");
        let (e0, e1) = (max_band_error(&before, &reference), max_band_error(&after, &reference));
        assert!(e1 < e0 / 2.0, "band error {e0} -> {e1}");
        for (a, (b, r)) in after.bands().iter().zip(before.bands().iter().zip(reference.bands().iter())) {
            assert!(max_abs(sub(*a, *r)) < max_abs(sub(*b, *r)), "{b:?} -> {a:?}, ref {r:?}");
        }
    }

    #[test]
    fn a_scene_wide_warm_cast_is_corrected_in_full() {
        // Every pixel is orange only because of the cast: nothing stands out, so nothing is protected.
        let reference = ColorMatchStats::measure(&picture(2400, [0.0; 3])).expect("measures");
        let warm: Vec<V3> =
            picture(2400, [0.0; 3]).iter().map(|p| clamp3([p[0], p[1] * 0.85, p[2] * 0.7], 0.0, 1.0)).collect();
        let clip = ColorMatchStats::measure(&warm).expect("measures");
        let plan = ColorMatchTargets::new(&clip, &reference, &[]);
        let (mut held, mut n) = (0, 0);
        for p in warm.iter().step_by(8) {
            let lab = Oklab::from_display(*p);
            n += 1;
            if !near(plan.target(lab, *p), plan.plain(lab, *p), 1e-4) {
                held += 1;
            }
        }
        assert!(held * 20 < n, "{held} of {n} held back");
    }

    #[test]
    fn the_hue_of_a_clearly_coloured_object_turns_at_most_eight_degrees() {
        // Reference: the blue object turned towards cyan (a large hue cast).
        let blue = [0.20, 0.30, 0.75];
        let clip = ColorMatchStats::measure(&scene(blue, [0.0; 3])).expect("measures");
        let reference = ColorMatchStats::measure(&scene([0.20, 0.60, 0.65], [0.0; 3])).expect("measures");
        let plan = ColorMatchTargets::new(&clip, &reference, &[]);
        let mut turned = 0;
        for p in patch(blue, 1200, [0.0; 3]).iter().take(200) {
            let lab = Oklab::from_display(*p);
            let t = plan.target(lab, *p);
            let u = plan.plain(lab, *p);
            let turn = |x: V3| -> f32 {
                let mut d = (x[2].atan2(x[1]) - lab[2].atan2(lab[1])).abs() * 180.0 / PI;
                if d > 180.0 {
                    d = 360.0 - d;
                }
                d
            };
            if turn(u) > 9.0 {
                turned += 1;
            }
            assert!(turn(t) <= ColorMatchTargets::MAX_HUE_CAST_DEGREES + 0.01);
        }
        assert!(turned > 100, "without the clamp the object would turn further");
    }

    #[test]
    fn result_stays_within_the_grade_bounds() {
        let src = picture(2400, [0.0; 3]);
        // An extreme reference: very dark and very blue.
        let dark_blue: Vec<V3> = src.iter().map(|p| clamp3([p[0] * 0.1, p[1] * 0.2, p[2] * 1.4], 0.0, 1.0)).collect();
        let reference = ColorMatchStats::measure(&dark_blue).expect("measures");
        let w = solver::solve(&src, &ColorWheels::default(), &reference).expect("solves");
        for v in [w.shadows, w.midtones, w.highlights] {
            assert!(v.amount >= 0.0 && v.amount <= 1.0 && v.hue >= 0.0 && v.hue < 360.0);
        }
        for l in [w.shadows_luma, w.midtones_luma, w.highlights_luma] {
            assert!((-100.0..=100.0).contains(&l));
        }
        assert!(w.saturation >= 0.0 && w.saturation <= 200.0);
    }
}
