// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Benchmark/MaskMetrics.swift
//! Segmentation metrics of the mask benchmark (REPORT.md section 5): J (region IoU), F (boundary F-measure, DAVIS style with
//! a tolerance of 0.8% of the diagonal) and J&F. Pure math on bool grids, no media or model.
use crate::mask_bench_scenarios::MaskFrameScore;
use crate::mask_lag::MaskLagSample;

/// The metrics.
pub struct MaskMetrics;

impl MaskMetrics {
    /// Boundary tolerance as a fraction of the diagonal (the Swift default).
    pub const BOUNDARY_TOLERANCE: f64 = 0.008;

    /// Region similarity. Two empty masks are a perfect match.
    pub fn jaccard(a: &[bool], b: &[bool]) -> f64 {
        assert_eq!(a.len(), b.len(), "mask size mismatch");
        let (mut inter, mut union) = (0_u64, 0_u64);
        for (x, y) in a.iter().zip(b) {
            if *x && *y {
                inter += 1;
            }
            if *x || *y {
                union += 1;
            }
        }
        if union == 0 { 1.0 } else { inter as f64 / union as f64 }
    }

    /// Pixels of the mask with at least one 4-neighbor outside it (the frame edge counts as inside).
    pub fn boundary(m: &[bool], width: usize, height: usize) -> Vec<bool> {
        let mut out = vec![false; m.len()];
        for y in 0..height {
            for x in 0..width {
                if !m[y * width + x] {
                    continue;
                }
                let edge = (x > 0 && !m[y * width + x - 1])
                    || (x < width - 1 && !m[y * width + x + 1])
                    || (y > 0 && !m[(y - 1) * width + x])
                    || (y < height - 1 && !m[(y + 1) * width + x]);
                if edge {
                    out[y * width + x] = true;
                }
            }
        }
        out
    }

    /// `m` grown by `radius` px (square window, separable).
    fn dilated(m: &[bool], width: usize, height: usize, radius: usize) -> Vec<bool> {
        let mut h = vec![false; m.len()];
        for y in 0..height {
            for x in 0..width {
                if m[y * width + x] {
                    for xx in x.saturating_sub(radius)..=(width - 1).min(x + radius) {
                        h[y * width + xx] = true;
                    }
                }
            }
        }
        let mut v = vec![false; m.len()];
        for y in 0..height {
            for x in 0..width {
                if h[y * width + x] {
                    for yy in y.saturating_sub(radius)..=(height - 1).min(y + radius) {
                        v[yy * width + x] = true;
                    }
                }
            }
        }
        v
    }

    /// Boundary F-measure. Both boundaries empty: 1; one empty: 0. `pixels` fixes the tolerance in px instead of the
    /// `tolerance` fraction of the diagonal.
    pub fn boundary_f(
        pred: &[bool],
        gt: &[bool],
        width: usize,
        height: usize,
        tolerance: f64,
        pixels: Option<usize>,
    ) -> f64 {
        assert!(pred.len() == width * height && gt.len() == pred.len(), "mask size mismatch");
        let bp = Self::boundary(pred, width, height);
        let bg = Self::boundary(gt, width, height);
        let np = bp.iter().filter(|b| **b).count();
        let ng = bg.iter().filter(|b| **b).count();
        if np == 0 && ng == 0 {
            return 1.0;
        }
        if np == 0 || ng == 0 {
            return 0.0;
        }
        let r = pixels
            .unwrap_or_else(|| 1.max((tolerance * ((width * width + height * height) as f64).sqrt()).round() as usize));
        let near_g = Self::dilated(&bg, width, height, r);
        let near_p = Self::dilated(&bp, width, height, r);
        let (mut hit_p, mut hit_g) = (0_u64, 0_u64);
        for i in 0..bp.len() {
            if bp[i] && near_g[i] {
                hit_p += 1;
            }
            if bg[i] && near_p[i] {
                hit_g += 1;
            }
        }
        let precision = hit_p as f64 / np as f64;
        let recall = hit_g as f64 / ng as f64;
        if precision + recall == 0.0 { 0.0 } else { 2.0 * precision * recall / (precision + recall) }
    }

    /// Mean absolute difference of the soft matte to the truth in the band of `radius` px around the truth's edge: how close
    /// the edge pixels are to the real alpha (a blobby or hand-drawn edge scores high, a keyed one low).
    pub fn band_error(alpha: &[f32], truth: &[f32], width: usize, height: usize, radius: usize) -> f64 {
        let t: Vec<bool> = truth.iter().map(|v| *v >= 0.5).collect();
        let band = Self::dilated(&Self::boundary(&t, width, height), width, height, radius);
        let (mut sum, mut n) = (0.0, 0_u64);
        for i in 0..band.len() {
            if band[i] {
                sum += f64::from((alpha[i] - truth[i]).abs());
                n += 1;
            }
        }
        if n == 0 { 0.0 } else { sum / n as f64 }
    }

    /// Nearest-neighbor shrink so the metrics stay cheap on 4K frames (longest side at most `long_side`). Returns the mask and
    /// its size.
    pub fn downscaled(values: &[f32], width: usize, height: usize, long_side: usize) -> (Vec<bool>, usize, usize) {
        let scale = 1.0_f64.min(long_side as f64 / width.max(height) as f64);
        let w = 1.max((width as f64 * scale).round() as usize);
        let h = 1.max((height as f64 * scale).round() as usize);
        let mut out = vec![false; w * h];
        for y in 0..h {
            let sy = (height - 1).min(((y as f64 + 0.5) / scale) as usize);
            for x in 0..w {
                let sx = (width - 1).min(((x as f64 + 0.5) / scale) as usize);
                out[y * w + x] = values[sy * width + sx] >= 0.5;
            }
        }
        (out, w, h)
    }
}

/// Scores of one variant on one clip, averaged over the labeled frames that were scored.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MaskBenchScore {
    /// Mean region similarity.
    pub j: f64,
    /// Mean boundary F-measure.
    pub f: f64,
    /// Strict edge score at the frame's full size: boundary F within 2 px.
    pub f2: f64,
    /// The soft matte's mean error in the 6 px band around the true edge.
    pub band_error: f64,
    /// J of the first labeled frame (the pick itself, before any tracking).
    pub first_j: f64,
    /// Strict F of the first labeled frame.
    pub first_f2: f64,
    /// Frames scored.
    pub scored: u32,
    /// Frames the tracker answered "lost" or "nothing".
    pub lost_frames: u32,
    /// Scripted corrections given (strokes variant).
    pub corrections: u32,
    /// Wall time of the tracker's steps (seconds).
    pub step_seconds: f64,
    /// How many steps were taken.
    pub steps: u32,
    /// Per scored frame, when asked for (the benchmark's details).
    pub notes: Vec<String>,
    /// J and F of every scored labeled frame, in order (the scenario reports cut windows out of it).
    pub per_frame: Vec<MaskFrameScore>,
    /// Frame indices the tracker answered "lost", "nothing" or threw on.
    pub lost_frame_indices: Vec<i64>,
    /// Mask and truth centroids of every scored labeled frame (the lag report, `MaskLag`).
    pub lag_samples: Vec<MaskLagSample>,
    /// The clip's frame rate (the lag report's speeds per second).
    pub fps: f64,
}

impl MaskBenchScore {
    /// Milliseconds per step.
    pub fn ms_per_frame(&self) -> f64 {
        if self.steps > 0 { self.step_seconds * 1000.0 / f64::from(self.steps) } else { 0.0 }
    }

    /// Mean of J and F.
    pub fn jf(&self) -> f64 {
        (self.j + self.f) / 2.0
    }

    /// Adds one scored frame to the running means.
    pub fn add(&mut self, j: f64, f: f64, f2: f64, band_error: f64) {
        let n = f64::from(self.scored);
        self.f2 = (self.f2 * n + f2) / (n + 1.0);
        self.band_error = (self.band_error * n + band_error) / (n + 1.0);
        self.j = (self.j * n + j) / (n + 1.0);
        self.f = (self.f * n + f) / (n + 1.0);
        self.scored += 1;
    }

    /// The compact table written to build/mask-bench.md: one row per clip and variant.
    pub fn table(rows: &[(&str, &str, &MaskBenchScore)]) -> String {
        let mut s = String::from(
            "| clip | variant | J | F | J&F | lost | corr | scored | ms/frame | F2px | band err | J@0 | F2@0 |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|\n",
        );
        for (clip, variant, sc) in rows {
            s += &format!(
                "| {clip} | {variant} | {:.3} | {:.3} | {:.3} | {} | {} | {} | {:.0} | {:.3} | {:.4} | {:.3} | {:.3} |\n",
                sc.j,
                sc.f,
                sc.jf(),
                sc.lost_frames,
                sc.corrections,
                sc.scored,
                sc.ms_per_frame(),
                sc.f2,
                sc.band_error,
                sc.first_j,
                sc.first_f2
            );
        }
        s
    }
}

/// A filled rectangle `x0..x1` x `y0..y1` on a `w` x `h` grid (shared by the benchmark tests).
#[cfg(test)]
pub(crate) fn rect(w: usize, h: usize, x0: usize, y0: usize, x1: usize, y1: usize) -> Vec<bool> {
    (0..w * h).map(|i| (i % w >= x0) && (i % w < x1) && (i / w >= y0) && (i / w < y1)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn boundary_f(p: &[bool], g: &[bool], w: usize, h: usize) -> f64 {
        MaskMetrics::boundary_f(p, g, w, h, MaskMetrics::BOUNDARY_TOLERANCE, None)
    }

    #[test]
    fn jaccard_of_known_overlaps() {
        let a = rect(10, 10, 0, 0, 4, 10); // 40 px
        let b = rect(10, 10, 2, 0, 6, 10); // 40 px, 20 shared
        assert_eq!(MaskMetrics::jaccard(&a, &a), 1.0);
        assert!((MaskMetrics::jaccard(&a, &b) - 20.0 / 60.0).abs() < 1e-9);
        assert_eq!(MaskMetrics::jaccard(&a, &rect(10, 10, 6, 0, 10, 10)), 0.0);
        assert_eq!(MaskMetrics::jaccard(&[false; 4], &[false; 4]), 1.0);
    }

    #[test]
    fn boundary_of_a_square_is_its_ring() {
        let m = rect(10, 10, 2, 2, 8, 8);
        assert_eq!(MaskMetrics::boundary(&m, 10, 10).iter().filter(|b| **b).count(), 20);
    }

    #[test]
    fn boundary_f_is_one_for_equal_and_drops_with_shift() {
        let a = rect(100, 100, 20, 20, 60, 60);
        let near = rect(100, 100, 21, 20, 61, 60);
        let far = rect(100, 100, 40, 40, 90, 90);
        assert_eq!(boundary_f(&a, &a, 100, 100), 1.0);
        assert!(boundary_f(&near, &a, 100, 100) > 0.9);
        assert!(boundary_f(&far, &a, 100, 100) < 0.5);
        assert_eq!(boundary_f(&vec![false; 10_000], &a, 100, 100), 0.0);
    }

    #[test]
    fn a_pixel_tolerance_is_stricter_than_the_diagonal_fraction() {
        let a = rect(100, 100, 20, 20, 60, 60);
        let shifted = rect(100, 100, 23, 20, 63, 60);
        let loose = MaskMetrics::boundary_f(&shifted, &a, 100, 100, 0.03, None);
        let strict = MaskMetrics::boundary_f(&shifted, &a, 100, 100, MaskMetrics::BOUNDARY_TOLERANCE, Some(1));
        assert!(strict < loose);
    }

    #[test]
    fn band_error_is_zero_for_the_truth_and_grows_with_a_blurred_edge() {
        let (w, h) = (60, 60);
        let truth: Vec<f32> = rect(w, h, 15, 15, 45, 45).iter().map(|b| if *b { 1.0 } else { 0.0 }).collect();
        assert_eq!(MaskMetrics::band_error(&truth, &truth, w, h, 6), 0.0);
        assert!(MaskMetrics::band_error(&vec![0.5; w * h], &truth, w, h, 6) > 0.4);
    }

    #[test]
    fn downscale_keeps_shape() {
        let mut v = vec![0.0_f32; 960 * 480];
        for y in 100..300 {
            for x in 200..600 {
                v[y * 960 + x] = 1.0;
            }
        }
        let (mask, w, h) = MaskMetrics::downscaled(&v, 960, 480, 480);
        assert!(w == 480 && h == 240);
        let area = mask.iter().filter(|b| **b).count() as f64 / (w * h) as f64;
        assert!((area - (200.0 * 400.0) / (960.0 * 480.0)).abs() < 0.01);
    }

    #[test]
    fn score_averages_and_table() {
        let mut s = MaskBenchScore::default();
        s.add(1.0, 0.5, 0.0, 0.0);
        s.add(0.5, 0.5, 0.0, 0.0);
        assert!((s.j - 0.75).abs() < 1e-9 && (s.f - 0.5).abs() < 1e-9 && (s.jf() - 0.625).abs() < 1e-9);
        assert!(
            MaskBenchScore::table(&[("clip", "baseline", &s)]).contains("| clip | baseline | 0.750 | 0.500 | 0.625 |")
        );
    }
}
