//! Animated GIF: one palette per frame.

use super::pipeline::pump;
use super::video::writer_error;
use crate::core::{CancelToken, ExportError, FrameSource, GifPalette, GifTiming};
use sq_frame::sqframe::SQFramePixelFormat;
use sq_media_ffmpeg::decode::MemoryFrame;
use sq_media_ffmpeg::encode::{EncodeConfig, Encoder, PixelLayout};
use std::path::Path;

/// Looping GIF; frame i runs from round(i * 100 / fps) to round((i + 1) * 100 / fps) centiseconds.
pub(super) fn write(
    video: &mut dyn FrameSource,
    url: &Path,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<(), ExportError> {
    let n = video.frame_count();
    let fd = video.frame_duration();
    let delays = GifTiming::delays_centiseconds(fd, n);
    let _ = std::fs::remove_file(url);
    let mut enc: Option<Encoder> = None;
    let mut start: i64 = 0;
    pump(video, cancel, |i, frame| {
        let bgra = frame.pixel_format == SQFramePixelFormat::Bgra8;
        let m = frame
            .storage_as::<MemoryFrame>()
            .filter(|_| bgra || frame.pixel_format == SQFramePixelFormat::Rgba8)
            .ok_or_else(|| ExportError::WriterFailed(format!("GIF frame {i} is not 8-bit RGBA")))?;
        if enc.is_none() {
            enc = Some(
                Encoder::open(&EncodeConfig {
                    path: url.to_path_buf(),
                    gif: true,
                    width: frame.width as i32,
                    height: frame.height as i32,
                    fps_num: fd.timescale() as i32,
                    fps_den: fd.value().max(1) as i32,
                    gop: 1,
                    gif_final_delay: delays.last().copied().unwrap_or(1) as i32,
                    ..EncodeConfig::default()
                })
                .map_err(writer_error)?,
            );
        }
        let pal = GifPalette::quantize(
            &m.bytes,
            frame.width,
            frame.height,
            m.bytes_per_row,
            if bgra { 2 } else { 0 },
            1,
            if bgra { 0 } else { 2 },
            256,
        );
        let mut bytes = pal.indices;
        bytes.reserve(1024);
        for k in 0..256 {
            let c = pal.colors.get(k).copied().unwrap_or((0, 0, 0));
            bytes.extend_from_slice(&[c.2, c.1, c.0, 255]); // AV_PIX_FMT_PAL8 entries: native-endian 0xAARRGGBB
        }
        if let Some(e) = enc.as_mut() {
            e.video(&bytes, PixelLayout::Pal8, frame.width as i32, start).map_err(writer_error)?;
        }
        start += delays[i];
        progress((i + 1) as f64 / n as f64 * 0.98);
        Ok(())
    })?;
    enc.ok_or(ExportError::EmptySource)?.finish().map_err(writer_error)
}
