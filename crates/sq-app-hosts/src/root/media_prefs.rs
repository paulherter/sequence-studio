//! Preferences > Media in the running app (Swift `SharedUILibrary.wirePreferencesLibrary` and `refreshUsed`): the Library
//! Folders list, Add Folder, Remove, Delete Cache, the cache size line and the proxy copy after a folder change.

use super::AppRoot;
use sq_draw_shell::{ShellHost as DrawShell, ShellLibraryFolder};
use sq_editor_session::{AppSettings, EditorSession, StorageFolderChoice};
use sq_library::library_index::FolderState;
use sq_uikit::sqbyte_size::SQByteSize;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};

/// The cache size line (`ShellPreferences.refreshUsed`): the cache folder, plus the proxy folder when it lies outside.
pub(crate) fn cache_used_text(cache: &Path, proxies: &Path) -> String {
    let mut bytes = DrawShell::cache_folder_size(cache);
    if !proxies.starts_with(cache) {
        bytes += DrawShell::cache_folder_size(proxies);
    }
    if bytes == 0 { "Empty".to_string() } else { SQByteSize::string(bytes) }
}

/// Delete Cache: everything in the cache folder except the proxy folder (the proxies go through the proxy cache itself).
pub(crate) fn clear_cache_folder(cache: &Path, proxies: &Path) {
    let keep = sq_os::paths::canonical(proxies).unwrap_or_else(|_| proxies.to_path_buf());
    let Ok(items) = std::fs::read_dir(cache) else { return };
    for item in items.flatten() {
        let path = item.path();
        if sq_os::paths::canonical(&path).unwrap_or_else(|_| path.clone()) == keep {
            continue;
        }
        // shortcut: a file that cannot be removed (in use) stays; the size line then still shows it.
        let _ = if path.is_dir() { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
    }
}

/// Where the cache size line stands: one state, so no flags can disagree.
pub(crate) enum CacheUsed {
    /// Not asked yet.
    Unknown,
    /// A worker adds up the folders.
    Counting(Receiver<String>),
    /// The text shows.
    Known,
}

impl AppRoot {
    /// The Library Folders rows and the cache size line as the Preferences page reads them.
    pub(super) fn sync_media_prefs(&mut self) {
        let rows: Vec<ShellLibraryFolder> = self
            .library
            .panel_host()
            .panel
            .model
            .folders()
            .iter()
            .map(|f| ShellLibraryFolder {
                id: f.folder.id.to_string(),
                name: f.folder.display_name.clone(),
                path: sq_os::paths::tilde_here(&f.folder.url),
                offline: f.state == FolderState::Offline,
            })
            .collect();
        let roots: Vec<_> = self
            .library
            .panel_host()
            .panel
            .model
            .folders()
            .iter()
            .map(|f| std::path::PathBuf::from(&f.folder.url))
            .collect();
        let shell = self.shell.shell();
        // The import rules treat files below these folders as Library items.
        if shell.outside_media.library_roots != roots {
            shell.outside_media.library_roots = roots;
        }
        if shell.preferences.library_folders.as_ref() != Some(&rows) {
            shell.preferences.library_folders = Some(rows);
        }
        match &self.cache_used {
            CacheUsed::Unknown => self.count_cache(),
            CacheUsed::Counting(rx) => {
                if let Ok(text) = rx.try_recv() {
                    self.shell.shell().preferences.cache_used = Some(text);
                    self.cache_used = CacheUsed::Known;
                }
            }
            CacheUsed::Known => {}
        }
    }

    /// Adds the cache folders up on a worker (`refreshUsed`).
    fn count_cache(&mut self) {
        let shell = self.shell.shell();
        let settings = AppSettings::load(&*shell.defaults);
        let (cache, proxies) = (settings.effective_cache_folder(), settings.proxy_cache_directory(&*shell.defaults));
        shell.preferences.cache_used = Some("Calculating…".to_string());
        let (tx, rx) = channel();
        let wake = self.wake.clone();
        std::thread::spawn(move || {
            let _ = tx.send(cache_used_text(&cache, &proxies));
            // Nothing else redraws the idle window: "Calculating…" would stay until the next input.
            if let Some(wake) = wake {
                wake();
            }
        });
        self.cache_used = CacheUsed::Counting(rx);
    }

    /// Add Folder…: the Library watches the folder (the model's change event saves the list).
    pub(super) fn add_library_folder(&mut self, url: PathBuf) {
        // shortcut: no security-scoped bookmark (the Mac sandbox build only); the plain path is stored.
        self.library.panel_host().panel.model.add_folder(url, None);
        self.sync_media_prefs();
    }

    /// Remove: the Library stops watching the folder with this id.
    pub(super) fn remove_library_folder(&mut self, id: &str) {
        let model = &mut self.library.panel_host().panel.model;
        if let Some(found) = model.folders().iter().find(|f| f.folder.id.to_string() == id).map(|f| f.folder.id) {
            model.remove_folder(found);
        }
        self.sync_media_prefs();
    }

    /// Delete Cache: the proxy cache and everything else in the cache folder, then the size line again.
    pub(super) fn clear_cache(&mut self, session: &mut EditorSession) {
        session.clear_proxy_cache();
        let shell = self.shell.shell();
        let settings = AppSettings::load(&*shell.defaults);
        clear_cache_folder(&settings.effective_cache_folder(), &settings.proxy_cache_directory(&*shell.defaults));
        self.cache_used = CacheUsed::Unknown;
    }

    /// The cache folder changed: the proxies made so far are copied over, never moved (`PreferenceChoices`).
    pub(super) fn move_proxies(&mut self, from: &Path, to: &Path) {
        StorageFolderChoice::migrate_in_background(from, to);
        self.cache_used = CacheUsed::Unknown;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delete_cache_keeps_the_proxy_folder_and_removes_the_rest() {
        let dir = crate::test_rig::unique_dir("sq-app-hosts-clear-cache");
        let (proxies, previews) = (dir.join("Proxies"), dir.join("Previews"));
        std::fs::create_dir_all(&proxies).expect("dir");
        std::fs::create_dir_all(&previews).expect("dir");
        std::fs::write(proxies.join("p.mov"), b"proxy").expect("file");
        std::fs::write(previews.join("a.png"), b"x").expect("file");
        std::fs::write(dir.join("loose.bin"), b"y").expect("file");
        clear_cache_folder(&dir, &proxies);
        assert!(proxies.join("p.mov").exists());
        assert!(!previews.exists() && !dir.join("loose.bin").exists());
        assert_eq!(cache_used_text(&dir, &proxies), "5 bytes");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod wake_tests {
    use super::super::menu_click_tests::new_root;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    /// The cache size is counted on a worker: the idle window has to be woken when the number is ready, or the Media
    /// preferences keep saying "Calculating…" until the next input.
    #[test]
    fn the_cache_count_wakes_the_idle_window_when_it_is_ready() {
        let (mut root, _rig) = new_root();
        let wakes = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&wakes);
        root.set_wake(Arc::new(move || {
            counted.fetch_add(1, Ordering::SeqCst);
        }));
        root.sync_media_prefs();
        let end = Instant::now() + Duration::from_secs(10);
        while wakes.load(Ordering::SeqCst) == 0 && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(wakes.load(Ordering::SeqCst) > 0, "the finished count did not wake the window loop");
        root.sync_media_prefs();
        let shown = root.shell.shell().preferences.cache_used.clone();
        assert_ne!(shown.as_deref(), Some("Calculating…"), "the woken frame still shows the old text");
    }
}
