// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Windows/SQWinApp WinCompositor.swift (render, layer(for:), presentPass, download*), WinTimelineFrameSource.swift
// (the compositing half)
//! The program compositor: one display frame from `LayerRequest`s. Media layers come from the caller's `source` (a decoded
//! `SQFrame` whose storage `planes::to_gpu` turns into textures), titles, shapes, Lottie and captions as premultiplied linear
//! [`Raster`]s the caller drew, solids and adjustment layers are built here. The node tree is drawn by the clip-effect
//! compositor into a half-float canvas and the Present pass writes BT.709 code values into an RGBA8 texture.
//! shortcut: text / shape / Lottie / caption rasters and the Magic matte store are the caller's (the playback and export
//! crates own those engines); this module only uploads and places what they hand over.

use super::planes::{PlaneCache, PlaneError, PlaneKey, to_gpu};
use crate::color::pipeline::ColorPipeline;
use crate::compositor::{CompositorError, Content, GpuCompositor, Picture, PlaceholderKind, RenderLayer, RenderNode};
use crate::gpu_effects::ClipEffectHooks;
use sq_core_effects::adjustment_clip::ADJUSTMENT_KIND;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_masks::SubjectMatte;
use sq_core_model::{ClipTransform, MaskSource, SequenceFormat, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
use sq_gpu::frames::{GpuFrame, GpuTexture};
use sq_gpu::gpu::{Admit, FRAMES_IN_FLIGHT, Gpu, GpuCommands, GpuError, InFlight, Waited, wait_in_slices};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::{Blend, Primitive, RenderKey};
use sq_gpu::readback::ReadbackTicket;
use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};

const SOLID_KIND: &str = "solid";

#[derive(Debug)]
pub enum ProgramError {
    Compositor(CompositorError),
    Gpu(GpuError),
    Plane(PlaneError),
    /// The GPU still ran the frame before the previous one when the wait ran out: nothing was recorded, the frame is
    /// dropped (playback) and the caller composites the then-current frame later.
    GpuBusy,
}

impl fmt::Display for ProgramError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Compositor(e) => write!(f, "compositor: {e}"),
            Self::Gpu(e) => write!(f, "compositor: {e}"),
            Self::Plane(e) => write!(f, "compositor: {e}"),
            Self::GpuBusy => write!(f, "compositor: the GPU is still busy with earlier frames"),
        }
    }
}

impl std::error::Error for ProgramError {}

impl From<CompositorError> for ProgramError {
    fn from(e: CompositorError) -> Self {
        Self::Compositor(e)
    }
}
impl From<GpuError> for ProgramError {
    fn from(e: GpuError) -> Self {
        Self::Gpu(e)
    }
}
impl From<PlaneError> for ProgramError {
    fn from(e: PlaneError) -> Self {
        Self::Plane(e)
    }
}

/// One decoded picture of a media layer: the cache key parts, the frame (any storage `to_gpu` knows) and the track facts
/// (rotation, matrix). `proxy`: the picture is the media's proxy; `divisor`: the decode reduction.
#[derive(Clone)]
pub struct Source {
    pub media: Id,
    pub index: i64,
    pub frame: SQFrame,
    pub info: VideoTrackInfo,
    pub proxy: bool,
    pub divisor: u32,
    /// The Gyroflow warp of this frame (the layer's Stabilizer uses Gyroflow and its analysis is ready): the picture is
    /// resampled with it before anything else. `None` = unwarped.
    pub gyro: Option<Arc<super::gyro_warp::WarpMap>>,
}

/// A premultiplied linear Rec.709 RGBA float picture (a title, shape, Lottie frame or caption) and where it sits. `key`
/// names the picture: the same key in the next frame reuses the upload.
#[derive(Clone)]
pub struct Raster {
    pub key: u64,
    pub width: u32,
    pub height: u32,
    /// `width * height * 4` floats, rows top down.
    pub pixels: Arc<Vec<f32>>,
    /// Size of the layer in sequence px (the picture may be a rasterized part of it).
    pub layer_width: f64,
    pub layer_height: f64,
    pub transform: ClipTransform,
    pub corner_radius: f64,
    pub footage_fill: Option<crate::compositor::FootageFill>,
    /// See `RenderLayer::sample_transforms`.
    pub sample_transforms: Vec<ClipTransform>,
}

/// What a layer request shows.
#[derive(Clone)]
pub enum LayerSource {
    /// The media is offline: the offline slate.
    Offline,
    /// Nothing to draw (empty text, shape off, failed raster): invisible.
    Hidden,
    /// A decoded video or image picture.
    Media(Source),
    /// A PNG's straight RGBA, drawn with its transparency; kept on the GPU per media.
    Still { media: Id, width: u32, height: u32, rgba: Arc<Vec<u8>>, info: VideoTrackInfo },
    /// A drawn generator.
    Raster(Raster),
}

type Grade<'a> = &'a dyn Fn(&LayerRequest) -> Option<Arc<ColorPipeline>>;
type Mattes<'a> = &'a dyn Fn(&LayerRequest) -> HashMap<Id, Arc<SubjectMatte>>;

/// What `render` asks the caller for.
pub struct Inputs<'a> {
    /// The clip or adjustment-layer grade (the layer color resolver).
    pub grade: Grade<'a>,
    /// Color page Split: the same layers graded again, shown on the left `width` columns of the output.
    pub split: Option<(Grade<'a>, u32)>,
    /// Magic masks read the mattes picked and tracked on this source frame.
    pub mattes: Option<Mattes<'a>>,
    /// The picture of a request.
    pub source: &'a dyn Fn(&LayerRequest) -> LayerSource,
}

/// Per-frame choices.
#[derive(Default)]
pub struct RenderOptions {
    /// Present resamples the sequence-sized composite to this size (export scaling); `None` = the sequence size.
    pub output_size: Option<(u32, u32)>,
    /// Transparency grid: the composite starts transparent and Present lays it over the checkerboard.
    pub transparent: bool,
    /// Record the readback of the output into the frame's command buffer.
    pub readback: bool,
    /// The caption layers on top of the picture.
    pub captions: Vec<Raster>,
    /// How long `render` waits for the GPU to finish the frame before the previous one when two frames are in flight
    /// already. `Some(d)`: at most `d`, then `render` gives up with [`ProgramError::GpuBusy`] (playback drops the frame).
    /// `None`: as long as it takes (export and a paused picture never drop), up to [`GPU_WAIT_LIMIT`].
    pub gpu_wait: Option<Duration>,
    /// Asked between the slices of that wait: true ends it (the caller has a command queued: Stop must not sit behind a 30 s
    /// wait on a GPU that stopped answering). `render` then gives up with [`ProgramError::GpuBusy`] and the caller draws
    /// the frame again after its command. `None` (the export): the wait always runs its whole bound.
    pub abandon_wait: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}

/// The longest `render` waits when it never drops (a GPU that stopped answering ends in an error, not a hang).
pub const GPU_WAIT_LIMIT: Duration = Duration::from_secs(30);

/// A submitted frame. The GPU may still run it; `readback.wait` / `download_rgba8` wait for it.
pub struct RenderedFrame {
    /// The linear half-float composite.
    pub working: GpuTexture,
    /// BT.709 code values, RGBA8.
    pub output: GpuTexture,
    pub readback: Option<ReadbackTicket>,
    /// CPU milliseconds (layers, uploads, recording).
    pub milliseconds: f64,
    /// Milliseconds spent waiting for the GPU to finish an earlier frame (back-pressure), not part of `milliseconds`.
    pub gpu_wait_ms: f64,
}

/// Which uploaded picture a layer's frame stands for.
struct Slot(usize);
impl SQFrameStorage for Slot {}

fn slot_frame(width: usize, height: usize, format: SQFramePixelFormat, slot: usize) -> SQFrame {
    SQFrame::new(width, height, format, SQFrameColorSpace::Unspecified, Time::new(0, 1), Arc::new(Slot(slot)))
}

/// How many finished composites the compositor rotates through.
pub const OUTPUT_RING: usize = 4;

/// The program picture of one device.
pub struct ProgramCompositor {
    gpu: Arc<Gpu>,
    compositor: GpuCompositor,
    planes: PlaneCache,
    working: Option<GpuTexture>,
    /// A ring of finished composites: the UI thread reads the newest one while the next render already runs.
    outputs: Vec<GpuTexture>,
    next_output: usize,
    split_working: Option<GpuTexture>,
    linear_output: Option<GpuTexture>,
    /// The frames the GPU has not finished: a new one is recorded only when fewer than `FRAMES_IN_FLIGHT` are.
    in_flight: InFlight<wgpu::SubmissionIndex>,
}

impl ProgramCompositor {
    pub fn new(gpu: &Arc<Gpu>) -> Result<Self, ProgramError> {
        Ok(Self {
            gpu: Arc::clone(gpu),
            compositor: ClipEffectHooks::compositor(gpu)?,
            planes: PlaneCache::new(),
            working: None,
            outputs: Vec::new(),
            next_output: 0,
            split_working: None,
            linear_output: None,
            in_flight: InFlight::new(FRAMES_IN_FLIGHT),
        })
    }

    /// Frames submitted that the GPU may still run (never more than `FRAMES_IN_FLIGHT`).
    pub fn frames_in_flight(&self) -> usize {
        self.in_flight.len()
    }

    /// The clip-effect compositor (resolver, quality switches).
    pub fn compositor_mut(&mut self) -> &mut GpuCompositor {
        &mut self.compositor
    }

    /// Forgets the uploaded planes (the engine's pictures changed size for the same frame: playback quality).
    pub fn drop_planes(&mut self) {
        self.planes.clear();
    }

    /// Composites `requests` (bottom to top) at the sequence size and presents. The frame is submitted without waiting for
    /// itself, but never more than `FRAMES_IN_FLIGHT` frames queue on the GPU: before recording, `render` waits for the frame
    /// before the previous one (`options.gpu_wait`) so an overloaded GPU slows the producer down instead of piling up memory.
    pub fn render(
        &mut self,
        requests: &[LayerRequest],
        format: &SequenceFormat,
        options: &RenderOptions,
        inputs: &Inputs<'_>,
    ) -> Result<RenderedFrame, ProgramError> {
        let waited = Instant::now();
        let bound = options.gpu_wait.unwrap_or(GPU_WAIT_LIMIT);
        let gpu = &self.gpu;
        let abandon = || options.abandon_wait.as_ref().is_some_and(|f| f());
        let mut abandoned = false;
        let busy = self.in_flight.admit(|index| match wait_in_slices(bound, &abandon, |d| gpu.wait_for(index, d)) {
            Waited::Finished => true,
            Waited::TimedOut => false,
            Waited::Abandoned => {
                abandoned = true;
                false
            }
        });
        if busy == Admit::Busy {
            return Err(if options.gpu_wait.is_some() || abandoned {
                ProgramError::GpuBusy
            } else {
                ProgramError::Gpu(GpuError::Device("the GPU did not finish a frame in 30 s".into()))
            });
        }
        let gpu_wait_ms = waited.elapsed().as_secs_f64() * 1e3;
        let start = Instant::now();
        let mut cmds = self.gpu.commands();
        let mut pictures: Vec<Picture> = Vec::new();
        let mut kept: Vec<Arc<GpuFrame>> = Vec::new();
        let mut layers = Vec::with_capacity(requests.len());
        for l in requests {
            let mut r = self.layer_for(l, inputs.source, &mut pictures, &mut kept)?;
            let loading_placeholder = matches!(r.content, Content::Placeholder(PlaceholderKind::Loading));
            let adjustment = l.generator.as_ref().is_some_and(|g| g.kind == ADJUSTMENT_KIND);
            if !loading_placeholder || adjustment {
                r.color_pipeline = (inputs.grade)(l);
            }
            if let Some(mattes) = inputs.mattes
                && l.effects.masks.iter().any(|m| m.source == MaskSource::Magic)
            {
                r.mattes = mattes(l);
            }
            layers.push(r);
        }
        let mut caption_nodes = Vec::new();
        for c in &options.captions {
            caption_nodes.push(RenderNode::Layer(self.raster_layer(c, &mut pictures)?));
        }
        let (w, h) = (format.width as u32, format.height as u32);
        let (ow, oh) = options.output_size.unwrap_or((w, h));
        let working = self.canvas(w, h, PixelFormat::Rgba16Float, |s| &mut s.working);
        let output = self.next_output_canvas(ow, oh);

        let mut nodes = RenderNode::tree(requests, &layers);
        nodes.extend(caption_nodes.iter().cloned());
        self.draw(&nodes, format, &working, &mut cmds, options.transparent, &pictures, &mut kept)?;
        self.present(&mut cmds, &working, &output, None)?;
        if let Some((grade, columns)) = &inputs.split {
            let regraded: Vec<RenderLayer> = requests
                .iter()
                .zip(&layers)
                .map(|(l, r)| {
                    let mut r = r.clone();
                    if r.color_pipeline.is_some() {
                        r.color_pipeline = grade(l);
                    }
                    r
                })
                .collect();
            if *columns > 0 {
                let other = self.canvas(w, h, PixelFormat::Rgba16Float, |s| &mut s.split_working);
                let mut nodes = RenderNode::tree(requests, &regraded);
                nodes.extend(caption_nodes.iter().cloned());
                self.draw(&nodes, format, &other, &mut cmds, options.transparent, &pictures, &mut kept)?;
                self.present(&mut cmds, &other, &output, Some(*columns))?;
            }
        } else {
            // A second canvas is only kept while Split is showing.
            self.split_working = None;
        }
        let readback = if options.readback { Some(cmds.read_texture(&output)?) } else { None };
        for f in kept {
            cmds.keep(f);
        }
        let submission = self.gpu.submit(cmds);
        self.in_flight.submitted(submission);
        self.gpu.poll();
        self.planes.end_frame();
        Ok(RenderedFrame { working, output, readback, milliseconds: start.elapsed().as_secs_f64() * 1e3, gpu_wait_ms })
    }

    /// The RGBA8 bytes of a presented frame (rows top down, stride = width * 4).
    pub fn download_rgba8(&self, frame: RenderedFrame) -> Result<Vec<u8>, ProgramError> {
        match frame.readback {
            Some(ticket) => Ok(ticket.wait(&self.gpu)?),
            None => Ok(self.gpu.read_texture(&frame.output)?),
        }
    }

    /// The linear composite of `frame` (rgba halves, premultiplied linear Rec.709, rows top down, stride = width * 8), the
    /// image-sequence export frame. `size` other than the sequence's: stretched to it (`GpuCompositor::resample_linear`).
    pub fn download_linear(
        &mut self,
        frame: &RenderedFrame,
        size: Option<(u32, u32)>,
    ) -> Result<(Vec<u8>, u32, u32), ProgramError> {
        let (w, h) = (frame.working.width(), frame.working.height());
        match size {
            Some((sw, sh)) if (sw, sh) != (w, h) => {
                let out = self.canvas(sw, sh, PixelFormat::Rgba16Float, |s| &mut s.linear_output);
                let mut cmds = self.gpu.commands();
                self.compositor.resample_linear(&frame.working, &out, &mut cmds)?;
                self.gpu.submit_and_wait(cmds)?;
                Ok((self.gpu.read_texture(&out)?, sw, sh))
            }
            _ => Ok((self.gpu.read_texture(&frame.working)?, w, h)),
        }
    }

    /// A texture of the size and format, kept in `slot` (recreated when the size changes).
    /// The texture the next composite lands in. Every render takes the next ring slot, so a reader of the previous
    /// composite never sees a half-drawn newer one (it is safe for `OUTPUT_RING - 2` newer renders).
    fn next_output_canvas(&mut self, w: u32, h: u32) -> GpuTexture {
        if self.outputs.first().is_some_and(|t| t.width() != w || t.height() != h) {
            self.outputs.clear();
        }
        while self.outputs.len() < OUTPUT_RING {
            self.outputs.push(self.gpu.texture(w, h, PixelFormat::Rgba8Unorm));
        }
        let t = self.outputs[self.next_output % OUTPUT_RING].clone();
        self.next_output = (self.next_output + 1) % OUTPUT_RING;
        t
    }

    fn canvas(
        &mut self,
        w: u32,
        h: u32,
        format: PixelFormat,
        slot: impl Fn(&mut Self) -> &mut Option<GpuTexture>,
    ) -> GpuTexture {
        let gpu = Arc::clone(&self.gpu);
        let s = slot(self);
        match s {
            Some(t) if t.width() == w && t.height() == h => t.clone(),
            _ => {
                let t = gpu.texture(w, h, format);
                *s = Some(t.clone());
                t
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(
        &mut self,
        nodes: &[RenderNode],
        format: &SequenceFormat,
        target: &GpuTexture,
        cmds: &mut GpuCommands,
        transparent: bool,
        pictures: &[Picture],
        kept: &mut Vec<Arc<GpuFrame>>,
    ) -> Result<(), ProgramError> {
        // Frames the layers carry besides the numbered slots (blend neighbors, temporal frames) upload on demand.
        let extra = RefCell::new((kept, &mut self.planes));
        let gpu = Arc::clone(&self.gpu);
        let lookup = |f: &SQFrame| -> Option<Picture> {
            if let Some(s) = f.storage_as::<Slot>() {
                return pictures.get(s.0).cloned();
            }
            let mut guard = extra.borrow_mut();
            let (kept, planes) = &mut *guard;
            to_gpu(&gpu, f, None, planes, kept).ok()
        };
        self.compositor.render(nodes, format, target, cmds, transparent, &lookup)?;
        Ok(())
    }

    /// The monitor's Present shader from a working canvas into `output`; `scissor`: only the left columns.
    fn present(
        &self,
        cmds: &mut GpuCommands,
        canvas: &GpuTexture,
        output: &GpuTexture,
        scissor: Option<u32>,
    ) -> Result<(), ProgramError> {
        let key = RenderKey {
            module: "Present",
            vertex: "presentVertex",
            fragment: "presentFragment",
            format: PixelFormat::Rgba8Unorm,
            blend: Blend::Replace,
            primitive: Primitive::Triangles,
        };
        let pipeline = self.gpu.render_pipeline(key)?;
        let mut pass = cmds.render(output, None);
        pass.set_pipeline(&pipeline);
        pass.set_input(canvas, 0)?;
        pass.set_constants(&present_uniforms(), 0)?;
        if let Some(columns) = scissor {
            pass.set_scissor(0, 0, columns.min(output.width()), output.height());
        }
        pass.draw(3, 1)?;
        Ok(())
    }

    fn layer_for(
        &mut self,
        l: &LayerRequest,
        source: &dyn Fn(&LayerRequest) -> LayerSource,
        pictures: &mut Vec<Picture>,
        kept: &mut Vec<Arc<GpuFrame>>,
    ) -> Result<RenderLayer, ProgramError> {
        let mut hidden = l.transform;
        hidden.opacity = 0.0;
        let hidden_layer = || {
            let mut r = RenderLayer::new(Content::Placeholder(PlaceholderKind::Loading));
            r.transform = hidden;
            r
        };
        if let Some(g) = &l.generator {
            return Ok(match g.kind.as_str() {
                SOLID_KIND => RenderLayer::solid(&g.payload, l.transform, None, l.corner_radius).applying(l),
                ADJUSTMENT_KIND => RenderLayer::adjustment(l.transform, None).applying(l),
                _ => match source(l) {
                    LayerSource::Raster(r) => self.raster_layer(&r, pictures)?.applying(l),
                    LayerSource::Offline => offline(l),
                    _ => hidden_layer(),
                },
            });
        }
        Ok(match source(l) {
            LayerSource::Offline => offline(l),
            LayerSource::Hidden => hidden_layer(),
            LayerSource::Raster(r) => self.raster_layer(&r, pictures)?.applying(l),
            LayerSource::Still { media, width, height, rgba, info } => {
                let picture = match self.planes.still(media) {
                    Some(p) => p,
                    None => {
                        let t = self.gpu.texture(width, height, PixelFormat::Rgba8Unorm);
                        let bytes: Vec<u8> = rgba.as_ref().clone();
                        self.gpu.upload_texture(&t, &bytes, width * 4);
                        let p = Picture::rgba(t, 1);
                        self.planes.put_still(media, p.clone());
                        p
                    }
                };
                pictures.push(picture);
                let frame = slot_frame(width as usize, height as usize, SQFramePixelFormat::Rgba8, pictures.len() - 1);
                let mut r = RenderLayer::new(Content::Frame { frame, color_hint: info });
                r.transform = l.transform;
                r.corner_radius = l.corner_radius;
                r.native_size = Some((i64::from(width), i64::from(height)));
                r.applying(l)
            }
            LayerSource::Media(s) => {
                let key = PlaneKey { media: s.media, index: s.index, proxy: s.proxy, divisor: s.divisor };
                let mut picture = to_gpu(&self.gpu, &s.frame, Some(key), &mut self.planes, kept)?;
                if let Some(map) = &s.gyro {
                    picture = super::gyro_warp::warp_picture(&self.gpu, &picture, map).unwrap_or(picture);
                }
                pictures.push(picture);
                let frame = slot_frame(s.frame.width, s.frame.height, s.frame.pixel_format, pictures.len() - 1);
                let mut r = RenderLayer::new(Content::Frame { frame, color_hint: s.info.clone() });
                r.transform = l.transform;
                r.corner_radius = l.corner_radius;
                r.native_size = Some((s.info.width, s.info.height));
                r.applying(l)
            }
        })
    }

    /// A drawn generator as a linear premultiplied layer; the upload is kept by `key`.
    fn raster_layer(&mut self, r: &Raster, pictures: &mut Vec<Picture>) -> Result<RenderLayer, ProgramError> {
        let picture = match self.planes.raster(r.key) {
            Some(p) => p,
            None => {
                let t = self.gpu.texture(r.width, r.height, PixelFormat::Rgba32Float);
                let bytes: Vec<u8> = r.pixels.iter().flat_map(|v| v.to_le_bytes()).collect();
                self.gpu.upload_texture(&t, &bytes, r.width * 16);
                let p = Picture::rgba(t, 0);
                self.planes.put_raster(r.key, p.clone());
                p
            }
        };
        pictures.push(picture);
        let frame = slot_frame(r.width as usize, r.height as usize, SQFramePixelFormat::Rgba32f, pictures.len() - 1);
        let mut layer =
            RenderLayer::new(Content::LinearPremultiplied { frame, width: r.layer_width, height: r.layer_height });
        layer.transform = r.transform;
        layer.corner_radius = r.corner_radius;
        layer.footage_fill = r.footage_fill;
        layer.sample_transforms.clone_from(&r.sample_transforms);
        Ok(layer)
    }
}

fn offline(l: &LayerRequest) -> RenderLayer {
    let mut r = RenderLayer::new(Content::Placeholder(PlaceholderKind::Offline));
    r.transform = l.transform;
    r.corner_radius = l.corner_radius;
    r.applying(l)
}

/// `PresentU` of Present.slang (80 bytes): SDR, unchanged gamma, linear sampling.
fn present_uniforms() -> Vec<u8> {
    let f = |v: [f32; 4]| v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>();
    let mut b = Vec::with_capacity(80);
    b.extend(f([1.0, 0.0, 0.0, 0.0]));
    b.extend(f([0.0, 1.0, 0.0, 0.0]));
    b.extend(f([0.0, 0.0, 1.0, 0.0]));
    b.extend(f([0.0, 1.0, 1.0, 1.0])); // mode, peak, knee, exponent
    b.extend([0u8; 16]); // nearest + padding
    b
}
