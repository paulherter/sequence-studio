// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectMatteRefiner.swift, SubjectMatteEdges and SubjectMatteEdger (SubjectTrackLeg.swift), SubjectMatteCore.swift
//! The edge step of a tracked subject matte. Quality: the model's mask is turned into soft alpha at the picture's own
//! size by a fast guided filter (He and Sun) with the color picture as guide, acting only in a band around the mask's
//! edge. Speed: the same idea with the gray picture at a quarter of the size. Both are CPU code (Swift runs them on the
//! CPU with Accelerate too), so Mac, Windows and Linux share it.

use sq_core_masks::{SubjectMatte, SubjectTrackRules};

use crate::edge_tamonnx::SubjectFrame;
use crate::subject_mask_quality::SubjectMaskQuality;

/// Settings of the Quality step (Swift `SubjectMatteRefiner.Settings`).
#[derive(Clone, Debug, PartialEq)]
pub struct RefinerSettings {
    /// Long edge of the size the matte is made at.
    pub long_edge: usize,
    /// Long edge of the size the filter's coefficients are solved at.
    pub coefficient_edge: usize,
    /// Box radius at the coefficient size.
    pub radius: usize,
    /// Regularization of the window covariance.
    pub epsilon: f32,
    /// Passes of the filter.
    pub passes: usize,
    /// How fast the band saturates around the mask's edge.
    pub band_gain: f32,
    /// Box radius of the band at the coefficient size.
    pub band_radius: usize,
    /// The full-size step works only inside the band's bounding box.
    pub restrict_to_band: bool,
    /// Box radius of the color step (0: off).
    pub color_radius: usize,
    /// RGB distance the two nearby colors must differ by before the color step is trusted.
    pub color_contrast: f32,
    /// How much of the color step's answer is taken.
    pub color_mix: f32,
    /// The color step only raises alpha.
    pub color_adds_only: bool,
    /// The color step is trusted less off the line between the two colors.
    pub color_on_line: bool,
    /// With `color_adds_only`: alpha is raised only where the guided step gave some.
    pub color_needs_support: bool,
    /// Box radius of the keep step (0: off).
    pub keep_radius: usize,
    /// Distance from the nearby background color at which a pixel counts as something else.
    pub keep_contrast: f32,
}

impl Default for RefinerSettings {
    fn default() -> RefinerSettings {
        RefinerSettings {
            long_edge: 1920,
            coefficient_edge: 480,
            radius: 3,
            epsilon: 1e-4,
            passes: 2,
            band_gain: 3.0,
            band_radius: 5,
            restrict_to_band: true,
            color_radius: 0,
            color_contrast: 0.1,
            color_mix: 1.0,
            color_adds_only: false,
            color_on_line: false,
            color_needs_support: false,
            keep_radius: 10,
            keep_contrast: 0.1,
        }
    }
}

impl RefinerSettings {
    /// The color step for strands (`SQ_SUBJECT_MASK_STRANDS=1`).
    pub fn strands() -> RefinerSettings {
        RefinerSettings {
            color_radius: 10,
            color_adds_only: true,
            color_on_line: true,
            color_needs_support: true,
            ..RefinerSettings::default()
        }
    }

    /// The settings the legs use: strands when `SQ_SUBJECT_MASK_STRANDS=1`.
    pub fn edge_settings() -> RefinerSettings {
        if std::env::var("SQ_SUBJECT_MASK_STRANDS").is_ok_and(|v| v == "1") {
            RefinerSettings::strands()
        } else {
            RefinerSettings::default()
        }
    }
}

/// The guide picture as three planes, 0...1, at the size the matte is made at.
struct Picture {
    width: usize,
    height: usize,
    planes: [Vec<f32>; 3],
}

/// Size a picture of `width` x `height` is worked at.
pub fn work_size(width: usize, height: usize, long_edge: usize) -> (usize, usize) {
    let long = width.max(height);
    if long <= long_edge || long_edge == 0 {
        return (width, height);
    }
    let k = long_edge as f64 / long as f64;
    (((width as f64 * k).round() as usize).max(1), ((height as f64 * k).round() as usize).max(1))
}

impl Picture {
    /// `None`: too small to filter.
    fn load(frame: &SubjectFrame, long_edge: usize) -> Option<Picture> {
        if frame.width < 64 || frame.height < 64 {
            return None;
        }
        let n = frame.width * frame.height;
        let mut planes = [vec![0.0; n], vec![0.0; n], vec![0.0; n]];
        for (i, px) in frame.rgba.as_chunks::<4>().0.iter().enumerate() {
            for c in 0..3 {
                planes[c][i] = f32::from(px[c]) / 255.0;
            }
        }
        let (width, height) = work_size(frame.width, frame.height, long_edge);
        if (width, height) != (frame.width, frame.height) {
            // vImage's 8 bit scale saturates: the ringing of the kernel stays inside 0...1.
            planes = planes.map(|p| {
                let mut p = resample(&p, frame.width, frame.height, width, height);
                p.iter_mut().for_each(|v| *v = v.clamp(0.0, 1.0));
                p
            });
        }
        Some(Picture { width, height, planes })
    }
}

/// Lanczos kernel of radius 3 (what vImage's scale uses without flags: measured on a step edge, see the tests).
fn lanczos3(x: f64) -> f64 {
    if x == 0.0 {
        return 1.0;
    }
    if x.abs() >= 3.0 {
        return 0.0;
    }
    let px = std::f64::consts::PI * x;
    3.0 * px.sin() * (px / 3.0).sin() / (px * px)
}

/// One axis of an antialiased Lanczos-3 resample: per output index the first source index and the weights (the kernel is
/// stretched by the reduction when shrinking, and cut and renormalized at the picture's edge).
fn axis(from: usize, to: usize) -> Vec<(usize, Vec<f32>)> {
    let scale = from as f64 / to as f64;
    let stretch = scale.max(1.0);
    let support = 3.0 * stretch;
    (0..to)
        .map(|o| {
            let center = (o as f64 + 0.5) * scale - 0.5;
            let lo = (center - support).ceil().max(0.0) as usize;
            let hi = ((center + support).floor().max(0.0) as usize).min(from - 1);
            let mut w: Vec<f32> = (lo..=hi).map(|i| lanczos3((i as f64 - center) / stretch) as f32).collect();
            let sum: f32 = w.iter().sum();
            if lo > hi || sum.abs() < 1e-6 {
                let nearest = (center.round().max(0.0) as usize).min(from - 1);
                return (nearest, vec![1.0]);
            }
            w.iter_mut().for_each(|v| *v /= sum);
            (lo, w)
        })
        .collect()
}

/// `values` (`w` x `h`) at `to_w` x `to_h`.
pub fn resample(values: &[f32], w: usize, h: usize, to_w: usize, to_h: usize) -> Vec<f32> {
    if (w, h) == (to_w, to_h) {
        return values.to_vec();
    }
    let (ax, ay) = (axis(w, to_w), axis(h, to_h));
    let mut across = vec![0.0_f32; to_w * h];
    for y in 0..h {
        for (x, (lo, ws)) in ax.iter().enumerate() {
            across[y * to_w + x] = ws.iter().enumerate().map(|(k, wt)| wt * values[y * w + lo + k]).sum();
        }
    }
    let mut out = vec![0.0_f32; to_w * to_h];
    for (y, (lo, ws)) in ay.iter().enumerate() {
        for x in 0..to_w {
            out[y * to_w + x] = ws.iter().enumerate().map(|(k, wt)| wt * across[(lo + k) * to_w + x]).sum();
        }
    }
    out
}

/// Box mean of radius `radius`, edges extended.
pub fn box_mean(values: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let side = (2 * radius + 1) as f32;
    let r = radius as isize;
    let mut across = vec![0.0_f32; w * h];
    for y in 0..h {
        let row = &values[y * w..(y + 1) * w];
        for x in 0..w as isize {
            let sum: f32 = (x - r..=x + r).map(|i| row[i.clamp(0, w as isize - 1) as usize]).sum();
            across[y * w + x as usize] = sum / side;
        }
    }
    let mut out = vec![0.0_f32; w * h];
    for y in 0..h as isize {
        for x in 0..w {
            let sum: f32 = (y - r..=y + r).map(|i| across[i.clamp(0, h as isize - 1) as usize * w + x]).sum();
            out[y as usize * w + x] = sum / side;
        }
    }
    out
}

fn mul(a: &[f32], b: &[f32]) -> Vec<f32> {
    a.iter().zip(b).map(|(x, y)| x * y).collect()
}

fn clip(v: &mut [f32]) {
    v.iter_mut().for_each(|x| *x = x.clamp(0.0, 1.0));
}

fn crop(v: &[f32], vw: usize, (x0, y0, x1, y1): (usize, usize, usize, usize)) -> Vec<f32> {
    (y0..y1).flat_map(|y| v[y * vw + x0..y * vw + x1].iter().copied()).collect()
}

/// Mean subject color (r, g, b) over the pixels plainly inside the mask within `radius`, mean background color over
/// those plainly outside, and how well both were seen: seven planes (Swift `localColors`).
fn local_colors(planes: &[Vec<f32>; 3], near: &[f32], w: usize, h: usize, radius: usize) -> Vec<Vec<f32>> {
    let inside: Vec<f32> = near.iter().map(|v| if *v > 0.99 { 1.0 } else { 0.0 }).collect();
    let outside: Vec<f32> = near.iter().map(|v| if *v < 0.01 { 1.0 } else { 0.0 }).collect();
    let see_in = box_mean(&inside, w, h, radius);
    let see_out = box_mean(&outside, w, h, radius);
    let mut out = Vec::new();
    for (mask, seen) in [(&inside, &see_in), (&outside, &see_out)] {
        for p in planes {
            let mut sum = box_mean(&mul(p, mask), w, h, radius);
            sum.iter_mut().zip(seen.iter()).for_each(|(s, n)| *s = if *n > 1e-4 { *s / n } else { 0.0 });
            out.push(sum);
        }
    }
    out.push(see_in.iter().zip(&see_out).map(|(a, b)| (a.min(*b) * 20.0).min(1.0)).collect());
    out
}

/// Mean background color (3), its spread, how well it was seen, mean subject color (3), how well that was seen: nine
/// planes (Swift `localBackground`).
fn local_background(planes: &[Vec<f32>; 3], near: &[f32], w: usize, h: usize, radius: usize) -> Vec<Vec<f32>> {
    let n = w * h;
    let outside: Vec<f32> = near.iter().map(|v| if *v < 0.01 { 1.0 } else { 0.0 }).collect();
    let inside: Vec<f32> = near.iter().map(|v| if *v > 0.99 { 1.0 } else { 0.0 }).collect();
    let seen = box_mean(&outside, w, h, radius);
    let see_in = box_mean(&inside, w, h, radius);
    let mut out: Vec<Vec<f32>> = Vec::new();
    let mut square = vec![0.0_f32; n];
    for p in planes {
        let masked = mul(p, &outside);
        let mut mean = box_mean(&masked, w, h, radius);
        mean.iter_mut().zip(&seen).for_each(|(m, s)| *m = if *s > 1e-4 { *m / s } else { 0.0 });
        let sq = box_mean(&mul(&masked, p), w, h, radius);
        square.iter_mut().zip(&sq).for_each(|(a, b)| *a += b);
        out.push(mean);
    }
    let mut spread = vec![0.0_f32; n];
    for i in (0..n).filter(|i| seen[*i] > 1e-4) {
        let m2 = out[0][i] * out[0][i] + out[1][i] * out[1][i] + out[2][i] * out[2][i];
        spread[i] = (square[i] / seen[i] - m2).max(0.0).sqrt();
    }
    out.push(spread);
    out.push(seen.iter().map(|s| (s * 20.0).min(1.0)).collect());
    for p in planes {
        let mut mean = box_mean(&mul(p, &inside), w, h, radius);
        mean.iter_mut().zip(&see_in).for_each(|(m, s)| *m = if *s > 1e-4 { *m / s } else { 0.0 });
        out.push(mean);
    }
    out.push(see_in.iter().map(|s| (s * 20.0).min(1.0)).collect());
    out
}

/// The matte at the size the frame is worked at, or `None` when the frame cannot be a guide (the caller keeps the quick
/// step). `matte` may have any size: it is laid over the whole picture.
pub fn refine(matte: &SubjectMatte, frame: &SubjectFrame, settings: &RefinerSettings) -> Option<SubjectMatte> {
    let picture = Picture::load(frame, settings.long_edge)?;
    Some(refine_picture(matte, &picture, settings))
}

fn refine_picture(matte: &SubjectMatte, picture: &Picture, s: &RefinerSettings) -> SubjectMatte {
    let (w, h) = (picture.width, picture.height);
    let k = ((w.max(h) as f64 / s.coefficient_edge.max(1) as f64).round() as usize).max(1);
    let (lw, lh) = ((w / k).max(1), (h / k).max(1));
    let n = lw * lh;
    let mut full_mask = resample(&matte.values, matte.width(), matte.height(), w, h);
    clip(&mut full_mask);
    if lw < 16 || lh < 16 {
        return SubjectMatte::new(w, h, full_mask);
    }
    let mut mask = resample(&matte.values, matte.width(), matte.height(), lw, lh);
    clip(&mut mask);
    let planes = picture.planes.each_ref().map(|p| resample(p, w, h, lw, lh));
    let radius = s.radius.max(1);
    let means = planes.each_ref().map(|p| box_mean(p, lw, lh, radius));

    // The band: 1 around the mask's edge, 0 where the mask is plainly in or out within the band's reach.
    let near = box_mean(&mask, lw, lh, s.band_radius.max(1));
    let band: Vec<f32> = near.iter().map(|v| (4.0 * s.band_gain * v * (1.0 - v)).clamp(0.0, 1.0)).collect();
    let colors = (s.color_radius > 0).then(|| local_colors(&planes, &near, lw, lh, s.color_radius));
    let background = (s.keep_radius > 0).then(|| local_background(&planes, &near, lw, lh, s.keep_radius));

    // Inverse of the picture's covariance (+ epsilon) per window: the same for every pass.
    let mut cov: Vec<Vec<f32>> = Vec::new();
    for (a, b) in [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)] {
        let mut c = box_mean(&mul(&planes[a], &planes[b]), lw, lh, radius);
        c.iter_mut().zip(mul(&means[a], &means[b])).for_each(|(c, m)| *c -= m);
        cov.push(c);
    }
    let mut inverse = vec![vec![0.0_f32; n]; 6];
    let e = s.epsilon;
    for i in 0..n {
        let (rr, rg, rb) = (cov[0][i] + e, cov[1][i], cov[2][i]);
        let (gg, gb, bb) = (cov[3][i] + e, cov[4][i], cov[5][i] + e);
        let (c0, c1, c2) = (gg * bb - gb * gb, rb * gb - rg * bb, rg * gb - rb * gg);
        let det = rr * c0 + rg * c1 + rb * c2;
        let d = if det.abs() > 1e-20 { 1.0 / det } else { 0.0 };
        inverse[0][i] = c0 * d;
        inverse[1][i] = c1 * d;
        inverse[2][i] = c2 * d;
        inverse[3][i] = (rr * bb - rb * rb) * d;
        inverse[4][i] = (rb * rg - rr * gb) * d;
        inverse[5][i] = (rr * gg - rg * rg) * d;
    }

    let mut input = mask.clone();
    let mut a = vec![vec![0.0_f32; n]; 3];
    let mut b = vec![0.0_f32; n];
    let passes = s.passes.max(1);
    for pass in 0..passes {
        let mean_input = box_mean(&input, lw, lh, radius);
        let cross: Vec<Vec<f32>> = (0..3)
            .map(|c| {
                let mut x = box_mean(&mul(&planes[c], &input), lw, lh, radius);
                x.iter_mut().zip(mul(&means[c], &mean_input)).for_each(|(x, m)| *x -= m);
                x
            })
            .collect();
        for i in 0..n {
            let (x, y, z) = (cross[0][i], cross[1][i], cross[2][i]);
            let ar = inverse[0][i] * x + inverse[1][i] * y + inverse[2][i] * z;
            let ag = inverse[1][i] * x + inverse[3][i] * y + inverse[4][i] * z;
            let ab = inverse[2][i] * x + inverse[4][i] * y + inverse[5][i] * z;
            a[0][i] = ar;
            a[1][i] = ag;
            a[2][i] = ab;
            b[i] = mean_input[i] - ar * means[0][i] - ag * means[1][i] - ab * means[2][i];
        }
        for plane in a.iter_mut() {
            *plane = box_mean(plane, lw, lh, radius);
        }
        b = box_mean(&b, lw, lh, radius);
        if pass + 1 >= passes {
            break;
        }
        // The next pass starts from this one's answer inside the band and from the mask outside it.
        for i in 0..n {
            let q = (a[0][i] * planes[0][i] + a[1][i] * planes[1][i] + a[2][i] * planes[2][i] + b[i]).clamp(0.0, 1.0);
            input[i] = mask[i] + band[i] * (q - mask[i]);
        }
    }

    // Applied to the full-size picture, inside the band's bounding box: outside it the matte is the model's mask.
    let (mut lx0, mut ly0, mut lx1, mut ly1) = (0, 0, lw, lh);
    if s.restrict_to_band {
        (lx0, ly0, lx1, ly1) = (lw, lh, 0, 0);
        for y in 0..lh {
            for x in (0..lw).filter(|x| band[y * lw + x] > 0.02) {
                lx0 = lx0.min(x);
                lx1 = lx1.max(x + 1);
                ly0 = ly0.min(y);
                ly1 = ly1.max(y + 1);
            }
        }
        // One coefficient pixel of margin for the resampling's reach.
        (lx0, ly0, lx1, ly1) = (lx0.saturating_sub(1), ly0.saturating_sub(1), (lx1 + 1).min(lw), (ly1 + 1).min(lh));
        if lx1 <= lx0 || ly1 <= ly0 {
            return SubjectMatte::new(w, h, full_mask);
        }
    }
    let (fx0, fy0) = (lx0 * w / lw, ly0 * h / lh);
    let fx1 = if lx1 == lw { w } else { lx1 * w / lw };
    let fy1 = if ly1 == lh { h } else { ly1 * h / lh };
    let (cw, ch) = (fx1 - fx0, fy1 - fy0);
    let whole = cw == w && ch == h;
    let resized = |v: &[f32]| resample(&crop(v, lw, (lx0, ly0, lx1, ly1)), lx1 - lx0, ly1 - ly0, cw, ch);
    let crops: Vec<Vec<f32>> = picture.planes.iter().map(|p| crop(p, w, (fx0, fy0, fx1, fy1))).collect();
    let base = crop(&full_mask, w, (fx0, fy0, fx1, fy1));

    let mut fine = resized(&b);
    for c in 0..3 {
        let tmp = resized(&a[c]);
        fine.iter_mut().zip(tmp.iter().zip(&crops[c])).for_each(|(f, (t, p))| *f += t * p);
    }
    clip(&mut fine);
    let mut weight = resized(&band);
    clip(&mut weight);
    fine.iter_mut().zip(base.iter().zip(&weight)).for_each(|(f, (b, w))| *f = (*f - b) * w + b);

    if let Some(colors) = colors {
        // Each band pixel's color projected on the line from the nearby background color to the nearby subject color.
        let local: Vec<Vec<f32>> = colors.iter().map(|c| resized(c)).collect();
        let low = s.color_contrast;
        for i in 0..cw * ch {
            let wgt = (weight[i] * local[6][i].clamp(0.0, 1.0)).min(1.0);
            if wgt <= 0.01 {
                continue;
            }
            let (dr, dg, db) = (local[0][i] - local[3][i], local[1][i] - local[4][i], local[2][i] - local[5][i]);
            let d2 = dr * dr + dg * dg + db * db;
            let trust = ((d2.sqrt() - low) / low).clamp(0.0, 1.0);
            if trust <= 0.0 {
                continue;
            }
            let (er, eg, eb) = (crops[0][i] - local[3][i], crops[1][i] - local[4][i], crops[2][i] - local[5][i]);
            let p = (er * dr + eg * dg + eb * db) / d2;
            let mut t = trust;
            if s.color_on_line {
                let (ox, oy, oz) = (er - p * dr, eg - p * dg, eb - p * db);
                t *= (1.0 - (ox * ox + oy * oy + oz * oz).sqrt() / (0.5 * d2.sqrt())).clamp(0.0, 1.0);
            }
            let target = p.clamp(0.0, 1.0);
            if s.color_adds_only {
                if target <= fine[i] {
                    continue;
                }
                if s.color_needs_support {
                    t *= (fine[i] * 5.0).min(1.0);
                }
            }
            fine[i] += s.color_mix * wgt * t * (target - fine[i]);
        }
    }
    if let Some(background) = background {
        // Alpha the filter took from a pixel the model is sure of, whose color is not the nearby background, is given back.
        let local: Vec<Vec<f32>> = background.iter().map(|c| resized(c)).collect();
        for i in 0..cw * ch {
            if fine[i] >= base[i] || base[i] <= 0.5 {
                continue;
            }
            let sure = ((base[i] - 0.5) / 0.4).min(1.0);
            let seen = local[4][i].clamp(0.0, 1.0);
            if sure * seen <= 0.01 {
                continue;
            }
            let (er, eg, eb) = (crops[0][i] - local[0][i], crops[1][i] - local[1][i], crops[2][i] - local[2][i]);
            let low = s.keep_contrast.max(2.0 * local[3][i].max(0.0));
            let to_background = (er * er + eg * eg + eb * eb).sqrt();
            let mut distance = to_background;
            let inside = local[8][i].clamp(0.0, 1.0);
            if inside > 0.01 {
                let (dr, dg, db) = (local[5][i] - local[0][i], local[6][i] - local[1][i], local[7][i] - local[2][i]);
                let d2 = (dr * dr + dg * dg + db * db).max(1e-6);
                let p = ((er * dr + eg * dg + eb * db) / d2).clamp(0.0, 1.0);
                let (ox, oy, oz) = (er - p * dr, eg - p * dg, eb - p * db);
                distance = inside * (ox * ox + oy * oy + oz * oz).sqrt() + (1.0 - inside) * to_background;
            }
            let other = ((distance - low) / low).clamp(0.0, 1.0);
            fine[i] += sure * seen * other * (base[i] - fine[i]);
        }
    }
    if whole {
        return SubjectMatte::new(w, h, fine);
    }
    let mut out = full_mask;
    for y in 0..ch {
        out[(fy0 + y) * w + fx0..(fy0 + y) * w + fx0 + cw].copy_from_slice(&fine[y * cw..(y + 1) * cw]);
    }
    SubjectMatte::new(w, h, out)
}

/// Quick edge step (Swift `SubjectMatteEdges.refine`): a guided filter with the green channel as guide at a quarter of
/// the size, applied in the band around the matte's edge. The frame must have the matte's size.
pub fn quick_refine(matte: &SubjectMatte, frame: &SubjectFrame) -> SubjectMatte {
    const SCALE: usize = 4;
    const RADIUS: usize = 2;
    const EPSILON: f32 = 0.001;
    let (w, h) = (matte.width(), matte.height());
    if (frame.width, frame.height) != (w, h) || w < 16 * SCALE || h < 16 * SCALE {
        return matte.clone();
    }
    // Green as luma: close enough for edges, one channel to read.
    let gray: Vec<f32> = frame.rgba.as_chunks::<4>().0.iter().map(|px| f32::from(px[1]) / 255.0).collect();
    let (lw, lh) = (w / SCALE, h / SCALE);
    let guide = resample(&gray, w, h, lw, lh);
    let mask = resample(&matte.values, w, h, lw, lh);
    let mean_guide = box_mean(&guide, lw, lh, RADIUS);
    let mean_mask = box_mean(&mask, lw, lh, RADIUS);
    let mean_both = box_mean(&mul(&guide, &mask), lw, lh, RADIUS);
    let mean_square = box_mean(&mul(&guide, &guide), lw, lh, RADIUS);
    let n = lw * lh;
    let (mut a, mut b) = (vec![0.0_f32; n], vec![0.0_f32; n]);
    for i in 0..n {
        let variance = mean_square[i] - mean_guide[i] * mean_guide[i];
        a[i] = (mean_both[i] - mean_guide[i] * mean_mask[i]) / (variance.max(0.0) + EPSILON);
        b[i] = mean_mask[i] - a[i] * mean_guide[i];
    }
    let full_a = resample(&box_mean(&a, lw, lh, RADIUS), lw, lh, w, h);
    let full_b = resample(&box_mean(&b, lw, lh, RADIUS), lw, lh, w, h);
    let near = resample(&mean_mask, lw, lh, w, h);
    let mut out = matte.values.clone();
    for i in 0..w * h {
        // 1 on the edge, 0 where the matte is plainly in or out within the filter's reach.
        let band = (4.0 * near[i] * (1.0 - near[i])).clamp(0.0, 1.0);
        if band > 0.01 {
            let filtered = (full_a[i] * gray[i] + full_b[i]).clamp(0.0, 1.0);
            out[i] += band * (filtered - out[i]);
        }
    }
    SubjectMatte::new(w, h, out)
}

/// The inside of a mask is solid (Swift `SubjectMatteCore.solid`): `matte` with alpha 1 wherever `mask` (the matte
/// before its edge step; `None`: the matte itself) is at least 0.5 within one logit cell of the contour.
// The erosion extends the picture edge: measured on the Mac, `vImageMin_Planar8` with no flag leaves a solid picture solid
// up to its border (a matte that touches the border stays solid there). The size change is the Lanczos `resample`.
pub fn solid(matte: &SubjectMatte, mask: Option<&SubjectMatte>) -> SubjectMatte {
    let src = mask.unwrap_or(matte);
    let (w, h) = (src.width(), src.height());
    let r = ((w.max(h) as f64 / SubjectTrackRules::LOGIT_SIZE as f64).round() as usize).max(2);
    let inside: Vec<f32> = src.values.iter().map(|v| if *v >= 0.5 { 1.0 } else { 0.0 }).collect();
    // Minimum over a (2r+1) square, as two passes.
    let min_pass = |v: &[f32], horizontal: bool| -> Vec<f32> {
        let mut out = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                out[y * w + x] = (-(r as isize)..=r as isize)
                    .map(|d| {
                        let (xx, yy) =
                            if horizontal { (x as isize + d, y as isize) } else { (x as isize, y as isize + d) };
                        v[yy.clamp(0, h as isize - 1) as usize * w + xx.clamp(0, w as isize - 1) as usize]
                    })
                    .fold(1.0, f32::min);
            }
        }
        out
    };
    let core = min_pass(&min_pass(&inside, true), false);
    let core = resample(&core, w, h, matte.width(), matte.height());
    let values = core.iter().zip(&matte.values).map(|(c, v)| c.max(*v)).collect();
    SubjectMatte::new(matte.width(), matte.height(), values)
}

/// The edge step of a leg's mattes (Swift `SubjectMatteEdger`).
#[derive(Clone, Debug)]
pub struct SubjectMatteEdger {
    /// `SQ_SUBJECT_MASK_EDGES=0` switches the step off.
    pub refines: bool,
    /// Quality uses the guided filter at the picture's size, Speed the quick step.
    pub quality: SubjectMaskQuality,
    settings: RefinerSettings,
}

impl SubjectMatteEdger {
    /// An edger for a run with `quality`; reads the environment switches once.
    pub fn new(quality: SubjectMaskQuality) -> SubjectMatteEdger {
        SubjectMatteEdger {
            refines: std::env::var("SQ_SUBJECT_MASK_EDGES").map_or(true, |v| v != "0"),
            quality,
            settings: RefinerSettings::edge_settings(),
        }
    }

    /// `matte` with its edge taken from `frame`, the inside solid.
    pub fn edged(&self, matte: SubjectMatte, frame: &SubjectFrame) -> SubjectMatte {
        if !self.refines {
            return matte;
        }
        if self.quality == SubjectMaskQuality::Quality
            && let Some(fine) = refine(&matte, frame, &self.settings)
        {
            return solid(&fine, Some(&matte));
        }
        solid(&quick_refine(&matte, frame), Some(&matte))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const N: usize = 64;

    /// Subject on the left of `edge`; the picture's own soft edge sits at `ramp` .. `ramp + 8`.
    fn scene(edge: usize, ramp: usize) -> (SubjectMatte, SubjectFrame) {
        let mut matte = vec![0.0_f32; N * N];
        let mut rgba = vec![255_u8; N * N * 4];
        for y in 0..N {
            for x in 0..N {
                matte[y * N + x] = if x < edge { 1.0 } else { 0.0 };
                let t = ((x as f32 - ramp as f32) / 8.0).clamp(0.0, 1.0);
                let v = (230.0 - 200.0 * t) as u8;
                // A little color so the covariance is not singular.
                rgba[(y * N + x) * 4..(y * N + x) * 4 + 3].copy_from_slice(&[v, v.saturating_sub(20), v / 2 + 10]);
            }
        }
        (SubjectMatte::new(N, N, matte), SubjectFrame::new(N, N, rgba))
    }

    /// The guided filter written as one window loop per pixel, one pass, no band box, no color or keep step.
    fn naive(matte: &SubjectMatte, frame: &SubjectFrame, s: &RefinerSettings) -> Vec<f32> {
        let px = |x: isize, y: isize, c: usize| {
            let i = y.clamp(0, N as isize - 1) as usize * N + x.clamp(0, N as isize - 1) as usize;
            f32::from(frame.rgba[i * 4 + c]) / 255.0
        };
        let p = |x: isize, y: isize| {
            matte.values[y.clamp(0, N as isize - 1) as usize * N + x.clamp(0, N as isize - 1) as usize]
        };
        let r = s.radius as isize;
        let count = ((2 * r + 1) * (2 * r + 1)) as f32;
        let window = |x: isize, y: isize| (y - r..=y + r).flat_map(move |yy| (x - r..=x + r).map(move |xx| (xx, yy)));
        let coeffs = |x: isize, y: isize| {
            let mut mean = [0.0_f32; 3];
            let mut mp = 0.0;
            let mut ip = [0.0_f32; 3];
            let mut ii = [[0.0_f32; 3]; 3];
            for (xx, yy) in window(x, y) {
                let v = [px(xx, yy, 0), px(xx, yy, 1), px(xx, yy, 2)];
                for a in 0..3 {
                    mean[a] += v[a];
                    ip[a] += v[a] * p(xx, yy);
                    for b in 0..3 {
                        ii[a][b] += v[a] * v[b];
                    }
                }
                mp += p(xx, yy);
            }
            mean.iter_mut().for_each(|m| *m /= count);
            mp /= count;
            let cov = |a: usize, b: usize| ii[a][b] / count - mean[a] * mean[b] + if a == b { s.epsilon } else { 0.0 };
            let (rr, rg, rb, gg, gb, bb) = (cov(0, 0), cov(0, 1), cov(0, 2), cov(1, 1), cov(1, 2), cov(2, 2));
            let det = rr * (gg * bb - gb * gb) - rg * (rg * bb - gb * rb) + rb * (rg * gb - gg * rb);
            let cross = [ip[0] / count - mean[0] * mp, ip[1] / count - mean[1] * mp, ip[2] / count - mean[2] * mp];
            let a0 = (cross[0] * (gg * bb - gb * gb) - rg * (cross[1] * bb - gb * cross[2])
                + rb * (cross[1] * gb - gg * cross[2]))
                / det;
            let a1 = (rr * (cross[1] * bb - gb * cross[2]) - cross[0] * (rg * bb - gb * rb)
                + rb * (rg * cross[2] - cross[1] * rb))
                / det;
            let a2 = (rr * (gg * cross[2] - cross[1] * gb) - rg * (rg * cross[2] - cross[1] * rb)
                + cross[0] * (rg * gb - gg * rb))
                / det;
            (a0, a1, a2, mp - a0 * mean[0] - a1 * mean[1] - a2 * mean[2])
        };
        let mut out = vec![0.0_f32; N * N];
        for y in 0..N as isize {
            for x in 0..N as isize {
                let (mut a0, mut a1, mut a2, mut b) = (0.0, 0.0, 0.0, 0.0);
                for (xx, yy) in window(x, y) {
                    let (c0, c1, c2, cb) = coeffs(xx.clamp(0, N as isize - 1), yy.clamp(0, N as isize - 1));
                    a0 += c0;
                    a1 += c1;
                    a2 += c2;
                    b += cb;
                }
                let fine = ((a0 * px(x, y, 0) + a1 * px(x, y, 1) + a2 * px(x, y, 2) + b) / count).clamp(0.0, 1.0);
                out[y as usize * N + x as usize] = fine;
            }
        }
        out
    }

    #[test]
    fn the_guided_filter_matches_a_window_by_window_computation() {
        let (matte, frame) = scene(30, 33);
        let s = RefinerSettings { passes: 1, restrict_to_band: false, keep_radius: 0, ..RefinerSettings::default() };
        let fast = refine(&matte, &frame, &s).expect("64 px frame is large enough");
        let reference = naive(&matte, &frame, &s);
        // Coefficient size is the picture size here (long edge 64 < 480), so nothing is resampled.
        let near = box_mean(&matte.values, N, N, s.band_radius);
        for i in 0..N * N {
            let band = (4.0 * s.band_gain * near[i] * (1.0 - near[i])).clamp(0.0, 1.0);
            let expected = matte.values[i] + band * (reference[i] - matte.values[i]);
            assert!((fast.values[i] - expected).abs() < 2e-3, "pixel {i}: {} vs {expected}", fast.values[i]);
        }
    }

    #[test]
    fn a_hard_matte_takes_the_pictures_soft_edge_and_keeps_inside_and_outside() {
        let (matte, frame) = scene(30, 33);
        let fine = refine(&matte, &frame, &RefinerSettings::default()).expect("refined");
        assert_eq!((fine.width(), fine.height()), (N, N));
        let row = 32 * N;
        assert!(fine.values[row + 5] > 0.99, "inside stays");
        assert!(fine.values[row + 60] < 0.01, "outside stays");
        // The picture's ramp lies right of the hard edge: the matte follows it, soft and falling.
        let ramp: Vec<f32> = (30..42).map(|x| fine.values[row + x]).collect();
        assert!(ramp.iter().any(|v| *v > 0.05 && *v < 0.95), "soft alpha at the edge: {ramp:?}");
        assert!(ramp.windows(2).all(|w| w[1] <= w[0] + 0.02), "falls from the subject to the background: {ramp:?}");
    }

    #[test]
    fn a_frame_below_64_px_is_no_guide() {
        let small = SubjectFrame::new(32, 32, vec![0; 32 * 32 * 4]);
        assert!(refine(&SubjectMatte::new(8, 8, vec![0.0; 64]), &small, &RefinerSettings::default()).is_none());
    }

    #[test]
    fn work_size_scales_the_long_edge_down_only() {
        assert_eq!(work_size(3840, 2160, 1920), (1920, 1080));
        assert_eq!(work_size(1280, 720, 1920), (1280, 720));
        assert_eq!(work_size(1000, 3000, 1500), (500, 1500));
    }

    fn close(got: &[f32], want: &[f32], tol: f32) {
        assert_eq!(got.len(), want.len());
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            assert!((g - w).abs() <= tol, "at {i}: {g} vs {w} (all {got:?})");
        }
    }

    /// Numbers measured on the Mac with `vImageScale_PlanarF` and no flags (a step edge, one row).
    #[test]
    fn resample_matches_vimages_lanczos_on_a_step_edge() {
        let up: Vec<f32> = (0..8).map(|x| if x >= 4 { 1.0 } else { 0.0 }).collect();
        let want_up =
            [0.0, 0.0, 0.0, 0.007, 0.030, -0.061, -0.103, 0.210, 0.790, 1.103, 1.061, 0.970, 0.993, 1.0, 1.0, 1.0];
        close(&resample(&up, 8, 1, 16, 1), &want_up, 0.02);
        let down: Vec<f32> = (0..16).map(|x| if x >= 8 { 1.0 } else { 0.0 }).collect();
        close(&resample(&down, 16, 1, 8, 1), &[0.0, 0.004, -0.015, 0.054, 0.946, 1.015, 0.996, 1.0], 0.02);
    }

    #[test]
    fn a_matte_that_touches_the_border_stays_solid_there() {
        let n = 64;
        let matte = SubjectMatte::new(n, n, vec![1.0; n * n]);
        let out = solid(&matte, None);
        assert!(out.values.iter().all(|v| *v > 0.999), "the erosion does not eat the picture edge");
    }

    #[test]
    fn resample_keeps_a_constant_and_the_box_mean_of_a_constant() {
        let flat = vec![0.25_f32; 40 * 30];
        assert!(resample(&flat, 40, 30, 17, 11).iter().all(|v| (v - 0.25).abs() < 1e-5));
        assert!(resample(&flat, 40, 30, 90, 70).iter().all(|v| (v - 0.25).abs() < 1e-5));
        assert!(box_mean(&flat, 40, 30, 3).iter().all(|v| (v - 0.25).abs() < 1e-6));
    }

    #[test]
    fn quick_refine_needs_a_frame_of_the_mattes_size() {
        let (matte, frame) = scene(30, 33);
        let other = SubjectFrame::new(32, 32, vec![0; 32 * 32 * 4]);
        assert_eq!(quick_refine(&matte, &other), matte);
        let fine = quick_refine(&matte, &frame);
        let row = 32 * N;
        assert!(fine.values[row + 4] > 0.99 && fine.values[row + 60] < 0.01);
        assert!(fine.values.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    #[test]
    fn quick_refine_pulls_the_edge_onto_the_pictures_edge() {
        let (matte, frame) = scene(30, 33);
        let fine = quick_refine(&matte, &frame);
        let moved: f32 = fine.values.iter().zip(&matte.values).map(|(a, b)| (a - b).abs()).sum();
        assert!(moved > 1.0, "the band around the edge changed: {moved}");
        // Away from the edge band nothing changes.
        assert_eq!(fine.values[32 * N + 2], 1.0);
    }

    #[test]
    fn solid_gives_the_inside_back_and_leaves_the_edge_soft() {
        let mut values = vec![0.0_f32; N * N];
        for y in 0..N {
            for x in 0..40 {
                values[y * N + x] = if x < 20 { 0.6 } else { 0.8 - 0.02 * (x - 20) as f32 };
            }
        }
        let mask = SubjectMatte::new(N, N, (0..N * N).map(|i| if i % N < 30 { 1.0 } else { 0.0 }).collect());
        let out = solid(&SubjectMatte::new(N, N, values), Some(&mask));
        // Band: max(2, round(64 / 256)) = 2 px, so the core is x in 2 ..= 27 (the border extends).
        assert_eq!(out.values[32 * N + 10], 1.0, "inside solid");
        assert_eq!(out.values[32 * N + 29], 0.8 - 0.02 * 9.0, "edge untouched: {}", out.values[32 * N + 29]);
        assert_eq!(out.values[32 * N + 50], 0.0);
    }

    #[test]
    fn the_edger_follows_quality_and_the_off_switch() {
        let (matte, frame) = scene(30, 33);
        let quality = SubjectMatteEdger::new(SubjectMaskQuality::Quality).edged(matte.clone(), &frame);
        let speed = SubjectMatteEdger::new(SubjectMaskQuality::Speed).edged(matte.clone(), &frame);
        assert_ne!(quality, speed);
        let mut off = SubjectMatteEdger::new(SubjectMaskQuality::Quality);
        off.refines = false;
        assert_eq!(off.edged(matte.clone(), &frame), matte);
    }
}
