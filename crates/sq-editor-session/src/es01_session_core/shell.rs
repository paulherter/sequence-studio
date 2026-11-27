//! Shell commands of the session: close project, autosave versions, relink and locate media.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use sq_core_model::MediaStatus;
use sq_core_project::media_path_resolver::{MediaPathResolver, RelinkScanner};
use sq_core_project::recovery::AutosaveVersion;
use sq_core_project::relink::RelinkPlanner;
use sq_core_time::Id;
use sq_playback::engine::preview_rate::PreviewRate;

use crate::{EditorSession, SaveError};

/// What a relink pass did: how many items it relinked, how many were offline, how many it left because the size differs.
// Swift: EditorSession+Shell.swift:59
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RelinkOutcome {
    // Swift: EditorSession+Shell.swift:62
    pub relinked: i64,
    // Swift: EditorSession+Shell.swift:63
    pub offline: i64,
    // Swift: EditorSession+Shell.swift:65
    pub size_differs: i64,
}

impl EditorSession {
    /// Close Project: the empty state before a project is chosen.
    // Swift: EditorSession+Shell.swift:30
    pub fn close_project(&mut self) {
        self.preview_rate = PreviewRate::NORMAL;
        let empty = EditorSession::make_empty(self.ids.as_mut());
        self.new_project(empty);
    }

    /// An untouched, unsaved, empty project (the launch state or after Close Project).
    // Swift: EditorSession+Shell.swift:33
    pub fn is_empty_untitled(&self) -> bool {
        self.file_url.is_none()
            && !self.is_dirty()
            && self.project().media.is_empty()
            && self.project().timelines.iter().all(|t| t.tracks.iter().all(|tr| tr.clips().is_empty()))
    }

    /// Seconds between timed autosave versions (30 s to 1 h; other values are ignored).
    // Swift: EditorSession+Shell.swift:40
    pub fn set_autosave_interval(&mut self, seconds: f64) {
        if seconds.is_finite() && (30.0..=3600.0).contains(&seconds) {
            self.autosave_store.policy.interval = seconds;
        }
    }

    /// Seconds between timed autosave versions now in force.
    pub fn autosave_interval(&self) -> f64 {
        self.autosave_store.policy.interval
    }

    /// How long a listing of the autosave folder serves the menus (they ask on every frame; on Windows one listing of the
    /// folder took 13 to 50 ms of the UI thread). Only changes from outside wait this long: every write or delete the app
    /// does itself bumps `autosave_generation`, which drops the listing at once.
    const AUTOSAVE_LISTING_TTL: std::time::Duration = std::time::Duration::from_secs(2);

    /// The autosave versions of this project, newest first (a listing at most `AUTOSAVE_LISTING_TTL` old and never older
    /// than the app's own last write).
    // Swift: EditorSession+Shell.swift:46
    pub fn autosave_versions(&self) -> Vec<AutosaveVersion> {
        self.autosave_versions_at(std::time::Instant::now())
    }

    pub(crate) fn autosave_versions_at(&self, now: std::time::Instant) -> Vec<AutosaveVersion> {
        let id = self.project().id;
        let generation = self.autosave_generation.load(std::sync::atomic::Ordering::Acquire);
        let mut cache = self.autosave_listing.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(l) = cache.as_ref()
            && l.project == id
            && l.generation == generation
            && now.saturating_duration_since(l.at) < Self::AUTOSAVE_LISTING_TTL
        {
            return l.versions.clone();
        }
        // The generation read before the listing: a write that lands while the folder is read invalidates it again.
        let versions = self.autosave_store.versions(id);
        *cache = Some(crate::session::AutosaveListing { at: now, generation, project: id, versions: versions.clone() });
        versions
    }

    /// The folder changed through this session (a version written or deleted): the cached listing is stale.
    pub(crate) fn forget_autosave_listing(&self) {
        self.autosave_generation.fetch_add(1, std::sync::atomic::Ordering::Release);
    }

    /// Replaces the project by an autosave version: one undo step.
    // Swift: EditorSession+Shell.swift:50
    pub fn restore_autosave(&mut self, version: &AutosaveVersion) -> Result<(), sq_core_file::ProjectFileError> {
        self.forget_autosave_listing();
        let restored = self.autosave_store.read(version)?; // the caller reports the error
        self.perform("Restore Autosave Version", None, |p| *p = restored);
        Ok(())
    }

    /// Whether any media is missing.
    // Swift: EditorSession+Shell.swift:59
    pub fn can_relink(&self) -> bool {
        self.with_missing_media(|m| !m.is_empty())
    }

    /// Searches `folder` for the missing media by file name and relinks what matches.
    // Swift: EditorSession+Shell.swift:69
    pub fn relink_missing(&mut self, folder: &Path) -> RelinkOutcome {
        self.relink_missing_in(&[folder.to_path_buf()], true)
    }

    /// `relink_missing` over several folders; `undoable` false relinks quietly (no undo step).
    // Swift: EditorSession+Shell.swift:75
    pub fn relink_missing_in(&mut self, folders: &[PathBuf], undoable: bool) -> RelinkOutcome {
        let missing = self.missing_media();
        if missing.is_empty() || folders.is_empty() {
            return RelinkOutcome { offline: missing.len() as i64, ..RelinkOutcome::default() };
        }
        let wanted: BTreeSet<String> =
            missing.iter().map(|m| MediaPathResolver::file_name_of(&m.path).to_lowercase()).collect();
        let found = RelinkScanner::scan(folders, &wanted);
        let result = RelinkPlanner::match_(&missing, &found);
        if !result.plan.is_empty() {
            self.stop_playback();
            if undoable {
                self.relink_media(&result.plan, "Relink Media");
            } else {
                self.relink_media_quietly(&result.plan);
            }
        }
        RelinkOutcome {
            relinked: result.plan.len() as i64,
            offline: missing.len() as i64,
            size_differs: result.size_mismatch.len() as i64,
        }
    }

    /// Saves under a new name without keeping the watched-folder policy of the old project.
    // Swift: EditorSession+Shell.swift:94
    pub fn save_as_without_watching(&mut self, url: &Path) -> Result<(), Box<dyn std::error::Error>> {
        let had_watch = self.project().media_policy.as_ref().is_some_and(|m| m.watch_folder == Some(true));
        let was_flagged = self.force_dirty;
        let project_id = self.project().id;
        if had_watch {
            self.amend_project(|p| {
                if let Some(m) = p.media_policy.as_mut() {
                    m.watch_folder = Some(false);
                }
            });
        }
        if let Err(e) = self.save_as(url) {
            // Another project was opened meanwhile: it keeps its own setting and dirty flag.
            let changed = e.downcast_ref::<SaveError>() == Some(&SaveError::ProjectChanged);
            if changed || self.project().id != project_id {
                return Err(e);
            }
            if had_watch {
                self.amend_project(|p| {
                    if let Some(m) = p.media_policy.as_mut() {
                        m.watch_folder = Some(true);
                    }
                });
                self.force_dirty = was_flagged;
            }
            return Err(e);
        }
        Ok(())
    }

    /// Points one missing item at a file the user picked. False when the item is not missing.
    // Swift: EditorSession+Shell.swift:109
    pub fn locate_media(&mut self, id: Id, url: &Path) -> bool {
        if !self.project().media(id).is_some_and(|m| m.status() == MediaStatus::Missing) {
            return false;
        }
        self.stop_playback();
        let mut paths = BTreeMap::new();
        paths.insert(id, url.to_string_lossy().into_owned());
        self.relink_media(&paths, "Locate Media");
        true
    }

    /// The other missing items whose files lie in `folder` (the user located one; offer the rest).
    // Swift: EditorSession+Shell.swift:120
    pub fn missing_siblings(&self, folder: &Path, excluding: Id) -> BTreeMap<Id, String> {
        let others: Vec<_> = self.missing_media().into_iter().filter(|m| m.id != excluding).collect();
        if others.is_empty() {
            return BTreeMap::new();
        }
        let wanted: BTreeSet<String> =
            others.iter().map(|m| MediaPathResolver::file_name_of(&m.path).to_lowercase()).collect();
        let found = RelinkScanner::scan_roots(&[(folder.to_path_buf(), 0)], &wanted);
        RelinkPlanner::match_(&others, &found).plan
    }

    /// Relinks the items of a plan the user accepted: one undo step.
    // Swift: EditorSession+Shell.swift:129
    pub fn relink_siblings(&mut self, plan: &BTreeMap<Id, String>) {
        if plan.is_empty() {
            return;
        }
        self.stop_playback();
        self.relink_media(plan, "Relink Media");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    use crate::SessionDeps;

    fn session(name: &str) -> EditorSession {
        let mut ids = SequentialIds::default();
        let dir = std::env::temp_dir().join(format!("sq-es01-shell-{name}-{}", std::process::id()));
        EditorSession::new(EditorSession::make_untitled(&mut ids), SessionDeps::headless(dir))
    }

    #[test]
    fn empty_untitled_until_something_changes() {
        let mut s = session("empty");
        assert!(s.is_empty_untitled());
        s.perform("Rename", None, |p| p.name = "A".into());
        assert!(!s.is_empty_untitled());
        s.close_project();
        assert!(s.is_empty_untitled() && s.active_timeline_id().is_none());
    }

    #[test]
    fn autosave_interval_accepts_only_sensible_values() {
        let mut s = session("interval");
        let before = s.autosave_store.policy.interval;
        s.set_autosave_interval(5.0);
        s.set_autosave_interval(f64::NAN);
        s.set_autosave_interval(7200.0);
        assert_eq!(s.autosave_store.policy.interval, before);
        s.set_autosave_interval(60.0);
        assert_eq!(s.autosave_store.policy.interval, 60.0);
    }

    #[test]
    fn restore_autosave_is_one_undo_step() {
        let mut s = session("restore");
        s.perform("Rename", None, |p| p.name = "Old".into());
        assert!(s.tick_autosave());
        s.perform("Rename", None, |p| p.name = "New".into());
        let v = s.autosave_versions().into_iter().next().expect("version");
        assert!(s.restore_autosave(&v).is_ok());
        assert_eq!((s.project().name.as_str(), s.undo_name()), ("Old", Some("Restore Autosave Version")));
        assert!(!s.can_relink());
        assert!(!s.locate_media(Id::from_u128(5), Path::new("/x")));
    }

    #[test]
    fn offline_check_does_not_stat_per_call() {
        let mut s = session("stat-cache");
        let path = std::env::temp_dir().join(format!("sq-stat-cache-{}.bin", std::process::id()));
        std::fs::write(&path, b"x").unwrap();
        let p = path.to_string_lossy().to_string();
        s.perform("Add", None, |pr| {
            let fp = sq_core_model::MediaFingerprint { size: 1, modified: None, head_hash: None };
            pr.media.push(sq_core_model::MediaRef::new(Id::from_u128(77), "a", &p, fp));
        });
        // Counts as one stat pass: online.
        assert!(!s.can_relink());
        std::fs::remove_file(&path).unwrap();
        // The file is gone, but nothing was notified and the TTL has not run out: no new stat() pass.
        for _ in 0..100 {
            assert!(!s.can_relink());
        }
        // A project change invalidates the cache.
        s.notify(crate::Change::PROJECT);
        assert!(s.can_relink());
    }
}
