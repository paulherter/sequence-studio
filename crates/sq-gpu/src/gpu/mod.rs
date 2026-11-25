//! The device: one wgpu device and queue for UI, program and export, with the fixed samplers and layouts.
//!
//! Rules the shaders depend on (docs/rust/render-playback-export-design.md section 1, spikes/g2-slang/REPORT.md):
//! the three samplers are the first objects created on the device and are never dropped (the Slang HLSL reads sampler heap
//! slots 0..2 directly), every pipeline uses the fixed layout, and immediates stay unused.

mod adapter;
mod commands;
mod in_flight;
pub mod timing;

pub use commands::{ComputeEncoder, GpuCommands, RenderEncoder};
pub use in_flight::{Admit, FRAMES_IN_FLIGHT, InFlight, WAIT_SLICE, Waited, wait_in_slices};

use crate::frames::{GpuTexture, TexturePool, default_pool_bytes};
use crate::layout::{self, LayoutKind, PixelFormat};
use crate::pipelines::{ComputePipeline, Layout, RenderPipeline};
use crate::readback::StagingPool;
use crate::uniforms::ChunkPool;
use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

/// Everything that can go wrong in the GPU layer.
#[derive(Debug)]
pub enum GpuError {
    /// No adapter for the platform backend (tests skip on this).
    NoAdapter(String),
    /// The adapter lacks a required feature.
    MissingFeature(String),
    /// `request_device` failed.
    Device(String),
    /// A pipeline did not build: unknown entry, missing shader bytes or a wgpu error.
    Pipeline(String),
    /// A wrong slot, size or format passed to an encoder.
    Binding(String),
    /// Mapping or reading back failed.
    Readback(String),
}

impl fmt::Display for GpuError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (what, why) = match self {
            Self::NoAdapter(s) => ("no GPU adapter", s),
            Self::MissingFeature(s) => ("missing GPU feature", s),
            Self::Device(s) => ("GPU device", s),
            Self::Pipeline(s) => ("GPU pipeline", s),
            Self::Binding(s) => ("GPU binding", s),
            Self::Readback(s) => ("GPU readback", s),
        };
        write!(f, "{what}: {why}")
    }
}

impl std::error::Error for GpuError {}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A poisoned map still holds valid entries (nothing here panics mid-update).
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Compute pipelines by module, entry and `out0` format.
pub(crate) type ComputeKey = (&'static str, &'static str, PixelFormat);

/// The 1x1 stand-ins for unused slots.
struct Dummies {
    texture: wgpu::TextureView,
    table: wgpu::TextureView,
    filler: wgpu::TextureView,
    buffer: wgpu::Buffer,
    uniform: wgpu::Buffer,
}

/// The device layer. Create once, share through `Arc`.
pub struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    info: wgpu::AdapterInfo,
    adapter: wgpu::Adapter,
    // Created first and never dropped: see the module docs. Declared before everything built on the device.
    samplers: [wgpu::Sampler; 3],
    dummies: Dummies,
    outputs: Mutex<HashMap<PixelFormat, wgpu::TextureView>>,
    layouts: Mutex<HashMap<(LayoutKind, PixelFormat), Arc<Layout>>>,
    pub(crate) compute: Mutex<HashMap<ComputeKey, Arc<ComputePipeline>>>,
    pub(crate) render: Mutex<HashMap<crate::pipelines::RenderKey, Arc<RenderPipeline>>>,
    pub(crate) modules: Mutex<HashMap<String, Arc<wgpu::ShaderModule>>>,
    pub(crate) pool: TexturePool,
    pub(crate) chunks: ChunkPool,
    pub(crate) staging: StagingPool,
    features: wgpu::Features,
    /// Vulkan driver cache and its file (`pipelines/warm.rs`).
    /// Pipelines being compiled right now (one build per pipeline).
    pub(crate) building: (Mutex<std::collections::HashSet<String>>, std::sync::Condvar),
    pub(crate) pipeline_cache: Option<(wgpu::PipelineCache, std::path::PathBuf)>,
}

/// The wgpu backend of this platform: D3D12, Metal or Vulkan.
pub fn backend() -> wgpu::Backends {
    if cfg!(windows) {
        wgpu::Backends::DX12
    } else if cfg!(target_os = "macos") {
        wgpu::Backends::METAL
    } else {
        wgpu::Backends::VULKAN
    }
}

impl Gpu {
    /// Opens the platform backend (Metal, D3D12) on the high-performance adapter.
    pub fn new() -> Result<Arc<Gpu>, GpuError> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: backend(),
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        pollster::block_on(Self::with_instance(&instance, None))
    }

    /// Opens the adapter of `instance`, compatible with `surface` when the UI presents through this device.
    pub async fn with_instance(
        instance: &wgpu::Instance,
        surface: Option<&wgpu::Surface<'_>>,
    ) -> Result<Arc<Gpu>, GpuError> {
        let required = wgpu::Features::PASSTHROUGH_SHADERS
            | wgpu::Features::ADDRESS_MODE_CLAMP_TO_BORDER
            | wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES;
        let adapter = Self::pick_adapter(instance, surface, required).await?;
        let mut optional = wgpu::Features::TEXTURE_FORMAT_16BIT_NORM
            | wgpu::Features::FLOAT32_FILTERABLE
            | wgpu::Features::PIPELINE_CACHE;
        if timing::requested() {
            optional |= wgpu::Features::TIMESTAMP_QUERY;
        }
        let features = required | (optional & adapter.features());
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("sq-gpu"),
                required_features: features,
                required_limits: adapter.limits(),
                ..Default::default()
            })
            .await
            .map_err(|e| GpuError::Device(e.to_string()))?;
        Ok(Arc::new(Self::build(device, queue, adapter, features)))
    }

    /// The best adapter that has the required features and can present to `surface` (see `adapter.rs`); one line on stderr
    /// names the choice and the others. Falls back to wgpu's own high-performance pick when the system lists none.
    async fn pick_adapter(
        instance: &wgpu::Instance,
        surface: Option<&wgpu::Surface<'_>>,
        required: wgpu::Features,
    ) -> Result<wgpu::Adapter, GpuError> {
        let adapters = instance.enumerate_adapters(backend()).await;
        let candidates: Vec<adapter::Candidate> = adapters
            .iter()
            .map(|a| adapter::Candidate {
                name: a.get_info().name,
                device_type: a.get_info().device_type,
                features_ok: a.features().contains(required),
                surface_ok: surface.is_none_or(|s| a.is_surface_supported(s)),
            })
            .collect();
        let listing = || {
            candidates
                .iter()
                .map(|c| {
                    format!(
                        "{} ({:?}{}{})",
                        c.name,
                        c.device_type,
                        if c.features_ok { "" } else { ", lacks features" },
                        if c.surface_ok { "" } else { ", cannot present" }
                    )
                })
                .collect::<Vec<_>>()
                .join("; ")
        };
        let wanted = std::env::var("SQ_GPU_ADAPTER").ok();
        if let Some(i) = adapter::choose(&candidates, wanted.as_deref()) {
            let info = adapters[i].get_info();
            eprintln!("gpu: using {} ({:?}, {:?}); adapters: {}", info.name, info.device_type, info.backend, listing());
            return adapters.into_iter().nth(i).ok_or_else(|| GpuError::NoAdapter("adapter list changed".into()));
        }
        if !adapters.is_empty() {
            let missing =
                adapters.iter().map(|a| format!("{:?}", required - a.features())).collect::<Vec<_>>().join(" | ");
            eprintln!("gpu: no usable adapter; adapters: {}", listing());
            return Err(GpuError::MissingFeature(format!(
                "no adapter has them all ({missing}); adapters: {}",
                listing()
            )));
        }
        eprintln!("gpu: the system lists no adapter, asking for the high-performance one");
        instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: surface,
                ..Default::default()
            })
            .await
            .map_err(|e| GpuError::NoAdapter(e.to_string()))
    }

    fn build(device: wgpu::Device, queue: wgpu::Queue, adapter: wgpu::Adapter, features: wgpu::Features) -> Gpu {
        let info = adapter.get_info();
        let pipeline_cache = crate::pipelines::warm::open_cache(&device, &info, features);
        let pool = TexturePool::new(default_pool_bytes(info.device_type));
        let sampler = |label, address, filter, border| {
            device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some(label),
                address_mode_u: address,
                address_mode_v: address,
                address_mode_w: address,
                mag_filter: filter,
                min_filter: filter,
                mipmap_filter: wgpu::MipmapFilterMode::Nearest,
                border_color: border,
                ..Default::default()
            })
        };
        // Order is the contract: zero (s0), edge (s1), nearest (s2).
        let samplers = [
            sampler(
                "zero",
                wgpu::AddressMode::ClampToBorder,
                wgpu::FilterMode::Linear,
                Some(wgpu::SamplerBorderColor::TransparentBlack),
            ),
            sampler("edge", wgpu::AddressMode::ClampToEdge, wgpu::FilterMode::Linear, None),
            sampler("nearest", wgpu::AddressMode::ClampToEdge, wgpu::FilterMode::Nearest, None),
        ];
        let tiny = |dimension, size, usage| {
            let depth = if dimension == wgpu::TextureDimension::D3 { size } else { 1 };
            device
                .create_texture(&wgpu::TextureDescriptor {
                    label: Some("dummy"),
                    size: wgpu::Extent3d { width: size, height: size, depth_or_array_layers: depth },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension,
                    format: wgpu::TextureFormat::Rgba16Float,
                    usage,
                    view_formats: &[],
                })
                .create_view(&Default::default())
        };
        let buffer = |usage| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("dummy"),
                size: layout::MAX_CONSTANT_BYTES as u64,
                usage,
                mapped_at_creation: false,
            })
        };
        let dummies = Dummies {
            texture: tiny(wgpu::TextureDimension::D2, 1, wgpu::TextureUsages::TEXTURE_BINDING),
            table: tiny(wgpu::TextureDimension::D3, 2, wgpu::TextureUsages::TEXTURE_BINDING),
            filler: tiny(wgpu::TextureDimension::D2, 1, wgpu::TextureUsages::STORAGE_BINDING),
            buffer: buffer(wgpu::BufferUsages::STORAGE),
            uniform: buffer(wgpu::BufferUsages::UNIFORM),
        };
        Gpu {
            chunks: ChunkPool::new(device.limits().min_uniform_buffer_offset_alignment as u64),
            device,
            queue,
            info,
            adapter,
            samplers,
            dummies,
            outputs: Mutex::default(),
            layouts: Mutex::default(),
            compute: Mutex::default(),
            render: Mutex::default(),
            modules: Mutex::default(),
            pool,
            staging: StagingPool::default(),
            features,
            building: Default::default(),
            pipeline_cache,
        }
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    /// The adapter this device came from (surface capability checks).
    pub fn adapter(&self) -> &wgpu::Adapter {
        &self.adapter
    }

    /// Adapter name, backend and driver, for logs and bug reports.
    pub fn info(&self) -> &wgpu::AdapterInfo {
        &self.info
    }

    /// Whether `format` can be created on this adapter (16-bit planes need `TEXTURE_FORMAT_16BIT_NORM`).
    pub fn supports(&self, format: PixelFormat) -> bool {
        !matches!(format, PixelFormat::R16Unorm | PixelFormat::Rg16Unorm)
            || self.features.contains(wgpu::Features::TEXTURE_FORMAT_16BIT_NORM)
    }

    /// Starts recording a command buffer.
    pub fn commands(self: &Arc<Self>) -> GpuCommands {
        GpuCommands::new(Arc::clone(self))
    }

    /// Submits and returns at once. The frames and uniform chunks the commands used are released after the GPU finished
    /// (reported by [`Gpu::poll`] or a blocking wait).
    pub fn submit(&self, commands: GpuCommands) -> wgpu::SubmissionIndex {
        let commands::Finished { buffer, chunks, keep, timing: pass_times } = commands.finish();
        let index = self.queue.submit([buffer]);
        let pool = self.chunks.shared();
        let timed = pass_times.map(|mut t| {
            t.index = Some(index.clone());
            let done = Arc::clone(&t.done);
            timing::submitted(t);
            done
        });
        self.queue.on_submitted_work_done(move || {
            drop(keep);
            lock(&pool).extend(chunks);
            if let Some(done) = timed {
                done.store(true, std::sync::atomic::Ordering::Release);
            }
        });
        index
    }

    /// Submits and blocks until the GPU finished (tests, headless renders).
    pub fn submit_and_wait(&self, commands: GpuCommands) -> Result<(), GpuError> {
        self.submit(commands);
        self.wait()
    }

    /// Lets finished submissions release their frames; never blocks.
    pub fn poll(&self) {
        // A poll error means the device is lost; the next real call reports it.
        let _ = self.device.poll(wgpu::PollType::Poll);
        if self.timing_supported() {
            timing::collect(false);
        }
    }

    /// Waits up to `timeout` for the submission `index` to finish; true when the GPU finished it. A device that is lost or an
    /// index that is unknown count as finished: there is nothing left to wait for, and the next real call reports the error.
    pub fn wait_for(&self, index: &wgpu::SubmissionIndex, timeout: std::time::Duration) -> bool {
        let wait = wgpu::PollType::Wait { submission_index: Some(index.clone()), timeout: Some(timeout) };
        match self.device.poll(wait) {
            Ok(status) => status.wait_finished(),
            Err(wgpu::PollError::Timeout) => false,
            Err(_) => true,
        }
    }

    /// Whether passes record their GPU time (`SQ_GPU_TIMING=1` and the adapter has timestamp queries): see [`timing`].
    pub fn timing_supported(&self) -> bool {
        self.features.contains(wgpu::Features::TIMESTAMP_QUERY)
    }

    /// Lowers the bytes of free intermediate textures the pool keeps to `bytes` at most (the adapter class sets the
    /// default; the app lowers it with the machine's RAM). Never raises it.
    pub fn limit_pool_bytes(&self, bytes: u64) {
        self.pool.limit(bytes);
    }

    /// Bytes of free intermediate textures the pool holds right now.
    pub fn pool_free_bytes(&self) -> u64 {
        self.pool.free_bytes()
    }

    /// Blocks until everything submitted so far finished.
    pub fn wait(&self) -> Result<(), GpuError> {
        self.device.poll(wgpu::PollType::wait_indefinitely()).map(|_| ()).map_err(|e| GpuError::Readback(e.to_string()))
    }

    pub(crate) fn sampler_views(&self) -> [&wgpu::Sampler; 3] {
        [&self.samplers[0], &self.samplers[1], &self.samplers[2]]
    }

    pub(crate) fn dummy_texture(&self) -> &wgpu::TextureView {
        &self.dummies.texture
    }

    pub(crate) fn dummy_table(&self) -> &wgpu::TextureView {
        &self.dummies.table
    }

    pub(crate) fn dummy_filler(&self) -> &wgpu::TextureView {
        &self.dummies.filler
    }

    pub(crate) fn dummy_buffer(&self) -> &wgpu::Buffer {
        &self.dummies.buffer
    }

    pub(crate) fn dummy_uniform(&self) -> &wgpu::Buffer {
        &self.dummies.uniform
    }

    /// A 1x1 `out0` stand-in of `format` for passes that write no output texture.
    pub(crate) fn dummy_output(&self, format: PixelFormat) -> wgpu::TextureView {
        lock(&self.outputs)
            .entry(format)
            .or_insert_with(|| {
                let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("dummy out"),
                    size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: format.wgpu(),
                    usage: wgpu::TextureUsages::STORAGE_BINDING,
                    view_formats: &[],
                });
                texture.create_view(&Default::default())
            })
            .clone()
    }

    /// The bind group and pipeline layout of `kind`; `out` is the `out0` format of compute layouts.
    pub(crate) fn layout(&self, kind: LayoutKind, out: PixelFormat) -> Arc<Layout> {
        let out = if matches!(kind, LayoutKind::Compute | LayoutKind::ComputeInPlace) {
            out
        } else {
            PixelFormat::Rgba16Float
        };
        let mut layouts = lock(&self.layouts);
        let layout = layouts.entry((kind, out)).or_insert_with(|| {
            let entries = if kind == LayoutKind::DrawQuads {
                layout::draw_quads_entries()
            } else {
                layout::fixed_entries(kind, out)
            };
            let group = self
                .device
                .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &entries });
            let pipeline = self.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(&group)],
                immediate_size: 0,
            });
            Arc::new(Layout { kind, group, pipeline })
        });
        Arc::clone(layout)
    }

    /// A GPU-only texture for passes: sampled, storage (when the format allows), render target and copy source/target.
    pub fn texture(&self, width: u32, height: u32, format: PixelFormat) -> GpuTexture {
        GpuTexture::create(&self.device, width, height, format)
    }

    /// A pooled texture; goes back to the pool when dropped.
    pub fn acquire(self: &Arc<Self>, width: u32, height: u32, format: PixelFormat) -> crate::frames::PooledTexture {
        self.pool.acquire(self, width, height, format)
    }

    /// A read-only 3D table (color LUT), filled by [`Gpu::upload_texture`].
    pub fn texture_3d(&self, width: u32, height: u32, depth: u32, format: PixelFormat) -> GpuTexture {
        GpuTexture::create_3d(&self.device, width, height, depth, format)
    }

    /// Rows of `bytes_per_row` into `texture` (2D, or the slices of a 3D table one after another).
    pub fn upload_texture(&self, texture: &GpuTexture, bytes: &[u8], bytes_per_row: u32) {
        let size = texture.texture().size();
        let _span = sq_os::trace::span_args("xfer", "texture upload", || {
            format!("{}x{} bytes={}", size.width, size.height, bytes.len())
        });
        self.queue.write_texture(
            texture.texture().as_image_copy(),
            bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(bytes_per_row),
                rows_per_image: Some(size.height),
            },
            size,
        );
    }

    /// A zero-filled data buffer for `u2..u4` (counts, means, gains); readable with [`GpuCommands::read_buffer`].
    pub fn storage_buffer(&self, length: u64) -> wgpu::Buffer {
        self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("data"),
            size: length.next_multiple_of(4),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }

    /// Records, submits and waits: the tightly packed bytes of `texture`.
    pub fn read_texture(self: &Arc<Self>, texture: &GpuTexture) -> Result<Vec<u8>, GpuError> {
        let mut commands = self.commands();
        let ticket = commands.read_texture(texture)?;
        self.submit(commands);
        ticket.wait(self)
    }

    /// Records, submits and waits: the first `length` bytes of `buffer` (needs `COPY_SRC`).
    pub fn read_buffer(self: &Arc<Self>, buffer: &wgpu::Buffer, length: u64) -> Result<Vec<u8>, GpuError> {
        let mut commands = self.commands();
        let ticket = commands.read_buffer(buffer, length);
        self.submit(commands);
        ticket.wait(self)
    }

    /// Pipeline compile errors from wgpu come as scoped errors, not panics.
    pub(crate) fn scoped<T>(&self, build: impl FnOnce() -> T) -> Result<T, GpuError> {
        let outer = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let inner = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let built = build();
        let error = pollster::block_on(inner.pop()).or(pollster::block_on(outer.pop()));
        match error {
            Some(e) => Err(GpuError::Pipeline(e.to_string().lines().next().unwrap_or("error").to_string())),
            None => Ok(built),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The shared device of the GPU tests; `None` (with a note) when the machine has no adapter.
    pub(crate) fn test_gpu() -> Option<Arc<Gpu>> {
        static GPU: std::sync::OnceLock<Option<Arc<Gpu>>> = std::sync::OnceLock::new();
        GPU.get_or_init(|| match Gpu::new() {
            Ok(gpu) => Some(gpu),
            Err(e) => {
                eprintln!("skipping GPU tests: {e}");
                None
            }
        })
        .clone()
    }

    #[test]
    fn device_opens_with_three_samplers_first() {
        let Some(gpu) = test_gpu() else { return };
        assert_eq!(gpu.sampler_views().len(), 3);
        assert!(gpu.supports(PixelFormat::Rgba16Float));
        eprintln!("adapter: {} ({:?})", gpu.info().name, gpu.info().backend);
    }
}
