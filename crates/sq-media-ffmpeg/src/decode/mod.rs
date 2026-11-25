//! FFmpeg demuxer, video decoder, audio source and frame storage behind sq-media's `Demuxing`, `VideoDecoding` and
//! `AudioSource`. Port of `FFmpeg*.swift` (SQMediaFFmpeg, SQMediaFFmpegCore); the C++ shim sits behind `crate::shim`.
//! Decode is software on the Mac (hardware there is the direct VideoToolbox path, a separate crate) and D3D11VA or
//! software on Windows.

mod audio_source;
mod color;
mod demuxer;
mod error;
mod frame;
mod hardware;
mod timing;
mod video_decoder;

#[cfg(test)]
mod audio_variants_tests;
#[cfg(test)]
mod oracle_tests;

pub use audio_source::{AudioStreamInfo, FFmpegAudioSource};
pub use color::{field_order_of, flagged_full_range, frame_color, matrix_tag, primaries_tag, transfer_tag};
pub use demuxer::FFmpegDemuxer;
pub use error::media_error;
pub use frame::{FFmpegFrame, MemoryFrame};
pub use hardware::{
    DEFAULT_MAX_HARDWARE_SESSIONS, DOWNLOAD_FAILURES_BEFORE_SOFTWARE, DecodePath, DownloadWatch, HardwareSessions,
    SessionGuard, acquire_hardware_session, acquire_hardware_session_for, decode_path, hardware_hold_limit,
    supports_hardware_decode,
};
pub use timing::{DecodeCursor, DecodePlan, FrameTable, PacketTiming, TimeBase};
pub use video_decoder::{DEFAULT_EXTRA_HW_FRAMES, FFmpegVideoDecoder, set_fallback_hook};
