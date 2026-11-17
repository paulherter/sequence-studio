// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: HomographyFit.swift
//! Planar homography from point pairs (stabilizer analysis, REA-resolve-stabilizer.md section 7 item 3: the default warp is
//! one homography). Own code: direct linear solve with h33 = 1 on Hartley-normalized points, RANSAC over 4-point samples,
//! least-squares refit on the inliers. The stabilizer corrects a similarity, so the homography is reduced to the similarity
//! that best explains it over the picture (`similarity`); perspective the camera really had then no longer bends the
//! estimate of turn and zoom the way a straight similarity fit through moving points does.
use crate::registration_math::{Registration, SplitMix};
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_masks::stabilizer_perspective::PerspectiveResidual;
use sq_core_time::Vec2;

/// 3x3 projective map, row-major, h[8] = 1. Points are centered pixel coordinates (the `CameraMotion` convention).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Homography {
    /// The nine numbers.
    pub h: [f64; 9],
}

/// A homography found by RANSAC and the indices of the pairs it explains.
#[derive(Clone, Debug, PartialEq)]
pub struct RansacFit {
    /// The map.
    pub map: Homography,
    /// Indices of the inlier pairs.
    pub inliers: Vec<usize>,
}

impl Homography {
    /// No change.
    pub const IDENTITY: Homography = Homography { h: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0] };

    /// `p` through the map; `None` when it goes to infinity.
    pub fn apply(&self, p: Vec2) -> Option<Vec2> {
        let h = &self.h;
        let w = h[6] * p.x + h[7] * p.y + h[8];
        if w.abs() <= 1e-9 {
            return None;
        }
        let r = Vec2::new((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w);
        (r.x.is_finite() && r.y.is_finite()).then_some(r)
    }

    /// Least-squares fit through 4 or more pairs (normal equations of the 8 unknowns, Hartley-normalized); `None` when the
    /// points are degenerate (collinear, repeated).
    pub fn fit(src: &[Vec2], dst: &[Vec2]) -> Option<Homography> {
        let n = src.len().min(dst.len());
        if n < 4 {
            return None;
        }
        let (ts, ss) = normalization(&src[..n]);
        let (td, sd) = normalization(&dst[..n]);
        if ss <= 0.0 || sd <= 0.0 {
            return None;
        }
        let mut ata = [0.0_f64; 64];
        let mut atb = [0.0_f64; 8];
        let mut add_row = |r: [f64; 8], b: f64| {
            for i in 0..8 {
                atb[i] += r[i] * b;
                for j in 0..8 {
                    ata[i * 8 + j] += r[i] * r[j];
                }
            }
        };
        for i in 0..n {
            let x = (src[i].x - ts.x) * ss;
            let y = (src[i].y - ts.y) * ss;
            let u = (dst[i].x - td.x) * sd;
            let v = (dst[i].y - td.y) * sd;
            add_row([x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y], u);
            add_row([0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y], v);
        }
        let s = solve(&ata, &atb, 8)?;
        // Normalized H' maps ((p - ts) ss) to ((q - td) sd); undo: H = T_d^-1 H' T_s.
        let hn = [s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], 1.0];
        let t_s = [ss, 0.0, -ts.x * ss, 0.0, ss, -ts.y * ss, 0.0, 0.0, 1.0];
        let t_d_inv = [1.0 / sd, 0.0, td.x, 0.0, 1.0 / sd, td.y, 0.0, 0.0, 1.0];
        let mut out = mul(&t_d_inv, &mul(&hn, &t_s));
        if out[8].abs() <= 1e-12 {
            return None;
        }
        let k = 1.0 / out[8];
        for v in &mut out {
            *v *= k;
        }
        out.iter().all(|v| v.is_finite()).then_some(Homography { h: out })
    }

    /// The similarity that best explains the map over a grid of points inside `half_width` x `half_height` (the picture is
    /// centered on the origin; Swift default grid 5). `None` when the map degenerates there.
    pub fn similarity(&self, half_width: f64, half_height: f64, grid: usize) -> Option<CameraMotion> {
        let mut a: Vec<Vec2> = Vec::new();
        let mut b: Vec<Vec2> = Vec::new();
        for i in 0..grid {
            for j in 0..grid {
                let p = Vec2::new(
                    (i as f64 / (grid - 1) as f64 * 2.0 - 1.0) * half_width,
                    (j as f64 / (grid - 1) as f64 * 2.0 - 1.0) * half_height,
                );
                let q = self.apply(p)?;
                a.push(p);
                b.push(q);
            }
        }
        Registration::fit_similarity(&a, &b)
    }

    /// What the camera similarity `s` (previous -> current) cannot express of this map: R = S^-1 H, normalized to h33 = 1 (the
    /// residual perspective the Stabilizer keeps, `PerspectiveResidual`). Identity when the map is a similarity.
    pub fn residual(&self, s: &CameraMotion) -> Option<PerspectiveResidual> {
        let r = s.rotation * std::f64::consts::PI / 180.0;
        let a = s.scale * r.cos();
        let b = s.scale * r.sin();
        let k = a * a + b * b;
        if k <= 1e-12 {
            return None;
        }
        // S^-1 = [a b -(a tx + b ty); -b a (b tx - a ty); 0 0 k] / k
        let inv = [a, b, -(a * s.dx + b * s.dy), -b, a, b * s.dx - a * s.dy, 0.0, 0.0, k];
        let mut m = [0.0_f64; 9];
        for i in 0..3 {
            for j in 0..3 {
                for t in 0..3 {
                    m[i * 3 + j] += inv[i * 3 + t] * self.h[t * 3 + j];
                }
            }
        }
        PerspectiveResidual::from_matrix(&m)
    }

    /// RANSAC over 4-point samples (Swift defaults: 400 iterations, confidence 0.995); refit on the inliers (twice).
    /// `threshold`: px of transfer error. `None` when fewer than 4 points or no model with a plausible reduction
    /// `max_perspective` (|h6|, |h7| times the long half side).
    pub fn ransac(
        src: &[Vec2],
        dst: &[Vec2],
        threshold: f64,
        half_width: f64,
        half_height: f64,
        max_iterations: usize,
        confidence: f64,
    ) -> Option<RansacFit> {
        let n = src.len().min(dst.len());
        if n < 4 {
            return None;
        }
        let reach = half_width.max(half_height);
        let plausible = |m: &Homography| -> bool {
            if !(m.h[6].abs() * reach < 0.35 && m.h[7].abs() * reach < 0.35) {
                return false;
            }
            m.similarity(half_width, half_height, 3).is_some_and(|s| Registration::plausible_scale(&s))
        };
        let inliers_of = |m: &Homography| -> Vec<usize> {
            (0..n)
                .filter(|&i| {
                    let Some(q) = m.apply(src[i]) else { return false };
                    let d = q - dst[i];
                    d.x * d.x + d.y * d.y <= threshold * threshold
                })
                .collect()
        };
        let mut rng = SplitMix::new(0x4851_4D47);
        let mut best: Vec<usize> = Vec::new();
        let mut iterations = max_iterations;
        let mut it = 0;
        while it < iterations {
            it += 1;
            let mut pick: Vec<usize> = Vec::new();
            while pick.len() < 4 {
                let k = (rng.next_u64() % n as u64) as usize;
                if !pick.contains(&k) {
                    pick.push(k);
                }
            }
            let ps: Vec<Vec2> = pick.iter().map(|&i| src[i]).collect();
            let pd: Vec<Vec2> = pick.iter().map(|&i| dst[i]).collect();
            let Some(m) = Self::fit(&ps, &pd) else { continue };
            if !plausible(&m) {
                continue;
            }
            let inl = inliers_of(&m);
            if inl.len() > best.len() {
                best = inl;
                let w = best.len() as f64 / n as f64;
                if w >= 1.0 {
                    break;
                }
                let need = (1.0 - confidence).ln() / (1.0 - w.powi(4)).max(1e-12).ln();
                iterations = max_iterations.min((need.ceil().max(0.0) as usize).max(20));
            }
        }
        if best.len() < 4 {
            return None;
        }
        let mut set = best;
        let mut model: Option<Homography> = None;
        for _ in 0..2 {
            let ps: Vec<Vec2> = set.iter().map(|&i| src[i]).collect();
            let pd: Vec<Vec2> = set.iter().map(|&i| dst[i]).collect();
            let Some(m) = Self::fit(&ps, &pd) else { break };
            if !plausible(&m) {
                break;
            }
            let next = inliers_of(&m);
            if next.len() < 4 {
                break;
            }
            model = Some(m);
            set = next;
        }
        model.map(|map| RansacFit { map, inliers: set })
    }
}

// MARK: Linear algebra helpers

fn normalization(pts: &[Vec2]) -> (Vec2, f64) {
    let n = pts.len() as f64;
    let c = Vec2::new(pts.iter().fold(0.0, |a, p| a + p.x) / n, pts.iter().fold(0.0, |a, p| a + p.y) / n);
    let d = pts.iter().fold(0.0, |a, p| a + ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).sqrt()) / n;
    (c, if d > 1e-9 { 2.0_f64.sqrt() / d } else { 0.0 })
}

fn mul(a: &[f64; 9], b: &[f64; 9]) -> [f64; 9] {
    let mut o = [0.0_f64; 9];
    for i in 0..3 {
        for j in 0..3 {
            for k in 0..3 {
                o[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j];
            }
        }
    }
    o
}

/// Gaussian elimination with partial pivoting; `None` when singular.
fn solve(a: &[f64], b: &[f64], n: usize) -> Option<Vec<f64>> {
    let mut m = a.to_vec();
    let mut r = b.to_vec();
    for c in 0..n {
        let mut p = c;
        for i in c..n {
            if m[i * n + c].abs() > m[p * n + c].abs() {
                p = i;
            }
        }
        if m[p * n + c].abs() <= 1e-10 {
            return None;
        }
        if p != c {
            for j in 0..n {
                m.swap(c * n + j, p * n + j);
            }
            r.swap(c, p);
        }
        for i in c + 1..n {
            let f = m[i * n + c] / m[c * n + c];
            if f == 0.0 {
                continue;
            }
            for j in c..n {
                m[i * n + j] -= f * m[c * n + j];
            }
            r[i] -= f * r[c];
        }
    }
    let mut x = vec![0.0_f64; n];
    for i in (0..n).rev() {
        let mut s = r[i];
        for j in i + 1..n {
            s -= m[i * n + j] * x[j];
        }
        x[i] = s / m[i * n + i];
    }
    x.iter().all(|v| v.is_finite()).then_some(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid_points() -> Vec<Vec2> {
        (0..5)
            .flat_map(|i| (0..4).map(move |j| Vec2::new(f64::from(i) * 40.0 - 80.0, f64::from(j) * 30.0 - 45.0)))
            .collect()
    }

    /// A similarity (rotation 4 degrees, scale 1.03, shift (6, -4)) as a homography.
    fn motion_map() -> Homography {
        let r = 4.0_f64.to_radians();
        let (a, b) = (1.03 * r.cos(), 1.03 * r.sin());
        Homography { h: [a, -b, 6.0, b, a, -4.0, 0.0, 0.0, 1.0] }
    }

    #[test]
    fn a_known_map_is_recovered_from_pairs() {
        let src = grid_points();
        let dst: Vec<Vec2> = src.iter().filter_map(|p| motion_map().apply(*p)).collect();
        let m = Homography::fit(&src, &dst).expect("fit");
        for (p, q) in src.iter().zip(&dst) {
            let got = m.apply(*p).expect("apply");
            assert!((got.x - q.x).abs() < 1e-6 && (got.y - q.y).abs() < 1e-6);
        }
        let s = m.similarity(100.0, 60.0, 5).expect("similarity");
        assert!((s.rotation - 4.0).abs() < 1e-6 && (s.scale - 1.03).abs() < 1e-9);
        assert!((s.dx - 6.0).abs() < 1e-6 && (s.dy - -4.0).abs() < 1e-6);
    }

    #[test]
    fn degenerate_points_give_no_map() {
        let line: Vec<Vec2> = (0..6).map(|i| Vec2::new(f64::from(i), f64::from(i))).collect();
        assert!(Homography::fit(&line, &line).is_none());
        assert!(Homography::fit(&line[..3], &line[..3]).is_none());
    }

    #[test]
    fn the_residual_of_a_similarity_is_the_identity() {
        let s = Registration::fit_similarity(
            &grid_points(),
            &grid_points().iter().filter_map(|p| motion_map().apply(*p)).collect::<Vec<_>>(),
        )
        .expect("similarity");
        let r = motion_map().residual(&s).expect("residual");
        assert!(r.magnitude() < 1e-9);
    }

    #[test]
    fn ransac_ignores_outliers() {
        let src = grid_points();
        let mut dst: Vec<Vec2> = src.iter().filter_map(|p| motion_map().apply(*p)).collect();
        for i in [3, 11, 17] {
            dst[i] = dst[i] + Vec2::new(30.0, -25.0);
        }
        let fit = Homography::ransac(&src, &dst, 1.0, 100.0, 60.0, 400, 0.995).expect("ransac");
        assert_eq!(fit.inliers.len(), src.len() - 3);
        assert!(![3, 11, 17].iter().any(|i| fit.inliers.contains(i)));
        let s = fit.map.similarity(100.0, 60.0, 5).expect("similarity");
        assert!((s.rotation - 4.0).abs() < 0.01 && (s.scale - 1.03).abs() < 1e-3);
        assert!(Homography::ransac(&src[..3], &dst[..3], 1.0, 100.0, 60.0, 400, 0.995).is_none());
    }
}
