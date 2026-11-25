// Swift: AppController.swift (layout, handle chain and the hook wiring of the three panel hosts)
//! The window's panel hosts in one [`AppHost`]. The `sq-draw-shell` dock places them (Monitor, Library and Timeline get
//! the content frame of their panel; panels without a host draw a placeholder card). Input goes to the dialog, then the
//! menu, then the dock, then the hosts top-most first (Timeline, Library, Monitor); after every call the root answers what
//! the hosts queued. Menus the Monitor and Library ask for open in the one [`MenuController`], drawn last.
//! Requests that need another host's editor get a status line until their host is ported.

use crate::ShellDeferred;
use crate::audio_extraction;
use crate::chrome::{Chrome, ChromeAction, ChromeInputs, Mouse};
use crate::color_page_host::ColorPageHost;
use crate::persist::Persist;
use crate::project_host::media_ids;
use crate::timeline_commands::{self, CommandScope, TimelineLink};
use crate::timeline_header_host::TimelineHeaderHost;
use crate::tools_panel_host::ToolsPanelHost;
use crate::{
    EffectsApply, EffectsDeferred, EffectsHost, GraphicsHost, InspectorHost, LibraryDeferred, LibraryHost,
    MonitorDeferred, MonitorHost, ProjectHost, ShellHost, SourceMonitorHost, TextHost, TimelineHostEvent,
    TimelinePanelHost,
};
use sq_app_shell::{A11yAction, AppEvent, AppHost, HostCx};
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputKey, InputModifiers};
use sq_draw_library::effects::effects_draw_panel::EffectsEvent;
use sq_draw_library::effects::effects_tile_atlas::EffectsTileAtlas;
use sq_draw_library::library::library_draw_panel::{DragPhase, LibraryPanelEvent, LibraryRequest};
use sq_draw_library::library::library_draw_services::LibraryDrawServices;
use sq_draw_library::library::library_panel_logic::LibraryDragPayload;
use sq_draw_library::library::library_panel_model::LibraryModelEvent;
use sq_draw_monitor::meter_panel::{MeterPanel, MeterPanelEvent};
use sq_draw_monitor::monitor_panel::PanelEvent;
use sq_draw_shell::{
    DockEvent, DragPhase as ProjectDragPhase, FormRow, MenuController, ProjectListEvent, ShellDialog, ShellDock,
    ShellEvent, ShellFlow, ShellForm,
};
use sq_draw_timeline::action::TimelineAction;
use sq_draw_timeline::app_host::TimelineAppHost;
use sq_draw_timeline::host::TimelineEditorRequest;
use sq_draw_timeline::{TimelineDropSource, drop_items};
use sq_editor_session::{
    Change, EditorSession, PresetApplyModeSetting, ProjectMenuAction, SplitAxis, TransitionDefaults, WorkspaceStore,
};
use sq_inspector_ui::clip_sections::SectionAction;
use sq_inspector_ui::graphics::panel_draw::PanelRequest;
use sq_inspector_ui::text::template_tiles::TextTemplatePlacement;
use sq_library::library_folder_store::MemorySettings;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::SystemTime;

/// What a drag from the Project or Library panel carries over the timeline.
enum DropKind {
    /// Project media.
    Media(Vec<sq_core_time::Id>),
    /// Files from the Library, imported on release when new.
    Files(Vec<PathBuf>),
    /// A saved title block.
    Title(sq_core_time::Id),
    /// A built-in template.
    Template(String),
}

/// Owns the panel hosts of the editing window and the dock that places them.
pub struct AppRoot {
    /// The eyedropper shared with the monitor and the inspector: while it samples, a press outside the Program picture
    /// picks from the app's own last frame, and the loupe follows the pointer over everything.
    dropper: Option<crate::Eyedropper>,
    /// The loupe over the window frame and the pointer (points).
    window_loupe: Option<(sq_draw_monitor::color_loupe::ColorLoupe, CGPoint)>,
    /// The modifiers of the last press or drag: drags that start in a panel (Library, Project) read the live keys here
    /// (Swift hosts read `NSEvent.modifierFlags`).
    live_modifiers: InputModifiers,
    /// The Source drag running now (streams and the pointer in window pixels): its tile follows the pointer.
    source_drag_tile: Option<(SourceStreams, f32, f32)>,
    /// Conform to Constant Frame Rate jobs (`None`: the app has no probe, the menu item says so).
    conform: Option<crate::ConformJobs>,
    /// The Program/Source monitor.
    pub monitor: MonitorHost,
    /// The Source monitor (`None`: the app has no second engine, double clicks on media say so).
    pub source: Option<SourceMonitorHost>,
    /// The monitor that fills the window (`root/full_screen.rs`).
    full_screen: Option<PanelID>,
    /// The Library panel.
    pub library: LibraryHost,
    /// The Effects panel (`None`: the panel draws a placeholder).
    pub effects: Option<EffectsHost>,
    /// The thumbnail atlas the posters and the Effects stills are packed into.
    atlas: crate::SharedAtlas,
    /// Posters, waveforms and the offline state the timeline's clips draw.
    timeline_media: std::rc::Rc<crate::timeline_media::TimelineMedia>,
    /// The Graphics panel (`None`: the panel draws a placeholder).
    pub graphics: Option<GraphicsHost>,
    /// The Library's keystones as saved Intro / Outro animations of the Graphics panel's text block.
    animation_keystones: std::rc::Rc<crate::animation_keystones::AnimationKeystones>,
    /// The Text panel (`None`: the panel draws a placeholder).
    pub text: Option<TextHost>,
    /// The audio meters beside the timeline (`None`: the panel draws a placeholder).
    pub meter: Option<MeterPanel>,
    /// The stored listening level was handed to the engine.
    monitor_sent: bool,
    /// The Marker List panel (`None`: the panel draws a placeholder).
    pub marker_list: Option<crate::MarkerListHost>,
    /// The session facts behind the tab, tool, transport and timeline accessibility nodes.
    access: crate::session_access::SessionAccess,
    /// The Project panel: the project's media, sequences and folders.
    pub project: ProjectHost,
    /// The timeline.
    pub timeline: TimelinePanelHost,
    /// The header bar and tool strip above the timeline lanes.
    pub header: TimelineHeaderHost,
    /// The Tools panel: the tool column left of the timeline.
    pub tools: ToolsPanelHost,
    /// The clip sections (Effect Controls panel).
    pub inspector: InspectorHost,
    /// Menu bar, dialogs and the start window.
    pub shell: ShellHost,
    /// The start screen's card pictures (their uploads leave with the other panels').
    start_posters: crate::SharedStartPosters,
    /// The dockable layout: where each panel's content goes.
    pub dock: ShellDock,
    /// The one menu system: drawn last, gets input first.
    pub menu: MenuController,
    dialog: Option<ShellDialog>,
    /// Where the dock layout is saved (`None`: not saved).
    workspaces_path: Option<PathBuf>,
    /// Where the recent projects are saved (`None`: not saved).
    recents_path: Option<PathBuf>,
    /// The project the app was launched with (command line) is on the recent list already.
    /// Stored defaults, floating frames, autosave and recovery (`None`: nothing is kept).
    persist: Option<Persist>,
    /// Clock of the Auto quality governor.
    started: std::time::Instant,
    /// The active sequence and its own preview quality as last applied to the Program monitor.
    sequence_quality: Option<(sq_core_time::Id, Option<sq_core_model::SequencePreviewQuality>)>,
    /// The Program picture's size in physical pixels last sent to the engine.
    view_px: (u32, u32),
    popover_guard: crate::popover_guard::PopoverCloseGuard,
    /// The user's effect and transition defaults and their file (Swift `EffectDefaultsLibrary.shared`).
    effect_defaults: Option<Box<sq_editor_session::EffectDefaultsLibrary>>,
    /// The loaded defaults still have to reach the session and Effect Controls (they need the session).
    effect_defaults_unapplied: bool,
    /// Thermal state, Low Power Mode and memory pressure on their way to the session and the caches.
    load_watch: crate::load_watch::LoadWatch,
    /// The project version the dialogue pause store was last pruned at.
    silences_pruned_at: u64,
    /// What the editor is opening (r8 loading state); `None` once loaded. See [`AppRoot::set_opening`].
    opening: Option<String>,
    edit_api: Option<crate::edit_api_host::EditApiController>,
    /// The Edit API run state the shell last heard of (`state_changed`): a new one reaches an open Preferences page.
    edit_api_seen: Option<sq_draw_shell::EditApiState>,
    /// The Preferences > Media cache size line.
    cache_used: media_prefs::CacheUsed,
    /// Asks the window loop for a frame; the workers of this root call it after they answered (an idle window sleeps
    /// until something wakes it, and nothing polls a worker's channel then).
    wake: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// The timeline's view commands the shell hooks queued (`None`: the shell has no timeline hooks).
    timeline_link: Option<TimelineLink>,
    /// The Program picture Export Frame saves.
    frame_picture: Option<crate::MonitorPicture>,
    /// An Export Frame waiting for its full-size picture.
    frame_grab: Option<crate::FrameGrab>,
    /// Templates waiting for a preview image, and the frame grab of the first one.
    template_saves: Vec<crate::template_thumbnail::PendingTemplate>,
    template_grab: Option<crate::FrameGrab>,
    /// The view settings (track heights, toggles); in memory until the app's settings reach the hosts.
    settings: MemorySettings,
    /// The title row and status bar around the dock.
    chrome: Chrome,
    /// The Color page's panels (Color settings, Steps, Sources, Scopes, viewer header).
    color: ColorPageHost,
    /// The user's Looks (`looks.json` under the support folder): the Text panel's styles are a view of it.
    looks: Option<std::sync::Arc<sq_editor_session::LookStore>>,
    /// The audio preset each track's audio controls set (Swift `ClipSectionsDraw.audioPresets`); a track without an
    /// entry follows its role. In memory like Swift's: the export and playback read it.
    /// The Magic Mask and Stabilizer analysis jobs (`None`: nothing is analyzed).
    analysis: Option<crate::analysis_links::analysis::AnalysisLinks>,
    /// The Stabilizer row shows a real run (so an idle pump does not clear a demo state).
    stabilize_shown: bool,
    /// Opens files in their default app (Edit Original); the tests swap in one that records.
    opener: Box<dyn crate::FileManager>,
    /// The Library requests that wait for a chooser or a dialog.
    library_flows: library_flows::LibraryFlows,
    /// The Effects panel's open folder-name dialog and what the name is for.
    effects_name:
        Option<(sq_runtime::ModalAsk<SQDialogResponse>, sq_draw_library::effects::effects_draw_panel::NamePurpose)>,
    /// A Whoosh whose sound is still being imported: the file and the cuts to place it on.
    pending_whoosh: Option<(std::path::PathBuf, Vec<sq_core_time::Time>)>,
    /// Extract Audio jobs on their worker threads, each with the item's name.
    extractions: Vec<Extraction>,
}

/// One Extract Audio job: the worker's answer (the written file).
struct Extraction {
    rx: std::sync::mpsc::Receiver<Result<PathBuf, sq_editor_session::AudioExtractionFailure>>,
}

fn new_dock(store: WorkspaceStore) -> ShellDock {
    let mut dock = ShellDock::new(store);
    dock.can_float_windows = true;
    dock.owns_header =
        Box::new(|p| matches!(p, PanelID::ProgramMonitor | PanelID::SourceMonitor | PanelID::AudioMeter));
    // The editing panel has the keyboard from the start (Premiere's default): S, Shift+Backspace and the other
    // Timeline-scope keys work before the first click, not only after one.
    dock.set_focused(Some(PanelID::Timeline));
    dock
}

/// Rows of Effects stills kept in the shared atlas (8 per row).
const EFFECTS_ROWS: usize = 12;

/// What became of a command a panel asked the shell to run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PanelCommand {
    Ran,
    /// Disabled now: nothing happens and nothing is said (the row or button is drawn dimmed).
    Disabled,
    /// Enabled but nobody runs it: a bug, never a status line (the dead-commands test fails for it).
    Dead,
}

impl AppRoot {
    /// Checks the staged file once more (hash and signature), then puts it in place. A file that does not pass is
    /// deleted and never applied.
    pub fn apply_verified_update(update: &sq_editor_session::PendingUpdate, restart: bool) -> Result<(), String> {
        if let Err(why) = update.verify() {
            let _ = std::fs::remove_file(&update.file);
            return Err(why.message());
        }
        sq_platform::app_update::apply_update(&update.file, &update.version, restart).map_err(|e| match e {
            sq_platform::app_update::ApplyError::Unsupported => {
                "This system cannot install updates from the app yet.".to_string()
            }
            sq_platform::app_update::ApplyError::Failed(why) => why,
        })
    }

    /// Runs a menu command a panel asked for (context menu rows, header buttons, monitor rows). A disabled command does
    /// nothing and says nothing; an enabled one nobody runs is a bug (`debug_assert`, and the dead-commands test).
    pub(crate) fn run_panel_command(
        &mut self,
        cx: &mut HostCx,
        c: sq_uikit::editor_command::EditorCommand,
    ) -> PanelCommand {
        if !self.shell.command_enabled(cx.session, c) {
            return PanelCommand::Disabled;
        }
        if self.shell.run_command(cx, c) {
            return PanelCommand::Ran;
        }
        debug_assert!(false, "{c:?} is enabled but nobody runs it");
        PanelCommand::Dead
    }

    /// Where Export's right edge sits from the window's right edge (Windows keeps room for the caption buttons).
    pub fn set_title_right_margin(&mut self, margin: f64) {
        self.chrome.set_right_margin(margin);
    }

    /// The title row's clickable frames and where the rows end: the Windows caption drags the window by the rest.
    pub fn title_drag(&self) -> (Vec<CGRect>, f64) {
        self.chrome.title_drag()
    }

    /// Runs `wake` on a worker thread whenever a poster decode or an analysis job has news (the app posts a redraw to its
    /// inbox). Call it after `with_analysis`.
    pub fn set_wake(&mut self, wake: std::sync::Arc<dyn Fn() + Send + Sync>) {
        self.project.set_wake(std::sync::Arc::clone(&wake));
        self.library.set_wake(std::sync::Arc::clone(&wake));
        self.timeline_media.set_wake(std::sync::Arc::clone(&wake));
        if let Some(conform) = &mut self.conform {
            conform.set_wake(std::sync::Arc::clone(&wake));
        }
        if let Some(analysis) = &mut self.analysis {
            analysis.set_wake(std::sync::Arc::clone(&wake));
        }
        self.shell.shell().flow_env.services.set_wake(std::sync::Arc::clone(&wake));
        self.start_posters.borrow_mut().set_wake(std::sync::Arc::clone(&wake));
        self.color.set_wake(std::sync::Arc::clone(&wake));
        self.wake = Some(wake);
    }

    /// A root over the hosts, docked in the default workspace.
    pub fn new(
        monitor: MonitorHost,
        library: LibraryHost,
        timeline: TimelinePanelHost,
        inspector: InspectorHost,
        shell: ShellHost,
    ) -> AppRoot {
        // The Project panel's posters and the Color page's Sources share one thumbnail atlas slot.
        let atlas = crate::SharedAtlas::default();
        let shared = std::rc::Rc::clone(&atlas);
        let mut project = ProjectHost::new();
        project.share_atlas(std::rc::Rc::clone(&atlas));
        let mut color = ColorPageHost::default();
        color.share_atlas(atlas);
        let mut library = library;
        library.panel_host().panel.model.set_templates(Box::new(crate::text_catalog::CatalogTemplates));
        library.share_atlas(std::rc::Rc::clone(&shared));
        let timeline_media = std::rc::Rc::new(crate::timeline_media::TimelineMedia::new(std::rc::Rc::clone(&shared)));
        let mut timeline = timeline;
        timeline.inner().panel.media = Some(std::rc::Rc::clone(&timeline_media) as _);
        let duck_waves = std::rc::Rc::clone(&timeline_media);
        timeline.attach_waveforms(std::rc::Rc::new(move |id| {
            sq_draw_timeline::TimelineMediaSource::waveform(&*duck_waves, id)
        }));
        // The shell's audio tools (Remove Silences, Bake Live Duck to Keys, Audio Gain) read the same waveforms.
        let mut shell = shell;
        shell.shell().focus = Some(PanelID::Timeline);
        let start_posters: crate::SharedStartPosters =
            std::rc::Rc::new(std::cell::RefCell::new(crate::StartPosters::new(std::rc::Rc::clone(&shared))));
        let asked = std::rc::Rc::clone(&start_posters);
        shell.shell().start_poster =
            Some(std::rc::Rc::new(move |path: &str, seconds: f64| asked.borrow_mut().poster(path, seconds)));
        let waves = std::rc::Rc::clone(&timeline_media);
        shell
            .shell()
            .flow_env
            .services
            .attach_waveforms(std::rc::Rc::new(move |id| sq_draw_timeline::TimelineMediaSource::waveform(&*waves, id)));
        AppRoot {
            start_posters,
            live_modifiers: InputModifiers::NONE,
            source_drag_tile: None,
            conform: None,
            monitor,
            source: None,
            full_screen: None,
            library,
            effects: None,
            atlas: shared,
            timeline_media,
            graphics: None,
            animation_keystones: std::rc::Rc::default(),
            text: None,
            meter: None,
            monitor_sent: false,
            marker_list: None,
            access: crate::session_access::SessionAccess::default(),
            project,
            timeline,
            header: TimelineHeaderHost::new(DrawTheme::default()),
            tools: ToolsPanelHost::new(DrawTheme::default()),
            inspector,
            shell,
            dropper: None,
            window_loupe: None,
            dock: new_dock(WorkspaceStore::default()),
            menu: MenuController::new(),
            dialog: None,
            workspaces_path: None,
            recents_path: None,
            persist: None,
            started: std::time::Instant::now(),
            sequence_quality: None,
            view_px: (0, 0),
            popover_guard: crate::popover_guard::PopoverCloseGuard::default(),
            effect_defaults: None,
            effect_defaults_unapplied: false,
            load_watch: crate::load_watch::LoadWatch::default(),
            silences_pruned_at: u64::MAX,
            opening: None,
            edit_api: None,
            edit_api_seen: None,
            cache_used: media_prefs::CacheUsed::Unknown,
            wake: None,
            timeline_link: None,
            frame_picture: None,
            template_saves: Vec::new(),
            template_grab: None,
            frame_grab: None,
            settings: MemorySettings::default(),
            chrome: Chrome::default(),
            color,
            looks: None,
            analysis: None,
            stabilize_shown: false,
            opener: Box::new(crate::SystemPlatform),
            library_flows: Default::default(),
            effects_name: None,
            pending_whoosh: None,
            extractions: Vec::new(),
        }
    }

    /// Adds the Source monitor as the panel next to the Program monitor.
    /// Enables Conform to Constant Frame Rate; `probe` reads the conformed file like an import does.
    pub fn with_conform(mut self, probe: sq_editor_session::ConformProbe) -> AppRoot {
        // The same probe serves Reconnect / Replace Media and the project imports (`ShellServices::probe`).
        let shared = std::sync::Arc::clone(&probe);
        self.shell.shell().flow_env.services.attach_probe(std::sync::Arc::new(move |path| shared(path).ok()));
        self.conform = Some(crate::ConformJobs::new(probe));
        self
    }

    pub fn with_source(mut self, mut source: SourceMonitorHost) -> AppRoot {
        // The monitor card's header is the Program | Source switch; each side marks its own tab.
        let tabs = vec![SQL10n::string("Program"), SQL10n::string("Source")];
        self.monitor.panel.tabs.clone_from(&tabs);
        self.monitor.panel.selected_tab = 0;
        source.set_tabs(tabs);
        self.color.set_source_picture(source.picture().clone());
        self.source = Some(source);
        if let Some(persist) = &self.persist {
            let stored = sq_editor_session::AppSettings::load(&*persist.defaults().borrow());
            self.apply_monitor_settings(&stored);
        }
        self
    }

    /// Adds the Effects panel: its drags show a ghost and drop on the timeline and Effect Controls.
    pub fn with_effects(mut self, mut effects: EffectsHost) -> AppRoot {
        // The stills get a block of the shared thumbnail atlas; slot 5 belongs to the Source picture.
        let (w, h) = EffectsTileAtlas::block_size(EFFECTS_ROWS);
        if let Some(at) = self.atlas.borrow_mut().place(w, h) {
            effects.panel_host().atlas.bind(sq_app_shell::ATLAS_SLOT, at, sq_app_shell::ATLAS_SIZE, EFFECTS_ROWS);
        }
        self.effects = Some(effects);
        self
    }

    /// Adds the Graphics panel: Edit Graphics in Effect Controls brings it forward on the selected Graphic.
    /// The Color page's white-balance eyedropper samples the Program monitor picture through `eyedropper`.
    /// The LUT folder of the Color page (import, favorites, the library list).
    pub fn with_color_luts(mut self, library: sq_library::lutlibrary::LUTLibrary) -> AppRoot {
        self.color = std::mem::take(&mut self.color).with_lut_library(library);
        self
    }

    pub fn with_color_eyedropper(mut self, eyedropper: crate::Eyedropper) -> AppRoot {
        self.dropper = Some(eyedropper.clone());
        self.color = std::mem::take(&mut self.color).with_eyedropper(eyedropper);
        self
    }

    pub fn with_graphics(mut self, mut graphics: GraphicsHost) -> AppRoot {
        graphics.panel().set_animation_keystones(std::rc::Rc::<crate::animation_keystones::AnimationKeystones>::clone(
            &self.animation_keystones,
        ));
        if let Some(looks) = &self.looks {
            graphics = graphics.with_looks(std::sync::Arc::clone(looks));
        }
        self.graphics = Some(graphics);
        self
    }

    /// Adds the Text panel: Transcript, Captions and Style over the session.
    pub fn with_text(mut self, mut text: TextHost) -> AppRoot {
        text.panel().style.set_animation_keystones(
            std::rc::Rc::<crate::animation_keystones::AnimationKeystones>::clone(&self.animation_keystones),
        );
        self.text = Some(text);
        self
    }

    /// Adds the audio meter panel; every frame it is fed the Program engine's mix peaks and loudness.
    pub fn with_meter(mut self, meter: MeterPanel) -> AppRoot {
        self.meter = Some(meter);
        self
    }

    /// Adds the Marker List panel that sits next to the Project panel.
    pub fn with_lists(mut self, marker_list: crate::MarkerListHost) -> AppRoot {
        self.marker_list = Some(marker_list);
        self
    }

    /// The Scopes on the Color page measure the frames put into `picture` (the Program monitor's).
    pub fn with_scope_picture(mut self, picture: crate::MonitorPicture) -> AppRoot {
        self.frame_picture = Some(picture.clone());
        self.color.set_picture(picture);
        self
    }

    /// Connects the shell's [`TimelineHooks`] so snapping, zoom, track heights, tools and the other view commands reach the
    /// timeline panel; the menus follow the key map the shell holds.
    pub fn with_timeline_link(mut self, link: TimelineLink) -> AppRoot {
        self.timeline_link = Some(link);
        let map = self.shell.shell().map.clone();
        self.header.set_command_map(map.clone());
        self.tools.set_command_map(map.clone());
        self.timeline.set_command_map(map);
        self
    }

    /// Runs the Magic Mask and Stabilizer analysis jobs each pump, with progress in the status bar.
    pub fn with_analysis(mut self, analysis: crate::analysis_links::analysis::AnalysisLinks) -> AppRoot {
        self.analysis = Some(analysis);
        self
    }

    /// Keeps the dock layout in `workspaces` (loaded now, saved on every change) and the recent projects in `recents`
    /// (saved when they change; the caller loaded them into the shell).
    pub fn with_storage(mut self, workspaces: PathBuf, recents: PathBuf) -> AppRoot {
        self.dock = new_dock(WorkspaceStore::load(&workspaces));
        self.shell.shell().focus = self.dock.focused();
        self.workspaces_path = Some(workspaces);
        self.recents_path = Some(recents);
        self
    }

    /// Keeps the settings (`prefs.json`), the floating panel frames and the open project's autosave under `support`,
    /// and offers the last autosave of a run that did not end cleanly.
    pub fn with_prefs(self, support: &std::path::Path) -> AppRoot {
        self.with_prefs_store(support, crate::persist::FileDefaults::shared(support))
    }

    /// Runs the local Edit API when the stored switch (`sq.api.enabled`, Preferences > Advanced) is on; its requests
    /// reach the session through `sender` (the app inbox). Call after the prefs are set.
    pub fn with_edit_api(
        mut self,
        sender: sq_runtime::channel::Sender<sq_app_shell::AppMessage>,
        support: &std::path::Path,
    ) -> AppRoot {
        let controller = crate::edit_api_host::EditApiController::new(sender, support);
        if let Some(persist) = &self.persist {
            self.shell.shell().flow_env.edit_api = Some(controller.shell_api(persist.defaults()));
        }
        self.edit_api = Some(controller);
        self
    }

    /// [`AppRoot::with_prefs`] over a store the panels already share.
    pub fn with_prefs_store(
        mut self,
        support: &std::path::Path,
        defaults: std::rc::Rc<std::cell::RefCell<crate::persist::FileDefaults>>,
    ) -> AppRoot {
        let persist = Persist::open_with(support, defaults);
        self.dock.load_floating(persist.floating());
        let store: sq_draw_shell::SharedDefaults = persist.defaults();
        let shell = self.shell.shell();
        shell.defaults = Box::new(sq_draw_shell::SharedView(std::rc::Rc::clone(&store)));
        shell.settings = std::rc::Rc::clone(&store);
        // Preferences > Audio > Audio Output: the devices that exist now; the stored choice is applied at once.
        shell.preferences.audio_outputs = Some(
            sq_audio_out::output::devices::available()
                .into_iter()
                .map(|d| sq_editor_session::AudioOutputDevice::new(&d.uid, &d.name))
                .collect(),
        );
        let stored = sq_editor_session::AppSettings::load(&sq_draw_shell::SharedView(std::rc::Rc::clone(&store)));
        sq_audio_out::output::devices::set_preferred(stored.audio_output_uid.clone());
        // Preferences > Dropped Frames: the Program monitor's drop dot (Swift `MonitorCardHost`).
        self.monitor.panel.model.drop_indicator_enabled = stored.drop_indicator;
        shell.export.stem_presets =
            Some(sq_export::core::stems::StemPresetStore::new(support.join("stem-presets.json")));
        self.project.set_settings_store(std::rc::Rc::clone(&store));
        self.inspector.set_settings_store(std::rc::Rc::clone(&store));
        let view = sq_draw_shell::BytesView(store);
        self.library.set_apply_mode(Box::new(move || PresetApplyModeSetting::load(&view)));
        self.shell.hold_welcome(true, false); // until the first pump has scanned for a recovery
        self.persist = Some(persist);
        self.apply_monitor_settings(&stored);
        let mut ids = sq_core_time::RandomIds;
        let now = sq_core_time::Timestamp::from_unix_seconds(
            SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64()),
        );
        let library = sq_editor_session::EffectDefaultsLibrary::new(
            Some(sq_library::effect_defaults_file::EffectDefaultsFile::file_url_in(support)),
            now,
            &mut ids,
        );
        // Preferences > Editing lists the defaults the Effect Controls panel saves.
        self.shell.shell().preferences.effect_defaults = Some(library.defaults().clone());
        self.effect_defaults = Some(Box::new(library));
        self.effect_defaults_unapplied = true;
        let url = sq_editor_session::LookStore::default_url(support);
        let legacy = sq_editor_session::LookStore::legacy_text_styles_url(support);
        if self.looks.is_none() {
            let store = std::sync::Arc::new(sq_editor_session::LookStore::new(Some(url), Some(legacy), None, None));
            self.attach_looks(store);
        }
        self
    }

    /// The one Look store of the app, shared with the Text panel's caption Looks (call before `with_prefs_store`).
    #[must_use]
    pub fn with_look_store(mut self, looks: std::sync::Arc<sq_editor_session::LookStore>) -> Self {
        self.attach_looks(looks);
        self
    }

    /// Every panel that lists or saves Looks (Inspector text block, Graphics text block) works on this one store.
    fn attach_looks(&mut self, looks: std::sync::Arc<sq_editor_session::LookStore>) {
        self.inspector.set_looks(std::sync::Arc::clone(&looks));
        if let Some(graphics) = self.graphics.take() {
            self.graphics = Some(graphics.with_looks(std::sync::Arc::clone(&looks)));
        }
        self.looks = Some(looks);
    }

    /// Writes the Looks a text block changed to the store (a failed write is shown, never dropped).
    fn save_text_styles(
        &self,
        library: &sq_inspector_ui::text::style_library::TextStyleLibrary,
        lines: &mut Vec<String>,
    ) {
        match &self.looks {
            Some(store) => {
                if let Err(e) = sq_inspector_ui::text::style_library::TextStyleStore::save(library, store) {
                    lines.push(e.to_string());
                }
            }
            None => lines.push("Text styles are not saved here yet.".into()),
        }
    }

    /// The Text panel's styles as stored (built-ins plus the user's).
    pub fn text_styles(&self) -> Option<sq_inspector_ui::text::style_library::TextStyleLibrary> {
        self.looks.as_deref().map(sq_inspector_ui::text::style_library::TextStyleStore::load)
    }

    fn save_file(path: Option<&PathBuf>, bytes: Option<Vec<u8>>) {
        // A failed write is dropped: the layout and the recents are only conveniences.
        if let (Some(path), Some(bytes)) = (path, bytes) {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(path, bytes);
        }
    }

    /// Shows `dialog` over the window; it takes every event until it finished.
    pub fn show_dialog(&mut self, dialog: ShellDialog) {
        self.dialog = Some(dialog);
    }

    /// Whether a dialog is up.
    pub fn has_dialog(&self) -> bool {
        self.dialog.is_some()
    }

    /// While the eyedropper samples: Esc cancels, the loupe follows the pointer and a press picks, everywhere except over
    /// the Program picture (the monitor answers there with the picture's own pixels and linear light). `e` is in window
    /// pixels, the canvas in points. True when the event is used up.
    fn sample_window(&mut self, e: &InputEvent, scale: f32) -> bool {
        let Some(dropper) = self.dropper.as_ref().filter(|d| d.is_armed()) else {
            self.window_loupe = None;
            return false;
        };
        let k = f64::from(scale.max(0.01));
        let canvas = self.monitor.panel.canvas_rect();
        let over_picture = |x: f32, y: f32| canvas.contains(CGPoint::new(f64::from(x) / k, f64::from(y) / k));
        match *e {
            InputEvent::KeyDown { key: InputKey::Escape, .. } => {
                dropper.cancel();
                self.window_loupe = None;
                true
            }
            InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } => {
                let (px, py) = (f64::from(x), f64::from(y));
                self.window_loupe = if over_picture(x, y) {
                    None
                } else {
                    dropper.window_loupe(px, py).map(|l| (l, CGPoint::new(px / k, py / k)))
                };
                !over_picture(x, y)
            }
            InputEvent::MouseDown { x, y, .. } if !over_picture(x, y) => {
                self.window_loupe = None;
                dropper.pick_window(f64::from(x), f64::from(y))
            }
            _ => false,
        }
    }

    fn monitor_frame(&self) -> CGRect {
        let d = &self.dock;
        let program = d.content_frame(PanelID::ProgramMonitor);
        // Without a Source host the Program monitor takes over the Source panel's slot.
        if self.source.is_some() { program } else { program.or_else(|| d.content_frame(PanelID::SourceMonitor)) }
            .unwrap_or_default()
    }

    /// A click on the monitor header's Program | Source switch.
    fn select_monitor_tab(&mut self, i: usize) {
        self.dock.show(if i == 1 { PanelID::SourceMonitor } else { PanelID::ProgramMonitor });
    }

    /// The resize cursor over a divider of the dock (the host maps it to the window's pointer).
    fn request_divider_cursor(&self, e: &InputEvent, cx: &mut HostCx) {
        let (InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. }) = *e else { return };
        let at = CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale));
        if let Some(d) = self.dock.divider_at(at) {
            cx.ui.hover.request(Some(if d.axis == SplitAxis::Horizontal {
                DrawCursor::ResizeLeftRight
            } else {
                DrawCursor::ResizeUpDown
            }));
        }
    }

    fn open_menu(&mut self, cx: &HostCx, items: Vec<SQMenuItem>, anchor: CGRect, pointer: Option<CGPoint>) {
        self.menu.pop_up(items, anchor, pointer, &cx.measure());
    }

    /// Serves one Library request: Reveal and Whoosh here, the chooser and dialog flows in `library_flows`.
    fn library_request(&mut self, cx: &mut HostCx, r: LibraryRequest, lines: &mut Vec<String>) {
        match r {
            LibraryRequest::Reveal(urls) => {
                use crate::project_services::{FileManager, SystemPlatform};
                for url in urls {
                    if let Err(e) = SystemPlatform.reveal(&url) {
                        lines.push(e);
                    }
                }
            }
            LibraryRequest::ImportMedia => cx.emit(AppEvent::Flow(ShellFlow::ImportAnything)),
            LibraryRequest::Whoosh(url) => lines.extend(self.whoosh(cx, &url)),
            // The Color LUT popup's pick: the look slot of the clip the Color page shows.
            LibraryRequest::ApplyLut(path) => {
                if !self.color.apply_look_lut(&path) {
                    lines.push("Open the Color page on a clip to apply a LUT.".to_string());
                }
            }
            other => {
                let mut env = library_flows::Env {
                    model: &mut self.library.panel_host().panel.model,
                    shell: self.shell.shell(),
                    files: &mut *cx.services.files,
                };
                self.library_flows.start(other, &mut env);
                self.library_flows.poll(&mut env);
            }
        }
    }

    /// Whoosh at Cuts (Swift `LibraryHost.whoosh`): the cuts come from the selected edges, else from the selected clips;
    /// the sound is imported when it is not a project item yet and placed as soon as the import has landed.
    fn whoosh(&mut self, cx: &mut HostCx, url: &std::path::Path) -> Vec<String> {
        let edges = self.timeline.inner().panel.selected_edges();
        let cuts = cx.session.selected_cuts(&edges);
        if cuts.is_empty() {
            return vec!["Select a cut first: click an edge, or select clips next to each other.".to_string()];
        }
        self.pending_whoosh = Some((url.to_path_buf(), cuts));
        if Self::media_of(cx, url).is_none() {
            cx.emit(AppEvent::Flow(ShellFlow::ImportMixed(vec![url.to_path_buf()])));
        }
        self.poll_whoosh(cx)
    }

    /// The menu command (Swift `LibraryHost.whooshFromSFXBin`): the SFX bin's whoosh sound, or the bin is made and the
    /// status line says what to do.
    fn whoosh_from_sfx_bin(&mut self, cx: &mut HostCx) -> Vec<String> {
        let model = &mut self.library.panel_host().panel.model;
        if let Some(url) = model.whoosh_sound() {
            return self.whoosh(cx, &url);
        }
        let existed = model.sfx_folder().is_some();
        model.ensure_sfx_bin();
        vec![
            if existed {
                "The SFX folder is empty. Add sound files to it (Library item menu: Add to SFX Folder)."
            } else {
                "SFX bin created in the Library. Add whoosh sounds to it, then run this again."
            }
            .to_string(),
        ]
    }

    fn media_of(cx: &HostCx, url: &std::path::Path) -> Option<sq_core_time::Id> {
        let path = sq_os::paths::stored(url);
        cx.session.project().media.iter().find(|m| sq_os::paths::stored_form(&m.path) == path).map(|m| m.id)
    }

    /// Places the waiting whoosh once its sound is a project item.
    fn poll_whoosh(&mut self, cx: &mut HostCx) -> Vec<String> {
        let Some((url, cuts)) = self.pending_whoosh.clone() else { return Vec::new() };
        let Some(media) = Self::media_of(cx, &url) else { return Vec::new() };
        self.pending_whoosh = None;
        if cx.session.add_whoosh(media, &cuts) {
            Vec::new()
        } else {
            vec![cx.session.last_error().unwrap_or("Could not place the sound on the cuts.").to_string()]
        }
    }

    /// The Library model's hooks (`onFoldersChanged`, `onInsertTitleBlock`, `onImportWorkspaces`).
    fn library_model_event(&mut self, cx: &mut HostCx, e: LibraryModelEvent, lines: &mut Vec<String>) {
        match e {
            LibraryModelEvent::FoldersChanged(folders) => {
                let mut store = sq_draw_shell::BytesView(std::rc::Rc::clone(&self.shell.shell().settings));
                LibraryDrawServices::persist_folders(&folders, &mut store);
            }
            LibraryModelEvent::InsertTitleBlock(item, time) => {
                lines.push(TextTemplatePlacement::insert_title(&item, time, cx.session));
            }
            LibraryModelEvent::ImportWorkspaces(w) => lines.extend(self.import_workspaces(&w)),
            LibraryModelEvent::ApplyPreset(..) => {}
        }
    }

    /// Project > Extract Audio: the sound of the item as "Name (audio).m4a" next to the project (else the source file),
    /// written on a worker; the file is imported when it is done (`AudioExtraction`, `ProjectPanelModel.extractAudio`).
    /// New Color Matte… (Sequence > Layer, the Project panel menu): the dialog the timeline menu opens.
    fn open_color_matte(&mut self, cx: &mut HostCx, lines: &mut Vec<String>) {
        let request = TimelineEditorRequest::NewColorMatte;
        match self.timeline.editor_dialog(cx.session, &request) {
            Some(d) => self.show_dialog(d),
            None => lines.push(request.unavailable()),
        }
    }

    fn start_extraction(&mut self, cx: &mut HostCx, id: sq_core_time::Id) {
        const TITLE: &str = "Extract Audio";
        let Some(media) = cx.session.project().media(id).cloned() else { return };
        if cx.session.missing_media().iter().any(|m| m.id == id) {
            let detail = audio_extraction::failure_text(&sq_editor_session::AudioExtractionFailure::Offline);
            return self.shell.shell().present_message(TITLE, &detail, None);
        }
        let export = &self.shell.shell().export;
        let (Some(mix), Some(encoder)) = (export.stem_audio.clone(), export.stem_encoder.clone()) else {
            return self.shell.shell().present_message(TITLE, "Extract Audio is not available here yet.", None);
        };
        let folder = cx
            .session
            .file_url()
            .and_then(|p| p.parent())
            .map(std::path::Path::to_path_buf)
            .or_else(|| std::path::Path::new(&media.path).parent().map(std::path::Path::to_path_buf))
            .unwrap_or_default();
        let (tx, rx) = std::sync::mpsc::channel();
        let job = media.clone();
        let wake = self.wake.clone();
        std::thread::spawn(move || {
            let mut ids = sq_core_time::RandomIds;
            let cancel = sq_export::core::error::CancelToken::default();
            let done = audio_extraction::extract(&job, &folder, &mut ids, &mix, &encoder, &cancel, &mut |_| {});
            let _ = tx.send(done);
            // The idle window imports the file and reports a failure only on a frame.
            if let Some(wake) = wake {
                wake();
            }
        });
        self.extractions.push(Extraction { rx });
        cx.ui.request_animation();
    }

    /// Imports the files of finished extractions and reports the failures.
    fn poll_extractions(&mut self, cx: &mut HostCx) {
        if self.extractions.is_empty() {
            return;
        }
        let mut waiting = Vec::new();
        for job in std::mem::take(&mut self.extractions) {
            match job.rx.try_recv() {
                Ok(Ok(url)) => cx.emit(AppEvent::Flow(ShellFlow::ImportMixed(vec![url]))),
                Ok(Err(e)) => {
                    self.shell.shell().present_message("Extract Audio", &audio_extraction::failure_text(&e), None)
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => waiting.push(job),
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    let detail = "Extract Audio: the file could not be added.";
                    self.shell.shell().present_message("Extract Audio", detail, None);
                }
            }
        }
        self.extractions = waiting;
        if !self.extractions.is_empty() {
            cx.ui.request_animation();
        }
    }

    /// Advances the Library flows whose chooser or dialog was answered.
    fn poll_library_flows(&mut self, cx: &mut HostCx) {
        if !self.library_flows.is_active() {
            return;
        }
        let mut env = library_flows::Env {
            model: &mut self.library.panel_host().panel.model,
            shell: self.shell.shell(),
            files: &mut *cx.services.files,
        };
        if self.library_flows.poll(&mut env) {
            cx.ui.request_animation();
        }
    }

    /// Drains the queues of all hosts: menu requests open at once, the rest gets a status line.
    fn answer(&mut self, cx: &mut HostCx) {
        let mut lines = Vec::new();
        if std::mem::take(&mut self.effect_defaults_unapplied)
            && let Some(lib) = &self.effect_defaults
        {
            let d = lib.defaults().clone();
            self.apply_effect_defaults(cx.session, d);
        }
        for d in self.inspector.take_effect_defaults_changes() {
            lines.extend(self.store_effect_defaults(cx.session, d));
        }
        // The Project list's selection for the shell's Clip menu rows (`host.projectSelection`).
        self.shell.shell().project_selection = self.project.view().selection().to_vec();
        // Dock events (Swift hooks): the tab menu, focus, the layout save and Move to Floating Window are served here.
        for e in self.dock.take_events() {
            match e {
                DockEvent::PresentMenu(items, at) => {
                    self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
                }
                // The key map's scope: shortcuts bound to a panel (timeline editing keys) need the shell to know it.
                // The blue focus frame is drawn by this root's dock; the shell keeps only the focus for its key scope.
                DockEvent::Focus(p) => {
                    let shell = self.shell.shell();
                    shell.focus = Some(p);
                    if shell.dock.focused() != Some(p) {
                        shell.dock.set_focused(Some(p));
                    }
                }
                DockEvent::SaveWorkspaces => lines.extend(self.save_workspaces()),
                // The tab menu's "Move to Floating Window" (Swift `dock.floatPanel`).
                DockEvent::FloatPanel(p) => {
                    self.dock.float(p, None);
                }
                // The floating windows are the OS shell's (`float_windows.rs`): it reads the dock each frame, brings a window
                // forward through `ShellFloating::take_raised`, and `persist` writes `floating-panels.json` (the layout
                // refresh and the floating save are polled, not announced; the saved frames come back at the next start,
                // test `persist::floating_frames_are_stored_and_loaded`).
                DockEvent::Raise(_) | DockEvent::Changed => {}
            }
        }
        if let Some(conform) = &mut self.conform {
            lines.extend(conform.poll(cx.session));
        }
        for d in self.library.take_deferred() {
            match d {
                LibraryDeferred::Panel(LibraryPanelEvent::Menu(items, at)) => {
                    self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
                }
                LibraryDeferred::Panel(LibraryPanelEvent::Drag(payload, phase, at)) => {
                    let (x, y) = Self::pixels(at, cx.scale);
                    self.library_drag(cx, payload, phase, at, (x, y), &mut lines);
                }
                LibraryDeferred::Request(r) => self.library_request(cx, r, &mut lines),
                LibraryDeferred::Model(e) => self.library_model_event(cx, e, &mut lines),
                _ => lines.push("This Library action is not available here yet.".to_string()),
            }
        }
        self.poll_library_flows(cx);
        lines.extend(self.poll_whoosh(cx));
        self.poll_effects_name();
        self.answer_effects(cx, &mut lines);
        for d in self.project.take_deferred() {
            match d {
                ProjectListEvent::PresentOptionsMenu { items, at } => {
                    let items = self.dock.with_panel_rows(PanelID::Project, items, false);
                    self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
                }
                ProjectListEvent::PresentMenu { items, at, anchor } => {
                    self.open_menu(cx, items, anchor.unwrap_or(CGRect::new(at.x, at.y, 0.0, 0.0)), Some(at));
                }
                ProjectListEvent::Drag { refs, phase, x, y } => {
                    let phase = match phase {
                        ProjectDragPhase::Moved => DragPhase::Moved,
                        ProjectDragPhase::Ended => DragPhase::Ended,
                        ProjectDragPhase::Canceled => DragPhase::Canceled,
                    };
                    lines.extend(self.project_dragged(cx, media_ids(&refs), phase, (x, y)));
                }
                ProjectListEvent::OpenMedia(id) => match &mut self.source {
                    Some(source) => {
                        if source.open(cx, id) {
                            self.dock.show(PanelID::SourceMonitor);
                        }
                    }
                    None => lines.push("The Source monitor is not available here yet.".to_string()),
                },
                ProjectListEvent::ConformToConstantFrameRate(ids) => match &mut self.conform {
                    Some(conform) => {
                        let folder = cx.session.file_url().and_then(|p| p.parent()).map(std::path::Path::to_path_buf);
                        for id in ids {
                            lines.push(match conform.start(cx.session, id, folder.clone()) {
                                Ok(started) => started,
                                Err(e) => format!("Conform: {e}"),
                            });
                        }
                    }
                    None => lines.push("Conform to Constant Frame Rate is not available here yet.".to_string()),
                },
                // New Sequence / Angles / Fill Reel / Edit Original run as the menu commands (`host.execute`).
                ProjectListEvent::Host(
                    action @ (ProjectMenuAction::NewSequence
                    | ProjectMenuAction::CreateAnglesClip
                    | ProjectMenuAction::FillReel
                    | ProjectMenuAction::EditOriginal),
                    _,
                ) => {
                    use sq_uikit::editor_command::EditorCommand as C;
                    let (c, needs_media) = match action {
                        ProjectMenuAction::NewSequence => (C::NewSequence, false),
                        ProjectMenuAction::FillReel => (C::FillReel, true),
                        ProjectMenuAction::EditOriginal => (C::EditOriginal, true),
                        _ => (C::CreateAnglesClip, true),
                    };
                    if !self.shell.run_command(cx, c) && needs_media {
                        lines.push("This needs the selected media items.".to_string());
                    }
                }
                // The panel menu's New Color Matte…: the timeline menu's dialog.
                ProjectListEvent::Host(ProjectMenuAction::NewColorMatte, _) => self.open_color_matte(cx, &mut lines),
                // The Delete and Clear Used Media confirmations of the panel (`shell.presentMessage`).
                ProjectListEvent::Message(title, detail) => self.shell.shell().present_message(&title, &detail, None),
                ProjectListEvent::ExtractAudio(id) => self.start_extraction(cx, id),
                _ => lines.push("This Project action is not available here yet.".to_string()),
            }
        }
        // The picture's handles edit Effect Controls; the model's edits then reach the session.
        let edits = self.monitor.apply_overlay_events(cx.session, &mut self.inspector.controls().model);
        lines.extend(edits);
        self.inspector.route_model(cx);
        // The layer overlay's edits of this event need the Graphics editor.
        {
            let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
            self.monitor.apply_layer_edits(cx.session, editor);
        }
        for d in self.monitor.take_deferred() {
            match d {
                MonitorDeferred::Panel(PanelEvent::Menu { items, anchor, pointer }) => {
                    self.open_menu(cx, items, anchor, pointer);
                }
                MonitorDeferred::Panel(PanelEvent::SelectTab(i)) => self.select_monitor_tab(i),
                // The Select tool's click: a Graphic's text layer above the clip wins (Swift `onPickClip`).
                MonitorDeferred::Panel(PanelEvent::PickClip(p)) => {
                    let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
                    crate::monitor_host::pick_clip(cx.session, editor, p);
                }
                // A wheel zoom or pan: the card shows it itself, Swift sets no Program hook (`onZoomGesture`).
                MonitorDeferred::Panel(PanelEvent::ZoomGesture(_)) => {}
                // The Create tool's drag on the picture (Swift `onCreateShape` / `onCreateStroke`).
                MonitorDeferred::Panel(e @ (PanelEvent::CreateShape(..) | PanelEvent::CreateStroke(..))) => {
                    lines.extend(self.run_create(cx, &e));
                }
                // The Type tool and the double-click on text or a caption (Swift `MonitorTextHost`).
                MonitorDeferred::Panel(
                    e @ (PanelEvent::TypeClick(_)
                    | PanelEvent::TypeBox { .. }
                    | PanelEvent::TextDoubleClick(_)
                    | PanelEvent::CaptionDoubleClick(_)),
                ) => {
                    let seconds = self.new_text_seconds();
                    let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
                    self.monitor.run_text_event(cx.session, editor, seconds, &e);
                }
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::FullScreen) => {
                    self.enter_full_screen(cx, PanelID::ProgramMonitor);
                }
                // A transport button runs the command its key runs (Space is Play/Pause), on the shell like a menu row.
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::Action(a)) => {
                    use sq_draw::monitor::monitor_modes::MonitorAction as A;
                    // The "..." menu's Safe Margins row (Swift `MonitorHost`: `model.safeMargins.toggle()`).
                    if a == A::ToggleSafeMargins {
                        let on = !self.monitor.panel.model.safe_margins();
                        self.monitor.panel.model.set_safe_margins(on);
                        continue;
                    }
                    match Self::monitor_command(a) {
                        Some(c) => {
                            self.run_panel_command(cx, c);
                        }
                        None => lines.push("This Monitor action is not available here yet.".to_string()),
                    }
                }
                // A right-click row: a command runs like its key, a mask row edits the Effect Controls model.
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::ProgramMenu(a)) => {
                    use sq_draw_monitor::monitor_panel_model::ProgramMenuAction as P;
                    match a {
                        P::Command(c) => {
                            self.run_panel_command(cx, c);
                        }
                        P::AddMask(kind) => {
                            self.inspector.controls().model.add_mask(kind);
                        }
                        P::AddPictureMask(track) => {
                            self.inspector.controls().model.add_picture_mask(track);
                        }
                        P::AddColorRangeMask => {
                            self.inspector.controls().model.add_color_range_mask(sq_core_model::ColorRangeKey::DEFAULT);
                        }
                        P::DeleteMasks => self.inspector.controls().model.remove_all_masks(),
                        P::SetSubjectMaskEdges(n) => {
                            use sq_analysis::subject_mask_quality::SubjectMaskQuality as Q;
                            if let (Some(q), Some(persist)) = (Q::ALL.get(n).copied(), &self.persist) {
                                sq_uikit::appearance_palette::UiDefaults::set_string(
                                    &mut *persist.defaults().borrow_mut(),
                                    Q::DEFAULTS_KEY,
                                    q.raw_value(),
                                );
                                lines.push(format!(
                                    "Subject mask edges: {}. Track the mask again to change frames that are already tracked.",
                                    q.title()
                                ));
                            }
                        }
                    }
                }
                // The empty Program monitor's button runs File > New > Sequence... (Swift `onNewSequence`).
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::NewSequence) => {
                    self.shell.run_command(cx, sq_uikit::editor_command::EditorCommand::NewSequence);
                }
                // The offline card's Locate… runs the Reconnect Media flow (r8:745).
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::LocateOffline) => {
                    if cx.session.can_relink() {
                        cx.emit(AppEvent::Flow(ShellFlow::Project(sq_draw_shell::ShellAction::RelinkMedia)));
                    }
                }
                // The "..." menu's Show Scopes toggles the Scopes panel (Swift `SharedUIController`: `dock.toggle(.scopes)`).
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::ShowScopes) => {
                    self.dock.toggle(PanelID::Scopes);
                }
                // A hand pick in the quality popup is the new default (Swift `MonitorHost.rememberQuality`).
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::QualityChange(q)) => {
                    self.remember_quality(q);
                }
                _ => lines.push("This Monitor action is not available here yet.".to_string()),
            }
        }
        // The on-canvas text field's typing, end and style toggles reach the layer.
        {
            let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
            self.monitor.pump_text(cx.session, editor);
        }
        let mut full_screen = false;
        let source_deferred = self.source.as_mut().map(SourceMonitorHost::take_deferred).unwrap_or_default();
        for d in source_deferred {
            match d {
                MonitorDeferred::Panel(PanelEvent::Menu { items, anchor, pointer }) => {
                    self.menu.pop_up(items, anchor, pointer, &cx.measure());
                }
                MonitorDeferred::Panel(PanelEvent::SelectTab(i)) => self.select_monitor_tab(i),
                // The Source card reads its zoom itself (Swift sets no `onZoomGesture` hook).
                MonitorDeferred::Panel(PanelEvent::ZoomGesture(_)) => {}
                // The Source picture or a footer handle dragged onto the timeline: the Project list's drop path with the
                // Source clip and those streams (Swift `MonitorCardHost.sourceDragged`).
                MonitorDeferred::Panel(PanelEvent::SourceDrag { streams, phase, x, y }) => {
                    lines.extend(self.source_dragged(cx, streams, phase, x, y));
                }
                MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::FullScreen) => {
                    full_screen = true;
                }
                _ => lines.push("This Source monitor action is not available here yet.".to_string()),
            }
        }
        if full_screen {
            self.enter_full_screen(cx, PanelID::SourceMonitor);
        }
        if let Some(text) = &mut self.text {
            for (items, anchor) in text.take_menus() {
                self.menu.pop_up(items, anchor, None, &cx.measure());
            }
        }
        if let Some(meter) = &mut self.meter {
            // The stored listening level reaches the output once, before the first change (Swift reads it at launch).
            if !std::mem::replace(&mut self.monitor_sent, true) {
                cx.session.engine_mut().set_monitor_gain(meter.monitor_setting());
            }
            for e in meter.take_events() {
                match e {
                    MeterPanelEvent::Menu(items, at) => {
                        self.menu.pop_up(items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at), &cx.measure());
                    }
                    MeterPanelEvent::ResetLoudness => cx.session.engine_mut().reset_loudness_meter(),
                    MeterPanelEvent::ChannelMonitorChange(m) => cx.session.engine_mut().set_channel_monitor(m),
                    MeterPanelEvent::MonitorGainChange(g) => cx.session.engine_mut().set_monitor_gain(g),
                }
            }
        }
        if let Some(d) = self.text.as_mut().and_then(|t| t.take_dialogs().pop()) {
            self.show_dialog(d);
        }
        if let Some(d) = self.timeline.take_dialogs().pop() {
            self.show_dialog(d);
        }
        if let Some(d) = self.inspector.take_dialogs().pop() {
            self.show_dialog(d);
        }
        for id in self.inspector.take_transition_saves() {
            match self.timeline.editor_dialog(cx.session, &TimelineEditorRequest::SaveTransitionPreset(id)) {
                Some(d) => self.show_dialog(d),
                None => lines.push(TimelineEditorRequest::SaveTransitionPreset(id).unavailable()),
            }
        }
        for (items, anchor) in self.inspector.take_menus() {
            self.open_menu(cx, items, anchor, None);
        }
        for d in self.inspector.take_deferred() {
            match d {
                SectionAction::EditGraphics => self.dock.show(PanelID::Graphics),
                SectionAction::StylesChanged(library) => self.save_text_styles(&library, &mut lines),
                _ => lines.push("This Inspector action is not available here yet.".to_string()),
            }
        }
        for _ in self.inspector.take_view_deferred() {
            lines.push("This Effect Controls action is not available here yet.".to_string());
        }
        for d in self.shell.take_deferred() {
            match d {
                ShellDeferred::Flow(flow) => cx.emit(AppEvent::Flow(flow)),
                ShellDeferred::Event(ShellEvent::Quit) => {
                    // "Later" on a downloaded update: it goes in place now, without a restart.
                    if let Some(update) = self.shell.shell().pending_update.take()
                        && let Err(e) = Self::apply_verified_update(&update, false)
                    {
                        lines.push(format!("The update could not be installed on quit: {e}"));
                    }
                    if self.persist.is_some() {
                        cx.session.close(); // ends the crash marker: the next start offers nothing
                    }
                    cx.emit(AppEvent::Quit);
                }
                ShellDeferred::Event(ShellEvent::RecentsChanged) => {
                    // The system's own list (Dock menu / jump list) follows the shared one: its newest entry is added.
                    if let Some(newest) = self.shell.shell().recents.entries().first() {
                        sq_platform::add_recent_document(std::path::Path::new(&newest.path));
                    }
                    let bytes = serde_json::to_vec(&self.shell.shell().recents).ok();
                    Self::save_file(self.recents_path.as_ref(), bytes);
                }
                // The panels follow the session's own change notes; the start screen settings are not stored yet.
                ShellDeferred::Event(ShellEvent::RevealFile(path)) => {
                    if let Err(e) = crate::FileManager::reveal(&crate::SystemPlatform, &path) {
                        lines.push(e);
                    }
                }
                // About, Help and Support links (Swift `openURL`: `NSWorkspace.open`).
                // shortcut: the system's open command takes the link as a path argument; upgrade with a URL-opener seam.
                ShellDeferred::Event(ShellEvent::OpenUrl(url)) => {
                    if let Err(e) = crate::FileManager::open(&crate::SystemPlatform, std::path::Path::new(&url)) {
                        lines.push(e);
                    }
                }
                ShellDeferred::Event(ShellEvent::ApplyUpdate { update, restart }) => {
                    match Self::apply_verified_update(&update, restart) {
                        Ok(()) if restart => {
                            if self.persist.is_some() {
                                cx.session.close();
                            }
                            cx.emit(AppEvent::Quit);
                        }
                        Ok(()) => {}
                        Err(why) => {
                            self.shell.shell().present_message(
                                "The update did not finish",
                                &why,
                                Some(sq_draw_shell::Tone::Error),
                            );
                        }
                    }
                }
                ShellDeferred::Event(ShellEvent::AppMenu(request)) => {
                    let env = sq_platform::desktop_integration::DesktopEnv::current();
                    let outcome =
                        crate::desktop_entry::card_for(request, crate::desktop_entry::run(env.as_ref(), request));
                    let shell = self.shell.shell();
                    shell.preferences.app_menu = crate::desktop_entry::row_for(
                        env.as_ref(),
                        &sq_platform::desktop_integration::state(env.as_ref()),
                    );
                    shell.show_app_menu_result(outcome);
                }
                ShellDeferred::Event(ShellEvent::RunExportQueue) => {
                    if let Some(queue) = self.shell.shell().export.queue.clone() {
                        crate::export_host::run_queue(queue);
                    }
                }
                ShellDeferred::Event(ShellEvent::CancelBackgroundJob(id)) => cx.session.cancel_proxy_job(&id),
                ShellDeferred::Event(ShellEvent::AddLibraryFolder(url)) => self.add_library_folder(url),
                ShellDeferred::Event(ShellEvent::RemoveLibraryFolder(id)) => self.remove_library_folder(&id),
                ShellDeferred::Event(ShellEvent::ClearCache) => self.clear_cache(cx.session),
                ShellDeferred::Event(ShellEvent::MoveProxies { from, to }) => self.move_proxies(&from, &to),
                ShellDeferred::Event(ShellEvent::RunCommand(c)) => {
                    self.shell.run_command(cx, c);
                }
                // The flow follows the statuses and shows the outcome itself.
                ShellDeferred::Event(ShellEvent::ExportsFinished { done, failed }) => {
                    cx.emit(AppEvent::ExportsFinished { done, failed });
                }
                ShellDeferred::Event(ShellEvent::SettingsChanged(s)) => self.apply_settings_changed(&s, cx.session),
                // Edit API address: the clipboard (Swift `shell.copyText`).
                ShellDeferred::Event(ShellEvent::CopyText(text)) => cx.ui.clipboard.write(&text),
                // Preferences > Editing > Restore Factory: the library forgets that default (Swift `effectDefaultsLibrary.update`).
                ShellDeferred::Event(ShellEvent::RestoreEffectDefault(entry)) => {
                    use sq_editor_session::EffectDefaultsSettings;
                    if let Some(lib) = &mut self.effect_defaults {
                        if !lib.update(|d| d.remove_entry(&entry)) {
                            lines.push("Your defaults could not be saved.".to_string());
                        }
                        let d = lib.defaults().clone();
                        self.apply_effect_defaults(cx.session, d);
                    }
                }
                // A running job's title for the status bar (Swift `shell.onJob`).
                ShellDeferred::Event(ShellEvent::Job(line)) => self.chrome.set_job_line(line),
                // Imported presets: the Library lists them (the store is the one the panel reads).
                ShellDeferred::Event(ShellEvent::PresetsChanged) => {
                    self.library.panel_host().panel.model.reload_presets();
                }
                // Full Screen began or ended: the window shell keeps its chrome (Swift sets no `onFullScreenChange` here).
                ShellDeferred::Event(ShellEvent::FullScreen(_)) => {}
                ShellDeferred::Event(ShellEvent::Window(op)) => cx.emit(AppEvent::Window(op)),
                ShellDeferred::Event(ShellEvent::ProjectChanged | ShellEvent::Setting { .. }) => {}
                ShellDeferred::Event(_) => lines.push("This menu command is not available here yet.".to_string()),
            }
        }
        for e in self.timeline.take_events() {
            match e {
                TimelineHostEvent::Open(TimelineEditorRequest::Source { media }) => match &mut self.source {
                    Some(source) => {
                        if source.open(cx, media) {
                            self.dock.show(PanelID::SourceMonitor);
                        }
                    }
                    None => lines.push("The Source monitor is not available here yet.".to_string()),
                },
                TimelineHostEvent::Open(TimelineEditorRequest::RevealInProject { media }) => {
                    if self.project.reveal(cx, media) {
                        self.dock.show(PanelID::Project);
                    } else {
                        lines.push(TimelineEditorRequest::RevealInProject { media }.unavailable());
                    }
                }
                TimelineHostEvent::Open(TimelineEditorRequest::TrimMode { point, pointer_before }) => {
                    self.shell.enter_trim_mode(cx, point, pointer_before);
                }
                TimelineHostEvent::Open(TimelineEditorRequest::SpeedCurve { clip, segment, at }) => {
                    // `at` is in panel points; the popover wants window points.
                    let origin = self.timeline.inner().panel.point(0.0, 0.0);
                    let anchor = CGRect::new(at.x - origin.x, at.y - origin.y, 1.0, 1.0);
                    self.inspector.open_speed_curve(cx, clip, segment, anchor);
                }
                // Controls shows the Text and Graphic sections of the selected clip.
                TimelineHostEvent::Open(
                    TimelineEditorRequest::TextClip(id) | TimelineEditorRequest::GraphicLayers(id),
                ) => cx.session.select(BTreeSet::from([id]), BTreeSet::new()),
                // The inline field over one caption word; the caption's Text dialog when no word opens (`captionWord`).
                TimelineHostEvent::Open(TimelineEditorRequest::CaptionWord(word)) => {
                    let TimelineAppHost { panel, host } = self.timeline.inner();
                    let actions = panel.begin_word_editing(word);
                    let opened = actions.is_some();
                    for action in actions.unwrap_or_default() {
                        lines.extend(sq_draw_timeline::session_bridge::apply(
                            action,
                            cx.session,
                            host,
                            Some(&mut *panel),
                        ));
                    }
                    if !opened && !self.edit_caption_in_panel(cx, word.caption) {
                        let r = TimelineEditorRequest::CaptionText(word.caption);
                        match self.timeline.editor_dialog(cx.session, &r) {
                            Some(d) => self.show_dialog(d),
                            None => lines.push(r.unavailable()),
                        }
                    }
                }
                // The caption's text is typed in the Text panel's row; the one-line dialog is the fallback.
                TimelineHostEvent::Open(TimelineEditorRequest::CaptionText(id))
                    if self.edit_caption_in_panel(cx, id) => {}
                TimelineHostEvent::Open(r) => match self.timeline.editor_dialog(cx.session, &r) {
                    Some(d) => self.show_dialog(d),
                    None => lines.push(r.unavailable()),
                },
                TimelineHostEvent::Command(c) => {
                    self.run_panel_command(cx, c);
                }
            }
        }
        self.open_color_dropdowns(cx);
        self.answer_timeline(cx, &mut lines);
        self.answer_graphics(cx, &mut lines);
        self.save_presets(&mut lines);
        self.drive_template_saves(cx, &mut lines);
        for flow in self.timeline.take_flows() {
            cx.emit(AppEvent::Flow(flow));
        }
        for (items, anchor) in self.color.take_menus() {
            self.open_menu(cx, items, anchor, None);
        }
        if let (Some(api), Some(persist)) = (&mut self.edit_api, &self.persist) {
            api.sync(&persist.defaults().borrow());
            api.set_busy(self.timeline.is_dragging());
        }
        self.sync_media_prefs();
        let api_state = self.shell.shell().flow_env.edit_api.as_ref().map(|a| (a.state)());
        if api_state != self.edit_api_seen {
            self.edit_api_seen = api_state;
            self.shell.shell().edit_api_state_changed();
        }
        if let Some(persist) = &mut self.persist
            && let Some(d) = persist.pump(cx, &mut self.dock)
        {
            self.show_dialog(d);
        }
        if let Some(persist) = &self.persist {
            self.shell.hold_welcome(persist.recovery_pending(), persist.recovered());
        }
        lines.extend(crate::audio_notice::take(&cx.services.audio_notices));
        // One line per call: the last wins, as the status bar shows one.
        if let Some(line) = lines.pop() {
            cx.emit(AppEvent::Status(line));
        }
        // Every status line queued in this call also shows in the status bar.
        let line =
            cx.events.iter().rev().find_map(|e| if let AppEvent::Status(l) = e { Some(l.clone()) } else { None });
        if let Some(line) = line {
            self.chrome.flash(line, SystemTime::now());
        }
    }

    /// The Graphics panel's requests: menus open, Make Graphic and the template and preset sheets run.
    /// Preferences > Editing > New Text Length, in seconds (5 until stored).
    fn new_text_seconds(&self) -> i64 {
        match &self.persist {
            Some(p) => {
                sq_editor_session::AppSettings::load(&sq_draw_shell::SharedView(p.defaults())).default_text_seconds
            }
            None => sq_editor_session::AppSettings::standard().default_text_seconds,
        }
    }

    /// A Create tool drag on the Program picture: a layer of the shown Graphic, else a new Graphic clip as long as the New
    /// Text Length (Swift `MonitorHost.createItem`). The status line when it fails.
    fn run_create(&mut self, cx: &mut HostCx, event: &PanelEvent) -> Option<String> {
        let seconds = self.new_text_seconds();
        let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
        crate::monitor_host::create_tool::run_create_event(cx.session, editor, seconds, event)?.err()
    }

    fn answer_graphics(&mut self, cx: &mut HostCx, lines: &mut Vec<String>) {
        let Some(graphics) = &mut self.graphics else { return };
        graphics.pump(cx);
        for item in self.animation_keystones.take_saved() {
            if let Err(e) = self.library.panel_host().panel.model.replace_preset(item) {
                let (_, detail) = sq_draw_library::library::library_panel_logic::LibraryLabels::preset_error(&e, None);
                lines.push(format!("The animation could not be saved: {detail}"));
            }
        }
        let Some(graphics) = &mut self.graphics else { return };
        let origin = graphics.frame();
        for r in graphics.take_requests() {
            match r {
                PanelRequest::Menu { items, anchor } => {
                    let at = CGRect::new(anchor.x + origin.x, anchor.y + origin.y, anchor.width, anchor.height);
                    self.open_menu(cx, items, at, None);
                }
                PanelRequest::EditText(layer) => {
                    let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
                    self.monitor.edit_graphic_text(cx.session, editor, layer);
                }
                PanelRequest::MakeGraphic => {
                    if !cx.session.make_graphic() {
                        lines.push(cx.session.last_error().unwrap_or("Make Graphic is not possible here.").to_string());
                    }
                }
                PanelRequest::SaveTemplate => {
                    match self.timeline.editor_dialog(cx.session, &TimelineEditorRequest::SaveTemplate) {
                        Some(d) => self.show_dialog(d),
                        None => lines.push(TimelineEditorRequest::SaveTemplate.unavailable()),
                    }
                }
                PanelRequest::SaveEffectPreset(p) => {
                    let d = self.timeline.effect_preset_dialog(p);
                    self.show_dialog(d);
                }
                PanelRequest::Notice(text) => lines.push(text),
                PanelRequest::AskName(ask) => self.show_dialog(crate::name_dialog::name_dialog(ask)),
                PanelRequest::StylesChanged(library) => self.save_text_styles(&library, lines),
                // The pickers are answered by `GraphicsHost::pump` itself.
                PanelRequest::PickColor { .. } | PanelRequest::SampleColor(_) => {}
            }
        }
    }

    /// Adds the presets the editor dialogs finished to the Library; their status lines (and failures) show.
    /// `editCaptionInPanel`: shows the Text panel and opens typing on the caption's row. False without a Text panel or caption.
    fn edit_caption_in_panel(&mut self, cx: &mut HostCx, id: sq_core_time::Id) -> bool {
        let Some(text) = &mut self.text else { return false };
        if !text.edit_caption(cx.session, id) {
            return false;
        }
        self.dock.show(PanelID::Text);
        true
    }

    /// Save as Template: the Program frame at the playhead becomes the preview image (320 px PNG), then the template goes
    /// to the Library. Without a picture the template saves without one and the status line says so.
    fn drive_template_saves(&mut self, cx: &mut HostCx, lines: &mut Vec<String>) {
        self.template_saves.extend(self.timeline.take_templates());
        if self.template_saves.is_empty() {
            return;
        }
        let picture = self.frame_picture.clone().filter(|p| p.size().is_some());
        let fetched = match (&picture, &mut self.template_grab) {
            (Some(picture), grab) => {
                let grab = grab.get_or_insert_with(|| {
                    crate::FrameGrab::start(cx.session.engine_mut(), picture, self.template_saves[0].name.clone())
                });
                grab.poll_image(cx.session.engine_mut(), picture)
            }
            (None, _) => crate::frame_export::Fetched::Missing,
        };
        let png = match fetched {
            crate::frame_export::Fetched::Waiting => {
                cx.ui.request_animation();
                return;
            }
            crate::frame_export::Fetched::Frame(image) => crate::template_thumbnail::thumbnail_png(&image),
            _ => None,
        };
        self.template_grab = None;
        let save = self.template_saves.remove(0).into_save(png, true);
        let model = &mut self.library.panel_host().panel.model;
        lines.push(match model.save_new_preset(save.make) {
            Ok(()) => save.done,
            Err(e) => format!("{}{e}", save.failure),
        });
    }

    fn save_presets(&mut self, lines: &mut Vec<String>) {
        let (saves, notes) = self.timeline.take_saved();
        for s in saves {
            let model = &mut self.library.panel_host().panel.model;
            lines.push(match model.save_new_preset(s.make) {
                Ok(()) => s.done,
                Err(e) => format!("{}{e}", s.failure),
            });
        }
        lines.extend(notes);
    }

    /// Preferences saved new settings: what must change while the app runs does so now (Swift `onSettingsChanged` and
    /// `applySessionSettings`). The rest is read where it is used.
    pub(crate) fn apply_settings_changed(
        &mut self,
        s: &sq_editor_session::AppSettings,
        session: &mut sq_editor_session::EditorSession,
    ) {
        sq_audio_out::output::devices::set_preferred(s.audio_output_uid.clone());
        // Help > Check for Updates follows the channel chosen in Settings.
        let feed = {
            let shell = self.shell.shell();
            sq_editor_session::UpdateCheck::feed_url_for(s.update_channel, &*shell.defaults)
        };
        self.shell.shell().update_feed = feed;
        self.monitor.panel.model.drop_indicator_enabled = s.drop_indicator;
        self.apply_monitor_settings(s);
        crate::persist::apply_session_settings_from(s, session);
        crate::persist::apply_media_defaults(&*self.shell.shell().defaults, session);
    }

    /// Preferences > Playback: the Program monitor's quality (Default Quality, or Auto) and the Source monitor's Preroll
    /// and Postroll for Play In to Out with roll and Play Around (Swift `applyRememberedQuality`).
    fn apply_monitor_settings(&mut self, s: &sq_editor_session::AppSettings) {
        // Auto stays Auto: it starts at the machine's pick and the governor lowers it on sustained lateness.
        let wanted = s.start_quality(sq_editor_session::MonitorQuality::Auto);
        // The active sequence's own quality keeps winning over a Preferences change.
        let wanted = self
            .sequence_quality
            .and_then(|(_, own)| own)
            .map_or(wanted, sq_editor_session::MonitorQuality::from_sequence);
        let model = &mut self.monitor.panel.model;
        let start = sq_playback::engine::memory_budget::auto_start_scale_here(
            |k| std::env::var(k).ok(),
            sq_platform::physical_memory().unwrap_or(16 << 30),
        );
        model.set_auto_base(sq_editor_session::MonitorQuality::from_scale(start));
        sq_media_ffmpeg::shim::set_weak_machine(
            sq_core_project::work_limits::MachineResources::current(
                |k| std::env::var(k).ok(),
                sq_platform::physical_memory().unwrap_or(16 << 30),
                std::thread::available_parallelism().map_or(8, |n| n.get() as i64),
                cfg!(all(target_os = "macos", target_arch = "x86_64")),
            )
            .is_weak_for_decode(),
        );
        if model.quality() != wanted || model.quality() == sq_editor_session::MonitorQuality::Auto {
            model.set_quality(wanted);
        }
        if let Some(source) = &mut self.source {
            source.set_roll(s.preroll(), s.postroll());
        }
    }

    /// Every frame: the one place where the sequence's own preview quality is put over the app's quality, and where the
    /// Auto quality reads how the engine keeps up. A new active sequence starts Auto over (the governor re-bases).
    fn pump_quality(&mut self, session: &sq_editor_session::EditorSession) {
        let own = session.active_timeline().map(|t| (t.id, t.preview_quality()));
        if own != self.sequence_quality {
            self.sequence_quality = own;
            // Without stored settings (tests) only a sequence value is applied.
            let stored = match &self.persist {
                Some(persist) => Some(sq_editor_session::AppSettings::load(&*persist.defaults().borrow())),
                None => own.and_then(|(_, q)| q).map(|_| sq_editor_session::AppSettings::standard()),
            };
            if let Some(stored) = stored {
                self.apply_monitor_settings(&stored);
            }
        }
        let now = self.started.elapsed().as_secs_f64();
        if let Some(stall) = session.take_present_stall() {
            self.monitor.panel.model.note_present_stall(stall.as_secs_f64());
        }
        let counts = session.engine().play_counts();
        self.monitor.panel.model.update_play_counts(counts, session.is_playing(), now);
    }

    /// Saves a quality picked by hand in the Program monitor as the new default; Auto is saved as Auto.
    fn remember_quality(&mut self, q: sq_editor_session::MonitorQuality) {
        use sq_editor_session::{AppSettings, MonitorQuality};
        // A sequence's own preview quality is temporary: it never becomes the app's default.
        if self.sequence_quality.is_some_and(|(_, own)| own.is_some()) {
            return;
        }
        let Some(persist) = &self.persist else { return };
        let defaults = persist.defaults();
        let stored = AppSettings::load(&*defaults.borrow());
        let next = if self.monitor.panel.model.quality() == MonitorQuality::Auto {
            AppSettings { preview_quality_auto: true, ..stored.clone() }
        } else {
            stored.choosing_fixed_quality(q)
        };
        if next != stored {
            next.save(&mut *defaults.borrow_mut());
        }
    }

    /// Hands `d` to the session, Effect Controls and Preferences (Swift `InspectorHooks.apply` and the library's change note).
    fn apply_effect_defaults(
        &mut self,
        session: &mut EditorSession,
        d: sq_core_model::effect_defaults::EffectDefaults,
    ) {
        session.set_effect_defaults(d.clone());
        self.inspector.set_effect_defaults(d.clone());
        self.shell.shell().preferences.effect_defaults = Some(d);
    }

    /// Defaults the user changed ("Use as Default", a transition default): stored in the library file, then applied. A file
    /// that cannot be written gives the status line and the stored defaults stay.
    fn store_effect_defaults(
        &mut self,
        session: &mut EditorSession,
        d: sq_core_model::effect_defaults::EffectDefaults,
    ) -> Option<String> {
        let Some(lib) = &mut self.effect_defaults else {
            // No library file (no support folder): the defaults live in this session only.
            self.apply_effect_defaults(session, d);
            return None;
        };
        let saved = lib.replace(d);
        let current = lib.defaults().clone();
        self.apply_effect_defaults(session, current);
        (!saved).then(|| "Your defaults could not be saved.".to_string())
    }

    /// The monitor quality and the Linked Selection state the status bar shows.
    /// The thermal / Low Power / memory-pressure load reaches the monitors, the proxy service, the render cache and the
    /// poster caches (Swift `PlaybackEngine.powerPolicy`, `PowerPolicy.combined`, `MemoryPressureRegistry`).
    fn apply_system_load(&mut self, cx: &mut HostCx) {
        let defaults = self.persist.as_ref().map(Persist::defaults);
        let switches = || match &defaults {
            Some(d) => {
                let s = sq_editor_session::AppSettings::load(&*d.borrow());
                (s.preview_quality_auto, s.background_work)
            }
            None => (true, true),
        };
        if let Some(load) = self.load_watch.poll_system(switches) {
            cx.session.apply_load_policy(load.policy);
            self.timeline_media.apply_memory_pressure(load.level);
        }
    }

    fn chrome_values(&mut self) -> (sq_editor_session::MonitorQuality, bool) {
        let quality = self.monitor.panel.model.quality();
        (quality, self.timeline.inner().panel.tool_state().linked_selection)
    }

    /// Whether this event takes the keyboard away from Effect Controls: a dialog, menu or start window is up, another panel
    /// has the focus, or the press lands outside the panel. A field that was being typed then commits (never stays open).
    fn inspector_lost_keyboard(&self, e: &InputEvent, scale: f32) -> bool {
        if self.dialog.is_some() || self.shell.has_dialog() || self.shell.start_shown() || self.menu.is_open() {
            return true;
        }
        if self.dock.focused() != Some(PanelID::EffectControls) {
            return true;
        }
        let InputEvent::MouseDown { x, y, .. } = *e else { return false };
        let at = CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        self.dock.content_frame(PanelID::EffectControls).is_none_or(|f| !f.contains(at))
    }

    /// Hover and clicks on the title row and the status bar.
    /// Commits the open Project, Marker list, Library, Effects, Text and Graphics fields and the timeline's caption word
    /// field: a press elsewhere, a menu chord and the window losing the keyboard end an edit the same way, so no field
    /// stays open without the keyboard.
    fn end_text_edits(&mut self, cx: &mut HostCx) {
        self.project.end_rename(cx);
        if let Some(list) = self.marker_list.as_mut() {
            list.end_text_edits(cx);
        }
        self.library.panel_host().panel.end_search_editing();
        if let Some(effects) = self.effects.as_mut() {
            effects.panel_host().panel.end_search_editing();
        }
        if let Some(text) = self.text.as_mut() {
            text.end_text_edits(cx);
        }
        if let Some(graphics) = self.graphics.as_mut() {
            graphics.end_text_edits(cx);
        }
        self.timeline.inner().end_text_edits(cx);
        self.sync_project_panel(cx);
    }

    /// Hands the Project panel the project as it is now. The panel edits a copy it syncs on the next change poll and writes
    /// the whole copy back on every edit (`ProjectPanelModel::commit`), so a field committed a moment ago in the same turn
    /// (the caption text a menu chord such as New Bin ends first) would be overwritten by the stale copy.
    fn sync_project_panel(&mut self, cx: &mut HostCx) {
        self.project.sync(cx.session);
    }

    /// A press outside the Text panel, the Graphics panel or the timeline commits the fields typed in them: their panels
    /// only hear presses inside their own frame, so a field would stay open behind the press and eat the next keys.
    fn end_panel_fields_on_outside_press(&mut self, e: &InputEvent, cx: &mut HostCx) {
        let InputEvent::MouseDown { x, y, .. } = *e else { return };
        let at = self.dock.panel_at(CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale)));
        if at != Some(PanelID::Text)
            && let Some(text) = self.text.as_mut()
        {
            text.end_text_edits(cx);
        }
        if at != Some(PanelID::Graphics)
            && let Some(graphics) = self.graphics.as_mut()
        {
            graphics.end_text_edits(cx);
        }
        if at != Some(PanelID::Timeline) {
            self.timeline.inner().end_text_edits(cx);
        }
        self.sync_project_panel(cx);
    }

    /// The Project and Marker list name fields own the keyboard while open, whatever panel has the dock focus (a press on
    /// the timeline moves the focus and must not leave the field open to eat the next keys). `Some` when the event is
    /// answered; a press outside the field's panel commits it and goes on as if no field were open.
    fn name_field_gate(&mut self, e: &InputEvent, cx: &mut HostCx) -> Option<bool> {
        let project = self.project.is_renaming();
        let markers = self.marker_list.as_ref().is_some_and(|l| l.is_renaming());
        if !project && !markers {
            return None;
        }
        match *e {
            InputEvent::KeyDown { .. } => match self.marker_list.as_mut().filter(|_| markers) {
                Some(list) => Some(list.handle(e, cx)),
                None => Some(self.project.handle(e, cx)),
            },
            InputEvent::MouseDown { x, y, .. } => {
                let at = self.dock.panel_at(CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale)));
                if project && at != Some(PanelID::Project) {
                    self.project.end_rename(cx);
                }
                if markers
                    && at != Some(PanelID::MarkerList)
                    && let Some(list) = self.marker_list.as_mut()
                {
                    list.end_rename(true, cx);
                }
                None
            }
            _ => None,
        }
    }

    fn handle_chrome(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let k = f64::from(cx.scale);
        let (mouse, x, y) = match *e {
            InputEvent::MouseMoved { x, y } => (Mouse::Moved, x, y),
            InputEvent::MouseDown { x, y, .. } => (Mouse::Down, x, y),
            InputEvent::MouseUp { x, y } => (Mouse::Up, x, y),
            _ => return false,
        };
        let mut actions = Vec::new();
        let measure = cx.measure();
        let taken = self.chrome.handle(mouse, CGPoint::new(f64::from(x) / k, f64::from(y) / k), &measure, &mut actions);
        for a in actions {
            match a {
                ChromeAction::Export => {
                    self.shell.run_command(cx, sq_uikit::editor_command::EditorCommand::Export);
                }
                ChromeAction::Workspaces(r) => {
                    let items = Chrome::workspace_items(self.shell.shell());
                    self.menu.pop_up(items, r, None, &measure);
                }
                ChromeAction::Page(p) => self.dock.set_page(p),
                ChromeAction::Relink => self.shell.shell().accept_relink_offer(cx.session),
                ChromeAction::Queue(at, ring) => self.shell.shell().show_export_queue(at, ring),
            }
        }
        self.answer(cx);
        taken
    }

    /// The Color page's dock-strip dropdowns open the timeline header's menus; Copy and Paste Grade ride in "...".
    fn open_color_dropdowns(&mut self, cx: &mut HostCx) {
        use sq_draw_timeline::header::TimelineHeaderMenu;
        use sq_inspector_ui::color::color_viewer_header_draw::StripDropdown;
        for (d, r) in self.color.take_dropdowns() {
            let (menu, x, extra) = match d {
                StripDropdown::Sequence => (TimelineHeaderMenu::Sequence, r.min_x(), Vec::new()),
                StripDropdown::Mode => (TimelineHeaderMenu::EditMode, r.min_x(), Vec::new()),
                StripDropdown::Fit => (TimelineHeaderMenu::Fit, r.min_x(), Vec::new()),
                StripDropdown::More => {
                    let own = self.color.grade_menu_items(cx.session);
                    let at = CGPoint::new(r.mid_x(), r.mid_y());
                    let extra = match self.dock.panel_at(at) {
                        Some(p) => self.dock.with_panel_rows(p, own, true),
                        None => own,
                    };
                    (TimelineHeaderMenu::More, r.max_x(), extra)
                }
            };
            self.header.open_header_menu(menu, CGPoint::new(x, r.max_y()), self.timeline.inner(), extra);
        }
    }

    /// The timeline's right-click menus open; the view commands the shell queued run on the panel and the check marks
    /// of the menus follow it.
    fn answer_timeline(&mut self, cx: &mut HostCx, lines: &mut Vec<String>) {
        // Select Next / Previous Panel ran on the shell's dock: the app's dock shows the focus.
        if let Some(p) = self.shell.shell().take_dock_focus() {
            self.dock.set_focused(Some(p));
        }
        let ducking = self.shell.shell().resolved_live_ducking(cx.session.project().live_ducking.as_ref());
        self.timeline.set_live_ducking(ducking);
        for (items, at) in self.timeline.take_menus() {
            self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
        }
        for (items, at) in self.header.take_menus().into_iter().chain(self.tools.take_menus()) {
            self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
        }
        for c in self.header.take_commands() {
            self.run_panel_command(cx, c);
        }
        lines.extend(self.poll_frame_grab(cx));
        let Some(link) = self.timeline_link.clone() else { return };
        if link.borrow_mut().take_whoosh() {
            lines.extend(self.whoosh_from_sfx_bin(cx));
        }
        let shapes = link.borrow_mut().take_new_shapes();
        for kind in shapes {
            let seconds = self.new_text_seconds();
            let editor = self.graphics.as_mut().map(|g| &mut g.panel().host.editor);
            if let Err(line) =
                crate::monitor_host::create_tool::create_shape_at_center(cx.session, editor, seconds, kind)
            {
                lines.push(line);
            }
        }
        if link.borrow_mut().take_new_color_matte() {
            self.open_color_matte(cx, lines);
        }
        if link.borrow_mut().take_save_stack_preset() {
            let request = TimelineEditorRequest::SaveClipPreset;
            match self.timeline.editor_dialog(cx.session, &request) {
                Some(d) => self.show_dialog(d),
                None => lines.push(request.unavailable()),
            }
        }
        if link.borrow_mut().take_auto_captions() {
            lines.push(match &mut self.text {
                Some(text) => {
                    let line = text.auto_captions(cx.session);
                    self.dock.show(PanelID::Text);
                    line
                }
                None => "Open a sequence first.".to_string(),
            });
        }
        if link.borrow_mut().take_project_delete() {
            self.project.delete_selection(cx);
        }
        // Edit > Find: the Project model lives here, so the root runs the search the shell asked for.
        if let Some(c) = self.shell.shell().take_find_request() {
            let found = self.project.model().find(&c);
            if self.shell.shell().show_found(&c, &found) {
                self.project.reveal_found(cx, found);
            }
        }
        let project_view = link.borrow_mut().take_project_view();
        for c in project_view {
            lines.extend(self.project.run_view_command(cx, c));
        }
        let monitor_view = link.borrow_mut().take_monitor_view();
        for c in monitor_view {
            let model = &mut self.monitor.panel.model;
            if c == sq_uikit::editor_command::EditorCommand::ToggleSafeAreas {
                let on = model.safe_margins();
                model.set_safe_margins(!on);
            } else {
                model.toggle_overlays();
            }
        }
        let placement = link.borrow_mut().take_placement();
        for c in placement {
            self.run_placement(cx, c);
        }
        let host_commands = link.borrow_mut().take_host_commands();
        for c in host_commands {
            lines.extend(self.run_host_command(cx, c));
        }
        let edit_actions = link.borrow_mut().take_edit_actions();
        for a in edit_actions {
            self.run_edit_action(cx, a);
        }
        if link.borrow_mut().take_export_frame() {
            lines.extend(self.export_frame(cx.session));
        }
        if link.borrow_mut().take_gamma_changed() {
            cx.session.engine_mut().redraw();
        }
        let commands = link.borrow_mut().take_commands();
        // Monitors keep their own zoom; the timeline owns Delete when it (or nothing) has the focus.
        let focus = self.shell.shell().focus;
        let scope = CommandScope {
            zooms: !matches!(focus, Some(PanelID::ProgramMonitor | PanelID::SourceMonitor)),
            owns_delete: matches!(focus, None | Some(PanelID::Timeline)),
        };
        let TimelineAppHost { panel, host } = self.timeline.inner();
        for c in commands {
            lines.extend(timeline_commands::run(&c, panel, host, cx.session, &scope, &mut self.settings));
        }
        let mut checks = panel.view_checks(cx.session);
        let model = &self.monitor.panel.model;
        if model.safe_margins() {
            checks.insert(sq_uikit::editor_command::EditorCommand::ToggleSafeAreas);
        }
        if !model.overlays_hidden() {
            checks.insert(sq_uikit::editor_command::EditorCommand::ToggleOverlays);
        }
        link.borrow_mut().set_checks(checks);
        let facts = self.panel_facts(cx.session);
        let edges = self.timeline.inner().panel.edge_selection();
        link.borrow_mut().set_facts(facts, edges);
    }

    /// The facts the menu rules read from the panels (Swift `SourceHost.layout`, `SharedUIController`'s edge and delete
    /// facts, `currentFacts`' Project selection, the Inspector's fact provider).
    fn panel_facts(&mut self, session: &EditorSession) -> sq_draw_shell::ShellPanelFacts {
        use sq_core_model::BinItemRef;
        let mut f = sq_draw_shell::ShellPanelFacts::default();
        self.inspector.fill_facts(&mut f);
        f.panels_loaded = self.source.is_some();
        f.source_media_loaded = self.source.as_ref().is_some_and(|s| s.core().media_id().is_some());
        let (mut media, mut sequences) = (Vec::new(), 0);
        for r in self.project.view().selection() {
            match r {
                BinItemRef::Media(id) => media.push(*id),
                BinItemRef::Sequence(_) => sequences += 1,
                BinItemRef::Bin(_) => {}
            }
        }
        f.project_selected_media = media.len() as i64;
        f.project_selected_sequences = sequences;
        f.fill_reel_enabled = session.reel_slot_count() > 0 && !media.is_empty();
        f.project_media_has_file = media.iter().any(|id| session.project().media(*id).is_some());
        let panel = &self.timeline.inner().panel;
        f.edge_selected = panel.edge_selection().is_some();
        f.has_delete_target = panel.has_delete_target();
        f
    }

    /// Replace Modes and Append to Main Track (Swift `SourceHost.command`) and File > Export Markers as CSV
    /// (`MarkerListHost`): the status lines go out as events.
    fn run_placement(&mut self, cx: &mut HostCx, c: sq_uikit::editor_command::EditorCommand) {
        use sq_uikit::editor_command::EditorCommand as C;
        match c {
            C::Insert | C::Overwrite | C::PlaceOnTop => {
                use sq_uikit::focus_routing::PlaceSource;
                let f = self.panel_facts(cx.session);
                let focus = self.shell.shell().focus;
                match PlaceSource::resolve(
                    f.source_media_loaded,
                    focus,
                    f.project_selected_media,
                    f.project_selected_sequences,
                ) {
                    PlaceSource::SourceMonitor => {
                        if let Some(source) = &mut self.source {
                            source.run_edit(cx, c);
                        }
                    }
                    // Swift `ProjectListView.run`: media go through the format question, sequences nest as one clip.
                    PlaceSource::ProjectMedia => {
                        let ids = media_ids(self.project.view().selection());
                        let options = sq_editor_session::PlaceOptions {
                            mode: if c == C::Insert {
                                sq_core_model::ThreePointMode::Insert
                            } else {
                                sq_core_model::ThreePointMode::Overwrite
                            },
                            place_on_top: c == C::PlaceOnTop,
                            ..Default::default()
                        };
                        cx.emit(AppEvent::Flow(ShellFlow::PlaceMedia { ids, options }));
                    }
                    PlaceSource::ProjectSequences => {
                        let ids: Vec<_> = self
                            .project
                            .view()
                            .selection()
                            .iter()
                            .filter_map(
                                |r| if let sq_core_model::BinItemRef::Sequence(id) = r { Some(*id) } else { None },
                            )
                            .collect();
                        let mode = if c == C::Insert {
                            sq_core_model::ThreePointMode::Insert
                        } else {
                            sq_core_model::ThreePointMode::Overwrite
                        };
                        if !cx.session.place_sequences(&ids, None, None, mode, None)
                            && let Some(e) = cx.session.last_error()
                        {
                            cx.emit(AppEvent::Status(e.to_string()));
                        }
                    }
                    PlaceSource::Nothing => {}
                }
            }
            C::FitToFill | C::ReplaceClipFromSource => {
                if let Some(source) = &mut self.source {
                    source.run_edit(cx, c);
                }
            }
            C::EditOriginal => {
                // The Project selection when it has focus, else the selected clips' files, else the Source clip
                // (Swift `ShellFacts`: which files the command is enabled for).
                fn cx_path(s: &EditorSession, id: sq_core_time::Id) -> Option<String> {
                    s.project().media(id).map(|m| m.path.clone())
                }
                let mut files = if self.shell.shell().focus == Some(PanelID::Project) {
                    media_ids(self.project.view().selection())
                        .iter()
                        .filter_map(|id| cx_path(cx.session, *id))
                        .collect()
                } else {
                    cx.session.original_files_of_selection()
                };
                if files.is_empty() {
                    files = self
                        .source
                        .as_ref()
                        .and_then(|s| s.core().media_id())
                        .and_then(|id| cx_path(cx.session, id))
                        .into_iter()
                        .collect();
                }
                let mut line = match files.len() {
                    0 => "Nothing selected has an original file.".to_string(),
                    1 => "Opening the original file.".to_string(),
                    n => format!("Opening {n} original files."),
                };
                for f in &files {
                    if let Err(e) = self.opener.open(std::path::Path::new(f)) {
                        line = format!("Could not open {f}: {e}");
                    }
                }
                cx.emit(AppEvent::Status(line));
            }
            C::FillReel => {
                // Fills a copy of the open sequence ("<name> Fill") with the selected media, one per slot; the template stays.
                let ids = media_ids(self.project.view().selection());
                let line = match cx.session.fill_reel(&ids, true) {
                    Some(r) => format!(
                        "Filled {} slot{}{}.",
                        r.filled.len(),
                        if r.filled.len() == 1 { "" } else { "s" },
                        if r.unfilled.is_empty() {
                            String::new()
                        } else {
                            format!(", {} left empty", r.unfilled.len())
                        }
                    ),
                    None => {
                        cx.session.last_error().map_or_else(|| "Fill Reel did not run.".to_string(), str::to_string)
                    }
                };
                cx.emit(AppEvent::Status(line));
            }
            C::ReplaceMode(mode) => match &mut self.source {
                Some(source) => source.replace_with_mode(cx, mode),
                None => cx.emit(AppEvent::Status(
                    "Open a clip in the Source monitor first (double-click it in the Project panel).".to_string(),
                )),
            },
            C::AppendToMainTrack => {
                let picked = crate::project_host::media_ids(self.project.view().selection());
                match &mut self.source {
                    Some(source) => source.append_to_main_track(cx, picked),
                    None => cx.emit(AppEvent::Status("Open a clip in the Source view first.".to_string())),
                }
            }
            C::AttachBacktimed => {
                let picked = crate::project_host::media_ids(self.project.view().selection());
                match &mut self.source {
                    Some(source) => source.attach_backtimed(cx, picked),
                    None => cx.emit(AppEvent::Status("Open a clip in the Source view first.".to_string())),
                }
            }
            C::ExportMarkersCSV => {
                if let Some(list) = &self.marker_list {
                    list.export_csv(cx);
                }
            }
            C::RemoveFillerWords => {
                let line = match &mut self.text {
                    Some(text) => text.remove_filler_words(cx.session),
                    None => "Create captions first: the filler words come from the transcript.".to_string(),
                };
                cx.emit(AppEvent::Status(line));
            }
            C::DisguiseVoice => {
                let line = match &mut self.text {
                    Some(text) => text.disguise_voice(cx.session),
                    None => crate::TextHost::new().disguise_voice(cx.session),
                };
                cx.emit(AppEvent::Status(line));
            }
            _ => {}
        }
    }

    /// Export Frame: pauses, renders the picture at the sequence's size and saves it where the save panel says
    /// (`MacPictureTap.exportFrame`). The frame arrives a few frames later: [`Self::poll_frame_grab`] finishes it.
    fn export_frame(&mut self, session: &mut EditorSession) -> Option<String> {
        let Some(picture) = self.frame_picture.clone().filter(|p| p.size().is_some()) else {
            session.engine_mut().pause();
            return Some("There is no frame to export yet.".to_string());
        };
        if self.frame_grab.is_some() {
            return None;
        }
        let name = session.active_timeline().map(|t| t.name.clone()).unwrap_or_default();
        let name = crate::frame_export::suggested_name(if name.is_empty() { "Frame" } else { &name });
        self.frame_grab = Some(crate::FrameGrab::start(session.engine_mut(), &picture, name));
        None
    }

    /// A waiting Export Frame looks for its picture; the status line of a finished one.
    fn poll_frame_grab(&mut self, cx: &mut HostCx) -> Option<String> {
        let picture = self.frame_picture.clone()?;
        let grab = self.frame_grab.as_mut()?;
        match grab.poll(cx.session.engine_mut(), &picture, &mut *cx.services.panel_files) {
            crate::Grab::Waiting => {
                cx.ui.request_animation();
                None
            }
            crate::Grab::Done(line) => {
                self.frame_grab = None;
                line
            }
        }
    }

    /// Whether a drop is the Command variant: the key held now (Swift `TimelineDropRoute.drag`: `insert = mods.contains(.command)`;
    /// the timeline's drop preview turns it into insert or overwrite by the sequence's mode).
    fn drop_inserts(&self) -> bool {
        self.live_modifiers.contains(InputModifiers::COMMAND)
    }

    /// A drag from the Library: files, saved titles and built-in templates follow the pointer over the timeline.
    fn library_drag(
        &mut self,
        cx: &mut HostCx,
        payload: LibraryDragPayload,
        phase: DragPhase,
        at: CGPoint,
        px: (f32, f32),
        lines: &mut Vec<String>,
    ) {
        let kind = match payload {
            LibraryDragPayload::Files(urls) => DropKind::Files(urls),
            LibraryDragPayload::TitleBlock(id) => DropKind::Title(id),
            LibraryDragPayload::TextTemplate(id) => DropKind::Template(id),
            LibraryDragPayload::AudioStack(id) => {
                lines.extend(self.drag_effect_key(cx, id, phase, at, px));
                return;
            }
            LibraryDragPayload::EffectPreset(id) => {
                lines.extend(self.drag_effect_preset(cx, id, phase, at, px));
                return;
            }
        };
        lines.extend(self.drag_to_timeline(cx, kind, phase, at, px, SourceStreams::Both));
    }

    /// The clip an Effects or Library drag released over Effect Controls lands on: the clip shown there, none while it
    /// shows a transition (Swift `inspectorDropClip`).
    fn inspector_drop_clip(dock: &ShellDock, session: &EditorSession, at: CGPoint) -> Option<sq_core_time::Id> {
        if !dock.content_frame(PanelID::EffectControls).is_some_and(|f| f.contains(at))
            || session.selected_transition().is_some()
        {
            return None;
        }
        session.single_selected_clip().map(|c| c.id)
    }

    /// A saved effect preset dragged from the Library (Swift `LibraryDropRoute.drag(.library(.effectPreset))`): the clip
    /// under the pointer lights, a release applies it there; over Effect Controls it lands on the clip shown.
    fn drag_effect_preset(
        &mut self,
        cx: &mut HostCx,
        id: sq_core_time::Id,
        phase: DragPhase,
        at: CGPoint,
        (x, y): (f32, f32),
    ) -> Option<String> {
        self.drag_effect_key(cx, format!("preset.{id}"), phase, at, (x, y))
    }

    /// A built-in effect or stack row dragged from the Library: same landing rules as `drag_effect_preset`.
    fn drag_effect_key(
        &mut self,
        cx: &mut HostCx,
        key: String,
        phase: DragPhase,
        at: CGPoint,
        (x, y): (f32, f32),
    ) -> Option<String> {
        let over = self.dock.content_frame(PanelID::Timeline).is_some_and(|f| f.contains(at));
        let panel = &mut self.timeline.inner().panel;
        if phase == DragPhase::Moved {
            if over {
                panel.effect_drop_hover(std::slice::from_ref(&key), x, y, sq_core_time::Time::ZERO);
            } else {
                panel.effect_drop_exit();
            }
            return None;
        }
        panel.effect_drop_exit();
        if phase != DragPhase::Ended {
            return None;
        }
        let target = if over {
            self.timeline.inner().panel.clip_id(x, y)
        } else {
            Self::inspector_drop_clip(&self.dock, cx.session, at)
        }?;
        let presets = self.library.panel_host().panel.model.presets().to_vec();
        let settings = sq_draw_shell::BytesView(std::rc::Rc::clone(&self.shell.shell().settings));
        let with = EffectsApply {
            presets: &presets,
            mode: PresetApplyModeSetting::load(&settings),
            transitions: TransitionDefaults::load(&settings),
            edges: None,
        };
        crate::drop_on_clips(cx.session, &[key], &BTreeSet::from([target]), &with)
    }

    /// The Source drag (both streams from the picture, one from a footer handle): the timeline shows its drop preview, the
    /// tile follows the pointer, the release places the Source clip with those streams.
    fn source_dragged(
        &mut self,
        cx: &mut HostCx,
        streams: SourceStreams,
        phase: sq_draw_monitor::monitor_panel_source_drag::MonitorDragPhase,
        x: f32,
        y: f32,
    ) -> Option<String> {
        use sq_draw_monitor::monitor_panel_source_drag::MonitorDragPhase as M;
        self.source_drag_tile = (phase == M::Moved).then_some((streams, x, y));
        let id = self.source.as_ref()?.core().media_id()?;
        let phase = match phase {
            M::Moved => DragPhase::Moved,
            M::Ended => DragPhase::Ended,
            M::Canceled => DragPhase::Canceled,
        };
        let at = CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale));
        self.drag_to_timeline(cx, DropKind::Media(vec![id]), phase, at, (x, y), streams)
    }

    /// Project media dragged over the timeline. Option held at the release over a clip replaces that clip with the first
    /// item (Swift `TimelineDropRoute.drag`), and with Shift too, when the Source monitor shows that media, its frame lines
    /// up with the playhead (`match_source_time`). Anything else is a normal drop.
    fn project_dragged(
        &mut self,
        cx: &mut HostCx,
        ids: Vec<sq_core_time::Id>,
        phase: DragPhase,
        (x, y): (f32, f32),
    ) -> Option<String> {
        let at = CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale));
        let over = self.dock.content_frame(PanelID::Timeline).is_some_and(|f| f.contains(at));
        if phase == DragPhase::Ended
            && over
            && self.live_modifiers.contains(InputModifiers::OPTION)
            && let Some(clip) = self.timeline.inner().panel.clip_id(x, y)
        {
            self.timeline.inner().panel.drop_exit();
            let first = *ids.first()?;
            let source = self.source.as_ref().map(|s| s.core());
            let matched = source
                .filter(|c| self.live_modifiers.contains(InputModifiers::SHIFT) && c.media_id() == Some(first))
                .map(|c| c.current_time());
            let done = sq_draw_timeline::drop_replace(&TimelineDropSource::Media(ids), clip, matched, cx.session);
            return if done { None } else { cx.session.last_error().map(str::to_string) };
        }
        self.drag_to_timeline(cx, DropKind::Media(ids), phase, at, (x, y), SourceStreams::Both)
    }

    /// A drag over the timeline panel: the ghost and the snap line follow the pointer (`drop_hover`); the release lands
    /// where the ghost showed (`drop_commit`). Returns a status line.
    fn drag_to_timeline(
        &mut self,
        cx: &mut HostCx,
        kind: DropKind,
        phase: DragPhase,
        at: CGPoint,
        (x, y): (f32, f32),
        streams: SourceStreams,
    ) -> Option<String> {
        let over = self.dock.content_frame(PanelID::Timeline).is_some_and(|f| f.contains(at));
        let insert = self.drop_inserts();
        let TimelineAppHost { panel, host } = self.timeline.inner();
        if phase == DragPhase::Canceled || !over {
            panel.drop_exit();
            return None;
        }
        let source = match &kind {
            DropKind::Media(ids) => TimelineDropSource::Media(ids.clone()),
            DropKind::Files(urls) => TimelineDropSource::Files(urls.clone()),
            DropKind::Title(_) | DropKind::Template(_) => TimelineDropSource::Files(Vec::new()),
        };
        if phase == DragPhase::Moved {
            let items = drop_items(&source, cx.session, streams);
            panel.drop_hover(items, x, y, insert, true, streams);
            return None;
        }
        let ids = if let DropKind::Media(ids) = &kind { ids.clone() } else { Vec::new() };
        let mut line = None;
        for action in panel.drop_commit(ids, x, y, insert) {
            let TimelineAction::DropMedia { time, track, new_track, insert, .. } = action else { continue };
            match &kind {
                DropKind::Media(_) => {
                    line = sq_draw_timeline::session_bridge::apply(action, cx.session, host, Some(&mut *panel));
                }
                DropKind::Files(urls) => {
                    let urls = urls.clone();
                    cx.emit(AppEvent::Flow(ShellFlow::PlaceFilesAt { urls, at: time, track, new_track, insert }));
                }
                DropKind::Title(id) => {
                    let item = self.library.panel_host().panel.model.presets().iter().find(|p| p.id == *id).cloned();
                    line = item.map(|i| TextTemplatePlacement::insert_title(&i, Some(time), cx.session));
                }
                DropKind::Template(id) => {
                    let entries = self.library.panel_host().panel.model.template_entries();
                    line = match entries.iter().find(|e| e.id == *id) {
                        Some(e) if e.is_cta => cx.session.add_cta_end_card(Some(time), track).map(|_| String::new()),
                        Some(e) => match &e.graphic_preset_id {
                            Some(g) => cx.session.add_graphic_preset(g, Some(time), track).map(|_| String::new()),
                            None => match sq_inspector_ui::text::template_tiles::TextTemplateCatalog::entry(&e.id) {
                                Some(entry) => cx
                                    .session
                                    .add_text_clip(
                                        &entry.template,
                                        Some(time),
                                        track,
                                        sq_core_time::Time::new(5, 1),
                                        None,
                                        false,
                                    )
                                    .map(|_| String::new()),
                                None => None,
                            },
                        },
                        None => None,
                    }
                    .filter(|l| !l.is_empty());
                }
            }
        }
        line
    }

    /// The window point `at` as device pixels (the timeline panel takes pixels).
    fn pixels(at: CGPoint, scale: f32) -> (f32, f32) {
        ((at.x * f64::from(scale)) as f32, (at.y * f64::from(scale)) as f32)
    }

    /// Hands the answered folder-name dialog of the Effects panel back to it.
    fn poll_effects_name(&mut self) {
        let Some((ask, purpose)) = &mut self.effects_name else { return };
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        let std::task::Poll::Ready(answer) = std::pin::Pin::new(ask).poll(&mut cx) else { return };
        let purpose = purpose.clone();
        self.effects_name = None;
        let name = if answer == SQDialogResponse::FIRST {
            self.shell.shell().take_answered_form().and_then(|mut f| {
                f.commit_editing();
                f.text("name").map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
            })
        } else {
            None
        };
        if let Some(effects) = &mut self.effects {
            effects.panel_host().panel.answer_name(&purpose, name.as_deref());
        }
    }

    /// Files the curves saved from the curve popover in the Library as `.easing` presets (`EasingPresets.save`: the name
    /// trimmed, empty becomes "Custom Curve") and hands the list back to the popover.
    fn file_ease_saves(&mut self) {
        use sq_core_model::{EasingCurveShape, easing_curve_from_preset_payload};
        let saves = self.inspector.take_ease_saves();
        let model = &mut self.library.panel_host().panel.model;
        for (shape, name) in saves {
            let name = name.trim();
            let name = if name.is_empty() { "Custom Curve" } else { name };
            let id = sq_core_time::Id::from_u128(rand_id());
            let curve = sq_core_model::easing_curve_from_shape(id, &shape, name.to_string());
            let Ok(payload) = curve.preset_payload() else { continue };
            let now = sq_core_time::Timestamp::from_unix_seconds(
                SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64()),
            );
            let item = sq_library::preset_store::PresetItem::new(
                id,
                sq_library::preset_store::PresetKind::Easing,
                name,
                now,
                payload,
                i64::from(<sq_core_time::EasingCurve as EasingCurveShape>::PRESET_PAYLOAD_VERSION),
            );
            let _ = model.replace_preset(item);
        }
        let curves: Vec<_> = model
            .presets()
            .iter()
            .filter(|p| p.kind == sq_library::preset_store::PresetKind::Easing)
            .filter_map(|p| easing_curve_from_preset_payload(&p.payload, p.name.clone(), p.id).ok())
            .collect();
        self.inspector.set_saved_curves(curves);
    }

    /// The Effects panel's queue: double clicks apply to the selection, a drag lights the timeline target under the
    /// pointer, a release applies it (timeline clip, cut or empty spot) or applies to the selection (Effect Controls).
    fn answer_effects(&mut self, cx: &mut HostCx, lines: &mut Vec<String>) {
        let Some(effects) = &mut self.effects else { return };
        let events = effects.take_events();
        let presets = self.library.panel_host().panel.model.presets().to_vec();
        effects.list_presets(&presets);
        let settings = sq_draw_shell::BytesView(std::rc::Rc::clone(&self.shell.shell().settings));
        let with = EffectsApply {
            presets: &presets,
            mode: PresetApplyModeSetting::load(&settings),
            transitions: TransitionDefaults::load(&settings),
            edges: self.timeline.inner().panel.edge_selection(),
        };
        let over =
            |dock: &ShellDock, panel: PanelID, at: CGPoint| dock.content_frame(panel).is_some_and(|f| f.contains(at));
        for e in events {
            match e {
                EffectsDeferred::Apply(id) => lines.extend(crate::apply_to_selection(cx.session, &[id], &with)),
                EffectsDeferred::Moved(ids, at) => {
                    let (x, y) = Self::pixels(at, cx.scale);
                    let layer = crate::effects_host::layer_duration(cx.session, &ids, &with.transitions);
                    let panel = &mut self.timeline.inner().panel;
                    if over(&self.dock, PanelID::Timeline, at) {
                        panel.effect_drop_hover(&ids, x, y, layer);
                    } else {
                        panel.effect_drop_exit();
                    }
                    if let Some(g) = &mut self.graphics {
                        g.effect_drag_over(Some(at));
                    }
                }
                EffectsDeferred::Dropped(ids, at) => {
                    let (x, y) = Self::pixels(at, cx.scale);
                    let layer = crate::effects_host::layer_duration(cx.session, &ids, &with.transitions);
                    let panel = &mut self.timeline.inner().panel;
                    if over(&self.dock, PanelID::Timeline, at) {
                        panel.effect_drop_hover(&ids, x, y, layer);
                        if let Some(drop) = panel.effect_drop_take() {
                            lines.extend(crate::apply_drop(cx.session, &ids, drop, &with));
                        }
                    } else {
                        panel.effect_drop_exit();
                        let shown = Self::inspector_drop_clip(&self.dock, cx.session, at);
                        if let Some(clip) = shown {
                            lines.extend(crate::drop_on_clips(cx.session, &ids, &BTreeSet::from([clip]), &with));
                        } else if let Some(g) = &mut self.graphics {
                            // The Graphics card takes plain effects for its layer (not presets, not transitions).
                            let kinds: Vec<String> = ids
                                .iter()
                                .filter(|i| {
                                    !i.starts_with("preset.")
                                        && sq_editor_session::EffectDragPayload::transition_kind(i).is_none()
                                })
                                .cloned()
                                .collect();
                            if !kinds.is_empty() {
                                g.drop_effects(&kinds, at, cx);
                            }
                        }
                    }
                    if let Some(g) = &mut self.graphics {
                        g.effect_drag_over(None);
                    }
                }
                EffectsDeferred::Canceled => {
                    self.timeline.inner().panel.effect_drop_exit();
                    if let Some(g) = &mut self.graphics {
                        g.effect_drag_over(None);
                    }
                }
                EffectsDeferred::Other(EffectsEvent::Menu(items, at)) => {
                    let origin = self.dock.content_frame(PanelID::Effects).unwrap_or_default();
                    let at = CGPoint::new(at.x + origin.x, at.y + origin.y);
                    self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
                }
                EffectsDeferred::Other(EffectsEvent::AskName { title, initial, purpose }) => {
                    // Swift `panel.askName`: a dialog with one Name field; an empty or canceled answer is none.
                    let mut d = ShellDialog::new(&title, "");
                    d.form =
                        Some(Box::new(ShellForm::new(vec![FormRow::field("name", &SQL10n::string("Name"), &initial)])));
                    d.add_button(&SQL10n::string("OK"), SQDialogRole::Default, false);
                    d.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
                    self.effects_name = Some((self.shell.shell().present(d), purpose));
                }
                EffectsDeferred::Other(_) => lines.push("This Effects action is not available here yet.".to_string()),
            }
        }
    }

    /// The menu command behind a Program monitor footer button.
    fn monitor_command(
        a: sq_draw::monitor::monitor_modes::MonitorAction,
    ) -> Option<sq_uikit::editor_command::EditorCommand> {
        use sq_draw::monitor::monitor_modes::MonitorAction as A;
        use sq_uikit::editor_command::EditorCommand as C;
        Some(match a {
            A::MarkIn => C::MarkIn,
            A::MarkOut => C::MarkOut,
            A::GoToIn => C::GoToIn,
            A::GoToOut => C::GoToOut,
            A::ClearIn => C::ClearIn,
            A::ClearOut => C::ClearOut,
            A::ClearInOut => C::ClearInOut,
            A::StepBack => C::StepBackward,
            A::StepForward => C::StepForward,
            A::PlayPause => C::PlayPause,
            A::AddMarker => C::AddMarker,
            A::Lift => C::Lift,
            A::Extract => C::Extract,
            A::ExportFrame => C::ExportFrame,
            A::Loop => C::ToggleLoop,
            A::PlayInToOut => C::PlayInToOut,
            A::Insert | A::Overwrite | A::Replace | A::FitToFill | A::ToggleSafeMargins => return None,
        })
    }

    /// Stores the layouts of an imported pack as user workspaces (same name = replaced; a built-in name is skipped).
    fn import_workspaces(&mut self, layouts: &[sq_editor_session::Workspace]) -> Option<String> {
        let mut store = self.dock.store().clone();
        let added = layouts.iter().filter(|w| store.library.save_as(&w.name, w)).count();
        if added > 0 {
            self.dock.load(store);
            if let Some(line) = self.save_workspaces() {
                return Some(line);
            }
        }
        (added < layouts.len())
            .then(|| format!("{} workspace layouts in the pack could not be added.", layouts.len() - added))
    }

    /// Writes the dock layouts when a storage path is set; the failure line otherwise.
    fn save_workspaces(&self) -> Option<String> {
        let path = self.workspaces_path.as_ref()?;
        self.dock.store().save(path).err().map(|e| format!("The layout could not be saved: {e}"))
    }

    /// Runs `turn` on the shell with the layouts it shares with the root's dock: the shell's menu rows (Window >
    /// Workspaces, panel toggles) edit its own dock, so the root's layouts go in first and a changed result comes back
    /// and is saved.
    fn shell_turn<R>(&mut self, cx: &mut HostCx, turn: impl FnOnce(&mut ShellHost, &mut HostCx) -> R) -> R {
        if self.shell.shell().dock.store() != self.dock.store() {
            self.shell.shell().dock.load(self.dock.store().clone());
        }
        if self.shell.shell().dock.floating.state() != self.dock.floating.state() {
            self.shell.shell().dock.load_floating(self.dock.floating.state().clone());
        }
        // The maximized panel is transient (not in the layouts): Maximize Panel Under Pointer, run by a key or a menu row,
        // toggles the shell's copy, so the window's dock hands its own state in first and takes the result back.
        self.shell.shell().dock.adopt_maximized(self.dock.maximized());
        let out = turn(&mut self.shell, cx);
        let maximized = self.shell.shell().dock.maximized();
        self.dock.adopt_maximized(maximized);
        // The floating windows live in the root's dock; the shell's rows (Reset to Saved Layout, Window > panel) edit a
        // copy, so a changed copy and the windows it wants forward come back too (else the real window never changes).
        let shell_dock = &mut self.shell.shell().dock;
        for p in shell_dock.floating.take_raised() {
            self.dock.floating.raise(p);
        }
        if shell_dock.floating.state() != self.dock.floating.state() {
            self.dock.floating.adopt_state(shell_dock.floating.state().clone());
            self.dock.relayout();
        }
        if self.shell.shell().dock.store() != self.dock.store() {
            self.dock.load(self.shell.shell().dock.store().clone());
            if let Some(line) = self.save_workspaces() {
                cx.emit(AppEvent::Status(line));
            }
        }
        out
    }

    /// The export queue popover lies over the panels: its Escape, every press and what happens inside its frame go to it
    /// before the panels (a click on its "Stop All" or "..." reached the Project panel underneath). Hover and wheel
    /// outside its frame go on to the panels.
    /// A picker, curve or Multiband popover of Effect Controls, the Text panel or the Graphics panel is open.
    fn any_popover(&self) -> bool {
        self.inspector.has_popover()
            || self.text.as_ref().is_some_and(|t| t.has_popover())
            || self.graphics.as_ref().is_some_and(|g| g.has_popover())
    }

    fn export_popover_wants(&mut self, e: &InputEvent, scale: f32) -> bool {
        let Some(frame) = self.shell.shell().export_queue_popover_frame() else { return false };
        let at = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        match *e {
            InputEvent::KeyDown { key, .. } => key == sq_draw::InputKey::Escape,
            InputEvent::MouseDown { .. } => true,
            InputEvent::MouseMoved { x, y }
            | InputEvent::MouseDragged { x, y, .. }
            | InputEvent::MouseUp { x, y }
            | InputEvent::Scroll { x, y, .. } => frame.contains(at(x, y)),
        }
    }

    /// `e` as the host of a panel sees it: whole while the panel is `shown`; when it is not, a move is the pointer far away
    /// (its hover and tip clear) and a press, drag, release or wheel does not reach it. Keys pass either way (the focus
    /// routes them).
    fn pointer_for(shown: bool, e: &InputEvent) -> Option<InputEvent> {
        match e {
            _ if shown => Some(*e),
            InputEvent::MouseMoved { .. } => Some(InputEvent::MouseMoved { x: -1.0e6, y: -1.0e6 }),
            InputEvent::KeyDown { .. } => Some(*e),
            _ => None,
        }
    }

    /// The one card of Program and Source is drawn: its own tab is up, or the Source tab when there is no Source host.
    fn monitor_shown(&self) -> bool {
        self.dock.shows(PanelID::ProgramMonitor) || (self.source.is_none() && self.dock.shows(PanelID::SourceMonitor))
    }

    fn shell_handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.shell_turn(cx, |shell, cx| shell.handle(e, cx))
    }

    fn shell_pump(&mut self, cx: &mut HostCx) {
        self.shell_turn(cx, |shell, cx| shell.pump(cx));
    }

    /// Hands the picks of a closed menu row to the host that built it.
    fn pump_menu_picks(&mut self, cx: &mut HostCx) {
        self.monitor.pump(cx.session);
        self.library.panel_host().panel.pump();
        if let Some(effects) = &mut self.effects {
            effects.panel_host().panel.pump();
        }
        if let Some(text) = &mut self.text {
            text.pump(cx);
        }
        if let Some(meter) = &mut self.meter {
            meter.pump();
        }
        self.project.pump(cx);
        self.inspector.pump(cx);
        self.file_ease_saves();
        if let Some(list) = &mut self.marker_list {
            list.pump(cx);
        }
        if let Some((items, at)) = self.marker_list.as_mut().and_then(crate::MarkerListHost::take_menu) {
            let items = self.dock.with_panel_rows(PanelID::MarkerList, items, false);
            self.open_menu(cx, items, CGRect::new(at.x, at.y, 0.0, 0.0), Some(at));
        }
        for (phase, window) in self.monitor.take_step_window_events() {
            self.color.apply_window_drag(cx.session, phase, &window);
        }
        self.color.pump(cx);
        self.library.panel_host().panel.model.set_lut_entries(self.color.lut_entries());
        if let Some(source) = &mut self.source {
            source.pump(cx);
        }
        self.timeline.pump(cx);
        self.header.pump(cx, self.timeline.inner(), &mut self.settings);
        self.tools.pump(self.timeline.inner());
        self.dock.run_tab_actions();
    }
}

impl AppRoot {
    /// The project is opening (r8 loading state): the viewer and timeline show it, the next frame draws the skeletons of the
    /// Inspector, Library and Project. `None` is the loaded editor. Nothing opens a project through here yet: the shot
    /// pose `state-loading` is the one caller (shortcut: wire it to the real open when it reports progress).
    pub fn set_opening(&mut self, name: Option<String>) {
        self.timeline.inner().panel.loading = name.is_some();
        self.monitor.panel.model.opening = name.clone();
        self.chrome.set_export_locked(name.is_some());
        self.opening = name;
    }

    /// Grey skeleton rows over the Inspector, Library and Project while a project opens (r8:733, 774, 781).
    fn draw_opening_skeletons(&mut self, c: &mut Canvas, t: &DrawTheme) {
        use sq_draw::empty_pane::{SkeletonKind, draw_skeleton};
        if self.opening.is_none() {
            return;
        }
        for g in self.dock.groups() {
            match g.selected {
                PanelID::EffectControls => draw_skeleton(c, t, g.content, SkeletonKind::Inspector, 15),
                PanelID::Library => {
                    let list = self.library.panel_host().panel.list_rect();
                    let area = CGRect::new(
                        g.content.min_x() + list.min_x(),
                        g.content.min_y() + list.min_y(),
                        list.width,
                        list.height,
                    );
                    draw_skeleton(c, t, area, SkeletonKind::Browser, 7);
                }
                // The 24 pt column header stays: the rows start below it.
                PanelID::Project => {
                    let area = CGRect::new(
                        g.content.min_x(),
                        g.content.min_y() + 24.0,
                        g.content.width,
                        (g.content.height - 24.0).max(0.0),
                    );
                    draw_skeleton(c, t, area, SkeletonKind::Browser, 10);
                }
                _ => {}
            }
        }
    }
}

impl AppRoot {
    /// The "Media offline" card and the resolution badge of the Program monitor, per frame (equal values are not
    /// re-assigned). Swift: MonitorCardHost.swift:371 `refreshOfflineAndSize`.
    fn refresh_offline_and_size(&mut self, session: &EditorSession) {
        let project = session.project();
        let offline = self.project.model();
        let name = |id: sq_core_time::Id| {
            offline.is_offline(id).then(|| project.media(id).map_or_else(|| "Media".to_string(), |m| m.name.clone()))
        };
        let failure = session.engine().failure();
        let model = &mut self.monitor.panel.model;
        if model.engine_failure != failure {
            model.engine_failure = failure;
        }
        match session.active_timeline() {
            Some(tl) => {
                let n = sq_editor_session::MediaOfflineCard::file_name(tl, session.playhead(), name);
                if model.offline_file_name != n {
                    model.offline_file_name = n;
                }
                let size = Some((tl.format.display_width(), tl.format.height));
                if model.picture_size != size {
                    model.picture_size = size;
                }
            }
            None => model.offline_file_name = None,
        }
        // r8:759: a sequence without a clip says so on the picture (the Project's own count and the Library's empty state
        // follow the project by themselves).
        let empty = session
            .active_timeline()
            .filter(|tl| tl.tracks.iter().all(|t| t.clips().is_empty()))
            .map(|tl| tl.name.clone());
        if model.empty_sequence != empty {
            model.empty_sequence = empty;
        }
    }
}

impl AppRoot {
    /// The stored Subject Mask Edges choice (default by machine).
    fn stored_subject_edges(
        d: &dyn sq_uikit::appearance_palette::UiDefaults,
    ) -> sq_analysis::subject_mask_quality::SubjectMaskQuality {
        use sq_analysis::subject_mask_quality::SubjectMaskQuality as Q;
        d.string(Q::DEFAULTS_KEY).and_then(|s| Q::from_raw(&s)).unwrap_or_else(Q::standard)
    }
}

impl AppHost for AppRoot {
    fn wants_frames(&self) -> bool {
        self.timeline.needs_frames()
            || self.shell.start_mascot_animating()
            // An idle window gets no other wake: the recovery debounce needs polls until the snapshot is written.
            || self.persist.as_ref().is_some_and(|p| p.snapshot_needs_poll())
    }

    fn key_up(&mut self, key: InputKey, cx: &mut HostCx) {
        self.shell.shell().key_up(cx.session, key);
    }

    fn alt_tapped(&mut self, cx: &mut HostCx) {
        // Not while a dialog, palette or panel popover owns the keyboard.
        if self.shell.has_dialog()
            || self.shell.quick_apply_open()
            || self.any_popover()
            || self.monitor.is_text_editing()
        {
            return;
        }
        self.shell_turn(cx, |shell, cx| shell.alt_tapped(cx));
    }

    fn focus_lost(&mut self, cx: &mut HostCx) {
        self.end_text_edits(cx);
        self.shell.shell().release_held_keys(cx.session);
    }

    fn focus_gained(&mut self, cx: &mut HostCx) {
        // A file that came back (a drive mounted, a copy finished) while another app had the focus is online again.
        // Not only the Project row: the engine reopens it and the timeline judges its clips again, like after Locate.
        let before: std::collections::BTreeSet<sq_core_time::Id> =
            cx.session.project().media.iter().filter(|m| self.project.model().is_offline(m.id)).map(|m| m.id).collect();
        self.project.refresh_offline();
        let (mut appeared, mut vanished) = (std::collections::BTreeSet::new(), std::collections::BTreeSet::new());
        for m in cx.session.project().media.iter() {
            match (before.contains(&m.id), self.project.model().is_offline(m.id)) {
                (true, false) => appeared.insert(m.id),
                (false, true) => vanished.insert(m.id),
                _ => false,
            };
        }
        let touched = cx.session.media_files_came_or_went(appeared, vanished);
        self.timeline_media.files_changed(&touched);
    }

    fn theme_changed(&mut self, theme: &DrawTheme) {
        self.timeline.theme_changed(theme);
    }

    fn sync(&mut self, session: &EditorSession) {
        // Swift `onKeymapChanged`: a map edited in Keyboard Shortcuts reaches the timeline and header menus.
        if let Some(map) = self.shell.shell().take_keymap_change() {
            self.header.set_command_map(map.clone());
            self.tools.set_command_map(map.clone());
            self.tools.set_command_map(map.clone());
            self.timeline.set_command_map(map);
        }
        // Effect Controls first: the overlay reads its handles, mask outlines and selected section.
        sq_app_shell::timed("inspector sync", || self.inspector.sync(session));
        if let Some(persist) = &self.persist {
            self.monitor.set_subject_edges(Self::stored_subject_edges(&*persist.defaults().borrow()));
        }
        self.monitor.set_source_open(self.source.as_ref().is_some_and(|s| s.core().media_id().is_some()));
        let tool = self.timeline.inner().panel.tool_state();
        self.monitor.set_mask_tool((tool.tool == sq_editor_session::TimelineTool::Mask).then_some(tool.mask_mode));
        self.monitor.set_create_tool((tool.tool == sq_editor_session::TimelineTool::Type).then_some(tool.create_mode));
        self.monitor.set_hand_tool(tool.tool == sq_editor_session::TimelineTool::Hand);
        // The layer overlay reads the Graphics editor before the card syncs.
        let editor = self.graphics.as_mut().map(|g| &g.panel().host.editor);
        self.monitor.sync_layers(session, editor);
        self.monitor.sync_with(session, &self.inspector.controls().model);
        let editor = self.graphics.as_mut().map(|g| &g.panel().host.editor);
        self.monitor.sync_text(session, editor);
        sq_app_shell::timed("library sync", || self.library.sync(session));
        if let Some(effects) = &mut self.effects {
            effects.sync(session);
        }
        if let Some(text) = &mut self.text {
            text.sync(session);
        }
        sq_app_shell::timed("project sync", || self.project.sync(session));
        sq_app_shell::timed("offline and size", || self.refresh_offline_and_size(session));
        if let Some(list) = &mut self.marker_list {
            list.sync(session);
        }
        self.animation_keystones.refresh(self.library.panel_host().panel.model.presets());
        if let Some(link) = &self.timeline_link {
            link.borrow_mut().set_presets(self.library.panel_host().panel.model.presets());
        }
        if let Some(source) = &mut self.source {
            source.sync(session);
        }
        self.timeline_media.pump(session.project().media.iter());
        sq_app_shell::timed("timeline sync", || self.timeline.sync(session));
        self.timeline.inner().panel.sync_toggles(session);
        sq_app_shell::timed("shell sync", || self.shell.sync(session));
        let tool = *self.timeline.inner().panel.tool_state();
        let media = self.timeline.inner().panel.media.clone();
        self.access.sync(session, tool, media.as_deref());
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        let m = &cx.measure();
        sq_app_shell::timed("shell layout", || self.shell.layout(frame, cx));
        self.inspector.set_window(frame);
        if let Some(text) = &mut self.text {
            text.set_window(frame);
        }
        if let Some(graphics) = &mut self.graphics {
            graphics.set_window(frame);
        }
        // The start screen's menu bar takes its own top strip; in the edit window the titles sit in the title row.
        let merged = !self.shell.start_shown();
        self.shell.shell().menu_bar.set_merged(merged);
        let bar = self.shell.shell().menu_bar.height();
        let mut body = CGRect::new(frame.x, frame.y + bar, frame.width, (frame.height - bar).max(0.0));
        if !self.shell.start_shown() {
            let (quality, linked_selection) = self.chrome_values();
            let grade = self.color.grade_status(cx.session);
            let bar = &mut self.shell.shell().menu_bar;
            let room = self.chrome.menu_room(frame.width, bar.origin().x, m);
            bar.set_room_limit(Some(room), m);
            let inputs = ChromeInputs {
                session: cx.session,
                shell: self.shell.shell(),
                quality,
                linked_selection,
                page: self.dock.store().page,
                grade: &grade,
                now: SystemTime::now(),
            };
            body = sq_app_shell::timed("chrome layout", || self.chrome.layout(frame, &inputs, m));
        }
        self.dock.set_measure(m);
        // The Project tab strip carries the item count, New Folder and "..." (Swift: SharedUIController.swift:251,
        // `projectList.dock(in: shell.dock)`): the dock keeps their width free, the list draws into the strip.
        self.dock.project_tools = self.project.strip_tools_width(m);
        // The Library strip carries "Import..." in Presets mode (kit: Panel / Library / Presets).
        let library_tools = if self.library.panel_host().panel.wants_import() {
            sq_draw_library::library::library_draw_panel::LibraryDrawPanel::IMPORT_WIDTH + 6.0
        } else {
            0.0
        };
        if self.dock.library_tools != library_tools {
            self.dock.library_tools = library_tools;
            self.dock.relayout();
        }
        if self.dock.frame != body {
            sq_app_shell::timed("dock set_frame", || self.dock.set_frame(body));
        }
        // The shell's own dock answers the panel commands (Select Next Panel, Maximize): it needs the same layout.
        {
            let shell_dock = &mut self.shell.shell().dock;
            // This root's dock lays out the panels and draws the focus frame; the shell's copy only answers commands
            // (its groups lag behind a maximize or a resize).
            shell_dock.draws_focus_frame = false;
            shell_dock.set_measure(m);
            if shell_dock.frame != body {
                shell_dock.set_frame(body);
            }
        }
        self.menu.bounds = frame;
        // A Window-menu change of the shown monitor moves the header's tab with it.
        let tab = usize::from(self.source.is_some() && self.dock.shows(PanelID::SourceMonitor));
        self.monitor.panel.selected_tab = tab;
        let monitor = self.monitor_frame();
        let monitor = self.color.monitor_card(monitor, &self.dock);
        self.monitor.hides_transform_handles = self.color.is_on_color_page();
        sq_app_shell::timed("monitor layout", || self.monitor.layout(monitor, cx));
        let window_edit = self.color.window_edit_target();
        self.monitor.refresh_step_window(cx.session, window_edit.as_ref());
        let import = self
            .dock
            .groups()
            .iter()
            .find(|g| g.selected == PanelID::Library && g.strip.height > 0.0)
            .filter(|_| self.dock.library_tools > 0.0)
            .map(|g| {
                let strip = g.tools_strip();
                CGRect::new(
                    strip.max_x() - sq_draw_library::library::library_draw_panel::LibraryDrawPanel::IMPORT_WIDTH,
                    strip.mid_y() - 10.0,
                    sq_draw_library::library::library_draw_panel::LibraryDrawPanel::IMPORT_WIDTH,
                    20.0,
                )
            });
        self.library.panel_host().set_strip_import(import);
        sq_app_shell::timed("library layout", || {
            self.library.layout(self.dock.content_frame(PanelID::Library).unwrap_or_default(), cx)
        });
        if let Some(effects) = &mut self.effects {
            effects.layout(self.dock.content_frame(PanelID::Effects).unwrap_or_default(), cx);
        }
        if let Some(graphics) = &mut self.graphics {
            graphics.layout(self.dock.content_frame(PanelID::Graphics).unwrap_or_default(), cx);
        }
        if let Some(source) = &mut self.source {
            source.layout(self.dock.content_frame(PanelID::SourceMonitor).unwrap_or_default(), cx);
        }
        if let Some(text) = &mut self.text {
            text.layout(self.dock.content_frame(PanelID::Text).unwrap_or_default(), cx);
        }
        if let Some(meter) = &mut self.meter {
            meter.layout(self.dock.content_frame(PanelID::AudioMeter).unwrap_or_default(), cx);
        }
        if let Some(list) = &mut self.marker_list {
            if self.dock.option_panels.insert(PanelID::MarkerList) {
                self.dock.relayout();
            }
            list.set_options_rect(self.dock.options_rect(PanelID::MarkerList));
            list.layout(self.dock.content_frame(PanelID::MarkerList).unwrap_or_default(), cx);
        }
        let strip = self
            .dock
            .groups()
            .iter()
            .find(|g| g.selected == PanelID::Project)
            .map(|g| sq_draw_shell::StripTools { strip: g.tools_strip() });
        self.project.set_strip(strip);
        sq_app_shell::timed("project layout", || {
            self.project.layout(self.dock.content_frame(PanelID::Project).unwrap_or_default(), cx)
        });
        // The header runs across the top of the timeline's frame; the lanes get the rest. The Tools panel is its own card.
        self.header.set_compact(self.color.is_on_color_page());
        let lanes = self.header.layout(
            self.dock.content_frame(PanelID::Timeline).unwrap_or_default(),
            cx,
            self.timeline.inner(),
        );
        let tools_frame =
            self.dock.groups().iter().find(|g| g.selected == PanelID::Tools).map(|g| g.frame).unwrap_or_default();
        self.tools.layout(tools_frame, cx.scale, self.timeline.inner());
        let st = self.header.bar().state();
        let title = st.tabs.iter().find(|t| t.active).map(|t| t.title.clone()).unwrap_or_default();
        self.color.set_timeline_labels(title, st.edit_mode == sq_core_model::TimelineEditMode::Magnetic);
        sq_app_shell::timed("timeline layout", || self.timeline.layout(lanes, cx));
        sq_app_shell::timed("inspector layout", || {
            self.inspector.layout(self.dock.content_frame(PanelID::EffectControls).unwrap_or_default(), cx)
        });
        sq_app_shell::timed("color layout", || self.color.layout(&mut self.dock, cx));
        if let Some(d) = &mut self.dialog {
            d.layout(frame, m);
        }
        sq_app_shell::timed("full screen layout", || self.layout_full_screen(frame, cx));
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.poll_library_flows(cx);
        self.poll_extractions(cx);
        self.apply_system_load(cx);
        let project_version = cx.session.version(sq_editor_session::Change::PROJECT);
        if project_version != self.silences_pruned_at {
            self.silences_pruned_at = project_version;
            crate::export_audio::prune_silences(crate::export_audio::app_silences(), &cx.session.project().timelines);
        }
        // Proxy transcodes show in the export queue popover like the Mac's background jobs.
        self.shell.shell().export.background_jobs = cx
            .session
            .pump_proxies()
            .into_iter()
            .map(|j| sq_draw_shell::BackgroundJob { id: j.id, title: j.title, progress: j.progress })
            .collect();
        if let Some(line) = cx.session.take_proxy_disk_notice() {
            self.chrome.flash(line, SystemTime::now());
        }
        if self.draw_full_screen(c, t, cx) {
            return;
        }
        if !self.shell.start_shown() {
            let (quality, linked_selection) = self.chrome_values();
            let grade = self.color.grade_status(cx.session);
            let inputs = ChromeInputs {
                session: cx.session,
                shell: self.shell.shell(),
                quality,
                linked_selection,
                page: self.dock.store().page,
                grade: &grade,
                now: SystemTime::now(),
            };
            self.chrome.draw(c, t, &inputs);
        }
        if self.dock.tick(cx.ui.now) {
            cx.session.engine_mut().redraw();
        }
        self.dock.draw(c, t);
        for g in self.dock.groups() {
            if !(self.effects.is_some() && g.selected == PanelID::Effects)
                && !(self.graphics.is_some() && g.selected == PanelID::Graphics)
                && !(self.text.is_some() && g.selected == PanelID::Text)
                && !(self.meter.is_some() && g.selected == PanelID::AudioMeter)
                && !(self.marker_list.is_some() && g.selected == PanelID::MarkerList)
                && !matches!(
                    g.selected,
                    PanelID::ProgramMonitor
                        | PanelID::SourceMonitor
                        | PanelID::Library
                        | PanelID::Project
                        | PanelID::Timeline
                        | PanelID::Tools
                        | PanelID::EffectControls
                        | PanelID::ColorInspector
                        | PanelID::Steps
                        | PanelID::ColorClips
                        | PanelID::Scopes
                )
            {
                ShellDock::draw_placeholder(c, g.selected, g.content, t);
            }
        }
        // With the Source tab selected the Program card has no frame and would draw its header at the origin.
        if self.monitor_shown() {
            self.monitor.draw(c, t, cx);
        }
        // On the Color page the Library is hidden: its content frame is empty and it would draw at the origin.
        if self.dock.shows(PanelID::Library) {
            self.library.draw(c, t, cx);
        } else {
            // Another tab or the Color page covers the Library: its preview must not play on unseen.
            self.library.panel_host().panel.pause_preview();
        }
        if let Some(effects) = &mut self.effects
            && self.dock.shows(PanelID::Effects)
        {
            effects.draw(c, t, cx);
        }
        if let Some(graphics) = &mut self.graphics
            && self.dock.shows(PanelID::Graphics)
        {
            graphics.draw(c, t, cx);
        }
        if let Some(text) = &mut self.text
            && self.dock.shows(PanelID::Text)
        {
            text.draw(c, t, cx);
        }
        if let Some(meter) = &mut self.meter
            && self.dock.shows(PanelID::AudioMeter)
        {
            if crate::meter_feed::feed_from_session(meter, cx.session, cx.ui.now) {
                cx.ui.request_animation();
            }
            meter.draw(c, t, cx);
        }
        if let Some(source) = &mut self.source
            && self.dock.shows(PanelID::SourceMonitor)
        {
            source.draw(c, t, cx);
        }
        if let Some(list) = &mut self.marker_list
            && self.dock.shows(PanelID::MarkerList)
        {
            list.draw(c, t, cx);
        }
        self.project.draw(c, t, cx);
        // Swift: `timelinePanel.gradeOutline = colorPage.gradeOutline` before each draw.
        let outline = self.color.grade_outline();
        if self.timeline.inner().panel.grade_outline != outline {
            self.timeline.inner().panel.grade_outline = outline;
        }
        self.timeline.draw(c, t, cx);
        self.header.draw(c, t);
        self.tools.draw(c, t, self.timeline.inner());
        self.inspector.draw(c, t, cx);
        self.color.set_focused_panel(self.dock.focused());
        self.color.set_picture_view(self.monitor.panel.canvas_rect(), self.monitor.panel.sequence_size().width);
        // The monitor's picture in physical pixels: playback composes at this size when it is smaller than the sequence.
        let view = self.monitor.panel.canvas_rect();
        let view_px =
            ((view.width * f64::from(cx.scale)).round() as u32, (view.height * f64::from(cx.scale)).round() as u32);
        if self.view_px != view_px {
            self.view_px = view_px;
            cx.session.engine_mut().set_view_size(view_px.0, view_px.1);
        }
        self.color.draw(c, t, cx);
        self.draw_opening_skeletons(c, t);
        // The blue focus frame follows this dock's current panel rect every frame; the shell's dialogs and menus draw over it.
        self.dock.draw_focus_frame(c, t);
        self.shell.draw(c, t, cx);
        if let Some(effects) = &self.effects {
            effects.draw_ghost(c, t, cx);
        }
        if let Some(d) = &mut self.dialog {
            let window = self.dock.frame;
            d.draw(c, t, window, cx.ui);
        }
        self.inspector.draw_popover(c, t, cx);
        if let Some(text) = &mut self.text {
            text.draw_popover(c, t, cx);
        }
        if let Some(graphics) = &self.graphics {
            graphics.draw_popover(c, t, cx);
        }
        if let Some((streams, x, y)) = self.source_drag_tile {
            let k = f64::from(cx.scale.max(0.01));
            sq_draw_monitor::monitor_panel_source_drag::SourceDragGhost::draw(
                c,
                streams,
                CGPoint::new(f64::from(x) / k, f64::from(y) / k),
                t,
            );
        }
        // The tab drag's drop preview: the drag runs on this dock, which the shell's own overlay pass never sees.
        self.dock.draw_drop_preview(c, t, &sq_draw::TextMeasure::new(c.atlas(), c.scale));
        self.menu.draw(c, t);
        if self.dropper.as_ref().is_some_and(crate::Eyedropper::is_armed)
            && let Some((loupe, pointer)) = &self.window_loupe
        {
            loupe.draw(c, *pointer, self.dock.frame, t);
        }
    }

    fn wants_window_frame(&self) -> bool {
        self.dropper.as_ref().is_some_and(crate::Eyedropper::wants_window_frame)
    }

    fn set_window_frame(&mut self, frame: sq_draw::RgbaImage) {
        if let Some(d) = &self.dropper {
            d.set_window_frame(frame);
        }
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        if self.sample_window(e, cx.scale) {
            return true;
        }
        if let InputEvent::MouseDown { modifiers, .. } | InputEvent::MouseDragged { modifiers, .. } = *e {
            self.live_modifiers = modifiers;
        }
        let tm = cx.measure();
        let scale = cx.scale;
        if self.inspector.has_keyboard_focus() && self.inspector_lost_keyboard(e, scale) {
            self.inspector.blur(cx);
        }
        // A press outside the Color grade panel commits a value typed into one of its fields, whoever takes the press.
        if let InputEvent::MouseDown { x, y, .. } = *e {
            self.color.commit_typing_on_press(x, y, cx);
        }
        if let Some(d) = &mut self.dialog {
            d.handle(e, scale, &tm, cx.ui);
            if d.finished() {
                self.dialog = None;
                // The answer sits in the sink of the host that asked (Text block, Style tab, Graphics, Timeline...); the
                // next menu close would run it, so every host runs its queue now.
                self.pump_menu_picks(cx);
            }
            return true;
        }
        cx.ui.hover.offer_tip(self.menu.tip_at(e, scale, &tm).as_deref());
        if self.menu.handle(e, scale, &tm) {
            self.pump_menu_picks(cx);
            self.answer(cx);
            return true;
        }
        if self.menu.take_dismissed() {
            self.pump_menu_picks(cx);
        }
        // The drawn menu bar's open menu lies over the panels: a press, release or key reaches it before them (a panel under
        // a submenu took the click on its row, and the focused panel took Enter). A press outside it closes it and goes on.
        if (self.shell.menu_open() || self.export_popover_wants(e, scale)) && !self.shell.start_shown() {
            let taken = self.shell_handle(e, cx);
            self.answer(cx);
            if taken {
                return true;
            }
        }
        // The one keyboard rule: while a palette, popup, sheet or menu is up it owns every key (an unclaimed one is dropped,
        // never an editor shortcut behind it), and the Quick Apply palette also takes the pointer (a press outside closes it).
        if !self.shell.start_shown()
            && ((matches!(e, InputEvent::KeyDown { .. }) && self.shell.owns_keyboard())
                || self.shell.quick_apply_open())
        {
            let _ = self.shell_handle(e, cx);
            self.answer(cx);
            return true;
        }
        if let Some(taken) = self.handle_full_screen(e, cx) {
            return taken;
        }
        // The press that closed a popover (the opener clicked a second time) takes its release with it.
        if self.popover_guard.swallows(e) {
            return true;
        }
        let popover_was_up = self.any_popover();
        if self.inspector.has_popover() && self.inspector.handle_popover(e, cx) {
            self.popover_guard.note(e, popover_was_up, self.any_popover());
            self.answer(cx);
            return true;
        }
        if let Some(text) = self.text.as_mut().filter(|t| t.has_popover())
            && text.handle_popover(e, cx)
        {
            let still_up = self.any_popover();
            self.popover_guard.note(e, popover_was_up, still_up);
            self.answer(cx);
            return true;
        }
        if let Some(graphics) = self.graphics.as_mut().filter(|g| g.has_popover())
            && graphics.handle_popover(e, cx)
        {
            let still_up = self.any_popover();
            self.popover_guard.note(e, popover_was_up, still_up);
            self.answer(cx);
            return true;
        }
        // A panel popover (color picker, easing, text and graphics pickers) owns the keys it did not use itself.
        if matches!(e, InputEvent::KeyDown { .. }) && self.any_popover() {
            self.answer(cx);
            return true;
        }
        // The start window is modal; otherwise the shell (menu bar, shortcuts) comes after the panels.
        if self.shell.start_shown() || self.shell.has_dialog() {
            let taken = self.shell_handle(e, cx);
            self.answer(cx);
            return taken;
        }
        // The on-canvas text field is the first responder while it is open: it takes every key before shortcuts do, and a
        // press outside the monitor ends the edit (Swift `MonitorTextHost.pressOutside`).
        if self.monitor.is_text_editing() {
            if let InputEvent::KeyDown { key, modifiers } = *e {
                if key.is_menu_chord(modifiers) {
                    // A menu chord (Export, Save ...) ends the edit like a press outside and goes on to the menu.
                    self.monitor.panel.text_field.end();
                } else {
                    let taken = self.monitor.handle(e, cx);
                    self.answer(cx);
                    return taken;
                }
            }
            if let InputEvent::MouseDown { x, y, .. } = *e
                && self.dock.panel_at(CGPoint::new(f64::from(x / scale), f64::from(y / scale)))
                    != Some(PanelID::ProgramMonitor)
            {
                self.monitor.panel.text_field.end();
            }
        }
        // A menu chord is the menu's whatever field has the keyboard: the open fields commit (the monitor's and the
        // inspector's own handlers do the same) and the chord goes on as if none were open.
        if let InputEvent::KeyDown { key, modifiers } = *e
            && key.is_menu_chord(modifiers)
        {
            self.end_text_edits(cx);
        }
        self.end_panel_fields_on_outside_press(e, cx);
        if let Some(taken) = self.name_field_gate(e, cx) {
            self.answer(cx);
            return taken;
        }
        // A search field with the keyboard is the first responder, like the on-canvas text field: it takes every key before
        // the tool, edit and timeline shortcuts do (B and A of "blade" switched tools and never reached the field).
        if matches!(e, InputEvent::KeyDown { .. }) {
            let focus = self.dock.focused();
            // A menu chord is the menu's even while a search field types: it goes on to the shell below.
            let menu_chord = matches!(*e, InputEvent::KeyDown { key, modifiers } if key.is_menu_chord(modifiers));
            let typing = !menu_chord
                && match focus {
                    Some(PanelID::Effects) => {
                        self.effects.as_mut().is_some_and(|f| f.panel_host().panel.is_editing_search())
                    }
                    Some(PanelID::Library) => self.library.panel_host().panel.is_editing_search(),
                    _ => false,
                };
            if typing {
                let taken = match focus {
                    Some(PanelID::Effects) => self.effects.as_mut().is_some_and(|f| f.handle(e, cx)),
                    _ => self.library.handle(e, cx),
                };
                self.answer(cx);
                return taken;
            }
        }
        if self.handle_chrome(e, cx) {
            return true;
        }
        // A press inside a panel gives it the keyboard focus (tab strips and gaps do it in the dock).
        if let InputEvent::MouseDown { x, y, .. } = *e
            && let Some(p) = self.dock.panel_at(CGPoint::new(f64::from(x / scale), f64::from(y / scale)))
        {
            self.dock.focus_press(p);
        }
        // A key goes to the panel with the focus first (the library's arrows must not swallow the timeline's frame step).
        let focus = self.dock.focused();
        self.request_divider_cursor(e, cx);
        let key = matches!(e, InputEvent::KeyDown { .. });
        let monitor_focus = matches!(focus, Some(PanelID::ProgramMonitor | PanelID::SourceMonitor));
        // A panel the dock does not draw (another tab on top, another panel maximized) hears no pointer press, drag or wheel
        // and sees every move as the pointer far away: it keeps the control rectangles of its last frame, and with those a
        // tip, a cursor and a click would still come from under the panel that covers it.
        let to = |p: PanelID| Self::pointer_for(self.dock.shows(p), e);
        let (timeline, tools, library) = (to(PanelID::Timeline), to(PanelID::Tools), to(PanelID::Library));
        let (effects, graphics, text, meter) =
            (to(PanelID::Effects), to(PanelID::Graphics), to(PanelID::Text), to(PanelID::AudioMeter));
        let (marker_list, project, source, inspector) =
            (to(PanelID::MarkerList), to(PanelID::Project), to(PanelID::SourceMonitor), to(PanelID::EffectControls));
        let monitor = Self::pointer_for(self.monitor_shown(), e);
        let taken = self.dock.handle(e, scale)
            || timeline.is_some_and(|ev| self.header.handle(&ev, cx, self.timeline.inner(), &mut self.settings))
            || tools.is_some_and(|ev| self.tools.handle(&ev, cx, self.timeline.inner()))
            // The timeline's own keys (zoom with + and -, Delete, the tool letters) need its focus: a value typed in Effect
            // Controls or a search field must never zoom or edit it.
            || (!key || matches!(focus, None | Some(PanelID::Timeline)))
                && timeline.is_some_and(|ev| self.timeline.handle(&ev, cx))
            || (!key || focus == Some(PanelID::Library)) && library.is_some_and(|ev| self.library.handle(&ev, cx))
            || (!key || focus == Some(PanelID::Effects))
                && effects.is_some_and(|ev| self.effects.as_mut().is_some_and(|f| f.handle(&ev, cx)))
            || (!key || focus == Some(PanelID::Graphics))
                && graphics.is_some_and(|ev| self.graphics.as_mut().is_some_and(|g| g.handle(&ev, cx)))
            || (!key || focus == Some(PanelID::Text))
                && text.is_some_and(|ev| self.text.as_mut().is_some_and(|t| t.handle(&ev, cx)))
            || !key && meter.is_some_and(|ev| self.meter.as_mut().is_some_and(|m| m.handle(&ev, cx)))
            || (!key || focus == Some(PanelID::MarkerList))
                && marker_list.is_some_and(|ev| self.marker_list.as_mut().is_some_and(|l| l.handle(&ev, cx)))
            || (!key || focus == Some(PanelID::Project)) && project.is_some_and(|ev| self.project.handle(&ev, cx))
            || (!key || focus == Some(PanelID::SourceMonitor))
                && source.is_some_and(|ev| self.source.as_mut().is_some_and(|s| s.handle(&ev, cx)))
            || (!key || monitor_focus) && monitor.is_some_and(|ev| self.monitor.handle(&ev, cx))
            || (!key || focus == Some(PanelID::EffectControls))
                && inspector.is_some_and(|ev| self.inspector.handle(&ev, cx))
            || self.color.handle(e, cx)
            || self.shell_handle(e, cx);
        self.answer(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        // Only what the dock draws: a panel another tab or a maximized panel covers keeps its last controls, and a screen
        // reader must not offer them (the pointer is gated the same way in `handle`).
        let shown = |p: PanelID| self.dock.shows(p);
        if self.monitor_shown() {
            self.monitor.a11y(a);
        }
        if shown(PanelID::Library) {
            self.library.a11y(a);
        }
        if shown(PanelID::Timeline) {
            self.timeline.a11y(a);
        }
        if shown(PanelID::EffectControls) {
            self.inspector.a11y(a);
        }
        if shown(PanelID::Project) {
            self.project.a11y(a);
        }
        if let Some(effects) = &self.effects
            && shown(PanelID::Effects)
        {
            effects.a11y(a);
        }
        self.color.a11y(a);
        self.shell.a11y(a);
        if a.is_active() {
            for g in self.dock.groups() {
                let mut n = accesskit::Node::new(accesskit::Role::TabPanel);
                n.set_label(sq_uikit::editor_command::EditorCommand::localized_panel_title(g.selected));
                n.set_selected(self.dock.focused() == Some(g.selected));
                a.push("dock", accesskit::Role::TabPanel, &format!("{:?}", g.selected), n);
            }
        }
        self.access.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let mut taken = self.inspector.a11y_action(id, action.clone(), cx)
            || self.monitor.a11y_action(id, action.clone(), cx)
            || self.library.a11y_action(id, action.clone(), cx)
            || self.effects.as_mut().is_some_and(|e| e.a11y_action(id, action.clone(), cx))
            || self.color.a11y_action(id, action.clone(), cx)
            || self.project.a11y_action(id, action.clone(), cx)
            || self.shell.a11y_action(id, action.clone(), cx);
        if !taken {
            match self.access.run(id, action, cx.session) {
                crate::session_access::Outcome::Unknown => {}
                crate::session_access::Outcome::Done => taken = true,
                crate::session_access::Outcome::Tool(t) => {
                    self.timeline.inner().panel.tool_state_mut().select(t);
                    taken = true;
                }
            }
        }
        self.answer(cx);
        taken
    }

    fn shell_mut(&mut self) -> Option<&mut sq_draw_shell::ShellHost> {
        Some(self.shell.shell())
    }

    fn dock_mut(&mut self) -> Option<&mut sq_draw_shell::ShellDock> {
        Some(&mut self.dock)
    }

    /// The Swift shot harness's `effectControlsSweep` states, one per call: the Effect Controls panel maximized, a
    /// rectangle mask, a Stabilizer at 42 %, the six effects of the sweep (each on the selected clip).
    fn shot_pose(&mut self, name: &str, cx: &mut HostCx) -> bool {
        use sq_core_model::ClipEffect;
        let selected = cx.session.selection().clone();
        match name {
            // The eyedropper sampling (the shot harness gives it the window frame and moves the pointer).
            "sampling" => {
                if let Some(d) = &self.dropper {
                    d.arm();
                }
            }
            // The editor while its project opens (loader and skeletons), without a loaded project change.
            "state-loading" => {
                let name = cx.session.project().name.clone();
                self.set_opening(Some(name));
            }
            // A project with no clip and no media, through the session's own delete paths.
            "state-empty" => {
                self.set_opening(None);
                cx.session.select_all_clips();
                cx.session.delete_selection(false, None);
            }
            // Offline is not a pose of its own: the media file is really missing (a removed symlink, or the use pass's
            // sample project). It only plays the playhead onto the first clip so the viewer reads the card.
            "state-offline" => {
                self.set_opening(None);
                cx.session.seek(sq_core_time::Time::ZERO);
            }
            // Library list columns for the proof shots: the Library watches the folder named by `SQ_POSE_LIBRARY_DIR` and is
            // maximized, so its list is wide enough for Kind / Size / Created (the docked panel is under the 300 pt column
            // rule). `project-deep` adds a bin nested 4 levels deep to the Project panel (each New Folder opens inside the
            // one just made). Nothing is removed; both are ordinary user actions.
            "library-media" => {
                if let Some(dir) = std::env::var_os("SQ_POSE_LIBRARY_DIR") {
                    self.add_library_folder(std::path::PathBuf::from(dir));
                }
                self.library
                    .panel_host()
                    .panel
                    .model
                    .set_view_mode(sq_draw_library::library::library_panel_model::LibraryViewMode::List);
                self.dock.show(PanelID::Library);
                self.dock.toggle_maximize(PanelID::Library);
                self.dock.set_focused(None);
            }
            // Website shots: the Library watches the folder named by `SQ_POSE_LIBRARY_DIR` in the normal docked layout.
            "library-watch" => {
                if let Some(dir) = std::env::var_os("SQ_POSE_LIBRARY_DIR") {
                    self.add_library_folder(std::path::PathBuf::from(dir));
                }
            }
            // Library preview proof: the watched folder's first video starts previewing (use with SQ_SHOT_WAIT_MS).
            "library-preview" => {
                if let Some(dir) = std::env::var_os("SQ_POSE_LIBRARY_DIR") {
                    self.add_library_folder(std::path::PathBuf::from(dir));
                }
                self.dock.show(PanelID::Library);
                self.dock.toggle_maximize(PanelID::Library);
                self.dock.set_focused(None);
                let panel = &mut self.library.panel_host().panel;
                panel.refresh();
                let video = panel.model.items().into_iter().find(|i| {
                    sq_library::library_preview_math::mode(i.entry.kind)
                        == Some(sq_library::library_preview_math::PreviewMode::Video)
                });
                panel.model.select_item_for_preview(video.as_ref());
            }
            "project-deep" => {
                for _ in 0..4 {
                    self.project.new_folder(cx);
                }
            }
            "max-ec" => {
                self.dock.show(PanelID::EffectControls);
                self.dock.toggle_maximize(PanelID::EffectControls);
                self.dock.set_focused(None);
            }
            // Two texts of one Graphic on the Program monitor, no layer selected: the proof of the click-to-pick-text rule.
            "graphic-texts" => {
                if cx.session.active_timeline().is_none() {
                    cx.session.add_sequence(None, None, None);
                }
                if let Some(g) = self.graphics.as_mut() {
                    let ed = &mut g.panel().host.editor;
                    if ed.new_graphics_clip(cx.session).is_some() {
                        ed.add_text_at(cx.session, sq_core_time::Vec2::new(-400.0, 0.0), "Left", None);
                        ed.add_text_at(cx.session, sq_core_time::Vec2::new(400.0, 0.0), "Right", None);
                        ed.select(cx.session, std::collections::BTreeSet::new());
                    }
                }
            }
            // The Captions panel's three tabs and the Graphics panel, maximized (design checks).
            "captions-transcript" | "captions-list" | "captions-style" | "graphics" | "graphics-text" => {
                let graphics = name.starts_with("graphics");
                let panel = if graphics { PanelID::Graphics } else { PanelID::Text };
                if graphics {
                    // A graphic with layers, so the panel shows its list.
                    cx.session.add_graphic_preset("sticker-circle", None, None);
                    // Three layers (shape, text, shape) so the list shows kind labels and the +Text / +Shape chips. The
                    // last one added is the selected one: a shape shows the shape rows, the text layer the Text block with
                    // its Look row (Save as New Look, Update, Font), which the sweep must open too.
                    if let Some(g) = self.graphics.as_mut() {
                        let ed = &mut g.panel().host.editor;
                        ed.sync(cx.session);
                        if name == "graphics-text" {
                            ed.add_shape(cx.session, sq_core_model::ShapeKind::Rectangle);
                            ed.add_text(cx.session, "Price");
                        } else {
                            ed.add_text(cx.session, "Price");
                            ed.add_shape(cx.session, sq_core_model::ShapeKind::Rectangle);
                        }
                    }
                }
                self.dock.show(panel);
                self.dock.toggle_maximize(panel);
                self.dock.set_focused(None);
                if let Some(text) = self.text.as_mut() {
                    use sq_inspector_ui::text::panel_draw::Tab;
                    let tab = match name {
                        "captions-transcript" => Tab::Transcript,
                        "captions-list" => Tab::Captions,
                        _ => Tab::Style,
                    };
                    if name == "captions-transcript" {
                        text.panel().use_transcription();
                    }
                    if !graphics {
                        text.panel().select(cx.session, tab);
                    }
                }
            }
            // The audio block's Effects tab (EQ, Gate, Noise Reduction, Warmth, Multiband), design checks.
            "audio-fx" => {
                self.inspector.sections().set_audio_tab(sq_inspector_ui::audio_masks::audio_effects_tab::Tab::Effects)
            }
            // The Timeline takes the blue focus frame, like the design frames of the Editor.
            "focus-timeline" => self.dock.set_focused(Some(PanelID::Timeline)),
            // `mask-ellipse:<feather px>:<half width>:<opacity %>`: a soft ellipse mask (site clips).
            n if n.starts_with("mask-ellipse:") => {
                let v: Vec<f64> = n["mask-ellipse:".len()..].split(':').filter_map(|x| x.parse().ok()).collect();
                if let [feather, half, opacity] = v[..] {
                    self.inspector.controls().model.add_ellipse_mask(feather, half, opacity);
                }
            }
            "mask" => {
                self.inspector.controls().model.add_mask(sq_core_model::MaskShapeKind::Rectangle);
            }
            // The Transition controls: a cross dissolve on every video cut of the selection or playhead, the first one picked.
            "transition" | "transition-wipe" | "transition-options" | "transition-custom" => {
                cx.session.apply_default_transitions(
                    sq_editor_session::TransitionScope::Video,
                    None,
                    None,
                    &sq_editor_session::TransitionDefaults::STANDARD,
                );
                // A cut between two clips shows the two-sided controls (Alignment switch); else the first one.
                let all: Vec<_> = cx
                    .session
                    .active_timeline()
                    .map(|t| t.tracks.iter().flat_map(|tr| tr.transitions.iter()).cloned().collect())
                    .unwrap_or_default();
                let pick =
                    all.iter().find(|x| x.outgoing.is_some() && x.incoming.is_some()).or(all.first()).map(|x| x.id);
                cx.session.select_transition(pick, false);
                if name != "transition"
                    && let Some(id) = pick
                {
                    // A kind with options behind the fold (Direction, softness, border, motion blur).
                    let change = sq_editor_session::TransitionTimingChange {
                        kind: Some(sq_core_model::TransitionKind::SoftWipe),
                        ..Default::default()
                    };
                    cx.session.set_transition(id, &change, false);
                }
                self.inspector.transition_panel().set_options_open(name == "transition-options");
                self.inspector.transition_panel().set_custom_open(name == "transition-custom");
            }
            // The Magic Mask section: a subject mask on the selected clip (its Magic Mask controls show).
            "magic-mask" => {
                cx.session.add_subject_mask();
            }
            "stabilize" => {
                if cx.session.add_stabilizer(&selected) {
                    let run = sq_inspector_ui::ec::stabilize::StabilizeRunState { clips: selected, progress: 0.42 };
                    self.inspector.controls().model.set_stabilize_run(Some(run));
                }
            }
            "effects" => {
                for kind in [
                    ClipEffect::GAUSSIAN_BLUR_KIND,
                    ClipEffect::DROP_SHADOW_KIND,
                    ClipEffect::CROP_KIND,
                    ClipEffect::LUMA_KEY_KIND,
                    ClipEffect::AGED_FILM_KIND,
                    ClipEffect::ROUNDED_CORNERS_KIND,
                ] {
                    cx.session.add_effect(kind, &selected);
                }
            }
            "new-project" => {
                let shell = self.shell.shell();
                shell.present_sample_start("home");
                return shell.present_sample_new_project();
            }
            "color-pro" | "color-grade" => return self.color.shot_pose(name, cx),
            // After `color-grade`, once the Steps tab exists: brings it to the front like a click on it.
            "color-steps" => self.dock.select(PanelID::Steps),
            "import-report" => self.shell.shell().present_sample_import_report(),
            other if other.starts_with("dlg-") => return self.shell.shell().present_sample_dialog(&other[4..]),
            other if other.starts_with("start-") => return self.shell.shell().present_sample_start(&other[6..]),
            _ => return false,
        }
        true
    }

    fn open_menu_items(&mut self) -> Vec<SQMenuItem> {
        let items = self.menu.root_items();
        if items.is_empty() { self.shell.shell().menu_bar.controller.root_items() } else { items }
    }

    fn open_bar_menu(&mut self, title: &str, cx: &mut HostCx) -> bool {
        let bar = &mut self.shell.shell().menu_bar;
        let Some(i) = bar.menus().iter().position(|m| m.title == title) else { return false };
        bar.open_menu(i, None, false, &cx.measure(), &mut None);
        true
    }

    fn launch(&mut self, cx: &mut HostCx) {
        self.shell.launch(cx);
        // A project opened before the window existed (`sequence-studio <file>`, the file association) is opened by the
        // session itself, as the window needs it for its first frame: the after-open work of the Open flow runs here,
        // before anything else can touch the project. An untitled session has nothing to do.
        self.shell.shell().project_opened(cx.session);
        self.shell.shell().restore_captions_in_monitor(cx.session);
        self.answer(cx);
    }

    fn take_image_uploads(&mut self) -> Vec<sq_app_shell::ImageUpload> {
        let mut uploads = self.project.take_uploads();
        uploads.extend(
            self.shell.shell().take_export_uploads().into_iter().map(|(slot, image)| sq_app_shell::ImageUpload {
                slot,
                at: None,
                image,
            }),
        );
        uploads.extend(self.timeline_media.take_uploads());
        if !self.shell.shell().is_start_shown() {
            self.start_posters.borrow_mut().release();
        }
        uploads.extend(self.start_posters.borrow_mut().take_uploads());
        uploads.extend(self.monitor.take_image_uploads());
        uploads.extend(self.color.take_image_uploads());
        uploads.extend(AppHost::take_image_uploads(&mut self.library));
        if let Some(effects) = &mut self.effects {
            let stills = effects.panel_host().atlas.take_uploads();
            uploads.extend(stills.into_iter().map(|(slot, x, y, image)| sq_app_shell::ImageUpload {
                slot,
                at: Some((x, y)),
                image,
            }));
        }
        uploads
    }

    fn pump(&mut self, cx: &mut HostCx) {
        self.shell.shell().tick_shuttle(cx.session);
        self.pump_quality(cx.session);
        self.shell_pump(cx);
        // The Color page's turn: the armed white-balance picker's answer, LUT choosers and decisions. It ran only after a
        // menu closed before, so the picker beeped until some menu had been used.
        self.color.pump(cx);
        if let Some(analysis) = &mut self.analysis {
            let turn = analysis.pump(cx.session);
            cx.events.extend(turn.lines.into_iter().map(AppEvent::Status));
            self.chrome.set_job_progress(turn.progress);
            let run = turn.stabilize_run.map(|(clip, progress)| sq_inspector_ui::ec::stabilize::StabilizeRunState {
                clips: std::collections::BTreeSet::from([clip]),
                progress,
            });
            if run.is_some() || self.stabilize_shown {
                self.stabilize_shown = run.is_some();
                self.inspector.controls().model.set_stabilize_run(run);
            }
            if turn.progress.is_some() {
                // The ring moves while a job runs; the job's own wake-up polls it.
                cx.ui.request_animation();
            }
        }
        self.answer(cx);
    }

    fn session_event(&mut self, event: &sq_editor_session::SessionEvent, cx: &mut HostCx) {
        // The session's "Use as Default" for transitions (Swift `session.onEffectDefaultsChange`).
        if let sq_editor_session::SessionEvent::EffectDefaultsChange(d) = event
            && let Some(line) = self.store_effect_defaults(cx.session, d.clone())
        {
            cx.emit(AppEvent::Status(line));
        }
        // Stabilize dropped or Rolling Shutter switched on: the analysis of these clips runs (Swift `analyzeStabilizers`).
        if let sq_editor_session::SessionEvent::StabilizerNeedsAnalysis { clips, .. } = event
            && let Some(analysis) = &mut self.analysis
        {
            analysis.analyze_stabilizers(clips);
            cx.ui.request_animation();
        }
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.monitor.on_change(changes, cx);
        self.library.on_change(changes, cx);
        if let Some(effects) = &mut self.effects {
            effects.on_change(changes, cx);
        }
        if let Some(graphics) = &mut self.graphics {
            graphics.on_change(changes, cx);
        }
        if let Some(text) = &mut self.text {
            text.on_change(changes, cx);
        }
        self.project.on_change(changes, cx);
        if let Some(source) = &mut self.source {
            source.on_change(changes, cx);
        }
        self.timeline.on_change(changes, cx);
        self.inspector.on_change(changes, cx);
        self.color.on_change(changes, cx);
        self.shell.on_change(changes, cx);
        self.answer(cx);
    }
}

mod full_screen;
#[cfg(test)]
mod heads_tests;
mod host_commands;
#[cfg(test)]
mod host_commands_tests;
mod library_flows;
mod media_prefs;
#[cfg(test)]
mod wired_hooks_tests;

#[cfg(test)]
mod covered_panels_tests;
#[cfg(test)]
mod create_tool_tests;
#[cfg(test)]
mod dead_commands_tests;
#[cfg(test)]
mod defaults_tests;
#[cfg(test)]
mod disabled_commands_tests;
#[cfg(test)]
mod effect_controls_delete_tests;
#[cfg(test)]
mod fast_cut_delete_tests;
#[cfg(test)]
mod idle_tests;
#[cfg(test)]
mod in_out_menu_tests;
#[cfg(test)]
mod layer_pick_tests;
#[cfg(test)]
mod linked_pair_tests;
#[cfg(test)]
mod menu_click_tests;
#[cfg(test)]
mod modal_keys_tests;
#[cfg(test)]
mod monitor_events_tests;
#[cfg(test)]
mod not_available_tests;
#[cfg(test)]
mod placement_tests;
#[cfg(test)]
mod popup_toggle_tests;
#[cfg(test)]
mod real_path_tests;
#[cfg(test)]
mod real_window_tests;
#[cfg(test)]
mod shown_shortcuts_tests;
#[cfg(test)]
mod silent_chords_tests;
#[cfg(test)]
mod source_drag_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod text_tool_tests;
#[cfg(test)]
mod trim_edge_tests;
#[cfg(test)]
mod view_tools_tests;
#[cfg(test)]
mod wheel_tests;

/// A random 128-bit id for a preset the user saves.
fn rand_id() -> u128 {
    let t = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(1, |d| d.as_nanos());
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    t << 64 | u128::from(std::process::id()) << 32 | u128::from(n)
}

static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
