// Swift: GPUCompositor.swift, GPUCompositor+Resample.swift
//! The compositor on `sq-gpu`: the render-node tree drawn with the Slang layer draws, uniform blocks ([`Uniforms`]) and
//! placement maths. Covered here: pictures (Y'CbCr planes, RGBA, linear premultiplied rasters incl. partial ones), solids and
//! placeholders, transform, opacity, tilt, corner radius, every blend mode (the destination is copied to input 6 before a
//! blending draw, which D3D12 needs: it has no framebuffer fetch), footage fill (stencil and inverted), nested groups, pairs,
//! adjustment layers and fused transitions (with mirrored edges and the long-blur pre-pass), clip grades through the color
//! chain.
//!
//! The clip effect chain, frame blending, temporal filters and Picture mattes belong to the effect passes (R4b): they plug in
//! through [`EffectHooks`]; the default hooks draw a layer plainly and skip the rest.

use std::collections::HashMap;
use std::sync::Arc;

use sq_core_effects::transition::TransitionRender;
use sq_core_model::{BlendMode, ClipTransform, SequenceFormat};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::SQFrame;
use sq_gpu::frames::{GpuTexture, PooledTexture};
use sq_gpu::gpu::{Gpu, GpuCommands, RenderEncoder};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::{Blend, Primitive, RenderKey};

use super::color_chain::GpuColorChain;
use super::layer::{
    AdjustmentNode, CompositorError, Content, OpticalFlowRequest, PlaceholderKind, RenderLayer, RenderNode,
    TemporalFrames,
};
use super::pixel_formats;
use super::plan::shader_index;
use super::resolver::LayerColorResolver;
use super::uniforms::{
    ConvertUniforms, PreBlurUniforms, TransitionUniforms, Uniforms, lin, long_blur_target, placeholder_linear,
    radius_factor,
};
use crate::color::pipeline::ColorPipeline;
use crate::effects::blend_modes;

const F16: PixelFormat = PixelFormat::Rgba16Float;
/// Largest side of the long-blur pre-pass canvas.
const MAX_INTERMEDIATE_SIDE: i64 = 16384;
/// Solid-color textures kept (never rewritten, so a frame in flight never sees a change).
const SOLID_TEXTURES: usize = 8;

/// What a decoded picture holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PictureKind {
    /// Y'CbCr: `planes.0` luma (read from r), `planes.1` interleaved Cb Cr (read from r g); unorm samples of `bit_depth`
    /// (10 bit MSB-aligned in 16) or float planes holding the same 0...1 values.
    Ycbcr { bit_depth: u32, full_range: bool },
    /// R'G'B'A, display-encoded BT.709. `alpha_mode` as `Uniforms::alpha_mode` (0: premultiplied, 1: straight).
    Rgba { alpha_mode: u32 },
}

/// A decoded source picture already on the GPU.
#[derive(Clone)]
pub struct Picture {
    pub planes: (GpuTexture, Option<GpuTexture>),
    pub kind: PictureKind,
}

impl Picture {
    pub fn ycbcr(luma: GpuTexture, chroma: GpuTexture, bit_depth: u32, full_range: bool) -> Picture {
        Picture { planes: (luma, Some(chroma)), kind: PictureKind::Ycbcr { bit_depth, full_range } }
    }

    pub fn rgba(texture: GpuTexture, alpha_mode: u32) -> Picture {
        Picture { planes: (texture, None), kind: PictureKind::Rgba { alpha_mode } }
    }
}

/// Turns a layer's frame into GPU planes (upload or wrap); `None` draws the damaged placeholder.
pub type PictureSource<'a> = &'a dyn Fn(&SQFrame) -> Option<Picture>;

/// One draw on the target.
#[derive(Clone)]
pub struct Draw {
    pub u: Uniforms,
    pub tex0: Option<GpuTexture>,
    pub tex1: Option<GpuTexture>,
    pub blend: BlendMode,
    pub stencil: bool,
    pub mix: Option<TransitionUniforms>,
    /// Converts a corner radius in clip px (fitted into the canvas) to layer px.
    pub radius_factor: f64,
    /// Clip mask entries and the matte texture they read; `None` = none.
    pub mask_data: Option<wgpu::Buffer>,
    pub matte: Option<GpuTexture>,
    /// Picture mask images (inputs 4 / 5).
    pub picture0: Option<GpuTexture>,
    pub picture1: Option<GpuTexture>,
    /// A transition's measured side coverage (mirrored edges); `None` = both sides cover.
    pub cover: Option<wgpu::Buffer>,
}

impl Draw {
    pub fn new(u: Uniforms, tex0: Option<GpuTexture>, tex1: Option<GpuTexture>) -> Draw {
        Draw {
            u,
            tex0,
            tex1,
            blend: BlendMode::Normal,
            stencil: false,
            mix: None,
            radius_factor: 1.0,
            mask_data: None,
            matte: None,
            picture0: None,
            picture1: None,
            cover: None,
        }
    }
}

/// The parts of the compositor that belong to the clip effect passes. Every hook has the plain-draw default, so the core
/// compositor renders without effects; the effect passes (R4b) implement them through the compositor's public surface
/// (`acquire`, `draw_all`, `plain`, `gpu`, `picture_scopes`, `render_into`).
pub trait EffectHooks: Send + Sync {
    /// A new `render` begins: per-render caches are released.
    fn begin_render(&self) {}

    /// The draw of one layer (or group) turns into the draws that show it with its clip effects: Crop, Rounded Corners,
    /// Gaussian Blur, shadows, filters, keys, masks, film look. Default: a layer whose crop took the whole picture draws
    /// nothing, any other is drawn as it is with its blend mode.
    fn finish_layer(
        &self,
        _c: &mut GpuCompositor,
        mut draw: Draw,
        layer: &RenderLayer,
        _format: &SequenceFormat,
        _cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        if layer.effects.is_empty() {
            return Ok(());
        }
        draw.blend = layer.blend_mode;
        draws.push(draw);
        Ok(())
    }

    /// Renders the Picture mattes of this level; returns whether a matte scope was pushed (it is popped after the level).
    /// Default: none.
    fn encode_picture_mattes(
        &self,
        _c: &mut GpuCompositor,
        _nodes: &[RenderNode],
        _format: &SequenceFormat,
        _cmds: &mut GpuCommands,
        _pictures: PictureSource,
    ) -> Result<bool, CompositorError> {
        Ok(false)
    }

    /// Frame blending: both frames converted (and graded), mixed light-linear (or moved along their optical flow) into one
    /// working-linear intermediate. `None` = the layer shows its first frame. Default: `None`.
    #[allow(clippy::too_many_arguments)]
    fn blend_intermediate(
        &self,
        _c: &mut GpuCompositor,
        _a: &Picture,
        _b: &Picture,
        _weight: f32,
        _flow: Option<OpticalFlowRequest>,
        _u: &Uniforms,
        _pipeline: Option<&ColorPipeline>,
        _cmds: &mut GpuCommands,
    ) -> Result<Option<GpuTexture>, CompositorError> {
        Ok(None)
    }

    /// Deflicker, Video Denoise, Trails on the decoded frame and its neighbors; the intermediate is working-linear. Default:
    /// `None`.
    #[allow(clippy::too_many_arguments)]
    fn temporal_intermediate(
        &self,
        _c: &mut GpuCompositor,
        _center: &Picture,
        _frames: &TemporalFrames,
        _u: &Uniforms,
        _pipeline: Option<&ColorPipeline>,
        _cmds: &mut GpuCommands,
        _pictures: PictureSource,
    ) -> Result<Option<GpuTexture>, CompositorError> {
        Ok(None)
    }
}

struct NoEffects;
impl EffectHooks for NoEffects {}

/// Sides of a transition ready to mix, the mix constants and the coverage buffer.
struct Sides {
    textures: (GpuTexture, GpuTexture),
    uniforms: TransitionUniforms,
    cover: Option<wgpu::Buffer>,
}

/// The compositor. One instance renders one frame at a time (`render` takes `&mut self`).
pub struct GpuCompositor {
    gpu: Arc<Gpu>,
    hooks: Arc<dyn EffectHooks>,
    chain: GpuColorChain,
    dummy: GpuTexture,
    dummy_buffer: wgpu::Buffer,
    cover_neutral: wgpu::Buffer,
    /// Intermediates and buffers of the running render; they go back to the pool at the next `render`.
    scratch: Vec<PooledTexture>,
    scratch_buffers: Vec<wgpu::Buffer>,
    /// Full-frame intermediates taken by the last `render` (a counter for the tests and traces, no GPU cost).
    offscreens: usize,
    solid_textures: HashMap<[u8; 3], GpuTexture>,
    /// C6: the Picture matte images of the current level, innermost last.
    pub picture_scopes: Vec<HashMap<Id, GpuTexture>>,
    /// Draws whose frame could not be turned into planes.
    pub unsupported_frame_count: usize,
    /// A layer shown at half size or less runs its effect passes at half size.
    pub limits_color_work: bool,
    /// Playback preview (a canvas smaller than the sequence): graded layers convert and grade at the size they are shown at.
    pub preview_reduce: bool,
    /// Loads the LUTs of masked Color effects; `None` = masked grades without LUTs.
    pub color_resolver: Option<Arc<LayerColorResolver>>,
    /// Masked grades wait for their LUTs (export) instead of drawing the last served grade.
    pub color_resolver_blocks: bool,
}

impl GpuCompositor {
    /// A compositor on `gpu` without clip effects.
    pub fn new(gpu: &Arc<Gpu>) -> Result<GpuCompositor, CompositorError> {
        Self::with_hooks(gpu, Arc::new(NoEffects))
    }

    /// A compositor whose clip effects, frame blending, temporal filters and Picture mattes are run by `hooks`.
    pub fn with_hooks(gpu: &Arc<Gpu>, hooks: Arc<dyn EffectHooks>) -> Result<GpuCompositor, CompositorError> {
        // Fail early when a pipeline is missing.
        for key in [
            layer_key("compositeFragment", Blend::PremultipliedOver),
            layer_key("compositeFragmentBlend", Blend::Replace),
        ] {
            gpu.render_pipeline(key)?;
        }
        // Build the other pipelines a cut, a dissolve or a title stack needs now, not at their first draw during playback: the
        // first dissolve of the real project cost a 50 ms draw (GPU pipeline compile) at its start. Errors surface at the draw.
        for blend in [Blend::PremultipliedOver, Blend::Additive] {
            let _ = gpu.render_pipeline(layer_key("compositeFragment", blend));
            let _ = gpu.render_pipeline(RenderKey {
                module: "LayerTransition",
                vertex: "compositeVertex",
                fragment: "compositeFragmentTransition",
                format: F16,
                blend,
                primitive: Primitive::TriangleStrip,
            });
        }
        let _ = gpu.compute_pipeline("TransitionPreBlur", "transitionPreBlur", F16);
        let dummy = gpu.texture(1, 1, F16);
        gpu.upload_texture(&dummy, &[0u8; 8], 8);
        let dummy_buffer = gpu.storage_buffer(16);
        let cover_neutral = gpu.storage_buffer(16);
        let ones: Vec<u8> = [1.0f32, 1.0, 0.0, 0.0].iter().flat_map(|v| v.to_le_bytes()).collect();
        gpu.queue().write_buffer(&cover_neutral, 0, &ones);
        Ok(GpuCompositor {
            gpu: Arc::clone(gpu),
            hooks,
            chain: GpuColorChain::new(gpu),
            dummy,
            dummy_buffer,
            cover_neutral,
            scratch: Vec::new(),
            scratch_buffers: Vec::new(),
            offscreens: 0,
            solid_textures: HashMap::new(),
            picture_scopes: vec![HashMap::new()],
            unsupported_frame_count: 0,
            limits_color_work: true,
            preview_reduce: false,
            color_resolver: None,
            color_resolver_blocks: false,
        })
    }

    pub fn gpu(&self) -> &Arc<Gpu> {
        &self.gpu
    }

    /// The color chain (clip grades), shared with the effect passes.
    pub fn chain(&self) -> &GpuColorChain {
        &self.chain
    }

    /// A 1x1 transparent texture for unused inputs.
    pub fn dummy(&self) -> &GpuTexture {
        &self.dummy
    }

    /// Renders the tree bottom to top into `target` (half float, sequence size), over opaque black or transparent. The
    /// caller submits `cmds`. Intermediates go back to the pool at the next `render`.
    pub fn render(
        &mut self,
        nodes: &[RenderNode],
        format: &SequenceFormat,
        target: &GpuTexture,
        cmds: &mut GpuCommands,
        transparent: bool,
        pictures: PictureSource,
    ) -> Result<(), CompositorError> {
        if i64::from(target.width()) != format.width || i64::from(target.height()) != format.height {
            return Err(CompositorError::InvalidTarget(format!(
                "size {}x{} != sequence {}x{}",
                target.width(),
                target.height(),
                format.width,
                format.height
            )));
        }
        let _encode = sq_os::trace::span_args("render", "compositor encode", || format!("nodes={}", nodes.len()));
        self.scratch.clear();
        self.scratch_buffers.clear();
        self.offscreens = 0;
        self.hooks.begin_render();
        self.picture_scopes = vec![HashMap::new()];
        self.encode(nodes, format, target, cmds, [0.0, 0.0, 0.0, if transparent { 0.0 } else { 1.0 }], false, pictures)
    }

    /// Hands the render's intermediates back to the texture pool. Call right after the commands of the last `render` were
    /// submitted: the queue runs in order, so a reused texture is safe, and the pool's byte cap then frees what does not fit.
    /// Without it every intermediate (a 4K half-float one is 63 MB) stayed borrowed until the next render, which on a machine
    /// that shares RAM with the GPU held ~60 textures (3-6 GB) at Play.
    pub fn release_scratch(&mut self) {
        self.scratch.clear();
        self.scratch_buffers.clear();
        self.hooks.begin_render();
    }

    /// A half-float picture stretched to `target`'s size, alpha kept: an image-sequence frame at another size than the
    /// sequence (one bilinear tap per output pixel, clamped to the edge). Drawn as the plain layer (mode 3).
    pub fn resample_linear(
        &mut self,
        source: &GpuTexture,
        target: &GpuTexture,
        cmds: &mut GpuCommands,
    ) -> Result<(), CompositorError> {
        let canvas = canvas_format(i64::from(target.width()), i64::from(target.height()));
        let d = self.plain(source, &canvas, [target.width() as f32, target.height() as f32]);
        self.draw_all(cmds, &[d], target, Some([0.0; 4]), false)
    }

    /// A pooled half-float texture that stays reserved until the next `render`.
    #[track_caller]
    pub fn acquire(&mut self, w: i64, h: i64) -> GpuTexture {
        let t = self.gpu.acquire(w.max(1) as u32, h.max(1) as u32, F16);
        let tex = GpuTexture::clone(&t);
        self.offscreens += 1;
        self.scratch.push(t);
        tex
    }

    /// How many intermediates the last `render` acquired.
    pub fn offscreens(&self) -> usize {
        self.offscreens
    }

    /// A zeroed data buffer that stays reserved until the next `render`.
    pub fn scratch_buffer(&mut self, length: u64) -> wgpu::Buffer {
        let b = self.gpu.storage_buffer(length);
        self.scratch_buffers.push(b.clone());
        b
    }

    /// Composites `nodes` into `target` (`clear` = its first color; `additive_onto`: add onto its content instead).
    #[allow(clippy::too_many_arguments)]
    pub fn encode(
        &mut self,
        nodes: &[RenderNode],
        format: &SequenceFormat,
        target: &GpuTexture,
        cmds: &mut GpuCommands,
        clear: [f64; 4],
        additive_onto: bool,
        pictures: PictureSource,
    ) -> Result<(), CompositorError> {
        let hooks = Arc::clone(&self.hooks);
        let scoped = hooks.encode_picture_mattes(self, nodes, format, cmds, pictures)?;
        let result = (|| {
            let mut draws = Vec::new();
            for node in nodes {
                self.queue(node, format, cmds, &mut draws, pictures)?;
            }
            self.draw_all(cmds, &draws, target, if additive_onto { None } else { Some(clear) }, additive_onto)
        })();
        if scoped {
            self.picture_scopes.pop();
        }
        result
    }

    /// The plain draw of `tex` (mode 3, identity placement) at `size` on `canvas`.
    pub fn plain(&self, tex: &GpuTexture, canvas: &SequenceFormat, size: [f32; 2]) -> Draw {
        let mut u = Uniforms { mode: 3, ..Uniforms::default() };
        u.layer_geometry(&ClipTransform::IDENTITY, canvas, size, 0.0);
        Draw::new(u, Some(tex.clone()), None)
    }

    fn queue(
        &mut self,
        node: &RenderNode,
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
        pictures: PictureSource,
    ) -> Result<(), CompositorError> {
        let transparent = [0.0; 4];
        match node {
            RenderNode::Layer(layer) if layer.stencil() => {
                let mut inner = layer.clone();
                let opacity = inner.transform.opacity.clamp(0.0, 1.0);
                inner.transform.opacity = 1.0;
                inner.footage_fill = None;
                inner.blend_mode = BlendMode::Normal;
                let stencil = RenderNode::Stencil { opacity, children: vec![RenderNode::Layer(inner)] };
                self.queue(&stencil, format, cmds, draws, pictures)
            }
            RenderNode::Layer(layer) => {
                if let Some(d) = self.prepare_layer(layer, format, cmds, pictures)? {
                    let hooks = Arc::clone(&self.hooks);
                    hooks.finish_layer(self, d, layer, format, cmds, draws)?;
                }
                Ok(())
            }
            RenderNode::Group { format: gf, transform, opacity, corner_radius, children } => {
                self.group(gf, transform, *opacity, *corner_radius, children, None, format, cmds, pictures, draws)
            }
            RenderNode::StyledGroup {
                format: gf,
                transform,
                opacity,
                corner_radius,
                children,
                effects,
                blend_mode,
            } => self.group(
                gf,
                transform,
                *opacity,
                *corner_radius,
                children,
                Some((effects, *blend_mode)),
                format,
                cmds,
                pictures,
                draws,
            ),
            RenderNode::Pair { format: pf, first, second } => {
                let tex = self.acquire(pf.width, pf.height);
                self.encode(first, pf, &tex, cmds, transparent, false, pictures)?;
                self.encode(second, pf, &tex, cmds, transparent, true, pictures)?;
                draws.push(self.plain(&tex, &format.stored_pixels(), [pf.width as f32, pf.height as f32]));
                Ok(())
            }
            RenderNode::Transition { format: pf, render, first, second } => {
                let a = self.acquire(pf.width, pf.height);
                let b = self.acquire(pf.width, pf.height);
                self.encode(first, pf, &a, cmds, transparent, false, pictures)?;
                self.encode(second, pf, &b, cmds, transparent, false, pictures)?;
                let sides = self.transition_sides(render, &a, &b, pf, cmds)?;
                let size = [pf.width as f32, pf.height as f32];
                let mut d = self.plain(&sides.textures.0, &format.stored_pixels(), size);
                d.tex1 = Some(sides.textures.1.clone());
                d.mix = Some(sides.uniforms);
                d.cover = sides.cover.clone();
                if pf.width != format.width || pf.height != format.height {
                    // The fused draw reads the sides at target pixels: another canvas size gets its mix drawn first.
                    let mixed = self.acquire(pf.width, pf.height);
                    let mut m = self.plain(&sides.textures.0, &pf.stored_pixels(), size);
                    m.tex1 = Some(sides.textures.1.clone());
                    m.mix = d.mix;
                    m.cover = sides.cover;
                    self.draw_all(cmds, &[m], &mixed, Some(transparent), false)?;
                    d = self.plain(&mixed, &format.stored_pixels(), size);
                }
                draws.push(d);
                Ok(())
            }
            RenderNode::Adjustment(a, below) => self.adjustment_node(a, below, format, cmds, pictures, draws),
            RenderNode::Stencil { opacity, children } => {
                let tex = self.acquire(format.width, format.height);
                self.encode(children, format, &tex, cmds, transparent, false, pictures)?;
                let mut d = self.plain(&tex, &format.stored_pixels(), [format.width as f32, format.height as f32]);
                d.u.opacity = *opacity as f32;
                d.stencil = true;
                draws.push(d);
                Ok(())
            }
            RenderNode::PictureMatte { .. } | RenderNode::PictureScope => Ok(()),
            RenderNode::Blended(inner, mode) => {
                let n = draws.len();
                self.queue(inner, format, cmds, draws, pictures)?;
                if draws.len() > n {
                    let last = draws.len() - 1;
                    if *mode != BlendMode::Normal
                        && let Some(mix) = draws[last].mix
                    {
                        // The blending draw reads one texture: the transition's mix is drawn first.
                        let mixed = self.acquire(format.width, format.height);
                        let mut m = draws[last].clone();
                        m.mix = Some(mix);
                        self.draw_all(cmds, &[m], &mixed, Some(transparent), false)?;
                        draws[last] =
                            self.plain(&mixed, &format.stored_pixels(), [format.width as f32, format.height as f32]);
                    }
                    draws[last].blend = *mode;
                }
                Ok(())
            }
        }
    }

    /// A nested sequence's children composited offscreen, queued as one layer with the nested clip's effects.
    #[allow(clippy::too_many_arguments)]
    fn group(
        &mut self,
        gf: &SequenceFormat,
        transform: &ClipTransform,
        opacity: f64,
        radius: f64,
        children: &[RenderNode],
        styled: Option<(&sq_core_effects::effects_evaluation::ClipEffects, BlendMode)>,
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let tex = self.acquire(gf.width, gf.height);
        // A nested level: its Picture masks read only its own mattes.
        self.picture_scopes.push(HashMap::new());
        let inner = self.encode(children, gf, &tex, cmds, [0.0; 4], false, pictures);
        self.picture_scopes.pop();
        inner?;
        let mut u = Uniforms { mode: 3, ..Uniforms::default() };
        let factor = radius_factor(gf.display_width(), gf.height, format);
        u.layer_geometry(transform, format, [gf.display_width() as f32, gf.height as f32], radius * factor);
        u.opacity = (transform.opacity * opacity).clamp(0.0, 1.0) as f32;
        let mut d = Draw::new(u, Some(tex), None);
        d.radius_factor = factor;
        let mut layer = RenderLayer::new(Content::Placeholder(PlaceholderKind::Loading));
        layer.corner_radius = radius;
        if let Some((effects, blend)) = styled {
            layer.effects = effects.clone();
            layer.blend_mode = blend;
        }
        let hooks = Arc::clone(&self.hooks);
        hooks.finish_layer(self, d, &layer, format, cmds, draws)
    }

    /// An Adjustment Layer: `below` composited into one image, drawn plainly (`draws_base`) and again graded, with the
    /// effects, Motion (or the mean of its sub-frame copies), opacity and blend mode.
    fn adjustment_node(
        &mut self,
        a: &AdjustmentNode,
        below: &[RenderNode],
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let tex = self.acquire(format.width, format.height);
        self.encode(below, format, &tex, cmds, [0.0; 4], false, pictures)?;
        let size = [format.display_width() as f32, format.height as f32];
        let base = self.plain(&tex, format, size);
        if a.draws_base {
            draws.push(base.clone());
        }
        let mut src = base;
        if let Some(pipeline) = &a.color_pipeline {
            // The composite BT.709-encoded, graded in place, drawn straight.
            let mid = self.acquire(format.width, format.height);
            self.encode_709(cmds, &tex, &mid)?;
            self.chain.encode(cmds, pipeline, &mid, false)?;
            src.tex0 = Some(mid);
            src.u.mode = 1;
            src.u.linearize = 0;
            src.u.alpha_mode = 1;
        }
        self.adjustment(a, &src, size, format, cmds, draws)
    }

    /// Premultiplied working-linear to straight BT.709-encoded, alpha kept (Adjustment Layer grade input).
    fn encode_709(&self, cmds: &mut GpuCommands, src: &GpuTexture, dst: &GpuTexture) -> Result<(), CompositorError> {
        let kernel = self.gpu.compute_pipeline("Pointwise", "premultipliedLinearToEncoded709", F16)?;
        let mut enc = cmds.compute();
        enc.set_pipeline(&kernel);
        enc.set_input(src, 0)?;
        enc.set_output(dst);
        enc.set_constants(&[0u8; 16], 0)?;
        enc.dispatch(src.width(), src.height())?;
        Ok(())
    }

    /// The effects, Motion (or the mean of its sub-frame copies), opacity and blend mode of an adjustment over its input
    /// `src` (the composite below, or its graded copy).
    pub fn adjustment(
        &mut self,
        a: &AdjustmentNode,
        src: &Draw,
        size: [f32; 2],
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let factor = radius_factor(format.display_width(), format.height, format);
        let mut styled = RenderLayer::new(Content::Placeholder(PlaceholderKind::Loading));
        styled.corner_radius = a.corner_radius;
        styled.effects = a.effects.clone();
        styled.blend_mode = a.blend_mode;
        let adjusted = |t: &ClipTransform, opacity: f64| -> Draw {
            let mut p = src.clone();
            p.u.layer_geometry(t, format, size, a.corner_radius * factor);
            p.u.opacity = opacity as f32;
            p.radius_factor = factor;
            p
        };
        let hooks = Arc::clone(&self.hooks);
        if a.motion_samples.len() <= 1 {
            return hooks.finish_layer(self, adjusted(&a.transform, a.opacity), &styled, format, cmds, draws);
        }
        let sum = self.acquire(format.width, format.height);
        let mut normal = styled;
        normal.blend_mode = BlendMode::Normal;
        let n = a.motion_samples.len() as f64;
        for (k, t) in a.motion_samples.iter().enumerate() {
            let mut copy = Vec::new();
            hooks.finish_layer(self, adjusted(t, 1.0 / n), &normal, format, cmds, &mut copy)?;
            self.draw_all(cmds, &copy, &sum, if k > 0 { None } else { Some([0.0; 4]) }, k > 0)?;
        }
        let mut p = self.plain(&sum, format, size);
        p.u.opacity = a.opacity as f32;
        p.blend = a.blend_mode;
        draws.push(p);
        Ok(())
    }

    /// A transition's sides: a side with mirrored edges is measured first (any pixel below full alpha turns its mirror
    /// off), a side with a long blur runs the pre-pass onto a grown canvas.
    fn transition_sides(
        &mut self,
        render: &TransitionRender,
        a: &GpuTexture,
        b: &GpuTexture,
        pf: &SequenceFormat,
        cmds: &mut GpuCommands,
    ) -> Result<Sides, CompositorError> {
        let mut tu = TransitionUniforms::new(render);
        let canvas = [pf.width as f32, pf.height as f32];
        let mut sides = [a.clone(), b.clone()];
        let mut cover = None;
        let mirrored = [tu.a.mirror > 0.5 && tu.a.opacity > 0.0, tu.b.mirror > 0.5 && tu.b.opacity > 0.0];
        if mirrored[0] || mirrored[1] {
            let buf = self.scratch_buffer(256);
            let mut ones = [0u8; 256];
            ones[..4].copy_from_slice(&1.0f32.to_le_bytes());
            ones[4..8].copy_from_slice(&1.0f32.to_le_bytes());
            self.gpu.queue().write_buffer(&buf, 0, &ones);
            let kernel = self.gpu.compute_pipeline("TransitionCover", "transitionCoverMin", F16)?;
            let mut enc = cmds.compute();
            enc.set_pipeline(&kernel);
            enc.set_buffer(&buf, 2)?;
            for (i, on) in mirrored.iter().enumerate().filter(|(_, on)| **on) {
                enc.set_input(&sides[i], 0)?;
                let mut c = Vec::new();
                for v in [i as u32, 0, 0, 0] {
                    c.extend_from_slice(&v.to_le_bytes());
                }
                enc.set_constants(&c, 0)?;
                // Whole 16 x 16 groups: the kernel's group minimum needs every thread (extra ones count as opaque).
                let _ = on;
                enc.dispatch(((pf.width + 15) / 16 * 16) as u32, ((pf.height + 15) / 16 * 16) as u32)?;
            }
            drop(enc);
            cover = Some(buf);
        }
        let pre_pass = [tu.a.split_long_blur(canvas), tu.b.split_long_blur(canvas)];
        for (i, pre) in pre_pass.into_iter().enumerate() {
            let Some((side, needed)) = pre else { continue };
            let (needed, tw, th) = long_blur_target(pf.width, pf.height, needed, MAX_INTERMEDIATE_SIDE);
            if i == 0 {
                tu.a.scale = 1.0 + 2.0 * needed;
            } else {
                tu.b.scale = 1.0 + 2.0 * needed;
            }
            let t = self.acquire(tw, th);
            let pre_u = PreBlurUniforms { canvas, pad: needed, slot: i as u32 };
            let kernel = self.gpu.compute_pipeline("TransitionPreBlur", "transitionPreBlur", F16)?;
            let mut enc = cmds.compute();
            enc.set_pipeline(&kernel);
            enc.set_input(&sides[i], 0)?;
            enc.set_output(&t);
            enc.set_constants(&side.to_bytes(), 0)?;
            enc.set_constants(&pre_u.to_bytes(), 1)?;
            enc.set_buffer(cover.as_ref().unwrap_or(&self.cover_neutral), 2)?;
            enc.dispatch(tw as u32, th as u32)?;
            drop(enc);
            sides[i] = t;
        }
        let [s0, s1] = sides;
        Ok(Sides { textures: (s0, s1), uniforms: tu, cover })
    }

    /// The draw of one leaf layer.
    fn prepare_layer(
        &mut self,
        layer: &RenderLayer,
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
    ) -> Result<Option<Draw>, CompositorError> {
        let canvas_size = [format.display_width() as f32, format.height as f32];
        let fill = |color: [f32; 4]| -> Draw {
            let mut u = Uniforms { mode: 2, solid: color, ..Uniforms::default() };
            u.layer_geometry(&layer.transform, format, canvas_size, layer.corner_radius);
            Draw::new(u, None, None)
        };
        match &layer.content {
            Content::Placeholder(kind) => {
                Ok((*kind != PlaceholderKind::Loading).then(|| fill(placeholder_linear(*kind))))
            }
            Content::Solid { red, green, blue } => {
                // A graded solid (Color Matte with a grade) runs the picture path on a tiny flat frame stretched to the
                // canvas, so it grades with the same code as footage.
                if layer.color_pipeline.is_some() {
                    let t = self.solid_texture(*red, *green, *blue);
                    let mut framed = layer.clone();
                    framed.native_size = Some((format.display_width(), format.height));
                    framed.temporal = None;
                    framed.blend = None;
                    return self.frame_draw(&Picture::rgba(t, 0), &solid_hint(), &framed, format, cmds, pictures);
                }
                Ok(Some(fill([lin(*red), lin(*green), lin(*blue), 1.0])))
            }
            Content::LinearPremultiplied { frame, width, height } => {
                let Some(pic) = pictures(frame).filter(|p| matches!(p.kind, PictureKind::Rgba { .. })) else {
                    self.unsupported_frame_count += 1;
                    return Ok(Some(fill(placeholder_linear(PlaceholderKind::Damaged))));
                };
                let t0 = pic.planes.0;
                let mut u = Uniforms { mode: 3, ..Uniforms::default() };
                if let Some(cp) = layer.content_part {
                    if !cp.holds(i64::from(t0.width()), i64::from(t0.height())) {
                        self.unsupported_frame_count += 1;
                        return Ok(Some(fill(placeholder_linear(PlaceholderKind::Damaged))));
                    }
                    u.part = [cp.x as f32, cp.y as f32, cp.whole_width as f32, cp.whole_height as f32];
                }
                u.layer_geometry(&layer.transform, format, [*width as f32, *height as f32], layer.corner_radius);
                Ok(Some(Draw::new(u, Some(t0), None)))
            }
            Content::Frame { frame, color_hint } => {
                let Some(pic) = pictures(frame) else {
                    self.unsupported_frame_count += 1;
                    return Ok(Some(fill(placeholder_linear(PlaceholderKind::Damaged))));
                };
                self.frame_draw(&pic, color_hint, layer, format, cmds, pictures)
            }
        }
    }

    /// 2 x 2 RGBA8 textures of one display-encoded color, kept for the last few colors.
    fn solid_texture(&mut self, r: f32, g: f32, b: f32) -> GpuTexture {
        let byte = |v: f32| (v * 255.0).round().clamp(0.0, 255.0) as u8;
        let key = [byte(r), byte(g), byte(b)];
        if let Some(t) = self.solid_textures.get(&key) {
            return t.clone();
        }
        let t = self.gpu.texture(2, 2, PixelFormat::Rgba8Unorm);
        let px: Vec<u8> = (0..16).map(|i| if i % 4 == 3 { 255 } else { key[i % 4] }).collect();
        self.gpu.upload_texture(&t, &px, 8);
        if self.solid_textures.len() >= SOLID_TEXTURES {
            self.solid_textures.clear();
        }
        self.solid_textures.insert(key, t.clone());
        t
    }

    /// The draw of a decoded picture (`Frame` content, also a graded solid's flat frame).
    fn frame_draw(
        &mut self,
        pic: &Picture,
        hint: &sq_core_model::VideoTrackInfo,
        layer: &RenderLayer,
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
    ) -> Result<Option<Draw>, CompositorError> {
        let mut u = Uniforms::default();
        let (w, h) = (i64::from(pic.planes.0.width()), i64::from(pic.planes.0.height()));
        let quarter = ((hint.rotation / 90) & 3) as u32;
        let (nw, nh) = layer.native_size.unwrap_or((w, h));
        let (dw, dh) = if quarter & 1 == 1 { (nh, nw) } else { (nw, nh) };
        match pic.kind {
            PictureKind::Ycbcr { bit_depth, full_range } => {
                if pic.planes.1.is_none() {
                    self.unsupported_frame_count += 1;
                    u.mode = 2;
                    u.solid = placeholder_linear(PlaceholderKind::Damaged);
                    u.layer_geometry(
                        &layer.transform,
                        format,
                        [format.display_width() as f32, format.height as f32],
                        layer.corner_radius,
                    );
                    return Ok(Some(Draw::new(u, None, None)));
                }
                u.mode = 0;
                u.range = pixel_formats::range_params(bit_depth, full_range);
            }
            PictureKind::Rgba { alpha_mode } => {
                u.mode = 1;
                u.alpha_mode = alpha_mode;
                u.range = pixel_formats::range_params(8, true);
            }
        }
        u.m = pixel_formats::ycbcr_to_rgb(pixel_formats::matrix(hint.matrix.as_deref()));
        u.quarter = quarter;
        let factor = radius_factor(dw, dh, format);
        u.layer_geometry(&layer.transform, format, [dw as f32, dh as f32], layer.corner_radius * factor);
        let hooks = Arc::clone(&self.hooks);
        let pipeline = layer.color_pipeline.as_deref();
        let intermediate_alpha = |u: &mut Uniforms| {
            u.mode = 1;
            u.linearize = 0;
            u.alpha_mode = if u.alpha_mode == 0 { 0 } else { 1 };
        };
        if let Some(tf) = layer.temporal.as_ref().filter(|tf| !tf.filter.is_identity()) {
            // Deflicker, Video Denoise, Trails: already working-linear.
            if let Some(mid) = hooks.temporal_intermediate(self, pic, tf, &u, pipeline, cmds, pictures)? {
                intermediate_alpha(&mut u);
                let mut d = Draw::new(u, Some(mid), None);
                d.radius_factor = factor;
                return Ok(Some(d));
            }
        }
        if let Some(b) = layer.blend.as_ref().filter(|b| b.weight > 0.0)
            && let Some(next) = pictures(&b.next)
        {
            // Frame blending: both frames converted (and graded), mixed light-linear.
            if let Some(mid) = hooks.blend_intermediate(self, pic, &next, b.weight, b.flow, &u, pipeline, cmds)? {
                intermediate_alpha(&mut u);
                let mut d = Draw::new(u, Some(mid), None);
                d.radius_factor = factor;
                return Ok(Some(d));
            }
        }
        if let Some(pipeline) = pipeline {
            // The grade: conversion to source-encoded R'G'B' at the texture size, the chain in place, then drawn as
            // working-linear straight (premultiplied sources stay premultiplied).
            let transfer = shader_index(pipeline.source());
            let mid = match self.preview_grade_size(&layer.transform, (w, h), (nw, nh)) {
                // Preview: convert (averaging the covered texels in light) and grade at the size the layer is shown at.
                Some((rw, rh)) => {
                    let mid = self.acquire(rw, rh);
                    self.convert_scaled(cmds, pic, &u, transfer, &mid)?;
                    mid
                }
                None => {
                    let mid = self.acquire(w, h);
                    self.convert(cmds, pic, &u, transfer, &mid)?;
                    mid
                }
            };
            self.chain.encode(cmds, pipeline, &mid, quarter & 1 == 1)?;
            intermediate_alpha(&mut u);
            let mut d = Draw::new(u, Some(mid), None);
            d.radius_factor = factor;
            return Ok(Some(d));
        }
        let mut d = Draw::new(u, Some(pic.planes.0.clone()), pic.planes.1.clone());
        d.radius_factor = factor;
        Ok(Some(d))
    }

    /// Preview only (`preview_reduce`): the size a graded layer converts and grades at, `None` = the texture size. The layer is
    /// shown at `scale` canvas px per native px, its texture holds `texture / native` texels per native px; the grade runs at
    /// one texel per canvas px (at least 2 x 2 source texels per output texel, at most 4 x 4: the kernel's sampling).
    fn preview_grade_size(&self, t: &ClipTransform, texture: (i64, i64), native: (i64, i64)) -> Option<(i64, i64)> {
        if !self.preview_reduce {
            return None;
        }
        preview_shown_size(t, texture, native)
    }

    /// `convert` at the size of `out` (any ratio; `convertToRGBScaled`).
    pub fn convert_scaled(
        &self,
        cmds: &mut GpuCommands,
        pic: &Picture,
        u: &Uniforms,
        transfer: u32,
        out: &GpuTexture,
    ) -> Result<(), CompositorError> {
        let kernel = self.gpu.compute_pipeline("SourceConvert", "convertToRGBScaled", F16)?;
        let mut enc = cmds.compute();
        enc.set_pipeline(&kernel);
        enc.set_input(&pic.planes.0, 0)?;
        enc.set_input(pic.planes.1.as_ref().unwrap_or(&self.dummy), 1)?;
        enc.set_constants(&u.to_bytes(), 0)?;
        enc.set_constants(&ConvertUniforms { origin: [0, 0], transfer }.to_bytes(), 1)?;
        enc.set_output(out);
        enc.dispatch(out.width(), out.height())?;
        Ok(())
    }

    /// Source planes to R'G'B' (source-encoded) at the texture size, into `out` (the `convertToRGB` kernel).
    pub fn convert(
        &self,
        cmds: &mut GpuCommands,
        pic: &Picture,
        u: &Uniforms,
        transfer: u32,
        out: &GpuTexture,
    ) -> Result<(), CompositorError> {
        let kernel = self.gpu.compute_pipeline("SourceConvert", "convertToRGB", F16)?;
        let mut enc = cmds.compute();
        enc.set_pipeline(&kernel);
        enc.set_input(&pic.planes.0, 0)?;
        enc.set_input(pic.planes.1.as_ref().unwrap_or(&self.dummy), 1)?;
        enc.set_constants(&u.to_bytes(), 0)?;
        enc.set_constants(&ConvertUniforms { origin: [0, 0], transfer }.to_bytes(), 1)?;
        enc.set_output(out);
        enc.dispatch(pic.planes.0.width(), pic.planes.0.height())?;
        Ok(())
    }

    /// Records `draws` onto `target`. A blending draw (blend mode or stencil) ends the pass, copies the target to input 6 and
    /// draws on a new pass that keeps the target.
    pub fn draw_all(
        &mut self,
        cmds: &mut GpuCommands,
        draws: &[Draw],
        target: &GpuTexture,
        clear: Option<[f64; 4]>,
        additive: bool,
    ) -> Result<(), CompositorError> {
        let wants_blend = |d: &Draw| (d.blend != BlendMode::Normal || d.stencil) && d.mix.is_none();
        // Segments: the first (possibly empty, it clears) and one per blending draw.
        let mut starts = vec![0];
        starts.extend(draws.iter().enumerate().filter(|(i, d)| *i > 0 && wants_blend(d)).map(|(i, _)| i));
        if draws.first().is_some_and(wants_blend) {
            starts = std::iter::once(0).chain(starts.into_iter().filter(|s| *s != 0)).collect();
        }
        let first_blends = draws.first().is_some_and(wants_blend);
        let mut segments: Vec<&[Draw]> = Vec::new();
        if first_blends {
            segments.push(&[]);
        }
        for (k, s) in starts.iter().enumerate() {
            let end = starts.get(k + 1).copied().unwrap_or(draws.len());
            segments.push(&draws[*s..end]);
        }
        let mut destination: Option<GpuTexture> = None;
        for (n, seg) in segments.iter().enumerate() {
            let copy = if seg.first().is_some_and(wants_blend) {
                let c = match &destination {
                    Some(c) => c.clone(),
                    None => {
                        let c = self.acquire(i64::from(target.width()), i64::from(target.height()));
                        destination = Some(c.clone());
                        c
                    }
                };
                cmds.copy(target, &c);
                Some(c)
            } else {
                None
            };
            let mut pass = cmds.render(target, if n == 0 { clear } else { None });
            for d in seg.iter() {
                self.draw_one(&mut pass, d, additive, copy.as_ref())?;
            }
        }
        Ok(())
    }

    fn draw_one(
        &self,
        pass: &mut RenderEncoder,
        d: &Draw,
        additive: bool,
        copy: Option<&GpuTexture>,
    ) -> Result<(), CompositorError> {
        let mut u = d.u.clone();
        let blending = (d.blend != BlendMode::Normal || d.stencil) && d.mix.is_none();
        let key = if blending {
            u.blend = if d.stencil { blend_modes::STENCIL_SHADER_ID } else { blend_modes::shader_id(d.blend) };
            layer_key("compositeFragmentBlend", Blend::Replace)
        } else if d.mix.is_some() {
            u.blend = 0;
            RenderKey {
                module: "LayerTransition",
                vertex: "compositeVertex",
                fragment: "compositeFragmentTransition",
                format: F16,
                blend: if additive { Blend::Additive } else { Blend::PremultipliedOver },
                primitive: Primitive::TriangleStrip,
            }
        } else {
            u.blend = 0;
            layer_key("compositeFragment", if additive { Blend::Additive } else { Blend::PremultipliedOver })
        };
        pass.set_pipeline(&self.gpu.render_pipeline(key)?);
        if let Some(copy) = copy.filter(|_| blending) {
            pass.set_input(copy, 6)?;
        }
        pass.set_constants(&u.to_bytes(), 0)?;
        let tex = |t: &Option<GpuTexture>| t.clone().unwrap_or_else(|| self.dummy.clone());
        pass.set_input(&tex(&d.tex0), 0)?;
        pass.set_input(&tex(&d.tex1), 1)?;
        pass.set_input(&tex(&d.matte), 3)?;
        pass.set_input(&tex(&d.picture0), 4)?;
        pass.set_input(&tex(&d.picture1), 5)?;
        if let Some(tu) = &d.mix {
            pass.set_constants(&tu.to_bytes(), 1)?;
            pass.set_buffer(d.cover.as_ref().unwrap_or(&self.cover_neutral), 2)?;
        } else {
            pass.set_buffer(d.mask_data.as_ref().unwrap_or(&self.dummy_buffer), 2)?;
        }
        pass.draw(4, 1)?;
        Ok(())
    }
}

fn layer_key(fragment: &'static str, blend: Blend) -> RenderKey {
    RenderKey {
        module: "Layer",
        vertex: "compositeVertex",
        fragment,
        format: F16,
        blend,
        primitive: Primitive::TriangleStrip,
    }
}

/// A square-pixel canvas of the given stored size.
fn canvas_format(width: i64, height: i64) -> SequenceFormat {
    SequenceFormat {
        width,
        height,
        frame_duration: Time::new(1, 25),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: sq_core_model::UnknownKeys::default(),
    }
}

fn solid_hint() -> sq_core_model::VideoTrackInfo {
    sq_core_model::VideoTrackInfo {
        width: 2,
        height: 2,
        codec: "rgba".into(),
        bit_depth: 8,
        chroma: "4:4:4".into(),
        nominal_frame_duration: Time::new(1, 25),
        is_variable_frame_rate: false,
        color_primaries: None,
        transfer: None,
        matrix: None,
        rotation: 0,
        pixel_aspect: sq_core_model::PixelAspect::square(),
        pixel_aspect_override: None,
        field_order: None,
        deinterlace_off: false,
    }
}

/// Preview only: the size (in texels of a `texture`-sized picture) a layer is shown at, `None` = it is shown larger than half
/// its texture, tilted or its size unknown. The layer is shown at `scale` canvas px per native px, its texture holds
/// `texture / native` texels per native px; the grade (and the Gyroflow warp) runs at one texel per canvas px.
pub fn preview_shown_size(t: &ClipTransform, texture: (i64, i64), native: (i64, i64)) -> Option<(i64, i64)> {
    if t.is_tilted() || native.0 <= 0 || native.1 <= 0 {
        return None;
    }
    let shown = t.scale.x.max(t.scale.y) * native.0 as f64 / texture.0 as f64;
    if !(shown > 0.0 && shown <= 0.5) {
        return None;
    }
    let rw = ((texture.0 as f64 * shown).ceil() as i64).max(1);
    let rh = ((texture.1 as f64 * shown).ceil() as i64).max(1);
    (rw >= 64 && rh >= 64).then_some((rw, rh))
}
