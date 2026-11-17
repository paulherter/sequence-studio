// Swift: FolderWatching.swift
//! The seam to the file system watcher. The app implements `FolderWatching` (FSEvents, `notify`); this crate has no OS code.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// Called when something changed under the folder (the implementation coalesces bursts).
pub type ChangeCallback = Arc<dyn Fn() + Send + Sync>;

/// Cancels a running watch. Idempotent.
pub trait FolderWatchToken: Send {
    /// Stops the watch; calling it again does nothing.
    fn cancel(&self);
}

/// Reports "something changed under this folder" (coalesced by the implementation).
pub trait FolderWatching: Send + Sync {
    /// Starts watching `path`; `on_change` may run on any thread.
    fn watch(&self, path: &Path, on_change: ChangeCallback) -> Box<dyn FolderWatchToken>;
}

type Handlers = Arc<Mutex<HashMap<u64, (PathBuf, ChangeCallback)>>>;

fn lock(handlers: &Handlers) -> MutexGuard<'_, HashMap<u64, (PathBuf, ChangeCallback)>> {
    handlers.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Test double: call `fire(path)` to simulate a change.
#[derive(Default)]
pub struct FakeFolderWatcher {
    handlers: Handlers,
    next: Mutex<u64>,
}

impl FakeFolderWatcher {
    /// A watcher with nothing watched.
    pub fn new() -> FakeFolderWatcher {
        FakeFolderWatcher::default()
    }

    /// Number of running watches.
    pub fn active_count(&self) -> usize {
        lock(&self.handlers).len()
    }

    /// Reports a change under `path` to every watch of exactly that folder.
    pub fn fire(&self, path: &Path) {
        let targets: Vec<ChangeCallback> =
            lock(&self.handlers).values().filter(|(p, _)| p == path).map(|(_, f)| Arc::clone(f)).collect();
        for f in targets {
            f();
        }
    }
}

impl FolderWatching for FakeFolderWatcher {
    fn watch(&self, path: &Path, on_change: ChangeCallback) -> Box<dyn FolderWatchToken> {
        let id = {
            let mut next = self.next.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            *next += 1;
            *next
        };
        lock(&self.handlers).insert(id, (path.to_path_buf(), on_change));
        Box::new(FakeToken { handlers: Arc::clone(&self.handlers), id })
    }
}

struct FakeToken {
    handlers: Handlers,
    id: u64,
}

impl FolderWatchToken for FakeToken {
    fn cancel(&self) {
        lock(&self.handlers).remove(&self.id);
    }
}

/// The real watcher: the OS file events (FSEvents on the Mac, inotify on Linux, ReadDirectoryChangesW on Windows through
/// `notify`), coalesced like the FSEvents latency of Swift's `FSEventsFolderWatcher`: a burst of events within `latency`
/// is one `on_change` call.
pub struct NotifyFolderWatcher {
    latency: std::time::Duration,
}

impl Default for NotifyFolderWatcher {
    /// One second, the latency of Swift's `FSEventsFolderWatcher`.
    fn default() -> NotifyFolderWatcher {
        NotifyFolderWatcher { latency: std::time::Duration::from_secs(1) }
    }
}

impl NotifyFolderWatcher {
    /// A watcher that coalesces events within `latency`.
    pub fn new(latency: std::time::Duration) -> NotifyFolderWatcher {
        NotifyFolderWatcher { latency }
    }
}

/// Owns the OS watcher and the coalescing thread; cancelling (or dropping) stops both.
struct NotifyToken {
    inner: Mutex<Option<(notify::RecommendedWatcher, std::sync::mpsc::Sender<()>)>>,
}

impl FolderWatchToken for NotifyToken {
    fn cancel(&self) {
        // Dropping the watcher closes the event channel, which ends the coalescing thread.
        let taken = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        drop(taken);
    }
}

impl FolderWatching for NotifyFolderWatcher {
    fn watch(&self, path: &Path, on_change: ChangeCallback) -> Box<dyn FolderWatchToken> {
        use notify::Watcher;
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let sender = tx.clone();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            // Access events (a file merely read) are not changes.
            if event.is_ok_and(|e| !e.kind.is_access()) {
                let _ = sender.send(());
            }
        });
        let started = watcher.and_then(|mut w| w.watch(path, notify::RecursiveMode::Recursive).map(|()| w));
        let Ok(watcher) = started else {
            // The folder is simply not watched, as with a failing FSEvents stream.
            return Box::new(NotifyToken { inner: Mutex::new(None) });
        };
        let latency = self.latency;
        let spawned = std::thread::Builder::new().name("folder-watch".into()).spawn(move || {
            // The thread ends when every sender is gone: the watcher's callback (dropped with the watcher) and `tx`.
            while rx.recv().is_ok() {
                // Wait out the burst: restart the window on every further event.
                while rx.recv_timeout(latency).is_ok() {}
                on_change();
            }
        });
        if spawned.is_err() {
            return Box::new(NotifyToken { inner: Mutex::new(None) });
        }
        Box::new(NotifyToken { inner: Mutex::new(Some((watcher, tx))) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn fire_reaches_the_watch_of_that_folder_until_cancelled() {
        let w = FakeFolderWatcher::new();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = Arc::clone(&hits);
        let token = w.watch(
            Path::new("/a"),
            Arc::new(move || {
                h.fetch_add(1, Ordering::SeqCst);
            }),
        );
        w.fire(Path::new("/b"));
        w.fire(Path::new("/a"));
        assert_eq!((hits.load(Ordering::SeqCst), w.active_count()), (1, 1));
        token.cancel();
        token.cancel();
        w.fire(Path::new("/a"));
        assert_eq!((hits.load(Ordering::SeqCst), w.active_count()), (1, 0));
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn wait_for(hits: &AtomicUsize, want: usize) {
        for _ in 0..200 {
            if hits.load(Ordering::SeqCst) >= want {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
    }

    #[test]
    fn notify_watcher_reports_a_burst_once_and_stops_when_cancelled() {
        let dir = temp_dir("notify-watch");
        let hits = Arc::new(AtomicUsize::new(0));
        let h = Arc::clone(&hits);
        let w = NotifyFolderWatcher::new(std::time::Duration::from_millis(150));
        let token = w.watch(
            &dir,
            Arc::new(move || {
                h.fetch_add(1, Ordering::SeqCst);
            }),
        );
        for n in 0..5 {
            std::fs::write(dir.join(format!("a{n}.mov")), b"x").unwrap();
        }
        wait_for(&hits, 1);
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert_eq!(hits.load(Ordering::SeqCst), 1, "five writes in one burst are one call");
        // A change in a sub folder counts too.
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        wait_for(&hits, 2);
        assert!(hits.load(Ordering::SeqCst) >= 2);
        token.cancel();
        token.cancel();
        std::thread::sleep(std::time::Duration::from_millis(400));
        let seen = hits.load(Ordering::SeqCst);
        std::fs::write(dir.join("b.mov"), b"y").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(600));
        assert_eq!(hits.load(Ordering::SeqCst), seen);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn notify_watcher_on_a_missing_folder_watches_nothing_and_does_not_panic() {
        let w = NotifyFolderWatcher::default();
        let token = w.watch(Path::new("/no/such/folder/sq"), Arc::new(|| {}));
        token.cancel();
    }
}
