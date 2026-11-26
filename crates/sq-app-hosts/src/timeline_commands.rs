// Swift: AppController+Commands / +TimelineOps (the timeline's view commands behind the menus and keys)
//! Menu and key commands that need the timeline panel's own state (snapping, zoom, track heights, tools, edge trims,
//! Fast Cut, speed band). The shell asks [`TimelineHooks`] first; it queues the command and the app root runs it on the
//! panel ([`run`]), because the hooks cannot reach the panel.

use sq_draw_shell::{ShellHooks, ShellPanelFacts};
use sq_draw_timeline::host::TimelineHost;
use sq_draw_timeline::panel::TimelinePanel;
use sq_editor_session::EditorSession;
use sq_library::library_folder_store::SettingsStore;
use sq_render::effects::display_view::DisplayView;
use sq_render::effects::view_choices::ViewChoices;
use sq_render::effects::view_gamma::ViewGamma;
use sq_uikit::editor_command::EditorCommand as C;
use sq_uikit::editor_command::{DisplayViewChoice, ViewGammaChoice};
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

/// What the hooks and the root share: commands waiting for the panel and the check marks the panel last published.
#[derive(Default)]
pub struct TimelineLinkState {
    queue: Vec<C>,
    checks: HashSet<C>,
    /// Edit > Delete with the Project focused waits for the Project host (the hooks cannot reach the list).
    project_delete: bool,
    /// View > Project Panel rows and Hover Scrub wait for the Project host too.
    project_view: Vec<C>,
    /// Sequence > Cut Tools > Whoosh at Selected Cuts was picked.
    whoosh: bool,
    /// Sequence > New Shape picks, run by the root through the Create tool's path (Swift `createShapeAtCenter`).
    new_shapes: Vec<sq_core_model::ShapeKind>,
    /// Sequence > Transcribe and Create Captions was picked.
    auto_captions: bool,
    /// Sequence > Layer > New Color Matte… was picked: the root opens the dialog (the timeline menu's own request).
    new_color_matte: bool,
    /// Quick Apply > Save Effect Stack as Preset was picked: the root opens the clip preset dialog (Swift `timelineHost.open?(.saveClipPreset)`).
    save_stack_preset: bool,
    /// View > View Gamma changed: the monitors redraw a paused picture (Swift `engine.redraw()`).
    gamma_changed: bool,
    /// View > Display and View > View Gamma: the app's handle, shared with the monitor picture and the windows.
    view: ViewChoices,
    /// View > Safe Margins and Show Overlays wait for the root, which owns the Program monitor (Swift `MonitorCardHost.wireTools`).
    monitor_view: Vec<C>,
    /// Export Frame (menu, Shift+E, a monitor's button) waits for the root, which owns the Program picture.
    export_frame: bool,
    /// Replace Modes, Append to Main Track, Export Markers as CSV, Remove Filler Words and Disguise Voice wait for the root, which owns the Source monitor, the
    /// Project selection and the marker list (Swift `SourceHost.command`, `MarkerListHost`).
    placement: Vec<C>,
    /// Commands a panel host runs on its own state (Project, Source, Graphics, Controls): the Swift `commandHandlers`
    /// chain. The root runs them in order ([`is_host_command`], `AppRoot::run_host_command`).
    host_commands: Vec<C>,
    /// Edit > Delete / Select All with the Graphics or Captions panel focused: the panel's own action, run by the root
    /// (Swift `shell.editActions`, set by `SharedUIController+ShellHooks`).
    edit_actions: Vec<sq_editor_session::EditAction>,
    /// The panel facts the menu rules read (Source clip, Project selection, edge, Controls clip), published by the root
    /// every frame (Swift `shell.panels` and `factProviders`).
    facts: ShellPanelFacts,
    /// The selected timeline edges (Swift `timelinePanel.interaction.edgeSelection`, read by Quick Apply).
    edges: Option<sq_editor_session::EdgeSelection>,
    /// The Library's saved presets, which Quick Apply lists next to the effects (Swift `connectQuickApply`).
    presets: Vec<sq_library::preset_store::PresetItem>,
    /// The system clipboard reader behind Paste with files or a picture (Swift `mediaClipboard`); `None` = no reader.
    media_clipboard: Option<crate::MediaClipboard>,
}

/// The shared state of one window.
pub type TimelineLink = Rc<RefCell<TimelineLinkState>>;

/// The shell's panel hooks for the timeline.
pub struct TimelineHooks(pub(crate) TimelineLink);

impl TimelineHooks {
    /// Hooks over an existing link (tests read what the shell's hooks answer).
    #[cfg(test)]
    pub(crate) fn from_link(link: &TimelineLink) -> TimelineHooks {
        TimelineHooks(Rc::clone(link))
    }

    /// Hooks plus the link the root keeps; the View menu choices go into `view`.
    pub fn new(view: ViewChoices) -> (TimelineHooks, TimelineLink) {
        let link = TimelineLink::default();
        link.borrow_mut().view = view;
        (TimelineHooks(Rc::clone(&link)), link)
    }

    /// Paste reads files and pictures from `clipboard` (the app passes the system one; tests pass a fake).
    pub fn with_media_clipboard(self, clipboard: crate::MediaClipboard) -> TimelineHooks {
        self.0.borrow_mut().media_clipboard = Some(clipboard);
        self
    }
}

impl ShellHooks for TimelineHooks {
    fn media_clipboard(&self) -> Option<sq_editor_session::PasteContent> {
        self.0.borrow().media_clipboard.as_ref().map(crate::MediaClipboard::read)
    }

    fn media_clipboard_offer(&self) -> Option<sq_editor_session::PasteOffer> {
        self.0.borrow().media_clipboard.as_ref().map(crate::MediaClipboard::offer)
    }

    fn media_clipboard_job(&self) -> Option<Box<dyn FnOnce() -> sq_editor_session::PasteContent + Send>> {
        self.0.borrow().media_clipboard.as_ref().and_then(crate::MediaClipboard::job)
    }

    /// The Quick Apply palette (Option+Space): effects, transitions, presets, the supported menu commands and macros
    /// (Swift `LibraryHost.connectQuickApply`). Without this hook the command only said it was not available.
    fn quick_apply_items(&self) -> Option<Vec<sq_editor_session::QuickApplyItem>> {
        use sq_draw_library::effects::effects_catalog::QuickApplyCatalogExt as _;
        let commands: Vec<C> = sq_uikit::menu_spec::EditorMenus::visible()
            .iter()
            .flat_map(sq_uikit::menu_spec::MenuSpec::commands)
            .filter(|c| sq_draw_shell::ShellMenuBar::is_visible(*c))
            .collect();
        Some(sq_editor_session::QuickApplyCatalog::items_for(&self.0.borrow().presets, &commands))
    }

    fn command_handler(&mut self, c: C) -> Option<bool> {
        if !is_host_command(&c) {
            return None;
        }
        self.0.borrow_mut().host_commands.push(c);
        Some(true)
    }

    fn on_command(&mut self, c: C) -> bool {
        if let C::DisplayView(choice) = c {
            // Session-only and display-only, like Swift `DisplayView.current`: the window surface follows on its next frame.
            self.0.borrow().view.set_display(display_view_of(choice));
            self.0.borrow_mut().gamma_changed = true;
            return true;
        }
        if let C::ViewGamma(choice) = c {
            // Session-only and display-only: both monitors read it on every frame (Swift `ViewGamma.current`).
            self.0.borrow().view.set_gamma(view_gamma_of(choice));
            self.0.borrow_mut().gamma_changed = true;
            return true;
        }
        if c == C::ExportFrame {
            self.0.borrow_mut().export_frame = true;
            return true;
        }
        if matches!(
            c,
            C::ProjectListView
                | C::ProjectIconView
                | C::ToggleHoverScrub
                | C::ProjectThumbnailSmaller
                | C::ProjectThumbnailLarger
        ) {
            self.0.borrow_mut().project_view.push(c);
            return true;
        }
        // Insert, Overwrite and Place on Top also run from a Project selection alone (`AppRoot::run_placement`).
        if matches!(c, C::Insert | C::Overwrite | C::PlaceOnTop | C::EditOriginal | C::FillReel) {
            self.0.borrow_mut().placement.push(c);
            return true;
        }
        if matches!(c, C::FitToFill | C::ReplaceClipFromSource) && self.0.borrow().facts.source_media_loaded {
            self.0.borrow_mut().placement.push(c);
            return true;
        }
        if matches!(
            c,
            C::ReplaceMode(_)
                | C::AppendToMainTrack
                | C::AttachBacktimed
                | C::ExportMarkersCSV
                | C::RemoveFillerWords
                | C::DisguiseVoice
        ) {
            self.0.borrow_mut().placement.push(c);
            return true;
        }
        if matches!(c, C::ToggleSafeAreas | C::ToggleOverlays) {
            self.0.borrow_mut().monitor_view.push(c);
            return true;
        }
        if !is_view_command(&c) {
            return false;
        }
        self.0.borrow_mut().queue.push(c);
        true
    }

    fn edit_effect_controls(&mut self, c: C) {
        self.0.borrow_mut().host_commands.push(c);
    }

    fn edit_action(&mut self, a: sq_editor_session::EditAction) {
        self.0.borrow_mut().edit_actions.push(a);
    }

    /// The same list the Quick Apply palette shows, so a picked preset applies what the row promised.
    fn library_presets(&self) -> Vec<sq_library::preset_store::PresetItem> {
        self.0.borrow().presets.clone()
    }

    fn has_project_list(&self) -> bool {
        true
    }

    fn save_stack_as_preset(&mut self) -> bool {
        self.0.borrow_mut().save_stack_preset = true;
        true
    }

    fn edge_selection(&self) -> Option<sq_editor_session::EdgeSelection> {
        self.0.borrow().edges.clone()
    }

    fn fill_facts(&self, p: &mut ShellPanelFacts) {
        let f = self.0.borrow();
        p.panels_loaded = f.facts.panels_loaded;
        p.source_media_loaded = f.facts.source_media_loaded;
        p.project_selected_media = f.facts.project_selected_media;
        p.project_selected_sequences = f.facts.project_selected_sequences;
        p.project_media_has_file = f.facts.project_media_has_file;
        p.fill_reel_enabled = f.facts.fill_reel_enabled;
        p.edge_selected = f.facts.edge_selected;
        p.has_delete_target = f.facts.has_delete_target;
        p.effect_controls_clip = f.facts.effect_controls_clip;
        p.effect_selection_empty = f.facts.effect_selection_empty;
        p.effect_can_copy = f.facts.effect_can_copy;
        p.effect_can_cut = f.facts.effect_can_cut;
        p.effect_can_paste = f.facts.effect_can_paste;
        p.effect_can_delete = f.facts.effect_can_delete;
    }

    fn run_auto_captions(&mut self) -> Option<bool> {
        self.0.borrow_mut().auto_captions = true;
        Some(true)
    }

    fn run_whoosh_at_cuts(&mut self) -> bool {
        self.0.borrow_mut().whoosh = true;
        true
    }

    fn on_action(&mut self, a: &sq_draw_shell::ShellAction) -> bool {
        match a {
            sq_draw_shell::ShellAction::NewColorMatte => {
                self.0.borrow_mut().new_color_matte = true;
                true
            }
            _ => false,
        }
    }

    fn on_new_shape(&mut self, kind: sq_core_model::ShapeKind) -> bool {
        self.0.borrow_mut().new_shapes.push(kind);
        true
    }

    fn delete_project_selection(&mut self, _host: &mut sq_draw_shell::ShellHost, _session: &mut EditorSession) {
        self.0.borrow_mut().project_delete = true;
    }

    fn menu_checks(&self) -> HashSet<C> {
        let mut checks = self.0.borrow().checks.clone();
        let current = self.0.borrow().view.gamma();
        checks.extend(ViewGammaChoice::ALL.into_iter().filter(|g| view_gamma_of(*g) == current).map(C::ViewGamma));
        let view = self.0.borrow().view.display();
        checks.extend(DisplayViewChoice::ALL.into_iter().filter(|v| display_view_of(*v) == view).map(C::DisplayView));
        checks
    }
}

fn display_view_of(choice: DisplayViewChoice) -> DisplayView {
    match choice {
        DisplayViewChoice::Sdr => DisplayView::Sdr,
        DisplayViewChoice::DisplayP3 => DisplayView::DisplayP3,
        DisplayViewChoice::Hdr1000 => DisplayView::Hdr1000,
        DisplayViewChoice::UnToneMapped => DisplayView::UnToneMapped,
    }
}

fn view_gamma_of(choice: ViewGammaChoice) -> ViewGamma {
    match choice {
        ViewGammaChoice::Mac => ViewGamma::Mac,
        ViewGammaChoice::Web => ViewGamma::Web,
        ViewGammaChoice::Broadcast => ViewGamma::Broadcast,
    }
}

/// Commands the panel hosts run themselves (Swift `shell.commandHandlers` / the chained `shell.onCommand` of
/// `MonitorCardHost`, `SourceHost`, `GraphicsHost`, `InspectorHost`, `ProjectListView`).
pub fn is_host_command(c: &C) -> bool {
    matches!(
        c,
        C::NewBin
            | C::SetPosterFrame
            | C::ClearPosterFrame
            | C::MatchFrame
            | C::ReverseMatchFrame
            | C::SelectLayerAbove
            | C::SelectLayerBelow
            | C::AddKeyframe
            | C::EditDynamicZoom
            | C::EaseLinear
            | C::EasyEase
            | C::EaseIn
            | C::EaseOut
            | C::ToggleHoldInterpolation
    )
}

/// Commands the panel runs ([`TimelinePanel::run_view_command`], [`TimelinePanel::run_speed_command`]).
pub fn is_view_command(c: &C) -> bool {
    matches!(
        c,
        C::Tool(_)
            | C::SlipKeyframesStayTool
            | C::ToggleSnapping
            | C::ToggleLinkedSelection
            | C::ThumbnailMode(_)
            | C::ToggleMagnetic
            | C::ZoomIn
            | C::ZoomOut
            | C::ZoomFit
            | C::VideoTracksTaller
            | C::VideoTracksShorter
            | C::AudioTracksTaller
            | C::AudioTracksShorter
            | C::AllTracksTaller
            | C::AllTracksShorter
            | C::ToggleFitTracks
            | C::MinimizeAllTracks
            | C::ExpandAllTracks
            | C::TrackHeightSmall
            | C::TrackHeightMedium
            | C::TrackHeightLarge
            | C::TrackHeightAuto
            | C::SelectLeftEdge
            | C::SelectRightEdge
            | C::ToggleTrimType
            | C::ExtendEdit
            | C::TrimBackward
            | C::TrimForward
            | C::TrimBackward5
            | C::TrimForward5
            | C::SaveAsTemplate
            | C::Combine
            | C::CreateAnglesClip
            | C::ToggleAnimationZones
            | C::EditMarker
            | C::AddAndEditMarker
            | C::ToggleTimeRemapping
            | C::AddSpeedPoint
            | C::RemoveTimeRemapping
            | C::SpeedRampPreset(..)
    )
}

impl TimelineLinkState {
    /// Whether the Project list was asked to delete its selection since the last call.
    pub fn take_whoosh(&mut self) -> bool {
        std::mem::take(&mut self.whoosh)
    }

    /// The Sequence > New Shape picks since the last call.
    pub fn take_new_shapes(&mut self) -> Vec<sq_core_model::ShapeKind> {
        std::mem::take(&mut self.new_shapes)
    }

    /// Whether New Color Matte… was picked since the last call.
    pub fn take_new_color_matte(&mut self) -> bool {
        std::mem::take(&mut self.new_color_matte)
    }

    /// Whether Save Effect Stack as Preset was picked since the last call.
    pub fn take_save_stack_preset(&mut self) -> bool {
        std::mem::take(&mut self.save_stack_preset)
    }

    /// Whether Transcribe and Create Captions was picked since the last call.
    pub fn take_auto_captions(&mut self) -> bool {
        std::mem::take(&mut self.auto_captions)
    }

    /// The Replace Modes, Append to Main Track and Export Markers as CSV queued since the last call.
    pub fn take_placement(&mut self) -> Vec<C> {
        std::mem::take(&mut self.placement)
    }

    /// The Program monitor's View switches queued since the last call.
    pub fn take_monitor_view(&mut self) -> Vec<C> {
        std::mem::take(&mut self.monitor_view)
    }

    /// The panel-host commands queued since the last call.
    pub fn take_host_commands(&mut self) -> Vec<C> {
        std::mem::take(&mut self.host_commands)
    }

    /// The Project panel view commands queued since the last call.
    /// The Graphics and Captions panel actions picked since the last call.
    pub fn take_edit_actions(&mut self) -> Vec<sq_editor_session::EditAction> {
        std::mem::take(&mut self.edit_actions)
    }

    pub fn take_project_view(&mut self) -> Vec<C> {
        std::mem::take(&mut self.project_view)
    }

    pub fn take_project_delete(&mut self) -> bool {
        std::mem::take(&mut self.project_delete)
    }

    /// Whether Export Frame was asked since the last call.
    pub fn take_export_frame(&mut self) -> bool {
        std::mem::take(&mut self.export_frame)
    }

    /// Whether View Gamma changed since the last call.
    pub fn take_gamma_changed(&mut self) -> bool {
        std::mem::take(&mut self.gamma_changed)
    }

    /// The commands queued since the last call.
    pub fn take_commands(&mut self) -> Vec<C> {
        std::mem::take(&mut self.queue)
    }

    /// Publishes the panel facts for the menu rules (the hooks hand them to the shell).
    pub fn set_facts(&mut self, facts: ShellPanelFacts, edges: Option<sq_editor_session::EdgeSelection>) {
        self.facts = facts;
        self.edges = edges;
    }

    /// Publishes the Library's saved presets for Quick Apply (kept only when they changed).
    pub fn set_presets(&mut self, presets: &[sq_library::preset_store::PresetItem]) {
        if self.presets != presets {
            self.presets = presets.to_vec();
        }
    }

    /// Publishes the View and Sequence check marks for the menus.
    pub fn set_checks(&mut self, checks: HashSet<C>) {
        self.checks = checks;
    }
}

/// Where a command runs: the panel in view, who has the keyboard focus.
pub struct CommandScope {
    /// The zoom commands go to the timeline (no monitor has the focus).
    pub zooms: bool,
    /// The timeline (or nothing) has the focus.
    pub owns_delete: bool,
}

/// Runs a queued command on the panel; the status line it left, if any.
pub fn run(
    c: &C,
    panel: &mut TimelinePanel,
    host: &mut TimelineHost,
    session: &mut EditorSession,
    scope: &CommandScope,
    defaults: &mut dyn SettingsStore,
) -> Option<String> {
    let line = panel
        .run_view_command(c, session, scope.zooms, Some(host), scope.owns_delete, defaults)
        .or_else(|| panel.run_speed_command(c, session))?;
    (!line.is_empty()).then_some(line)
}

#[cfg(test)]
impl TimelineLinkState {
    pub(crate) fn checks_has(&self, c: &C) -> bool {
        self.checks.contains(c)
    }
}

#[cfg(test)]
mod gamma_tests {
    use super::*;

    #[test]
    fn view_gamma_sets_the_shared_choice_checks_it_and_asks_for_a_redraw() {
        let view = ViewChoices::default();
        let (mut hooks, link) = TimelineHooks::new(view.clone());
        assert!(hooks.on_command(C::ViewGamma(ViewGammaChoice::Web)));
        assert_eq!(view.gamma(), ViewGamma::Web);
        assert!(link.borrow_mut().take_gamma_changed());
        assert!(!link.borrow_mut().take_gamma_changed());
        let checks = hooks.menu_checks();
        assert!(checks.contains(&C::ViewGamma(ViewGammaChoice::Web)));
        assert!(!checks.contains(&C::ViewGamma(ViewGammaChoice::Mac)));
        assert!(hooks.on_command(C::ViewGamma(ViewGammaChoice::Mac)));
        assert_eq!(view.gamma(), ViewGamma::Mac);
    }

    #[test]
    fn display_view_is_session_only_checked_and_defaults_to_sdr() {
        let view = ViewChoices::default();
        let (mut hooks, link) = TimelineHooks::new(view.clone());
        assert_eq!(view.display(), DisplayView::Sdr);
        assert!(hooks.menu_checks().contains(&C::DisplayView(DisplayViewChoice::Sdr)));
        assert!(hooks.on_command(C::DisplayView(DisplayViewChoice::Hdr1000)));
        assert_eq!(view.display(), DisplayView::Hdr1000);
        assert!(link.borrow_mut().take_gamma_changed(), "the picture is redrawn");
        let checks = hooks.menu_checks();
        assert!(checks.contains(&C::DisplayView(DisplayViewChoice::Hdr1000)));
        assert!(!checks.contains(&C::DisplayView(DisplayViewChoice::Sdr)));
        assert!(hooks.on_command(C::DisplayView(DisplayViewChoice::Sdr)));
        assert_eq!(view.display(), DisplayView::Sdr);
    }

    /// The choices belong to one app's handle: another app in the same process (the tests run many) keeps its own.
    #[test]
    fn a_choice_in_one_app_leaves_another_apps_choice_alone() {
        let (one, other) = (ViewChoices::default(), ViewChoices::default());
        let (mut hooks, _) = TimelineHooks::new(one);
        let (other_hooks, _) = TimelineHooks::new(other.clone());
        assert!(hooks.on_command(C::DisplayView(DisplayViewChoice::UnToneMapped)));
        assert!(hooks.on_command(C::ViewGamma(ViewGammaChoice::Broadcast)));
        assert_eq!((other.display(), other.gamma()), (DisplayView::Sdr, ViewGamma::Mac));
        assert!(other_hooks.menu_checks().contains(&C::DisplayView(DisplayViewChoice::Sdr)));
    }
}

#[cfg(test)]
mod media_clipboard_tests {
    use super::*;
    use crate::{ClipboardSource, MediaClipboard};
    use std::path::PathBuf;

    struct Picture;

    impl ClipboardSource for Picture {
        fn file_paths(&self) -> Vec<PathBuf> {
            Vec::new()
        }
        fn image_png(&self) -> Option<Vec<u8>> {
            Some(vec![1, 2, 3])
        }
    }

    #[test]
    fn paste_has_a_reader_only_when_the_app_gives_one() {
        let (none, _) = TimelineHooks::new(ViewChoices::default());
        assert!(none.media_clipboard().is_none(), "no reader: the shell keeps its own clip paste");
        let (hooks, _) = TimelineHooks::new(ViewChoices::default());
        let hooks = hooks.with_media_clipboard(MediaClipboard::new(Box::new(Picture)));
        let content = hooks.media_clipboard().expect("a reader");
        assert_eq!((content.file_urls.len(), content.image_data), (0, Some(vec![1, 2, 3])));
    }
}
