// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaPlacement.swift (`restartWatching`, `sync`; removed with the AppKit shell), MediaPolicy.swift (`scanFiles`,
// `stat`, `isWatchableFolder`)
//! The project folder's media watcher: every tick the folder is read on a worker, new media files that stopped changing
//! are filed (linked in place) into bins that mirror their folders, and files that vanished turn offline. One task for
//! every platform; the platform loops only keep the executor's timers running.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use sq_core_project::media_policy::{
    FolderSyncAdd, SeenFile, folder_sync_plan, is_hidden_or_package, settled, skipped_top_level,
};
use sq_core_time::Id;
use sq_library::library_item_kind::LibraryItemKind;
use sq_media::media_file_ops::MediaManagement;
use sq_runtime::{UiRef, WorkerPool};

use super::{ImportBackend, ProjectPanelModel, ProjectPanelRoot};
use crate::EditorSession;

/// How often the project folder is read.
pub const TICK: Duration = Duration::from_secs(2);
/// A file written within this time is still being copied.
const QUIET: Duration = Duration::from_secs(2);
/// A file seen for the first time is measured again after this gap: a copy that still grows is told from a finished one
/// within the same tick.
const RECHECK: Duration = Duration::from_millis(250);

/// A folder that can be a project's own home: not a volume or system root, the home folder or one of its standard folders
/// (watching those would pull in the user's whole library).
// Swift: MediaPolicy.swift:119 (`isWatchableFolder`)
pub fn is_watchable_folder(folder: &Path, home: Option<&Path>) -> bool {
    if folder.parent().is_none() || folder == Path::new("/Users") || folder == Path::new("/Volumes") {
        return false;
    }
    if let Some(home) = home {
        let standard = ["Movies", "Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"];
        if folder == home || standard.iter().any(|name| folder == home.join(name)) {
            return false;
        }
    }
    let parts: Vec<_> = folder.components().collect();
    !(parts.len() == 3 && parts[1].as_os_str() == "Volumes")
}

fn is_media(path: &Path) -> bool {
    matches!(
        LibraryItemKind::classify(path, false),
        LibraryItemKind::Video | LibraryItemKind::Image | LibraryItemKind::Audio
    )
}

/// Every media file below `folder`, skipping hidden items, project packages and our own output folders at the top
/// level. File system only: call it on a worker.
// Swift: MediaPolicy.swift:257 (`scanFiles`)
pub fn scan_files(folder: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut open = vec![(folder.to_path_buf(), 0usize)];
    while let Some((dir, level)) = open.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let (name, Ok(kind)) = (entry.file_name().to_string_lossy().into_owned(), entry.file_type()) else {
                continue;
            };
            if is_hidden_or_package(&name) {
                continue;
            }
            if kind.is_dir() {
                if !(level == 0 && skipped_top_level(&name)) {
                    open.push((entry.path(), level + 1));
                }
            } else if kind.is_file() && is_media(&entry.path()) {
                out.push(entry.path().to_string_lossy().into_owned());
            }
        }
    }
    out
}

/// Size and modification date of each path; missing files are left out.
// Swift: MediaPolicy.swift:213 (`stat`)
fn stat(paths: &[String]) -> Vec<SeenFile> {
    paths
        .iter()
        .filter_map(|p| {
            let meta = std::fs::metadata(p).ok()?;
            Some(SeenFile { path: p.clone(), size: meta.len(), modified: meta.modified().ok()? })
        })
        .collect()
}

/// What one pass needs from the session, read on the UI thread.
struct Job {
    project: Id,
    folder: PathBuf,
    known: BTreeSet<String>,
    ignored: Vec<String>,
    pool: Arc<WorkerPool>,
    backend: Arc<dyn ImportBackend>,
}

impl Job {
    /// `None` while the project does not watch its folder (setting off, loose project file, a folder that is too wide).
    fn of(panel: &ProjectPanelModel, session: &EditorSession) -> Option<Job> {
        let project = session.project();
        let policy = project.media_policy.as_ref()?;
        if policy.watch_folder != Some(true) {
            return None;
        }
        let folder = MediaManagement::project_folder(session.file_url())?;
        let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from);
        if !is_watchable_folder(&folder, home.as_deref()) {
            return None;
        }
        Some(Job {
            project: project.id,
            folder,
            known: project.media.iter().map(|m| m.path.clone()).collect(),
            ignored: policy.ignored.clone().unwrap_or_default(),
            pool: Arc::clone(&panel.deps.pool),
            backend: Arc::clone(&panel.deps.backend),
        })
    }
}

/// What the worker found.
struct Scan {
    plan: Vec<FolderSyncAdd>,
    seen: Vec<SeenFile>,
    frames: BTreeSet<String>,
    gone: BTreeSet<String>,
}

/// Reads the folder: the files to add (settled, not numbered frames), what was seen, and the known paths that are gone.
// Swift: MediaPlacement.swift:406 (`sync`, the detached part)
fn scan_stage(
    job: &Job,
    previous: &BTreeMap<String, SeenFile>,
    frames: &BTreeSet<String>,
    now: SystemTime,
    recheck: Duration,
) -> Scan {
    let found: Vec<String> = scan_files(&job.folder).into_iter().filter(|f| !frames.contains(f)).collect();
    let mut plan = folder_sync_plan(&found, &job.folder, &job.known, &job.ignored);
    // Numbered frames are one image sequence, not hundreds of stills: they stay out of the automatic add.
    let paths: Vec<PathBuf> = plan.iter().map(|a| PathBuf::from(&a.path)).collect();
    let grouped: BTreeSet<String> =
        job.backend.image_sequences(&paths).into_iter().flatten().map(|p| p.to_string_lossy().into_owned()).collect();
    plan.retain(|a| !grouped.contains(&a.path));
    let paths: Vec<String> = plan.iter().map(|a| a.path.clone()).collect();
    let mut seen = stat(&paths);
    let mut before = previous.clone();
    if seen.iter().any(|f| !previous.contains_key(&f.path)) {
        std::thread::sleep(recheck);
        for first in std::mem::replace(&mut seen, stat(&paths)) {
            before.entry(first.path.clone()).or_insert(first);
        }
    }
    let (stable, _) = settled(&seen, &before, now, QUIET);
    plan.retain(|a| stable.contains(&a.path));
    let gone = job.known.iter().filter(|p| !Path::new(p).exists()).cloned().collect();
    Scan { plan, seen, frames: grouped, gone }
}

/// The watcher's memory between ticks: what the last scan saw (a file counts as written once it looked the same twice).
pub struct FolderWatch {
    project: Option<Id>,
    last_seen: BTreeMap<String, SeenFile>,
    sequence_frames: BTreeSet<String>,
    gone: BTreeSet<String>,
    recheck: Duration,
}

impl Default for FolderWatch {
    fn default() -> FolderWatch {
        FolderWatch::with_recheck(RECHECK)
    }
}

impl FolderWatch {
    pub(super) fn with_recheck(recheck: Duration) -> FolderWatch {
        FolderWatch {
            project: None,
            last_seen: BTreeMap::new(),
            sequence_frames: BTreeSet::new(),
            gone: BTreeSet::new(),
            recheck,
        }
    }

    /// Runs one pass every [`TICK`] until the root is gone. Spawn it once on the app's executor; it follows whichever
    /// project is open and does nothing while that project's watch-folder setting is off.
    pub async fn run<R: ProjectPanelRoot + ?Sized>(h: UiRef<R>) {
        let mut watch = FolderWatch::default();
        while h.is_alive() {
            if sq_runtime::sleep(TICK).await.is_err() {
                return;
            }
            watch.sync(&h, SystemTime::now()).await;
        }
    }

    /// One pass: new settled files are imported (one history-neutral step), vanished files turn offline. Returns how many
    /// files were added.
    // Swift: MediaPlacement.swift:406
    pub async fn sync<R: ProjectPanelRoot + ?Sized>(&mut self, h: &UiRef<R>, now: SystemTime) -> i64 {
        let Some(Some(job)) = h.with(|r| {
            let (panel, session) = r.panel_parts();
            Job::of(panel, session)
        }) else {
            return 0;
        };
        if self.project != Some(job.project) {
            *self = FolderWatch { project: Some(job.project), ..FolderWatch::with_recheck(self.recheck) };
        }
        let (project, pool) = (job.project, Arc::clone(&job.pool));
        let (previous, frames, recheck) = (self.last_seen.clone(), self.sequence_frames.clone(), self.recheck);
        let Ok(scan) = pool.run(move |_| scan_stage(&job, &previous, &frames, now, recheck)).await else { return 0 };
        self.last_seen = scan.seen.into_iter().map(|f| (f.path.clone(), f)).collect();
        self.sequence_frames.extend(scan.frames);
        let offline_changed = scan.gone != self.gone;
        self.gone = scan.gone;
        let same_project = h.with(|r| {
            let (panel, session) = r.panel_parts();
            if session.project().id != project {
                return false;
            }
            if offline_changed {
                panel.refresh_offline();
            }
            true
        });
        if same_project != Some(true) || scan.plan.is_empty() {
            return 0;
        }
        ProjectPanelModel::import_synced(h.clone(), scan.plan, move |r: &mut R| {
            r.panel_parts().1.project().id == project
        })
        .await
    }
}
