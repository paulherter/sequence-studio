// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FrameMatteStore.swift
//! Per-frame Magic mattes by cache key and source time (seconds): what a Magic pick and its tracking make on a platform
//! without the Mac `MagicMatteStore` (Windows: EdgeTAM through ONNX Runtime). `mattes_for` is what the compositor reads per
//! layer, with the mask's Feather / Expansion applied.
//!
//! With a `directory` every key lives in one `<key>.sqmatte` file, the Mac store's format (`SQMT`, version 2, 8-bit frames),
//! so a project that is reopened (or moved between the Mac and Windows with its cache) finds its mattes: the project holds
//! the picks, the files hold what tracking made (`MagicSelection.cacheKey`). Frames are written raw here; the Mac store
//! compresses them with LZFSE and reads raw frames too. A frame whose stored size differs from width x height is LZFSE
//! (`Lzfse::decode`, portable), so Mac cache files load on Windows as well.
use crate::analysis_cache_location::AnalysisCacheLocation;
use crate::lzfse::Lzfse;
use sq_core_effects::effects_evaluation::ClipEffects;
use sq_core_masks::magic_track_health::HealthSample;
use sq_core_masks::matte_refine::MatteRefine;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_core_time::Id;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::{self, JoinHandle};

#[derive(Clone, Debug)]
struct Frame {
    pts: f64,
    matte: SubjectMatte,
}

#[derive(Clone, Debug, PartialEq)]
struct EdgeKey {
    key: String,
    pts: f64,
    feather: f64,
    expansion: f64,
    frame_width: f64,
}

#[derive(Default)]
struct State {
    frames: HashMap<String, Vec<Frame>>,
    edged: Vec<(EdgeKey, SubjectMatte)>,
    revision: i64,
    loaded: HashSet<String>,
    unsaved: BTreeSet<String>,
    queued: HashSet<String>,
}

struct Inner {
    directory: Option<PathBuf>,
    state: Mutex<State>,
    save_lock: Mutex<()>,
    /// Background saves that have not been waited for.
    saves: Mutex<Vec<JoinHandle<()>>>,
}

/// Per-frame Magic mattes by cache key and source time.
pub struct FrameMatteStore {
    // Shared with the background save threads (`save_later`).
    inner: Arc<Inner>,
}

const FILE_VERSION: u32 = 2;
const EDGED_LIMIT: usize = 24;
/// A stored frame larger than this many texels is damaged; its buffer is not allocated.
const MAX_TEXELS: u64 = 1 << 28;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl FrameMatteStore {
    /// The app's store: `<analysis cache>/MagicMattes`.
    pub fn shared() -> &'static FrameMatteStore {
        static SHARED: OnceLock<FrameMatteStore> = OnceLock::new();
        SHARED.get_or_init(|| {
            FrameMatteStore::new(AnalysisCacheLocation::directory("MagicMattes", || {
                AnalysisCacheLocation::legacy_bundle_directory("MagicMattes")
            }))
        })
    }

    /// `directory` `None` = memory only (tests).
    pub fn new(directory: Option<PathBuf>) -> FrameMatteStore {
        if let Some(d) = &directory {
            let _ = std::fs::create_dir_all(d);
        }
        FrameMatteStore {
            inner: Arc::new(Inner {
                directory,
                state: Mutex::new(State::default()),
                save_lock: Mutex::new(()),
                saves: Mutex::new(Vec::new()),
            }),
        }
    }

    /// Where the files live.
    pub fn directory(&self) -> Option<&Path> {
        self.inner.directory.as_deref()
    }

    /// Bumps whenever a matte is stored or removed (callers that cache a drawing by it).
    pub fn revision(&self) -> i64 {
        lock(&self.inner.state).revision
    }

    /// Stores the matte of the frame at `pts`, replacing one at the same time.
    pub fn put(&self, key: &str, pts: f64, matte: SubjectMatte) {
        self.load(key);
        let mut s = lock(&self.inner.state);
        s.unsaved.insert(key.to_string());
        let mut list = s.frames.remove(key).unwrap_or_default();
        list.retain(|f| (f.pts - pts).abs() >= 1e-6);
        list.push(Frame { pts, matte });
        list.sort_by(|a, b| a.pts.total_cmp(&b.pts));
        s.frames.insert(key.to_string(), list);
        s.edged.retain(|e| e.0.key != key);
        s.revision += 1;
    }

    /// The source times of the stored frames of `key`.
    pub fn times(&self, key: &str) -> Vec<f64> {
        self.load(key);
        lock(&self.inner.state).frames.get(key).map(|l| l.iter().map(|f| f.pts).collect()).unwrap_or_default()
    }

    /// Matte coverage (0...1) of every stored frame of `key`, in time order: the input of the confidence strip
    /// (`MagicTrackHealth::weak_spans`), like `MagicMatteStore.healthSamples` on the Mac. Frames at or under half an 8-bit
    /// step count as empty, as the Mac store's 8-bit data does.
    pub fn health_samples(&self, key: &str) -> Vec<HealthSample> {
        self.load(key);
        let list = lock(&self.inner.state).frames.get(key).cloned().unwrap_or_default();
        list.iter()
            .map(|f| {
                let n = f.matte.width() * f.matte.height();
                let sum =
                    f.matte.values.iter().fold(0.0_f64, |a, v| a + f64::from((v.clamp(0.0, 1.0) * 255.0).round()));
                HealthSample { pts: f.pts, area: sum / (255.0 * n as f64) }
            })
            .collect()
    }

    /// Whether any frame of `key` is stored.
    pub fn has(&self, key: &str) -> bool {
        self.load(key);
        lock(&self.inner.state).frames.get(key).is_some_and(|l| !l.is_empty())
    }

    /// Drops `key` and its file.
    pub fn remove(&self, key: &str) {
        self.load(key);
        let mut s = lock(&self.inner.state);
        s.unsaved.remove(key);
        if let Some(path) = self.file(key) {
            let _ = std::fs::remove_file(path);
        }
        s.frames.remove(key);
        s.edged.retain(|e| e.0.key != key);
        s.revision += 1;
    }

    /// The stored matte of the frame at `pts` (the last one at or before it, no further than the frame spacing away).
    pub fn matte(&self, key: &str, pts: f64) -> Option<SubjectMatte> {
        self.load(key);
        let s = lock(&self.inner.state);
        s.frames.get(key).and_then(|l| nearest(l, pts)).map(|f| f.matte.clone())
    }

    /// The matte at `pts` with the mask's edge (Feather / Expansion in px of a frame `frame_width` px wide).
    pub fn matte_with_edge(
        &self,
        key: &str,
        pts: f64,
        feather: f64,
        expansion: f64,
        frame_width: f64,
    ) -> Option<SubjectMatte> {
        self.load(key);
        let (frame, ek) = {
            let s = lock(&self.inner.state);
            let f = s.frames.get(key).and_then(|l| nearest(l, pts))?;
            (f.clone(), EdgeKey { key: key.to_string(), pts: f.pts, feather, expansion, frame_width })
        };
        if let Some(cached) = lock(&self.inner.state).edged.iter().find(|e| e.0 == ek).map(|e| e.1.clone()) {
            return Some(cached);
        }
        let out = edge(&frame.matte, feather, expansion, frame_width);
        let mut s = lock(&self.inner.state);
        // Stored again meanwhile: the new frame is edged when it is asked for.
        let still_there = s
            .frames
            .get(key)
            .is_some_and(|l| l.iter().any(|f| (f.pts - frame.pts).abs() < 1e-6 && f.matte == frame.matte));
        if still_there {
            s.edged.push((ek, out.clone()));
            if s.edged.len() > EDGED_LIMIT {
                let extra = s.edged.len() - EDGED_LIMIT;
                s.edged.drain(..extra);
            }
        }
        Some(out)
    }

    /// The mattes a layer's masks read (`RenderLayer.mattes`); a mask without a matte at `pts` is left out ("not tracked
    /// here": nothing picked).
    pub fn mattes_for(&self, fx: &ClipEffects, pts: f64, frame_width: f64) -> BTreeMap<Id, SubjectMatte> {
        let mut out = BTreeMap::new();
        for m in fx.magic_mattes().into_iter().filter(|m| !m.cache_key.is_empty()) {
            if let Some(x) = self.matte_with_edge(&m.cache_key, pts, m.feather, m.expansion, frame_width) {
                out.insert(m.mask, x);
            }
        }
        out
    }

    /// Copies the frames of `from` whose time passes `keep` to `to` (frames there at the same times are replaced): a
    /// corrected pick keeps the tracked frames the correction does not change. Returns how many moved.
    pub fn copy_frames(&self, from: &str, to: &str, keep: impl Fn(f64) -> bool) -> usize {
        self.load(from);
        self.load(to);
        let mut s = lock(&self.inner.state);
        let moved: Vec<Frame> =
            s.frames.get(from).map(|l| l.iter().filter(|f| keep(f.pts)).cloned().collect()).unwrap_or_default();
        if moved.is_empty() {
            return 0;
        }
        let mut list: Vec<Frame> = s
            .frames
            .get(to)
            .map(|l| l.iter().filter(|f| !moved.iter().any(|m| (m.pts - f.pts).abs() < 1e-6)).cloned().collect())
            .unwrap_or_default();
        let count = moved.len();
        list.extend(moved);
        list.sort_by(|a, b| a.pts.total_cmp(&b.pts));
        s.frames.insert(to.to_string(), list);
        s.edged.retain(|e| e.0.key != to);
        s.unsaved.insert(to.to_string());
        s.revision += 1;
        count
    }

    // MARK: Files

    fn file(&self, key: &str) -> Option<PathBuf> {
        self.inner.directory.as_ref().map(|d| d.join(format!("{key}.sqmatte")))
    }

    /// Reads a key's file once (frames put meanwhile win over the file's at the same time).
    pub fn load(&self, key: &str) {
        if lock(&self.inner.state).loaded.contains(key) {
            return;
        }
        let read = self.file(key).and_then(|p| std::fs::read(p).ok()).map(|d| parse(&d)).unwrap_or_default();
        let mut s = lock(&self.inner.state);
        if s.loaded.contains(key) {
            return;
        }
        s.loaded.insert(key.to_string());
        let mem = s.frames.get(key).cloned().unwrap_or_default();
        if read.is_empty() {
            return;
        }
        let mut all: Vec<Frame> =
            read.into_iter().filter(|f| !mem.iter().any(|m| (m.pts - f.pts).abs() < 1e-6)).collect();
        all.extend(mem);
        all.sort_by(|a, b| a.pts.total_cmp(&b.pts));
        s.frames.insert(key.to_string(), all);
        s.revision += 1;
    }

    /// Keys whose frames in memory are not in their file.
    pub fn unsaved_keys(&self) -> BTreeSet<String> {
        lock(&self.inner.state).unsaved.clone()
    }

    /// Writes a key's frames to its file (one writer at a time; each reads the frames when it runs).
    pub fn save(&self, key: &str) {
        self.inner.save(key);
    }

    /// `save` off the calling thread.
    // shortcut: one thread per queued key and the saves run in lock order, not strictly in queue order; each save writes the
    // frames as they are when it runs, so the order does not change a file. Upgrade to a single writer thread when many keys
    // are saved at once.
    pub fn save_later(&self, key: &str) {
        if self.inner.directory.is_none() || !lock(&self.inner.state).queued.insert(key.to_string()) {
            return;
        }
        let inner = Arc::clone(&self.inner);
        let key = key.to_string();
        let handle = thread::spawn(move || {
            lock(&inner.state).queued.remove(&key);
            inner.save(&key);
        });
        lock(&self.inner.saves).push(handle);
    }

    /// Returns when every save queued so far is in its file (quit; tests).
    pub fn wait_for_saves(&self) {
        let handles = std::mem::take(&mut *lock(&self.inner.saves));
        for h in handles {
            let _ = h.join();
        }
    }
}

impl Inner {
    fn save(&self, key: &str) {
        let Some(dir) = &self.directory else { return };
        let path = dir.join(format!("{key}.sqmatte"));
        let _writer = lock(&self.save_lock);
        let list: Vec<Frame> = {
            let mut s = lock(&self.state);
            s.unsaved.remove(key);
            s.frames.get(key).cloned().unwrap_or_default()
        };
        if list.is_empty() {
            let _ = std::fs::remove_file(&path);
            return;
        }
        let tmp = path.with_extension("sqmatte.tmp");
        if std::fs::write(&tmp, encode(&list)).is_ok() && std::fs::rename(&tmp, &path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

fn encode(list: &[Frame]) -> Vec<u8> {
    let mut out = b"SQMT".to_vec();
    out.extend(FILE_VERSION.to_le_bytes());
    out.extend((list.len() as u32).to_le_bytes());
    for f in list {
        let n = f.matte.values.len();
        out.extend(f.pts.to_le_bytes());
        out.extend((f.matte.width() as u32).to_le_bytes());
        out.extend((f.matte.height() as u32).to_le_bytes());
        out.extend((n as u32).to_le_bytes());
        out.extend(f.matte.values.iter().map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8));
    }
    out
}

/// The raw frames of a file; frames the Mac store compressed (size differs from width x height) are decoded with LZFSE.
fn parse(d: &[u8]) -> Vec<Frame> {
    let mut i = 0_usize;
    let mut take = |n: usize| -> Option<&[u8]> {
        let s = d.get(i..i.checked_add(n)?)?;
        i += n;
        Some(s)
    };
    let u32_of = |b: &[u8]| b.try_into().ok().map(u32::from_le_bytes);
    if d.len() < 12 || &d[..4] != b"SQMT" {
        return Vec::new();
    }
    take(4);
    if take(4).and_then(u32_of) != Some(FILE_VERSION) {
        return Vec::new();
    }
    let Some(count) = take(4).and_then(u32_of) else { return Vec::new() };
    let mut out = Vec::new();
    for _ in 0..count {
        let (Some(pts), Some(w), Some(h), Some(n)) = (
            take(8).and_then(|b| b.try_into().ok()).map(f64::from_le_bytes),
            take(4).and_then(u32_of),
            take(4).and_then(u32_of),
            take(4).and_then(u32_of),
        ) else {
            break;
        };
        let Some(stored) = take(n as usize) else { break };
        if w == 0 || h == 0 {
            continue;
        }
        let texels = u64::from(w) * u64::from(h);
        if texels > MAX_TEXELS {
            continue;
        }
        let size = texels as usize;
        let Some(raw) = (if stored.len() == size { Some(stored.to_vec()) } else { Lzfse::decode(stored, size) }) else {
            continue;
        };
        let values = raw.iter().map(|b| f32::from(*b) / 255.0).collect();
        out.push(Frame { pts, matte: SubjectMatte::new(w as usize, h as usize, values) });
    }
    out
}

fn nearest(list: &[Frame], pts: f64) -> Option<&Frame> {
    let t = pts + 1e-6;
    let (mut lo, mut hi) = (0, list.len());
    while lo < hi {
        let mid = (lo + hi) / 2;
        if list[mid].pts > t {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    if lo == 0 {
        return None;
    }
    let best = &list[lo - 1];
    let mut spacing = 0.05;
    if list.len() > 1 {
        spacing = f64::INFINITY;
        if lo - 1 > 0 {
            spacing = spacing.min(best.pts - list[lo - 2].pts);
        }
        if lo < list.len() {
            spacing = spacing.min(list[lo].pts - best.pts);
        }
    }
    (t - best.pts < spacing + 1e-6).then_some(best)
}

/// The Mac store's edge: positive `expansion` grows the subject, `feather` is the soft edge width (box radius feather / 2);
/// both in px of a `frame_width` px wide frame, scaled to the matte.
// Swift: FrameMatteStore.swift:253 (feather and shrink only; its tone is the identity there too)
fn edge(m: &SubjectMatte, feather: f64, expansion: f64, frame_width: f64) -> SubjectMatte {
    let scale = m.width() as f64 / frame_width.max(1.0);
    let feather = feather * scale / 2.0;
    let shrink_px = -expansion * scale;
    if shrink_px == 0.0 && feather == 0.0 {
        return m.clone();
    }
    let (w, h) = (m.width(), m.height());
    let v = MatteRefine { feather, shrink_px, ..Default::default() }.refine(&m.values, w, h);
    SubjectMatte::new(w, h, v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lzfse::mac_matte_fixture as fx;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn matte(v: f32) -> SubjectMatte {
        SubjectMatte::new(4, 4, vec![v; 16])
    }

    /// A fresh folder in the temp directory, removed when dropped.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> TempDir {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            TempDir(std::env::temp_dir().join(format!(
                "sq-matte-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            )))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_frame_is_found_at_its_time_and_not_far_after_it() {
        let store = FrameMatteStore::new(None);
        store.put("k", 1.0, matte(1.0));
        store.put("k", 1.04, matte(0.5));
        assert_eq!(store.matte("k", 1.0).map(|m| m.values[0]), Some(1.0));
        assert_eq!(store.matte("k", 1.04).map(|m| m.values[0]), Some(0.5));
        assert!(store.matte("k", 0.9).is_none()); // before the first tracked frame
        assert!(store.matte("k", 1.2).is_none()); // a hole longer than the spacing: not tracked there
        assert_eq!(store.times("k"), [1.0, 1.04]);
    }

    #[test]
    fn health_samples_are_the_coverage_of_each_stored_frame_in_time_order() {
        let store = FrameMatteStore::new(None);
        store.put("k", 2.0, matte(0.0));
        store.put("k", 1.0, matte(1.0));
        store.put("k", 3.0, matte(0.5));
        let s = store.health_samples("k");
        assert_eq!(s.iter().map(|x| x.pts).collect::<Vec<_>>(), [1.0, 2.0, 3.0]);
        assert!(s[0].area == 1.0 && s[1].area == 0.0 && (s[2].area - 0.5).abs() < 0.01);
        assert!(store.health_samples("none").is_empty());
    }

    #[test]
    fn storing_again_replaces_the_frame_and_drops_its_edged_copy() {
        let store = FrameMatteStore::new(None);
        store.put("k", 2.0, matte(1.0));
        let before = store.revision();
        let _ = store.matte_with_edge("k", 2.0, 2.0, 0.0, 4.0);
        store.put("k", 2.0, matte(0.0));
        assert!(store.revision() > before);
        assert!(store.matte_with_edge("k", 2.0, 2.0, 0.0, 4.0).is_some_and(|m| m.values.iter().all(|v| *v == 0.0)));
        store.remove("k");
        assert!(!store.has("k"));
    }

    #[test]
    fn expansion_grows_the_pick_and_no_edge_keeps_it_as_is() {
        let store = FrameMatteStore::new(None);
        let mut v = vec![0.0_f32; 64];
        v[3 * 8 + 3] = 1.0;
        store.put("k", 0.0, SubjectMatte::new(8, 8, v.clone()));
        assert_eq!(store.matte_with_edge("k", 0.0, 0.0, 0.0, 8.0).map(|m| m.values), Some(v));
        let grown = store.matte_with_edge("k", 0.0, 0.0, 1.0, 8.0).expect("matte");
        assert!(grown.values[3 * 8 + 4] == 1.0 && grown.area() > 1.0);
    }

    fn matte_2x4(v: f32) -> SubjectMatte {
        SubjectMatte::new(4, 2, vec![v; 8])
    }

    #[test]
    fn frames_come_back_from_the_file_in_another_store() {
        let dir = TempDir::new();
        let a = FrameMatteStore::new(Some(dir.0.clone()));
        a.put("k", 0.5, matte_2x4(1.0));
        a.put("k", 0.54, matte_2x4(0.0));
        a.save_later("k");
        a.wait_for_saves();
        assert!(a.unsaved_keys().is_empty());
        let b = FrameMatteStore::new(Some(dir.0.clone()));
        assert_eq!(b.times("k"), [0.5, 0.54]);
        assert!(b.matte("k", 0.5).is_some_and(|m| m.values.iter().all(|v| *v == 1.0)));
        assert!(b.matte("k", 0.54).is_some_and(|m| m.values.iter().all(|v| *v == 0.0)));
    }

    #[test]
    fn the_file_is_the_mac_format() {
        let dir = TempDir::new();
        let a = FrameMatteStore::new(Some(dir.0.clone()));
        a.put("k", 2.0, matte_2x4(1.0));
        a.save("k");
        let d = std::fs::read(dir.0.join("k.sqmatte")).expect("file");
        assert_eq!(&d[..4], b"SQMT");
        // magic 4, version 4, count 4, then pts 8, width 4, height 4, size 4, 8 bytes.
        assert_eq!(d.len(), 12 + 8 + 4 + 4 + 4 + 8);
        assert_eq!(u32::from_le_bytes([d[4], d[5], d[6], d[7]]), 2);
    }

    #[test]
    fn removing_a_key_deletes_its_file_and_copy_keeps_the_wanted_frames() {
        let dir = TempDir::new();
        let a = FrameMatteStore::new(Some(dir.0.clone()));
        for t in [1.0, 1.04, 1.08] {
            a.put("old", t, matte_2x4(1.0));
        }
        a.put("new", 1.04, matte_2x4(0.0));
        assert_eq!(a.copy_frames("old", "new", |t| t < 1.04 - 1e-6), 1);
        assert_eq!(a.times("new"), [1.0, 1.04]);
        assert_eq!(a.matte("new", 1.04).map(|m| m.values[0]), Some(0.0)); // the corrected frame is not overwritten
        a.save("new");
        a.remove("new");
        assert!(!dir.0.join("new.sqmatte").exists());
        assert!(!FrameMatteStore::new(Some(dir.0.clone())).has("new"));
    }

    #[test]
    fn a_file_of_another_version_gives_nothing() {
        let dir = TempDir::new();
        std::fs::create_dir_all(&dir.0).expect("dir");
        std::fs::write(dir.0.join("junk.sqmatte"), b"SQMT").expect("file");
        assert!(!FrameMatteStore::new(Some(dir.0.clone())).has("junk"));
    }

    #[test]
    fn a_mac_cache_file_with_compressed_frames_loads() {
        let dir = TempDir::new();
        std::fs::create_dir_all(&dir.0).expect("dir");
        let raw = fx::disc(24, 24); // a raw frame sits next to the compressed ones
        let file = fx::file(&[
            (1.0, 24, 24, fx::small()),
            (1.04, 80, 80, fx::large()),
            (1.08, 24, 24, raw),
            (1.12, 80, 80, vec![9, 9, 9]),
        ]);
        std::fs::write(dir.0.join("mac.sqmatte"), file).expect("file");
        let store = FrameMatteStore::new(Some(dir.0.clone()));
        assert_eq!(store.times("mac"), [1.0, 1.04, 1.08]); // the damaged frame alone is dropped
        let a = store.matte("mac", 1.0).expect("a");
        let b = store.matte("mac", 1.04).expect("b");
        assert_eq!(a.values, fx::disc(24, 24).iter().map(|v| f32::from(*v) / 255.0).collect::<Vec<_>>());
        assert_eq!(b.values, fx::disc(80, 80).iter().map(|v| f32::from(*v) / 255.0).collect::<Vec<_>>());
    }
}
