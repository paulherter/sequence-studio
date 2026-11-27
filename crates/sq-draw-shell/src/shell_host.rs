// Swift: ShellHost.swift
//! The app shell around the panels: menu bar, dialogs, the key route, the project file flows and the window title.
//! `AppController`'s shell part translated (AppController+Files `openProject`, `saveDocument`, `saveDocumentAs`,
//! `saveDocumentCopy`, `confirmDiscardChanges`, `closeProjectItem`, `presentMessage`; AppController+Shell
//! `executeShellCommand`, `revertProject`, `commandEnabled`). The host window feeds events and draws the bar and overlays.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the host does not store the session; every call that needs it gets
//! it in a [`ShellCx`]. Swift hooks (`onStatus`, `onProjectChanged`, `onQuit`, ...) are [`ShellEvent`]s the app drains with
//! [`ShellHost::take_events`]; hooks that return a value are the methods of [`ShellHooks`]; `spawn { await ... }` is a
//! [`ShellFlow`] request the app runs with [`ShellHost::run_flow`].

use crate::keys::{ShellKeys, ShellWindowTitle};
use crate::menu_bar::MenuBar;
use crate::pending_steps::autosave_rows;
use crate::shell_app_menu::{AppMenuOutcome, AppMenuRequest};
use crate::shell_commands::{ShellCommands, ShellPanelFacts};
use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_dock::ShellDock;
use crate::shell_mascot::ShellMascot;
use crate::shell_menu_bar::{PerformAction, ShellAction, ShellMenu, ShellMenuBar, ShellMenuState};
use crate::shell_platform_text::ShellPlatformText;
use crate::shell_quick_apply::QuickApplyPopup;
use crate::shell_settings::{MemoryDefaults, SharedDefaults};
use crate::shell_start::ShellStartScreen;
use sq_core_edit::angles_proxy::AnglesClipExt;
use sq_core_model::{BinItemRef, ShapeKind};
use sq_core_project::project_template::TemplateFolder;
use sq_core_time::{Id, IdSource, Timestamp};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextMeasure, UiCx};
use sq_editor_session::{
    AudioRoleDefaults, CommandRouting, EdgeSelection, EditAction, EditorLookCommands, EditorSession, KeyRouter,
    MagicTrackHealthCache, PasteContent, PasteOffer, PasteRoute, QuickApplyItem, RecentProjects, StorageLocations,
    TrimModeModel,
};
use sq_library::preset_store::PresetItem;
use sq_os::Platform;
use sq_runtime::{Clock, ModalAsk, modal};
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::focus_routing::{EditVerb, FocusedEditTarget};
use sq_uikit::localization::SQL10n;
use sq_uikit::menu_keys::MenuKeys;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::SQDialogResponse;
use sq_uikit::sqmascot_model::SQMascotAnim;
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

/// What Window > Minimize and Maximize ask of the window (Windows and Linux; the Mac's system menu does it itself).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowOp {
    /// Minimize.
    Minimize,
    /// Maximize, or restore when it is maximized already.
    ToggleMaximize,
}

/// What the host tells its owner (the Swift hooks that only notify).
#[derive(Clone, Debug, PartialEq)]
pub enum ShellEvent {
    /// Window > Minimize / Maximize on a window the app draws the caption of: the window follows.
    Window(WindowOp),
    /// `onStatus`: a line for the status bar.
    Status(String),
    /// `onProjectChanged`: the project in the window changed (opened, new, closed, saved under a new name): the host
    /// refreshes its panels.
    ProjectChanged,
    /// `onQuit`: quit after the Save Changes question.
    Quit,
    /// `saveRecents`: the recents changed; persist them (`RecentProjects::save`, key `sq.recentProjects`).
    RecentsChanged,
    /// The app stores a setting (`UserDefaults.set` of the start screen: tab, sort, layout, reopen last).
    Setting {
        /// The defaults key.
        key: String,
        /// The value.
        value: SettingValue,
    },
    /// `onFullScreenChange`: Program monitor Full Screen began or ended; the platform may hide its window chrome.
    FullScreen(bool),
    /// `onJob`: the long-running job's title for the status bar; `None` clears it.
    Job(Option<String>),
    /// `presetsChanged`: the user preset library got new items; the Library panel refreshes.
    PresetsChanged,
    /// `openURL`: open a link in the browser or mail client.
    OpenUrl(String),
    /// A verified update goes in place of the running app (the platform's `apply_update`); with `restart` the new
    /// version starts and this one quits.
    ApplyUpdate {
        /// The staged installer with what is needed to check it once more.
        update: sq_editor_session::PendingUpdate,
        /// Start the new version afterwards.
        restart: bool,
    },
    /// Linux AppImage: Settings > General added the app to the menu or removed it; the host does the file work and
    /// answers with `ShellFlow::AppMenuDone`.
    AppMenu(AppMenuRequest),
    /// `revealFile`: show a file in the file browser.
    RevealFile(PathBuf),
    /// `copyText`: put text on the clipboard.
    CopyText(String),
    /// `onSettingsChanged`: Preferences saved new settings; the app applies them.
    SettingsChanged(Box<sq_editor_session::AppSettings>),
    /// Preferences > Media > Add Folder…: watch this Library folder (`addLibraryFolder`).
    AddLibraryFolder(PathBuf),
    /// Preferences > Media > Remove: stop watching this Library folder (`removeLibraryFolder`, the folder's id).
    RemoveLibraryFolder(String),
    /// Preferences > Media > Delete Cache (`clearCache`).
    ClearCache,
    /// Preferences > Media: the cache folder changed; copy the proxies made so far from the old folder to the new one.
    MoveProxies {
        /// The old proxy folder.
        from: PathBuf,
        /// The new proxy folder.
        to: PathBuf,
    },
    /// Preferences > Editing > Restore Factory: delete this effect or transition default (`effectDefaultsLibrary.update`).
    RestoreEffectDefault(sq_editor_session::EffectDefaultsEntry),
    /// An export was queued: the app runs `ExportQueue::run_all` on a worker (it blocks).
    RunExportQueue,
    /// A menu command a dialog asked for after it closed (the Export sheet's Other Formats\u{2026}): the app runs it like the
    /// menu bar would.
    RunCommand(EditorCommand),
    /// `onExportsFinished`: the exports this window followed have ended (the Mac's notification when the app is in the
    /// background): the files that finished and the failure lines.
    ExportsFinished {
        /// Files written.
        done: Vec<PathBuf>,
        /// One line per failed job.
        failed: Vec<String>,
    },
    /// The queue popover's Cancel on a background job (proxies, transcription; `cancelBackgroundJob`).
    CancelBackgroundJob(String),
}

/// A value of [`ShellEvent::Setting`].
#[derive(Clone, Debug, PartialEq)]
pub enum SettingValue {
    /// A string.
    Text(String),
    /// A switch.
    Flag(bool),
}

/// The stored start screen settings the app hands the host (keys in `shell_start`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StartSettings {
    /// `sq.start.tab`.
    pub tab: Option<String>,
    /// `sq.start.sort`.
    pub sort: Option<String>,
    /// `sq.start.listLayout`.
    pub list_layout: bool,
    /// `sq.reopenLastOnLaunch`.
    pub reopen_last: bool,
    /// `sq.start.whatsNewSeen`: the version whose What's new page was opened last.
    pub whats_new_seen: Option<String>,
}

/// A one-shot answer slot for a flow the edit API starts: the flow sends once, the API thread waits on the receiver.
pub struct FlowReply<T>(std::sync::Arc<std::sync::Mutex<Option<std::sync::mpsc::Sender<T>>>>);

impl<T> FlowReply<T> {
    /// A slot and the receiver of its answer.
    pub fn channel() -> (FlowReply<T>, std::sync::mpsc::Receiver<T>) {
        let (tx, rx) = std::sync::mpsc::channel();
        (FlowReply(std::sync::Arc::new(std::sync::Mutex::new(Some(tx)))), rx)
    }

    /// Answers once; later calls do nothing.
    pub fn send(&self, value: T) {
        let sender = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(tx) = sender {
            let _ = tx.send(value);
        }
    }
}

impl<T> Clone for FlowReply<T> {
    fn clone(&self) -> Self {
        FlowReply(std::sync::Arc::clone(&self.0))
    }
}

impl<T> std::fmt::Debug for FlowReply<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FlowReply")
    }
}

impl<T> PartialEq for FlowReply<T> {
    fn eq(&self, other: &Self) -> bool {
        std::sync::Arc::ptr_eq(&self.0, &other.0)
    }
}

/// What one path of an edit API import became.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiImported {
    /// The path as asked for.
    pub path: PathBuf,
    /// The media item it is now (an existing item for a file the project already had).
    pub media: Option<Id>,
    /// Why there is none.
    pub error: Option<String>,
}

/// A flow that awaits dialogs or file choosers: the host asks its owner to run it with [`ShellHost::run_flow`] (Swift
/// `spawn { await ... }`).
#[derive(Clone, Debug, PartialEq)]
pub enum ShellFlow {
    /// Place media on the timeline, asking the format question first when the media would reformat an empty sequence.
    PlaceMedia {
        /// The media.
        ids: Vec<sq_core_time::Id>,
        /// Where and how.
        options: sq_editor_session::PlaceOptions,
    },
    /// File > New Project (the form).
    NewProjectForm,
    /// File > Open Project.
    ChooseAndOpenProject,
    /// Open a project file (Open Recent, a dropped file).
    OpenProject(PathBuf),
    /// File > Save.
    Save,
    /// File > Save As.
    SaveAs,
    /// File > Save a Copy.
    SaveCopy,
    /// File > Revert.
    Revert,
    /// File > Close Project.
    CloseProject,
    /// File > Quit: the Save Changes question, then [`ShellEvent::Quit`].
    Quit,
    /// File > Save Checkpoint.
    SaveCheckpoint,
    /// Window > Save as New Workspace.
    SaveWorkspaceAs,
    /// Window > Rename Workspace.
    RenameWorkspace,
    /// Window > Delete Workspace.
    DeleteWorkspace,
    /// Window > History.
    History,
    /// Edit > Paste Settings.
    PasteSettings,
    /// Sequence > Punch In Cuts.
    PunchInCuts,
    /// File > New > Sequence.
    NewSequence,
    /// Sequence > Sequence Settings (and Live Ducking for This Project).
    SequenceSettings,
    /// File > Project Notes.
    ProjectNotes,
    /// The marker dialog of the sequence marker `id` (Add and Edit Marker, Edit Marker, M twice on a marker).
    EditMarker(sq_core_time::Id),
    /// Go to Timecode, when the host has no timecode field to focus.
    GoToTimecode,
    /// New Tone (`editing` false) and Tone Settings (true).
    Tone {
        /// Edit the selected tone instead of adding one.
        editing: bool,
    },
    /// Create Angles Clip, after the sheet: lines the angles up (Timecode and Audio read the files), then makes the clip.
    CreateAngles {
        /// The timeline clips the angles come from.
        clips: Vec<sq_core_time::Id>,
        /// The clip's name (the sheet's, never blank).
        name: String,
        /// The sync the sheet chose.
        sync: sq_editor_session::AngleSyncMode,
        /// The angle whose sound plays.
        sound: usize,
        /// Audio Follows Video.
        follows: bool,
    },
    /// File > Import.
    ImportAnything,
    /// Import these files, folders and projects (`importMixed`: Paste, drops).
    ImportMixed(Vec<PathBuf>),
    /// The edit API's import: the same flow as a drop on the window, then the answer per path.
    ApiImport {
        /// The files.
        urls: Vec<PathBuf>,
        /// Gets one entry per path once the import ended.
        reply: FlowReply<Vec<ApiImported>>,
    },
    /// The edit API's export: builds the job like the Export sheet and queues it; answers the queue job ids.
    ApiExport {
        /// What to export.
        request: crate::ApiExportRequest,
        /// The queue job ids, or why not.
        reply: FlowReply<Result<Vec<Id>, String>>,
    },
    /// The edit API's Sync Audio: the fit of `clip` against `to` (timecode, sound or capture date), without moving anything.
    ApiSyncFit {
        /// The clip to move.
        clip: Id,
        /// The reference clip.
        to: Id,
        /// The fit, or why there is none.
        reply: FlowReply<Result<sq_core_audio::audio_drift_fit::AudioDriftFit, String>>,
    },
    /// Files dragged from the Library onto the timeline: imported if new, then placed at the playhead.
    PlaceFiles(Vec<PathBuf>),
    /// The same, landing where the pointer was released (the drop preview's time, track and insert or overwrite).
    PlaceFilesAt {
        /// The files.
        urls: Vec<PathBuf>,
        /// Where the first one starts.
        at: sq_core_time::Time,
        /// The video track under the pointer.
        track: Option<sq_core_time::Id>,
        /// A ghost track of this kind is created for the drop.
        new_track: Option<sq_core_model::TrackKind>,
        /// Insert instead of overwrite.
        insert: bool,
    },
    /// File > Preferences.
    ShowPreferences,
    /// Settings on a page (the Shortcuts editor's sidebar); `true` puts the keyboard in the search field.
    ShowPreferencesAt(crate::shell_preferences::Page, bool),
    /// File > Export.
    ShowExport,
    /// File > Quick Export: the last settings, no sheet.
    QuickExport,
    /// Help > Welcome Tour.
    Welcome,
    /// File > Import Project (another .sqproj as a bin).
    ImportProject,
    /// A File > Project, Sequence or Clip row that opens a dialog (`performProject`).
    Project(ShellAction),
    /// Sequence Studio > About.
    ShowAbout,
    /// Help > Check for Updates.
    CheckForUpdates,
    /// Settings > General > App menu > Remove…: the question, then `ShellEvent::AppMenu`.
    AppMenuRemove,
    /// The host finished an app menu request: the result dialog, then Settings opens again.
    AppMenuDone(AppMenuOutcome),
    /// "Locate…" on a missing recent (the path).
    LocateRecent(PathBuf),
    /// A size tile or template card makes a project (the template id).
    QuickCreate(String),
    /// A template card: the name field first, Return creates (the template id).
    CreateNamed(String),
    /// Rename a saved template (its id).
    RenameTemplate(String),
    /// Delete a saved template (its id).
    DeleteTemplate(String),
    /// A dialog flow of the flow files (analysis, audio tools, imports, card import ...).
    Tool(crate::shell_flow_env::ShellTool),
    /// A step of Keyboard Shortcuts that waits for a dialog or chooser.
    Shortcuts(crate::shell_shortcuts::ShortcutsFlow),
    /// Cancel an export job (the queue popover or ring menu); a running one asks first.
    StopExport(Id),
    /// The exports ended: the dialog with the files.
    ExportFinished(Vec<PathBuf>),
    /// After an import: the checklist card when something needs a look, then Reconnect Media (`spawn` in the importers).
    ImportCard,
    /// The import report card's Save Report… (the report, the imported file's name).
    SaveImportReport(sq_premiere_import::primport_report::PRImportReport, String),
}

/// The panel facts and commands the shell asks its owner (the Swift closures `onCommand`, `commandHandlers`, `onAction`,
/// `fillMenuState`, `menuChecks`, `factProviders`, `isAnonymizing`, `runAutoCaptions`, `runWhooshAtCuts`).
pub trait ShellHooks {
    /// The host's panels run a command the shell does not own (zoom, panels, import...); true when handled.
    fn on_command(&mut self, _c: EditorCommand) -> bool {
        false
    }
    /// Commands a panel host runs itself (the Text panel's Remove Filler Words and Disguise Voice read its transcript):
    /// `Some(true)` when the handler answered. Asked before `on_command`.
    fn command_handler(&mut self, _c: EditorCommand) -> Option<bool> {
        None
    }
    /// Menu rows that are not commands (About, Support, workspaces...); true when handled.
    fn on_action(&mut self, _a: &ShellAction) -> bool {
        false
    }
    /// Menu check marks of host-owned toggles (Safe Margins, Show Overlays...).
    fn menu_checks(&self) -> HashSet<EditorCommand> {
        HashSet::new()
    }
    /// Host pieces that know a panel fact the menu rules read (Controls clip, Graphics selection, grade copy and paste):
    /// each one fills what it owns into the copy `current_facts` hands to the rules.
    fn fill_facts(&self, _p: &mut ShellPanelFacts) {}
    /// Sequence > Transcribe and Create Captions: the Text panel's host; `Some(true)` when it answered.
    fn run_auto_captions(&mut self) -> Option<bool> {
        None
    }
    /// Clip > Cut Tools > Whoosh at Selected Cuts: the Library host's SFX bin flow; true when it ran.
    fn run_whoosh_at_cuts(&mut self) -> bool {
        false
    }
    /// The app has a Project list (Edit > Delete with the Project focused removes its selection).
    fn has_project_list(&self) -> bool {
        false
    }
    /// Removes the selected items of the Project list (`ProjectListView::delete_selection`).
    fn delete_project_selection(&mut self, _host: &mut ShellHost, _session: &mut EditorSession) {}
    /// Runs the panel action of an edit route (Graphics, Keystones and Captions panels: `editActions[a]?()`).
    fn edit_action(&mut self, _a: EditAction) {}
    /// Cut, Copy, Paste, Delete and Ripple Delete with Controls focused: the Controls run them on their own selection (keys,
    /// effect or mask), never on the timeline's clips (the Swift InspectorHost `onCommand` for Delete).
    fn edit_effect_controls(&mut self, _c: EditorCommand) {}
    /// The rows of the Quick Apply palette (`quickApplyItems`); `None` = the host has none, Quick Apply says so.
    fn quick_apply_items(&self) -> Option<Vec<QuickApplyItem>> {
        None
    }
    /// The Library's presets (`libraryPresets`).
    fn library_presets(&self) -> Vec<PresetItem> {
        Vec::new()
    }
    /// The edges selected in the timeline (`edgeSelection`).
    fn edge_selection(&self) -> Option<EdgeSelection> {
        None
    }
    /// Quick Apply > Save Effect Stack as Preset (`saveStackAsPreset`); false = the host cannot.
    fn save_stack_as_preset(&mut self) -> bool {
        false
    }
    /// What the system clipboard holds that can become media (`mediaClipboard`); `None` = the host has no reader.
    fn media_clipboard(&self) -> Option<PasteContent> {
        None
    }
    /// What the clipboard offers, for the menu rules that run every frame: must not read or encode clipboard data.
    /// The default reads it through [`ShellHooks::media_clipboard`]; a host with cheap facts overrides this.
    fn media_clipboard_offer(&self) -> Option<PasteOffer> {
        self.media_clipboard().map(|c| PasteOffer::of(&c))
    }
    /// The full clipboard read as a job for a worker thread (Paste of a picture is slow); `None` = read it on the UI
    /// thread through [`ShellHooks::media_clipboard`].
    fn media_clipboard_job(&self) -> Option<Box<dyn FnOnce() -> PasteContent + Send>> {
        None
    }
    /// Where a pasted image is written (`pastedImageFolder`): a saved project copies it on import, so the scratch folder
    /// (or temp) does; an unsaved one keeps the file where it is, so it should survive a restart.
    fn pasted_image_folder(&self, saved: bool) -> PathBuf {
        crate::shell_paste_media::pasted_image_folder_in(saved, Platform::current(), |k| std::env::var_os(k))
    }
    /// Go to Timecode: the host focuses its monitor's timecode field; true when it did (else a dialog asks).
    fn focus_timecode(&mut self) -> bool {
        false
    }
    /// Sequence > New Shape through the Create tool; true when the host placed the shape.
    fn on_new_shape(&mut self, _kind: ShapeKind) -> bool {
        false
    }
}

/// A host without panels: every hook answers "not mine".
pub struct NoHooks;

impl ShellHooks for NoHooks {}

/// What one shell call may touch: the session, the measure, the UI context and the panel hooks.
pub struct ShellCx<'a, 'm> {
    /// The session.
    pub session: &'a mut EditorSession,
    /// Text measure at the window's scale.
    pub measure: TextMeasure<'m>,
    /// Hover, key repeat, clipboard.
    pub ui: &'a mut UiCx,
    /// The panels' answers.
    pub hooks: &'a mut dyn ShellHooks,
}

/// The frame of a poster media at a time in seconds (Swift `startPoster`).
pub type StartPosterFn = dyn Fn(&str, f64) -> Option<crate::project_list_view::ProjectPoster>;

/// The app shell around the panels (Swift `ShellHost`).
pub struct ShellHost {
    /// The app can show a file in Explorer/Finder (Swift `revealFile != nil`); the "Export finished" button follows it.
    pub can_reveal_file: bool,
    /// The key map (Premiere default or the user's).
    pub map: CommandMap,
    /// Open Recent.
    pub recents: RecentProjects,
    /// What the host's panels know (the enabled rules read it).
    pub panels: ShellPanelFacts,
    /// The facts of one menu build: the rules ask for them once per row (hundreds of rows), and they scan the clips.
    facts_memo: RefCell<Option<ShellPanelFacts>>,
    /// What the last bar built by `refresh_menus` was made from.
    pub(crate) menu_stamp: RefCell<Option<crate::shell_menu_cache::MenuStamp>>,
    pub(crate) menu_builds: Cell<u64>,
    /// `has_angles_clip` of the last clip scan, keyed on the project and the session's change counters.
    pub(crate) angles_scan: RefCell<Option<(sq_core_time::Id, [u64; sq_editor_session::Change::COUNT], bool)>>,
    /// How many clip scans ran (tests).
    pub angles_scans: Cell<u64>,
    /// A Paste whose clipboard read runs on a worker thread; its result is taken in `poll_paste`.
    pub(crate) pending_paste: RefCell<Option<crate::shell_paste_media::PendingPaste>>,
    /// Tests turn this on: every frame that keeps the bar builds it again and must find it equal (`refresh_menus`).
    pub verify_menu_cache: bool,
    pub(crate) menus_built: RefCell<Vec<ShellMenu>>,
    /// The panel with keyboard focus (the key map's scope).
    pub focus: Option<PanelID>,
    /// Trim mode's model (the two-up monitor and the bar under the timeline show it).
    pub trim: TrimModeModel,
    /// Program monitor Full Screen is on; the host draws only the picture and swallows the mouse.
    pub is_program_full_screen: bool,
    /// The Mac window: Command and Control are separate shortcut modifiers (`ShellKeys::command`). On by default on macOS.
    pub mac_keys: bool,
    /// This window's system: Ctrl+Q quits on Linux (`ShellKeys::is_quit_chord`).
    pub platform: Platform,
    /// The supporters' names About lists (`aboutSupporters`).
    pub about_supporters: Vec<String>,
    /// The start screen, while it is up.
    pub(crate) start: Option<ShellStartScreen>,
    /// The stored start settings (the app keeps them current from [`ShellEvent::Setting`]).
    pub start_settings: StartSettings,
    /// The projects folder the start screen's status bar names.
    pub projects_root: String,
    /// The start screen has a window of its own of this size (the Mac).
    pub start_window_size: Option<CGSize>,
    /// The system window buttons float over the top-left of the window (the Mac): the start screen keeps its top bar
    /// clear of them and draws no title text there.
    pub window_lights: bool,
    /// The start window's search moves into the menu bar's row.
    pub start_search_in_bar: bool,
    /// Width at the bar's right end the in-bar search keeps clear (the Windows and Linux window buttons).
    pub start_bar_right_inset: f64,
    /// Pip is drawn by the shell (hosts without real mascot views).
    pub draws_start_mascots: bool,
    /// The frame of a poster media at a time in seconds, for the start screen's cards (Swift `startPoster`).
    pub start_poster: Option<Rc<StartPosterFn>>,
    pub(crate) start_shown_for: Option<Id>,
    pub(crate) start_shown_empty: bool,
    pub(crate) start_project_id: Option<Id>,
    /// The open project's name and whether it is a real one, as of the last `layout` (the start screen's status bar).
    pub(crate) start_open_name: String,
    pub(crate) start_has_project: bool,
    /// The operating system version the feedback mail names (`ProcessInfo.operatingSystemVersionString`).
    pub os_version: String,
    /// The folder of the app log, revealed by Help > Reveal Logs (`SQLog.directory`); `None` until a logger exists.
    pub log_directory: Option<PathBuf>,
    /// The address of Help > Check for Updates (`UpdateCheck::feed_url`); empty switches the check off.
    pub update_feed: String,
    /// Whether this system installs an update in place (the platform's `apply_update` is wired); else the Download
    /// button opens the link.
    pub update_install: bool,
    /// Where downloaded installers are staged; `None` switches the in-app download off.
    pub update_cache: Option<PathBuf>,
    /// A downloaded, verified update chosen with "Later": applied when the app quits, after a second check.
    pub pending_update: Option<sq_editor_session::PendingUpdate>,
    pub(crate) full_screen_started: f64,
    pub(crate) shuttle_router: KeyRouter,
    /// When the shuttle router wants its `tick` (Swift's `shuttleDeadline` task).
    pub(crate) shuttle_wake: Option<f64>,
    /// The stored defaults the commands and dialogs read (UserDefaults in Swift); the app fills it from its store and keeps
    /// it current from [`ShellEvent::Setting`]. Writes of the shell are kept here and announced as that event.
    pub settings: SharedDefaults,
    /// The J / L cut offsets per audio role (`AudioRoleDefaults.current`).
    pub audio_role_defaults: AudioRoleDefaults,
    /// The Quick Apply palette, while it is up.
    pub(crate) quick_apply: Option<QuickApplyPopup>,
    /// The tracking confidence of the Magic masks (Go to Next Weak Tracking); the app fills it in.
    pub magic_health: Option<MagicTrackHealthCache>,
    /// The bar at the top of the window.
    pub menu_bar: MenuBar,
    /// The items selected in the Project list; the list keeps it current (Swift `projectSelection`).
    pub project_selection: Vec<BinItemRef>,
    /// Edit > Find asked for this search; the app root runs it on the Project model ([`ShellHost::take_find_request`]).
    pub(crate) find_request: Option<sq_editor_session::FindCriteria>,
    /// The user's saved sequence templates (Swift `templateFolder`); `None` = only the built-in ones.
    pub template_folder: Option<TemplateFolder>,
    /// Ids for the templates the user saves; the app replaces it with its random source.
    pub ids: Box<dyn IdSource>,
    /// The services and state of the flow files (waveforms, probe, presets, relink chip, Edit API ...).
    pub flow_env: crate::shell_flow_env::FlowEnv,
    /// Library folders and the moved originals that wait for a save (the "Outside files" setting at import).
    pub outside_media: crate::shell_outside_media::OutsideMediaState,
    /// The typed view (Swift `UserDefaults.standard`) of the same store as `settings`: one store, two handles.
    pub defaults: Box<dyn UiDefaults>,
    /// The folder picked in the New Project sheet this session (Swift `newProjectLocation`); `None` = the stored Projects
    /// folder, so a setting stored before the host was built (an offscreen run's own folder) is the one suggested.
    pub new_project_location: Option<PathBuf>,
    /// What Export knows from the host: sources, queue, codecs, the queue popover.
    pub export: crate::shell_export::ExportHost,
    /// Flows a menu row asked for (the export ring menu); `take_flows` hands them out with the others.
    pub(crate) menu_flows: Rc<RefCell<Vec<ShellFlow>>>,
    /// What Preferences shows that the host knows (output devices, library folders, Edit API ...).
    pub preferences: crate::shell_preferences::PreferencesHost,
    /// A new Preferences page asks the open dialog to scroll back to the top at its next layout.
    pending_scroll_reset: bool,
    /// Keyboard Shortcuts while it is up (`ShellShortcuts.swift`).
    pub(crate) shortcuts: Option<crate::shell_shortcuts::ShellShortcutsEditor>,
    pub(crate) keymap_change: Option<CommandMap>,
    /// The Shortcuts page handed over to another Settings page: the Settings card is the same window, so it appears at once,
    /// without the open motion (`draw_overlays` clears it once the card is drawn).
    pub(crate) settings_card_instant: bool,
    /// The dockable panel layout (Window menu rows, panel commands, floating windows).
    pub dock: ShellDock,
    dialog: Option<ShellDialog>,
    size: CGSize,
    layout_dirty: bool,
    /// A change made outside an input event (an answered chooser) that the window shows only in a new frame.
    frame_requested: bool,
    /// Rows picked in an open menu, performed after the menu closed.
    actions: Rc<RefCell<Vec<ShellAction>>>,
    events: Rc<RefCell<Vec<ShellEvent>>>,
    flows: Vec<ShellFlow>,
    answered_form: Option<Box<dyn DialogForm>>,
    pub(crate) dock_out: Vec<crate::shell_dock::DockEvent>,
    /// The panel the shell's own dock focused since the last call (Select Next Panel): the app's dock follows.
    pub(crate) dock_focus_out: Option<PanelID>,
    pub(crate) history_dialog: Option<ShellDialog>,
    pub(crate) form_changes: Vec<(String, FormValue)>,
    /// The live dialog flow waiting for a form change (`shell_live`).
    pub(crate) form_waker: Option<std::task::Waker>,
    /// First history row shown by the open History dialog: a picked row jumps there.
    pub(crate) history_base: Option<i64>,
    pub(crate) clock: Arc<dyn Clock>,
    wall: Box<dyn Fn() -> Timestamp>,
}

impl ShellHost {
    /// The folder the start screen's footer names: the host's own `projects_root`, else the stored Projects folder.
    pub(crate) fn start_projects_root(&self) -> String {
        if !self.projects_root.is_empty() {
            return self.projects_root.clone();
        }
        StorageLocations::load(&*self.defaults).projects_root().to_string_lossy().into_owned()
    }

    /// Where File > New Project suggests its folder: the one picked this session, else the stored Projects folder.
    pub fn new_project_start_folder(&self) -> PathBuf {
        self.new_project_location.clone().unwrap_or_else(|| StorageLocations::load(&*self.defaults).projects_root())
    }

    /// A host with the key map `map`. `clock` is the steady clock of the shuttle keys, `wall` the time of the autosave
    /// version labels. The menus are built by the first [`ShellHost::layout`].
    pub fn new(
        map: CommandMap,
        recents: RecentProjects,
        clock: Arc<dyn Clock>,
        wall: Box<dyn Fn() -> Timestamp>,
    ) -> ShellHost {
        let router_clock = Arc::clone(&clock);
        // Swift ShellHost.init: the empty states draw Pip asleep with gray marks.
        Canvas::set_empty_state_art(|rect, c| {
            crate::shell_mascot::ShellMascot::draw_with_marks(
                sq_uikit::sqmascot_model::SQMascotAnim::Sleep,
                rect,
                c,
                crate::shell_mascot::neutral_mark(),
            )
        });
        let settings: SharedDefaults = Rc::new(RefCell::new(MemoryDefaults::default()));
        ShellHost {
            can_reveal_file: false,
            shuttle_router: KeyRouter::new(
                CommandMap::premiere_default(),
                None,
                Box::new(move || router_clock.now().as_secs_f64()),
            ),
            map,
            recents,
            panels: ShellPanelFacts::default(),
            facts_memo: RefCell::new(None),
            menu_stamp: RefCell::new(None),
            menu_builds: Cell::new(0),
            angles_scan: RefCell::new(None),
            angles_scans: Cell::new(0),
            pending_paste: RefCell::new(None),
            verify_menu_cache: false,
            menus_built: RefCell::new(Vec::new()),
            focus: None,
            trim: TrimModeModel::new(),
            is_program_full_screen: false,
            full_screen_started: 0.0,
            mac_keys: Platform::current().command_is_cmd_key(),
            settings_card_instant: false,
            platform: Platform::current(),
            about_supporters: Vec::new(),
            start: None,
            start_settings: StartSettings::default(),
            template_folder: None,
            projects_root: String::new(),
            start_window_size: None,
            window_lights: false,
            start_search_in_bar: false,
            start_bar_right_inset: 0.0,
            draws_start_mascots: true,
            start_poster: None,
            start_shown_for: None,
            start_shown_empty: false,
            start_project_id: None,
            start_open_name: String::new(),
            start_has_project: false,
            os_version: String::new(),
            log_directory: None,
            update_feed: String::new(),
            update_install: false,
            update_cache: None,
            pending_update: None,
            shuttle_wake: None,
            settings: Rc::clone(&settings),
            audio_role_defaults: AudioRoleDefaults::standard(),
            quick_apply: None,
            magic_health: None,
            menu_bar: MenuBar::new(),
            project_selection: Vec::new(),
            find_request: None,
            // Random: the importers and templates mint ids that land in saved projects.
            ids: Box::new(sq_core_time::RandomIds),
            flow_env: crate::shell_flow_env::FlowEnv::default(),
            outside_media: crate::shell_outside_media::OutsideMediaState::default(),
            new_project_location: None,
            defaults: Box::new(crate::shell_settings::SharedView(Rc::clone(&settings))),
            export: crate::shell_export::ExportHost::default(),
            menu_flows: Rc::new(RefCell::new(Vec::new())),
            preferences: crate::shell_preferences::PreferencesHost::default(),
            pending_scroll_reset: false,
            shortcuts: None,
            keymap_change: None,
            dock: ShellDock::default(),
            dialog: None,
            size: CGSize::new(1280.0, 800.0),
            layout_dirty: true,
            frame_requested: false,
            actions: Rc::new(RefCell::new(Vec::new())),
            events: Rc::new(RefCell::new(Vec::new())),
            flows: Vec::new(),
            answered_form: None,
            dock_out: Vec::new(),
            dock_focus_out: None,
            history_dialog: None,
            form_changes: Vec::new(),
            form_waker: None,
            history_base: None,
            clock,
            wall,
        }
    }

    /// Everything the host wants its owner to know since the last call, in order.
    pub fn take_events(&mut self) -> Vec<ShellEvent> {
        std::mem::take(&mut *self.events.borrow_mut())
    }

    /// The form of the dialog that was answered last: the asking flow reads the typed values from it.
    pub fn take_answered_form(&mut self) -> Option<Box<dyn DialogForm>> {
        self.answered_form.take()
    }

    /// The form values changed while a dialog was open, in order (Swift `ShellForm.onChange`); the History dialog's rows
    /// are handled by the host itself and do not show here.
    pub fn take_form_changes(&mut self) -> Vec<(String, FormValue)> {
        std::mem::take(&mut self.form_changes)
    }

    /// The flows the host started since the last call (run each with [`ShellHost::run_flow`]).
    pub fn take_flows(&mut self) -> Vec<ShellFlow> {
        let mut flows = std::mem::take(&mut self.flows);
        flows.append(&mut self.menu_flows.borrow_mut());
        flows
    }

    pub(crate) fn start_flow(&mut self, f: ShellFlow) {
        self.flows.push(f);
    }

    /// The event queue, for dialog contents that report links and the like without a host borrow (Swift closures capturing
    /// the host).
    pub(crate) fn event_sink(&self) -> Rc<RefCell<Vec<ShellEvent>>> {
        Rc::clone(&self.events)
    }

    pub fn emit(&mut self, e: ShellEvent) {
        self.events.borrow_mut().push(e);
    }

    /// The window size in points.
    pub fn size(&self) -> CGSize {
        self.size
    }

    /// Sets the window size; the next `layout` places the bar, dialog and popups for it.
    pub fn set_size(&mut self, size: CGSize) {
        self.size = size;
        self.layout_dirty = true;
    }

    /// Wall-clock time (version labels).
    pub(crate) fn wall_now(&self) -> Timestamp {
        (self.wall)()
    }

    /// Steady seconds.
    pub(crate) fn now_seconds(&self) -> f64 {
        self.clock.now().as_secs_f64()
    }

    fn window(&self) -> CGRect {
        CGRect::new(0.0, 0.0, self.size.width, self.size.height)
    }

    /// Lays the bar titles, the dialog and the popup bounds out for the current size and measure; rebuilds the menus.
    pub fn layout(&mut self, session: &EditorSession, hooks: &dyn ShellHooks, m: &TextMeasure) {
        self.start_open_name = if session.is_empty_untitled() { String::new() } else { session.display_name() };
        self.start_has_project = !session.is_empty_untitled();
        let menus = self.menus(session, hooks);
        self.menu_bar.set_menus(menus, m);
        self.relayout(m);
    }

    fn relayout(&mut self, m: &TextMeasure) {
        self.layout_dirty = false;
        let w = self.window();
        self.menu_bar.controller.bounds = w;
        self.start_layout();
        self.fit_start_bar(m);
        if let Some(e) = self.shortcuts.as_mut() {
            e.frame = w;
        }
        if let Some(p) = self.export.popover.as_mut() {
            p.layout(w);
        }
        self.dock.set_measure(m);
        // pending: ShellShortcuts (editor frame), ExportQueuePopover layouts
        if let Some(q) = self.quick_apply.as_mut() {
            q.layout(w);
        }
        if let Some(d) = self.dialog.as_mut() {
            d.layout(w, m);
            if std::mem::take(&mut self.pending_scroll_reset) {
                d.reset_form_scroll(m);
            }
        }
    }

    /// The start screen's bar row holds the menu titles and the search field: split it so both fit (field shrinks, then
    /// hides, then the titles fold into the overflow menu). Without the in-bar field the titles keep the whole row.
    fn fit_start_bar(&mut self, m: &TextMeasure) {
        let Some(s) = self.start.as_mut() else { return };
        let Some(bar) = s.bar_frame else {
            s.search_width = None;
            self.menu_bar.set_room_limit(None, m);
            return;
        };
        let origin = self.menu_bar.origin().x;
        let (width, limit) = ShellStartScreen::bar_split(bar.max_x(), origin, self.menu_bar.natural_right(m));
        s.search_width = Some(width);
        self.menu_bar.set_room_limit(limit, m);
    }

    /// The open dialog's rows changed (a Preferences page swap): lays it out again at the next event or frame, back at the
    /// top when `reset_scroll`.
    pub(crate) fn invalidate_dialog_layout(&mut self, reset_scroll: bool) {
        self.layout_dirty = true;
        self.pending_scroll_reset |= reset_scroll;
        self.request_frame();
    }

    /// Asks the app for a frame: a task changed the shell (a folder chosen for Preferences) and no input event follows to
    /// draw it. The app reads it with [`ShellHost::take_frame_request`] after the tasks ran.
    pub fn request_frame(&mut self) {
        self.frame_requested = true;
    }

    /// Whether a task asked for a frame since the last call.
    pub fn take_frame_request(&mut self) -> bool {
        std::mem::take(&mut self.frame_requested)
    }

    fn ensure_layout(&mut self, m: &TextMeasure) {
        if self.layout_dirty {
            self.relayout(m);
        }
    }

    /// Lays `d` out again after its rows changed (a Preferences page swap).
    pub fn relayout_dialog(&mut self, m: &TextMeasure) {
        self.relayout(m);
    }

    // MARK: Window title, menus

    /// The window title for the open project.
    pub fn window_title(&self, session: &EditorSession) -> String {
        if session.is_empty_untitled() {
            ShellWindowTitle::text(None, false)
        } else {
            ShellWindowTitle::text(Some(&session.display_name()), session.is_dirty())
        }
    }

    /// The state the menus show.
    pub fn menu_state(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> ShellMenuState {
        let mut s = ShellMenuState {
            recents: self.recents.entries().to_vec(),
            undo_name: session.undo_name().map(str::to_string),
            redo_name: session.redo_name().map(str::to_string),
            modal_shown: self.dialog().is_some() || self.shortcuts.is_some(),
            chooser_shown: self.start.is_some(),
            autosave_versions: autosave_rows(session),
            now: self.wall_now(),
            ..ShellMenuState::default()
        };
        if self.flow_env.services.anonymize_running() {
            s.titles.insert(EditorCommand::Anonymize, "Cancel Anonymize".to_string());
        }
        self.analysis_titles(&mut s);
        s.reasons.extend(EditorLookCommands::disabled_reasons(session));
        self.fill_window_state(session, &mut s);
        self.fill_project_state(session, hooks, &mut s);
        s
    }

    /// The main menu for the current state. A picked row queues its [`ShellAction`] for [`ShellHost::handle`] to perform.
    pub fn menus(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> Vec<ShellMenu> {
        let actions = Rc::clone(&self.actions);
        let perform: PerformAction = Rc::new(move |a| actions.borrow_mut().push(a));
        let validate = |c: EditorCommand| self.menu_enabled(session, hooks, c);
        // One facts computation for the whole menu bar, not one per row (a 5000-clip timeline cost 100 ms per frame).
        *self.facts_memo.borrow_mut() = Some(self.current_facts_uncached(session, hooks));
        let built =
            ShellMenuBar::build(&self.menu_state(session, hooks), &self.map, self.platform, Some(&validate), perform);
        *self.facts_memo.borrow_mut() = None;
        built
    }

    /// A menu row's enabled state: `enabled` plus the focus rules of the Mac `validateMenuItem` (Cut, Copy, Paste, Select All
    /// and Delete follow the focused panel through `CommandRouting::edit_route`; Copy and Paste in the Color panels copy and
    /// paste the grade). Keys keep using `enabled`: a key the focused panel does not take goes on to the panel under it.
    pub fn menu_enabled(&self, session: &EditorSession, hooks: &dyn ShellHooks, c: EditorCommand) -> bool {
        use EditorCommand as C;
        let facts = self.current_facts(session, hooks);
        // Typing in a text field (the Mac `textResponder`): the text verbs and Undo/Redo belong to it, panel-only Command
        // shortcuts and Find / poster frame / hover scrub do not fire.
        if facts.text_editing {
            if [C::Find, C::SetPosterFrame, C::ClearPosterFrame, C::ToggleHoverScrub].contains(&c) {
                return false;
            }
            if [C::Cut, C::Copy, C::Paste, C::Delete, C::DeleteProjectItems, C::SelectAll, C::Undo, C::Redo]
                .contains(&c)
            {
                return true;
            }
            if MenuKeys::blocked_while_typing(&c, &self.map) {
                return false;
            }
        }
        if matches!(self.focus, Some(PanelID::ColorInspector | PanelID::ColorClips | PanelID::Steps))
            && (c == C::Copy || c == C::Paste)
        {
            return (if c == C::Copy { facts.can_copy_grade } else { facts.can_paste_grade }).unwrap_or(true);
        }
        if let Some(verb) = EditVerb::from_command(&c) {
            use sq_editor_session::EditEnabled as E;
            match CommandRouting::edit_route(FocusedEditTarget::from_panel(self.focus), verb).enabled {
                E::TimelineRules => {}
                E::Always => return true,
                E::Never => return false,
                E::CanPasteMedia => return facts.can_paste_media,
                E::GraphicsHasSelection => return facts.graphics_has_selection.unwrap_or(true),
                E::GraphicsHasLayers => return facts.graphics_has_layers.unwrap_or(true),
            }
        }
        // Effect Controls takes Cut / Copy / Paste when the panel has focus and something to act on, and owns Delete
        // (the Mac `validateInEffectControls`).
        if self.focus == Some(PanelID::EffectControls) {
            match c {
                C::Copy if facts.effect_can_copy == Some(true) => return true,
                C::Cut if facts.effect_can_cut == Some(true) => return true,
                C::Paste if facts.effect_can_paste == Some(true) => return true,
                C::Delete | C::RippleDelete => {
                    if let Some(can) = facts.effect_can_delete {
                        return can;
                    }
                }
                _ => {}
            }
        }
        match c {
            C::Undo => session.can_undo(),
            C::Redo => session.can_redo(),
            _ => self.enabled(session, hooks, c),
        }
    }

    /// Whether `c` can run now (the menu rules of `ShellCommands::enabled` plus the shell's own).
    pub fn enabled(&self, session: &EditorSession, hooks: &dyn ShellHooks, c: EditorCommand) -> bool {
        let mut p = self.current_facts(session, hooks);
        p.dialog_shown = p.dialog_shown || self.dialog().is_some();
        p.anonymizing = self.flow_env.services.anonymize_running();
        if let Some(on) = self.analysis_enabled(session, c) {
            return on;
        }
        if self.focused_deletes_project(c) {
            return hooks.has_project_list();
        }
        ShellCommands::enabled(c, session, &p)
    }

    /// The facts the menu rules read, as the Mac `AppController.commandEnabled` reads them from its panels: what the shell
    /// itself knows (session, Project list, focus) is derived here, so every host shows the same rows; what only a panel
    /// knows (Controls clip, Graphics selection, grade copy and paste) comes from the hooks. A fact nobody reports keeps
    /// the value in `panels`.
    // Swift: ShellFacts.swift `currentFacts`
    // The voice recorder fact is set by the host into `panels` (the app wires the recorder); it keeps the value there.
    pub fn current_facts(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> ShellPanelFacts {
        if let Some(memo) = self.facts_memo.borrow().as_ref() {
            return memo.clone();
        }
        self.current_facts_uncached(session, hooks)
    }

    pub(crate) fn current_facts_uncached(&self, session: &EditorSession, hooks: &dyn ShellHooks) -> ShellPanelFacts {
        let mut p = self.panels.clone();
        // The scan walks every clip; it reruns only after a session change (the stamp asks on every frame).
        let key = (session.project().id, crate::shell_menu_cache::versions_without_playhead(session));
        let cached = self.angles_scan.borrow().filter(|c| (c.0, c.1) == key).map(|c| c.2);
        p.has_angles_clip = cached.unwrap_or_else(|| {
            self.angles_scans.set(self.angles_scans.get() + 1);
            let found = session
                .active_timeline()
                .is_some_and(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(AnglesClipExt::is_angles_clip)));
            *self.angles_scan.borrow_mut() = Some((key.0, key.1, found));
            found
        });
        if let Some(offer) = hooks.media_clipboard_offer() {
            p.can_paste_media =
                matches!(self.media_route(session, offer), PasteRoute::ImportFiles | PasteRoute::ImportImage);
        }
        hooks.fill_facts(&mut p);
        let focus = self.focus;
        if hooks.has_project_list() {
            // Edit Original: the Project selection when it has focus, else the selected clips' files, else the Source clip.
            p.edit_original_available = if focus == Some(PanelID::Project) {
                p.project_media_has_file
            } else {
                !session.original_files_of_selection().is_empty() || p.source_media_loaded
            };
        } else if focus != Some(PanelID::Project) {
            p.edit_original_available = p.edit_original_available || !session.original_files_of_selection().is_empty();
        }
        if p.panels_loaded {
            // Insert / Overwrite: the Source clip, else the Project selection (the Mac `placeSource`).
            p.can_place_source = sq_uikit::focus_routing::PlaceSource::resolve(
                p.source_media_loaded,
                focus,
                p.project_selected_media,
                p.project_selected_sequences,
            ) != sq_uikit::focus_routing::PlaceSource::Nothing;
        }
        p
    }

    // MARK: Actions and commands

    /// Performs a menu row.
    pub fn perform(&mut self, cx: &mut ShellCx, a: ShellAction) {
        match a {
            ShellAction::Command(c) => {
                self.execute(cx, c);
            }
            ShellAction::OpenRecent { path } => self.start_flow(ShellFlow::OpenProject(PathBuf::from(path))),
            ShellAction::ClearRecents => {
                self.recents.clear();
                self.emit(ShellEvent::RecentsChanged);
            }
            ShellAction::Quit => self.start_flow(ShellFlow::Quit),
            ShellAction::RestoreAutosave { path } => self.restore_autosave(cx, &path),
            ShellAction::SaveCheckpoint => self.start_flow(ShellFlow::SaveCheckpoint),
            ShellAction::StartWindow => self.show_start(cx),
            _ => {
                if self.perform_help(cx, &a) || self.perform_window(cx, &a) || self.perform_project(cx, &a) {
                    return;
                }
                if !cx.hooks.on_action(&a) {
                    self.flash(ShellPlatformText::not_available());
                }
            }
        }
    }

    /// Runs a command: the shell's own file commands, then the host's panels, then the session-only commands. False when
    /// it is disabled or nobody runs it (a key press then goes on to the panel under it).
    pub fn execute(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        if let Some(taken) = self.run_focused_edit(cx, c) {
            return taken;
        }
        if !self.enabled(cx.session, &*cx.hooks, c) {
            return false;
        }
        match c {
            C::NewProject => self.start_flow(ShellFlow::NewProjectForm),
            C::OpenProject => self.start_flow(ShellFlow::ChooseAndOpenProject),
            C::Save => self.start_flow(ShellFlow::Save),
            C::SaveAs => self.start_flow(ShellFlow::SaveAs),
            C::SaveCopy => self.start_flow(ShellFlow::SaveCopy),
            C::Revert => self.start_flow(ShellFlow::Revert),
            C::CloseProject => self.start_flow(ShellFlow::CloseProject),
            C::ImportMedia => self.start_flow(ShellFlow::ImportAnything),
            C::Preferences => self.start_flow(ShellFlow::ShowPreferences),
            C::KeyboardShortcuts => self.show_shortcuts(cx),
            C::Export if self.export.sources.is_some() => self.start_flow(ShellFlow::ShowExport),
            C::QuickExport if self.export.sources.is_some() => self.start_flow(ShellFlow::QuickExport),
            _ => {
                if self.run_focused_delete(cx, c) {
                    return true;
                }
                if c == C::Paste && self.paste_media(cx) {
                    return true;
                }
                if self.run_trim_command(cx, c) {
                    return true;
                }
                if let Some(done) = self.execute_panel_command(cx, c) {
                    return done;
                }
                if cx.hooks.command_handler(c) == Some(true) {
                    return true;
                }
                if self.perform_audio_flow_command(cx, c) {
                    return true;
                }
                if cx.hooks.on_command(c) {
                    return true;
                }
                if self.run_analysis_command(cx, c) {
                    return true;
                }
                if self.run_library_import_command(cx, c) {
                    return true;
                }
                if c == C::AutoCaptions && cx.hooks.run_auto_captions().is_some() {
                    return true;
                }
                if c == C::WhooshAtCuts && cx.hooks.run_whoosh_at_cuts() {
                    return true;
                }
                if self.perform_dialog_command(cx, c) {
                    return true;
                }
                if self.run_shuttle_command(cx, c) {
                    return true;
                }
                let Some(line) = ShellCommands::run(c, cx.session, &self.bytes_view(), &self.audio_role_defaults)
                else {
                    // Swift: a command in `notYetShared` flashes "<title> is not available in this window yet."; the set is empty.
                    return false;
                };
                if !line.is_empty() {
                    self.flash(&line);
                }
            }
        }
        true
    }

    pub(crate) fn flash(&mut self, s: &str) {
        self.emit(ShellEvent::Status(SQL10n::string(s)));
    }

    // MARK: Events and drawing

    /// One window event (pixels, `scale` = pixels per point). True when the shell took it; otherwise it goes on to the panels.
    pub fn handle(&mut self, cx: &mut ShellCx, e: &InputEvent, scale: f32) -> bool {
        self.sweep_dialog();
        self.ensure_layout(&cx.measure);
        self.sync_start(cx);
        if let Some(d) = self.dialog.as_mut() {
            d.handle(e, scale, &cx.measure, cx.ui);
            let mut changes = d.form.as_mut().map(|f| f.take_changes()).unwrap_or_default();
            changes.extend(d.content.as_mut().map(|c| c.take_changes()).unwrap_or_default());
            self.route_form_changes(cx, changes);
            self.sweep_dialog();
            return true;
        }
        if self.shortcuts.is_some() {
            self.handle_shortcuts(cx, e, scale);
            return true;
        }
        if self.export.popover.is_some() && self.handle_export_popover(e, scale, cx.ui, &cx.measure) {
            return true;
        }
        if self.handle_quick_apply(cx, e, scale) {
            return true;
        }
        if self.handle_menu_bar(cx, e, scale) {
            return true;
        }
        if let InputEvent::KeyDown { key, modifiers } = *e
            && ShellKeys::is_quit_chord(key, modifiers, self.platform)
        {
            self.perform(cx, ShellAction::Quit);
            return true;
        }
        // The dock takes presses on its gaps and tab strips (and their drags); hover only records the pointer.
        // pending: the start screen's modal key rule
        if self.start.is_none() && self.dock.handle(e, scale) {
            self.focus = self.dock.focused().or(self.focus);
            self.sync_dock(&cx.measure);
            return true;
        }
        if self.start.is_some() {
            return self.handle_start(cx, e, scale);
        }
        if let InputEvent::KeyDown { key, modifiers } = *e {
            if key == InputKey::Escape && modifiers == InputModifiers::NONE {
                return self.escape_key(cx);
            }
            if let Some(c) = ShellKeys::command(key, modifiers, self.focus, &self.map, self.mac_keys) {
                return self.key_command(cx, c, key);
            }
        }
        false
    }

    /// The menu bar and its open menu; the rows it picked are performed after it closed.
    fn handle_menu_bar(&mut self, cx: &mut ShellCx, e: &InputEvent, scale: f32) -> bool {
        // The bar rebuilds the menus right before one opens; the rebuild needs `self`, so the bar steps out meanwhile.
        let mut bar = std::mem::take(&mut self.menu_bar);
        // Alt+letter opens the menu of that mnemonic unless the key map binds the chord (then the command runs).
        let mnemonic = match *e {
            InputEvent::KeyDown { key: key @ InputKey::Character(c), modifiers }
                if ShellKeys::is_menu_mnemonic_chord(key, modifiers, self.platform)
                    && ShellKeys::command(key, modifiers, self.focus, &self.map, self.mac_keys).is_none() =>
            {
                Some(c)
            }
            _ => None,
        };
        let took = {
            let this: &ShellHost = self;
            let (session, hooks) = (&*cx.session, &*cx.hooks);
            let mut refresh = || this.menus(session, hooks);
            let mut refresh = Some(&mut refresh as &mut dyn FnMut() -> Vec<ShellMenu>);
            match mnemonic {
                Some(c) if bar.open_mnemonic(c, &cx.measure, &mut refresh) => true,
                _ => bar.handle(e, scale, &cx.measure, &mut refresh),
            }
        };
        cx.ui.hover.offer_tip(bar.controller.tip_at(e, scale, &cx.measure).as_deref());
        self.menu_bar = bar;
        self.perform_queued(cx);
        // A row picked in a menu the start screen opened queues a start action; the menu took the event, so
        // `handle_start` never runs for it. Without this the start screen shows the old state until the next pointer move.
        if self.start.is_some() {
            self.apply_start_actions(cx);
        }
        took
    }

    /// Performs the rows picked outside the drawn bar (the system menu bar calls the row's action, which queues it).
    pub fn perform_pending(&mut self, cx: &mut ShellCx) {
        self.perform_queued(cx);
    }

    fn perform_queued(&mut self, cx: &mut ShellCx) {
        let queued: Vec<ShellAction> = self.actions.borrow_mut().drain(..).collect();
        for a in queued {
            self.perform(cx, a);
        }
    }

    /// Alt pressed and released alone (the Windows menu key rule): opens the first menu.
    pub fn alt_tapped(&mut self, cx: &mut ShellCx) {
        let mut bar = std::mem::take(&mut self.menu_bar);
        {
            let this: &ShellHost = self;
            let (session, hooks) = (&*cx.session, &*cx.hooks);
            let mut refresh = || this.menus(session, hooks);
            bar.alt_tapped(&cx.measure, &mut Some(&mut refresh));
        }
        self.menu_bar = bar;
    }

    /// The bar at the top of the window (call before the panels, which start `MenuBar::DEFAULT_HEIGHT` lower).
    pub fn draw_bar(&self, c: &mut Canvas, t: &DrawTheme) {
        self.menu_bar.draw(c, t, self.size.width);
    }

    /// Open menus and the dialog over everything (call last).
    pub fn draw_overlays(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.sweep_dialog();
        let m = TextMeasure::new(c.atlas(), c.scale);
        self.ensure_layout(&m);
        if self.start.is_none() {
            self.dock.draw_overlay(c, t, &m);
        }
        self.draw_start(c, t);
        if let Some(e) = self.shortcuts.as_mut() {
            e.draw(c, t, cx);
        }
        if self.export.popover.is_some() {
            self.refresh_export_queue();
            let now = self.now_seconds();
            if let Some(p) = self.export.popover.as_mut() {
                let frame = p.frame();
                let origin = sq_draw::canvas::corner_toward(frame, p.anchor());
                c.open_motion_from(origin, 1, true, |c| p.draw(c, t, now));
            }
        }
        self.draw_quick_apply(c, t, &m, cx);
        self.menu_bar.draw_menus(c, t);
        let window = self.window();
        if let Some(d) = self.dialog.as_mut() {
            let card = d.card();
            if std::mem::take(&mut self.settings_card_instant) && d.message_text == "Settings" {
                d.draw(c, t, window, cx);
            } else {
                c.open_motion(card, 0, true, |c| d.draw(c, t, window, cx));
            }
            if d.footer_mascot && d.mascot_frame().width > 0.0 {
                ShellMascot::draw(SQMascotAnim::Wink, d.mascot_frame(), c);
            }
        }
    }

    // MARK: Dialogs

    /// The dialog on top, while it waits for an answer.
    pub fn dialog(&self) -> Option<&ShellDialog> {
        self.dialog.as_ref().filter(|d| !d.finished())
    }

    /// The dialog on top, mutably.
    pub fn dialog_mut(&mut self) -> Option<&mut ShellDialog> {
        self.dialog.as_mut().filter(|d| !d.finished())
    }

    /// Drops a dialog that was answered (Swift's `completion` cleared `dialog` itself).
    fn sweep_dialog(&mut self) {
        if self.dialog.as_ref().is_some_and(ShellDialog::finished) {
            // The flow that asked reads the typed values from the form after the answer (Swift read `d.form`).
            self.answered_form = self.dialog.take().and_then(|d| d.form);
            self.layout_dirty = true;
            self.request_frame();
        }
    }

    /// Answers and drops the dialog on top now (a flow that moves on to another screen).
    pub(crate) fn close_dialog(&mut self, r: SQDialogResponse) {
        if let Some(d) = self.dialog_mut() {
            d.press(r);
        }
        self.sweep_dialog();
        self.request_frame();
    }

    /// Shows `d` modally over the window and returns the ask for its answer (Swift `ask`).
    pub fn present(&mut self, mut d: ShellDialog) -> ModalAsk<SQDialogResponse> {
        self.menu_bar.dismiss();
        let (ask, answer) = modal();
        d.completion = Some(Box::new(move |r| {
            answer.answer(r);
        }));
        if d.message_text == "Settings" {
            self.shortcuts = None; // swapped with the card in this step
        }
        self.dialog = Some(d);
        self.layout_dirty = true;
        // A task presents it (the update offer after a feed answer): no input event follows to draw it.
        self.request_frame();
        ask
    }

    /// The queue the shell's own closures push flows to (a dialog button that starts a flow).
    pub fn menu_flows_handle(&self) -> Rc<RefCell<Vec<ShellFlow>>> {
        Rc::clone(&self.menu_flows)
    }

    /// A message the user dismisses (Swift `presentMessage`).
    pub fn present_message(&mut self, title: &str, detail: &str, tone: Option<crate::shell_dialog::Tone>) {
        let mut d = ShellDialog::new(title, detail);
        d.header_icon = tone;
        // Nobody waits for the answer; the sweep drops the dialog once it is closed.
        drop(self.present(d));
    }

    /// An error as a dialog (Swift `presentError`). The Swift log line (`SQLog.error`) waits for the Rust logger.
    pub fn present_error(&mut self, title: &str, error: &dyn std::error::Error) {
        self.present_message(title, &SQL10n::error_text(error), Some(crate::shell_dialog::Tone::Error));
    }

    /// The one after-open step of every way a project reaches the window (Open dialog, Recents, start screen cards, a drop,
    /// the dock, a double click, the command line and Revert): Recent, the quiet relink of media beside a moved or copied
    /// project folder with the Reconnect offer, and the notice of a repaired project. The session says what was opened (its
    /// file, or the damaged file it repaired), so no caller passes its own copy of that. A flow that swapped the project
    /// under the hosts also emits `ProjectChanged` itself; a launch has nothing to refresh.
    pub fn project_opened(&mut self, session: &sq_editor_session::EditorSession) {
        let Some(url) = session.file_url().or(session.salvaged_from()).map(std::path::Path::to_path_buf) else {
            return;
        };
        self.note_recent(&url);
        // A project with every file online has nothing to look for: no flow is queued (a flow queued at launch also took
        // the Enter of an import question in `enter_on_the_question_copies_into_a_project_opened_from_its_folder`).
        if !session.missing_media().is_empty() {
            self.offer_relink_if_needed();
        }
        if let Some(report) = session.salvage_report() {
            let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            self.present_message(
                sq_uikit::project_salvage_notice::TITLE,
                &sq_uikit::project_salvage_notice::detail(&name, report),
                None,
            );
        }
    }

    /// Puts `url` on top of the recent projects and tells the host to save them (Swift `noteNewRecentDocument`).
    pub fn note_recent(&mut self, url: &std::path::Path) {
        let now = self.wall_now();
        self.recents.note(url, now);
        self.emit(ShellEvent::RecentsChanged);
    }
}
