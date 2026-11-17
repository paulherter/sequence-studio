//! Textures, the texture pool and `GpuFrame`, the decoded picture on the GPU.

use crate::gpu::{Gpu, lock};
use crate::layout::PixelFormat;
use sq_core_time::Time;
use sq_frame::sqframe::{SQFrameColorSpace, SQFrameStorage};
use std::any::Any;
use std::collections::HashMap;
use std::ops::Deref;
use std::sync::{Arc, Mutex};

/// A wgpu texture with its default view, the unit the encoders bind.
#[derive(Clone)]
pub struct GpuTexture {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
}

impl GpuTexture {
    /// Wraps an existing texture (a plane imported from the platform decoder).
    pub fn from_texture(texture: wgpu::Texture) -> Self {
        let view = texture.create_view(&Default::default());
        Self { texture, view }
    }

    pub(crate) fn create(device: &wgpu::Device, width: u32, height: u32, format: PixelFormat) -> Self {
        Self::from_texture(device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: format.wgpu(),
            usage: usage(format),
            view_formats: &[],
        }))
    }

    pub(crate) fn create_3d(device: &wgpu::Device, width: u32, height: u32, depth: u32, format: PixelFormat) -> Self {
        Self::from_texture(device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width, height, depth_or_array_layers: depth },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D3,
            format: format.wgpu(),
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        }))
    }

    pub fn texture(&self) -> &wgpu::Texture {
        &self.texture
    }

    pub fn view(&self) -> &wgpu::TextureView {
        &self.view
    }

    pub fn width(&self) -> u32 {
        self.texture.width()
    }

    pub fn height(&self) -> u32 {
        self.texture.height()
    }

    /// `None` for formats outside [`PixelFormat`].
    pub fn format(&self) -> Option<PixelFormat> {
        PixelFormat::from_wgpu(self.texture.format())
    }
}

/// What a texture of `format` may be used for: every format can be sampled and copied; storage and render use follow the format.
fn usage(format: PixelFormat) -> wgpu::TextureUsages {
    let mut u = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST;
    if format.is_storage() {
        u |= wgpu::TextureUsages::STORAGE_BINDING;
    }
    if format.is_renderable() {
        u |= wgpu::TextureUsages::RENDER_ATTACHMENT;
    }
    u
}

/// Free textures by size and format, with the bytes they hold, behind a byte budget.
struct FreeList<T> {
    by_key: HashMap<(u32, u32, PixelFormat), Vec<T>>,
    bytes: u64,
    budget: u64,
}

/// Textures kept per size and format; more are dropped.
const POOL_DEPTH: usize = 8;

impl<T> FreeList<T> {
    fn bytes_of((w, h, format): (u32, u32, PixelFormat)) -> u64 {
        u64::from(w) * u64::from(h) * u64::from(format.bytes_per_pixel())
    }

    fn take(&mut self, key: (u32, u32, PixelFormat)) -> Option<T> {
        let t = self.by_key.get_mut(&key).and_then(Vec::pop)?;
        self.bytes = self.bytes.saturating_sub(Self::bytes_of(key));
        Some(t)
    }

    /// Keeps `t` for reuse unless the pool is at its depth or byte budget (`t` is then dropped, its memory goes back).
    fn give(&mut self, key: (u32, u32, PixelFormat), t: T) {
        let bytes = Self::bytes_of(key);
        let list = self.by_key.entry(key).or_default();
        if list.len() < POOL_DEPTH && self.bytes + bytes <= self.budget {
            list.push(t);
            self.bytes += bytes;
        }
    }

    /// Lowers the budget to `bytes` at most and frees textures until the pool fits.
    fn limit(&mut self, bytes: u64) {
        self.budget = self.budget.min(bytes);
        while self.bytes > self.budget {
            let Some(key) = self.by_key.iter().find(|(_, v)| !v.is_empty()).map(|(k, _)| *k) else { break };
            if self.take(key).is_none() {
                break;
            }
        }
    }
}

/// Free textures by size and format. Reuse is safe without tracking the GPU: the queue runs submissions in order. The free
/// textures are capped by a byte budget, so passes of many sizes (a blur on crops, a zoom) cannot park gigabytes of unused
/// textures in the pool of a GPU that shares its memory with the system.
pub(crate) struct TexturePool {
    free: Arc<Mutex<FreeList<GpuTexture>>>,
}

/// The default budget of free textures for an adapter class: discrete GPUs own their memory, integrated ones and software
/// renderers take it from the system RAM the decoder, the frame cache and the app share. wgpu reports no memory size, so this
/// is a conservative figure per class; the app lowers it further with the machine's RAM (`Gpu::limit_pool_bytes`).
pub(crate) fn default_pool_bytes(kind: wgpu::DeviceType) -> u64 {
    const MIB: u64 = 1 << 20;
    match kind {
        wgpu::DeviceType::DiscreteGpu => 768 * MIB,
        wgpu::DeviceType::IntegratedGpu => 192 * MIB,
        wgpu::DeviceType::VirtualGpu | wgpu::DeviceType::Cpu | wgpu::DeviceType::Other => 128 * MIB,
    }
}

impl TexturePool {
    pub(crate) fn new(budget: u64) -> Self {
        Self { free: Arc::new(Mutex::new(FreeList { by_key: HashMap::new(), bytes: 0, budget })) }
    }

    pub(crate) fn acquire(&self, gpu: &Gpu, width: u32, height: u32, format: PixelFormat) -> PooledTexture {
        let key = (width, height, format);
        let texture = lock(&self.free).take(key);
        PooledTexture {
            texture: Some(texture.unwrap_or_else(|| gpu.texture(width, height, format))),
            key,
            pool: Arc::clone(&self.free),
        }
    }

    /// Never more than `bytes` of free textures from now on.
    pub(crate) fn limit(&self, bytes: u64) {
        lock(&self.free).limit(bytes);
    }

    /// Bytes of free textures held right now.
    pub(crate) fn free_bytes(&self) -> u64 {
        lock(&self.free).bytes
    }
}

/// A texture on loan from the pool.
pub struct PooledTexture {
    texture: Option<GpuTexture>,
    key: (u32, u32, PixelFormat),
    pool: Arc<Mutex<FreeList<GpuTexture>>>,
}

impl Deref for PooledTexture {
    type Target = GpuTexture;

    fn deref(&self) -> &GpuTexture {
        // `texture` is only taken in `drop`.
        self.texture.as_ref().unwrap_or_else(|| unreachable!("pooled texture used after drop"))
    }
}

impl Drop for PooledTexture {
    fn drop(&mut self) {
        if let Some(texture) = self.texture.take() {
            lock(&self.pool).give(self.key, texture);
        }
    }
}

#[cfg(test)]
mod pool_tests {
    use super::*;

    fn list(budget: u64) -> FreeList<u32> {
        FreeList { by_key: HashMap::new(), bytes: 0, budget }
    }

    const KEY: (u32, u32, PixelFormat) = (100, 100, PixelFormat::Rgba8Unorm); // 40 000 bytes

    #[test]
    fn free_textures_stay_inside_the_byte_budget() {
        let mut l = list(100_000);
        for i in 0..8 {
            l.give(KEY, i);
        }
        assert_eq!(l.bytes, 80_000, "two fit, the others were dropped");
        assert_eq!(l.by_key[&KEY].len(), 2);
        assert!(l.take(KEY).is_some());
        assert_eq!(l.bytes, 40_000, "a taken texture leaves the account");
    }

    #[test]
    fn many_sizes_cannot_outgrow_the_budget() {
        let mut l = list(1 << 20);
        for w in 1..400u32 {
            l.give((w, 200, PixelFormat::Rgba16Float), 0);
            assert!(l.bytes <= 1 << 20, "{} bytes after {w} sizes", l.bytes);
        }
    }

    #[test]
    fn lowering_the_limit_frees_what_does_not_fit() {
        let mut l = list(1 << 30);
        for i in 0..8 {
            l.give(KEY, i);
        }
        l.limit(100_000);
        assert!(l.bytes <= 100_000);
        l.limit(1 << 30);
        assert_eq!(l.budget, 100_000, "a limit never raises the budget");
    }

    #[test]
    fn the_default_budget_is_smallest_where_memory_is_shared() {
        use wgpu::DeviceType as D;
        assert!(default_pool_bytes(D::IntegratedGpu) < default_pool_bytes(D::DiscreteGpu));
        assert!(default_pool_bytes(D::Cpu) <= default_pool_bytes(D::IntegratedGpu));
    }
}

/// How a frame's planes are laid out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaneLayout {
    /// `R8Unorm` luma + `Rg8Unorm` chroma.
    Nv12,
    /// `R16Unorm` luma + `Rg16Unorm` chroma, 10 bits MSB-aligned.
    P010,
    /// One `Rgba8Unorm` plane, straight alpha.
    Rgba8Straight,
    /// One `Rgba16Float` plane.
    Rgba16f,
}

/// A decoded picture on the GPU. Passed as `Arc`; `keep` holds whatever must outlive the GPU's reads (on the Mac the
/// CVPixelBuffer and CVMetalTexture of a zero-copy import).
pub struct GpuFrame {
    /// One to three planes (luma, chroma, or the single picture).
    pub planes: Vec<GpuTexture>,
    pub layout: PlaneLayout,
    pub size: (u32, u32),
    pub color: SQFrameColorSpace,
    pub pts: Time,
    pub keep: Option<Box<dyn Any + Send + Sync>>,
}

impl SQFrameStorage for GpuFrame {}
