//! State and edit logic of the Project panel (Swift `ProjectPanelModel`). Holds a `Project` value; every mutating action
//! applies to a copy, reports it to the session (one undo step per action) and then adopts it. The app pushes external
//! changes (undo, open) in with [`ProjectPanelModel::set_project`].

use sq_core_audio::audio_channel_map::ProjectChannelMapExt as _;
use sq_core_edit::deinterlace::DeinterlaceExt as _;
use sq_core_edit::project_spoken_search::ProjectSpokenSearchExt as _;
use sq_core_edit::source_markers::SourceMarkersExt as _;
use sq_core_project::media_policy::ProjectFolderSyncExt as _;
use sq_core_project::smart_bin_matches::SmartBinMatchExt as _;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use sq_core_model::{
    AudioChannelMap, Bin, BinItem, BinItemRef, LabelColor, MediaFilterToken, MediaRef, MediaStatus, PixelAspect,
    Project, SmartBin, SmartBinKind, SmartBinUsage,
};
use sq_core_project::media_filter_tokens::MediaFilterQuery;
use sq_core_project::media_grouping::MediaGrouping;
use sq_core_project::relink_scoring::ProjectHealth;
use sq_core_time::text::{ci_contains, standard_compare};
use sq_core_time::{Id, IdSource, Time, Timestamp};
use sq_media::source_timecode::SourceTimecode;

use super::{ImportBackend, ImportReport, PanelCalendar, UtcCalendar};
use crate::EditorSession;

/// Columns the Project panel can show. `Name` is always shown, first.
// Swift: ProjectPanelModel.swift:18
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Column {
    Name,
    Label,
    FrameRate,
    Duration,
    Resolution,
    Codec,
    Audio,
    InPoint,
    FilePath,
    Format,
    SourceTimecode,
}

impl Column {
    /// Every column in menu order (Swift `allCases`).
    pub const ALL: [Column; 11] = [
        Column::Name,
        Column::Label,
        Column::FrameRate,
        Column::Duration,
        Column::Resolution,
        Column::Codec,
        Column::Audio,
        Column::InPoint,
        Column::FilePath,
        Column::Format,
        Column::SourceTimecode,
    ];

    /// The saved name (Swift `rawValue`).
    pub fn raw_value(self) -> &'static str {
        match self {
            Column::Name => "name",
            Column::Label => "label",
            Column::FrameRate => "frameRate",
            Column::Duration => "duration",
            Column::Resolution => "resolution",
            Column::Codec => "codec",
            Column::Audio => "audio",
            Column::InPoint => "inPoint",
            Column::FilePath => "filePath",
            Column::Format => "format",
            Column::SourceTimecode => "sourceTimecode",
        }
    }

    /// The column with a saved name, `None` for an unknown one (from a newer version).
    pub fn from_raw(raw: &str) -> Option<Column> {
        Column::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    // Swift: ProjectPanelModel.swift:20
    pub fn title(self) -> &'static str {
        match self {
            Column::Name => "Name",
            Column::Label => "Label",
            Column::FrameRate => "Frame Rate",
            Column::Duration => "Duration",
            Column::Resolution => "Resolution",
            Column::Codec => "Codec",
            Column::Audio => "Audio",
            Column::InPoint => "Source In",
            Column::FilePath => "File Path",
            Column::Format => "Format",
            Column::SourceTimecode => "Source Timecode",
        }
    }

    // Swift: ProjectPanelModel.swift:36
    pub fn default_width(self) -> f64 {
        match self {
            Column::Name => 200.0,
            Column::Label => 80.0,
            Column::FrameRate | Column::Duration | Column::Resolution | Column::InPoint => 90.0,
            Column::Codec | Column::SourceTimecode => 110.0,
            Column::Audio => 100.0,
            Column::FilePath => 260.0,
            Column::Format => 210.0,
        }
    }

    // Swift: ProjectPanelModel.swift:51
    pub fn min_width(self) -> f64 {
        if self == Column::Name { 100.0 } else { 50.0 }
    }
}

/// Display-only media filter (header menu > Show): all items, only media no sequence uses, only offline media.
// Swift: ProjectPanelModel.swift:63
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaFilter {
    All,
    Unused,
    Offline,
}

impl MediaFilter {
    pub const ALL: [MediaFilter; 3] = [MediaFilter::All, MediaFilter::Unused, MediaFilter::Offline];

    // Swift: ProjectPanelModel.swift:65
    pub fn title(self) -> &'static str {
        match self {
            MediaFilter::All => "All Media",
            MediaFilter::Unused => "Unused Media",
            MediaFilter::Offline => "Offline Media",
        }
    }
}

/// A file that landed in the bin: its item and the path it was imported from.
// Swift: ProjectPanelModel.swift:173
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportedFile {
    // Swift: ProjectPanelModel.swift:174
    pub id: Id,
    // Swift: ProjectPanelModel.swift:175
    pub url: PathBuf,
}

/// File name and video or audio codec of an import that could not (fully) be decoded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileCodec {
    pub file: String,
    pub codec: String,
}

/// File name and plain-language reason of an import that failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileReason {
    pub file: String,
    pub reason: String,
}

/// The `on*` hooks of the Swift model, pushed in Swift's call order and drained with
/// [`ProjectPanelModel::take_events`].
#[derive(Clone, Debug, PartialEq)]
pub enum ProjectPanelEvent {
    /// `onUnsupported`: an import left files whose video codec cannot be decoded (the view shows a dialog).
    // Swift: ProjectPanelModel.swift:134
    Unsupported(Vec<FileCodec>),
    /// `onAudioDropped`: files imported without sound (the view shows a notice).
    // Swift: ProjectPanelModel.swift:140
    AudioDropped(Vec<FileCodec>),
    /// `onImported`: media landed in the bin at its original place; `pointer` is where the drop happened (screen).
    // Swift: ProjectPanelModel.swift:170
    Imported { files: Vec<ImportedFile>, pointer: (f64, f64) },
}

/// What `delete` did. `blocked_by` lists the sequence names that kept items from being deleted (each name once, project
/// order). `message` is the status line for it.
// Swift: ProjectPanelModel.swift:355
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeleteResult {
    // Swift: ProjectPanelModel.swift:356
    pub changed: bool,
    // Swift: ProjectPanelModel.swift:357
    pub blocked_by: Vec<String>,
    // Swift: ProjectPanelModel.swift:358
    pub blocked_items: i64,
    /// Media still used by a sequence that `clear` made offline instead of deleting (clips stay).
    // Swift: ProjectPanelModel.swift:360
    pub offlined: i64,
}

impl DeleteResult {
    // Swift: ProjectPanelModel.swift:361
    pub fn message(&self) -> Option<String> {
        if self.blocked_items == 0 {
            return (self.offlined > 0).then(|| {
                format!(
                    "{} item{} offline now: the clips stay, Relink attaches a file.",
                    self.offlined,
                    if self.offlined == 1 { " is" } else { "s are" }
                )
            });
        }
        let names: Vec<String> = self.blocked_by.iter().take(3).map(|n| format!("\u{201C}{n}\u{201D}")).collect();
        let names = names.join(", ") + if self.blocked_by.len() > 3 { " and more" } else { "" };
        Some(if self.blocked_by.is_empty() {
            "The last sequence cannot be deleted.".to_string()
        } else {
            format!("Not deleted: still used in {names}.")
        })
    }
}

/// Which text Find looks at.
// Swift: ProjectPanelModel.swift:432
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FindField {
    Name,
    Label,
}

/// Find criteria of the Project panel: text in the name (or label name) and/or offline items only.
// Swift: ProjectPanelModel.swift:431
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FindCriteria {
    // Swift: ProjectPanelModel.swift:433
    pub text: String,
    // Swift: ProjectPanelModel.swift:434
    pub field: FindField,
    // Swift: ProjectPanelModel.swift:435
    pub offline_only: bool,
}

impl Default for FindCriteria {
    fn default() -> Self {
        FindCriteria::new("", FindField::Name, false)
    }
}

impl FindCriteria {
    // Swift: ProjectPanelModel.swift:436
    pub fn new(text: &str, field: FindField, offline_only: bool) -> FindCriteria {
        FindCriteria { text: text.to_string(), field, offline_only }
    }

    // Swift: ProjectPanelModel.swift:439
    pub fn is_empty(&self) -> bool {
        self.text.trim().is_empty() && !self.offline_only
    }
}

/// What the model needs from the app. `headless` gives defaults for tests.
pub struct ProjectPanelDeps {
    /// Probing of files and the platform side of an import.
    pub backend: Arc<dyn ImportBackend>,
    /// Whether a media file is on disk (Swift `status`).
    pub status: Arc<dyn Fn(&MediaRef) -> MediaStatus + Send + Sync>,
    /// Calendar of the day filters and grouping.
    pub calendar: Rc<dyn PanelCalendar>,
    /// Now (the session's clock).
    pub clock: Rc<dyn Fn() -> Timestamp>,
    /// Workers the probes run on.
    pub pool: Arc<sq_runtime::WorkerPool>,
    /// Probes (and copies) of one import running at once (`WorkLimits.importProbes`).
    pub probe_limit: usize,
    /// Monotonic time for the import commit schedule.
    pub mono: Arc<dyn sq_runtime::Clock>,
}

impl ProjectPanelDeps {
    /// A backend that probes nothing, `MediaRef::status`, UTC and a manual pool (tests drive it).
    pub fn headless() -> ProjectPanelDeps {
        ProjectPanelDeps {
            backend: Arc::new(super::NoImportBackend),
            status: Arc::new(MediaRef::status),
            calendar: Rc::new(UtcCalendar),
            clock: Rc::new(|| Timestamp::from_reference_seconds(0.0)),
            pool: Arc::new(sq_runtime::WorkerPool::manual()),
            probe_limit: 4,
            mono: Arc::new(sq_runtime::SystemClock::new()),
        }
    }
}

/// The Project panel's model. Methods that edit take the session and make one undo step; the panel reads
/// [`Self::project`], its own copy.
// Swift: ProjectPanelModel.swift:13
pub struct ProjectPanelModel {
    pub(super) project: Project,
    /// Files the folder sync could not read, by path, with the size and date they had. Session only.
    pub(super) failed_probes: BTreeMap<String, String>,
    pub(super) current_bin: Id,
    pub(super) browse_bin: Id,
    pub(super) search_text: String,
    pub(super) search_spoken: bool,
    pub(super) media_filter: MediaFilter,
    pub(super) active_smart_bin: Option<Id>,
    pub(super) filter_tokens: Vec<MediaFilterToken>,
    pub(super) grouping: MediaGrouping,
    pub(super) group_bins: RefCell<BTreeMap<Id, Bin>>,
    pub(super) sort_column: Option<Column>,
    pub(super) sort_ascending: bool,
    pub(super) pending_imports: i64,
    pub(super) import_total: i64,
    pub(super) import_canceled: Option<(i64, i64)>,
    pub(super) import_tokens: BTreeMap<u64, Arc<std::sync::atomic::AtomicBool>>,
    pub(super) next_token: u64,
    pub(super) import_failures: Vec<String>,
    pub(super) last_import_report: Option<ImportReport>,
    pub(super) already_in_project: Vec<String>,
    /// File identity of project media by stored path, learned on a worker (`ProjectPanelModel::scan_identities`), so an
    /// import never stats the whole project again on the UI thread.
    pub(super) identity_cache: BTreeMap<String, String>,
    pub(super) unsupported_imports: Vec<FileCodec>,
    pub(super) import_failure_reasons: Vec<FileReason>,
    pub(super) audio_dropped_imports: Vec<FileCodec>,
    pub(super) offline: BTreeSet<Id>,
    pub(super) health: ProjectHealth,
    pub(super) project_error: Option<(String, String)>,
    pub(super) imported_project_names: Vec<String>,
    pub(super) imported_ids: BTreeMap<String, Id>,
    pub(super) project_folder: Option<PathBuf>,
    pub(super) coalescing_imports: bool,
    pub(super) import_commit_interval: Duration,
    pub(super) events: Vec<ProjectPanelEvent>,
    pub(super) version: u64,
    pub(super) deps: ProjectPanelDeps,
    pub(super) source_timecodes: BTreeMap<Id, Option<SourceTimecode>>,
    pub(super) timecode_requests: RefCell<Vec<(Id, PathBuf)>>,
    pub(super) timecode_started: RefCell<BTreeSet<Id>>,
    pub(super) spoken_cache: RefCell<Option<(u64, String, BTreeSet<Id>)>>,
}

impl ProjectPanelModel {
    // Swift: ProjectPanelModel.swift:209
    pub fn new(project: Project, deps: ProjectPanelDeps) -> ProjectPanelModel {
        let mut p = project;
        p.normalize_bins();
        let root = p.root_bin.id;
        let mut m = ProjectPanelModel {
            project: p,
            failed_probes: BTreeMap::new(),
            current_bin: root,
            browse_bin: root,
            search_text: String::new(),
            search_spoken: false,
            media_filter: MediaFilter::All,
            active_smart_bin: None,
            filter_tokens: Vec::new(),
            grouping: MediaGrouping::Folders,
            group_bins: RefCell::new(BTreeMap::new()),
            sort_column: None,
            sort_ascending: true,
            pending_imports: 0,
            import_total: 0,
            import_canceled: None,
            import_tokens: BTreeMap::new(),
            next_token: 0,
            import_failures: Vec::new(),
            last_import_report: None,
            already_in_project: Vec::new(),
            identity_cache: BTreeMap::new(),
            unsupported_imports: Vec::new(),
            import_failure_reasons: Vec::new(),
            audio_dropped_imports: Vec::new(),
            offline: BTreeSet::new(),
            health: ProjectHealth::default(),
            project_error: None,
            imported_project_names: Vec::new(),
            imported_ids: BTreeMap::new(),
            project_folder: None,
            coalescing_imports: false,
            import_commit_interval: Duration::from_millis(250),
            events: Vec::new(),
            version: 0,
            deps,
            source_timecodes: BTreeMap::new(),
            timecode_requests: RefCell::new(Vec::new()),
            timecode_started: RefCell::new(BTreeSet::new()),
            spoken_cache: RefCell::new(None),
        };
        m.refresh_offline();
        m
    }

    /// Bumped on every change the view must reload for.
    pub fn version(&self) -> u64 {
        self.version
    }

    // Swift: ProjectPanelModel.swift:54
    pub fn project(&self) -> &Project {
        &self.project
    }

    /// The `on*` hooks since the last call, oldest first.
    pub fn take_events(&mut self) -> Vec<ProjectPanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The files that landed since the last call (the `Imported` events, oldest first) and where the drop happened; the
    /// other events stay queued. The shell decides what happens to the ones outside the project folder.
    pub fn take_imported(&mut self) -> Vec<(Vec<ImportedFile>, (f64, f64))> {
        let (imported, rest): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.events).into_iter().partition(|e| matches!(e, ProjectPanelEvent::Imported { .. }));
        self.events = rest;
        imported
            .into_iter()
            .filter_map(|e| match e {
                ProjectPanelEvent::Imported { files, pointer } => Some((files, pointer)),
                _ => None,
            })
            .collect()
    }

    /// Bin that receives imports and new bins.
    // Swift: ProjectPanelModel.swift:56
    pub fn current_bin(&self) -> Id {
        self.current_bin
    }

    pub fn set_current_bin(&mut self, id: Id) {
        self.current_bin = id;
    }

    /// Bin the icon view shows (double-click a bin to enter it).
    // Swift: ProjectPanelModel.swift:58
    pub fn browse_bin(&self) -> Id {
        self.browse_bin
    }

    pub fn set_browse_bin(&mut self, id: Id) {
        if self.browse_bin != id {
            self.browse_bin = id;
            self.version += 1;
        }
    }

    // Swift: ProjectPanelModel.swift:59
    pub fn search_text(&self) -> &str {
        &self.search_text
    }

    pub fn set_search_text(&mut self, text: &str) {
        self.search_text = text.to_string();
        self.version += 1;
    }

    /// The search text also looks through the spoken words (captions over the media), not only names.
    // Swift: ProjectPanelModel.swift:61
    pub fn search_spoken(&self) -> bool {
        self.search_spoken
    }

    pub fn set_search_spoken(&mut self, on: bool) {
        if self.search_spoken != on {
            self.search_spoken = on;
            self.version += 1;
        }
    }

    // Swift: ProjectPanelModel.swift:69
    pub fn media_filter(&self) -> MediaFilter {
        self.media_filter
    }

    pub fn set_media_filter(&mut self, f: MediaFilter) {
        if self.media_filter != f {
            self.media_filter = f;
            self.version += 1;
        }
    }

    /// Smart bin shown instead of the folder tree (display only, not saved).
    // Swift: ProjectPanelModel.swift:71
    pub fn active_smart_bin(&self) -> Option<Id> {
        self.active_smart_bin
    }

    pub fn set_active_smart_bin(&mut self, id: Option<Id>) {
        if self.active_smart_bin != id {
            self.active_smart_bin = id;
            self.version += 1;
        }
    }

    /// True while search or the media filter hides items (drag reordering is off then).
    // Swift: ProjectPanelModel.swift:73
    pub fn is_filtering(&self) -> bool {
        self.active_smart_bin.is_some()
            || self.media_filter != MediaFilter::All
            || !self.filter_tokens.is_empty()
            || self.grouping != MediaGrouping::Folders
            || !self.search_text.trim_matches(' ').is_empty()
    }

    /// Facts typed into the search field (`cam:FX3`, `unused`, ...), shown as chips. Display only, not saved.
    // Swift: ProjectPanelModel.swift:78
    pub fn filter_tokens(&self) -> &[MediaFilterToken] {
        &self.filter_tokens
    }

    pub fn set_filter_tokens(&mut self, tokens: Vec<MediaFilterToken>) {
        if self.filter_tokens != tokens {
            self.filter_tokens = tokens;
            self.version += 1;
        }
    }

    /// "Sorted by": the same media shown grouped by day, camera or kind. Display only, moves nothing, not saved.
    // Swift: ProjectPanelModel.swift:80
    pub fn grouping(&self) -> MediaGrouping {
        self.grouping
    }

    pub fn set_grouping(&mut self, g: MediaGrouping) {
        if self.grouping != g {
            self.grouping = g;
            self.version += 1;
        }
    }

    /// The folder with `id`: a real one of the project, or a group header of the "Sorted by" view.
    // Swift: ProjectPanelModel.swift:85
    pub fn display_bin(&self, id: Id) -> Option<Bin> {
        self.project.bin(id).cloned().or_else(|| self.group_bins.borrow().get(&id).cloned())
    }

    // Swift: ProjectPanelModel.swift:86
    pub fn is_group_header(&self, id: Id) -> bool {
        self.group_bins.borrow().contains_key(&id) && self.project.bin(id).is_none()
    }

    /// Name of a folder, media item or sequence as shown (group headers carry their title).
    // Swift: ProjectPanelModel.swift:88
    pub fn display_name(&self, item: BinItemRef) -> String {
        if let BinItemRef::Bin(id) = item
            && self.project.bin(id).is_none()
            && let Some(g) = self.group_bins.borrow().get(&id)
        {
            return g.name.clone();
        }
        self.project.display_name(item)
    }

    /// Same id for the same group on every call, so expanded headers stay expanded.
    // Swift: ProjectPanelModel.swift:94
    pub(super) fn group_id(mode: MediaGrouping, key: &str) -> Id {
        let raw = match mode {
            MediaGrouping::Folders => "folders",
            MediaGrouping::Day => "day",
            MediaGrouping::Camera => "camera",
            MediaGrouping::Kind => "kind",
        };
        let fnv = |salt: u64| {
            let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ salt;
            for b in format!("{raw}|{key}").bytes() {
                h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
            }
            h
        };
        let (a, b) = (fnv(0), fnv(0x9E37_79B9_7F4A_7C15));
        let mut bytes = [0u8; 16];
        bytes[..8].copy_from_slice(&a.to_le_bytes());
        bytes[8..].copy_from_slice(&b.to_le_bytes());
        Id::from_u128(u128::from_be_bytes(bytes))
    }

    // Swift: ProjectPanelModel.swift:106
    pub fn sort_column(&self) -> Option<Column> {
        self.sort_column
    }

    // Swift: ProjectPanelModel.swift:107
    pub fn sort_ascending(&self) -> bool {
        self.sort_ascending
    }

    /// Number of files still being probed.
    // Swift: ProjectPanelModel.swift:109
    pub fn pending_imports(&self) -> i64 {
        self.pending_imports
    }

    /// Files of the running import batch (all overlapping imports together); 0 when none runs.
    // Swift: ProjectPanelModel.swift:112
    pub fn import_total(&self) -> i64 {
        self.import_total
    }

    /// Set when the last import was canceled: files that landed, and files in the batch.
    // Swift: ProjectPanelModel.swift:114
    pub fn import_canceled(&self) -> Option<(i64, i64)> {
        self.import_canceled
    }

    /// Stops the running import: files not probed yet are skipped; files already probed or landed stay.
    // Swift: ProjectPanelModel.swift:118
    pub fn cancel_import(&self) {
        for t in self.import_tokens.values() {
            t.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// Status line after a canceled import.
    // Swift: ProjectPanelModel.swift:121
    pub fn canceled_text(imported: i64, total: i64) -> String {
        format!("Import canceled: {imported} of {total} file{} imported.", if total == 1 { "" } else { "s" })
    }

    /// File names of the last imports that could not be read.
    // Swift: ProjectPanelModel.swift:125
    pub fn import_failures(&self) -> &[String] {
        &self.import_failures
    }

    /// Summary of the last import. A view shows `summary` once it wants to; nothing here asks for attention by itself.
    // Swift: ProjectPanelModel.swift:128
    pub fn last_import_report(&self) -> Option<&ImportReport> {
        self.last_import_report.as_ref()
    }

    /// File names of the last import that were already in the project (skipped; the panel says so).
    // Swift: ProjectPanelModel.swift:130
    pub fn already_in_project(&self) -> &[String] {
        &self.already_in_project
    }

    /// Files of the last imports whose video codec cannot be decoded here.
    // Swift: ProjectPanelModel.swift:132
    pub fn unsupported_imports(&self) -> &[FileCodec] {
        &self.unsupported_imports
    }

    /// Plain-language reason per file of `import_failures`.
    // Swift: ProjectPanelModel.swift:136
    pub fn import_failure_reasons(&self) -> &[FileReason] {
        &self.import_failure_reasons
    }

    /// Files of the last imports that imported without sound because their audio codec cannot be decoded.
    // Swift: ProjectPanelModel.swift:138
    pub fn audio_dropped_imports(&self) -> &[FileCodec] {
        &self.audio_dropped_imports
    }

    // Swift: ProjectPanelModel.swift:141
    pub fn offline(&self) -> &BTreeSet<Id> {
        &self.offline
    }

    /// Counts for the Library's health line (in the project folder, outside it, offline).
    // Swift: ProjectPanelModel.swift:143
    pub fn health(&self) -> ProjectHealth {
        self.health
    }

    /// Why the last project import failed (title, plain-language detail).
    // Swift: ProjectPanelModel.swift:757
    pub fn project_import_error(&self) -> Option<&(String, String)> {
        self.project_error.as_ref()
    }

    /// Names of the projects imported in the last call.
    // Swift: ProjectPanelModel.swift:759
    pub fn imported_project_names(&self) -> &[String] {
        &self.imported_project_names
    }

    /// The project folder, if the project lives in one: bin items removed while their file stays in it are remembered so
    /// the folder watcher does not add them again (Swift `projectFolder`, pushed here by the app).
    // Swift: ProjectPanelModel.swift:165
    pub fn set_project_folder(&mut self, folder: Option<PathBuf>) {
        self.project_folder = folder;
    }

    /// When on, an import fills the bin while it probes and merges into one undo step (Swift: `onCoalescingEdit` set).
    // Swift: ProjectPanelModel.swift:180
    pub fn set_coalescing_imports(&mut self, on: bool) {
        self.coalescing_imports = on;
    }

    /// Least time between two bin updates of one import (each reloads the grid).
    // Swift: ProjectPanelModel.swift:182
    pub fn set_import_commit_interval(&mut self, d: Duration) {
        self.import_commit_interval = d;
    }

    // Swift: ProjectPanelModel.swift:226
    pub fn set_project(&mut self, p: Project) {
        let mut p = p;
        p.normalize_bins();
        self.project = p;
        if self.project.bin(self.current_bin).is_none() {
            self.current_bin = self.project.root_bin.id;
        }
        if self.project.bin(self.browse_bin).is_none() {
            self.browse_bin = self.project.root_bin.id;
        }
        self.schedule_offline_refresh();
        self.version += 1;
    }

    /// Re-checks the files of all media items. Offline means nothing is at the stored path.
    // Swift: ProjectPanelModel.swift:238
    pub fn refresh_offline(&mut self) {
        let status = &self.deps.status;
        self.offline = self.project.media.iter().filter(|m| status(m) == MediaStatus::Missing).map(|m| m.id).collect();
        self.health = self.health_now();
        self.version += 1;
    }

    fn health_now(&self) -> ProjectHealth {
        let inside = self.project_folder.as_ref().map(|f| {
            let f = f.clone();
            move |path: &str| Path::new(path).starts_with(&f)
        });
        ProjectHealth::make(&self.project.media, &self.offline, inside.as_ref().map(|f| f as &dyn Fn(&str) -> bool))
    }

    /// Same check as `refresh_offline`; a burst of calls costs one pass each.
    // shortcut: runs on the calling thread (Swift stats the files on a utility thread and coalesces bursts); upgrade
    // with a `WorkerPool` job and a dirty flag when a project with thousands of media makes the stat calls visible.
    // Swift: ProjectPanelModel.swift:246
    pub fn schedule_offline_refresh(&mut self) {
        self.refresh_offline();
    }

    // Swift: ProjectPanelModel.swift:263
    pub fn is_offline(&self, id: Id) -> bool {
        self.offline.contains(&id)
    }

    /// Size and modification date of a file as text, to tell an unchanged unreadable file from a replaced one.
    // Swift: ProjectPanelModel.swift:153
    pub(super) fn file_signature(path: &str) -> Option<String> {
        let stamp = sq_library::media_file_stamp::MediaFileStamp::read(Path::new(path))?;
        Some(format!("{}-{}", stamp.size, stamp.modified.unix_seconds()))
    }

    /// How many unreadable files the folder sync remembers (test seam).
    // Swift: ProjectPanelModel.swift:159
    pub fn remembered_failure_count(&self) -> usize {
        self.failed_probes.len()
    }

    // MARK: Editing

    /// Applies `body` to a copy of the session's project as it is right now; when it changed something the session
    /// records one undo step and the model adopts the copy. The copy never comes from `self.project`: that one is only
    /// synced on the host's next change poll, so after an edit made through another panel it is stale and writing it
    /// back would undo that edit (the copy is taken and written back in this one call, so nothing can come between).
    // Swift: ProjectPanelModel.swift:15 (`EditHandler` is `EditorSession::perform` here)
    pub(super) fn commit(
        &mut self,
        session: &mut EditorSession,
        name: &str,
        coalescing: Option<&str>,
        body: impl FnOnce(&mut Project, &mut dyn IdSource) -> bool,
    ) -> bool {
        let mut p = session.project().clone();
        p.normalize_bins();
        let before = p.clone();
        if !body(&mut p, &mut *session.ids) || p == before {
            return false;
        }
        self.project = p.clone();
        self.version += 1;
        session.perform(name, coalescing, move |sp| *sp = p);
        true
    }

    // MARK: Smart bins

    /// Saves a filter as a smart bin (one undo step). Returns its id, `None` for an empty name.
    // Swift: ProjectPanelModel.swift:280
    pub fn add_smart_bin(&mut self, session: &mut EditorSession, bin: SmartBin) -> Option<Id> {
        let id = bin.id;
        self.commit(session, "New Smart Folder", None, |p, _| p.add_smart_bin(bin)).then_some(id)
    }

    /// Smart Folder from what the header currently filters by (search text, Unused / Offline).
    // Swift: ProjectPanelModel.swift:286
    pub fn current_filter_as_smart_bin(&self, id: Id, name: &str) -> SmartBin {
        let mut bin = SmartBin {
            id,
            name: name.to_string(),
            text: self.search_text.trim_matches(' ').to_string(),
            usage: if self.media_filter == MediaFilter::Unused { SmartBinUsage::Unused } else { SmartBinUsage::Any },
            kind: SmartBinKind::Any,
            offline_only: self.media_filter == MediaFilter::Offline,
            label: None,
            tokens: None,
            searches_spoken: None,
        };
        if !self.filter_tokens.is_empty() {
            bin.tokens = Some(self.filter_tokens.clone());
        }
        if self.search_spoken {
            bin.searches_spoken = Some(true);
        }
        bin
    }

    // Swift: ProjectPanelModel.swift:291
    pub fn update_smart_bin(&mut self, session: &mut EditorSession, bin: SmartBin) -> bool {
        self.commit(session, "Edit Smart Folder", None, |p, _| p.update_smart_bin(bin))
    }

    // Swift: ProjectPanelModel.swift:294
    pub fn remove_smart_bin(&mut self, session: &mut EditorSession, id: Id) -> bool {
        if self.active_smart_bin == Some(id) {
            self.set_active_smart_bin(None);
        }
        self.commit(session, "Delete Smart Folder", None, |p, _| p.remove_smart_bin(id))
    }

    /// Ids of the media that count as used: in a non-nested, non-generator clip of any sequence.
    fn used_media(&self) -> BTreeSet<Id> {
        let mut used = BTreeSet::new();
        for t in self.project.timelines.iter() {
            for tr in t.tracks.iter() {
                used.extend(tr.clips().iter().filter(|c| !c.is_nested() && !c.is_generator()).map(|c| c.media));
            }
        }
        used
    }

    /// Media matching a smart bin, in project order.
    // Swift: ProjectPanelModel.swift:302
    pub fn smart_bin_media(&self, id: Id) -> Vec<Id> {
        let Some(bin) = self.project.smart_bin(id) else { return Vec::new() };
        let used = self.used_media();
        let spoken =
            if bin.searches_spoken == Some(true) { self.project.media_ids_spoken(&bin.text) } else { BTreeSet::new() };
        let now = (self.deps.clock)();
        self.project
            .media
            .iter()
            .filter(|m| {
                bin.matches(m, used.contains(&m.id), self.offline.contains(&m.id), &spoken, now, &*self.deps.calendar)
            })
            .map(|m| m.id)
            .collect()
    }

    /// 0...1 share of the media's length the sequences use; `None` = length unknown.
    // Swift: ProjectPanelModel.swift:310
    pub fn used_fraction(&self, id: Id) -> Option<f64> {
        self.project.used_fraction(id)
    }

    /// Creates a bin in the current bin and returns its id.
    // Swift: ProjectPanelModel.swift:313
    pub fn new_bin(&mut self, session: &mut EditorSession, name: &str) -> Option<Id> {
        let parent = self.current_bin;
        let mut id = None;
        self.commit(session, "New Folder", None, |p, ids| {
            id = p.new_bin(name, Some(parent), ids);
            id.is_some()
        });
        id
    }

    // Swift: ProjectPanelModel.swift:320
    pub fn rename(&mut self, session: &mut EditorSession, item: BinItemRef, name: &str) -> bool {
        if name.trim_matches(' ').is_empty() {
            return false;
        }
        self.commit(session, "Rename", None, |p, _| match item {
            BinItemRef::Bin(id) => p.rename_bin(id, name),
            BinItemRef::Media(id) => match p.media.iter_mut().find(|m| m.id == id) {
                Some(m) => {
                    m.name = name.to_string();
                    true
                }
                None => false,
            },
            BinItemRef::Sequence(id) => match p.timelines.iter_mut().find(|t| t.id == id) {
                Some(t) => {
                    t.name = name.to_string();
                    true
                }
                None => false,
            },
        })
    }

    // Swift: ProjectPanelModel.swift:336
    pub fn move_items(
        &mut self,
        session: &mut EditorSession,
        items: &[BinItemRef],
        dest: Id,
        index: Option<i64>,
    ) -> bool {
        // Dropping items on the bin they already sit in (no insertion position) is a no-op, not "move to the bottom".
        if index.is_none()
            && let Some(d) = self.project.bin(dest)
            && items.iter().all(|r| d.children.iter().any(|c| c.item_ref() == *r))
        {
            return false;
        }
        self.commit(session, "Move to Folder", None, |p, _| p.move_items(items, dest, index))
    }

    /// Sets the label of the media items and sequences in `items` (`None` = back to the type default): one undo step.
    // Swift: ProjectPanelModel.swift:345
    pub fn set_label(&mut self, session: &mut EditorSession, label: Option<LabelColor>, items: &[BinItemRef]) -> bool {
        self.commit(session, "Change Label", None, |p, _| p.set_label(label, items))
    }

    /// Label color shown for an item.
    // Swift: ProjectPanelModel.swift:351
    pub fn label(&self, item: BinItemRef) -> LabelColor {
        self.project.label_of(item)
    }

    /// Undo name of a delete: "Delete Folder" for exactly one bin, otherwise "Delete Items".
    // Swift: ProjectPanelModel.swift:371
    pub fn delete_name(items: &[BinItemRef]) -> &'static str {
        if items.len() == 1 && matches!(items[0], BinItemRef::Bin(_)) { "Delete Folder" } else { "Delete Items" }
    }

    /// Deletes bins (their content moves up), media not used by any sequence, and sequences (never the last one, nor one
    /// that another sequence nests). The root bin is kept. One undo step. Items that are in use stay and their sequence
    /// names come back in `blocked_by`.
    // Swift: ProjectPanelModel.swift:379
    pub fn delete(&mut self, session: &mut EditorSession, items: &[BinItemRef]) -> DeleteResult {
        self.remove(session, items, false)
    }

    /// Clear: like `delete`, but media a sequence still uses is not blocked: it goes offline and its clips stay on the
    /// timelines (`Project::make_offline`, `DeleteResult::offlined`). Unused items and bins are deleted.
    // Swift: ProjectPanelModel.swift:384
    pub fn clear(&mut self, session: &mut EditorSession, items: &[BinItemRef]) -> DeleteResult {
        self.remove(session, items, true)
    }

    fn remove(&mut self, session: &mut EditorSession, items: &[BinItemRef], offline_used: bool) -> DeleteResult {
        let mut result = DeleteResult::default();
        let name = if offline_used { "Clear Items" } else { Self::delete_name(items) };
        let folder = self.project_folder.as_ref().map(|f| f.to_string_lossy().into_owned());
        // The file stays in the project folder: the watcher must not add it back.
        let ignore = |p: &mut Project, id: Id| {
            if let (Some(folder), Some(m)) = (folder.as_deref(), p.media.iter().find(|m| m.id == id).cloned())
                && Path::new(&m.path).exists()
            {
                p.ignore_folder_file(&m.path, folder);
            }
        };
        result.changed = self.commit(session, name, None, |p, _| {
            let mut changed = false;
            for r in items {
                match *r {
                    BinItemRef::Bin(id) => changed |= p.delete_bin(id),
                    BinItemRef::Media(id) => {
                        if !p.media.iter().any(|m| m.id == id) {
                            continue;
                        }
                        let users = p.sequence_names_using(id);
                        if !users.is_empty() {
                            if !offline_used {
                                block(&mut result, users);
                                continue;
                            }
                            ignore(p, id);
                            if p.make_offline(id) {
                                result.offlined += 1;
                                changed = true;
                            }
                            continue;
                        }
                        ignore(p, id);
                        p.media.retain(|m| m.id != id);
                        p.source_marks.remove(&id);
                        p.normalize_bins();
                        changed = true;
                    }
                    BinItemRef::Sequence(id) => {
                        let nesting = p.sequence_names_nesting(id);
                        if p.delete_sequence(id) {
                            changed = true;
                        } else {
                            block(&mut result, nesting);
                        }
                    }
                }
            }
            changed
        });
        result
    }

    // MARK: Find (Cmd+F)

    /// Items (media and sequences, in tree order, bins skipped) that match all criteria. Empty criteria match nothing.
    // Swift: ProjectPanelModel.swift:443
    pub fn find(&self, c: &FindCriteria) -> Vec<BinItemRef> {
        if c.is_empty() {
            return Vec::new();
        }
        let q = c.text.trim_matches(' ');
        let mut out = Vec::new();
        self.find_in(&self.project.root_bin, c, q, &mut out);
        out
    }

    fn find_in(&self, bin: &Bin, c: &FindCriteria, q: &str, out: &mut Vec<BinItemRef>) {
        for child in &bin.children {
            if let BinItem::Bin(b) = child {
                self.find_in(b, c, q, out);
                continue;
            }
            let item = child.item_ref();
            if c.offline_only {
                match item {
                    BinItemRef::Media(id) if self.offline.contains(&id) => {}
                    _ => continue,
                }
            }
            if !q.is_empty() {
                let hay = match c.field {
                    FindField::Name => self.project.display_name(item),
                    FindField::Label => self.project.label_of(item).display_name().to_string(),
                };
                if !ci_contains(&hay, q) {
                    continue;
                }
            }
            out.push(item);
        }
    }

    // MARK: Poster frame, pixel aspect, audio channels, deinterlace

    /// Sets (or with `None` clears) the poster frame of media items: one undo step. Items that are not media are skipped.
    // Swift: ProjectPanelModel.swift:468
    pub fn set_poster(&mut self, session: &mut EditorSession, time: Option<Time>, items: &[BinItemRef]) -> bool {
        let name = if time.is_none() { "Clear Poster Frame" } else { "Set Poster Frame" };
        self.commit(session, name, None, |p, _| each_media(items, |id| p.set_poster_time(time, id)))
    }

    /// Source settings > Pixel Aspect for media items (`None` = what the file says): one undo step. Items that are not
    /// media, or have no picture, are skipped.
    // Swift: ProjectPanelModel.swift:481
    pub fn set_pixel_aspect(
        &mut self,
        session: &mut EditorSession,
        aspect: Option<PixelAspect>,
        items: &[BinItemRef],
    ) -> bool {
        self.commit(session, "Set Pixel Aspect", None, |p, _| each_media(items, |id| p.set_pixel_aspect(aspect, id)))
    }

    /// Source settings > Audio Channels for media items (`None` = the file's layout): one undo step.
    // Swift: ProjectPanelModel.swift:492
    pub fn set_audio_channels(
        &mut self,
        session: &mut EditorSession,
        map: Option<&AudioChannelMap>,
        items: &[BinItemRef],
    ) -> bool {
        self.commit(session, "Set Audio Channels", None, |p, _| {
            each_media(items, |id| p.set_audio_channel_map(map, id))
        })
    }

    /// The Deinterlace row is offered when every selected item is interlaced media: true = on for all of them.
    // Swift: ProjectPanelModel.swift:504
    pub fn deinterlace_state(&self, media: &[Id]) -> Option<bool> {
        let states: Vec<bool> = media.iter().filter_map(|id| self.project.deinterlace(*id)).collect();
        if media.is_empty() || states.len() != media.len() {
            return None;
        }
        Some(states.iter().all(|s| *s))
    }

    /// Source settings > Deinterlace for media items: one undo step.
    // Swift: ProjectPanelModel.swift:512
    pub fn set_deinterlace(&mut self, session: &mut EditorSession, on: bool, items: &[BinItemRef]) -> bool {
        self.commit(session, "Set Deinterlace", None, |p, _| each_media(items, |id| p.set_deinterlace(on, id)))
    }

    // MARK: Failure lines

    /// Status line for files that could not be read: the first three names, then a count.
    // Swift: ProjectPanelModel.swift:743
    pub fn failure_text(names: &[String]) -> String {
        let shown = names.iter().take(3).cloned().collect::<Vec<_>>().join(", ");
        format!(
            "Could not read: {shown}{}",
            if names.len() > 3 { format!(" and {} more.", names.len() - 3) } else { String::new() }
        )
    }

    /// Status line for failed imports: one file names its reason, several list the names.
    // Swift: ProjectPanelModel.swift:749
    pub fn failure_status(items: &[FileReason], names: &[String]) -> String {
        if items.len() == 1 && names.len() == 1 {
            return format!("{}: {}", items[0].file, items[0].reason);
        }
        Self::failure_text(names)
    }

    // MARK: Display (sort + filter are display-only)

    // Swift: ProjectPanelModel.swift:795
    pub fn set_sort(&mut self, column: Option<Column>, ascending: bool) {
        self.sort_column = column;
        self.sort_ascending = ascending;
        self.version += 1;
    }

    /// Children of `bin` as shown: filtered by the search text, sorted by the active column (bins first).
    // Swift: ProjectPanelModel.swift:801
    pub fn children(&self, bin: &Bin) -> Vec<BinItem> {
        let mut q = self.search_text.trim_matches(' ').to_string();
        // A bin whose own name matches shows its full content.
        if !q.is_empty() && bin.id != self.project.root_bin.id && ci_contains(&bin.name, &q) {
            q.clear();
        }
        if let Some(sb) = self.active_smart_bin.filter(|id| self.project.smart_bin(*id).is_some()) {
            if bin.id != self.project.root_bin.id {
                return Vec::new();
            }
            return self
                .smart_bin_media(sb)
                .into_iter()
                .map(BinItem::Media)
                .filter(|i| (q.is_empty() || self.matches(i, &q)) && self.passes_filter(i))
                .collect();
        }
        if self.grouping != MediaGrouping::Folders {
            if self.project.bin(bin.id).is_none()
                && let Some(g) = self.group_bins.borrow().get(&bin.id)
            {
                return g.children.clone();
            }
            if bin.id != self.project.root_bin.id {
                return Vec::new();
            }
            return self.grouped_root(&q);
        }
        let mut items = bin.children.clone();
        if !q.is_empty() {
            items.retain(|i| self.matches(i, &q));
        }
        if self.media_filter != MediaFilter::All || !self.filter_tokens.is_empty() {
            items.retain(|i| self.passes_filter(i));
        }
        let Some(col) = self.sort_column else { return items };
        let rank = |i: &BinItem| usize::from(!matches!(i, BinItem::Bin(_)));
        let keys: Vec<String> = items.iter().map(|i| self.sort_key(col, i)).collect();
        let mut order: Vec<usize> = (0..items.len()).collect();
        order.sort_by(|&l, &r| {
            let rk = rank(&items[l]).cmp(&rank(&items[r]));
            if rk.is_ne() {
                return rk;
            }
            let c = standard_compare(&keys[l], &keys[r]);
            if c.is_eq() {
                return l.cmp(&r);
            }
            if self.sort_ascending { c } else { c.reverse() }
        });
        order.into_iter().map(|i| items[i].clone()).collect()
    }

    fn sort_key(&self, col: Column, item: &BinItem) -> String {
        match (col, item) {
            (Column::Name, _) => self.display_name(item.item_ref()),
            (Column::Duration, BinItem::Media(id)) => {
                format!("{:020.6}", self.project.media(*id).and_then(|m| m.duration).map_or(0.0, Self::seconds))
            }
            (Column::FrameRate, BinItem::Media(id)) => {
                let rate = self
                    .project
                    .media(*id)
                    .and_then(|m| m.info.as_ref())
                    .and_then(|i| i.video.as_ref())
                    .map_or(0.0, |v| 1.0 / Self::seconds(v.nominal_frame_duration));
                format!("{rate:020.6}")
            }
            _ => self.cell_text(col, item.item_ref()),
        }
    }

    /// Media: unused / offline as chosen, and every token. Folders stay when anything inside passes. Sequences are hidden
    /// by a filter.
    fn passes_filter(&self, item: &BinItem) -> bool {
        match item {
            BinItem::Bin(b) => b.children.iter().any(|c| self.passes_filter(c)),
            BinItem::Media(id) => {
                let unused = self.project.sequence_names_using(*id).is_empty();
                match self.media_filter {
                    MediaFilter::All => {}
                    MediaFilter::Unused if !unused => return false,
                    MediaFilter::Offline if !self.is_offline(*id) => return false,
                    _ => {}
                }
                if self.filter_tokens.is_empty() {
                    return true;
                }
                let Some(m) = self.project.media(*id) else { return false };
                let query = MediaFilterQuery { text: String::new(), tokens: self.filter_tokens.clone() };
                query.matches(m, !unused, (self.deps.clock)(), &*self.deps.calendar)
            }
            BinItem::Sequence(_) => false,
        }
    }

    /// Root of the "Sorted by" view: one header per group (folders are flattened away), media filtered like the folder view.
    fn grouped_root(&self, q: &str) -> Vec<BinItem> {
        let shown: Vec<MediaRef> = self
            .project
            .media
            .iter()
            .filter(|m| {
                let item = BinItem::Media(m.id);
                (q.is_empty() || self.matches(&item, q)) && self.passes_filter(&item)
            })
            .cloned()
            .collect();
        let groups = self.grouping.groups(&shown, &*self.deps.calendar);
        let mut bins = self.group_bins.borrow_mut();
        bins.clear();
        groups
            .into_iter()
            .map(|g| {
                let id = Self::group_id(self.grouping, &g.id);
                let bin = Bin::new(id, g.title, g.items.iter().map(|m| BinItem::Media(*m)).collect());
                bins.insert(id, bin.clone());
                BinItem::Bin(bin)
            })
            .collect()
    }

    fn matches(&self, item: &BinItem, q: &str) -> bool {
        match item {
            BinItem::Bin(b) => ci_contains(&b.name, q) || b.children.iter().any(|c| self.matches(c, q)),
            _ => {
                if ci_contains(&self.display_name(item.item_ref()), q) {
                    return true;
                }
                if let (true, BinItem::Media(id)) = (self.search_spoken, item) {
                    return self.spoken_contains(q, *id);
                }
                false
            }
        }
    }

    /// Whether `id` has the words `q` in its captions; the lookup is kept per project revision and text so typing stays cheap.
    fn spoken_contains(&self, q: &str, id: Id) -> bool {
        let fresh = !matches!(&*self.spoken_cache.borrow(), Some((v, t, _)) if *v == self.version && t == q);
        if fresh {
            *self.spoken_cache.borrow_mut() = Some((self.version, q.to_string(), self.project.media_ids_spoken(q)));
        }
        self.spoken_cache.borrow().as_ref().is_some_and(|(_, _, ids)| ids.contains(&id))
    }

    // MARK: Pasteboard

    /// Custom pasteboard type carrying item ids.
    // Swift: ProjectPanelModel.swift:982
    pub const PASTEBOARD_TYPE_NAME: &'static str = "com.sequencestudio.media-ids";

    // Swift: ProjectPanelModel.swift:983
    pub fn encode_items(refs: &[BinItemRef]) -> String {
        refs.iter()
            .map(|r| match r {
                BinItemRef::Bin(id) => format!("b:{id}"),
                BinItemRef::Media(id) => format!("m:{id}"),
                BinItemRef::Sequence(id) => format!("s:{id}"),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    // Swift: ProjectPanelModel.swift:993
    pub fn decode_items(s: &str) -> Vec<BinItemRef> {
        s.split('\n')
            .filter_map(|line| {
                let (tag, rest) = (line.get(..2)?, line.get(2..)?);
                if rest.is_empty() {
                    return None;
                }
                let id = Id::parse(rest)?;
                match tag {
                    "b:" => Some(BinItemRef::Bin(id)),
                    "m:" => Some(BinItemRef::Media(id)),
                    "s:" => Some(BinItemRef::Sequence(id)),
                    _ => None,
                }
            })
            .collect()
    }
}

fn block(result: &mut DeleteResult, names: Vec<String>) {
    result.blocked_items += 1;
    for n in names {
        if !result.blocked_by.contains(&n) {
            result.blocked_by.push(n);
        }
    }
}

/// True when `f` changed the media of at least one item that is media (all items are visited).
fn each_media(items: &[BinItemRef], mut f: impl FnMut(Id) -> bool) -> bool {
    let mut changed = false;
    for r in items {
        if let BinItemRef::Media(id) = r {
            changed |= f(*id);
        }
    }
    changed
}
