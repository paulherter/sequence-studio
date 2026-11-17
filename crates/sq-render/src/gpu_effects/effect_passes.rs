// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/EffectPasses.swift
//! The compute passes of a layer's effect chain: blur, Drop Shadow and the whole-picture filters (ImageFilters, StyleFilters,
//! Outline, Long Shadow). Every texture is premultiplied working-linear `Rgba16Float`; the clip's own frame sits centered in the
//! padded intermediate. Scratch textures come from a [`Scratch`] that outlives the command buffer.

use super::effect_chain_plan::lin;
use super::kernels::{Kernel, Kernels, filter_block};
use super::outline_filters as outline;
use super::scratch::{Block, Scratch};
use crate::effects::gaussian_blur::{self, MAX_DIRECT_SIGMA, Plan};
use crate::effects::image_filters::{self as filters, FilterUniforms, Frame};
use crate::effects::simd::{Float2, Float3, Float4, Int4};
use crate::effects::style_filters::{self, Family};
use crate::passes::{OutlineStyle, PixelRect};
use sq_core_effects::effects_evaluation::{DropShadow, ImageFilter, OutlinePosition};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use std::sync::Arc;

/// The effect passes of one device.
#[derive(Clone)]
pub struct EffectPasses {
    kernels: Kernels,
}

/// A blur plan for a plain `width x height` image (no margin, no reduction).
fn plain_plan(width: f64, height: f64, sigma: f64) -> Plan {
    Plan::new(width, height, sigma, 0.0, None, 1, i64::MAX)
}

fn lin3(c: [f64; 3]) -> Float3 {
    Float3::new(lin(c[0] as f32), lin(c[1] as f32), lin(c[2] as f32))
}

impl EffectPasses {
    /// The passes on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { kernels: Kernels::new(gpu) }
    }

    /// The kernels the passes are built from.
    pub fn kernels(&self) -> &Kernels {
        &self.kernels
    }

    /// Separable Gaussian: `a` is read, blurred horizontally into `b`, then vertically back into `a`. `repeat_edges`: reads
    /// clamp into that texture px rectangle (Repeat Edge Pixels) instead of zero outside the texture.
    pub fn blur(
        &self,
        cmds: &mut GpuCommands,
        plan: &Plan,
        a: &GpuTexture,
        b: &GpuTexture,
        repeat_edges: Option<([i32; 2], [i32; 2])>,
    ) -> Result<(), GpuError> {
        let weights = gaussian_blur::weights(plan.sigma, Some(plan.radius));
        self.kernels.blur(cmds, a, b, &weights, repeat_edges)
    }

    /// Drop Shadow on `image` (premultiplied, full size, picture centered in the padded texture) into `result` (same size).
    /// The shadow's alpha plane is made at 1/`reduction` size (reduction grows with softness so the kernel stays short) and
    /// upsampled bilinearly when composited; the picture itself is never reduced.
    pub fn shadow(
        &self,
        cmds: &mut GpuCommands,
        scratch: &mut Scratch,
        sh: &DropShadow,
        plan: &Plan,
        image: &GpuTexture,
        result: &GpuTexture,
    ) -> Result<(), GpuError> {
        let pf = plan.factor as f64;
        let sigma = sh.sigma / pf;
        let red = ((sigma / MAX_DIRECT_SIGMA).ceil() as i64).max(1) as u32;
        let (sw, shh) = (image.width().div_ceil(red).max(1), image.height().div_ceil(red).max(1));
        let (s1, s2) = (scratch.image(sw, shh), scratch.image(sw, shh));
        let blur_plan = plain_plan(f64::from(sw), f64::from(shh), sigma / f64::from(red));
        // Offset in texture px of the full-size picture (uv shift), shared by both kernels; color is working-linear. The
        // float4 starts a new 16-byte row, so the offset is followed by two pad floats.
        let color = lin3(sh.color);
        let constants = Block::new()
            .f32s(&[(sh.dx / pf) as f32, (sh.dy / pf) as f32, 0.0, 0.0])
            .f32s(&[color.x, color.y, color.z, sh.opacity as f32])
            .i32s(&[i32::from(sh.shadow_only)])
            .f32s(&[sh.spread.min(0.99) as f32, 0.0, 0.0])
            .padded();
        self.kernels.run(cmds, Kernel::SHADOW_EXTRACT, &[image], &s1, constants.bytes(), None)?;
        self.blur(cmds, &blur_plan, &s1, &s2, None)?; // result stays in s1
        self.kernels.run(cmds, Kernel::SHADOW_COMPOSITE, &[image, &s1], result, constants.bytes(), None)
    }

    /// Runs `filter` on `image` (premultiplied, picture centered) into `out` (same size). false when it could not run (a filter
    /// without a kernel). `frame`: the clip's own frame in texture px; `pf`: clip px per texture px.
    #[allow(clippy::too_many_lines, clippy::too_many_arguments)]
    pub fn filter(
        &self,
        cmds: &mut GpuCommands,
        scratch: &mut Scratch,
        filter: &ImageFilter,
        image: &GpuTexture,
        out: &GpuTexture,
        frame: &Frame,
        pf: f64,
    ) -> Result<bool, GpuError> {
        let k = &self.kernels;
        let (iw, ih) = (image.width(), image.height());
        let rect = || filters::pixel_rect(frame.origin(), frame.size, i64::from(iw), i64::from(ih));
        let mut u = FilterUniforms::new(frame.center, frame.size);
        match filter {
            ImageFilter::Sharpen { amount } => k.sharpen(cmds, image, out, *amount as f32, prect(rect()))?,
            ImageFilter::UnsharpMask { sigma, amount, threshold } => {
                // Blur of a copy at texture scale. Same as Swift (EffectPasses.swift:83): sigma is capped at MAX_DIRECT_SIGMA texture px (radius 12 px shown
                // at 1:1 stays exact; a picture upscaled past that gets a slightly smaller radius), upgrade with a
                // reduced-size blur like Glow when a larger radius is needed.
                let s = (sigma / pf).min(MAX_DIRECT_SIGMA);
                let (g1, g2) = (scratch.image(iw, ih), scratch.image(iw, ih));
                cmds.copy(image, &g1);
                let r = rect();
                let plan = plain_plan(f64::from(iw), f64::from(ih), s);
                self.blur(cmds, &plan, &g1, &g2, Some(([r.0 as i32, r.1 as i32], [r.2 as i32, r.3 as i32])))?;
                u.a = Float4::new(*amount as f32, *threshold as f32, 0.0, 0.0);
                u.i = Int4::new(r.0 as i32, r.1 as i32, r.2 as i32, r.3 as i32);
                k.run(cmds, Kernel::UNSHARP, &[image, &g1], out, filter_block(&u).bytes(), None)?;
            }
            ImageFilter::DirectionalBlur { dx, dy } => {
                k.directional_blur(cmds, image, out, [(dx / pf) as f32, (dy / pf) as f32], scratch)?;
            }
            ImageFilter::Mirror { center, angle } => k.mirror(
                cmds,
                image,
                out,
                {
                    let n = filters::mirror_normal(*angle);
                    [n.x, n.y]
                },
                {
                    let c = frame.center + Float2::new((center.x / pf) as f32, (center.y / pf) as f32);
                    [c.x, c.y]
                },
            )?,
            ImageFilter::Noise { amount, color, clip, seed } => {
                k.noise(cmds, image, out, *amount as f32, *color, *clip, *seed)?;
            }
            ImageFilter::Glow { threshold, sigma, intensity, color } => {
                // Bright pass at 1/red size so the kernel stays short (as Drop Shadow does), blurred, added back upsampled.
                let s = sigma / pf;
                let red = ((s / MAX_DIRECT_SIGMA).ceil() as i64).max(1) as u32;
                let (sw, sh) = (iw.div_ceil(red).max(1), ih.div_ceil(red).max(1));
                let (g1, g2) = (scratch.image(sw, sh), scratch.image(sw, sh));
                u.a = Float4::new(*threshold as f32, *intensity as f32, 0.0, 0.0);
                if let Some(tint) = color {
                    let t = lin3(*tint);
                    u.b = Float4::new(t.x, t.y, t.z, 1.0);
                    u.i.x = 1;
                }
                u.i.y = red as i32;
                k.run(cmds, Kernel::GLOW_BRIGHT, &[image], &g1, filter_block(&u).bytes(), None)?;
                if s > 0.0 {
                    self.blur(cmds, &plain_plan(f64::from(sw), f64::from(sh), s / f64::from(red)), &g1, &g2, None)?;
                }
                k.run(cmds, Kernel::GLOW_ADD, &[image, &g1], out, filter_block(&u).bytes(), None)?;
            }
            ImageFilter::Mosaic { columns, rows, sharp } => {
                k.mosaic(
                    cmds,
                    image,
                    out,
                    ([frame.center.x, frame.center.y], [frame.size.x, frame.size.y]),
                    (*columns as u32, *rows as u32),
                    *sharp,
                    scratch,
                )?;
            }
            ImageFilter::Outline { width, color, softness, position } => {
                let (w, soft) = (width / pf, softness / pf);
                let reach = (if *position == OutlinePosition::Centre { w / 2.0 } else { w }) + soft.max(1.0) + 2.0;
                let c = lin3(*color);
                let style = OutlineStyle {
                    width: w as f32,
                    softness: soft as f32,
                    color: [c.x, c.y, c.z],
                    position: *position as i32,
                };
                k.outline(cmds, image, out, &outline::jump_steps(reach), style, scratch)?;
            }
            ImageFilter::LongShadow { angle, length, color, fade, opacity } => {
                // The shadow plane is held to MAX_SHAPE_PASS_PIXELS (the picture itself stays full size); `sx`, `sy` canvas px
                // per plane px. Steps are planned in plane px along the longer scale so a full-size plane keeps whole-pixel steps.
                let (pw, ph) = outline::shadow_plane_size(iw, ih);
                let (sx, sy) = (f64::from(iw) / f64::from(pw), f64::from(ih) / f64::from(ph));
                let sc = sx.max(sy);
                let len = length / pf / sc;
                let dir = ImageFilter::long_shadow_direction(*angle);
                let steps: Vec<[f32; 3]> = outline::shadow_steps(len)
                    .into_iter()
                    .map(|h| [(dir.x * h * sc / sx) as f32, (dir.y * h * sc / sy) as f32, (fade * h / len) as f32])
                    .collect();
                let opacity = opacity.clamp(0.0, 1.0) as f32;
                if steps.is_empty() {
                    return Ok(false);
                }
                let c = lin3(*color);
                k.long_shadow(cmds, image, out, (pw, ph), &steps, [c.x, c.y, c.z], opacity, scratch)?;
                return Ok(true);
            }
            other => {
                // FB-T2 style filters: one pass each (StyleFilters).
                let Some((family, su)) = style_filters::plan(other, frame, pf) else { return Ok(false) };
                let kernel = match family {
                    Family::Pixel => Kernel::STYLE_PIXEL,
                    Family::Warp => Kernel::STYLE_WARP,
                    Family::RgbSplit => Kernel::RGB_SPLIT,
                    Family::RadialBlur => Kernel::RADIAL_BLUR,
                    Family::Lens => Kernel::LENS,
                    Family::Glitch => Kernel::GLITCH,
                };
                k.run(cmds, kernel, &[image], out, filter_block(&su).bytes(), None)?;
            }
        }
        Ok(true)
    }
}

/// The picture's pixel rect from the CPU plan's `(min_x, min_y, max_x, max_y)`.
fn prect(r: (i64, i64, i64, i64)) -> PixelRect {
    PixelRect { min_x: r.0 as i32, min_y: r.1 as i32, max_x: r.2 as i32, max_y: r.3 as i32 }
}
