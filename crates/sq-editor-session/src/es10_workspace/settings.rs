//! The Settings window's preferences and the other app-wide defaults (media, audio, card import) with their keys.

use std::path::PathBuf;

use sq_core_model::{OutsideMediaMode, TimelineEditMode};
use sq_core_time::{Id, Time};
use sq_export::core::settings::EncoderSpeed;
use sq_uikit::appearance_palette::UiDefaults;

use super::defaults::DefaultsExt;
use super::storage::{StorageLocations, env_var};
use super::update::ReleaseChannel;
use crate::MonitorQuality;
use crate::es08_media::MediaPolicyDefaults;

fn encoder_speed_raw(s: EncoderSpeed) -> &'static str {
    match s {
        EncoderSpeed::Quality => "quality",
        EncoderSpeed::Balanced => "balanced",
        EncoderSpeed::Fast => "fast",
    }
}

fn encoder_speed_stored(raw: &str) -> Option<EncoderSpeed> {
    EncoderSpeed::ALL.into_iter().find(|s| encoder_speed_raw(*s) == raw)
}

fn edit_mode_raw(m: TimelineEditMode) -> &'static str {
    match m {
        TimelineEditMode::Normal => "normal",
        TimelineEditMode::Magnetic => "magnetic",
    }
}

fn edit_mode_stored(raw: &str) -> Option<TimelineEditMode> {
    [TimelineEditMode::Normal, TimelineEditMode::Magnetic].into_iter().find(|m| edit_mode_raw(*m) == raw)
}

/// Preferences of the Settings window, persisted in the settings store (Swift: UserDefaults). Every read validates,
/// so a hand-edited or stale value falls back to the default instead of reaching the app.
// Swift: AppSettings.swift:8
#[derive(Clone, Debug, PartialEq)]
pub struct AppSettings {
    // General
    // Swift: AppSettings.swift:11
    /// Seconds between autosaves of a changed project.
    pub autosave_interval: f64,
    // Swift: AppSettings.swift:13
    /// Offer to restore the last autosave after an unclean quit.
    pub offer_recovery: bool,
    // Swift: AppSettings.swift:15
    /// Ask the update address (`UpdateCheck::feed_url`) for a newer version at launch. Inert while that address is empty.
    pub check_for_updates: bool,
    /// Which stream the update check follows; new installs start on the channel they were built for.
    pub update_channel: ReleaseChannel,
    // Swift: AppSettings.swift:17
    /// The first-run welcome sheet was shown (or skipped); it never appears again.
    pub onboarding_seen: bool,
    // Playback
    // Swift: AppSettings.swift:19
    pub default_quality: MonitorQuality,
    // Swift: AppSettings.swift:22
    /// Seconds played before the marked range (Shift+Space) or the playhead (Shift+K Play Around). Premiere defaults:
    /// 3 s before, 2 s after (Preferences > Playback).
    pub preroll_seconds: i64,
    // Swift: AppSettings.swift:23
    /// Seconds played after the marked range or the playhead.
    pub postroll_seconds: i64,
    // Swift: AppSettings.swift:25
    /// Project panel Hover Scrub (Shift+H toggles).
    pub hover_scrub: bool,
    // Swift: AppSettings.swift:27
    /// Dropped-frame dot in the Program monitor.
    pub drop_indicator: bool,
    // Swift: AppSettings.swift:29
    /// Audio scrubbing (Shift+S): sound while dragging the playhead. Off by default; video scrubbing is always on.
    pub audio_scrubbing: bool,
    // Swift: AppSettings.swift:31
    /// Edit mode a new sequence starts in (`sq.newSequenceEditMode`): Normal, or Fast Cut (magnetic main track).
    pub new_sequence_edit_mode: TimelineEditMode,
    // Swift: AppSettings.swift:33
    /// Sequence > Selection Follows Playhead (`sq.selectionFollowsPlayhead`), off by default.
    pub selection_follows_playhead: bool,
    /// Preview quality Auto: the monitors start at the size `memory_budget::auto_start_scale` picks for this
    /// machine and drop lower under memory pressure. Off = start at `default_quality` and stay there.
    // Swift: AppSettings.swift:36
    pub preview_quality_auto: bool,
    /// Frame cache of both monitors in GB; 0 = Auto (scaled to the machine's RAM, `MemoryBudget`).
    // Swift: AppSettings.swift:38
    pub frame_cache_gb: i64,
    /// Background work (proxy generation while editing). Off = only on request.
    // Swift: AppSettings.swift:40
    pub background_work: bool,
    /// Preview render cache: heavy stretches of the timeline are rendered to disk while idle and played from there.
    // Swift: AppSettings.swift:42
    pub render_cache: bool,
    /// Disk the render cache may use, in GB (`RENDER_CACHE_CAP_CHOICES`).
    // Swift: AppSettings.swift:44
    pub render_cache_cap_gb: i64,
    /// H.264 / HEVC encoder speed of every export on this machine. Quality by default; small machines only get a
    /// suggestion in the Export dialog (`EncoderSpeed::suggested`), never a silent change.
    // Swift: AppSettings.swift:48
    pub export_encoder_speed: EncoderSpeed,
    /// Audio device id; `None` = system default output.
    // Swift: AppSettings.swift:50
    pub audio_output_uid: Option<String>,
    // Media
    /// Folder for proxies and render cache; `None` = the default folder.
    // Swift: AppSettings.swift:53
    pub cache_folder: Option<PathBuf>,
    /// Cache size cap in gigabytes.
    // Swift: AppSettings.swift:55
    pub cache_cap_gb: i64,
    /// Look for project media that is still growing (a recording in progress) or was re-rendered, and refresh its
    /// length, thumbnails and waveform (`sq.media.refreshGrowing`). Off = only when the app comes to the front.
    // Swift: AppSettings.swift:58
    pub refresh_growing_files: bool,
    /// Global "use proxies for export" (`sq.proxy.export`): the render reads ready proxies instead of the originals.
    // Swift: AppSettings.swift:61
    pub use_proxies_for_export: bool,
    // Text
    /// Length of a new text layer and of a caption added by hand, in seconds (Premiere: 5 s for a title).
    // Swift: AppSettings.swift:64
    pub default_text_seconds: i64,
    /// Default TRANSCRIPTION language (BCP-47) of the Captions panel; a project may override it.
    // Swift: AppSettings.swift:66
    pub caption_language: String,
    /// After a transcription, switch to the language the text is in and run it again (`CaptionLanguageGuess`).
    // Swift: AppSettings.swift:68
    pub caption_auto_language: bool,
}

/// The keys `AppSettings` and its neighbours store under.
// Swift: AppSettings.swift:143
pub enum AppSettingsKey {}

impl AppSettingsKey {
    pub const AUTOSAVE: &'static str = "settings.autosaveInterval";
    pub const RECOVERY: &'static str = "settings.offerRecovery";
    // Swift: AppSettings.swift:144
    pub const QUALITY: &'static str = "settings.defaultQuality";
    // Swift: AppSettings.swift:145
    pub const AUDIO: &'static str = "settings.audioOutputUID";
    // Swift: AppSettings.swift:146
    pub const CACHE: &'static str = "settings.cacheFolder";
    // Swift: AppSettings.swift:147
    pub const CAP: &'static str = "settings.cacheCapGB";
    pub const PREROLL: &'static str = "settings.prerollSeconds";
    pub const POSTROLL: &'static str = "settings.postrollSeconds";
    // Swift: AppSettings.swift:150
    pub const HOVER_SCRUB: &'static str = "settings.hoverScrub";
    pub const DROP_INDICATOR: &'static str = "sq.playback.dropIndicator";
    pub const TEXT_SECONDS: &'static str = "settings.defaultTextSeconds";
    /// The key the Shift+S toggle has always written.
    pub const AUDIO_SCRUBBING: &'static str = "sq.audioScrubbing";
    /// Retired: Delete follows the sequence mode. The stored value is ignored and removed on save.
    pub const RETIRED_RIPPLE_DELETE: &'static str = "sq.delete.ripple";
    pub const NEW_SEQUENCE_EDIT_MODE: &'static str = "sq.newSequenceEditMode";
    pub const SELECTION_FOLLOWS: &'static str = "sq.selectionFollowsPlayhead";
    // Swift: AppSettings.swift:158
    pub const CAPTION_LANGUAGE: &'static str = "sq.captions.language";
    pub const CAPTION_AUTO_LANGUAGE: &'static str = "sq.captions.autoLanguage";
    pub const PROJECT_LANGUAGE_PREFIX: &'static str = "sq.captions.language.";
    pub const QUALITY_AUTO: &'static str = "sq.playback.previewQualityAuto";
    pub const FRAME_CACHE: &'static str = "sq.playback.frameCacheGB";
    pub const BACKGROUND_WORK: &'static str = "sq.playback.backgroundWork";
    pub const RENDER_CACHE: &'static str = "sq.playback.renderCache";
    pub const RENDER_CACHE_CAP: &'static str = "sq.playback.renderCacheCapGB";
    // Swift: AppSettings.swift:166
    pub const ENCODER_SPEED: &'static str = "sq.export.encoderSpeed";
    // Swift: AppSettings.swift:167
    pub const CHECK_FOR_UPDATES: &'static str = "sq.updates.check";
    pub const UPDATE_CHANNEL: &'static str = "sq.updates.channel";
    // Swift: AppSettings.swift:168
    pub const ONBOARDING_SEEN: &'static str = "sq.onboarding.seen";
    // Swift: AppSettings.swift:169
    pub const REFRESH_GROWING: &'static str = "sq.media.refreshGrowing";
    // Swift: AppSettings.swift:170
    pub const PROXIES_FOR_EXPORT: &'static str = "sq.proxy.export";
}

impl Default for AppSettings {
    fn default() -> AppSettings {
        AppSettings::standard()
    }
}

impl AppSettings {
    // Swift: AppSettings.swift:45
    pub const RENDER_CACHE_CAP_CHOICES: [i64; 5] = [2, 5, 10, 20, 50];
    // Swift: AppSettings.swift:72
    pub const SUPPORTED_CAPTION_LANGUAGES: [&'static str; 6] = ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"];
    // Swift: AppSettings.swift:86
    pub const TEXT_DURATION_CHOICES: [i64; 9] = [1, 2, 3, 4, 5, 8, 10, 15, 30];
    // Swift: AppSettings.swift:87
    pub const AUTOSAVE_CHOICES: [f64; 5] = [60.0, 120.0, 300.0, 600.0, 900.0];
    // Swift: AppSettings.swift:89
    pub const CACHE_CAP_CHOICES: [i64; 5] = [10, 20, 50, 100, 250];
    // Swift: AppSettings.swift:90
    pub const ROLL_CHOICES: [i64; 9] = [0, 1, 2, 3, 4, 5, 6, 8, 10];

    /// Factory default: the system language mapped to a supported transcription language (English if unsupported).
    // Swift: AppSettings.swift:70
    pub fn default_caption_language() -> String {
        let preferred: Vec<String> = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .filter_map(|k| env_var(k))
            .filter(|v| !v.is_empty())
            .map(|v| v.split(['.', '@']).next().unwrap_or("").to_string())
            .collect();
        Self::derived_caption_language(&preferred, &Self::SUPPORTED_CAPTION_LANGUAGES)
    }

    /// First preferred language that has a supported transcription language (exact region first, else the same
    /// language in any region); "en-US" when none matches.
    // Swift: AppSettings.swift:76
    pub fn derived_caption_language(preferred: &[String], supported: &[&str]) -> String {
        for p in preferred {
            let id = p.replace('_', "-");
            if let Some(exact) = supported.iter().find(|s| s.eq_ignore_ascii_case(&id)) {
                return (*exact).to_string();
            }
            let code = id.split('-').next().unwrap_or("").to_lowercase();
            if let Some(same) = supported.iter().find(|s| s.split('-').next().unwrap_or("").to_lowercase() == code) {
                return (*same).to_string();
            }
        }
        "en-US".to_string()
    }

    /// A quality picked by hand in a monitor: fixed from now on, remembered across projects.
    // Swift: AppSettings.swift:93
    pub fn choosing_fixed_quality(&self, q: MonitorQuality) -> AppSettings {
        let mut s = self.clone();
        s.preview_quality_auto = false;
        s.default_quality = q;
        s
    }

    /// Monitor quality at launch / project open.
    // Swift: AppSettings.swift:101
    pub fn start_quality(&self, auto: MonitorQuality) -> MonitorQuality {
        if self.preview_quality_auto { auto } else { self.default_quality }
    }

    // Swift: AppSettings.swift:102
    pub fn preroll(&self) -> Time {
        Time::seconds(self.preroll_seconds)
    }

    // Swift: AppSettings.swift:104
    pub fn postroll(&self) -> Time {
        Time::seconds(self.postroll_seconds)
    }

    // Swift: AppSettings.swift:105
    pub fn standard() -> AppSettings {
        AppSettings::new(300.0, true, MonitorQuality::Full, None, None, 50)
    }

    // Swift: AppSettings.swift:107
    pub fn new(
        autosave_interval: f64,
        offer_recovery: bool,
        default_quality: MonitorQuality,
        audio_output_uid: Option<String>,
        cache_folder: Option<PathBuf>,
        cache_cap_gb: i64,
    ) -> AppSettings {
        AppSettings {
            autosave_interval,
            offer_recovery,
            check_for_updates: true,
            update_channel: ReleaseChannel::build(),
            onboarding_seen: false,
            default_quality,
            preroll_seconds: 3,
            postroll_seconds: 2,
            hover_scrub: true,
            drop_indicator: true,
            audio_scrubbing: false,
            new_sequence_edit_mode: TimelineEditMode::Normal,
            selection_follows_playhead: false,
            preview_quality_auto: true,
            frame_cache_gb: 0,
            background_work: true,
            render_cache: true,
            render_cache_cap_gb: 10,
            export_encoder_speed: EncoderSpeed::Quality,
            audio_output_uid,
            cache_folder,
            cache_cap_gb,
            refresh_growing_files: true,
            use_proxies_for_export: false,
            default_text_seconds: 5,
            caption_language: Self::default_caption_language(),
            caption_auto_language: true,
        }
    }

    /// Default cache folder: `<caches>/Sequence Studio` (the Mac: ~/Library/Caches).
    // Swift: AppSettings.swift:116
    pub fn default_cache_folder() -> PathBuf {
        super::storage::caches_directory().join("Sequence Studio")
    }

    // Swift: AppSettings.swift:120
    pub fn effective_cache_folder(&self) -> PathBuf {
        self.cache_folder.clone().unwrap_or_else(Self::default_cache_folder)
    }

    /// Where the proxy cache lives: the default location until the user picks a folder, then `<folder>/Proxies`.
    /// Read at launch; a folder change applies at the next launch (the old cache stays where it was).
    // Swift: AppSettings.swift:125
    pub fn proxy_cache_directory(&self, defaults: &dyn UiDefaults) -> PathBuf {
        self.locations(defaults).proxy_directory()
    }

    /// Cache, scratch and projects roots (scratch and projects picks live in their own `sq.storage.*` keys).
    // Swift: AppSettings.swift:130
    // Swift: AppSettings.swift:131
    pub fn locations(&self, defaults: &dyn UiDefaults) -> StorageLocations {
        let mut l = StorageLocations::load(defaults);
        l.cache_folder = self.cache_folder.clone();
        l
    }

    /// The cache size cap in bytes (decimal gigabytes, like the 50 GB default of `ProxySettings`).
    // Swift: AppSettings.swift:139
    pub fn cache_cap_bytes(&self) -> i64 {
        self.cache_cap_gb.max(1) * 1_000_000_000
    }

    /// Reads and validates every setting.
    // Swift: AppSettings.swift:172
    pub fn load(d: &dyn UiDefaults) -> AppSettings {
        use AppSettingsKey as K;
        let mut s = AppSettings::standard();
        if let Some(v) = d.number(K::AUTOSAVE).filter(|v| v.is_finite() && (30.0..=3600.0).contains(v)) {
            s.autosave_interval = v;
        }
        if let Some(v) = d.flag(K::RECOVERY) {
            s.offer_recovery = v;
        }
        let stored_quality = d.string(K::QUALITY).and_then(|q| MonitorQuality::stored(&q));
        if let Some(q) = stored_quality {
            s.default_quality = q;
        }
        // A 1/2 or 1/4 remembered before Auto existed stays fixed; a stored "full" was written by every save of older
        // builds (the default, not a choice), so it means Auto.
        s.preview_quality_auto = d
            .flag(K::QUALITY_AUTO)
            .unwrap_or_else(|| stored_quality.unwrap_or(MonitorQuality::Full) == MonitorQuality::Full);
        let ranged = |key: &str, range: std::ops::RangeInclusive<i64>| d.integer(key).filter(|v| range.contains(v));
        if let Some(v) = ranged(K::FRAME_CACHE, 0..=1024) {
            s.frame_cache_gb = v;
        }
        if let Some(v) = d.flag(K::BACKGROUND_WORK) {
            s.background_work = v;
        }
        if let Some(v) = d.flag(K::RENDER_CACHE) {
            s.render_cache = v;
        }
        if let Some(v) = ranged(K::RENDER_CACHE_CAP, 1..=1000) {
            s.render_cache_cap_gb = v;
        }
        if let Some(v) = d.flag(K::CHECK_FOR_UPDATES) {
            s.check_for_updates = v;
        }
        if let Some(v) = d.string(K::UPDATE_CHANNEL) {
            s.update_channel = ReleaseChannel::from_raw(Some(&v));
        }
        s.onboarding_seen = d.bool_value(K::ONBOARDING_SEEN);
        if let Some(v) = d.flag(K::REFRESH_GROWING) {
            s.refresh_growing_files = v;
        }
        s.use_proxies_for_export = d.bool_value(K::PROXIES_FOR_EXPORT);
        if let Some(v) = d.string(K::ENCODER_SPEED).and_then(|v| encoder_speed_stored(&v)) {
            s.export_encoder_speed = v;
        }
        if let Some(u) = d.string(K::AUDIO).filter(|u| !u.is_empty()) {
            s.audio_output_uid = Some(u);
        }
        if let Some(p) = d.string(K::CACHE).filter(|p| StorageLocations::is_absolute_path(p)) {
            s.cache_folder = Some(PathBuf::from(p));
        }
        if let Some(v) = ranged(K::CAP, 1..=10_000) {
            s.cache_cap_gb = v;
        }
        if let Some(v) = ranged(K::PREROLL, 0..=60) {
            s.preroll_seconds = v;
        }
        if let Some(v) = ranged(K::POSTROLL, 0..=60) {
            s.postroll_seconds = v;
        }
        if let Some(v) = d.flag(K::HOVER_SCRUB) {
            s.hover_scrub = v;
        }
        if let Some(v) = d.flag(K::DROP_INDICATOR) {
            s.drop_indicator = v;
        }
        if let Some(v) = d.flag(K::AUDIO_SCRUBBING) {
            s.audio_scrubbing = v;
        }
        if let Some(m) = d.string(K::NEW_SEQUENCE_EDIT_MODE).and_then(|m| edit_mode_stored(&m)) {
            s.new_sequence_edit_mode = m;
        }
        if let Some(v) = d.flag(K::SELECTION_FOLLOWS) {
            s.selection_follows_playhead = v;
        }
        if let Some(l) = d.string(K::CAPTION_LANGUAGE).filter(|l| Self::is_valid_language(l)) {
            s.caption_language = l;
        }
        if let Some(v) = d.flag(K::CAPTION_AUTO_LANGUAGE) {
            s.caption_auto_language = v;
        }
        if let Some(v) = ranged(K::TEXT_SECONDS, 1..=600) {
            s.default_text_seconds = v;
        }
        s
    }

    /// Writes every setting. The app's store flushes to disk itself (Swift called `synchronize()` here).
    // Swift: AppSettings.swift:216
    pub fn save(&self, d: &mut dyn UiDefaults) {
        use AppSettingsKey as K;
        d.set_number(K::AUTOSAVE, self.autosave_interval);
        d.set_flag(K::RECOVERY, self.offer_recovery);
        // Only a fixed choice is stored; Auto leaves no quality behind.
        if self.preview_quality_auto {
            d.remove(K::QUALITY);
        } else {
            d.set_string(K::QUALITY, self.default_quality.raw_value());
        }
        match &self.audio_output_uid {
            Some(uid) => d.set_string(K::AUDIO, uid),
            None => d.remove(K::AUDIO),
        }
        match &self.cache_folder {
            Some(folder) => d.set_string(K::CACHE, &folder.to_string_lossy()),
            None => d.remove(K::CACHE),
        }
        d.set_integer(K::CAP, self.cache_cap_gb);
        d.set_integer(K::PREROLL, self.preroll_seconds);
        d.set_integer(K::POSTROLL, self.postroll_seconds);
        d.set_flag(K::HOVER_SCRUB, self.hover_scrub);
        d.set_flag(K::DROP_INDICATOR, self.drop_indicator);
        d.set_integer(K::TEXT_SECONDS, self.default_text_seconds);
        d.set_flag(K::AUDIO_SCRUBBING, self.audio_scrubbing);
        d.remove(K::RETIRED_RIPPLE_DELETE);
        d.set_string(K::NEW_SEQUENCE_EDIT_MODE, edit_mode_raw(self.new_sequence_edit_mode));
        d.set_flag(K::SELECTION_FOLLOWS, self.selection_follows_playhead);
        d.set_string(K::CAPTION_LANGUAGE, &self.caption_language);
        d.set_flag(K::CAPTION_AUTO_LANGUAGE, self.caption_auto_language);
        d.set_flag(K::QUALITY_AUTO, self.preview_quality_auto);
        d.set_integer(K::FRAME_CACHE, self.frame_cache_gb);
        d.set_flag(K::BACKGROUND_WORK, self.background_work);
        d.set_flag(K::RENDER_CACHE, self.render_cache);
        d.set_integer(K::RENDER_CACHE_CAP, self.render_cache_cap_gb);
        d.set_string(K::ENCODER_SPEED, encoder_speed_raw(self.export_encoder_speed));
        d.set_flag(K::CHECK_FOR_UPDATES, self.check_for_updates);
        d.set_string(K::UPDATE_CHANNEL, self.update_channel.raw());
        d.set_flag(K::ONBOARDING_SEEN, self.onboarding_seen);
        d.set_flag(K::REFRESH_GROWING, self.refresh_growing_files);
        d.set_flag(K::PROXIES_FOR_EXPORT, self.use_proxies_for_export);
    }

    /// A BCP-47 identifier as the language list uses it ("de-DE"): letters and hyphens, 2 to 12 characters.
    pub fn is_valid_language(l: &str) -> bool {
        (2..=12).contains(&l.chars().count()) && l.chars().all(|c| c.is_alphabetic() || c == '-')
    }

    /// Transcription language of one project: its override when set, else the default from Settings.
    // Swift: AppSettings.swift:255
    pub fn caption_language_for_project(id: Id, d: &dyn UiDefaults) -> String {
        match d.string(&format!("{}{id}", AppSettingsKey::PROJECT_LANGUAGE_PREFIX)) {
            Some(l) if Self::is_valid_language(&l) => l,
            _ => Self::load(d).caption_language,
        }
    }

    /// Stores (or with `None` removes) the per-project override.
    // Swift: AppSettings.swift:261
    pub fn set_caption_language_for_project(l: Option<&str>, id: Id, d: &mut dyn UiDefaults) {
        let key = format!("{}{id}", AppSettingsKey::PROJECT_LANGUAGE_PREFIX);
        match l {
            Some(l) if Self::is_valid_language(l) => d.set_string(&key, l),
            _ => d.remove(&key),
        }
    }
}

// MARK: - Media, audio and card import

/// App-wide media management defaults (Preferences > Media: Outside Files, Project Folder, Library). A project's own
/// `MediaPolicy` overrides them. Shared by every shell (one store).
// Swift: MediaPreferences.swift:5
pub enum MediaSettings {}

impl MediaSettings {
    // Swift: MediaPreferences.swift:7
    pub const OUTSIDE_KEY: &'static str = "sq.media.outside";
    // Swift: MediaPreferences.swift:8
    pub const LIBRARY_KEY: &'static str = "sq.media.copyLibraryItems";
    // Swift: MediaPreferences.swift:9
    pub const WATCH_KEY: &'static str = "sq.media.watchProjectFolder";

    fn outside_raw(m: OutsideMediaMode) -> &'static str {
        match m {
            OutsideMediaMode::Ask => "ask",
            OutsideMediaMode::Copy => "copy",
            OutsideMediaMode::Move => "move",
            OutsideMediaMode::Leave => "leave",
        }
    }

    /// The stored defaults (Swift `MediaSettings.defaults` getter on the standard store).
    // Swift: MediaPreferences.swift:10
    // Swift: MediaPreferences.swift:15
    pub fn load(d: &dyn UiDefaults) -> MediaPolicyDefaults {
        let outside = d
            .string(Self::OUTSIDE_KEY)
            .and_then(|s| {
                [OutsideMediaMode::Ask, OutsideMediaMode::Copy, OutsideMediaMode::Move, OutsideMediaMode::Leave]
                    .into_iter()
                    .find(|m| Self::outside_raw(*m) == s)
            })
            .unwrap_or(OutsideMediaMode::Ask);
        MediaPolicyDefaults {
            outside,
            copy_library_items: d.bool_or(Self::LIBRARY_KEY, true),
            watch_folder: d.bool_or(Self::WATCH_KEY, true),
        }
    }

    // Swift: MediaPreferences.swift:22
    pub fn store(v: MediaPolicyDefaults, d: &mut dyn UiDefaults) {
        d.set_string(Self::OUTSIDE_KEY, Self::outside_raw(v.outside));
        d.set_flag(Self::LIBRARY_KEY, v.copy_library_items);
        d.set_flag(Self::WATCH_KEY, v.watch_folder);
    }
}

/// Preference: open the import window when an SD card or external drive mounts. Default on.
// Swift: MediaPreferences.swift:30
pub enum CardImportSettings {}

impl CardImportSettings {
    // Swift: MediaPreferences.swift:32
    pub const KEY: &'static str = "sq.autoImportFromCards";

    // Swift: MediaPreferences.swift:33
    // Swift: MediaPreferences.swift:38
    pub fn is_enabled(d: &dyn UiDefaults) -> bool {
        d.bool_or(Self::KEY, true)
    }

    // Swift: MediaPreferences.swift:40
    pub fn set_enabled(on: bool, d: &mut dyn UiDefaults) {
        d.set_flag(Self::KEY, on);
    }
}

/// Preferences > Audio > De-Click for shells that do not link the audio effects themselves.
// Swift: AudioPreferences.swift:4
pub enum AudioPreferences {}

impl AudioPreferences {
    /// The stored setting; absent means on.
    // Swift: AudioPreferences.swift:7
    pub fn de_click(d: &dyn UiDefaults) -> bool {
        d.bool_or(sq_audiofx::de_click::AudioDeClick::DEFAULTS_KEY, true)
    }

    // Swift: AudioPreferences.swift:8
    pub fn set_de_click(on: bool, d: &mut dyn UiDefaults) {
        d.set_flag(sq_audiofx::de_click::AudioDeClick::DEFAULTS_KEY, on);
    }
}

/// One-time migration of settings keys written by older builds (`ss.*`) to their `sq.*` names.
// Swift: DefaultsMigration.swift:4
pub enum DefaultsMigration {}

impl DefaultsMigration {
    // Swift: DefaultsMigration.swift:5
    pub const LEGACY_PREFIX: &'static str = "ss.";
    // Swift: DefaultsMigration.swift:6
    pub const PREFIX: &'static str = "sq.";

    /// Moves every `ss.<rest>` value to `sq.<rest>` (an existing `sq.` value wins) and removes the old key. `keys`
    /// lists the keys the store holds. Returns the number of keys migrated. Cheap and idempotent, so it may run at
    /// every launch.
    // Swift: DefaultsMigration.swift:10
    pub fn migrate_legacy_keys(d: &mut dyn UiDefaults, keys: &[String]) -> usize {
        let mut n = 0;
        for key in keys.iter().filter(|k| k.starts_with(Self::LEGACY_PREFIX)) {
            let new = format!("{}{}", Self::PREFIX, &key[Self::LEGACY_PREFIX.len()..]);
            if !d.has(&new) {
                if let Some(v) = d.string(key) {
                    d.set_string(&new, &v);
                } else if let Some(v) = d.integer(key) {
                    d.set_integer(&new, v);
                } else if let Some(v) = d.string_array(key) {
                    d.set_string_array(&new, &v);
                } else if let Some(v) = d.data(key) {
                    d.set_data(&new, &v);
                }
            }
            d.remove(key);
            n += 1;
        }
        n
    }
}
