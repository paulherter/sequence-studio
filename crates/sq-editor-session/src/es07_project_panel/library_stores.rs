//! The app's Application Support folder and its one preset store (Swift `LibraryStores`).

use std::path::{Path, PathBuf};

use sq_core_time::Timestamp;
use sq_library::favorites::LibraryStoreError;
use sq_library::preset_store::PresetStore;

/// Where the app keeps its files; the preset store is owned by the app and passed to the session code as a parameter
/// (CONVENTIONS: no `.shared` singletons in the session).
// Swift: LibraryStores.swift:5
pub enum LibraryStores {}

impl LibraryStores {
    /// `<Application Support>/Sequence Studio` (AppData on Windows); `base` is the platform's Application Support root,
    /// which the shell knows (this crate has no platform code).
    // Swift: LibraryStores.swift:7
    pub fn support_directory(application_support: &Path) -> PathBuf {
        application_support.join("Sequence Studio")
    }

    /// The one preset store of the app (Library panel, easing presets, effect presets): one store per file, so two stores
    /// never overwrite each other's presets.json. The app creates it once and passes it on (no singleton). When the store
    /// cannot be opened, a stand-in below `fallback_root` (a temporary folder) is used, as in Swift.
    // Swift: LibraryStores.swift:14
    pub fn preset_store(
        application_support: &Path,
        fallback_root: &Path,
        now: Timestamp,
    ) -> Result<PresetStore, LibraryStoreError> {
        PresetStore::open(application_support, false, now).or_else(|_| PresetStore::open(fallback_root, true, now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_store_opens_below_the_root_and_falls_back_to_a_stand_in() {
        let dir = std::env::temp_dir().join(format!("sq-es07-presets-{}", std::process::id()));
        let now = Timestamp::from_reference_seconds(0.0);
        let store = LibraryStores::preset_store(&dir, &dir, now).expect("store");
        assert_eq!(store.file_url(), PresetStore::file_url_in(&dir));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn support_directory_is_below_the_root() {
        assert_eq!(
            LibraryStores::support_directory(std::path::Path::new("/a")),
            std::path::Path::new("/a/Sequence Studio")
        );
    }
}
