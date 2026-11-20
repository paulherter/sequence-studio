//! The window of the start-failure screen. It never touches the GPU: the screen (`sq_draw_shell::ErrorView`) is rasterized
//! by the toolkit's software renderer and blitted with softbuffer, so the window opens even when the GPU, its driver or
//! the shaders are what failed. It uses the system's own title bar and a fixed size; everything inside is the app's look.
//!
//! The last fallback, when not even this window can open (no softbuffer surface, no fonts), is a native message box that
//! still names the code and the log path (`native_message`).

use crate::applog;
use crate::input::{self, Pointer};
use crate::start_failure::StartFailure;
use sq_app_hosts::{FileManager, SystemPlatform};
use sq_draw::InputEvent;
use sq_draw::pointer::{Click, primary_clicks};
use sq_draw::{Canvas, DrawTheme, GlyphAtlas, RgbaImage, SoftwareRenderer, Sources, motion};
use sq_draw_shell::{
    ERROR_SCREEN_H, ERROR_SCREEN_W, ErrorAction, ErrorKey, ErrorPrimary, ErrorScreen, ErrorView, LogOpen,
};
use sq_uikit::appearance_palette::{AppearanceMode, AppearanceSettings};
use sq_uikit::redesign_tokens as rt;
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Instant;
use winit::dpi::LogicalSize;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::ActiveEventLoop;
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{Theme, Window, WindowId};

/// How the user left the screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// `Close`, Esc or the title bar's close button.
    Close,
    /// `Try Again`: run the start again.
    TryAgain,
    /// `Continue`: go on with the start.
    Continue,
}

/// The screen as pixels: the software renderer's picture of `view` at `scale`, `size` in device pixels.
pub fn render(
    view: &mut ErrorView,
    atlas: Option<&GlyphAtlas>,
    theme: &DrawTheme,
    size: (usize, usize),
    now: f64,
) -> RgbaImage {
    let mut canvas = Canvas::with_size(size.0 as f32, size.1 as f32, atlas, theme.scale);
    view.draw(&mut canvas, theme, now);
    let clear = theme.token(rt::color::PANEL);
    SoftwareRenderer::render_8bit(&canvas.list, size.0, size.1, clear, &Sources { atlas, ..Sources::default() })
}

/// The theme of the screen: dark or light, at `scale` device pixels per point.
pub fn theme(light: bool, scale: f32) -> DrawTheme {
    let mode = if light { AppearanceMode::Light } else { AppearanceMode::Dark };
    DrawTheme::new(&AppearanceSettings::new(mode, 0, 50), scale)
}

/// The key a window event stands for.
fn map_key(key: &Key, shift: bool, command: bool) -> Option<ErrorKey> {
    match key {
        Key::Named(NamedKey::Enter) => Some(ErrorKey::Enter),
        Key::Named(NamedKey::Escape) => Some(ErrorKey::Escape),
        Key::Named(NamedKey::Tab) => Some(if shift { ErrorKey::ShiftTab } else { ErrorKey::Tab }),
        Key::Named(NamedKey::Space) => Some(ErrorKey::Space),
        Key::Character(c) if command && c.eq_ignore_ascii_case("c") => Some(ErrorKey::Copy),
        _ => None,
    }
}

/// Puts `text` on the clipboard; whether it worked.
fn copy_to_clipboard(text: String, what: &str) -> bool {
    match arboard::Clipboard::new().and_then(|mut c| c.set_text(text)) {
        Ok(()) => {
            applog::info(&format!("start error: {what} copied"));
            true
        }
        Err(e) => {
            applog::error(&format!("start error: the clipboard refused the {what}: {e}"));
            false
        }
    }
}

/// What the screen does with the pointer events of one button change (device pixels, as `Pointer` makes them): a press and
/// a release go to the view, a secondary click does nothing here. Returns whether to redraw and the actions the view
/// answered with.
fn route_pointer(view: &mut ErrorView, events: &[InputEvent], scale: f64, now: f64) -> (bool, Vec<ErrorAction>) {
    let (mut redraw, mut actions) = (false, Vec::new());
    for click in primary_clicks(events, scale) {
        match click {
            Click::Down { x, y } => redraw |= view.pointer_down(x, y),
            Click::Up { x, y } => {
                actions.extend(view.pointer_up(x, y, now));
                redraw = true;
            }
        }
    }
    (redraw, actions)
}

/// The open error window.
pub struct ErrorWindow {
    window: Arc<Window>,
    // Kept alive with the surface; softbuffer's surface refers to its display.
    _context: softbuffer::Context<Arc<Window>>,
    surface: softbuffer::Surface<Arc<Window>, Arc<Window>>,
    view: ErrorView,
    atlas: Option<GlyphAtlas>,
    light: bool,
    started: Instant,
    /// The first frame reached the window (logged once; a harness run may press a key by itself then).
    shown: bool,
    /// The main window's pointer (`input.rs`): a press that comes before the first position waits for it instead of
    /// landing at (0, 0), where the window opened under a still pointer swallowed the first click.
    pointer: Pointer,
    mods: ModifiersState,
}

impl ErrorWindow {
    /// Opens the window for `screen`. `fonts` is the folder with the bundled Inter; without it the text cannot be drawn
    /// and the caller falls back to [`native_message`].
    pub fn open(el: &ActiveEventLoop, screen: ErrorScreen, fonts: &std::path::Path) -> Result<ErrorWindow, String> {
        let atlas = GlyphAtlas::inter(fonts).ok_or_else(|| format!("Inter not found in {}", fonts.display()))?;
        let mut attrs = Window::default_attributes()
            .with_title("Sequence Studio")
            .with_inner_size(LogicalSize::new(ERROR_SCREEN_W, ERROR_SCREEN_H))
            .with_resizable(false)
            .with_visible(true);
        let (icon_pixels, icon_side) = sq_draw_shell::ShellAppIcon::rgba();
        if let Ok(icon) = winit::window::Icon::from_rgba(icon_pixels.to_vec(), icon_side, icon_side) {
            attrs = attrs.with_window_icon(Some(icon));
        }
        // The same app id as the main window, so the desktop groups it under the app's icon.
        attrs = sq_platform::app_window::with_app_id(attrs);
        let window = Arc::new(el.create_window(attrs).map_err(|e| format!("window: {e}"))?);
        let context = softbuffer::Context::new(Arc::clone(&window)).map_err(|e| format!("display: {e}"))?;
        let surface = softbuffer::Surface::new(&context, Arc::clone(&window)).map_err(|e| format!("surface: {e}"))?;
        let light = window.theme() == Some(Theme::Light);
        window.request_redraw();
        Ok(ErrorWindow {
            window,
            _context: context,
            surface,
            view: ErrorView::new(screen),
            atlas: Some(atlas),
            light,
            started: Instant::now(),
            shown: false,
            pointer: Pointer::awaiting_position(),
            mods: ModifiersState::empty(),
        })
    }

    pub fn id(&self) -> WindowId {
        self.window.id()
    }

    /// Brings the window forward (a notice that opens over the running app).
    pub fn focus(&self) {
        self.window.focus_window();
    }

    /// One window event; `Some` when the user is done.
    pub fn event(&mut self, event: WindowEvent) -> Option<Outcome> {
        let now = self.started.elapsed().as_secs_f64();
        let scale = self.window.scale_factor();
        match event {
            WindowEvent::CloseRequested => return Some(Outcome::Close),
            WindowEvent::RedrawRequested => return self.paint(),
            // The compositor can report the real scale after the first frame (Wayland maps the window first); the log shows
            // the size and scale of every frame the window was drawn at, so a late jump is read from it, not from a shot.
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                applog::info(&format!("start error window: scale factor now {scale_factor}"));
                self.window.request_redraw();
            }
            WindowEvent::Resized(_) | WindowEvent::Occluded(false) => {
                self.window.request_redraw();
            }
            WindowEvent::ThemeChanged(theme) => {
                self.light = theme == Theme::Light;
                self.window.request_redraw();
            }
            WindowEvent::ModifiersChanged(m) => self.mods = m.state(),
            WindowEvent::CursorMoved { position, .. } => {
                let mods = input::modifiers(self.mods);
                if let InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } =
                    self.pointer.moved(position.x, position.y, mods)
                    && self.view.pointer_moved(f64::from(x) / scale, f64::from(y) / scale)
                {
                    self.window.request_redraw();
                }
                // Presses that came before this first position land here now.
                for (_, _, events) in self.pointer.take_queued() {
                    if let Some(outcome) = self.route(&events, scale, now) {
                        return Some(outcome);
                    }
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if self.view.pointer_left() {
                    self.window.request_redraw();
                }
            }
            WindowEvent::MouseInput { state, button: MouseButton::Left, .. } => {
                let events = self.pointer.button(state, MouseButton::Left, input::modifiers(self.mods));
                return self.route(&events, scale, now);
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed && !event.repeat => {
                let command = self.mods.control_key() || self.mods.super_key();
                if let Some(key) = map_key(&event.logical_key, self.mods.shift_key(), command) {
                    let action = self.view.key(key, now);
                    self.window.request_redraw();
                    return action.and_then(|a| self.perform(a));
                }
            }
            _ => {}
        }
        None
    }

    /// The pointer events of one press or release, in points at `scale`: the view takes them and the action it returns is
    /// performed. `Some` when the user is done.
    fn route(&mut self, events: &[InputEvent], scale: f64, now: f64) -> Option<Outcome> {
        let (redraw, actions) = route_pointer(&mut self.view, events, scale, now);
        if redraw {
            self.window.request_redraw();
        }
        actions.into_iter().find_map(|a| self.perform(a))
    }

    /// Does what a button asked; `Some` when it ends the screen.
    fn perform(&mut self, action: ErrorAction) -> Option<Outcome> {
        match action {
            ErrorAction::Copy(text) => {
                copy_to_clipboard(text, "details");
                None
            }
            ErrorAction::OpenLog(path) => {
                let result = match SystemPlatform.open(&path) {
                    Ok(()) => LogOpen::Opened,
                    Err(e) => {
                        applog::error(&format!("start error: the log could not be opened: {e}"));
                        LogOpen::Failed { path_copied: copy_to_clipboard(path.display().to_string(), "log path") }
                    }
                };
                self.view.log_opened(result, self.started.elapsed().as_secs_f64());
                self.window.request_redraw();
                None
            }
            ErrorAction::Close => Some(Outcome::Close),
            ErrorAction::Primary(ErrorPrimary::TryAgain) => Some(Outcome::TryAgain),
            ErrorAction::Primary(ErrorPrimary::Continue) => Some(Outcome::Continue),
            ErrorAction::Primary(ErrorPrimary::None) => Some(Outcome::Close),
        }
    }

    /// Rasterizes the screen at the window's size and blits it. `Some` when a harness run pressed a key by itself.
    fn paint(&mut self) -> Option<Outcome> {
        let now = self.started.elapsed().as_secs_f64();
        motion::begin_frame(now);
        let size = self.window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else { return None };
        let scale = self.window.scale_factor() as f32;
        let theme = theme(self.light, scale);
        let image =
            render(&mut self.view, self.atlas.as_ref(), &theme, (size.width as usize, size.height as usize), now);
        if let Err(e) = self.surface.resize(w, h) {
            applog::error(&format!("start error window: resize failed: {e}"));
            return None;
        }
        let presented = match self.surface.buffer_mut() {
            Ok(mut buffer) => {
                let (pixels, _) = image.pixels.as_chunks::<4>();
                for (dst, px) in buffer.iter_mut().zip(pixels) {
                    *dst = u32::from(px[0]) << 16 | u32::from(px[1]) << 8 | u32::from(px[2]);
                }
                buffer.present().map_err(|e| format!("present failed: {e}"))
            }
            Err(e) => Err(format!("no buffer: {e}")),
        };
        if let Err(why) = &presented {
            applog::error(&format!("start error window: {why}"));
        }
        if self.view.animating(now) || motion::needs_frame() {
            self.window.request_redraw();
        }
        if presented.is_ok() && !self.shown {
            self.shown = true;
            applog::info(&format!(
                "start error window shown: {} ({}x{} px at scale {scale})",
                self.view.screen().code,
                size.width,
                size.height
            ));
            if let Some(key) = crate::fault_inject::auto_press() {
                let action = self.view.key(key, now);
                return action.and_then(|a| self.perform(a));
            }
        }
        None
    }
}

/// The last fallback: a native message box with the code, the sentence and the log path. The caller also returns the
/// failure as the run's error, which `main` prints to stderr (a terminal run shows it when no box can open).
pub fn native_message(failure: &StartFailure, log: Option<&std::path::Path>) {
    let log_line = log.map(|p| format!("\n\nLog: {}", p.display())).unwrap_or_default();
    let text = format!("Error {}: {}{log_line}", failure.code.text(), failure.sentence());
    if std::env::var_os("SQ_NO_EXTERNAL_OPEN").is_some() {
        return; // a test run: never raise a box on the desktop
    }
    let _ = rfd::MessageDialog::new()
        .set_level(rfd::MessageLevel::Error)
        .set_title("Sequence Studio couldn't start")
        .set_description(text)
        .set_buttons(rfd::MessageButtons::Ok)
        .show();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::start_failure::StartCode;

    fn fonts() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
    }

    fn pixels_differ(a: &RgbaImage, b: &RgbaImage) -> usize {
        a.pixels.iter().zip(&b.pixels).filter(|(x, y)| x != y).count()
    }

    #[test]
    fn keys_map_to_the_screen_keys() {
        assert_eq!(map_key(&Key::Named(NamedKey::Enter), false, false), Some(ErrorKey::Enter));
        assert_eq!(map_key(&Key::Named(NamedKey::Tab), true, false), Some(ErrorKey::ShiftTab));
        assert_eq!(map_key(&Key::Character("c".into()), false, true), Some(ErrorKey::Copy));
        assert_eq!(map_key(&Key::Character("C".into()), false, true), Some(ErrorKey::Copy));
        assert_eq!(map_key(&Key::Character("c".into()), false, false), None, "a plain c copies nothing");
    }

    /// A drawn view (the button frames exist after a draw) over a log that exists.
    fn drawn_view(atlas: &GlyphAtlas) -> ErrorView {
        let failure = StartFailure::new(StartCode::GpuNoAdapter, "starting the graphics", "no GPU adapter: none");
        let mut view = ErrorView::new(failure.screen(Some("/tmp/sq.log".into())));
        let size = (ERROR_SCREEN_W as usize, ERROR_SCREEN_H as usize);
        render(&mut view, Some(atlas), &theme(false, 1.0), size, 0.0);
        view
    }

    /// The window opened under a pointer that has not moved: winit sends the press with no position. The shared pointer
    /// holds it and the click lands on the button under the first position (it used to land at (0, 0) and vanish).
    #[test]
    fn the_first_click_before_any_pointer_position_is_not_swallowed() {
        let Some(atlas) = GlyphAtlas::inter(&fonts()) else { return };
        let mut view = drawn_view(&atlas);
        let at = view.frame_of(sq_draw_shell::ErrorPart::OpenLog).expect("Open log is drawn");
        let (scale, none) = (2.0, sq_draw::InputModifiers::NONE);
        let mut pointer = Pointer::awaiting_position();
        for state in [ElementState::Pressed, ElementState::Released] {
            assert!(pointer.button(state, MouseButton::Left, none).is_empty(), "no position yet: the press waits");
        }
        pointer.moved(at.mid_x() * scale, at.mid_y() * scale, none);
        let mut actions = Vec::new();
        for (_, _, events) in pointer.take_queued() {
            actions.extend(route_pointer(&mut view, &events, scale, 0.0).1);
        }
        assert_eq!(actions, [ErrorAction::OpenLog("/tmp/sq.log".into())]);
    }

    #[test]
    fn a_right_click_on_a_button_does_nothing() {
        let Some(atlas) = GlyphAtlas::inter(&fonts()) else { return };
        let mut view = drawn_view(&atlas);
        let at = view.frame_of(sq_draw_shell::ErrorPart::OpenLog).expect("Open log is drawn");
        let mut pointer = Pointer::default();
        pointer.moved(at.mid_x(), at.mid_y(), sq_draw::InputModifiers::NONE);
        let events = pointer.button(ElementState::Pressed, MouseButton::Right, sq_draw::InputModifiers::NONE);
        assert!(route_pointer(&mut view, &events, 1.0, 0.0).1.is_empty());
    }

    #[test]
    fn the_screen_renders_on_the_cpu_in_both_themes_and_the_gpu_is_never_asked() {
        let Some(atlas) = GlyphAtlas::inter(&fonts()) else { return };
        let failure = StartFailure::new(StartCode::GpuNoAdapter, "starting the graphics", "no GPU adapter: none");
        let mut dark_view = ErrorView::new(failure.screen(Some("/tmp/sq.log".into())));
        let mut light_view = ErrorView::new(failure.screen(Some("/tmp/sq.log".into())));
        let size = (ERROR_SCREEN_W as usize, ERROR_SCREEN_H as usize);
        let dark = render(&mut dark_view, Some(&atlas), &theme(false, 1.0), size, 0.0);
        let light = render(&mut light_view, Some(&atlas), &theme(true, 1.0), size, 0.0);
        assert_eq!((dark.width, dark.height), size);
        assert!(pixels_differ(&dark, &light) > size.0 * size.1, "dark and light must differ");
        let panel = |img: &RgbaImage| img.pixels[(5 * img.width + 5) * 4..][..3].to_vec();
        assert_eq!(panel(&dark), vec![0x1C, 0x1C, 0x1E], "the window surface is the PANEL token in dark");
        assert_eq!(panel(&light), vec![0xF1, 0xF1, 0xF3], "and in light");
    }
}
