// Swift: SQAppShell/AppController+Shell (the shell's hooks into the window)
//! The app shell (menu bar, dialogs, Preferences, start window) as an app host: delegates to [`DrawShell`], then turns the
//! shell's events into app events; what the app root must run (quit, settings, flows) waits in [`ShellHost::take_deferred`].

use crate::export_host::{self, ExportSetup, ExportSnapshot, SharedSnapshot};
use sq_app_shell::{A11yAction, AppEvent, AppHost, HostCx};
use sq_core_edit::timeline_trim_mode::TrimPoint;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent};
use sq_draw_shell::{NoHooks, ShellCx, ShellEvent, ShellFlow, ShellHooks, ShellHost as DrawShell, ShellMenu};
use sq_editor_session::{Change, EditorSession};
use sq_uikit::controls_grid::{CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;

/// What the host could not do alone: the app root owns the window, settings, engines and the executor.
#[derive(Clone, Debug, PartialEq)]
pub enum ShellDeferred {
    /// A hook that only notifies the owner (quit, settings, folders, exports...).
    Event(ShellEvent),
    /// A flow that awaits dialogs or choosers (`spawn { await .. }`).
    Flow(ShellFlow),
}

/// The shell: menu bar on top, dialogs and menus over everything.
pub struct ShellHost {
    inner: DrawShell,
    hooks: Box<dyn ShellHooks>,
    /// Menus built in `sync` (the only call that sees the session), installed by `layout`; `None` while the bar is up to date.
    menus: Option<Vec<ShellMenu>>,
    pub(crate) deferred: Vec<ShellDeferred>,
    /// The project the export jobs read, refreshed by `sync`.
    snapshot: SharedSnapshot,
    /// The start window's controls as of the last `layout` (nodes are pushed without the session at hand).
    start_spots: Vec<sq_draw_shell::StartSpot>,
    /// The first-run welcome was checked (`welcomeChecked`): once per run, the first time the editor window is drawn.
    /// Starts true and `launch` (the real app start) arms it, so panels driven without a launch never get the dialog.
    welcome_checked: bool,
    /// The welcome waits: the recovery offer is not settled yet (see [`ShellHost::hold_welcome`]).
    welcome_held: bool,
}

impl ShellHost {
    /// A host around `shell` with the panel hooks of the app root (`None`: a shell without panels).
    pub fn new(mut shell: DrawShell, hooks: Option<Box<dyn ShellHooks>>) -> ShellHost {
        // The root reveals files itself (`ShellEvent::RevealFile`), so the Export finished card may offer it.
        shell.can_reveal_file = true;
        // Tests check on every idle frame that the kept menu bar is the one a fresh build gives.
        shell.verify_menu_cache = cfg!(test);
        ShellHost {
            inner: shell,
            hooks: hooks.unwrap_or_else(|| Box::new(NoHooks)),
            menus: None,
            deferred: Vec::new(),
            snapshot: SharedSnapshot::default(),
            start_spots: Vec::new(),
            welcome_checked: true,
            welcome_held: false,
        }
    }

    /// The Welcome Tour never opens over the recovery prompt or a project that was just recovered: `pending` holds it back
    /// until the offer is answered, `recovered` drops it for this run (the flag stays unset, the next start shows it).
    pub fn hold_welcome(&mut self, pending: bool, recovered: bool) {
        self.welcome_held = pending;
        if recovered {
            self.welcome_checked = true;
        }
    }

    /// Turns File > Export on: the sheet, the queue and the sources of a sequence.
    pub fn enable_export(&mut self, setup: ExportSetup) {
        let export = &mut self.inner.export;
        export.sources = Some(export_host::provider(SharedSnapshot::clone(&self.snapshot), setup.make_sources));
        export.queue = Some(setup.queue);
        export.frame_pixels = setup.frame_pixels;
        export.stem_audio =
            setup.make_stem_audio.map(|make| export_host::stem_provider(SharedSnapshot::clone(&self.snapshot), make));
        export.stem_encoder = setup.stem_encoder;
        export.file_outputs = false;
    }

    /// The shell (dialogs are presented, flows run, settings are stored through it).
    pub fn shell(&mut self) -> &mut DrawShell {
        &mut self.inner
    }

    /// Pip on the start window needs a steady stream of frames (no input drives him).
    pub fn start_mascot_animating(&self) -> bool {
        self.inner.start_mascot_animating()
    }

    /// Whether the start window is up (it takes every event).
    pub fn start_shown(&self) -> bool {
        self.inner.is_start_shown()
    }

    /// Whether a shell dialog (Save Changes, New Project, errors) or the Shortcuts page of Settings is up: it takes every
    /// event (the shortcut tool keys must not reach the timeline while its search field types).
    pub fn has_dialog(&self) -> bool {
        self.inner.dialog().is_some() || self.inner.is_shortcuts_shown()
    }

    /// Whether a shell surface (dialog, Settings shortcuts page, menu, Quick Apply, the export queue popover, the start
    /// screen) owns the keyboard: no editor shortcut may run behind it.
    pub fn owns_keyboard(&self) -> bool {
        self.inner.owns_keyboard()
    }

    /// Whether the Quick Apply palette is showing.
    pub fn quick_apply_open(&self) -> bool {
        self.inner.quick_apply_open()
    }

    /// Whether a menu of the drawn menu bar (or a popup the shell opened) is open: it is drawn over every panel, so it gets
    /// each event before any panel does.
    pub fn menu_open(&self) -> bool {
        self.inner.menu_bar.controller.is_open() || self.inner.menu_bar.keyboard_focus().is_some()
    }

    /// Alt pressed and released alone (Windows and Linux): the keyboard focus goes to the menu bar, or leaves it.
    pub fn alt_tapped(&mut self, cx: &mut HostCx) {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.inner.alt_tapped(&mut sc);
    }

    /// What waits for the app root, in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<ShellDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// Runs a menu command a panel asked for (the timeline's context menu and header buttons) as the menu bar would;
    /// false when the command is disabled or nobody runs it.
    pub fn run_command(&mut self, cx: &mut HostCx, c: EditorCommand) -> bool {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        let done = self.inner.execute(&mut sc, c);
        self.route(cx);
        done
    }

    /// Performs a menu row that is not a command (About, Window rows, imports...), as a click on it does.
    pub fn perform_action(&mut self, cx: &mut HostCx, a: sq_draw_shell::ShellAction) {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.inner.perform(&mut sc, a);
        self.route(cx);
    }

    /// Whether the menu row of `c` is enabled now (the rules the menu bar and `run_command` use).
    pub fn command_enabled(&self, session: &EditorSession, c: EditorCommand) -> bool {
        self.inner.enabled(session, self.hooks.as_ref(), c)
    }

    /// Whether the menu row of `c` is enabled (`ShellHost::menu_enabled`: the focus rules and Undo / Redo on top of `command_enabled`).
    pub fn menu_enabled(&self, session: &EditorSession, c: EditorCommand) -> bool {
        self.inner.menu_enabled(session, self.hooks.as_ref(), c)
    }

    /// Opens Trim mode at an edit (a double-click on a clip edge) and stops playback.
    pub fn enter_trim_mode(&mut self, cx: &mut HostCx, p: TrimPoint, pointer_before: bool) {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.inner.enter_trim_mode(&mut sc, p, pointer_before);
    }

    /// The first-run Welcome Tour (`presentWelcomeOnce`): not while the start screen or a dialog is up, never in the
    /// screenshot harness (`SQ_SHARED_UI_SHOT`).
    fn present_welcome_once(&mut self, cx: &mut HostCx) {
        if self.welcome_checked || self.welcome_held || self.inner.is_start_shown() || self.inner.dialog().is_some() {
            return;
        }
        self.welcome_checked = true;
        if std::env::var_os("SQ_SHARED_UI_SHOT").is_some() {
            return;
        }
        // The welcome comes first. The first-run window for the app menu (`desktop_entry::offer_due`) is wired by the
        // setup flow, not here: the old question dialog is gone.
        let _ = self.inner.present_welcome_if_needed();
        self.route(cx);
    }

    fn route(&mut self, cx: &mut HostCx) {
        let events = self.inner.take_events();
        let flows = self.inner.take_flows();
        let (deferred, status) = route_shell(events, flows);
        self.deferred.extend(deferred);
        for line in status {
            cx.emit(AppEvent::Status(line));
        }
    }
}

/// Splits the shell's events into the status lines (`onStatus`) and the rest, which keeps its order (events, then flows).
pub fn route_shell(events: Vec<ShellEvent>, flows: Vec<ShellFlow>) -> (Vec<ShellDeferred>, Vec<String>) {
    let (mut deferred, mut status) = (Vec::new(), Vec::new());
    for event in events {
        match event {
            ShellEvent::Status(line) => status.push(line),
            other => deferred.push(ShellDeferred::Event(other)),
        }
    }
    deferred.extend(flows.into_iter().map(ShellDeferred::Flow));
    (deferred, status)
}

impl AppHost for ShellHost {
    fn sync(&mut self, session: &EditorSession) {
        if let Some(menus) = self.inner.refresh_menus(session, self.hooks.as_ref()) {
            self.menus = Some(menus);
        }
        let project = session.project();
        let mut snapshot = self.snapshot.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *snapshot = ExportSnapshot {
            timelines: project.timelines.clone(),
            media: project.media.clone(),
            use_proxies_for_export: session.use_proxies_for_export(),
        };
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        let m = &cx.measure();
        self.inner.set_size(CGSize::new(frame.width, frame.height));
        match self.menus.take() {
            Some(menus) => self.inner.menu_bar.set_menus(menus, m),
            // Same rows; the titles still follow the text scale.
            None => self.inner.menu_bar.set_origin(self.inner.menu_bar.origin(), m),
        }
        self.inner.relayout_dialog(m);
        let measure = cx.measure();
        let sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.start_spots = self.inner.a11y_start(&sc);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.inner.draw_bar(c, t);
        self.inner.draw_overlays(c, t, cx.ui);
        self.present_welcome_once(cx);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        let taken = self.inner.handle(&mut sc, e, cx.scale);
        self.route(cx);
        taken
    }

    fn on_change(&mut self, _changes: Change, cx: &mut HostCx) {
        // A project created or opened by a flow moves the start screen on without waiting for the next input.
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.inner.sync_start(&mut sc);
        self.route(cx);
    }

    fn launch(&mut self, cx: &mut HostCx) {
        self.welcome_checked = false;
        if cx.session.is_empty_untitled() {
            let measure = cx.measure();
            let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
            self.inner.present_start_at_launch(&mut sc);
        }
        self.route(cx);
    }

    fn pump(&mut self, cx: &mut HostCx) {
        let measure = cx.measure();
        let mut sc = ShellCx { session: cx.session, measure, ui: cx.ui, hooks: self.hooks.as_mut() };
        self.inner.perform_pending(&mut sc);
        self.inner.sync_start(&mut sc);
        self.inner.pump_analysis(sc.session);
        self.route(cx);
    }

    fn shell_mut(&mut self) -> Option<&mut DrawShell> {
        Some(&mut self.inner)
    }

    fn a11y(&self, a: &mut A11y) {
        self.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        self.run_action(id, action, cx)
    }
}

mod access;
#[cfg(test)]
mod tests;
