//! Command recording: `GpuCommands` and the compute and render encoders (`GPUCompositor`'s encoder API).
//!
//! An encoder keeps the bound state (`set_input(slot)`, `set_output`, `set_buffer`, `set_constants`) and builds the bind
//! group of the fixed layout when it dispatches or draws. Constant blocks go to the uniform arena and are bound with
//! dynamic offsets; unused slots get the device's 1x1 dummies.

use super::{Gpu, GpuError, timing};
use crate::frames::{GpuFrame, GpuTexture};
use crate::layout::{self, LayoutKind, PixelFormat};
use crate::pipelines::{ComputePipeline, Layout, RenderPipeline};
use crate::readback::ReadbackTicket;
use crate::uniforms::UniformArena;
use std::num::NonZeroU64;
use std::sync::Arc;

/// The recorded state of one encoder.
#[derive(Default)]
struct Bindings {
    /// `in0..in23` and the 3D table in slot 24.
    inputs: [Option<wgpu::TextureView>; layout::INPUT_SLOTS + 1],
    output: Option<(wgpu::TextureView, Option<PixelFormat>)>,
    buffers: [Option<wgpu::Buffer>; 3],
    constants: [Option<(wgpu::Buffer, u32)>; layout::CONSTANT_SLOTS],
}

type Group = (wgpu::BindGroup, Vec<u32>);

fn bad(what: String) -> GpuError {
    GpuError::Binding(what)
}

impl Bindings {
    fn set_input(&mut self, slot: usize, texture: &GpuTexture) -> Result<(), GpuError> {
        let cell =
            self.inputs.get_mut(slot).ok_or_else(|| bad(format!("input slot {slot} (0..={})", layout::TABLE_SLOT)))?;
        *cell = Some(texture.view().clone());
        Ok(())
    }

    fn set_buffer(&mut self, slot: usize, buffer: &wgpu::Buffer) -> Result<(), GpuError> {
        if !layout::BUFFER_SLOTS.contains(&slot) {
            return Err(bad(format!("buffer slot {slot} (u2..u4)")));
        }
        self.buffers[slot - 2] = Some(buffer.clone());
        Ok(())
    }

    fn set_constants(
        &mut self,
        gpu: &Gpu,
        arena: &mut UniformArena,
        bytes: &[u8],
        slot: usize,
    ) -> Result<(), GpuError> {
        let cell = self.constants.get_mut(slot).ok_or_else(|| bad(format!("constant slot {slot} (b0..b1)")))?;
        *cell = Some(arena.push(gpu, bytes)?);
        Ok(())
    }

    /// The bind group for `layout` and the dynamic offsets of its constant blocks.
    fn group(&self, gpu: &Gpu, layout: &Layout, out_format: PixelFormat) -> Group {
        let draw = layout.kind == LayoutKind::DrawQuads;
        let window = NonZeroU64::new(layout::MAX_CONSTANT_BYTES as u64);
        let blocks: Vec<(wgpu::Buffer, u32)> = self
            .constants
            .iter()
            .map(|c| c.clone().unwrap_or_else(|| (gpu.dummy_uniform().clone(), 0)))
            .take(if draw { 1 } else { layout::CONSTANT_SLOTS })
            .collect();
        let views: Vec<wgpu::TextureView> = self.inputs[..layout::INPUT_SLOTS]
            .iter()
            .map(|v| v.clone().unwrap_or_else(|| gpu.dummy_texture().clone()))
            .collect();
        let table = self.inputs[layout::TABLE_SLOT].clone().unwrap_or_else(|| gpu.dummy_table().clone());
        let out = self.output.as_ref().map_or_else(|| gpu.dummy_output(out_format), |(view, _)| view.clone());
        let buffers: Vec<wgpu::Buffer> =
            self.buffers.iter().map(|b| b.clone().unwrap_or_else(|| gpu.dummy_buffer().clone())).collect();
        let entry = |binding, resource| wgpu::BindGroupEntry { binding, resource };
        let texture = |binding, view| entry(binding, wgpu::BindingResource::TextureView(view));
        let mut entries = Vec::with_capacity(layout::ENTRY_COUNT);
        for (i, (buffer, _)) in blocks.iter().enumerate() {
            let binding = wgpu::BufferBinding { buffer, offset: 0, size: window };
            entries.push(entry(i as u32, wgpu::BindingResource::Buffer(binding)));
        }
        let samplers = gpu.sampler_views();
        if draw {
            for (i, view) in views.iter().take(layout::DRAW_INPUTS).enumerate() {
                entries.push(texture(layout::DRAW_BIND_INPUT0 + i as u32, view));
            }
            entries.push(entry(layout::DRAW_BIND_QUADS, buffers[0].as_entire_binding()));
            for (i, s) in samplers.iter().enumerate() {
                entries.push(entry(layout::DRAW_BIND_SAMPLER0 + i as u32, wgpu::BindingResource::Sampler(s)));
            }
        } else {
            for (i, view) in views.iter().enumerate() {
                entries.push(texture(layout::BIND_INPUT0 + i as u32, view));
            }
            entries.push(texture(layout::BIND_TABLE, &table));
            entries.push(texture(layout::BIND_OUTPUT, &out));
            entries.push(texture(layout::BIND_FILLER, gpu.dummy_filler()));
            for (i, b) in buffers.iter().enumerate() {
                entries.push(entry(layout::BIND_BUFFER0 + i as u32, b.as_entire_binding()));
            }
            for (i, s) in samplers.iter().enumerate() {
                entries.push(entry(layout::BIND_SAMPLER0 + i as u32, wgpu::BindingResource::Sampler(s)));
            }
        }
        let group = gpu.device().create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &layout.group,
            entries: &entries,
        });
        (group, blocks.iter().map(|(_, offset)| *offset).collect())
    }
}

/// A command buffer being recorded. Frames the commands read are kept alive until the GPU finished.
pub struct GpuCommands {
    gpu: Arc<Gpu>,
    encoder: wgpu::CommandEncoder,
    arena: UniformArena,
    keep: Vec<Arc<GpuFrame>>,
    /// Pass timestamps (`SQ_GPU_TIMING=1` on an adapter that has them).
    timing: Option<timing::Recorder>,
}

/// What a recorded command buffer hands to `Gpu::submit`.
pub(super) struct Finished {
    pub(super) buffer: wgpu::CommandBuffer,
    pub(super) chunks: Vec<wgpu::Buffer>,
    pub(super) keep: Vec<Arc<GpuFrame>>,
    pub(super) timing: Option<timing::Pending>,
}

impl GpuCommands {
    pub(super) fn new(gpu: Arc<Gpu>) -> Self {
        let encoder = gpu.device().create_command_encoder(&Default::default());
        let timing = gpu.timing_supported().then(|| timing::Recorder::new(gpu.device()));
        Self { gpu, encoder, arena: UniformArena::new(), keep: Vec::new(), timing }
    }

    /// Holds `frame` (its textures and `keep` payload) until the submission finished on the GPU.
    pub fn keep(&mut self, frame: Arc<GpuFrame>) {
        self.keep.push(frame);
    }

    /// A compute pass. Dispatches inside it see each other's writes.
    pub fn compute(&mut self) -> ComputeEncoder<'_> {
        let slots = self.timing.as_mut().and_then(timing::Recorder::next_pass);
        let timestamp_writes = match (&self.timing, slots) {
            (Some(t), Some((begin, end))) => Some(wgpu::ComputePassTimestampWrites {
                query_set: t.queries(),
                beginning_of_pass_write_index: Some(begin),
                end_of_pass_write_index: Some(end),
            }),
            _ => None,
        };
        let pass = self.encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes });
        ComputeEncoder {
            gpu: &self.gpu,
            pass,
            arena: &mut self.arena,
            binds: Bindings::default(),
            pipeline: None,
            group: None,
            name: slots.and(self.timing.as_mut()).and_then(timing::Recorder::label_mut),
        }
    }

    /// A render pass into `target`; `clear` is the RGBA it is cleared to first, `None` keeps its content.
    pub fn render(&mut self, target: &GpuTexture, clear: Option<[f64; 4]>) -> RenderEncoder<'_> {
        let load = match clear {
            Some([r, g, b, a]) => wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a }),
            None => wgpu::LoadOp::Load,
        };
        let slots = self.timing.as_mut().and_then(timing::Recorder::next_pass);
        let timestamp_writes = match (&self.timing, slots) {
            (Some(t), Some((begin, end))) => Some(wgpu::RenderPassTimestampWrites {
                query_set: t.queries(),
                beginning_of_pass_write_index: Some(begin),
                end_of_pass_write_index: Some(end),
            }),
            _ => None,
        };
        let pass = self.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target.view(),
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load, store: wgpu::StoreOp::Store },
            })],
            timestamp_writes,
            ..Default::default()
        });
        let mut name = slots.and(self.timing.as_mut()).and_then(timing::Recorder::label_mut);
        if let Some(n) = name.as_deref_mut() {
            timing::name_pass(n, &format!("{}x{}", target.width(), target.height()));
        }
        RenderEncoder {
            gpu: &self.gpu,
            pass,
            arena: &mut self.arena,
            binds: Bindings::default(),
            pipeline: None,
            group: None,
            name,
        }
    }

    /// Whole-texture copy (same size and format).
    pub fn copy(&mut self, source: &GpuTexture, destination: &GpuTexture) {
        self.encoder.copy_texture_to_texture(
            source.texture().as_image_copy(),
            destination.texture().as_image_copy(),
            source.texture().size(),
        );
    }

    /// Records a readback of `texture`; submit, then `wait` on the ticket.
    pub fn read_texture(&mut self, texture: &GpuTexture) -> Result<ReadbackTicket, GpuError> {
        ReadbackTicket::texture(&self.gpu, &mut self.encoder, texture)
    }

    /// Records a readback of the first `length` bytes of `buffer` (needs `COPY_SRC`).
    pub fn read_buffer(&mut self, buffer: &wgpu::Buffer, length: u64) -> ReadbackTicket {
        ReadbackTicket::buffer(&self.gpu, &mut self.encoder, buffer, length)
    }

    pub(super) fn finish(mut self) -> Finished {
        let timing = self
            .timing
            .and_then(|t| t.resolve(&mut self.encoder, self.gpu.device(), self.gpu.queue().get_timestamp_period()));
        Finished { buffer: self.encoder.finish(), chunks: self.arena.into_chunks(), keep: self.keep, timing }
    }
}

/// Compute encoder: bind inputs, an output, buffers and constants, then dispatch.
pub struct ComputeEncoder<'a> {
    gpu: &'a Arc<Gpu>,
    pass: wgpu::ComputePass<'a>,
    arena: &'a mut UniformArena,
    binds: Bindings,
    pipeline: Option<Arc<ComputePipeline>>,
    group: Option<Group>,
    /// The pass's name in the GPU timing report (`None`: untimed).
    name: Option<&'a mut String>,
}

impl ComputeEncoder<'_> {
    pub fn set_pipeline(&mut self, pipeline: &Arc<ComputePipeline>) {
        if let Some(name) = self.name.as_deref_mut() {
            timing::name_pass(name, &pipeline.label);
        }
        self.pass.set_pipeline(&pipeline.raw);
        self.pipeline = Some(Arc::clone(pipeline));
        self.group = None;
    }

    /// `slot` 0..=23 is `in0..in23`, 24 the 3D table `lut0`.
    pub fn set_input(&mut self, texture: &GpuTexture, slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_input(slot, texture)
    }

    /// The texture `out0` writes; its format must be the one the pipeline was built for.
    pub fn set_output(&mut self, texture: &GpuTexture) {
        self.group = None;
        if let Some(n) = self.name.as_deref_mut() {
            timing::name_pass(n, &format!("{}x{}", texture.width(), texture.height()));
        }
        self.binds.output = Some((texture.view().clone(), texture.format()));
    }

    /// A data buffer at `slot` 2..=4 (`u2..u4`).
    pub fn set_buffer(&mut self, buffer: &wgpu::Buffer, slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_buffer(slot, buffer)
    }

    /// Copies `bytes` (at most [`layout::MAX_CONSTANT_BYTES`]) into constant block `slot` (0..=1); valid for the following dispatches.
    pub fn set_constants(&mut self, bytes: &[u8], slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_constants(self.gpu, self.arena, bytes, slot)
    }

    /// One thread per (x, y) in `width` x `height`; kernels bound-check, so the grid may be any size.
    pub fn dispatch(&mut self, width: u32, height: u32) -> Result<(), GpuError> {
        self.dispatch_groups(width.div_ceil(layout::GROUP_SIDE), height.div_ceil(layout::GROUP_SIDE))
    }

    /// Whole 16x16 groups (kernels that reduce per group need a whole-group grid).
    pub fn dispatch_groups(&mut self, groups_x: u32, groups_y: u32) -> Result<(), GpuError> {
        let pipeline = self.pipeline.clone().ok_or_else(|| bad("dispatch without a pipeline".into()))?;
        if let Some((_, Some(format))) =
            self.binds.output.as_ref().filter(|(_, f)| f.is_some_and(|f| f != pipeline.out_format))
        {
            return Err(bad(format!("output is {format:?}, the pipeline writes {:?}", pipeline.out_format)));
        }
        if self.group.is_none() {
            self.group = Some(self.binds.group(self.gpu, &pipeline.layout, pipeline.out_format));
        }
        if let Some((group, offsets)) = &self.group {
            self.pass.set_bind_group(0, group, offsets);
        }
        self.pass.dispatch_workgroups(groups_x, groups_y, 1);
        Ok(())
    }
}

/// Render encoder: the same slots as compute, writing the pass's target instead of `out0`.
pub struct RenderEncoder<'a> {
    gpu: &'a Arc<Gpu>,
    pass: wgpu::RenderPass<'a>,
    arena: &'a mut UniformArena,
    binds: Bindings,
    pipeline: Option<Arc<RenderPipeline>>,
    group: Option<Group>,
    /// The pass's name in the GPU timing report (`None`: untimed).
    name: Option<&'a mut String>,
}

impl RenderEncoder<'_> {
    pub fn set_pipeline(&mut self, pipeline: &Arc<RenderPipeline>) {
        if let Some(name) = self.name.as_deref_mut() {
            timing::name_pass(name, &pipeline.label);
        }
        self.pass.set_pipeline(&pipeline.raw);
        self.pipeline = Some(Arc::clone(pipeline));
        self.group = None;
    }

    /// `slot` 0..=23 is `in0..in23`, 24 the 3D table; `DrawQuads` takes slots 0..=8.
    pub fn set_input(&mut self, texture: &GpuTexture, slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_input(slot, texture)
    }

    /// A data buffer at `slot` 2..=4; `DrawQuads` reads its quads from slot 2.
    pub fn set_buffer(&mut self, buffer: &wgpu::Buffer, slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_buffer(slot, buffer)
    }

    pub fn set_constants(&mut self, bytes: &[u8], slot: usize) -> Result<(), GpuError> {
        self.group = None;
        self.binds.set_constants(self.gpu, self.arena, bytes, slot)
    }

    /// Target pixels the draw maps to (origin top-left); default the whole target.
    pub fn set_viewport(&mut self, x: f32, y: f32, width: f32, height: f32) {
        self.pass.set_viewport(x, y, width, height, 0.0, 1.0);
    }

    /// Target pixels the draw may write; default the whole target.
    pub fn set_scissor(&mut self, x: u32, y: u32, width: u32, height: u32) {
        self.pass.set_scissor_rect(x, y, width, height);
    }

    /// Draws `vertex_count` vertices for `instances` instances; the vertex entry builds them from `SV_VertexID`.
    pub fn draw(&mut self, vertex_count: u32, instances: u32) -> Result<(), GpuError> {
        let pipeline = self.pipeline.clone().ok_or_else(|| bad("draw without a pipeline".into()))?;
        if self.group.is_none() {
            self.group = Some(self.binds.group(self.gpu, &pipeline.layout, PixelFormat::Rgba16Float));
        }
        if let Some((group, offsets)) = &self.group {
            self.pass.set_bind_group(0, group, offsets);
        }
        self.pass.draw(0..vertex_count, 0..instances);
        Ok(())
    }
}
