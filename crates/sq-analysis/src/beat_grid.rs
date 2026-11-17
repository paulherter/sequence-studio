// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BeatGrid.swift
//! Beats and downbeats of a piece of music, for cut-to-beat and snapping.
use sq_core_time::Time;

/// Beats and downbeats of a piece of music, for cut-to-beat and snapping.
/// `beats` are ascending; `downbeat_beat_indices` index into `beats` (every `beats_per_bar`-th beat from the detected bar phase).
#[derive(Clone, Debug, PartialEq)]
pub struct BeatGrid {
    /// Beat times, ascending.
    pub beats: Vec<Time>,
    /// Indices into `beats`.
    pub downbeat_beat_indices: Vec<usize>,
    /// Beats in a bar.
    pub beats_per_bar: i64,
    /// Estimated tempo in beats per minute (informational; the beat times are the truth, they follow tempo drift).
    pub bpm: f64,
}

impl BeatGrid {
    /// The times of the downbeats.
    pub fn downbeats(&self) -> Vec<Time> {
        self.downbeat_beat_indices.iter().map(|&i| self.beats[i]).collect()
    }
}
