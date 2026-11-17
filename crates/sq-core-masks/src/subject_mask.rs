// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectMask.swift
//! A person matte (from Vision, made in SQAnalysis) as a mask source, plus the pure maths around it: sampling (CPU
//! reference of the shader), resampling, motion-compensated temporal smoothing and an edge-flicker measure.

use crate::matte_refine;
use sq_core_model::{MaskSource, MatteChannel};
use sq_core_time::Vec2;

/// Logic Swift keeps on `MaskSource`.
pub trait MaskSourceExt {
    /// Mattes instead of a polygon (a color range reads the picture itself: neither).
    fn uses_matte(self) -> bool;
}

impl MaskSourceExt for MaskSource {
    fn uses_matte(self) -> bool {
        self != MaskSource::Path && self != MaskSource::ColorRange
    }
}

/// Logic Swift keeps on `MatteChannel`.
pub trait MatteChannelExt {
    /// Display name.
    fn title(self) -> &'static str;
    /// The matte value 0...1 of one pixel of straight (not premultiplied), display-encoded color.
    fn value(self, red: f64, green: f64, blue: f64, alpha: f64) -> f64;
}

impl MatteChannelExt for MatteChannel {
    fn title(self) -> &'static str {
        match self {
            MatteChannel::Shape => "Shape",
            MatteChannel::Brightness => "Brightness",
        }
    }

    fn value(self, r: f64, g: f64, b: f64, a: f64) -> f64 {
        let alpha = a.clamp(0.0, 1.0);
        match self {
            MatteChannel::Shape => alpha,
            MatteChannel::Brightness => (0.2126 * r + 0.7152 * g + 0.0722 * b).clamp(0.0, 1.0) * alpha,
        }
    }
}

/// A single-channel matte, 0 (background) ... 1 (subject), row-major, row 0 at the top. Texel centers sit at
/// (x + 0.5, y + 0.5) in matte px; frame fractions map to matte px by scaling with the size (the matte covers the
/// whole frame).
#[derive(Clone, Debug, PartialEq)]
pub struct SubjectMatte {
    width: usize,
    height: usize,
    /// The values.
    pub values: Vec<f32>,
}

impl SubjectMatte {
    /// A matte of `width` x `height`; `values.len()` must be `width * height` (Swift traps otherwise).
    pub fn new(width: usize, height: usize, values: Vec<f32>) -> SubjectMatte {
        assert!(width > 0 && height > 0 && values.len() == width * height, "SubjectMatte size mismatch");
        SubjectMatte { width, height, values }
    }

    /// Width in texels.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in texels.
    pub fn height(&self) -> usize {
        self.height
    }

    /// The value at texel `(x, y)`.
    pub fn at(&self, x: usize, y: usize) -> f32 {
        self.values[y * self.width + x]
    }

    /// Sum of all values (px² of subject).
    pub fn area(&self) -> f64 {
        self.values.iter().fold(0.0, |s, v| s + f64::from(*v))
    }

    /// No value reaches one 8-bit step (the matte store keeps 8 bit): the matte covers nothing. A Magic pick or tracked
    /// frame like that counts as "nothing found", never as a mask that cuts the whole picture.
    pub fn is_blank(&self) -> bool {
        !self.values.iter().any(|v| *v >= 0.5_f32 / 255.0_f32)
    }

    /// Value-weighted center in matte px (texel centers at +0.5), `None` for an empty matte.
    pub fn centroid(&self) -> Option<Vec2> {
        let (mut s, mut sx, mut sy) = (0.0_f64, 0.0_f64, 0.0_f64);
        for y in 0..self.height {
            let row = y * self.width;
            for x in 0..self.width {
                let v = f64::from(self.values[row + x]);
                if v == 0.0 {
                    continue;
                }
                s += v;
                sx += v * (x as f64 + 0.5);
                sy += v * (y as f64 + 0.5);
            }
        }
        (s > 1e-9).then(|| Vec2::new(sx / s, sy / s))
    }

    /// Bilinear sample at matte px `(px, py)` (texel centers at +0.5), clamped to the edge texels.
    pub fn sample_px(&self, px: f64, py: f64) -> f64 {
        let fx = (px - 0.5).max(0.0).min((self.width - 1) as f64);
        let fy = (py - 0.5).max(0.0).min((self.height - 1) as f64);
        let (x0, y0) = (fx as usize, fy as usize);
        let x1 = (x0 + 1).min(self.width - 1);
        let y1 = (y0 + 1).min(self.height - 1);
        let (tx, ty) = (fx - x0 as f64, fy - y0 as f64);
        let a = f64::from(self.values[y0 * self.width + x0]);
        let b = f64::from(self.values[y0 * self.width + x1]);
        let c = f64::from(self.values[y1 * self.width + x0]);
        let d = f64::from(self.values[y1 * self.width + x1]);
        let top = a + (b - a) * tx;
        let bottom = c + (d - c) * tx;
        top + (bottom - top) * ty
    }

    /// Bilinear sample at frame fractions `(u, v)` (0...1, origin top left), like the shader's sampler on the matte texture.
    pub fn sample(&self, u: f64, v: f64) -> f64 {
        self.sample_px(u * self.width as f64, v * self.height as f64)
    }

    /// The same matte at another size (bilinear).
    pub fn resampled(&self, w: usize, h: usize) -> SubjectMatte {
        if w == self.width && h == self.height {
            return self.clone();
        }
        let mut out = vec![0.0_f32; w * h];
        for y in 0..h {
            let v = (y as f64 + 0.5) / h as f64;
            for x in 0..w {
                out[y * w + x] = self.sample((x as f64 + 0.5) / w as f64, v) as f32;
            }
        }
        SubjectMatte::new(w, h, out)
    }

    /// The matte moved by `d` matte px (bilinear, edges clamped: a subject cut by the frame edge stays cut there).
    pub fn translated(&self, d: Vec2) -> SubjectMatte {
        if d.x == 0.0 && d.y == 0.0 {
            return self.clone();
        }
        let mut out = vec![0.0_f32; self.width * self.height];
        for y in 0..self.height {
            let py = y as f64 + 0.5 - d.y;
            for x in 0..self.width {
                out[y * self.width + x] = self.sample_px(x as f64 + 0.5 - d.x, py) as f32;
            }
        }
        SubjectMatte::new(self.width, self.height, out)
    }

    /// How far the 0.5 contours of two same-size mattes lie apart, in matte px: from every contour point of one matte,
    /// the distance along its normal to the other's contour (searched up to `reach` px, a miss counts as `reach`), both
    /// ways. Returns `(max, mean)`.
    pub fn edge_delta(a: &SubjectMatte, b: &SubjectMatte, reach: f64) -> (f64, f64) {
        assert!(a.width == b.width && a.height == b.height, "edgeDelta needs equal sizes");
        let (mut worst, mut sum, mut n) = (0.0_f64, 0.0_f64, 0_usize);
        for (from, to) in [(a, b), (b, a)] {
            for p in from.contour_points() {
                let d = from.distance_along_normal(p, to, reach);
                worst = worst.max(d);
                sum += d;
                n += 1;
            }
        }
        (worst, if n > 0 { sum / n as f64 } else { 0.0 })
    }

    /// Points (matte px) where the matte crosses 0.5 between horizontally or vertically adjacent texel centers.
    fn contour_points(&self) -> Vec<Vec2> {
        let mut pts = Vec::new();
        for y in 0..self.height {
            for x in 0..self.width {
                let v = f64::from(self.at(x, y)) - 0.5;
                if x + 1 < self.width {
                    let w = f64::from(self.at(x + 1, y)) - 0.5;
                    if (v < 0.0) != (w < 0.0) && v != w {
                        pts.push(Vec2::new(x as f64 + 0.5 + v / (v - w), y as f64 + 0.5));
                    }
                }
                if y + 1 < self.height {
                    let w = f64::from(self.at(x, y + 1)) - 0.5;
                    if (v < 0.0) != (w < 0.0) && v != w {
                        pts.push(Vec2::new(x as f64 + 0.5, y as f64 + 0.5 + v / (v - w)));
                    }
                }
            }
        }
        pts
    }

    /// Distance from contour point `p` of this matte along its normal to the nearest 0.5 crossing of `other`.
    fn distance_along_normal(&self, p: Vec2, other: &SubjectMatte, reach: f64) -> f64 {
        let gx = self.sample_px(p.x + 0.5, p.y) - self.sample_px(p.x - 0.5, p.y);
        let gy = self.sample_px(p.x, p.y + 0.5) - self.sample_px(p.x, p.y - 0.5);
        let g = (gx * gx + gy * gy).sqrt();
        if g <= 1e-9 {
            return 0.0;
        }
        let n = Vec2::new(gx / g, gy / g);
        let f = |s: f64| other.sample_px(p.x + n.x * s, p.y + n.y * s) - 0.5;
        let f0 = f(0.0);
        if f0.abs() < 1e-9 {
            return 0.0;
        }
        let step = 0.25;
        let mut s = step;
        while s <= reach + 1e-9 {
            for dir in [1.0, -1.0] {
                let prev = f(dir * (s - step));
                let cur = f(dir * s);
                if (prev < 0.0) != (cur < 0.0) || cur == 0.0 {
                    let (mut lo, mut hi) = (s - step, s);
                    for _ in 0..30 {
                        let mid = (lo + hi) / 2.0;
                        if (f(dir * mid) < 0.0) == (prev < 0.0) {
                            lo = mid;
                        } else {
                            hi = mid;
                        }
                    }
                    return (lo + hi) / 2.0;
                }
            }
            s += step;
        }
        reach
    }
}

/// Edge moves up to `wobble` matte px count as segmentation wobble and are averaged; from `motion` px on they are
/// motion and the new matte is taken as is (linear in between).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotionGate {
    /// Largest averaged edge move.
    pub wobble: f64,
    /// From here the new matte wins.
    pub motion: f64,
}

/// Temporal smoothing of per-frame person mattes, so segmentation edges do not flicker. Motion compensated: the
/// smoothed matte of the neighboring frame (index +-1, so forward and reverse playback both smooth) is moved onto the
/// new matte's centroid before blending, so a walking subject is followed without lag. Blending is gated by how far the
/// edge moved at each pixel (`edge_displacement`): edge wobble of a few px is averaged, a part that really moved takes
/// the new matte. The last few results are kept by frame index: a frame shown again returns its result unchanged, and
/// frames arriving out of order blend with whichever neighbor is there. A frame without a smoothed neighbor, a size
/// change, an empty matte or a scene change starts from the raw matte.
#[derive(Clone, Debug)]
pub struct SubjectMatteSmoother {
    /// Weight of the new frame in the running average.
    pub new_frame_weight: f64,
    /// When set, blending is gated per pixel by how far the edge moved; `None` = plain blend.
    pub motion_gate: Option<MotionGate>,
    /// Results kept by frame index (oldest first).
    pub capacity: usize,
    recent: Vec<(i64, SubjectMatte)>,
}

impl Default for SubjectMatteSmoother {
    fn default() -> Self {
        SubjectMatteSmoother::new(0.25, 8, None)
    }
}

impl SubjectMatteSmoother {
    /// A smoother; `capacity` is at least 2.
    pub fn new(new_frame_weight: f64, capacity: usize, motion_gate: Option<MotionGate>) -> SubjectMatteSmoother {
        SubjectMatteSmoother { new_frame_weight, motion_gate, capacity: capacity.max(2), recent: Vec::new() }
    }

    /// Forgets every kept result.
    pub fn reset(&mut self) {
        self.recent.clear();
    }

    /// The smoothed matte already made for `frame_index`, if still kept.
    pub fn cached(&self, frame_index: i64) -> Option<&SubjectMatte> {
        self.recent.iter().rev().find(|r| r.0 == frame_index).map(|r| &r.1)
    }

    /// Adds the raw matte of frame `frame_index` and returns the smoothed matte for it (the kept one if that frame was done).
    pub fn push(&mut self, raw: &SubjectMatte, frame_index: i64) -> SubjectMatte {
        if let Some(done) = self.cached(frame_index) {
            return done.clone();
        }
        let prev = self
            .recent
            .iter()
            .rev()
            .find(|r| (r.0 - frame_index).abs() == 1 && r.1.width == raw.width && r.1.height == raw.height);
        let out = match prev {
            Some(p) => self.blend(raw, &p.1),
            None => raw.clone(),
        };
        self.recent.push((frame_index, out.clone()));
        if self.recent.len() > self.capacity {
            let extra = self.recent.len() - self.capacity;
            self.recent.drain(..extra);
        }
        out
    }

    fn blend(&self, raw: &SubjectMatte, prev: &SubjectMatte) -> SubjectMatte {
        let (Some(c_raw), Some(c_prev)) = (raw.centroid(), prev.centroid()) else {
            return raw.clone();
        };
        let (a_raw, a_prev) = (raw.area(), prev.area());
        let shift = Vec2::new(c_raw.x - c_prev.x, c_raw.y - c_prev.y);
        let diag = raw.width.max(raw.height) as f64;
        if a_raw / a_prev > 1.5 || a_prev / a_raw > 1.5 || shift.length() > 0.1 * diag {
            return raw.clone();
        }
        let moved = prev.translated(shift);
        let mut diff = 0.0_f64;
        for i in 0..raw.values.len() {
            diff += (f64::from(raw.values[i]) - f64::from(moved.values[i])).abs();
        }
        if diff > 0.5 * a_raw {
            return raw.clone();
        }
        let k = self.new_frame_weight as f32;
        let mut out = moved.values.clone();
        let Some(gate) = self.motion_gate else {
            for (i, o) in out.iter_mut().enumerate() {
                *o += (raw.values[i] - *o) * k;
            }
            return SubjectMatte::new(raw.width, raw.height, out);
        };
        // Spread over a few px and soften, so the weight is one smooth field (a per-pixel switch makes stray contours).
        let (w0, h0) = (raw.width, raw.height);
        let disp = matte_refine::box_blur(
            &matte_refine::morph(&Self::edge_displacement(raw, &moved), w0, h0, 2, false),
            w0,
            h0,
            2,
        );
        let r0 = gate.wobble as f32;
        let r1 = gate.motion.max(gate.wobble + 0.5) as f32;
        for i in 0..out.len() {
            // Weight of the new frame: k up to wobble reach, ramping to 1 (the new matte alone) at motion reach.
            let t = ((disp[i] - r0) / (r1 - r0)).clamp(0.0, 1.0);
            let w = k + (1.0 - k) * t;
            out[i] += (raw.values[i] - out[i]) * w;
        }
        SubjectMatte::new(raw.width, raw.height, out)
    }

    /// Per pixel, how far the 0.5 edge moved between `a` and `b` (matte px) where they disagree (one inside, the other
    /// outside): distance to `a`'s edge plus distance to `b`'s edge (chamfer distances). 0 where they agree.
    pub fn edge_displacement(a: &SubjectMatte, b: &SubjectMatte) -> Vec<f32> {
        let (w, h) = (a.width, a.height);
        let n = w * h;
        let a_in: Vec<bool> = a.values.iter().map(|v| *v >= 0.5).collect();
        let b_in: Vec<bool> = b.values.iter().map(|v| *v >= 0.5).collect();
        let a_out: Vec<bool> = a_in.iter().map(|v| !v).collect();
        let b_out: Vec<bool> = b_in.iter().map(|v| !v).collect();
        let to_a_in = distance_transform(&a_in, w, h);
        let to_a_out = distance_transform(&a_out, w, h);
        let to_b_in = distance_transform(&b_in, w, h);
        let to_b_out = distance_transform(&b_out, w, h);
        let mut out = vec![0.0_f32; n];
        for i in 0..n {
            if a_in[i] != b_in[i] {
                // Inside a, outside b: distance to a's outside plus distance to b's inside (each about the gap to that edge).
                out[i] = if a_in[i] { to_a_out[i] + to_b_in[i] } else { to_a_in[i] + to_b_out[i] };
            }
        }
        out
    }
}

/// Chamfer distance (1, sqrt 2) of every pixel to the nearest `true` pixel; a large value when there is none.
pub fn distance_transform(m: &[bool], w: usize, h: usize) -> Vec<f32> {
    let far = (w + h) as f32;
    let mut d: Vec<f32> = m.iter().map(|b| if *b { 0.0 } else { far }).collect();
    let s2 = 2.0_f32.sqrt();
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            let mut v = d[i];
            if v == 0.0 {
                continue;
            }
            if x > 0 {
                v = v.min(d[i - 1] + 1.0);
            }
            if y > 0 {
                v = v.min(d[i - w] + 1.0);
                if x > 0 {
                    v = v.min(d[i - w - 1] + s2);
                }
                if x + 1 < w {
                    v = v.min(d[i - w + 1] + s2);
                }
            }
            d[i] = v;
        }
    }
    for y in (0..h).rev() {
        for x in (0..w).rev() {
            let i = y * w + x;
            let mut v = d[i];
            if v == 0.0 {
                continue;
            }
            if x + 1 < w {
                v = v.min(d[i + 1] + 1.0);
            }
            if y + 1 < h {
                v = v.min(d[i + w] + 1.0);
                if x + 1 < w {
                    v = v.min(d[i + w + 1] + s2);
                }
                if x > 0 {
                    v = v.min(d[i + w - 1] + s2);
                }
            }
            d[i] = v;
        }
    }
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::Lcg;

    /// An anti-aliased disc whose radius wobbles along the contour like a segmentation edge: low angular frequencies with
    /// a new random phase/amplitude every frame, peak `jitter` px.
    fn noisy_disc(w: usize, h: usize, center: Vec2, radius: f64, jitter: f64, rng: &mut Lcg) -> SubjectMatte {
        let mut harmonics = Vec::new();
        for k in [2.0, 3.0, 5.0, 7.0] {
            let a = rng.symmetric();
            let p = rng.next() * 2.0 * std::f64::consts::PI;
            harmonics.push((k, a, p));
        }
        let total = harmonics.iter().map(|h| h.1.abs()).fold(0.0, |a, b| a + b);
        let scale = if total > 0.0 { jitter / total } else { 0.0 };
        let mut v = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 + 0.5 - center.x;
                let dy = y as f64 + 0.5 - center.y;
                let th = dy.atan2(dx);
                let mut r = radius;
                for hm in &harmonics {
                    r += hm.1 * scale * (hm.0 * th + hm.2).sin();
                }
                let d = (dx * dx + dy * dy).sqrt() - r;
                v[y * w + x] = (0.5 - d).clamp(0.0, 1.0) as f32;
            }
        }
        SubjectMatte::new(w, h, v)
    }

    fn matte(w: usize, h: usize, f: impl Fn(usize, usize) -> f32) -> SubjectMatte {
        let mut v = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                v[y * w + x] = f(x, y);
            }
        }
        SubjectMatte::new(w, h, v)
    }

    #[test]
    fn resampled_keeps_the_shape() {
        let a = SubjectMatte::new(4, 2, vec![0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0]);
        let b = a.resampled(8, 4);
        assert!(b.width() == 8 && b.height() == 4);
        assert!(b.at(0, 0) == 0.0 && b.at(7, 3) == 1.0);
        assert!((b.area() - a.area() * 4.0).abs() < 0.5);
    }

    #[test]
    fn translated_moves_the_centroid() {
        let mut rng = Lcg(1);
        let a = noisy_disc(64, 64, Vec2::new(32.0, 32.0), 10.0, 0.0, &mut rng);
        let b = a.translated(Vec2::new(3.5, -2.0));
        let (ca, cb) = (a.centroid().unwrap(), b.centroid().unwrap());
        assert!((cb.x - ca.x - 3.5).abs() < 0.05 && (cb.y - ca.y + 2.0).abs() < 0.05);
    }

    #[test]
    fn blank_mattes() {
        assert!(matte(8, 4, |_, _| 0.0).is_blank());
        assert!(matte(8, 4, |_, _| 0.001).is_blank());
        assert!(!matte(8, 4, |x, y| if x == 3 && y == 2 { 1.0 } else { 0.0 }).is_blank());
        assert!(!matte(8, 4, |_, _| 1.0).is_blank());
    }

    #[test]
    fn static_subject_edges_stop_flickering() {
        let mut rng = Lcg(42);
        let mut smoother = SubjectMatteSmoother::default();
        let (mut raw_prev, mut out_prev): (Option<SubjectMatte>, Option<SubjectMatte>) = (None, None);
        let (mut raw_worst, mut out_worst, mut out_mean, mut n) = (0.0_f64, 0.0_f64, 0.0_f64, 0);
        for f in 0..60 {
            let raw = noisy_disc(160, 160, Vec2::new(80.0, 80.0), 45.0, 3.0, &mut rng);
            let out = smoother.push(&raw, f);
            if let (Some(rp), Some(op)) = (&raw_prev, &out_prev)
                && f >= 8
            {
                raw_worst = raw_worst.max(SubjectMatte::edge_delta(rp, &raw, 16.0).0);
                let d = SubjectMatte::edge_delta(op, &out, 16.0);
                out_worst = out_worst.max(d.0);
                out_mean += d.1;
                n += 1;
            }
            raw_prev = Some(raw);
            out_prev = Some(out);
        }
        assert!(raw_worst > 3.0, "the test sequence must flicker: {raw_worst}");
        assert!(out_worst < 2.0, "smoothed edge delta {out_worst} px");
        assert!(out_mean / (n as f64) < 0.8, "mean {} px", out_mean / n as f64);
    }

    #[test]
    fn moving_subject_is_followed_without_lag() {
        let mut rng = Lcg(7);
        let mut smoother = SubjectMatteSmoother::default();
        let speed = Vec2::new(3.0, 1.0);
        let mut out_prev: Option<SubjectMatte> = None;
        let (mut jitter_worst, mut lag_worst) = (0.0_f64, 0.0_f64);
        for f in 0..40 {
            let c = Vec2::new(50.0 + speed.x * f as f64, 70.0 + speed.y * f as f64);
            let raw = noisy_disc(220, 160, c, 30.0, 3.0, &mut rng);
            let out = smoother.push(&raw, f);
            if f >= 8 {
                let truth = noisy_disc(220, 160, c, 30.0, 0.0, &mut rng);
                lag_worst = lag_worst.max(SubjectMatte::edge_delta(&truth, &out, 16.0).0);
                if let Some(op) = &out_prev {
                    jitter_worst = jitter_worst.max(SubjectMatte::edge_delta(&op.translated(speed), &out, 16.0).0);
                }
            }
            out_prev = Some(out);
        }
        assert!(jitter_worst < 2.0, "jitter {jitter_worst} px");
        assert!(lag_worst < 3.0, "distance to the true edge {lag_worst} px");
    }

    #[test]
    fn scene_cut_and_frame_jump_reset() {
        let mut rng = Lcg(3);
        let mut smoother = SubjectMatteSmoother::default();
        for f in 0..10 {
            smoother.push(&noisy_disc(120, 80, Vec2::new(30.0, 40.0), 15.0, 2.0, &mut rng), f);
        }
        let cut = noisy_disc(120, 80, Vec2::new(90.0, 40.0), 35.0, 0.0, &mut rng);
        assert_eq!(smoother.push(&cut, 10), cut);
        let jump = noisy_disc(120, 80, Vec2::new(88.0, 40.0), 33.0, 1.0, &mut rng);
        assert_eq!(smoother.push(&jump, 50), jump);
    }

    #[test]
    fn same_frame_again_returns_the_cached_result() {
        let mut rng = Lcg(11);
        let mut smoother = SubjectMatteSmoother::default();
        let mut last = SubjectMatte::new(1, 1, vec![0.0]);
        for f in 0..5 {
            last = smoother.push(&noisy_disc(80, 80, Vec2::new(40.0, 40.0), 20.0, 2.0, &mut rng), f);
        }
        assert_eq!(smoother.cached(4), Some(&last));
        let again = noisy_disc(80, 80, Vec2::new(40.0, 40.0), 20.0, 2.0, &mut rng);
        assert_eq!(smoother.push(&again, 4), last);
        assert_eq!(smoother.cached(99), None);
    }

    #[test]
    fn reverse_playback_is_smoothed_too() {
        let mut rng = Lcg(5);
        let mut smoother = SubjectMatteSmoother::default();
        let mut out_prev: Option<SubjectMatte> = None;
        let mut worst = 0.0_f64;
        for (n, f) in (0..40).rev().enumerate() {
            let out = smoother.push(&noisy_disc(120, 120, Vec2::new(60.0, 60.0), 30.0, 3.0, &mut rng), f);
            if let Some(op) = &out_prev
                && n >= 8
            {
                worst = worst.max(SubjectMatte::edge_delta(op, &out, 16.0).0);
            }
            out_prev = Some(out);
        }
        assert!(worst < 2.0, "J-K reverse edge delta {worst} px");
    }

    #[test]
    fn out_of_order_frames_find_their_neighbour() {
        let mut rng = Lcg(13);
        let mut smoother = SubjectMatteSmoother::default();
        let mut disc = || noisy_disc(80, 80, Vec2::new(40.0, 40.0), 20.0, 3.0, &mut rng);
        for f in 0..6 {
            smoother.push(&disc(), f);
        }
        let r7 = disc();
        assert_eq!(smoother.push(&r7, 7), r7);
        let r6 = disc();
        assert_ne!(smoother.push(&r6, 6), r6);
        let r8 = disc();
        assert_ne!(smoother.push(&r8, 8), r8);
    }

    #[test]
    fn different_size_resets() {
        let mut smoother = SubjectMatteSmoother::default();
        smoother.push(&SubjectMatte::new(4, 4, vec![1.0; 16]), 0);
        let b = SubjectMatte::new(2, 2, vec![1.0, 0.0, 0.0, 1.0]);
        assert_eq!(smoother.push(&b, 1), b);
    }

    #[test]
    fn edge_delta_measures_a_shift() {
        let mut rng = Lcg(9);
        let a = noisy_disc(100, 100, Vec2::new(50.0, 50.0), 20.0, 0.0, &mut rng);
        let b = noisy_disc(100, 100, Vec2::new(51.5, 50.0), 20.0, 0.0, &mut rng);
        let d = SubjectMatte::edge_delta(&a, &b, 16.0);
        assert!(d.0 > 1.3 && d.0 < 1.7, "{}", d.0);
        assert!(SubjectMatte::edge_delta(&a, &a, 16.0).0 < 1e-9);
    }

    #[test]
    fn matte_channel_values() {
        assert_eq!(MatteChannel::Shape.value(1.0, 0.0, 0.0, 0.5), 0.5);
        assert!((MatteChannel::Brightness.value(1.0, 1.0, 1.0, 1.0) - 1.0).abs() < 1e-12);
        assert_eq!(MatteChannel::Brightness.title(), "Brightness");
        assert!(
            MaskSource::Magic.uses_matte() && !MaskSource::ColorRange.uses_matte() && !MaskSource::Path.uses_matte()
        );
    }
}
