// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Windows/SQWinApp WinCompositor.upload / stillTexture / plane cache
//! `SQFrame` storage to textures: the one interop function of the render side (design section 3). A [`GpuFrame`] (a decoder
//! that already holds textures: the Mac VideoToolbox import) passes through without a copy; [`CpuPlanes`] (a software or
//! downloaded hardware frame) is written into textures cached by (media, index, proxy, divisor). The frames a render read
//! are held by the command buffer (`GpuCommands::keep`, released after the submission finished on the GPU).

use crate::compositor::Picture;
use sq_core_time::Id;
use sq_frame::buffer_pool::PooledBytes;
use sq_frame::sqframe::{SQFrame, SQFramePixelFormat, SQFrameStorage};
use sq_gpu::frames::{GpuFrame, GpuTexture, PlaneLayout};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use std::any::Any;
use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

/// Pixels in memory: the planes packed in the `SQFrame`'s pixel format layout (luma then interleaved chroma for NV12 / P010,
/// one plane otherwise), rows tightly packed.
pub struct CpuPlanes {
    /// Picture bytes, usually on loan from the decoder's buffer pool: dropping the planes returns the buffer.
    pub bytes: PooledBytes,
}

impl SQFrameStorage for CpuPlanes {}

/// Identity of an uploaded picture: the media's frame `index`; `proxy` pictures never mix with the original's; `divisor` is
/// the decode reduction (playback quality), so a changed size is a new key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PlaneKey {
    pub media: Id,
    pub index: i64,
    pub proxy: bool,
    pub divisor: u32,
}

#[derive(Debug)]
pub enum PlaneError {
    /// The storage is neither a `GpuFrame` nor `CpuPlanes`, or the pixel format has no texture layout.
    Unsupported(String),
    /// The bytes are shorter than the format needs.
    Short { need: usize, have: usize },
}

impl fmt::Display for PlaneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(s) => write!(f, "unsupported frame: {s}"),
            Self::Short { need, have } => write!(f, "frame bytes too short: need {need}, have {have}"),
        }
    }
}

impl std::error::Error for PlaneError {}

type TexKey = (u32, u32, PixelFormat);

/// Free textures kept per (size, format); more are dropped.
const POOL_PER_KEY: usize = 8;
/// Sizes kept in the free pool; a pool of more sizes is dropped whole (a zoom or a quality change).
const POOL_KEYS: usize = 12;
/// Frames a retired picture waits before its textures are written again: the 2 frames the GPU may still be reading.
const RETIRE_AFTER: u8 = 2;

/// Textures this cache created for uploaded pictures; recycled once the picture left the cache for `RETIRE_AFTER` frames.
struct Owned {
    key: Option<PlaneKey>,
    textures: Vec<(TexKey, GpuTexture)>,
    idle: u8,
}

/// Uploaded pictures: the ones the last frame drew stay, the rest are dropped at `end_frame`. Textures of dropped
/// uploaded pictures go to a free pool (by size and format) and are written again by the next upload instead of
/// creating 2 textures per layer and frame.
#[derive(Default)]
pub struct PlaneCache {
    owned: Vec<Owned>,
    fresh: Vec<(TexKey, GpuTexture)>,
    free: HashMap<TexKey, Vec<GpuTexture>>,
    created: usize,
    previous: HashMap<PlaneKey, Picture>,
    used: HashMap<PlaneKey, Picture>,
    rasters: HashMap<u64, Picture>,
    used_rasters: HashMap<u64, Picture>,
    stills: HashMap<Id, Picture>,
}

impl PlaneCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Forgets every picture (the engine's pictures changed size for the same frame).
    pub fn clear(&mut self) {
        let created = self.created;
        *self = Self::default();
        self.created = created;
    }

    /// The frame is recorded: only what it drew stays.
    pub fn end_frame(&mut self) {
        self.previous = std::mem::take(&mut self.used);
        self.rasters = std::mem::take(&mut self.used_rasters);
        let mut keep = Vec::with_capacity(self.owned.len());
        for mut o in std::mem::take(&mut self.owned) {
            if o.key.is_some_and(|k| self.previous.contains_key(&k)) {
                o.idle = 0;
            } else {
                o.idle += 1;
            }
            if o.idle >= RETIRE_AFTER {
                for (k, t) in o.textures {
                    let list = self.free.entry(k).or_default();
                    if list.len() < POOL_PER_KEY {
                        list.push(t);
                    }
                }
            } else {
                keep.push(o);
            }
        }
        self.owned = keep;
        if self.free.len() > POOL_KEYS {
            self.free.clear();
        }
    }

    /// Textures created (not reused) since the cache was made (tests).
    pub fn textures_created(&self) -> usize {
        self.created
    }

    /// A texture for an upload: a free one of the same size and format, else a new one.
    fn take_texture(&mut self, gpu: &Gpu, w: u32, h: u32, format: PixelFormat) -> GpuTexture {
        let key = (w, h, format);
        let t = match self.free.get_mut(&key).and_then(Vec::pop) {
            Some(t) => t,
            None => {
                self.created += 1;
                gpu.texture(w, h, format)
            }
        };
        self.fresh.push((key, t.clone()));
        t
    }

    /// Pictures cached for the frame being recorded and the one before (tests).
    pub fn len(&self) -> usize {
        self.previous.len() + self.used.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub(crate) fn raster(&mut self, key: u64) -> Option<Picture> {
        let p = self.used_rasters.get(&key).or_else(|| self.rasters.get(&key))?.clone();
        self.used_rasters.insert(key, p.clone());
        Some(p)
    }

    pub(crate) fn put_raster(&mut self, key: u64, p: Picture) {
        self.used_rasters.insert(key, p);
    }

    /// A PNG still, kept per media (a still never changes between frames); at most 24 are kept.
    pub(crate) fn still(&mut self, media: Id) -> Option<Picture> {
        self.stills.get(&media).cloned()
    }

    pub(crate) fn put_still(&mut self, media: Id, p: Picture) {
        if self.stills.len() >= 24 {
            self.stills.clear();
        }
        self.stills.insert(media, p);
    }
}

/// The picture of `frame` on the GPU. `key`: cache identity (`None` = upload every time, the frame is not cached). A
/// `GpuFrame` is added to `kept` (hand `kept` to `GpuCommands::keep` before the submit).
pub fn to_gpu(
    gpu: &Arc<Gpu>,
    frame: &SQFrame,
    key: Option<PlaneKey>,
    cache: &mut PlaneCache,
    kept: &mut Vec<Arc<GpuFrame>>,
) -> Result<Picture, PlaneError> {
    if let Some(k) = key
        && let Some(p) = cache.used.get(&k).or_else(|| cache.previous.get(&k))
    {
        let p = p.clone();
        cache.used.insert(k, p.clone());
        return Ok(p);
    }
    let any: Arc<dyn Any + Send + Sync> = Arc::clone(frame.storage()) as Arc<dyn SQFrameStorage>;
    let picture = if let Ok(gf) = Arc::clone(&any).downcast::<GpuFrame>() {
        let p = wrap(&gf, frame.pixel_format)?;
        kept.push(gf);
        p
    } else if let Some(cpu) = frame.storage_as::<CpuPlanes>() {
        let p = upload(gpu, frame, &cpu.bytes, cache)?;
        let textures = std::mem::take(&mut cache.fresh);
        cache.owned.push(Owned { key, textures, idle: 0 });
        p
    } else {
        return Err(PlaneError::Unsupported("storage".into()));
    };
    if let Some(k) = key {
        cache.used.insert(k, picture.clone());
    }
    Ok(picture)
}

fn wrap(gf: &GpuFrame, format: SQFramePixelFormat) -> Result<Picture, PlaneError> {
    let full = format.is_full_range();
    let plane = |i: usize| gf.planes.get(i).cloned().ok_or_else(|| PlaneError::Unsupported("missing plane".into()));
    Ok(match gf.layout {
        PlaneLayout::Nv12 => Picture::ycbcr(plane(0)?, plane(1)?, 8, full),
        PlaneLayout::P010 => Picture::ycbcr(plane(0)?, plane(1)?, 10, full),
        PlaneLayout::Rgba8Straight => Picture::rgba(plane(0)?, 1),
        PlaneLayout::Rgba16f => Picture::rgba(plane(0)?, 0),
    })
}

/// Textures and `write_texture` of one picture, timed for the per-frame bench trace (`Stage::Upload`) when it is on.
fn upload(gpu: &Arc<Gpu>, frame: &SQFrame, bytes: &[u8], cache: &mut PlaneCache) -> Result<Picture, PlaneError> {
    let started = sq_gpu::gpu::timing::upload_trace().then(std::time::Instant::now);
    let picture = upload_planes(gpu, frame, bytes, cache);
    if let Some(t) = started {
        sq_gpu::gpu::timing::add_upload(t.elapsed());
    }
    picture
}

fn upload_planes(gpu: &Arc<Gpu>, frame: &SQFrame, bytes: &[u8], cache: &mut PlaneCache) -> Result<Picture, PlaneError> {
    let (w, h) = (frame.width as u32, frame.height as u32);
    let need = |n: usize| if bytes.len() < n { Err(PlaneError::Short { need: n, have: bytes.len() }) } else { Ok(()) };
    match frame.pixel_format {
        SQFramePixelFormat::Nv12
        | SQFramePixelFormat::Nv12FullRange
        | SQFramePixelFormat::P010
        | SQFramePixelFormat::P010FullRange => {
            let deep = matches!(frame.pixel_format, SQFramePixelFormat::P010 | SQFramePixelFormat::P010FullRange);
            let full =
                matches!(frame.pixel_format, SQFramePixelFormat::Nv12FullRange | SQFramePixelFormat::P010FullRange);
            let s = if deep { 2usize } else { 1 };
            let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
            let luma_bytes = w as usize * h as usize * s;
            need(luma_bytes + cw as usize * ch as usize * 2 * s)?;
            let (lf, cf) = if deep {
                (PixelFormat::R16Unorm, PixelFormat::Rg16Unorm)
            } else {
                (PixelFormat::R8Unorm, PixelFormat::Rg8Unorm)
            };
            let (luma, chroma) = (cache.take_texture(gpu, w, h, lf), cache.take_texture(gpu, cw, ch, cf));
            gpu.upload_texture(&luma, &bytes[..luma_bytes], w * s as u32);
            gpu.upload_texture(&chroma, &bytes[luma_bytes..], cw * 2 * s as u32);
            Ok(Picture::ycbcr(luma, chroma, if deep { 10 } else { 8 }, full))
        }
        SQFramePixelFormat::P210 | SQFramePixelFormat::P210FullRange => {
            // 10-bit 4:2:2 in 16-bit words: full-height interleaved chroma, sampled as it is (no CPU merge to 4:2:0).
            let full = frame.pixel_format == SQFramePixelFormat::P210FullRange;
            let cw = w.div_ceil(2);
            let luma_bytes = w as usize * h as usize * 2;
            need(luma_bytes + cw as usize * h as usize * 4)?;
            let (luma, chroma) = (
                cache.take_texture(gpu, w, h, PixelFormat::R16Unorm),
                cache.take_texture(gpu, cw, h, PixelFormat::Rg16Unorm),
            );
            gpu.upload_texture(&luma, &bytes[..luma_bytes], w * 2);
            gpu.upload_texture(&chroma, &bytes[luma_bytes..], cw * 4);
            Ok(Picture::ycbcr(luma, chroma, 10, full))
        }
        SQFramePixelFormat::Rgba8 => {
            need(w as usize * h as usize * 4)?;
            let t = cache.take_texture(gpu, w, h, PixelFormat::Rgba8Unorm);
            gpu.upload_texture(&t, bytes, w * 4);
            Ok(Picture::rgba(t, 1))
        }
        SQFramePixelFormat::Rgba16f => {
            need(w as usize * h as usize * 8)?;
            let t = cache.take_texture(gpu, w, h, PixelFormat::Rgba16Float);
            gpu.upload_texture(&t, bytes, w * 8);
            Ok(Picture::rgba(t, 0))
        }
        SQFramePixelFormat::Rgba32f => {
            need(w as usize * h as usize * 16)?;
            let t = cache.take_texture(gpu, w, h, PixelFormat::Rgba32Float);
            gpu.upload_texture(&t, bytes, w * 16);
            Ok(Picture::rgba(t, 0))
        }
        other => Err(PlaneError::Unsupported(format!("{other:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compositor::gpu_test_support::gpu;
    use sq_core_time::Time;
    use sq_frame::sqframe::SQFrameColorSpace;

    fn nv12(w: usize, h: usize) -> SQFrame {
        let bytes = vec![100u8; w * h * 3 / 2];
        SQFrame::new(
            w,
            h,
            SQFramePixelFormat::Nv12,
            SQFrameColorSpace::Rec709,
            Time::ZERO,
            Arc::new(CpuPlanes { bytes: bytes.into() }),
        )
    }

    fn frame_of(gpu: &Arc<Gpu>, cache: &mut PlaneCache, f: &SQFrame) {
        let mut kept = Vec::new();
        to_gpu(gpu, f, None, cache, &mut kept).expect("uploads");
        cache.end_frame();
    }

    #[test]
    fn a_p210_picture_uploads_a_full_height_chroma_plane() {
        let Some(gpu) = gpu() else { return };
        let mut cache = PlaneCache::new();
        let (w, h) = (64usize, 32usize);
        let f = SQFrame::new(
            w,
            h,
            SQFramePixelFormat::P210,
            SQFrameColorSpace::Rec709,
            Time::ZERO,
            Arc::new(CpuPlanes { bytes: vec![0u8; w * h * 4].into() }),
        );
        let mut kept = Vec::new();
        let p = to_gpu(&gpu, &f, None, &mut cache, &mut kept).expect("uploads");
        let chroma = p.planes.1.expect("chroma plane");
        assert_eq!((chroma.width(), chroma.height()), (32, 32), "4:2:2: half the width, the full height");
        let short = SQFrame::new(
            w,
            h,
            SQFramePixelFormat::P210,
            SQFrameColorSpace::Rec709,
            Time::ZERO,
            Arc::new(CpuPlanes { bytes: vec![0u8; w * h * 3].into() }),
        );
        assert!(to_gpu(&gpu, &short, None, &mut cache, &mut kept).is_err(), "a 4:2:0 sized buffer is too short");
    }

    #[test]
    fn uploads_reuse_textures_only_after_two_frames() {
        let Some(gpu) = gpu() else { return };
        let mut cache = PlaneCache::new();
        let f = nv12(64, 32);
        frame_of(&gpu, &mut cache, &f);
        assert_eq!(cache.textures_created(), 2, "luma and chroma");
        // Frame 2: the first picture may still be read by the GPU, so it is not written again.
        frame_of(&gpu, &mut cache, &f);
        assert_eq!(cache.textures_created(), 4, "no reuse while a frame in flight may read the pictures");
        // From frame 3 on the textures of two frames ago are free again: the count stays flat.
        for _ in 0..10 {
            frame_of(&gpu, &mut cache, &f);
        }
        assert_eq!(cache.textures_created(), 4, "steady state is reuse only");
    }

    #[test]
    fn a_cached_picture_is_never_recycled_while_it_is_drawn() {
        let Some(gpu) = gpu() else { return };
        let mut cache = PlaneCache::new();
        let f = nv12(64, 32);
        let key = PlaneKey { media: Id::from_u128(1), index: 0, proxy: false, divisor: 1 };
        for _ in 0..6 {
            let mut kept = Vec::new();
            to_gpu(&gpu, &f, Some(key), &mut cache, &mut kept).expect("uploads");
            cache.end_frame();
        }
        assert_eq!(cache.textures_created(), 2, "the same key is one upload, drawn again and again");
    }

    #[test]
    fn other_sizes_do_not_take_each_others_textures() {
        let Some(gpu) = gpu() else { return };
        let mut cache = PlaneCache::new();
        for _ in 0..5 {
            frame_of(&gpu, &mut cache, &nv12(64, 32));
        }
        let before = cache.textures_created();
        frame_of(&gpu, &mut cache, &nv12(128, 64));
        assert_eq!(cache.textures_created(), before + 2);
    }

    fn patterned(w: usize, h: usize, seed: u8) -> SQFrame {
        let bytes: Vec<u8> = (0..w * h * 3 / 2).map(|i| (i as u8).wrapping_mul(7).wrapping_add(seed)).collect();
        SQFrame::new(
            w,
            h,
            SQFramePixelFormat::Nv12,
            SQFrameColorSpace::Rec709,
            Time::ZERO,
            Arc::new(CpuPlanes { bytes: bytes.into() }),
        )
    }

    fn planes_of(gpu: &Arc<Gpu>, cache: &mut PlaneCache, f: &SQFrame) -> (Vec<u8>, Vec<u8>) {
        let mut kept = Vec::new();
        let p = to_gpu(gpu, f, None, cache, &mut kept).expect("uploads");
        let luma = gpu.read_texture(&p.planes.0).expect("luma");
        let chroma = gpu.read_texture(p.planes.1.as_ref().expect("chroma plane")).expect("chroma");
        cache.end_frame();
        (luma, chroma)
    }

    #[test]
    fn a_reused_texture_holds_exactly_the_pixels_of_an_unpooled_upload() {
        let Some(gpu) = gpu() else { return };
        let mut pooled = PlaneCache::new();
        for seed in 0..8u8 {
            let f = patterned(64, 32, seed.wrapping_mul(31));
            let got = planes_of(&gpu, &mut pooled, &f);
            let want = planes_of(&gpu, &mut PlaneCache::new(), &f);
            assert_eq!(got, want, "frame {seed}: pooled upload differs from a fresh texture");
        }
        assert_eq!(pooled.textures_created(), 4, "the later frames reused textures");
    }
}
