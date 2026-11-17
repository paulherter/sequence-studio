// Swift: ShellHost.swift (the members the flow files read: `startDefaults`, `files`, `probe`, `waveform`, `clipPeak`,
// `startTimecode`, `projectModel`, `projectList`, `voiceover`, `runAnonymize`, `editAPI`, `relinkOffer`, `importRunning`,
// `silencePreview`)
//! What the flow and dialog files of the shell need from the app besides the session and the file choosers.
//!
//! Swift's `ShellHost` held closures and references to the Project panel's model, the Project list, the waveform cache and
//! the media probe. Here they sit behind one trait, [`ShellServices`], that the app implements (every method has a "not
//! provided" default), next to the stored settings. Work the platform does on a worker answers through a
//! [`ModalAsk`] like the file choosers do; an outer `None` says the platform has no such service.

use crate::library_imports::MogrtRead;
use crate::shell_background_offers::ShellRelinkOffer;
use crate::shell_card_browser::CardPoster;
use crate::shell_edit_api::ShellEditApi;
use crate::shell_flows::ShellRoot;
use crate::shell_host::{SettingValue, ShellEvent, ShellHost};
use crate::shell_loudness::LoudnessState;
use sq_core_audio::live_ducking::DefaultsStore;
use sq_core_masks::anonymize::AnonymizePerson;
use sq_core_model::{Clip, MediaRef, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::{
    AnalysisFlows, AnalysisLauncher, AnonymizeCheckLine, AnonymizeChoice, EditorSession, LookStore, VoiceRecorderState,
    VoiceRecordingStep, VoiceRecordingTake,
};
use sq_export::core::error::CancelToken;
use sq_library::library_folder_store::{MemorySettings, SettingsStore};
use sq_library::preset_store::PresetStore;
use sq_media::waveform_data::WaveformData;
use sq_runtime::{ModalAsk, UiRef, WorkerPool};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

/// Why a voice could not be rendered (`ShellVoiceoverError`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellVoiceoverError {
    /// The voice made no sound.
    NoAudio,
    /// Any other failure.
    Failed,
}

/// A loudness measurement that runs on a worker: sequence, range, cancel token.
pub type LoudnessMeasurer = Arc<dyn Fn(&Timeline, TimeRange, &CancelToken) -> Option<f64> + Send + Sync>;

/// A host's waveform cache as a lookup by media id.
pub type WaveformLookup = std::rc::Rc<dyn Fn(Id) -> Option<Arc<WaveformData>>>;

/// Reads one media file for the probe flows (Reconnect, Replace, project imports): `None` = could not be read.
pub type MediaProbe = Arc<dyn Fn(&Path) -> Option<MediaRef> + Send + Sync>;

/// The services the shell flows ask the app for. Every method has a default that provides nothing.
pub trait ShellServices {
    /// The shared worker pool for blocking work (copying files); `None` = the app has none.
    fn worker_pool(&self) -> Option<Arc<WorkerPool>> {
        None
    }

    // MARK: Project panel (the app owns the model and the list)

    /// `projectModel.mediaID(forImported:)`.
    fn imported_media_id(&self, _url: &Path) -> Option<Id> {
        None
    }

    // MARK: Media

    /// The platform's media probe (`probe`, `MediaImporter` on the Mac, the FFmpeg probe on Windows): `None` = no probe,
    /// the answer `None` = the file could not be read.
    fn probe(&mut self, _url: &Path) -> Option<ModalAsk<Option<MediaRef>>> {
        None
    }
    /// Hands the services the app's media probe (the FFmpeg probe); services without a worker for it ignore it.
    fn attach_probe(&mut self, _probe: MediaProbe) {}
    /// Hands the host's waveform cache to the services (the app owns it; the shell tools read it through `waveform`).
    fn attach_waveforms(&mut self, _lookup: WaveformLookup) {}
    /// The host's waveform cache (`waveform`).
    fn waveform(&self, _media: Id) -> Option<Arc<WaveformData>> {
        None
    }
    /// The host's own linear peak of a clip's source range (`clipPeak`).
    fn clip_peak(&self, _clip: &Clip) -> Option<f64> {
        None
    }
    /// The host's start timecode reader (`startTimecode`, AVFoundation on the Mac); `None` = no reader.
    fn start_timecode(&mut self, _media: &MediaRef) -> Option<ModalAsk<Option<Time>>> {
        None
    }

    // MARK: Analysis

    /// Runs on every pump of the app: reads the messages of the analysis workers and routes them to the flows.
    fn pump(&mut self, _session: &mut EditorSession) {}
    /// Runs `wake` on a worker thread when an analysis job has news (the app posts a redraw to its inbox).
    fn set_wake(&mut self, _wake: Arc<dyn Fn() + Send + Sync>) {}
    /// The analysis flows (Find Scene Changes, Auto Reframe, Stabilize) with the worker launcher; `None` = no analysis.
    fn analysis(&mut self) -> Option<(&mut AnalysisFlows, &mut dyn AnalysisLauncher)> {
        None
    }
    /// Clip > Video Options > Anonymize: starts the people finder (`AnonymizeFlow.request`), or cancels the running one;
    /// false = this build has none.
    fn run_anonymize(&mut self, _session: &mut EditorSession) -> bool {
        false
    }
    /// An Anonymize search or run is going (the command then reads "Cancel Anonymize").
    fn anonymize_running(&self) -> bool {
        false
    }
    /// The answer of the Anonymize sheet (`None` = canceled): starts following the chosen people.
    fn anonymize_answer(&mut self, _session: &mut EditorSession, _choice: Option<AnonymizeChoice>) {}
    /// What the Anonymize flow wants the shell to show since the last call (the Swift `AnonymizeUI` closures).
    fn take_anonymize_events(&mut self) -> Vec<AnonymizeEvent> {
        Vec::new()
    }
    /// Match Color to Clip started run `run`: the services end it after the flows' timeout.
    fn color_match_started(&mut self, _run: i64) {}
    /// The analysis flows for the menu rules (`analysis.isFindingSceneChanges` ...).
    fn analysis_flows(&self) -> Option<&AnalysisFlows> {
        None
    }

    // MARK: Loudness, titles, imports, presets

    /// Measures the integrated loudness (LUFS) of a one-track sequence over a range, `None` for silence or a failure.
    /// The shell runs it on the worker pool; `media` and `sequences` (the nested ones) are the project's lists, which
    /// the mix needs. `None` = the app cannot measure.
    fn loudness_measurer(&self, _media: Vec<MediaRef>, _sequences: Vec<Timeline>) -> Option<LoudnessMeasurer> {
        None
    }
    /// The Looks Add Title styles with.
    fn look_store(&self) -> Option<&LookStore> {
        None
    }
    /// The user preset library (`presetStore`).
    fn preset_store(&mut self) -> Option<&mut PresetStore> {
        None
    }
    /// Reads one `.mogrt` into a title template (Swift `MogrtImporter.read`).
    fn read_mogrt(&mut self, _url: &Path) -> Result<MogrtRead, String> {
        Err("Motion Graphics Templates cannot be read in this build.".to_string())
    }
    /// Whether a waveform cache exists at all (`waveform != nil`): without one, waiting for waveforms ends at once.
    fn has_waveforms(&self) -> bool {
        false
    }

    // MARK: Voice-over

    /// The voices of the platform's speech engine as (id, title); `None` = no engine.
    fn voices(&self) -> Option<Vec<(String, String)>> {
        None
    }
    /// Speaks `text` into the file at `url` and answers its length (`voiceover.render`).
    fn render_voiceover(
        &mut self,
        _text: &str,
        _voice_id: &str,
        _rate: f64,
        _url: &Path,
    ) -> Option<ModalAsk<Result<Time, ShellVoiceoverError>>> {
        None
    }
    /// Where voiceovers and recorded takes are written (the Mac `Sequence Studio/Voiceovers` in Application Support).
    // The default is the temp folder; the app's flow environment returns its own voiceover folder (`analysis_services`).
    fn voiceover_folder(&self) -> PathBuf {
        std::env::temp_dir().join("Sequence Studio/Voiceovers")
    }
    /// The microphone's state; `None` = no recorder.
    fn voice_recorder_state(&self) -> Option<VoiceRecorderState> {
        None
    }
    /// Seconds left of the countdown while the recorder counts down (3, 2, 1); `None` otherwise.
    fn voice_countdown_left(&self) -> Option<u32> {
        None
    }
    /// Why the last take could not start (the microphone did not open), once; `None` otherwise.
    fn voice_take_failure(&mut self) -> Option<String> {
        None
    }
    /// Record Voice-Over from idle or during the countdown: `EditorSession::toggle_voice_recording` with the app's
    /// recorder (a stop is `stop_voice_take`, the shell imports the take itself); `None` = no recorder.
    fn toggle_voice_recording(&mut self, _session: &mut EditorSession, _folder: &Path) -> Option<VoiceRecordingStep> {
        None
    }
    /// Ends a running take: `EditorSession::stop_voice_take` with the app's recorder; `None` = no recorder.
    fn stop_voice_take(
        &mut self,
        _session: &mut EditorSession,
    ) -> Option<Result<VoiceRecordingTake, VoiceRecordingStep>> {
        None
    }
}

/// A host without services: every method answers "not provided".
pub struct NoServices;

impl ShellServices for NoServices {}

/// The flow files' state and services, one field of `ShellHost`.
pub struct FlowEnv {
    /// The app's services.
    pub services: Box<dyn ShellServices>,
    /// `startDefaults`: the stored settings the dialogs remember their choices in. The app loads and saves it.
    pub settings: Box<dyn SettingsStore>,
    /// The Edit API the Advanced page of Preferences shows.
    pub edit_api: Option<ShellEditApi>,
    /// The relink chip of the status bar.
    pub relink_offer: Option<ShellRelinkOffer>,
    /// Remove Silences' preview (`silencePreview`): the ranges the timeline paints red; empty = none. The app reads it
    /// each frame.
    pub silence_preview: Rc<RefCell<Vec<TimeRange>>>,
    /// An import is running (`importRunning`).
    pub import_running: bool,
    /// What the last project import knew (`importChecklist`): File > Import Checklist… reads it.
    pub(crate) import_checklist: Option<ImportChecklistState>,
    /// The volumes whose card import flow runs (`cardImportVolumes`).
    pub card_import_volumes: BTreeSet<String>,
    /// The volume whose card import dialog is up (`ShellCardImport.dialogs`).
    pub(crate) card_dialog: Option<String>,
    /// A card file's picture for the board (`ShellCardImport.poster`; Windows: the FFmpeg thumbnail atlas); taken by the
    /// next card dialog.
    pub card_poster: Option<CardPoster>,
    /// The loudness measurement of Match Loudness and the readouts.
    pub loudness: LoudnessState,
}

impl Default for FlowEnv {
    fn default() -> FlowEnv {
        FlowEnv {
            services: Box::new(NoServices),
            settings: Box::new(MemorySettings::default()),
            edit_api: None,
            relink_offer: None,
            silence_preview: Rc::new(RefCell::new(Vec::new())),
            import_running: false,
            import_checklist: None,
            card_import_volumes: BTreeSet::new(),
            card_dialog: None,
            card_poster: None,
            loudness: LoudnessState::Idle,
        }
    }
}

/// `DefaultsStore` (numbers by key) over the stored settings: the session's ducking rules read their amounts there.
pub(crate) struct SettingsDefaults<'a>(pub &'a mut dyn SettingsStore);

impl DefaultsStore for SettingsDefaults<'_> {
    fn number(&self, key: &str) -> Option<f64> {
        let text = String::from_utf8(self.0.data(key)?).ok()?;
        text.trim().parse().ok()
    }

    fn set_number(&mut self, key: &str, value: f64) {
        self.0.set_data(key, value.to_string().into_bytes());
    }

    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

/// What the Anonymize flow asks the shell for (the closures of the Swift `AnonymizeUI`).
#[derive(Clone, Debug, PartialEq)]
pub enum AnonymizeEvent {
    /// `setJob`: the job line; `None` clears it.
    Job(Option<String>),
    /// `flash`: a status line.
    Flash(String),
    /// `warn`: a message with the warning look.
    Warn(String, String),
    /// `info`: a message.
    Info(String, String),
    /// `ask`: the sheet with the people found (the answer goes to `anonymize_answer`).
    Ask {
        /// The clip's name.
        clip_name: String,
        /// Left to right.
        people: Vec<AnonymizePerson>,
    },
    /// `checks`: the frames to check by hand after a run (Go to First seeks).
    Checks(Vec<AnonymizeCheckLine>),
}

/// A flow the flow files start from a synchronous command (Swift `spawn { await ... }`), run by
/// [`ShellHost::run_flow`] through [`ShellFlow::Tool`].
#[derive(Clone, Debug, PartialEq)]
pub enum ShellTool {
    /// The relink chip after a project opened.
    OfferRelink,
    /// Auto Reframe's sheet and run, for this subject.
    AutoReframe {
        /// The targets' name.
        what: String,
    },
    /// The Anonymize sheet over the people found.
    AnonymizeAsk {
        /// The clip's name.
        clip_name: String,
        /// Left to right.
        people: Vec<AnonymizePerson>,
    },
    /// The Anonymize check list.
    AnonymizeChecks(Vec<AnonymizeCheckLine>),
    /// Edit > Find.
    Find,
    /// Clip > Speed/Duration.
    SpeedDuration,
    /// Clip > Audio Gain.
    AudioGain,
    /// Clip > Match Loudness.
    MatchLoudness,
    /// The loudness line after Voice Chain went on.
    VoiceChainReadout,
    /// An interchange export command.
    ExportInterchange(EditorCommand),
    /// File > Import Timeline.
    ChooseAndImportTimeline,
    /// File > Import Premiere Project.
    ChooseAndImportPremiereProject,
    /// Sequence > Check Cuts.
    CheckCuts,
    /// Bake Live Duck to Keys.
    AutoDuck,
    /// Clip > Remove Silences.
    RemoveSilences,
    /// Clip > Sync Audio to Reference.
    SyncAudio,
    /// Markers on Beat / Downbeats.
    MarkersOnBeat {
        /// Only the first beat of each bar.
        downbeats_only: bool,
    },
    /// A proposed-cut command.
    ProposedCuts(EditorCommand),
    /// Fit Music to Length.
    FitMusic,
    /// Voiceover from Text.
    VoiceoverFromText,
    /// The running time on the job line while a voice-over records.
    TrackVoiceRecording {
        /// The sequence plays along once recording runs (voice-over to picture).
        play: bool,
    },
    /// The take of a stopped voice-over: imported like any media, then placed where recording began.
    FinishVoiceRecording(VoiceRecordingTake),
    /// File > Import Lottie Animation.
    ChooseAndImportLottie,
    /// File > Import Motion Graphics Template.
    ChooseAndImportTemplate,
    /// File > Import Premiere Presets.
    ChooseAndImportPresets,
    /// An import volume appeared.
    CardImport(PathBuf),
    /// Project panel > Locate… on an offline item.
    LocateOffline(Id),
    /// Reconnect / Replace Media on an item.
    ReplaceMedia(Id),
    /// File > Collect Files.
    CollectFiles,
}

impl ShellHost {
    /// Runs a flow started with [`ShellFlow::Tool`].
    pub(crate) async fn run_tool<R: ShellRoot + ?Sized>(h: UiRef<R>, tool: ShellTool) {
        match tool {
            ShellTool::OfferRelink => Self::run_offer_relink(h).await,
            ShellTool::AutoReframe { what } => Self::run_auto_reframe(h, what).await,
            ShellTool::AnonymizeAsk { clip_name, people } => Self::run_anonymize_ask(h, clip_name, people).await,
            ShellTool::AnonymizeChecks(lines) => Self::run_anonymize_checks(h, lines).await,
            ShellTool::Find => Self::find(h).await,
            ShellTool::SpeedDuration => Self::speed_duration(h).await,
            ShellTool::AudioGain => Self::audio_gain(h).await,
            ShellTool::MatchLoudness => Self::run_match_loudness(h).await,
            ShellTool::VoiceChainReadout => Self::run_voice_chain_readout(h).await,
            ShellTool::ExportInterchange(c) => Self::export_interchange(h, c).await,
            ShellTool::ChooseAndImportTimeline => Self::choose_and_import_timeline(h).await,
            ShellTool::ChooseAndImportPremiereProject => Self::choose_and_import_premiere_project(h).await,
            ShellTool::CheckCuts => Self::check_cuts(h).await,
            ShellTool::AutoDuck => Self::auto_duck(h).await,
            ShellTool::RemoveSilences => Self::remove_silences(h).await,
            ShellTool::SyncAudio => Self::sync_audio(h).await,
            ShellTool::MarkersOnBeat { downbeats_only } => Self::markers_on_beat(h, downbeats_only).await,
            ShellTool::ProposedCuts(c) => Self::proposed_cuts(h, c).await,
            ShellTool::FitMusic => Self::fit_music(h).await,
            ShellTool::VoiceoverFromText => Self::voiceover_from_text(h).await,
            ShellTool::TrackVoiceRecording { play } => Self::track_voice_recording_time(h, play).await,
            ShellTool::FinishVoiceRecording(take) => Self::finish_voice_recording(h, take).await,
            ShellTool::ChooseAndImportLottie => Self::choose_and_import_lottie(h).await,
            ShellTool::ChooseAndImportTemplate => Self::choose_and_import_template(h).await,
            ShellTool::ChooseAndImportPresets => Self::choose_and_import_presets(h).await,
            ShellTool::CardImport(volume) => Self::run_card_import(h, volume).await,
            ShellTool::LocateOffline(id) => Self::locate_offline(h, id).await,
            ShellTool::ReplaceMedia(id) => Self::replace_media(h, id).await,
            ShellTool::CollectFiles => Self::collect_files(h, None, false).await,
        }
    }

    /// `defaults.double(forKey:)` over the flow settings (`None` = not set).
    pub(crate) fn setting_number(&self, key: &str) -> Option<f64> {
        self.setting_string(key)?.trim().parse().ok()
    }

    /// `defaults.stringArray(forKey:)`: one entry per line.
    pub(crate) fn setting_list(&self, key: &str) -> Vec<String> {
        self.setting_string(key).map(|s| s.lines().map(str::to_string).collect()).unwrap_or_default()
    }

    /// `defaults.set(value, forKey:)` for a string: kept in the flow settings and told to the app as a setting.
    pub(crate) fn store_setting_string(&mut self, key: &str, value: &str) {
        // shortcut: `flow_env.settings` (FlowEnv, loaded by the app) is not touched by these helpers while other flows still use it directly (split store); the host store
        // (`ShellHost::settings`) is the one source. Upgrade: drop `FlowEnv::settings` once the app loads only the host store.
        self.store_setting(key, SettingValue::Text(value.to_string()));
    }

    /// `defaults.set(value, forKey:)` for a number.
    pub(crate) fn store_setting_number(&mut self, key: &str, value: f64) {
        self.store_setting_string(key, &value.to_string());
    }

    /// The status line of a count: `one` for 1, else `other` (`SQL10n.plural`).
    pub(crate) fn flash_plural(&mut self, n: i64, one: &str, other: &str) {
        self.emit(ShellEvent::Status(SQL10n::plural(n, one, other)));
    }
}

/// What the last project import knew: the checklist and, per row, which affected clip "Show" visits next (the Mac
/// `ShellImportChecklist`).
pub(crate) struct ImportChecklistState {
    pub checklist: sq_premiere_import::primport_checklist::PRImportChecklist,
    pub report: sq_premiere_import::primport_report::PRImportReport,
    pub file_name: String,
    pub cursor: std::collections::HashMap<String, usize>,
}

impl ImportChecklistState {
    pub fn new(
        report: sq_premiere_import::primport_report::PRImportReport,
        project: &sq_core_model::Project,
        file_name: &str,
    ) -> ImportChecklistState {
        ImportChecklistState {
            checklist: sq_premiere_import::primport_checklist::PRImportChecklist::new(&report, project),
            report,
            file_name: file_name.to_string(),
            cursor: std::collections::HashMap::new(),
        }
    }
}
