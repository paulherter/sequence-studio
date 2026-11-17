//! Where cache, proxies, scratch files and new projects live, and the Preferences lists built on it.

use std::fs;
use std::path::{Path, PathBuf};

use sq_analysis::analysis_cache_location::AnalysisCacheLocation;
use sq_core_effects::transition::TransitionKindExt;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::{EffectCatalog, TrackKind, TransitionKind};
use sq_playback::engine::memory_budget::{GIB, MemoryBudget};
use sq_proxy::proxy_cache::ProxyCache;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqbyte_size::SQByteSize;

use super::settings::{AppSettings, AppSettingsKey};
use sq_os::Platform;

/// A process environment variable (`None` when unset or not text).
pub(crate) fn env_var(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

/// The process environment as `Platform`'s folder methods read it.
fn os_env(name: &str) -> Option<std::ffi::OsString> {
    std::env::var_os(name)
}

/// The user's home folder.
fn home_directory() -> PathBuf {
    Platform::current().home_dir(os_env).unwrap_or_else(std::env::temp_dir)
}

/// The per-user caches folder (`Platform::cache_dir`); the temporary folder when none is known (Swift fallback).
pub(crate) fn caches_directory() -> PathBuf {
    Platform::current().cache_dir(os_env).unwrap_or_else(std::env::temp_dir)
}

/// The one place that decides where Sequence Studio keeps cache, proxies, scratch files and new projects. Everything
/// else asks this resolver; nothing builds a cache path by hand. Pure value, no I/O except in `validate`, `migrate`
/// and the `*_directory` helpers that create folders.
// Swift: StorageLocations.swift:11
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StorageLocations {
    /// User-picked roots; `None` means the default.
    // Swift: StorageLocations.swift:12
    pub cache_folder: Option<PathBuf>,
    // Swift: StorageLocations.swift:13
    pub scratch_folder: Option<PathBuf>,
    // Swift: StorageLocations.swift:14
    pub projects_folder: Option<PathBuf>,
}

/// The keys `StorageLocations` stores under.
pub enum StorageLocationsKey {}

impl StorageLocationsKey {
    /// Same key `AppSettings` has always written (`settings.cacheFolder`): one value, two readers.
    // Swift: StorageLocations.swift:22
    pub const CACHE: &'static str = AppSettingsKey::CACHE;
    // Swift: StorageLocations.swift:23
    pub const SCRATCH: &'static str = "sq.storage.scratchFolder";
    // Swift: StorageLocations.swift:24
    pub const PROJECTS: &'static str = "sq.storage.projectsFolder";
}

/// Why a folder cannot serve as a storage root.
// Swift: StorageLocations.swift:101
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StorageProblem {
    /// Not an absolute path.
    NotAbsolute,
    /// A file is in the way.
    NotAFolder,
    /// The folder cannot be written.
    NotWritable,
    /// The disk is too full.
    NotEnoughSpace {
        /// Free bytes.
        free: i64,
        /// Needed bytes.
        needed: i64,
    },
}

impl StorageProblem {
    // Swift: StorageLocations.swift:105
    pub fn message(&self) -> String {
        match self {
            StorageProblem::NotAbsolute => "Choose a folder on a disk.".to_string(),
            StorageProblem::NotAFolder => "That is a file, not a folder.".to_string(),
            StorageProblem::NotWritable => "Sequence Studio cannot write to that folder.".to_string(),
            StorageProblem::NotEnoughSpace { free, needed } => {
                format!("Only {} free, {} needed.", SQByteSize::string(*free), SQByteSize::string(*needed))
            }
        }
    }
}

/// What `StorageLocations::migrate` did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MigrationReport {
    /// Files copied.
    pub copied: usize,
    /// Files left alone because the target had them.
    pub skipped: usize,
    /// Files that could not be copied.
    pub failed: usize,
}

impl StorageLocations {
    // Swift: StorageLocations.swift:15
    pub fn new(
        cache_folder: Option<PathBuf>,
        scratch_folder: Option<PathBuf>,
        projects_folder: Option<PathBuf>,
    ) -> StorageLocations {
        StorageLocations { cache_folder, scratch_folder, projects_folder }
    }

    // Swift: StorageLocations.swift:26
    pub fn cache_root(&self) -> PathBuf {
        self.cache_folder.clone().unwrap_or_else(AppSettings::default_cache_folder)
    }

    /// Proxies stay at their historic default until a cache folder is picked, then live in `<cache>/Proxies`.
    // Swift: StorageLocations.swift:30
    pub fn proxy_directory(&self) -> PathBuf {
        match &self.cache_folder {
            Some(folder) => folder.join("Proxies"),
            None => ProxyCache::default_directory(env_var),
        }
    }

    // Swift: StorageLocations.swift:34
    pub fn waveform_directory(&self) -> PathBuf {
        self.cache_root().join("Waveforms")
    }

    /// Temporary working files (renders in progress, extracted audio): `<cache>/Scratch` unless picked.
    // Swift: StorageLocations.swift:38
    pub fn scratch_root(&self) -> PathBuf {
        self.scratch_folder.clone().unwrap_or_else(|| self.cache_root().join("Scratch"))
    }

    /// Where new projects are suggested: the movies folder (`~/Movies` on the Mac, `~/Videos` elsewhere) / Sequence Studio unless picked.
    // Swift: StorageLocations.swift:41
    pub fn projects_root(&self) -> PathBuf {
        if let Some(folder) = &self.projects_folder {
            return folder.clone();
        }
        home_directory().join(Platform::current().movies_folder_name()).join("Sequence Studio")
    }

    /// Points the waveform disk cache at `waveform_directory`. The portable path of the Swift code does nothing (only
    /// the Mac's disk cache is configurable); kept so callers read the same on every system.
    // Swift: StorageLocations.swift:49
    pub fn apply_waveform_directory(&self) {}

    /// Points the analysis caches (stabilization, subject masks, mattes) at `<cache>/<Name>`. A default cache folder
    /// keeps every cache where it always was. Matte stores follow at the next launch.
    // shortcut: the library preview cache root (`PreviewCache.configureCacheRoot`) is a process-wide setting in Swift;
    // the Rust `PreviewCache` is built by its owner with a root, so the app passes `cache_folder` there. Upgrade when a
    // shared preview-cache setting exists.
    // Swift: StorageLocations.swift:57
    pub fn apply_analysis_and_preview_roots(&self) {
        AnalysisCacheLocation::configure(self.cache_folder.clone());
    }

    /// Where Quick Export writes when there is no project folder and no earlier export: the projects root, created.
    // Swift: StorageLocations.swift:63
    pub fn export_fallback_directory(&self) -> Option<PathBuf> {
        self.ensured_projects_root()
    }

    /// A scratch subfolder (`<scratch root>/<name>`), created on demand. `None` when it cannot be created.
    // Swift: StorageLocations.swift:66
    pub fn scratch_directory(&self, name: &str) -> Option<PathBuf> {
        let u = self.scratch_root().join(name);
        fs::create_dir_all(&u).ok().map(|_| u)
    }

    /// The projects root, created on demand (`None` when its disk is gone or read-only).
    // Swift: StorageLocations.swift:73
    pub fn ensured_projects_root(&self) -> Option<PathBuf> {
        let u = self.projects_root();
        fs::create_dir_all(&u).ok().map(|_| u)
    }

    // Swift: StorageLocations.swift:78
    pub fn load(d: &dyn UiDefaults) -> StorageLocations {
        let url = |key: &str| d.string(key).filter(|p| Self::is_absolute_path(p)).map(PathBuf::from);
        StorageLocations::new(
            url(StorageLocationsKey::CACHE),
            url(StorageLocationsKey::SCRATCH),
            url(StorageLocationsKey::PROJECTS),
        )
    }

    // Swift: StorageLocations.swift:86
    pub fn save(&self, d: &mut dyn UiDefaults) {
        let mut put = |u: &Option<PathBuf>, key: &str| match u {
            Some(u) => d.set_string(key, &u.to_string_lossy()),
            None => d.remove(key),
        };
        put(&self.cache_folder, StorageLocationsKey::CACHE);
        put(&self.scratch_folder, StorageLocationsKey::SCRATCH);
        put(&self.projects_folder, StorageLocationsKey::PROJECTS);
    }

    // MARK: Validation

    /// An absolute folder path on macOS ("/...") or Windows ("C:/...", "C:\...", "\\server\share").
    // Swift: StorageLocations.swift:95
    pub fn is_absolute_path(p: &str) -> bool {
        if p.starts_with('/') || p.starts_with("\\\\") {
            return true;
        }
        let c = p.as_bytes();
        c.len() >= 3 && c[0].is_ascii_alphabetic() && c[1] == b':' && (c[2] == b'/' || c[2] == b'\\')
    }

    /// Free bytes on the volume holding `url`, or `None` when unknown.
    /// The platform probe installed at start (`ExportPreflight::install_host_probes`); unknown passes validation.
    // Swift: StorageLocations.swift:120
    pub fn free_bytes(url: &Path) -> Option<i64> {
        sq_export::core::preflight::ExportPreflight::free_bytes(url)
    }

    /// `None` when `url` can serve as a storage root: absolute, a folder (or creatable), writable, enough space. An
    /// unknown free size passes. Creates a missing folder (a pick must be usable at once).
    // Swift: StorageLocations.swift:133
    pub fn validate(
        url: &Path,
        required_bytes: i64,
        free_bytes: &dyn Fn(&Path) -> Option<i64>,
    ) -> Option<StorageProblem> {
        if !Self::is_absolute_path(&url.to_string_lossy()) {
            return Some(StorageProblem::NotAbsolute);
        }
        if url.exists() {
            if !url.is_dir() {
                return Some(StorageProblem::NotAFolder);
            }
        } else if fs::create_dir_all(url).is_err() {
            return Some(StorageProblem::NotWritable);
        }
        if fs::metadata(url).map(|m| m.permissions().readonly()).unwrap_or(true) {
            return Some(StorageProblem::NotWritable);
        }
        if let Some(free) = free_bytes(url).filter(|f| required_bytes > 0 && *f < required_bytes) {
            return Some(StorageProblem::NotEnoughSpace { free, needed: required_bytes });
        }
        None
    }

    // MARK: Migration

    /// Copies everything under `old` into `new`, keeping relative paths. Never deletes the old data and never
    /// overwrites a file already in `new`. Refuses identical or nested folders (a copy into itself would recurse).
    // Swift: StorageLocations.swift:156
    pub fn migrate(old: &Path, new: &Path) -> MigrationReport {
        let mut report = MigrationReport::default();
        let src = sq_os::paths::canonical(old).unwrap_or_else(|_| old.to_path_buf());
        let dst = sq_os::paths::canonical(new).unwrap_or_else(|_| new.to_path_buf());
        if src == dst || dst.starts_with(&src) || src.starts_with(&dst) || !src.is_dir() {
            return report;
        }
        if fs::create_dir_all(&dst).is_err() {
            report.failed += 1;
            return report;
        }
        Self::copy_tree(&src, &dst, &mut report);
        report
    }

    fn copy_tree(src: &Path, dst: &Path, report: &mut MigrationReport) {
        let Ok(entries) = fs::read_dir(src) else {
            report.failed += 1;
            return;
        };
        for entry in entries.flatten() {
            let (item, target) = (entry.path(), dst.join(entry.file_name()));
            if item.is_dir() {
                let _ = fs::create_dir_all(&target);
                Self::copy_tree(&item, &target, report);
            } else if target.exists() {
                report.skipped += 1;
            } else if fs::copy(&item, &target).is_ok() {
                report.copied += 1;
            } else {
                report.failed += 1;
            }
        }
    }
}

// MARK: - Preference lists

/// Preferences > Playback > Frame Cache: Auto (scaled to the machine's RAM), then fixed sizes up to half the RAM.
/// One list for every shell.
// Swift: PreferenceChoices.swift:9
pub enum FrameCacheChoices {}

impl FrameCacheChoices {
    /// Stored `AppSettings::frame_cache_gb` per entry; 0 = Auto.
    // Swift: PreferenceChoices.swift:10
    pub fn values(b: &MemoryBudget) -> Vec<i64> {
        std::iter::once(0).chain(b.cache_choices_gb().into_iter().map(|g| g as i64)).collect()
    }

    // Swift: PreferenceChoices.swift:11
    pub fn titles(b: &MemoryBudget) -> Vec<String> {
        let auto = b.auto_frame_cache_bytes() as f64 / GIB as f64;
        std::iter::once(format!("Auto ({auto:.1} GB)"))
            .chain(b.cache_choices_gb().into_iter().map(|g| format!("{g} GB")))
            .collect()
    }

    /// The entry of `gb`; a stored size no longer offered (less RAM now) shows Auto.
    // Swift: PreferenceChoices.swift:18
    pub fn index(gb: i64, b: &MemoryBudget) -> usize {
        Self::values(b).iter().position(|v| *v == gb).unwrap_or(0)
    }
}

/// Preferences > Playback > Audio Output: System Default, every output device, and a stored device that is not connected.
// Swift: PreferenceChoices.swift:22
pub enum AudioOutputChoices {}

/// An audio output device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioOutputDevice {
    // Swift: PreferenceChoices.swift:24
    pub uid: String,
    // Swift: PreferenceChoices.swift:25
    pub name: String,
}

impl AudioOutputDevice {
    // Swift: PreferenceChoices.swift:26
    pub fn new(uid: &str, name: &str) -> AudioOutputDevice {
        AudioOutputDevice { uid: uid.to_string(), name: name.to_string() }
    }
}

/// One row of the audio output popup.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioOutputEntry {
    // Swift: PreferenceChoices.swift:30
    pub title: String,
    /// `None` = System Default.
    // Swift: PreferenceChoices.swift:32
    pub uid: Option<String>,
}

impl AudioOutputChoices {
    // Swift: PreferenceChoices.swift:34
    pub const SYSTEM_DEFAULT: &'static str = "System Default";
    // Swift: PreferenceChoices.swift:36
    pub const NOT_CONNECTED: &'static str = "Not connected (playing on System Default)";

    // Swift: PreferenceChoices.swift:37
    pub fn entries(devices: &[AudioOutputDevice], stored: Option<&str>) -> Vec<AudioOutputEntry> {
        let mut out = vec![AudioOutputEntry { title: Self::SYSTEM_DEFAULT.to_string(), uid: None }];
        out.extend(devices.iter().map(|d| AudioOutputEntry { title: d.name.clone(), uid: Some(d.uid.clone()) }));
        if let Some(s) = stored.filter(|s| !s.is_empty() && !devices.iter().any(|d| d.uid == *s)) {
            out.push(AudioOutputEntry { title: Self::NOT_CONNECTED.to_string(), uid: Some(s.to_string()) });
        }
        out
    }

    // Swift: PreferenceChoices.swift:43
    pub fn index(stored: Option<&str>, entries: &[AudioOutputEntry]) -> usize {
        match stored.filter(|s| !s.is_empty()) {
            Some(s) => entries.iter().position(|e| e.uid.as_deref() == Some(s)).unwrap_or(0),
            None => 0,
        }
    }
}

/// How a cache folder change moves the proxies already made (called with the old and the new proxy folder).
// Swift: PreferenceChoices.swift:53
pub type ProxyMigrate<'a> = &'a dyn Fn(&Path, &Path);

/// How `StorageFolderChoice::set_cache_folder` hands the proxies over.
#[derive(Clone, Copy)]
pub enum ProxyMove<'a> {
    /// Copy in the background; the new folder applies at the next launch.
    Background(ProxyMigrate<'a>),
    /// The app switches its proxy cache at once (Swift `movesProxiesAtOnce`, set by Windows): it gets the old and new
    /// proxy folder, and the note drops "at the next launch".
    AtOnce(ProxyMigrate<'a>),
}

/// Preferences > Media > Cache, Scratch and Projects Folder: Choose... and Use Default, shared by every shell.
// Swift: PreferenceChoices.swift:51
pub enum StorageFolderChoice {}

impl StorageFolderChoice {
    /// Copies the proxies of the old cache folder into the new one (never moves them), on a background thread.
    // Swift: PreferenceChoices.swift:59
    pub fn migrate_in_background(old: &Path, new: &Path) {
        let (old, new) = (old.to_path_buf(), new.to_path_buf());
        std::thread::spawn(move || {
            StorageLocations::migrate(&old, &new);
        });
    }

    /// Sets (`url`) or resets (`None`) the cache folder: validated for a tenth of the cache size, saved, the waveform,
    /// analysis and preview roots moved, the proxies copied over. Returns the note under the row ("" when nothing to
    /// say), or the problem with the folder (nothing changed then).
    // Swift: PreferenceChoices.swift:66
    pub fn set_cache_folder(
        url: Option<&Path>,
        settings: &mut AppSettings,
        d: &mut dyn UiDefaults,
        mover: ProxyMove<'_>,
    ) -> String {
        let old = settings.locations(d).proxy_directory();
        if let Some(url) = url {
            let required = settings.cache_cap_gb * 1_000_000_000 / 10;
            if let Some(problem) = StorageLocations::validate(url, required, &StorageLocations::free_bytes) {
                return problem.message();
            }
        }
        settings.cache_folder = url.map(Path::to_path_buf);
        settings.save(d);
        let l = settings.locations(d);
        l.apply_waveform_directory();
        l.apply_analysis_and_preview_roots();
        let new = l.proxy_directory();
        if old == new {
            return String::new();
        }
        let was = Self::short_path(&old);
        match mover {
            ProxyMove::AtOnce(m) => {
                m(&old, &new);
                SQL10n::format("Proxies already made are copied from %@; the original stays there.", &[&was])
            }
            ProxyMove::Background(m) => {
                m(&old, &new);
                SQL10n::format(
                    "Applies at the next launch. Proxies already made are copied from %@; the original stays there.",
                    &[&was],
                )
            }
        }
    }

    /// Sets (`url`) or resets (`None`) the scratch or projects folder. `None` when saved, else the problem with the folder.
    // Swift: PreferenceChoices.swift:90
    pub fn set_folder(scratch: bool, url: Option<&Path>, d: &mut dyn UiDefaults) -> Option<String> {
        if let Some(problem) = url.and_then(|u| StorageLocations::validate(u, 0, &StorageLocations::free_bytes)) {
            return Some(problem.message());
        }
        let mut l = StorageLocations::load(d);
        let folder = url.map(Path::to_path_buf);
        if scratch {
            l.scratch_folder = folder;
        } else {
            l.projects_folder = folder;
        }
        l.save(d);
        None
    }

    /// `path` with the home folder as `~` (the Mac `abbreviatingWithTildeInPath`, also on Windows).
    // Swift: PreferenceChoices.swift:147
    pub fn short_path(url: &Path) -> String {
        Self::short_path_in(url, &home_directory(), std::path::MAIN_SEPARATOR)
    }

    /// [`StorageFolderChoice::short_path`] for a given home folder and separator (Windows shows `~\AppData\Local`, the
    /// separator the rest of the Media page and Explorer use).
    pub fn short_path_in(url: &Path, home: &Path, separator: char) -> String {
        match url.strip_prefix(home) {
            Ok(rest) if !home.as_os_str().is_empty() => {
                let parts: Vec<_> = rest.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
                if parts.is_empty() {
                    "~".to_string()
                } else {
                    format!("~{separator}{}", parts.join(&separator.to_string()))
                }
            }
            _ => url.to_string_lossy().into_owned(),
        }
    }
}

// MARK: - Effect and transition defaults

/// A group of the "Your effect and transition defaults" list.
// Swift: PreferenceChoices.swift:101
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EffectDefaultsGroup {
    /// Effects.
    Effects,
    /// Video transitions.
    VideoTransitions,
    /// Audio transitions.
    AudioTransitions,
}

impl EffectDefaultsGroup {
    /// Every group, in order.
    pub const ALL: [EffectDefaultsGroup; 3] =
        [EffectDefaultsGroup::Effects, EffectDefaultsGroup::VideoTransitions, EffectDefaultsGroup::AudioTransitions];

    // Swift: PreferenceChoices.swift:103
    pub fn title(self) -> &'static str {
        match self {
            EffectDefaultsGroup::Effects => "Effects",
            EffectDefaultsGroup::VideoTransitions => "Video Transitions",
            EffectDefaultsGroup::AudioTransitions => "Audio Transitions",
        }
    }
}

/// One entry of the defaults list: an effect kind or a transition.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum EffectDefaultsEntry {
    /// An effect, by kind.
    Effect(String),
    /// A transition.
    Transition(TransitionKind),
}

impl EffectDefaultsEntry {
    // Swift: PreferenceChoices.swift:114
    pub fn title(&self) -> String {
        match self {
            EffectDefaultsEntry::Effect(k) => EffectCatalog::title_for(k),
            EffectDefaultsEntry::Transition(k) => k.name().to_string(),
        }
    }
}

/// Preferences > Editing > "Your effect and transition defaults": the kinds with a user default in three groups.
pub trait EffectDefaultsSettings {
    /// The entries of `g`, sorted by title.
    fn entries_in(&self, g: EffectDefaultsGroup) -> Vec<EffectDefaultsEntry>;
    /// Restore Factory of one entry.
    fn remove_entry(&mut self, e: &EffectDefaultsEntry);
}

impl EffectDefaultsSettings for EffectDefaults {
    // Swift: PreferenceChoices.swift:126
    fn entries_in(&self, g: EffectDefaultsGroup) -> Vec<EffectDefaultsEntry> {
        let transitions: Vec<TransitionKind> = self
            .transitions
            .keys()
            .filter_map(|k| serde_json::from_value(serde_json::Value::String(k.clone())).ok())
            .collect();
        let mut list: Vec<EffectDefaultsEntry> = match g {
            EffectDefaultsGroup::Effects => self.effects.keys().cloned().map(EffectDefaultsEntry::Effect).collect(),
            EffectDefaultsGroup::VideoTransitions => transitions
                .into_iter()
                .filter(|k| k.track_kind() == TrackKind::Video)
                .map(EffectDefaultsEntry::Transition)
                .collect(),
            EffectDefaultsGroup::AudioTransitions => transitions
                .into_iter()
                .filter(|k| k.track_kind() != TrackKind::Video)
                .map(EffectDefaultsEntry::Transition)
                .collect(),
        };
        list.sort_by_cached_key(|e| e.title().to_lowercase());
        list
    }

    // Swift: PreferenceChoices.swift:137
    fn remove_entry(&mut self, e: &EffectDefaultsEntry) {
        match e {
            EffectDefaultsEntry::Effect(k) => self.remove_default_effect(k),
            EffectDefaultsEntry::Transition(k) => {
                if let Ok(serde_json::Value::String(raw)) = serde_json::to_value(k) {
                    self.remove_default_transition(&raw);
                }
            }
        }
    }
}

impl EffectDefaultsGroup {
    /// The empty-group hint.
    // Swift: PreferenceChoices.swift:121
    pub const EMPTY_GROUP_TEXT: &'static str =
        "None yet. Right-click an effect or transition and choose Use as Default.";
    // Swift: PreferenceChoices.swift:123
    pub const SETTINGS_HELP: &'static str = "New effects and transitions of these kinds start with your values. Presets you apply still win. Restore Factory deletes your default; instances already in a project keep their values.";
}
