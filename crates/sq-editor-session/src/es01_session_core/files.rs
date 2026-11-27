//! Files: save, save as, copy, open, replace the project, autosave and recovery, notes, source marks, relink.
//!
//! // shortcut: Swift's `async` file work (writes, reads, probes) runs here on the calling thread; the app calls these
//! from a worker-pool job and routes the result back as an inbox message. The `Task`-driven autosave timer is the
//! app's: it calls `tick_autosave` every `check_every` seconds (`start_autosave_timer` only stops a stored task).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use sq_core_color::ProjectGradeLinksExt;
use sq_core_edit::playback_bounds::PlaybackBounds;
use sq_core_file::{ProjectFile, ProjectFileError, ProjectSalvageReport, converted_path, is_legacy_path};
use sq_core_graphics::format_variants_view::TimelineVariantsExt;
use sq_core_model::{ColorSpaceID, Marker, MediaRef, Project, SourceMarks};

use sq_core_project::recovery::{AutosaveStore, AutosaveVersion, RecoveryCandidate, RecoveryScanner, SessionMarker};
use sq_core_project::relink::ProjectRelinkExt;
use sq_core_time::{Id, IdSource, Time, Timestamp};

use super::{ProjectSaveQueue, SequenceTabs};
use crate::{Change, EditorSession, SaveError, SessionEvent};

impl ProjectSaveQueue {
    /// Reads a project that does not decode as a whole: the rest is salvaged and listed in the report.
    // Swift: ProjectSaveQueue.swift:21
    pub fn read_salvaging(&self, path: &Path) -> Result<(Project, ProjectSalvageReport), ProjectFileError> {
        sq_core_project::project_file::project_file().read_salvaging(path)
    }

    /// The project of a recovery candidate.
    // Swift: ProjectSaveQueue.swift:24
    pub fn recover(
        &self,
        candidate: &RecoveryCandidate,
        scanner: &RecoveryScanner<'_>,
    ) -> Result<Project, ProjectFileError> {
        scanner.recover(candidate)
    }

    /// Writes an autosave version (or a named checkpoint) of the project.
    // Swift: ProjectSaveQueue.swift:28
    pub fn autosave(
        &self,
        project: &Project,
        store: &AutosaveStore,
        date: Timestamp,
        name: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<AutosaveVersion, ProjectFileError> {
        store.write(project, date, name, ids)
    }
}

/// Recovery snapshots between the timed autosave versions: what the last one wrote, what the project looked like at
/// the last poll, and the write that is still running on its worker thread.
// Swift: EditorSession+Recovery.swift:11
#[derive(Debug, Default)]
pub struct RecoverySnapshotState {
    project_id: Option<Id>,
    /// What the last started snapshot holds.
    last_project: Option<Project>,
    last_path: Option<PathBuf>,
    /// The project as the last poll saw it, and when it last differed from the poll before.
    observed: Option<Project>,
    changed_at: Option<Timestamp>,
    /// When the project first differed from the last snapshot (the longest a steady stream of edits waits).
    first_change: Option<Timestamp>,
    in_flight: Option<InFlight>,
    /// The last poll saw an edit that no snapshot holds yet: the loop must poll again by itself.
    waiting: bool,
}

#[derive(Debug)]
struct InFlight {
    project_id: Id,
    done: std::sync::mpsc::Receiver<Option<AutosaveVersion>>,
}

/// An id source that hands out one id: the temp package name, drawn on the UI thread for the worker.
struct OneId(Option<Id>);

impl IdSource for OneId {
    fn next_id(&mut self) -> Id {
        self.0.take().unwrap_or(Id::fixed(0))
    }
}

impl RecoverySnapshotState {
    // Swift: EditorSession+Recovery.swift:14
    pub fn new() -> RecoverySnapshotState {
        RecoverySnapshotState::default()
    }

    /// Takes in a finished write: remembers its path, or forgets the snapshot when it failed so the next poll retries.
    fn poll_done(&mut self, block: bool) {
        let Some(flight) = &self.in_flight else { return };
        let result = if block { flight.done.recv().ok() } else { flight.done.try_recv().ok() };
        let Some(result) = result else {
            if matches!(flight.done.try_recv(), Err(std::sync::mpsc::TryRecvError::Disconnected)) {
                self.in_flight = None; // the worker died
                self.last_project = None;
            }
            return;
        };
        let same = self.project_id == Some(flight.project_id);
        self.in_flight = None;
        match result {
            Some(v) if same => self.last_path = Some(v.path),
            Some(_) => {}
            None => self.last_project = None,
        }
    }

    /// Waits for the running write (tests; the app polls).
    pub fn finish_pending(&mut self) {
        self.poll_done(true);
    }

    /// Whether the app must keep polling: an edit waits for its debounce, or a write is running. While the window is idle
    /// nothing else wakes the loop, so the debounce would not fire until the next input.
    pub fn needs_poll(&self) -> bool {
        self.waiting || self.in_flight.is_some()
    }

    /// Whether a write is running.
    pub fn is_writing(&self) -> bool {
        self.in_flight.is_some()
    }
}

/// The longest a steady stream of edits (a drag) waits for a snapshot, in seconds.
const RECOVERY_MAX_WAIT: f64 = 5.0;

impl EditorSession {
    pub(crate) fn begin_marker(&mut self) {
        let (id, name) = (self.project().id, self.project().name.clone());
        let now = (self.clock)();
        let _ = SessionMarker::new(&self.autosave_store).begin(
            id,
            self.file_url.as_deref(),
            &name,
            std::process::id() as i32,
            now,
            None,
        );
    }

    /// The session clock (wall time in the app, injected in tests).
    pub fn now(&self) -> Timestamp {
        (self.clock)()
    }

    fn end_marker(&self) {
        SessionMarker::new(&self.autosave_store).end(self.project().id, std::process::id() as i32);
    }

    /// Ends the crash marker and the autosave timer. Call on a clean quit or before replacing the session.
    // Swift: EditorSession.swift:339
    pub fn close(&mut self) {
        self.stop_autosave_timer();
        self.end_marker();
        self.emit(SessionEvent::ProjectReplaced);
        let (p, dirty) = (self.project().clone(), self.is_dirty());
        self.emit(SessionEvent::ReleaseProject { project: Box::new(p), was_dirty: dirty });
    }

    /// The project as it is written: with the active sequence and variants. Returns (history state, file state).
    // Swift: EditorSession.swift:1751
    fn snapshot_for_save(&self) -> (Project, Project) {
        let base = self.history.current().clone();
        let mut file = base.clone();
        file.active_timeline = self.active_timeline_id;
        file.active_variants = self
            .active_variants
            .iter()
            .filter(|(t, v)| file.timeline(**t).is_some_and(|tl| tl.variant(Some(**v)).is_some()))
            .map(|(t, v)| (*t, *v))
            .collect();
        (base, file)
    }

    /// Writes the project to its file. A project opened from a legacy file is written to a sibling and says so.
    // Swift: EditorSession.swift:1759
    pub fn save(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let Some(url) = self.file_url.clone() else { return Err(SaveError::NoFileURL.into()) };
        // A project opened from a legacy file is written to a sibling `.sqproj`; the old file stays untouched.
        if is_legacy_path(&url) {
            let target = converted_path(&url);
            self.save_as(&target)?;
            let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            self.set_error(format!("Saved as “{}”; the old “{}” was left in place.", name(&target), name(&url)));
            return Ok(());
        }
        self.write_to(&url)
    }

    // Swift: EditorSession.swift:1770
    pub fn save_as(&mut self, url: &Path) -> Result<(), Box<dyn std::error::Error>> {
        self.write_to(url)?;
        self.file_url = Some(url.to_path_buf());
        self.media.set_project_folder(url.parent().map(Path::to_path_buf));
        self.begin_marker();
        self.notify(Change::PROJECT);
        Ok(())
    }

    /// Saves a copy under another name; the open project stays where it is.
    // Swift: EditorSession.swift:1782
    pub fn save_copy(&mut self, url: &Path) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(current) = self.file_url.clone()
            && current == url
            && !is_legacy_path(&current)
        {
            return self.save();
        }
        let swaps = self.collect_luts(url);
        let mut file = self.snapshot_for_save().1;
        file.replace_lut_paths(|p| swaps.get(p).cloned());
        file.id = self.ids.next_id();
        if let Some(policy) = file.media_policy.as_mut() {
            policy.watch_folder = Some(false);
        }
        let result = self.protect_salvaged_original(url).and_then(|()| self.save_queue.write(&file, url));
        if let Err(e) = result {
            self.set_error(format!("Could not save a copy:{e}"));
            return Err(e.into());
        }
        Ok(())
    }

    /// Part of a save into the project file: with the copy setting on (project policy over the app default) and a
    /// project folder around `url`, every LUT a grade uses from outside that folder is copied into `Files/Library/`
    /// (identical content is reused). Returns old path -> copy path; a LUT that cannot be read stays as it is.
    // Swift: EditorSession+Shell.swift:14 (`collectLUTs(forSaveAt:)`)
    pub(crate) fn collect_luts(&self, url: &Path) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        let stem = url.file_stem();
        let folder = match url.parent() {
            Some(f) if stem.is_some() && f.file_name() == stem => f,
            _ => return out,
        };
        let copies = self
            .project()
            .media_policy
            .as_ref()
            .and_then(|m| m.copy_library_items)
            .unwrap_or_else(|| self.media_policy_defaults().copy_library_items);
        if !copies {
            return out;
        }
        let library = folder.join("Files").join("Library");
        for p in self.history.current().referenced_lut_files() {
            if p.starts_with('/')
                && !sq_media::media_file_ops::MediaManagement::is_inside(&p, folder)
                && let Ok(r) = sq_media::media_file_ops::MediaFileOps::collect_lut(Path::new(&p), &library)
            {
                out.insert(p, r.url.to_string_lossy().into_owned());
            }
        }
        out
    }

    // Swift: EditorSession.swift:1796
    fn write_to(&mut self, url: &Path) -> Result<(), Box<dyn std::error::Error>> {
        let swaps = self.collect_luts(url);
        let (base, mut file) = self.snapshot_for_save();
        file.replace_lut_paths(|p| swaps.get(p).cloned()); // the file holds the copies; the open project follows after the write
        let result = self.protect_salvaged_original(url).and_then(|()| self.save_queue.write(&file, url));
        if let Err(e) = result {
            self.set_error(format!("Could not save:{e}"));
            return Err(e.into());
        }
        // The written state is the saved one (undo during the write leaves the project dirty); edits keep it dirty.
        let unchanged = *self.history.current() == base;
        self.history.mark_saved_state(base);
        let dirty_before = self.force_dirty;
        if !swaps.is_empty() {
            self.amend_project(|p| p.replace_lut_paths(|q| swaps.get(q).cloned())); // also moves the saved state along
        }
        self.force_dirty = if unchanged { false } else { dirty_before };
        self.notify(Change::PROJECT);
        self.emit(SessionEvent::Saved(Box::new(file)));
        Ok(())
    }

    /// Opens a project file. A damaged one is salvaged into an unsaved project and the report returned.
    // Swift: EditorSession.swift:1824
    pub fn open(&mut self, url: &Path) -> Result<Option<ProjectSalvageReport>, Box<dyn std::error::Error>> {
        match self.save_queue.read(url) {
            Ok(p) => {
                sq_core_time::milestones::mark("project file read and migrated");
                self.replace_with(p, Some(url.to_path_buf()), false, None);
                Ok(None)
            }
            Err(e) => {
                if e == ProjectFileError::Corrupt
                    && let Ok((project, report)) = self.save_queue.read_salvaging(url)
                    && !report.is_empty()
                {
                    self.replace_with(project, None, true, Some(url));
                    self.salvaged_from = Some(url.to_path_buf());
                    self.salvage_report = Some(report.clone());
                    return Ok(Some(report));
                }
                self.set_error(format!("Could not open: {e}"));
                Err(e.into())
            }
        }
    }

    /// The damaged file this project was repaired from, until the first save: the project has no file of its own then, so
    /// Save asks for a place, and writing to this very path first keeps the old file as `<name>.damaged.bak`.
    pub fn salvaged_from(&self) -> Option<&Path> {
        self.salvaged_from.as_deref()
    }

    /// What the repair of [`Self::salvaged_from`] left out (the same report `open` returned), until the project is replaced.
    pub fn salvage_report(&self) -> Option<&ProjectSalvageReport> {
        self.salvage_report.as_ref()
    }

    fn protect_salvaged_original(&mut self, url: &Path) -> Result<(), ProjectFileError> {
        let Some(from) = self.salvaged_from.clone() else { return Ok(()) };
        if from != url {
            return Ok(());
        }
        ProjectFile::back_up_damaged(&from)?;
        self.salvaged_from = None;
        Ok(())
    }

    /// Project notes: one undo step.
    // Swift: EditorSession.swift:1847
    pub fn set_project_notes(&mut self, text: &str) {
        if self.project().notes() == text {
            return;
        }
        self.perform(Self::PROJECT_NOTES_UNDO_NAME, None, |p| p.set_notes(text));
    }

    pub const PROJECT_NOTES_UNDO_NAME: &'static str = "Edit Project Notes";

    /// Replaces the open project by a new one (a fresh untitled one by default).
    // Swift: EditorSession.swift:1853
    pub fn new_project(&mut self, project: Project) {
        self.replace_with(project, None, false, None);
    }

    /// Open, new, import, revert, close: everything of the old project stops, the new one starts clean.
    fn replace_with(&mut self, p: Project, url: Option<PathBuf>, dirty: bool, media_folder_of: Option<&Path>) {
        self.end_marker();
        self.emit(SessionEvent::ProjectReplaced); // background work of the old project stops
        let (old, was_dirty) = (self.project().clone(), self.is_dirty());
        self.emit(SessionEvent::ReleaseProject { project: Box::new(old), was_dirty });
        let first = p
            .active_timeline
            .filter(|id| p.timeline(*id).is_some())
            .or_else(|| p.timelines.iter().find(|t| !t.is_group()).map(|t| t.id));
        self.history = sq_core_edit::history::History::with_default_limit(p);
        self.salvaged_from = None;
        self.salvage_report = None;
        self.playhead_steps.clear();
        self.held_playhead_steps.clear();
        self.side_steps.clear();
        self.file_url = url;
        let folder = media_folder_of.or(self.file_url.as_deref()).and_then(Path::parent).map(Path::to_path_buf);
        self.media.set_project_folder(folder);
        self.force_dirty = dirty;
        self.active_timeline_id = first;
        self.active_variants = self.project().active_variants.clone();
        self.set_selection_raw(BTreeSet::new());
        self.caption_selection.clear();
        self.sequence_tabs = SequenceTabs::new();
        if let Some(id) = first {
            self.sequence_tabs.open(id);
        }
        if self.is_playing || !self.engine.rate().is_paused() {
            self.engine.pause();
            self.is_playing = false;
        }
        self.reset_follow();
        self.set_bounds(PlaybackBounds::default());
        self.clipboard = None; // its clips refer to media of the old project
        self.playhead = Time::ZERO;
        self.last_autosave = None;
        self.media_snapshot = Default::default();
        self.requested_media.clear();
        self.begin_marker();
        sq_core_time::milestones::mark("replace: state reset");
        self.sync_media();
        sq_core_time::milestones::mark("replace: media synced");
        // A project without media skips sync_media's proxy sync: its mode still applies and the old project's jobs stop.
        let (media, id) = (self.project().media.to_vec(), self.project().id);
        if let Some(a) = self.auto_proxy.as_mut()
            && a.project_id() != Some(id)
        {
            a.sync(&media, Some(id), None);
            self.apply_proxy_effects();
        }
        self.push_timeline(true);
        sq_core_time::milestones::mark("replace: timeline pushed");
        self.engine.seek(Time::ZERO);
        sq_core_time::milestones::mark("replace: engine seek returned");
        // The old project's message (a failed open before this one) must not stay on the status line.
        self.clear_error();
        self.notify(Change::PROJECT | Change::SELECTION | Change::PLAYHEAD);
        sq_core_time::milestones::mark("replace: notified");
        self.detect_missing_color();
        sq_core_time::milestones::mark("replace: color detection done");
        self.refresh_missing_sound_info();
        self.refresh_missing_shoot_info();
        sq_core_time::milestones::mark("replace: missing info done");
    }

    pub const PROJECT_INPUT_COLOR_UNDO_NAME: &'static str = "Set Project Input Color Space";

    // Swift: EditorSession.swift:1898
    pub fn set_project_input_color_space(&mut self, space: Option<ColorSpaceID>) {
        if self.project().input_color_space == space {
            return;
        }
        self.perform(Self::PROJECT_INPUT_COLOR_UNDO_NAME, None, |p| p.input_color_space = space);
    }

    /// The platform's color detection for media saved before detection existed; runs it once now.
    // Swift: EditorSession.swift:316
    pub fn install_color_detector(&mut self, detect: crate::session::ColorDetector) {
        self.color_detector = detect;
        self.detect_missing_color();
    }

    /// Detects the color space of media saved without one (blocking; see the module note).
    // Swift: EditorSession.swift:1905
    pub fn detect_missing_color(&mut self) {
        let pending: Vec<MediaRef> = self
            .project()
            .media
            .iter()
            .filter(|m| m.info.as_ref().is_some_and(|i| i.needs_color_detection() && i.video.is_some()))
            .cloned()
            .collect();
        if pending.is_empty() {
            return;
        }
        let mut changed = false;
        for r in pending {
            if !Path::new(&r.path).exists() {
                continue;
            }
            let Some(found) = (self.color_detector)(Path::new(&r.path)) else { continue };
            self.history.amend_all(|p| {
                if let Some(i) = p.media.iter().position(|m| m.id == r.id && m.path == r.path)
                    && let Some(info) = p.media[i].info.as_mut()
                {
                    info.detected_color_space = Some(found.space);
                    info.embedded_lut_name = found.embedded_lut_name.clone();
                }
            });
            changed = true;
        }
        if changed {
            self.project_did_change();
        }
    }

    /// Counts the sound of media saved before the sound was counted across tracks (blocking probe).
    // Swift: EditorSession.swift:1929
    pub fn refresh_missing_sound_info(&mut self) {
        let pending: Vec<MediaRef> = self
            .project()
            .media
            .iter()
            .filter(|m| {
                m.info.as_ref().is_some_and(|i| {
                    !i.is_still
                        && i.sound_probed != Some(true)
                        && i.audio.as_ref().is_none_or(|a| a.first_track_channels.is_none())
                })
            })
            .cloned()
            .collect();
        if pending.is_empty() {
            return;
        }
        let mut probed: BTreeMap<Id, sq_core_model::MediaInfo> = BTreeMap::new();
        for r in &pending {
            if !Path::new(&r.path).exists() {
                continue;
            }
            if let Some(info) = (self.media_info_probe)(Path::new(&r.path)) {
                probed.insert(r.id, info);
            }
        }
        if probed.is_empty() {
            return;
        }
        self.history.amend_all(|p| {
            let here: BTreeMap<Id, sq_core_model::MediaInfo> = probed
                .iter()
                .filter(|(id, _)| {
                    pending.iter().any(|q| q.id == **id && p.media.iter().any(|m| m.id == q.id && m.path == q.path))
                })
                .map(|(id, i)| (*id, i.clone()))
                .collect();
            p.fit_audio_channel_maps(&here);
            for m in p.media.iter_mut() {
                if probed.contains_key(&m.id)
                    && pending.iter().any(|q| q.id == m.id && q.path == m.path)
                    && let Some(info) = m.info.as_mut()
                {
                    info.sound_probed = Some(true);
                }
            }
        });
        self.project_did_change();
    }

    /// Shooting date and camera are read on the Mac only (Swift `#if os(macOS)`); nothing to do elsewhere.
    // Swift: EditorSession.swift:1960
    pub fn refresh_missing_shoot_info(&mut self) {}

    // Swift: EditorSession.swift:1988
    pub fn set_source_marks(&mut self, marks: Option<SourceMarks>, media: Id) {
        let value = marks.filter(|m| !m.is_empty());
        if self.project().source_marks.get(&media) == value.as_ref() {
            return;
        }
        self.history.amend_all(|p| match &value {
            Some(v) => {
                p.source_marks.insert(media, v.clone());
            }
            None => {
                p.source_marks.remove(&media);
            }
        });
        self.force_dirty = true;
        self.notify(Change::PROJECT);
    }

    // Swift: EditorSession.swift:1996
    pub fn set_source_markers(&mut self, markers: Option<Vec<Marker>>, media: Id) {
        let value = markers.filter(|m| !m.is_empty());
        if self.project().media(media).is_some_and(|m| m.source_markers == value) {
            return;
        }
        self.history.amend_all(|p| {
            if let Some(m) = p.media.iter_mut().find(|m| m.id == media) {
                m.source_markers = value.clone();
            }
        });
        self.force_dirty = true;
        self.notify(Change::PROJECT);
    }

    /// Media whose file is not at its path.
    // Swift: EditorSession.swift:813
    pub fn missing_media(&self) -> Vec<MediaRef> {
        self.with_missing_media(|m| m.to_vec())
    }

    /// How long a `stat()` pass over the media stays valid when nothing was notified (a file deleted outside the app).
    pub(crate) const MISSING_MEDIA_TTL: std::time::Duration = std::time::Duration::from_secs(1);

    /// Runs `f` on the offline media. The files are `stat()`ed again only after a project/media change or after
    /// `MISSING_MEDIA_TTL`, never per call (the shell menus ask on every frame).
    pub(crate) fn with_missing_media<T>(&self, f: impl FnOnce(&[MediaRef]) -> T) -> T {
        let key = (self.version(crate::Change::PROJECT), self.version(crate::Change::MEDIA));
        let id = self.project().id;
        let mut slot = self.missing_media_cache.lock().unwrap_or_else(|e| e.into_inner());
        let fresh = slot
            .as_ref()
            .is_some_and(|c| c.project == id && c.versions == key && c.at.elapsed() < Self::MISSING_MEDIA_TTL);
        if !fresh {
            *slot = Some(crate::session::MissingMediaCache {
                project: id,
                versions: key,
                at: std::time::Instant::now(),
                missing: self.project().missing_media(),
            });
        }
        f(slot.as_ref().map(|c| c.missing.as_slice()).unwrap_or_default())
    }

    /// Points media at new files: one undo step. Media without probe info is probed afterwards.
    // Swift: EditorSession.swift:816
    pub fn relink_media(&mut self, paths: &BTreeMap<Id, String>, name: &str) {
        if paths.is_empty() {
            return;
        }
        for id in paths.keys() {
            self.requested_media.remove(id); // so `sync_media` prepares them again
        }
        self.perform(name, None, |p| p.relink(paths, &BTreeMap::new()));
        self.probe_unprobed(paths);
    }

    /// Like `relink_media`, but no undo step and the project does not become dirty.
    // Swift: EditorSession.swift:845
    pub fn relink_media_quietly(&mut self, paths: &BTreeMap<Id, String>) {
        if paths.is_empty() {
            return;
        }
        for id in paths.keys() {
            self.requested_media.remove(id);
        }
        self.amend_project(|p| p.relink(paths, &BTreeMap::new()));
        self.probe_unprobed(paths);
    }

    /// Probes relinked media that has no info yet and folds the result into every undo state.
    fn probe_unprobed(&mut self, paths: &BTreeMap<Id, String>) {
        let ids = self.project().media_awaiting_probe(paths);
        if ids.is_empty() {
            return;
        }
        let mut found = BTreeMap::new();
        for id in ids {
            if let Some(info) = paths.get(&id).and_then(|p| (self.media_info_probe)(Path::new(p))) {
                found.insert(id, info);
            }
        }
        if found.is_empty() {
            return;
        }
        let before = self.history.current().clone();
        // shortcut: the file fingerprint (size, date) is not stored here; the media watcher (ES8) records it.
        self.history.amend_all(|p| {
            p.adopt_probed_info(&found, &BTreeMap::new());
            p.fit_audio_channel_maps(&found);
        });
        if *self.history.current() != before {
            self.force_dirty = true; // amended undo/redo states alone save nothing new
        }
        for id in found.keys() {
            self.requested_media.remove(id);
        }
        self.project_did_change();
    }

    /// Changes the project in every undo state without an undo step (probe results, relinks). True when it changed.
    // Swift: EditorSession.swift:835
    pub fn amend_project(&mut self, change: impl FnMut(&mut Project)) -> bool {
        let before = self.history.current().clone();
        self.history.amend_all(change);
        let changed = *self.history.current() != before;
        if changed {
            self.force_dirty = true;
            self.project_did_change();
            self.notify(Change::PROJECT);
        }
        changed
    }

    /// Defaults for the media policy of new projects (the app reads them from its settings).
    // Swift: EditorSession.swift:830
    pub fn media_policy_defaults(&self) -> crate::MediaPolicyDefaults {
        (self.media_policy_defaults)()
    }
    pub fn set_media_policy_defaults(&mut self, f: Box<dyn Fn() -> crate::MediaPolicyDefaults>) {
        self.media_policy_defaults = f;
    }

    // MARK: Autosave and recovery

    /// One autosave poll: writes a version when the policy says so. Returns whether one was written.
    // Swift: EditorSession.swift:2010
    pub fn tick_autosave(&mut self) -> bool {
        let now = (self.clock)();
        if !self.autosave_store.policy.should_autosave(self.is_dirty(), self.last_autosave, now) {
            return false;
        }
        let (_, file) = self.snapshot_for_save();
        let result = self.with_save_parts(|queue, store, ids| queue.autosave(&file, store, now, None, ids));
        self.forget_autosave_listing(); // a write also prunes old versions
        match result {
            Ok(_) => {
                self.last_autosave = Some(now);
                self.notify(Change::STATUS); // the status bar's "Edited · Backup 14:32" follows at once
                true
            }
            Err(e) => {
                self.set_error(format!("Autosave failed: {e}"));
                false
            }
        }
    }

    /// A named checkpoint version. `None` when the name is not usable or the write failed.
    // Swift: EditorSession.swift:2032
    pub fn save_checkpoint(&mut self, name: &str) -> Option<AutosaveVersion> {
        AutosaveStore::sanitized(name)?;
        let (_, file) = self.snapshot_for_save();
        let now = (self.clock)();
        let written = self.with_save_parts(|queue, store, ids| queue.autosave(&file, store, now, Some(name), ids));
        self.forget_autosave_listing();
        match written {
            Ok(v) => Some(v),
            Err(e) => {
                self.set_error(format!("Checkpoint failed: {e}"));
                None
            }
        }
    }

    fn with_save_parts<R>(&mut self, f: impl FnOnce(&ProjectSaveQueue, &AutosaveStore, &mut dyn IdSource) -> R) -> R {
        f(&self.save_queue, &self.autosave_store, self.ids.as_mut())
    }

    /// Stops a stored autosave task. The poll itself is the app's timer calling `tick_autosave` (module note).
    // Swift: EditorSession.swift:2045
    pub fn start_autosave_timer(&mut self, _check_every: std::time::Duration) {
        self.stop_autosave_timer();
    }

    // Swift: EditorSession.swift:2056
    pub fn stop_autosave_timer(&mut self) {
        if let Some(task) = self.autosave_task.take() {
            task.cancel();
        }
    }

    /// Projects the previous run left unsaved.
    // Swift: EditorSession.swift:2060
    pub fn recovery_candidates(scanner: &RecoveryScanner<'_>, now: Timestamp) -> Vec<RecoveryCandidate> {
        scanner.scan(now)
    }

    /// Replaces the open project by a recovery candidate (dirty, at its old place when that file exists).
    // Swift: EditorSession.swift:2066
    pub fn recover(
        &mut self,
        candidate: &RecoveryCandidate,
        scanner: &RecoveryScanner<'_>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let p = match self.save_queue.recover(candidate, scanner) {
            Ok(p) => p,
            Err(e) => {
                self.set_error(format!("Could not recover: {e}"));
                return Err(e.into());
            }
        };
        let home = candidate.project_path.clone().filter(|u| u.exists());
        self.replace_with(p, home, true, None);
        scanner.dismiss(candidate);
        self.forget_autosave_listing(); // dismiss deletes the candidate's version
        Ok(())
    }

    // MARK: Recovery snapshots

    /// One poll: starts a recovery snapshot when the project changed and then stayed quiet for `quiet` seconds (or kept
    /// changing for `RECOVERY_MAX_WAIT`). The write runs on a worker thread, atomically (temp package, then rename), and
    /// replaces this run's previous snapshot. Returns whether a write was started.
    // Swift: EditorSession+Recovery.swift:20
    pub fn tick_recovery(&mut self, state: &mut RecoverySnapshotState, quiet: f64, now: Timestamp) -> bool {
        state.poll_done(false);
        state.waiting = false;
        if !self.is_dirty() {
            return false;
        }
        let id = self.project().id;
        if state.project_id != Some(id) {
            // Another project: its snapshot is not ours to replace.
            state.last_path = None;
            state.last_project = None;
            state.observed = None;
            state.first_change = None;
            state.project_id = Some(id);
        }
        let current = self.history.current();
        if state.observed.as_ref() != Some(current) {
            state.observed = Some(current.clone());
            state.changed_at = Some(now);
        }
        if state.last_project.as_ref() == Some(current) {
            state.first_change = None;
            return false;
        }
        let first = *state.first_change.get_or_insert(now);
        if state.in_flight.is_some() {
            state.waiting = true;
            return false;
        }
        let secs = |t: Option<Timestamp>| t.map_or(0.0, |t| now.unix_seconds() - t.unix_seconds());
        if secs(state.changed_at) < quiet && now.unix_seconds() - first.unix_seconds() < RECOVERY_MAX_WAIT {
            state.waiting = true;
            return false;
        }
        let snapshot = current.clone();
        let store = self.autosave_store.clone();
        let generation = std::sync::Arc::clone(&self.autosave_generation);
        let tmp_id = self.ids.next_id();
        let old = state.last_path.take();
        let (tx, rx) = std::sync::mpsc::channel();
        let job = snapshot.clone();
        let spawned = std::thread::Builder::new().name("sq-recovery-snapshot".into()).spawn(move || {
            let written = store.write(&job, now, None, &mut OneId(Some(tmp_id))).ok();
            if let Some(v) = &written
                && let Some(old) = old.filter(|o| *o != v.path)
            {
                // A project is a package folder or, where new projects are files, one file.
                let _ = if old.is_dir() { std::fs::remove_dir_all(&old) } else { std::fs::remove_file(&old) };
            }
            // Before the result is sent: whoever sees the write finished also sees a fresh listing.
            generation.fetch_add(1, std::sync::atomic::Ordering::Release);
            let _ = tx.send(written);
        });
        if spawned.is_err() {
            return false;
        }
        state.in_flight = Some(InFlight { project_id: id, done: rx });
        state.last_project = Some(snapshot);
        state.first_change = None;
        true
    }

    /// Polls every `poll` seconds; the app's timer calls `tick_recovery` (module note).
    // Swift: EditorSession+Recovery.swift:43
    pub fn start_recovery_timer(&mut self, _min_gap: f64, _poll: f64) -> RecoverySnapshotState {
        RecoverySnapshotState::new()
    }
}
