// Swift: EditorSession+GrowingFiles.swift
//! The growing-file poll: footage still being recorded, or re-rendered over its path, is noticed by size and date and
//! its length is probed again.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use sq_core_model::{MediaInfo, MediaRef};
use sq_core_time::Id;
use sq_library::media_file_stamp::{MediaFileStamp, MediaFileStampTracker};
use sq_runtime::UiRef;

use crate::{EditorSession, MediaWorkers, SessionRoot};

/// When the poll looks next and whether it looks now (Swift's `(poll:, next:)` tuple).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrowingFilePlan {
    /// Look at the files now.
    pub poll: bool,
    /// Seconds until the next decision.
    pub next: f64,
}

/// When the growing-file poll looks at the disk. Pure, so the "cheap timer" rules are testable.
pub enum GrowingFilePolicy {}

impl GrowingFilePolicy {
    /// Seconds between looks while nothing happens.
    // Swift: EditorSession+GrowingFiles.swift:8
    pub const ACTIVE_INTERVAL: f64 = 3.0;
    /// While playing no `stat` runs; the timer only checks back this often.
    // Swift: EditorSession+GrowingFiles.swift:10
    pub const BUSY_INTERVAL: f64 = 10.0;
    /// While exporting no `stat` runs; the timer only checks back this often.
    // Swift: EditorSession+GrowingFiles.swift:11
    pub const EXPORT_INTERVAL: f64 = 20.0;
    /// After this many looks without a change the interval grows to [`GrowingFilePolicy::CALM_INTERVAL`].
    // Swift: EditorSession+GrowingFiles.swift:13
    pub const QUIET_POLLS_BEFORE_BACKOFF: i64 = 20;
    /// The slow interval of a project that does not change.
    // Swift: EditorSession+GrowingFiles.swift:14
    pub const CALM_INTERVAL: f64 = 10.0;

    /// The next step of the poll.
    // Swift: EditorSession+GrowingFiles.swift:17
    pub fn decide(
        enabled: bool,
        online_count: usize,
        is_playing: bool,
        is_exporting: bool,
        quiet_polls: i64,
    ) -> GrowingFilePlan {
        if !enabled || online_count == 0 {
            return GrowingFilePlan { poll: false, next: Self::BUSY_INTERVAL };
        }
        if is_exporting {
            return GrowingFilePlan { poll: false, next: Self::EXPORT_INTERVAL };
        }
        if is_playing {
            return GrowingFilePlan { poll: false, next: Self::BUSY_INTERVAL };
        }
        let next =
            if quiet_polls >= Self::QUIET_POLLS_BEFORE_BACKOFF { Self::CALM_INTERVAL } else { Self::ACTIVE_INTERVAL };
        GrowingFilePlan { poll: true, next }
    }
}

/// Helpers for the re-probe of a changed file.
pub enum GrowingFileProbe {}

impl GrowingFileProbe {
    /// The item as it is after a re-probe of its changed file: new probe info, length and size/date stamp. The hash of
    /// the first bytes and everything else stays.
    // Swift: EditorSession+GrowingFiles.swift:29
    pub fn refreshed(media: &MediaRef, info: MediaInfo, stamp: Option<MediaFileStamp>) -> MediaRef {
        let mut r = media.clone();
        r.duration = Some(info.duration);
        r.info = Some(info);
        if let Some(s) = stamp {
            r.fingerprint.size = s.size;
            r.fingerprint.modified = Some(s.modified);
        }
        r
    }
}

/// The result of re-probing one changed file.
pub(crate) type Reprobed = BTreeMap<Id, (MediaInfo, Option<MediaFileStamp>)>;

impl EditorSession {
    /// One step of the growing-file timer (footage still being recorded or re-rendered over its path). Stats the online
    /// files in one batch off the UI thread; a file whose size or date changed gets its decoders, thumbnails and
    /// waveform dropped ([`EditorSession::refresh_media_from_disk`]) and is probed again for its new length. Skips
    /// offline items, and does nothing while playing, exporting or switched off. Returns the seconds until the next tick.
    // Swift: EditorSession+GrowingFiles.swift:43
    pub async fn growing_file_tick<R: SessionRoot + MediaWorkers + ?Sized>(
        h: UiRef<R>,
        enabled: bool,
        is_exporting: bool,
    ) -> f64 {
        const BUSY: f64 = GrowingFilePolicy::ACTIVE_INTERVAL;
        let Some(true) = h.with(|r| {
            let s = r.session();
            if s.grow_poll_running {
                return false;
            }
            s.grow_poll_running = true;
            true
        }) else {
            return BUSY;
        };
        let next = Self::growing_file_step(&h, enabled, is_exporting).await;
        let _ = h.with(|r| r.session().grow_poll_running = false);
        next.unwrap_or(BUSY)
    }

    /// The body of the tick; `None` = the root is gone.
    async fn growing_file_step<R: SessionRoot + MediaWorkers + ?Sized>(
        h: &UiRef<R>,
        enabled: bool,
        is_exporting: bool,
    ) -> Option<f64> {
        let baseline = h.with(|r| {
            let s = r.session();
            s.disk_tracker.known_count() == 0 && !s.project().media.is_empty() && enabled
        })?;
        if baseline {
            Self::refresh_media_from_disk(UiRef::clone(h)).await;
        }
        let (project, online, plan, pool) = h.with(|r| {
            let pool = r.workers();
            let s = r.session();
            let online: Vec<(Id, String)> = s
                .project()
                .media
                .iter()
                .filter(|m| s.disk_tracker.is_online(m.id) && m.info.as_ref().is_none_or(|i| !i.is_still))
                .map(|m| (m.id, m.path.clone()))
                .collect();
            let plan =
                GrowingFilePolicy::decide(enabled, online.len(), s.is_playing(), is_exporting, s.grow_quiet_polls);
            if !plan.poll && !enabled {
                s.grow_tracker = MediaFileStampTracker::new();
            }
            (s.project().id, online, plan, pool)
        })?;
        if !plan.poll {
            return Some(plan.next);
        }
        let urls: BTreeSet<PathBuf> = online.iter().map(|(_, p)| PathBuf::from(p)).collect();
        let mut tracker = h.with(|r| std::mem::replace(&mut r.session().grow_tracker, MediaFileStampTracker::new()))?;
        let polled = pool
            .run(move |_| {
                tracker.set_tracked(urls.iter().map(PathBuf::as_path));
                let changed = tracker.poll();
                (tracker, changed)
            })
            .await
            .ok();
        let changed_paths: BTreeSet<PathBuf> = h.with(|r| {
            let s = r.session();
            if s.project().id != project {
                return BTreeSet::new();
            }
            let Some((tracker, changed)) = polled else { return BTreeSet::new() };
            s.grow_tracker = tracker;
            if changed.is_empty() {
                s.grow_quiet_polls += 1;
            } else {
                s.grow_quiet_polls = 0;
            }
            changed.into_iter().collect()
        })?;
        if changed_paths.is_empty() {
            return Some(plan.next);
        }
        let ids: Vec<(Id, String)> = online.into_iter().filter(|(_, p)| changed_paths.contains(Path::new(p))).collect();
        Self::refresh_media_from_disk(UiRef::clone(h)).await;
        Self::reprobe_media(h, ids, project, &pool).await;
        Some(GrowingFilePolicy::ACTIVE_INTERVAL)
    }

    /// Probes `ids` again and folds the new info, length and stamp into the project (no undo step, like the other probe
    /// refreshes). A file that cannot be read yet (still being written) keeps its old info and is tried again at its
    /// next change.
    async fn reprobe_media<R: SessionRoot + MediaWorkers + ?Sized>(
        h: &UiRef<R>,
        ids: Vec<(Id, String)>,
        project: Id,
        pool: &sq_runtime::WorkerPool,
    ) {
        let Some(probe) = h.with(|r| std::sync::Arc::clone(&r.session().media_info_probe)) else { return };
        let found: Reprobed = pool
            .run(move |_| {
                let mut found = Reprobed::new();
                for (id, path) in ids {
                    let Some(info) = probe(Path::new(&path)) else { continue };
                    found.insert(id, (info, MediaFileStamp::read(Path::new(&path))));
                }
                found
            })
            .await
            .unwrap_or_default();
        let _ = h.with(|r| {
            let s = r.session();
            if s.project().id == project {
                s.fold_growing_probes(found);
            }
        });
    }

    /// Folds re-probed info of changed (growing or re-rendered) files into every history state: no undo step, marks the
    /// project dirty when something changed.
    // shortcut: Swift's `foldRefreshedProbes` (EditorSession.swift:895) is ES1's; this is the same fold under another
    // name until ES1 lands it, then call that one.
    pub(crate) fn fold_growing_probes(&mut self, found: Reprobed) {
        if found.is_empty() {
            return;
        }
        let before = self.history.current().clone();
        self.history.amend_all(|p| {
            for (id, (info, stamp)) in &found {
                let Some(r) = p.media(*id) else { continue };
                if r.info.as_ref() == Some(info) && r.duration == Some(info.duration) {
                    continue;
                }
                let replacement = GrowingFileProbe::refreshed(r, info.clone(), *stamp);
                p.replace_media(*id, &replacement);
            }
        });
        if *self.history.current() != before {
            self.force_dirty = true;
        }
        for id in found.keys() {
            self.requested_media.remove(id);
        }
        self.project_did_change();
    }
}
