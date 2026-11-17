//! The converted compute kernels on one `Gpu`: dispatch plumbing, the compositor core passes and the effect passes
//! (Swift `GPUKernels`). Every pass records into a `GpuCommands`; scratch textures stay alive in a [`Scratch`] until the
//! caller submitted.

#![allow(clippy::too_many_arguments)]

use super::plan::{MAX_BLUR_WEIGHTS, PixelRect, smear_passes, smear_taps};
use super::uniforms::{BlurU, FilterU};
use sq_gpu::frames::{GpuTexture, PooledTexture};
use sq_gpu::gpu::{ComputeEncoder, Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

/// One compute entry point: its Slang module and name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Kernel {
    pub module: &'static str,
    pub name: &'static str,
}

const fn kernel(module: &'static str, name: &'static str) -> Kernel {
    Kernel::new(module, name)
}

impl Kernel {
    pub const fn new(module: &'static str, name: &'static str) -> Self {
        Self { module, name }
    }

    pub const GAUSSIAN_BLUR_1D: Kernel = kernel("Blur", "gaussianBlur1D");
    pub const ENCODE_709: Kernel = kernel("Pointwise", "premultipliedLinearToEncoded709");
    pub const PREMULTIPLY: Kernel = kernel("Pointwise", "straightToPremultiplied");
    pub const BLEND_FRAMES: Kernel = kernel("Pointwise", "blendFrames");
    pub const ANTI_FLICKER: Kernel = kernel("Pointwise", "antiFlickerVertical");
    pub const SHARPEN: Kernel = kernel("Filters", "filterSharpen");
    pub const DIRECTIONAL_BLUR: Kernel = kernel("Filters", "filterDirectionalBlur");
    pub const SMEAR_COMB: Kernel = kernel("Filters", "filterSmearComb");
    pub const MIRROR: Kernel = kernel("Filters", "filterMirror");
    pub const NOISE: Kernel = kernel("Filters", "filterNoise");
    pub const MOSAIC_ROWS: Kernel = kernel("Filters", "filterMosaicRows");
    pub const MOSAIC_BLOCKS: Kernel = kernel("Filters", "filterMosaicBlocks");
    pub const MOSAIC_APPLY: Kernel = kernel("Filters", "filterMosaicApply");
    pub const OUTLINE_SEED: Kernel = kernel("Filters", "filterOutlineSeed");
    pub const OUTLINE_JUMP: Kernel = kernel("Filters", "filterOutlineJump");
    pub const OUTLINE_APPLY: Kernel = kernel("Filters", "filterOutlineApply");
    pub const LONG_SHADOW_STEP: Kernel = kernel("Filters", "filterLongShadowStep");
    pub const LONG_SHADOW_APPLY: Kernel = kernel("Filters", "filterLongShadowApply");

    pub const SHADOW_EXTRACT: Kernel = kernel("DropShadow", "shadowExtract");
    pub const SHADOW_COMPOSITE: Kernel = kernel("DropShadow", "shadowComposite");
    pub const UNSHARP: Kernel = kernel("Filters", "filterUnsharp");
    pub const GLOW_BRIGHT: Kernel = kernel("Filters", "filterGlowBright");
    pub const GLOW_ADD: Kernel = kernel("Filters", "filterGlowAdd");
    pub const STYLE_PIXEL: Kernel = kernel("Filters", "filterStylePixel");
    pub const STYLE_WARP: Kernel = kernel("Filters", "filterStyleWarp");
    pub const LENS: Kernel = kernel("Filters", "filterLens");
    pub const GLITCH: Kernel = kernel("Filters", "filterGlitch");
    pub const RGB_SPLIT: Kernel = kernel("Filters", "filterRGBSplit");
    pub const RADIAL_BLUR: Kernel = kernel("Filters", "filterRadialBlur");
    pub const OF_LUMA: Kernel = kernel("OpticalFlow", "ofLuma");
    pub const OF_DOWN: Kernel = kernel("OpticalFlow", "ofDown");
    pub const OF_GRAD: Kernel = kernel("OpticalFlow", "ofGrad");
    pub const OF_UP: Kernel = kernel("OpticalFlow", "ofUp");
    pub const OF_LK: Kernel = kernel("OpticalFlow", "ofLK");
    pub const OF_MEDIAN: Kernel = kernel("OpticalFlow", "ofMedian");
    pub const OF_CONFIDENCE: Kernel = kernel("OpticalFlow", "ofConfidence");
    pub const OF_INTERPOLATE: Kernel = kernel("OpticalFlow", "ofInterpolate");

    /// Every kernel the passes in this module run (the table the pipeline test walks).
    pub const ALL: [Kernel; 37] = [
        Self::GAUSSIAN_BLUR_1D,
        Self::ENCODE_709,
        Self::PREMULTIPLY,
        Self::BLEND_FRAMES,
        Self::ANTI_FLICKER,
        Self::SHARPEN,
        Self::DIRECTIONAL_BLUR,
        Self::SMEAR_COMB,
        Self::MIRROR,
        Self::NOISE,
        Self::MOSAIC_ROWS,
        Self::MOSAIC_BLOCKS,
        Self::MOSAIC_APPLY,
        Self::OUTLINE_SEED,
        Self::OUTLINE_JUMP,
        Self::OUTLINE_APPLY,
        Self::LONG_SHADOW_STEP,
        Self::LONG_SHADOW_APPLY,
        Self::SHADOW_EXTRACT,
        Self::SHADOW_COMPOSITE,
        Self::UNSHARP,
        Self::GLOW_BRIGHT,
        Self::GLOW_ADD,
        Self::STYLE_PIXEL,
        Self::STYLE_WARP,
        Self::LENS,
        Self::GLITCH,
        Self::RGB_SPLIT,
        Self::RADIAL_BLUR,
        Self::OF_LUMA,
        Self::OF_DOWN,
        Self::OF_GRAD,
        Self::OF_UP,
        Self::OF_LK,
        Self::OF_MEDIAN,
        Self::OF_CONFIDENCE,
        Self::OF_INTERPOLATE,
    ];
}

/// One compute dispatch with explicit bindings: textures by slot, data buffers by slot (2..=4), constant blocks b0, b1.
pub struct Dispatch<'a> {
    pub kernel: Kernel,
    pub inputs: &'a [(usize, &'a GpuTexture)],
    pub buffers: &'a [(usize, &'a wgpu::Buffer)],
    pub constants: &'a [&'a [u8]],
    pub output: &'a GpuTexture,
    /// Threads in x and y; the output's size unless given.
    pub grid: Option<(u32, u32)>,
}

impl Dispatch<'_> {
    /// Binds and dispatches on `enc`. The pipeline is the one built for the output's format.
    pub fn record(&self, gpu: &Gpu, enc: &mut ComputeEncoder<'_>) -> Result<(), GpuError> {
        let format = self.output.format().ok_or_else(|| GpuError::Binding("output texture format".into()))?;
        enc.set_pipeline(&gpu.compute_pipeline(self.kernel.module, self.kernel.name, format)?);
        for (slot, texture) in self.inputs {
            enc.set_input(texture, *slot)?;
        }
        for (slot, buffer) in self.buffers {
            enc.set_buffer(buffer, *slot)?;
        }
        for (slot, bytes) in self.constants.iter().enumerate() {
            enc.set_constants(bytes, slot)?;
        }
        enc.set_output(self.output);
        let (width, height) = self.grid.unwrap_or((self.output.width(), self.output.height()));
        enc.dispatch(width, height)
    }
}

/// Scratch textures (rgba16Float, GPU only) a pass borrows; they go back to the pool when this is dropped, so keep it
/// until the commands are submitted.
pub struct Scratch {
    gpu: Arc<Gpu>,
    held: Vec<PooledTexture>,
}

impl Scratch {
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { gpu: Arc::clone(gpu), held: Vec::new() }
    }

    /// The device the textures live on.
    pub fn gpu(&self) -> &Arc<Gpu> {
        &self.gpu
    }

    /// A `width` x `height` texture of `format`, kept until the scratch is dropped.
    pub fn texture(&mut self, width: u32, height: u32, format: PixelFormat) -> GpuTexture {
        let pooled = self.gpu.acquire(width.max(1), height.max(1), format);
        let texture = (*pooled).clone();
        self.held.push(pooled);
        texture
    }

    /// A working image (premultiplied working-linear `Rgba16Float`).
    pub fn image(&mut self, width: u32, height: u32) -> GpuTexture {
        self.texture(width, height, PixelFormat::Rgba16Float)
    }

    pub fn acquire(&mut self, width: u32, height: u32) -> GpuTexture {
        self.image(width, height)
    }
}

/// The kernels on one device. Pipelines are built on first use by `Gpu` and cached there.
#[derive(Clone)]
pub struct Kernels {
    gpu: Arc<Gpu>,
    /// Stands in for the input slots a dispatch does not use: bindings outlive a dispatch inside one compute pass, and a
    /// texture left in a slot that a later dispatch does not use still counts as read when it is that dispatch's output
    /// (wgpu: conflicting usages).
    dummy: GpuTexture,
}

/// Most input textures one kernel reads (the Lucas-Kanade step).
const MAX_KERNEL_INPUTS: usize = 5;

impl Kernels {
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { gpu: Arc::clone(gpu), dummy: gpu.texture(1, 1, PixelFormat::Rgba16Float) }
    }

    /// One dispatch in its own compute pass: `inputs` to in0..., `output` to out0, `constants` to block 0.
    pub fn run(
        &self,
        cb: &mut GpuCommands,
        kernel: Kernel,
        inputs: &[&GpuTexture],
        output: &GpuTexture,
        constants: &[u8],
        grid: Option<(u32, u32)>,
    ) -> Result<(), GpuError> {
        let mut enc = cb.compute();
        self.record(&mut enc, kernel, inputs, output, constants, grid)
    }

    /// One dispatch into an open pass (several dispatches share one pass and see each other's writes).
    pub fn record(
        &self,
        enc: &mut ComputeEncoder<'_>,
        kernel: Kernel,
        inputs: &[&GpuTexture],
        output: &GpuTexture,
        constants: &[u8],
        grid: Option<(u32, u32)>,
    ) -> Result<(), GpuError> {
        let slots: Vec<(usize, &GpuTexture)> = (0..inputs.len().max(MAX_KERNEL_INPUTS))
            .map(|i| (i, inputs.get(i).copied().unwrap_or(&self.dummy)))
            .collect();
        Dispatch { kernel, inputs: &slots, buffers: &[], constants: &[constants], output, grid }.record(&self.gpu, enc)
    }

    /// Alias of [`Self::record`].
    pub fn dispatch(
        &self,
        enc: &mut ComputeEncoder<'_>,
        kernel: Kernel,
        inputs: &[&GpuTexture],
        output: &GpuTexture,
        constants: &[u8],
        grid: Option<(u32, u32)>,
    ) -> Result<(), GpuError> {
        self.record(enc, kernel, inputs, output, constants, grid)
    }

    // Compositor core.

    /// Separable Gaussian in place: `a` is read, blurred horizontally into `b`, then vertically back into `a`.
    /// `weights`: 2 * radius + 1 normalized taps (at most [`MAX_BLUR_WEIGHTS`]). `repeat_edges`: reads clamp into that
    /// texture px rectangle (lo, hi) instead of zero outside the texture.
    pub fn blur(
        &self,
        cb: &mut GpuCommands,
        a: &GpuTexture,
        via_b: &GpuTexture,
        weights: &[f32],
        repeat_edges: Option<([i32; 2], [i32; 2])>,
    ) -> Result<(), GpuError> {
        if weights.is_empty() || weights.len() > MAX_BLUR_WEIGHTS {
            return Err(GpuError::Binding(format!("{} blur weights (1..={MAX_BLUR_WEIGHTS})", weights.len())));
        }
        // The whole BlurW block: a shorter buffer than the declared struct trips validation.
        let block: Vec<u8> = weights
            .iter()
            .copied()
            .chain(std::iter::repeat(0.0))
            .take(MAX_BLUR_WEIGHTS)
            .flat_map(f32::to_le_bytes)
            .collect();
        let (lo, hi) = repeat_edges.unwrap_or_default();
        let uniforms = |axis| {
            BlurU {
                axis,
                radius: ((weights.len() - 1) / 2) as i32,
                clamp_edges: i32::from(repeat_edges.is_some()),
                lo,
                hi,
            }
            .bytes()
        };
        let mut enc = cb.compute();
        for (axis, source, target) in [([1, 0], a, via_b), ([0, 1], via_b, a)] {
            let slots = [(0, source)];
            let constants = [uniforms(axis), block.clone()];
            let refs: Vec<&[u8]> = constants.iter().map(Vec::as_slice).collect();
            Dispatch {
                kernel: Kernel::GAUSSIAN_BLUR_1D,
                inputs: &slots,
                buffers: &[],
                constants: &refs,
                output: target,
                grid: Some((a.width(), a.height())),
            }
            .record(&self.gpu, &mut enc)?;
        }
        Ok(())
    }

    /// Anti-flicker: vertical [k, 1 - 2k, k] softening, `k` = the neighbor weight.
    pub fn anti_flicker(
        &self,
        cb: &mut GpuCommands,
        src: &GpuTexture,
        dst: &GpuTexture,
        k: f32,
    ) -> Result<(), GpuError> {
        self.run(cb, Kernel::ANTI_FLICKER, &[src], dst, &vec4_bytes([k, 0.0, 0.0, 0.0]), None)
    }

    /// Premultiplied working-linear to straight BT.709-encoded, alpha kept (Adjustment Layer grade input).
    pub fn encode_709(&self, cb: &mut GpuCommands, src: &GpuTexture, dst: &GpuTexture) -> Result<(), GpuError> {
        self.run(cb, Kernel::ENCODE_709, &[src], dst, &vec4_bytes([0.0; 4]), None)
    }

    /// Straight working-linear to premultiplied.
    pub fn premultiply(&self, cb: &mut GpuCommands, src: &GpuTexture, dst: &GpuTexture) -> Result<(), GpuError> {
        self.run(cb, Kernel::PREMULTIPLY, &[src], dst, &vec4_bytes([0.0; 4]), None)
    }

    /// Frame Blending in light-linear space: mix(lin(a), lin(b), weight); `encoded`: inputs are BT.709-encoded.
    pub fn blend_frames(
        &self,
        cb: &mut GpuCommands,
        a: &GpuTexture,
        b: &GpuTexture,
        out: &GpuTexture,
        weight: f32,
        encoded: bool,
    ) -> Result<(), GpuError> {
        let flag = if encoded { 1.0 } else { 0.0 };
        self.run(cb, Kernel::BLEND_FRAMES, &[a, b], out, &vec4_bytes([weight, flag, 0.0, 0.0]), None)
    }

    // Effects (CPU references: ImageFilters in `effects`).

    /// `rect`: the picture's pixel rect ([`PixelRect::new`]).
    pub fn sharpen(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        amount: f32,
        rect: PixelRect,
    ) -> Result<(), GpuError> {
        let mut u = FilterU::default();
        u.a[0] = amount;
        u.i = [rect.min_x, rect.min_y, rect.max_x, rect.max_y];
        self.run(cb, Kernel::SHARPEN, &[image], out, &u.bytes(), None)
    }

    /// `normal`: unit normal of the reflection line; `center` in texture px.
    pub fn mirror(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        normal: [f32; 2],
        center: [f32; 2],
    ) -> Result<(), GpuError> {
        let mut u = FilterU { center, ..FilterU::default() };
        u.a = [normal[0], normal[1], 0.0, 0.0];
        self.run(cb, Kernel::MIRROR, &[image], out, &u.bytes(), None)
    }

    pub fn noise(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        amount: f32,
        color: bool,
        clip: bool,
        seed: u32,
    ) -> Result<(), GpuError> {
        let mut u = FilterU::default();
        u.a[0] = amount;
        u.i = [i32::from(color), i32::from(clip), seed as i32, 0];
        self.run(cb, Kernel::NOISE, &[image], out, &u.bytes(), None)
    }

    /// `d`: smear vector in texture px. Long smears run as two comb passes through a padded scratch texture.
    pub fn directional_blur(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        d: [f32; 2],
        scratch: &mut Scratch,
    ) -> Result<(), GpuError> {
        let n = smear_taps(d);
        let mut u = FilterU::default();
        let Some((fine, coarse)) = smear_passes(n) else {
            u.a = [d[0], d[1], 0.0, 0.0];
            u.i[0] = n as i32;
            return self.run(cb, Kernel::DIRECTIONAL_BLUR, &[image], out, &u.bytes(), None);
        };
        // The fine pass writes a padded intermediate: the coarse pass reaches half the smear beyond each edge, where the
        // fine pass still sees the picture.
        let step = [d[0] / (n - 1) as f32, d[1] / (n - 1) as f32];
        let half = (fine * (coarse - 1)) as f32 / 2.0;
        // Rounded up to 16 px so an animated length reuses pooled textures.
        let pad = |s: f32| ((s * half).abs().ceil() as u32 + 16) / 16 * 16;
        let (px, py) = (pad(step[0]), pad(step[1]));
        let mid = scratch.acquire(image.width() + 2 * px, image.height() + 2 * py);
        u.a = [step[0], step[1], 0.0, 0.0];
        u.b = [-(px as f32), -(py as f32), 0.0, 0.0];
        u.i[0] = fine as i32;
        self.run(cb, Kernel::SMEAR_COMB, &[image], &mid, &u.bytes(), None)?;
        let coarse_step = [step[0] * fine as f32, step[1] * fine as f32];
        u.a = [coarse_step[0], coarse_step[1], 0.0, 0.0];
        u.b = [px as f32, py as f32, 0.0, 0.0];
        u.i[0] = coarse as i32;
        self.run(cb, Kernel::SMEAR_COMB, &[&mid], out, &u.bytes(), Some((image.width(), image.height())))
    }

    /// Exact block means in two short passes (row means, then their mean): no thread loops over a whole block.
    /// `frame_center`/`frame_size`: the clip's frame in texture px.
    pub fn mosaic(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        frame: ([f32; 2], [f32; 2]),
        grid: (u32, u32),
        sharp: bool,
        scratch: &mut Scratch,
    ) -> Result<(), GpuError> {
        let (center, size) = frame;
        let (columns, rows) = grid;
        let origin = [center[0] - size[0] / 2.0, center[1] - size[1] / 2.0];
        let pr = PixelRect::new(origin, size, image.width(), image.height());
        let n_rows = (pr.max_y - pr.min_y + 1).max(1) as u32;
        let blocks = scratch.acquire(columns, rows);
        let row_means = scratch.acquire(columns, n_rows);
        let mut u = FilterU::with_frame(center, size);
        u.i = [columns as i32, rows as i32, i32::from(sharp), pr.min_y];
        u.a = [size[0] / columns as f32, size[1] / rows as f32, 0.0, 0.0]; // block size, see Filters.slang
        if !sharp {
            self.run(cb, Kernel::MOSAIC_ROWS, &[image], &row_means, &u.bytes(), Some((columns, n_rows)))?;
        }
        self.run(cb, Kernel::MOSAIC_BLOCKS, &[image, &row_means], &blocks, &u.bytes(), Some((columns, rows)))?;
        self.run(cb, Kernel::MOSAIC_APPLY, &[image, &blocks], out, &u.bytes(), None)
    }

    /// Outline: alpha 0.5 crossings as seeds, jump-flood passes of `jump_steps` px, then the band laid on/under the
    /// picture. `width`, `softness` in texture px, `color` linear, `position` 0 outside, 1 inside, 2 center.
    pub fn outline(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        jump_steps: &[i32],
        style: OutlineStyle,
        scratch: &mut Scratch,
    ) -> Result<(), GpuError> {
        let (mut a, mut b) =
            (scratch.acquire(image.width(), image.height()), scratch.acquire(image.width(), image.height()));
        let mut enc = cb.compute();
        let mut u = FilterU::default();
        self.record(&mut enc, Kernel::OUTLINE_SEED, &[image], &a, &u.bytes(), None)?;
        for step in jump_steps {
            u.i[0] = *step;
            self.record(&mut enc, Kernel::OUTLINE_JUMP, &[&a], &b, &u.bytes(), None)?;
            std::mem::swap(&mut a, &mut b);
        }
        u.a = [style.width, style.softness, 0.0, 0.0];
        u.b = [style.color[0], style.color[1], style.color[2], 1.0];
        u.i[0] = style.position;
        self.record(&mut enc, Kernel::OUTLINE_APPLY, &[image, &a], out, &u.bytes(), None)
    }

    /// Long Shadow: one doubling pass per step over the alpha into a `plane` sized texture, then laid under the picture.
    /// `steps`: (step back x, y in plane px, fade over the step) each. `color` linear, `opacity` 0...1.
    pub fn long_shadow(
        &self,
        cb: &mut GpuCommands,
        image: &GpuTexture,
        out: &GpuTexture,
        plane: (u32, u32),
        steps: &[[f32; 3]],
        color: [f32; 3],
        opacity: f32,
        scratch: &mut Scratch,
    ) -> Result<(), GpuError> {
        if steps.is_empty() {
            return Err(GpuError::Binding("long shadow without steps".into()));
        }
        let (mut dst, mut spare) = (scratch.acquire(plane.0, plane.1), scratch.acquire(plane.0, plane.1));
        let mut src = image.clone();
        let mut enc = cb.compute();
        let mut u = FilterU::default();
        for (i, h) in steps.iter().enumerate() {
            u.a = [h[0], h[1], h[2], 0.0];
            u.i[0] = i32::from(i == 0);
            self.record(&mut enc, Kernel::LONG_SHADOW_STEP, &[&src], &dst, &u.bytes(), None)?;
            src = dst.clone();
            std::mem::swap(&mut dst, &mut spare);
        }
        u.a = [0.0, 0.0, 0.0, opacity];
        u.b = [color[0], color[1], color[2], 1.0];
        self.record(&mut enc, Kernel::LONG_SHADOW_APPLY, &[image, &src], out, &u.bytes(), None)
    }
}

/// Look of the Outline pass (texture px for the sizes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutlineStyle {
    pub width: f32,
    pub softness: f32,
    pub color: [f32; 3],
    /// 0 outside, 1 inside, 2 center.
    pub position: i32,
}

fn vec4_bytes(v: [f32; 4]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}
