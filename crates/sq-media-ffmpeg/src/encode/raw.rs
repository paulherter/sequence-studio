//! Raw declarations of the encode half of `vendor/csqffmpeg.h`. Without FFmpeg (`sq_ffmpeg` off) the same names exist
//! as stubs that fail with `ENOSYS`, so no handle ever reaches the other functions.
#![allow(unsafe_code)]

use std::ffi::{c_char, c_int};

/// `SQFFEncodeConfig`, field for field.
#[repr(C)]
pub struct Config {
    pub path: *const c_char,
    pub hevc: c_int,
    pub hardware: c_int,
    pub width: c_int,
    pub height: c_int,
    pub fps_num: c_int,
    pub fps_den: c_int,
    pub bitrate: i64,
    pub gop: c_int,
    pub b_frames: c_int,
    pub ten_bit: c_int,
    pub prores: c_int,
    pub pcm_bits: c_int,
    pub audio_rate: c_int,
    pub audio_channels: c_int,
    pub audio_bitrate: i64,
    pub no_video: c_int,
    pub flac: c_int,
    pub gif: c_int,
    pub gif_final_delay: c_int,
    pub quality: f64,
    pub max_bitrate: i64,
    pub cbr: c_int,
    pub speed: c_int,
    pub color_primaries: c_int,
    pub color_trc: c_int,
    pub color_space: c_int,
    pub rotation: c_int,
    pub title: *const c_char,
    pub comment: *const c_char,
    pub creation_time: *const c_char,
    pub mdcv: *const u8,
    pub cll: *const u8,
    pub encoders: *const c_char,
    pub encoder_options: *const c_char,
    pub hardware_encoders: c_int,
    pub extra_audio_count: c_int,
    pub extra_audio_rate: [c_int; 7],
    pub extra_audio_channels: [c_int; 7],
    pub h264_profile: c_int,
}

/// Opaque C++ encoder.
pub enum Encoder {}

#[cfg(sq_ffmpeg)]
unsafe extern "C" {
    pub fn sq_enc_open(cfg: *const Config, out: *mut *mut Encoder, err: *mut c_char, err_len: c_int) -> c_int;
    pub fn sq_enc_video_name(e: *const Encoder) -> *const c_char;
    pub fn sq_enc_video_facts(e: *const Encoder, bit_depth: *mut c_int, reordered: *mut c_int);
    pub fn sq_enc_drain_video(e: *mut Encoder) -> c_int;
    pub fn sq_enc_video(e: *mut Encoder, pixels: *const u8, format: *const c_char, stride: c_int, index: i64) -> c_int;
    pub fn sq_enc_audio_track(e: *mut Encoder, track: c_int, interleaved: *const f32, frames: c_int) -> c_int;
    pub fn sq_enc_finish(e: *mut Encoder, err: *mut c_char, err_len: c_int) -> c_int;
    pub fn sq_enc_abort(e: *mut Encoder);
    #[allow(clippy::too_many_arguments)]
    pub fn sq_still_write(
        path: *const c_char,
        codec: *const c_char,
        pixels: *const u8,
        format: *const c_char,
        stride: c_int,
        width: c_int,
        height: c_int,
        alpha: c_int,
        quality: f64,
        err: *mut c_char,
        err_len: c_int,
    ) -> c_int;
}

#[cfg(not(sq_ffmpeg))]
mod stub {
    use super::*;
    const ENOSYS: c_int = -38;

    pub unsafe fn sq_enc_open(_: *const Config, _: *mut *mut Encoder, _: *mut c_char, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_enc_video_name(_: *const Encoder) -> *const c_char {
        std::ptr::null()
    }
    pub unsafe fn sq_enc_video_facts(_: *const Encoder, bit_depth: *mut c_int, reordered: *mut c_int) {
        // SAFETY: callers pass valid pointers; without FFmpeg no encoder exists, so the values are never read.
        unsafe {
            bit_depth.write(0);
            reordered.write(0);
        }
    }
    pub unsafe fn sq_enc_drain_video(_: *mut Encoder) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_enc_video(_: *mut Encoder, _: *const u8, _: *const c_char, _: c_int, _: i64) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_enc_audio_track(_: *mut Encoder, _: c_int, _: *const f32, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_enc_finish(_: *mut Encoder, _: *mut c_char, _: c_int) -> c_int {
        ENOSYS
    }
    pub unsafe fn sq_enc_abort(_: *mut Encoder) {}
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn sq_still_write(
        _: *const c_char,
        _: *const c_char,
        _: *const u8,
        _: *const c_char,
        _: c_int,
        _: c_int,
        _: c_int,
        _: c_int,
        _: f64,
        _: *mut c_char,
        _: c_int,
    ) -> c_int {
        ENOSYS
    }
}

#[cfg(not(sq_ffmpeg))]
pub use stub::*;
