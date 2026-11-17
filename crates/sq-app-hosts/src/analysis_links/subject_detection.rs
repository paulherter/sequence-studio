//! The subject detector of Auto-Reframe on the FFmpeg frame reader and the ONNX face / person models (the Windows and Linux
//! counterpart of the Mac's `VisionSubjectDetector`; the Mac keeps Vision).

use super::ffmpeg_frames::FfmpegFrameReader;
use sq_analysis::edge_tamonnx::SubjectFrame;
use sq_analysis::person_detector::{FrameAt, OnnxSubjectDetector, default_folder};
use std::path::Path;
use std::sync::Mutex;

/// Longest side of the analyzed frame, as the Swift detector's default (640).
const MAX_SIDE: usize = 640;

/// A detector over the frames of the video file at `path`; the models come from the person-model folder (downloaded on first
/// use). The frame nearest to the asked time is analyzed (the Swift detector allows a 50 ms window as well).
/// Frames are turned upright by the file's rotation tag before detection, so boxes are fractions of the upright picture as on
/// the Mac (a phone clip stored sideways is analyzed upright).
pub fn onnx_subject_detector(path: &Path) -> Result<OnnxSubjectDetector, String> {
    let reader = FfmpegFrameReader::open(path)?;
    let rotation = reader.rotation();
    let reader = Mutex::new(reader);
    let frames: FrameAt = Box::new(move |t| {
        let reader = reader.lock().map_err(|_| "the frame reader failed".to_string())?;
        Ok(upright_frame(&reader, rotation, t))
    });
    let folder = default_folder(|k| std::env::var(k).ok());
    OnnxSubjectDetector::new(&folder, frames)
}

/// The frame shown at `t`, turned upright by `rotation` degrees; `None` outside the file.
fn upright_frame(reader: &FfmpegFrameReader, rotation: i64, t: sq_core_time::Time) -> Option<SubjectFrame> {
    let index = reader.index_at(t)?;
    reader.picture(index, MAX_SIDE).map(|p| SubjectFrame::new(p.width, p.height, p.rgba).upright(rotation))
}

/// The analysis backend of the systems without Apple's Vision framework (Windows, Linux): Auto Reframe finds subjects with the
/// ONNX face and body models (saliency where nobody is found) over the FFmpeg frame reader; Find Scene Changes and Stabilize
/// read the same frames.
pub struct PortableAnalysisBackend;

impl sq_editor_session::AnalysisBackend for PortableAnalysisBackend {
    fn scene_changes(
        &self,
        path: &Path,
        range: sq_core_time::TimeRange,
        progress: &(dyn Fn(f64) + Send + Sync),
    ) -> Result<Option<Vec<sq_core_time::Time>>, String> {
        super::scene_changes::scene_changes(path, range, progress).map(Some)
    }

    fn offers_stabilize(&self) -> bool {
        true
    }

    fn stabilization_analyzer(
        &self,
        media: &sq_core_model::MediaRef,
    ) -> Option<sq_editor_session::BoxedStabilizationAnalyzer> {
        Some(Box::new(super::stabilization_analyzer::FfmpegStabilizationAnalyzer::new(Path::new(&media.path))))
    }

    fn offers_reframe(&self) -> bool {
        sq_translate::translator::runtime_available()
    }

    fn subject_detector(
        &self,
        media: &sq_core_model::MediaRef,
    ) -> Option<Box<dyn sq_analysis::reframe::SubjectDetecting<Error = String> + Send>> {
        let detector = onnx_subject_detector(Path::new(&media.path)).ok()?;
        Some(Box::new(detector))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    /// A clip stored landscape with a 90 degree rotation tag (`SQ_ROTATED_CLIP`, made with `ffmpeg -display_rotation 90 -i
    /// clip.mp4 -c copy`): the analyzed frame is portrait, the stored one is landscape. Skips without the file.
    #[test]
    fn a_clip_with_a_rotation_tag_is_analyzed_upright() {
        let Ok(path) = std::env::var("SQ_ROTATED_CLIP") else {
            eprintln!("skipped: SQ_ROTATED_CLIP (a landscape clip with a 90 degree rotation tag) is not set");
            return;
        };
        let reader = FfmpegFrameReader::open(Path::new(&path)).expect("open");
        let rotation = reader.rotation();
        assert!(rotation == 90 || rotation == 270, "rotation tag {rotation}");
        let stored = reader.picture(0, MAX_SIDE).expect("stored frame");
        assert!(stored.width > stored.height, "the clip is stored landscape: {}x{}", stored.width, stored.height);
        let upright = upright_frame(&reader, rotation, Time::ZERO).expect("upright frame");
        assert_eq!((upright.width, upright.height), (stored.height, stored.width));
        // And a clip without a tag is left alone.
        if let Ok(plain) = std::env::var("SQ_UPRIGHT_CLIP") {
            let reader = FfmpegFrameReader::open(Path::new(&plain)).expect("open");
            assert_eq!(reader.rotation(), 0);
            let f = upright_frame(&reader, 0, Time::ZERO).expect("frame");
            assert!(f.width > f.height);
        }
    }

    #[test]
    fn the_backend_offers_reframe_only_with_the_runtime_and_gives_no_detector_for_a_missing_file() {
        use sq_editor_session::AnalysisBackend;
        let backend = PortableAnalysisBackend;
        assert_eq!(backend.offers_reframe(), sq_translate::translator::runtime_available());
        let media = sq_core_model::MediaRef::new(
            sq_core_time::Id::from_u128(1),
            "gone",
            "no-such-folder/gone.mp4",
            sq_core_model::MediaFingerprint::new(1),
        );
        assert!(backend.subject_detector(&media).is_none());
    }
}
