// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MaskMotion.swift
//! Mask tracking beyond translation and scale. The tracker reports one motion per frame: a 3 x 3 projective map from the
//! frame the track started on. Position and +Scale come from the object tracker's box; +Rotation and Perspective are
//! fitted here from point correspondences (optical flow samples inside the mask), robustly, so background flow leaking
//! into the region does not drag the mask.

use crate::mask_path_editing::MaskTrackBox;
use sq_core_model::{MaskPath, MaskVertex};
use sq_core_time::Vec2;

/// What a mask track follows (chosen in Effect Controls, not stored in the project).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MaskTrackMode {
    /// Position only.
    Position,
    /// Position and per-axis scale from the object tracker.
    Scale,
    /// Plus rotation.
    Rotation,
    /// A full projective fit.
    Perspective,
}

impl MaskTrackMode {
    /// The behavior before this choice existed: position + per-axis scale from the object tracker.
    pub const DEFAULT: MaskTrackMode = MaskTrackMode::Scale;

    /// Every mode in menu order.
    pub const ALL: [MaskTrackMode; 4] =
        [MaskTrackMode::Position, MaskTrackMode::Scale, MaskTrackMode::Rotation, MaskTrackMode::Perspective];

    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            MaskTrackMode::Position => "Position",
            MaskTrackMode::Scale => "+ Scale",
            MaskTrackMode::Rotation => "+ Rotation",
            MaskTrackMode::Perspective => "Perspective",
        }
    }

    /// Point tracking (optical flow + fit) instead of the object tracker's box.
    pub fn uses_points(self) -> bool {
        self == MaskTrackMode::Rotation || self == MaskTrackMode::Perspective
    }

    /// Fewest correspondences a fit of this kind needs.
    fn min_points(self) -> usize {
        match self {
            MaskTrackMode::Position => 1,
            MaskTrackMode::Scale | MaskTrackMode::Rotation => 2,
            MaskTrackMode::Perspective => 4,
        }
    }
}

/// A 3 x 3 projective map (row major), p' = M p in homogeneous coordinates. Frame fractions or pixels, as named.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskMotion {
    /// The nine entries, row major.
    pub m: [f64; 9],
}

impl MaskMotion {
    /// No motion.
    pub const IDENTITY: MaskMotion = MaskMotion { m: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0] };

    /// A move by `t`.
    pub fn translation(t: Vec2) -> MaskMotion {
        MaskMotion { m: [1.0, 0.0, t.x, 0.0, 1.0, t.y, 0.0, 0.0, 1.0] }
    }

    /// Turn by `angle` radians about `c` (y down: positive turns +x towards +y, clockwise on screen).
    pub fn rotation(angle: f64, c: Vec2) -> MaskMotion {
        let (co, si) = (angle.cos(), angle.sin());
        MaskMotion { m: [co, -si, c.x - co * c.x + si * c.y, si, co, c.y - si * c.x - co * c.y, 0.0, 0.0, 1.0] }
    }

    /// Box `a` becoming box `b`: moved, and with `scale` sized per axis about its center (the object tracker's motion).
    pub fn from_boxes(a: &MaskTrackBox, b: &MaskTrackBox, scale: bool) -> MaskMotion {
        let sx = if scale && a.size.x > 1e-9 { b.size.x / a.size.x } else { 1.0 };
        let sy = if scale && a.size.y > 1e-9 { b.size.y / a.size.y } else { 1.0 };
        MaskMotion { m: [sx, 0.0, b.center.x - sx * a.center.x, 0.0, sy, b.center.y - sy * a.center.y, 0.0, 0.0, 1.0] }
    }

    /// The point `p` carried by the motion.
    pub fn apply(&self, p: Vec2) -> Vec2 {
        let m = &self.m;
        let w = m[6] * p.x + m[7] * p.y + m[8];
        let iw = if w.abs() > 1e-12 { 1.0 / w } else { 0.0 };
        Vec2::new((m[0] * p.x + m[1] * p.y + m[2]) * iw, (m[3] * p.x + m[4] * p.y + m[5]) * iw)
    }

    /// This motion first, then `next`.
    pub fn then(&self, next: &MaskMotion) -> MaskMotion {
        MaskMotion { m: Self::mul(&next.m, &self.m) }
    }

    /// The motion undone; `None` when singular.
    pub fn inverse(&self) -> Option<MaskMotion> {
        let a = &self.m;
        let c0 = a[4] * a[8] - a[5] * a[7];
        let c1 = a[5] * a[6] - a[3] * a[8];
        let c2 = a[3] * a[7] - a[4] * a[6];
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2;
        if det.abs() <= 1e-15 {
            return None;
        }
        let d = 1.0 / det;
        Some(MaskMotion {
            m: [
                c0 * d,
                (a[2] * a[7] - a[1] * a[8]) * d,
                (a[1] * a[5] - a[2] * a[4]) * d,
                c1 * d,
                (a[0] * a[8] - a[2] * a[6]) * d,
                (a[2] * a[3] - a[0] * a[5]) * d,
                c2 * d,
                (a[1] * a[6] - a[0] * a[7]) * d,
                (a[0] * a[4] - a[1] * a[3]) * d,
            ],
        })
    }

    /// A pixel-space motion on a `width` x `height` frame as a motion on frame fractions.
    pub fn in_fractions(&self, width: f64, height: f64) -> MaskMotion {
        MaskMotion {
            m: Self::mul(
                &Self::mul(&[1.0 / width, 0.0, 0.0, 0.0, 1.0 / height, 0.0, 0.0, 0.0, 1.0], &self.m),
                &[width, 0.0, 0.0, 0.0, height, 0.0, 0.0, 0.0, 1.0],
            ),
        }
    }

    /// A frame-fraction motion as a motion on pixels of a `width` x `height` frame.
    pub fn in_pixels(&self, width: f64, height: f64) -> MaskMotion {
        MaskMotion {
            m: Self::mul(
                &Self::mul(&[width, 0.0, 0.0, 0.0, height, 0.0, 0.0, 0.0, 1.0], &self.m),
                &[1.0 / width, 0.0, 0.0, 0.0, 1.0 / height, 0.0, 0.0, 0.0, 1.0],
            ),
        }
    }

    fn mul(a: &[f64; 9], b: &[f64; 9]) -> [f64; 9] {
        let mut out = [0.0; 9];
        for r in 0..3 {
            for c in 0..3 {
                let x: f64 = a[r * 3] * b[c];
                let y: f64 = a[r * 3 + 1] * b[3 + c];
                let z: f64 = a[r * 3 + 2] * b[6 + c];
                out[r * 3 + c] = x + y + z;
            }
        }
        out
    }
}

/// Logic Swift keeps on `MaskPath` in `MaskMotion.swift`.
pub trait MaskPathMotionExt {
    /// The path carried by `motion`: points mapped, tangents follow their handle ends (exact for affine motions).
    fn transformed(&self, motion: &MaskMotion) -> MaskPath;
}

impl MaskPathMotionExt for MaskPath {
    fn transformed(&self, motion: &MaskMotion) -> MaskPath {
        MaskPath {
            vertices: self
                .vertices
                .iter()
                .map(|v| {
                    let p = motion.apply(v.point);
                    MaskVertex {
                        point: p,
                        in_tangent: motion.apply(v.point + v.in_tangent) - p,
                        out_tangent: motion.apply(v.point + v.out_tangent) - p,
                    }
                })
                .collect(),
        }
    }
}

/// A fitted motion and how well it fits.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskFit {
    /// The motion.
    pub motion: MaskMotion,
    /// Root mean square residual of the kept points (px).
    pub rms: f64,
    /// Points kept after outlier rejection.
    pub inliers: usize,
}

/// Robust motion fits from point correspondences (pixel space, so a rotation stays a rotation on non-square frames).
pub struct MaskMotionFit;

fn sum_vec(items: &[Vec2]) -> Vec2 {
    items.iter().fold(Vec2::ZERO, |a, b| a + *b)
}

impl MaskMotionFit {
    /// Residuals below this always count as inliers (px): flow noise on real footage.
    const MIN_THRESHOLD: f64 = 0.75;
    const ROUNDS: usize = 4;

    /// Fits the motion of `mode` taking `from[i]` to `to[i]`, rejecting outliers (residual over 3 x median) in a few
    /// rounds. `None`: too few or degenerate points.
    pub fn fit(from: &[Vec2], to: &[Vec2], mode: MaskTrackMode) -> Option<MaskFit> {
        if from.len() != to.len() || from.len() < mode.min_points() {
            return None;
        }
        let mut keep: Vec<usize> = (0..from.len()).collect();
        // Perspective picks its inliers with a similarity first: a free homography bends towards outliers.
        if mode == MaskTrackMode::Perspective
            && let Some(sim) = Self::fit(from, to, MaskTrackMode::Rotation)
        {
            let limit = Self::threshold(&sim, from, to);
            keep = (0..from.len()).filter(|&i| (sim.motion.apply(from[i]) - to[i]).length() <= limit).collect();
        }
        let mut best: Option<MaskFit> = None;
        for _ in 0..Self::ROUNDS {
            if keep.len() < mode.min_points() {
                return best;
            }
            let a: Vec<Vec2> = keep.iter().map(|&i| from[i]).collect();
            let b: Vec<Vec2> = keep.iter().map(|&i| to[i]).collect();
            let Some(motion) = Self::solve(&a, &b, mode) else { return best };
            let res: Vec<f64> = (0..from.len()).map(|i| (motion.apply(from[i]) - to[i]).length()).collect();
            let kept: Vec<f64> = keep.iter().map(|&i| res[i]).collect();
            let rms = (kept.iter().fold(0.0, |a, r| a + r * r) / kept.len() as f64).sqrt();
            best = Some(MaskFit { motion, rms, inliers: keep.len() });
            let limit = (3.0 * Self::median(&kept)).max(Self::MIN_THRESHOLD);
            let next: Vec<usize> = (0..from.len()).filter(|&i| res[i] <= limit).collect();
            if next == keep {
                break;
            }
            keep = next;
        }
        best
    }

    fn threshold(r: &MaskFit, from: &[Vec2], to: &[Vec2]) -> f64 {
        let res: Vec<f64> = (0..from.len()).map(|i| (r.motion.apply(from[i]) - to[i]).length()).collect();
        (3.0 * Self::median(&res)).max(Self::MIN_THRESHOLD)
    }

    fn median(v: &[f64]) -> f64 {
        if v.is_empty() {
            return 0.0;
        }
        let mut s = v.to_vec();
        s.sort_by(f64::total_cmp);
        if s.len() % 2 == 1 { s[s.len() / 2] } else { (s[s.len() / 2 - 1] + s[s.len() / 2]) / 2.0 }
    }

    /// Least-squares fit of one kind (no outlier handling).
    fn solve(a: &[Vec2], b: &[Vec2], mode: MaskTrackMode) -> Option<MaskMotion> {
        let n = a.len() as f64;
        let ca = sum_vec(a) * (1.0 / n);
        let cb = sum_vec(b) * (1.0 / n);
        match mode {
            MaskTrackMode::Position => Some(MaskMotion::translation(cb - ca)),
            MaskTrackMode::Scale | MaskTrackMode::Rotation => {
                let (mut ss, mut dot, mut cross) = (0.0_f64, 0.0_f64, 0.0_f64);
                for (p, q) in a.iter().zip(b) {
                    let s = *p - ca;
                    let d = *q - cb;
                    ss += s.x * s.x + s.y * s.y;
                    dot += s.x * d.x + s.y * d.y;
                    cross += s.x * d.y - s.y * d.x;
                }
                if ss <= 1e-9 {
                    return None;
                }
                let k = dot / ss;
                let r = if mode == MaskTrackMode::Rotation { cross / ss } else { 0.0 };
                // q = cb + [k -r; r k](p - ca)
                Some(MaskMotion {
                    m: [k, -r, cb.x - k * ca.x + r * ca.y, r, k, cb.y - r * ca.x - k * ca.y, 0.0, 0.0, 1.0],
                })
            }
            MaskTrackMode::Perspective => Self::homography(a, b),
        }
    }

    /// Normalized DLT with h33 = 1 (Hartley): least squares over all points.
    fn homography(a: &[Vec2], b: &[Vec2]) -> Option<MaskMotion> {
        let ta = Self::normalizer(a)?;
        let tb = Self::normalizer(b)?;
        let tb_inv = tb.inverse()?;
        let na: Vec<Vec2> = a.iter().map(|p| ta.apply(*p)).collect();
        let nb: Vec<Vec2> = b.iter().map(|p| tb.apply(*p)).collect();
        let mut ata = vec![0.0_f64; 64];
        let mut atb = vec![0.0_f64; 8];
        let mut add = |row: [f64; 8], rhs: f64| {
            for i in 0..8 {
                atb[i] += row[i] * rhs;
                for j in 0..8 {
                    ata[i * 8 + j] += row[i] * row[j];
                }
            }
        };
        for (p, q) in na.iter().zip(&nb) {
            add([p.x, p.y, 1.0, 0.0, 0.0, 0.0, -p.x * q.x, -p.y * q.x], q.x);
            add([0.0, 0.0, 0.0, p.x, p.y, 1.0, -p.x * q.y, -p.y * q.y], q.y);
        }
        let h = Self::solve_linear(&ata, &atb, 8)?;
        let mut m = [1.0; 9];
        m[..8].copy_from_slice(&h);
        Some(ta.then(&MaskMotion { m }).then(&tb_inv))
    }

    /// Moves the centroid to the origin and scales the mean distance to sqrt 2.
    fn normalizer(p: &[Vec2]) -> Option<MaskMotion> {
        let n = p.len() as f64;
        let c = sum_vec(p) * (1.0 / n);
        let mean = p.iter().fold(0.0, |a, q| a + (*q - c).length()) / n;
        if mean <= 1e-9 {
            return None;
        }
        let s = 2.0_f64.sqrt() / mean;
        Some(MaskMotion { m: [s, 0.0, -s * c.x, 0.0, s, -s * c.y, 0.0, 0.0, 1.0] })
    }

    /// Gaussian elimination with partial pivoting; `None` when singular.
    fn solve_linear(a: &[f64], b: &[f64], n: usize) -> Option<Vec<f64>> {
        let (mut a, mut b) = (a.to_vec(), b.to_vec());
        for col in 0..n {
            let mut piv = col;
            for r in col + 1..n {
                if a[r * n + col].abs() > a[piv * n + col].abs() {
                    piv = r;
                }
            }
            if a[piv * n + col].abs() <= 1e-12 {
                return None;
            }
            if piv != col {
                for k in 0..n {
                    a.swap(col * n + k, piv * n + k);
                }
                b.swap(col, piv);
            }
            for r in col + 1..n {
                let f = a[r * n + col] / a[col * n + col];
                if f == 0.0 {
                    continue;
                }
                for k in col..n {
                    a[r * n + k] -= f * a[col * n + k];
                }
                b[r] -= f * b[col];
            }
        }
        let mut x = vec![0.0_f64; n];
        for r in (0..n).rev() {
            let mut s = b[r];
            for k in r + 1..n {
                s -= a[r * n + k] * x[k];
            }
            x[r] = s / a[r * n + r];
        }
        Some(x)
    }

    /// Grid points (cell centers, `spacing` apart) inside `polygon` (even-odd); at most `limit`, thinned evenly.
    pub fn sample_points(polygon: &[Vec2], spacing: f64, limit: usize) -> Vec<Vec2> {
        if polygon.len() < 3 || spacing <= 0.0 {
            return Vec::new();
        }
        let bx = MaskTrackBox::bounding(polygon);
        let lo = bx.center - bx.size * 0.5;
        let nx = (bx.size.x / spacing).floor() as i64;
        let ny = (bx.size.y / spacing).floor() as i64;
        let mut out = Vec::new();
        for j in 0..ny.max(0) {
            for i in 0..nx.max(0) {
                let p = Vec2::new(lo.x + (i as f64 + 0.5) * spacing, lo.y + (j as f64 + 0.5) * spacing);
                if Self::contains(polygon, p) {
                    out.push(p);
                }
            }
        }
        if out.len() <= limit || limit == 0 {
            return out;
        }
        let step = out.len() as f64 / limit as f64;
        (0..limit).map(|i| out[(i as f64 * step) as usize]).collect()
    }

    /// Even-odd point in polygon.
    fn contains(poly: &[Vec2], p: Vec2) -> bool {
        let mut inside = false;
        let mut j = poly.len() - 1;
        for i in 0..poly.len() {
            let (a, b) = (poly[i], poly[j]);
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside = !inside;
            }
            j = i;
        }
        inside
    }
}
