// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Vendor/sqgyro (libsqgyro, the C shim over gyroflow_core), SQAnalysis GyroflowEngine.swift
//! Gyroflow stabilization for Sequence Studio. `GyroFile` is the safe Rust form of libsqgyro: open a clip (gyro data from
//! the file or a `.gcsv` sidecar, lens profile), set options, smooth the whole clip (`recompute`), warp planes of decoded
//! frames. `GyroAnalyses` is the driver: one analysis per (file, options), the last four kept, the state each shows.
//! The Swift app loads libsqgyro with dlopen; here gyroflow-core is a cargo dependency (pinned to the same revision), so
//! there is no library to find and the Gyroflow method never reports "engine not installed".
//! The warp itself: `GyroFile::warp_map` captures gyroflow_core's output of a frame as a coarse map (two probe warps, like the
//! Mac's probe-plane map) and sq-render's `GyroWarp` Slang pass resamples the frame with it (Lanczos-4, Metal and D3D12).

mod analyses;
mod engine;
mod file;

pub use analyses::{AnalysisKey, GyroAnalyses, GyroBackend, GyroState, GyroflowBackend};
pub use engine::{GyroEngine, state_of};
pub use file::{GyroError, GyroFile, GyroInfo, PlaneKind, gyro_clock_ms, horizon_roll};
pub use file::{decode_map, warp_map_size};
