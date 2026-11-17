//! Pictures of a clip's media for the analyses: an FFmpeg decode of single frames, shrunk to the size the model or the
//! motion measurement wants. [`FfmpegTrackFrames`] gives Magic Mask tracking its frames in tracking order.
// The stored picture is used as it is unless a reader is `shaped` (only Anonymize does; Magic Mask tracking takes no pixel
// aspect or Deinterlace yet, as the shared track path has none); the rotation tag is read through `rotation` and applied by
// the subject detector and by the tracking frames (`upright_track_frame`).

use super::magic_job::TrackFrames;
use super::mask_track::MaskFrameSource;
use crate::project_services::scale_rgba;
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_analysis::mask_point_tracker::Gray;
use sq_analysis::subject_mask_quality::SubjectMaskQuality;
use sq_core_masks::subject_track_rules::SubjectTrackRules;
use sq_core_model::{FieldOrder, PixelAspect};
use sq_core_time::{Id, Time};
use sq_media::demuxing::Demuxing;
use sq_media_ffmpeg::decode::{FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder};
use std::path::Path;
use std::sync::Arc;

/// One decoded picture.
pub struct DecodedPicture {
    /// Presentation time in the media.
    pub pts: Time,
    /// Width in px.
    pub width: usize,
    /// Height in px.
    pub height: usize,
    /// Four bytes per px.
    pub rgba: Vec<u8>,
    /// The decoded pixel format has an alpha channel.
    pub has_alpha: bool,
}

/// Random access to the frames of one video file.
pub struct FfmpegFrameReader {
    demuxer: Arc<FFmpegDemuxer>,
    decoder: FFmpegVideoDecoder,
    /// The shape the stored pixels are shown with (square unless `shaped` says otherwise).
    aspect: PixelAspect,
}

impl FfmpegFrameReader {
    /// Opens `path` for software decoding.
    pub fn open(path: &Path) -> Result<FfmpegFrameReader, String> {
        let demuxer = FFmpegDemuxer::open_shared(path).map_err(|e| e.to_string())?;
        let decoder =
            FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(0), false, 0).map_err(|e| e.to_string())?;
        Ok(FfmpegFrameReader { demuxer, decoder, aspect: PixelAspect::square() })
    }

    /// Frames leave deinterlaced with `order` and as wide as they are shown (`aspect`): the media item's
    /// `deinterlace_field_order` and `display_pixel_aspect`, as Swift's `FrameReader` takes them.
    pub fn shaped(mut self, aspect: PixelAspect, order: Option<FieldOrder>) -> FfmpegFrameReader {
        self.decoder = self.decoder.with_deinterlace(order);
        self.aspect = aspect;
        self
    }

    /// Clockwise degrees (0, 90, 180, 270) that turn the stored picture upright (the file's rotation tag).
    pub fn rotation(&self) -> i64 {
        self.demuxer.rotation()
    }

    /// Frames in the file.
    pub fn count(&self) -> usize {
        self.demuxer.index().count()
    }

    /// The frame shown at `t`; `None` outside the file.
    pub fn index_at(&self, t: Time) -> Option<usize> {
        self.demuxer.index().frame_at(t)
    }

    /// Frame `index`, at most `max_side` px on its long side (never enlarged).
    pub fn picture(&self, index: usize, max_side: usize) -> Option<DecodedPicture> {
        let frames = self.decoder.decode_blocking(index..=index, None, None).ok()?;
        let decoded = frames.first()?;
        let rgba = decoded.frame.storage_as::<FFmpegFrame>()?.download_rgba().ok()?;
        let (w, h) = (decoded.frame.width, decoded.frame.height);
        let (out_w, out_h) = fit_long_side(shown_width(w, self.aspect), h, max_side);
        Some(DecodedPicture {
            pts: decoded.pts(),
            width: out_w,
            height: out_h,
            rgba: scale_rgba(&rgba, w, h, out_w, out_h),
            has_alpha: decoded.frame.storage_as::<FFmpegFrame>()?.has_alpha(),
        })
    }
}

/// The stored `width` as wide as it is shown with `aspect`.
pub fn shown_width(width: usize, aspect: PixelAspect) -> usize {
    aspect.display_width(width as i64).max(1) as usize
}

/// `width` x `height` shrunk to `max_side` on the long side, keeping the shape.
pub fn fit_long_side(width: usize, height: usize, max_side: usize) -> (usize, usize) {
    let long = width.max(height);
    if long <= max_side || long == 0 {
        return (width, height);
    }
    let f = |v: usize| (v * max_side / long).max(1);
    (f(width), f(height))
}

/// The frame indices a run visits from `start` to `stop` (both inside the file, either order): onward or backward.
pub fn track_indices(start: usize, stop: usize, count: usize) -> Vec<usize> {
    if start >= count {
        return Vec::new();
    }
    let stop = stop.min(count - 1);
    if stop >= start { (start..=stop).collect() } else { (stop..=start).rev().collect() }
}

/// [`MaskFrameSource`] over a video file: luma pictures by source time, shrunk for the tracker.
pub struct FfmpegMaskFrames {
    reader: FfmpegFrameReader,
}

impl FfmpegMaskFrames {
    /// Long side of the pictures the tracker works on (px).
    const MAX_SIDE: usize = 960;

    /// Opens `path`.
    pub fn open(path: &Path) -> Result<FfmpegMaskFrames, String> {
        Ok(FfmpegMaskFrames { reader: FfmpegFrameReader::open(path)? })
    }
}

impl MaskFrameSource for FfmpegMaskFrames {
    fn gray_at(&mut self, source: Time) -> Option<Gray> {
        let index = self.reader.index_at(source)?;
        let pic = self.reader.picture(index, Self::MAX_SIDE)?;
        Gray::from_rgba(pic.width, pic.height, &pic.rgba)
    }
}

/// [`TrackFrames`] over a video file: the pick frame first, then onward or backward.
pub struct FfmpegTrackFrames {
    reader: FfmpegFrameReader,
    indices: Vec<usize>,
    side: usize,
    /// Clockwise degrees that turn the stored picture upright.
    rotation: i64,
}

impl FfmpegTrackFrames {
    /// A run from the pick frame at source time `from` to the frame at `to` (before `from`: tracked backward). `to` past
    /// the file ends the run at the last frame.
    pub fn open(path: &Path, from: Time, to: Time) -> Result<FfmpegTrackFrames, String> {
        Self::open_with(path, from, to, SubjectMaskQuality::Speed)
    }

    /// Long side of the frames a run reads: the tracking size, and with Quality larger (Swift `frameDimension`), so the
    /// matte made from the logits has the finer size.
    pub fn track_side(quality: SubjectMaskQuality) -> usize {
        usize::try_from(quality.frame_dimension(SubjectTrackRules::MODEL_SIZE as i64))
            .unwrap_or(SubjectTrackRules::MODEL_SIZE)
    }

    /// [`open`](Self::open) with the Subject Mask Edges choice the run is made with.
    pub fn open_with(
        path: &Path,
        from: Time,
        to: Time,
        quality: SubjectMaskQuality,
    ) -> Result<FfmpegTrackFrames, String> {
        let reader = FfmpegFrameReader::open(path)?;
        let start = reader.index_at(from).ok_or("The pick frame is outside the file.")?;
        let stop = reader.index_at(to).unwrap_or(if to < from { 0 } else { usize::MAX });
        let indices = track_indices(start, stop, reader.count());
        let rotation = reader.rotation();
        Ok(FfmpegTrackFrames { reader, indices, side: Self::track_side(quality), rotation })
    }
}

impl TrackFrames for FfmpegTrackFrames {
    fn count(&self) -> usize {
        self.indices.len()
    }

    fn frame(&mut self, i: usize) -> Option<(f64, SubjectFrame)> {
        let pic = self.reader.picture(*self.indices.get(i)?, self.side)?;
        let seconds = pic.pts.value() as f64 / pic.pts.timescale() as f64;
        Some((seconds, upright_track_frame(pic.width, pic.height, pic.rgba, self.rotation)))
    }
}

/// A tracking frame turned upright by the file's rotation tag, so the pick (made on the upright picture) and the matte
/// share one orientation: a phone clip stored sideways tracks the right way up, as the Mac reads it.
fn upright_track_frame(width: usize, height: usize, rgba: Vec<u8>, rotation: i64) -> SubjectFrame {
    SubjectFrame::new(width, height, rgba).upright(rotation)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_reads_larger_tracking_frames_than_speed() {
        assert_eq!(FfmpegTrackFrames::track_side(SubjectMaskQuality::Speed), 1024);
        assert_eq!(FfmpegTrackFrames::track_side(SubjectMaskQuality::Quality), 1920);
    }

    #[test]
    fn the_long_side_is_capped_and_the_shape_kept() {
        assert_eq!(fit_long_side(3840, 2160, 1024), (1024, 576));
        assert_eq!(fit_long_side(1080, 1920, 1024), (576, 1024));
        assert_eq!(fit_long_side(640, 360, 1024), (640, 360));
    }

    #[test]
    fn frames_are_read_as_wide_as_they_are_shown() {
        let wide = PixelAspect::new(4, 3).expect("aspect");
        assert_eq!(shown_width(1440, wide), 1920);
        assert_eq!(shown_width(1920, PixelAspect::square()), 1920);
        // The analyzed picture keeps the shown shape: 1440 x 1080 at 4:3 pixels is 16:9.
        assert_eq!(fit_long_side(shown_width(1440, wide), 1080, 1024), (1024, 576));
    }

    #[test]
    fn a_run_goes_on_or_back_inside_the_file() {
        assert_eq!(track_indices(2, 99, 6), [2, 3, 4, 5]);
        assert_eq!(track_indices(2, 3, 6), [2, 3]);
        assert_eq!(track_indices(2, 0, 6), [2, 1, 0]);
        assert_eq!(track_indices(2, 2, 6), [2]);
        assert!(track_indices(6, 7, 6).is_empty());
    }

    #[test]
    fn a_sideways_tracking_frame_is_turned_upright() {
        // 2 x 1 stored picture, rotation tag 90: shown 1 x 2.
        let rgba = vec![1, 0, 0, 255, 2, 0, 0, 255];
        let turned = upright_track_frame(2, 1, rgba.clone(), 90);
        assert_eq!((turned.width, turned.height), (1, 2));
        let same = upright_track_frame(2, 1, rgba, 0);
        assert_eq!((same.width, same.height), (2, 1));
    }

    #[test]
    fn a_missing_file_says_so() {
        assert!(FfmpegTrackFrames::open(Path::new("/no/such.mov"), Time::ZERO, Time::seconds(1)).is_err());
    }
}
