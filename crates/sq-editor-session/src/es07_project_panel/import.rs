//! Import into the Project panel: the platform backend, the async `import_files` flow and the helpers around it
//! (Swift `ProjectPanelModel.importFiles`, `mediaID(forImported:)`).

use sq_core_project::media_policy::{ProjectFolderSyncExt as _, new_bin_ids};
use sq_core_project::project_merge::{ProjectMerge, ProjectMergeExt as _};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use sq_core_edit::import_scheduling::ImportCommitPlan;
use sq_core_model::{BinItemRef, MediaRef};
use sq_core_project::media_filter_tokens::Calendar;
use sq_core_project::media_grouping::GroupingCalendar;
use sq_core_time::{Id, SequentialIds};
use sq_runtime::{TaskGroup, UiRef, WorkerPool};

use super::{
    FileCodec, FileReason, ImportReport, ImportReportEntry, ImportedFile, ProjectPanelEvent, ProjectPanelModel,
};
use crate::EditorSession;

/// The calendar the panel's day filters and grouping read.
pub trait PanelCalendar: Calendar + GroupingCalendar {}
impl<T: Calendar + GroupingCalendar> PanelCalendar for T {}

/// Why a file could not be probed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportError {
    /// The video codec cannot be decoded here (the codec name).
    UnsupportedCodec(String),
    /// Anything else (the plain error text).
    Failed(String),
}

/// The platform side of an import (Swift `ProjectPanelModel.platformProbe`, `fileIdentity`, `imageSequences`,
/// `failureReason`, `takeAudioDropped`, `sequenceProbe`). Every method may block: they run on workers.
pub trait ImportBackend: Send + Sync {
    /// Probes one file into a media item (Swift `Probe`).
    // Swift: ProjectPanelModel.swift:14
    fn probe(&self, path: &Path) -> Result<MediaRef, ImportError>;
    /// Probes numbered frames picked together as one clip.
    fn probe_sequence(&self, _frames: &[PathBuf]) -> Result<MediaRef, ImportError> {
        Err(ImportError::UnsupportedCodec("image sequence".into()))
    }
    /// Identity of the file on disk (two paths to one file share it); `None` when unknown or unreachable.
    fn file_identity(&self, _path: &Path) -> Option<String> {
        None
    }
    /// Runs of numbered frames among `files` (at least `ProjectPanelModel::MIN_SEQUENCE_FRAMES` each).
    fn image_sequences(&self, _files: &[PathBuf]) -> Vec<Vec<PathBuf>> {
        Vec::new()
    }
    /// Plain-language reason a file could not be read (empty file, interrupted recording, AVI, ...).
    fn failure_reason(&self, _path: &Path, _error: &ImportError) -> Option<String> {
        None
    }
    /// The audio codec of a file that was imported without sound, once.
    fn take_audio_dropped(&self, _path: &Path) -> Option<String> {
        None
    }
}

/// A backend that reads nothing: every probe fails as unsupported (the portable default until the FFmpeg probe is wired).
// Off the Mac nothing probes, no duplicate file identity, no image sequence grouping, no diagnosis (as Swift's `#else`
// branch); the app injects the FFmpeg probe (sq-media-ffmpeg).
pub struct NoImportBackend;

impl ImportBackend for NoImportBackend {
    fn probe(&self, _path: &Path) -> Result<MediaRef, ImportError> {
        Err(ImportError::UnsupportedCodec("probe".into()))
    }
}

pub use sq_core_project::media_policy::FolderSyncAdd;

/// The root of the app as the import flow needs it: the panel model and the session, borrowed together.
pub trait ProjectPanelRoot {
    fn panel_parts(&mut self) -> (&mut ProjectPanelModel, &mut EditorSession);
}

enum Probed {
    Skipped,
    Done { media: Box<MediaRef>, audio_dropped: Option<String> },
    Unsupported(String),
    Failed(Option<String>),
}

/// State of one running import, owned by the flow (not the model) so nothing is borrowed across an await.
struct ImportRun {
    todo: Vec<PathBuf>,
    sequences: BTreeMap<String, Vec<PathBuf>>,
    token: Arc<AtomicBool>,
    token_key: u64,
    plan: ImportCommitPlan,
    progressive: bool,
    key: String,
    start_bin: Id,
    report: ImportReport,
    results: Vec<Option<(PathBuf, Option<MediaRef>)>>,
    unsupported_at: Vec<(usize, FileCodec)>,
    reasons: BTreeMap<usize, String>,
    audio_dropped: Vec<(usize, FileCodec)>,
    landed: i64,
    landed_files: Vec<ImportedFile>,
    skipped: i64,
    pointer: (f64, f64),
    backend: Arc<dyn ImportBackend>,
    pool: Arc<WorkerPool>,
    limit: usize,
}

/// What an import reads from the disk before it files anything: handed to a worker by `identity_scan`.
pub(super) struct IdentityScan {
    backend: Arc<dyn ImportBackend>,
    pool: Arc<WorkerPool>,
    candidates: Vec<PathBuf>,
    uncached: Vec<PathBuf>,
}

/// The file identities a worker read (stored path -> identity; a file whose identity is unknown has no entry).
#[derive(Default)]
pub(super) struct FoundIdentities {
    candidates: BTreeMap<String, Option<String>>,
    project: BTreeMap<String, String>,
}

impl IdentityScan {
    /// Stats on a worker: the new files, and only when one of them has an identity the project media not cached yet
    /// (a backend without identities, or an import of nothing, touches no project file).
    pub(super) async fn run(self) -> FoundIdentities {
        if self.candidates.is_empty() {
            return FoundIdentities::default();
        }
        let IdentityScan { backend, pool, candidates, uncached } = self;
        let job = pool.run(move |ctl| {
            let mut found = FoundIdentities::default();
            for url in &candidates {
                found.candidates.insert(path_key(url), backend.file_identity(url));
            }
            if found.candidates.values().any(Option::is_some) {
                for url in &uncached {
                    if ctl.is_cancelled() {
                        break;
                    }
                    if let Some(id) = backend.file_identity(url) {
                        found.project.insert(sq_os::paths::stored_form(&url.to_string_lossy()), id);
                    }
                }
            }
            found
        });
        job.await.unwrap_or_default()
    }
}

/// The text a path is compared by: the probe stores paths plain with `/` (`C:/Users/a.mp4`), so a Windows spelling
/// (`C:\Users\a.mp4` from the file dialog or a drop, or an old project's `//?/C:/Users/a.mp4`) must give the same key, or
/// a file already in the project is not recognized and its "Already in the project" line never appears.
fn path_key(p: &Path) -> String {
    sq_os::paths::stored(p)
}

fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

impl ProjectPanelModel {
    /// Fewest numbered files that count as a sequence (a few unrelated numbered screenshots stay separate stills).
    // Swift: ProjectPanelModel.swift:208
    pub const MIN_SEQUENCE_FRAMES: usize = 4;

    /// Media id for a file handed to `import_files` (its copy in Files, or the file itself), `None` if it was not imported.
    // Swift: ProjectPanelModel.swift:524
    pub fn media_id_for_imported(&self, url: &Path) -> Option<Id> {
        let key = path_key(url);
        self.imported_ids.get(&key).copied().or_else(|| self.project.media.iter().find(|m| m.path == key).map(|m| m.id))
    }

    /// Probes `urls` in the background and files the new items in the current bin as one undo step. Files already in the
    /// project (same path) are skipped; unreadable files end up in `import_failures`. With `set_coalescing_imports`, the
    /// bin fills while the import runs (in input order): a folder of hundreds of clips shows its first item at once
    /// instead of after the last probe; still one undo step.
    // Swift: ProjectPanelModel.swift:533
    pub async fn import_files<R: ProjectPanelRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>) {
        // The disk is touched on a worker only: a slow or disconnected NAS must not freeze the UI at an import.
        let Some(scan) = h.with(|r| r.panel_parts().0.identity_scan(&urls)) else { return };
        let found = scan.run().await;
        let Some(Some(mut run)) = h.with(|r| r.panel_parts().0.begin_import(&urls, found)) else { return };
        let n = run.todo.len();
        let mut group: TaskGroup<(usize, Probed)> = TaskGroup::new();
        let (mut next, mut inflight) = (0usize, 0usize);
        loop {
            while inflight < run.limit.max(1) && next < n {
                let (i, url) = (next, run.todo[next].clone());
                let frames = run.sequences.get(&path_key(&url)).cloned();
                let (backend, pool, token) = (Arc::clone(&run.backend), Arc::clone(&run.pool), Arc::clone(&run.token));
                group.spawn(async move { (i, probe_one(backend, pool, token, i, url, frames).await) });
                next += 1;
                inflight += 1;
            }
            let Some(done) = group.next().await else { break };
            inflight -= 1;
            let Ok((i, probed)) = done else { continue };
            let alive = h.with(|r| {
                let (m, s) = r.panel_parts();
                m.finished_probe(s, &mut run, i, probed);
            });
            if alive.is_none() {
                return;
            }
        }
        h.with(|r| {
            let (m, s) = r.panel_parts();
            m.finish_import(s, run);
        });
    }

    /// Moves imported files into bins that mirror their folders (bin names from the root down), creating the bins: one undo
    /// step. Files that are not in the project, or have an empty bin path, stay where they are.
    pub fn file_into_bins(&mut self, session: &mut EditorSession, placements: &[(PathBuf, Vec<String>)]) -> bool {
        self.commit(session, "Import Folder", None, |p, ids| {
            let none = BTreeMap::new();
            let mut changed = false;
            for (path, bin) in placements {
                let key = path_key(path);
                let Some(id) = p.media.iter().find(|m| m.path == key).map(|m| m.id) else { continue };
                if bin.is_empty() {
                    continue;
                }
                if let Some(dest) = p.bin_id(bin, true, &none, ids) {
                    changed |= p.move_items(&[BinItemRef::Media(id)], dest, None);
                }
            }
            changed
        })
    }

    /// Probes files that appeared in the project folder and files them, linked in place (no copy), into bins that mirror
    /// their folders: one undo step. Unreadable files are skipped silently (a scan will see them again). Returns the
    /// number added. `still_valid` is asked again after the probes: false (another project opened, watching restarted)
    /// drops the result.
    // Swift: ProjectPanelModel.swift:698
    // Files the watcher found are not an edit: `EditorSession::amend_project` (Swift `amend`) puts them in every history state.
    pub async fn import_synced<R: ProjectPanelRoot + ?Sized>(
        h: UiRef<R>,
        adds: Vec<FolderSyncAdd>,
        still_valid: impl Fn(&mut R) -> bool,
    ) -> i64 {
        let Some(Some((todo, backend, pool, limit, failed_before))) = h.with(|r| {
            let m = r.panel_parts().0;
            let known: BTreeSet<&str> = m.project.media.iter().map(|x| x.path.as_str()).collect();
            let todo: Vec<FolderSyncAdd> = adds.iter().filter(|a| !known.contains(a.path.as_str())).cloned().collect();
            if todo.is_empty() {
                return None;
            }
            Some((
                todo,
                Arc::clone(&m.deps.backend),
                Arc::clone(&m.deps.pool),
                m.deps.probe_limit,
                m.failed_probes.clone(),
            ))
        }) else {
            return 0;
        };
        let n = todo.len();
        let mut group: TaskGroup<(usize, Option<MediaRef>, Option<String>)> = TaskGroup::new();
        let (mut next, mut inflight) = (0usize, 0usize);
        let mut by_index: BTreeMap<usize, MediaRef> = BTreeMap::new();
        let mut new_failures: BTreeMap<String, String> = BTreeMap::new();
        loop {
            while inflight < limit.max(1) && next < n {
                let (i, path) = (next, todo[next].path.clone());
                let (backend, pool) = (Arc::clone(&backend), Arc::clone(&pool));
                let before = failed_before.get(&path).cloned();
                group.spawn(async move {
                    // A file that failed to probe is tried again only when its size or modification date changed.
                    let sig = ProjectPanelModel::file_signature(&path);
                    if sig.is_some() && before == sig {
                        return (i, None, None);
                    }
                    let probed = pool.run(move |_| backend.probe(Path::new(&path)).ok()).await.ok().flatten();
                    let failed = if probed.is_none() { sig } else { None };
                    (i, probed, failed)
                });
                next += 1;
                inflight += 1;
            }
            let Some(done) = group.next().await else { break };
            inflight -= 1;
            let Ok((i, media, failed_sig)) = done else { continue };
            if let Some(media) = media {
                by_index.insert(i, media);
            }
            if let Some(sig) = failed_sig {
                new_failures.insert(todo[i].path.clone(), sig);
            }
        }
        let Some(added) = h.with(|r| {
            if !still_valid(r) {
                return 0;
            }
            let (m, s) = r.panel_parts();
            m.failed_probes.extend(new_failures);
            let items: Vec<(MediaRef, Vec<String>)> =
                by_index.into_iter().map(|(i, media)| (media, todo[i].bin.clone())).collect();
            if items.is_empty() {
                return 0;
            }
            // Once, so every history state gets the same bin ids.
            let bin_ids = new_bin_ids(&items, &mut *s.ids);
            let mut added = 0usize;
            // shortcut: the bin ids are all fixed by `bin_ids`, so the throwaway id source below is never asked; upgrade
            // when `add_synced` takes no id source.
            let mut spare = SequentialIds::default();
            s.amend_project(|p| added = added.max(p.add_synced(&items, &bin_ids, &mut spare)));
            m.project = s.project().clone();
            m.version += 1;
            m.schedule_offline_refresh();
            added as i64
        }) else {
            return 0;
        };
        added
    }

    /// Imports other Sequence Studio projects (`.sqproj`, legacy `.ssproj`) as one bin each into the current bin, with
    /// all their media, sequences and bins, as one undo step. The current sequence is left alone. A project that cannot
    /// be read sets `project_import_error` and the others still import.
    // shortcut: the projects are read on the UI thread (Swift detaches the read); upgrade when a project is big enough to
    // stall a frame.
    // Swift: ProjectPanelModel.swift:764
    pub async fn import_projects<R: ProjectPanelRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>) {
        h.with(|r| {
            let (m, s) = r.panel_parts();
            m.import_projects_now(s, &urls);
        });
    }

    /// The body of `import_projects`: reads every project, merges the readable ones as one undo step.
    fn import_projects_now(&mut self, session: &mut EditorSession, urls: &[PathBuf]) {
        self.project_error = None;
        self.imported_project_names = Vec::new();
        let mut loaded: Vec<(PathBuf, sq_core_model::Project)> = Vec::new();
        for url in urls {
            let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            match ProjectMerge::load(url) {
                Ok(p) => loaded.push((url.clone(), p)),
                Err(e) => self.project_error = Some(ProjectMerge::message(Some(&e), &name)),
            }
        }
        if loaded.is_empty() {
            self.version += 1;
            return;
        }
        let dest = self.current_bin;
        let names: Vec<String> = loaded
            .iter()
            .map(|(url, p)| {
                if p.name.is_empty() {
                    url.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
                } else {
                    p.name.clone()
                }
            })
            .collect();
        let label = if loaded.len() == 1 {
            format!("Import Project \u{201C}{}\u{201D}", names[0])
        } else {
            format!("Import {} Projects", loaded.len())
        };
        let done = self.commit(session, &label, None, |p, ids| {
            let into = if p.bin(dest).is_some() { dest } else { p.root_bin.id };
            let mut any = false;
            for (i, (url, other)) in loaded.iter().enumerate() {
                if p.merge(other, Some(&names[i]), Some(into), url.parent(), ids).is_some() {
                    any = true;
                }
            }
            any
        });
        if done {
            self.imported_project_names = names;
        }
        self.version += 1;
        self.schedule_offline_refresh();
    }

    /// The paths whose file identity this import needs, split off so a worker reads them (no disk access here): the new
    /// files, and the project media whose identity is not cached yet.
    fn identity_scan(&mut self, urls: &[PathBuf]) -> IdentityScan {
        let known: BTreeSet<String> = self.project.media.iter().map(|m| sq_os::paths::stored_form(&m.path)).collect();
        // A path that left the project leaves the cache (the file under it may be another one by now).
        self.identity_cache.retain(|path, _| known.contains(path));
        let candidates = self.new_files(urls, &known);
        let uncached: Vec<PathBuf> = self
            .project
            .media
            .iter()
            .filter(|m| !self.identity_cache.contains_key(&sq_os::paths::stored_form(&m.path)))
            .map(|m| PathBuf::from(&m.path))
            .collect();
        IdentityScan {
            backend: Arc::clone(&self.deps.backend),
            pool: Arc::clone(&self.deps.pool),
            candidates,
            uncached,
        }
    }

    /// `urls` that are not in the project (same path) and not repeated in the batch.
    fn new_files(&self, urls: &[PathBuf], known: &BTreeSet<String>) -> Vec<PathBuf> {
        let mut seen = BTreeSet::new();
        urls.iter().filter(|u| !known.contains(&path_key(u)) && seen.insert(path_key(u))).cloned().collect()
    }

    /// Everything before the probes: duplicates, sequences, counters, the cancel token. `None` when nothing is left to
    /// probe. `found` is what the worker read from the disk (`identity_scan`).
    fn begin_import(&mut self, urls: &[PathBuf], found: FoundIdentities) -> Option<ImportRun> {
        let known: BTreeSet<String> = self.project.media.iter().map(|m| sq_os::paths::stored_form(&m.path)).collect();
        let mut todo = self.new_files(urls, &known);
        self.already_in_project = urls.iter().filter(|u| known.contains(&path_key(u))).map(|u| file_name(u)).collect();
        // Another path to a file that is in the project already (or earlier in this batch) is not imported twice.
        self.identity_cache.extend(found.project);
        self.identity_cache.retain(|path, _| known.contains(path));
        let mut duplicate_names = Vec::new();
        let backend = Arc::clone(&self.deps.backend);
        let identities: Vec<Option<String>> =
            todo.iter().map(|u| found.candidates.get(&path_key(u)).cloned().flatten()).collect();
        if identities.iter().any(Option::is_some) {
            let mut taken: BTreeSet<String> = self.identity_cache.values().cloned().collect();
            let mut keep = Vec::new();
            for (url, id) in todo.iter().zip(identities) {
                if id.is_some_and(|id| !taken.insert(id)) {
                    duplicate_names.push(file_name(url));
                } else {
                    keep.push(url.clone());
                }
            }
            todo = keep;
        }
        let mut report = ImportReport::new();
        report.already_in_project = self.already_in_project.clone();
        report.duplicates = duplicate_names.clone();
        if !urls.is_empty() {
            self.import_failures.clear();
            self.import_failure_reasons.clear();
            self.import_canceled = None;
        }
        if !self.already_in_project.is_empty() || !duplicate_names.is_empty() {
            self.version += 1;
        }
        // Numbered frames collapse into their first file; its probe renders the whole run.
        let mut sequences = BTreeMap::new();
        for g in backend.image_sequences(&todo) {
            if let Some(first) = g.first() {
                sequences.insert(path_key(first), g);
            }
        }
        if !sequences.is_empty() {
            let drop: BTreeSet<String> =
                sequences.values().flat_map(|g| g.iter().skip(1)).map(|p| path_key(p)).collect();
            todo.retain(|u| !drop.contains(&path_key(u)));
        }
        if todo.is_empty() {
            if !urls.is_empty() {
                self.last_import_report = Some(report);
            }
            return None;
        }
        self.import_failures.clear();
        self.pending_imports += todo.len() as i64;
        self.import_total += todo.len() as i64;
        let token = Arc::new(AtomicBool::new(false));
        self.next_token += 1;
        let token_key = self.next_token;
        self.import_tokens.insert(token_key, Arc::clone(&token));
        let n = todo.len();
        Some(ImportRun {
            plan: ImportCommitPlan::new(n as i64, self.import_commit_interval),
            progressive: self.coalescing_imports,
            key: format!("import-{token_key}"),
            start_bin: self.current_bin,
            results: vec![None; n],
            todo,
            sequences,
            token,
            token_key,
            report,
            unsupported_at: Vec::new(),
            reasons: BTreeMap::new(),
            audio_dropped: Vec::new(),
            landed: 0,
            landed_files: Vec::new(),
            skipped: 0,
            // No pointer position here; the shell passes where the drop happened to its own placement.
            pointer: (0.0, 0.0),
            backend,
            pool: Arc::clone(&self.deps.pool),
            limit: self.deps.probe_limit,
        })
    }

    /// One probe ended: record it and land the files the commit schedule hands out.
    fn finished_probe(&mut self, session: &mut EditorSession, run: &mut ImportRun, i: usize, probed: Probed) {
        let url = run.todo[i].clone();
        match probed {
            Probed::Skipped => run.skipped += 1,
            Probed::Done { media, audio_dropped } => {
                run.results[i] = Some((url.clone(), Some(*media)));
                if let Some(codec) = audio_dropped {
                    run.audio_dropped.push((i, FileCodec { file: file_name(&url), codec }));
                }
            }
            Probed::Unsupported(codec) => {
                run.results[i] = Some((url.clone(), None));
                run.unsupported_at.push((i, FileCodec { file: file_name(&url), codec }));
            }
            Probed::Failed(reason) => {
                run.results[i] = Some((url.clone(), None));
                if let Some(r) = reason {
                    run.reasons.insert(i, r);
                }
            }
        }
        self.pending_imports -= 1;
        if run.progressive
            && let Some(r) = run.plan.finished(i as i64, self.deps.mono.now())
        {
            self.land(session, run, r);
        }
    }

    /// Adds the probed items of `range` to the project (one commit; with a coalescing key while the import runs).
    fn land(&mut self, session: &mut EditorSession, run: &mut ImportRun, range: Range<usize>) {
        let batch: Vec<(PathBuf, MediaRef)> = range
            .filter_map(|i| run.results[i].as_ref().and_then(|(u, r)| r.clone().map(|r| (u.clone(), r))))
            .collect();
        // Imported files may live elsewhere now (Files folder): callers look the item up by the path they passed.
        for (url, r) in &batch {
            let id = self.project.media.iter().find(|m| m.path == r.path).map_or(r.id, |m| m.id);
            self.imported_ids.insert(path_key(url), id);
        }
        if batch.is_empty() {
            return;
        }
        run.landed += batch.len() as i64;
        let dest = if run.progressive { run.start_bin } else { self.current_bin };
        let name =
            if run.landed == 1 { "Import Media".to_string() } else { format!("Import {} Media Items", run.landed) };
        let key = run.progressive.then(|| run.key.clone());
        let mut resolved = Vec::new();
        let mut landed_files = Vec::new();
        let folder = self.project_folder.as_ref().map(|f| f.to_string_lossy().into_owned());
        self.commit(session, &name, key.as_deref(), |p, _| {
            if let Some(folder) = folder.as_deref() {
                for (_, r) in &batch {
                    p.unignore_folder_file(&r.path, folder);
                }
            }
            // Another import of the same file may have finished while this one probed.
            let present: BTreeSet<String> = p.media.iter().map(|m| m.path.clone()).collect();
            let fresh: Vec<&MediaRef> = batch.iter().map(|(_, r)| r).filter(|r| !present.contains(&r.path)).collect();
            for (url, r) in &batch {
                resolved.push((path_key(url), p.media.iter().find(|m| m.path == r.path).map_or(r.id, |m| m.id)));
            }
            if fresh.is_empty() {
                return false;
            }
            for r in &fresh {
                p.add((*r).clone());
            }
            for (url, r) in &batch {
                if r.path == path_key(url) && fresh.iter().any(|f| f.id == r.id) {
                    landed_files.push(ImportedFile { id: r.id, url: url.clone() });
                }
            }
            if p.bin(dest).is_some() && dest != p.root_bin.id {
                let refs: Vec<BinItemRef> = fresh.iter().map(|r| BinItemRef::Media(r.id)).collect();
                p.move_items(&refs, dest, None);
            }
            true
        });
        self.imported_ids.extend(resolved);
        run.landed_files.extend(landed_files);
    }

    /// Everything after the probes: the last commit, the lists, the report and the hooks.
    fn finish_import(&mut self, session: &mut EditorSession, mut run: ImportRun) {
        let n = run.todo.len();
        if run.progressive {
            if let Some(r) = run.plan.flush() {
                self.land(session, &mut run, r);
            }
        } else {
            self.land(session, &mut run, 0..n);
        }
        self.import_tokens.remove(&run.token_key);
        if self.import_tokens.is_empty() {
            self.import_total = 0;
        }
        if run.skipped > 0 {
            self.import_canceled = Some((run.landed, n as i64));
        }
        run.unsupported_at.sort_by_key(|(i, _)| *i);
        let unsupported: Vec<FileCodec> = run.unsupported_at.iter().map(|(_, f)| f.clone()).collect();
        self.unsupported_imports = unsupported.clone();
        self.import_failures = run
            .results
            .iter()
            .flatten()
            .filter(|(_, r)| r.is_none())
            .map(|(u, _)| file_name(u))
            .filter(|name| !unsupported.iter().any(|u| &u.file == name))
            .collect();
        self.import_failure_reasons = run
            .todo
            .iter()
            .enumerate()
            .filter_map(|(i, u)| run.reasons.get(&i).map(|r| FileReason { file: file_name(u), reason: r.clone() }))
            .collect();
        run.audio_dropped.sort_by_key(|(i, _)| *i);
        self.audio_dropped_imports = run.audio_dropped.iter().map(|(_, f)| f.clone()).collect();
        let mut report = run.report;
        report.imported = run.landed;
        report.canceled = run.skipped > 0;
        report.failed = self
            .import_failure_reasons
            .iter()
            .map(|f| ImportReportEntry::new(f.file.clone(), f.reason.clone()))
            .collect();
        // A failure without a reason (a probe that returned nothing) still counts as unreadable.
        for name in &self.import_failures {
            if !report.failed.iter().any(|f| &f.file == name) {
                report.failed.push(ImportReportEntry::new(name.clone(), "Could not be read."));
            }
        }
        report.unsupported =
            unsupported.iter().map(|u| ImportReportEntry::new(u.file.clone(), u.codec.clone())).collect();
        report.audio_dropped = self
            .audio_dropped_imports
            .iter()
            .map(|u| ImportReportEntry::new(u.file.clone(), u.codec.clone()))
            .collect();
        self.last_import_report = Some(report);
        if !unsupported.is_empty() {
            self.events.push(ProjectPanelEvent::Unsupported(unsupported));
        }
        if !self.audio_dropped_imports.is_empty() {
            self.events.push(ProjectPanelEvent::AudioDropped(self.audio_dropped_imports.clone()));
        }
        if run.landed == 0 {
            self.version += 1;
            return;
        }
        self.schedule_offline_refresh();
        if !run.landed_files.is_empty() {
            self.events.push(ProjectPanelEvent::Imported { files: run.landed_files, pointer: run.pointer });
        }
    }
}

/// Probes one file on a worker. Canceled before its turn: not probed. The original is probed first, so a file that
/// cannot be read is never copied, moved or trashed.
async fn probe_one(
    backend: Arc<dyn ImportBackend>,
    pool: Arc<WorkerPool>,
    token: Arc<AtomicBool>,
    _index: usize,
    url: PathBuf,
    frames: Option<Vec<PathBuf>>,
) -> Probed {
    if token.load(Ordering::SeqCst) {
        return Probed::Skipped;
    }
    let job = pool.run(move |_| {
        let result = match &frames {
            Some(f) => backend.probe_sequence(f),
            None => backend.probe(&url),
        };
        match result {
            Ok(media) => {
                let audio_dropped = backend.take_audio_dropped(&url);
                Probed::Done { media: Box::new(media), audio_dropped }
            }
            Err(ImportError::UnsupportedCodec(codec)) => Probed::Unsupported(codec),
            Err(e) => Probed::Failed(backend.failure_reason(&url, &e)),
        }
    });
    job.await.unwrap_or(Probed::Failed(None))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use sq_core_model::{Bin, BinItem, MediaFingerprint, MediaRef, Project};
    use sq_core_time::Id;

    use super::super::{ProjectPanelDeps, ProjectPanelModel};
    use crate::{EditorSession, SessionDeps};

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn media(n: u128, path: &str) -> MediaRef {
        MediaRef::new(id(n), path.rsplit('/').next().unwrap_or(path), path, MediaFingerprint::new(1))
    }

    fn session(p: Project) -> EditorSession {
        EditorSession::new(p, SessionDeps::headless(std::env::temp_dir().join("sq-es07-filing-autosave")))
    }

    fn path(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    /// The nested bin `name` directly inside `parent`.
    fn bin<'a>(parent: &'a Bin, name: &str) -> Option<&'a Bin> {
        parent.children.iter().find_map(|item| match item {
            BinItem::Bin(b) if b.name == name => Some(b),
            _ => None,
        })
    }

    /// The media ids directly inside `b`.
    fn media_in(b: &Bin) -> Vec<Id> {
        b.children.iter().filter_map(|item| if let BinItem::Media(m) = item { Some(*m) } else { None }).collect()
    }

    #[test]
    fn file_into_bins_mirrors_folders_as_nested_bins() {
        let pre = media(4, "/shoot/Day 1/pre.mov");
        let p = Project::new(
            id(1000),
            "P",
            vec![
                media(1, "/shoot/Day 1/A-cam/a.mov"),
                media(2, "/shoot/Day 1/B-cam/b.mov"),
                media(3, "/shoot/Day 2/c.mov"),
                pre,
            ],
            vec![],
        );
        let mut s = session(p.clone());
        let mut m = ProjectPanelModel::new(p, ProjectPanelDeps::headless());
        let depth = s.undo_step_depth();

        let placements = vec![
            (PathBuf::from("/shoot/Day 1/A-cam/a.mov"), path(&["Day 1", "A-cam"])),
            (PathBuf::from("/shoot/Day 1/B-cam/b.mov"), path(&["Day 1", "B-cam"])),
            (PathBuf::from("/shoot/Day 2/c.mov"), path(&["Day 2"])),
            // Already in the project at the root: it moves into the mirrored bin.
            (PathBuf::from("/shoot/Day 1/pre.mov"), path(&["Day 1"])),
            // Not in the project: skipped.
            (PathBuf::from("/shoot/missing.mov"), path(&["Missing"])),
        ];
        assert!(m.file_into_bins(&mut s, &placements));

        let root = &s.project().root_bin;
        assert!(root.children.iter().all(|c| !matches!(c, BinItem::Media(_))), "no media stays at the root");
        let day1 = bin(root, "Day 1").expect("Day 1 bin");
        let day2 = bin(root, "Day 2").expect("Day 2 bin");
        assert!(bin(root, "Missing").is_none(), "a file not in the project makes no bin");
        assert_eq!(media_in(day2), vec![id(3)]);
        assert_eq!(media_in(day1), vec![id(4)], "pre.mov moved into Day 1");
        let a_cam = bin(day1, "A-cam").expect("nested A-cam bin");
        let b_cam = bin(day1, "B-cam").expect("nested B-cam bin");
        assert_eq!(media_in(a_cam), vec![id(1)]);
        assert_eq!(media_in(b_cam), vec![id(2)]);
        assert_eq!(s.undo_step_depth(), depth + 1, "filing is one undo step");
        assert_eq!(s.undo_name(), Some("Import Folder"));

        // One undo removes the filing: every file is back at the root, the bins are gone.
        assert!(s.undo());
        assert_eq!(s.undo_step_depth(), depth);
        let root = &s.project().root_bin;
        let at_root: Vec<Id> =
            root.children.iter().filter_map(|c| if let BinItem::Media(m) = c { Some(*m) } else { None }).collect();
        assert_eq!(at_root.len(), 4);
        assert!(bin(root, "Day 1").is_none() && bin(root, "Day 2").is_none());
    }
}
