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
use sq_gpu::frames::{GpuFrame, PlaneLayout};
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

/// Uploaded pictures: the ones the last frame drew stay, the rest are dropped at `end_frame` (shortcut: no pool of unused
/// textures; add one when allocation shows in profiles).
#[derive(Default)]
pub struct PlaneCache {
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
        *self = Self::default();
    }

    /// The frame is recorded: only what it drew stays.
    pub fn end_frame(&mut self) {
        self.previous = std::mem::take(&mut self.used);
        self.rasters = std::mem::take(&mut self.used_rasters);
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
        upload(gpu, frame, &cpu.bytes)?
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

fn upload(gpu: &Arc<Gpu>, frame: &SQFrame, bytes: &[u8]) -> Result<Picture, PlaneError> {
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
            let (luma, chroma) = (gpu.texture(w, h, lf), gpu.texture(cw, ch, cf));
            gpu.upload_texture(&luma, &bytes[..luma_bytes], w * s as u32);
            gpu.upload_texture(&chroma, &bytes[luma_bytes..], cw * 2 * s as u32);
            Ok(Picture::ycbcr(luma, chroma, if deep { 10 } else { 8 }, full))
        }
        SQFramePixelFormat::Rgba8 => {
            need(w as usize * h as usize * 4)?;
            let t = gpu.texture(w, h, PixelFormat::Rgba8Unorm);
            gpu.upload_texture(&t, bytes, w * 4);
            Ok(Picture::rgba(t, 1))
        }
        SQFramePixelFormat::Rgba16f => {
            need(w as usize * h as usize * 8)?;
            let t = gpu.texture(w, h, PixelFormat::Rgba16Float);
            gpu.upload_texture(&t, bytes, w * 8);
            Ok(Picture::rgba(t, 0))
        }
        SQFramePixelFormat::Rgba32f => {
            need(w as usize * h as usize * 16)?;
            let t = gpu.texture(w, h, PixelFormat::Rgba32Float);
            gpu.upload_texture(&t, bytes, w * 16);
            Ok(Picture::rgba(t, 0))
        }
        other => Err(PlaneError::Unsupported(format!("{other:?}"))),
    }
}
