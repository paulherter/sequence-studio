// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizationCheck.swift
//! The stabilizer's second opinion. Next to Vision's registration every frame pair is also registered photometrically: a
//! robust pyramidal Lucas-Kanade fit of a similarity on a small gray picture (long side 256), started at "no motion", so it
//! does not inherit Vision's mistakes. It gives
//!   - the check motion (`StabilizationAnalysis::checks`, the plan's never-worse guard),
//!   - a texture score (smallest eigenvalue of the gradient structure tensor: a blank wall has none),
//!   - the confidence of Vision's motion (agreement of the two, texture),
//!   - the cut scores: gray residual left after the alignment, and a quadrant histogram distance.
//!
//! Pure CPU on ~37k pixels per frame (well under a millisecond per level), no allocations per iteration.
use crate::registration_math::Registration;
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_time::Vec2;

/// A gray picture (0...255), row-major.
#[derive(Clone, Debug, PartialEq)]
pub struct GrayFrame {
    /// Width in px.
    pub width: usize,
    /// Height in px.
    pub height: usize,
    /// The gray levels.
    pub pixels: Vec<f32>,
}

impl GrayFrame {
    /// A picture over `pixels` (`width * height` of them).
    pub fn new(width: usize, height: usize, pixels: Vec<f32>) -> GrayFrame {
        GrayFrame { width, height, pixels }
    }

    /// Half size (2x2 mean); `None` when the result would be under 8 px on a side.
    pub fn halved(&self) -> Option<GrayFrame> {
        let (w, h) = (self.width / 2, self.height / 2);
        if w < 8 || h < 8 {
            return None;
        }
        let p = &self.pixels;
        let mut out = vec![0.0_f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let i = 2 * y * self.width + 2 * x;
                out[y * w + x] = (p[i] + p[i + 1] + p[i + self.width] + p[i + self.width + 1]) * 0.25;
            }
        }
        Some(GrayFrame { width: w, height: h, pixels: out })
    }

    /// Finest first: self, half, quarter, ... while the long side stays >= 24.
    pub fn pyramid(&self, levels: usize) -> Vec<GrayFrame> {
        let mut out = vec![self.clone()];
        while out.len() < levels {
            let Some(h) = out[out.len() - 1].halved() else { break };
            if h.width.max(h.height) < 24 {
                break;
            }
            out.push(h);
        }
        out
    }

    /// 16-bin luma histogram per quadrant, each normalized to 1.
    pub fn quadrant_histograms(&self) -> Vec<f32> {
        let mut hist = vec![0.0_f32; 64];
        let (hw, hh) = (self.width / 2, self.height / 2);
        for y in 0..self.height {
            for x in 0..self.width {
                let q = (if y < hh { 0 } else { 2 }) + (if x < hw { 0 } else { 1 });
                let b = ((self.pixels[y * self.width + x] / 16.0) as i64).clamp(0, 15) as usize;
                hist[q * 16 + b] += 1.0;
            }
        }
        for q in 0..4 {
            let n: f32 = hist[q * 16..q * 16 + 16].iter().sum();
            if n > 0.0 {
                for b in 0..16 {
                    hist[q * 16 + b] /= n;
                }
            }
        }
        hist
    }

    /// Mean over the quadrants of half the L1 distance of two `quadrant_histograms` (0 = equal, 1 = disjoint).
    pub fn histogram_distance(a: &[f32], b: &[f32]) -> f64 {
        if a.len() != b.len() || a.is_empty() {
            return 0.0;
        }
        let mut s = 0.0_f32;
        for i in 0..a.len() {
            s += (a[i] - b[i]).abs();
        }
        f64::from(s) / 2.0 / 4.0
    }
}

/// The photometric registration of one pair.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhotometricMotion {
    /// Content motion previous -> current in px of the finest gray level (center origin, y down, degrees clockwise).
    pub motion: CameraMotion,
    /// Mean |gray difference| left after the alignment (0...255).
    pub residual: f64,
    /// Smallest eigenvalue of the mean gradient structure tensor (gray levels^2 per px^2) of the finest level.
    pub texture: f64,
    /// The fit converged inside the picture and enough grid cells agree on it.
    pub converged: bool,
    /// Share of the textured grid cells whose own shift agrees with the fitted motion (0...1).
    pub coherence: f64,
}

/// The fit quality at one step.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fit {
    /// Mean |gray difference|.
    pub residual: f64,
    /// Smallest eigenvalue of the structure tensor.
    pub texture: f64,
    /// Share of the grid positions that landed inside the picture.
    pub valid: f64,
}

/// Parameter change of one step: tx, ty, a, b.
pub type StepDelta = (f64, f64, f64, f64);

/// Pixel region x0..<x1, y0..<y1 of a step.
pub type Region = (usize, usize, usize, usize);

/// Photometric registration of frame pairs.
pub struct PhotometricRegistration;

impl PhotometricRegistration {
    /// Below this texture (`PhotometricMotion::texture`) neither registration is trusted: a blank wall, a black frame.
    /// Measured 2026-10-04 at 256 px (EngineBench stabilize, SQ_STAB_PROBE): hand-held iPhone shots 13-45, Sony shots with
    /// blurred backgrounds 3.5-36; a blank frame ~0.
    pub const MIN_TEXTURE: f64 = 4.0;
    /// Huber limit of the robust fit, gray levels: larger differences (a moving subject) count less.
    pub const HUBER: f32 = 12.0;
    /// Columns of the cell grid.
    pub const CELL_COLUMNS: usize = 6;
    /// Rows of the cell grid.
    pub const CELL_ROWS: usize = 4;
    /// Fewest agreeing cells for a check.
    pub const MIN_COHERENT_CELLS: usize = 6;
    /// Vision and the check agree within this, px per 512 px of the long side: full confidence ...
    pub const FULL_AGREEMENT: f64 = 1.0;
    /// ... at this disagreement none. Measured 2026-10-04 (EngineBench stabilize "check" line). Sony shots with a moving
    /// subject: median 0.3-1.3, p75 0.8-2.8; iPhone shots median 0.3-0.4.
    pub const FULL_DISAGREEMENT: f64 = 3.0;

    /// Registers `current` against `previous` (same size): q = [1+a -b; b 1+a] p + t on the pyramid, coarse to fine
    /// (`levels`: 4 in Swift).
    pub fn register(previous: &GrayFrame, current: &GrayFrame, levels: usize) -> Option<PhotometricMotion> {
        if previous.width != current.width || previous.height != current.height {
            return None;
        }
        let pp = previous.pyramid(levels);
        let cp = current.pyramid(levels);
        if pp.len() != cp.len() {
            return None;
        }
        let (mut tx, mut ty, mut a, mut b) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
        for level in (0..pp.len()).rev() {
            if level < pp.len() - 1 {
                tx *= 2.0;
                ty *= 2.0;
            }
            let stride = if level == 0 { 2 } else { 1 };
            for _ in 0..(if level == 0 { 6 } else { 10 }) {
                let (d, _) = Self::step(&pp[level], &cp[level], tx, ty, a, b, stride, None, false)?;
                tx += d.0;
                ty += d.1;
                a += d.2;
                b += d.3;
                if d.0.abs() < 0.005 && d.1.abs() < 0.005 && d.2.abs() < 1e-5 && d.3.abs() < 1e-5 {
                    break;
                }
            }
        }
        // Flow coherence: each grid cell refines its own shift from the global fit; a robust similarity through the cells
        // that agree replaces the global fit (a moving subject or a flat sky pulls one cell, not the camera motion).
        let cells = Self::cell_fit(&pp[0], &cp[0], tx, ty, a, b);
        let mut coherence = 0.0;
        if let Some((motion, c)) = &cells {
            coherence = *c;
            let r = motion.rotation * std::f64::consts::PI / 180.0;
            a = motion.scale * r.cos() - 1.0;
            b = motion.scale * r.sin();
            tx = motion.dx;
            ty = motion.dy;
        }
        let last = Self::measure(&pp[0], &cp[0], tx, ty, a, b)?;
        let s = ((1.0 + a) * (1.0 + a) + b * b).sqrt();
        if !(s.is_finite() && s > 0.0 && tx.is_finite() && ty.is_finite()) {
            return None;
        }
        let m = CameraMotion::new(tx, ty, b.atan2(1.0 + a) * 180.0 / std::f64::consts::PI, s);
        let w = previous.width as f64;
        let h = previous.height as f64;
        let converged = cells.is_some()
            && last.valid > 0.5
            && tx.abs() < w / 3.0
            && ty.abs() < h / 3.0
            && m.rotation.abs() < 15.0
            && s > 0.8
            && s < 1.25;
        Some(PhotometricMotion { motion: m, residual: last.residual, texture: last.texture, converged, coherence })
    }

    /// Refines the shift of each grid cell (translation only, started at the global fit) and fits a similarity through the
    /// cell centers, dropping cells that disagree (residual > max(0.3 px, 2.5 x median), twice). `None` when fewer than
    /// `MIN_COHERENT_CELLS` textured cells agree. Coherence = agreeing share of the textured cells.
    fn cell_fit(prev: &GrayFrame, cur: &GrayFrame, tx: f64, ty: f64, a: f64, b: f64) -> Option<(CameraMotion, f64)> {
        let (w, h) = (cur.width, cur.height);
        let cx = (w - 1) as f64 / 2.0;
        let cy = (h - 1) as f64 / 2.0;
        let mut src: Vec<Vec2> = Vec::new();
        let mut dst: Vec<Vec2> = Vec::new();
        for row in 0..Self::CELL_ROWS {
            for col in 0..Self::CELL_COLUMNS {
                let x0 = col * w / Self::CELL_COLUMNS;
                let x1 = (col + 1) * w / Self::CELL_COLUMNS;
                let y0 = row * h / Self::CELL_ROWS;
                let y1 = (row + 1) * h / Self::CELL_ROWS;
                let (mut ctx, mut cty, mut ok, mut textured) = (tx, ty, false, false);
                for _ in 0..8 {
                    let Some((d, fit)) = Self::step(prev, cur, ctx, cty, a, b, 1, Some((x0, x1, y0, y1)), true) else {
                        break;
                    };
                    if !(fit.texture >= Self::MIN_TEXTURE && fit.valid > 0.5) {
                        break;
                    }
                    textured = true;
                    ctx += d.0;
                    cty += d.1;
                    if d.0.abs() < 0.01 && d.1.abs() < 0.01 {
                        ok = true;
                        break;
                    }
                }
                if !(textured && ok && (ctx - tx).abs() < w as f64 / 16.0 && (cty - ty).abs() < h as f64 / 16.0) {
                    continue;
                }
                let p = Vec2::new(((x0 + x1) as f64 - 1.0) / 2.0 - cx, ((y0 + y1) as f64 - 1.0) / 2.0 - cy);
                src.push(p);
                dst.push(Vec2::new((1.0 + a) * p.x - b * p.y + ctx, b * p.x + (1.0 + a) * p.y + cty));
            }
        }
        if src.len() < Self::MIN_COHERENT_CELLS {
            return None;
        }
        let mut keep: Vec<usize> = (0..src.len()).collect();
        let mut fit: Option<CameraMotion> = None;
        for _ in 0..3 {
            if keep.len() < Self::MIN_COHERENT_CELLS {
                return None;
            }
            let ks: Vec<Vec2> = keep.iter().map(|&i| src[i]).collect();
            let kd: Vec<Vec2> = keep.iter().map(|&i| dst[i]).collect();
            let m = Registration::fit_similarity(&ks, &kd)?;
            fit = Some(m);
            let pose = m.pose();
            let res: Vec<f64> = (0..src.len())
                .map(|i| {
                    let d = pose.apply(src[i]) - dst[i];
                    (d.x * d.x + d.y * d.y).sqrt()
                })
                .collect();
            let mut kept_res: Vec<f64> = keep.iter().map(|&i| res[i]).collect();
            kept_res.sort_by(f64::total_cmp);
            let med = kept_res[keep.len() / 2];
            let limit = 0.3_f64.max(2.5 * med);
            let next: Vec<usize> = (0..src.len()).filter(|&i| res[i] <= limit).collect();
            if next == keep {
                break;
            }
            keep = next;
        }
        let fit = fit?;
        if keep.len() < Self::MIN_COHERENT_CELLS {
            return None;
        }
        Some((fit, keep.len() as f64 / src.len() as f64))
    }

    /// One robust Gauss-Newton step; the parameter change and the fit before it.
    /// `region` (pixel x0..<x1, y0..<y1; `None` = whole picture) and `translation_only` (only tx, ty change) serve the cells.
    #[allow(clippy::too_many_arguments, reason = "mirrors the Swift signature, one call site per use")]
    pub fn step(
        prev: &GrayFrame,
        cur: &GrayFrame,
        tx: f64,
        ty: f64,
        a: f64,
        b: f64,
        stride: usize,
        region: Option<Region>,
        translation_only: bool,
    ) -> Option<(StepDelta, Fit)> {
        let (w, h) = (cur.width, cur.height);
        let cx = (w - 1) as f64 / 2.0;
        let cy = (h - 1) as f64 / 2.0;
        let l = w.max(h) as f64 / 2.0;
        let (rx0, rx1, ry0, ry1) = match region {
            Some(r) => (r.0.max(2), r.1.min(w - 2), r.2.max(2), r.3.min(h - 2)),
            None => (2, w - 2, 2, h - 2),
        };
        if rx1 <= rx0 || ry1 <= ry0 {
            return None;
        }
        let (mut g0, mut g1, mut g2, mut g3) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
        let (mut h00, mut h01, mut h02, mut h03, mut h11, mut h12, mut h13, mut h22, mut h23, mut h33) =
            (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
        let (mut abs_sum, mut count, mut total) = (0.0_f64, 0_usize, 0_usize);
        let (mut sxx, mut syy, mut sxy) = (0.0_f64, 0.0_f64, 0.0_f64);
        let (p_px, c_px) = (&prev.pixels, &cur.pixels);
        let huber = f64::from(Self::HUBER);
        for y in (ry0..ry1).step_by(stride) {
            let py = y as f64 - cy;
            for x in (rx0..rx1).step_by(stride) {
                total += 1;
                let px = x as f64 - cx;
                let qx = (1.0 + a) * px - b * py + tx + cx;
                let qy = b * px + (1.0 + a) * py + ty + cy;
                if !(qx >= 1.0 && qy >= 1.0 && qx < (w - 2) as f64 && qy < (h - 2) as f64) {
                    continue;
                }
                let (x0, y0) = (qx as usize, qy as usize);
                let fx = (qx - x0 as f64) as f32;
                let fy = (qy - y0 as f64) as f32;
                let at = |xx: usize, yy: usize| c_px[yy * w + xx];
                // `dx`, `dy` are the offsets -1, 0 and +1 of the Swift helper, shifted by one to stay unsigned.
                let bil = |dx: usize, dy: usize| {
                    let (xa, ya) = (x0 + dx - 1, y0 + dy - 1);
                    let i00 = at(xa, ya);
                    let i10 = at(xa + 1, ya);
                    let i01 = at(xa, ya + 1);
                    let i11 = at(xa + 1, ya + 1);
                    (i00 * (1.0 - fx) + i10 * fx) * (1.0 - fy) + (i01 * (1.0 - fx) + i11 * fx) * fy
                };
                let ic = bil(1, 1);
                let gx = f64::from((bil(2, 1) - bil(0, 1)) * 0.5);
                let gy = f64::from((bil(1, 2) - bil(1, 0)) * 0.5);
                let r = f64::from(ic - p_px[y * w + x]);
                let ar = r.abs();
                let wt = if ar <= huber { 1.0 } else { huber / ar };
                let j0 = gx;
                let j1 = gy;
                let j2 = (gx * px + gy * py) / l;
                let j3 = (-gx * py + gy * px) / l;
                let (w0, w1, w2, w3) = (wt * j0, wt * j1, wt * j2, wt * j3);
                g0 += w0 * r;
                g1 += w1 * r;
                g2 += w2 * r;
                g3 += w3 * r;
                h00 += w0 * j0;
                h01 += w0 * j1;
                h02 += w0 * j2;
                h03 += w0 * j3;
                h11 += w1 * j1;
                h12 += w1 * j2;
                h13 += w1 * j3;
                h22 += w2 * j2;
                h23 += w2 * j3;
                h33 += w3 * j3;
                sxx += gx * gx;
                syy += gy * gy;
                sxy += gx * gy;
                abs_sum += ar;
                count += 1;
            }
        }
        if count <= 16 {
            return None;
        }
        let hm = [h00, h01, h02, h03, h01, h11, h12, h13, h02, h12, h22, h23, h03, h13, h23, h33];
        let g = [g0, g1, g2, g3];
        let n = count as f64;
        let (mxx, myy, mxy) = (sxx / n, syy / n, sxy / n);
        let tr = mxx + myy;
        let det = mxx * myy - mxy * mxy;
        let lmin = tr / 2.0 - (tr * tr / 4.0 - det).max(0.0).sqrt();
        let fit = Fit { residual: abs_sum / n, texture: lmin, valid: n / total.max(1) as f64 };
        if translation_only {
            let det2 = h00 * h11 - h01 * h01;
            if det2 <= 1e-9 * (h00 * h11).max(1e-300) {
                return Some(((0.0, 0.0, 0.0, 0.0), fit));
            }
            return Some((((-g0 * h11 + g1 * h01) / det2, (-g1 * h00 + g0 * h01) / det2, 0.0, 0.0), fit));
        }
        let neg: Vec<f64> = g.iter().map(|v| -v).collect();
        match Self::solve4(&hm, &neg) {
            Some(d) => Some(((d[0], d[1], d[2] / l, d[3] / l), fit)),
            None => Some(((0.0, 0.0, 0.0, 0.0), fit)),
        }
    }

    /// Residual and texture at the given parameters (no step).
    fn measure(prev: &GrayFrame, cur: &GrayFrame, tx: f64, ty: f64, a: f64, b: f64) -> Option<Fit> {
        Self::step(prev, cur, tx, ty, a, b, 1, None, false).map(|s| s.1)
    }

    /// Gaussian elimination with partial pivoting; `None` when singular.
    pub fn solve4(m: &[f64], rhs: &[f64]) -> Option<Vec<f64>> {
        let mut a = m.to_vec();
        let mut b = rhs.to_vec();
        let scale = (0..4).map(|i| a[i * 4 + i].abs()).fold(0.0, f64::max);
        if scale <= 0.0 {
            return None;
        }
        for c in 0..4 {
            let mut p = c;
            for r in c + 1..4 {
                if a[r * 4 + c].abs() > a[p * 4 + c].abs() {
                    p = r;
                }
            }
            if a[p * 4 + c].abs() <= scale * 1e-12 {
                return None;
            }
            if p != c {
                for k in 0..4 {
                    a.swap(c * 4 + k, p * 4 + k);
                }
                b.swap(c, p);
            }
            for r in c + 1..4 {
                let f = a[r * 4 + c] / a[c * 4 + c];
                for k in c..4 {
                    a[r * 4 + k] -= f * a[c * 4 + k];
                }
                b[r] -= f * b[c];
            }
        }
        let mut x = vec![0.0_f64; 4];
        for r in (0..4).rev() {
            let mut s = b[r];
            for k in r + 1..4 {
                s -= a[r * 4 + k] * x[k];
            }
            x[r] = s / a[r * 4 + r];
        }
        Some(x)
    }

    /// Displacement difference of two motions (same px) at the four points half way to the corners, RMS px.
    pub fn disagreement(m1: &CameraMotion, m2: &CameraMotion, width: f64, height: f64) -> f64 {
        let (p1, p2) = (m1.pose(), m2.pose());
        let mut s = 0.0;
        for q in [
            Vec2::new(-width / 4.0, -height / 4.0),
            Vec2::new(width / 4.0, -height / 4.0),
            Vec2::new(width / 4.0, height / 4.0),
            Vec2::new(-width / 4.0, height / 4.0),
        ] {
            let d = p1.apply(q) - p2.apply(q);
            s += d.x * d.x + d.y * d.y;
        }
        (s / 4.0).sqrt()
    }

    /// Confidence of Vision's motion (source px) given the check (`check_in_source` already in source px).
    pub fn confidence(
        vision: &CameraMotion,
        check: Option<&PhotometricMotion>,
        check_in_source: Option<&CameraMotion>,
        picture_width: i64,
        picture_height: i64,
    ) -> f64 {
        let (Some(check), Some(c)) = (check, check_in_source) else { return 0.0 };
        if !(check.converged && check.texture >= Self::MIN_TEXTURE) {
            return 0.0;
        }
        let w = picture_width as f64;
        let h = picture_height as f64;
        let d = Self::disagreement(vision, c, w, h) * 512.0 / w.max(h);
        ((Self::FULL_DISAGREEMENT - d) / (Self::FULL_DISAGREEMENT - Self::FULL_AGREEMENT)).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scene with detail at several sizes, gray levels around 128.
    fn scene(x: f64, y: f64) -> f64 {
        128.0
            + 34.0 * (x / 5.3 + y / 9.1).sin()
            + 28.0 * (x / 11.7 - y / 6.3).cos()
            + 22.0 * (x / 3.1).sin() * (y / 4.3).cos()
            + 18.0 * ((x + 2.0 * y) / 17.9).sin()
            + 14.0 * ((3.0 * x - y) / 23.3).cos()
    }

    fn shot(dx: f64, dy: f64) -> GrayFrame {
        let (w, h) = (256, 144);
        let px = (0..w * h).map(|i| scene((i % w) as f64 - dx, (i / w) as f64 - dy) as f32).collect();
        GrayFrame::new(w, h, px)
    }

    #[test]
    fn a_shifted_scene_is_registered() {
        let m = PhotometricRegistration::register(&shot(0.0, 0.0), &shot(3.5, -2.0), 4).expect("register");
        assert!(m.converged && m.texture >= PhotometricRegistration::MIN_TEXTURE);
        assert!((m.motion.dx - 3.5).abs() < 0.1 && (m.motion.dy - -2.0).abs() < 0.1, "{:?}", m.motion);
        assert!(m.motion.rotation.abs() < 0.2 && (m.motion.scale - 1.0).abs() < 0.01, "{:?}", m.motion);
        assert!(m.coherence > 0.9 && m.residual < 2.0);
    }

    #[test]
    fn pictures_of_another_size_do_not_register() {
        let small = GrayFrame::new(64, 64, vec![0.0; 64 * 64]);
        assert!(PhotometricRegistration::register(&shot(0.0, 0.0), &small, 4).is_none());
    }

    #[test]
    fn a_blank_picture_has_no_texture() {
        let blank = GrayFrame::new(256, 144, vec![100.0; 256 * 144]);
        let fit = PhotometricRegistration::step(&blank, &blank, 0.0, 0.0, 0.0, 0.0, 1, None, false).expect("step").1;
        assert!(fit.texture < PhotometricRegistration::MIN_TEXTURE);
    }

    #[test]
    fn the_pyramid_halves_while_the_long_side_stays_large() {
        let levels = shot(0.0, 0.0).pyramid(10);
        assert_eq!(levels.iter().map(|l| l.width).collect::<Vec<_>>(), [256, 128, 64, 32]);
    }

    #[test]
    fn solve4_solves_and_refuses_a_singular_system() {
        let m = [2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 0.0, 5.0];
        assert_eq!(PhotometricRegistration::solve4(&m, &[2.0, 6.0, 12.0, 20.0]), Some(vec![1.0, 2.0, 3.0, 4.0]));
        assert!(PhotometricRegistration::solve4(&[0.0; 16], &[1.0; 4]).is_none());
    }

    #[test]
    fn histograms_tell_a_cut_from_the_same_picture() {
        let a = shot(0.0, 0.0).quadrant_histograms();
        assert_eq!(GrayFrame::histogram_distance(&a, &a), 0.0);
        let dark = GrayFrame::new(256, 144, vec![10.0; 256 * 144]).quadrant_histograms();
        assert!(GrayFrame::histogram_distance(&a, &dark) > 0.5);
    }

    #[test]
    fn confidence_falls_with_the_disagreement() {
        let check = PhotometricMotion {
            motion: CameraMotion::IDENTITY,
            residual: 1.0,
            texture: 20.0,
            converged: true,
            coherence: 1.0,
        };
        let same = CameraMotion::IDENTITY;
        let off = CameraMotion::new(30.0, 0.0, 0.0, 1.0);
        let at = |v: &CameraMotion| PhotometricRegistration::confidence(v, Some(&check), Some(&same), 1920, 1080);
        assert_eq!(at(&same), 1.0);
        assert_eq!(at(&off), 0.0);
        assert_eq!(PhotometricRegistration::confidence(&same, None, None, 1920, 1080), 0.0);
    }
}
