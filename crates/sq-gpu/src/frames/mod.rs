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
    /// Counts this texture in the live census until the last clone is dropped.
    _live: Option<Arc<census::Live>>,
}

/// Live textures by (width, height, format, creating call site), so a memory peak has a named owner (play bench `MEM1`).
pub mod census {
    use std::collections::HashMap;
    use std::sync::Mutex;

    type Key = (u32, u32, String, &'static std::panic::Location<'static>);
    static LIVE: Mutex<Option<HashMap<Key, (i64, u64)>>> = Mutex::new(None);

    static TOTAL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    static PEAK: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    pub struct Live {
        key: Key,
        bytes: u64,
    }

    impl Live {
        pub(super) fn new(
            w: u32,
            h: u32,
            format: String,
            bytes: u64,
            at: &'static std::panic::Location<'static>,
        ) -> Self {
            let key = (w, h, format, at);
            let mut g = LIVE.lock().unwrap_or_else(|e| e.into_inner());
            let e = g.get_or_insert_with(HashMap::new).entry(key.clone()).or_default();
            e.0 += 1;
            e.1 += bytes;
            let now = TOTAL.fetch_add(bytes, std::sync::atomic::Ordering::Relaxed) + bytes;
            PEAK.fetch_max(now, std::sync::atomic::Ordering::Relaxed);
            Self { key, bytes }
        }
    }

    impl Drop for Live {
        fn drop(&mut self) {
            TOTAL.fetch_sub(self.bytes, std::sync::atomic::Ordering::Relaxed);
            let mut g = LIVE.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(map) = g.as_mut()
                && let Some(e) = map.get_mut(&self.key)
            {
                e.0 -= 1;
                e.1 -= self.bytes;
                if e.0 <= 0 {
                    map.remove(&self.key);
                }
            }
        }
    }

    /// The live textures, biggest first: `count x WxH format = MB @ file:line`, top `n`, plus the totals.
    pub fn report(n: usize) -> String {
        let g = LIVE.lock().unwrap_or_else(|e| e.into_inner());
        let mut rows: Vec<(&Key, &(i64, u64))> = g.iter().flat_map(|m| m.iter()).collect();
        rows.sort_by_key(|a| std::cmp::Reverse(a.1.1));
        let total: u64 = rows.iter().map(|r| r.1.1).sum();
        let count: i64 = rows.iter().map(|r| r.1.0).sum();
        let top: Vec<String> = rows
            .iter()
            .take(n)
            .map(|(k, v)| {
                format!("{}x {}x{} {} = {} MB @ {}:{}", v.0, k.0, k.1, k.2, v.1 >> 20, k.3.file(), k.3.line())
            })
            .collect();
        format!(
            "live textures {count} = {} MB (peak since start {} MB): [{}]",
            total >> 20,
            PEAK.load(std::sync::atomic::Ordering::Relaxed) >> 20,
            top.join("; ")
        )
    }
}

impl GpuTexture {
    /// Wraps an existing texture (a plane imported from the platform decoder).
    pub fn from_texture(texture: wgpu::Texture) -> Self {
        let view = texture.create_view(&Default::default());
        Self { texture, view, _live: None }
    }

    #[track_caller]
    pub(crate) fn create(device: &wgpu::Device, width: u32, height: u32, format: PixelFormat) -> Self {
        let at = std::panic::Location::caller();
        // Labeled by shape so an allocator report (play bench `MEM1`) tells which textures hold the memory.
        let label = format!("tex {width}x{height} {format:?}");
        let mut t = Self::from_texture(device.create_texture(&wgpu::TextureDescriptor {
            label: Some(&label),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: format.wgpu(),
            usage: usage(format),
            view_formats: &[],
        }));
        let bytes = u64::from(width) * u64::from(height) * u64::from(format.bytes_per_pixel());
        t._live = Some(Arc::new(census::Live::new(width, height, format!("{format:?}"), bytes, at)));
        t
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

    #[track_caller]
    pub(crate) fn acquire(&self, gpu: &Gpu, width: u32, height: u32, format: PixelFormat) -> PooledTexture {
        let key = (width, height, format);
        let taken = lock(&self.free).take(key);
        let texture = match taken {
            Some(t) => t,
            None => gpu.texture(width, height, format),
        };
        PooledTexture { texture: Some(texture), key, pool: Arc::clone(&self.free) }
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
