// Swift: LibraryDrawServices.swift
//! Production wiring of the Library model for the shared draw UI: the same files in Application Support as the Mac
//! `LibraryServices` (favorites, watched folders, presets, SFX bin), with the platform's folder watcher and preview
//! provider.
//!
//! The app hands in the platform's `FolderWatching` (`sq_library::folder_watching::NotifyFolderWatcher`: OS file events).

use crate::library::library_panel_model::{LibraryPanelDeps, LibraryPanelModel};
use sq_library::library_folder_store::{LibraryFolderStore, SettingsStore};
use sq_library::watched_folder::WatchedFolder;

/// Wiring of the Library model.
pub enum LibraryDrawServices {}

impl LibraryDrawServices {
    /// The model is not running yet: call `start`.
    pub fn make_model(deps: LibraryPanelDeps) -> LibraryPanelModel {
        let support = deps.favorites_url.parent().map(std::path::Path::to_path_buf).unwrap_or_default();
        let _ = std::fs::create_dir_all(&support);
        let mut model = LibraryPanelModel::new(deps);
        model.sfx_directory = Some(support.join("SFX"));
        model
    }

    /// Restores the saved watched folders, then loads favorites, presets and the index.
    pub fn start(model: &mut LibraryPanelModel, settings: &mut dyn SettingsStore) {
        let folders = LibraryFolderStore::load(settings);
        if !folders.is_empty() {
            model.restore_folders(folders);
        }
        model.register_installed_pack_fonts();
        model.start();
    }

    /// Saves the watched folders (the Swift `onFoldersChanged` of `makeModel`).
    pub fn persist_folders(folders: &[WatchedFolder], settings: &mut dyn SettingsStore) {
        LibraryFolderStore::save(folders, settings);
    }
}
