// Swift: SceneCutAnalyzer.swift
//! Find Scene Changes on the FFmpeg frame reader (the Windows and Linux counterpart of the Mac's `SceneCutAnalyzer`): frames
//! are shrunk, binned by luma and the histogram differences go to the shared `SceneCutDetector`.

use super::ffmpeg_frames::FfmpegFrameReader;
use sq_analysis::scene_cut_detector::{SceneCutDetector, Settings};
use sq_core_time::{Time, TimeRange};
use std::path::Path;

const BINS: usize = 32;
/// Long side of the pictures read (the Swift analyzer reads 96 x 54).
const SIDE: usize = 96;

/// The Rec. 601 luma histogram (32 bins) of RGBA pixels.
pub(super) fn histogram(rgba: &[u8]) -> Vec<i64> {
    let mut h = vec![0_i64; BINS];
    for c in rgba.as_chunks::<4>().0 {
        let l = (usize::from(c[0]) * 77 + usize::from(c[1]) * 150 + usize::from(c[2]) * 29) >> 8;
        h[(l * BINS / 256).min(BINS - 1)] += 1;
    }
    h
}

/// The times where a new shot starts, from the frames' histograms in order.
pub(super) fn cuts(frames: &[(Time, Vec<i64>)]) -> Vec<Time> {
    let diffs: Vec<f64> = (0..frames.len())
        .map(|i| if i == 0 { 0.0 } else { SceneCutDetector::histogram_difference(&frames[i - 1].1, &frames[i].1) })
        .collect();
    SceneCutDetector::cut_indices(&diffs, &Settings::default()).into_iter().map(|i| frames[i].0).collect()
}

/// Scene changes of the file's `range`, in media time; `progress` runs 0...1.
pub fn scene_changes(
    path: &Path,
    range: TimeRange,
    progress: &(dyn Fn(f64) + Send + Sync),
) -> Result<Vec<Time>, String> {
    let reader = FfmpegFrameReader::open(path)?;
    if reader.count() == 0 {
        return Err("The file has no video track.".to_string());
    }
    let first = reader.index_at(range.start).unwrap_or(0);
    let last = reader.index_at(range.end() - Time::new(1, 1_000_000)).unwrap_or(reader.count() - 1).max(first);
    let total = (last - first + 1) as f64;
    let mut frames = Vec::new();
    for (n, i) in (first..=last).enumerate() {
        let p = reader.picture(i, SIDE).ok_or_else(|| "The file could not be read.".to_string())?;
        frames.push((p.pts, histogram(&p.rgba)));
        if n % 30 == 0 {
            progress(n as f64 / total);
        }
    }
    Ok(cuts(&frames))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(luma: u8, count: usize) -> Vec<u8> {
        [luma, luma, luma, 255].repeat(count)
    }

    #[test]
    fn a_dark_to_bright_jump_is_one_cut_at_the_first_bright_frame() {
        let mut frames = Vec::new();
        for i in 0..40_i64 {
            let luma = if i < 20 { 20 } else { 230 };
            frames.push((Time::new(i, 24), histogram(&frame(luma, 64))));
        }
        assert_eq!(cuts(&frames), vec![Time::new(20, 24)]);
    }

    #[test]
    fn a_steady_picture_has_no_cuts() {
        let frames: Vec<_> = (0..40_i64).map(|i| (Time::new(i, 24), histogram(&frame(100, 64)))).collect();
        assert!(cuts(&frames).is_empty());
    }
}
