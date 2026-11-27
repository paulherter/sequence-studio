//! Windows and Linux: the drawn caption around the app root. The root lays out and draws as on the Mac; this wrapper
//! shrinks the menu row to the caption's height, keeps the menu titles clear of the window buttons, draws the buttons over
//! the row and keeps the frames the window's hit test reads (Swift AppController+Chrome.swift `windowHit`). Windows
//! answers its frame messages from them (`install_chrome`); Linux has no system title bar either, the window loop reads them (`caption::WindowControls`).

use crate::caption::{self, Button, CaptionState, Shared};
use sq_app_hosts::AppRoot;
use sq_app_shell::{AppHost, HostCx};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent};
use sq_draw_shell::ShellHost;
use sq_editor_session::{Change, EditorSession, SessionEvent};
use sq_uikit::controls_grid::CGRect;
use std::sync::Arc;
use winit::window::Window;

/// What a caption button does to `window`. Close asks the app the Save Changes question: Windows posts its close
/// message, elsewhere the window loop reads the request from `state` (`CaptionState::take_close`).
fn act(window: &Window, state: &Shared, b: Button) {
    match b {
        Button::Minimize => window.set_minimized(true),
        Button::Maximize => window.set_maximized(!window.is_maximized()),
        Button::Close => close(window, state),
    }
}

#[cfg(windows)]
fn close(window: &Window, _state: &Shared) {
    sq_platform_win::request_close(window);
}

#[cfg(not(windows))]
fn close(_window: &Window, state: &Shared) {
    with(state, CaptionState::ask_close);
}

/// Runs `f` on the shared state; skipped when the draw UI holds it (a hit test then answers "client").
fn with<T>(state: &Shared, f: impl FnOnce(&mut CaptionState) -> T) -> Option<T> {
    state.try_lock().ok().map(|mut s| f(&mut s))
}

/// The root with the caption around it.
pub struct CaptionRoot {
    root: AppRoot,
    state: Shared,
    window: Arc<Window>,
}

/// Windows: the window's frame messages answer from the same state the draw UI lays out.
#[cfg(windows)]
fn install_chrome(window: &Arc<Window>, state: &Shared) {
    use crate::caption::WindowHit;
    use sq_platform_win::{Chrome, Hit, MaxButton};
    let (hit_state, max_state, max_window) = (Arc::clone(state), Arc::clone(state), Arc::clone(window));
    let chrome = Chrome {
        hit: Box::new(move |x, y| match with(&hit_state, |s| s.hit_px(x, y)).unwrap_or(WindowHit::Client) {
            WindowHit::Client | WindowHit::Button(Button::Minimize | Button::Close) => Hit::Client,
            WindowHit::Caption => Hit::Caption,
            WindowHit::Button(Button::Maximize) => Hit::Maximize,
            WindowHit::Left => Hit::Left,
            WindowHit::Right => Hit::Right,
            WindowHit::Top => Hit::Top,
            WindowHit::Bottom => Hit::Bottom,
            WindowHit::TopLeft => Hit::TopLeft,
            WindowHit::TopRight => Hit::TopRight,
            WindowHit::BottomLeft => Hit::BottomLeft,
            WindowHit::BottomRight => Hit::BottomRight,
        }),
        max_button: Box::new(move |m| {
            let fired = with(&max_state, |s| match m {
                MaxButton::Moved(x, y) => (s.moved(x, y), None),
                MaxButton::Down(x, y) => (s.pressed_at(x, y), None),
                MaxButton::Up(x, y) => (true, s.released_at(x, y)),
                MaxButton::Left => (s.left(), None),
            });
            if let Some((changed, fired)) = fired {
                if let Some(b) = fired {
                    act(&max_window, &max_state, b);
                }
                if changed {
                    max_window.request_redraw();
                }
            }
        }),
    };
    if !sq_platform_win::install_chrome(window, chrome) {
        sq_os::errln!("window chrome could not be installed");
    }
}

impl CaptionRoot {
    /// Wraps `root`; `state` is the caption state the window loop and (on Windows) the frame messages read.
    pub fn new(root: AppRoot, window: &Arc<Window>, state: Shared) -> CaptionRoot {
        #[cfg(windows)]
        install_chrome(window, &state);
        CaptionRoot { root, state, window: Arc::clone(window) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, CaptionState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl AppHost for CaptionRoot {
    fn sync(&mut self, session: &EditorSession) {
        self.root.sync(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        let m = cx.measure();
        self.root.set_title_right_margin(caption::export_margin(sq_os::Platform::current()));
        // The start screen's search sits in the bar, left of the buttons.
        self.root.shell.shell().start_search_in_bar = true;
        self.root.shell.shell().start_bar_right_inset = caption::START_BAR_INSET;
        let bar = self.root.shell.shell().menu_bar.height();
        if (bar - caption::HEIGHT).abs() > f64::EPSILON {
            self.root.shell.shell().menu_bar.set_height(caption::HEIGHT, &m);
        }
        let room = CaptionState::menu_room(self.root.shell.shell().menu_bar.origin().x, frame.width);
        self.root.shell.shell().menu_bar.set_max_width(Some(room), &m);
        self.root.layout(frame, cx);
        let (title_controls, rows_bottom) = self.root.title_drag();
        let start_controls = self.root.shell.shell().start_bar_controls();
        let bar = &self.root.shell.shell().menu_bar;
        let controls: Vec<CGRect> = bar
            .title_frames()
            .iter()
            .copied()
            .chain(bar.overflow_frame())
            .chain(title_controls)
            .chain(start_controls)
            .collect();
        // The menu row always drags, also where no title row sits under it (the start screen).
        let rows_bottom = rows_bottom.max(bar.height());
        let open = bar.controller.is_open();
        let mut s = self.lock();
        s.scale = f64::from(cx.scale);
        s.maximized = self.window.is_maximized();
        s.layout(frame.width, frame.height, controls, rows_bottom, open);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.root.draw(c, t, cx);
        self.lock().draw(c, t);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let (taken, fired) = self.lock().handle(e);
        if let Some(b) = fired {
            act(&self.window, &self.state, b);
        }
        taken || self.root.handle(e, cx)
    }

    // Every `AppHost` method must be forwarded to the root: a method left at its default silently drops the call (the
    // key-up of J/K/L was lost this way). `host_forwarding::every_app_host_method_is_forwarded` guards the list on every platform.
    fn key_up(&mut self, key: sq_draw::InputKey, cx: &mut HostCx) {
        self.root.key_up(key, cx);
    }

    fn alt_tapped(&mut self, cx: &mut HostCx) {
        self.root.alt_tapped(cx);
    }

    fn focus_lost(&mut self, cx: &mut HostCx) {
        self.root.focus_lost(cx);
    }

    fn focus_gained(&mut self, cx: &mut HostCx) {
        self.root.focus_gained(cx);
    }

    fn a11y(&self, a: &mut A11y) {
        self.root.a11y(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: sq_app_shell::A11yAction, cx: &mut HostCx) -> bool {
        self.root.a11y_action(id, action, cx)
    }

    fn take_image_uploads(&mut self) -> Vec<sq_app_shell::ImageUpload> {
        self.root.take_image_uploads()
    }

    fn open_menu_items(&mut self) -> Vec<sq_uikit::sqmenu_model::SQMenuItem> {
        self.root.open_menu_items()
    }

    fn shot_pose(&mut self, name: &str, cx: &mut HostCx) -> bool {
        self.root.shot_pose(name, cx)
    }

    fn open_bar_menu(&mut self, title: &str, cx: &mut HostCx) -> bool {
        self.root.open_bar_menu(title, cx)
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.root.on_change(changes, cx);
    }

    fn session_event(&mut self, event: &SessionEvent, cx: &mut HostCx) {
        self.root.session_event(event, cx);
    }

    fn launch(&mut self, cx: &mut HostCx) {
        self.root.launch(cx);
    }

    fn pump(&mut self, cx: &mut HostCx) {
        self.root.pump(cx);
    }

    fn theme_changed(&mut self, theme: &DrawTheme) {
        self.root.theme_changed(theme);
    }

    fn shell_mut(&mut self) -> Option<&mut ShellHost> {
        self.root.shell_mut()
    }

    fn wants_frames(&self) -> bool {
        self.root.wants_frames()
    }

    fn wants_window_frame(&self) -> bool {
        self.root.wants_window_frame()
    }

    fn set_window_frame(&mut self, frame: sq_draw::RgbaImage) {
        self.root.set_window_frame(frame);
    }

    fn dock_mut(&mut self) -> Option<&mut sq_draw_shell::ShellDock> {
        self.root.dock_mut()
    }
}
