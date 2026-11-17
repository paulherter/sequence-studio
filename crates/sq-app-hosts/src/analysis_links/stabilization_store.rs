//! The analyses a Stabilizer re-plan reads (Swift `StabilizationCache`): a finished run puts its result in, the session's
//! [`StabilizationLookup`] finds it again for any range it covers. With a cache folder ([`StabilizationStore::with_disk`])
//! a miss reads the file the runs write (`stabilization_analyzer::cache_name`), so a result outlives the launch.

use sq_core_masks::stabilizer::StabilizationAnalysis;
use sq_core_time::TimeRange;
use sq_editor_session::StabilizationLookup;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use super::stabilization_analyzer::{cache_name, load_analysis};

struct Entry {
    path: String,
    range: TimeRange,
    analysis: StabilizationAnalysis,
}

/// Shared by the analysis job (writes) and the inspector (re-plans); clones see the same entries.
#[derive(Clone, Default)]
pub struct StabilizationStore {
    entries: Arc<Mutex<Vec<Entry>>>,
    /// The folder of the disk cache and the files already read from it (read once per launch, then memory answers).
    disk: Option<(PathBuf, Arc<Mutex<HashSet<String>>>)>,
}

fn covers(outer: TimeRange, inner: TimeRange) -> bool {
    outer.start <= inner.start && outer.start + outer.duration >= inner.start + inner.duration
}

impl StabilizationStore {
    /// A store that also finds what earlier launches measured in `dir`.
    pub fn with_disk(dir: PathBuf) -> StabilizationStore {
        StabilizationStore { disk: Some((dir, Arc::default())), ..StabilizationStore::default() }
    }

    /// Keeps `analysis` for `path` over `range`; an entry of the same picture size it covers is replaced.
    pub fn put(&self, path: &str, range: TimeRange, analysis: StabilizationAnalysis) {
        let mut all = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        all.retain(|e| {
            !(e.path == path
                && e.analysis.picture_width == analysis.picture_width
                && e.analysis.picture_height == analysis.picture_height
                && covers(range, e.range))
        });
        all.push(Entry { path: path.to_string(), range, analysis });
    }

    /// The analysis of `path` at this picture size that covers `range`.
    pub fn get(&self, path: &str, range: TimeRange, width: i64, height: i64) -> Option<StabilizationAnalysis> {
        if let Some(hit) = self.find(path, range, width, height) {
            return Some(hit);
        }
        let (dir, tried) = self.disk.as_ref()?;
        let name = cache_name(std::path::Path::new(path))?;
        if !tried.lock().unwrap_or_else(PoisonError::into_inner).insert(name.clone()) {
            return None;
        }
        let (stored, analysis) = load_analysis(&dir.join(name))?;
        self.put(path, stored, analysis);
        self.find(path, range, width, height)
    }

    fn find(&self, path: &str, range: TimeRange, width: i64, height: i64) -> Option<StabilizationAnalysis> {
        let all = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        all.iter()
            .find(|e| {
                e.path == path
                    && e.analysis.picture_width == width
                    && e.analysis.picture_height == height
                    && covers(e.range, range)
            })
            .map(|e| e.analysis.clone())
    }

    /// The lookup the session's re-plan takes.
    pub fn lookup(&self) -> StabilizationLookup {
        let store = self.clone();
        Arc::new(move |media, range, w, h| store.get(&media.path, range, w, h))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn analysis(w: i64, h: i64) -> StabilizationAnalysis {
        StabilizationAnalysis::new(w, h, vec![Time::ZERO], Vec::new())
    }

    fn range(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(Time::seconds(a), Time::seconds(b))
    }

    #[test]
    fn a_wider_analysis_serves_a_trimmed_clip() {
        let s = StabilizationStore::default();
        s.put("/m/a.mov", range(0, 10), analysis(1920, 1080));
        assert!(s.get("/m/a.mov", range(2, 5), 1920, 1080).is_some());
        assert!(s.get("/m/a.mov", range(5, 12), 1920, 1080).is_none(), "range not covered");
        assert!(s.get("/m/a.mov", range(2, 5), 1280, 720).is_none(), "other picture size");
        assert!(s.get("/m/b.mov", range(2, 5), 1920, 1080).is_none(), "other file");
    }

    #[test]
    fn a_new_run_replaces_the_ones_it_covers() {
        let s = StabilizationStore::default();
        s.put("/m/a.mov", range(2, 4), analysis(1920, 1080));
        s.put("/m/a.mov", range(0, 10), analysis(1920, 1080));
        assert_eq!(s.entries.lock().map(|g| g.len()).unwrap_or(0), 1);
    }
}
