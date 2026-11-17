// Swift: EditorSession+MediaDisk.swift, MediaDiskWatcher.swift
//! Media files changing under the open project: re-exported or overwritten clips, volumes that unmount or come back, the
//! machine sleeping. Decoders, caches and the viewer follow the files without a manual relink.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use sq_core_time::Id;
use sq_library::folder_watching::FolderWatchToken;
use sq_runtime::UiRef;

use crate::{
    Change, EditorSession, MediaDiskChanges, MediaDiskState, MediaDiskTracker, MediaWorkers, SessionEvent, SessionRoot,
};

/// System events after which project media may have changed on disk or the machine's state changed under playback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaDiskEvent {
    /// The app came to the front (a file may have been re-exported meanwhile).
    Activated,
    /// A volume appeared (SD card, USB disk, network drive).
    Mounted,
    /// A volume went away.
    Unmounted,
    /// The machine goes to sleep or the displays do.
    WillSleep,
    /// The matching wake-up.
    DidWake,
}

/// Where workspace events come from: the platform shell (NSWorkspace notifications on the Mac, power and device
/// broadcasts on Windows, or a file system watcher on the volumes folder through the `notify` crate). The handler may
/// run on any thread; the app forwards it to the UI inbox and calls [`EditorSession::handle_disk_event`].
pub trait MediaDiskEventSource {
    /// Starts delivering events; the token ends the subscription.
    fn subscribe(&self, handler: Arc<dyn Fn(MediaDiskEvent) + Send + Sync>) -> Box<dyn FolderWatchToken>;
}

/// Forwards workspace events to a handler until it is stopped or dropped (Swift `MediaDiskWatcher`).
pub struct MediaDiskWatcher {
    token: Option<Box<dyn FolderWatchToken>>,
}

impl MediaDiskWatcher {
    /// Subscribes `handler` to `source`.
    // Swift: MediaDiskWatcher.swift:9
    pub fn new(
        source: &dyn MediaDiskEventSource,
        handler: Arc<dyn Fn(MediaDiskEvent) + Send + Sync>,
    ) -> MediaDiskWatcher {
        MediaDiskWatcher { token: Some(source.subscribe(handler)) }
    }

    /// Removes the subscription; calling it again does nothing.
    // Swift: MediaDiskWatcher.swift:30
    pub fn stop(&mut self) {
        if let Some(t) = self.token.take() {
            t.cancel();
        }
    }
}

impl Drop for MediaDiskWatcher {
    fn drop(&mut self) {
        self.stop();
    }
}

/// One disk look in flight: the project it belongs to and the paths to stat.
#[derive(Clone, Debug)]
pub(crate) struct DiskRefreshJob {
    pub(crate) project: Id,
    pub(crate) paths: BTreeMap<Id, String>,
}

/// What a disk look changed in the session.
#[derive(Clone, Debug, Default)]
pub(crate) struct DiskApplied {
    pub(crate) touched: BTreeSet<Id>,
    /// Modified and returned items: their sources are prepared again.
    pub(crate) reopen: Vec<Id>,
}

impl EditorSession {
    /// Starts listening to the workspace. The app owns the [`MediaDiskWatcher`] (the session has no field for it) and
    /// feeds its events to [`EditorSession::handle_disk_event`]; this call stays for the Swift contract and does nothing.
    // Swift: EditorSession+MediaDisk.swift:19
    // shortcut: no session-owned watcher; upgrade if the session gains a `disk_watcher` field.
    pub fn start_watching_media_files(&mut self) {}

    /// Stops listening (see [`EditorSession::start_watching_media_files`]).
    // Swift: EditorSession+MediaDisk.swift:25
    pub fn stop_watching_media_files(&mut self) {}

    /// Reacts to one workspace event: sleep stops playback, everything else looks at the files again.
    pub async fn handle_disk_event<R: SessionRoot + MediaWorkers + ?Sized>(h: UiRef<R>, event: MediaDiskEvent) {
        match event {
            // A sleeping machine tears the audio device down under a running playback: stop first, Play after.
            MediaDiskEvent::WillSleep => {
                let _ = h.with(|r| r.session().stop_playback());
            }
            MediaDiskEvent::Activated
            | MediaDiskEvent::Mounted
            | MediaDiskEvent::Unmounted
            | MediaDiskEvent::DidWake => {
                Self::refresh_media_from_disk(h).await;
            }
        }
    }

    /// Looks at every media file once (off the UI thread) and reacts to what changed since the last look: open sources
    /// of changed, vanished and returned files are dropped and opened again, the viewer redraws, and
    /// [`SessionEvent::MediaFilesChanged`] lets the UI forget thumbnails and waveforms. The first look only records the
    /// state. Returns the items that changed.
    // Swift: EditorSession+MediaDisk.swift:47
    pub async fn refresh_media_from_disk<R: SessionRoot + MediaWorkers + ?Sized>(h: UiRef<R>) -> BTreeSet<Id> {
        let Some(Some((job, pool))) = h.with(|r| {
            let pool = r.workers();
            r.session().begin_disk_refresh().map(|j| (j, pool))
        }) else {
            return BTreeSet::new();
        };
        let paths = job.paths.clone();
        let snapshot = pool.run(move |_| MediaDiskTracker::snapshot(&paths)).await.ok();
        let Some(applied) = h.with(|r| r.session().finish_disk_refresh(&job, snapshot)) else { return BTreeSet::new() };
        if !applied.reopen.is_empty() {
            let Some(media) = h.with(|r| Arc::clone(&r.session().media)) else { return applied.touched };
            let reopen = applied.reopen;
            let _ = pool.run(move |_| media.prepare(&reopen)).await;
            let _ = h.with(|r| r.session().notify(Change::MEDIA));
        }
        applied.touched
    }

    /// Starts a disk look unless one runs: the paths to stat. `None` = one is running already.
    pub(crate) fn begin_disk_refresh(&mut self) -> Option<DiskRefreshJob> {
        if self.disk_refresh_running {
            return None;
        }
        self.disk_refresh_running = true;
        let paths = self.project().media.iter().map(|m| (m.id, m.path.clone())).collect();
        Some(DiskRefreshJob { project: self.project().id, paths })
    }

    /// Folds the stats of a disk look in (nothing when the project was replaced meanwhile or the look failed).
    pub(crate) fn finish_disk_refresh(
        &mut self,
        job: &DiskRefreshJob,
        snapshot: Option<BTreeMap<Id, MediaDiskState>>,
    ) -> DiskApplied {
        self.disk_refresh_running = false;
        let Some(snapshot) = snapshot else { return DiskApplied::default() };
        if self.project().id != job.project {
            return DiskApplied::default();
        }
        let changes = self.disk_tracker.update(snapshot);
        self.apply_disk_changes(&changes)
    }

    /// Files the UI found missing or back on its own look (the app regained focus): same reaction as a disk look.
    /// Returns the items that changed.
    pub fn media_files_came_or_went(&mut self, appeared: BTreeSet<Id>, vanished: BTreeSet<Id>) -> BTreeSet<Id> {
        self.apply_disk_changes(&MediaDiskChanges { modified: BTreeSet::new(), appeared, vanished }).touched
    }

    /// Drops what the changed files had open, tells the engines, the render cache and the UI.
    pub(crate) fn apply_disk_changes(&mut self, changes: &MediaDiskChanges) -> DiskApplied {
        let touched = changes.all();
        if touched.is_empty() {
            return DiskApplied::default();
        }
        self.media.invalidate(&touched);
        for id in &touched {
            self.requested_media.remove(id);
        }
        self.engine.media_changed(&touched);
        if let Some(cache) = self.render_cache.as_mut() {
            cache.media_changed();
        }
        for engine in self.auxiliary_engines.iter_mut().filter(|e| e.is_alive()) {
            engine.media_changed(&touched);
        }
        self.emit(SessionEvent::MediaFilesChanged(touched.clone()));
        let reopen: Vec<Id> = changes.modified.union(&changes.appeared).copied().collect();
        self.requested_media.extend(reopen.iter().copied());
        self.notify(Change::MEDIA);
        DiskApplied { touched, reopen }
    }
}
