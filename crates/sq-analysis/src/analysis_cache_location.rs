// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnalysisCacheLocation.swift
//! Where the analysis caches (stabilization, subject masks, Magic and subject mattes) live. The app points it at `<cache
//! folder>` (Settings > Media) at launch and on a folder change; before that, and in tests, every cache sits where it always
//! did. Existing files are not moved; entries are rebuilt on demand. The matte stores are created once per launch, so a
//! folder change reaches them at the next launch.
use sq_os::Platform;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

static CONFIGURED: Mutex<Option<PathBuf>> = Mutex::new(None);

fn configured() -> MutexGuard<'static, Option<PathBuf>> {
    CONFIGURED.lock().unwrap_or_else(|e| e.into_inner())
}

/// The user's cache folder (Swift `FileManager.urls(for: .cachesDirectory)`), see `Platform::cache_dir`.
fn caches_directory() -> Option<PathBuf> {
    Platform::current().cache_dir(|name| std::env::var_os(name))
}

/// Where the analysis caches live.
pub struct AnalysisCacheLocation;

impl AnalysisCacheLocation {
    /// `None`: the historic default (`~/Library/Caches/Sequence Studio`, mattes under the bundle identifier).
    pub fn configure(root: Option<PathBuf>) {
        *configured() = root;
    }

    /// The configured root.
    pub fn configured_root() -> Option<PathBuf> {
        configured().clone()
    }

    /// `<root>/<name>` when a root is configured, else the legacy folder.
    pub fn directory(name: &str, legacy: impl FnOnce() -> Option<PathBuf>) -> Option<PathBuf> {
        match Self::configured_root() {
            Some(root) => Some(root.join(name)),
            None => legacy(),
        }
    }

    /// Legacy matte folder: `<caches>/Sequence Studio/<name>` (an older `<caches>/SequenceStudio/<name>` is moved there once).
    pub fn legacy_bundle_directory(name: &str) -> Option<PathBuf> {
        caches_directory().map(|c| sq_os::app_folders::app_subfolder(&c, name))
    }

    /// `<caches>/Sequence Studio/<name>` (temp when caches are unavailable).
    pub fn legacy_shared_directory(name: &str) -> PathBuf {
        sq_os::app_folders::app_subfolder(&caches_directory().unwrap_or_else(std::env::temp_dir), name)
    }

    /// Folder `name` of the shared analysis cache.
    pub fn shared_directory(name: &str) -> PathBuf {
        match Self::configured_root() {
            Some(root) => root.join(name),
            None => Self::legacy_shared_directory(name),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as TestLock;

    /// The root is process-wide: tests that set it run one at a time.
    static SERIAL: TestLock<()> = TestLock::new(());

    #[test]
    fn configured_root_decides_the_folders() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let root = PathBuf::from("/Volumes/Fast/C");
        AnalysisCacheLocation::configure(Some(root.clone()));
        assert_eq!(AnalysisCacheLocation::shared_directory("Stabilizer"), root.join("Stabilizer"));
        assert_eq!(AnalysisCacheLocation::directory("MagicMattes", || None), Some(root.join("MagicMattes")));
        AnalysisCacheLocation::configure(None);
    }

    #[test]
    fn without_a_root_the_historic_folders_stay() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        AnalysisCacheLocation::configure(None);
        assert!(AnalysisCacheLocation::shared_directory("Stabilizer").ends_with("Sequence Studio/Stabilizer"));
        assert_eq!(
            AnalysisCacheLocation::directory("MagicMattes", || Some(PathBuf::from("/legacy"))),
            Some(PathBuf::from("/legacy"))
        );
    }
}
