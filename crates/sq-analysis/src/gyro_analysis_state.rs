// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: GyroAnalysisState.swift
//! Portable: the Stabilizer's Analyze row reads it on every platform; the engine is Mac-only.

/// Where the engine is with one clip file and one set of options (shown in the Stabilizer's Analyze row).
#[derive(Clone, Debug, PartialEq)]
pub enum GyroAnalysisState {
    /// Nothing asked for yet.
    Idle,
    /// Reading the gyro data / smoothing, 0...1.
    Analysing(f64),
    /// Done.
    Ready,
    /// Failed with a reason.
    Failed(String),
}
