//! Export frames as bytes the encoder takes.

use crate::core::{ExportError, ExportFrame};
use sq_frame::sqframe::SQFramePixelFormat;
use sq_media_ffmpeg::decode::{FFmpegFrame, MemoryFrame};
use sq_media_ffmpeg::encode::PixelLayout;
use std::borrow::Cow;

/// One frame's bytes, the row stride of its first plane and the layout.
pub(super) struct Pixels<'a> {
    pub bytes: Cow<'a, [u8]>,
    pub stride: usize,
    pub layout: PixelLayout,
}

fn layout_of(format: SQFramePixelFormat) -> Option<PixelLayout> {
    match format {
        SQFramePixelFormat::Bgra8 => Some(PixelLayout::Bgra),
        SQFramePixelFormat::Rgba8 => Some(PixelLayout::Rgba),
        SQFramePixelFormat::Nv12 | SQFramePixelFormat::Nv12FullRange => Some(PixelLayout::Nv12),
        SQFramePixelFormat::P010 | SQFramePixelFormat::P010FullRange => Some(PixelLayout::P010le),
        SQFramePixelFormat::Rgba16f => Some(PixelLayout::Rgbaf16le),
        _ => None,
    }
}

/// The pixels of frame `index`: memory frames as they are, FFmpeg frames downloaded (NV12 / P010, tightly packed).
pub(super) fn pixels_of(
    frame: &ExportFrame,
    index: usize,
    width: usize,
    height: usize,
) -> Result<Pixels<'_>, ExportError> {
    if frame.width != width || frame.height != height {
        return Err(ExportError::WriterFailed(format!(
            "frame {index} is {}x{}, the export {width}x{height}",
            frame.width, frame.height
        )));
    }
    if let Some(m) = frame.storage_as::<MemoryFrame>() {
        let layout = layout_of(frame.pixel_format).ok_or_else(|| {
            ExportError::WriterFailed(format!("pixel format {:?} cannot be exported", frame.pixel_format))
        })?;
        return Ok(Pixels { bytes: Cow::Borrowed(&m.bytes), stride: m.bytes_per_row, layout });
    }
    if let Some(f) = frame.storage_as::<FFmpegFrame>() {
        let bytes = f.download().map_err(|e| ExportError::WriterFailed(e.to_string()))?;
        let deep = matches!(frame.pixel_format, SQFramePixelFormat::P010 | SQFramePixelFormat::P010FullRange);
        let layout = if deep { PixelLayout::P010le } else { PixelLayout::Nv12 };
        return Ok(Pixels { bytes: Cow::Owned(bytes), stride: if deep { width * 2 } else { width }, layout });
    }
    Err(ExportError::WriterFailed(format!("frame {index} has a storage this encoder cannot read")))
}
