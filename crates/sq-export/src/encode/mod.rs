//! The FFmpeg implementation of `ExportEncoding`: the export pipeline (frame source -> readback bytes -> encoder, three
//! frames in flight, cancel per frame, a partial file is deleted) over `sq_media_ffmpeg::encode`. Port of
//! `FFmpegExportEncoder` (Windows/SQMediaFFmpeg); hardware encoders first (VideoToolbox on the Mac; NVENC, AMF, Quick
//! Sync, Media Foundation on Windows; VA-API on Linux), x264 / x265, OpenH264 or Kvazaar in software, `prores_ks`, AAC or
//! integer PCM, GIF, stills.
//!
//! Read back from the written file: the loudness (`measure_output_audio`, Swift AudioDelivery's verifier). Swift reads the HDR
//! tags back only in its tests (ExportWriterTests); so does `hdr_delivery_tags_bt2020_pq_and_hlg_with_mastering_metadata`
//! (the `mdcv` / `clli` boxes and ffprobe's primaries, transfer, matrix and pixel format).
//!
//! The frame source feeds `FrameSource` (the GPU render and readback of `sq-render` sit behind it); `WinTimelineFrameSource`
//! and the D3D12 `WinRenderActor` have no counterpart here: the render thread of the design owns the compositor.

mod audio;
mod audio_file;
mod encoder;
mod gif;
mod hdr_stage;
mod pipeline;
mod pixels;
mod sequence;
mod verify;
mod video;

#[cfg(test)]
mod proof_tests;
#[cfg(test)]
mod tests;

pub use encoder::FfmpegExportEncoder;
pub use pipeline::IN_FLIGHT;
pub use verify::measure_output_audio;
