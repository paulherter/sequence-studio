//! Stand-ins for the two analyses the workflow benchmark and its cases need without a model or a picture analysis: a
//! synthetic hand-held camera path for the Stabilizer and synthetic subject mattes for a Magic mask. Both go through the
//! app's own paths after that (the Stabilizer effect writer, the matte store the monitor reads), so playback pays what it
//! pays for a real result. shortcut: the numbers say what playing a Stabilizer / matte costs, not what the analysis or the
//! tracking costs; upgrade with a run through `MagicTrackJob` and the real analyzer once they are callable headless.

use sq_analysis::analysis_turn::{CancelToken, Cancelled};
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_analysis::stabilization_analyzing::{Progress, StabilizationAnalyzing, StabilizationError};
use sq_core_effects::effects_editing::stabilizer_effect;
use sq_core_masks::SubjectMatte;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_masks::stabilizer::{CameraMotion, StabilizationAnalysis, Stabilizer, StabilizerOptions};
use sq_core_model::{Clip, ClipEffect};
use sq_core_time::{Id, RandomIds, Time, TimeRange};
use std::path::Path;

/// Frames per second of the synthetic analysis and of the synthetic mattes.
const FPS: i64 = 30;

/// A hand-held path: a few pixels of shake and a fraction of a degree of roll, frame after frame.
pub fn analysis(width: i64, height: i64, range: TimeRange) -> StabilizationAnalysis {
    let start = range.start.value() as f64 / range.start.timescale().max(1) as f64;
    let secs = range.duration.value() as f64 / range.duration.timescale().max(1) as f64;
    let n = (secs * FPS as f64).round().max(2.0) as i64;
    let times: Vec<Time> = (0..n).map(|i| Time::new((start * 1000.0).round() as i64 + i * 1000 / FPS, 1000)).collect();
    let motions = (0..n)
        .map(|i| {
            if i == 0 {
                return CameraMotion::IDENTITY;
            }
            let t = i as f64;
            CameraMotion {
                dx: 3.0 * (t * 0.9).sin(),
                dy: 2.0 * (t * 1.3).cos(),
                rotation: 0.15 * (t * 0.5).sin(),
                scale: 1.0,
            }
        })
        .collect();
    StabilizationAnalysis::new(width, height, times, motions)
}

/// The analyzer the Stabilize command asks for.
pub struct SyntheticAnalyzer;

impl StabilizationAnalyzing for SyntheticAnalyzer {
    fn analyze(
        &self,
        source_range: TimeRange,
        picture_width: i64,
        picture_height: i64,
        _progress: Progress<'_>,
        cancel: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        cancel.check().map_err(|Cancelled| StabilizationError::Cancelled)?;
        Ok(analysis(picture_width, picture_height, source_range))
    }
}

/// A finished Stabilizer effect for `clip` (its keys are the planned correction), for a case project.
pub fn stabilizer_for(clip: &Clip, picture: (i64, i64), fd: Time, id: Id) -> Option<ClipEffect> {
    let options = StabilizerOptions::default();
    let a = analysis(picture.0, picture.1, clip.source);
    let plan = Stabilizer::plan(&a, &options)?;
    Some(stabilizer_effect(&plan, &a, clip, fd, &options, id, &mut RandomIds))
}

/// Writes synthetic mattes (a soft ellipse drifting with the shot) for `key` at every frame of `range` (source time)
/// into the store folder, where the app's own store loads them when a Magic mask asks.
pub fn write_mattes(folder: &Path, key: &str, range: TimeRange) {
    let store = FrameMatteStore::new(Some(folder.to_path_buf()));
    let start = range.start.value() as f64 / range.start.timescale().max(1) as f64;
    let secs = range.duration.value() as f64 / range.duration.timescale().max(1) as f64;
    let (w, h) = (160usize, 90usize);
    for i in 0..(secs * FPS as f64).ceil() as i64 {
        let pts = start + i as f64 / FPS as f64;
        let cx = 0.5 + 0.1 * (pts * 0.8).sin();
        let values = (0..w * h)
            .map(|p| {
                let (x, y) = ((p % w) as f64 / w as f64, (p / w) as f64 / h as f64);
                let d = (((x - cx) / 0.28).powi(2) + ((y - 0.5) / 0.4).powi(2)).sqrt();
                (1.5 - 2.0 * d).clamp(0.0, 1.0) as f32
            })
            .collect();
        store.put(key, pts, SubjectMatte::new(w, h, values));
    }
    store.save(key);
    store.wait_for_saves();
}

/// Writes the synthetic mattes of every Magic mask of the project that has none in `folder` yet; returns how many keys.
pub fn ensure_mattes(project: &sq_core_model::Project, folder: &Path) -> usize {
    use sq_core_masks::anonymize::MagicSelectionAnonymizeExt;
    let mut keys = std::collections::BTreeSet::new();
    for clip in project.timelines.iter().flat_map(|t| t.tracks.iter()).flat_map(|tr| tr.clips().iter()) {
        for m in clip.masks().iter().filter(|m| m.source() == sq_core_model::MaskSource::Magic) {
            let key = m.magic.clone().unwrap_or_default().matte_key(clip.media);
            if keys.insert(key.clone()) && !FrameMatteStore::new(Some(folder.to_path_buf())).has(&key) {
                write_mattes(folder, &key, clip.source);
            }
        }
    }
    keys.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_synthetic_path_has_one_motion_per_frame_and_plans() {
        let range = TimeRange::new(Time::ZERO, Time::new(4, 1));
        let a = analysis(1920, 1080, range);
        assert_eq!(a.frame_times.len(), a.motions.len());
        assert_eq!(a.frame_times.len(), 120);
        assert_eq!(a.motions[0], CameraMotion::IDENTITY);
        assert!(Stabilizer::plan(&a, &StabilizerOptions::default()).is_some());
    }

    #[test]
    fn the_matte_files_come_back_through_a_store_of_the_same_folder() {
        let dir = std::env::temp_dir().join(format!("sq-wf-synth-{}", std::process::id()));
        write_mattes(&dir, "k", TimeRange::new(Time::ZERO, Time::new(1, 1)));
        let again = FrameMatteStore::new(Some(dir.clone()));
        assert_eq!(again.times("k").len(), 30);
        let m = again.matte("k", 0.0).expect("a matte");
        assert!(m.values.iter().any(|v| *v > 0.9) && m.values.iter().any(|v| *v < 0.1));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
