//! The second reference graph (Swift `ReferenceFamilies`): one picture through every shader family that is not an effect
//! filter (source conversion, temporal stats / deflicker / denoise / trails, spatial denoise, both color chain entries,
//! optical flow, film look, drop shadow, outline, long shadow, anti-flicker, mask scope, transition cover / pre-blur /
//! mix, scopes) and the draws (layer, layer + look, fused transition, blend mode via the destination copy, present).
//! Uniforms are packed by byte offset from the Slang structs.

use super::kernels::{Dispatch, Kernel, Kernels, Scratch};
use super::reference_graph::{
    GRAPH_HEIGHT, GRAPH_OUTLINE, WIDTH, bytes8, cos_approx, float_bytes, gaussian_weights, input_pixels, sin_approx,
};
use super::uniforms::Block;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::{Blend, Primitive, RenderKey};
use std::f32::consts::PI;
use std::sync::Arc;

const F16: PixelFormat = PixelFormat::Rgba16Float;

/// `CompositeU` (Parts/CompositeU.slang, 368 bytes): full-range BT.709 Y'CbCr matrix, one layer of `size` on `canvas`.
fn composite(mode: u32, canvas: [f32; 2], size: [f32; 2]) -> Block {
    let mut b = Block::new(368);
    b.f(0, &[1.0, 1.0, 1.0, 0.0]).f(16, &[0.0, -0.187_324, 1.8556, 0.0]).f(32, &[1.5748, -0.468_124, 0.0, 0.0]); // m0...m2
    b.f(64, &[1.0, 0.0, 1.0, -0.5]); // range
    b.f(80, &[canvas[0], canvas[1], size[0], size[1]]); // canvas, size
    b.f(112, &[1.0, 1.0, 1.0, 0.0, 1.0]); // scale, rotCos, rotSin, opacity
    b.u(132, &[mode]);
    b.f(152, &size); // maskSize
    b.f(272, &[1.0, 0.0, 1.0, 0.0]).f(288, &[1.0, 0.0, 1.0, 0.0]); // cc0, cc1 neutral
    b
}

/// Y'CbCr planes (full range) of the test picture moved `shift` px right and scaled in brightness by `gain`: luma
/// (Y, Y, Y, 1) full size, chroma (Cb, Cr, 0, 1) half size; rgba32Float rows.
fn planes(shift: usize, gain: f32) -> (Vec<f32>, Vec<f32>) {
    let (w, h) = (WIDTH as usize, GRAPH_HEIGHT as usize);
    let src = input_pixels();
    let rgb = |x: usize, y: usize| {
        let i = (y * w + x.saturating_sub(shift).min(w - 1)) * 4;
        [src[i] * gain, src[i + 1].min(1.0) * gain, src[i + 2] * gain]
    };
    let mut luma = vec![1.0f32; w * h * 4];
    let mut chroma = vec![1.0f32; w / 2 * (h / 2) * 4];
    for y in 0..h {
        for x in 0..w {
            let c = rgb(x, y);
            let yy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            let i = (y * w + x) * 4;
            luma[i..i + 3].fill(yy);
            if x % 2 == 0 && y % 2 == 0 {
                let j = ((y / 2) * (w / 2) + x / 2) * 4;
                chroma[j] = (c[2] - yy) / 1.8556 + 0.5;
                chroma[j + 1] = (c[0] - yy) / 1.5748 + 0.5;
                chroma[j + 2] = 0.0;
            }
        }
    }
    (luma, chroma)
}

/// Recording state of the graph: one command buffer, the kernels and the scratch textures.
struct Graph {
    gpu: Arc<Gpu>,
    kernels: Kernels,
    cb: GpuCommands,
    scratch: Scratch,
}

type Inputs<'a> = &'a [(usize, &'a GpuTexture)];
type Buffers<'a> = &'a [(usize, &'a wgpu::Buffer)];

impl Graph {
    fn tex(&self, w: u32, h: u32) -> GpuTexture {
        self.gpu.texture(w, h, F16)
    }

    fn buffer(&self, words: &[u32]) -> wgpu::Buffer {
        let buffer = self.gpu.storage_buffer(words.len() as u64 * 4);
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        self.gpu.queue().write_buffer(&buffer, 0, &bytes);
        buffer
    }

    fn run(
        &mut self,
        kernel: Kernel,
        inputs: Inputs<'_>,
        output: &GpuTexture,
        blocks: &[&Block],
        buffers: Buffers<'_>,
        grid: Option<(u32, u32)>,
    ) -> Result<(), GpuError> {
        let bytes: Vec<Vec<u8>> = blocks.iter().map(|b| b.bytes()).collect();
        let constants: Vec<&[u8]> = bytes.iter().map(Vec::as_slice).collect();
        let mut enc = self.cb.compute();
        Dispatch { kernel, inputs, buffers, constants: &constants, output, grid }.record(&self.gpu, &mut enc)
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(
        &mut self,
        key: RenderKey,
        target: &GpuTexture,
        clear: Option<[f64; 4]>,
        inputs: Inputs<'_>,
        blocks: &[&Block],
        buffers: Buffers<'_>,
    ) -> Result<(), GpuError> {
        let pipeline = self.gpu.render_pipeline(key)?;
        let mut enc = self.cb.render(target, clear);
        enc.set_pipeline(&pipeline);
        for (slot, texture) in inputs {
            enc.set_input(texture, *slot)?;
        }
        for (slot, buffer) in buffers {
            enc.set_buffer(buffer, *slot)?;
        }
        for (slot, block) in blocks.iter().enumerate() {
            enc.set_constants(&block.bytes(), slot)?;
        }
        enc.draw(if key.primitive == Primitive::TriangleStrip { 4 } else { 3 }, 1)
    }

    /// rgba32Float CPU rows to a GPU rgba16Float texture (blendFrames with weight 0 copies an opaque picture).
    fn upload(&mut self, px: &[f32], w: u32, h: u32) -> Result<GpuTexture, GpuError> {
        let staging = self.gpu.texture(w, h, PixelFormat::Rgba32Float);
        self.gpu.upload_texture(&staging, &float_bytes(px), w * 16);
        let t = self.tex(w, h);
        self.kernels.blend_frames(&mut self.cb, &staging, &staging, &t, 0.0, false)?;
        Ok(t)
    }
}

fn layer_key(module: &'static str, fragment: &'static str, blend: Blend, primitive: Primitive) -> RenderKey {
    let vertex = if module == "Present" { "presentVertex" } else { "compositeVertex" };
    RenderKey { module, vertex, fragment, format: F16, blend, primitive }
}

const fn k(module: &'static str, name: &'static str) -> Kernel {
    Kernel::new(module, name)
}

/// The families graph, `WIDTH x GRAPH_HEIGHT`: 8-bit BT.709 code values from the present draw, alpha 255.
#[allow(clippy::too_many_lines)]
pub fn render(gpu: &Arc<Gpu>) -> Result<Vec<u8>, GpuError> {
    let (w, h) = (WIDTH, GRAPH_HEIGHT);
    let (fw, fh) = (w as f32, h as f32);
    let canvas = [fw, fh];
    let mut g =
        Graph { gpu: Arc::clone(gpu), kernels: Kernels::new(gpu), cb: gpu.commands(), scratch: Scratch::new(gpu) };

    // Three frames (before, center, after) as Y'CbCr planes: moving and flickering.
    let (mut lumas, mut chromas) = (Vec::new(), Vec::new());
    for (shift, gain) in [(0, 0.92f32), (3, 1.0), (6, 1.06)] {
        let (luma, chroma) = planes(shift, gain);
        lumas.push(g.upload(&luma, w, h)?);
        chromas.push(g.upload(&chroma, w / 2, h / 2)?);
    }
    let ycc = composite(0, canvas, canvas);
    let scratch = g.tex(w, h); // output of the passes that only write data buffers

    // Source conversion: the before and center frames, the after frame at half size (scaled).
    let convert = k("SourceConvert", "convertToRGB");
    let convert_scaled = k("SourceConvert", "convertToRGBScaled");
    let mut conv = Block::new(16);
    conv.u(8, &[2]); // transfer 2: averages in light
    let (s0, s1, small) = (g.tex(w, h), g.tex(w, h), g.tex(w / 2, h / 2));
    g.run(convert, &[(0, &lumas[0]), (1, &chromas[0])], &s0, &[&ycc, &conv], &[], None)?;
    g.run(convert, &[(0, &lumas[1]), (1, &chromas[1])], &s1, &[&ycc, &conv], &[], None)?;
    g.run(convert_scaled, &[(0, &lumas[2]), (1, &chromas[2])], &small, &[&ycc, &conv], &[], None)?;

    // Temporal: tile means of every frame (stats order: center, before, after), deflicker gains, denoise, trails.
    let (tiles_x, tiles_y) = (4u32, 3u32);
    let tiles = tiles_x * tiles_y;
    let means = g.buffer(&vec![0; 3 * tiles as usize]);
    let gains = g.buffer(&vec![0; 3 * tiles as usize]);
    for (frame, frame_index) in [1usize, 0, 2].into_iter().enumerate() {
        let mut su = Block::new(16);
        su.u(0, &[frame as u32, tiles_x, tiles_y]);
        g.run(
            k("TemporalStats", "temporalStats"),
            &[(0, &lumas[frame_index]), (1, &chromas[frame_index])],
            &scratch,
            &[&ycc, &su],
            &[(2, &means)],
            Some((tiles_x * 16, tiles_y * 16)),
        )?;
    }
    let mut du = Block::new(32);
    du.u(0, &[3, tiles, 1, 1, 1, 0]).f(24, &[0.8]);
    g.run(k("DeflickerGains", "deflickerGains"), &[], &scratch, &[&du], &[(2, &means), (3, &gains)], Some((tiles, 1)))?;
    let mut tu = Block::new(48);
    tu.u(0, &[3, 1, 1, 1 | 2 | 4]).f(16, &[0.12, 0.1, 0.25, 0.2]).u(32, &[2, 9, tiles_x, tiles_y]);
    let denoised = g.tex(w, h);
    g.run(
        k("TemporalDenoise", "temporalDenoise"),
        &[(0, &lumas[1]), (11, &chromas[1]), (1, &lumas[0]), (12, &chromas[0]), (2, &lumas[2]), (13, &chromas[2])],
        &denoised,
        &[&ycc, &tu],
        &[(3, &gains)],
        None,
    )?;
    let mut ru = Block::new(48);
    ru.u(0, &[2, 1, 0]).f(16, &[0.5, 0.25]);
    let trails = g.tex(w, h);
    g.run(
        k("TemporalTrails", "temporalTrails"),
        &[(0, &lumas[1]), (9, &chromas[1]), (1, &lumas[0]), (10, &chromas[0]), (2, &lumas[2]), (11, &chromas[2])],
        &trails,
        &[&ycc, &ru],
        &[],
        None,
    )?;
    let (temporal, smooth) = (g.tex(w, h), g.tex(w, h));
    g.kernels.blend_frames(&mut g.cb, &denoised, &trails, &temporal, 0.4, false)?;
    let mut sp = Block::new(32);
    sp.u(0, &[2, 1]).f(8, &[0.08, 0.06]);
    g.run(k("SpatialDenoise", "spatialDenoise"), &[(0, &temporal)], &smooth, &[&sp], &[], None)?;

    // Color chain: basic (white balance matrix, exposure, contrast) + curves, then a vignette in place.
    let mut chain = Block::new(3104);
    chain.u(0, &[2, 0, 3, 2]); // 2 blocks, source-encoded to working-linear, Rec.709
    chain.u(32, &[1, 1, 7, 0]).f(48, &[1.25, 1.15]); // basic: matrix + exposure + contrast
    chain.f(72, &[1.0, 0.0, 0.2126, 0.7152, 0.0722]); // saturation 1, vibrance 0, luma weights
    chain.f(112, &[1.06, 0.0, 0.0, 0.0]).f(128, &[0.0, 1.0, 0.0, 0.0]).f(144, &[0.0, 0.0, 0.9, 0.0]);
    chain.u(160, &[4, 1, 0, 0]); // curves, table 0
    let mut curves = Block::new(3072);
    for i in 0..64 {
        let x = i as f32 / 63.0;
        let s = x * x * (3.0 - 2.0 * x);
        curves.f(i * 16, &[0.6 * s + 0.4 * x, 0.7 * s + 0.3 * x, 0.5 * s + 0.5 * x, 0.0]);
    }
    let graded = g.tex(w, h);
    g.run(k("ColorChain", "colorChain"), &[(0, &smooth)], &graded, &[&chain, &curves], &[], None)?;
    let mut vignette = Block::new(3104);
    vignette.u(0, &[1, 1, 1, 2]).u(32, &[6, 1, 0, 0]).f(48, &[-1.2, 0.35, 0.6, 2.0]);
    g.run(k("ColorChainInPlace", "colorChainInPlace"), &[], &graded, &[&vignette, &curves], &[], None)?;

    // Optical flow between the before and center frames: coarse level from zero, fine level from the coarse one,
    // backward field, trust both ways, the picture halfway.
    let (f_w, f_h) = (w / 4, h / 4);
    let (c_w, c_h) = (f_w.div_ceil(2), f_h.div_ceil(2));
    let mut fu = Block::new(48);
    fu.u(0, &[3]).f(4, &[1e-3, 1.0 / 8.0, 1.5, 0.5]).u(20, &[1]).f(24, &[4.0, 4.0, 0.15]);
    let mut fu_up = fu.clone();
    fu_up.u(36, &[1]);
    let flow = |name| k("OpticalFlow", name);
    let fine = |g: &Graph| g.tex(f_w, f_h);
    let coarse = |g: &Graph| g.tex(c_w, c_h);
    let (l0, l1, c0, c1) = (fine(&g), fine(&g), coarse(&g), coarse(&g));
    let (g0, g1, cg0, cg1) = (fine(&g), fine(&g), coarse(&g), coarse(&g));
    let (cv0, cf, cm) = (coarse(&g), coarse(&g), coarse(&g));
    let (up, fwd, fwd_m, zero, bwd) = (fine(&g), fine(&g), fine(&g), fine(&g), fine(&g));
    let (bwd_m, trust_f, trust_b, between) = (fine(&g), fine(&g), fine(&g), g.tex(w, h));
    g.run(flow("ofLuma"), &[(0, &s0)], &l0, &[&fu], &[], None)?;
    g.run(flow("ofLuma"), &[(0, &s1)], &l1, &[&fu], &[], None)?;
    g.run(flow("ofDown"), &[(0, &l0)], &c0, &[&fu], &[], None)?;
    g.run(flow("ofDown"), &[(0, &l1)], &c1, &[&fu], &[], None)?;
    g.run(flow("ofGrad"), &[(0, &c0)], &cg0, &[&fu], &[], None)?;
    g.run(flow("ofGrad"), &[(0, &c1)], &cg1, &[&fu], &[], None)?;
    g.run(flow("ofUp"), &[(0, &cm)], &cv0, &[&fu], &[], None)?; // hasPrev 0: zero field
    g.run(flow("ofLK"), &[(0, &c0), (1, &cg0), (2, &c1), (3, &cg1), (4, &cv0)], &cf, &[&fu], &[], None)?;
    g.run(flow("ofMedian"), &[(0, &cf)], &cm, &[&fu], &[], None)?;
    g.run(flow("ofUp"), &[(0, &cm)], &up, &[&fu_up], &[], None)?;
    g.run(flow("ofGrad"), &[(0, &l0)], &g0, &[&fu], &[], None)?;
    g.run(flow("ofGrad"), &[(0, &l1)], &g1, &[&fu], &[], None)?;
    g.run(flow("ofLK"), &[(0, &l0), (1, &g0), (2, &l1), (3, &g1), (4, &up)], &fwd, &[&fu], &[], None)?;
    g.run(flow("ofMedian"), &[(0, &fwd)], &fwd_m, &[&fu], &[], None)?;
    g.run(flow("ofUp"), &[(0, &cm)], &zero, &[&fu], &[], None)?;
    g.run(flow("ofLK"), &[(0, &l1), (1, &g1), (2, &l0), (3, &g0), (4, &zero)], &bwd, &[&fu], &[], None)?;
    g.run(flow("ofMedian"), &[(0, &bwd)], &bwd_m, &[&fu], &[], None)?;
    g.run(flow("ofConfidence"), &[(0, &l0), (1, &l1), (2, &fwd_m), (3, &bwd_m)], &trust_f, &[&fu], &[], None)?;
    g.run(flow("ofConfidence"), &[(0, &l1), (1, &l0), (2, &bwd_m), (3, &fwd_m)], &trust_b, &[&fu], &[], None)?;
    g.run(flow("ofInterpolate"), &[(0, &s0), (1, &s1), (2, &trust_f), (3, &trust_b)], &between, &[&fu], &[], None)?;

    // Graded picture over the in-between frame, given the test picture's alpha falloff, premultiplied; film look (every
    // flag); drop shadow; outline; long shadow; anti-flicker.
    let (mixed, cut, pm, look) = (g.tex(w, h), g.tex(w, h), g.tex(w, h), g.tex(w, h));
    g.kernels.blend_frames(&mut g.cb, &graded, &between, &mixed, 0.35, false)?;
    let picture = g.upload(&input_pixels(), w, h)?;
    g.kernels.blend_frames(&mut g.cb, &mixed, &picture, &cut, 0.7, false)?;
    g.kernels.premultiply(&mut g.cb, &cut, &pm)?;
    let mut lu = Block::new(112);
    lu.f(0, &[fw, fh, 0.3, 0.5]).u(16, &[1 | 8 | 16 | 32 | 64, 11, 23, 5]);
    lu.f(32, &[0.4, 2.1, 0.5, 0.5])
        .f(48, &[0.3, 4.0, 0.5, 0.0])
        .f(64, &[2.0, 1.0])
        .f(80, &[0.5, 0.2, 0.4])
        .f(96, &[0.8, 0.8, 0.5]);
    g.run(k("FilmLook", "filmLook"), &[(0, &pm)], &look, &[&lu], &[], None)?;
    let mut shadow = Block::new(48);
    shadow.f(0, &[6.0, 4.0]).f(16, &[0.05, 0.0, 0.1, 0.7]).f(36, &[0.2]);
    let (alpha, alpha_b, shadowed) = (g.tex(w, h), g.tex(w, h), g.tex(w, h));
    g.run(k("DropShadow", "shadowExtract"), &[(0, &look)], &alpha, &[&shadow], &[], None)?;
    g.kernels.blur(&mut g.cb, &alpha, &alpha_b, &gaussian_weights(2.5), None)?;
    g.run(k("DropShadow", "shadowComposite"), &[(0, &look), (1, &alpha)], &shadowed, &[&shadow], &[], None)?;
    let (outlined, long, calm) = (g.tex(w, h), g.tex(w, h), g.tex(w, h));
    g.kernels.outline(&mut g.cb, &shadowed, &outlined, &[8, 4, 2, 1], GRAPH_OUTLINE, &mut g.scratch)?;
    g.kernels.long_shadow(
        &mut g.cb,
        &outlined,
        &long,
        (w, h),
        &[[4.0, 3.0, 0.9], [8.0, 6.0, 0.8]],
        [0.1, 0.0, 0.2],
        0.6,
        &mut g.scratch,
    )?;
    g.kernels.anti_flicker(&mut g.cb, &long, &calm, 0.2)?;

    // Mask scope: the effect (calm) shows inside a soft pentagon intersected with a color range, the plain picture outside.
    let mut mask: Vec<f32> = vec![8.0, 5.0, 0.0, 0.0, 14.0, 0.0, 1.0, 0.0, 13.0, 3.0, 2.0, 0.0, 0.0, 0.0, 1.0, 10.0];
    for i in 0..5 {
        let a = i as f32 * 2.0 * PI / 5.0 - PI / 2.0;
        mask.extend([cos_approx(a) * 70.0, sin_approx(a) * 70.0]);
    }
    mask.extend([0.6, 0.5, 0.4, 0.35, 0.2, 0.0]);
    let mask_data = g.buffer(&mask.iter().map(|v| v.to_bits()).collect::<Vec<_>>());
    let mut scope = composite(3, canvas, canvas);
    scope.u(316, &[2]);
    let scoped = g.tex(w, h);
    g.run(k("MaskScope", "maskScopeMix"), &[(0, &pm), (1, &calm)], &scoped, &[&scope], &[(2, &mask_data)], None)?;

    // Transition: smallest alpha of both sides, a mirrored pre-blur of side A, a wipe between it and the small frame.
    let cover = g.buffer(&[1.0f32.to_bits(), 1.0f32.to_bits()]);
    let c0u = Block::new(16);
    let mut c1u = Block::new(16);
    c1u.u(0, &[1]);
    let cover_min = k("TransitionCover", "transitionCoverMin");
    g.run(cover_min, &[(0, &scoped)], &scratch, &[&c0u], &[(2, &cover)], Some((320, 192)))?;
    g.run(cover_min, &[(0, &small)], &scratch, &[&c1u], &[(2, &cover)], Some((160, 96)))?;
    let mut side = Block::new(48);
    side.f(0, &[0.02, 0.0, 0.01, 0.0, 1.05, 1.0, 0.0, 0.0, 0.05, 1.0]);
    let mut pre = Block::new(16);
    pre.f(0, &[fw, fh]);
    let (side_a, wipe) = (g.tex(w, h), g.tex(w, h));
    g.run(k("TransitionPreBlur", "transitionPreBlur"), &[(0, &scoped)], &side_a, &[&side, &pre], &[(2, &cover)], None)?;
    let mut tr = Block::new(128);
    tr.f(0, &[0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, -0.03, 0.01, 0.005, 0.0, 1.1, 0.9, 0.2, 0.0, 0.1, 0.0]);
    tr.f(80, &[0.8, 0.6, 0.5, 0.1]).u(96, &[3]).f(100, &[2.0, 1.0, 1.0, 1.0]);
    g.run(k("TransitionMix", "transitionMix"), &[(0, &side_a), (1, &small)], &wipe, &[&tr], &[(2, &cover)], None)?;

    // Scopes of the wipe: luma waveform and histograms, their maximum, the normalized waveform as a picture.
    let (wave_w, wave_l) = (64u32, 64u32);
    let hist = wave_w * wave_l;
    let max_slot = hist + 4 * 256;
    let counts = g.buffer(&vec![7; max_slot as usize + 1]);
    let wave = g.tex(wave_w, wave_l);
    let scope_u = |offset: u32, count: u32| {
        let mut b = Block::new(80);
        b.u(0, &[w, h, 1, 1 | 8, wave_w, wave_l, 64, 64, 0, 0, 0, hist]);
        b.u(48, &[offset, count, max_slot]).u(64, &[wave_w, wave_l]);
        b
    };
    let scopes = |name| k("Scopes", name);
    g.run(
        scopes("scopeClear"),
        &[],
        &wave,
        &[&scope_u(0, max_slot + 1)],
        &[(2, &counts)],
        Some((64, (max_slot + 64) / 64)),
    )?;
    g.run(scopes("scopeAccumulate"), &[(0, &wipe)], &wave, &[&scope_u(0, 0)], &[(2, &counts)], Some((w, h)))?;
    g.run(scopes("scopeFindMax"), &[], &wave, &[&scope_u(0, hist)], &[(2, &counts)], Some((64, 64)))?;
    g.run(scopes("scopeResolve"), &[], &wave, &[&scope_u(0, hist)], &[(2, &counts)], None)?;

    // Draws on the canvas: the wipe as a turned, rounded, masked layer; the waveform with grain and scanlines; the fused
    // transition (light leak) at half opacity; a solid in the Color blend mode (destination read from a copy); present.
    let (target, destination) = (g.tex(w, h), g.tex(w, h));
    let over = Blend::PremultipliedOver;
    let strip = Primitive::TriangleStrip;
    let mut layer = composite(3, canvas, canvas);
    layer.f(96, &[10.0, -6.0, 0.0, 0.0, 0.85, 0.85, cos_approx(0.14), sin_approx(0.14), 1.0]);
    layer.f(140, &[12.0]).f(160, &[0.02, 0.03, 0.04, 0.01]).u(316, &[1]);
    g.draw(
        layer_key("Layer", "compositeFragment", over, strip),
        &target,
        Some([0.03, 0.03, 0.05, 1.0]),
        &[(0, &wipe)],
        &[&layer],
        &[(2, &mask_data)],
    )?;

    let mut wave_layer = composite(1, canvas, [wave_w as f32, wave_l as f32]);
    wave_layer.f(96, &[-110.0, -45.0]).f(112, &[1.2, 1.2]).f(128, &[0.9]);
    let mut wave_look = lu.clone();
    wave_look.u(16, &[1 | 8]);
    g.draw(
        layer_key("LayerLook", "compositeFragmentLook", over, strip),
        &target,
        None,
        &[(0, &wave)],
        &[&wave_layer, &wave_look],
        &[(2, &mask_data)],
    )?;

    let mut full = composite(3, canvas, canvas);
    full.f(128, &[0.5]);
    // Light leak, not glitch: the glitch's 24 row bands are 7.5 px on this 180-row canvas, so pixel centers sit exactly on
    // band edges where the backends' rounding picks different bands (also why the grain size is 2.1, not 2).
    let mut leak = tr.clone();
    leak.u(96, &[6]);
    g.draw(
        layer_key("LayerTransition", "compositeFragmentTransition", over, strip),
        &target,
        None,
        &[(0, &side_a), (1, &small)],
        &[&full, &leak],
        &[(2, &cover)],
    )?;

    g.cb.copy(&target, &destination);
    let mut solid = composite(2, canvas, [120.0, 70.0]);
    solid.f(48, &[0.9, 0.2, 0.05, 1.0]).f(96, &[70.0, 30.0]).f(128, &[0.8]).u(148, &[25]);
    g.draw(
        layer_key("Layer", "compositeFragmentBlend", Blend::Replace, strip),
        &target,
        None,
        &[(6, &destination)],
        &[&solid],
        &[],
    )?;

    let mut pu = Block::new(96);
    pu.f(0, &[1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]).f(48, &[0.0, 1.0, 0.8, 1.1]);
    let shown = g.tex(w, h);
    let out = gpu.texture(w, h, PixelFormat::Rgba32Float);
    g.draw(
        layer_key("Present", "presentFragment", Blend::Replace, Primitive::Triangles),
        &shown,
        None,
        &[(0, &target)],
        &[&pu],
        &[],
    )?;
    g.kernels.blend_frames(&mut g.cb, &shown, &shown, &out, 0.0, false)?;
    let ticket = g.cb.read_texture(&out)?;
    let Graph { cb, scratch, .. } = g;
    gpu.submit(cb);
    let raw = ticket.wait(gpu)?;
    drop(scratch);
    Ok(bytes8(&raw))
}
