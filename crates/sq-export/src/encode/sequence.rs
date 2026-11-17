//! Image sequences: one numbered still per frame.

use super::pipeline::pump;
use super::video::writer_error;
use crate::core::{CancelToken, ExportError, FrameSource, FrameStillFormat, FrameStillPixels, ImageSequenceNaming};
use sq_frame::sqframe::SQFramePixelFormat;
use sq_media_ffmpeg::decode::MemoryFrame;
use sq_media_ffmpeg::encode::{PixelLayout, StillCodec, write_still};
use std::path::{Path, PathBuf};

/// `folder` (created; its name is the file name stem) gets one numbered still per frame. Returns the files.
pub(super) fn write(
    video: &mut dyn FrameSource,
    format: FrameStillFormat,
    folder: &Path,
    start_number: i64,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<Vec<PathBuf>, ExportError> {
    std::fs::create_dir_all(folder).map_err(|e| ExportError::from_io(&e))?;
    let total = video.frame_count();
    let stem = folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let names = ImageSequenceNaming::file_names(&stem, start_number, total as i64, format.file_extension());
    let mut files = Vec::with_capacity(total);
    pump(video, cancel, |i, frame| {
        let m = frame
            .storage_as::<MemoryFrame>()
            .filter(|_| frame.pixel_format == SQFramePixelFormat::Rgba16f)
            .ok_or_else(|| ExportError::WriterFailed(format!("image sequence frame {i} is not RGBA half")))?;
        let file = folder.join(&names[i]);
        write_one(&m.bytes, frame.width, frame.height, m.bytes_per_row, format, &file)?;
        files.push(file);
        progress((i + 1) as f64 / total as f64);
        Ok(())
    })?;
    Ok(files)
}

/// One still from rgba halves (premultiplied linear) in `format`.
pub(super) fn write_one(
    half: &[u8],
    w: usize,
    h: usize,
    bytes_per_row: usize,
    format: FrameStillFormat,
    file: &Path,
) -> Result<(), ExportError> {
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let img = FrameStillPixels::image(half, w, h, bytes_per_row, format)
        .ok_or_else(|| ExportError::WriterFailed(format!("still {name}: the frame is too small")))?;
    let (codec, layout, bytes, stride) = match format {
        FrameStillFormat::Png | FrameStillFormat::PngAlpha => (StillCodec::Png, PixelLayout::Rgba, img.bytes, w * 4),
        FrameStillFormat::Jpeg => (StillCodec::Mjpeg, PixelLayout::Rgba, img.bytes, w * 4),
        FrameStillFormat::Tiff16 | FrameStillFormat::Tiff16Alpha => {
            (StillCodec::Tiff, PixelLayout::Rgba64le, img.bytes, w * 8)
        }
        FrameStillFormat::Exr => {
            // The EXR encoder takes planar G, B, R, A floats.
            let n = w * h;
            let mut planes = vec![0u8; n * 16];
            for p in 0..n {
                for (plane, k) in [(0, 1), (1, 2), (2, 0), (3, 3)] {
                    let o = (p * 4 + k) * 2;
                    let v = FrameStillPixels::float(u16::from_le_bytes([img.bytes[o], img.bytes[o + 1]]));
                    planes[(plane * n + p) * 4..][..4].copy_from_slice(&v.to_le_bytes());
                }
            }
            (StillCodec::Exr, PixelLayout::Gbrapf32le, planes, w * 4)
        }
    };
    let _ = std::fs::remove_file(file);
    write_still(file, codec, &bytes, layout, stride as i32, w as i32, h as i32, img.has_alpha, 0.95)
        .map_err(writer_error)
}
