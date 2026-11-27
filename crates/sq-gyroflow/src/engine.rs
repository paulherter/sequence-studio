// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQAnalysis GyroflowEngine.swift (`warp`, `map`, `prefetchMap`, `analysisState`, `runningAnalyses`)
//! The engine the render paths and the inspector talk to: analyses per (file, options) on background threads, and the warp
//! maps of frames (cached per frame time, the next frame prefetched while playing). `GyroMaps` is what the compositor needs.

use crate::{GyroAnalyses, GyroFile, GyroState, GyroflowBackend};
use parking_lot::Mutex;
use sq_core_masks::stabilize_effect::GyroflowOptions;
use sq_render::program::{GyroMaps, GyroReadiness, WarpMap};
use std::collections::HashMap;
use std::sync::Arc;

/// Maps kept per analysis (about 10 s of 25 fps would be 250: a map is 480x270x16 bytes = 2 MB, so only a short window).
const MAP_CAPACITY: usize = 24;

/// (path, option bits, frame time, analysis generation): a map built from an older analysis is never found by a newer one.
type MapKey = (String, [u64; 7], i64, u64);
type MapCache = Mutex<Vec<(MapKey, Arc<WarpMap>)>>;

/// One engine per session.
pub struct GyroEngine {
    analyses: Arc<GyroAnalyses<GyroflowBackend>>,
    maps: Arc<MapCache>,
    pending: Arc<Mutex<HashMap<(String, i64), ()>>>,
    /// Keys whose map came back `None`, with the analysis generation: not retried until the generation changes.
    missed: Arc<Mutex<HashMap<(String, i64), u64>>>,
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
            missed: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// The analyses (state, prepare, cancel, observers for the Analyze row and the Jobs list).
    pub fn analyses(&self) -> &Arc<GyroAnalyses<GyroflowBackend>> {
        &self.analyses
    }

    fn key(path: &str, options: &GyroflowOptions, ts: i64, generation: u64) -> MapKey {
        let k = crate::AnalysisKey::new(path, options);
        (path.to_string(), k.options_bits(), ts, generation)
    }

    fn cached(&self, key: &MapKey) -> Option<Arc<WarpMap>> {
        let mut c = self.maps.lock();
        let i = c.iter().position(|(k, _)| k == key)?;
        let e = c.remove(i);
        let m = Arc::clone(&e.1);
        c.push(e);
        Some(m)
    }

    fn store(maps: &MapCache, key: MapKey, m: Arc<WarpMap>) {
        let mut c = maps.lock();
        c.retain(|(k, _)| *k != key);
        c.push((key, m));
        let over = c.len().saturating_sub(MAP_CAPACITY);
        c.drain(..over);
    }

    /// The map of the frame after `ts_us` in the background (playback asks for it next).
    fn prefetch(&self, file: &Arc<GyroFile>, path: &str, options: &GyroflowOptions, ts_us: i64, generation: u64) {
        let fps = file.info().fps;
        if fps <= 0.0 {
            return;
        }
        // Frame times come from rational pts rounded to microseconds; predict the next one the same way.
        let frame = (ts_us as f64 * fps / 1_000_000.0).round();
        let next = ((frame + 1.0) / fps * 1_000_000.0).round() as i64;
        if next <= ts_us {
            return;
        }
        self.compute_in_background(file, Self::key(path, options, next, generation), next, generation);
    }

    /// Computes and stores the map of `key` (frame time `next`) on a thread, unless it is cached, already running, or it
    /// already returned nothing under this analysis `generation`.
    fn compute_in_background(&self, file: &Arc<GyroFile>, key: MapKey, next: i64, generation: u64) {
        if self.cached(&key).is_some() {
            return;
        }
        let file = Arc::clone(file);
        self.start_job(key, next, generation, move || file.warp_map(next));
    }

    /// Runs `compute` on a thread and stores its map under `key`. Nothing starts when the same job runs or already returned
    /// nothing under this `generation`; a panic counts as nothing.
    fn start_job(
        &self,
        key: MapKey,
        next: i64,
        generation: u64,
        compute: impl FnOnce() -> Option<WarpMap> + Send + 'static,
    ) -> Option<std::thread::JoinHandle<()>> {
        let tag = (format!("{:?}", key), next);
        if self.missed.lock().get(&tag) == Some(&generation) {
            return None;
        }
        if self.pending.lock().insert(tag.clone(), ()).is_some() {
            return None;
        }
        let (maps, pending, missed) = (Arc::clone(&self.maps), Arc::clone(&self.pending), Arc::clone(&self.missed));
        Some(std::thread::spawn(move || {
            // The guard clears the pending tag on every exit.
            let _guard = PendingGuard { pending, tag: tag.clone() };
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(compute)) {
                Ok(Some(m)) => Self::store(&maps, key, Arc::new(m)),
                Ok(None) | Err(_) => {
                    missed.lock().insert(tag, generation);
                }
            }
        }))
    }
}

struct PendingGuard {
    pending: Arc<Mutex<HashMap<(String, i64), ()>>>,
    tag: (String, i64),
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        self.pending.lock().remove(&self.tag);
    }
}

impl GyroMaps for GyroEngine {
    fn map(&self, path: &str, options: &GyroflowOptions, ts_us: i64, wait: bool) -> Option<Arc<WarpMap>> {
        // Export needs the analysis, also one canceled before it began; playback leaves a canceled one alone and shows the
        // last finished smoothing of the file until the new options are ready.
        // The generation is read before the analysis: a map is keyed with the generation it was requested under, so an
        // older analysis' map can never answer a newer generation.
        let generation = self.analyses.generation(path, options);
        let file =
            if wait { self.analyses.wait_ready(path, options)? } else { self.analyses.get_or_stale(path, options)? };
        let key = Self::key(path, options, ts_us, generation);
        if let Some(m) = self.cached(&key) {
            if !wait {
                self.prefetch(&file, path, options, ts_us, generation);
            }
            return Some(m);
        }
        let m = Arc::new(file.warp_map(ts_us)?);
        Self::store(&self.maps, key, Arc::clone(&m));
        if !wait {
            self.prefetch(&file, path, options, ts_us, generation);
        }
        Some(m)
    }

    /// Only a Ready analysis is warmed: during a re-analysis `get_or_stale` hands out the old smoothing, and its map would be
    /// stored under the new analysis' key; the key now carries the generation, this stays as a cheap early exit.
    fn warm(&self, path: &str, options: &GyroflowOptions, ts_us: i64) {
        if !matches!(self.analyses.state(path, options), GyroState::Ready) {
            return;
        }
        if let Some(file) = self.analyses.get_or_stale(path, options) {
            let generation = self.analyses.generation(path, options);
            self.compute_in_background(&file, Self::key(path, options, ts_us, generation), ts_us, generation);
        }
    }

    fn prepare(&self, path: &str, options: &GyroflowOptions) {
        self.analyses.get_or_stale(path, options);
    }

    fn prioritize(&self, path: &str, options: &GyroflowOptions) {
        self.analyses.prioritize(path, options);
    }

    fn expect_clips(&self, n: usize) {
        self.analyses.expect_keys(n);
    }

    fn generation(&self, path: &str, options: &GyroflowOptions) -> u64 {
        self.analyses.generation(path, options)
    }

    fn readiness(&self, path: &str, options: &GyroflowOptions, limit: std::time::Duration) -> GyroReadiness {
        match self.analyses.ready_within(path, options, limit) {
            GyroState::Ready => GyroReadiness::Ready,
            GyroState::Failed(why) => GyroReadiness::Failed(why),
            GyroState::Idle | GyroState::Analysing(_) => GyroReadiness::Loading,
        }
    }

    fn add_observer(&self, f: Arc<dyn Fn() + Send + Sync>) {
        self.analyses.add_observer(f);
    }
}

/// The inspector's state word of a file and options.
pub fn state_of(engine: &GyroEngine, path: &str, options: &GyroflowOptions) -> GyroState {
    engine.analyses.state(path, options)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn warming_a_file_that_is_not_analyzed_returns_at_once_and_stores_nothing() {
        let engine = GyroEngine::new();
        let options = GyroflowOptions::default();
        engine.warm("/nonexistent/clip.mp4", &options, 1_000_000);
        assert!(engine.maps.lock().is_empty());
        assert!(engine.pending.lock().is_empty());
    }

    fn key_of(ts: i64) -> MapKey {
        GyroEngine::key("/a.mp4", &GyroflowOptions::default(), ts, 1)
    }

    fn map() -> WarpMap {
        WarpMap { width: 1, height: 1, texels: vec![] }
    }

    #[test]
    fn a_panicking_map_job_clears_its_pending_tag_and_is_not_retried_under_the_same_generation() {
        let engine = GyroEngine::new();
        let h = engine.start_job(key_of(5), 5, 1, || panic!("warp failed")).unwrap();
        assert!(h.join().is_ok());
        assert!(engine.pending.lock().is_empty());
        assert!(engine.start_job(key_of(5), 5, 1, || Some(map())).is_none());
        assert!(engine.maps.lock().is_empty());
    }

    #[test]
    fn a_job_without_a_map_runs_again_only_after_the_generation_changed() {
        let engine = GyroEngine::new();
        engine.start_job(key_of(7), 7, 1, || None).unwrap().join().unwrap();
        assert!(engine.start_job(key_of(7), 7, 1, || Some(map())).is_none());
        engine.start_job(key_of(7), 7, 2, || Some(map())).unwrap().join().unwrap();
        assert_eq!(engine.maps.lock().len(), 1);
        assert!(engine.pending.lock().is_empty());
    }

    #[test]
    fn a_map_stored_under_an_older_generation_is_not_found_by_a_newer_one() {
        let engine = GyroEngine::new();
        let options = GyroflowOptions::default();
        let old = GyroEngine::key("/a.mp4", &options, 9, 1);
        GyroEngine::store(&engine.maps, old.clone(), Arc::new(map()));
        assert!(engine.cached(&old).is_some());
        assert!(engine.cached(&GyroEngine::key("/a.mp4", &options, 9, 2)).is_none());
    }
}
