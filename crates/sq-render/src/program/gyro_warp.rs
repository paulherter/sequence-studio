// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Packages/SQAnalysis GyroWarpMap.swift (`GyroWarpMap`, the Metal kernel `sq_gyro_warp`), GyroStabilization.swift
//! The Gyroflow warp of a decoded picture. gyroflow_core's output is captured as a [`WarpMap`] (a coarse grid that says, for
//! every output texel, which source position it samples: lens model, rolling shutter, adaptive zoom and horizon lock are all
//! inside it); `warp_picture` then resamples the planes of a [`Picture`] with the `GyroWarp` Slang pass (Lanczos-4,
//! background outside the picture), written once for Metal and D3D12. The map is normalized, so one map serves every decode
//! size (proxy, reduced quality, full): playback and export show the same pixels. [`warp_plane_cpu`] is the same arithmetic
//! on the CPU, the reference of the tests.

use crate::compositor::{Picture, PictureKind};
use sq_core_masks::stabilize_effect::GyroflowOptions;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

/// Texel j of a map `width` wide stands for the output position (j + 0.5) / width and holds `(u, v, known, 0)`: the source
/// position it samples, normalized so that source pixel k of a plane m wide is k / m; `known` is 1 where gyroflow_core's
/// filter stayed inside the picture (the border is refilled by extrapolation).
#[derive(Clone, Debug, PartialEq)]
pub struct WarpMap {
    pub width: u32,
    pub height: u32,
    pub texels: Vec<[f32; 4]>,
}

impl WarpMap {
    /// A map that samples every output pixel where it is (a map `width` x `height` over a picture of any size).
    pub fn identity(width: u32, height: u32) -> WarpMap {
        let (w, h) = (width as f32, height as f32);
        let mut texels = Vec::with_capacity((width * height) as usize);
        for j in 0..height {
            for i in 0..width {
                // Output pixel i samples source pixel i, which sits at i / m.
                texels.push([i as f32 / w, j as f32 / h, 1.0, 0.0]);
            }
        }
        WarpMap { width, height, texels }
    }

    fn bytes(&self) -> Vec<u8> {
        self.texels.iter().flatten().flat_map(|v| v.to_le_bytes()).collect()
    }

    fn at(&self, x: u32, y: u32) -> [f32; 4] {
        self.texels[(y * self.width + x) as usize]
    }
}

/// Where the gyro engine's warp maps come from. Called from the render thread; `wait` = block until the clip's analysis is
/// done (export), otherwise a clip that is not analyzed yet gives `None` and shows unwarped (playback).
pub trait GyroMaps: Send + Sync {
    /// The map of the frame at `ts_us` (microseconds in the file `path`) with `options`; `None` = show the frame as is.
    fn map(&self, path: &str, options: &GyroflowOptions, ts_us: i64, wait: bool) -> Option<Arc<WarpMap>>;
    /// `f` runs (any thread) when an analysis finished or failed: redraw.
    fn add_observer(&self, f: Arc<dyn Fn() + Send + Sync>);
}

/// Constant block of `GyroWarp.slang` (48 bytes).
fn constants(dst: (u32, u32), src: (u32, u32), map: &WarpMap, background: [f32; 4]) -> Vec<u8> {
    let mut b = Vec::with_capacity(48);
    for v in [dst.0, dst.1, src.0, src.1, map.width, map.height, 0, 0] {
        b.extend(v.to_le_bytes());
    }
    for v in background {
        b.extend(v.to_le_bytes());
    }
    b
}

/// The plane's background (what lies outside the picture): black in the picture's range, neutral chroma.
fn backgrounds(kind: &PictureKind) -> Option<(Vec<[f32; 4]>, Option<bool>)> {
    match *kind {
        PictureKind::Ycbcr { bit_depth, full_range } => {
            let y = if full_range { 0.0 } else { 16.0 / 255.0 };
            let c = if bit_depth == 8 { 128.0 / 255.0 } else { 0.5 };
            Some((vec![[y, 0.0, 0.0, 1.0], [c, c, 0.0, 1.0]], Some(full_range)))
        }
        PictureKind::Rgba { alpha_mode } => (alpha_mode == 1).then(|| (vec![[0.0, 0.0, 0.0, 1.0]], None)),
        #[allow(unreachable_patterns)]
        _ => None,
    }
}

/// The picture resampled with `map`: the planes keep their meaning (luma, chroma, RGBA) but are stored as half-float RGBA
/// textures (the compositor reads textures as float4, so the format does not matter to it). `None` = this picture cannot be
/// warped (only 8-bit RGBA and YCbCr planes are) or the pass failed: the caller shows the picture as is. The pass is
/// submitted (not waited for): later work on the queue sees its result.
pub fn warp_picture(gpu: &Arc<Gpu>, picture: &Picture, map: &WarpMap) -> Option<Picture> {
    let (backgrounds, _) = backgrounds(&picture.kind)?;
    let (a, b) = &picture.planes;
    let sources: Vec<&GpuTexture> = std::iter::once(a).chain(b.as_ref()).collect();
    if sources.len() != backgrounds.len() {
        return None;
    }
    let buffer = gpu.storage_buffer(map.bytes().len() as u64);
    gpu.queue().write_buffer(&buffer, 0, &map.bytes());
    let outputs: Vec<GpuTexture> =
        sources.iter().map(|s| gpu.texture(s.width(), s.height(), PixelFormat::Rgba16Float)).collect();
    let run = || -> Result<(), GpuError> {
        let pipeline = gpu.compute_pipeline("GyroWarp", "gyroWarp", PixelFormat::Rgba16Float)?;
        let mut cmds = gpu.commands();
        {
            let mut pass = cmds.compute();
            pass.set_pipeline(&pipeline);
            pass.set_buffer(&buffer, 2)?;
            for ((s, o), bg) in sources.iter().zip(&outputs).zip(&backgrounds) {
                pass.set_input(s, 0)?;
                pass.set_output(o);
                pass.set_constants(&constants((o.width(), o.height()), (s.width(), s.height()), map, *bg), 0)?;
                pass.dispatch(o.width(), o.height())?;
            }
        }
        gpu.submit(cmds);
        Ok(())
    };
    run().ok()?;
    let mut it = outputs.into_iter();
    let first = it.next()?;
    Some(Picture { planes: (first, it.next()), kind: picture.kind })
}

/// `GyroWarp.slang` on the CPU: one plane of `channels` interleaved floats (0...1), `width` x `height`, resampled to
/// `out_width` x `out_height` with `map`. The reference of the GPU pass (and of gyroflow_core's own warp, see sq-gyroflow).
pub fn warp_plane_cpu(
    src: &[f32],
    (width, height): (usize, usize),
    channels: usize,
    (out_width, out_height): (usize, usize),
    map: &WarpMap,
    background: [f32; 4],
) -> Vec<f32> {
    let mut out = vec![0.0f32; out_width * out_height * channels];
    let (mw, mh) = (map.width as i64, map.height as i64);
    for y in 0..out_height {
        for x in 0..out_width {
            let m = [
                (x as f32 + 0.5) * mw as f32 / out_width as f32 - 0.5,
                (y as f32 + 0.5) * mh as f32 / out_height as f32 - 0.5,
            ];
            let i0 = [(m[0].floor() as i64).clamp(0, (mw - 2).max(0)), (m[1].floor() as i64).clamp(0, (mh - 2).max(0))];
            let i1 = [(i0[0] + 1).min(mw - 1), (i0[1] + 1).min(mh - 1)];
            let t = [m[0] - i0[0] as f32, m[1] - i0[1] as f32];
            let (a, b) = (map.at(i0[0] as u32, i0[1] as u32), map.at(i1[0] as u32, i0[1] as u32));
            let (c, d) = (map.at(i0[0] as u32, i1[1] as u32), map.at(i1[0] as u32, i1[1] as u32));
            let o = (y * out_width + x) * channels;
            if a[2].min(b[2]).min(c[2].min(d[2])) < 0.5 {
                out[o..o + channels].copy_from_slice(&background[..channels]);
                continue;
            }
            let lerp = |p: f32, q: f32, t: f32| p + (q - p) * t;
            let s = [
                lerp(lerp(a[0], b[0], t[0]), lerp(c[0], d[0], t[0]), t[1]),
                lerp(lerp(a[1], b[1], t[0]), lerp(c[1], d[1], t[0]), t[1]),
            ];
            let uv = [s[0] * width as f32 - 3.0, s[1] * height as f32 - 3.0];
            let q = [(uv[0] * 32.0).round() as i64, (uv[1] * 32.0).round() as i64];
            let base = [q[0] >> 5, q[1] >> 5];
            let f = [(q[0] & 31) as f32 / 32.0, (q[1] & 31) as f32 / 32.0];
            let (cx, cy) = (lanczos4(f[0]), lanczos4(f[1]));
            let mut sum = [0.0f32; 4];
            for (yp, wy) in cy.iter().enumerate() {
                let sy = base[1] + yp as i64;
                let mut row = [0.0f32; 4];
                if sy < 0 || sy >= height as i64 {
                    for k in 0..channels {
                        sum[k] += background[k] * wy;
                    }
                    continue;
                }
                for (xp, wx) in cx.iter().enumerate() {
                    let sx = base[0] + xp as i64;
                    for k in 0..channels {
                        let px = if sx >= 0 && sx < width as i64 {
                            src[(sy as usize * width + sx as usize) * channels + k]
                        } else {
                            background[k]
                        };
                        row[k] += px * wx;
                    }
                }
                for k in 0..channels {
                    sum[k] += row[k] * wy;
                }
            }
            for k in 0..channels {
                out[o + k] = sum[k].clamp(0.0, 1.0);
            }
        }
    }
    out
}

/// gyroflow_core's Lanczos-4 weights for the fraction `x` (normalized to 1).
fn lanczos4(x: f32) -> [f32; 8] {
    let mut c = [0.0f32; 8];
    if x < 1.192_092_9e-7 {
        c[3] = 1.0;
        return c;
    }
    const S45: f32 = std::f32::consts::FRAC_1_SQRT_2;
    let cs = [(1.0, 0.0), (-S45, -S45), (0.0, 1.0), (S45, -S45), (-1.0, 0.0), (S45, S45), (0.0, -1.0), (-S45, S45)];
    let y0 = -(x + 3.0) * std::f32::consts::FRAC_PI_4;
    let (s0, c0) = y0.sin_cos();
    let mut sum = 0.0;
    for i in 0..8 {
        let y = -(x + 3.0 - i as f32) * std::f32::consts::FRAC_PI_4;
        c[i] = (cs[i].0 * s0 + cs[i].1 * c0) / (y * y);
        sum += c[i];
    }
    let k = 1.0 / sum;
    for v in &mut c {
        *v *= k;
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compositor::Picture;

    /// A smooth, textured plane: gradients plus a checker, so the filter has something to resolve.
    fn plane(w: usize, h: usize) -> Vec<f32> {
        (0..w * h)
            .map(|i| {
                let (x, y) = ((i % w) as f32, (i / w) as f32);
                let checker = if ((x as i32 / 6) + (y as i32 / 6)) % 2 == 0 { 0.15 } else { 0.0 };
                (0.2 + 0.5 * (x / w as f32) * 0.8 + 0.3 * (y / h as f32) * 0.5 + checker).clamp(0.0, 1.0)
            })
            .collect()
    }

    /// A map that scales about the center by 1.1 and rotates a little: the interior samples inside, the border outside.
    fn map(w: u32, h: u32) -> WarpMap {
        let mut m = WarpMap::identity(w, h);
        let (c, s) = (0.03f32.cos(), 0.03f32.sin());
        for (n, t) in m.texels.iter_mut().enumerate() {
            let (x, y) =
                (((n as u32 % w) as f32 + 0.5) / w as f32 - 0.5, ((n as u32 / w) as f32 + 0.5) / h as f32 - 0.5);
            let (rx, ry) = ((c * x - s * y) * 1.1, (s * x + c * y) * 1.1);
            *t = [(rx + 0.5) * (w as f32 - 1.0) / w as f32 + 0.0, (ry + 0.5) * (h as f32 - 1.0) / h as f32, 1.0, 0.0];
        }
        m
    }

    #[test]
    fn the_identity_map_reproduces_the_plane() {
        let (w, h) = (64usize, 48usize);
        let src = plane(w, h);
        let out = warp_plane_cpu(&src, (w, h), 1, (w, h), &WarpMap::identity(w as u32, h as u32), [0.0; 4]);
        let worst = src.iter().zip(&out).map(|(a, b)| (a - b).abs()).fold(0.0f32, f32::max);
        assert!(worst < 1.0 / 255.0, "worst {worst}");
    }

    #[test]
    fn the_gpu_pass_matches_the_cpu_reference() {
        let Some(gpu) = Gpu::new().ok() else {
            eprintln!("skipping: no GPU adapter");
            return;
        };
        let (w, h) = (96usize, 64usize);
        let src = plane(w, h);
        let m = map(32, 24);
        let reference = warp_plane_cpu(&src, (w, h), 1, (w, h), &m, [0.0625, 0.0, 0.0, 1.0]);
        // The luma plane as R8: the pass reads it through the sampler-free Load, like a decoded plane.
        let bytes: Vec<u8> = src.iter().map(|v| (v * 255.0).round() as u8).collect();
        let t = gpu.texture(w as u32, h as u32, PixelFormat::Rgba8Unorm);
        let rgba: Vec<u8> = bytes.iter().flat_map(|&v| [v, 0, 0, 255]).collect();
        gpu.upload_texture(&t, &rgba, w as u32 * 4);
        let chroma = gpu.texture(w as u32 / 2, h as u32 / 2, PixelFormat::Rgba8Unorm);
        gpu.upload_texture(&chroma, &vec![128u8; w / 2 * h / 2 * 4], w as u32 / 2 * 4);
        let pic = Picture::ycbcr(t, chroma, 8, false);
        let warped = warp_picture(&gpu, &pic, &m).expect("warp");
        let half = gpu.read_texture(&warped.planes.0).unwrap();
        let mut worst = 0.0f32;
        for (i, r) in reference.iter().enumerate() {
            let (x, y) = (i % w, i / w);
            if x < 8 || y < 8 || x >= w - 8 || y >= h - 8 {
                continue;
            }
            let v = half_to_f32(u16::from_le_bytes([half[(y * w + x) * 8], half[(y * w + x) * 8 + 1]]));
            // The reference reads the plane at 8 bits too.
            worst = worst.max((v - r).abs());
        }
        assert!(worst <= 2.0 / 255.0, "GPU vs CPU warp: worst {}/255", worst * 255.0);
    }

    fn half_to_f32(h: u16) -> f32 {
        let (s, e, m) = ((h >> 15) & 1, (h >> 10) & 0x1f, h & 0x3ff);
        let v = match e {
            0 => f32::from(m) / 1024.0 * 2f32.powi(-14),
            31 => f32::INFINITY,
            _ => (1.0 + f32::from(m) / 1024.0) * 2f32.powi(i32::from(e) - 15),
        };
        if s == 1 { -v } else { v }
    }
}
