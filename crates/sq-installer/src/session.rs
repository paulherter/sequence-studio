//! The setup's window and the glue around the machine: [`SetupSession`] owns the machine, the view and a software-drawn
//! window (the toolkit's CPU renderer blitted with softbuffer, so the window opens on any machine and never depends on the
//! GPU), turns window events into machine events and does the machine's effects through [`Services`]. The Windows
//! installer runs one session as the whole program; the app opens one before its Start window for the Linux first run.

use crate::machine::{Effect, Event, Exit, JobRequest, LocationCheck, Machine, Taskbar};
use crate::view::{Chrome, ErrorContext, Output, SetupKey, SetupView, WINDOW_H, WINDOW_W};
use sq_draw::pointer::{Pointer, modifiers};
use sq_draw::{Canvas, DrawTheme, GlyphAtlas, InputEvent, SoftwareRenderer, Sources, motion};
use sq_draw_shell::LogOpen;
use sq_uikit::appearance_palette::{AppearanceMode, AppearanceSettings};
use sq_uikit::redesign_tokens as rt;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};
use winit::dpi::{LogicalSize, PhysicalPosition};
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::ActiveEventLoop;
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{Theme, Window, WindowId};

/// How long a scripted key waits after the last one (the screen change has played by then).
const SCRIPT_GAP: f64 = 1.0;
/// The frame pace while something moves (a job runs, a fade plays).
const FRAME: Duration = Duration::from_millis(16);

/// The worker's end of the session's channel. A send also wakes the window's event loop: it sleeps while nothing moves, so
/// without the wake a worker's last message (`JobEnded`, `DataMeasured`) would show up only at the next input.
#[derive(Clone)]
pub struct EventTx {
    tx: Sender<Event>,
    wake: Arc<dyn Fn() + Send + Sync>,
}

impl EventTx {
    pub fn new(tx: Sender<Event>, wake: Arc<dyn Fn() + Send + Sync>) -> EventTx {
        EventTx { tx, wake }
    }

    /// Sends `event` and wakes the loop; `false` when the session is gone.
    pub fn send(&self, event: Event) -> bool {
        let sent = self.tx.send(event).is_ok();
        (self.wake)();
        sent
    }
}

/// What the machine's effects need from the system. The Windows and the Linux flow each have their own.
pub trait Services {
    /// The system's folder chooser (the one place a system dialog is allowed).
    fn choose_folder(&mut self, start: &Path) -> Option<PathBuf>;
    /// Space and rights of a folder; fast, runs on the window's thread.
    fn check_location(&mut self, location: &Path) -> LocationCheck;
    /// Starts the work on its own thread; it sends machine events (`LogAt`, `JobProgress`, `JobEnded`) and ends when
    /// `cancel` is set and the rollback is done.
    fn start_job(&mut self, request: JobRequest, tx: EventTx, cancel: Arc<AtomicBool>);
    /// Measures the settings and caches on its own thread and sends `DataMeasured`.
    fn measure_data(&mut self, tx: EventTx);
    fn open_license(&mut self);
    /// Opens the log in the default app; false when the system would not (a test run's skip counts as opened).
    fn open_log(&mut self, path: &Path) -> bool;
    /// Starts the installed app (not elevated). The window's own `AppUp` comes through `tx` when it exists.
    fn launch_app(&mut self, exe: &Path, tx: EventTx);
}

/// Puts `text` on the clipboard; false when the clipboard refused it.
fn copy_text(text: String) -> bool {
    arboard::Clipboard::new().and_then(|mut c| c.set_text(text)).is_ok()
}

/// Whether a system open (the log, the license) really happens: a test run sets `SQ_NO_EXTERNAL_OPEN` and never raises
/// another program on the desktop.
pub fn external_open_allowed() -> bool {
    std::env::var_os("SQ_NO_EXTERNAL_OPEN").is_none()
}

/// The window's theme and size from the system: dark or light, at `scale` device pixels per point.
pub fn theme(light: bool, scale: f32) -> DrawTheme {
    let mode = if light { AppearanceMode::Light } else { AppearanceMode::Dark };
    DrawTheme::new(&AppearanceSettings::new(mode, 0, 50), scale)
}

/// The screen as pixels: the software renderer's picture of the view at `scale`, `size` in device pixels.
pub fn render(
    view: &mut SetupView,
    machine: &Machine,
    atlas: Option<&GlyphAtlas>,
    light: bool,
    size: (usize, usize),
    scale: f32,
    now: f64,
) -> sq_draw::RgbaImage {
    let t = theme(light, scale);
    let mut canvas = Canvas::with_size(size.0 as f32, size.1 as f32, atlas, scale);
    view.draw(&mut canvas, &t, machine, now);
    let clear = t.token(rt::color::PANEL);
    SoftwareRenderer::render_8bit(&canvas.list, size.0, size.1, clear, &Sources { atlas, ..Sources::default() })
}

/// A test run's keys: `SQ_SETUP_KEYS=enter,escape` presses them in turn. It only works together with
/// `SQ_NO_EXTERNAL_OPEN` (the switch every test run sets), so a user's setup never presses itself.
fn scripted_keys() -> std::collections::VecDeque<SetupKey> {
    let (Some(keys), Some(_)) = (std::env::var_os("SQ_SETUP_KEYS"), std::env::var_os("SQ_NO_EXTERNAL_OPEN")) else {
        return std::collections::VecDeque::new();
    };
    keys.to_string_lossy()
        .split(',')
        .filter_map(|k| match k.trim() {
            "enter" => Some(SetupKey::Enter),
            "escape" => Some(SetupKey::Escape),
            "tab" => Some(SetupKey::Tab),
            "space" => Some(SetupKey::Space),
            _ => None,
        })
        .collect()
}

fn map_key(key: &Key, command: bool, shift: bool) -> Option<SetupKey> {
    match key {
        Key::Named(NamedKey::Enter) => Some(SetupKey::Enter),
        Key::Named(NamedKey::Escape) => Some(SetupKey::Escape),
        Key::Named(NamedKey::Tab) => Some(if shift { SetupKey::ShiftTab } else { SetupKey::Tab }),
        Key::Named(NamedKey::Space) => Some(SetupKey::Space),
        Key::Character(c) if command && c.eq_ignore_ascii_case("c") => Some(SetupKey::Copy),
        _ => None,
    }
}

/// The open setup window with its machine.
pub struct SetupSession {
    window: Arc<Window>,
    // Kept alive with the surface; softbuffer's surface refers to its display.
    _context: softbuffer::Context<Arc<Window>>,
    surface: softbuffer::Surface<Arc<Window>, Arc<Window>>,
    machine: Machine,
    view: SetupView,
    atlas: Option<GlyphAtlas>,
    services: Box<dyn Services>,
    light: bool,
    started: Instant,
    pointer: Pointer,
    mods: ModifiersState,
    tx: EventTx,
    rx: Receiver<Event>,
    cancel: Arc<AtomicBool>,
    /// The machine revision the last frame showed.
    painted: u64,
    exit: Option<Exit>,
    #[cfg(windows)]
    taskbar: sq_platform_win::TaskbarProgress,
    /// Keys a harness run presses by itself, one every [`SCRIPT_GAP`] seconds (`SQ_SETUP_KEYS`).
    script: std::collections::VecDeque<SetupKey>,
    script_at: f64,
}

impl SetupSession {
    /// Opens the window for `machine`. `title` is the taskbar and Alt+Tab name; `atlas` is the Inter the text is drawn in.
    pub fn open(
        el: &ActiveEventLoop,
        title: &str,
        chrome: Chrome,
        context: ErrorContext,
        atlas: GlyphAtlas,
        machine: Machine,
        services: Box<dyn Services>,
    ) -> Result<SetupSession, String> {
        let mut attrs = Window::default_attributes()
            .with_title(title)
            .with_inner_size(LogicalSize::new(WINDOW_W, WINDOW_H))
            .with_resizable(false)
            .with_enabled_buttons(winit::window::WindowButtons::CLOSE)
            .with_decorations(chrome == Chrome::System)
            .with_visible(true);
        let (icon_pixels, icon_side) = sq_draw_shell::ShellAppIcon::rgba();
        if let Ok(icon) = winit::window::Icon::from_rgba(icon_pixels.to_vec(), icon_side, icon_side) {
            attrs = attrs.with_window_icon(Some(icon));
        }
        #[cfg(windows)]
        {
            use winit::platform::windows::{CornerPreference, WindowAttributesExtWindows};
            attrs = attrs.with_undecorated_shadow(true).with_corner_preference(CornerPreference::Round);
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            use winit::platform::wayland::WindowAttributesExtWayland;
            use winit::platform::x11::WindowAttributesExtX11;
            let id = sq_platform::desktop_integration::app_id();
            attrs = WindowAttributesExtWayland::with_name(attrs, id, id);
            attrs = WindowAttributesExtX11::with_name(attrs, id, id);
        }
        let window = Arc::new(el.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        if let Some(monitor) = el.primary_monitor() {
            let (size, at, own) = (monitor.size(), monitor.position(), window.outer_size());
            let x = at.x + (size.width.saturating_sub(own.width) / 2) as i32;
            let y = at.y + (size.height.saturating_sub(own.height) / 2) as i32;
            window.set_outer_position(PhysicalPosition::new(x, y));
        }
        #[cfg(windows)]
        let window_for_taskbar = Arc::clone(&window);
        let context_handle = softbuffer::Context::new(Arc::clone(&window)).map_err(|e| format!("display: {e}"))?;
        let surface =
            softbuffer::Surface::new(&context_handle, Arc::clone(&window)).map_err(|e| format!("surface: {e}"))?;
        let light = window.theme() == Some(Theme::Light);
        let (tx, rx) = std::sync::mpsc::channel();
        let wake_window = Arc::clone(&window);
        let tx = EventTx::new(tx, Arc::new(move || wake_window.request_redraw()));
        let started = Instant::now();
        // The uninstall question shows the size of the settings and caches, measured while it is on screen.
        let effects = if matches!(machine.screen, crate::machine::InstallerScreen::UninstallConfirm { .. }) {
            vec![Effect::MeasureData]
        } else {
            Vec::new()
        };
        let mut session = SetupSession {
            window,
            _context: context_handle,
            surface,
            machine,
            view: SetupView::new(chrome, context),
            atlas: Some(atlas),
            services,
            light,
            started,
            pointer: Pointer::awaiting_position(),
            mods: ModifiersState::empty(),
            tx,
            rx,
            cancel: Arc::new(AtomicBool::new(false)),
            painted: 0,
            exit: None,
            script: scripted_keys(),
            script_at: SCRIPT_GAP,
            #[cfg(windows)]
            taskbar: sq_platform_win::TaskbarProgress::new(&window_for_taskbar),
        };
        session.perform(effects);
        session.window.request_redraw();
        Ok(session)
    }

    pub fn id(&self) -> WindowId {
        self.window.id()
    }

    pub fn machine(&self) -> &Machine {
        &self.machine
    }

    pub fn focus(&self) {
        self.window.focus_window();
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// Feeds one event and does what comes out of it.
    fn feed(&mut self, event: Event) {
        let now = self.now();
        let effects = self.machine.handle(event, now);
        self.perform(effects);
        self.window.request_redraw();
    }

    fn perform(&mut self, effects: Vec<Effect>) {
        let now = self.now();
        for effect in effects {
            match effect {
                Effect::ChooseFolder(start) => {
                    if let Some(picked) = self.services.choose_folder(&start) {
                        self.feed(Event::LocationPicked(picked));
                    }
                }
                Effect::CheckLocation(location) => {
                    let check = self.services.check_location(&location);
                    let again = self.machine.handle(Event::LocationChecked { location, check }, now);
                    self.perform(again);
                }
                Effect::StartJob(request) => {
                    self.cancel.store(false, std::sync::atomic::Ordering::SeqCst);
                    self.services.start_job(request, self.tx.clone(), Arc::clone(&self.cancel));
                }
                Effect::CancelJob => self.cancel.store(true, std::sync::atomic::Ordering::SeqCst),
                Effect::MeasureData => self.services.measure_data(self.tx.clone()),
                Effect::OpenLicense => self.services.open_license(),
                Effect::LaunchApp(exe) => self.services.launch_app(&exe, self.tx.clone()),
                Effect::Exit(exit) => self.exit = Some(exit),
                Effect::Taskbar(state) => self.set_taskbar(state),
            }
        }
    }

    /// Windows mirrors the progress on the taskbar button; elsewhere there is no such button.
    fn set_taskbar(&mut self, state: Taskbar) {
        #[cfg(windows)]
        match state {
            Taskbar::Off => self.taskbar.set(None),
            Taskbar::Value(v) => self.taskbar.set(Some((v.clamp(0.0, 1.0) * 100.0) as u8)),
            Taskbar::Error => self.taskbar.set_error(),
        }
        #[cfg(not(windows))]
        let _ = state;
    }

    fn outputs(&mut self, outputs: Vec<Output>) {
        for output in outputs {
            match output {
                Output::Event(event) => self.feed(event),
                Output::Copy(text) => {
                    copy_text(text);
                }
                Output::OpenLog(path) => {
                    // The card says what came of it; a refused open leaves the path on the clipboard instead.
                    let result = if self.services.open_log(&path) {
                        LogOpen::Opened
                    } else {
                        LogOpen::Failed { path_copied: copy_text(path.display().to_string()) }
                    };
                    let now = self.now();
                    self.view.log_opened(result, now);
                    self.window.request_redraw();
                }
            }
        }
    }

    /// The pointer events of one button change, in device pixels, go to the view.
    fn clicks(&mut self, events: &[InputEvent], scale: f64, now: f64) {
        let done = self.view.clicks(events, scale, now);
        if done.redraw {
            self.window.request_redraw();
        }
        if done.drag_window {
            let _ = self.window.drag_window();
        }
        self.outputs(done.outputs);
    }

    /// One window event; `Some` when the setup is over.
    pub fn window_event(&mut self, event: WindowEvent) -> Option<Exit> {
        let now = self.now();
        let scale = self.window.scale_factor();
        match event {
            WindowEvent::CloseRequested => self.feed(Event::Escape),
            WindowEvent::RedrawRequested => self.paint(),
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } | WindowEvent::Occluded(false) => {
                self.window.request_redraw();
            }
            WindowEvent::ThemeChanged(theme) => {
                self.light = theme == Theme::Light;
                self.window.request_redraw();
            }
            WindowEvent::ModifiersChanged(m) => self.mods = m.state(),
            WindowEvent::CursorMoved { position, .. } => {
                let mods = modifiers(self.mods);
                if let InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } =
                    self.pointer.moved(position.x, position.y, mods)
                    && self.view.pointer_moved(f64::from(x) / scale, f64::from(y) / scale)
                {
                    self.window.request_redraw();
                }
                // Presses that came before this first position land here now.
                for (_, _, events) in self.pointer.take_queued() {
                    self.clicks(&events, scale, now);
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if self.view.pointer_left() {
                    self.window.request_redraw();
                }
            }
            WindowEvent::MouseInput { state, button: MouseButton::Left, .. } => {
                let events = self.pointer.button(state, MouseButton::Left, modifiers(self.mods));
                self.clicks(&events, scale, now);
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed && !event.repeat => {
                let command = self.mods.control_key() || self.mods.super_key();
                if let Some(key) = map_key(&event.logical_key, command, self.mods.shift_key()) {
                    let out = self.view.key(key, &self.machine, now);
                    self.window.request_redraw();
                    self.outputs(out);
                }
            }
            _ => {}
        }
        self.exit
    }

    /// Between events: the worker's messages, the machine's clock, the next frame. Returns the exit and when to wake.
    pub fn about_to_wait(&mut self) -> (Option<Exit>, Option<Instant>) {
        while let Ok(event) = self.rx.try_recv() {
            self.feed(event);
        }
        let now = self.now();
        if now >= self.script_at
            && let Some(key) = self.script.pop_front()
        {
            self.script_at = now + SCRIPT_GAP;
            let out = self.view.key(key, &self.machine, now);
            self.outputs(out);
        }
        let effects = self.machine.handle(Event::Tick, now);
        self.perform(effects);
        // A tick can change the screen on its own (the hold after a finished job ends): draw it now, the loop may sleep next.
        if self.machine.revision() != self.painted {
            self.window.request_redraw();
        }
        if self.exit.is_some() {
            return (self.exit, None);
        }
        let busy = !self.script.is_empty()
            || self.machine.needs_ticks()
            || self.view.animating(&self.machine, now)
            || motion::needs_frame();
        if busy {
            self.window.request_redraw();
            return (None, Some(Instant::now() + FRAME));
        }
        (None, None)
    }

    fn paint(&mut self) {
        self.painted = self.machine.revision();
        let now = self.now();
        motion::begin_frame(now);
        let size = self.window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else { return };
        let scale = self.window.scale_factor() as f32;
        let image = render(
            &mut self.view,
            &self.machine,
            self.atlas.as_ref(),
            self.light,
            (size.width as usize, size.height as usize),
            scale,
            now,
        );
        if self.surface.resize(w, h).is_err() {
            return;
        }
        if let Ok(mut buffer) = self.surface.buffer_mut() {
            let (pixels, _) = image.pixels.as_chunks::<4>();
            for (dst, px) in buffer.iter_mut().zip(pixels) {
                *dst = u32::from(px[0]) << 16 | u32::from(px[1]) << 8 | u32::from(px[2]);
            }
            let _ = buffer.present();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn a_worker_send_delivers_the_event_and_wakes_the_loop_every_time() {
        let (tx, rx) = std::sync::mpsc::channel();
        let wakes = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&wakes);
        let tx = EventTx::new(
            tx,
            Arc::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
        );
        let from_thread = tx.clone();
        let worker = std::thread::spawn(move || from_thread.send(Event::AppUp));
        assert_eq!(worker.join().ok(), Some(true));
        assert!(tx.send(Event::Tick));
        assert_eq!(wakes.load(Ordering::SeqCst), 2, "one wake per send, also from another thread");
        assert!(matches!(rx.try_recv(), Ok(Event::AppUp)) && matches!(rx.try_recv(), Ok(Event::Tick)));
        drop(rx);
        assert!(!tx.send(Event::Tick), "a closed session says so");
        assert_eq!(wakes.load(Ordering::SeqCst), 3);
    }
}
