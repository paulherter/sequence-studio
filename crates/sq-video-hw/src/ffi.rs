//! The only `unsafe` in the crate: VideoToolbox session, CoreVideo pixel buffers and the Metal import into wgpu.
//! Everything outside this module sees safe types: `Session`, `PixelBuffer`, `Importer`, `Imported`.
//! Port of spikes/g1-video/src/vt.rs and `Gpu::import_plane` in spikes/g1-video/src/main.rs.

use crate::codec::{Codec, PixelKind};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::{CFBoolean, CFData, CFDictionary, CFNumber, CFRetained, CFString, CFType};
use objc2_core_media::{
    CMBlockBuffer, CMFormatDescription, CMSampleBuffer, CMSampleTimingInfo, CMTime, CMTimeFlags,
    CMVideoFormatDescriptionCreate, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
};
use objc2_core_video::{
    CVImageBuffer, CVMetalTexture, CVMetalTextureCache, CVMetalTextureGetTexture, CVPixelBuffer,
    CVPixelBufferGetHeightOfPlane, CVPixelBufferGetPixelFormatType, CVPixelBufferGetWidthOfPlane,
    kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferPixelFormatTypeKey,
};
use objc2_metal::{MTLDevice, MTLPixelFormat, MTLTexture, MTLTextureType};
use objc2_video_toolbox::{
    VTDecodeFrameFlags, VTDecodeInfoFlags, VTDecompressionOutputCallbackRecord, VTDecompressionSession,
};
use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr::{NonNull, null, null_mut};
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::Duration;
use wgpu::hal;

/// Why a session or an import failed.
#[derive(Debug)]
pub enum Failure {
    /// The platform cannot do this (no hardware decoder, unsupported stream).
    Unsupported(String),
    /// A CoreMedia / VideoToolbox / CoreVideo status code (`OSStatus`).
    Status(i32),
}

fn status(rc: i32) -> Failure {
    Failure::Status(rc)
}

/// Stream facts a session is created from.
pub struct Config<'a> {
    pub codec: Codec,
    pub width: i32,
    pub height: i32,
    /// avcC / hvcC record (empty for ProRes).
    pub extradata: &'a [u8],
    pub pixel: PixelKind,
    /// The stream is full range: ask for the full-range layout.
    pub full: bool,
}

/// A CoreMedia time: `value / timescale` seconds.
#[derive(Clone, Copy, Debug)]
pub struct Stamp {
    pub value: i64,
    pub timescale: i32,
}

impl Stamp {
    fn cm(self) -> CMTime {
        CMTime { value: self.value, timescale: self.timescale, flags: CMTimeFlags::Valid, epoch: 0 }
    }
}

/// A decoded picture: the CVPixelBuffer (IOSurface-backed) of one frame.
pub struct PixelBuffer(CFRetained<CVPixelBuffer>);

// SAFETY: CoreVideo buffers are reference-counted, thread-safe objects; we only hand them to the texture cache and
// release them, and the pixels are never written after VideoToolbox delivered them.
unsafe impl Send for PixelBuffer {}
// SAFETY: see above, shared use is read-only.
unsafe impl Sync for PixelBuffer {}

impl PixelBuffer {
    pub fn kind(&self) -> Option<PixelKind> {
        PixelKind::from_fourcc(CVPixelBufferGetPixelFormatType(&self.0))
    }
}

/// One output of the session: which sample it came from (`tag` given to `submit`) and its picture.
pub struct Output {
    pub tag: usize,
    pub buffer: PixelBuffer,
}

struct Shared {
    queue: Mutex<VecDeque<Output>>,
    ready: Condvar,
    inflight: AtomicUsize,
    errors: AtomicUsize,
    last_status: AtomicI32,
}

unsafe extern "C-unwind" fn on_frame(
    refcon: *mut c_void,
    source: *mut c_void,
    rc: i32,
    _flags: VTDecodeInfoFlags,
    image: *mut CVImageBuffer,
    _pts: CMTime,
    _dur: CMTime,
) {
    // SAFETY: refcon is the `Shared` of the session; `Session::drop` invalidates the session (no callback after that)
    // before the box is freed.
    let shared = unsafe { &*(refcon as *const Shared) };
    match (rc, NonNull::new(image)) {
        (0, Some(img)) => {
            // SAFETY: VideoToolbox passes a borrowed image buffer, valid for this call; retain it for our queue.
            let pb = unsafe { CFRetained::retain(img) };
            shared
                .queue
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push_back(Output { tag: source as usize, buffer: PixelBuffer(pb) });
        }
        _ => {
            shared.last_status.store(if rc == 0 { -1 } else { rc }, Ordering::Relaxed);
            shared.errors.fetch_add(1, Ordering::Relaxed);
        }
    }
    shared.inflight.fetch_sub(1, Ordering::AcqRel);
    shared.ready.notify_all();
}

/// An asynchronous hardware decompression session. Methods take `&self`; callers serialize decodes themselves.
pub struct Session {
    session: CFRetained<VTDecompressionSession>,
    format: CFRetained<CMFormatDescription>,
    shared: Box<Shared>,
}

// SAFETY: VTDecompressionSession and CMFormatDescription are thread-safe CF objects; `Shared` is Sync by construction.
unsafe impl Send for Session {}
// SAFETY: see above.
unsafe impl Sync for Session {}

impl Session {
    pub fn new(cfg: &Config<'_>) -> Result<Session, Failure> {
        let codec = u32::from_be_bytes(cfg.codec.fourcc());
        let extensions: Option<CFRetained<CFDictionary<CFString, CFType>>> = cfg.codec.config_atom().map(|name| {
            let data = CFData::from_bytes(cfg.extradata);
            let key = CFString::from_str(name);
            let atoms = CFDictionary::<CFString, CFType>::from_slices(&[&*key], &[&**data]);
            // SAFETY: CoreMedia's extern static string key.
            let k = unsafe { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms };
            CFDictionary::<CFString, CFType>::from_slices(&[k], &[&**atoms])
        });
        let mut format: *const CMFormatDescription = null();
        // SAFETY: valid out pointer; the extensions are deep-copied by CoreMedia.
        let rc = unsafe {
            CMVideoFormatDescriptionCreate(
                None,
                codec,
                cfg.width,
                cfg.height,
                extensions.as_deref().map(|d| d.as_opaque()),
                NonNull::from(&mut format),
            )
        };
        let format = NonNull::new(format as *mut CMFormatDescription).filter(|_| rc == 0).ok_or(status(rc))?;
        // SAFETY: Create returned +1 ownership.
        let format = unsafe { CFRetained::from_raw(format) };

        let pixel = CFNumber::new_i32(u32::from_be_bytes(cfg.pixel.fourcc(cfg.full)) as i32);
        let empty = CFDictionary::<CFString, CFType>::from_slices(&[], &[]);
        // SAFETY: CoreVideo extern static keys.
        let (kp, ki, km) = unsafe {
            (
                kCVPixelBufferPixelFormatTypeKey,
                kCVPixelBufferIOSurfacePropertiesKey,
                kCVPixelBufferMetalCompatibilityKey,
            )
        };
        let attrs =
            CFDictionary::<CFString, CFType>::from_slices(&[kp, ki, km], &[&**pixel, &**empty, CFBoolean::new(true)]);
        let hw_key = CFString::from_static_str("RequireHardwareAcceleratedVideoDecoder");
        let spec = CFDictionary::<CFString, CFType>::from_slices(&[&*hw_key], &[CFBoolean::new(true)]);

        let shared = Box::new(Shared {
            queue: Mutex::new(VecDeque::new()),
            ready: Condvar::new(),
            inflight: AtomicUsize::new(0),
            errors: AtomicUsize::new(0),
            last_status: AtomicI32::new(0),
        });
        let record = VTDecompressionOutputCallbackRecord {
            decompressionOutputCallback: Some(on_frame),
            decompressionOutputRefCon: &*shared as *const Shared as *mut c_void,
        };
        let mut raw: *mut VTDecompressionSession = null_mut();
        // SAFETY: all CF arguments are valid; VideoToolbox copies the callback record.
        let rc = unsafe {
            VTDecompressionSession::create(
                None,
                &format,
                Some(spec.as_opaque()),
                Some(attrs.as_opaque()),
                &record,
                NonNull::from(&mut raw),
            )
        };
        let session = NonNull::new(raw).filter(|_| rc == 0).ok_or(status(rc))?;
        // SAFETY: Create returned +1 ownership.
        let session = unsafe { CFRetained::from_raw(session) };
        Ok(Session { session, format, shared })
    }

    /// Frames submitted and not yet delivered (as output or error).
    pub fn inflight(&self) -> usize {
        self.shared.inflight.load(Ordering::Acquire)
    }

    /// Frames the hardware failed to decode since the session was created, and the last status.
    pub fn failures(&self) -> (usize, i32) {
        (self.shared.errors.load(Ordering::Relaxed), self.shared.last_status.load(Ordering::Relaxed))
    }

    /// Queues one compressed sample (length-prefixed NAL units for H.264/HEVC); `tag` comes back with its picture.
    pub fn submit(&self, data: &[u8], pts: Stamp, dts: Stamp, duration: Stamp, tag: usize) -> Result<(), Failure> {
        let len = data.len();
        let mut block: *mut CMBlockBuffer = null_mut();
        // SAFETY: CoreMedia allocates `len` bytes, we copy the compressed sample into them (compressed data only),
        // every out pointer is valid for the call, and the retained objects come from +1 Create calls.
        unsafe {
            let rc = CMBlockBuffer::create_with_memory_block(
                None,
                null_mut(),
                len,
                None,
                null(),
                0,
                len,
                0,
                NonNull::from(&mut block),
            );
            let block = NonNull::new(block).filter(|_| rc == 0).ok_or(status(rc))?;
            let block = CFRetained::from_raw(block);
            let src =
                NonNull::new(data.as_ptr() as *mut c_void).ok_or(Failure::Unsupported("empty sample".to_string()))?;
            let rc = CMBlockBuffer::replace_data_bytes(src, &block, 0, len);
            if rc != 0 {
                return Err(status(rc));
            }
            let timing = CMSampleTimingInfo {
                duration: duration.cm(),
                presentationTimeStamp: pts.cm(),
                decodeTimeStamp: dts.cm(),
            };
            let mut sample: *mut CMSampleBuffer = null_mut();
            let rc = CMSampleBuffer::create_ready(
                None,
                Some(&block),
                Some(&self.format),
                1,
                1,
                &timing,
                1,
                &len,
                NonNull::from(&mut sample),
            );
            let sample = NonNull::new(sample).filter(|_| rc == 0).ok_or(status(rc))?;
            let sample = CFRetained::from_raw(sample);
            self.shared.inflight.fetch_add(1, Ordering::AcqRel);
            let mut info = VTDecodeInfoFlags(0);
            let rc = self.session.decode_frame(
                &sample,
                VTDecodeFrameFlags::Frame_EnableAsynchronousDecompression,
                tag as *mut c_void,
                &mut info,
            );
            if rc != 0 {
                self.shared.inflight.fetch_sub(1, Ordering::AcqRel);
                return Err(status(rc));
            }
        }
        Ok(())
    }

    /// Moves every finished picture into `out` (decode-complete order, not presentation order).
    pub fn take(&self, out: &mut Vec<Output>) {
        out.extend(self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner).drain(..));
    }

    /// Waits up to `timeout` for a picture or an error to arrive (returns at once when one is queued or nothing is in flight).
    pub fn wait_output(&self, timeout: Duration) {
        let queue = self.shared.queue.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = self.shared.ready.wait_timeout_while(queue, timeout, |q| q.is_empty() && self.inflight() > 0);
    }

    /// Forces out every picture the decoder still holds for reordering and waits until all callbacks ran.
    pub fn finish(&self) {
        // SAFETY: plain calls on a live session.
        unsafe {
            self.session.finish_delayed_frames();
            self.session.wait_for_asynchronous_frames();
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: after `invalidate` no callback runs, so `shared` can be freed safely afterwards.
        unsafe {
            self.session.wait_for_asynchronous_frames();
            self.session.invalidate();
        }
    }
}

/// What must outlive the GPU's reads of an imported frame: the pixel buffer and its Metal textures.
pub struct Keep {
    _buffer: PixelBuffer,
    _textures: Vec<CFRetained<CVMetalTexture>>,
}

// SAFETY: held only to be released later; CoreVideo objects are thread-safe reference-counted objects.
unsafe impl Send for Keep {}
// SAFETY: never accessed.
unsafe impl Sync for Keep {}

/// The planes of one picture as wgpu textures plus their keep-alive.
pub struct Imported {
    pub planes: Vec<wgpu::Texture>,
    pub size: (u32, u32),
    pub kind: PixelKind,
    pub keep: Keep,
}

/// A CVMetalTextureCache on the wgpu device's MTLDevice.
pub struct Importer {
    device: wgpu::Device,
    cache: CFRetained<CVMetalTextureCache>,
}

// SAFETY: CVMetalTextureCache is documented thread-safe; the decoder additionally uses it under its state lock.
unsafe impl Send for Importer {}
// SAFETY: see above.
unsafe impl Sync for Importer {}

impl Importer {
    pub fn new(device: &wgpu::Device) -> Result<Importer, Failure> {
        // SAFETY: the hal device is only used to clone its MTLDevice for the texture cache.
        let mtl: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
            let hal_device = device
                .as_hal::<hal::api::Metal>()
                .ok_or(Failure::Unsupported("the wgpu device is not a Metal device".to_string()))?;
            hal_device.raw_device().clone()
        };
        let mut raw: *mut CVMetalTextureCache = null_mut();
        // SAFETY: plain CoreVideo create call with a valid out pointer.
        let rc = unsafe { CVMetalTextureCache::create(None, None, &mtl, None, NonNull::from(&mut raw)) };
        let cache = NonNull::new(raw).filter(|_| rc == 0).ok_or(status(rc))?;
        // SAFETY: create returned +1 ownership.
        let cache = unsafe { CFRetained::from_raw(cache) };
        Ok(Importer { device: device.clone(), cache })
    }

    /// Wraps both planes of `buffer` as wgpu textures without a copy; every Metal texture is checked to be IOSurface-backed.
    pub fn import(&self, buffer: PixelBuffer) -> Result<Imported, Failure> {
        let kind = buffer.kind().ok_or(Failure::Unsupported("unexpected pixel format".to_string()))?;
        let mut planes = Vec::with_capacity(2);
        let mut textures = Vec::with_capacity(2);
        for plane in 0..2 {
            let (texture, cv) = self.import_plane(&buffer.0, plane, kind.is_sixteen_bit())?;
            planes.push(texture);
            textures.push(cv);
        }
        let size =
            (CVPixelBufferGetWidthOfPlane(&buffer.0, 0) as u32, CVPixelBufferGetHeightOfPlane(&buffer.0, 0) as u32);
        Ok(Imported { planes, size, kind, keep: Keep { _buffer: buffer, _textures: textures } })
    }

    fn import_plane(
        &self,
        buffer: &CVPixelBuffer,
        plane: usize,
        sixteen: bool,
    ) -> Result<(wgpu::Texture, CFRetained<CVMetalTexture>), Failure> {
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane);
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane);
        let (metal_format, format) = match (plane, sixteen) {
            (0, false) => (MTLPixelFormat::R8Unorm, wgpu::TextureFormat::R8Unorm),
            (0, true) => (MTLPixelFormat::R16Unorm, wgpu::TextureFormat::R16Unorm),
            (_, false) => (MTLPixelFormat::RG8Unorm, wgpu::TextureFormat::Rg8Unorm),
            (_, true) => (MTLPixelFormat::RG16Unorm, wgpu::TextureFormat::Rg16Unorm),
        };
        let mut out: *mut CVMetalTexture = null_mut();
        // SAFETY: valid cache and pixel buffer, out pointer valid for the call.
        let rc = unsafe {
            CVMetalTextureCache::create_texture_from_image(
                None,
                &self.cache,
                buffer,
                None,
                metal_format,
                w,
                h,
                plane,
                NonNull::from(&mut out),
            )
        };
        let cv = NonNull::new(out).filter(|_| rc == 0).ok_or(status(rc))?;
        // SAFETY: +1 from the create call.
        let cv = unsafe { CFRetained::from_raw(cv) };
        let metal = CVMetalTextureGetTexture(&cv).ok_or(Failure::Unsupported("no MTLTexture".to_string()))?;
        if metal.iosurface().is_none() {
            return Err(Failure::Unsupported("MTLTexture is not IOSurface-backed (would imply a copy)".to_string()));
        }
        let size = wgpu::Extent3d { width: w as u32, height: h as u32, depth_or_array_layers: 1 };
        // SAFETY: the MTLTexture is a 2D, 1-mip, 1-layer texture of `format`; the CVMetalTexture that owns its backing is
        // returned to the caller, who keeps it (in `Keep`) until the GPU work using the texture has completed.
        let texture = unsafe {
            let raw = hal::metal::Device::texture_from_raw(
                metal,
                format,
                MTLTextureType::Type2D,
                1,
                1,
                hal::CopyExtent { width: size.width, height: size.height, depth: 1 },
                None,
            );
            self.device.create_texture_from_hal::<hal::api::Metal>(
                raw,
                &wgpu::TextureDescriptor {
                    label: Some("video plane"),
                    size,
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
                    view_formats: &[],
                },
                wgpu::TextureUses::RESOURCE,
            )
        };
        Ok((texture, cv))
    }

    /// Releases textures the cache still holds (call now and then while decoding).
    pub fn flush(&self) {
        self.cache.flush(0);
    }
}
