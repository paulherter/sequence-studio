//! The error screen: one fixed 520 x 280 pt card with an error tile, a title, `Error <code>`, one sentence, a details
//! well, and the footer `Copy details` / `Open log` (left) and `Close` / a primary button (right). The app shows it when
//! it cannot start; the installer reuses it for its failed job. Design: `design/installer/spec.md` section 6.6
//! (`win-7-error-*.png`).
//!
//! The screen is data ([`ErrorScreen`]) plus the interaction state ([`ErrorView`]). It never touches the GPU, the
//! clipboard or the file manager: `draw` builds a draw list (the software renderer can rasterize it), the pointer and key
//! methods return an [`ErrorAction`] and the host performs it. That keeps it usable when the GPU is the thing that failed.

use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, DrawTheme, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::height;
use sq_uikit::redesign_tokens as rt;
use sq_uikit::sqicon::SQIcon;
use std::path::PathBuf;

/// Content width in points (`rt::size::DIALOG_W_WIDE`).
pub const WINDOW_W: f64 = rt::size::DIALOG_W_WIDE as f64;
/// Content height in points: the same on every screen of the card.
pub const WINDOW_H: f64 = 280.0;
/// How long `Copy details` shows `Copied` before it turns back.
const COPIED_HOLD: f64 = 1.5;
/// How long the answer to `Open log` replaces the log path line.
const LOG_NOTE_HOLD: f64 = 3.0;
/// The crossfade between the two labels of `Copy details`.
const COPIED_FADE: f64 = 0.12;
/// The error tile inside its 40 pt slot (`SlotIcon::Err`, shell_dialog.rs): inset, side, corner, icon, tile fill alpha.
const TILE_INSET: f64 = 3.0;
const TILE_SIDE: f64 = 34.0;
const TILE_RADIUS: f64 = 8.0;
const TILE_ICON: f64 = 20.0;
const TILE_ALPHA: f32 = 0.14;
/// Icon slot and the title column start (`24 + 40 + GUTTER`).
const SLOT: f64 = 40.0;
const TITLE_LINE: f64 = 20.0;
const SUB_LINE: f64 = 17.0;
const TITLE_TOP: f64 = rt::spacing::PAGE as f64;
const SUB_TOP: f64 = 46.0;
/// The body starts 20 below the slot (`24 + 40 + XXL`).
const BODY_TOP: f64 = 84.0;
const SENTENCE_LINE: f64 = 17.0;
const SENTENCE_LINES: usize = 2;
const DETAILS_H: f64 = 52.0;
const DETAILS_LINE: f64 = 16.0;
const FOOT_BOTTOM: f64 = 256.0;
const BUTTON_ICON_GAP: f64 = rt::spacing::SM as f64;

/// What the right-hand primary button is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorPrimary {
    /// `Try Again` (Accent): the job can be run again; `Close` stays raised.
    TryAgain,
    /// `Continue` (Accent): the problem was worked around and the app can go on; `Close` stays raised.
    Continue,
    /// No retry: `Close` becomes the Accent button.
    None,
}

impl ErrorPrimary {
    fn label(self) -> Option<&'static str> {
        match self {
            ErrorPrimary::TryAgain => Some("Try Again"),
            ErrorPrimary::Continue => Some("Continue"),
            ErrorPrimary::None => None,
        }
    }
}

/// Everything the screen shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ErrorScreen {
    /// `Installation failed`, `Sequence Studio couldn't start`.
    pub title: String,
    /// The code alone (`SQS-201`); the sub line reads `Error SQS-201`.
    pub code: String,
    /// One sentence, at most two lines, ending with what state things are in.
    pub sentence: String,
    /// Details line 1: `SQS-201 · <step> <path>`.
    pub step_line: String,
    /// Details line 2: `os error 112 · <system message>`.
    pub system_line: String,
    /// The `Copy details` text: version, system, code and sentence, step, path, system, log.
    pub copy_text: String,
    /// The log `Open log` shows; `None` disables the button.
    pub log: Option<PathBuf>,
    pub primary: ErrorPrimary,
}

/// The four buttons, in Tab order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorPart {
    CopyDetails,
    OpenLog,
    Close,
    Primary,
}

/// What the host does after a click or key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ErrorAction {
    /// Put this text on the clipboard.
    Copy(String),
    /// Open this log file in the default app (not when `SQ_NO_EXTERNAL_OPEN` is set).
    OpenLog(PathBuf),
    /// End the screen without going on.
    Close,
    /// The primary button: try again or continue.
    Primary(ErrorPrimary),
}

/// A key of the screen, mapped by the host from its window system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKey {
    Enter,
    Escape,
    Tab,
    ShiftTab,
    Space,
    /// Ctrl+C (Cmd+C on the Mac).
    Copy,
}

/// What came of `Open log`, reported back by the host so the card can say it (a test run and a failed system open used to
/// leave the click without any sign).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogOpen {
    /// The system took the file.
    Opened,
    /// The system could not open it; `path_copied` says whether the host put the path on the clipboard instead.
    Failed { path_copied: bool },
}

impl LogOpen {
    fn text(self) -> &'static str {
        match self {
            LogOpen::Opened => "Opened",
            LogOpen::Failed { path_copied: true } => "Could not open \u{2014} path copied",
            LogOpen::Failed { path_copied: false } => "Could not open",
        }
    }
}

/// The pointer's relation to the buttons: one value, never two flags.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pointer {
    Away,
    Over(ErrorPart),
    Down(ErrorPart),
}

/// The screen with its interaction state.
pub struct ErrorView {
    screen: ErrorScreen,
    pointer: Pointer,
    /// Keyboard focus: `None` until the first Tab (mouse clicks never show a focus ring).
    focus: Option<ErrorPart>,
    /// When `Copy details` was last used.
    copied_at: Option<f64>,
    /// The last answer to `Open log` and when it came.
    log_note: Option<(LogOpen, f64)>,
    /// The button frames of the last draw, in points: what the pointer hits.
    frames: Vec<(ErrorPart, CGRect)>,
}

impl ErrorView {
    pub fn new(screen: ErrorScreen) -> ErrorView {
        ErrorView { screen, pointer: Pointer::Away, focus: None, copied_at: None, log_note: None, frames: Vec::new() }
    }

    pub fn screen(&self) -> &ErrorScreen {
        &self.screen
    }

    /// The parts that exist on this screen, left to right.
    fn parts(&self) -> Vec<ErrorPart> {
        let mut parts = vec![ErrorPart::CopyDetails, ErrorPart::OpenLog, ErrorPart::Close];
        if self.screen.primary != ErrorPrimary::None {
            parts.push(ErrorPart::Primary);
        }
        parts
    }

    /// The button Enter presses when nothing has the focus: the Accent one.
    fn default_part(&self) -> ErrorPart {
        if self.screen.primary == ErrorPrimary::None { ErrorPart::Close } else { ErrorPart::Primary }
    }

    fn enabled(&self, part: ErrorPart) -> bool {
        part != ErrorPart::OpenLog || self.screen.log.is_some()
    }

    /// How visible `Copied` is: 0 before and after the hold, fading in and out over [`COPIED_FADE`].
    fn copied_level(&self, now: f64) -> f32 {
        let Some(at) = self.copied_at else { return 0.0 };
        let t = now - at;
        if !(0.0..=COPIED_HOLD).contains(&t) {
            return 0.0;
        }
        ((t / COPIED_FADE).min((COPIED_HOLD - t) / COPIED_FADE).clamp(0.0, 1.0)) as f32
    }

    /// Whether the host should keep asking for frames (the `Copied` or the log note hold is running).
    pub fn animating(&self, now: f64) -> bool {
        self.copied_at.is_some_and(|at| now - at <= COPIED_HOLD) || self.log_note(now).is_some()
    }

    /// The host's answer to an `Open log` action: the card says it for a moment.
    pub fn log_opened(&mut self, result: LogOpen, now: f64) {
        self.log_note = Some((result, now));
    }

    /// The answer to `Open log` while it is shown.
    pub fn log_note(&self, now: f64) -> Option<LogOpen> {
        self.log_note.filter(|(_, at)| (0.0..=LOG_NOTE_HOLD).contains(&(now - at))).map(|(result, _)| result)
    }

    /// Where a button is, in points (after the first draw).
    pub fn frame_of(&self, part: ErrorPart) -> Option<CGRect> {
        self.frames.iter().find(|(p, _)| *p == part).map(|(_, r)| *r)
    }

    /// The details well: two lines, and a third with the log's path when there is a log.
    fn details_height(&self) -> f64 {
        if self.screen.log.is_some() { DETAILS_H + DETAILS_LINE } else { DETAILS_H }
    }

    fn part_at(&self, x: f64, y: f64) -> Option<ErrorPart> {
        self.frames
            .iter()
            .find(|(part, r)| self.enabled(*part) && x >= r.min_x() && x < r.max_x() && y >= r.min_y() && y < r.max_y())
            .map(|(part, _)| *part)
    }

    /// The pointer moved to (x, y) points. Returns whether the picture changes.
    pub fn pointer_moved(&mut self, x: f64, y: f64) -> bool {
        let before = self.pointer;
        self.pointer = match (self.pointer, self.part_at(x, y)) {
            (Pointer::Down(held), _) => Pointer::Down(held),
            (_, Some(part)) => Pointer::Over(part),
            (_, None) => Pointer::Away,
        };
        self.pointer != before
    }

    /// The pointer left the window.
    pub fn pointer_left(&mut self) -> bool {
        let changed = self.pointer != Pointer::Away;
        self.pointer = Pointer::Away;
        changed
    }

    /// The primary button went down at (x, y).
    pub fn pointer_down(&mut self, x: f64, y: f64) -> bool {
        self.focus = None;
        match self.part_at(x, y) {
            Some(part) => {
                self.pointer = Pointer::Down(part);
                true
            }
            None => false,
        }
    }

    /// The primary button went up at (x, y): a press that ends on the same button acts.
    pub fn pointer_up(&mut self, x: f64, y: f64, now: f64) -> Option<ErrorAction> {
        let Pointer::Down(held) = self.pointer else { return None };
        let over = self.part_at(x, y);
        self.pointer = over.map_or(Pointer::Away, Pointer::Over);
        (over == Some(held)).then(|| self.activate(held, now)).flatten()
    }

    /// A key; `None` when it does nothing here.
    pub fn key(&mut self, key: ErrorKey, now: f64) -> Option<ErrorAction> {
        match key {
            ErrorKey::Escape => Some(ErrorAction::Close),
            ErrorKey::Copy => self.activate(ErrorPart::CopyDetails, now),
            ErrorKey::Enter => {
                let part = self.focus.unwrap_or_else(|| self.default_part());
                self.activate(part, now)
            }
            ErrorKey::Space => {
                let part = self.focus?;
                self.activate(part, now)
            }
            ErrorKey::Tab | ErrorKey::ShiftTab => {
                let order: Vec<ErrorPart> = self.parts().into_iter().filter(|p| self.enabled(*p)).collect();
                let at = self.focus.and_then(|f| order.iter().position(|p| *p == f));
                let next = match (at, key == ErrorKey::Tab) {
                    (None, true) => 0,
                    (None, false) => order.len().saturating_sub(1),
                    (Some(i), true) => (i + 1) % order.len().max(1),
                    (Some(i), false) => (i + order.len().max(1) - 1) % order.len().max(1),
                };
                self.focus = order.get(next).copied();
                None
            }
        }
    }

    fn activate(&mut self, part: ErrorPart, now: f64) -> Option<ErrorAction> {
        if !self.enabled(part) {
            return None;
        }
        match part {
            ErrorPart::CopyDetails => {
                self.copied_at = Some(now);
                Some(ErrorAction::Copy(self.screen.copy_text.clone()))
            }
            ErrorPart::OpenLog => self.screen.log.clone().map(ErrorAction::OpenLog),
            ErrorPart::Close => Some(ErrorAction::Close),
            ErrorPart::Primary => Some(ErrorAction::Primary(self.screen.primary)),
        }
    }

    /// Draws the whole card into `c` (`WINDOW_W` x `WINDOW_H` points) and remembers the button frames for the pointer.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        let full = CGRect::new(0.0, 0.0, WINDOW_W, WINDOW_H);
        c.fill(full, t.token(rt::color::PANEL));
        self.draw_header(c, t);
        let well_top = self.draw_body(c, t);
        self.draw_details(c, t, well_top, now);
        self.draw_footer(c, t, now);
    }

    fn draw_header(&self, c: &mut Canvas, t: &DrawTheme) {
        let page = f64::from(rt::spacing::PAGE);
        let slot = CGRect::new(page, page, SLOT, SLOT);
        let tile = CGRect::new(slot.min_x() + TILE_INSET, slot.min_y() + TILE_INSET, TILE_SIDE, TILE_SIDE);
        let red = t.err_text();
        c.fill_rounded(tile, TILE_RADIUS, red.with_alpha(TILE_ALPHA));
        let corner = CGPoint::new(tile.mid_x() - TILE_ICON / 2.0, tile.mid_y() - TILE_ICON / 2.0);
        c.draw_icon(SQIcon::AlertCircle, corner, TILE_ICON, red, None);
        let x = page + SLOT + f64::from(rt::spacing::GUTTER);
        let width = WINDOW_W - page - x;
        let semibold = c.semibold();
        let title = c.ellipsized(&self.screen.title, f64::from(rt::type_size::TIMECODE), semibold, width);
        let title_box = CGRect::new(x, TITLE_TOP, width, TITLE_LINE);
        c.draw_text_in(
            &title,
            title_box,
            f64::from(rt::type_size::TIMECODE),
            t.token(rt::color::TEXT),
            TextAlign::Left,
            0.0,
            semibold,
        );
        let sub = format!("Error {}", self.screen.code);
        let sub_box = CGRect::new(x, SUB_TOP, width, SUB_LINE);
        c.draw_text_in(
            &sub,
            sub_box,
            f64::from(rt::type_size::BODY),
            t.token(rt::color::TEXT3),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    /// The sentence (at most two lines, the last one cut with an ellipsis). Returns where the details well starts.
    fn draw_body(&self, c: &mut Canvas, t: &DrawTheme) -> f64 {
        let page = f64::from(rt::spacing::PAGE);
        let width = WINDOW_W - 2.0 * page;
        let size = f64::from(rt::type_size::BODY);
        let mut lines = c.wrap(&self.screen.sentence, width, size);
        if lines.len() > SENTENCE_LINES {
            let rest = lines.split_off(SENTENCE_LINES - 1).join(" ");
            lines.push(c.ellipsized(&rest, size, 0, width));
        }
        for (i, line) in lines.iter().enumerate() {
            let line_box = CGRect::new(page, BODY_TOP + i as f64 * SENTENCE_LINE, width, SENTENCE_LINE);
            c.draw_text_in(line, line_box, size, t.token(rt::color::TEXT2), TextAlign::Left, 0.0, 0);
        }
        BODY_TOP + lines.len().max(1) as f64 * SENTENCE_LINE + f64::from(rt::spacing::LG)
    }

    fn draw_details(&self, c: &mut Canvas, t: &DrawTheme, top: f64, now: f64) {
        let page = f64::from(rt::spacing::PAGE);
        let well = CGRect::new(page, top, WINDOW_W - 2.0 * page, self.details_height());
        c.stone_field(well, f64::from(rt::radius::CONTROL), false, Touch::default(), t);
        let pad = f64::from(rt::spacing::LG);
        let width = well.width - 2.0 * pad;
        let size = f64::from(rt::type_size::SMALL);
        for (i, text) in [&self.screen.step_line, &self.screen.system_line].into_iter().enumerate() {
            let shown = c.ellipsized_middle(text, size, 0, width);
            let line =
                CGRect::new(well.min_x() + pad, well.min_y() + pad + i as f64 * DETAILS_LINE, width, DETAILS_LINE);
            c.draw_text_in(&shown, line, size, t.token(rt::color::TEXT3), TextAlign::Left, 0.0, 0);
        }
        // The log's path, always visible so it can be read and typed even when the system cannot open it; for a moment
        // after `Open log` it gives way to the answer.
        if let Some(log) = &self.screen.log {
            let (text, ink) = match self.log_note(now) {
                Some(note @ LogOpen::Opened) => (note.text().to_string(), t.token(rt::color::TEXT2)),
                Some(note) => (note.text().to_string(), t.err_text()),
                None => (format!("Log: {}", log.display()), t.token(rt::color::TEXT3)),
            };
            let shown = c.ellipsized_middle(&text, size, 0, width);
            let line = CGRect::new(well.min_x() + pad, well.min_y() + pad + 2.0 * DETAILS_LINE, width, DETAILS_LINE);
            c.draw_text_in(&shown, line, size, ink, TextAlign::Left, 0.0, 0);
        }
    }

    fn draw_footer(&mut self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        let page = f64::from(rt::spacing::PAGE);
        let gap = f64::from(rt::spacing::MD);
        let h = f64::from(height::LARGE);
        let y = FOOT_BOTTOM - h;
        let medium = c.medium();
        let size = f64::from(rt::type_size::BODY);
        let text_w = |c: &Canvas, s: &str| c.size_of(s, size, medium).width.ceil();
        let quiet_pad = f64::from(rt::spacing::LG);
        let pad = f64::from(rt::spacing::GUTTER);
        let icon = f64::from(rt::size::ICON);
        let mut frames = Vec::new();
        // Right group, from the right edge: Primary, then Close.
        let mut right = WINDOW_W - page;
        let close_label = "Close";
        if let Some(label) = self.screen.primary.label() {
            let w = text_w(c, label) + 2.0 * pad;
            frames.push((ErrorPart::Primary, CGRect::new(right - w, y, w, h)));
            right -= w + gap;
        }
        let w = text_w(c, close_label) + 2.0 * pad;
        frames.push((ErrorPart::Close, CGRect::new(right - w, y, w, h)));
        // Left group: the first quiet button sits 10 left of the margin so its icon lines up with x 24.
        let widest = text_w(c, "Copy details").max(text_w(c, "Copied"));
        let copy_w = widest + icon + BUTTON_ICON_GAP + 2.0 * quiet_pad;
        let copy = CGRect::new(page - quiet_pad, y, copy_w, h);
        let log_w = text_w(c, "Open log") + icon + BUTTON_ICON_GAP + 2.0 * quiet_pad;
        frames.push((ErrorPart::CopyDetails, copy));
        frames.push((ErrorPart::OpenLog, CGRect::new(copy.max_x() + gap, y, log_w, h)));
        self.frames = frames.clone();
        let level = self.copied_level(now);
        for (part, r) in frames {
            self.draw_button(c, t, part, r, level);
        }
    }

    fn draw_button(&self, c: &mut Canvas, t: &DrawTheme, part: ErrorPart, r: CGRect, copied: f32) {
        let is_primary =
            part == ErrorPart::Primary || (part == ErrorPart::Close && self.screen.primary == ErrorPrimary::None);
        let kind = match part {
            ErrorPart::CopyDetails | ErrorPart::OpenLog => ButtonKind::Quiet,
            _ if is_primary => ButtonKind::Primary,
            _ => ButtonKind::Raised,
        };
        let touch = Touch {
            hovering: self.pointer == Pointer::Over(part) || self.pointer == Pointer::Down(part),
            pressed: self.pointer == Pointer::Down(part),
            disabled: !self.enabled(part),
            focused: self.focus == Some(part),
        };
        let body = c.stone_button(r, kind, touch, t);
        let size = f64::from(rt::type_size::BODY);
        let medium = c.medium();
        let live = if touch.hovering { t.token(rt::color::TEXT) } else { t.token(rt::color::TEXT2) };
        let ink = match kind {
            ButtonKind::Primary => t.primary_button_text(),
            ButtonKind::Quiet => live,
            _ => t.token(rt::color::TEXT),
        };
        let ink = if touch.disabled { ink.with_alpha(ink.a * 0.4) } else { ink };
        match part {
            ErrorPart::CopyDetails => {
                // Both labels are drawn, crossfaded: `Copy details` fades out as `Copied` fades in.
                self.draw_icon_label(c, body, SQIcon::Copy, "Copy details", ink.with_alpha(ink.a * (1.0 - copied)));
                if copied > 0.0 {
                    self.draw_icon_label(c, body, SQIcon::Check, "Copied", ink.with_alpha(ink.a * copied));
                }
            }
            ErrorPart::OpenLog => self.draw_icon_label(c, body, SQIcon::File, "Open log", ink),
            ErrorPart::Close => {
                c.draw_text_in("Close", body, size, ink, TextAlign::Center, 0.0, medium);
            }
            ErrorPart::Primary => {
                if let Some(label) = self.screen.primary.label() {
                    c.draw_text_in(label, body, size, ink, TextAlign::Center, 0.0, medium);
                }
            }
        }
    }

    /// An icon with its label to the right, left aligned inside the button's padding (the quiet buttons).
    fn draw_icon_label(&self, c: &mut Canvas, body: CGRect, icon: SQIcon, label: &str, ink: sq_draw::Color) {
        let size = f64::from(rt::type_size::BODY);
        let icon_size = f64::from(rt::size::ICON);
        let left = body.min_x() + f64::from(rt::spacing::LG);
        c.draw_icon(icon, CGPoint::new(left, (body.mid_y() - icon_size / 2.0).round()), icon_size, ink, None);
        let text_box = CGRect::new(left + icon_size + BUTTON_ICON_GAP, body.y, body.width, body.height);
        c.draw_text_in(label, text_box, size, ink, TextAlign::Left, 0.0, c.medium());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(primary: ErrorPrimary, log: bool) -> ErrorScreen {
        ErrorScreen {
            title: "Sequence Studio couldn't start".into(),
            code: "SQS-201".into(),
            sentence: "No graphics adapter was found.".into(),
            step_line: "SQS-201 · graphics".into(),
            system_line: "no GPU adapter: none".into(),
            copy_text: "Error SQS-201".into(),
            log: log.then(|| PathBuf::from("/tmp/sq.log")),
            primary,
        }
    }

    /// A view whose frames come from a fixed 8 pt per character measure (the draw needs a font atlas, a test does not).
    fn view(primary: ErrorPrimary, log: bool) -> ErrorView {
        let mut v = ErrorView::new(screen(primary, log));
        let h = f64::from(height::LARGE);
        let y = FOOT_BOTTOM - h;
        v.frames = vec![
            (ErrorPart::Primary, CGRect::new(420.0, y, 76.0, h)),
            (ErrorPart::Close, CGRect::new(340.0, y, 72.0, h)),
            (ErrorPart::CopyDetails, CGRect::new(14.0, y, 130.0, h)),
            (ErrorPart::OpenLog, CGRect::new(152.0, y, 100.0, h)),
        ];
        if primary == ErrorPrimary::None {
            v.frames.remove(0);
        }
        v
    }

    #[test]
    fn a_click_on_a_button_acts_when_the_press_ends_on_it() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        assert!(v.pointer_down(450.0, 240.0));
        assert_eq!(v.pointer_up(450.0, 240.0, 0.0), Some(ErrorAction::Primary(ErrorPrimary::TryAgain)));
        assert!(v.pointer_down(350.0, 240.0));
        assert_eq!(v.pointer_up(450.0, 240.0, 0.0), None, "released over another button: nothing");
        assert!(v.pointer_down(200.0, 240.0));
        assert_eq!(v.pointer_up(200.0, 240.0, 0.0), Some(ErrorAction::OpenLog(PathBuf::from("/tmp/sq.log"))));
    }

    #[test]
    fn open_log_is_dead_without_a_log() {
        let mut v = view(ErrorPrimary::TryAgain, false);
        assert!(!v.pointer_down(200.0, 240.0));
        assert_eq!(v.key(ErrorKey::Tab, 0.0), None);
        assert_eq!(v.focus, Some(ErrorPart::CopyDetails));
        v.key(ErrorKey::Tab, 0.0);
        assert_eq!(v.focus, Some(ErrorPart::Close), "Tab skips the disabled Open log");
    }

    #[test]
    fn enter_presses_the_accent_button_and_escape_closes() {
        let mut v = view(ErrorPrimary::Continue, true);
        assert_eq!(v.key(ErrorKey::Enter, 0.0), Some(ErrorAction::Primary(ErrorPrimary::Continue)));
        assert_eq!(v.key(ErrorKey::Escape, 0.0), Some(ErrorAction::Close));
        let mut v = view(ErrorPrimary::None, true);
        assert_eq!(v.key(ErrorKey::Enter, 0.0), Some(ErrorAction::Close), "no retry: Close is the Accent button");
    }

    #[test]
    fn tab_walks_the_buttons_left_to_right_and_space_presses_the_focused_one() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        let order =
            [ErrorPart::CopyDetails, ErrorPart::OpenLog, ErrorPart::Close, ErrorPart::Primary, ErrorPart::CopyDetails];
        for want in order {
            v.key(ErrorKey::Tab, 0.0);
            assert_eq!(v.focus, Some(want));
        }
        v.key(ErrorKey::ShiftTab, 0.0);
        assert_eq!(v.focus, Some(ErrorPart::Primary));
        assert_eq!(v.key(ErrorKey::Space, 0.0), Some(ErrorAction::Primary(ErrorPrimary::TryAgain)));
        let mut idle = view(ErrorPrimary::TryAgain, true);
        assert_eq!(idle.key(ErrorKey::Space, 0.0), None, "Space with no focus does nothing");
    }

    #[test]
    fn a_mouse_press_takes_the_focus_ring_away() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        v.key(ErrorKey::Tab, 0.0);
        v.pointer_down(1.0, 1.0);
        assert_eq!(v.focus, None);
    }

    #[test]
    fn open_log_answers_for_a_moment_and_keeps_the_frames_coming() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        assert_eq!(v.log_note(5.0), None, "nothing before an answer");
        v.log_opened(LogOpen::Opened, 5.0);
        assert_eq!(v.log_note(6.0), Some(LogOpen::Opened));
        assert!(v.animating(6.0), "the host keeps drawing while the note is up");
        assert_eq!(v.log_note(5.0 + LOG_NOTE_HOLD + 0.1), None, "the path line is back");
        v.log_opened(LogOpen::Failed { path_copied: true }, 9.0);
        assert_eq!(LogOpen::Failed { path_copied: true }.text(), "Could not open \u{2014} path copied");
        assert_eq!(LogOpen::Failed { path_copied: false }.text(), "Could not open");
        assert!(!v.animating(9.0 + LOG_NOTE_HOLD + 0.1));
    }

    #[test]
    fn the_well_grows_by_a_line_only_when_there_is_a_log_to_name() {
        assert!(view(ErrorPrimary::None, true).details_height() > view(ErrorPrimary::None, false).details_height());
    }

    #[test]
    fn copy_details_hands_over_the_text_and_shows_copied_for_a_moment() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        assert_eq!(v.key(ErrorKey::Copy, 10.0), Some(ErrorAction::Copy("Error SQS-201".into())));
        assert!(v.copied_level(10.0) < 0.01, "fades in");
        assert!((v.copied_level(10.5) - 1.0).abs() < f32::EPSILON, "fully shown in the hold");
        assert!(v.copied_level(11.45) < 0.5, "fades out at the end");
        assert_eq!(v.copied_level(11.6), 0.0, "back to Copy details");
        assert!(v.animating(11.0) && !v.animating(11.6));
    }

    #[test]
    fn hover_follows_the_pointer_and_clears_when_it_leaves() {
        let mut v = view(ErrorPrimary::TryAgain, true);
        assert!(v.pointer_moved(450.0, 240.0));
        assert_eq!(v.pointer, Pointer::Over(ErrorPart::Primary));
        assert!(!v.pointer_moved(452.0, 241.0), "same button: no change");
        assert!(v.pointer_left());
        assert_eq!(v.pointer, Pointer::Away);
    }
}
