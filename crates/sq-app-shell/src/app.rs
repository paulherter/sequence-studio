// Swift: AppController.swift (Windows/SQWinApp; the portable `frame` / `handle` path, the Mac `SharedUIController` is
// its near copy)
//! The app root: owns the session, the platform services, the panel hosts and the `UiCx`, and is reached only through
//! `UiRoot<App>` (one borrow per input event, frame, inbox drain or task step; tasks are polled outside that borrow).
//! One loop turn, as the binary and [`crate::Headless`] run it: [`App::drain`], `UiExecutor::poll_frame`, then
//! [`App::frame`] when [`App::needs_redraw`]; input goes to [`App::handle`] between turns.

use crate::host::{A11yAction, AppEvent, AppHost, HostCx};
use crate::{
    AppMagicMasks, AppMonitorBackend, AppPointer, AppPointerFacts, AppPointerShape, AppScreenSampler, PanelFileChooser,
    ShellFilePicker,
};
use sq_core_time::Timestamp;
use sq_draw::{A11y, Canvas, DrawList, DrawTheme, GlyphAtlas, InputEvent, UiCx};
use sq_draw_shell::{ShellFlow, ShellHost, ShellParts, ShellRoot};
use sq_editor_session::{
    Change, EditorSession, ProjectPanelDeps, ProjectPanelModel, ProjectPanelRoot, RecentProjects, SessionRoot,
};
use sq_runtime::channel::Sender;
use sq_runtime::{Clock, Inbox};
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::CGRect;
use std::sync::Arc;

/// Rounds of hook dispatch after one call before the app gives up (a host whose `on_change` keeps notifying).
const DISPATCH_ROUNDS: usize = 16;

/// The platform's implementations of the seams (`app_platform`, `shell_file_picker`), owned by the app and lent to
/// hosts through [`HostCx::services`]. `None`: the platform has none (Windows has no Magic segmenter yet).
pub struct AppServices {
    pub files: Box<dyn ShellFilePicker>,
    pub panel_files: Box<dyn PanelFileChooser>,
    pub monitor: Option<Box<dyn AppMonitorBackend>>,
    pub sampler: Option<Box<dyn AppScreenSampler>>,
    pub magic: Option<Box<dyn AppMagicMasks>>,
}

/// What [`App::new`] needs besides the session.
pub struct AppDeps {
    pub services: AppServices,
    /// The steady clock of tooltips and timers (the executor's clock; tests pass a `FakeClock`).
    pub clock: Arc<dyn Clock>,
    /// The glyph page; `None` draws no text (headless runs without the Inter font).
    pub atlas: Option<GlyphAtlas>,
    pub theme: DrawTheme,
    /// Runs on the sending thread after every inbox message (wakes the event loop).
    pub wake: Box<dyn Fn() + Send + Sync>,
    /// The probe, worker pool and calendar of imports into the project.
    pub import: ProjectPanelDeps,
}

/// A message from a background service to the UI thread, applied by [`App::drain`] at frame start. Owners of the
/// services add their typed kinds here (proxy, transcribe, analysis, library, export queue, media disk).
pub enum AppMessage {
    /// A background job finished: the session notifies `Change` (`MEDIA` after a prepare).
    Notify(Change),
    /// `DispatchQueue.main.async { .. }`: runs on the UI thread with the app.
    Post(Box<dyn FnOnce(&mut App) + Send>),
}

/// A host added with [`App::add_host`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HostId(usize);

struct Slot {
    host: Box<dyn AppHost>,
    /// `None`: the whole window.
    frame: Option<CGRect>,
}

/// The app root (Swift `AppController`).
pub struct App {
    profile: Vec<(&'static str, &'static str, std::time::Duration)>,
    session: EditorSession,
    /// The project's media as the Project panel lists it; imports run through it.
    panel: ProjectPanelModel,
    services: AppServices,
    ui: UiCx,
    theme: DrawTheme,
    atlas: Option<GlyphAtlas>,
    clock: Arc<dyn Clock>,
    inbox: Inbox<AppMessage>,
    hosts: Vec<Slot>,
    status: String,
    events: Vec<AppEvent>,
    /// Input or a message arrived since the last frame.
    dirty: bool,
    /// The session versions the last frame showed (`None`: no frame yet).
    drawn_versions: Option<[u64; Change::COUNT]>,
    /// Menu commands that wait for the loop to run them as tasks.
    flows: Vec<ShellFlow>,
    quit: bool,
    /// The last full screen request the window has not applied yet.
    full_screen: Option<bool>,
    /// The last Minimize / Maximize request the window has not applied yet.
    window_op: Option<sq_draw_shell::WindowOp>,
    exports_finished: Option<(Vec<std::path::PathBuf>, Vec<String>)>,
    /// Device pixels per point of the display; `theme.scale` is this times `ui_scale`.
    device_scale: f32,
    /// The interface size of Preferences (1.0 = 100 %).
    ui_scale: f32,
    /// Stands in for the shell when no host owns one (a flow cannot start then, so it is never drawn).
    spare_shell: Option<Box<ShellHost>>,
    /// Where the pointer was in the last mouse event (window pixels); `None` until one came.
    pointer: Option<(f32, f32)>,
    /// The primary button is held: a drag owns the pointer, nothing hit-tests under it again.
    button_down: bool,
    /// `sq_draw::scroll::content_epoch` when the hosts last saw the pointer.
    content_epoch: u64,
    /// Where the running trackpad gesture began: its later events go there, not under the pointer (bug 39).
    scroll_target: sq_draw::scroll::ScrollTarget,
}

impl App {
    /// The app around `session` (Swift `init(project:fileURL:audio:)` after the session exists).
    pub fn new(session: EditorSession, deps: AppDeps) -> App {
        App {
            profile: Vec::new(),
            panel: ProjectPanelModel::new(session.project().clone(), deps.import),
            session,
            services: deps.services,
            ui: UiCx::new(),
            device_scale: deps.theme.scale,
            ui_scale: 1.0,
            theme: deps.theme,
            atlas: deps.atlas,
            clock: deps.clock,
            inbox: Inbox::new(deps.wake),
            hosts: Vec::new(),
            status: String::new(),
            events: Vec::new(),
            dirty: true,
            drawn_versions: None,
            flows: Vec::new(),
            quit: false,
            full_screen: None,
            window_op: None,
            exports_finished: None,
            spare_shell: None,
            pointer: None,
            button_down: false,
            content_epoch: sq_draw::scroll::content_epoch(),
            scroll_target: Default::default(),
        }
    }

    /// The window is up: hosts act on the first session (the shell shows the start window when it is untitled and empty).
    pub fn launch(&mut self) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.launch(&mut cx);
        }
        self.dirty = true;
        self.dispatch();
    }

    /// Lets hosts pick up what tasks changed behind their back, then dispatches (call after polling the executor).
    pub fn settle(&mut self) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.pump(&mut cx);
        }
        // A task (a folder chosen for Settings > Media) changed the shell while no input event follows: draw it.
        let mut asked = false;
        for slot in &mut self.hosts {
            asked |= slot.host.shell_mut().is_some_and(sq_draw_shell::ShellHost::take_frame_request);
        }
        self.dirty |= asked;
        self.dispatch();
    }

    /// The shell's menus as of the last frame (the macOS system menu bar shows them).
    pub fn menus(&mut self) -> &[sq_draw_shell::ShellMenu] {
        let parts = self.shell_parts();
        parts.shell.menu_bar.menus()
    }

    /// How many times the shell rebuilt its menus: the macOS system menu bar is pushed only when this changes.
    pub fn menu_builds(&mut self) -> u64 {
        self.shell_parts().shell.menu_builds()
    }

    /// The rows of the open menu, outermost level (empty when none is open).
    pub fn open_menu_items(&mut self) -> Vec<sq_uikit::sqmenu_model::SQMenuItem> {
        self.hosts.iter_mut().rev().map(|s| s.host.open_menu_items()).find(|i| !i.is_empty()).unwrap_or_default()
    }

    /// Puts the app in the named parity-shot state (see [`AppHost::shot_pose`]).
    pub fn shot_pose(&mut self, name: &str) -> bool {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        self.hosts.iter_mut().any(|s| s.host.shot_pose(name, &mut cx))
    }

    /// A host's eyedropper waits for the last presented frame: the window loop renders it and calls `set_window_frame`.
    pub fn wants_window_frame(&self) -> bool {
        self.hosts.iter().any(|s| s.host.wants_window_frame())
    }

    /// The last presented frame (window pixels) for the eyedropper.
    pub fn set_window_frame(&mut self, frame: sq_draw::RgbaImage) {
        if let Some(slot) = self.hosts.iter_mut().find(|s| s.host.wants_window_frame()) {
            slot.host.set_window_frame(frame);
        }
    }

    /// Opens the menu-bar menu titled `title` (parity shots).
    pub fn open_bar_menu(&mut self, title: &str) -> bool {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        self.hosts.iter_mut().any(|s| s.host.open_bar_menu(title, &mut cx))
    }

    /// The overall progress of the running exports (`None` = nothing exports): the Dock icon shows it.
    pub fn export_progress(&mut self) -> Option<f64> {
        self.shell_parts().shell.export.progress
    }

    /// The menu commands to run as tasks now (`ShellHost::run_flow` with this app as the root).
    pub fn take_flows(&mut self) -> Vec<ShellFlow> {
        std::mem::take(&mut self.flows)
    }

    /// Files dropped on the window: a project among them is opened, else they are sorted by kind and imported like
    /// File > Import (media into the project).
    pub fn drop_files(&mut self, urls: Vec<std::path::PathBuf>) {
        if let Some(flow) = ShellFlow::for_drop(urls) {
            self.emit_flow(flow);
        }
    }

    /// The window's own close request (the title bar's close button, Alt+F4 on Windows, the window manager's close on
    /// Linux): the same Save Changes question as File > Quit (Swift `windowShouldClose`). Quitting is up to the loop, which
    /// ends once [`Self::quit_requested`] is true; Cancel keeps the window.
    pub fn close_requested(&mut self) {
        self.emit_flow(ShellFlow::Quit);
    }

    /// Queues a menu flow to run as a task (what the hosts do through [`AppEvent::Flow`]).
    pub fn emit_flow(&mut self, flow: ShellFlow) {
        self.flows.push(flow);
        self.dirty = true;
    }

    /// The files and failure lines of exports that just ended, once (for the system notification).
    pub fn take_exports_finished(&mut self) -> Option<(Vec<std::path::PathBuf>, Vec<String>)> {
        self.exports_finished.take()
    }

    /// The pending full screen request for the window (`true` = enter), once.
    pub fn take_full_screen(&mut self) -> Option<bool> {
        self.full_screen.take()
    }

    /// The pending Window > Minimize / Maximize request for the window, once.
    pub fn take_window_op(&mut self) -> Option<sq_draw_shell::WindowOp> {
        self.window_op.take()
    }

    /// Whether the user confirmed Quit.
    pub fn quit_requested(&self) -> bool {
        self.quit
    }

    pub fn session(&self) -> &EditorSession {
        &self.session
    }

    /// The project's media list and import state.
    pub fn panel(&self) -> &ProjectPanelModel {
        &self.panel
    }

    pub fn session_mut(&mut self) -> &mut EditorSession {
        &mut self.session
    }

    pub fn services_mut(&mut self) -> &mut AppServices {
        &mut self.services
    }

    pub fn ui(&self) -> &UiCx {
        &self.ui
    }

    pub fn ui_mut(&mut self) -> &mut UiCx {
        &mut self.ui
    }

    pub fn theme(&self) -> &DrawTheme {
        &self.theme
    }

    /// A new appearance or display scale (`theme.scale` is the display's); the interface size of Preferences comes on top.
    pub fn set_theme(&mut self, theme: DrawTheme) {
        self.device_scale = theme.scale;
        self.theme = DrawTheme { scale: self.device_scale * self.ui_scale, ..theme };
        self.atlas.iter().for_each(|a| a.set_point_scale(self.theme.scale));
        for slot in &mut self.hosts {
            slot.host.theme_changed(&self.theme);
        }
        self.dirty = true;
    }

    /// The display scale changed (window moved to another screen): the interface size of Preferences stays on top.
    pub fn set_display_scale(&mut self, scale: f32) {
        self.set_theme(DrawTheme { scale, ..self.theme });
    }

    /// The interface size of Preferences (1.0 = 100 %); `theme.scale` follows.
    pub fn set_ui_scale(&mut self, ui_scale: f32) {
        self.ui_scale = ui_scale;
        self.set_theme(DrawTheme { scale: self.device_scale, ..self.theme });
    }

    /// The next loop turn draws (window resized or exposed).
    pub fn set_needs_redraw(&mut self) {
        self.dirty = true;
    }

    /// The glyph page the renderer uploads from.
    pub fn atlas(&self) -> Option<&GlyphAtlas> {
        self.atlas.as_ref()
    }

    /// The executor's clock (the binary builds its `UiExecutor` on the same one).
    pub fn clock(&self) -> Arc<dyn Clock> {
        Arc::clone(&self.clock)
    }

    /// A sender for background services; every send wakes the loop.
    pub fn sender(&self) -> Sender<AppMessage> {
        self.inbox.sender()
    }

    /// The status line: the session's last error wins over the app's own status.
    /// The status bar shows no audio-device text (decision: the engine's device is not listed in the status line).
    pub fn status_text(&self) -> &str {
        self.session.last_error().unwrap_or(&self.status)
    }

    /// Adds a host on top: drawn after and routed before every host added earlier.
    /// Routing is top-most-first, which gives the same order as the hand-written Swift chain for the hosts the app adds.
    pub fn add_host(&mut self, host: Box<dyn AppHost>) -> HostId {
        self.hosts.push(Slot { host, frame: None });
        self.dirty = true;
        HostId(self.hosts.len() - 1)
    }

    /// The pictures the hosts made since the last call (poster frames, scopes), for the renderer's image slots.
    pub fn take_image_uploads(&mut self) -> Vec<crate::ImageUpload> {
        self.hosts.iter_mut().flat_map(|slot| slot.host.take_image_uploads()).collect()
    }

    /// Where `id` lays out (points); `None` = the whole window. Unknown ids are ignored.
    pub fn set_host_frame(&mut self, id: HostId, frame: Option<CGRect>) {
        if let Some(slot) = self.hosts.get_mut(id.0) {
            slot.frame = frame;
            self.dirty = true;
        }
    }

    fn now(&self) -> f64 {
        self.clock.now().as_secs_f64()
    }

    /// Frame start: applies every inbox message in send order, reads the Program engine's position report, then
    /// dispatches what they caused. Returns the number of messages.
    pub fn drain(&mut self) -> usize {
        self.ui.now = self.now();
        let messages = self.inbox.drain();
        let count = messages.len();
        for m in messages {
            match m {
                AppMessage::Notify(c) => self.session.notify(c),
                AppMessage::Post(f) => f(self),
            }
        }
        self.session.poll_engine_position();
        if count > 0 {
            self.dirty = true;
        }
        self.dispatch();
        count
    }

    /// [`handle`](Self::handle) for a scroll, pinch or double tap: the gesture rides along on the UI context while the
    /// hosts see the event, as the real window and the offscreen harness both deliver it.
    pub fn handle_with_gesture(&mut self, e: &InputEvent, gesture: sq_draw::scroll::ScrollGesture) -> bool {
        self.ui.gesture = Some(gesture);
        // A trackpad gesture belongs to the place where it began: the hosts see its events there, so the list that was
        // stretched gets the end even when the pointer is over another list by then.
        let routed = match *e {
            InputEvent::Scroll { x, y, dx, dy, modifiers } => {
                let now = self.now();
                let (rx, ry) = self.scroll_target.route(&gesture, (x, y), now);
                Some(((x, y), InputEvent::Scroll { x: rx, y: ry, dx, dy, modifiers }))
            }
            _ => None,
        };
        let taken = match &routed {
            Some((real, moved)) => {
                let taken = self.handle(moved);
                self.pointer = Some(*real);
                // The hosts saw the scroll at the held place, so their hover now sits there. The pointer is
                // elsewhere (it moved on while the list glides): tell them where it really is, so the row under it
                // lights as it does after any move. Not during a drag.
                if let InputEvent::Scroll { x, y, .. } = moved
                    && (*x, *y) != *real
                    && !self.button_down
                {
                    self.handle(&InputEvent::MouseMoved { x: real.0, y: real.1 });
                }
                taken
            }
            None => self.handle(e),
        };
        self.ui.gesture = None;
        taken
    }

    /// Routes one input event to the hosts, top-most first, until one takes it; true when one did.
    pub fn handle(&mut self, e: &InputEvent) -> bool {
        // Hosts put their cursor and tip into `ui.hover` while they see the event (the top-most offer wins).
        let now = self.now();
        self.ui.now = now;
        self.note_pointer(e);
        self.ui.hover.begin_event(e);
        if matches!(e, InputEvent::MouseDown { .. }) {
            self.ui.press(); // a press lands a settling drop chip at once
        }
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        let taken = self.hosts.iter_mut().rev().any(|slot| slot.host.handle(e, &mut cx));
        self.ui.hover.end_event(e, now);
        self.dirty = true;
        self.dispatch();
        taken
    }

    /// Remembers where the pointer is and whether a button holds it.
    fn note_pointer(&mut self, e: &InputEvent) {
        match *e {
            InputEvent::MouseDown { x, y, .. } => (self.pointer, self.button_down) = (Some((x, y)), true),
            InputEvent::MouseUp { x, y } => (self.pointer, self.button_down) = (Some((x, y)), false),
            InputEvent::MouseMoved { x, y }
            | InputEvent::MouseDragged { x, y, .. }
            | InputEvent::Scroll { x, y, .. } => {
                self.pointer = Some((x, y));
            }
            InputEvent::KeyDown { .. } => {}
        }
    }

    /// Content slid under a resting pointer (a list scrolled by wheel, trackpad, key or code, see
    /// `sq_draw::scroll::content_epoch`): the hosts get a move at the pointer's place, so hover and cursor follow what is
    /// under it now and not the row that was there, with no pointer move. The one place for every scrolling panel; when
    /// nothing moved this does nothing, so an idle window still asks for no frames. A held button is a drag: not touched.
    fn follow_content_under_pointer(&mut self) {
        if self.content_epoch == sq_draw::scroll::content_epoch() {
            return;
        }
        if let (Some((x, y)), false) = (self.pointer, self.button_down) {
            self.handle(&InputEvent::MouseMoved { x, y });
        }
        // After the move: the offsets it read are the ones the hosts have now.
        self.content_epoch = sq_draw::scroll::content_epoch();
    }

    /// A key came up: the hosts end what the key held (J/K/L).
    pub fn key_up(&mut self, key: sq_draw::InputKey) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.key_up(key, &mut cx);
        }
        self.dirty = true;
        self.dispatch();
    }

    /// Alt was pressed and released alone: the hosts may open the menu bar by keyboard.
    pub fn alt_tapped(&mut self) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.alt_tapped(&mut cx);
        }
        self.dirty = true;
        self.dispatch();
    }

    /// The window lost the keyboard: held keys are released.
    pub fn focus_lost(&mut self) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.focus_lost(&mut cx);
        }
        self.dirty = true;
        self.dispatch();
    }

    /// The window got the keyboard back: hosts re-check what changed on disk while another app had the focus.
    pub fn focus_gained(&mut self) {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        for slot in &mut self.hosts {
            slot.host.focus_gained(&mut cx);
        }
        self.dirty = true;
        self.dispatch();
    }

    /// Whether the next loop turn should draw: input or a message arrived, a session version moved, an animation or a
    /// tooltip waits, or playback runs. Otherwise the loop sleeps until the executor's next deadline.
    pub fn needs_redraw(&mut self) -> bool {
        self.ui.now = self.now();
        self.dirty
            || self.drawn_versions.as_ref() != Some(self.session.versions())
            || self.ui.needs_frame()
            || sq_draw::motion::needs_frame()
            || self.hosts.iter().any(|s| s.host.wants_frames())
            || self.session.is_playing()
    }

    /// What each host cost in the last [`App::frame`]: (host type, phase, time). For the stress tests and `SQ_PERF`.
    pub fn frame_profile(&self) -> &[(&'static str, &'static str, std::time::Duration)] {
        &self.profile
    }

    /// Lays out and draws the window at `width x height` device pixels: every host syncs from the session, lays out
    /// and draws in the order added, then the tooltip goes on top.
    pub fn frame(&mut self, width: i64, height: i64) -> DrawList {
        let now = self.now();
        self.ui.now = now;
        sq_draw::motion::begin_frame(now);
        self.ui.take_animation();
        self.ui.requests.caret = None;
        let scale = self.theme.scale;
        let window = CGRect::new(0.0, 0.0, width as f64 / scale as f64, height as f64 / scale as f64);
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale,
        };
        self.profile.clear();
        for slot in &mut self.hosts {
            let t = std::time::Instant::now();
            slot.host.sync(cx.session);
            slot.host.layout(slot.frame.unwrap_or(window), &mut cx);
            self.profile.push((std::any::type_name_of_val(&*slot.host), "sync+layout", t.elapsed()));
            self.profile.extend(crate::take_phases().into_iter().map(|(name, took)| ("phase", name, took)));
        }
        let mut c = Canvas::with_size(width as f32, height as f32, self.atlas.as_ref(), scale);
        // Floating panels lie right of the window on the same canvas; the window host shows each rectangle in its own window.
        if let Some(extent) = self.hosts.iter_mut().find_map(|s| s.host.dock_mut()).map(|d| d.floating.canvas_extent())
        {
            c.list.extend_canvas(extent.width as f32 * scale, extent.height as f32 * scale);
        }
        for slot in &mut self.hosts {
            let t = std::time::Instant::now();
            slot.host.draw(&mut c, &self.theme, &mut cx);
            self.profile.push((std::any::type_name_of_val(&*slot.host), "draw", t.elapsed()));
        }
        self.ui.requests.draw_composition(&mut c, &self.theme);
        self.ui.draw_drag(&mut c, &self.theme);
        self.ui.hover.draw_tooltip(&mut c, &self.theme, now);
        self.dirty = false;
        self.drawn_versions = Some(*self.session.versions());
        // Events a host raised while laying out or drawing (a menu it opened) are answered now; they may ask for a redraw.
        let list = c.list;
        self.dispatch();
        // After the frame, so this frame's offsets are the ones the move hit-tests; the next frame draws the new hover.
        self.follow_content_under_pointer();
        list
    }

    /// The dock layout of the host that owns it (the window host reads the floating windows from it).
    pub fn dock_mut(&mut self) -> Option<&mut sq_draw_shell::ShellDock> {
        self.hosts.iter_mut().find_map(|s| s.host.dock_mut())
    }

    /// The pointer shape this frame (`AppPointer` rules).
    /// The panels' request carries the divider, keystone and tool cursors: the hosts put them into `ui.hover` while they see the event.
    pub fn pointer_shape(&self) -> AppPointerShape {
        AppPointer::shape(&AppPointerFacts { panel: self.ui.hover.cursor, ..AppPointerFacts::default() })
    }

    /// The accessibility nodes of every host, in draw order (empty while assistive tech is off).
    pub fn accessibility(&self, active: bool) -> A11y {
        let mut a = A11y::new(active);
        if active {
            for slot in &self.hosts {
                slot.host.a11y(&mut a);
            }
        }
        a
    }

    /// Routes an assistive-tech action on node `id` to the host that pushed it; true when one acted. The caller redraws.
    pub fn accessibility_action(&mut self, id: accesskit::NodeId, action: A11yAction) -> bool {
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: self.atlas.as_ref(),
            scale: self.theme.scale,
        };
        let taken = self.hosts.iter_mut().rev().any(|slot| slot.host.a11y_action(id, action.clone(), &mut cx));
        self.dirty = true;
        self.dispatch();
        taken
    }

    /// Runs what the Swift hosts assigned to the hooks: host events here, the session's `onChange` chain and its
    /// `on*` hooks through every host, repeated until nothing new is pending (hooks may notify again).
    fn dispatch(&mut self) {
        for _ in 0..DISPATCH_ROUNDS {
            let events = std::mem::take(&mut self.events);
            let changes = self.session.take_changes();
            let session_events = self.session.take_events();
            if events.is_empty() && changes.is_empty() && session_events.is_empty() {
                return;
            }
            self.dirty = true;
            if changes.intersects(Change::PROJECT) && self.panel.project() != self.session.project() {
                self.panel.set_project(self.session.project().clone());
            }
            // A project that opens, closes or is created ends the status line of the one before (a failed open stays
            // no longer); a line emitted in the same round replaces it below.
            if session_events.iter().any(|e| matches!(e, sq_editor_session::SessionEvent::ProjectReplaced)) {
                self.status.clear();
            }
            for event in events {
                match event {
                    AppEvent::Status(line) => self.status = line,
                    AppEvent::Flow(flow) => self.flows.push(flow),
                    AppEvent::Quit => self.quit = true,
                    AppEvent::FullScreen(on) => self.full_screen = Some(on),
                    AppEvent::Window(op) => self.window_op = Some(op),
                    AppEvent::ExportsFinished { done, failed } => self.exports_finished = Some((done, failed)),
                    AppEvent::Appearance { settings, ui_scale } => {
                        self.ui_scale = ui_scale as f32;
                        self.set_theme(DrawTheme::new(&settings, self.device_scale));
                    }
                }
            }
            let mut cx = HostCx {
                session: &mut self.session,
                ui: &mut self.ui,
                services: &mut self.services,
                events: &mut self.events,
                atlas: self.atlas.as_ref(),
                scale: self.theme.scale,
            };
            for slot in &mut self.hosts {
                if !changes.is_empty() {
                    slot.host.on_change(changes, &mut cx);
                }
                for e in &session_events {
                    slot.host.session_event(e, &mut cx);
                }
            }
        }
        debug_assert!(false, "App::dispatch did not settle in {DISPATCH_ROUNDS} rounds");
    }
}

impl SessionRoot for App {
    fn session(&mut self) -> &mut EditorSession {
        &mut self.session
    }
}

impl ProjectPanelRoot for App {
    fn panel_parts(&mut self) -> (&mut ProjectPanelModel, &mut EditorSession) {
        (&mut self.panel, &mut self.session)
    }
}

impl ShellRoot for App {
    fn shell_parts(&mut self) -> ShellParts<'_> {
        let at = self.hosts.iter_mut().position(|s| s.host.shell_mut().is_some());
        let shell = match at.and_then(|i| self.hosts.get_mut(i)).and_then(|s| s.host.shell_mut()) {
            Some(shell) => shell,
            None => {
                let clock = Arc::clone(&self.clock);
                self.spare_shell.get_or_insert_with(|| {
                    let wall = Box::new(|| Timestamp::from_unix_seconds(0.0));
                    Box::new(ShellHost::new(
                        CommandMap::premiere_default(),
                        RecentProjects::new(Vec::new()),
                        clock,
                        wall,
                    ))
                })
            }
        };
        ShellParts { session: &mut self.session, shell, files: &mut *self.services.files }
    }
}
