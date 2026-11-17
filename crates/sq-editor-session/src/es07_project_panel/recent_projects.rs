//! The start window's Recents list: newest first, one entry per file, capped (Swift `RecentProjects`).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sq_core_time::Timestamp;
use sq_core_time::text::{ci_contains, standard_compare};
use sq_library::library_folder_store::SettingsStore;

/// One remembered project file.
// Swift: RecentProjects.swift:6
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecentEntry {
    // Swift: RecentProjects.swift:7
    pub path: String,
    // Swift: RecentProjects.swift:8
    pub name: String,
    // Swift: RecentProjects.swift:9
    pub opened: Timestamp,
}

impl RecentEntry {
    // Swift: RecentProjects.swift:11
    pub fn new(path: impl Into<String>, name: impl Into<String>, opened: Timestamp) -> RecentEntry {
        RecentEntry { path: path.into(), name: name.into(), opened }
    }

    /// Identity of the entry: its path.
    // Swift: RecentProjects.swift:10
    pub fn id(&self) -> &str {
        &self.path
    }

    // Swift: RecentProjects.swift:12
    pub fn url(&self) -> PathBuf {
        PathBuf::from(&self.path)
    }
}

/// Order of the start window's Recent list.
// Swift: RecentProjects.swift:72
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecentOrder {
    Opened,
    Name,
    Size,
}

/// Newest first, one entry per file, at most [`RecentProjects::LIMIT`]. Pure value; the app persists it through
/// [`RecentProjects::save`] (key `sq.recentProjects`) and passes a file-exists check to `pruned`.
// Swift: RecentProjects.swift:4
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(from = "RecentWire", into = "RecentWire")]
pub struct RecentProjects {
    entries: Vec<RecentEntry>,
}

#[derive(Serialize, Deserialize)]
struct RecentWire {
    entries: Vec<RecentEntry>,
}

/// A saved list is normalized on load (one entry per file, capped), so a hand-edited or older default cannot break it.
impl From<RecentWire> for RecentProjects {
    // Swift: RecentProjects.swift:21
    fn from(w: RecentWire) -> RecentProjects {
        let mut seen = std::collections::BTreeSet::new();
        RecentProjects::new(w.entries.into_iter().filter(|e| seen.insert(e.path.clone())).collect())
    }
}

impl From<RecentProjects> for RecentWire {
    fn from(r: RecentProjects) -> RecentWire {
        RecentWire { entries: r.entries }
    }
}

impl RecentProjects {
    // Swift: RecentProjects.swift:14
    pub const LIMIT: usize = 12;
    /// Defaults key of the saved list.
    pub const KEY: &'static str = "sq.recentProjects";

    // Swift: RecentProjects.swift:17
    pub fn new(mut entries: Vec<RecentEntry>) -> RecentProjects {
        entries.truncate(Self::LIMIT);
        RecentProjects { entries }
    }

    // Swift: RecentProjects.swift:15
    pub fn entries(&self) -> &[RecentEntry] {
        &self.entries
    }

    /// Remembers a project: moves it to the top (no duplicates), keeps `LIMIT` entries. `path` is the standardized path.
    // Swift: RecentProjects.swift:29
    pub fn note(&mut self, path: &Path, now: Timestamp) {
        let text = sq_os::paths::plain(path);
        self.entries.retain(|e| e.path != text);
        self.entries.insert(0, RecentEntry::new(text, file_stem(path), now));
        self.entries.truncate(Self::LIMIT);
    }

    // Swift: RecentProjects.swift:35
    pub fn remove(&mut self, path: &str) {
        self.entries.retain(|e| e.path != path);
    }

    // Swift: RecentProjects.swift:37
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Paths of entries whose file is gone (the start window shows them grayed with "Locate…").
    // Swift: RecentProjects.swift:40
    pub fn missing(&self, exists: impl Fn(&str) -> bool) -> Vec<String> {
        self.entries.iter().map(|e| e.path.clone()).filter(|p| !exists(p)).collect()
    }

    /// "Locate…": the entry at `path` now lives at `url`. It keeps its place in the list; another entry already at `url`
    /// is dropped.
    // Swift: RecentProjects.swift:43
    pub fn relocate(&mut self, path: &str, url: &Path) {
        let Some(i) = self.entries.iter().position(|e| e.path == path) else { return };
        let mut moved = self.entries.remove(i);
        moved.path = sq_os::paths::plain(url);
        moved.name = file_stem(url);
        self.entries.retain(|e| e.path != moved.path);
        self.entries.insert(i.min(self.entries.len()), moved);
    }

    /// Entries whose file is still there.
    // Swift: RecentProjects.swift:53
    pub fn pruned(&self, exists: impl Fn(&str) -> bool) -> RecentProjects {
        RecentProjects::new(self.entries.iter().filter(|e| exists(&e.path)).cloned().collect())
    }

    // Swift: RecentProjects.swift:58
    pub fn load(settings: &dyn SettingsStore, key: &str) -> RecentProjects {
        settings.data(key).and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    // Swift: RecentProjects.swift:63
    pub fn save(&self, settings: &mut dyn SettingsStore, key: &str) {
        if let Ok(data) = serde_json::to_vec(self) {
            settings.set_data(key, data);
        }
    }

    /// The start window's Recent list: entries whose name contains the trimmed query (case-insensitive), in the chosen
    /// order. `Opened` keeps the stored order (newest first); `Name` is Finder-style numeric; `Size` is largest frame
    /// first, unknown sizes last, ties by most recently opened.
    // Swift: RecentProjects.swift:75
    pub fn listing(
        entries: &[RecentEntry],
        query: &str,
        order: RecentOrder,
        pixels: impl Fn(&str) -> Option<i64>,
    ) -> Vec<RecentEntry> {
        let q = query.trim();
        let mut hits: Vec<RecentEntry> =
            entries.iter().filter(|e| q.is_empty() || ci_contains(&e.name, q)).cloned().collect();
        match order {
            RecentOrder::Opened => {}
            RecentOrder::Name => hits.sort_by(|a, b| standard_compare(&a.name, &b.name)),
            RecentOrder::Size => hits.sort_by(|a, b| {
                let (pa, pb) = (pixels(&a.path).unwrap_or(0), pixels(&b.path).unwrap_or(0));
                pb.cmp(&pa).then(b.opened.partial_cmp(&a.opened).unwrap_or(std::cmp::Ordering::Equal))
            }),
        }
        hits
    }
}

/// File name without its last extension (Swift `deletingPathExtension().lastPathComponent`).
fn file_stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_library::library_folder_store::MemorySettings;

    fn at(s: f64) -> Timestamp {
        Timestamp::from_unix_seconds(s)
    }

    fn entry(name: &str, opened: f64) -> RecentEntry {
        RecentEntry::new(format!("/p/{name}.sqproj"), name, at(opened))
    }

    #[test]
    fn a_recent_never_keeps_the_verbatim_prefix() {
        let mut recents = RecentProjects::default();
        recents.note(Path::new("//?/C:/Projects/Oppo.sqproj"), at(1.0));
        assert_eq!(recents.entries()[0].path, "C:/Projects/Oppo.sqproj");
    }

    #[test]
    fn note_moves_to_top_without_duplicates_and_caps() {
        let mut r = RecentProjects::default();
        for i in 0..14 {
            r.note(Path::new(&format!("/p/{i}.sqproj")), at(i as f64));
        }
        assert_eq!(r.entries().len(), RecentProjects::LIMIT);
        r.note(Path::new("/p/5.sqproj"), at(99.0));
        assert_eq!(r.entries()[0].name, "5");
        assert_eq!(r.entries().iter().filter(|e| e.path == "/p/5.sqproj").count(), 1);
    }

    #[test]
    fn relocate_keeps_the_place_and_drops_the_target() {
        let mut r = RecentProjects::new(vec![entry("a", 3.0), entry("b", 2.0), entry("c", 1.0)]);
        r.relocate("/p/b.sqproj", Path::new("/q/c.sqproj"));
        let names: Vec<_> = r.entries().iter().map(|e| e.path.as_str()).collect();
        assert_eq!(names, ["/p/a.sqproj", "/q/c.sqproj", "/p/c.sqproj"]);
        let mut t = RecentProjects::new(vec![entry("a", 3.0), entry("b", 2.0)]);
        t.relocate("/p/a.sqproj", Path::new("/p/b.sqproj"));
        assert_eq!(t.entries().len(), 1);
    }

    #[test]
    fn missing_and_pruned_follow_the_exists_check() {
        let r = RecentProjects::new(vec![entry("a", 2.0), entry("b", 1.0)]);
        assert_eq!(r.missing(|p| p.ends_with("a.sqproj")), vec!["/p/b.sqproj".to_string()]);
        assert_eq!(r.pruned(|p| p.ends_with("a.sqproj")).entries().len(), 1);
    }

    #[test]
    fn saved_list_is_normalized_on_load() {
        let mut s = MemorySettings::default();
        let raw = r#"{"entries":[{"path":"/a","name":"a","opened":1},{"path":"/a","name":"a","opened":2},{"path":"/b","name":"b","opened":3}]}"#;
        s.set_data("k", raw.as_bytes().to_vec());
        let r = RecentProjects::load(&s, "k");
        assert_eq!(r.entries().len(), 2);
        let mut out = MemorySettings::default();
        r.save(&mut out, "k");
        assert_eq!(RecentProjects::load(&out, "k"), r);
        assert!(RecentProjects::load(&out, "other").entries().is_empty());
    }

    #[test]
    fn listing_filters_and_orders() {
        let entries = vec![entry("Clip 10", 1.0), entry("Clip 2", 2.0), entry("Tour", 3.0)];
        let px = |p: &str| match p {
            "/p/Clip 2.sqproj" => Some(100),
            "/p/Tour.sqproj" => Some(100),
            _ => None,
        };
        let names = |v: Vec<RecentEntry>| v.into_iter().map(|e| e.name).collect::<Vec<_>>();
        assert_eq!(names(RecentProjects::listing(&entries, " clip ", RecentOrder::Opened, px)), ["Clip 10", "Clip 2"]);
        assert_eq!(names(RecentProjects::listing(&entries, "", RecentOrder::Name, px)), ["Clip 2", "Clip 10", "Tour"]);
        assert_eq!(names(RecentProjects::listing(&entries, "", RecentOrder::Size, px)), ["Tour", "Clip 2", "Clip 10"]);
    }
}
