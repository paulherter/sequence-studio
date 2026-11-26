// Swift: SQAppShell/ProjectHost (ProjectPanelView hooks: onOpenSequence, onDrag, menu actions)
//! The Project panel as an app host: owns [`ProjectListView`] and a [`ProjectPanelModel`] that shows the session's
//! project (names, durations, kinds, folders, selection). The list's events that need only the session run here
//! (open a sequence, Insert / Overwrite, status lines); menus, drags over the timeline and the rest wait in
//! [`ProjectHost::take_deferred`] for the app root.
//! Posters: a [`PosterPump`] queues the decodes, the worker pool runs them through a [`ThumbnailSource`] (FFmpeg by
//! default); each new picture is packed into the thumbnail atlas and waits in [`AppHost::take_image_uploads`] for the
//! renderer. Find, Replace Media and Locate start the shell's flows,
//! Reveal goes to the [`FileManager`], and Rename edits in a field bar at the top of the panel.
//! shortcut: the model is a view copy with the headless import services (imports run through the app's own panel
//! model and arrive as a project change); the rename field sits in a bar over the list, not in the row's cell (the
//! list keeps its row geometry private).

use std::path::Path;
use std::sync::Arc;

use sq_app_shell::{A11yAction, ATLAS_SLOT, AppEvent, AppHost, HostCx, ImageUpload};
use sq_core_model::{BinItemRef, ThreePointMode};
use sq_core_time::{Id, SequentialIds};
use sq_draw::panel::{Node, Role};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextFieldControl};
use sq_draw_shell::{
    ProjectListCx, ProjectListEvent, ProjectListSettings, ProjectListView, ProjectPoster, SharedDefaults, ShellAction,
    ShellFlow, ShellTool, ViewMode,
};
use sq_editor_session::{
    Change, EditorSession, PlaceOptions, ProjectColumnLayout, ProjectMenuAction, ProjectPanelDeps, ProjectPanelModel,
    ThumbnailSource,
};
use sq_runtime::WorkerPool;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};

use crate::poster_pump::{PosterPump, SharedAtlas};
use crate::project_services::{FfmpegPosters, FileManager, SystemPlatform};

/// What the host could not do alone: menus, drags (they end over another panel), dialogs and the source monitor.
pub type ProjectDeferred = ProjectListEvent;

/// The media ids among `refs` (sequences and folders do not place as clips).
pub(crate) fn media_ids(refs: &[BinItemRef]) -> Vec<Id> {
    refs.iter().filter_map(|r| if let BinItemRef::Media(id) = r { Some(*id) } else { None }).collect()
}

/// Runs the events that need only the session; returns the rest, the status lines and the flows to start.
pub fn route_project(
    session: &mut EditorSession,
    events: Vec<ProjectListEvent>,
) -> (Vec<ProjectDeferred>, Vec<String>, Vec<ShellFlow>) {
    let (mut deferred, mut status, mut flows) = (Vec::new(), Vec::new(), Vec::new());
    for event in events {
        match event {
            ProjectListEvent::OpenSequence(id) => session.open_sequence_tab(id),
            ProjectListEvent::OpenVariant(id, variant) => session.open_sequence_tab_variant(id, variant),
            ProjectListEvent::Flash(line) => status.push(line),
            ProjectListEvent::Host(ProjectMenuAction::ImportMedia, _) => flows.push(ShellFlow::ImportAnything),
            ProjectListEvent::Host(ProjectMenuAction::Find, _) => flows.push(ShellFlow::Tool(ShellTool::Find)),
            // The panel menu's "Custom Ratio…" (`customSelectionPixelAspect`); "New Color Matte…" opens the dialog in the root.
            event @ ProjectListEvent::Host(ProjectMenuAction::NewColorMatte, _) => deferred.push(event),
            ProjectListEvent::Host(ProjectMenuAction::CustomPixelAspect, _) => {
                flows.push(ShellFlow::Project(ShellAction::CustomPixelAspect));
            }
            // Health line > Fix: Collect (`onCollect`) and Reconnect (File > Reconnect Media…).
            ProjectListEvent::Collect => flows.push(ShellFlow::Tool(ShellTool::CollectFiles)),
            ProjectListEvent::Reconnect => {
                if session.can_relink() {
                    flows.push(ShellFlow::Project(ShellAction::RelinkMedia));
                } else {
                    status.push("All media is online.".to_string());
                }
            }
            ProjectListEvent::Host(
                action @ (ProjectMenuAction::ReplaceMedia | ProjectMenuAction::LocateMedia),
                refs,
            ) => match media_ids(&refs).first() {
                Some(id) if action == ProjectMenuAction::ReplaceMedia => {
                    flows.push(ShellFlow::Tool(ShellTool::ReplaceMedia(*id)));
                }
                Some(id) => flows.push(ShellFlow::Tool(ShellTool::LocateOffline(*id))),
                None => {}
            },
            ProjectListEvent::Host(action @ (ProjectMenuAction::Insert | ProjectMenuAction::Overwrite), refs) => {
                let mode = if action == ProjectMenuAction::Insert {
                    ThreePointMode::Insert
                } else {
                    ThreePointMode::Overwrite
                };
                // The format question comes first, as when media is dropped on the timeline (`ShellFlow::PlaceMedia`).
                let ids = media_ids(&refs);
                if !ids.is_empty() {
                    flows
                        .push(ShellFlow::PlaceMedia { ids, options: PlaceOptions { mode, ..PlaceOptions::default() } });
                }
            }
            ProjectListEvent::SettingsChanged => {}
            other => deferred.push(other),
        }
    }
    (deferred, status, flows)
}

/// The path of the first media among `refs`, for Reveal.
fn reveal_path(session: &EditorSession, refs: &[BinItemRef]) -> Option<String> {
    let id = media_ids(refs).first().copied()?;
    session.project().media(id).map(|m| m.path.clone())
}

/// The rename field and the item it renames.
struct Renaming {
    item: BinItemRef,
    field: TextFieldControl,
}

/// Height of the rename bar in points.
const RENAME_BAR: f64 = 28.0;

/// The Project panel in a dock slot.
pub struct ProjectHost {
    view: ProjectListView,
    model: ProjectPanelModel,
    ids: SequentialIds,
    shown: Option<u64>,
    deferred: Vec<ProjectDeferred>,
    posters: PosterPump,
    platform: Box<dyn FileManager>,
    renaming: Option<Renaming>,
    frame: CGRect,
    store: Option<SharedDefaults>,
}

impl ProjectHost {
    /// A host over an empty project; the first `sync` loads the session's. Posters come from FFmpeg on two workers.
    pub fn new() -> ProjectHost {
        ProjectHost::with_services(Arc::new(FfmpegPosters), Arc::new(crate::project_services::poster_pool(2)), Box::new(SystemPlatform))
    }

    /// Like [`ProjectHost::new`] with the poster source, the pool that runs it and the file manager given (tests).
    pub fn with_services(
        source: Arc<dyn ThumbnailSource>,
        pool: Arc<WorkerPool>,
        platform: Box<dyn FileManager>,
    ) -> ProjectHost {
        let mut ids = SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let mut view = ProjectListView::new(ProjectListSettings::default());
        view.shows_title = false; // the dock's tab strip names the panel
        ProjectHost {
            view,
            model: ProjectPanelModel::new(project, ProjectPanelDeps::headless()),
            ids,
            shown: None,
            deferred: Vec::new(),
            posters: PosterPump::new(source, pool, SharedAtlas::default()),
            platform,
            renaming: None,
            frame: CGRect::default(),
            store: None,
        }
    }

    /// Keeps the panel's view settings (list or icons, search row, thumbnail size, columns) in `store`: reads them now,
    /// writes them whenever the list reports a change.
    pub fn set_settings_store(&mut self, store: SharedDefaults) {
        let settings = read_settings(&*store.borrow());
        self.view = ProjectListView::new(settings);
        self.view.shows_title = false;
        self.store = Some(store);
    }

    /// Packs the posters into `atlas`, which another panel shares (call right after construction).
    pub fn share_atlas(&mut self, atlas: SharedAtlas) {
        self.posters.set_atlas(atlas);
    }

    /// The pictures the renderer has to upload since the last call.
    pub fn take_uploads(&mut self) -> Vec<ImageUpload> {
        self.posters.take_uploads()
    }

    /// Whether the rename field is open.
    pub fn is_renaming(&self) -> bool {
        self.renaming.is_some()
    }

    /// Closes the rename field and renames the item to what was typed: Enter, a press outside the field, a menu chord and
    /// the window losing the keyboard all end the edit this way (Escape alone leaves the name). Nothing happens when the
    /// field is closed.
    pub(crate) fn end_rename(&mut self, cx: &mut HostCx) {
        let Some(mut r) = self.renaming.take() else { return };
        if let Some(name) = r.field.commit() {
            let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
            self.view.rename_to(&mut lcx, r.item, &name);
        }
    }

    /// Opens the rename field on `item`, filled with its name.
    fn begin_rename(&mut self, item: BinItemRef) {
        let mut field = TextFieldControl::new(&self.model.display_name(item));
        field.mouse_down(None, 1);
        self.renaming = Some(Renaming { item, field });
    }

    /// Requests the posters of every media item, starts the decodes that may run and takes in what finished.
    fn pump_posters(&mut self) {
        let height = (self.view.settings().thumb_size * 2.0).round().max(64.0) as i64;
        self.posters.touch(media_ids(self.view.selection()));
        self.posters.pump(self.model.project().media.iter(), height);
        for id in self.posters.take_evicted() {
            self.view.posters.remove(&id);
        }
        // The view shows what the atlas holds now for every item: a poster the view lost (a project that was closed and
        // opened again, a cell that moved) comes back without a new decode.
        let ids: Vec<Id> = self.model.project().media.iter().map(|m| m.id).collect();
        self.view.posters.retain(|id, _| ids.contains(id));
        for id in ids {
            let Some(p) = self.posters.placed(id) else { continue };
            let [u0, v0, u1, v1] = p.uv();
            self.view.posters.insert(id, ProjectPoster { slot: ATLAS_SLOT, u0, v0, u1, v1, pixel_size: p.size() });
        }
    }

    /// Runs `wake` when a poster decode finishes, so the window redraws without waiting for input.
    pub fn set_wake(&mut self, wake: std::sync::Arc<dyn Fn() + Send + Sync>) {
        self.posters.set_wake(wake);
    }

    /// The list (selection, settings).
    pub fn view(&mut self) -> &mut ProjectListView {
        &mut self.view
    }

    /// Edit > Delete with the Project focused: removes the selected items (`ProjectListView::delete_selection`).
    pub fn delete_selection(&mut self, cx: &mut HostCx) {
        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
        self.view.delete_selection(&mut lcx);
        self.route(cx);
    }

    /// File > Bin / Cmd+B: a new folder in the selected folder or at the top (`ProjectListView.newFolder`).
    pub fn new_folder(&mut self, cx: &mut HostCx) {
        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
        self.view.new_folder(&mut lcx);
        self.route(cx);
    }

    /// Set / Clear Poster Frame (Swift `PosterFrameCommand.run`): the poster of the selected clip is the frame the Source
    /// monitor shows (`source`), the one under the pointer in the icon view wins; Clear goes back to the first frame for
    /// every selected clip. The status line when nothing changed for a reason the user should hear.
    pub fn poster_frame(
        &mut self,
        cx: &mut HostCx,
        clear: bool,
        source: Option<(Id, sq_core_time::Time)>,
    ) -> Option<String> {
        let ids: Vec<Id> = media_ids(self.view.selection());
        if ids.is_empty() {
            return Some("Select a clip first.".to_string());
        }
        let items = |id: Id| [BinItemRef::Media(id)];
        if clear {
            let all: Vec<BinItemRef> = ids.iter().copied().map(BinItemRef::Media).collect();
            self.model.set_poster(cx.session, None, &all);
            return None;
        }
        let hovered = self.view.hovered_frame().filter(|(m, _)| ids.contains(m));
        if let Some((m, t)) = hovered.or(source.filter(|(m, _)| ids.contains(m))) {
            self.model.set_poster(cx.session, Some(t), &items(m));
            return None;
        }
        Some(format!(
            "Hover a clip in icon view (or open it in the Source monitor) and press {}+P.",
            sq_os::Platform::current().command_key_name()
        ))
    }

    /// View > Project Panel and View > Hover Scrub: runs the command; the status line to show, if any.
    pub fn run_view_command(&mut self, cx: &mut HostCx, c: sq_uikit::editor_command::EditorCommand) -> Option<String> {
        let line = self.view.run_view_command(&mut self.model, c);
        self.route(cx);
        line
    }

    /// Moves the item count, New Folder and "..." into the dock's Project tab strip (Swift: `ProjectListView.dock(in:)`);
    /// `None` keeps the header row.
    pub fn set_strip(&mut self, strip: Option<sq_draw_shell::StripTools>) {
        self.view.set_strip(strip);
    }

    /// The width the dock keeps free at the end of the Project strip for those tools.
    pub fn strip_tools_width(&self, m: &sq_draw::TextMeasure) -> f64 {
        self.view.strip_tools_width(m, &self.view.item_count_text(&self.model))
    }

    /// The model the list shows.
    pub fn model(&self) -> &ProjectPanelModel {
        &self.model
    }

    /// Checks the files of all media again (which are missing now).
    pub fn refresh_offline(&mut self) {
        self.model.refresh_offline();
    }

    /// Reveal in Project: clears the search, opens the folders above `media` and selects it. False when the project has
    /// no such media.
    pub fn reveal(&mut self, cx: &mut HostCx, media: Id) -> bool {
        if cx.session.project().media(media).is_none() {
            return false;
        }
        let ProjectHost { view, model, ids, .. } = self;
        view.reveal_media(&mut list_cx(model, ids, cx), media);
        true
    }

    /// Edit > Find: clears the search, opens the folders above `found` and selects them.
    pub fn reveal_found(&mut self, cx: &mut HostCx, found: Vec<BinItemRef>) {
        let ProjectHost { view, model, ids, .. } = self;
        view.reveal_found(&mut list_cx(model, ids, cx), found);
    }

    /// What waits for the app root, in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<ProjectDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// Queues `event` as if the list had raised it (tests of the root).
    #[cfg(test)]
    pub(crate) fn defer(&mut self, event: ProjectDeferred) {
        self.deferred.push(event);
    }

    /// Performs the rows a closed menu queued.
    pub fn pump(&mut self, cx: &mut HostCx) {
        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
        self.view.run_queued(&mut lcx);
        self.route(cx);
    }

    fn route(&mut self, cx: &mut HostCx) {
        let events = self.view.take_events();
        self.route_events(events, cx);
    }

    fn route_events(&mut self, events: Vec<ProjectListEvent>, cx: &mut HostCx) {
        if events.is_empty() {
            return;
        }
        if let Some(store) = &self.store
            && events.iter().any(|e| matches!(e, ProjectListEvent::SettingsChanged))
        {
            write_settings(&mut *store.borrow_mut(), self.view.settings());
        }
        let (deferred, status, flows) = route_project(cx.session, events);
        let mut status = status;
        for event in deferred {
            match event {
                ProjectListEvent::Rename(item) => self.begin_rename(item),
                ProjectListEvent::Host(ProjectMenuAction::Reveal, refs) => match reveal_path(cx.session, &refs) {
                    Some(path) if Path::new(&path).exists() => {
                        if let Err(e) = self.platform.reveal(Path::new(&path)) {
                            status.push(format!("Could not show the file: {e}"));
                        }
                    }
                    Some(_) => status.push("The file is offline.".to_string()),
                    None => {}
                },
                other => self.deferred.push(other),
            }
        }
        flows.into_iter().for_each(|f| cx.emit(AppEvent::Flow(f)));
        status.into_iter().for_each(|line| cx.emit(AppEvent::Status(line)));
    }
}

const VIEW_MODE_KEY: &str = "ProjectPanel.viewMode";
const SEARCH_KEY: &str = "sq.project.searchVisible";
const THUMB_KEY: &str = "sq.project.thumbSize";

/// The saved view settings; missing or unreadable values keep the defaults. Hover Scrub is an app setting, not stored here.
fn read_settings(d: &dyn UiDefaults) -> ProjectListSettings {
    let mut s = ProjectListSettings::default();
    if let Some(mode) = d.string(VIEW_MODE_KEY).and_then(|m| ViewMode::from_raw(&m)) {
        s.view_mode = mode;
    }
    if let Some(n) = d.integer(SEARCH_KEY) {
        s.search_visible = n != 0;
    }
    if let Some(n) = d.integer(THUMB_KEY) {
        s.thumb_size = n as f64;
    }
    if let Some(c) = d.data(ProjectColumnLayout::DEFAULTS_KEY).and_then(|b| ProjectColumnLayout::from_json(&b)) {
        s.columns = c;
    }
    s
}

fn write_settings(d: &mut dyn UiDefaults, s: &ProjectListSettings) {
    d.set_string(VIEW_MODE_KEY, s.view_mode.raw_value());
    d.set_integer(SEARCH_KEY, i64::from(s.search_visible));
    d.set_integer(THUMB_KEY, s.thumb_size.round() as i64);
    if let Some(bytes) = s.columns.to_json() {
        d.set_data(ProjectColumnLayout::DEFAULTS_KEY, &bytes);
    }
}

/// The list's context for one call: the session, the UI context and the measure of `cx`.
fn list_cx<'a, 'm>(
    model: &'a mut ProjectPanelModel,
    ids: &'a mut SequentialIds,
    cx: &'a mut HostCx<'m>,
) -> ProjectListCx<'a, 'm> {
    let (measure, now) = (cx.measure(), cx.ui.now);
    ProjectListCx {
        model,
        session: cx.session,
        measure,
        ui: cx.ui,
        now,
        ids,
        can_collect: false,
        modifiers: InputModifiers::NONE,
    }
}

impl Default for ProjectHost {
    fn default() -> ProjectHost {
        ProjectHost::new()
    }
}

impl AppHost for ProjectHost {
    fn sync(&mut self, session: &EditorSession) {
        let version = session.version(Change::PROJECT);
        if self.shown != Some(version) {
            self.shown = Some(version);
            self.model.set_project(session.project().clone());
        }
        self.pump_posters();
    }

    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.frame = frame;
        let bar = if self.renaming.is_some() { RENAME_BAR } else { 0.0 };
        self.view.frame = CGRect::new(frame.min_x(), frame.min_y() + bar, frame.width, (frame.height - bar).max(0.0));
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
        self.view.draw(c, t, &mut lcx);
        if let Some(r) = &self.renaming {
            let bar = CGRect::new(self.frame.min_x(), self.frame.min_y(), self.frame.width, RENAME_BAR);
            c.fill(bar, t.row_separator());
            r.field.draw(
                c,
                CGRect::new(bar.min_x() + 6.0, bar.min_y() + 3.0, bar.width - 12.0, bar.height - 6.0),
                t,
                true,
                cx.ui,
            );
        }
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        // A press anywhere but on the field commits it and then acts like a press without a field (a row, the footer).
        if self.renaming.is_some()
            && let InputEvent::MouseDown { x, y, .. } = *e
        {
            let bar = CGRect::new(self.frame.min_x(), self.frame.min_y(), self.frame.width, RENAME_BAR);
            if !bar.contains(CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale))) {
                self.end_rename(cx);
            }
        }
        if let Some(r) = &mut self.renaming {
            match *e {
                InputEvent::KeyDown { key: InputKey::Escape, .. } => self.renaming = None,
                InputEvent::KeyDown { key, modifiers } => {
                    if let Some(name) = r.field.key(key, modifiers, cx.ui) {
                        let item = r.item;
                        self.renaming = None;
                        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
                        self.view.rename_to(&mut lcx, item, &name);
                    }
                }
                _ => {}
            }
            return true;
        }
        let scale = cx.scale;
        let mut lcx = list_cx(&mut self.model, &mut self.ids, cx);
        let taken = self.view.handle(&mut lcx, e, scale);
        // A press that queued a row itself (the footer's Locate…) has no closing menu to pump it: run it now.
        self.view.run_queued(&mut lcx);
        self.route(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        let mut list = Node::new(Role::List);
        list.set_label("Project");
        a.push("project", Role::List, "list", list);
        let selected = self.view.selection();
        for (i, row) in self.view.rows(&self.model).iter().enumerate() {
            let mut n = Node::new(Role::ListItem);
            n.set_label(self.model.display_name(row.item_ref));
            n.set_selected(selected.contains(&row.item_ref));
            n.add_action(accesskit::Action::Click);
            a.push("project", Role::ListItem, &i.to_string(), n);
        }
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let rows = self.view.rows(&self.model);
        let Some(row) = (0..rows.len()).find(|i| A11y::node_id("project", Role::ListItem, &i.to_string()) == id) else {
            return false;
        };
        if action == A11yAction::Click {
            let item = rows[row].item_ref;
            self.view.select(vec![item]);
            self.route(cx);
        }
        true
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        if changes.intersects(Change::PROJECT) {
            self.model.set_project(cx.session.project().clone());
            self.shown = Some(cx.session.version(Change::PROJECT));
        }
    }
}

#[cfg(test)]
mod tests;
