//! The plug-in point for panel hosts (the Swift `*Host` classes of SQAppShell and the panels `AppController` owns).
//! A host never stores the session or another host: it pulls state from `&EditorSession` in [`AppHost::sync`], edits
//! through the `&mut EditorSession` of [`HostCx`] (one undo step per `perform`), and reports what Swift sent through
//! its `on*` hooks as [`AppEvent`]s that [`crate::App`] dispatches after the call returns. The session's own hooks
//! (`onChange`, `on*`) reach hosts through [`AppHost::on_change`] and [`AppHost::session_event`].

use crate::AppServices;
use sq_draw::{A11y, Canvas, DrawTheme, GlyphAtlas, InputEvent, InputKey, RgbaImage, TextMeasure, UiCx};
use sq_draw_shell::{ShellFlow, ShellHost, WindowOp};
use sq_editor_session::{Change, EditorSession, SessionEvent};
use sq_uikit::controls_grid::CGRect;

/// What a host asks of the app (a Swift hook the host's owner assigned). Owners of later hosts add variants here and
/// the matching arm in `App::dispatch`.
#[derive(Clone, Debug, PartialEq)]
pub enum AppEvent {
    /// `shell.onStatus`: a line for the status bar.
    Status(String),
    /// A menu command that awaits dialogs or choosers (`spawn { await .. }`): the loop runs it as a task
    /// ([`crate::App::take_flows`]).
    Flow(ShellFlow),
    /// `shell.onQuit`: the user confirmed Quit; the loop ends ([`crate::App::quit_requested`]).
    Quit,
    /// A monitor enters (`true`) or leaves full screen playback: the window follows ([`crate::App::take_full_screen`]).
    FullScreen(bool),
    /// Window > Minimize / Maximize: the window follows ([`crate::App::take_window_op`]).
    Window(WindowOp),
    /// `onExportsFinished`: exports ended; the loop posts the system notification ([`crate::App::take_exports_finished`]).
    ExportsFinished {
        /// Files written.
        done: Vec<std::path::PathBuf>,
        /// One line per failed job.
        failed: Vec<String>,
    },
    /// Preferences changed the look: the app redraws with this palette and interface size (a factor of the display scale).
    Appearance {
        /// Mode, background and contrast.
        settings: sq_uikit::appearance_palette::AppearanceSettings,
        /// The interface size (`interface_scale`, 1.0 = 100 %).
        ui_scale: f64,
    },
}

/// What assistive tech asks of a node; the host turns it into what a pointer or key press on that control does.
#[derive(Clone, Debug, PartialEq)]
pub enum A11yAction {
    /// Press the control (button, row, menu item).
    Click,
    /// Move keyboard focus to the control.
    Focus,
    /// One step up on a slider or stepper.
    Increment,
    /// One step down on a slider or stepper.
    Decrement,
    /// Set a slider or field to this value (in the units the node reports).
    SetValue(f64),
    /// Set a text field to this text.
    SetText(String),
}

/// The renderer image slot of the shared thumbnail atlas (posters, Color page sources); `DrawList::IMAGE_SLOTS`
/// names the others.
pub const ATLAS_SLOT: usize = 0;
/// Width and height of the thumbnail atlas in pixels.
pub const ATLAS_SIZE: usize = 2048;

/// A picture a host made for a renderer image slot; the window or the headless shot applies it before drawing.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageUpload {
    /// The renderer slot.
    pub slot: usize,
    /// Where the picture lands in the slot (a part of the atlas); `None` replaces the whole slot by the picture.
    pub at: Option<(usize, usize)>,
    /// The picture, RGBA8 rows top down.
    pub image: RgbaImage,
}

/// What a host may touch while it handles one input event.
pub struct HostCx<'a> {
    /// The session: edits go through `perform` / `try_perform`.
    pub session: &'a mut EditorSession,
    /// Hover, requests, typed text, clipboard and drag preview of this event.
    pub ui: &'a mut UiCx,
    /// The platform's choosers and engines.
    pub services: &'a mut AppServices,
    /// Hook calls, in the order Swift made them.
    pub events: &'a mut Vec<AppEvent>,
    /// The glyph atlas text is measured with (`None` before the font is up: widths are zero).
    pub atlas: Option<&'a GlyphAtlas>,
    /// Device pixels per point.
    pub scale: f32,
}

impl<'a> HostCx<'a> {
    /// The text measure of this frame; it outlives the borrow of `self`, so a host may keep using the context.
    pub fn measure(&self) -> TextMeasure<'a> {
        TextMeasure::new(self.atlas, self.scale)
    }

    /// Queues `event` for `App::dispatch`.
    pub fn emit(&mut self, event: AppEvent) {
        self.events.push(event);
    }
}

/// A drawn panel host the app lays out, draws and routes input to.
pub trait AppHost {
    /// Pulls what the host shows from the session (every frame, before `layout`). Caches key on
    /// `session.version(Change::X)`.
    fn sync(&mut self, _session: &EditorSession) {}
    /// Places the host in `frame` (points) and measures what it needs ([`HostCx::measure`]); it may edit the session
    /// (ticks of an autoscroll) and open menus.
    fn layout(&mut self, frame: CGRect, cx: &mut HostCx);
    /// Draws the host; `cx` brings the session and the UI context for panels that read both while drawing.
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx);
    /// The host animates on its own clock (a zoom ease, a spring back): the loop keeps drawing frames, with no input,
    /// until it returns false. Animations that run through `sq_draw::motion` or `UiCx` need no override.
    fn wants_frames(&self) -> bool {
        false
    }
    /// Handles one input event; true when the host took it (routing stops there).
    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool;
    /// A key came up (J/K/L shuttle holds end on the key-up).
    fn key_up(&mut self, _key: InputKey, _cx: &mut HostCx) {}
    /// Alt was pressed and released alone (Windows and Linux): the menu bar takes the keyboard focus.
    fn alt_tapped(&mut self, _cx: &mut HostCx) {}
    /// The window lost the keyboard: held keys never send their key-up.
    fn focus_lost(&mut self, _cx: &mut HostCx) {}
    /// The window got the keyboard back: state that changes outside the app (files on disk) is checked again.
    fn focus_gained(&mut self, _cx: &mut HostCx) {}
    /// Pushes accessibility nodes (only while `a11y.is_active()`).
    fn a11y(&self, _a11y: &mut A11y) {}
    /// Runs `action` on the node `id` this host pushed in [`AppHost::a11y`]; true when the node is the host's and the
    /// action did something (the edit goes through the session like a pointer edit, so it undoes).
    fn a11y_action(&mut self, _id: accesskit::NodeId, _action: A11yAction, _cx: &mut HostCx) -> bool {
        false
    }
    /// The session notified `changes` (the host's link in Swift's `session.onChange` chain); hosts are called in the
    /// order added, after the call that caused the change returned.
    fn on_change(&mut self, _changes: Change, _cx: &mut HostCx) {}
    /// A session hook fired (`onEffectDefaultsChange`, `onStabilizerNeedsAnalysis`, ..): the host that assigned the
    /// hook in Swift acts on it, the others ignore it.
    fn session_event(&mut self, _event: &SessionEvent, _cx: &mut HostCx) {}
    /// The window is up with its first session (`App::launch`): the shell shows the start window here.
    fn launch(&mut self, _cx: &mut HostCx) {}
    /// Work that finished outside input handling (a flow task changed the session or the shell); called by
    /// `App::settle` after every task poll.
    fn pump(&mut self, _cx: &mut HostCx) {}
    /// The appearance or display scale changed: hosts that keep their own copy of the theme take the new one before
    /// the next layout.
    fn theme_changed(&mut self, _theme: &DrawTheme) {}
    /// The pictures made since the last call, for the renderer's image slots (called once per frame).
    fn take_image_uploads(&mut self) -> Vec<ImageUpload> {
        Vec::new()
    }
    /// The host that owns the shell, so the flow tasks can reach it next to the session (`ShellRoot`).
    fn shell_mut(&mut self) -> Option<&mut ShellHost> {
        None
    }
    /// The dock layout, for the window host: it opens an OS window per floating panel (`ShellDock::floating`).
    fn dock_mut(&mut self) -> Option<&mut sq_draw_shell::ShellDock> {
        None
    }
    /// The rows of the menu that is open (a right-click menu or a menu-bar menu), empty when none: the parity shots dump it.
    fn open_menu_items(&mut self) -> Vec<sq_uikit::sqmenu_model::SQMenuItem> {
        Vec::new()
    }
    /// The eyedropper waits for the app's last presented frame (window pixels); the window loop renders it once.
    fn wants_window_frame(&self) -> bool {
        false
    }
    /// The answer to [`wants_window_frame`](Self::wants_window_frame).
    fn set_window_frame(&mut self, _frame: sq_draw::RgbaImage) {}
    /// A named state of the parity shots (`--pose max-ec`, `mask`, `stabilize`, `effects`); false when unknown here.
    fn shot_pose(&mut self, _name: &str, _cx: &mut HostCx) -> bool {
        false
    }
    /// Opens the menu-bar menu titled `title` (the parity shots); false when this host has no such menu.
    fn open_bar_menu(&mut self, _title: &str, _cx: &mut HostCx) -> bool {
        false
    }
}
