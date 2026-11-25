//! Raw declarations of `vendor/csqffmpeg.h` (decode side). Without FFmpeg (`sq_ffmpeg` off) the same names exist as
//! stubs: opening fails with `ENOSYS`, so no handle ever reaches the other functions.

use std::ffi::{c_char, c_int, c_void};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Packet {
    pub pts: i64,
    pub dts: i64,
    pub duration: i64,
    pub pos: i64,
    pub size: i32,
    pub key: i32,
    pub discard: i32,
    pub reserved: i32,
}

#[repr(C)]
pub struct VideoInfo {
    pub width: c_int,
    pub height: c_int,
    pub tb_num: c_int,
    pub tb_den: c_int,
    pub fr_num: c_int,
    pub fr_den: c_int,
    pub rotation: c_int,
    pub bit_depth: c_int,
    pub codec: [c_char; 32],
    pub pix_fmt: [c_char; 32],
    pub color_primaries: c_int,
    pub color_transfer: c_int,
    pub color_matrix: c_int,
    pub color_range: c_int,
    pub field_order: c_int,
    pub bits_per_coded_sample: c_int,
    pub sar_num: c_int,
    pub sar_den: c_int,
    pub has_dolby_vision: c_int,
    pub dolby_vision: [u8; 5],
    pub codec_tag: u32,
}

#[repr(C)]
pub struct FrameInfo {
    pub width: c_int,
    pub height: c_int,
    pub hardware: c_int,
    pub texture: *mut c_void,
    pub texture_index: c_int,
    pub sw_format: c_int,
    pub pts: i64,
}

#[repr(C)]
pub struct Audio {
    pub samples: *mut f32,
    pub frames: i64,
    pub channels: c_int,
    pub sample_rate: c_int,
    pub source_channels: c_int,
}

#[repr(C)]
pub struct Probe {
    pub duration_us: i64,
    pub format: [c_char; 64],
    pub has_video: c_int,
    pub width: c_int,
    pub height: c_int,
    pub video_frames: i64,
    pub video_codec: [c_char; 32],
    pub has_audio: c_int,
    pub audio_rate: c_int,
    pub audio_channels: c_int,
    pub audio_codec: [c_char; 32],
}

/// Opaque C++ objects.
pub enum Demux {}
pub enum Decoder {}
pub enum AudioReader {}
pub enum Frame {}

#[cfg(sq_ffmpeg)]
unsafe extern "C" {
    pub fn sq_version_mismatch(err: *mut c_char, err_len: c_int) -> c_int;
    pub fn sq_demux_open_with(
        path: *const c_char,
        full_probe: c_int,
        out: *mut *mut Demux,
        err: *mut c_char,
        err_len: c_int,
    ) -> c_int;
    pub fn sq_seek_probe(
        path: *const c_char,
        max_packets: c_int,
        max_bytes: i64,
        codec: *mut c_char,
        codec_len: c_int,
        keys: *mut u8,
        count: *mut c_int,
        err: *mut c_char,
        err_len: c_int,
    ) -> c_int;
    pub fn sq_demux_fast_paths(d: *const Demux) -> c_int;
    pub fn sq_demux_close(d: *mut Demux);
    pub fn sq_demux_info(d: *const Demux, info: *mut VideoInfo);
    pub fn sq_demux_packet_count(d: *const Demux) -> c_int;
    pub fn sq_demux_packets(d: *const Demux) -> *const Packet;
    pub fn sq_demux_extradata(d: *const Demux, size: *mut c_int) -> *const u8;
    pub fn sq_demux_read(d: *mut Demux, ordinal: c_int, buf: *mut u8, cap: c_int) -> c_int;

    #[allow(clippy::too_many_arguments)]
    pub fn sq_dec_open(
        codec: *const c_char,
        extradata: *const u8,
        extradata_size: c_int,
        width: c_int,
        height: c_int,
        bits_per_coded_sample: c_int,
        codec_tag: u32,
        tb_num: c_int,
        tb_den: c_int,
        hardware: c_int,
        extra_hw_frames: c_int,
        sw_threads: c_int,
        out: *mut *mut Decoder,
        err: *mut c_char,
        err_len: c_int,
    ) -> c_int;
    pub fn sq_dec_close(dec: *mut Decoder);
    pub fn sq_dec_name(dec: *const Decoder) -> *const c_char;
    pub fn sq_dec_send(
        dec: *mut Decoder,
        data: *const u8,
        size: c_int,
        pts: i64,
        dts: i64,
        duration: i64,
        key: c_int,
    ) -> c_int;
    pub fn sq_dec_receive(dec: *mut Decoder, out: *mut *mut Frame) -> c_int;
    pub fn sq_dec_flush(dec: *mut Decoder);
    pub fn sq_dec_set_fast(dec: *mut Decoder, on: c_int);

    pub fn sq_frame_info(f: *const Frame, info: *mut FrameInfo);
    pub fn sq_frame_download_size(f: *const Frame) -> c_int;
    pub fn sq_frame_download(f: *const Frame, buf: *mut u8, cap: c_int) -> c_int;
    pub fn sq_frame_has_alpha(f: *const Frame) -> c_int;
    pub fn sq_frame_download_rgba(f: *const Frame, buf: *mut u8, cap: c_int) -> c_int;
    pub fn sq_frame_download_reduced_size(f: *const Frame, divisor: c_int, w: *mut c_int, h: *mut c_int) -> c_int;
    pub fn sq_frame_reduced_422(f: *const Frame) -> c_int;
    pub fn sq_frame_download_reduced(
        f: *const Frame,
        divisor: c_int,
        threads: c_int,
        buf: *mut u8,
        cap: c_int,
    ) -> c_int;
    pub fn sq_frame_free(f: *mut Frame);

    pub fn sq_audio_decode_track(
        path: *const c_char,
        rate: c_int,
        channels: c_int,
        ordinal: c_int,
        out: *mut Audio,
        err: *mut c_char,
        err_len: c_int,
    ) -> c_int;
    pub fn sq_audio_track_channels(path: *const c_char, counts: *mut c_int, cap: c_int) -> c_int;
    pub fn sq_audio_track_rates(path: *const c_char, rates: *mut c_int, cap: c_int) -> c_int;
    pub fn sq_audio_free(a: *mut Audio);
    pub fn sq_audio_reader_open(
        path: *const c_char,
        rate: c_int,
        channels: c_int,
        ordinal: c_int,
        estimated: *mut i64,
        source_channels: *mut c_int,
        err: *mut c_char,
        err_len: c_int,
    ) -> *mut AudioReader;
    pub fn sq_audio_reader_read(r: *mut AudioReader, start: i64, out: *mut f32, frames: c_int) -> c_int;
    pub fn sq_audio_reader_end(r: *const AudioReader) -> i64;
    pub fn sq_audio_reader_close(r: *mut AudioReader);
    pub fn sq_image_size(path: *const c_char, width: *mut c_int, height: *mut c_int) -> c_int;
    pub fn sq_image_decode_rgba(path: *const c_char, buf: *mut u8, cap: c_int) -> c_int;
    pub fn sq_probe(path: *const c_char, out: *mut Probe, err: *mut c_char, err_len: c_int) -> c_int;
}

#[cfg(not(sq_ffmpeg))]
mod stub {
    use super::*;
    pub const ENOSYS: c_int = -38;

    pub unsafe fn sq_version_mismatch(_: *mut c_char, _: c_int) -> c_int {
        0
    }

    pub unsafe fn sq_demux_open_with(
        _: *const c_char,
        _: c_int,
        _: *mut *mut Demux,
        _: *mut c_char,
        _: c_int,
    ) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_demux_fast_paths(_: *const Demux) -> c_int {
        0
    }
    pub unsafe fn sq_demux_close(_: *mut Demux) {}
    pub unsafe fn sq_demux_info(_: *const Demux, _: *mut VideoInfo) {}
    pub unsafe fn sq_demux_packet_count(_: *const Demux) -> c_int {
        0
    }
    pub unsafe fn sq_demux_packets(_: *const Demux) -> *const Packet {
        std::ptr::null()
    }
    pub unsafe fn sq_demux_extradata(_: *const Demux, _: *mut c_int) -> *const u8 {
        std::ptr::null()
    }
    pub unsafe fn sq_demux_read(_: *mut Demux, _: c_int, _: *mut u8, _: c_int) -> c_int {
        ENOSYS
    }
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn sq_dec_open(
        _: *const c_char,
        _: *const u8,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: u32,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: *mut *mut Decoder,
        _: *mut c_char,
        _: c_int,
    ) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_dec_close(_: *mut Decoder) {}
    pub unsafe fn sq_dec_name(_: *const Decoder) -> *const c_char {
        std::ptr::null()
    }
    pub unsafe fn sq_dec_send(_: *mut Decoder, _: *const u8, _: c_int, _: i64, _: i64, _: i64, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_dec_receive(_: *mut Decoder, _: *mut *mut Frame) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_dec_flush(_: *mut Decoder) {}
    pub unsafe fn sq_dec_set_fast(_: *mut Decoder, _: c_int) {}
    pub unsafe fn sq_frame_info(_: *const Frame, _: *mut FrameInfo) {}
    pub unsafe fn sq_frame_download_size(_: *const Frame) -> c_int {
        0
    }
    pub unsafe fn sq_frame_download(_: *const Frame, _: *mut u8, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_frame_has_alpha(_: *const Frame) -> c_int {
        0
    }
    pub unsafe fn sq_frame_download_rgba(_: *const Frame, _: *mut u8, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_frame_download_reduced_size(_: *const Frame, _: c_int, _: *mut c_int, _: *mut c_int) -> c_int {
        0
    }
    pub unsafe fn sq_frame_reduced_422(_: *const Frame) -> c_int {
        0
    }
    pub unsafe fn sq_frame_download_reduced(_: *const Frame, _: c_int, _: c_int, _: *mut u8, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_frame_free(_: *mut Frame) {}
    pub unsafe fn sq_audio_decode_track(
        _: *const c_char,
        _: c_int,
        _: c_int,
        _: c_int,
        _: *mut Audio,
        _: *mut c_char,
        _: c_int,
    ) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_audio_track_channels(_: *const c_char, _: *mut c_int, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_audio_track_rates(_: *const c_char, _: *mut c_int, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_audio_free(_: *mut Audio) {}
    pub unsafe fn sq_audio_reader_read(_: *mut AudioReader, _: i64, _: *mut f32, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_audio_reader_end(_: *const AudioReader) -> i64 {
        -1
    }
    pub unsafe fn sq_audio_reader_close(_: *mut AudioReader) {}
    pub unsafe fn sq_image_size(_: *const c_char, _: *mut c_int, _: *mut c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_image_decode_rgba(_: *const c_char, _: *mut u8, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_probe(_: *const c_char, _: *mut Probe, _: *mut c_char, _: c_int) -> c_int {
        ENOSYS
    }
}

#[cfg(not(sq_ffmpeg))]
pub use stub::*;

/// Arguments of `sq_seek_probe`, grouped so the Rust entry point takes one value (the C function keeps its flat list).
pub struct SeekProbeArgs {
    pub path: *const c_char,
    pub max_packets: c_int,
    pub max_bytes: i64,
    pub codec: *mut c_char,
    pub codec_len: c_int,
    pub keys: *mut u8,
    pub count: *mut c_int,
    pub err: *mut c_char,
    pub err_len: c_int,
}

/// Arguments of `sq_audio_reader_open`.
pub struct AudioReaderOpenArgs {
    pub path: *const c_char,
    pub rate: c_int,
    pub channels: c_int,
    pub ordinal: c_int,
    pub estimated: *mut i64,
    pub source_channels: *mut c_int,
    pub err: *mut c_char,
    pub err_len: c_int,
}

/// # Safety
/// Same contract as the C `sq_seek_probe`. Without FFmpeg it fails with `ENOSYS`.
#[cfg(sq_ffmpeg)]
pub unsafe fn seek_probe(a: SeekProbeArgs) -> c_int {
    // SAFETY: forwarded under the caller's contract.
    unsafe {
        sq_seek_probe(a.path, a.max_packets, a.max_bytes, a.codec, a.codec_len, a.keys, a.count, a.err, a.err_len)
    }
}

/// # Safety
/// Same contract as the C `sq_seek_probe`. Without FFmpeg it fails with `ENOSYS`.
#[cfg(not(sq_ffmpeg))]
pub unsafe fn seek_probe(a: SeekProbeArgs) -> c_int {
    // The stub touches nothing; reading the fields keeps them from being dead code in a build without FFmpeg.
    let _ = (a.path, a.max_packets, a.max_bytes, a.codec, a.codec_len, a.keys, a.count, a.err, a.err_len);
    stub::ENOSYS
}

/// # Safety
/// Same contract as the C `sq_audio_reader_open`. Without FFmpeg it returns null.
#[cfg(sq_ffmpeg)]
pub unsafe fn audio_reader_open(a: AudioReaderOpenArgs) -> *mut AudioReader {
    // SAFETY: forwarded under the caller's contract.
    unsafe {
        sq_audio_reader_open(a.path, a.rate, a.channels, a.ordinal, a.estimated, a.source_channels, a.err, a.err_len)
    }
}

/// # Safety
/// Same contract as the C `sq_audio_reader_open`. Without FFmpeg it returns null.
#[cfg(not(sq_ffmpeg))]
pub unsafe fn audio_reader_open(a: AudioReaderOpenArgs) -> *mut AudioReader {
    // See `seek_probe`: the stub reads the fields only to keep them live.
    let _ = (a.path, a.rate, a.channels, a.ordinal, a.estimated, a.source_channels, a.err, a.err_len);
    std::ptr::null_mut()
}
