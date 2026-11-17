//! A fixed headless graph through every converted pass, run the same way on every backend (Swift `GPUReferenceGraph`):
//! the cross-backend compare renders it on Metal and D3D12 and compares the PNGs. Two graphs stacked: the effect filters
//! on top (this file), every other shader family below ([`super::reference_families`]).

use super::kernels::{Kernels, OutlineStyle, Scratch};
use super::plan::PixelRect;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

/// Width of the whole image (both graphs).
pub const WIDTH: u32 = 320;
/// Height of each graph.
pub const GRAPH_HEIGHT: u32 = 180;
/// Height of the whole image.
pub const HEIGHT: u32 = 2 * GRAPH_HEIGHT;

/// Straight-alpha test picture (rgba32Float rows): ramps, a checker, an alpha falloff in one corner.
pub fn input_pixels() -> Vec<f32> {
    let (w, h) = (WIDTH as usize, GRAPH_HEIGHT as usize);
    let mut px = vec![0.0f32; w * h * 4];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let (fx, fy) = (x as f32 / (w - 1) as f32, y as f32 / (h - 1) as f32);
            let checker = if (x / 20 + y / 20) % 2 == 0 { 0.9 } else { 0.1 };
            let (dx, dy) = (fx - 0.85, fy - 0.8);
            px[i] = fx;
            px[i + 1] = fy * 1.4;
            px[i + 2] = checker;
            px[i + 3] = (((dx * dx + dy * dy).sqrt() - 0.05) * 6.0).clamp(0.0, 1.0);
        }
    }
    px
}

/// Runs both graphs and returns the image as 8-bit RGBA rows: the filter graph on top, the families graph below.
pub fn render(gpu: &Arc<Gpu>) -> Result<Vec<u8>, GpuError> {
    let mut image = render_filters(gpu)?;
    image.extend(super::reference_families::render(gpu)?);
    Ok(image)
}

/// f32 values as little-endian bytes (texture upload rows).
pub(super) fn float_bytes(values: &[f32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_le_bytes()).collect()
}

/// rgba32Float rows to 8-bit, clamped to 0...1.
pub(super) fn bytes8(raw: &[u8]) -> Vec<u8> {
    raw.as_chunks::<4>().0.iter().map(|c| (f32::from_le_bytes(*c).clamp(0.0, 1.0) * 255.0 + 0.5) as u8).collect()
}

/// The filter graph (BT.709-encoded straight color, alpha), `WIDTH x GRAPH_HEIGHT`.
pub fn render_filters(gpu: &Arc<Gpu>) -> Result<Vec<u8>, GpuError> {
    let (w, h) = (WIDTH, GRAPH_HEIGHT);
    let f16 = PixelFormat::Rgba16Float;
    let input = gpu.texture(w, h, PixelFormat::Rgba32Float);
    gpu.upload_texture(&input, &float_bytes(&input_pixels()), w * 16);
    let [a, b, c, d, e, f, g, hh] = std::array::from_fn(|_| gpu.texture(w, h, f16));
    let out = gpu.texture(w, h, PixelFormat::Rgba32Float);
    let mut scratch = Scratch::new(gpu);
    let kernels = Kernels::new(gpu);
    let mut cb = gpu.commands();

    kernels.premultiply(&mut cb, &input, &a)?;
    kernels.blur(&mut cb, &a, &b, &gaussian_weights(3.0), None)?;
    let frame_size = [(w - 32) as f32, (h - 32) as f32];
    let center = [w as f32 / 2.0, h as f32 / 2.0];
    let origin = [center[0] - frame_size[0] / 2.0, center[1] - frame_size[1] / 2.0];
    kernels.sharpen(&mut cb, &a, &c, 1.5, PixelRect::new(origin, frame_size, w, h))?;
    let angle = 30.0f32 * std::f32::consts::PI / 180.0;
    kernels.mirror(&mut cb, &c, &d, [cos_approx(angle), sin_approx(angle)], [center[0] + 40.0, center[1]])?;
    kernels.noise(&mut cb, &d, &e, 0.2, true, true, 7)?;
    kernels.directional_blur(&mut cb, &e, &f, [60.0, 20.0], &mut scratch)?;
    kernels.mosaic(&mut cb, &f, &g, (center, frame_size), (12, 8), false, &mut scratch)?;
    kernels.blend_frames(&mut cb, &g, &a, &hh, 0.3, false)?;
    kernels.encode_709(&mut cb, &hh, &out)?;
    let ticket = cb.read_texture(&out)?;
    gpu.submit(cb);
    let raw = ticket.wait(gpu)?;
    drop(scratch);
    Ok(bytes8(&raw))
}

/// Outline/long-shadow style used by the families graph.
pub(super) const GRAPH_OUTLINE: OutlineStyle =
    OutlineStyle { width: 3.0, softness: 1.0, color: [1.0, 0.8, 0.2], position: 0 };

/// Normalized Gaussian taps -r...r, r = ceil(3 sigma) (same formula as `effects::gaussian_blur` weights).
pub fn gaussian_weights(sigma: f32) -> Vec<f32> {
    let r = (3.0 * sigma).ceil() as i32;
    let mut w: Vec<f32> = (-r..=r).map(|k| exp_approx(-((k * k) as f32) / (2.0 * sigma * sigma))).collect();
    let sum: f32 = w.iter().sum();
    w.iter_mut().for_each(|v| *v /= sum);
    w
}

// Series instead of libm: the graph must be bit-identical on every platform, like the Swift CPU side.
fn exp_approx(x: f32) -> f32 {
    let (mut term, mut sum) = (1.0f64, 1.0f64);
    for n in 1..40 {
        term *= f64::from(x) / f64::from(n);
        sum += term;
    }
    sum as f32
}

pub(super) fn sin_approx(x: f32) -> f32 {
    let x = f64::from(x);
    let (mut term, mut sum) = (x, x);
    for n in (3..31).step_by(2) {
        term *= -x * x / f64::from((n - 1) * n);
        sum += term;
    }
    sum as f32
}

pub(super) fn cos_approx(x: f32) -> f32 {
    sin_approx(x + std::f32::consts::FRAC_PI_2)
}

/// Minimal PNG writer (8-bit RGBA, stored deflate blocks): enough for headless renders on every platform.
pub fn png_encode(rgba: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut raw = Vec::with_capacity((width * 4 + 1) * height);
    for row in rgba.chunks_exact(width * 4).take(height) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65_535).collect();
    for (i, block) in blocks.iter().enumerate() {
        let n = block.len() as u16;
        z.push(u8::from(i + 1 == blocks.len()));
        z.extend(n.to_le_bytes());
        z.extend((!n).to_le_bytes());
        z.extend_from_slice(block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for v in &raw {
        a = (a + u32::from(*v)) % 65_521;
        b = (b + a) % 65_521;
    }
    z.extend(((b << 16) | a).to_be_bytes());
    let mut png = vec![0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    let mut ihdr = (width as u32).to_be_bytes().to_vec();
    ihdr.extend((height as u32).to_be_bytes());
    ihdr.extend([8, 6, 0, 0, 0]);
    chunk(&mut png, b"IHDR", &ihdr);
    chunk(&mut png, b"IDAT", &z);
    chunk(&mut png, b"IEND", &[]);
    png
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend((data.len() as u32).to_be_bytes());
    out.extend(kind);
    out.extend(data);
    let mut c = 0xffff_ffffu32;
    for v in kind.iter().chain(data) {
        c ^= u32::from(*v);
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
        }
    }
    out.extend((!c).to_be_bytes());
}
