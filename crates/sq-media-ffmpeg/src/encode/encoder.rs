//! Safe wrappers over `vendor/encode.cpp` and `vendor/still.cpp`. Every block says why it holds.
#![allow(unsafe_code)]

use super::raw;
use crate::shim::ShimError;
use std::ffi::{CStr, CString, c_char, c_int};
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};

/// `AVERROR(EINVAL)`.
const EINVAL: i32 = -22;
/// FFmpeg's `AVERROR_ENCODER_NOT_FOUND` (`FFERRTAG(0xF8,'E','N','C')`): no encoder of the wanted kind in this build.
pub const ENCODER_NOT_FOUND: i32 = -1_129_203_192;
const ERR_LEN: usize = 256;

fn error(what: &str, code: i32, err: &[c_char]) -> ShimError {
    let bytes: Vec<u8> = err.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    let text = String::from_utf8_lossy(&bytes);
    let message = if text.is_empty() { format!("{what} failed ({code})") } else { format!("{what}: {text}") };
    ShimError { code, message }
}

fn failed(what: &str, code: i32) -> ShimError {
    ShimError { code, message: format!("{what} failed ({code})") }
}

fn c_path(path: &Path) -> Result<CString, ShimError> {
    let text = path.to_str().ok_or_else(|| failed("path", EINVAL))?;
    CString::new(text).map_err(|_| failed("path", EINVAL))
}

/// What a file is written with. The C struct documents every field; `Default` is H.264, no audio, software.
#[derive(Clone, Debug, Default)]
pub struct EncodeConfig {
    /// Output file; the container follows its extension.
    pub path: PathBuf,
    /// HEVC instead of H.264.
    pub hevc: bool,
    /// Try the hardware encoders before software.
    pub hardware: bool,
    pub width: i32,
    pub height: i32,
    /// Frame rate as numerator / denominator (the inverse of the frame duration).
    pub fps_num: i32,
    pub fps_den: i32,
    pub bitrate: i64,
    pub gop: i32,
    /// 0 = none.
    pub b_frames: i32,
    /// HEVC Main 10 (P010 input).
    pub ten_bit: bool,
    /// The H.264 profile (ignored for HEVC and ProRes); `Baseline` also means no B-frames.
    pub h264_profile: super::H264Profile,
    /// 0 = H.264/HEVC, else 1 + the `prores_ks` profile (1 Proxy, 2 LT, 3 422, 4 HQ, 5 4444).
    pub prores: i32,
    /// 0 = AAC, else 16, 24 or 32 bit integer PCM.
    pub pcm_bits: i32,
    pub audio_rate: i32,
    /// 0 = no audio.
    pub audio_channels: i32,
    pub audio_bitrate: i64,
    /// Further audio tracks after the first (up to 7): `(rate, channels)` each, same codec and depth.
    pub extra_audio: Vec<(i32, i32)>,
    /// Audio-only file (M4A, WAV or FLAC by the extension).
    pub no_video: bool,
    /// FLAC audio; `pcm_bits` is its depth.
    pub flac: bool,
    /// Animated GIF: `Pal8` frames, `frame_index` = start in centiseconds.
    pub gif: bool,
    /// Centiseconds the last GIF frame shows.
    pub gif_final_delay: i32,
    /// 0 = a target bitrate; else constant quality 0.05...1 (no bitrate target, no cap).
    pub quality: f64,
    /// 0 = the default cap (1.5 x `bitrate`); else the VBR maximum.
    pub max_bitrate: i64,
    /// Constant bitrate: maximum and minimum rate equal the bitrate.
    pub cbr: bool,
    /// 0 = Quality, 1 = Balanced, 2 = Fast: the software preset and the hardware speed hint.
    pub speed: i32,
    /// `AVColorPrimaries`, `AVColorTransferCharacteristic`, `AVColorSpace` tags of the video stream (0 = Rec. 709).
    pub color_tags: (i32, i32, i32),
    /// Clockwise degrees stored as the stream's display matrix (0 = none).
    pub rotation: i32,
    /// Container tags: title, comment (description) and creation time (ISO 8601); empty = none.
    pub tags: Tags,
    /// 24-byte mastering display color volume (HDR delivery); empty = none.
    pub mdcv: Vec<u8>,
    /// 4-byte content light level (MaxCLL, MaxFALL); empty = none.
    pub cll: Vec<u8>,
}

/// What an opened video encoder really does (see `Encoder::video_facts`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoFacts {
    /// Bits per sample of the pictures it takes: 8, or 10 for HEVC Main 10.
    pub bit_depth: i32,
    /// Packets came out in a different order than the pictures went in: it writes B-frames.
    pub reordered: bool,
}

/// The descriptive container tags of a file.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tags {
    pub title: String,
    pub comment: String,
    pub creation_time: String,
}

/// Pixel layout of the bytes handed to `Encoder::video` or `write_still` (an `AVPixelFormat`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelLayout {
    Bgra,
    Rgba,
    /// 8-bit 4:2:0, Y plane then interleaved CbCr.
    Nv12,
    /// 10-bit 4:2:0 in 16-bit words, two planes.
    P010le,
    /// 16-bit float RGBA.
    Rgbaf16le,
    /// 16-bit integer RGBA.
    Rgba64le,
    /// Palette indices, then 256 BGRA entries (GIF).
    Pal8,
    /// Planar G, B, R, A as 32-bit floats (EXR).
    Gbrapf32le,
}

impl PixelLayout {
    /// The `AVPixelFormat` name.
    pub fn name(self) -> &'static str {
        match self {
            PixelLayout::Bgra => "bgra",
            PixelLayout::Rgba => "rgba",
            PixelLayout::Nv12 => "nv12",
            PixelLayout::P010le => "p010le",
            PixelLayout::Rgbaf16le => "rgbaf16le",
            PixelLayout::Rgba64le => "rgba64le",
            PixelLayout::Pal8 => "pal8",
            PixelLayout::Gbrapf32le => "gbrapf32le",
        }
    }

    /// Bytes the C side reads for a `w` x `h` picture whose first plane has `stride` bytes per row.
    fn required_len(self, w: usize, h: usize, stride: usize) -> usize {
        match self {
            PixelLayout::Bgra | PixelLayout::Rgba | PixelLayout::Rgbaf16le | PixelLayout::Rgba64le => stride * h,
            PixelLayout::Pal8 => stride * h + 1024,
            // The chroma plane starts after `w`-wide rows (tight packing, the only layout the frames use).
            PixelLayout::Nv12 => stride * h + w * h.div_ceil(2),
            PixelLayout::P010le => stride * h + w * 2 * h.div_ceil(2),
            PixelLayout::Gbrapf32le => 16 * w * h,
        }
    }
}

fn check_len(layout: PixelLayout, pixels: &[u8], w: i32, h: i32, stride: i32) -> Result<(), ShimError> {
    let (w, h, s) = (usize::try_from(w), usize::try_from(h), usize::try_from(stride));
    let (Ok(w), Ok(h), Ok(s)) = (w, h, s) else { return Err(failed("picture size", EINVAL)) };
    if w == 0 || h == 0 || s == 0 || pixels.len() < layout.required_len(w, h, s) {
        return Err(failed("picture size", EINVAL));
    }
    Ok(())
}

/// One output file being written. Dropping it without `finish` aborts and deletes the partial file.
pub struct Encoder {
    raw: NonNull<raw::Encoder>,
    path: PathBuf,
    width: i32,
    height: i32,
    has_video: bool,
    /// Channels of every audio track in order (the first, then the extras).
    audio_channels: Vec<usize>,
}

// SAFETY: the C++ object is only reached through `&mut self` or by value, never concurrently.
unsafe impl Send for Encoder {}

impl Encoder {
    /// Opens the encoders and writes the container header. `ENCODER_NOT_FOUND` when this build has no encoder for it.
    pub fn open(cfg: &EncodeConfig) -> Result<Encoder, ShimError> {
        let path = c_path(&cfg.path)?;
        let text = |s: &str| CString::new(s.replace('\0', "")).unwrap_or_default();
        let (title, comment, creation) =
            (text(&cfg.tags.title), text(&cfg.tags.comment), text(&cfg.tags.creation_time));
        let cands = super::candidates(cfg.hevc, cfg.prores > 0, cfg.gif, cfg.hardware, super::Platform::current());
        let encoders = text(&cands.names.join(","));
        let request = super::VideoRequest {
            hevc: cfg.hevc,
            profile: cfg.h264_profile,
            quality: cfg.quality,
            cbr: cfg.cbr,
            speed: cfg.speed,
            b_frames: cfg.b_frames,
        };
        let options = text(&super::option_lines(&cands.names, &request));
        let c = raw::Config {
            path: path.as_ptr(),
            hevc: c_int::from(cfg.hevc),
            hardware: c_int::from(cfg.hardware),
            width: cfg.width,
            height: cfg.height,
            fps_num: cfg.fps_num,
            fps_den: cfg.fps_den,
            bitrate: cfg.bitrate,
            gop: cfg.gop,
            b_frames: cfg.b_frames,
            ten_bit: c_int::from(cfg.ten_bit),
            prores: cfg.prores,
            pcm_bits: cfg.pcm_bits,
            audio_rate: cfg.audio_rate,
            audio_channels: cfg.audio_channels,
            audio_bitrate: cfg.audio_bitrate,
            no_video: c_int::from(cfg.no_video),
            flac: c_int::from(cfg.flac),
            gif: c_int::from(cfg.gif),
            gif_final_delay: cfg.gif_final_delay,
            quality: cfg.quality,
            max_bitrate: cfg.max_bitrate,
            cbr: c_int::from(cfg.cbr),
            speed: cfg.speed,
            color_primaries: cfg.color_tags.0,
            color_trc: cfg.color_tags.1,
            color_space: cfg.color_tags.2,
            rotation: cfg.rotation,
            title: title.as_ptr(),
            comment: comment.as_ptr(),
            creation_time: creation.as_ptr(),
            mdcv: if cfg.mdcv.len() == 24 { cfg.mdcv.as_ptr() } else { ptr::null() },
            cll: if cfg.cll.len() == 4 { cfg.cll.as_ptr() } else { ptr::null() },
            encoders: encoders.as_ptr(),
            encoder_options: options.as_ptr(),
            hardware_encoders: cands.hardware as c_int,
            extra_audio_count: 0,
            extra_audio_rate: [0; 7],
            extra_audio_channels: [0; 7],
            h264_profile: if cfg.hevc { 0 } else { cfg.h264_profile.code() },
        };
        let mut out = ptr::null_mut();
        let mut err = [0 as c_char; ERR_LEN];
        let extras: Vec<(i32, i32)> = cfg.extra_audio.iter().copied().take(7).collect();
        let mut c = c;
        c.extra_audio_count = extras.len() as c_int;
        for (i, (rate, channels)) in extras.iter().enumerate() {
            c.extra_audio_rate[i] = *rate;
            c.extra_audio_channels[i] = *channels;
        }
        // SAFETY: `c` and `path` outlive the call (the shim copies what it keeps), `out` and `err` are valid, `err` has ERR_LEN bytes.
        let r = unsafe { raw::sq_enc_open(&c, &mut out, err.as_mut_ptr(), ERR_LEN as c_int) };
        match NonNull::new(out) {
            Some(raw) if r == 0 => Ok(Encoder {
                raw,
                path: cfg.path.clone(),
                width: cfg.width,
                height: cfg.height,
                has_video: !cfg.no_video,
                audio_channels: std::iter::once(cfg.audio_channels)
                    .chain(extras.iter().map(|e| e.1))
                    .map(|c| usize::try_from(c).unwrap_or(0))
                    .collect(),
            }),
            _ => Err(error("encoder", if r == 0 { -1 } else { r }, &err)),
        }
    }

    /// FFmpeg name of the video encoder in use ("h264_videotoolbox", "libx264", ...); empty without video.
    pub fn video_name(&self) -> String {
        // SAFETY: the name is a NUL-terminated array inside the live encoder object.
        unsafe {
            let p = raw::sq_enc_video_name(self.raw.as_ptr());
            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
        }
    }

    /// What the opened video encoder really does; the B-frame answer is final only after `drain_video` (or enough pictures).
    pub fn video_facts(&self) -> VideoFacts {
        let (mut bit_depth, mut reordered) = (0, 0);
        // SAFETY: the handle is live and both out pointers are valid for the call.
        unsafe { raw::sq_enc_video_facts(self.raw.as_ptr(), &mut bit_depth, &mut reordered) };
        VideoFacts { bit_depth, reordered: reordered != 0 }
    }

    /// Ends the video stream and writes what the encoder still holds, so `video_facts` is complete. No picture may
    /// follow: for probes, which drop the encoder afterwards (the partial file is deleted).
    pub fn drain_video(&mut self) -> Result<(), ShimError> {
        // SAFETY: the handle is live; the shim only flushes the video encoder.
        let r = unsafe { raw::sq_enc_drain_video(self.raw.as_ptr()) };
        if r == 0 { Ok(()) } else { Err(failed("video drain", r)) }
    }

    /// One picture of the configured size; `stride` is the bytes of a first-plane row. `index` is its timestamp in
    /// frames (GIF: centiseconds).
    pub fn video(&mut self, pixels: &[u8], layout: PixelLayout, stride: i32, index: i64) -> Result<(), ShimError> {
        if !self.has_video {
            return Err(failed("video encode", EINVAL));
        }
        check_len(layout, pixels, self.width, self.height, stride)?;
        let format = CString::new(layout.name()).map_err(|_| failed("pixel format", EINVAL))?;
        // SAFETY: `pixels` holds at least what the layout needs for width x height (checked above); the shim copies it.
        let r = unsafe { raw::sq_enc_video(self.raw.as_ptr(), pixels.as_ptr(), format.as_ptr(), stride, index) };
        if r == 0 { Ok(()) } else { Err(failed(&format!("video encode frame {index}"), r)) }
    }

    /// Interleaved float frames of the first audio track at the configured rate and channel count.
    pub fn audio(&mut self, interleaved: &[f32]) -> Result<(), ShimError> {
        self.audio_track(0, interleaved)
    }

    /// The same for audio track `track` (0 = the first, 1... = `extra_audio` in order).
    pub fn audio_track(&mut self, track: usize, interleaved: &[f32]) -> Result<(), ShimError> {
        let channels = self.audio_channels.get(track).copied().unwrap_or(0);
        if channels == 0 || !interleaved.len().is_multiple_of(channels) {
            return Err(failed("audio encode", EINVAL));
        }
        let frames = c_int::try_from(interleaved.len() / channels).map_err(|_| failed("audio encode", EINVAL))?;
        let track = c_int::try_from(track).map_err(|_| failed("audio encode", EINVAL))?;
        // SAFETY: `interleaved` holds `frames * channels` floats; the shim copies them.
        let r = unsafe { raw::sq_enc_audio_track(self.raw.as_ptr(), track, interleaved.as_ptr(), frames) };
        if r == 0 { Ok(()) } else { Err(failed("audio encode", r)) }
    }

    /// Flushes, writes the trailer and closes the file. On failure the partial file is deleted.
    pub fn finish(self) -> Result<(), ShimError> {
        let mut err = [0 as c_char; ERR_LEN];
        let raw = self.raw;
        let path = self.path.clone();
        std::mem::forget(self);
        // SAFETY: the handle is live; `sq_enc_finish` frees it on every outcome and `forget` skipped our Drop.
        let r = unsafe { raw::sq_enc_finish(raw.as_ptr(), err.as_mut_ptr(), ERR_LEN as c_int) };
        if r == 0 {
            Ok(())
        } else {
            let _ = std::fs::remove_file(path);
            Err(error("finish", r, &err))
        }
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_enc_open` and is aborted once (`finish` forgets `self` instead).
        unsafe { raw::sq_enc_abort(self.raw.as_ptr()) }
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Image encoder of a still.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StillCodec {
    Png,
    Mjpeg,
    Tiff,
    Exr,
}

impl StillCodec {
    fn name(self) -> &'static str {
        match self {
            StillCodec::Png => "png",
            StillCodec::Mjpeg => "mjpeg",
            StillCodec::Tiff => "tiff",
            StillCodec::Exr => "exr",
        }
    }
}

/// One still image file. `alpha` keeps the alpha channel (PNG, TIFF); `quality` 0...1 (JPEG).
#[allow(clippy::too_many_arguments)]
pub fn write_still(
    path: &Path,
    codec: StillCodec,
    pixels: &[u8],
    layout: PixelLayout,
    stride: i32,
    width: i32,
    height: i32,
    alpha: bool,
    quality: f64,
) -> Result<(), ShimError> {
    let c_file = c_path(path)?;
    let c_codec = CString::new(codec.name()).map_err(|_| failed("codec", EINVAL))?;
    let c_format = CString::new(layout.name()).map_err(|_| failed("pixel format", EINVAL))?;
    check_len(layout, pixels, width, height, stride)?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: the strings are NUL-terminated, `pixels` holds what the layout needs (checked above), `err` has ERR_LEN bytes.
    let r = unsafe {
        raw::sq_still_write(
            c_file.as_ptr(),
            c_codec.as_ptr(),
            pixels.as_ptr(),
            c_format.as_ptr(),
            stride,
            width,
            height,
            c_int::from(alpha),
            quality,
            err.as_mut_ptr(),
            ERR_LEN as c_int,
        )
    };
    if r == 0 {
        Ok(())
    } else {
        let _ = std::fs::remove_file(path);
        Err(error(&format!("still {name}"), r, &err))
    }
}
