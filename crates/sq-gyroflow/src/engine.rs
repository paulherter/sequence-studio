// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQAnalysis GyroflowEngine.swift (`warp`, `map`, `prefetchMap`, `analysisState`, `runningAnalyses`)
//! The engine the render paths and the inspector talk to: analyses per (file, options) on background threads, and the warp
//! maps of frames (cached per frame time, the next frame prefetched while playing). `GyroMaps` is what the compositor needs.

use crate::{GyroAnalyses, GyroFile, GyroState, GyroflowBackend};
use parking_lot::Mutex;
use sq_core_masks::stabilize_effect::GyroflowOptions;
use sq_render::program::{GyroMaps, WarpMap};
use std::collections::HashMap;
use std::sync::Arc;

/// Maps kept per analysis (about 10 s of 25 fps would be 250: a map is 480x270x16 bytes = 2 MB, so only a short window).
const MAP_CAPACITY: usize = 24;

type MapCache = Mutex<Vec<((String, [u64; 7], i64), Arc<WarpMap>)>>;

/// One engine per session.
pub struct GyroEngine {
    analyses: Arc<GyroAnalyses<GyroflowBackend>>,
    maps: Arc<MapCache>,
    pending: Arc<Mutex<HashMap<(String, i64), ()>>>,
}

impl Default for GyroEngine {
    fn default() -> Self {
        GyroEngine::new()
    }
}

impl GyroEngine {
    pub fn new() -> GyroEngine {
        GyroEngine {
            analyses: Arc::new(GyroAnalyses::new(GyroflowBackend)),
            maps: Arc::new(Mutex::new(Vec::new())),
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// The analyses (state, prepare, cancel, observers for the Analyze row and the Jobs list).
    pub fn analyses(&self) -> &Arc<GyroAnalyses<GyroflowBackend>> {
        &self.analyses
    }

    fn key(path: &str, options: &GyroflowOptions, ts: i64) -> (String, [u64; 7], i64) {
        let k = crate::AnalysisKey::new(path, options);
        (path.to_string(), k.options_bits(), ts)
    }

    fn cached(&self, key: &(String, [u64; 7], i64)) -> Option<Arc<WarpMap>> {
        let mut c = self.maps.lock();
        let i = c.iter().position(|(k, _)| k == key)?;
        let e = c.remove(i);
        let m = Arc::clone(&e.1);
        c.push(e);
        Some(m)
    }

    fn store(maps: &MapCache, key: (String, [u64; 7], i64), m: Arc<WarpMap>) {
        let mut c = maps.lock();
        c.retain(|(k, _)| *k != key);
        c.push((key, m));
        let over = c.len().saturating_sub(MAP_CAPACITY);
        c.drain(..over);
    }

    /// The map of the frame after `ts_us` in the background (playback asks for it next).
    fn prefetch(&self, file: &Arc<GyroFile>, path: &str, options: &GyroflowOptions, ts_us: i64) {
        let fps = file.info().fps;
        if fps <= 0.0 {
            return;
        }
        // Frame times come from rational pts rounded to microseconds; predict the next one the same way.
        let frame = (ts_us as f64 * fps / 1_000_000.0).round();
        let next = ((frame + 1.0) / fps * 1_000_000.0).round() as i64;
        let key = Self::key(path, options, next);
        if next <= ts_us || self.cached(&key).is_some() {
            return;
        }
        if self.pending.lock().insert((format!("{:?}", key), next), ()).is_some() {
            return;
        }
        let (file, maps, pending) = (Arc::clone(file), Arc::clone(&self.maps), Arc::clone(&self.pending));
        let tag = (format!("{:?}", key), next);
        std::thread::spawn(move || {
            if let Some(m) = file.warp_map(next) {
                Self::store(&maps, key, Arc::new(m));
            }
            pending.lock().remove(&tag);
        });
    }
}

impl GyroMaps for GyroEngine {
    fn map(&self, path: &str, options: &GyroflowOptions, ts_us: i64, wait: bool) -> Option<Arc<WarpMap>> {
        // Export needs the analysis, also one canceled before it began; playback leaves a canceled one alone and shows the
        // last finished smoothing of the file until the new options are ready.
        let file =
            if wait { self.analyses.wait_ready(path, options)? } else { self.analyses.get_or_stale(path, options)? };
        let key = Self::key(path, options, ts_us);
        if let Some(m) = self.cached(&key) {
            if !wait {
                self.prefetch(&file, path, options, ts_us);
            }
            return Some(m);
        }
        let m = Arc::new(file.warp_map(ts_us)?);
        Self::store(&self.maps, key, Arc::clone(&m));
        if !wait {
            self.prefetch(&file, path, options, ts_us);
        }
        Some(m)
    }

    fn add_observer(&self, f: Arc<dyn Fn() + Send + Sync>) {
        self.analyses.add_observer(f);
    }
}

/// The inspector's state word of a file and options.
pub fn state_of(engine: &GyroEngine, path: &str, options: &GyroflowOptions) -> GyroState {
    engine.analyses.state(path, options)
}
