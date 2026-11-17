// Swift: LibraryPanelModel+SFX.swift
//! The Library's SFX bin: a watched folder in Application Support that is created on demand and starts empty (nothing is
//! bundled, the user adds sound files). "Whoosh at Selected Cuts" takes its sound from here.

use crate::library::library_panel_model::{LibraryModelEvent, LibraryPanelModel};
use sq_core_time::text::standard_compare;
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::watched_folder::WatchedFolder;
use std::path::{Path, PathBuf};

fn standardized(p: &Path) -> PathBuf {
    sq_os::paths::canonical(p).unwrap_or_else(|_| p.to_path_buf())
}

impl LibraryPanelModel {
    /// The bin's folder name.
    pub const SFX_BIN_NAME: &'static str = "SFX";

    /// The SFX bin when it exists in the Library.
    pub fn sfx_folder(&self) -> Option<WatchedFolder> {
        let dir = standardized(self.sfx_directory.as_deref()?);
        self.folders().iter().find(|f| standardized(&f.folder.url) == dir).map(|f| f.folder.clone())
    }

    /// Creates the bin (folder on disk and Library entry) when it does not exist yet, without changing the selection.
    pub fn ensure_sfx_bin(&mut self) -> Option<WatchedFolder> {
        if let Some(f) = self.sfx_folder() {
            return Some(f);
        }
        let dir = self.sfx_directory.clone()?;
        std::fs::create_dir_all(&dir).ok()?;
        let folder = WatchedFolder::new(self.ids.next_id(), dir, Some(Self::SFX_BIN_NAME), None);
        self.restore_folders(vec![folder]);
        let all: Vec<WatchedFolder> = self.folders().iter().map(|f| f.folder.clone()).collect();
        self.push_event(LibraryModelEvent::FoldersChanged(all));
        self.sfx_folder()
    }

    /// Copies audio files into the SFX bin (creating it first); name clashes get a number. Returns the files copied.
    pub fn add_to_sfx_bin(&mut self, urls: &[PathBuf]) -> usize {
        let Some(folder) = self.ensure_sfx_bin() else { return 0 };
        let mut copied = 0;
        for url in urls {
            if LibraryItemKind::classify(url, false) != LibraryItemKind::Audio {
                continue;
            }
            if url.parent().map(standardized) == Some(standardized(&folder.url)) {
                continue;
            }
            let file = url.file_name().map(PathBuf::from).unwrap_or_default();
            let mut dest = folder.url.join(&file);
            let mut n = 2;
            while dest.exists() {
                let base = url.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                let ext = url.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
                dest = folder.url.join(format!("{base} {n}{ext}"));
                n += 1;
            }
            if std::fs::copy(url, &dest).is_ok() {
                copied += 1;
            }
        }
        if copied > 0 {
            self.rescan(folder.id);
        }
        copied
    }

    /// Audio files of the SFX bin by name.
    pub fn sfx_sounds(&self) -> Vec<PathBuf> {
        let Some(f) = self.sfx_folder() else { return Vec::new() };
        let mut audio: Vec<_> = self.entries(f.id).iter().filter(|e| e.kind == LibraryItemKind::Audio).collect();
        audio.sort_by(|a, b| standard_compare(a.name(), b.name()));
        audio.iter().map(|e| e.url(&f)).collect()
    }

    /// Remembers the whoosh the user picked (from the Library item menu).
    pub fn choose_whoosh(&mut self, url: &Path) {
        self.whoosh_defaults.set_string(Self::LAST_WHOOSH_KEY, &url.to_string_lossy());
    }

    /// The sound "Whoosh at Selected Cuts" uses from the Sequence menu: the last chosen one while it is still in the bin,
    /// else the bin's first audio file. None when the bin is empty or missing.
    pub fn whoosh_sound(&self) -> Option<PathBuf> {
        let sounds = self.sfx_sounds();
        if let Some(path) = self.whoosh_defaults.string(Self::LAST_WHOOSH_KEY)
            && let Some(hit) = sounds.iter().find(|s| s.to_string_lossy() == path)
        {
            return Some(hit.clone());
        }
        sounds.into_iter().next()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::library_panel_model::{LibraryPanelDeps, UnavailablePreviewProvider};
    use crate::test_support::MemoryDefaults;
    use sq_core_project::cache_disk_policy::CacheDiskPolicy;
    use sq_core_time::{SequentialIds, Timestamp};
    use sq_library::folder_scanner::FolderScanner;
    use sq_library::folder_watching::FakeFolderWatcher;
    use sq_library::library_index::LibraryIndex;
    use sq_library::preset_store::PresetStore;
    use sq_library::preview_requests::{PreviewCache, PreviewCoordinator};

    fn model(root: &Path) -> LibraryPanelModel {
        let now = Timestamp::from_unix_seconds(0.0);
        let mut m = LibraryPanelModel::new(LibraryPanelDeps {
            index: LibraryIndex::new(FolderScanner::default(), Box::new(FakeFolderWatcher::new())),
            preset_store: PresetStore::open(&root.join("support"), false, now).expect("store"),
            coordinator: PreviewCoordinator::new(PreviewCache::in_caches_directory(
                &root.join("caches"),
                PreviewCache::DEFAULT_BYTE_CAP,
                CacheDiskPolicy::unchecked(),
            )),
            provider: Box::new(UnavailablePreviewProvider),
            favorites_url: root.join("favorites.json"),
            ids: Box::new(SequentialIds::default()),
            clock: Box::new(|| Timestamp::from_unix_seconds(0.0)),
            whoosh_defaults: Box::new(MemoryDefaults::default()),
        });
        m.sfx_directory = Some(root.join("SFX"));
        m.start();
        m
    }

    #[test]
    fn the_sfx_bin_is_made_on_demand_and_copies_audio_with_numbered_names() {
        let root = std::env::temp_dir().join(format!("libsfx-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("root");
        let src = root.join("whoosh.wav");
        std::fs::write(&src, b"x").expect("wav");
        let pic = root.join("a.png");
        std::fs::write(&pic, b"x").expect("png");
        let mut m = model(&root);
        assert!(m.sfx_folder().is_none() && m.whoosh_sound().is_none());
        assert_eq!(m.add_to_sfx_bin(&[src.clone(), src.clone(), pic]), 2);
        assert!(root.join("SFX").join("whoosh.wav").exists() && root.join("SFX").join("whoosh 2.wav").exists());
        assert_eq!(m.sfx_sounds().len(), 2);
        assert_eq!(m.whoosh_sound(), m.sfx_sounds().first().cloned());
        let second = m.sfx_sounds()[1].clone();
        m.choose_whoosh(&second);
        assert_eq!(m.whoosh_sound(), Some(second));
        assert_eq!(m.take_events().len(), 1); // the bin was reported to the host once
        let _ = std::fs::remove_dir_all(&root);
    }
}
