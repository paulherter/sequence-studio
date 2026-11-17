// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizerL1.swift
//! Stabilizer v2: crop-constrained optimal path (principle of Grundmann et al., "Auto-Directed Video Stabilization with
//! Robust L1 Optimal Camera Paths", 2011, which also bounds the path by a crop window; own code). The wanted path of one
//! channel is the least-curvature path inside a tube around the real path (box-constrained quadratic program). The tube
//! width is the crop budget of one zoom, so the zoom is searched, not measured afterwards: the smallest zoom whose taut
//! path is no more jittery than the quadratic path it replaces. Any path inside the tube is a candidate, so the quadratic
//! one at its own zoom is too: the search can only improve on it.

use crate::stabilizer::{CameraPose, Stabilizer};
use sq_core_time::Vec2;

type FrameZoom<'a> = &'a dyn Fn(&CameraPose, usize) -> Option<f64>;

impl Stabilizer {
    /// RMS second difference of a path in px at `reach` (the frame-to-frame shake the wanted path still has).
    pub(crate) fn path_jitter(p: &[CameraPose], reach: f64) -> f64 {
        let n = p.len();
        if n <= 2 {
            return 0.0;
        }
        let d2 = |f: &dyn Fn(&CameraPose) -> f64| -> Vec<f64> {
            (1..n - 1).map(|i| f(&p[i + 1]) - 2.0 * f(&p[i]) + f(&p[i - 1])).collect()
        };
        let rad = std::f64::consts::PI / 180.0;
        let cs = [
            d2(&|q| q.translation.x),
            d2(&|q| q.translation.y),
            d2(&|q| q.rotation * rad * reach),
            d2(&|q| q.log_scale * reach),
        ];
        let sum = cs.iter().fold(0.0, |a, c| a + c.iter().fold(0.0, |b, v| b + v * v));
        (sum / (n - 2) as f64).sqrt()
    }

    /// The wanted path of one segment with the least zoom: for a zoom `z` (bisection from 1 to the zoom of `base`) the
    /// least-curvature path inside a tube around `real`, the tube per channel as wide as `base` strays from `real` at most
    /// and narrowed frame by frame (and around it) wherever the path would need more than `z`. The smallest `z` whose path
    /// is no more jittery than `base` wins; `base` (the quadratic path, also the fallback) is itself a candidate, so the
    /// result never needs more zoom or shakes more. `frame_zoom(pose, k)` is the zoom frame k needs (`None`: does not fit
    /// the limit).
    pub(crate) fn l1_crop_path(
        real: &[CameraPose],
        base: &[CameraPose],
        hw: f64,
        hh: f64,
        frame_zoom: FrameZoom,
    ) -> Vec<CameraPose> {
        let n = real.len();
        if !(n > 2 && base.len() == n) {
            return base.to_vec();
        }
        let zoom = |p: &[CameraPose]| -> Option<f64> {
            let mut z = 1.0_f64;
            for (k, pose) in p.iter().enumerate() {
                z = z.max(frame_zoom(pose, k)?);
            }
            Some(z)
        };
        let Some(base_zoom) = zoom(base).filter(|z| *z > 1.0 + 1e-6) else { return base.to_vec() };
        let diagonal = (hw * hw + hh * hh).sqrt();
        let target = Self::path_jitter(base, diagonal) * 1.0001;
        // The least-curvature path whose frames all need at most `z`: frames that do not fit are pinned at the boundary of
        // the feasible set (on the line from the real pose to the violating one) and the path is solved again.
        let path = |z: f64| -> Option<Vec<CameraPose>> {
            let mut pinned: Vec<Option<CameraPose>> = vec![None; n];
            let lambda = vec![1.0_f64; n - 2];
            let mu = vec![1e-4_f64; n];
            let solve = |pinned: &[Option<CameraPose>]| -> Vec<CameraPose> {
                let chans: [fn(&CameraPose) -> f64; 4] =
                    [|p| p.translation.x, |p| p.translation.y, |p| p.rotation, |p| p.log_scale];
                let mut channels: Vec<Vec<f64>> = Vec::new();
                for f in chans {
                    let target: Vec<f64> = (0..n).map(|i| pinned[i].as_ref().map_or_else(|| f(&base[i]), f)).collect();
                    let w: Vec<f64> = (0..n).map(|i| if pinned[i].is_none() { mu[i] } else { 1e6 }).collect();
                    channels.push(Self::solve_second_difference(&target, &lambda, Some(&w)));
                }
                (0..n)
                    .map(|i| CameraPose::new(Vec2::new(channels[0][i], channels[1][i]), channels[2][i], channels[3][i]))
                    .collect()
            };
            let over = |p: &CameraPose, k: usize| frame_zoom(p, k).unwrap_or(f64::INFINITY) > z + 1e-9;
            for _ in 0..30 {
                let mut p = solve(&pinned);
                let mut bad = false;
                for k in 0..n {
                    if pinned[k].is_none() && over(&p[k], k) {
                        bad = true;
                        let (mut lo, mut hi) = (0.0_f64, 1.0_f64); // fraction of the way from the real pose to p[k]
                        for _ in 0..25 {
                            let mid = (lo + hi) / 2.0;
                            if !over(&CameraPose::lerp(&real[k], &p[k], mid), k) {
                                lo = mid;
                            } else {
                                hi = mid;
                            }
                        }
                        pinned[k] = Some(CameraPose::lerp(&real[k], &p[k], lo));
                    }
                }
                if !bad {
                    return Some(p);
                }
                p = solve(&pinned);
                if (0..n).all(|i| !over(&p[i], i)) {
                    return Some(p);
                }
            }
            None
        };
        let (mut best, mut best_zoom) = (base.to_vec(), base_zoom);
        let (mut lo, mut hi) = (1.0_f64, base_zoom);
        for _ in 0..10 {
            let mid = (lo + hi) / 2.0;
            let found =
                path(mid).filter(|p| Self::path_jitter(p, diagonal) <= target).and_then(|p| zoom(&p).map(|z| (p, z)));
            if let Some((p, z)) = found {
                hi = mid;
                if z < best_zoom {
                    best = p;
                    best_zoom = z;
                }
            } else {
                lo = mid;
            }
        }
        best
    }

    /// Camera Lock pose with the least zoom: pattern search over (x, y, turn, scale) minimizing the largest zoom any frame
    /// of `real` needs to hold it (`zoom_of(pose, k)`, `None` = does not fit), starting at `start`, steps in px / degrees /
    /// log.
    pub(crate) fn lock_pose(real: &[CameraPose], start: CameraPose, step: f64, zoom_of: FrameZoom) -> CameraPose {
        let cost = |p: &CameraPose| -> f64 {
            let mut m = 1.0_f64;
            for k in 0..real.len() {
                m = m.max(zoom_of(p, k).unwrap_or(1e3));
            }
            m
        };
        let mut cur = start;
        let mut c = cost(&cur);
        let mut h = [step, step, step / 100.0, step / 2000.0];
        for _ in 0..60 {
            let mut improved = false;
            for (dim, &step) in h.iter().enumerate() {
                for sign in [-1.0_f64, 1.0] {
                    let mut q = cur;
                    match dim {
                        0 => q.translation.x += sign * step,
                        1 => q.translation.y += sign * step,
                        2 => q.rotation += sign * step,
                        _ => q.log_scale += sign * step,
                    }
                    let qc = cost(&q);
                    if qc < c - 1e-9 {
                        cur = q;
                        c = qc;
                        improved = true;
                    }
                }
            }
            if !improved {
                h = h.map(|v| v / 2.0);
                if h[0] < 0.05 {
                    break;
                }
            }
        }
        cur
    }
}
