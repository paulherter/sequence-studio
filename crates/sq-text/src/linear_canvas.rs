// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/LinearCanvas.swift
//! CPU drawing for the portable text raster: coverage masks from polygons, round strokes, Gaussian blur and source-over
//! compositing in linear light, premultiplied, y down. Coverage is applied in linear light like the Mac's Core Graphics
//! linear-sRGB context, so edges match.

use crate::glyph_raster::CoverageRasterizer;
use crate::text_style::RGBAColor;
use sq_core_time::Vec2;

/// A premultiplied RGBA color (the Swift `SIMD4<Float>`).
pub type Rgba = [f32; 4];

fn scaled(c: Rgba, k: f32) -> Rgba {
    [c[0] * k, c[1] * k, c[2] * k, c[3] * k]
}

/// A canvas of premultiplied linear-light RGBA pixels.
#[derive(Clone, Debug)]
pub struct LinearCanvas {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// RGBA per pixel, premultiplied, linear light (sRGB primaries), rows top to bottom.
    pub pixels: Vec<f32>,
}

impl LinearCanvas {
    /// A transparent canvas.
    pub fn new(width: usize, height: usize) -> LinearCanvas {
        LinearCanvas { width, height, pixels: vec![0.0; width * height * 4] }
    }

    /// Source-over of a solid premultiplied color through `mask`.
    pub fn fill(&mut self, mask: &[f32], c: Rgba) {
        if c[3] <= 0.0 {
            return;
        }
        for (i, &m) in mask.iter().enumerate().take(self.width * self.height) {
            if m > 0.0 {
                self.blend(i, scaled(c, m));
            }
        }
    }

    /// Source-over of a per-pixel premultiplied color through `mask`.
    pub fn fill_with(&mut self, mask: &[f32], color: impl Fn(usize, usize) -> Rgba) {
        for y in 0..self.height {
            for x in 0..self.width {
                let i = y * self.width + x;
                if mask[i] > 0.0 {
                    self.blend(i, scaled(color(x, y), mask[i]));
                }
            }
        }
    }

    /// `self` over `below` (the result replaces `self`).
    pub fn place(&mut self, below: &LinearCanvas) {
        for i in 0..self.width * self.height {
            let a = self.pixels[i * 4 + 3];
            for k in 0..4 {
                self.pixels[i * 4 + k] += below.pixels[i * 4 + k] * (1.0 - a);
            }
        }
    }

    /// The alpha channel.
    pub fn alpha(&self) -> Vec<f32> {
        (0..self.width * self.height).map(|i| self.pixels[i * 4 + 3]).collect()
    }

    fn blend(&mut self, i: usize, s: Rgba) {
        let k = i * 4;
        let keep = 1.0 - s[3];
        self.pixels[k] = s[0] + self.pixels[k] * keep;
        self.pixels[k + 1] = s[1] + self.pixels[k + 1] * keep;
        self.pixels[k + 2] = s[2] + self.pixels[k + 2] * keep;
        self.pixels[k + 3] = s[3] + self.pixels[k + 3] * keep;
    }

    /// An sRGB color (straight alpha) as premultiplied linear light.
    pub fn linear(c: &RGBAColor) -> Rgba {
        let a = c.alpha as f32;
        [Self::to_linear(c.red) * a, Self::to_linear(c.green) * a, Self::to_linear(c.blue) * a, a]
    }

    /// One sRGB component to linear light.
    pub fn to_linear(v: f64) -> f32 {
        (if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }) as f32
    }
}

/// Closed polygons in pixels (y down) to a nonzero coverage mask. Overlapping polygons of the same winding are a union
/// (the summed coverage is clamped at 1), so strokes are built from same-wound pieces.
#[derive(Clone, Debug)]
pub struct PolygonMask {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    raster: CoverageRasterizer,
}

impl PolygonMask {
    /// An empty mask.
    pub fn new(width: usize, height: usize) -> PolygonMask {
        PolygonMask { width, height, raster: CoverageRasterizer::new(width as i64, height as i64) }
    }

    /// One closed polygon (the closing edge is added).
    pub fn add(&mut self, points: &[Vec2]) {
        if points.len() <= 2 {
            return;
        }
        for i in 0..points.len() {
            self.edge(points[i], points[(i + 1) % points.len()]);
        }
    }

    /// Adds `points` wound so that their signed area is positive (for unions).
    pub fn add_positive(&mut self, points: &[Vec2]) {
        if Self::signed_area(points) < 0.0 {
            let reversed: Vec<Vec2> = points.iter().rev().copied().collect();
            self.add(&reversed);
        } else {
            self.add(points);
        }
    }

    /// The accumulation buffer spills a column left of 0 or right of `width` into the neighboring row, so every edge is
    /// cut at both sides and the parts outside are laid on the border (which keeps the area right of them covered).
    fn edge(&mut self, a: Vec2, b: Vec2) {
        let w = self.width as f64;
        let mut cuts: Vec<f64> = vec![0.0, 1.0];
        if b.x != a.x {
            for xc in [0.0, w] {
                let t = (xc - a.x) / (b.x - a.x);
                if t > 0.0 && t < 1.0 {
                    cuts.push(t);
                }
            }
        }
        cuts.sort_by(f64::total_cmp);
        for k in 0..cuts.len() - 1 {
            let p = a + (b - a) * cuts[k];
            let q = a + (b - a) * cuts[k + 1];
            self.raster.line(p.x.max(0.0).min(w) as f32, p.y as f32, q.x.max(0.0).min(w) as f32, q.y as f32);
        }
    }

    /// The coverage mask, row by row.
    pub fn mask(&self) -> Vec<f32> {
        self.raster.coverage_values()
    }

    /// The signed area of a polygon.
    pub fn signed_area(p: &[Vec2]) -> f64 {
        let mut s = 0.0;
        for i in 0..p.len() {
            let a = p[i];
            let b = p[(i + 1) % p.len()];
            s += a.x * b.y - b.x * a.y;
        }
        s / 2.0
    }

    /// A circle as a polygon fine enough at radius `r` pixels.
    pub fn disc(c: Vec2, r: f64) -> Vec<Vec2> {
        let n = ((r * 2.0).ceil() as i64).clamp(8, 96);
        (0..n)
            .map(|k| {
                let t = k as f64 / n as f64 * 2.0 * std::f64::consts::PI;
                c + Vec2::new(t.cos(), t.sin()) * r
            })
            .collect()
    }

    /// A round-joined, round-capped stroke of half width `r` along closed polylines: one rectangle per edge and one disc
    /// per vertex, all wound the same way (the union is what Core Graphics strokes with round joins).
    pub fn stroke(&mut self, polylines: &[Vec<Vec2>], half_width: f64) {
        let r = half_width;
        if r <= 0.0 {
            return;
        }
        for line in polylines.iter().filter(|l| l.len() > 1) {
            for i in 0..line.len() {
                let a = line[i];
                let b = line[(i + 1) % line.len()];
                self.add_positive(&Self::disc(a, r));
                let d = b - a;
                let len = (d.x * d.x + d.y * d.y).sqrt();
                if len <= 1e-9 {
                    continue;
                }
                let n = Vec2::new(-d.y / len * r, d.x / len * r);
                self.add_positive(&[a + n, b + n, b - n, a - n]);
            }
        }
    }

    /// A rounded rectangle (radius clamped to half the shorter side).
    pub fn rounded_rect(x: f64, y: f64, w: f64, h: f64, radius: f64) -> Vec<Vec2> {
        let r = radius.max(0.0).min(w.min(h) / 2.0);
        if r <= 0.0 {
            return vec![Vec2::new(x, y), Vec2::new(x + w, y), Vec2::new(x + w, y + h), Vec2::new(x, y + h)];
        }
        let n = (r.ceil() as i64).clamp(4, 32);
        let pi = std::f64::consts::PI;
        let mut out = Vec::new();
        let corners = [
            (Vec2::new(x + w - r, y + r), -pi / 2.0),
            (Vec2::new(x + w - r, y + h - r), 0.0),
            (Vec2::new(x + r, y + h - r), pi / 2.0),
            (Vec2::new(x + r, y + r), pi),
        ];
        for (c, start) in corners {
            for k in 0..=n {
                let t = start + k as f64 / n as f64 * pi / 2.0;
                out.push(c + Vec2::new(t.cos(), t.sin()) * r);
            }
        }
        out
    }
}

/// Pixelwise operations on coverage masks.
pub enum MaskOps {}

impl MaskOps {
    /// Pixelwise union of two masks (clamped sum: both come from the same shapes' parts).
    pub fn union(a: &[f32], b: &[f32]) -> Vec<f32> {
        a.iter().zip(b).map(|(x, y)| (x + y).min(1.0)).collect()
    }

    /// Separable Gaussian blur, sigma in pixels, zero outside.
    pub fn blur(m: &[f32], w: usize, h: usize, sigma: f64) -> Vec<f32> {
        if sigma <= 0.05 || w == 0 || h == 0 {
            return m.to_vec();
        }
        let radius = (sigma * 3.0).ceil() as i64;
        let mut k: Vec<f32> =
            (-radius..=radius).map(|j| (-((j * j) as f64) / (2.0 * sigma * sigma)).exp() as f32).collect();
        let total = k.iter().fold(0.0f32, |s, v| s + v);
        k = k.iter().map(|v| v / total).collect();
        let r = radius as usize;
        // Text masks are mostly empty: only the span between the first and last non-zero value of a row can contribute, and
        // a zero term adds exactly nothing, so skipping the rest gives the very same floats as the full sum.
        let mut tmp = vec![0.0f32; w * h];
        let (mut col_lo, mut col_hi) = (w, 0usize);
        let mut row_span: Vec<Option<(usize, usize)>> = vec![None; h];
        for y in 0..h {
            let row = &m[y * w..(y + 1) * w];
            let Some(first) = row.iter().position(|v| *v != 0.0) else { continue };
            let last = row.iter().rposition(|v| *v != 0.0).unwrap_or(first);
            let (lo, hi) = (first.saturating_sub(r), (last + r).min(w - 1));
            for x in lo..=hi {
                let from = x.saturating_sub(r).max(first);
                let to = (x + r).min(last);
                let mut s = 0.0f32;
                for xx in from..=to {
                    s += row[xx] * k[xx + r - x];
                }
                tmp[y * w + x] = s;
            }
            row_span[y] = Some((lo, hi));
            col_lo = col_lo.min(lo);
            col_hi = col_hi.max(hi);
        }
        let mut out = vec![0.0f32; w * h];
        let Some(first_row) = row_span.iter().position(Option::is_some) else { return out };
        let last_row = row_span.iter().rposition(Option::is_some).unwrap_or(first_row);
        // Row-wise accumulation: per output value the terms are added in the same order as a column walk, but the inner
        // loop runs over contiguous memory.
        for y in first_row.saturating_sub(r)..=(last_row + r).min(h - 1) {
            let out_row = &mut out[y * w + col_lo..y * w + col_hi + 1];
            for yy in y.saturating_sub(r).max(first_row)..=(y + r).min(last_row) {
                if row_span[yy].is_none() {
                    continue;
                }
                let kv = k[yy + r - y];
                let src = &tmp[yy * w + col_lo..yy * w + col_hi + 1];
                for (o, t) in out_row.iter_mut().zip(src) {
                    *o += t * kv;
                }
            }
        }
        out
    }

    /// `m` moved by (dx, dy) pixels (bilinear for fractional offsets), zero where nothing moves in.
    pub fn shift(m: &[f32], w: usize, h: usize, dx: f64, dy: f64) -> Vec<f32> {
        if dx == 0.0 && dy == 0.0 {
            return m.to_vec();
        }
        let mut out = vec![0.0f32; w * h];
        let fx = dx.floor();
        let fy = dy.floor();
        let tx = (dx - fx) as f32;
        let ty = (dy - fy) as f32;
        let ix = fx as i64;
        let iy = fy as i64;
        let at = |x: i64, y: i64| -> f32 {
            if x >= 0 && x < w as i64 && y >= 0 && y < h as i64 { m[y as usize * w + x as usize] } else { 0.0 }
        };
        for y in 0..h {
            for x in 0..w {
                let sx = x as i64 - ix;
                let sy = y as i64 - iy;
                let top = at(sx, sy) * (1.0 - tx) + at(sx - 1, sy) * tx;
                let bottom = at(sx, sy - 1) * (1.0 - tx) + at(sx - 1, sy - 1) * tx;
                out[y * w + x] = top * (1.0 - ty) + bottom * ty;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// The blur as it was before the sparse-span version: the full window at every pixel.
    fn blur_reference(m: &[f32], w: usize, h: usize, sigma: f64) -> Vec<f32> {
        let radius = (sigma * 3.0).ceil() as i64;
        let mut k: Vec<f32> =
            (-radius..=radius).map(|j| (-((j * j) as f64) / (2.0 * sigma * sigma)).exp() as f32).collect();
        let total = k.iter().fold(0.0f32, |s, v| s + v);
        k = k.iter().map(|v| v / total).collect();
        let mut tmp = vec![0.0f32; w * h];
        let mut out = tmp.clone();
        for y in 0..h {
            for x in 0..w {
                let mut s = 0.0f32;
                for j in -radius..=radius {
                    let xx = x as i64 + j;
                    if xx >= 0 && xx < w as i64 {
                        s += m[y * w + xx as usize] * k[(j + radius) as usize];
                    }
                }
                tmp[y * w + x] = s;
            }
        }
        for y in 0..h {
            for x in 0..w {
                let mut s = 0.0f32;
                for j in -radius..=radius {
                    let yy = y as i64 + j;
                    if yy >= 0 && yy < h as i64 {
                        s += tmp[yy as usize * w + x] * k[(j + radius) as usize];
                    }
                }
                out[y * w + x] = s;
            }
        }
        out
    }

    /// `cargo test -p sq-text --release -- --ignored --nocapture blur_speed`: a text-like mask (a few glyph-sized blocks).
    #[test]
    #[ignore]
    fn blur_speed() {
        let (w, h) = (1000usize, 600usize);
        let mut m = vec![0.0f32; w * h];
        for b in 0..8 {
            for y in 250..330 {
                for x in (60 + b * 110)..(130 + b * 110) {
                    m[y * w + x] = if (x + y) % 3 == 0 { 1.0 } else { 0.4 };
                }
            }
        }
        let t = std::time::Instant::now();
        let old = blur_reference(&m, w, h, 12.0);
        let old_ms = t.elapsed().as_secs_f64() * 1e3;
        let t = std::time::Instant::now();
        let new = MaskOps::blur(&m, w, h, 12.0);
        let new_ms = t.elapsed().as_secs_f64() * 1e3;
        assert!(old.iter().zip(&new).all(|(a, b)| a.to_bits() == b.to_bits()));
        eprintln!("blur {w}x{h} sigma 12: old {old_ms:.1} ms, new {new_ms:.1} ms");
    }

    #[test]
    fn sparse_blur_is_bit_identical_to_the_full_window_blur() {
        let (w, h) = (53usize, 41usize);
        let mut seed = 12345u32;
        let mut next = move || {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            (seed >> 8) as f32 / (1u32 << 24) as f32
        };
        let mut cases: Vec<Vec<f32>> = vec![vec![0.0; w * h], vec![1.0; w * h]];
        // dense noise, sparse specks, a block touching the border, a single pixel
        cases.push((0..w * h).map(|_| next()).collect());
        cases.push((0..w * h).map(|_| if next() > 0.97 { next() } else { 0.0 }).collect());
        let mut block = vec![0.0; w * h];
        for y in 0..7 {
            for x in 40..w {
                block[y * w + x] = next();
            }
        }
        cases.push(block);
        let mut one = vec![0.0; w * h];
        one[20 * w + 30] = 1.0;
        cases.push(one);
        for m in &cases {
            for sigma in [0.0, 0.5, 1.0, 2.7, 6.0, 30.0] {
                let a = MaskOps::blur(m, w, h, sigma);
                let b = if sigma <= 0.05 { m.clone() } else { blur_reference(m, w, h, sigma) };
                assert!(a.iter().zip(&b).all(|(x, y)| x.to_bits() == y.to_bits()), "sigma {sigma}");
            }
        }
    }

    const W: usize = 24;
    const H: usize = 20;

    /// The Swift dumper's float bit patterns (`oracle/sq-text/run.sh`), by case.
    fn golden() -> BTreeMap<String, Vec<f32>> {
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/sq-text/golden/linear-canvas.tsv");
        let mut out: BTreeMap<String, Vec<f32>> = BTreeMap::new();
        for line in std::fs::read_to_string(path).unwrap().lines() {
            let f: Vec<&str> = line.split('\t').collect();
            out.entry(f[0].to_string()).or_default().push(f32::from_bits(u32::from_str_radix(f[2], 16).unwrap()));
        }
        out
    }

    fn close(name: &str, got: &[f32], want: &[f32]) {
        assert_eq!(got.len(), want.len(), "{name} length");
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            assert!((g - w).abs() < 2e-5, "{name}[{i}]: {g} vs {w}");
        }
    }

    fn mask_a() -> Vec<f32> {
        let mut m = PolygonMask::new(W, H);
        m.add_positive(&[Vec2::new(2.0, 2.0), Vec2::new(20.0, 4.0), Vec2::new(8.0, 16.0)]);
        m.add_positive(&PolygonMask::rounded_rect(10.0, 8.0, 12.0, 9.0, 3.0));
        m.stroke(&[vec![Vec2::new(3.0, 3.0), Vec2::new(18.0, 3.0), Vec2::new(18.0, 14.0)]], 1.5);
        m.mask()
    }

    #[test]
    fn polygon_masks_blur_and_shift_match_the_swift_canvas() {
        let g = golden();
        let a = mask_a();
        close("mask", &a, &g["mask"]);
        close("blur", &MaskOps::blur(&a, W, H, 1.7), &g["blur"]);
        let shifted = MaskOps::shift(&a, W, H, 1.3, -0.6);
        close("shift", &shifted, &g["shift"]);
        close("union", &MaskOps::union(&a, &shifted), &g["union"]);
    }

    #[test]
    fn compositing_in_linear_light_matches_the_swift_canvas() {
        let g = golden();
        let a = mask_a();
        let shifted = MaskOps::shift(&a, W, H, 1.3, -0.6);
        let mut below = LinearCanvas::new(W, H);
        below.fill(&MaskOps::blur(&a, W, H, 1.7), LinearCanvas::linear(&RGBAColor::new(0.1, 0.2, 0.9, 1.0)));
        let mut top = LinearCanvas::new(W, H);
        top.fill(&a, LinearCanvas::linear(&RGBAColor::new(0.8, 0.4, 0.1, 0.9)));
        top.fill_with(&shifted, |x, y| [x as f32 / 24.0 * 0.5, y as f32 / 20.0 * 0.5, 0.25, 0.5]);
        close("alpha", &top.alpha(), &g["alpha"]);
        top.place(&below);
        close("canvas", &top.pixels, &g["canvas"]);
    }

    #[test]
    fn srgb_components_convert_to_linear_light() {
        assert_eq!(LinearCanvas::to_linear(0.0), 0.0);
        assert!((LinearCanvas::to_linear(1.0) - 1.0).abs() < 1e-6);
        assert!((LinearCanvas::to_linear(0.04) - 0.04 / 12.92).abs() < 1e-7);
        assert_eq!(LinearCanvas::linear(&RGBAColor::new(1.0, 1.0, 1.0, 0.5)), [0.5, 0.5, 0.5, 0.5]);
    }
}
