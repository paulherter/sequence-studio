// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FeatureTracker.swift
//! The camera motion between two frames from sparse tracked features: tiled Shi-Tomasi corners on the previous frame,
//! pyramidal Lucas-Kanade forward and back (a point whose round trip does not return is dropped), then a RANSAC homography
//! (similarity as the fallback) over the survivors. The inlier count and ratio are the confidence; a frame with too few
//! inliers is weak and reports `None`.

use crate::homography_fit::Homography;
use crate::registration_math::{Registration, SplitMix};
use crate::stabilization_check::GrayFrame;
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_masks::stabilizer_perspective::PerspectiveResidual;
use sq_core_time::Vec2;

type P2 = [f32; 2];

/// One tracked point set measured between two frames.
#[derive(Clone, Debug, PartialEq)]
pub struct FeatureMotion {
    /// previous -> current in px of the analysis frame (centered, y down, the `CameraMotion` convention).
    pub motion: CameraMotion,
    /// Points the model explains.
    pub inliers: usize,
    /// Points that survived the round trip.
    pub tracked: usize,
    /// What the similarity left of the pair's homography, in analysis px; `None` when fitted as a similarity.
    pub residual: Option<PerspectiveResidual>,
}

impl FeatureMotion {
    /// Inliers over tracked points.
    pub fn ratio(&self) -> f64 {
        if self.tracked > 0 { self.inliers as f64 / self.tracked as f64 } else { 0.0 }
    }

    /// 0...1: how far the estimate can be trusted (inlier ratio and count).
    pub fn confidence(&self) -> f64 {
        let by_ratio = ((self.ratio() - FeatureTracker::WEAK_RATIO) / 0.3).clamp(0.0, 1.0);
        let by_count = ((self.inliers as f64 - FeatureTracker::WEAK_INLIERS as f64) / 20.0).clamp(0.0, 1.0);
        by_ratio.min(by_count)
    }
}

/// Image pyramid of one frame (level 0 = the frame), cached between two pairs.
#[derive(Clone, Debug)]
pub struct FeaturePyramid {
    /// Finest first.
    pub levels: Vec<GrayFrame>,
}

impl FeaturePyramid {
    /// The frame and its halvings, up to `FeatureTracker::PYRAMID_LEVELS`.
    pub fn new(base: GrayFrame) -> FeaturePyramid {
        let mut levels = vec![base];
        while levels.len() < FeatureTracker::PYRAMID_LEVELS {
            let Some(next) = levels.last().and_then(GrayFrame::halved) else { break };
            levels.push(next);
        }
        FeaturePyramid { levels }
    }
}

/// The feature tracker (Swift enum `FeatureTracker`).
pub struct FeatureTracker;

impl FeatureTracker {
    /// The frame and three halvings.
    pub const PYRAMID_LEVELS: usize = 4;
    /// Fewest inliers of a usable pair.
    pub const WEAK_INLIERS: usize = 12;
    /// Smallest inlier ratio of a usable pair.
    pub const WEAK_RATIO: f64 = 0.3;
    /// px at the analysis size.
    pub const ROUND_TRIP_LIMIT: f64 = 0.5;
    const LK_ITERATIONS: usize = 30;
    const LK_EPSILON: f32 = 0.01;
    const MIN_EIGENVALUE: f32 = 1e-4;
    /// Fewest tracked points for which a homography is tried.
    pub const MIN_HOMOGRAPHY_POINTS: usize = 24;

    /// Shi-Tomasi corners of `f`, at most `per_tile` in each cell of an 8 x 6 grid, at least `min_distance` apart inside a
    /// tile. Quality: 1 % of the frame's best response.
    pub fn corners(f: &GrayFrame, per_tile: usize, min_distance: f64, margin: usize) -> Vec<P2> {
        let (tiles_x, tiles_y) = (8usize, 6usize);
        let (w, h) = (f.width, f.height);
        if w <= 2 * margin + 8 || h <= 2 * margin + 8 {
            return Vec::new();
        }
        let p = &f.pixels;
        let mut response = vec![0f32; w * h];
        let mut gxx = vec![0f32; w * h];
        let mut gxy = vec![0f32; w * h];
        let mut gyy = vec![0f32; w * h];
        for y in 1..h - 1 {
            for x in 1..w - 1 {
                let ix = (p[y * w + x + 1] - p[y * w + x - 1]) * 0.5;
                let iy = (p[(y + 1) * w + x] - p[(y - 1) * w + x]) * 0.5;
                gxx[y * w + x] = ix * ix;
                gxy[y * w + x] = ix * iy;
                gyy[y * w + x] = iy * iy;
            }
        }
        for y in 2..h - 2 {
            for x in 2..w - 2 {
                let (mut a, mut b, mut c) = (0f32, 0f32, 0f32);
                for dy in 0..3 {
                    let o = (y + dy - 1) * w + x;
                    a += gxx[o - 1] + gxx[o] + gxx[o + 1];
                    b += gxy[o - 1] + gxy[o] + gxy[o + 1];
                    c += gyy[o - 1] + gyy[o] + gyy[o + 1];
                }
                let half = (a + c) * 0.5;
                let d = ((a - c) * 0.5 * (a - c) * 0.5 + b * b).sqrt();
                response[y * w + x] = half - d;
            }
        }
        let best = response.iter().copied().fold(f32::MIN, f32::max);
        if best <= 1e-3 {
            return Vec::new();
        }
        let threshold = best * 0.01;
        let mut out = Vec::new();
        let (x0, x1, y0, y1) = (margin, w - margin, margin, h - margin);
        let tw = (x1 - x0) as f64 / tiles_x as f64;
        let th = (y1 - y0) as f64 / tiles_y as f64;
        let min_d2 = (min_distance * min_distance) as f32;
        for ty in 0..tiles_y {
            for tx in 0..tiles_x {
                let xa = x0 + (tx as f64 * tw) as usize;
                let xb = x0 + ((tx + 1) as f64 * tw) as usize;
                let ya = y0 + (ty as f64 * th) as usize;
                let yb = y0 + ((ty + 1) as f64 * th) as usize;
                let mut candidates: Vec<(f32, usize, usize)> = Vec::new();
                for y in ya..yb {
                    for x in xa..xb {
                        let r = response[y * w + x];
                        if r <= threshold {
                            continue;
                        }
                        let is_max = (0..9).filter(|k| *k != 4).all(|k| {
                            let (dx, dy) = (k % 3, k / 3);
                            response[(y + dy - 1) * w + x + dx - 1] <= r
                        });
                        if is_max {
                            candidates.push((r, x, y));
                        }
                    }
                }
                candidates.sort_by(|a, b| b.0.total_cmp(&a.0));
                let mut chosen: Vec<P2> = Vec::new();
                for c in candidates {
                    let q = [c.1 as f32, c.2 as f32];
                    if chosen.iter().all(|o| (o[0] - q[0]).powi(2) + (o[1] - q[1]).powi(2) >= min_d2) {
                        chosen.push(q);
                    }
                    if chosen.len() >= per_tile {
                        break;
                    }
                }
                out.extend(chosen);
            }
        }
        out
    }

    fn sample(p: &[f32], w: usize, x: f32, y: f32) -> f32 {
        let (xi, yi) = (x.floor() as usize, y.floor() as usize);
        let (fx, fy) = (x - xi as f32, y - yi as f32);
        let o = yi * w + xi;
        let a = p[o] + (p[o + 1] - p[o]) * fx;
        let b = p[o + w] + (p[o + w + 1] - p[o + w]) * fx;
        a + (b - a) * fy
    }

    /// Where the point `start` (level-0 px of `from`) is in `to`: pyramidal translation LK. `None` when it leaves the
    /// picture, has no texture in its window or does not converge.
    pub fn track(start: P2, from: &FeaturePyramid, to: &FeaturePyramid, hw: usize) -> Option<P2> {
        let mut flow: P2 = [0.0, 0.0];
        let top = from.levels.len().min(to.levels.len());
        for level in (0..top).rev() {
            let (a, b) = (&from.levels[level], &to.levels[level]);
            let scale = (1u32 << level) as f32;
            let p = [start[0] / scale, start[1] / scale];
            flow = [flow[0] * 2.0, flow[1] * 2.0];
            let (w, h) = (a.width, a.height);
            let (px, py) = (p[0] as i64, p[1] as i64);
            let hwi = hw as i64;
            if px - hwi - 2 < 0 || py - hwi - 2 < 0 || px + hwi + 3 >= w as i64 || py + hwi + 3 >= h as i64 {
                if level == 0 {
                    return None;
                }
                continue;
            }
            let (px, py) = (px as usize, py as usize);
            let n = (2 * hw + 1) * (2 * hw + 1);
            let (pa, pb) = (&a.pixels, &b.pixels);
            let (mut ix, mut iy, mut t) = (vec![0f32; n], vec![0f32; n], vec![0f32; n]);
            let (mut gxx, mut gxy, mut gyy) = (0f32, 0f32, 0f32);
            let mut k = 0;
            for j in 0..=2 * hw {
                for i in 0..=2 * hw {
                    let o = (py + j - hw) * w + px + i - hw;
                    let dx = (pa[o + 1] - pa[o - 1]) * 0.5;
                    let dy = (pa[o + w] - pa[o - w]) * 0.5;
                    ix[k] = dx;
                    iy[k] = dy;
                    t[k] = pa[o];
                    gxx += dx * dx;
                    gxy += dx * dy;
                    gyy += dy * dy;
                    k += 1;
                }
            }
            let det = gxx * gyy - gxy * gxy;
            let min_eig = ((gxx + gyy) - ((gxx - gyy) * (gxx - gyy) + 4.0 * gxy * gxy).sqrt()) * 0.5 / n as f32;
            if det <= 1e-6 || min_eig < Self::MIN_EIGENVALUE {
                return None;
            }
            let (ox, oy) = (px as f32, py as f32);
            for _ in 0..Self::LK_ITERATIONS {
                let (mut bx, mut by) = (0f32, 0f32);
                let mut k = 0;
                for j in 0..=2 * hw {
                    for i in 0..=2 * hw {
                        let sx = ox + i as f32 - hw as f32 + flow[0];
                        let sy = oy + j as f32 - hw as f32 + flow[1];
                        if !(sx >= 1.0 && sy >= 1.0 && sx < (w - 2) as f32 && sy < (h - 2) as f32) {
                            return None;
                        }
                        let e = t[k] - Self::sample(pb, w, sx, sy);
                        bx += ix[k] * e;
                        by += iy[k] * e;
                        k += 1;
                    }
                }
                let dx = (gyy * bx - gxy * by) / det;
                let dy = (gxx * by - gxy * bx) / det;
                flow = [flow[0] + dx, flow[1] + dy];
                if dx.abs() < Self::LK_EPSILON && dy.abs() < Self::LK_EPSILON {
                    break;
                }
                if flow[0].abs() > w as f32 / 2.0 || flow[1].abs() > h as f32 / 2.0 {
                    return None;
                }
            }
        }
        Some([start[0] + flow[0], start[1] + flow[1]])
    }

    /// RANSAC similarity through point pairs (`src` previous, `dst` current, centered); refit on the inliers.
    pub fn ransac_similarity(src: &[Vec2], dst: &[Vec2], threshold: f64) -> Option<(CameraMotion, usize)> {
        let (max_iterations, confidence) = (300usize, 0.995f64);
        let n = src.len().min(dst.len());
        if n < 2 {
            return None;
        }
        let inliers_of = |m: &CameraMotion| -> Vec<usize> {
            let pose = m.pose();
            (0..n)
                .filter(|&i| {
                    let d = pose.apply(src[i]) - dst[i];
                    d.x * d.x + d.y * d.y <= threshold * threshold
                })
                .collect()
        };
        let mut rng = SplitMix::new(0x5EED_5EED);
        let mut best: Vec<usize> = Vec::new();
        let (mut iterations, mut it) = (max_iterations, 0);
        while it < iterations {
            it += 1;
            let i = (rng.next_u64() % n as u64) as usize;
            let mut j = (rng.next_u64() % n as u64) as usize;
            if j == i {
                j = (j + 1) % n;
            }
            let Some(m) = Registration::fit_similarity(&[src[i], src[j]], &[dst[i], dst[j]]) else { continue };
            if !Registration::plausible_scale(&m) {
                continue;
            }
            let inl = inliers_of(&m);
            if inl.len() > best.len() {
                let w = inl.len() as f64 / n as f64;
                best = inl;
                if w >= 1.0 {
                    break;
                }
                let need = (1.0 - confidence).ln() / (1.0 - w * w).max(1e-12).ln();
                iterations = max_iterations.min((need.ceil() as usize).max(10));
            }
        }
        if best.len() < 2 {
            return None;
        }
        let mut set = best;
        let mut model = None;
        for _ in 0..2 {
            let s: Vec<Vec2> = set.iter().map(|&i| src[i]).collect();
            let d: Vec<Vec2> = set.iter().map(|&i| dst[i]).collect();
            let Some(m) = Registration::fit_similarity(&s, &d) else { break };
            let next = inliers_of(&m);
            model = Some(m);
            if next.len() < 2 {
                break;
            }
            set = next;
        }
        model.map(|m| (m, set.len()))
    }

    /// The camera motion through point pairs: a RANSAC homography reduced to the similarity that explains it over the
    /// picture, when it explains clearly more points than a similarity does; the similarity otherwise.
    pub fn fit_motion(
        src: &[Vec2],
        dst: &[Vec2],
        threshold: f64,
        half_width: f64,
        half_height: f64,
    ) -> Option<(CameraMotion, usize, Option<PerspectiveResidual>)> {
        let sim = Self::ransac_similarity(src, dst, threshold);
        if src.len() >= Self::MIN_HOMOGRAPHY_POINTS
            && let Some(hom) = Homography::ransac(src, dst, threshold, half_width, half_height, 400, 0.995)
            && let Some(m) = hom.map.similarity(half_width, half_height, 5)
            && Registration::plausible_scale(&m)
            && hom.inliers.len() > sim.as_ref().map_or(0, |s| s.1) + 2.max(src.len() / 50)
        {
            return Some((m, hom.inliers.len(), hom.map.residual(&m)));
        }
        sim.map(|(m, n)| (m, n, None))
    }

    /// Motion of `current` against `previous`; `None` when the frames have too little in common (weak frame).
    pub fn register(previous: &FeaturePyramid, current: &FeaturePyramid) -> Option<FeatureMotion> {
        let f = previous.levels.first()?;
        let (w, h) = (f.width, f.height);
        let max_dim = w.max(h);
        let per_tile = ((10.0 * w as f64 / 1920.0).round() as usize).clamp(4, 20);
        let search = 3.max(max_dim / 192);
        let hw = search + 3;
        let big = max_dim > 1000;
        let pts = Self::corners(f, per_tile, 4.0_f64.max(30.0 * w as f64 / 1920.0), hw + 2);
        let (cx, cy) = (w as f64 / 2.0, h as f64 / 2.0);
        let (mut src, mut dst) = (Vec::new(), Vec::new());
        for p in pts {
            let Some(q) = Self::track(p, previous, current, hw) else { continue };
            let Some(back) = Self::track(q, current, previous, hw) else { continue };
            let d = [back[0] - p[0], back[1] - p[1]];
            if f64::from((d[0] * d[0] + d[1] * d[1]).sqrt()) > Self::ROUND_TRIP_LIMIT {
                continue;
            }
            src.push(Vec2::new(f64::from(p[0]) - cx, f64::from(p[1]) - cy));
            dst.push(Vec2::new(f64::from(q[0]) - cx, f64::from(q[1]) - cy));
        }
        let tracked = src.len();
        if tracked < Self::WEAK_INLIERS {
            return None;
        }
        let (motion, inliers, residual) = Self::fit_motion(&src, &dst, if big { 0.5 } else { 1.0 }, cx, cy)?;
        let result = FeatureMotion { motion, inliers, tracked, residual };
        (result.inliers >= Self::WEAK_INLIERS && result.ratio() >= Self::WEAK_RATIO).then_some(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scene(x: f64, y: f64) -> f64 {
        128.0
            + 34.0 * (x / 5.3 + y / 9.1).sin()
            + 28.0 * (x / 11.7 - y / 6.3).cos()
            + 22.0 * (x / 3.1).sin() * (y / 4.3).cos()
            + 18.0 * ((x + 2.0 * y) / 17.9).sin()
            + 14.0 * ((3.0 * x - y) / 23.3).cos()
    }

    /// The scene seen by a camera that moved the content by (dx, dy) px, turned it `deg` degrees and zoomed it by `zoom`
    /// (content motion, centered, y down).
    fn shot(dx: f64, dy: f64, deg: f64, zoom: f64) -> FeaturePyramid {
        let (w, h) = (320usize, 192usize);
        let r = deg.to_radians();
        let (c, s) = (r.cos() * zoom, r.sin() * zoom);
        let (cx, cy) = (w as f64 / 2.0, h as f64 / 2.0);
        let px = (0..w * h)
            .map(|i| {
                let (x, y) = ((i % w) as f64 - cx - dx, (i / w) as f64 - cy - dy);
                // inverse of the content motion: p -> R(zoom, deg) p
                let det = c * c + s * s;
                scene((c * x + s * y) / det, (-s * x + c * y) / det) as f32
            })
            .collect();
        FeaturePyramid::new(GrayFrame::new(w, h, px))
    }

    #[test]
    fn a_shifted_turned_zoomed_scene_gives_its_motion() {
        let m = FeatureTracker::register(&shot(0.0, 0.0, 0.0, 1.0), &shot(4.5, -3.0, 1.5, 1.02)).expect("register");
        assert!((m.motion.dx - 4.5).abs() < 0.3 && (m.motion.dy + 3.0).abs() < 0.3, "{:?}", m.motion);
        assert!((m.motion.rotation - 1.5).abs() < 0.3 && (m.motion.scale - 1.02).abs() < 0.01, "{:?}", m.motion);
        assert!(m.confidence() > 0.9 && m.ratio() > 0.9, "{m:?}");
    }

    #[test]
    fn a_blank_frame_is_weak() {
        let blank = FeaturePyramid::new(GrayFrame::new(320, 192, vec![100.0; 320 * 192]));
        assert!(FeatureTracker::register(&blank, &blank).is_none());
    }

    #[test]
    fn the_similarity_fit_survives_outliers() {
        let src: Vec<Vec2> =
            (0..40).map(|i| Vec2::new(f64::from(i % 8) * 20.0 - 70.0, f64::from(i / 8) * 18.0 - 40.0)).collect();
        let mut dst: Vec<Vec2> = src.iter().map(|p| Vec2::new(p.x + 3.0, p.y - 2.0)).collect();
        for d in dst.iter_mut().take(8) {
            *d = Vec2::new(d.x + 30.0, d.y + 25.0);
        }
        let (m, n) = FeatureTracker::ransac_similarity(&src, &dst, 1.0).expect("fit");
        assert!((m.dx - 3.0).abs() < 0.05 && (m.dy + 2.0).abs() < 0.05 && n == 32, "{m:?} {n}");
    }
}
