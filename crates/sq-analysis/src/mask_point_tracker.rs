// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LucasKanade.swift, MaskPointTracker.swift (VisionMaskTracker's box tracker is replaced here, see the note below)
//! Drawn-mask tracking, portable: pyramidal Lucas-Kanade optical flow on grid points inside the outline, fitted per
//! [`MaskTrackMode`] (robust, `MaskMotionFit`), chained from the first frame and re-anchored against a template so the
//! chain does not drift. The output is the same as the Swift app's: one [`MaskMotion`] per frame (frame fractions, from the
//! first frame, the first is the identity), `None` from the frame the object was lost on; `apply_mask_track_segments`
//! turns them into path keys, so projects stay compatible.
// shortcut: Position and +Scale use this point tracker too; the Swift app follows the bounding box with Apple Vision there.
// Upgrade: a box tracker (e.g. EdgeTAM box prompt) if point flow proves worse than Vision on real footage.

use sq_core_masks::mask_motion::{MaskMotion, MaskMotionFit, MaskTrackMode};
use sq_core_time::Vec2;
use std::rc::Rc;

/// A luma image, 0...1.
#[derive(Clone, Debug)]
pub struct Gray {
    /// Width in px.
    pub w: usize,
    /// Height in px.
    pub h: usize,
    /// Row-major luma.
    pub px: Vec<f32>,
}

impl Gray {
    /// Luma of an RGBA picture (Rec. 709 weights).
    pub fn from_rgba(w: usize, h: usize, rgba: &[u8]) -> Option<Gray> {
        if rgba.len() < w * h * 4 || w == 0 || h == 0 {
            return None;
        }
        let px = rgba
            .as_chunks::<4>()
            .0
            .iter()
            .take(w * h)
            .map(|p| (0.2126 * f32::from(p[0]) + 0.7152 * f32::from(p[1]) + 0.0722 * f32::from(p[2])) / 255.0)
            .collect();
        Some(Gray { w, h, px })
    }

    /// Bilinear sample, clamped to the image.
    pub fn at(&self, x: f32, y: f32) -> f32 {
        let cx = x.clamp(0.0, (self.w - 1) as f32);
        let cy = y.clamp(0.0, (self.h - 1) as f32);
        let (x0, y0) = (cx as usize, cy as usize);
        let (x1, y1) = ((x0 + 1).min(self.w - 1), (y0 + 1).min(self.h - 1));
        let (fx, fy) = (cx - x0 as f32, cy - y0 as f32);
        let p = |x: usize, y: usize| self.px[y * self.w + x];
        let (a, b, c, d) = (p(x0, y0), p(x1, y0), p(x0, y1), p(x1, y1));
        (a + (b - a) * fx) * (1.0 - fy) + (c + (d - c) * fx) * fy
    }

    fn half(&self) -> Gray {
        let (nw, nh) = ((self.w / 2).max(1), (self.h / 2).max(1));
        let mut out = vec![0.0f32; nw * nh];
        for y in 0..nh {
            for x in 0..nw {
                let (x0, x1) = ((2 * x).min(self.w - 1), (2 * x + 1).min(self.w - 1));
                let (y0, y1) = ((2 * y).min(self.h - 1), (2 * y + 1).min(self.h - 1));
                let p = |x: usize, y: usize| self.px[y * self.w + x];
                out[y * nw + x] = (p(x0, y0) + p(x1, y0) + p(x0, y1) + p(x1, y1)) * 0.25;
            }
        }
        Gray { w: nw, h: nh, px: out }
    }
}

/// Pyramidal Lucas-Kanade.
pub struct LucasKanade;

impl LucasKanade {
    const LEVELS: usize = 3;
    /// Window radius (px).
    pub const RADIUS: usize = 7;
    const ITERATIONS: usize = 12;
    const MIN_EIGEN: f32 = 1e-4;

    /// The image and its halves.
    pub fn pyramid(g: &Gray) -> Vec<Gray> {
        let mut out = vec![g.clone()];
        while out.len() < Self::LEVELS {
            let next = out[out.len() - 1].half();
            out.push(next);
        }
        out
    }

    /// Where `pts` of `pa` went in `pb`; points that cannot be followed are dropped. `None` below 8 pairs.
    pub fn pairs(pa: &[Gray], pb: &[Gray], pts: &[Vec2]) -> Option<(Vec<Vec2>, Vec<Vec2>)> {
        let (mut from, mut to) = (Vec::new(), Vec::new());
        for p in pts {
            if let Some(q) = Self::track(*p, pa, pb) {
                from.push(*p);
                to.push(q);
            }
        }
        (from.len() >= 8).then_some((from, to))
    }

    /// One point through the pyramids; `None` when the window has no texture or the flow is implausible.
    pub fn track(p: Vec2, a: &[Gray], b: &[Gray]) -> Option<Vec2> {
        let r = Self::RADIUS as i32;
        let n = ((2 * r + 1) * (2 * r + 1)) as usize;
        let (mut ix, mut iy, mut i0) = (vec![0.0f32; n], vec![0.0f32; n], vec![0.0f32; n]);
        let (mut gx, mut gy) = (0.0f32, 0.0f32);
        for level in (0..a.len()).rev() {
            let s = (1u32 << level) as f32;
            let (px, py) = (p.x as f32 / s, p.y as f32 / s);
            let (la, lb) = (&a[level], &b[level]);
            let (mut gxx, mut gxy, mut gyy) = (0.0f32, 0.0f32, 0.0f32);
            let mut k = 0;
            for dy in -r..=r {
                for dx in -r..=r {
                    let (x, y) = (px + dx as f32, py + dy as f32);
                    let vx = (la.at(x + 1.0, y) - la.at(x - 1.0, y)) * 0.5;
                    let vy = (la.at(x, y + 1.0) - la.at(x, y - 1.0)) * 0.5;
                    ix[k] = vx;
                    iy[k] = vy;
                    i0[k] = la.at(x, y);
                    gxx += vx * vx;
                    gxy += vx * vy;
                    gyy += vy * vy;
                    k += 1;
                }
            }
            let det = gxx * gyy - gxy * gxy;
            let tr = gxx + gyy;
            let min_eig = (tr - ((gxx - gyy) * (gxx - gyy) + 4.0 * gxy * gxy).sqrt()) / 2.0 / n as f32;
            if det <= 1e-12 || (level == 0 && min_eig < Self::MIN_EIGEN) {
                return None;
            }
            let (mut vx, mut vy) = (0.0f32, 0.0f32);
            for _ in 0..Self::ITERATIONS {
                let (mut bx, mut by) = (0.0f32, 0.0f32);
                let mut k = 0;
                for dy in -r..=r {
                    for dx in -r..=r {
                        let d = lb.at(px + dx as f32 + gx + vx, py + dy as f32 + gy + vy) - i0[k];
                        bx += d * ix[k];
                        by += d * iy[k];
                        k += 1;
                    }
                }
                let ex = -(gyy * bx - gxy * by) / det;
                let ey = -(gxx * by - gxy * bx) / det;
                vx += ex;
                vy += ey;
                if ex * ex + ey * ey < 1e-4 {
                    break;
                }
            }
            if !vx.is_finite() || !vy.is_finite() {
                return None;
            }
            if level > 0 {
                gx = 2.0 * (gx + vx);
                gy = 2.0 * (gy + vy);
            } else {
                gx += vx;
                gy += vy;
            }
        }
        (gx.abs() < 60.0 && gy.abs() < 60.0).then(|| Vec2::new(p.x + f64::from(gx), p.y + f64::from(gy)))
    }
}

/// Distance from `p` to the nearest edge of the closed polygon.
fn edge_distance(poly: &[Vec2], p: Vec2) -> f64 {
    let mut best = f64::INFINITY;
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[(i + 1) % poly.len()]);
        let ab = b - a;
        let l2 = ab.x * ab.x + ab.y * ab.y;
        let t = if l2 > 0.0 { (((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2).clamp(0.0, 1.0) } else { 0.0 };
        best = best.min((a + ab * t - p).length());
    }
    best
}

fn area(p: &[Vec2]) -> f64 {
    let mut s = 0.0;
    for i in 0..p.len() {
        let (a, b) = (p[i], p[(i + 1) % p.len()]);
        s += a.x * b.y - b.x * a.y;
    }
    s / 2.0
}

/// A template: the luma around the region as it stood at `motion`, and the points to correlate.
struct Anchor {
    pyramid: Vec<Gray>,
    ox: usize,
    oy: usize,
    motion: MaskMotion,
    points: Vec<Vec2>,
}

impl Anchor {
    const MARGIN: f64 = 16.0;

    fn new(gray: &Gray, motion: MaskMotion, region: &[Vec2], w: f64, h: f64) -> Option<Anchor> {
        let poly: Vec<Vec2> = region.iter().map(|r| motion.apply(Vec2::new(r.x * w, r.y * h))).collect();
        let min_x = poly.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
        let max_x = poly.iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
        let min_y = poly.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
        let max_y = poly.iter().map(|p| p.y).fold(f64::NEG_INFINITY, f64::max);
        if !(min_x.is_finite() && max_x.is_finite() && min_y.is_finite() && max_y.is_finite()) {
            return None;
        }
        let x0 = (min_x - Self::MARGIN).floor().max(0.0) as usize;
        let y0 = (min_y - Self::MARGIN).floor().max(0.0) as usize;
        let x1 = ((max_x + Self::MARGIN).ceil().max(0.0) as usize).min(gray.w);
        let y1 = ((max_y + Self::MARGIN).ceil().max(0.0) as usize).min(gray.h);
        if x1 < x0 + 16 || y1 < y0 + 16 {
            return None;
        }
        let (cw, ch) = (x1 - x0, y1 - y0);
        let mut px = vec![0.0f32; cw * ch];
        for y in 0..ch {
            for x in 0..cw {
                px[y * cw + x] = gray.px[(y0 + y) * gray.w + x0 + x];
            }
        }
        let pyramid = LucasKanade::pyramid(&Gray { w: cw, h: ch, px });
        let r = LucasKanade::RADIUS as f64 + 1.0;
        let spacing = ((area(&poly).abs() / 200.0).sqrt()).max(2.0);
        let mut pts: Vec<Vec2> = MaskMotionFit::sample_points(&poly, spacing, 300)
            .into_iter()
            .filter(|p| {
                p.x - x0 as f64 >= r
                    && p.y - y0 as f64 >= r
                    && p.x - x0 as f64 <= (cw - 1) as f64 - r
                    && p.y - y0 as f64 <= (ch - 1) as f64 - r
            })
            .collect();
        let inset: Vec<Vec2> = pts.iter().copied().filter(|p| edge_distance(&poly, *p) > r).collect();
        if inset.len() >= 24 {
            pts = inset;
        }
        let points = pts.iter().map(|p| Vec2::new(p.x - x0 as f64, p.y - y0 as f64)).collect();
        Some(Anchor { pyramid, ox: x0, oy: y0, motion, points })
    }

    /// Refines `estimate` (this template's pose to `gray`'s, from the first frame) so the template matches `gray`; also
    /// the correlation of the result. Without usable points the estimate stands.
    fn align(&self, estimate: &MaskMotion, gray: &Gray, mode: MaskTrackMode) -> (MaskMotion, f64) {
        let Some(back) = self.motion.inverse() else { return (*estimate, 1.0) };
        if self.points.len() < 8 {
            return (*estimate, 1.0);
        }
        let rel = back.then(estimate);
        let base = &self.pyramid[0];
        let mut warped = Gray { w: base.w, h: base.h, px: vec![0.0; base.w * base.h] };
        for y in 0..base.h {
            for x in 0..base.w {
                let q = rel.apply(Vec2::new((self.ox + x) as f64, (self.oy + y) as f64));
                warped.px[y * base.w + x] = gray.at(q.x as f32, q.y as f32);
            }
        }
        let mut result = *estimate;
        if let Some((from, to)) = LucasKanade::pairs(&self.pyramid, &LucasKanade::pyramid(&warped), &self.points)
            && let Some(fit) = MaskMotionFit::fit(&from, &to, mode)
            && fit.inliers >= 8.max(self.points.len() / 5)
        {
            let e = MaskMotion::translation(Vec2::new(-(self.ox as f64), -(self.oy as f64)))
                .then(&fit.motion)
                .then(&MaskMotion::translation(Vec2::new(self.ox as f64, self.oy as f64)));
            result = self.motion.then(&e).then(&rel);
        }
        (result, self.correlation(&result, &back, gray))
    }

    /// Pearson correlation of the template and the frame at the sample points under `estimate`.
    fn correlation(&self, estimate: &MaskMotion, back: &MaskMotion, gray: &Gray) -> f64 {
        let rel = back.then(estimate);
        let (mut a, mut b) = (Vec::new(), Vec::new());
        for p in &self.points {
            let q = rel.apply(Vec2::new(self.ox as f64 + p.x, self.oy as f64 + p.y));
            a.push(f64::from(self.pyramid[0].at(p.x as f32, p.y as f32)));
            b.push(f64::from(gray.at(q.x as f32, q.y as f32)));
        }
        let n = a.len() as f64;
        let (ma, mb) = (a.iter().sum::<f64>() / n, b.iter().sum::<f64>() / n);
        let (mut saa, mut sbb, mut sab) = (0.0, 0.0, 0.0);
        for i in 0..a.len() {
            let (x, y) = (a[i] - ma, b[i] - mb);
            saa += x * x;
            sbb += y * y;
            sab += x * y;
        }
        if saa <= 1e-9 || sbb <= 1e-9 {
            return 0.0;
        }
        (sab / (saa * sbb).sqrt()).max(0.0)
    }
}

/// Follows one region through frames handed in tracking order. One per track run.
pub struct MaskPointTracker {
    mode: MaskTrackMode,
    region: Vec<Vec2>,
    total: MaskMotion,
    previous: Option<Vec<Gray>>,
    lost: bool,
    held_frames: usize,
    anchor: Option<Rc<Anchor>>,
    original: Option<Rc<Anchor>>,
}

impl MaskPointTracker {
    /// Below this correlation the template is refreshed from the current frame.
    const REFRESH_CONFIDENCE: f64 = 0.9;
    /// Below this the frame is not trusted: the motion holds.
    const HOLD_CONFIDENCE: f64 = 0.4;
    /// Held for more than this many frames in a row: lost.
    const MAX_HELD_FRAMES: usize = 90;
    /// With a refreshed template, the original one still correlating at least this much pulls the result back.
    const GUARD_CONFIDENCE: f64 = 0.6;
    /// Share of the way from the refreshed-template result to the original-template result.
    const GUARD_BLEND: f64 = 0.3;
    /// Grid points aimed at per frame.
    const SAMPLES: f64 = 300.0;
    /// Fewer kept points than this share of the samples (or than 8): lost.
    const MIN_INLIER_SHARE: f64 = 0.25;
    /// Less of the region than this inside the frame: lost.
    const MIN_VISIBLE_SHARE: f64 = 0.4;

    /// A tracker for `region` (frame fractions on the first frame).
    pub fn new(region: Vec<Vec2>, mode: MaskTrackMode) -> MaskPointTracker {
        MaskPointTracker {
            mode,
            region,
            total: MaskMotion::IDENTITY,
            previous: None,
            lost: false,
            held_frames: 0,
            anchor: None,
            original: None,
        }
    }

    fn blend(a: &MaskMotion, b: &MaskMotion, t: f64) -> MaskMotion {
        let na = if a.m[8] != 0.0 { a.m[8] } else { 1.0 };
        let nb = if b.m[8] != 0.0 { b.m[8] } else { 1.0 };
        let mut m = [0.0; 9];
        for (i, v) in m.iter_mut().enumerate() {
            *v = a.m[i] / na * (1.0 - t) + b.m[i] / nb * t;
        }
        MaskMotion { m }
    }

    /// Motion (frame fractions) from the first frame to `frame`; the first call gives the identity. `None` once lost.
    pub fn step(&mut self, frame: &Gray) -> Option<MaskMotion> {
        if self.lost {
            return None;
        }
        let (w, h) = (frame.w as f64, frame.h as f64);
        let pyramid = LucasKanade::pyramid(frame);
        let Some(prev) = self.previous.take() else {
            self.anchor = Anchor::new(frame, MaskMotion::IDENTITY, &self.region, w, h).map(Rc::new);
            self.original = self.anchor.clone();
            self.previous = Some(pyramid);
            return Some(MaskMotion::IDENTITY);
        };
        let now: Vec<Vec2> = self.region.iter().map(|p| self.total.apply(Vec2::new(p.x * w, p.y * h))).collect();
        let spacing = ((area(&now).abs() / Self::SAMPLES).sqrt()).max(2.0);
        let r = LucasKanade::RADIUS as f64 + 1.0;
        let all = MaskMotionFit::sample_points(&now, spacing, (Self::SAMPLES * 1.5) as usize);
        let mut pts: Vec<Vec2> =
            all.iter().copied().filter(|p| p.x >= r && p.y >= r && p.x <= w - 1.0 - r && p.y <= h - 1.0 - r).collect();
        if (pts.len() as f64) < Self::MIN_VISIBLE_SHARE * all.len() as f64 {
            self.lost = true;
            return None;
        }
        let inset: Vec<Vec2> = pts.iter().copied().filter(|p| edge_distance(&now, *p) > r).collect();
        if inset.len() >= 24 {
            pts = inset;
        }
        let mut candidate = self.total;
        if pts.len() >= 8
            && let Some((from, to)) = LucasKanade::pairs(&prev, &pyramid, &pts)
            && let Some(fit) = MaskMotionFit::fit(&from, &to, self.mode)
            && fit.inliers as f64 >= 8.0_f64.max(Self::MIN_INLIER_SHARE * pts.len() as f64)
        {
            candidate = self.total.then(&fit.motion);
        }
        let mut conf = 1.0;
        if let Some(anchor) = self.anchor.clone() {
            let (m1, c1) = anchor.align(&candidate, frame, self.mode);
            candidate = m1;
            conf = c1;
            if let Some(original) = &self.original
                && !Rc::ptr_eq(&anchor, original)
                && conf >= Self::HOLD_CONFIDENCE
            {
                let (m0, c0) = original.align(&candidate, frame, self.mode);
                if c0 >= Self::GUARD_CONFIDENCE {
                    candidate = Self::blend(&candidate, &m0, Self::GUARD_BLEND);
                }
            }
        }
        if conf < Self::HOLD_CONFIDENCE {
            self.held_frames += 1;
            self.previous = Some(prev);
            if self.held_frames > Self::MAX_HELD_FRAMES {
                self.lost = true;
                return None;
            }
            return Some(self.total.in_fractions(w, h));
        }
        self.held_frames = 0;
        self.total = candidate;
        self.previous = Some(pyramid);
        if (self.anchor.is_none() || conf < Self::REFRESH_CONFIDENCE)
            && let Some(a) = Anchor::new(frame, self.total, &self.region, w, h).map(Rc::new)
        {
            if self.original.is_none() {
                self.original = Some(Rc::clone(&a));
            }
            self.anchor = Some(a);
        }
        Some(self.total.in_fractions(w, h))
    }
}

/// A region followed over `frames` (tracking order): one motion per frame, `None` from the one it was lost on.
/// `stop` is asked before each frame: true ends the run early (the result is shorter then).
pub fn track_region(
    region: &[Vec2],
    mode: MaskTrackMode,
    frames: &mut dyn FnMut(usize) -> Option<Gray>,
    count: usize,
    stop: &mut dyn FnMut(usize) -> bool,
) -> Vec<Option<MaskMotion>> {
    let mut tracker = MaskPointTracker::new(region.to_vec(), mode);
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        if stop(i) {
            break;
        }
        let m = frames(i).and_then(|g| tracker.step(&g));
        let lost = m.is_none();
        out.push(m);
        if lost {
            // Frames after a loss stay lost, so the caller sees where the run ended.
            out.resize(count, None);
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A textured square patch of 40 px on a 160 x 120 noise-free gradient background, moved by `(dx, dy)` and turned by `deg`.
    fn frame(dx: f64, dy: f64, deg: f64) -> Gray {
        let (w, h) = (160usize, 120usize);
        let (cx, cy) = (60.0 + dx, 50.0 + dy);
        let a = deg.to_radians();
        let mut px = vec![0.0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let (ox, oy) = (x as f64 - cx, y as f64 - cy);
                // Back into the patch's own frame.
                let (u, v) = (ox * a.cos() + oy * a.sin(), -ox * a.sin() + oy * a.cos());
                let bg = 0.3 + 0.1 * ((x as f32) * 0.05).sin();
                px[y * w + x] = if u.abs() < 20.0 && v.abs() < 20.0 {
                    0.5 + 0.4 * ((u * 0.55).sin() * (v * 0.45).cos()) as f32
                } else {
                    bg
                };
            }
        }
        Gray { w, h, px }
    }

    fn region() -> Vec<Vec2> {
        let (w, h) = (160.0, 120.0);
        [(40.0, 30.0), (80.0, 30.0), (80.0, 70.0), (40.0, 70.0)].iter().map(|(x, y)| Vec2::new(x / w, y / h)).collect()
    }

    fn run(mode: MaskTrackMode, frames_at: Vec<(f64, f64, f64)>) -> Vec<Option<MaskMotion>> {
        let n = frames_at.len();
        let mut f = move |i: usize| Some(frame(frames_at[i].0, frames_at[i].1, frames_at[i].2));
        track_region(&region(), mode, &mut f, n, &mut |_| false)
    }

    #[test]
    fn a_moving_square_is_followed_to_within_a_pixel() {
        let path: Vec<_> = (0..12).map(|i| (i as f64 * 2.0, i as f64 * 1.0, 0.0)).collect();
        let out = run(MaskTrackMode::Position, path);
        assert!(out.iter().all(Option::is_some));
        let m = out[11].expect("motion");
        let c = m.apply(Vec2::new(0.5, 0.5));
        // Pixel motion (22, 11) on a 160 x 120 frame.
        assert!((c.x - (0.5 + 22.0 / 160.0)).abs() < 1.0 / 160.0, "x {}", c.x);
        assert!((c.y - (0.5 + 11.0 / 120.0)).abs() < 1.0 / 120.0, "y {}", c.y);
        assert_eq!(out[0].map(|m| m.m), Some(MaskMotion::IDENTITY.m));
    }

    #[test]
    fn a_turning_square_gives_a_rotation() {
        let path: Vec<_> = (0..10).map(|i| (0.0, 0.0, i as f64 * 2.0)).collect();
        let out = run(MaskTrackMode::Rotation, path);
        let m = out[9].expect("motion").in_pixels(160.0, 120.0);
        let angle = m.m[3].atan2(m.m[0]).to_degrees();
        assert!((angle - 18.0).abs() < 2.0, "angle {angle}");
    }

    #[test]
    fn a_vanished_object_is_held_for_a_while_then_lost() {
        let mut frames: Vec<(f64, f64, f64)> = (0..4).map(|i| (i as f64, 0.0, 0.0)).collect();
        frames.extend((0..95).map(|_| (400.0, 0.0, 0.0))); // the patch left the picture
        let out = run(MaskTrackMode::Position, frames);
        let held = out[3].expect("seen").m;
        assert_eq!(out[4].map(|m| m.m), Some(held), "held on the last motion");
        assert!(out[98].is_none(), "lost after 90 held frames");
    }

    #[test]
    fn a_stop_ends_the_run_early() {
        let mut f = |i: usize| Some(frame(i as f64, 0.0, 0.0));
        let out = track_region(&region(), MaskTrackMode::Position, &mut f, 10, &mut |i| i >= 3);
        assert_eq!(out.len(), 3);
    }
}
