// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/ImageFilters.swift (+ the pure `GPUFilterPlan` / `GPUFilterUniforms` of SQGPUKernels/Passes.swift)
//! W3.1 whole-picture effects (Sharpen, Directional Blur, Mirror, Noise, Glow, Mosaic). The CPU functions are the reference
//! the compute kernels are tested against; both work on premultiplied working-linear pixels in the padded intermediate,
//! where the clip's own frame is a rectangle centered in the texture (`Frame`).

use super::gaussian_blur;
use super::simd::{Float2, Float3, Float4, Int4};

/// The clip's own frame inside the working image, in texture px.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    /// Frame center.
    pub center: Float2,
    /// Frame size.
    pub size: Float2,
}

impl Frame {
    /// Top-left corner.
    pub fn origin(&self) -> Float2 {
        self.center - self.size / 2.0
    }
}

/// The 96-byte constant block every filter kernel takes (`FilterU`; Swift `GPUFilterUniforms`).
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct FilterUniforms {
    /// Parameters a.
    pub a: Float4,
    /// Parameters b.
    pub b: Float4,
    /// Center in texture px.
    pub center: Float2,
    /// Frame size (or a direction).
    pub frame: Float2,
    /// Integer parameters; `w` is the op code.
    pub i: Int4,
    /// Extra rows (the Stabilizer warp's perspective map); zero for every other kernel.
    pub c: Float4,
    /// Extra rows, second half.
    pub d: Float4,
}

impl FilterUniforms {
    /// Zeroed constants with a center and frame.
    pub fn new(center: Float2, frame: Float2) -> Self {
        Self { center, frame, ..Self::default() }
    }
}

/// Taps up to which a smear runs in one pass.
pub const ONE_PASS_TAPS: i64 = 32;

/// Pixels whose centers lie inside the frame (`origin`, `size` in texture px; inclusive bounds), kept in the image:
/// `(min_x, min_y, max_x, max_y)`.
pub fn pixel_rect(origin: Float2, size: Float2, width: i64, height: i64) -> (i64, i64, i64, i64) {
    let e = origin + size;
    (
        0.max((origin.x - 0.5).ceil() as i64),
        0.max((origin.y - 0.5).ceil() as i64),
        (width - 1).min((e.x - 0.5).ceil() as i64 - 1),
        (height - 1).min((e.y - 0.5).ceil() as i64 - 1),
    )
}

/// Taps along the smear: about one per px, at least 2, at most 512. Above `ONE_PASS_TAPS` rounded up to a product a x b
/// (a = ceil(sqrt n)), so the GPU runs it as two comb passes with exactly the same taps (`smear_passes`).
pub fn smear_taps(d: Float2) -> i64 {
    let n = 512.min(2.max((d.x * d.x + d.y * d.y).sqrt().ceil() as i64 + 1));
    if n <= ONE_PASS_TAPS {
        return n;
    }
    let a = (n as f64).sqrt().ceil() as i64;
    a * ((n + a - 1) / a)
}

/// Two comb passes for `n` taps (fine: `a` taps one spacing apart; coarse: `b` taps `a` spacings apart), or `None` for one pass.
pub fn smear_passes(n: i64) -> Option<(i64, i64)> {
    if n <= ONE_PASS_TAPS {
        return None;
    }
    let a = (n as f64).sqrt().ceil() as i64;
    if n % a == 0 { Some((a, n / a)) } else { None }
}

/// Largest Gaussian kernel the blur pass takes (2 * radius + 1 weights; Shaders/Blur.slang `BlurW`).
pub const MAX_BLUR_WEIGHTS: usize = 128;

/// A premultiplied image for the references (row-major, y down).
#[derive(Clone, Debug, PartialEq)]
pub struct Image {
    /// Width in px.
    pub width: usize,
    /// Height in px.
    pub height: usize,
    /// The pixels.
    pub px: Vec<Float4>,
}

impl Image {
    /// From a pixel function of `(x, y)`.
    pub fn from_fn(width: usize, height: usize, f: impl Fn(usize, usize) -> Float4) -> Image {
        let px = (0..width * height).map(|i| f(i % width, i / width)).collect();
        Image { width, height, px }
    }

    /// The pixel at `(x, y)`, transparent outside.
    pub fn at(&self, x: i64, y: i64) -> Float4 {
        if x < 0 || y < 0 || x >= self.width as i64 || y >= self.height as i64 {
            Float4::ZERO
        } else {
            self.px[y as usize * self.width + x as usize]
        }
    }

    /// Bilinear at texture position `p` (px, pixel centers at +0.5), transparent outside: what the GPU sampler does.
    pub fn sample(&self, p: Float2) -> Float4 {
        let q = p - 0.5;
        let x0 = q.x.floor() as i64;
        let y0 = q.y.floor() as i64;
        let fx = q.x - x0 as f32;
        let fy = q.y - y0 as f32;
        let top = self.at(x0, y0) * (1.0 - fx) + self.at(x0 + 1, y0) * fx;
        let bottom = self.at(x0, y0 + 1) * (1.0 - fx) + self.at(x0 + 1, y0 + 1) * fx;
        top * (1.0 - fy) + bottom * fy
    }

    /// Every pixel through `f(x, y, pixel)`.
    pub fn map(&self, f: impl Fn(usize, usize, Float4) -> Float4) -> Image {
        Image::from_fn(self.width, self.height, |x, y| f(x, y, self.px[y * self.width + x]))
    }
}

fn whole_frame(img: &Image) -> Frame {
    let size = Float2::new(img.width as f32, img.height as f32);
    Frame { center: size / 2.0, size }
}

/// p + amount * (p - mean of the 3 x 3 neighborhood); color never negative, alpha 0...1. Inside the picture (`frame`, `None`
/// = the whole image) the neighborhood is clamped to the picture, so its edge is not sharpened against the transparent
/// padding; outside it (a blur's halo) to the image.
pub fn sharpen(img: &Image, amount: f32, frame: Option<Frame>) -> Image {
    let f = frame.unwrap_or_else(|| whole_frame(img));
    let (min_x, min_y, max_x, max_y) = pixel_rect(f.origin(), f.size, img.width as i64, img.height as i64);
    img.map(|x, y, p| {
        let (x, y) = (x as i64, y as i64);
        let inside = x >= min_x && x <= max_x && y >= min_y && y <= max_y;
        let (lo_x, lo_y) = if inside { (min_x, min_y) } else { (0, 0) };
        let (hi_x, hi_y) = if inside { (max_x, max_y) } else { (img.width as i64 - 1, img.height as i64 - 1) };
        let mut sum = Float4::ZERO;
        for j in -1..=1 {
            for i in -1..=1 {
                sum += img.at((x + i).max(lo_x).min(hi_x), (y + j).max(lo_y).min(hi_y));
            }
        }
        sum /= 9.0;
        let mut o = p + amount * (p - sum);
        o = o.max(Float4::ZERO);
        o.w = o.w.min(1.0);
        o
    })
}

/// p + amount * (p - Gaussian blur) where the largest channel difference exceeds `threshold`. Inside the picture (`frame`,
/// `None` = the whole image) the blur repeats the picture's edge pixels; the padding outside stays as it is. `sigma` is
/// clamped to `MAX_DIRECT_SIGMA` like the GPU path.
pub fn unsharp_mask(img: &Image, sigma: f32, amount: f32, threshold: f32, frame: Option<Frame>) -> Image {
    if amount == 0.0 || !(sigma > 0.0) {
        return img.clone();
    }
    let f = frame.unwrap_or_else(|| whole_frame(img));
    let (min_x, min_y, max_x, max_y) = pixel_rect(f.origin(), f.size, img.width as i64, img.height as i64);
    if max_x < min_x || max_y < min_y {
        return img.clone();
    }
    let cw = (max_x - min_x + 1) as usize;
    let ch = (max_y - min_y + 1) as usize;
    let mut crop = Vec::with_capacity(cw * ch);
    for y in min_y..=max_y {
        for x in min_x..=max_x {
            crop.push(img.at(x, y));
        }
    }
    let blurred = gaussian_blur::blur(&crop, cw, ch, sigma.min(gaussian_blur::MAX_DIRECT_SIGMA as f32), true);
    img.map(|x, y, p| {
        let (xi, yi) = (x as i64, y as i64);
        if xi < min_x || xi > max_x || yi < min_y || yi > max_y {
            return p;
        }
        let d = p - blurred[(yi - min_y) as usize * cw + (xi - min_x) as usize];
        if !(d.x.abs().max(d.y.abs()).max(d.z.abs()) > threshold) {
            return p;
        }
        let mut o = p + amount * d;
        o = o.max(Float4::ZERO);
        o.w = o.w.min(1.0);
        o
    })
}

/// Average of `smear_taps` bilinear taps evenly spread over `d` (texture px), centered on each pixel.
pub fn directional_blur(img: &Image, d: Float2) -> Image {
    let n = smear_taps(d);
    img.map(|x, y, _| {
        let c = Float2::new(x as f32 + 0.5, y as f32 + 0.5);
        let mut acc = Float4::ZERO;
        for k in 0..n {
            acc += img.sample(c + d * (k as f32 / (n - 1) as f32 - 0.5));
        }
        acc / n as f32
    })
}

/// Unit normal of the reflection line: pixels on its side show their mirror image from the other side.
pub fn mirror_normal(degrees: f64) -> Float2 {
    let a = degrees * std::f64::consts::PI / 180.0;
    Float2::new(a.cos() as f32, a.sin() as f32)
}

/// Mirror over the line through `center` (texture px) at `degrees`.
pub fn mirror(img: &Image, center: Float2, degrees: f64) -> Image {
    let n = mirror_normal(degrees);
    img.map(|x, y, p| {
        let q = Float2::new(x as f32 + 0.5, y as f32 + 0.5);
        let d = (q - center).dot(n);
        if d > 0.0 { img.sample(q - n * (2.0 * d)) } else { p }
    })
}

/// Integer hash shared with the kernel (PCG output step): uniform 0...1.
pub fn hash01(x: u32, y: u32, seed: u32, ch: u32) -> f32 {
    let mut h = x
        .wrapping_mul(1_973)
        .wrapping_add(y.wrapping_mul(9_277))
        .wrapping_add(seed.wrapping_mul(26_699))
        .wrapping_add(ch.wrapping_mul(104_729));
    h = h.wrapping_mul(747_796_405).wrapping_add(2_891_336_453);
    let mut w = ((h >> ((h >> 28).wrapping_add(4))) ^ h).wrapping_mul(277_803_737);
    w = (w >> 22) ^ w;
    (w >> 8) as f32 / (1u32 << 24) as f32
}

/// Adds `amount * (u - 0.5) * alpha` per channel (one u for all three without color noise); `clip` keeps 0...max(1, input)
/// (premultiplied: max(alpha, input)), so HDR highlights are not capped; otherwise only negatives are cut.
pub fn noise(img: &Image, amount: f32, color: bool, clip: bool, seed: u32) -> Image {
    img.map(|x, y, p| {
        let mut o = p;
        for c in 0..3 {
            let u = hash01(x as u32, y as u32, seed, if color { c as u32 } else { 0 }) - 0.5;
            let v = p[c] + amount * u * p.w;
            o.set(c, if clip { v.max(0.0).min(p.w.max(p[c])) } else { v.max(0.0) });
        }
        o
    })
}

/// Bright pass of Glow: share of the pixel above `threshold` (luma of the un-premultiplied color), tinted when asked.
pub fn glow_bright(p: Float4, threshold: f32, tint: Option<Float3>) -> Float4 {
    if !(p.w > 0.0) {
        return Float4::ZERO;
    }
    let c = p.xyz() / p.w;
    let luma = c.dot(Float3::new(0.2126, 0.7152, 0.0722));
    let w = ((luma - threshold) / (1.0 - threshold).max(1e-3)).clamp(0.0, 1.0);
    if let Some(t) = tint {
        let tp = t * p.w;
        return Float4::new(tp.x, tp.y, tp.z, p.w) * w;
    }
    p * w
}

/// Picture plus `intensity` times the blurred bright pass; alpha grows where the glow reaches past the picture.
pub fn glow_add(p: Float4, g: Float4, intensity: f32) -> Float4 {
    let s = g * intensity;
    Float4::new(p.x + s.x, p.y + s.y, p.z + s.z, 1.0f32.min(p.w + s.w * (1.0 - p.w)))
}

/// Glow; `tint` working-linear.
pub fn glow(img: &Image, threshold: f32, sigma: f32, intensity: f32, tint: Option<Float3>) -> Image {
    let bright = img.map(|_, _, p| glow_bright(p, threshold, tint));
    let blurred = gaussian_blur::blur(&bright.px, img.width, img.height, sigma, false);
    img.map(|x, y, p| glow_add(p, blurred[y * img.width + x], intensity))
}

/// Pixels [start, end) whose centers fall in block `b` of size `bs` starting at `o`, inside 0...limit.
pub fn block_range(o: f32, bs: f32, b: i64, limit: i64) -> (i64, i64) {
    let s = (o + b as f32 * bs - 0.5).ceil() as i64;
    let e = (o + (b + 1) as f32 * bs - 0.5).ceil() as i64;
    (s.max(0).min(limit), e.max(0).min(limit))
}

/// Block colors, row-major `columns x rows`: the exact mean of the pixels whose centers fall in each block (row means, then
/// their mean, as the GPU does); a block holding no pixel center (smaller than a pixel) or Sharp Colors takes the pixel under
/// its center.
pub fn mosaic_blocks(img: &Image, frame: &Frame, columns: i64, rows: i64, sharp: bool) -> Vec<Float4> {
    let bw = frame.size.x / columns as f32;
    let bh = frame.size.y / rows as f32;
    let o = frame.origin();
    let mut out = Vec::new();
    for by in 0..rows {
        for bx in 0..columns {
            let (x0, x1) = block_range(o.x, bw, bx, img.width as i64);
            let (y0, y1) = block_range(o.y, bh, by, img.height as i64);
            if sharp || x1 <= x0 || y1 <= y0 {
                out.push(
                    img.at(
                        (o.x + (bx as f32 + 0.5) * bw).floor() as i64,
                        (o.y + (by as f32 + 0.5) * bh).floor() as i64,
                    ),
                );
                continue;
            }
            let mut acc = Float4::ZERO;
            for y in y0..y1 {
                let mut row = Float4::ZERO;
                for x in x0..x1 {
                    row += img.at(x, y);
                }
                acc += row / (x1 - x0) as f32;
            }
            out.push(acc / (y1 - y0) as f32);
        }
    }
    out
}

/// Inside the frame every pixel takes its block's color; outside it (a blur's halo) the picture is kept.
pub fn mosaic(img: &Image, frame: &Frame, columns: i64, rows: i64, sharp: bool) -> Image {
    let blocks = mosaic_blocks(img, frame, columns, rows, sharp);
    let bw = frame.size.x / columns as f32;
    let bh = frame.size.y / rows as f32;
    let o = frame.origin();
    img.map(|x, y, p| {
        let q = Float2::new(x as f32 + 0.5, y as f32 + 0.5) - o;
        if !(q.x >= 0.0 && q.y >= 0.0 && q.x < frame.size.x && q.y < frame.size.y) {
            return p;
        }
        let bx = (columns - 1).min((q.x / bw) as i64);
        let by = (rows - 1).min((q.y / bh) as i64);
        blocks[(by * columns + bx) as usize]
    })
}
