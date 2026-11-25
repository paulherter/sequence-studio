// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StabilizationAnalyzing.swift
//! Measures the camera motion of a media file over a source range.
use crate::analysis_turn::{CancelToken, Cancelled};
use sq_core_masks::stabilizer::StabilizationAnalysis;
use sq_core_time::TimeRange;
use std::fmt;

/// Why an analysis gave nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StabilizationError {
    /// The file has no video track.
    NoVideoTrack,
    /// The file could not be read.
    Unreadable,
    /// The task was canceled (Swift throws `CancellationError`).
    Cancelled,
}

impl From<Cancelled> for StabilizationError {
    fn from(_: Cancelled) -> Self {
        StabilizationError::Cancelled
    }
}

impl fmt::Display for StabilizationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            StabilizationError::NoVideoTrack => "the file has no video track",
            StabilizationError::Unreadable => "the file could not be read",
            StabilizationError::Cancelled => "canceled",
        })
    }
}

impl std::error::Error for StabilizationError {}

/// Reports progress 0...1.
pub type Progress<'a> = Option<&'a (dyn Fn(f64) + Sync)>;

/// Told `true` when a run stands still for playback (after a wait of 300 ms) and `false` when it goes on.
pub type HoldFn = std::sync::Arc<dyn Fn(bool) + Send + Sync>;

/// Measures the camera motion of a media file over a source range. Swift's `async` becomes a blocking call that checks a
/// `CancelToken` (no executor yet, PORTING section 9).
pub trait StabilizationAnalyzing: Sync {
    /// Where the analyzer tells that it waits for playback; the default analyzer never waits.
    fn set_hold(&mut self, _hold: HoldFn) {}

    /// `picture_width/height`: the upright source picture size the motions are measured in (the clip's own frame).
    fn analyze(
        &self,
        source_range: TimeRange,
        picture_width: i64,
        picture_height: i64,
        progress: Progress<'_>,
        cancel: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError>;

    /// The same for a Stabilizer whose Rolling Shutter option is on (`rolling`): the result must carry the per-row motion
    /// (`StabilizationAnalysis::rolling`), so a stored result from before it was measured does not do. The default asks
    /// the plain analysis.
    fn analyze_rolling(
        &self,
        source_range: TimeRange,
        picture_width: i64,
        picture_height: i64,
        _rolling: bool,
        progress: Progress<'_>,
        cancel: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        self.analyze(source_range, picture_width, picture_height, progress, cancel)
    }
}
