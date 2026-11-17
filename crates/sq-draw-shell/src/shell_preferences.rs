// Swift: ShellPreferences.swift
//! Preferences, translated from the Mac `SettingsWindow`: the same pages, row titles, choices and `AppSettings` fields,
//! as `ShellForm` rows in a shell dialog with the page list in a sidebar column, as the Mac window.
//! The stores outside `AppSettings` (UI language and size, `TransitionDefaults`, `AudioRoleDefaults`, De-Click, Live
//! Ducking with its preset and timing, Meter Response, Fade Shape, media defaults, card import) ride along in `Extras`;
//! the host applies what it reads from [`ShellEvent::SettingsChanged`]. What the host knows (output devices, the effect
//! defaults library, whether it has a card import window) comes in [`PreferencesHost`]; a row whose reader the host lacks
//! is left out. The Library Folders list is a `ShellForm` list box with folder icons (`ListLine`). The Advanced page (Edit
//! API) shows when the host sets `PreferencesHost::edit_api`.
//!
//! Mapping: Swift read and wrote one `UserDefaults`; the Rust stores take different traits (`UiDefaults`, the library's
//! `SettingsStore`, the audio core's `DefaultsStore`), so [`Bridge`] lends the one `ShellHost::defaults` to all of them.
//! The Swift hooks of the host (`audioOutputs`, `effectDefaultsLibrary`, `hasCardImport`, `libraryFolders`, `clearCache`,
//! `editAPI`, `addLibraryFolder`, `removeLibraryFolder`, `onSettingsChanged`) are the plain data of [`PreferencesHost`] and
//! [`ShellEvent`]s the app answers.

use crate::shell_app_menu::{AppMenuRequest, AppMenuRow};
use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_edit_api::EditApiState;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{GridCell, ListLine, NumberField, Row, ShellForm, Sidebar, Status};
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use crate::shell_live::Live;
use crate::shell_platform_text::ShellPlatformText;
use sq_core_audio::{DefaultsStore, DuckTimingExt, LiveDucking};
use sq_core_edit::duck_preset::DuckPreset;
use sq_core_edit::interface_scale;
use sq_core_effects::transition::TransitionKindExt;
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::fades_curve::{DefaultFadeCurve, FadeCurve};
use sq_core_model::{AudioTag, DuckTiming, MediaPolicyDefaults, OutsideMediaMode, TransitionKind};
use sq_draw::monitor::audio_meter::MeterStyle;
use sq_editor_session::{
    AppSettings, AudioOutputChoices, AudioOutputDevice, AudioPreferences, AudioRoleDefaults, CardImportSettings,
    DuckTimingChoices, EffectDefaultsEntry, EffectDefaultsGroup, EffectDefaultsSettings, MediaSettings, MonitorQuality,
    StorageFolderChoice, TransitionDefaults, UpdateCheck,
};
use sq_library::library_folder_store::SettingsStore;
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::appearance_palette::{AppearanceMode, AppearanceSettings, UiDefaults};
use sq_uikit::localization::{self, SQL10n};
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The Preferences pages.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Page {
    /// General.
    General,
    /// Playback.
    Playback,
    /// Editing.
    Editing,
    /// Audio.
    Audio,
    /// Media.
    Media,
    /// Keyboard Shortcuts (R4e): a sidebar page; the editor draws it (`shell_shortcuts_draw.rs`).
    Shortcuts,
    /// Edit API: only when the host runs one (`PreferencesHost::edit_api`; the Mac app and the Windows app do).
    Advanced,
}

impl Page {
    /// Every page, in the sidebar's order.
    pub const ALL: [Page; 7] =
        [Page::General, Page::Playback, Page::Editing, Page::Audio, Page::Media, Page::Shortcuts, Page::Advanced];

    /// The page at sidebar index `i`.
    pub fn from_index(i: i64) -> Option<Page> {
        usize::try_from(i).ok().and_then(|i| Self::ALL.get(i).copied())
    }

    /// The sidebar index.
    pub fn index(self) -> i64 {
        Self::ALL.iter().position(|p| *p == self).unwrap_or(0) as i64
    }

    /// Sidebar title.
    pub fn title(self) -> &'static str {
        match self {
            Page::General => "General",
            Page::Playback => "Playback",
            Page::Editing => "Editing",
            Page::Audio => "Audio",
            Page::Media => "Media",
            Page::Shortcuts => "Shortcuts",
            Page::Advanced => "Advanced",
        }
    }

    /// The line under the page title (frame `Settings / <page>`).
    pub fn subtitle(self) -> &'static str {
        match self {
            Page::General => "Size, look and how Sequence Studio keeps your work safe.",
            Page::Playback => "How smoothly the monitors play and what runs in the background.",
            Page::Editing => "How new sequences behave and how long transitions are.",
            Page::Audio => "Clicks, ducking, roles and meters.",
            Page::Media => "Where files go, what gets copied and how big the cache may grow.",
            Page::Shortcuts => "Every key and what it does. Click a key to see its commands.",
            Page::Advanced => "Folders and the local Edit API.",
        }
    }

    /// The Mac `SettingsPage.icon`.
    pub fn icon(self) -> SQIcon {
        match self {
            Page::General => SQIcon::SlidersHorizontal,
            Page::Playback => SQIcon::PlayCircle,
            Page::Editing => SQIcon::ToolBlade, // scissors
            Page::Audio => SQIcon::Waveform,
            Page::Media => SQIcon::Folder,
            Page::Shortcuts => SQIcon::Keyboard,
            Page::Advanced => SQIcon::Settings, // gear
        }
    }
}

/// How the Settings window ended.
enum PrefsExit {
    /// Done.
    Done,
    /// The Shortcuts page was picked: the editor takes over the window.
    Shortcuts,
    /// General > App menu > Add…
    AddAppMenu,
    /// General > App menu > Remove…
    RemoveAppMenu,
}

/// One watched Library folder as Preferences shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShellLibraryFolder {
    /// The folder's id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Abbreviated with `~`.
    pub path: String,
    /// The folder cannot be read now.
    pub offline: bool,
}

/// What the host tells Preferences (the Swift hooks on `ShellHost`); the app keeps it current.
#[derive(Clone, Debug)]
pub struct PreferencesHost {
    /// Stored `frame_cache_gb` per Frame Cache entry (0 = Auto); `FrameCacheChoices::values`.
    pub frame_cache_values: Vec<i64>,
    /// The entries' titles; `FrameCacheChoices::titles`.
    pub frame_cache_titles: Vec<String>,
    /// This machine's memory, shown in the Frame Cache help.
    pub physical_memory_gb: i64,
    /// `None`: the host cannot pick a device (row left out).
    pub audio_outputs: Option<Vec<AudioOutputDevice>>,
    /// `None`: the host has no effect defaults library (rows left out).
    pub effect_defaults: Option<EffectDefaults>,
    /// The host opens an import window when a card mounts (else the Card Import row is left out).
    pub card_import: bool,
    /// The Library's watched folders; `None`: the host has no Library (the Library Folders rows are left out).
    pub library_folders: Option<Vec<ShellLibraryFolder>>,
    /// The cache size line next to Delete Cache ("Calculating…", "Empty", "1.2 GB"); `None`: no Delete Cache row.
    pub cache_used: Option<String>,
    /// The Edit API switch and its status; `None`: no Advanced page.
    pub edit_api: Option<(bool, EditApiState)>,
    /// Linux AppImage: the General page's app menu row; the host sets it from the files on disk.
    pub app_menu: AppMenuRow,
    /// R4e: the text in the sidebar search; empty shows the selected page.
    pub search: String,
    /// R4e: the next page install puts the keyboard in the search field.
    pub focus_search: bool,
}

impl Default for PreferencesHost {
    fn default() -> PreferencesHost {
        PreferencesHost {
            frame_cache_values: vec![0],
            frame_cache_titles: vec!["Auto".to_string()],
            physical_memory_gb: 16,
            audio_outputs: None,
            effect_defaults: None,
            card_import: false,
            library_folders: None,
            cache_used: None,
            edit_api: None,
            app_menu: AppMenuRow::Hidden,
            search: String::new(),
            focus_search: false,
        }
    }
}

/// The stores outside `AppSettings` the pages edit, as the Mac window reads them.
#[derive(Clone, Debug, PartialEq)]
pub struct Extras {
    /// `SQL10n.defaultsKey` value; "system" = the key removed.
    pub ui_language: String,
    /// Default transition lengths.
    pub transitions: TransitionDefaults,
    /// Per-role audio defaults.
    pub roles: AudioRoleDefaults,
    /// Interface Size factor (one of `interface_scale::STEPS`).
    pub ui_scale: f64,
    /// De-Click.
    pub de_click: bool,
    /// Live Ducking amount in dB; `None` = off.
    pub duck_amount: Option<f64>,
    /// Meter Response.
    pub meter_style: MeterStyle,
    /// Fade Shape.
    pub fade_curve: FadeCurve,
    /// Duck Timing.
    pub duck_timing: DuckTiming,
    /// Outside Files, Project Folder and Library (`MediaSettings`).
    pub media: MediaPolicyDefaults,
    /// Open the import window when a card is connected.
    pub card_import: bool,
    /// Dark / Light, Background and Contrast (the start screen's Appearance popover, `sq.appearance.*`).
    pub appearance: AppearanceSettings,
    /// Settings › General › "Show experimental labels".
    pub experimental_labels: bool,
}

/// Lends one [`UiDefaults`] store to the stores that want another trait. Numbers are kept as text.
// shortcut: `DefaultsStore::number` and `SettingsStore::data` ride on the string and data slots of the one store; upgrade
// when the app's store has number slots of its own.
pub(crate) struct Bridge<'a>(pub(crate) &'a mut dyn UiDefaults);

impl SettingsStore for Bridge<'_> {
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.data(key)
    }
    fn set_data(&mut self, key: &str, value: Vec<u8>) {
        self.0.set_data(key, &value);
    }
    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

impl DefaultsStore for Bridge<'_> {
    fn number(&self, key: &str) -> Option<f64> {
        self.0.string(key).and_then(|s| s.trim().parse().ok())
    }
    fn set_number(&mut self, key: &str, value: f64) {
        self.0.set_string(key, &value.to_string());
    }
    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

impl crate::shell_host::ShellHost {
    /// The live ducking a project plays with: its own stored setting, else Preferences (`LiveDucking.resolved`).
    pub fn resolved_live_ducking(&self, project: Option<&sq_core_model::ProjectLiveDucking>) -> Option<LiveDucking> {
        LiveDucking::resolved(project, &ReadBridge(&*self.defaults))
    }
}

/// Read-only access through the same adapter.
struct ReadBridge<'a>(&'a dyn UiDefaults);

impl SettingsStore for ReadBridge<'_> {
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        self.0.data(key)
    }
    fn set_data(&mut self, _key: &str, _value: Vec<u8>) {}
    fn remove(&mut self, _key: &str) {}
}

impl DefaultsStore for ReadBridge<'_> {
    fn number(&self, key: &str) -> Option<f64> {
        self.0.string(key).and_then(|s| s.trim().parse().ok())
    }
    fn set_number(&mut self, _key: &str, _value: f64) {}
    fn remove(&mut self, _key: &str) {}
}

impl Default for Extras {
    fn default() -> Extras {
        Extras {
            ui_language: "system".to_string(),
            transitions: TransitionDefaults::STANDARD,
            roles: AudioRoleDefaults::standard(),
            ui_scale: 1.0,
            de_click: true,
            duck_amount: None,
            meter_style: MeterStyle::Standard,
            fade_curve: FadeCurve::Linear,
            duck_timing: DuckTiming::classic(),
            media: MediaPolicyDefaults::default(),
            card_import: true,
            appearance: AppearanceSettings::standard(),
            experimental_labels: true,
        }
    }
}

impl Extras {
    /// The stored values.
    pub fn load(d: &dyn UiDefaults) -> Extras {
        let bridge = ReadBridge(d);
        Extras {
            ui_language: d.string(localization::DEFAULTS_KEY).unwrap_or_else(|| "system".to_string()),
            transitions: TransitionDefaults::load(&bridge),
            roles: AudioRoleDefaults::load(&bridge),
            ui_scale: interface_scale::load(
                d.string(interface_scale::DEFAULTS_KEY).and_then(|s| s.trim().parse().ok()),
            ),
            de_click: AudioPreferences::de_click(d),
            duck_amount: LiveDucking::current(&bridge).map(|l| l.amount_db),
            meter_style: MeterStyle::current(d),
            fade_curve: DefaultFadeCurve::from_stored(d.string(DefaultFadeCurve::DEFAULTS_KEY).as_deref()),
            duck_timing: DuckTiming::stored(&bridge),
            media: MediaSettings::load(d),
            card_import: CardImportSettings::is_enabled(d),
            appearance: AppearanceSettings::from_defaults(d),
            experimental_labels: sq_draw::experimental::Prefs::load(d).labels,
        }
    }

    /// Writes what changed.
    pub fn save(&self, d: &mut dyn UiDefaults) {
        if self.ui_language == "system" {
            d.remove(localization::DEFAULTS_KEY);
        } else {
            d.set_string(localization::DEFAULTS_KEY, &self.ui_language);
        }
        self.transitions.save(&mut Bridge(d));
        self.roles.save(&mut Bridge(d));
        let stored: Option<f64> = d.string(interface_scale::DEFAULTS_KEY).and_then(|s| s.trim().parse().ok());
        if interface_scale::load(stored) != self.ui_scale {
            d.set_string(interface_scale::DEFAULTS_KEY, &interface_scale::store(self.ui_scale).to_string());
        }
        AudioPreferences::set_de_click(self.de_click, d);
        if LiveDucking::current(&ReadBridge(d)).map(|l| l.amount_db) != self.duck_amount {
            LiveDucking::set_amount(self.duck_amount, &mut Bridge(d));
        }
        d.set_string(MeterStyle::DEFAULTS_KEY, self.meter_style.raw_value());
        d.set_string(DefaultFadeCurve::DEFAULTS_KEY, fade_raw(self.fade_curve));
        if DuckTiming::stored(&ReadBridge(d)) != self.duck_timing.clamped() {
            DuckTiming::store(&self.duck_timing, &mut Bridge(d));
        }
        if MediaSettings::load(d) != self.media {
            MediaSettings::store(self.media, d);
        }
        if CardImportSettings::is_enabled(d) != self.card_import {
            CardImportSettings::set_enabled(self.card_import, d);
        }
        if AppearanceSettings::from_defaults(d) != self.appearance {
            self.appearance.save(d);
        }
        let mut exp = sq_draw::experimental::Prefs::load(d);
        if exp.labels != self.experimental_labels {
            exp.labels = self.experimental_labels;
            exp.save(d);
        }
        sq_draw::experimental::set_prefs(exp);
    }
}

/// A button of a `.buttons` row: what the host does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ButtonAction {
    ChooseFolder(Folder),
    UseDefault(Folder),
    RestoreFactory(EffectDefaultsEntry),
    AddLibraryFolder,
    RemoveLibraryFolder(usize),
    ClearCache,
}

/// A storage folder row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Folder {
    Cache,
    Scratch,
    Projects,
}

impl Folder {
    fn from_id(id: &str) -> Option<Folder> {
        match id {
            "cacheFolder" => Some(Folder::Cache),
            "scratchFolder" => Some(Folder::Scratch),
            "projectsFolder" => Some(Folder::Projects),
            _ => None,
        }
    }
}

/// The Duck Timing fields: id suffix, title, upper bound in ms (the Mac `DuckTimingForm`).
const TIMING_FIELDS: [(&str, &str, f64); 5] = [
    ("lookahead", "Lookahead", 500.0),
    ("attack", "Attack", 2000.0),
    ("hold", "Hold", 2000.0),
    ("recovery", "Recovery", 5000.0),
    ("minPause", "Minimum pause", 2000.0),
];

fn timing_value(t: &DuckTiming, field: usize) -> f64 {
    [t.lookahead_ms, t.attack_ms, t.hold_ms, t.recovery_ms, t.min_pause_ms][field]
}

fn set_timing_value(t: &mut DuckTiming, field: usize, v: f64) {
    match field {
        0 => t.lookahead_ms = v,
        1 => t.attack_ms = v,
        2 => t.hold_ms = v,
        3 => t.recovery_ms = v,
        _ => t.min_pause_ms = v,
    }
}

const OUTSIDE_MODES: [OutsideMediaMode; 4] =
    [OutsideMediaMode::Ask, OutsideMediaMode::Copy, OutsideMediaMode::Move, OutsideMediaMode::Leave];
const CROSSFADE_KINDS: [TransitionKind; 3] =
    [TransitionKind::ConstantPower, TransitionKind::ConstantGain, TransitionKind::ExponentialFade];
const QUALITIES: [MonitorQuality; 4] =
    [MonitorQuality::Auto, MonitorQuality::Full, MonitorQuality::Half, MonitorQuality::Quarter];
const ROLES: [AudioTag; 3] = [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx];

fn role_raw(t: AudioTag) -> &'static str {
    match t {
        AudioTag::Dialogue => "dialogue",
        AudioTag::Music => "music",
        AudioTag::Sfx => "sfx",
    }
}

fn appearance_title(m: AppearanceMode) -> &'static str {
    match m {
        AppearanceMode::Dark => "Dark",
        AppearanceMode::Light => "Light",
        AppearanceMode::System => "System",
    }
}

fn outside_title(m: OutsideMediaMode) -> &'static str {
    match m {
        OutsideMediaMode::Ask => "Ask each time",
        OutsideMediaMode::Copy => "Copy into project",
        OutsideMediaMode::Move => "Move into project",
        OutsideMediaMode::Leave => "Leave in place",
    }
}

fn fade_raw(c: FadeCurve) -> &'static str {
    match c {
        FadeCurve::Linear => "linear",
        FadeCurve::SCurve => "sCurve",
        FadeCurve::Plus3dB => "plus3dB",
        FadeCurve::Minus3dB => "minus3dB",
    }
}

fn quality_title(q: MonitorQuality) -> &'static str {
    match q {
        MonitorQuality::Auto => "Auto",
        MonitorQuality::Full => "Full",
        MonitorQuality::Half => "1/2",
        MonitorQuality::Quarter => "1/4",
    }
}

/// The Preferences form and its rules (Swift `ShellPreferences`).
pub struct ShellPreferences;

impl ShellPreferences {
    /// The footer line: "3 changes · apply right away" (the kit), plain while nothing differs from the defaults.
    pub(crate) fn footer_hint(changes: usize) -> String {
        match changes {
            0 => "Changes apply right away.".to_string(),
            1 => "1 change · applies right away".to_string(),
            n => format!("{n} changes · apply right away"),
        }
    }

    /// The Library Folders list as the dialog shows it right after Add or Remove: the page is rebuilt before the app has
    /// handled the event, so the row appears or goes at once; the app's next sync then replaces the list with the real
    /// ids (an added row carries an empty id until then).
    pub(crate) fn show_folder_change(c: &mut PreferencesHost, act: ButtonAction, added: Option<&Path>) {
        let Some(list) = c.library_folders.as_mut() else { return };
        match (act, added) {
            (ButtonAction::RemoveLibraryFolder(i), _) if i < list.len() => {
                list.remove(i);
            }
            (ButtonAction::AddLibraryFolder, Some(url)) => list.push(ShellLibraryFolder {
                id: String::new(),
                name: url.file_name().map_or_else(|| url.display().to_string(), |n| n.to_string_lossy().into_owned()),
                path: url.display().to_string(),
                offline: false,
            }),
            _ => {}
        }
    }

    /// The page list of the Preferences form (the Mac sidebar); Advanced only when the host has an Edit API.
    pub fn sidebar(c: &PreferencesHost) -> Sidebar {
        Sidebar {
            id: "page".to_string(),
            items: Page::ALL
                .iter()
                .filter(|p| **p != Page::Advanced || c.edit_api.is_some())
                .map(|p| (p.title().to_string(), p.icon()))
                .collect(),
        }
    }

    /// "System" and every supported UI language in its own name.
    fn ui_languages() -> Vec<String> {
        std::iter::once("system".to_string()).chain(localization::SUPPORTED.iter().map(|s| (*s).to_string())).collect()
    }

    fn ui_language_title(code: &str) -> String {
        match code {
            "system" => "System".to_string(),
            other => sq_uikit::local_format::native_language_name(other),
        }
    }

    fn percent(v: f64) -> String {
        format!("{} %", (v * 100.0).round() as i64)
    }

    /// The transcription languages offered, plus the stored one when it is not among them (the Mac `selectLanguage`).
    pub fn transcription_languages(current: &str) -> Vec<String> {
        let mut list: Vec<String> = AppSettings::SUPPORTED_CAPTION_LANGUAGES.iter().map(|s| (*s).to_string()).collect();
        if !list.iter().any(|l| l == current) {
            list.push(current.to_string());
        }
        list
    }

    /// A transcription language named in the interface language (`Locale.current.localizedString(forIdentifier:)`).
    fn language_title(id: &str) -> String {
        sq_uikit::local_format::language_name(id, None)
    }

    /// The Mac `liveDuckAmount`: 0.5...40 dB in 0.5 steps, one decimal, 12 by default, no unit shown.
    fn duck_amount_field(db: Option<f64>) -> NumberField {
        NumberField {
            id: "duckAmount".to_string(),
            value: db.unwrap_or(12.0),
            range: 0.5..=40.0,
            step: 0.5,
            decimals: 1,
            unit: "dB".to_string(),
            default_value: Some(12.0),
        }
    }

    /// The Edit API status line (`SettingsWindow.applyAPIState`): Copy address only while there is a port.
    pub fn api_status(s: &EditApiState) -> Status {
        Status {
            text: s.text.clone(),
            tone: s.tone,
            button: s.copyable_port.map(|_| "Copy address".to_string()),
            button_icon: Some(SQIcon::Copy),
        }
    }

    fn seconds(n: i64) -> String {
        if n == 1 { "1 second".to_string() } else { format!("{n} seconds") }
    }

    fn duck_preset_index(x: &Extras) -> usize {
        let Some(amount) = x.duck_amount else { return 0 };
        DuckPreset::matching(amount, &x.duck_timing)
            .and_then(|m| DuckPreset::all().iter().position(|p| *p == m))
            .map_or(0, |i| i + 1)
    }

    fn duck_preset_titles() -> Vec<String> {
        std::iter::once("Custom".to_string()).chain(DuckPreset::all().iter().map(|p| p.title.to_string())).collect()
    }

    /// The rows of one page filled from `s`; the form's sidebar (`sidebar`, id "page") picks the page. Rows, captions,
    /// help lines, check labels and control widths are the Mac `SettingsWindow` pages (`SQFormRow`).
    pub fn form(
        page: Page,
        s: &AppSettings,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
        folder_note: &str,
    ) -> ShellForm {
        let p = Self::page_rows(page, s, x, c, d, folder_note);
        let mut f = ShellForm::with_sidebar(p.rows, Some(Self::sidebar(c)), page.index());
        f.side_pad = 24.0; // the Mac page rows start at the sidebar rule + 24 (control column 373)
        f.helps = p.helps;
        f.check_labels = p.check_labels;
        f.control_widths = p.widths;
        for (id, cells) in p.grids {
            f.set_grid(&id, cells);
        }
        for (id, field, w) in p.check_fields {
            f.set_check_field(&id, field, w);
        }
        f.label_tinted = p.label_tinted;
        f.statuses = p.statuses;
        f.list_lines = p.list_lines;
        for id in &p.choice_cards {
            f.set_choice_cards(id);
        }
        f
    }

    /// The pages the sidebar lists.
    fn visible_pages(c: &PreferencesHost) -> Vec<Page> {
        Page::ALL.iter().copied().filter(|p| *p != Page::Advanced || c.edit_api.is_some()).collect()
    }

    /// The ids on `page` whose value differs from the factory value (the form's value map against the default form's).
    fn changed_ids(
        page: Page,
        s: &AppSettings,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
    ) -> BTreeSet<String> {
        let current = Self::form(page, s, x, c, d, "");
        let factory_extras = Extras { ui_language: x.ui_language.clone(), ..Extras::default() };
        let factory = Self::form(page, &AppSettings::standard(), &factory_extras, c, d, "");
        current
            .values()
            .iter()
            .filter(|(k, v)| k.as_str() != "page" && factory.values().get(*k) != Some(*v))
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// The factory value of row `id` on `page` (what its reset arrow goes back to).
    pub(crate) fn factory_value(
        page: Page,
        id: &str,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
    ) -> Option<FormValue> {
        let factory_extras = Extras { ui_language: x.ui_language.clone(), ..Extras::default() };
        Self::form(page, &AppSettings::standard(), &factory_extras, c, d, "").values().get(id).cloned()
    }

    /// The page that owns row `id` (the Results page asks).
    pub(crate) fn page_of(
        id: &str,
        s: &AppSettings,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
    ) -> Option<Page> {
        Self::visible_pages(c)
            .into_iter()
            .find(|p| Self::page_rows(*p, s, x, c, d, "").rows.iter().any(|r| r.id() == Some(id)))
    }

    /// The changed ids among the rows of `f` and the changed count per sidebar page (R4e dots and counters).
    pub(crate) fn marks(
        f: &dyn DialogForm,
        s: &AppSettings,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
    ) -> (BTreeSet<String>, Vec<usize>) {
        let pages = Self::visible_pages(c);
        let sets: Vec<BTreeSet<String>> = pages
            .iter()
            .map(|p| if *p == Page::Shortcuts { BTreeSet::new() } else { Self::changed_ids(*p, s, x, c, d) })
            .collect();
        let shown: BTreeSet<String> =
            f.row_ids().into_iter().filter(|id| sets.iter().any(|set| set.contains(id))).collect();
        // The Shortcuts page counts changed key bindings, not rows.
        let counts = pages
            .iter()
            .zip(&sets)
            .map(|(p, set)| {
                if *p == Page::Shortcuts {
                    crate::shell_shortcuts::ShellShortcutsEditor::changed_bindings(d)
                } else {
                    set.len()
                }
            })
            .collect();
        (shown, counts)
    }

    /// Every word of `query` is in `haystack` (ignoring case).
    fn matches(query: &str, haystack: &str) -> bool {
        let h = haystack.to_lowercase();
        query.split_whitespace().all(|w| h.contains(&w.to_lowercase()))
    }

    /// The search Results page: every row of every page whose title, help or page name has all words of `query`, under the
    /// name of its page.
    pub fn search_form(query: &str, s: &AppSettings, x: &Extras, c: &PreferencesHost, d: &dyn UiDefaults) -> ShellForm {
        let mut all = PageRows::default();
        for page in Self::visible_pages(c).into_iter().filter(|p| !matches!(p, Page::Shortcuts | Page::Advanced)) {
            let p = Self::page_rows(page, s, x, c, d, "");
            let mut hits: Vec<Row> = Vec::new();
            for r in &p.rows {
                let Some(id) = r.id() else { continue };
                let title = match r {
                    Row::Popup { label, .. } | Row::Field { label, .. } | Row::Slider { label, .. } => label.clone(),
                    Row::Buttons { label, .. } => label.clone(),
                    _ => p.check_labels.get(id).cloned().unwrap_or_default(),
                };
                let text = format!(
                    "{title} {} {} {}",
                    p.check_labels.get(id).cloned().unwrap_or_default(),
                    match r {
                        Row::Check { title, .. } => title.clone(),
                        _ => String::new(),
                    },
                    p.helps.get(id).cloned().unwrap_or_default()
                );
                if Self::matches(query, &format!("{text} {}", page.title())) {
                    hits.push(r.clone());
                }
            }
            if hits.is_empty() {
                continue;
            }
            all.rows.push(Row::Caption(page.title().to_string()));
            for r in hits {
                let id = r.id().map(str::to_string);
                all.rows.push(r);
                if let Some(id) = id {
                    if let Some(v) = p.helps.get(&id) {
                        all.helps.insert(id.clone(), v.clone());
                    }
                    if let Some(v) = p.check_labels.get(&id) {
                        all.check_labels.insert(id.clone(), v.clone());
                    }
                    if let Some(v) = p.widths.get(&id) {
                        all.widths.insert(id.clone(), *v);
                    }
                    if let Some(g) = p.grids.iter().find(|(gid, _)| *gid == id) {
                        all.grids.push(g.clone());
                    }
                    if let Some(g) = p.check_fields.iter().find(|(gid, _, _)| *gid == id) {
                        all.check_fields.push(g.clone());
                    }
                    if let Some(v) = p.statuses.get(&id) {
                        all.statuses.insert(id.clone(), v.clone());
                    }
                    if let Some(v) = p.list_lines.get(&id) {
                        all.list_lines.insert(id.clone(), v.clone());
                    }
                    if p.choice_cards.contains(&id) {
                        all.choice_cards.insert(id.clone());
                    }
                    if p.label_tinted.contains(&id) {
                        all.label_tinted.insert(id.clone());
                    }
                }
            }
        }
        // #41: the one search also finds shortcuts, by command name or by keys.
        let mut keys = crate::shell_shortcuts::ShellShortcutsEditor::new(d, sq_os::Platform::current());
        keys.set_query(query);
        if !keys.rows().is_empty() {
            const MAX_SHORTCUT_HITS: usize = 12;
            all.rows.push(Row::Caption(Page::Shortcuts.title().to_string()));
            for r in keys.rows().iter().take(MAX_SHORTCUT_HITS) {
                all.rows
                    .push(Row::Text(format!("{}   {} · {}", r.listing.command, r.listing.shortcut, r.listing.scope)));
            }
            if keys.rows().len() > MAX_SHORTCUT_HITS {
                all.rows
                    .push(Row::Text(format!("{} more on the Shortcuts page", keys.rows().len() - MAX_SHORTCUT_HITS)));
            }
        }
        if all.rows.is_empty() {
            all.rows.push(Row::Text(SQL10n::format("No settings match “%@”.", &[query])));
        }
        let mut f = ShellForm::with_sidebar(all.rows, Some(Self::sidebar(c)), -1);
        f.side_pad = 24.0;
        f.helps = all.helps;
        f.check_labels = all.check_labels;
        f.control_widths = all.widths;
        for (id, cells) in all.grids {
            f.set_grid(&id, cells);
        }
        for (id, field, w) in all.check_fields {
            f.set_check_field(&id, field, w);
        }
        f.label_tinted = all.label_tinted;
        f.statuses = all.statuses;
        f.list_lines = all.list_lines;
        for id in &all.choice_cards {
            f.set_choice_cards(id);
        }
        f
    }

    fn page_rows(
        page: Page,
        s: &AppSettings,
        x: &Extras,
        c: &PreferencesHost,
        d: &dyn UiDefaults,
        folder_note: &str,
    ) -> PageRows {
        let mut p = PageRows::default();
        match page {
            Page::General => {
                // English only for now: no Interface Language row (the stored choice is ignored too).
                if !localization::ENGLISH_ONLY {
                    let langs = Self::ui_languages();
                    let titles: Vec<String> = langs.iter().map(|l| Self::ui_language_title(l)).collect();
                    p.popup(
                        "uiLanguage",
                        "Interface Language",
                        titles,
                        langs.iter().position(|l| *l == x.ui_language).unwrap_or(0),
                        196.0,
                        Some(
                            "The language of menus, panels and settings. Applies the next time Sequence Studio starts.",
                        ),
                    );
                }
                p.popup(
                    "uiScale",
                    "Interface Size",
                    interface_scale::STEPS.iter().map(|v| Self::percent(*v)).collect(),
                    interface_scale::STEPS.iter().position(|v| *v == x.ui_scale).unwrap_or(2),
                    196.0,
                    Some("Scales text and controls everywhere, right away."),
                );
                // Appearance lives here in the shared shell (DECISIONS 2026-10-28); the Mac has it in the start window.
                p.popup(
                    "appearance",
                    "Appearance",
                    AppearanceMode::ALL.iter().map(|m| appearance_title(*m).to_string()).collect(),
                    AppearanceMode::ALL.iter().position(|m| *m == x.appearance.mode).unwrap_or(0),
                    196.0,
                    Some("System follows your computer's light or dark setting."),
                );
                p.choice_cards.insert("appearance".to_string());
                let (bg, ct) = (AppearanceSettings::BACKGROUND_RANGE, AppearanceSettings::CONTRAST_RANGE);
                p.rows.push(Row::slider(
                    "appearanceBackground",
                    "Background",
                    x.appearance.background() as f64,
                    *bg.start() as f64..=*bg.end() as f64,
                ));
                p.rows.push(Row::slider(
                    "appearanceContrast",
                    "Contrast",
                    x.appearance.contrast() as f64,
                    *ct.start() as f64..=*ct.end() as f64,
                ));
                p.popup(
                    "autosave",
                    "Autosave",
                    AppSettings::AUTOSAVE_CHOICES
                        .iter()
                        .map(|v| if *v < 120.0 { "Every minute".to_string() } else { format!("Every {} minutes", (*v / 60.0) as i64) })
                        .collect(),
                    AppSettings::AUTOSAVE_CHOICES.iter().position(|v| *v == s.autosave_interval).unwrap_or(2),
                    196.0,
                    Some("Changed projects are saved to a recovery copy; your project file is only written when you save."),
                );
                p.check(
                    "recovery",
                    "Recovery",
                    "Offer to restore after an unclean quit",
                    s.offer_recovery,
                    Some("After a crash, Sequence Studio offers the recovery copy the next time it starts."),
                );
                let feed = UpdateCheck::feed_url(d);
                p.check(
                    "updates",
                    "Updates",
                    "Check for a newer version at launch",
                    s.check_for_updates,
                    Some(if feed.is_empty() {
                        "Not set up in this build yet: nothing is contacted."
                    } else {
                        "Asks one address for the newest version number; nothing else is sent."
                    }),
                );
                if let (Some(row), Some(status)) = (c.app_menu.row(), c.app_menu.status()) {
                    p.rows.push(row);
                    p.helps.insert("appMenu".to_string(), status);
                }
                p.rows.push(Row::Caption("New items".to_string()));
                p.popup(
                    "textLength",
                    "New Text Length",
                    AppSettings::TEXT_DURATION_CHOICES.iter().map(|n| Self::seconds(*n)).collect(),
                    AppSettings::TEXT_DURATION_CHOICES.iter().position(|v| *v == s.default_text_seconds).unwrap_or(4),
                    196.0,
                    None,
                );
                let langs = Self::transcription_languages(&s.caption_language);
                p.popup(
                    "transcription",
                    "Transcription",
                    langs.iter().map(|l| Self::language_title(l)).collect(),
                    langs.iter().position(|l| *l == s.caption_language).unwrap_or(0),
                    196.0,
                    Some("The language spoken in your footage. A project can pick another language in the Captions panel."),
                );
                p.check(
                    "autoLanguage",
                    "Auto Language",
                    "Run again in the language the text turns out to be",
                    s.caption_auto_language,
                    Some("When a transcription clearly comes out in another language the list offers, it is transcribed once more in that language. Takes effect the next time a sequence opens."),
                );
                p.rows.push(Row::Caption("Experimental".to_string()));
                p.check(
                    "experimentalLabels",
                    "Labels",
                    "Show experimental labels",
                    x.experimental_labels,
                    Some("Features that are still being tested carry a flask mark. Turned off, the marks go away; the short note the first time you open such a feature still shows once."),
                );
            }
            Page::Playback => {
                p.popup(
                    "quality",
                    "Preview Quality",
                    QUALITIES.iter().map(|q| quality_title(*q).to_string()).collect(),
                    if s.preview_quality_auto {
                        0
                    } else {
                        QUALITIES.iter().position(|q| *q == s.default_quality).unwrap_or(1)
                    },
                    196.0,
                    Some("The monitors' playback resolution at launch; change it any time in the monitor. Auto picks 1/2 on Macs with 8 GB or less and lowers the resolution while memory runs low. Export always uses full quality."),
                );
                let ram = c.physical_memory_gb.to_string();
                let help = SQL10n::format(ShellPlatformText::frame_cache_help(Platform::current()), &[&ram]);
                p.popup(
                    "frameCache",
                    "Frame Cache",
                    c.frame_cache_titles.clone(),
                    c.frame_cache_values.iter().position(|v| *v == s.frame_cache_gb).unwrap_or(0),
                    196.0,
                    Some(&help),
                );
                p.check(
                    "background",
                    "Background Work",
                    "Make proxies while you edit",
                    s.background_work,
                    Some("Heavy clips get a lighter playback copy in the background. Turn off on a slow Mac to keep it quiet; it also pauses by itself when the Mac is hot or memory runs low."),
                );
                p.rows.push(Row::Caption("Play around".to_string()));
                p.popup(
                    "preroll",
                    "Preroll",
                    AppSettings::ROLL_CHOICES.iter().map(|n| Self::seconds(*n)).collect(),
                    AppSettings::ROLL_CHOICES.iter().position(|v| *v == s.preroll_seconds).unwrap_or(3),
                    180.0,
                    Some("Seconds played before the marked range (Shift+Space) or the playhead (Shift+K)."),
                );
                p.popup(
                    "postroll",
                    "Postroll",
                    AppSettings::ROLL_CHOICES.iter().map(|n| Self::seconds(*n)).collect(),
                    AppSettings::ROLL_CHOICES.iter().position(|v| *v == s.postroll_seconds).unwrap_or(2),
                    180.0,
                    Some("Seconds played after the marked range or the playhead."),
                );
                p.rows.push(Row::Caption("Feedback".to_string()));
                if let Some(devices) = &c.audio_outputs {
                    let entries = AudioOutputChoices::entries(devices, s.audio_output_uid.as_deref());
                    p.popup(
                        "audioOutput",
                        "Audio Output",
                        entries.iter().map(|e| e.title.clone()).collect(),
                        AudioOutputChoices::index(s.audio_output_uid.as_deref(), &entries),
                        260.0,
                        Some("Where both monitors play sound. System Default follows the Mac's output; a device that is not connected falls back to it."),
                    );
                }
                p.check(
                    "scrubbing",
                    "Audio Scrubbing",
                    "Play sound while dragging the playhead",
                    s.audio_scrubbing,
                    None,
                );
                p.check(
                    "dropIndicator",
                    "Dropped Frames",
                    "Show a dot when frames are dropped",
                    s.drop_indicator,
                    Some("A small dot in the Program monitor turns amber for two seconds when playback drops a frame. Hover it for the count of the last play."),
                );
            }
            Page::Editing => {
                // R4e/P2: two picture cards (Normal, Fast Cut) like Appearance, the kit's Choices row.
                p.popup(
                    "newSequence",
                    "New Sequences Start in",
                    vec!["Normal".to_string(), "Fast Cut".to_string()],
                    usize::from(s.new_sequence_edit_mode == sq_core_model::TimelineEditMode::Magnetic),
                    196.0,
                    Some("Normal keeps classic tracks and Delete leaves a gap (Shift+Delete closes it). Fast Cut closes gaps on the main track by itself and keeps clips above and below attached to their clip. You can switch any sequence later in the timeline header."),
                );
                p.choice_cards.insert("newSequence".to_string());
                p.rows.push(Row::Caption("Default transition length".to_string()));
                // The Mac `SQFormRow.numberRow`: a right-aligned 72 pt scrub field in `label` tint, unit and note after it.
                p.rows.push(Row::Number {
                    label: "Video Transition".to_string(),
                    field: NumberField {
                        id: "videoTransition".to_string(),
                        value: x.transitions.video_frames as f64,
                        range: 0.0..=10_000.0,
                        step: 1.0,
                        decimals: 0,
                        unit: "frames".to_string(),
                        default_value: Some(0.0),
                    },
                });
                p.rows.push(Row::Number {
                    label: "Audio Transition".to_string(),
                    field: NumberField {
                        id: "audioTransition".to_string(),
                        value: x.transitions.audio_seconds,
                        range: 0.05..=600.0,
                        step: 0.05,
                        decimals: 2,
                        unit: "seconds".to_string(),
                        default_value: Some(1.0),
                    },
                });
                p.label_tinted.extend(["videoTransition".to_string(), "audioTransition".to_string()]);
                // The kit: the zero rule sits under Video Transition, the shortcuts note under Audio Transition.
                p.helps.insert("videoTransition".to_string(), "0 means 1 second.".to_string());
                p.helps.insert("audioTransition".to_string(), "Default length of transitions placed with Command-D, Shift-Command-D and Shift-D. Existing transitions do not change.".to_string());
                if let Some(defaults) = &c.effect_defaults {
                    p.rows.push(Row::Caption("Your effect and transition defaults".to_string()));
                    // The Mac `EffectDefaultsSettingsView`: one list box per kind; the shared help sits under the last one.
                    for (n, g) in EffectDefaultsGroup::ALL.iter().enumerate() {
                        p.rows.push(Row::ListBox {
                            id: format!("default.{n}"),
                            label: g.title().to_string(),
                            lines: defaults.entries_in(*g).iter().map(EffectDefaultsEntry::title).collect(),
                            button: "Restore Factory".to_string(),
                            empty: EffectDefaultsGroup::EMPTY_GROUP_TEXT.to_string(),
                        });
                        if *g == EffectDefaultsGroup::AudioTransitions {
                            p.helps.insert(format!("default.{n}"), EffectDefaultsGroup::SETTINGS_HELP.to_string());
                        }
                    }
                }
            }
            Page::Audio => {
                p.check(
                    "deClick",
                    "De-Click",
                    "Fade clip edges to prevent clicks",
                    x.de_click,
                    Some("A 3 ms fade at the start and end of every audio clip, so hard cuts never pop. Playback and export."),
                );
                p.rows.push(Row::Caption("Ducking".to_string()));
                p.check(
                    "liveDuck",
                    "Live Ducking",
                    "Duck music under dialogue while mixing",
                    x.duck_amount.is_some(),
                    Some("Music-role tracks follow Dialogue-role tracks while mixing (playback and export). Off by default. A clip that also has baked Auto Duck keys ducks twice."),
                );
                p.check_fields.push(("liveDuck".to_string(), Self::duck_amount_field(x.duck_amount), 72.0));
                p.popup(
                    "duckPreset",
                    "Duck Preset",
                    Self::duck_preset_titles(),
                    Self::duck_preset_index(x),
                    196.0,
                    Some("Soft is a shallow duck with a slow return for voice-over. Hard is a deep, quick duck for fast speech. Change the amount or any timing value and it shows Custom."),
                );
                p.popup(
                    "duckTiming",
                    "Duck Timing",
                    DuckTimingChoices::titles().iter().map(|t| (*t).to_string()).collect(),
                    DuckTimingChoices::index(&x.duck_timing),
                    196.0,
                    Some("Lookahead starts the duck early, Attack and Recovery are the ramps down and back up, Hold keeps the duck after speech, Minimum pause is the shortest gap that lets the music come back. Classic is the original 300 ms fade each way."),
                );
                // `DuckTimingForm`: 0...max ms in 5 ms steps, double-click resets to 0; `SQFormRow.unitGrid` under the popup.
                let clamped = x.duck_timing.clamped();
                p.grids.push((
                    "duckTiming".to_string(),
                    TIMING_FIELDS
                        .iter()
                        .enumerate()
                        .map(|(i, (id, title, max))| GridCell {
                            title: (*title).to_string(),
                            field: NumberField {
                                id: format!("timing.{id}"),
                                value: timing_value(&clamped, i),
                                range: 0.0..=*max,
                                step: 5.0,
                                decimals: 0,
                                unit: String::new(),
                                default_value: Some(0.0),
                            },
                            unit: "ms".to_string(),
                        })
                        .collect(),
                ));
                p.rows.push(Row::Caption("Roles".to_string()));
                p.popup(
                    "crossfade",
                    "Crossfade",
                    CROSSFADE_KINDS.iter().map(|k| k.name().to_string()).collect(),
                    CROSSFADE_KINDS.iter().position(|k| *k == x.roles.crossfade_kind).unwrap_or(0),
                    196.0,
                    Some("The kind of crossfade the default audio transition places (Shift-Command-D)."),
                );
                // `roleOffsetFields` / `roleTransitionFields`: 0.05 steps, two decimals, the value in `label`, no unit; a grid per row.
                let standard = AudioRoleDefaults::standard();
                let role_grid = |p: &mut PageRows,
                                 id: &str,
                                 label: &str,
                                 range: std::ops::RangeInclusive<f64>,
                                 set: &dyn Fn(AudioTag) -> Option<f64>,
                                 base: &dyn Fn(AudioTag) -> f64,
                                 help: &str| {
                    p.rows.push(Row::Label { id: id.to_string(), label: label.to_string() });
                    p.helps.insert(id.to_string(), help.to_string());
                    let mut cells = Vec::new();
                    for tag in ROLES {
                        let fid = format!("{id}.{}", role_raw(tag));
                        let b = base(tag);
                        p.label_tinted.insert(fid.clone());
                        cells.push(GridCell {
                            title: tag.title().to_string(),
                            field: NumberField {
                                id: fid,
                                value: set(tag).unwrap_or(b),
                                range: range.clone(),
                                step: 0.05,
                                decimals: 2,
                                unit: String::new(),
                                default_value: Some(b),
                            },
                            unit: String::new(),
                        });
                    }
                    p.grids.push((id.to_string(), cells));
                };
                role_grid(
                    &mut p,
                    "offset",
                    "J / L Offset",
                    0.05..=10.0,
                    &|t| x.roles.split_offset_seconds(t),
                    &|t| standard.split_offset_seconds(t).unwrap_or(0.25),
                    "Seconds the audio edit moves for a J or L cut with the offset shortcut, by the role of the clip.",
                );
                role_grid(
                    &mut p,
                    "length",
                    "Crossfade Length",
                    0.05..=600.0,
                    &|t| x.roles.transition_seconds(t),
                    &|t| standard.transition_seconds(t).unwrap_or(1.0),
                    "Seconds a default audio transition gets on a clip with this role. Untagged clips use the Audio Transition length on the Editing page.",
                );
                p.rows.push(Row::Caption("Metering and fades".to_string()));
                p.popup(
                    "meterStyle",
                    "Meter Response",
                    MeterStyle::ALL.iter().map(|m| m.title().to_string()).collect(),
                    MeterStyle::ALL.iter().position(|m| *m == x.meter_style).unwrap_or(1),
                    196.0,
                    Some("How fast the level meters fall and how long the peak marker holds. Smooth is calm, Fast follows every peak."),
                );
                p.popup(
                    "fadeCurve",
                    "Fade Shape",
                    FadeCurve::ALL.iter().map(|m| m.title().to_string()).collect(),
                    FadeCurve::ALL.iter().position(|m| *m == x.fade_curve).unwrap_or(0),
                    196.0,
                    Some("The shape a new audio fade gets when you drag its handle. Existing fades keep theirs."),
                );
            }
            Page::Media => {
                let l = s.locations(d);
                p.popup(
                    "outside",
                    "Outside Files",
                    OUTSIDE_MODES.iter().map(|m| outside_title(*m).to_string()).collect(),
                    OUTSIDE_MODES.iter().position(|m| *m == x.media.outside).unwrap_or(0),
                    196.0,
                    Some("What happens to files dropped from outside the project folder. Files already inside the project folder are always used where they are. A project can override this in File > Media Management."),
                );
                p.check(
                    "watchFolder",
                    "Project Folder",
                    "Add new files in the project folder to the bin",
                    x.media.watch_folder,
                    Some("New files and folders appear in the bin, linked in place; removed files go offline."),
                );
                if c.card_import {
                    p.check(
                        "cardImport",
                        "Card Import",
                        "Open the import window when a card is connected",
                        x.card_import,
                        Some("You choose per import: copy the files into the Media folder next to your project, or use them directly from the card."),
                    );
                }
                p.rows.push(Row::Caption("Library".to_string()));
                p.check(
                    "libraryCopy",
                    "Library",
                    "Copy library items used in a sequence into the project",
                    x.media.copy_library_items,
                    Some("Sounds, music, video, images and LUTs are copied to Files/Library in the background, once per unique file."),
                );
                if let Some(folders) = &c.library_folders {
                    p.rows.push(Row::ListBox {
                        id: "libFolder".to_string(),
                        label: "Library Folders".to_string(),
                        lines: folders.iter().map(|f| f.name.clone()).collect(),
                        button: "Remove".to_string(),
                        empty: "No folders yet.".to_string(),
                    });
                    p.list_lines.insert(
                        "libFolder".to_string(),
                        folders
                            .iter()
                            .map(|f| ListLine {
                                icon: Some(SQIcon::Folder),
                                detail: f.path.clone(),
                                warning: f.offline.then(|| "unavailable".to_string()),
                            })
                            .collect(),
                    );
                    p.rows.push(Row::buttons("libFolderAdd", "", "", &["Add Folder…"]));
                    p.helps.insert("libFolder".to_string(), "Folders of sounds, music, graphics, video and LUTs. They appear in the Library panel of every project. Using an item in a sequence copies it into the project.".to_string());
                }
                p.rows.push(Row::Caption("Cache".to_string()));
                p.rows.push(Row::Buttons {
                    id: "cacheFolder".to_string(),
                    label: "Cache Folder".to_string(),
                    detail: StorageFolderChoice::short_path(&s.effective_cache_folder()),
                    titles: vec!["Choose…".to_string(), "Use Default".to_string()],
                    enabled: vec![true, s.cache_folder.is_some()],
                });
                p.helps.insert("cacheFolder".to_string(), "Proxies are stored in the Proxies folder inside it. A new folder applies at the next launch; proxies already made stay in the old folder (Delete Cache there is safe, they are rebuilt when needed).".to_string());
                p.popup(
                    "cacheCap",
                    "Cache Size",
                    AppSettings::CACHE_CAP_CHOICES.iter().map(|n| format!("{n} GB")).collect(),
                    AppSettings::CACHE_CAP_CHOICES.iter().position(|v| *v == s.cache_cap_gb).unwrap_or(1),
                    120.0,
                    Some("Most disk the proxy cache may use. The least recently used proxies go first, never one a monitor is playing."),
                );
                p.check(
                    "proxyExport",
                    "Export",
                    "Use proxies when exporting",
                    s.use_proxies_for_export,
                    Some("Renders from the ready proxies instead of the original files: much faster, lower quality. For drafts and review copies only. Clips without a ready proxy use the original, and smart-render copies stay original. Off by default."),
                );
                if let Some(used) = &c.cache_used {
                    p.rows.push(Row::buttons("cacheClear", "", used, &["Delete Cache"]));
                    p.helps.insert(
                        "cacheClear".to_string(),
                        "Clearing the cache is safe: files are rebuilt when needed.".to_string(),
                    );
                }
                p.rows.push(Row::Caption("Folders".to_string()));
                p.rows.push(Row::Buttons {
                    id: "scratchFolder".to_string(),
                    label: "Scratch Folder".to_string(),
                    detail: StorageFolderChoice::short_path(&l.scratch_root()),
                    titles: vec!["Choose…".to_string(), "Use Default".to_string()],
                    enabled: vec![true, l.scratch_folder.is_some()],
                });
                p.rows.push(Row::Buttons {
                    id: "projectsFolder".to_string(),
                    label: "Projects Folder".to_string(),
                    detail: StorageFolderChoice::short_path(&l.projects_root()),
                    titles: vec!["Choose…".to_string(), "Use Default".to_string()],
                    enabled: vec![true, l.projects_folder.is_some()],
                });
                p.helps.insert("scratchFolder".to_string(), "Temporary working files such as pasted images of an unsaved project. Defaults to the Scratch folder inside the cache folder. Applies at once.".to_string());
                p.helps.insert(
                    "projectsFolder".to_string(),
                    "Where new projects are created and suggested. Defaults to ~/Movies/Sequence Studio.".to_string(),
                );
                if !folder_note.is_empty() {
                    p.rows.push(Row::Text(folder_note.to_string()));
                }
            }
            Page::Shortcuts => {}
            Page::Advanced => {
                if let Some((on, state)) = &c.edit_api {
                    p.check(
                        "api",
                        "Edit API",
                        "Allow local tools to edit the open project",
                        *on,
                        Some(ShellPlatformText::edit_api_help()),
                    );
                    p.statuses.insert("api".to_string(), Self::api_status(state));
                }
            }
        }
        p
    }

    /// Applies the `AppSettings` rows of `f`.
    pub fn apply_settings(f: &dyn DialogForm, s: &mut AppSettings, c: &PreferencesHost) {
        fn pick<T: Clone>(f: &dyn DialogForm, id: &str, list: &[T]) -> Option<T> {
            f.index(id).and_then(|i| usize::try_from(i).ok()).and_then(|i| list.get(i)).cloned()
        }
        if let Some(v) = pick(f, "autosave", &AppSettings::AUTOSAVE_CHOICES) {
            s.autosave_interval = v;
        }
        if let Some(v) = f.bool("recovery") {
            s.offer_recovery = v;
        }
        if let Some(v) = f.bool("updates") {
            s.check_for_updates = v;
        }
        if let Some(v) = pick(f, "textLength", &AppSettings::TEXT_DURATION_CHOICES) {
            s.default_text_seconds = v;
        }
        if let Some(v) = f.bool("autoLanguage") {
            s.caption_auto_language = v;
        }
        if let Some(v) = pick(f, "transcription", &Self::transcription_languages(&s.caption_language)) {
            s.caption_language = v;
        }
        if let Some(q) = pick(f, "quality", &QUALITIES) {
            s.preview_quality_auto = q == MonitorQuality::Auto;
            if q != MonitorQuality::Auto {
                s.default_quality = q;
            }
        }
        if let Some(v) = f.bool("background") {
            s.background_work = v;
        }
        if let Some(v) = pick(f, "frameCache", &c.frame_cache_values) {
            s.frame_cache_gb = v;
        }
        if let Some(devices) = &c.audio_outputs {
            let entries = AudioOutputChoices::entries(devices, s.audio_output_uid.as_deref());
            if let Some(e) = pick(f, "audioOutput", &entries) {
                s.audio_output_uid = e.uid;
            }
        }
        if let Some(v) = pick(f, "preroll", &AppSettings::ROLL_CHOICES) {
            s.preroll_seconds = v;
        }
        if let Some(v) = pick(f, "postroll", &AppSettings::ROLL_CHOICES) {
            s.postroll_seconds = v;
        }
        if let Some(v) = f.bool("scrubbing") {
            s.audio_scrubbing = v;
        }
        if let Some(v) = f.index("newSequence") {
            s.new_sequence_edit_mode = if v == 1 {
                sq_core_model::TimelineEditMode::Magnetic
            } else {
                sq_core_model::TimelineEditMode::Normal
            };
        }
        if let Some(v) = f.bool("dropIndicator") {
            s.drop_indicator = v;
        }
        if let Some(v) = f.bool("proxyExport") {
            s.use_proxies_for_export = v;
        }
        if let Some(v) = pick(f, "cacheCap", &AppSettings::CACHE_CAP_CHOICES) {
            s.cache_cap_gb = v;
        }
    }

    /// The Mac `uiLanguageChanged`, `transitionDefaultsChanged` and `roleDefaultsChanged`: same ranges, invalid text ignored.
    pub fn apply_extras(f: &dyn DialogForm, x: &mut Extras) {
        let at = |id: &str, len: usize| f.index(id).and_then(|i| usize::try_from(i).ok()).filter(|i| *i < len);
        let langs = Self::ui_languages();
        if let Some(i) = at("uiLanguage", langs.len()) {
            x.ui_language = langs[i].clone();
        }
        if let Some(v) = f.number("videoTransition").filter(|v| v.is_finite()) {
            let frames = v.round() as i64;
            if (0..=10_000).contains(&frames) {
                x.transitions.video_frames = frames;
            }
        }
        if let Some(v) = f.number("audioTransition") {
            let seconds = (v * 100.0).round() / 100.0;
            if seconds.is_finite() && seconds > 0.0 && seconds <= 600.0 {
                x.transitions.audio_seconds = seconds;
            }
        }
        if let Some(i) = at("crossfade", CROSSFADE_KINDS.len()) {
            x.roles.crossfade_kind = CROSSFADE_KINDS[i];
        }
        if let Some(i) = at("uiScale", interface_scale::STEPS.len()) {
            x.ui_scale = interface_scale::STEPS[i];
        }
        if let Some(i) = f.index("appearance") {
            x.appearance.mode = usize::try_from(i)
                .ok()
                .and_then(|i| AppearanceMode::ALL.get(i).copied())
                .unwrap_or(AppearanceMode::Dark);
        }
        if let Some(v) = f.number("appearanceBackground").filter(|v| v.is_finite()) {
            x.appearance.set_background(v.round() as i64);
        }
        if let Some(v) = f.number("appearanceContrast").filter(|v| v.is_finite()) {
            x.appearance.set_contrast(v.round() as i64);
        }
        if let Some(v) = f.bool("deClick") {
            x.de_click = v;
        }
        // `liveDuckChanged`: the typed amount, clamped and rounded to 0.5 dB.
        if let Some(on) = f.bool("liveDuck") {
            x.duck_amount = on.then(|| DuckPreset::clamped_amount(f.number("duckAmount").unwrap_or(12.0)));
        }
        Self::apply_ducking(f, x);
        if let Some(i) = at("outside", OUTSIDE_MODES.len()) {
            x.media.outside = OUTSIDE_MODES[i];
        }
        if let Some(v) = f.bool("watchFolder") {
            x.media.watch_folder = v;
        }
        if let Some(v) = f.bool("libraryCopy") {
            x.media.copy_library_items = v;
        }
        if let Some(v) = f.bool("experimentalLabels") {
            x.experimental_labels = v;
        }
        if let Some(v) = f.bool("cardImport") {
            x.card_import = v;
        }
        if let Some(i) = at("meterStyle", MeterStyle::ALL.len()) {
            x.meter_style = MeterStyle::ALL[i];
        }
        if let Some(i) = at("fadeCurve", FadeCurve::ALL.len()) {
            x.fade_curve = FadeCurve::ALL[i];
        }
        for r in ROLES {
            if let Some(v) = f.number(&format!("offset.{}", role_raw(r))).filter(|v| v.is_finite() && *v > 0.0) {
                x.roles.set_split_offset_seconds(r, (v * 100.0).round() / 100.0);
            }
            if let Some(v) = f.number(&format!("length.{}", role_raw(r))).filter(|v| v.is_finite() && *v > 0.0) {
                x.roles.set_transition_seconds(r, (v * 100.0).round() / 100.0);
            }
        }
    }

    /// The Mac `liveDuckPresetPicked` and `DuckTimingForm`: a picked Duck Preset sets the amount and the timing (and turns
    /// Live Ducking on); a picked Duck Timing sets the five fields; otherwise the fields are read. `sync` then shows the
    /// result in the form (the preset pop-ups follow the values: Custom when none matches).
    fn apply_ducking(f: &dyn DialogForm, x: &mut Extras) {
        let Some(picked_timing) = f.index("duckTiming") else { return };
        let picked_preset = f.index("duckPreset").unwrap_or(0);
        let presets = DuckTimingChoices::presets();
        let preset_at = usize::try_from(picked_preset - 1).ok().and_then(|i| DuckPreset::all().get(i).cloned());
        let timing_at = usize::try_from(picked_timing).ok().and_then(|i| presets.get(i));
        if picked_preset != Self::duck_preset_index(x) as i64
            && let Some(p) = preset_at
        {
            x.duck_amount = Some(p.amount_db);
            x.duck_timing = p.timing;
        } else if picked_timing != DuckTimingChoices::index(&x.duck_timing) as i64
            && let Some(t) = timing_at
        {
            x.duck_timing = t.timing.clone();
        } else {
            let mut t = x.duck_timing.clone();
            for (i, (id, _, max)) in TIMING_FIELDS.iter().enumerate() {
                if let Some(v) = f.number(&format!("timing.{id}")).filter(|v| v.is_finite()) {
                    set_timing_value(&mut t, i, v.round().max(0.0).min(*max));
                }
            }
            x.duck_timing = t.clamped();
        }
    }

    /// Shows the values `x` holds in the derived rows of `f` (the Mac `syncDuckPresetPopup`).
    pub fn sync(f: &mut dyn DialogForm, x: &Extras) {
        if f.index("duckTiming").is_none() {
            return;
        }
        if let Some(on) = f.bool("liveDuck")
            && on != x.duck_amount.is_some()
        {
            f.set_value("liveDuck", FormValue::Bool(x.duck_amount.is_some()));
        }
        if let Some(db) = x.duck_amount {
            f.set_value("duckAmount", FormValue::Number(db));
        }
        f.set_value("duckPreset", FormValue::Index(Self::duck_preset_index(x) as i64));
        f.set_value("duckTiming", FormValue::Index(DuckTimingChoices::index(&x.duck_timing) as i64));
        let clamped = x.duck_timing.clamped();
        for (i, (id, _, _)) in TIMING_FIELDS.iter().enumerate() {
            f.set_value(&format!("timing.{id}"), FormValue::Number(timing_value(&clamped, i)));
        }
    }

    /// What a button of a `.buttons` or list row asks for.
    pub(crate) fn button_action(
        id: &str,
        button: usize,
        effect_defaults: Option<&EffectDefaults>,
    ) -> Option<ButtonAction> {
        if let Some(folder) = Folder::from_id(id) {
            return Some(if button == 0 {
                ButtonAction::ChooseFolder(folder)
            } else {
                ButtonAction::UseDefault(folder)
            });
        }
        match id {
            "libFolderAdd" => return Some(ButtonAction::AddLibraryFolder),
            "cacheClear" => return Some(ButtonAction::ClearCache),
            "libFolder" => return Some(ButtonAction::RemoveLibraryFolder(button)),
            _ => {}
        }
        let n: usize = id.strip_prefix("default.")?.parse().ok()?;
        let group = EffectDefaultsGroup::ALL.get(n)?;
        let entry = effect_defaults?.entries_in(*group).get(button)?.clone();
        Some(ButtonAction::RestoreFactory(entry))
    }

    /// Sets (`url`) or resets (`None`) a storage folder; the note to show under the folder rows.
    pub(crate) fn set_folder(
        folder: Folder,
        url: Option<&Path>,
        s: &mut AppSettings,
        d: &mut dyn UiDefaults,
        mover: sq_editor_session::ProxyMove<'_>,
    ) -> String {
        match folder {
            Folder::Cache => StorageFolderChoice::set_cache_folder(url, s, d, mover),
            Folder::Scratch => StorageFolderChoice::set_folder(true, url, d).unwrap_or_default(),
            Folder::Projects => StorageFolderChoice::set_folder(false, url, d).unwrap_or_default(),
        }
    }
}

/// One page: rows plus the Mac help lines, check row labels, fixed control widths, grids, check fields and status lines by
/// row id.
#[derive(Default)]
struct PageRows {
    rows: Vec<Row>,
    helps: BTreeMap<String, String>,
    check_labels: BTreeMap<String, String>,
    widths: BTreeMap<String, f64>,
    grids: Vec<(String, Vec<GridCell>)>,
    check_fields: Vec<(String, NumberField, f64)>,
    label_tinted: BTreeSet<String>,
    statuses: BTreeMap<String, Status>,
    list_lines: BTreeMap<String, Vec<ListLine>>,
    choice_cards: BTreeSet<String>,
}

impl PageRows {
    /// `SQFormRow.row(label, fixed(popup, w), help:)`.
    fn popup(&mut self, id: &str, label: &str, options: Vec<String>, sel: usize, width: f64, help: Option<&str>) {
        self.rows.push(Row::Popup { id: id.to_string(), label: label.to_string(), options, selected: sel as i64 });
        self.widths.insert(id.to_string(), width);
        if let Some(h) = help {
            self.helps.insert(id.to_string(), h.to_string());
        }
    }

    /// `SQFormRow.row(label, checkItem(box, title), help:)`.
    fn check(&mut self, id: &str, label: &str, title: &str, on: bool, help: Option<&str>) {
        self.rows.push(Row::check(id, title, on));
        self.check_labels.insert(id.to_string(), label.to_string());
        if let Some(h) = help {
            self.helps.insert(id.to_string(), h.to_string());
        }
    }
}

// MARK: The dialog

/// The Preferences window's size: an L modal (900 x 640) that keeps its size on every page.
const WIDTH_L: f64 = 900.0;
const HEIGHT_L: f64 = 640.0;

/// The Settings window's height before the window's margins cut it. Shot-only: `SQ_SHOT_SETTINGS_HEIGHT=<pt>` makes it as
/// tall as a design frame for `--ui-shot`.
// shortcut: the env var is read on every layout; remove it with the page shortcut (`SQ_SHOT_SETTINGS_PAGE`) when the design shots are done.
pub(crate) fn settings_height() -> f64 {
    std::env::var("SQ_SHOT_SETTINGS_HEIGHT").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(HEIGHT_L)
}

/// Where the Settings window sits in `window`: the one card of every page, the Shortcuts page included, so the sidebar never
/// moves when a page is picked. Same arithmetic as `ShellDialog::layout` (a margin around the card, centered, a half point
/// floors), because the pages are two kinds of window (a dialog and the Shortcuts editor) sharing one frame.
pub(crate) fn settings_card(window: sq_uikit::controls_grid::CGRect) -> sq_uikit::controls_grid::CGRect {
    let margin = crate::shell_dialog::m::WINDOW_MARGIN;
    let w = WIDTH_L.min((window.width - 2.0 * margin).max(0.0));
    let h = settings_height().min((window.height - 2.0 * margin).max(0.0));
    sq_uikit::controls_grid::CGRect::new((window.mid_x() - w / 2.0).round(), (window.mid_y() - h / 2.0).floor(), w, h)
}

fn folder_size(url: &Path) -> i64 {
    let Ok(entries) = std::fs::read_dir(url) else { return 0 };
    entries
        .flatten()
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => folder_size(&e.path()),
            Ok(m) => i64::try_from(m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

impl ShellHost {
    /// Preferences (Ctrl+,): every change is saved at once, as in the Mac window; the sidebar swaps the page's rows.
    /// Choose… / Use Default and Restore Factory act at once and rebuild the page.
    pub async fn show_preferences<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        Self::show_preferences_at(h, None, false).await;
    }

    /// Preferences on `page` (the Shortcuts editor's sidebar sends the page it was asked for); `search` puts the keyboard in
    /// the search field.
    pub async fn show_preferences_at<R: ShellRoot + ?Sized>(h: UiRef<R>, page: Option<Page>, search: bool) {
        let _ = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            shell.preferences.search.clear();
            shell.preferences.focus_search = search;
            shell.hide_shortcuts(); // one modal at a time
        });
        // shortcut: SQ_SHOT_SETTINGS_PAGE=<index> opens a given page for `--ui-shot` (shots cannot click inside the dialog); remove once shots take clicks after keys.
        let start = Self::start_page(std::env::var("SQ_SHOT_SETTINGS_PAGE").ok().as_deref(), page);
        // Reset to Defaults (ghost button, footer left, art.html Settings) keeps the window open (`present_preferences`).
        // Shortcuts is no form page: the editor takes over the window, as when the sidebar row is clicked.
        let direct = start == Page::Shortcuts;
        let exit = if direct { Some(PrefsExit::Shortcuts) } else { Self::present_preferences(&h, start).await };
        if let Some(PrefsExit::AddAppMenu | PrefsExit::RemoveAppMenu) = exit {
            let _ = h.with(|r| {
                let shell = &mut *r.shell_parts().shell;
                shell.close_dialog(SQDialogResponse::FIRST);
                if matches!(exit, Some(PrefsExit::AddAppMenu)) {
                    shell.emit(ShellEvent::AppMenu(AppMenuRequest::Add));
                } else {
                    shell.start_flow(ShellFlow::AppMenuRemove);
                }
            });
        }
        if let Some(PrefsExit::Shortcuts) = exit {
            let _ = h.with(|r| {
                let shell = &mut *r.shell_parts().shell;
                shell.preferences.search.clear();
                // The Settings dialog was never answered: close it, or it stays modal over the editor (none is up when the
                // page was asked for directly).
                if !direct {
                    shell.close_dialog(SQDialogResponse::FIRST);
                }
                shell.show_shortcuts_page();
            });
        }
    }

    /// The page Settings opens on: the shot pose's index wins, then the asked page, then General.
    fn start_page(pose: Option<&str>, asked: Option<Page>) -> Page {
        pose.and_then(|v| v.parse::<i64>().ok()).and_then(Page::from_index).or(asked).unwrap_or(Page::General)
    }

    /// Index of the "Reset to Defaults" button in the Settings dialog (Done is 0).
    const RESET_BUTTON: usize = 1;

    /// Whether Reset to Defaults has anything to restore: a setting or extra that is not at its factory value (the language
    /// stays, as in [`Self::reset_preferences_to_defaults`]). A button that would change nothing looks off and takes no click.
    fn reset_has_work(s: &AppSettings, x: &Extras) -> bool {
        *s != Self::factory_settings(s) || *x != (Extras { ui_language: x.ui_language.clone(), ..Extras::default() })
    }

    /// Turns the Reset to Defaults button of the open Settings dialog on or off by [`Self::reset_has_work`].
    fn sync_reset_button(&mut self, s: &AppSettings, x: &Extras) {
        let on = Self::reset_has_work(s, x);
        if let Some(d) = self.dialog_mut() {
            d.button_enabled = Some(Box::new(move |i| i != Self::RESET_BUTTON || on));
        }
    }

    /// The factory values of every setting. `onboarding_seen` is the first-run state, not a setting: Reset keeps it, or the
    /// Welcome tour would return (and swallow Ctrl+,) after a reset.
    fn factory_settings(current: &AppSettings) -> AppSettings {
        AppSettings { onboarding_seen: current.onboarding_seen, ..AppSettings::standard() }
    }

    /// Back to the factory values (the language and the first-run state stay); tells the app.
    fn reset_preferences_to_defaults(shell: &mut ShellHost) {
        let factory = Self::factory_settings(&AppSettings::load(&*shell.defaults));
        factory.save(&mut *shell.defaults);
        let x = Extras { ui_language: Extras::load(&*shell.defaults).ui_language, ..Extras::default() };
        x.save(&mut *shell.defaults);
        shell.emit(ShellEvent::SettingsChanged(Box::new(factory)));
    }

    /// The Advanced page exists when the host runs an Edit API: its switch and run state as they are now.
    pub(crate) fn sync_edit_api(&mut self) {
        self.preferences.edit_api = self.flow_env.edit_api.as_ref().map(|a| ((a.is_enabled)(), (a.state)()));
    }

    /// The host's Edit API changed its run state (a server that starts or fails after the switch): an open Advanced page
    /// shows the new line at once (Swift `editAPI.stateChanged`).
    pub fn edit_api_state_changed(&mut self) {
        self.sync_edit_api();
        let Some((_, state)) = self.preferences.edit_api.clone() else { return };
        let status = ShellPreferences::api_status(&state);
        let shown = self.dialog_mut().and_then(|d| d.form.as_mut()).is_some_and(|f| f.replace_status("api", status));
        if shown {
            self.invalidate_dialog_layout(true);
        }
    }

    /// Builds the form of `page` into the open dialog (`install`).
    fn install_preferences_page(&mut self, page: Page, s: &AppSettings, x: &Extras, note: &str) {
        let sidebar_focused = self.dialog().and_then(|d| d.form.as_ref()).is_some_and(|f| f.sidebar_focused());
        // The field being typed in goes over to the new page whole: the page is rebuilt for every changed query, and a fresh
        // field would open with everything selected and lose the next characters.
        let typing = self.dialog_mut().and_then(|d| d.form.as_mut()).and_then(|f| f.take_search_editing());
        if let Some(t) = &typing {
            self.preferences.search = t.editor().map_or_else(|| t.text.clone(), |e| e.string());
        }
        let query = self.preferences.search.trim().to_string();
        let mut f = if query.is_empty() {
            let mut f = ShellPreferences::form(page, s, x, &self.preferences, &*self.defaults, note);
            f.page_header = Some((page.title().to_string(), page.subtitle().to_string()));
            f
        } else {
            let mut f = ShellPreferences::search_form(&query, s, x, &self.preferences, &*self.defaults);
            f.page_header = Some(("Results".to_string(), SQL10n::format("Settings matching “%@”.", &[&query])));
            f
        };
        f.set_sidebar_focused(sidebar_focused); // a page picked by key keeps the keyboard on the list
        f.enable_search(&self.preferences.search);
        if let Some(t) = typing {
            f.keep_search(t);
            self.preferences.focus_search = false;
        } else if !query.is_empty() || std::mem::take(&mut self.preferences.focus_search) {
            f.focus_search();
        }
        let (changed, counts) = ShellPreferences::marks(&f, s, x, &self.preferences, &*self.defaults);
        f.set_changed(changed);
        let total: usize = counts.iter().sum();
        f.set_sidebar_counts(counts);
        if let Some(d) = self.dialog_mut() {
            d.footer_hint = Some(ShellPreferences::footer_hint(total));
            d.form = Some(Box::new(f));
        }
        self.sync_reset_button(s, x);
        self.invalidate_dialog_layout(true);
    }

    /// One Preferences window; the page it was left on when Reset to Defaults was pressed, else `None`.
    async fn present_preferences<R: ShellRoot + ?Sized>(h: &UiRef<R>, start: Page) -> Option<PrefsExit> {
        let (mut settings, mut extras, mut note) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            shell.sync_edit_api();
            (AppSettings::load(&*shell.defaults), Extras::load(&*shell.defaults), String::new())
        })?;
        let mut page = start;
        let mut d = ShellDialog::new("Settings", ""); // the Mac `SettingsWindow` title
        d.width = WIDTH_L;
        d.card_height = Some(settings_height());
        d.headerless = true; // R4b: the page title sits inside the page, the sidebar starts at the window's top
        d.add_button("Done", SQDialogRole::Default, false);
        d.add_button("Reset to Defaults", SQDialogRole::Normal, true);
        d.button_widths.insert(0, 70.0); // kit: Done is 70 wide
        d.keep_open = vec![1]; // Reset acts in place: the window and its page stay
        // Settings has no Cancel button: Escape is Done (the change is saved at once), never Reset.
        d.escape_response = Some(SQDialogResponse::FIRST);
        d.footer_hint = Some("Changes apply right away.".to_string());
        let mut live = Self::present_live(h, d)?;
        h.with(|r| r.shell_parts().shell.install_preferences_page(page, &settings, &extras, &note))?;
        loop {
            match live.next(h).await? {
                Live::Answered(_) => {
                    return Some(PrefsExit::Done);
                }
                Live::Changed(changes) => {
                    for (id, v) in changes {
                        if id == ShellDialog::BUTTON_CHANGE {
                            h.with(|r| {
                                let shell = &mut *r.shell_parts().shell;
                                Self::reset_preferences_to_defaults(shell);
                                settings = AppSettings::load(&*shell.defaults);
                                extras = Extras::load(&*shell.defaults);
                                note.clear();
                                shell.install_preferences_page(page, &settings, &extras, &note);
                            })?;
                            continue;
                        }
                        if id == "page" {
                            if let FormValue::Index(i) = v
                                && let Some(p) = Page::from_index(i)
                            {
                                if p == Page::Shortcuts {
                                    return Some(PrefsExit::Shortcuts);
                                }
                                page = p;
                                note.clear();
                                h.with(|r| r.shell_parts().shell.preferences.search.clear())?;
                                h.with(|r| {
                                    r.shell_parts().shell.install_preferences_page(page, &settings, &extras, &note)
                                })?;
                            }
                            continue;
                        }
                        // R4e: the sidebar search; the page shows the matches while there is a query.
                        if id == "search" {
                            if let FormValue::Text(q) = v {
                                h.with(|r| {
                                    let shell = &mut *r.shell_parts().shell;
                                    shell.preferences.search = q;
                                    shell.install_preferences_page(page, &settings, &extras, &note);
                                })?;
                            }
                            continue;
                        }
                        // R4e: a reset arrow goes back to the factory value of its row, then the change is saved as any other.
                        let (id, v) = if let Some(real) = id.strip_prefix("reset:") {
                            let real = real.to_string();
                            let back = h.with(|r| {
                                let shell = &mut *r.shell_parts().shell;
                                let c = shell.preferences.clone();
                                let owner = ShellPreferences::page_of(&real, &settings, &extras, &c, &*shell.defaults)
                                    .unwrap_or(page);
                                let factory =
                                    ShellPreferences::factory_value(owner, &real, &extras, &c, &*shell.defaults);
                                if let (Some(v), Some(form)) =
                                    (factory.clone(), shell.dialog_mut().and_then(|d| d.form.as_mut()))
                                {
                                    form.set_value(&real, v);
                                }
                                factory
                            })?;
                            (real, back.unwrap_or(v))
                        } else {
                            (id, v)
                        };
                        // Advanced: the Edit API switch (`apiChanged`) and Copy address (`copyAPIAddress`), not stored here.
                        if id == "api" {
                            if let FormValue::Bool(on) = v {
                                h.with(|r| {
                                    let shell = &mut *r.shell_parts().shell;
                                    // The Mac `editAPI?.setEnabled(on)`: the host stores the switch and starts or stops the server.
                                    if let Some(api) = shell.flow_env.edit_api.as_ref() {
                                        (api.set_enabled)(on);
                                    }
                                    shell.sync_edit_api();
                                    shell.install_preferences_page(page, &settings, &extras, &note);
                                })?;
                            }
                            continue;
                        }
                        if id == "appMenu" {
                            let added = h.with(|r| {
                                matches!(r.shell_parts().shell.preferences.app_menu, AppMenuRow::Added { .. })
                            })?;
                            return Some(if added { PrefsExit::RemoveAppMenu } else { PrefsExit::AddAppMenu });
                        }
                        if id == "api.status" {
                            h.with(|r| {
                                let shell = &mut *r.shell_parts().shell;
                                if let Some(port) =
                                    shell.preferences.edit_api.as_ref().and_then(|(_, s)| s.copyable_port)
                                {
                                    shell.emit(ShellEvent::CopyText(format!("127.0.0.1:{port}")));
                                }
                            })?;
                            continue;
                        }
                        if let FormValue::Index(b) = v
                            && let Some(act) = h.with(|r| {
                                let c = &r.shell_parts().shell.preferences;
                                ShellPreferences::button_action(
                                    &id,
                                    usize::try_from(b).unwrap_or(usize::MAX),
                                    c.effect_defaults.as_ref(),
                                )
                            })?
                        {
                            Self::preferences_button(h, act, &mut settings, &mut note).await?;
                            h.with(|r| {
                                r.shell_parts().shell.install_preferences_page(page, &settings, &extras, &note)
                            })?;
                            continue;
                        }
                        h.with(|r| {
                            let shell = &mut *r.shell_parts().shell;
                            let c = shell.preferences.clone();
                            let Some(mut form) = shell.dialog_mut().and_then(|d| d.form.take()) else { return };
                            ShellPreferences::apply_settings(&*form, &mut settings, &c);
                            settings.save(&mut *shell.defaults);
                            ShellPreferences::apply_extras(&*form, &mut extras);
                            extras.save(&mut *shell.defaults);
                            ShellPreferences::sync(&mut *form, &extras);
                            let (changed, counts) =
                                ShellPreferences::marks(&*form, &settings, &extras, &c, &*shell.defaults);
                            form.set_marks(changed, counts);
                            if let Some(d) = shell.dialog_mut() {
                                d.form = Some(form);
                            }
                            shell.sync_reset_button(&settings, &extras);
                            shell.invalidate_dialog_layout(false); // a changed value keeps the page where it is
                            shell.emit(ShellEvent::SettingsChanged(Box::new(settings.clone())));
                        })?;
                    }
                }
            }
        }
    }

    /// A button of a Preferences row: the folder chooser first where there is one, then the change. `None` when the root is
    /// gone.
    async fn preferences_button<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        act: ButtonAction,
        settings: &mut AppSettings,
        note: &mut String,
    ) -> Option<()> {
        let url: Option<PathBuf> = match act {
            ButtonAction::ChooseFolder(_) => {
                h.with(|r| r.shell_parts().files.choose_folder(&SQL10n::string("Choose")))?.await?.into()
            }
            ButtonAction::AddLibraryFolder => {
                h.with(|r| r.shell_parts().files.choose_folder(&SQL10n::string("Add")))?.await?.into()
            }
            _ => None,
        };
        if matches!(act, ButtonAction::ChooseFolder(_) | ButtonAction::AddLibraryFolder) && url.is_none() {
            return Some(());
        }
        h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            match act {
                ButtonAction::RemoveLibraryFolder(i) => {
                    let id = shell.preferences.library_folders.as_ref().and_then(|l| l.get(i)).map(|f| f.id.clone());
                    if let Some(id) = id {
                        shell.emit(ShellEvent::RemoveLibraryFolder(id));
                        ShellPreferences::show_folder_change(&mut shell.preferences, act, None);
                    }
                }
                ButtonAction::AddLibraryFolder => {
                    if let Some(url) = url {
                        ShellPreferences::show_folder_change(&mut shell.preferences, act, Some(&url));
                        shell.emit(ShellEvent::AddLibraryFolder(url));
                    }
                }
                ButtonAction::ClearCache => {
                    shell.emit(ShellEvent::ClearCache);
                    shell.preferences.cache_used =
                        shell.preferences.cache_used.as_ref().map(|_| "Calculating…".to_string());
                }
                ButtonAction::ChooseFolder(folder) | ButtonAction::UseDefault(folder) => {
                    // The proxies are copied by the app (`ShellEvent::MoveProxies`); a platform without one skips the copy.
                    let pair = std::cell::RefCell::new(None);
                    let record =
                        |old: &Path, new: &Path| *pair.borrow_mut() = Some((old.to_path_buf(), new.to_path_buf()));
                    *note = ShellPreferences::set_folder(
                        folder,
                        url.as_deref(),
                        settings,
                        &mut *shell.defaults,
                        sq_editor_session::ProxyMove::Background(&record),
                    );
                    if folder == Folder::Projects {
                        shell.new_project_location = None;
                    }
                    if let Some((from, to)) = pair.into_inner() {
                        shell.emit(ShellEvent::MoveProxies { from, to });
                    }
                    shell.emit(ShellEvent::SettingsChanged(Box::new(settings.clone())));
                }
                ButtonAction::RestoreFactory(entry) => {
                    if let Some(defaults) = shell.preferences.effect_defaults.as_mut() {
                        defaults.remove_entry(&entry);
                    }
                    shell.emit(ShellEvent::RestoreEffectDefault(entry));
                }
            }
        })
    }

    /// The size of the folders the cache line adds up (`ShellPreferences.folderSize`), for the app to call off the UI thread.
    pub fn cache_folder_size(url: &Path) -> i64 {
        folder_size(url)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn live_ducking_resolves_to_the_project_setting_else_preferences() {
        use sq_core_model::ProjectLiveDucking;
        let shell = crate::test_support::shell();
        assert_eq!(shell.resolved_live_ducking(None), None, "off in Preferences");
        let own = ProjectLiveDucking { is_on: true, amount_db: 12.0, timing: None };
        assert_eq!(shell.resolved_live_ducking(Some(&own)).map(|d| d.amount_db), Some(12.0));
        let off = ProjectLiveDucking { is_on: false, amount_db: 12.0, timing: None };
        assert_eq!(shell.resolved_live_ducking(Some(&off)), None, "the project switched it off");
    }

    use super::*;
    use crate::ShellDefaults;
    use crate::shell_form::StatusTone;
    use crate::shell_live::test_rig::{answer_swept, type_into};
    use crate::tests::Rig;
    use sq_editor_session::StorageLocations;

    fn form(page: Page, s: &AppSettings, x: &Extras, c: &PreferencesHost, d: &ShellDefaults) -> ShellForm {
        ShellPreferences::form(page, s, x, c, d, "")
    }

    fn captions(f: &ShellForm) -> Vec<String> {
        f.rows().iter().filter_map(|r| if let Row::Caption(t) = r { Some(t.clone()) } else { None }).collect()
    }

    fn button_ids(f: &ShellForm) -> Vec<String> {
        f.rows().iter().filter_map(|r| if let Row::Buttons { id, .. } = r { Some(id.clone()) } else { None }).collect()
    }

    /// Break-UI pass 3: the 900 wide Settings sheet and the other sheets stay inside a 640x400 window, and the Done
    /// button (and every other footer button) is inside the window.
    #[test]
    fn settings_and_other_sheets_fit_a_640_by_400_window() {
        let window = sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 640.0, 400.0);
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let mut settings = ShellDialog::new("Settings", "");
        settings.width = WIDTH_L;
        settings.card_height = Some(HEIGHT_L);
        settings.headerless = true;
        settings.add_button("Done", SQDialogRole::Default, false);
        settings.add_button("Reset to Defaults", SQDialogRole::Normal, true);
        settings.button_widths.insert(0, 70.0);
        settings.form = Some(Box::new(form(Page::General, &s, &x, &c, &d)));
        let shell = crate::test_support::shell();
        let mut about = shell.about_dialog(crate::shell_about::AboutPage::About);
        let mut ack = shell.about_dialog(crate::shell_about::AboutPage::Acknowledgments);
        let mut wide = ShellDialog::new("Export", "");
        wide.width = WIDTH_L;
        wide.add_button("Export", SQDialogRole::Default, false);
        for (name, dialog) in
            [("settings", &mut settings), ("about", &mut about), ("ack", &mut ack), ("wide", &mut wide)]
        {
            dialog.layout(window, &tm);
            let card = dialog.card();
            assert!(
                card.min_x() >= 0.0
                    && card.max_x() <= window.width
                    && card.min_y() >= 0.0
                    && card.max_y() <= window.height,
                "{name}: card {card:?} leaves the window"
            );
            assert!(!dialog.button_frames().is_empty(), "{name}: no buttons");
            for (i, f) in dialog.button_frames() {
                assert!(
                    f.min_x() >= 0.0 && f.max_x() <= window.width && f.min_y() >= 0.0 && f.max_y() <= window.height,
                    "{name}: button {i} {f:?} leaves the window"
                );
            }
        }
    }

    /// Linux check part 5: the Shortcuts page was as tall as the app window (640-900) while the other pages are 640, so the
    /// sidebar jumped up to 89 px when the page was picked and back (and a click at the old spot hit something else). Every
    /// page, the Shortcuts page included, is the one Settings card with the sidebar search at the same place, in any window.
    #[test]
    fn every_settings_page_has_the_same_card_and_sidebar_position_in_every_window() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let mut editor = crate::shell_shortcuts::ShellShortcutsEditor::new(&d, Platform::Mac);
        for (w, h) in [(640.0, 400.0), (1280.0, 800.0), (1440.0, 900.0), (1920.0, 898.0), (1440.0, 1400.0)] {
            let window = sq_uikit::controls_grid::CGRect::new(0.0, 0.0, w, h);
            editor.frame = window;
            let shortcuts = editor.parts(&tm);
            assert_eq!(shortcuts.card, settings_card(window), "{w}x{h}: Shortcuts card");
            for page in ShellPreferences::visible_pages(&c).into_iter().filter(|p| *p != Page::Shortcuts) {
                let mut sheet = ShellDialog::new("Settings", "");
                sheet.width = WIDTH_L;
                sheet.card_height = Some(settings_height());
                sheet.headerless = true;
                sheet.add_button("Done", SQDialogRole::Default, false);
                let mut f = form(page, &s, &x, &c, &d);
                f.enable_search("");
                sheet.form = Some(Box::new(f));
                sheet.layout(window, &tm);
                assert_eq!(sheet.card(), shortcuts.card, "{w}x{h}: the {page:?} card differs from the Shortcuts card");
                let search = sheet.form.as_ref().and_then(|f| f.search_field()).map(|f| f.0).expect("search field");
                assert_eq!(
                    (search.min_x(), search.min_y()),
                    (shortcuts.side_search.min_x(), shortcuts.side_search.min_y()),
                    "{w}x{h}: the sidebar search of {page:?} sits elsewhere than on the Shortcuts page"
                );
            }
        }
    }

    /// Review: at 640 wide every wrapped help line fits the column beside its control, so none is cut by an ellipsis in the
    /// middle of a sentence; the page subtitle fits the card column too (else it ends in an ellipsis when drawn).
    #[test]
    fn settings_help_lines_fit_their_column_at_640_by_400() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let mut checked = 0;
        for page in ShellPreferences::visible_pages(&c) {
            let mut f = form(page, &s, &x, &c, &d);
            f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, 640.0, &tm);
            for (i, text) in f.card_text_rects() {
                let widest = f.widest_help_line(i, &tm);
                if widest > 0.0 {
                    checked += 1;
                    assert!(
                        widest <= text.width + 0.5,
                        "{page:?} row {i}: help line {widest} in a {} column",
                        text.width
                    );
                }
            }
        }
        assert!(checked > 10, "{checked}");
    }

    /// The card width the Settings sheet really gets in a `w` x `h` window (the form is laid out at the card's width).
    fn real_card_width(w: f64, h: f64, tm: &sq_draw::TextMeasure) -> f64 {
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let mut sheet = ShellDialog::new("Settings", "");
        sheet.width = WIDTH_L;
        sheet.card_height = Some(HEIGHT_L);
        sheet.headerless = true;
        sheet.add_button("Done", SQDialogRole::Default, false);
        sheet.add_button("Reset to Defaults", SQDialogRole::Normal, true);
        sheet.button_widths.insert(0, 70.0);
        sheet.form = Some(Box::new(form(Page::General, &s, &x, &c, &d)));
        sheet.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, w, h), tm);
        sheet.card().width
    }

    /// The footer at the real narrow window sizes: Reset to Defaults and Done keep the standard gap between their outlines,
    /// and the hint (in every state) ends before Reset starts.
    #[test]
    fn the_settings_footer_keeps_a_gap_between_reset_and_done_at_640_by_400() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        for hint_changes in [0usize, 1, 12] {
            for (w, h) in [(640.0, 400.0), (1440.0, 900.0)] {
                let mut sheet = ShellDialog::new("Settings", "");
                sheet.width = WIDTH_L;
                sheet.card_height = Some(HEIGHT_L);
                sheet.headerless = true;
                sheet.add_button("Done", SQDialogRole::Default, false);
                sheet.add_button("Reset to Defaults", SQDialogRole::Normal, true);
                sheet.button_widths.insert(0, 70.0);
                sheet.footer_hint = Some(ShellPreferences::footer_hint(hint_changes));
                sheet.form = Some(Box::new(form(Page::General, &s, &x, &c, &d)));
                sheet.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, w, h), &tm);
                let (done, reset) = (sheet.button_frames()[&0], sheet.button_frames()[&1]);
                let gap = done.min_x() - reset.max_x();
                assert!(gap >= 8.0 - 0.01, "{w}x{h} hint {hint_changes}: gap {gap} between {reset:?} and {done:?}");
                let hint_w = tm.width(&ShellPreferences::footer_hint(hint_changes), 11.0, 0).ceil();
                let card = sheet.card();
                let hint_end = card.min_x() + 232.0 + hint_w;
                assert!(reset.width >= 120.0, "{w}x{h}: Reset to Defaults is cut to {}", reset.width);
                if sheet.footer_hint_shown() {
                    assert!(
                        hint_end <= reset.min_x() + 0.5,
                        "{w}x{h}: hint ends {hint_end}, Reset starts {}",
                        reset.min_x()
                    );
                } else {
                    assert_eq!(w, 640.0, "the hint stays in a big window");
                }
            }
        }
    }

    fn overlaps(a: sq_uikit::controls_grid::CGRect, b: sq_uikit::controls_grid::CGRect) -> bool {
        a.min_x() < b.max_x() - 0.5
            && b.min_x() < a.max_x() - 0.5
            && a.min_y() < b.max_y() - 0.5
            && b.min_y() < a.max_y() - 0.5
    }

    /// Every row of every Settings page at the card width the 640x400 and 640x1000 windows really give: no control touches
    /// any text, every title and help line fits its column (no ellipsis), the subtitle fits its lines.
    #[test]
    fn every_settings_row_is_clean_at_the_real_narrow_card_width() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let (mut texts_n, mut stacked) = (0, 0);
        for (w, h) in [(640.0, 400.0), (640.0, 1000.0)] {
            let card = real_card_width(w, h, &tm);
            assert!(card < 640.0, "card {card} in a {w} wide window");
            for page in ShellPreferences::visible_pages(&c) {
                let mut f = form(page, &s, &x, &c, &d);
                f.page_header = Some((page.title().to_string(), page.subtitle().to_string()));
                f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, card, &tm);
                stacked += f.stacked_row_count();
                assert!(f.subtitle_line_count() >= 1, "{page:?}: no subtitle");
                let (texts, controls) = f.page_rects(&tm);
                for (row, what, rect, need) in &texts {
                    texts_n += 1;
                    assert!(
                        *need <= rect.width + 0.5,
                        "{page:?} row {row} {what}: {need} wide in a {} column",
                        rect.width
                    );
                    for (crow, ctl) in &controls {
                        assert!(
                            !overlaps(*rect, *ctl),
                            "{page:?} card {card}: {what} of row {row} {rect:?} meets the control of row {crow} {ctl:?}"
                        );
                    }
                }
            }
        }
        assert!(texts_n > 60, "{texts_n}");
        assert!(stacked > 20, "{stacked}");
    }

    /// At the full 900 wide card nothing stacks and every row's text still fits its column: the wide layout is the one
    /// the kit shows.
    #[test]
    fn no_settings_row_stacks_at_the_wide_card_width() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let card = real_card_width(1440.0, 900.0, &tm);
        assert!(card >= 900.0, "{card}");
        for page in ShellPreferences::visible_pages(&c) {
            let mut f = form(page, &s, &x, &c, &d);
            f.page_header = Some((page.title().to_string(), page.subtitle().to_string()));
            f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, card, &tm);
            assert_eq!(f.stacked_row_count(), 0, "{page:?} stacked at {card}");
            assert_eq!(f.subtitle_line_count(), 1, "{page:?} subtitle wrapped at {card}");
            let (texts, controls) = f.page_rects(&tm);
            for (row, what, rect, need) in &texts {
                assert!(*need <= rect.width + 0.5, "{page:?} row {row} {what}: {need} in {}", rect.width);
                for (_, ctl) in &controls {
                    assert!(!overlaps(*rect, *ctl), "{page:?} {what} of row {row} meets a control");
                }
            }
        }
    }

    /// Review: Playback, Editing and Media squeezed a row's label column to ~70 pt at 640 wide. Every card row's text column
    /// is at least its longest word (and 130 pt) wide.
    #[test]
    fn no_settings_label_is_narrower_than_its_longest_word_at_640_by_400() {
        let tm = crate::tests::measure();
        let (d, c) = (ShellDefaults::default(), PreferencesHost::default());
        let (s, x) = (AppSettings::standard(), Extras::default());
        let mut checked = 0;
        for page in ShellPreferences::visible_pages(&c) {
            let mut f = form(page, &s, &x, &c, &d);
            f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, 640.0, &tm);
            for (i, text) in f.card_text_rects() {
                let ctl = f.control_frames()[i];
                if ctl.width <= 0.0 || ctl.height <= 0.0 || text.min_x() >= ctl.max_x() || text.min_y() >= ctl.max_y() {
                    continue;
                }
                checked += 1;
                assert!(text.width >= 130.0, "{page:?} row {i}: label column {} wide", text.width);
            }
        }
        assert!(checked > 20, "{checked}");
    }

    #[test]
    fn a_setting_off_its_factory_value_is_marked_and_counted_on_its_page() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let mut s = AppSettings::standard();
        let mut x = Extras::default();
        let f = form(Page::General, &s, &x, &c, &d);
        let (none, counts) = ShellPreferences::marks(&f, &s, &x, &c, &d);
        assert!(none.is_empty() && counts.iter().all(|n| *n == 0));
        x.ui_scale = interface_scale::STEPS[0];
        s.use_proxies_for_export = true;
        let f = form(Page::General, &s, &x, &c, &d);
        let (changed, counts) = ShellPreferences::marks(&f, &s, &x, &c, &d);
        assert_eq!(changed.into_iter().collect::<Vec<_>>(), ["uiScale"], "only the rows this page shows");
        let media = ShellPreferences::visible_pages(&c).iter().position(|p| *p == Page::Media).unwrap();
        assert_eq!((counts[0], counts[media]), (1, 1));
    }

    #[test]
    fn the_factory_value_is_what_the_reset_arrow_goes_back_to() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let x = Extras { ui_scale: interface_scale::STEPS[0], ..Extras::default() };
        let factory = ShellPreferences::factory_value(Page::General, "uiScale", &x, &c, &d);
        let default_index =
            interface_scale::STEPS.iter().position(|v| *v == Extras::default().ui_scale).unwrap_or(2) as i64;
        assert_eq!(factory, Some(FormValue::Index(default_index)));
        assert_eq!(ShellPreferences::page_of("proxyExport", &AppSettings::standard(), &x, &c, &d), Some(Page::Media));
    }

    #[test]
    fn search_lists_matching_rows_of_every_page_under_their_page_name() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let (s, x) = (AppSettings::standard(), Extras::default());
        let f = ShellPreferences::search_form("proxies", &s, &x, &c, &d);
        assert!(captions(&f).contains(&"Media".to_string()));
        assert!(f.rows().iter().any(|r| r.id() == Some("proxyExport")));
        assert!(f.rows().iter().all(|r| r.id() != Some("uiLanguage")), "no match, no row");
        // a page name finds all rows of that page
        assert!(ShellPreferences::search_form("audio", &s, &x, &c, &d).rows().len() > 5);
        // nothing found: a line says so
        let none = ShellPreferences::search_form("qqqzzz", &s, &x, &c, &d);
        assert!(matches!(none.rows(), [Row::Text(t)] if t.contains("qqqzzz")));
    }

    #[test]
    fn search_also_lists_shortcuts_by_name_or_keys_and_the_page_counts_changed_bindings() {
        let mut d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let (s, x) = (AppSettings::standard(), Extras::default());
        let f = ShellPreferences::search_form("undo", &s, &x, &c, &d);
        assert!(captions(&f).contains(&"Shortcuts".to_string()), "{:?}", captions(&f));
        assert!(f.rows().iter().any(|r| matches!(r, Row::Text(t) if t.starts_with("Undo"))));
        let f = ShellPreferences::search_form("qqqzzz", &s, &x, &c, &d);
        assert!(matches!(f.rows(), [Row::Text(t)] if t.contains("qqqzzz")));
        // the sidebar counter of Shortcuts is the changed bindings
        let pages = ShellPreferences::visible_pages(&c);
        let at = pages.iter().position(|p| *p == Page::Shortcuts).unwrap();
        let form = ShellPreferences::form(Page::General, &s, &x, &c, &d, "");
        assert_eq!(ShellPreferences::marks(&form, &s, &x, &c, &d).1[at], 0);
        let mut e = crate::shell_shortcuts::ShellShortcutsEditor::new(&d, sq_os::Platform::Mac);
        let i = e.all_rows().iter().position(|r| r.command == sq_uikit::editor_command::EditorCommand::Undo).unwrap();
        e.select(Some(i));
        e.remove_shortcut();
        sq_uikit::keymap_store::KeymapStore::save(e.config(), &mut d);
        assert_eq!(ShellPreferences::marks(&form, &s, &x, &c, &d).1[at], 1);
    }

    #[test]
    fn appearance_has_a_system_card_and_it_is_stored() {
        let mut d = ShellDefaults::default();
        let (s, mut x) = (AppSettings::standard(), Extras::default());
        let mut f = form(Page::General, &s, &x, &PreferencesHost::default(), &d);
        let i = f.rows().iter().position(|r| r.id() == Some("appearance")).unwrap();
        assert!(matches!(&f.rows()[i], Row::Popup { options, .. } if options == &["Dark", "Light", "System"]));
        f.set("appearance", FormValue::Index(2));
        ShellPreferences::apply_extras(&f, &mut x);
        x.save(&mut d);
        assert_eq!(AppearanceSettings::from_defaults(&d).mode, AppearanceMode::System);
        let again = form(Page::General, &s, &Extras::load(&d), &PreferencesHost::default(), &d);
        assert_eq!(again.index("appearance"), Some(2));
    }

    #[test]
    fn new_sequences_start_in_two_picture_cards_with_the_help_above_them() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let mut f = form(Page::Editing, &AppSettings::standard(), &Extras::default(), &c, &d);
        f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, 900.0, &sq_draw::TextMeasure::new(None, 1.0));
        let i = f.rows().iter().position(|r| r.id() == Some("newSequence")).unwrap();
        assert!(matches!(&f.rows()[i], Row::Popup { options, .. } if options == &["Normal", "Fast Cut"]));
        let (row, cards) = (f.row_frames()[i], f.control_frames()[i]);
        assert!(cards.height >= 94.0 && cards.min_y() > row.min_y() + 40.0, "cards sit under title and help");
        f.set("newSequence", FormValue::Index(1));
        let mut s = AppSettings::standard();
        ShellPreferences::apply_settings(&f, &mut s, &c);
        assert_eq!(s.new_sequence_edit_mode, sq_core_model::TimelineEditMode::Magnetic);
    }

    /// Windows: the unit label ran past the card edge, and the Advanced switch was a full-width bar.
    #[test]
    fn number_units_stay_inside_the_card_and_the_edit_api_switch_is_a_switch() {
        let d = ShellDefaults::default();
        let tm = sq_draw::TextMeasure::new(None, 1.0);
        let at = sq_uikit::controls_grid::CGPoint::ZERO;
        let c = PreferencesHost::default();
        let mut f = form(Page::Editing, &AppSettings::standard(), &Extras::default(), &c, &d);
        f.layout_at(at, 900.0, &tm);
        for (id, unit) in [("videoTransition", "frames"), ("audioTransition", "seconds")] {
            let i = f.rows().iter().position(|r| r.id() == Some(id)).unwrap();
            let end = f.scrub_frames()[id].max_x() + 8.0 + tm.width(unit, 13.0, 0);
            assert!(end <= f.row_frames()[i].max_x() - 20.0, "{id}: unit ends at {end}, row {:?}", f.row_frames()[i]);
        }
        let c = PreferencesHost {
            edit_api: Some((true, EditApiState::new("Not running", StatusTone::Idle))),
            ..PreferencesHost::default()
        };
        let mut f = form(Page::Advanced, &AppSettings::standard(), &Extras::default(), &c, &d);
        f.layout_at(at, 900.0, &tm);
        let i = f.rows().iter().position(|r| r.id() == Some("api")).unwrap();
        assert_eq!(f.control_frames()[i].width, 34.0, "a 34 pt switch, not a bar");
        assert!(f.control_frames()[i].max_x() <= f.row_frames()[i].max_x());
    }

    #[test]
    fn duck_timing_cells_are_rows_of_the_card_and_role_cells_sit_inline() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let mut f = form(Page::Audio, &AppSettings::standard(), &Extras::default(), &c, &d);
        f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, 900.0, &sq_draw::TextMeasure::new(None, 1.0));
        let at = |id: &str| f.rows().iter().position(|r| r.id() == Some(id)).unwrap();
        let (timing, offset) = (at("duckTiming"), at("offset"));
        let cells: Vec<sq_uikit::controls_grid::CGRect> =
            TIMING_FIELDS.iter().map(|(id, _, _)| f.scrub_frames()[&format!("timing.{id}")]).collect();
        // stacked below the popup, 5 rows, one pitch apart, inside the popup row's frame
        assert!(
            cells.windows(2).all(|w| w[1].min_y() - w[0].min_y() >= 35.0 && (w[0].min_x() - w[1].min_x()).abs() < 0.5)
        );
        assert!(cells[0].min_y() > f.control_frames()[timing].max_y());
        assert!(
            cells
                .iter()
                .all(|r| r.min_y() >= f.row_frames()[timing].min_y() && r.max_y() <= f.row_frames()[timing].max_y())
        );
        // role cells: one line, right of the row's title, left to right
        let roles: Vec<sq_uikit::controls_grid::CGRect> =
            ["dialogue", "music", "sfx"].iter().map(|r| f.scrub_frames()[&format!("offset.{r}")]).collect();
        assert!(roles.windows(2).all(|w| w[1].min_x() > w[0].max_x() && w[0].min_y() == w[1].min_y()));
        assert!(
            roles[0].min_y() >= f.row_frames()[offset].min_y() && roles[2].max_y() <= f.row_frames()[offset].max_y()
        );
    }

    #[test]
    fn appearance_is_a_row_of_picture_cards_and_the_sidebar_lists_shortcuts() {
        let d = ShellDefaults::default();
        let c = PreferencesHost::default();
        let mut f = form(Page::General, &AppSettings::standard(), &Extras::default(), &c, &d);
        f.layout_at(sq_uikit::controls_grid::CGPoint::ZERO, 900.0, &sq_draw::TextMeasure::new(None, 1.0));
        let i = f.rows().iter().position(|r| r.id() == Some("appearance")).unwrap();
        assert!(f.control_frames()[i].height >= 94.0);
        let titles: Vec<String> = ShellPreferences::sidebar(&c).items.into_iter().map(|(t, _)| t).collect();
        assert_eq!(titles, ["General", "Playback", "Editing", "Audio", "Media", "Shortcuts"]);
    }

    #[test]
    fn general_rows_write_interface_size_and_transcription() {
        let mut d = ShellDefaults::default();
        let mut s = AppSettings::load(&d);
        let mut x = Extras::load(&d);
        assert_eq!(x.ui_scale, 1.0);
        let mut f = form(Page::General, &s, &x, &PreferencesHost::default(), &d);
        assert_eq!(f.index("uiScale"), interface_scale::STEPS.iter().position(|v| *v == 1.0).map(|i| i as i64));
        let step = interface_scale::STEPS.iter().position(|v| *v == 1.25).expect("step");
        f.set("uiScale", FormValue::Index(step as i64));
        let langs = ShellPreferences::transcription_languages(&s.caption_language);
        let other = langs.iter().position(|l| *l != s.caption_language).expect("another language");
        f.set("transcription", FormValue::Index(other as i64));
        ShellPreferences::apply_settings(&f, &mut s, &PreferencesHost::default());
        ShellPreferences::apply_extras(&f, &mut x);
        x.save(&mut d);
        assert_eq!(s.caption_language, langs[other]);
        assert_eq!(Extras::load(&d).ui_scale, 1.25);
    }

    /// Mac parity: the pages are `SettingsWindow`'s `SQFormRow` rows: captions, check row labels, help lines, popup widths.
    #[test]
    fn pages_carry_the_mac_captions_labels_helps_and_widths() {
        let d = ShellDefaults::default();
        let (s, x, c) = (AppSettings::load(&d), Extras::load(&d), PreferencesHost::default());
        let general = form(Page::General, &s, &x, &c, &d);
        assert_eq!(captions(&general), ["New items", "Experimental"]);
        assert_eq!(general.check_labels.get("recovery").map(String::as_str), Some("Recovery"));
        assert_eq!(general.check_labels.get("autoLanguage").map(String::as_str), Some("Auto Language"));
        assert!(!general.helps.contains_key("uiLanguage"), "English only: no Interface Language row");
        assert_eq!(general.control_widths["autosave"], 196.0);
        let playback = form(Page::Playback, &s, &x, &c, &d);
        assert_eq!(captions(&playback), ["Play around", "Feedback"]);
        assert_eq!((playback.control_widths["preroll"], playback.control_widths["postroll"]), (180.0, 180.0));
        assert_eq!(playback.check_labels["dropIndicator"], "Dropped Frames");
        assert_eq!(captions(&form(Page::Audio, &s, &x, &c, &d)).first().map(String::as_str), Some("Ducking"));
        assert_eq!(captions(&form(Page::Media, &s, &x, &c, &d)), ["Library", "Cache", "Folders"]);
    }

    /// The kit's page lines (prefs-body.html DESC), the shared outside-files names and the General order.
    #[test]
    fn page_lines_outside_names_and_general_order_follow_the_kit() {
        let lines: Vec<&str> = Page::ALL.iter().map(|p| p.subtitle()).collect();
        assert!(lines.contains(&"How smoothly the monitors play and what runs in the background."));
        assert!(lines.contains(&"How new sequences behave and how long transitions are."));
        assert!(lines.contains(&"Clicks, ducking, roles and meters."));
        assert!(lines.contains(&"Where files go, what gets copied and how big the cache may grow."));
        assert!(lines.contains(&"Folders and the local Edit API."));
        for m in OUTSIDE_MODES {
            let n = crate::shell_new_project::ShellNewProject::OUTSIDE_CHOICES.iter().find(|c| c.0 == m).map(|c| c.1);
            assert_eq!(Some(outside_title(m)), n, "Settings and New Project name {m:?} alike");
        }
        let d = ShellDefaults::default();
        let (s, x, c) = (AppSettings::load(&d), Extras::load(&d), PreferencesHost::default());
        let general = form(Page::General, &s, &x, &c, &d);
        let pos = |id: &str| general.rows().iter().position(|r| r.id() == Some(id));
        let cap = |t: &str| general.rows().iter().position(|r| matches!(r, Row::Caption(c) if c == t));
        assert!(cap("New items") < cap("Experimental"));
        assert!(cap("Experimental") < pos("experimentalLabels"), "Labels sits under the Experimental caption");
        assert!(pos("autoLanguage") < cap("Experimental"));
    }

    #[test]
    fn the_footer_counts_changes_like_the_kit() {
        assert_eq!(ShellPreferences::footer_hint(0), "Changes apply right away.");
        assert_eq!(ShellPreferences::footer_hint(1), "1 change · applies right away");
        assert_eq!(ShellPreferences::footer_hint(3), "3 changes · apply right away");
    }

    #[test]
    fn settings_icons_and_tiles_follow_the_kit() {
        assert_eq!(Page::Editing.icon(), SQIcon::ToolBlade, "scissors");
        assert_eq!(Page::Advanced.icon(), SQIcon::Settings, "gear");
        assert_eq!(SQIcon::ToolBlade.resource(), "ph-scissors");
        assert_eq!(SQIcon::Settings.resource(), "ph-gear-six");
        let tile = |t: &str| crate::shell_form::ShellForm::tile_color(t);
        assert_eq!(tile("Editing"), sq_draw::Color::hex(0x7350C0, 1.0));
        assert_eq!(tile("Advanced"), sq_draw::Color::hex(0x4F78A3, 1.0));
    }

    #[test]
    fn the_experimental_switch_is_stored_and_applied() {
        let mut d = ShellDefaults::default();
        let mut x = Extras::load(&d);
        assert!(x.experimental_labels, "on by default");
        x.experimental_labels = false;
        x.save(&mut d);
        assert!(!Extras::load(&d).experimental_labels);
        assert!(!sq_draw::experimental::prefs().shows_mark(), "the live marks follow the switch");
        x.experimental_labels = true;
        x.save(&mut d);
        assert!(sq_draw::experimental::prefs().shows_mark());
    }

    #[test]
    fn general_rows_write_the_appearance_keys() {
        let mut d = ShellDefaults::default();
        let s = AppSettings::load(&d);
        let mut x = Extras::load(&d);
        assert_eq!(x.appearance, AppearanceSettings::standard());
        let mut f = form(Page::General, &s, &x, &PreferencesHost::default(), &d);
        assert_eq!(
            (f.index("appearance"), f.number("appearanceBackground"), f.number("appearanceContrast")),
            (Some(0), Some(0.0), Some(50.0))
        );
        f.set("appearance", FormValue::Index(1));
        f.set("appearanceBackground", FormValue::Number(-2.4));
        f.set("appearanceContrast", FormValue::Number(140.0));
        ShellPreferences::apply_extras(&f, &mut x);
        x.save(&mut d);
        assert_eq!(AppearanceSettings::from_defaults(&d), AppearanceSettings::new(AppearanceMode::Light, -2, 100));
    }

    #[test]
    fn audio_rows_write_de_click_ducking_meter_and_fade_shape() {
        let mut d = ShellDefaults::default();
        let s = AppSettings::load(&d);
        let mut x = Extras::load(&d);
        assert!(x.de_click && x.duck_amount.is_none());
        assert_eq!((x.meter_style, x.fade_curve), (MeterStyle::Standard, FadeCurve::Linear));
        let c = PreferencesHost::default();
        let mut f = form(Page::Audio, &s, &x, &c, &d);
        f.set("deClick", FormValue::Bool(false));
        f.set("liveDuck", FormValue::Bool(true));
        f.set("duckAmount", FormValue::Number(18.0));
        f.set(
            "meterStyle",
            FormValue::Index(MeterStyle::ALL.iter().position(|m| *m == MeterStyle::Fast).expect("fast") as i64),
        );
        f.set(
            "fadeCurve",
            FormValue::Index(FadeCurve::ALL.iter().position(|m| *m == FadeCurve::SCurve).expect("s") as i64),
        );
        ShellPreferences::apply_extras(&f, &mut x);
        x.save(&mut d);
        assert!(!AudioPreferences::de_click(&d));
        assert_eq!(LiveDucking::current(&ReadBridge(&d)).map(|l| l.amount_db), Some(18.0));
        assert_eq!(MeterStyle::current(&d), MeterStyle::Fast);
        assert_eq!(Extras::load(&d).fade_curve, FadeCurve::SCurve);

        let mut off = form(Page::Audio, &s, &x, &c, &d);
        assert_eq!(off.bool("liveDuck"), Some(true));
        off.set("liveDuck", FormValue::Bool(false));
        ShellPreferences::apply_extras(&off, &mut x);
        x.save(&mut d);
        assert!(LiveDucking::current(&ReadBridge(&d)).is_none());
    }

    /// The Mac Live Ducking row: the amount is a 72 pt field after the check title ("12.0", no unit), any 0.5 dB step.
    #[test]
    fn the_duck_amount_is_a_field_after_the_live_ducking_check() {
        let mut d = ShellDefaults::default();
        LiveDucking::set_amount(Some(10.0), &mut Bridge(&mut d));
        let mut x = Extras::load(&d);
        let mut f = form(Page::Audio, &AppSettings::load(&d), &x, &PreferencesHost::default(), &d);
        let (field, width) = f.check_fields().get("liveDuck").cloned().expect("check field");
        assert_eq!((width, field.decimals), (72.0, 1));
        assert_eq!(f.number("duckAmount"), Some(10.0));
        f.set("duckAmount", FormValue::Number(13.3));
        ShellPreferences::apply_extras(&f, &mut x);
        assert_eq!(x.duck_amount, Some(13.5));
        f.set("liveDuck", FormValue::Bool(false));
        ShellPreferences::apply_extras(&f, &mut x);
        assert_eq!(x.duck_amount, None);
    }

    /// Duck Timing and the role values sit in grids under their rows: ms fields for the timing, label-tinted role fields
    /// without a unit under "J / L Offset" and "Crossfade Length".
    #[test]
    fn timing_and_role_values_are_grids_under_their_rows() {
        let d = ShellDefaults::default();
        let f = form(Page::Audio, &AppSettings::load(&d), &Extras::load(&d), &PreferencesHost::default(), &d);
        let timing = &f.grids()["duckTiming"];
        let titles: Vec<&str> = timing.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(titles, ["Lookahead", "Attack", "Hold", "Recovery", "Minimum pause"]);
        assert!(timing.iter().all(|c| c.unit == "ms" && c.field.step == 5.0));
        assert_eq!((f.grids()["offset"].len(), f.grids()["length"].len()), (ROLES.len(), ROLES.len()));
        assert!(f.grids()["offset"].iter().all(|c| c.unit.is_empty() && f.label_tinted.contains(&c.field.id)));
        assert!(
            f.rows().iter().any(|r| matches!(r, Row::Label { id, label } if id == "offset" && label == "J / L Offset"))
        );
        assert!(!f.rows().iter().any(|r| matches!(r, Row::Caption(t) if t == "J / L Offset")));
    }

    /// Advanced appears only with a host Edit API: the switch, its status line and Copy address.
    #[test]
    fn the_advanced_page_shows_the_edit_api_switch_and_status() {
        let d = ShellDefaults::default();
        let mut c = PreferencesHost::default();
        assert_eq!(ShellPreferences::sidebar(&c).items.len(), Page::ALL.len() - 1);
        c.edit_api = Some((
            true,
            EditApiState {
                text: "Listening on 127.0.0.1, port 7341".to_string(),
                tone: StatusTone::Ok,
                copyable_port: Some(7341),
            },
        ));
        assert_eq!(ShellPreferences::sidebar(&c).items.last().map(|i| i.0.as_str()), Some("Advanced"));
        let f = form(Page::Advanced, &AppSettings::load(&d), &Extras::load(&d), &c, &d);
        assert_eq!(f.bool("api"), Some(true));
        assert_eq!(f.check_labels["api"], "Edit API");
        let status = &f.statuses["api"];
        assert_eq!((status.button.as_deref(), status.tone), (Some("Copy address"), StatusTone::Ok));
        let idle = EditApiState { text: "Not running".to_string(), tone: StatusTone::Idle, copyable_port: None };
        assert_eq!(ShellPreferences::api_status(&idle).button, None);
    }

    #[test]
    fn duck_preset_sets_amount_and_timing_and_the_fields_fall_back_to_custom() {
        let mut d = ShellDefaults::default();
        let mut x = Extras::load(&d);
        assert_eq!(x.duck_timing, DuckTiming::classic());
        let mut f = form(Page::Audio, &AppSettings::load(&d), &x, &PreferencesHost::default(), &d);
        assert_eq!((f.index("duckPreset"), f.index("duckTiming")), (Some(0), Some(0)));
        let hard = DuckPreset::all().iter().position(|p| p.title.starts_with("Hard")).expect("hard");
        f.set("duckPreset", FormValue::Index(hard as i64 + 1));
        ShellPreferences::apply_extras(&f, &mut x);
        ShellPreferences::sync(&mut f, &x);
        x.save(&mut d);
        let want = DuckPreset::all()[hard].clone();
        assert_eq!(LiveDucking::current(&ReadBridge(&d)).map(|l| l.amount_db), Some(want.amount_db));
        assert_eq!(DuckTiming::stored(&ReadBridge(&d)), want.timing.clamped());
        assert_eq!(f.bool("liveDuck"), Some(true));
        assert_eq!(f.number("timing.attack"), Some(want.timing.attack_ms));

        f.set("duckTiming", FormValue::Index(2));
        ShellPreferences::apply_extras(&f, &mut x);
        ShellPreferences::sync(&mut f, &x);
        assert_eq!(x.duck_timing, DuckTimingChoices::presets()[2].timing.clamped());
        assert_eq!(f.index("duckPreset"), Some(0));

        f.set("timing.hold", FormValue::Text("777".to_string()));
        ShellPreferences::apply_extras(&f, &mut x);
        ShellPreferences::sync(&mut f, &x);
        x.save(&mut d);
        assert_eq!(DuckTiming::stored(&ReadBridge(&d)).hold_ms, 777.0);
        assert_eq!(f.index("duckTiming"), Some(DuckTimingChoices::presets().len() as i64));
    }

    #[test]
    fn media_rows_write_the_media_defaults_and_card_import() {
        let mut d = ShellDefaults::default();
        let mut x = Extras::load(&d);
        let mut c = PreferencesHost::default();
        let hidden = form(Page::Media, &AppSettings::load(&d), &x, &c, &d);
        assert_eq!(hidden.bool("cardImport"), None);
        c.card_import = true;
        let mut f = form(Page::Media, &AppSettings::load(&d), &x, &c, &d);
        f.set(
            "outside",
            FormValue::Index(OUTSIDE_MODES.iter().position(|m| *m == OutsideMediaMode::Copy).expect("copy") as i64),
        );
        f.set("watchFolder", FormValue::Bool(false));
        f.set("libraryCopy", FormValue::Bool(false));
        f.set("cardImport", FormValue::Bool(false));
        ShellPreferences::apply_extras(&f, &mut x);
        x.save(&mut d);
        assert_eq!(
            MediaSettings::load(&d),
            MediaPolicyDefaults { outside: OutsideMediaMode::Copy, copy_library_items: false, watch_folder: false }
        );
        assert!(!CardImportSettings::is_enabled(&d));
    }

    #[test]
    fn general_page_shows_the_app_menu_row_only_for_an_appimage() {
        let d = ShellDefaults::default();
        let (s, x) = (AppSettings::load(&d), Extras::load(&d));
        let mut c = PreferencesHost::default();
        assert!(!button_ids(&form(Page::General, &s, &x, &c, &d)).iter().any(|id| id == "appMenu"));
        c.app_menu = AppMenuRow::NotAdded;
        assert!(button_ids(&form(Page::General, &s, &x, &c, &d)).iter().any(|id| id == "appMenu"));
        c.app_menu = AppMenuRow::Added { file: "~/Applications/SequenceStudio.AppImage".into() };
        let f = form(Page::General, &s, &x, &c, &d);
        let shown = f.rows().iter().find_map(|r| match r {
            Row::Buttons { id, titles, .. } if id == "appMenu" => Some(titles.clone()),
            _ => None,
        });
        assert_eq!(shown, Some(vec!["Remove…".to_string()]));
        assert_eq!(
            f.helps.get("appMenu").map(String::as_str),
            Some("Added \u{b7} ~/Applications/SequenceStudio.AppImage")
        );
    }

    #[test]
    fn media_page_lists_library_folders_and_delete_cache() {
        let d = ShellDefaults::default();
        let (s, x) = (AppSettings::load(&d), Extras::load(&d));
        let mut c = PreferencesHost::default();
        let bare = button_ids(&form(Page::Media, &s, &x, &c, &d));
        assert!(!bare.iter().any(|id| id == "libFolderAdd" || id == "cacheClear"));
        c.library_folders = Some(vec![ShellLibraryFolder {
            id: "a".into(),
            name: "Music".into(),
            path: "~/Music".into(),
            offline: false,
        }]);
        c.cache_used = Some("Empty".to_string());
        let f = form(Page::Media, &s, &x, &c, &d);
        let ids = button_ids(&f);
        assert!(ids.iter().any(|id| id == "libFolderAdd") && ids.iter().any(|id| id == "cacheClear"));
        // The Mac boxed list: one list box, a folder icon and the path on each line, a Remove button per line.
        let list = f.rows().iter().find_map(|r| match r {
            Row::ListBox { id, label, lines, button, .. } if id == "libFolder" => Some((label, lines, button)),
            _ => None,
        });
        let (label, lines, button) = list.expect("Library Folders list box");
        assert_eq!(
            (label.as_str(), lines.as_slice(), button.as_str()),
            ("Library Folders", &["Music".to_string()][..], "Remove")
        );
        assert_eq!(
            f.list_lines["libFolder"],
            [ListLine { icon: Some(SQIcon::Folder), detail: "~/Music".into(), warning: None }]
        );
        assert_eq!(ShellPreferences::button_action("libFolder", 0, None), Some(ButtonAction::RemoveLibraryFolder(0)));
        assert_eq!(ShellPreferences::button_action("libFolderAdd", 0, None), Some(ButtonAction::AddLibraryFolder));
        assert_eq!(ShellPreferences::button_action("cacheClear", 0, None), Some(ButtonAction::ClearCache));
    }

    #[test]
    fn add_and_remove_change_the_folder_list_the_open_page_shows() {
        let mut c = PreferencesHost {
            library_folders: Some(vec![ShellLibraryFolder {
                id: "a".into(),
                name: "Music".into(),
                path: "~/Music".into(),
                offline: false,
            }]),
            ..PreferencesHost::default()
        };
        ShellPreferences::show_folder_change(&mut c, ButtonAction::AddLibraryFolder, Some(Path::new("/x/Sounds")));
        let names: Vec<String> =
            c.library_folders.as_ref().map(|l| l.iter().map(|f| f.name.clone()).collect()).unwrap_or_default();
        assert_eq!(names, ["Music", "Sounds"]);
        ShellPreferences::show_folder_change(&mut c, ButtonAction::RemoveLibraryFolder(0), None);
        let names: Vec<String> =
            c.library_folders.as_ref().map(|l| l.iter().map(|f| f.name.clone()).collect()).unwrap_or_default();
        assert_eq!(names, ["Sounds"]);
    }

    #[test]
    fn frame_cache_and_audio_output_rows_write_app_settings() {
        let d = ShellDefaults::default();
        let mut s = AppSettings::load(&d);
        let mut c = PreferencesHost {
            frame_cache_values: vec![0, 1, 2],
            frame_cache_titles: vec!["Auto (1.0 GB)".into(), "1 GB".into(), "2 GB".into()],
            ..PreferencesHost::default()
        };
        let x = Extras::default();
        assert_eq!(form(Page::Playback, &s, &x, &c, &d).index("audioOutput"), None);
        c.audio_outputs =
            Some(vec![AudioOutputDevice::new("a", "Speakers"), AudioOutputDevice::new("b", "Headphones")]);
        let mut f = form(Page::Playback, &s, &x, &c, &d);
        assert_eq!((f.index("frameCache"), f.index("audioOutput")), (Some(0), Some(0)));
        f.set("frameCache", FormValue::Index(2));
        f.set("audioOutput", FormValue::Index(2));
        ShellPreferences::apply_settings(&f, &mut s, &c);
        assert_eq!((s.frame_cache_gb, s.audio_output_uid.as_deref()), (2, Some("b")));

        s.audio_output_uid = Some("gone".to_string());
        let mut missing = form(Page::Playback, &s, &x, &c, &d);
        assert_eq!(missing.index("audioOutput"), Some(3));
        missing.set("audioOutput", FormValue::Index(0));
        ShellPreferences::apply_settings(&missing, &mut s, &c);
        assert_eq!(s.audio_output_uid, None);
    }

    #[test]
    fn restore_factory_buttons_map_to_the_listed_entries() {
        assert_eq!(
            ShellPreferences::button_action("cacheFolder", 1, None),
            Some(ButtonAction::UseDefault(Folder::Cache))
        );
        assert_eq!(
            ShellPreferences::button_action("projectsFolder", 0, None),
            Some(ButtonAction::ChooseFolder(Folder::Projects))
        );
        assert_eq!(ShellPreferences::button_action("default.0", 0, None), None);
        assert_eq!(ShellPreferences::button_action("nothing", 0, None), None);
    }

    #[test]
    fn folder_buttons_save_the_folders_and_copy_the_proxies() {
        let mut d = ShellDefaults::default();
        let tmp = std::env::temp_dir().join(format!("sq-prefs-{}", std::process::id()));
        let mut s = AppSettings::load(&d);
        let none = |_: &Path, _: &Path| {};
        let note = ShellPreferences::set_folder(
            Folder::Scratch,
            Some(&tmp.join("Scratch")),
            &mut s,
            &mut d,
            sq_editor_session::ProxyMove::AtOnce(&none),
        );
        assert!(note.is_empty());
        assert_eq!(
            StorageLocations::load(&d).scratch_folder.as_deref().and_then(Path::file_name).and_then(|n| n.to_str()),
            Some("Scratch")
        );
        ShellPreferences::set_folder(
            Folder::Scratch,
            None,
            &mut s,
            &mut d,
            sq_editor_session::ProxyMove::AtOnce(&none),
        );
        assert_eq!(StorageLocations::load(&d).scratch_folder, None);

        let pair = std::cell::RefCell::new(None);
        let record = |a: &Path, b: &Path| *pair.borrow_mut() = Some((a.to_path_buf(), b.to_path_buf()));
        let note = ShellPreferences::set_folder(
            Folder::Cache,
            Some(&tmp.join("Cache")),
            &mut s,
            &mut d,
            sq_editor_session::ProxyMove::Background(&record),
        );
        assert_eq!(s.cache_folder.as_deref().and_then(Path::file_name).and_then(|n| n.to_str()), Some("Cache"));
        assert_eq!(
            AppSettings::load(&d).cache_folder.as_deref().and_then(Path::file_name).and_then(|n| n.to_str()),
            Some("Cache")
        );
        assert!(pair.borrow().as_ref().is_some_and(|(_, to)| to.starts_with(tmp.join("Cache"))));
        assert!(note.starts_with("Applies at the next launch"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Pushes one change of the open Settings window as the form does, and lets the flow save it.
    fn change(rig: &Rig, id: &str, v: FormValue) {
        rig.with(|r| {
            r.shell.form_changes.push((id.to_string(), v));
            if let Some(w) = r.shell.form_waker.take() {
                w.wake();
            }
        });
        rig.rt.run_until_stalled();
    }

    #[test]
    fn every_settings_control_saves_its_value_and_tells_the_app() {
        // One change per control of the pages General, Playback, Editing, Media: it reaches the store under its key and
        // `ShellEvent::SettingsChanged` carries it (the app applies what is live; the rest is read where it is used).
        let std = AppSettings::standard();
        type Check = fn(&AppSettings) -> bool;
        let table: Vec<(&str, FormValue, Check)> = vec![
            ("autosave", FormValue::Index(4), |s| s.autosave_interval == 900.0),
            ("recovery", FormValue::Bool(!std.offer_recovery), |s| {
                s.offer_recovery != AppSettings::standard().offer_recovery
            }),
            ("updates", FormValue::Bool(!std.check_for_updates), |s| {
                s.check_for_updates != AppSettings::standard().check_for_updates
            }),
            ("textLength", FormValue::Index(8), |s| s.default_text_seconds == 30),
            ("autoLanguage", FormValue::Bool(!std.caption_auto_language), |s| {
                s.caption_auto_language != AppSettings::standard().caption_auto_language
            }),
            ("background", FormValue::Bool(!std.background_work), |s| {
                s.background_work != AppSettings::standard().background_work
            }),
            ("preroll", FormValue::Index(8), |s| s.preroll_seconds == 10),
            ("postroll", FormValue::Index(0), |s| s.postroll_seconds == 0),
            ("scrubbing", FormValue::Bool(!std.audio_scrubbing), |s| {
                s.audio_scrubbing != AppSettings::standard().audio_scrubbing
            }),
            ("newSequence", FormValue::Index(1), |s| {
                s.new_sequence_edit_mode == sq_core_model::TimelineEditMode::Magnetic
            }),
            ("dropIndicator", FormValue::Bool(!std.drop_indicator), |s| {
                s.drop_indicator != AppSettings::standard().drop_indicator
            }),
            ("proxyExport", FormValue::Bool(!std.use_proxies_for_export), |s| {
                s.use_proxies_for_export != AppSettings::standard().use_proxies_for_export
            }),
        ];
        let d = ShellDefaults::default();
        let (s0, x0, c0) = (AppSettings::load(&d), Extras::load(&d), PreferencesHost::default());
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        for (id, value, check) in table {
            let page = Page::ALL
                .iter()
                .position(|p| {
                    let f = form(*p, &s0, &x0, &c0, &d);
                    f.index(id).is_some() || f.bool(id).is_some()
                })
                .unwrap_or_else(|| panic!("no page has the control {id}"));
            change(&rig, "page", FormValue::Index(page as i64));
            rig.with(|r| r.shell.take_events());
            type_into(&rig, id, value.clone());
            change(&rig, id, value);
            assert!(check(&rig.with(|r| AppSettings::load(&*r.shell.defaults))), "{id} is saved");
            let told = rig.with(|r| {
                r.shell.take_events().into_iter().find_map(|e| match e {
                    ShellEvent::SettingsChanged(s) => Some(s),
                    _ => None,
                })
            });
            assert!(told.is_some_and(|s| check(&s)), "{id} reaches the app");
        }
    }

    #[test]
    fn the_edit_api_switch_reaches_the_host_and_the_page_exists_only_with_one() {
        use crate::shell_edit_api::ShellEditApi;
        use std::cell::Cell;
        use std::rc::Rc;
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        assert!(rig.with(|r| r.shell.preferences.edit_api.is_none()), "no host API: no Advanced page");
        answer_swept(&rig, SQDialogResponse::FIRST);

        let on = Rc::new(Cell::new(false));
        let (read, write) = (Rc::clone(&on), Rc::clone(&on));
        rig.with(|r| {
            r.shell.flow_env.edit_api = Some(ShellEditApi::new(
                move || read.get(),
                move |v| write.set(v),
                || EditApiState::new("Not running", StatusTone::Idle),
            ));
        });
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        assert!(rig.with(|r| r.shell.preferences.edit_api.is_some()), "the host runs an Edit API: Advanced is there");
        change(&rig, "page", FormValue::Index(Page::Advanced.index()));
        type_into(&rig, "api", FormValue::Bool(true));
        change(&rig, "api", FormValue::Bool(true));
        assert!(on.get(), "the switch reached the host");
        assert_eq!(rig.with(|r| r.shell.preferences.edit_api.as_ref().map(|(b, _)| *b)), Some(true));
    }

    /// A server that starts after the switch: the open Advanced page shows the new line when the host reports it.
    #[test]
    fn a_state_change_of_the_edit_api_updates_the_open_advanced_page() {
        use crate::shell_edit_api::ShellEditApi;
        use std::cell::RefCell;
        use std::rc::Rc;
        let rig = Rig::new();
        let line = Rc::new(RefCell::new(EditApiState::new("Starting\u{2026}", StatusTone::Idle)));
        let read = Rc::clone(&line);
        rig.with(|r| {
            r.shell.flow_env.edit_api = Some(ShellEditApi::new(|| true, |_| {}, move || read.borrow().clone()));
        });
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        change(&rig, "page", FormValue::Index(Page::Advanced.index()));
        let shown =
            |rig: &Rig| rig.with(|r| r.shell.dialog().and_then(|d| d.form.as_ref()).and_then(|f| f.status_text("api")));
        assert_eq!(shown(&rig).as_deref(), Some("Starting\u{2026}"));
        *line.borrow_mut() = EditApiState::new("Listening on 127.0.0.1, port 19790", StatusTone::Ok);
        rig.with(|r| r.shell.edit_api_state_changed());
        assert_eq!(shown(&rig).as_deref(), Some("Listening on 127.0.0.1, port 19790"));
    }

    /// D7: `SQ_SHOT_SETTINGS_PAGE=5` is the Shortcuts page, which the editor draws (not a blank form page).
    #[test]
    fn the_shot_pose_picks_the_start_page() {
        let shortcuts = Page::Shortcuts.index().to_string();
        assert_eq!(ShellHost::start_page(Some(&shortcuts), None), Page::Shortcuts);
        assert_eq!(ShellHost::start_page(Some("zz"), Some(Page::Audio)), Page::Audio);
        assert_eq!(ShellHost::start_page(None, None), Page::General);
    }

    /// Windows bug: the Shortcuts sidebar row left the Settings dialog open (modal, never answered) under the editor, so
    /// the old page stayed and Done / Escape went to the stale dialog.
    #[test]
    fn the_shortcuts_row_closes_settings_and_shows_the_editor_that_escape_closes() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        assert!(rig.has_dialog());
        let _ = rig.with(|r| r.shell.take_frame_request());
        change(&rig, "page", FormValue::Index(Page::Shortcuts.index()));
        assert!(!rig.has_dialog(), "the Settings dialog is gone");
        assert!(rig.with(|r| r.shell.is_shortcuts_shown()), "the editor shows at once");
        assert!(rig.with(|r| r.shell.take_frame_request()), "the screen asks for a frame");
        rig.key(sq_draw::InputKey::Escape, sq_draw::InputModifiers::NONE);
        rig.rt.run_until_stalled();
        assert!(!rig.with(|r| r.shell.is_shortcuts_shown()), "Escape closes the editor");
        assert!(!rig.has_dialog());
        assert!(rig.with(|r| r.shell.take_frame_request()), "the screen asks for a frame after the close");
    }

    /// Keyboard Shortcuts… with Settings open jumps to the Shortcuts page (D3), no second window.
    #[test]
    fn the_shortcuts_command_with_settings_open_jumps_to_the_shortcuts_page() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        rig.execute(sq_uikit::editor_command::EditorCommand::KeyboardShortcuts);
        rig.rt.run_until_stalled();
        assert!(rig.with(|r| r.shell.is_shortcuts_shown()), "the Shortcuts page is up");
        assert!(!rig.has_dialog(), "Settings closed, not stacked");
    }

    /// The footer reads hint, Reset (raised), Done.
    #[test]
    fn the_settings_footer_follows_the_kit() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        rig.key(sq_draw::InputKey::Character('x'), sq_draw::InputModifiers::NONE); // lays the dialog out
        let (done, reset, ghost) = rig.with(|r| {
            let d = r.shell.dialog().expect("settings");
            (d.button_frames()[&0], d.button_frames()[&1], d.ghost_buttons.contains(&1))
        });
        assert!(!ghost, "Reset has the raised button look");
        assert!(reset.min_x() < done.min_x(), "Reset sits left of Done");
        assert!(reset.min_x() > 100.0, "the hint text comes first: {reset:?}");
    }

    fn scroll_of(rig: &Rig) -> (f64, bool) {
        rig.with(|r| r.shell.dialog().map(|d| (d.form_scroll(), d.form_scrolls())).unwrap_or((0.0, false)))
    }

    fn send(rig: &Rig, e: &sq_draw::InputEvent) {
        rig.cx(|h, cx| h.handle(cx, e, 1.0));
    }

    fn open_page(page: Page) -> Rig {
        let rig = Rig::new();
        rig.with(|r| r.shell.set_size(sq_uikit::controls_grid::CGSize::new(1100.0, 420.0)));
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        rig.cx(|h, cx| h.relayout_dialog(&cx.measure));
        change(&rig, "page", FormValue::Index(page.index()));
        rig.cx(|h, cx| h.relayout_dialog(&cx.measure));
        rig
    }

    /// Windows bug: long Settings pages (Playback, Editing) did not scroll.
    #[test]
    fn the_mouse_wheel_scrolls_a_long_settings_page() {
        let rig = open_page(Page::Editing);
        let (_, scrolls) = scroll_of(&rig);
        assert!(scrolls, "the Editing page is taller than the window");
        let wheel = sq_draw::InputEvent::Scroll {
            x: 700.0,
            y: 300.0,
            dx: 0.0,
            dy: -120.0,
            modifiers: sq_draw::InputModifiers::NONE,
        };
        send(&rig, &wheel);
        assert!(scroll_of(&rig).0 > 0.0, "the wheel moved the page");
    }

    /// The use pass found Reset to Defaults answering a click with nothing while every setting was at its factory value: it
    /// looks off then, takes no click, and turns on with the first change.
    #[test]
    fn reset_to_defaults_is_off_while_every_setting_is_at_its_factory_value() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        let enabled = |rig: &Rig| rig.with(|r| r.shell.dialog().is_some_and(|d| d.is_enabled(ShellHost::RESET_BUTTON)));
        assert!(!enabled(&rig), "nothing changed yet");
        let _ = rig.with(|r| r.shell.take_events());
        answer_swept(&rig, SQDialogResponse::SECOND);
        assert!(rig.has_dialog(), "a click on the off button leaves the window as it was");
        assert!(rig.with(|r| r.shell.take_events().is_empty()), "and tells the app nothing");
        type_into(&rig, "recovery", FormValue::Bool(false));
        rig.with(|r| {
            r.shell.form_changes.push(("recovery".to_string(), FormValue::Bool(false)));
            if let Some(w) = r.shell.form_waker.take() {
                w.wake();
            }
        });
        rig.rt.run_until_stalled();
        assert!(enabled(&rig), "a changed setting turns it on");
        answer_swept(&rig, SQDialogResponse::SECOND);
        assert!(!enabled(&rig), "after the reset it is off again");
    }

    /// Linux check part 5: Reset to Defaults wrote `sq.onboarding.seen` back to 0, so the Welcome tour returned and swallowed
    /// Ctrl+,. The first-run state is not a setting: Reset keeps it, restores every setting, and stays off while only it differs.
    #[test]
    fn reset_to_defaults_keeps_the_first_run_state() {
        let rig = Rig::new();
        rig.with(|r| {
            let s = AppSettings { onboarding_seen: true, ..AppSettings::standard() };
            s.save(&mut *r.shell.defaults);
            r.shell.start_flow(crate::ShellFlow::ShowPreferences);
        });
        rig.run_flows();
        let enabled = |rig: &Rig| rig.with(|r| r.shell.dialog().is_some_and(|d| d.is_enabled(ShellHost::RESET_BUTTON)));
        assert!(!enabled(&rig), "a seen tour alone is no change to reset");
        type_into(&rig, "recovery", FormValue::Bool(false));
        rig.with(|r| {
            r.shell.form_changes.push(("recovery".to_string(), FormValue::Bool(false)));
            if let Some(w) = r.shell.form_waker.take() {
                w.wake();
            }
        });
        rig.rt.run_until_stalled();
        assert!(enabled(&rig));
        let _ = rig.with(|r| r.shell.take_events());
        answer_swept(&rig, SQDialogResponse::SECOND);
        let after = rig.with(|r| AppSettings::load(&*r.shell.defaults));
        assert!(after.offer_recovery, "the setting is back at its factory value");
        assert!(after.onboarding_seen, "the Welcome tour stays seen");
        let told = rig.with(|r| {
            r.shell.take_events().into_iter().find_map(|e| match e {
                ShellEvent::SettingsChanged(s) => Some(s),
                _ => None,
            })
        });
        assert!(told.is_some_and(|s| s.onboarding_seen), "the app is told the settings as saved");
        assert!(!enabled(&rig), "after the reset it is off again");
    }

    #[test]
    fn the_window_saves_each_change_and_reset_goes_back_to_the_defaults() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::ShowPreferences));
        rig.run_flows();
        assert!(rig.has_dialog());
        // A change in the open form is saved at once and the app is told.
        type_into(&rig, "recovery", FormValue::Bool(false));
        rig.with(|r| {
            r.shell.form_changes.push(("recovery".to_string(), FormValue::Bool(false)));
            if let Some(w) = r.shell.form_waker.take() {
                w.wake();
            }
        });
        rig.rt.run_until_stalled();
        assert!(!rig.with(|r| AppSettings::load(&*r.shell.defaults).offer_recovery));
        assert!(rig.with(|r| r.shell.take_events().iter().any(|e| matches!(e, ShellEvent::SettingsChanged(_)))));
        // Reset to Defaults restores the factory values and the same window stays open, on the same page.
        let before = rig.with(|r| r.shell.dialog().map(|d| d as *const _ as usize));
        answer_swept(&rig, SQDialogResponse::SECOND);
        assert!(rig.with(|r| AppSettings::load(&*r.shell.defaults).offer_recovery));
        assert!(rig.has_dialog());
        assert_eq!(rig.with(|r| r.shell.dialog().map(|d| d as *const _ as usize)), before, "same dialog, not reopened");
        assert!(!rig.with(|r| r.shell.dialog().is_some_and(|d| d.finished())));
        answer_swept(&rig, SQDialogResponse::FIRST);
        assert!(!rig.has_dialog());
    }
}
