// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/GaussianBlur.swift
//! Gaussian Blur. `blurriness` is the standard deviation in px of the clip's own frame. The CPU function is the reference
//! the compute kernel is tested against; `Plan` is how the GPU path shrinks the work for a large sigma.

use super::simd::Float4;

/// Largest sigma the GPU runs at full size. Beyond it the layer is drawn at 1/factor size first, blurred there and
/// stretched back (linear filtering), so the kernel never exceeds `3 * MAX_DIRECT_SIGMA` taps per side.
pub const MAX_DIRECT_SIGMA: f64 = 6.0;
/// Largest texture side the device takes.
const MAX_TEXTURE_SIZE: i64 = 16_384;
/// Pixel budget of the Long Shadow's own shadow planes (4096 x 4096: 128 MB at rgba16Float, two of them). Beyond it the plane
/// alone runs at a reduced size and is stretched back under the full-size picture.
pub const MAX_SHAPE_PASS_PIXELS: i64 = 4_096 * 4_096;
/// Pixel budget of the padded working canvas of a Long Shadow or Outline pass (8192 x 8192: 512 MB at rgba16Float). The
/// picture is never reduced for it: only the transparent margin is cut (the far end of a very long shadow).
pub const MAX_SHAPE_CANVAS_PIXELS: i64 = 8_192 * 8_192;

/// Normalized 1D kernel for taps -radius...radius (2 * radius + 1 values). Radius defaults to ceil(3 sigma).
pub fn weights(sigma: f32, radius: Option<i64>) -> Vec<f32> {
    let r = radius.unwrap_or_else(|| (3.0 * sigma).ceil() as i64);
    if !(sigma > 0.0 && r > 0) {
        return vec![1.0];
    }
    let mut w: Vec<f32> = (-r..=r).map(|k| (-((k * k) as f32) / (2.0 * sigma * sigma)).exp()).collect();
    let sum = w.iter().fold(0.0f32, |a, b| a + b);
    for v in &mut w {
        *v /= sum;
    }
    w
}

/// Separable blur of premultiplied pixels with zero outside the image: the reference. `repeat_edges` (Repeat Edge Pixels):
/// outside the image the edge pixels repeat instead, so an opaque picture stays opaque up to its edge.
pub fn blur(px: &[Float4], width: usize, height: usize, sigma: f32, repeat_edges: bool) -> Vec<Float4> {
    if !(sigma > 0.0) {
        return px.to_vec();
    }
    let w = weights(sigma, None);
    let r = ((w.len() - 1) / 2) as i64;
    let (wi, hi) = (width as i64, height as i64);
    let mut tmp = vec![Float4::ZERO; px.len()];
    for y in 0..height {
        for x in 0..wi {
            let mut acc = Float4::ZERO;
            for k in -r..=r {
                let mut xx = x + k;
                if repeat_edges {
                    xx = xx.max(0).min(wi - 1);
                } else if xx < 0 || xx >= wi {
                    continue;
                }
                acc += px[y * width + xx as usize] * w[(k + r) as usize];
            }
            tmp[y * width + x as usize] = acc;
        }
    }
    let mut out = tmp.clone();
    for y in 0..hi {
        for x in 0..width {
            let mut acc = Float4::ZERO;
            for k in -r..=r {
                let mut yy = y + k;
                if repeat_edges {
                    yy = yy.max(0).min(hi - 1);
                } else if yy < 0 || yy >= hi {
                    continue;
                }
                acc += tmp[yy as usize * width + x] * w[(k + r) as usize];
            }
            out[y as usize * width + x] = acc;
        }
    }
    out
}

/// How the GPU blurs a layer of `layer_width x layer_height` px with `sigma`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Plan {
    /// The layer is drawn at 1/factor size (1 = full size).
    pub factor: i64,
    /// Sigma at the working size.
    pub sigma: f32,
    /// Kernel radius at the working size.
    pub radius: i64,
    /// Working texture width: the (reduced) picture plus `radius` of transparent margin on each side.
    pub texture_width: i64,
    /// Working texture height.
    pub texture_height: i64,
    /// Reduced picture width inside the texture (not necessarily whole px).
    pub content_width: f32,
    /// Reduced picture height inside the texture.
    pub content_height: f32,
}

impl Plan {
    /// Size of the finished image in layer px (bigger than the layer by the margin).
    pub fn output_width(&self) -> f32 {
        (self.texture_width * self.factor) as f32
    }

    /// Height of the finished image in layer px.
    pub fn output_height(&self) -> f32 {
        (self.texture_height * self.factor) as f32
    }

    /// `extra_margin`: more transparent border in layer px (a Drop Shadow's offset), on top of the 3 sigma; `extra_margin_y` a
    /// different one for top and bottom (`None` = the same). `min_factor`: work at 1/min_factor size or smaller (a layer
    /// shown at half size or less, see `effect_work_factor`). `max_pixels`: the working texture never holds more pixels; the
    /// extra margin is cut until it fits, never the picture. Only the device limit reduces the picture.
    pub fn new(
        layer_width: f64,
        layer_height: f64,
        sigma: f64,
        extra_margin: f64,
        extra_margin_y: Option<f64>,
        min_factor: i64,
        max_pixels: i64,
    ) -> Plan {
        let mut f = 1.max(min_factor).max((sigma / MAX_DIRECT_SIGMA).ceil() as i64);
        let mut extra_margin = extra_margin;
        let mut extra_margin_y = extra_margin_y;
        loop {
            let s = (sigma / f as f64) as f32;
            let r = if sigma > 0.0 { 1.max((3.0 * s).ceil() as i64) } else { 0 };
            // Rounded up to a multiple of 64 so a sigma that animates keeps asking for the same few texture sizes and the
            // pool can reuse them; the picture inside keeps its exact size, centered.
            let up = |v: i64| (v + 63) / 64 * 64;
            let mx = r + (extra_margin / f as f64).ceil() as i64;
            let my = r + (extra_margin_y.unwrap_or(extra_margin) / f as f64).ceil() as i64;
            let tw = up((layer_width / f as f64).ceil() as i64 + 2 * mx);
            let th = up((layer_height / f as f64).ceil() as i64 + 2 * my);
            if tw.saturating_mul(th) > max_pixels && extra_margin.max(extra_margin_y.unwrap_or(extra_margin)) >= 1.0 {
                // Over the budget: shrink the margin (5 % per try, both axes alike), keep the picture's size.
                extra_margin = (extra_margin * 0.95).floor();
                extra_margin_y = extra_margin_y.map(|v| (v * 0.95).floor());
                continue;
            }
            if tw.max(th) <= MAX_TEXTURE_SIZE || f > 4096 {
                return Plan {
                    factor: f,
                    sigma: s,
                    radius: r,
                    texture_width: tw,
                    texture_height: th,
                    content_width: (layer_width / f as f64) as f32,
                    content_height: (layer_height / f as f64) as f32,
                };
            }
            f += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weights_are_normalized_and_symmetric() {
        let w = weights(2.0, None);
        assert_eq!(w.len(), 13);
        assert!((w.iter().sum::<f32>() - 1.0).abs() < 1e-6);
        assert_eq!(w[0], w[12]);
        assert_eq!(weights(0.0, None), vec![1.0]);
        assert_eq!(weights(2.0, Some(1)).len(), 3);
    }

    #[test]
    fn blur_keeps_energy_and_repeat_edges_keeps_opaque_opaque() {
        let mut px = vec![Float4::ZERO; 9 * 9];
        px[4 * 9 + 4] = Float4::new(1.0, 1.0, 1.0, 1.0);
        let out = blur(&px, 9, 9, 1.0, false);
        let total: f32 = out.iter().map(|p| p.w).sum();
        assert!((total - 1.0).abs() < 1e-5);
        let opaque = vec![Float4::new(0.5, 0.5, 0.5, 1.0); 16];
        assert!(blur(&opaque, 4, 4, 2.0, false)[0].w < 1.0);
        assert!(blur(&opaque, 4, 4, 2.0, true).iter().all(|p| (p.w - 1.0).abs() < 1e-5));
        assert_eq!(blur(&px, 9, 9, 0.0, false), px);
    }

    #[test]
    fn plan_reduces_big_sigma_and_pads_to_64() {
        let p = Plan::new(100.0, 50.0, 4.0, 0.0, None, 1, i64::MAX);
        assert_eq!((p.factor, p.radius), (1, 12));
        assert_eq!((p.texture_width, p.texture_height), (128, 128));
        let big = Plan::new(1000.0, 1000.0, 30.0, 0.0, None, 1, i64::MAX);
        assert_eq!(big.factor, 5);
        assert_eq!(big.sigma, 6.0);
        assert_eq!(Plan::new(100.0, 50.0, 1.0, 0.0, None, 2, i64::MAX).factor, 2);
        assert_eq!(Plan::new(100.0, 50.0, 0.0, 0.0, None, 1, i64::MAX).radius, 0);
    }

    #[test]
    fn plan_cuts_the_margin_not_the_picture_over_budget() {
        let free = Plan::new(1000.0, 1000.0, 2.0, 500.0, None, 1, i64::MAX);
        let capped = Plan::new(1000.0, 1000.0, 2.0, 500.0, None, 1, 1_500_000);
        assert!(capped.texture_width < free.texture_width);
        assert_eq!(capped.content_width, 1000.0);
        assert!(capped.texture_width >= 1000);
    }

    #[test]
    fn plan_output_size_is_the_texture_times_the_factor() {
        let p = Plan::new(400.0, 300.0, 12.0, 0.0, None, 1, i64::MAX);
        assert_eq!(p.output_width(), (p.texture_width * p.factor) as f32);
        assert_eq!(p.output_height(), (p.texture_height * p.factor) as f32);
    }
}
