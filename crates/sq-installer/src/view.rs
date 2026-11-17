//! Drawing and input of the setup window. `SetupView::draw` paints the model of the machine's screen (header, card or
//! progress, note, footer) with the app's own parts: stone buttons, the sunken well, the checkbox, the playhead head, the
//! app icon and Pip. The error screen is `sq_draw_shell::ErrorView`, shared with the app's start failures. The view never
//! touches the machine: input comes out as [`Output`]s the host feeds back. Spec: `design/installer/spec.md` §4, §5, §8, §9.

use crate::machine::{Button, Event, InstallerScreen, Machine};
use crate::model::{Body, Btn, Model, Note, NoteTone, Row, Slot, Sub, Target, Value, ellipsize_path};
use sq_draw::pointer::{Click, primary_clicks};
use sq_draw::stone::Touch;
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, TextAlign};
use sq_draw_shell::{
    ErrorAction, ErrorKey, ErrorPrimary, ErrorScreen, ErrorView, LogOpen, ShellAppIcon, ShellMascotStage,
};
use sq_setup_engine::SetupError;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::height;
use sq_uikit::redesign_tokens as rt;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmascot_model::SQMascotAnim;
use std::path::PathBuf;

/// Content width in points.
pub const WINDOW_W: f64 = sq_draw_shell::ERROR_SCREEN_W;
/// Content height in points: the same on every screen.
pub const WINDOW_H: f64 = sq_draw_shell::ERROR_SCREEN_H;

const PAGE: f64 = rt::spacing::PAGE as f64;
const SLOT: f64 = 40.0;
const TITLE_X: f64 = PAGE + SLOT + rt::spacing::GUTTER as f64;
const TITLE_LINE: f64 = 20.0;
const SUB_TOP: f64 = 46.0;
const SUB_LINE: f64 = 17.0;
const BODY_TOP: f64 = PAGE + SLOT + rt::spacing::XXL as f64;
const ROW_H: f64 = rt::size::CONTROL as f64 + 2.0 * rt::spacing::MD as f64;
const LABEL_COL: f64 = 72.0;
const VALUE_X: f64 = rt::spacing::GUTTER as f64 + LABEL_COL;
/// The 1 pt ring inside the card's edge.
const RING: f64 = 1.0;
const NOTE_LINE: f64 = 16.0;
const NOTE_LINES: usize = 2;
const NOTE_ICON: f64 = 12.0;
const FOOT_BOTTOM: f64 = 256.0;
const CHECKBOX: f64 = rt::size::ICON as f64;
const TRACK_TOP: f64 = 121.0;
const TRACK_H: f64 = 4.0;
const TRACK_RADIUS: f64 = 2.0;
const PROGRESS_LINE: f64 = 17.0;
const PROGRESS_DETAIL_TOP: f64 = 133.0;
const PLAYHEAD_TOP: f64 = 109.0;
/// The Close button of the Windows window (spec §2): as wide as the app's, as tall as the drag band.
const CLOSE_W: f64 = 46.0;
const CLOSE_H: f64 = 40.0;
const CLOSE_ICON: f64 = 16.0;
/// Out and in of a screen change (`duration::exit(MEDIUM)` and `duration::MEDIUM`), the rise of the new one.
const FADE_OUT: f64 = 0.12;
const FADE_IN: f64 = 0.18;
const RISE: f64 = 4.0;
/// Pip waits this long after the screen came, then plays; he runs this long, then stands still.
const PIP_DELAY: f64 = 0.2;
const PIP_RUN: f64 = 4.0;
/// The drawn progress follows the real one with this time constant (about 0.3 s to settle).
const PROGRESS_TAU: f64 = 0.1;

/// A key the view understands, mapped by the window host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetupKey {
    Enter,
    Escape,
    Tab,
    ShiftTab,
    Space,
    /// Ctrl+C: `Copy details` on the error screen.
    Copy,
}

/// What the host does after input.
#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    Event(Event),
    Copy(String),
    OpenLog(PathBuf),
}

/// What the pointer events of one button change did.
#[derive(Debug, Default)]
pub struct Clicked {
    /// The picture changed.
    pub redraw: bool,
    /// The press landed on the drawn caption, so the window (with its own Close button) moves with it.
    pub drag_window: bool,
    pub outputs: Vec<Output>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Part {
    Target(Target),
    Close,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pointer {
    Away,
    Over(Part),
    Down(Part),
}

/// Which screen is shown, so a change can fade.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shown {
    Welcome,
    Update,
    Confirm,
    Progress,
    Done,
    Uninstalled,
    Error,
}

fn shown_of(screen: &InstallerScreen) -> Shown {
    match screen {
        InstallerScreen::Welcome { .. } => Shown::Welcome,
        InstallerScreen::Update { .. } => Shown::Update,
        InstallerScreen::UninstallConfirm { .. } => Shown::Confirm,
        InstallerScreen::Progress { .. } => Shown::Progress,
        InstallerScreen::Done { .. } => Shown::Done,
        InstallerScreen::Uninstalled { .. } => Shown::Uninstalled,
        InstallerScreen::Error { .. } => Shown::Error,
    }
}

/// The window around the content: Windows draws its own Close button, Linux keeps the window manager's title bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chrome {
    OwnClose,
    System,
}

/// The screen being left, kept for its fade-out.
struct Leaving {
    model: Model,
    since: f64,
    value: f64,
}

/// What the error screen needs to scrub and head its `Copy details` text.
#[derive(Clone, Debug, Default)]
pub struct ErrorContext {
    /// The user's home folders as the system spells them.
    pub homes: Vec<String>,
    /// What replaces them: `%USERPROFILE%` or `~`.
    pub token: String,
}

pub struct SetupView {
    chrome: Chrome,
    context: ErrorContext,
    shown: Option<Shown>,
    since: f64,
    last_model: Option<Model>,
    leaving: Option<Leaving>,
    error: Option<ErrorView>,
    frames: Vec<(Part, CGRect)>,
    pointer: Pointer,
    focus: Option<Target>,
    drawn: f64,
    last_now: f64,
    stage: ShellMascotStage,
}

impl SetupView {
    pub fn new(chrome: Chrome, context: ErrorContext) -> SetupView {
        SetupView {
            chrome,
            context,
            shown: None,
            since: 0.0,
            last_model: None,
            leaving: None,
            error: None,
            frames: Vec::new(),
            pointer: Pointer::Away,
            focus: None,
            drawn: 0.0,
            last_now: 0.0,
            stage: ShellMascotStage::new(),
        }
    }

    /// Whether the host should keep asking for frames.
    pub fn animating(&self, machine: &Machine, now: f64) -> bool {
        let fading = now - self.since < FADE_OUT + FADE_IN || self.leaving.is_some();
        let bar =
            matches!(&machine.screen, InstallerScreen::Progress { value, .. } if (self.drawn - value).abs() > 1e-3);
        let pip = matches!(self.last_model.as_ref().map(|m| m.slot), Some(Slot::Pip(_)))
            && !sq_draw::motion::reduce_motion()
            && now - self.since < PIP_DELAY + PIP_RUN;
        let copied = self.error.as_ref().is_some_and(|e| e.animating(now));
        fading || bar || pip || copied
    }

    fn part_at(&self, x: f64, y: f64) -> Option<Part> {
        self.frames
            .iter()
            .rev()
            .find(|(_, r)| x >= r.min_x() && x < r.max_x() && y >= r.min_y() && y < r.max_y())
            .map(|(p, _)| *p)
    }

    /// The pointer moved to (x, y) points; true when the picture changes.
    pub fn pointer_moved(&mut self, x: f64, y: f64) -> bool {
        if let Some(e) = self.error.as_mut() {
            let moved = e.pointer_moved(x, y);
            return self.close_hover(x, y) || moved;
        }
        let before = self.pointer;
        self.pointer = match (self.pointer, self.part_at(x, y)) {
            (Pointer::Down(held), _) => Pointer::Down(held),
            (_, Some(part)) => Pointer::Over(part),
            (_, None) => Pointer::Away,
        };
        self.pointer != before
    }

    /// Close hover on the error screen (the error view owns its buttons, the Close button is ours).
    fn close_hover(&mut self, x: f64, y: f64) -> bool {
        let before = self.pointer;
        self.pointer = match (self.pointer, self.part_at(x, y)) {
            (Pointer::Down(held), _) => Pointer::Down(held),
            (_, Some(Part::Close)) => Pointer::Over(Part::Close),
            _ => Pointer::Away,
        };
        self.pointer != before
    }

    pub fn pointer_left(&mut self) -> bool {
        let a = self.error.as_mut().is_some_and(ErrorView::pointer_left);
        let b = std::mem::replace(&mut self.pointer, Pointer::Away) != Pointer::Away;
        a || b
    }

    /// The events one button change made in the shared pointer (device pixels) at `scale`: a primary press or release goes
    /// to the view, a secondary click does nothing.
    pub fn clicks(&mut self, events: &[InputEvent], scale: f64, now: f64) -> Clicked {
        let mut done = Clicked::default();
        for click in primary_clicks(events, scale) {
            match click {
                Click::Down { x, y } if self.pointer_down(x, y) => done.redraw = true,
                Click::Down { x, y } => done.drag_window = self.chrome == Chrome::OwnClose && Self::is_caption(x, y),
                Click::Up { x, y } => {
                    done.redraw = true;
                    done.outputs.extend(self.pointer_up(x, y, now));
                }
            }
        }
        done
    }

    /// The host's answer to `Open log`: the error card says it for a moment.
    pub fn log_opened(&mut self, result: LogOpen, now: f64) {
        if let Some(e) = self.error.as_mut() {
            e.log_opened(result, now);
        }
    }

    /// The primary button went down at (x, y) points.
    pub fn pointer_down(&mut self, x: f64, y: f64) -> bool {
        self.focus = None;
        let close = self.part_at(x, y).filter(|p| *p == Part::Close);
        if let Some(e) = self.error.as_mut() {
            let on_error = e.pointer_down(x, y);
            if let Some(part) = close {
                self.pointer = Pointer::Down(part);
                return true;
            }
            return on_error;
        }
        match self.part_at(x, y) {
            Some(part) => {
                self.pointer = Pointer::Down(part);
                true
            }
            None => false,
        }
    }

    /// The button went up: a press that ends on the part it started on acts.
    pub fn pointer_up(&mut self, x: f64, y: f64, now: f64) -> Vec<Output> {
        let down = self.pointer;
        let over = self.part_at(x, y);
        if let Pointer::Down(Part::Close) = down {
            self.pointer = over.map_or(Pointer::Away, Pointer::Over);
            return if over == Some(Part::Close) { vec![Output::Event(Event::Escape)] } else { Vec::new() };
        }
        if let Some(e) = self.error.as_mut() {
            let action = e.pointer_up(x, y, now);
            return action.map(error_output).unwrap_or_default();
        }
        let Pointer::Down(held) = down else { return Vec::new() };
        self.pointer = over.map_or(Pointer::Away, Pointer::Over);
        match (over == Some(held), held) {
            (true, Part::Target(target)) => vec![Output::Event(event_of(target))],
            _ => Vec::new(),
        }
    }

    /// A key; empty when it does nothing here.
    pub fn key(&mut self, key: SetupKey, machine: &Machine, now: f64) -> Vec<Output> {
        if let Some(e) = self.error.as_mut() {
            let mapped = match key {
                SetupKey::Enter => ErrorKey::Enter,
                SetupKey::Escape => ErrorKey::Escape,
                SetupKey::Tab => ErrorKey::Tab,
                SetupKey::ShiftTab => ErrorKey::ShiftTab,
                SetupKey::Space => ErrorKey::Space,
                SetupKey::Copy => ErrorKey::Copy,
            };
            return e.key(mapped, now).map(error_output).unwrap_or_default();
        }
        let order = self.last_model.as_ref().map(Model::tab_order).unwrap_or_default();
        match key {
            SetupKey::Escape => vec![Output::Event(Event::Escape)],
            SetupKey::Copy => Vec::new(),
            SetupKey::Enter => vec![Output::Event(self.focus.map_or(Event::Enter, event_of))],
            SetupKey::Space => self.focus.map(|t| vec![Output::Event(event_of(t))]).unwrap_or_default(),
            SetupKey::Tab | SetupKey::ShiftTab => {
                let at = self.focus.and_then(|f| order.iter().position(|t| *t == f));
                let n = order.len().max(1);
                let next = match (at, key == SetupKey::Tab) {
                    (None, true) => 0,
                    (None, false) => n - 1,
                    (Some(i), true) => (i + 1) % n,
                    (Some(i), false) => (i + n - 1) % n,
                };
                self.focus = order.get(next).copied();
                let _ = machine;
                Vec::new()
            }
        }
    }

    /// Paints the screen into `c` (`WINDOW_W` x `WINDOW_H` points) at `now` seconds.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, machine: &Machine, now: f64) {
        let dt = (now - self.last_now).clamp(0.0, 0.1);
        self.last_now = now;
        c.fill(CGRect::new(0.0, 0.0, WINDOW_W, WINDOW_H), t.token(rt::color::PANEL));
        self.frames.clear();
        let key = shown_of(&machine.screen);
        if let InstallerScreen::Error { job, error, log } = &machine.screen {
            if self.error.is_none() {
                let screen = error_screen(job, error, log.clone(), &machine.facts.system_line, &self.context);
                self.error = Some(ErrorView::new(screen));
                self.focus = None;
            }
        } else {
            self.error = None;
        }
        if let Some(view) = self.error.as_mut() {
            self.shown = Some(key);
            view.draw(c, t, now);
            self.last_model = None;
        } else {
            let model = Model::of(machine);
            if self.shown != Some(key) {
                // A screen change: the old one fades out (it is gone when there was none or when it was the error view).
                self.leaving = self.last_model.take().map(|m| Leaving { model: m, since: now, value: self.drawn });
                self.shown = Some(key);
                self.since = now;
                self.focus = None;
                if let InstallerScreen::Progress { value, .. } = &machine.screen {
                    self.drawn = *value;
                }
            }
            if let Body::Progress { fraction, .. } = &model.body {
                let step = (fraction - self.drawn) * (1.0 - (-dt / PROGRESS_TAU).exp());
                self.drawn = if sq_draw::motion::reduce_motion() {
                    *fraction
                } else {
                    (self.drawn + step.max(0.0)).min(*fraction)
                };
                if (fraction - self.drawn).abs() < 1e-3 {
                    self.drawn = *fraction;
                }
            }
            self.draw_screen(c, t, &model, now);
            self.last_model = Some(model);
        }
        if self.chrome == Chrome::OwnClose {
            self.draw_close(c, t);
        }
    }

    /// The fade of a screen change: the old content out, then the new content in and up.
    fn draw_screen(&mut self, c: &mut Canvas, t: &DrawTheme, model: &Model, now: f64) {
        let reduce = sq_draw::motion::reduce_motion();
        if let Some(leaving) = &self.leaving {
            let p = (now - leaving.since) / FADE_OUT;
            if p < 1.0 {
                let (old, value) = (leaving.model.clone(), leaving.value);
                let start = c.list.quads().len();
                self.draw_content(c, t, &old, now, false, Some(value));
                c.list.transform_from(start, (1.0 - p) as f32, 1.0, (0.0, 0.0));
                return;
            }
            self.leaving = None;
            self.since = now;
        }
        let p = ((now - self.since) / FADE_IN).clamp(0.0, 1.0);
        if p >= 1.0 {
            self.draw_content(c, t, model, now, true, None);
            return;
        }
        let eased = 1.0 - (1.0 - p).powi(3);
        c.save_gstate();
        if !reduce {
            c.translate_by(0.0, RISE * (1.0 - eased));
        }
        let start = c.list.quads().len();
        self.draw_content(c, t, model, now, true, None);
        c.list.transform_from(start, eased as f32, 1.0, (0.0, 0.0));
        c.restore_gstate();
    }

    /// One screen's content. `live` is false for a screen on its way out: it takes no input.
    fn draw_content(&mut self, c: &mut Canvas, t: &DrawTheme, m: &Model, now: f64, live: bool, value: Option<f64>) {
        self.draw_header(c, t, m, now);
        let note_top = match &m.body {
            Body::Card(rows) => self.draw_card(c, t, rows, live),
            Body::Progress { label, detail, .. } => {
                self.draw_progress(c, t, label, detail, value.unwrap_or(self.drawn));
                BODY_TOP
            }
        };
        if let Some(note) = &m.note {
            self.draw_note(c, t, note, note_top);
        }
        self.draw_footer(c, t, m, live);
    }

    fn draw_header(&mut self, c: &mut Canvas, t: &DrawTheme, m: &Model, now: f64) {
        let slot = CGRect::new(PAGE, PAGE, SLOT, SLOT);
        match m.slot {
            Slot::AppIcon => ShellAppIcon::draw(slot, c, false),
            Slot::Warn => draw_tile(c, slot, SQIcon::Warning, t.warning()),
            Slot::Pip(anim) => {
                // Frozen during the delay and after the run: the still pose, and no frames asked for.
                let held = (now - self.since - PIP_DELAY).clamp(0.0, PIP_RUN);
                let clock = if sq_draw::motion::reduce_motion() { 0.0 } else { self.since + held };
                self.stage.draw(anim, pip_slot(anim), clock, slot, c);
            }
        }
        let width = WINDOW_W - PAGE - TITLE_X;
        let semibold = c.semibold();
        let title = c.ellipsized(&m.title, f64::from(rt::type_size::TIMECODE), semibold, width);
        c.draw_text_in(
            &title,
            CGRect::new(TITLE_X, PAGE, width, TITLE_LINE),
            f64::from(rt::type_size::TIMECODE),
            t.token(rt::color::TEXT),
            TextAlign::Left,
            0.0,
            semibold,
        );
        let size = f64::from(rt::type_size::BODY);
        let sub_box = CGRect::new(TITLE_X, SUB_TOP, width, SUB_LINE);
        match &m.sub {
            Sub::Text(text) => {
                c.draw_text_in(text, sub_box, size, t.token(rt::color::TEXT3), TextAlign::Left, 0.0, 0);
            }
            Sub::Versions { old, new } => {
                let gap = f64::from(rt::spacing::SM);
                let arrow = NOTE_ICON;
                let mut x = TITLE_X;
                x += c.draw_text_in(
                    old,
                    CGRect::new(x, SUB_TOP, width, SUB_LINE),
                    size,
                    t.token(rt::color::TEXT3),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                x += gap;
                c.draw_icon(
                    SQIcon::ArrowRight,
                    CGPoint::new(x, (SUB_TOP + SUB_LINE / 2.0 - arrow / 2.0).round()),
                    arrow,
                    t.token(rt::color::TEXT4),
                    None,
                );
                x += arrow + gap;
                c.draw_text_in(
                    new,
                    CGRect::new(x, SUB_TOP, width, SUB_LINE),
                    size,
                    t.token(rt::color::TEXT2),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
    }

    /// The card; returns where the note starts.
    fn draw_card(&mut self, c: &mut Canvas, t: &DrawTheme, rows: &[Row], live: bool) -> f64 {
        let card = CGRect::new(PAGE, BODY_TOP, WINDOW_W - 2.0 * PAGE, rows.len() as f64 * ROW_H);
        let radius = f64::from(rt::radius::CARD);
        c.fill_rounded(card, radius, t.token(rt::color::GROUP));
        c.stroke_rounded(card.inset_by(RING / 2.0, RING / 2.0), radius - RING / 2.0, RING, t.token(rt::color::LINE));
        for (i, row) in rows.iter().enumerate() {
            let top = card.min_y() + i as f64 * ROW_H;
            if i > 0 {
                c.fill(CGRect::new(card.min_x(), top, card.width, 1.0), t.token(rt::color::ROW_LINE));
            }
            self.draw_row(c, t, row, CGRect::new(card.min_x(), top, card.width, ROW_H), live);
        }
        card.max_y() + f64::from(rt::spacing::LG)
    }

    fn draw_row(&mut self, c: &mut Canvas, t: &DrawTheme, row: &Row, r: CGRect, live: bool) {
        let label_box = CGRect::new(r.min_x() + f64::from(rt::spacing::GUTTER), r.min_y(), LABEL_COL, r.height);
        c.draw_text_in(
            row.label,
            label_box,
            f64::from(rt::type_size::SMALL),
            t.token(rt::color::TEXT3),
            TextAlign::Left,
            0.0,
            0,
        );
        let x = r.min_x() + VALUE_X;
        let size = f64::from(rt::type_size::BODY);
        let mut right = r.max_x() - f64::from(rt::spacing::MD);
        if let Some(button) = &row.button {
            let medium = c.medium();
            let pad = f64::from(rt::spacing::LG);
            let w = c.size_of(&button.label, size, medium).width.ceil() + 2.0 * pad;
            let frame = CGRect::new(right - w, r.min_y() + f64::from(rt::spacing::MD), w, f64::from(rt::size::CONTROL));
            self.draw_button(c, t, button, frame, live, true);
            right = frame.min_x() - f64::from(rt::spacing::LG);
        }
        match &row.value {
            Value::Text(text) | Value::Path(text) => {
                let width = (right - x).max(0.0);
                let shown = if matches!(row.value, Value::Path(_)) {
                    let long = ellipsize_path(text, |s| c.size_of(s, size, 0).width <= width);
                    c.ellipsized(&long, size, 0, width)
                } else {
                    c.ellipsized(text, size, 0, width)
                };
                c.draw_text_in(
                    &shown,
                    CGRect::new(x, r.min_y(), width, r.height),
                    size,
                    t.token(rt::color::TEXT),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            Value::Checkbox { check, on, label, suffix } => {
                let target = Part::Target(Target::Check(*check));
                let gap = f64::from(rt::spacing::MD);
                let boxed = CGRect::new(x, r.mid_y() - CHECKBOX / 2.0, CHECKBOX, CHECKBOX);
                let label_w = c.size_of(label, size, 0).width.ceil();
                let hit = CGRect::new(x, r.min_y(), CHECKBOX + gap + label_w, r.height);
                if live {
                    self.frames.push((target, hit));
                }
                let touch = self.touch(target, true);
                c.stone_checkbox(boxed, *on, touch, t);
                c.draw_text_in(
                    label,
                    CGRect::new(boxed.max_x() + gap, r.min_y(), label_w + 2.0, r.height),
                    size,
                    t.token(rt::color::TEXT),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                if let Some(suffix) = suffix {
                    let sx = boxed.max_x() + gap + label_w + gap;
                    c.draw_text_in(
                        suffix,
                        CGRect::new(sx, r.min_y(), (r.max_x() - sx).max(0.0), r.height),
                        size,
                        t.token(rt::color::TEXT3),
                        TextAlign::Left,
                        0.0,
                        0,
                    );
                }
                if self.focus == Some(Target::Check(*check)) && live {
                    c.stone_focus_ring(hit.inset_by(-1.0, 3.0), f64::from(rt::radius::FIELD), t);
                }
            }
        }
    }

    fn draw_note(&mut self, c: &mut Canvas, t: &DrawTheme, note: &Note, top: f64) {
        let size = f64::from(rt::type_size::SMALL);
        let (color, indent) = match note.tone {
            NoteTone::Plain => (t.token(rt::color::TEXT3), 0.0),
            NoteTone::Error => (t.token(rt::color::RED_TEXT), 0.0),
            NoteTone::Caution => (t.token(rt::color::TEXT2), NOTE_ICON + f64::from(rt::spacing::SM)),
        };
        let width = WINDOW_W - 2.0 * PAGE - indent;
        let mut lines = c.wrap(&note.text, width, size);
        if lines.len() > NOTE_LINES {
            let rest = lines.split_off(NOTE_LINES - 1).join(" ");
            lines.push(c.ellipsized(&rest, size, 0, width));
        }
        if note.tone == NoteTone::Caution {
            let y = top + (NOTE_LINE - NOTE_ICON) / 2.0;
            c.draw_icon(SQIcon::Warning, CGPoint::new(PAGE, y.round()), NOTE_ICON, t.token(rt::color::EXP_TEXT), None);
        }
        for (i, line) in lines.iter().enumerate() {
            c.draw_text_in(
                line,
                CGRect::new(PAGE + indent, top + i as f64 * NOTE_LINE, width, NOTE_LINE),
                size,
                color,
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    fn draw_progress(&mut self, c: &mut Canvas, t: &DrawTheme, label: &str, detail: &str, value: f64) {
        let size = f64::from(rt::type_size::BODY);
        let width = WINDOW_W - 2.0 * PAGE;
        let medium = c.medium();
        let percent = format!("{} %", (value * 100.0).floor() as u32);
        let pw = c.size_of(&percent, size, medium).width.ceil() + 2.0;
        c.draw_text_in(
            &c.ellipsized(label, size, 0, width - pw - f64::from(rt::spacing::GUTTER)),
            CGRect::new(PAGE, BODY_TOP, width - pw, PROGRESS_LINE),
            size,
            t.token(rt::color::TEXT),
            TextAlign::Left,
            0.0,
            0,
        );
        c.draw_text_in(
            &percent,
            CGRect::new(PAGE + width - pw, BODY_TOP, pw, PROGRESS_LINE),
            size,
            t.token(rt::color::TEXT2),
            TextAlign::Right,
            0.0,
            medium,
        );
        let track = CGRect::new(PAGE, TRACK_TOP, width, TRACK_H);
        c.stone_field(track, TRACK_RADIUS, false, Touch::default(), t);
        let value = value.clamp(0.0, 1.0);
        if value > 0.0 {
            let fill = CGRect::new(PAGE, TRACK_TOP, (width * value).max(TRACK_H).min(width), TRACK_H);
            c.fill_rounded(fill, TRACK_RADIUS, t.accent());
        }
        let x = PAGE + width * value;
        c.fill(CGRect::new(x - 0.5, TRACK_TOP, 1.0, TRACK_H), t.playhead());
        t.playhead_head(x, PLAYHEAD_TOP).draw(c);
        let small = f64::from(rt::type_size::SMALL);
        c.draw_text_in(
            detail,
            CGRect::new(PAGE, PROGRESS_DETAIL_TOP, width, NOTE_LINE),
            small,
            t.token(rt::color::TEXT3),
            TextAlign::Left,
            0.0,
            0,
        );
    }

    fn draw_footer(&mut self, c: &mut Canvas, t: &DrawTheme, m: &Model, live: bool) {
        let h = f64::from(height::LARGE);
        let y = FOOT_BOTTOM - h;
        let gap = f64::from(rt::spacing::MD);
        let size = f64::from(rt::type_size::BODY);
        let medium = c.medium();
        let pad = f64::from(rt::spacing::GUTTER);
        let quiet_pad = f64::from(rt::spacing::LG);
        let mut right = WINDOW_W - PAGE;
        for b in m.footer_right.iter().rev() {
            let w = c.size_of(&b.label, size, medium).width.ceil() + 2.0 * pad;
            let frame = CGRect::new(right - w, y, w, h);
            self.draw_button(c, t, b, frame, live, false);
            right -= w + gap;
        }
        let mut left = PAGE;
        for b in &m.footer_left {
            let quiet = b.look == crate::model::Look::Quiet;
            let p = if quiet { quiet_pad } else { pad };
            let w = c.size_of(&b.label, size, medium).width.ceil() + 2.0 * p;
            let x = if quiet { left - quiet_pad } else { left };
            let frame = CGRect::new(x, y, w, h);
            self.draw_button(c, t, b, frame, live, false);
            left = frame.max_x() + gap;
        }
    }

    fn touch(&self, part: Part, enabled: bool) -> Touch {
        Touch {
            hovering: self.pointer == Pointer::Over(part) || self.pointer == Pointer::Down(part),
            pressed: self.pointer == Pointer::Down(part),
            disabled: !enabled,
            focused: matches!(part, Part::Target(target) if self.focus == Some(target)),
        }
    }

    fn draw_button(&mut self, c: &mut Canvas, t: &DrawTheme, b: &Btn, frame: CGRect, live: bool, small: bool) {
        let part = Part::Target(Target::Button(b.id));
        if live && b.enabled && !b.loading {
            self.frames.push((part, frame));
        }
        let touch = self.touch(part, b.enabled || b.loading);
        let body = c.stone_button(frame, b.look.kind(), touch, t);
        let _ = small;
        let size = f64::from(rt::type_size::BODY);
        let medium = c.medium();
        let hovering = touch.hovering;
        let ink = match b.look {
            crate::model::Look::Accent | crate::model::Look::Destructive => t.token(rt::color::ON_ACCENT),
            crate::model::Look::Quiet => t.token(if hovering { rt::color::TEXT } else { rt::color::TEXT2 }),
            crate::model::Look::Raised => t.token(rt::color::TEXT),
        };
        let ink = if touch.disabled && !b.loading { ink.with_alpha(ink.a * 0.4) } else { ink };
        match b.look {
            crate::model::Look::Quiet => {
                let text_box =
                    CGRect::new(body.min_x() + f64::from(rt::spacing::LG), body.min_y(), body.width, body.height);
                c.draw_text_in(&b.label, text_box, size, ink, TextAlign::Left, 0.0, medium);
            }
            _ => {
                c.draw_text_in(&b.label, body, size, ink, TextAlign::Center, 0.0, medium);
            }
        }
    }

    fn draw_close(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let r = CGRect::new(WINDOW_W - CLOSE_W, 0.0, CLOSE_W, CLOSE_H);
        self.frames.push((Part::Close, r));
        let pressed = self.pointer == Pointer::Down(Part::Close);
        let active = pressed || (matches!(self.pointer, Pointer::Over(Part::Close)));
        let mut ink = t.label2();
        if active {
            let red = t.red();
            c.fill(r, if pressed { red.lifted(-0.1) } else { red });
            ink = Color::WHITE;
        }
        c.draw_icon(
            SQIcon::Close,
            CGPoint::new((r.mid_x() - CLOSE_ICON / 2.0).round(), (r.mid_y() - CLOSE_ICON / 2.0).round()),
            CLOSE_ICON,
            ink,
            None,
        );
    }

    /// The hit test of the Windows window: the band over the full width minus the Close button drags the window.
    pub fn is_caption(x: f64, y: f64) -> bool {
        (0.0..CLOSE_H).contains(&y) && (0.0..WINDOW_W - CLOSE_W).contains(&x)
    }
}

/// The 34 pt tile of the slot (`SlotIcon::Warn`), as the kit dialog and the error screen draw it.
fn draw_tile(c: &mut Canvas, slot: CGRect, icon: SQIcon, color: Color) {
    const INSET: f64 = 3.0;
    const SIDE: f64 = 34.0;
    const RADIUS: f64 = 8.0;
    const GLYPH: f64 = 20.0;
    const ALPHA: f32 = 0.14;
    let tile = CGRect::new(slot.min_x() + INSET, slot.min_y() + INSET, SIDE, SIDE);
    c.fill_rounded(tile, RADIUS, color.with_alpha(ALPHA));
    c.draw_icon(icon, CGPoint::new(tile.mid_x() - GLYPH / 2.0, tile.mid_y() - GLYPH / 2.0), GLYPH, color, None);
}

fn pip_slot(anim: SQMascotAnim) -> i64 {
    match anim {
        SQMascotAnim::Wink => 1,
        _ => 2,
    }
}

fn event_of(target: Target) -> Event {
    match target {
        Target::Button(b) => Event::Press(b),
        Target::Check(c) => Event::Toggle(c),
    }
}

fn error_output(action: ErrorAction) -> Vec<Output> {
    match action {
        ErrorAction::Copy(text) => vec![Output::Copy(text)],
        ErrorAction::OpenLog(path) => vec![Output::OpenLog(path)],
        ErrorAction::Close => vec![Output::Event(Event::Press(Button::Close))],
        ErrorAction::Primary(ErrorPrimary::TryAgain) => vec![Output::Event(Event::TryAgain)],
        ErrorAction::Primary(ErrorPrimary::Continue | ErrorPrimary::None) => {
            vec![Output::Event(Event::Press(Button::Close))]
        }
    }
}

/// The screen the error view shows for a failed job: title by job, `Error SQI-104`, the sentence with the state of the
/// computer, the two details lines, the `Copy details` text and the log.
pub fn error_screen(
    job: &sq_setup_engine::Job,
    error: &SetupError,
    log: Option<PathBuf>,
    header: &str,
    context: &ErrorContext,
) -> ErrorScreen {
    let scrub = |text: &str| {
        let homes = context.homes.iter().filter(|h| h.chars().count() > 1);
        homes.fold(text.to_string(), |t, h| t.replace(h.as_str(), &context.token))
    };
    let mut lines = vec![
        header.to_string(),
        format!("Error {}: {}", error.code.text(), error.sentence(job)),
        format!("Step: {}", error.step),
    ];
    if let Some(path) = &error.path {
        lines.push(format!("Path: {}", path.display()));
    }
    lines.push(format!("System: {}", error.system));
    if let Some(log) = &log {
        lines.push(format!("Log: {}", log.display()));
    }
    ErrorScreen {
        title: error.title(job).to_string(),
        code: error.code.text(),
        sentence: error.sentence(job),
        step_line: scrub(&error.step_line()),
        system_line: scrub(&error.system),
        copy_text: scrub(&lines.join("\n")) + "\n",
        log,
        primary: if error.code.retryable() { ErrorPrimary::TryAgain } else { ErrorPrimary::None },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machine::Button;
    use winit::event::{ElementState, MouseButton};

    #[test]
    fn a_failed_start_has_its_own_title_the_start_menu_hint_and_no_try_again() {
        let error =
            SetupError::new(sq_setup_engine::ErrorCode::AppNotStarted, "starting Sequence Studio", "os error 5");
        let screen =
            error_screen(&sq_setup_engine::Job::Install, &error, None, "Setup 0.2.0", &ErrorContext::default());
        assert_eq!(screen.title, "Sequence Studio could not start");
        assert_eq!(screen.code, "SQI-109");
        assert!(screen.sentence.ends_with("open it from the Start menu."), "{}", screen.sentence);
        assert_eq!(screen.primary, ErrorPrimary::None);
    }

    /// The window opened under a pointer that has not moved: winit sends the press with no position. The shared pointer
    /// holds it, and it lands on the button under the first position (the setup's own pointer started at (0, 0)).
    #[test]
    fn a_press_before_the_first_pointer_position_lands_on_the_button_under_it() {
        let machine = crate::shots::machine("win-1-welcome").expect("the welcome screen");
        let mut view = SetupView::new(Chrome::OwnClose, ErrorContext::default());
        let scale = 2.0_f32;
        let theme = crate::session::theme(false, scale);
        for now in [0.0, 5.0] {
            let mut canvas = Canvas::with_size(WINDOW_W as f32 * scale, WINDOW_H as f32 * scale, None, scale);
            view.draw(&mut canvas, &theme, &machine, now);
        }
        let install = Part::Target(Target::Button(Button::Install));
        let at = view.frames.iter().find(|(part, _)| *part == install).map(|(_, r)| *r).expect("Install is drawn");
        let none = sq_draw::InputModifiers::NONE;
        let mut pointer = sq_draw::pointer::Pointer::awaiting_position();
        for state in [ElementState::Pressed, ElementState::Released] {
            assert!(pointer.button(state, MouseButton::Left, none).is_empty(), "no position yet: the press waits");
        }
        pointer.moved(at.mid_x() * f64::from(scale), at.mid_y() * f64::from(scale), none);
        let mut outputs = Vec::new();
        for (_, _, events) in pointer.take_queued() {
            outputs.extend(view.clicks(&events, f64::from(scale), 6.0).outputs);
        }
        assert_eq!(outputs, [Output::Event(Event::Press(Button::Install))]);
    }
}
