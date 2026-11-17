//! Safe wrappers over the C++ shim (`vendor/*.cpp`, built by build.rs): demuxer, video decoder, decoded frames and
//! whole-file audio decode. The only module of the crate with `unsafe` code; every block says why it holds.
//! Without an FFmpeg install the shim is a stub whose `open` calls fail (`AVAILABLE` is false).
#![allow(unsafe_code)]

mod ffi;

pub use ffi::Packet;
use sq_core_model::FieldOrder;
use sq_frame::buffer_pool::{BufferPool, PooledBytes};
use std::ffi::{CStr, CString, c_char, c_int};
use std::fmt;
use std::path::Path;
use std::ptr::{self, NonNull};

/// FFmpeg was found at build time and the shim is linked.
pub const AVAILABLE: bool = cfg!(sq_ffmpeg);

/// `AVERROR(EINVAL)`.
const EINVAL: i32 = -22;
/// FFmpeg's `AVERROR_DECODER_NOT_FOUND` (`FFERRTAG(0xF8,'D','E','C')`).
pub const DECODER_NOT_FOUND: i32 = -1_128_613_112;

/// A failed shim call: FFmpeg's negative code and the text ("open: No such file or directory").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShimError {
    pub code: i32,
    pub message: String,
}

impl ShimError {
    fn new(what: &str, code: i32, err: &[c_char]) -> ShimError {
        let text = c_string(err);
        let message = if text.is_empty() { format!("{what} failed ({code})") } else { format!("{what}: {text}") };
        ShimError { code, message }
    }

    fn failed(what: &str, code: i32) -> ShimError {
        ShimError { code, message: format!("{what} failed ({code})") }
    }
}

impl fmt::Display for ShimError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ShimError {}

const ERR_LEN: usize = 256;

/// Whether the FFmpeg libraries loaded at run time have the major versions this build was made against: `None` when
/// they do, or when no FFmpeg is linked; else what differs (`avcodec 62 built against, 61 loaded`).
pub fn version_mismatch() -> Option<String> {
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: `err` is a writable buffer of `ERR_LEN` bytes; the shim writes at most that many, NUL-terminated.
    let rc = unsafe { ffi::sq_version_mismatch(err.as_mut_ptr(), ERR_LEN as c_int) };
    (rc != 0).then(|| c_string(&err))
}

fn c_path(path: &Path) -> Result<CString, ShimError> {
    let text = path.to_str().ok_or_else(|| ShimError::failed("path", EINVAL))?;
    CString::new(text).map_err(|_| ShimError::failed("path", EINVAL))
}

fn c_string(text: &[c_char]) -> String {
    let bytes: Vec<u8> = text.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The facts of the best video stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoInfo {
    pub width: i32,
    pub height: i32,
    /// Stream time base.
    pub tb_num: i32,
    pub tb_den: i32,
    /// Average frame rate; 0/0 unknown.
    pub fr_num: i32,
    pub fr_den: i32,
    /// Clockwise degrees.
    pub rotation: i32,
    pub bit_depth: i32,
    /// FFmpeg codec name ("h264", "hevc", ...).
    pub codec: String,
    /// FFmpeg pixel format name ("yuv420p", ...).
    pub pix_fmt: String,
    /// AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace / AVColorRange values.
    pub color_primaries: i32,
    pub color_transfer: i32,
    pub color_matrix: i32,
    pub color_range: i32,
    /// AVFieldOrder (0 unknown, 1 progressive, 2 TT, 3 BB, 4 TB, 5 BT).
    pub field_order: i32,
    /// QuickTime Animation and other RLE codecs need it to pick their pixel format.
    pub bits_per_coded_sample: i32,
    /// The container's codec FourCC (ProRes tells its profile and bit depth by it).
    pub codec_tag: u32,
    /// Sample aspect ratio the file tags (0 = untagged).
    pub sar_num: i32,
    pub sar_den: i32,
    /// The Dolby Vision configuration record (`dvcC` / `dvvC` / `dvwC` payload layout), when the stream carries one.
    pub dolby_vision: Option<[u8; 5]>,
}

/// FFmpeg's `AVERROR_STREAM_NOT_FOUND`: the file has no stream of the wanted kind.
pub const STREAM_NOT_FOUND: i32 = -1_381_258_232;

/// How the first video packets of a file seek: its codec and which packets are sync samples.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeekProbe {
    /// FFmpeg codec name ("h264", "prores", ...).
    pub codec: String,
    /// Sync flag of each packet read, in decode order.
    pub keys: Vec<bool>,
}

/// Reads the codec and the sync flags of up to `max_packets` video packets without indexing or decoding the file: a plain
/// mov/mp4 answers from its header alone, any other container reads about `max_bytes` of payload at most (never fewer
/// than 16 packets).
pub fn seek_probe(path: &Path, max_packets: usize, max_bytes: i64) -> Result<SeekProbe, ShimError> {
    let c = c_path(path)?;
    let cap = c_int::try_from(max_packets).map_err(|_| ShimError::failed("seek probe", EINVAL))?;
    let mut keys = vec![0u8; max_packets];
    let (mut codec, mut err) = ([0 as c_char; 32], [0 as c_char; ERR_LEN]);
    let mut count: c_int = 0;
    // SAFETY: `c` is NUL-terminated; `codec` and `err` are valid for their stated lengths, `keys` holds `cap` bytes and the
    // shim writes at most that many; `count` is valid for the call.
    let r = unsafe {
        ffi::sq_seek_probe(
            c.as_ptr(),
            cap,
            max_bytes,
            codec.as_mut_ptr(),
            codec.len() as c_int,
            keys.as_mut_ptr(),
            &mut count,
            err.as_mut_ptr(),
            ERR_LEN as c_int,
        )
    };
    if r != 0 {
        return Err(ShimError::new("seek probe", r, &err));
    }
    keys.truncate(usize::try_from(count).unwrap_or(0).min(max_packets));
    Ok(SeekProbe { codec: c_string(&codec), keys: keys.into_iter().map(|k| k != 0).collect() })
}

/// A file opened for demuxing: every packet of the best video stream indexed, samples read by position.
pub struct Demux {
    raw: NonNull<ffi::Demux>,
}

// SAFETY: after open the packet table is never written; `sq_demux_read` takes the C++ object's mutex.
unsafe impl Send for Demux {}
// SAFETY: see above.
unsafe impl Sync for Demux {}

impl Demux {
    /// Opens `path` and indexes the best video stream (reads the whole file once).
    pub fn open(path: &Path) -> Result<Demux, ShimError> {
        Demux::open_probing(path, false)
    }

    /// `open` with FFmpeg's complete stream probe, which decodes a picture; the reference the quick open is tested against.
    pub fn open_full_probe(path: &Path) -> Result<Demux, ShimError> {
        Demux::open_probing(path, true)
    }

    fn open_probing(path: &Path, full_probe: bool) -> Result<Demux, ShimError> {
        let c = c_path(path)?;
        let mut raw = ptr::null_mut();
        let mut err = [0 as c_char; ERR_LEN];
        // SAFETY: `c` is NUL-terminated, `raw` and `err` are valid for the call, `err` has ERR_LEN bytes.
        let r = unsafe {
            ffi::sq_demux_open_with(c.as_ptr(), c_int::from(full_probe), &mut raw, err.as_mut_ptr(), ERR_LEN as c_int)
        };
        match NonNull::new(raw) {
            Some(raw) if r == 0 => Ok(Demux { raw }),
            _ => {
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                Err(ShimError::new(&format!("open {name}"), if r == 0 { -1 } else { r }, &err))
            }
        }
    }

    /// True when the packet index came from the container's index without reading the payload (a plain mov/mp4).
    pub fn index_without_payload(&self) -> bool {
        self.fast_paths() & 1 != 0
    }

    /// True when the stream facts came from the H.264 SPS and no picture was decoded to learn them.
    pub fn facts_from_sps(&self) -> bool {
        self.fast_paths() & 2 != 0
    }

    fn fast_paths(&self) -> c_int {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_demux_fast_paths(self.raw.as_ptr()) }
    }

    /// Stream facts.
    pub fn info(&self) -> VideoInfo {
        let mut raw = std::mem::MaybeUninit::<ffi::VideoInfo>::zeroed();
        // SAFETY: the handle is live; the shim fills a zeroed (valid for every field) struct.
        let i = unsafe {
            ffi::sq_demux_info(self.raw.as_ptr(), raw.as_mut_ptr());
            raw.assume_init()
        };
        VideoInfo {
            width: i.width,
            height: i.height,
            tb_num: i.tb_num,
            tb_den: i.tb_den,
            fr_num: i.fr_num,
            fr_den: i.fr_den,
            rotation: i.rotation,
            bit_depth: i.bit_depth,
            codec: c_string(&i.codec),
            pix_fmt: c_string(&i.pix_fmt),
            color_primaries: i.color_primaries,
            color_transfer: i.color_transfer,
            color_matrix: i.color_matrix,
            color_range: i.color_range,
            field_order: i.field_order,
            bits_per_coded_sample: i.bits_per_coded_sample,
            codec_tag: i.codec_tag,
            sar_num: i.sar_num,
            sar_den: i.sar_den,
            dolby_vision: (i.has_dolby_vision != 0).then_some(i.dolby_vision),
        }
    }

    /// Every packet in decode order.
    pub fn packets(&self) -> &[Packet] {
        // SAFETY: the table lives as long as the handle and is never modified after open; count matches the table.
        unsafe {
            let n = usize::try_from(ffi::sq_demux_packet_count(self.raw.as_ptr())).unwrap_or(0);
            let p = ffi::sq_demux_packets(self.raw.as_ptr());
            if p.is_null() { &[] } else { std::slice::from_raw_parts(p, n) }
        }
    }

    /// Codec configuration record (avcC / hvcC); empty when the stream has none.
    pub fn extradata(&self) -> Vec<u8> {
        let mut size: c_int = 0;
        // SAFETY: the returned pointer is valid for `size` bytes while the handle lives; it is copied at once.
        unsafe {
            let p = ffi::sq_demux_extradata(self.raw.as_ptr(), &mut size);
            if p.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(p, usize::try_from(size).unwrap_or(0)).to_vec()
            }
        }
    }

    /// The bytes of packet `ordinal` (decode order). Thread-safe.
    pub fn read(&self, ordinal: usize) -> Result<Vec<u8>, ShimError> {
        let size = self.packets().get(ordinal).map_or(0, |p| usize::try_from(p.size).unwrap_or(0));
        let mut data = vec![0u8; size];
        let o = c_int::try_from(ordinal).map_err(|_| ShimError::failed("read sample", EINVAL))?;
        // SAFETY: `data` holds `size` bytes and the shim copies at most `cap` = `size` bytes into it.
        let r = unsafe { ffi::sq_demux_read(self.raw.as_ptr(), o, data.as_mut_ptr(), size as c_int) };
        if r == 0 { Ok(data) } else { Err(ShimError::failed(&format!("read sample {ordinal}"), r)) }
    }
}

impl Drop for Demux {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_demux_open` and is closed once.
        unsafe { ffi::sq_demux_close(self.raw.as_ptr()) }
    }
}

/// What a decoder is opened with.
pub struct DecoderConfig<'a> {
    pub codec: &'a str,
    pub extradata: &'a [u8],
    pub width: i32,
    pub height: i32,
    pub bits_per_coded_sample: i32,
    /// The container's codec FourCC; 0 = none.
    pub codec_tag: u32,
    pub tb_num: i32,
    pub tb_den: i32,
    /// D3D11VA decode (frames stay GPU textures); fails when the GPU cannot decode the stream.
    pub hardware: bool,
    /// Pool textures beyond the decoder's own references (hardware only).
    pub extra_hw_frames: i32,
}

/// One compressed picture to send, timing in stream ticks.
pub struct InputPacket<'a> {
    pub data: &'a [u8],
    pub pts: i64,
    pub dts: i64,
    pub duration: i64,
    pub key: bool,
}

/// Result of sending input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sent {
    Accepted,
    /// The decoder is full: receive frames, then send again.
    Full,
}

/// Result of asking for output.
pub enum Received {
    Frame(Frame),
    NeedsInput,
    Ended,
}

/// One video decoder (software, or D3D11VA).
pub struct Decoder {
    raw: NonNull<ffi::Decoder>,
}

// SAFETY: a decoder is used by one thread at a time (all methods take &mut self or run under the owner's lock).
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn open(cfg: &DecoderConfig<'_>) -> Result<Decoder, ShimError> {
        let codec = CString::new(cfg.codec).map_err(|_| ShimError::failed("codec name", EINVAL))?;
        let extra_len = c_int::try_from(cfg.extradata.len()).map_err(|_| ShimError::failed("extradata", EINVAL))?;
        let mut raw = ptr::null_mut();
        let mut err = [0 as c_char; ERR_LEN];
        // SAFETY: all pointers are valid for the call; the shim copies the extradata and keeps no borrowed pointer.
        let r = unsafe {
            ffi::sq_dec_open(
                codec.as_ptr(),
                cfg.extradata.as_ptr(),
                extra_len,
                cfg.width,
                cfg.height,
                cfg.bits_per_coded_sample,
                cfg.codec_tag,
                cfg.tb_num,
                cfg.tb_den,
                c_int::from(cfg.hardware),
                cfg.extra_hw_frames,
                &mut raw,
                err.as_mut_ptr(),
                ERR_LEN as c_int,
            )
        };
        match NonNull::new(raw) {
            Some(raw) if r == 0 => Ok(Decoder { raw }),
            _ => Err(ShimError::new("decoder", if r == 0 { -1 } else { r }, &err)),
        }
    }

    /// "h264 (software)" / "h264 (d3d11va)".
    pub fn name(&self) -> String {
        // SAFETY: the name is a NUL-terminated array inside the live decoder object.
        unsafe {
            let p = ffi::sq_dec_name(self.raw.as_ptr());
            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
        }
    }

    pub fn send(&mut self, p: &InputPacket<'_>) -> Result<Sent, ShimError> {
        let size = c_int::try_from(p.data.len()).map_err(|_| ShimError::failed("send sample", EINVAL))?;
        // SAFETY: `data` is valid for `size` bytes; the shim copies it into its own packet.
        let r = unsafe {
            ffi::sq_dec_send(self.raw.as_ptr(), p.data.as_ptr(), size, p.pts, p.dts, p.duration, c_int::from(p.key))
        };
        Self::sent(r, "send sample")
    }

    /// Signals the end of the stream (the decoder then drains its buffered pictures).
    pub fn send_end(&mut self) -> Result<Sent, ShimError> {
        // SAFETY: a null packet is the shim's end-of-stream marker.
        let r = unsafe { ffi::sq_dec_send(self.raw.as_ptr(), ptr::null(), 0, 0, 0, 0, 0) };
        Self::sent(r, "drain")
    }

    fn sent(r: c_int, what: &str) -> Result<Sent, ShimError> {
        match r {
            0 => Ok(Sent::Accepted),
            1 => Ok(Sent::Full),
            _ => Err(ShimError::failed(what, r)),
        }
    }

    pub fn receive(&mut self) -> Result<Received, ShimError> {
        let mut out = ptr::null_mut();
        // SAFETY: `out` is valid for the call; on 0 it receives a frame we then own.
        let r = unsafe { ffi::sq_dec_receive(self.raw.as_ptr(), &mut out) };
        match (r, NonNull::new(out)) {
            (0, Some(raw)) => Ok(Received::Frame(Frame::adopt(raw))),
            (1, _) => Ok(Received::NeedsInput),
            (2, _) => Ok(Received::Ended),
            _ => Err(ShimError::failed("decode", if r == 0 { -1 } else { r })),
        }
    }

    /// Drops buffered pictures (before a seek).
    pub fn flush(&mut self) {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_dec_flush(self.raw.as_ptr()) }
    }

    /// Preview decode for software decoders: no loop filter (faster, not exact). Flush after turning it off.
    pub fn set_fast(&mut self, on: bool) {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_dec_set_fast(self.raw.as_ptr(), c_int::from(on)) }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_dec_open` and is closed once. Frames hold their own references.
        unsafe { ffi::sq_dec_close(self.raw.as_ptr()) }
    }
}

/// A reduced download: planes packed in the NV12 / P010 layout at the reduced size.
pub struct Reduced {
    pub bytes: PooledBytes,
    pub width: i32,
    pub height: i32,
}

/// A reference to one decoded picture.
pub struct Frame {
    raw: NonNull<ffi::Frame>,
    pub width: i32,
    pub height: i32,
    pub hardware: bool,
    /// Array slice of the D3D11 texture (hardware frames).
    pub texture_index: i32,
    /// AVPixelFormat of the pixels (NV12, P010, YUV420P...).
    pub sw_format: i32,
    /// Best-effort pts in stream ticks.
    pub pts: i64,
    texture: usize,
    /// Field order this picture is deinterlaced with on download (`None`: as stored).
    deinterlace: Option<FieldOrder>,
}

// SAFETY: the AVFrame behind the handle is immutable after it left the decoder; downloads only read it.
unsafe impl Send for Frame {}
// SAFETY: see above.
unsafe impl Sync for Frame {}

impl Frame {
    fn adopt(raw: NonNull<ffi::Frame>) -> Frame {
        let mut info = std::mem::MaybeUninit::<ffi::FrameInfo>::zeroed();
        // SAFETY: the handle is live; the shim fills a zeroed struct (null texture pointer is valid).
        let i = unsafe {
            ffi::sq_frame_info(raw.as_ptr(), info.as_mut_ptr());
            info.assume_init()
        };
        Frame {
            raw,
            width: i.width,
            height: i.height,
            hardware: i.hardware != 0,
            texture_index: i.texture_index,
            sw_format: i.sw_format,
            pts: i.pts,
            texture: i.texture as usize,
            deinterlace: None,
        }
    }

    /// `ID3D11Texture2D*` of a hardware frame (0 for software frames); valid while this frame lives.
    pub fn d3d11_texture(&self) -> usize {
        self.texture
    }

    /// Pixels in NV12 (8 bit) or P010 (deeper) layout, planes packed. Blocking (a GPU copy for hardware frames).
    pub fn download(&self) -> Result<Vec<u8>, ShimError> {
        self.download_pooled().map(PooledBytes::into_vec)
    }

    /// [`Frame::download`] into a buffer of the shared pool: the picture's owner returns it by dropping it.
    pub fn download_pooled(&self) -> Result<PooledBytes, ShimError> {
        let bytes = self.download_stored()?;
        let Some(order) = self.deinterlace else { return Ok(bytes) };
        let (w, h) = (usize::try_from(self.width).unwrap_or(0), usize::try_from(self.height).unwrap_or(0));
        let wide = bytes.len() >= w * h * 3;
        let stride = if wide { w * 2 } else { w };
        // An odd width has a wider chroma row than luma row in the packed layout: left as stored.
        if w % 2 != 0 {
            return Ok(bytes);
        }
        Ok(sq_media::deinterlacer::deinterlace_biplanar_420(&bytes, w, h, stride, wide, order)
            .map_or(bytes, PooledBytes::from))
    }

    /// The deinterlaced picture of this frame from now on (`download`; the reduced path steps aside).
    pub fn set_deinterlace(&mut self, order: Option<FieldOrder>) {
        self.deinterlace = order;
    }

    fn download_stored(&self) -> Result<PooledBytes, ShimError> {
        // SAFETY: handle live.
        let size = unsafe { ffi::sq_frame_download_size(self.raw.as_ptr()) };
        let len = usize::try_from(size).ok().filter(|n| *n > 0).ok_or_else(|| ShimError::failed("frame size", size))?;
        let mut out = BufferPool::shared().take(len);
        // SAFETY: `out` holds `size` bytes, passed as the capacity.
        let r = unsafe { ffi::sq_frame_download(self.raw.as_ptr(), out.as_mut_ptr(), size) };
        if r == 0 { Ok(out) } else { Err(ShimError::failed("frame download", r)) }
    }

    /// The decoded pixel format has an alpha channel: such pictures go through `download_rgba`.
    pub fn has_alpha(&self) -> bool {
        // SAFETY: handle live.
        unsafe { ffi::sq_frame_has_alpha(self.raw.as_ptr()) != 0 }
    }

    /// 8-bit RGBA, straight alpha, width * height * 4 bytes. Blocking.
    pub fn download_rgba(&self) -> Result<Vec<u8>, ShimError> {
        self.download_rgba_pooled().map(PooledBytes::into_vec)
    }

    /// [`Frame::download_rgba`] into a buffer of the shared pool.
    pub fn download_rgba_pooled(&self) -> Result<PooledBytes, ShimError> {
        let len = usize::try_from(self.width).unwrap_or(0) * usize::try_from(self.height).unwrap_or(0) * 4;
        let cap = c_int::try_from(len).map_err(|_| ShimError::failed("frame download", EINVAL))?;
        // swscale's SIMD writers may store a few bytes past the last line; the pad keeps those off the heap's bookkeeping.
        let mut out = BufferPool::shared().take(len + 64);
        // SAFETY: `out` holds `cap` bytes (plus the pad).
        let r = unsafe { ffi::sq_frame_download_rgba(self.raw.as_ptr(), out.as_mut_ptr(), cap) };
        out.truncate(len);
        if r == 0 { Ok(out) } else { Err(ShimError::failed("frame download", r)) }
    }

    /// The same layout box-reduced by `divisor` (1, 2, 4) on `threads` threads; `None` when this frame has no such path
    /// (use `download`).
    pub fn download_reduced(&self, divisor: i32, threads: i32) -> Result<Option<Reduced>, ShimError> {
        if self.deinterlace.is_some() {
            return Ok(None); // the fields need every line: full size, then the caller reduces
        }
        let (mut w, mut h) = (0, 0);
        // SAFETY: handle live, `w` and `h` valid for writes.
        let size = unsafe { ffi::sq_frame_download_reduced_size(self.raw.as_ptr(), divisor, &mut w, &mut h) };
        let Some(len) = usize::try_from(size).ok().filter(|n| *n > 0) else { return Ok(None) };
        let mut out = BufferPool::shared().take(len);
        // SAFETY: `out` holds `size` bytes, passed as the capacity.
        let r = unsafe { ffi::sq_frame_download_reduced(self.raw.as_ptr(), divisor, threads, out.as_mut_ptr(), size) };
        match r {
            0 => Ok(Some(Reduced { bytes: out, width: w, height: h })),
            1 => Ok(None),
            _ => Err(ShimError::failed("frame download", r)),
        }
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        // SAFETY: the frame was handed to us by `sq_dec_receive` and is freed once.
        unsafe { ffi::sq_frame_free(self.raw.as_ptr()) }
    }
}

/// A whole audio stream decoded to interleaved float.
pub struct AudioPcm {
    /// `channels` values per frame.
    pub samples: Vec<f32>,
    pub frames: i64,
    pub channels: i32,
    /// Channel count of the file itself.
    pub source_channels: i32,
}

/// Decodes the best audio stream of `path`, resampled to `rate` and `channels` (1 or 2).
pub fn decode_audio(path: &Path, rate: i32, channels: i32) -> Result<AudioPcm, ShimError> {
    decode_audio_track(path, rate, channels, None)
}

/// The channels of every audio track of `path` in file order (empty without sound).
pub fn audio_track_channels(path: &Path) -> Result<Vec<i64>, ShimError> {
    let c = c_path(path)?;
    let mut counts = [0 as c_int; 64];
    // SAFETY: `counts` holds the 64 entries passed as the capacity.
    let n = unsafe { ffi::sq_audio_track_channels(c.as_ptr(), counts.as_mut_ptr(), 64) };
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let n = usize::try_from(n).map_err(|_| ShimError::failed(&format!("audio tracks of {name}"), n))?;
    Ok(counts[..n.min(64)].iter().map(|c| i64::from(*c)).collect())
}

/// The sample rate of every audio track of `path` in file order (the order of `audio_track_channels`).
pub fn audio_track_rates(path: &Path) -> Result<Vec<i32>, ShimError> {
    let c = c_path(path)?;
    let mut rates = [0 as c_int; 64];
    // SAFETY: `rates` holds the 64 entries passed as the capacity.
    let n = unsafe { ffi::sq_audio_track_rates(c.as_ptr(), rates.as_mut_ptr(), 64) };
    let n = usize::try_from(n).map_err(|_| ShimError::failed("audio track rates", n))?;
    Ok(rates[..n.min(64)].to_vec())
}

/// Like `decode_audio` for audio track `ordinal` (0-based among the audio tracks; `None` = the best one).
pub fn decode_audio_track(
    path: &Path,
    rate: i32,
    channels: i32,
    ordinal: Option<usize>,
) -> Result<AudioPcm, ShimError> {
    let c = c_path(path)?;
    let ordinal = ordinal.map_or(-1, |o| c_int::try_from(o).unwrap_or(-1));
    let mut a = ffi::Audio { samples: ptr::null_mut(), frames: 0, channels: 0, sample_rate: 0, source_channels: 0 };
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: valid pointers; on success `a.samples` points to `frames * channels` floats we copy and then free.
    unsafe {
        let r =
            ffi::sq_audio_decode_track(c.as_ptr(), rate, channels, ordinal, &mut a, err.as_mut_ptr(), ERR_LEN as c_int);
        if r != 0 {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            return Err(ShimError::new(&format!("audio {name}"), r, &err));
        }
        let n = usize::try_from(a.frames).unwrap_or(0) * usize::try_from(a.channels).unwrap_or(0);
        let samples = if a.samples.is_null() { Vec::new() } else { std::slice::from_raw_parts(a.samples, n).to_vec() };
        ffi::sq_audio_free(&mut a);
        Ok(AudioPcm { samples, frames: a.frames, channels: a.channels, source_channels: a.source_channels })
    }
}

/// What the container says about the audio stream and length, read without decoding.
pub struct AudioProbe {
    /// Container duration in microseconds; `None` = unknown.
    pub duration_us: Option<i64>,
    /// Rate, channels and codec of the best audio stream; `None` = no sound.
    pub audio: Option<(i32, i32, String)>,
}

/// Opens `path` and reads its stream headers only.
pub fn probe_audio(path: &Path) -> Result<AudioProbe, ShimError> {
    let c = c_path(path)?;
    // SAFETY: all-zero is a valid `Probe` (integers and char arrays); `sq_probe` zeroes it again anyway.
    let mut p: ffi::Probe = unsafe { std::mem::zeroed() };
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: valid pointers for the call; the struct holds no pointers.
    let r = unsafe { ffi::sq_probe(c.as_ptr(), &mut p, err.as_mut_ptr(), ERR_LEN as c_int) };
    if r != 0 {
        return Err(ShimError::new("probe", r, &err));
    }
    Ok(AudioProbe {
        duration_us: (p.duration_us >= 0).then_some(p.duration_us),
        audio: (p.has_audio != 0).then(|| (p.audio_rate, p.audio_channels, c_string(&p.audio_codec))),
    })
}

/// A streaming audio reader: decodes on demand and keeps nothing but what the C++ side needs to continue.
pub struct AudioReader {
    raw: ptr::NonNull<ffi::AudioReader>,
    channels: usize,
    /// Frames from the container's duration; -1 = unknown.
    pub estimated_frames: i64,
    /// Channel count of the file itself.
    pub source_channels: i32,
}

// SAFETY: the C++ reader is used from one thread at a time (callers hold a mutex around every call).
unsafe impl Send for AudioReader {}

impl AudioReader {
    /// Opens audio track `ordinal` (`None` = the best one) as `channels` floats at `rate` (any count: the layout is the
    /// default one for it).
    pub fn open(path: &Path, rate: i32, channels: i32, ordinal: Option<usize>) -> Result<AudioReader, ShimError> {
        let c = c_path(path)?;
        let ordinal = ordinal.map_or(-1, |o| c_int::try_from(o).unwrap_or(-1));
        let (mut estimated, mut source) = (-1i64, 0 as c_int);
        let mut err = [0 as c_char; ERR_LEN];
        // SAFETY: valid pointers for the call; the handle is owned by the result and freed in `Drop`.
        let raw = unsafe {
            ffi::sq_audio_reader_open(
                c.as_ptr(),
                rate,
                channels,
                ordinal,
                &mut estimated,
                &mut source,
                err.as_mut_ptr(),
                ERR_LEN as c_int,
            )
        };
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let raw = ptr::NonNull::new(raw).ok_or_else(|| ShimError::new(&format!("audio {name}"), -1, &err))?;
        Ok(AudioReader {
            raw,
            channels: usize::try_from(channels).unwrap_or(1),
            estimated_frames: estimated,
            source_channels: source,
        })
    }

    /// Fills `out` (interleaved, a multiple of `channels` long) with frames from `start`; returns the frames written.
    pub fn read(&mut self, start: i64, out: &mut [f32]) -> Result<usize, ShimError> {
        let frames = c_int::try_from(out.len() / self.channels).map_err(|_| ShimError::failed("audio read", EINVAL))?;
        // SAFETY: `out` holds `frames * channels` floats; the handle is live.
        let n = unsafe { ffi::sq_audio_reader_read(self.raw.as_ptr(), start, out.as_mut_ptr(), frames) };
        usize::try_from(n).map_err(|_| ShimError::failed("audio read", n))
    }

    /// The length in frames once the end of the stream was reached.
    pub fn end(&self) -> Option<i64> {
        // SAFETY: the handle is live.
        let n = unsafe { ffi::sq_audio_reader_end(self.raw.as_ptr()) };
        (n >= 0).then_some(n)
    }
}

impl Drop for AudioReader {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_audio_reader_open` and is closed once.
        unsafe { ffi::sq_audio_reader_close(self.raw.as_ptr()) }
    }
}

/// The picture size of a still image file, read without decoding.
pub fn image_size(path: &Path) -> Result<(usize, usize), ShimError> {
    let c = c_path(path)?;
    let (mut w, mut h) = (0 as c_int, 0 as c_int);
    // SAFETY: valid pointers for the call.
    let r = unsafe { ffi::sq_image_size(c.as_ptr(), &mut w, &mut h) };
    if r != 0 || w <= 0 || h <= 0 {
        return Err(ShimError::failed("image size", if r != 0 { r } else { EINVAL }));
    }
    Ok((w as usize, h as usize))
}

/// The first picture of a still image file as straight 8-bit RGBA at its own size.
pub fn image_rgba(path: &Path, width: usize, height: usize) -> Result<Vec<u8>, ShimError> {
    let c = c_path(path)?;
    let mut buf = vec![0u8; width * height * 4];
    let cap = c_int::try_from(buf.len()).map_err(|_| ShimError::failed("image decode", EINVAL))?;
    // SAFETY: `buf` holds `cap` bytes.
    let r = unsafe { ffi::sq_image_decode_rgba(c.as_ptr(), buf.as_mut_ptr(), cap) };
    if r != 0 {
        return Err(ShimError::failed("image decode", r));
    }
    Ok(buf)
}

#[cfg(test)]
mod version_tests {
    #[test]
    fn the_loaded_libraries_are_the_ones_the_headers_describe() {
        // Built and run against one FFmpeg install: nothing differs. With no FFmpeg linked the check is vacuous.
        assert_eq!(super::version_mismatch(), None);
    }
}
