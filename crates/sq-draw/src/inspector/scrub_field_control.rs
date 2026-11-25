// Swift: ScrubFieldControl.swift
//! The scrub number field of the portable UI: a translation of the uikit `ScrubField` (same `ScrubMath`, same gesture
//! rules, same look). Drag scrubs (Shift x10, Option/Command x0.1), a click types, a double-click types with the whole value selected, Enter
//! commits, Esc cancels typing or returns the open gesture to its start, arrows and the Option-wheel step.
//! Instead of the AppKit callbacks it returns `Event`s the owner applies (EffectControlsModel's begin / set / end).

use super::inspector_controls::{InspectorDraw, InspectorTokens, faded};
use super::text_edit_state::{Outcome, TextEditState};
use super::text_field_control::typographic_minus;
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::glyph_atlas::TextAlign;
use crate::input::{InputKey, InputModifiers};
use crate::stone::Touch;
use crate::theme::DrawTheme;
use crate::ui_cx::DrawCursor;
use crate::ui_cx::UiCx;
use sq_core_model::trim_spaces;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::scrub_math::{ScrubMath, StepBurst, WheelAccumulator};
use sq_uikit::tokens::{radius as rd, type_size};
use std::ops::RangeInclusive;

/// What a scrub field asks its owner to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// A gesture opened (drag, arrow / wheel burst, typed commit, reset): the owner begins one undo step.
    Begin,
    /// A drag value (draw now, apply at display rate).
    Live(f64),
    /// A committed value (arrow, wheel, typed, reset).
    Change(f64),
    /// The gesture closed with this value.
    End(f64),
    /// Esc during a gesture: back to the start value, no undo step.
    Cancel(f64),
}

/// Formats a value for display.
pub type ValueFormatter = Box<dyn Fn(f64) -> String>;
/// Parses typed text to a value.
pub type ValueParser = Box<dyn Fn(&str) -> Option<f64>>;

/// The scrub number field.
pub struct ScrubFieldControl {
    // Configuration (ScrubField's public vars)
    /// The value.
    pub value: f64,
    /// Arrow and drag step.
    pub step: f64,
    /// Allowed range.
    pub range: RangeInclusive<f64>,
    /// Decimal places shown.
    pub decimals: i64,
    /// Unit text.
    pub unit: String,
    /// The reset value (the row's reset arrow).
    pub default_value: Option<f64>,
    /// Whether the field reacts.
    pub is_enabled: bool,
    /// Several values (shows a dash).
    pub is_mixed: bool,
    /// Text starts at the leading edge.
    pub leading_text: bool,
    /// Value text color (`valueTint`); `None` = accent for plain fields, label otherwise.
    pub value_tint: Option<Color>,
    /// Custom display text.
    pub value_formatter: Option<ValueFormatter>,
    /// Custom typed-text parser.
    pub value_parser: Option<ValueParser>,
    /// Draws a leading "-" before a digit as the true minus sign U+2212 (art.html dialogs: "−12 dB"); the typed text stays ASCII.
    pub true_minus: bool,
    /// The pointer is over the field.
    pub hovering: bool,
    /// Draws the sunken box at rest (form and export fields). Off: a panel number is plain text and only shows a field on
    /// hover, while dragging or typing (r8 `#st-editor .num`).
    pub well: bool,
    /// The keyboard (Tab) put focus on the field: the ring shows without typing. A pointer scrub never sets it.
    pub keyboard_focus: bool,

    // State
    is_dragging: bool,
    editor: Option<TextEditState>,
    pressed: bool,
    press_start_x: f32,
    last_x: f32,
    drag_start_value: f64,
    accumulated_dx: f64,
    burst: StepBurst,
    burst_last: f64,
    wheel: WheelAccumulator,
    gesture_start: Option<f64>,
}

impl ScrubFieldControl {
    /// Pixels of travel before a press becomes a drag (ScrubField.dragThreshold, in points times the scale).
    pub const DRAG_THRESHOLD: f32 = 3.0;
    /// Pointer travel for one step (redesign HAUPTFENSTER "Zahl ziehen": 2 px = 1 step, Shift = 10x).
    pub const PX_PER_STEP: f64 = 2.0;
    /// Space between the well's edge and its text (kit `.field` padding).
    pub const PAD: f64 = 8.0;
    /// The least padding a long value squeezes down to.
    pub const PAD_MIN: f64 = 3.0;
    /// Padding of a panel number without a box (r8 `#st-editor .num`).
    pub const FLAT_PAD: f64 = 5.0;
    /// Width of the unit column of a panel number, and the gap before it.
    pub const UNIT_COLUMN: f64 = 13.0;
    const UNIT_GAP: f64 = 1.0;

    /// A field showing `value`.
    pub fn new(value: f64) -> ScrubFieldControl {
        ScrubFieldControl {
            value,
            step: 1.0,
            range: -1_000_000.0..=1_000_000.0,
            decimals: 0,
            unit: String::new(),
            default_value: None,
            is_enabled: true,
            is_mixed: false,
            leading_text: false,
            value_tint: None,
            value_formatter: None,
            value_parser: None,
            true_minus: false,
            hovering: false,
            well: false,
            keyboard_focus: false,
            is_dragging: false,
            editor: None,
            pressed: false,
            press_start_x: 0.0,
            last_x: 0.0,
            drag_start_value: 0.0,
            accumulated_dx: 0.0,
            burst: StepBurst::new(),
            burst_last: 0.0,
            wheel: WheelAccumulator::new(),
            gesture_start: None,
        }
    }

    /// Whether a drag is running.
    pub fn is_dragging(&self) -> bool {
        self.is_dragging
    }
    /// The open editor.
    pub fn editor(&self) -> Option<&TextEditState> {
        self.editor.as_ref()
    }
    /// Whether the editor is open.
    pub fn is_editing(&self) -> bool {
        self.editor.is_some()
    }

    /// The text shown for the value.
    pub fn display_text(&self) -> String {
        let text = match &self.value_formatter {
            Some(f) => f(self.value),
            None => ScrubMath::format(self.value, self.decimals, &self.unit),
        };
        if self.true_minus { typographic_minus(&text) } else { text }
    }

    // Mouse

    /// `x` in pixels of the host; `click_count` from the host's click counter.
    pub fn mouse_down(&mut self, x: f32, click_count: i64) -> Vec<Event> {
        if !self.is_enabled {
            return vec![];
        }
        let out = self.end_step_burst();
        if self.is_editing() {
            // A press in the open field keeps it open (the caret stays); a double click selects the whole value to retype
            // it (HAUPTFENSTER H11). Leaving the field (another press, Tab, Enter) commits.
            if click_count == 2
                && let Some(e) = &mut self.editor
            {
                e.select_all();
            }
            return out;
        }
        self.press_start_x = x;
        self.last_x = x;
        self.pressed = true;
        if click_count == 2 {
            // Double-click = type, the whole value selected; Reset stays on the row's arrow and its menu.
            self.pressed = false;
            self.begin_editing();
            if let Some(e) = &mut self.editor {
                e.select_all();
            }
            return out;
        }
        self.drag_start_value = self.value;
        self.accumulated_dx = 0.0;
        out
    }

    /// `scale`: device pixels per point (the Mac scrubs per point).
    pub fn mouse_dragged(&mut self, x: f32, modifiers: InputModifiers, scale: f32, cx: &mut UiCx) -> Vec<Event> {
        if !self.pressed {
            return vec![];
        }
        let mut out = vec![];
        if !self.is_dragging {
            // The threshold only decides when the drag starts: the travel counts from the press point, so the pixels
            // moved before the threshold are not lost (`last_x` stays at the press until the drag begins).
            if (x - self.press_start_x).abs() < Self::DRAG_THRESHOLD * scale {
                return vec![];
            }
            self.is_dragging = true;
            self.gesture_start = Some(self.drag_start_value);
            self.accumulated_dx = 0.0;
            out.push(Event::Begin);
            cx.requests.pointer_lock = true; // the Mac ScrubField hides and pins the pointer while scrubbing
        }
        self.accumulated_dx += ((x - self.last_x) / scale) as f64;
        self.last_x = x;
        let v = ScrubMath::value(
            self.drag_start_value,
            self.accumulated_dx / Self::PX_PER_STEP,
            self.step,
            modifiers.contains(InputModifiers::SHIFT),
            modifiers.contains(InputModifiers::OPTION) || modifiers.contains(InputModifiers::COMMAND),
            &self.range,
        );
        if v != self.value {
            self.value = v;
            out.push(Event::Live(v));
        }
        out
    }

    /// The button went up.
    pub fn mouse_up(&mut self, cx: &mut UiCx) -> Vec<Event> {
        if !self.pressed {
            return vec![];
        }
        self.pressed = false;
        if self.is_dragging {
            self.is_dragging = false;
            cx.requests.pointer_lock = false;
            self.gesture_start = None;
            return vec![Event::End(self.value)];
        }
        self.begin_editing();
        vec![]
    }

    // Keys

    /// A key press.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, now: f64, cx: &mut UiCx) -> Vec<Event> {
        if let Some(e) = self.editor.as_mut() {
            return match e.handle(k, modifiers, cx) {
                Outcome::Commit => self.commit_editing(),
                Outcome::Cancel => {
                    self.editor = None;
                    vec![]
                }
                _ => vec![],
            };
        }
        let shift = modifiers.contains(InputModifiers::SHIFT);
        let option = modifiers.contains(InputModifiers::OPTION) || modifiers.contains(InputModifiers::COMMAND);
        match k {
            InputKey::Left | InputKey::Down => {
                let v = ScrubMath::stepped(self.value, -1, self.step, shift, option, &self.range);
                self.burst_apply(v, now)
            }
            InputKey::Right | InputKey::Up => {
                let v = ScrubMath::stepped(self.value, 1, self.step, shift, option, &self.range);
                self.burst_apply(v, now)
            }
            InputKey::Enter => {
                self.begin_editing();
                vec![]
            }
            InputKey::Escape => self.cancel_gesture(cx),
            _ => vec![],
        }
    }

    /// `key`, and whether the field used the key. A focused field that is not being typed in keeps only its own keys
    /// (the arrows, Enter, Esc); a shortcut such as Cmd+S or any other key goes on to the app, so a value that was
    /// typed and committed with Enter never swallows the save that follows.
    pub fn key_used(&mut self, k: InputKey, modifiers: InputModifiers, now: f64, cx: &mut UiCx) -> (Vec<Event>, bool) {
        let was_editing = self.is_editing();
        let events = self.key(k, modifiers, now, cx);
        let own = matches!(
            k,
            InputKey::Left | InputKey::Right | InputKey::Up | InputKey::Down | InputKey::Enter | InputKey::Escape
        );
        let used = was_editing || self.is_editing() || !events.is_empty() || own;
        (events, used)
    }

    /// The Mac ends a burst on key-up or after `StepBurst::IDLE` without a press; the host calls this every frame.
    pub fn tick(&mut self, now: f64) -> Vec<Event> {
        if !self.burst.is_open() || now - self.burst_last < StepBurst::IDLE {
            return vec![];
        }
        self.end_step_burst()
    }

    /// True when the wheel event belongs to this field.
    /// A host gesture (`cx.gesture`) wins over `delta` / `precise`: the Mac ScrubField reads the raw
    /// `scrollingDelta` (Shift turns a wheel sideways) and the device kind; a pinch is no wheel.
    pub fn scroll(
        &mut self,
        delta: f64,
        precise: bool,
        modifiers: InputModifiers,
        focused: bool,
        now: f64,
        cx: &UiCx,
    ) -> (bool, Vec<Event>) {
        let (mut delta, mut precise) = (delta, precise);
        if let Some(g) = cx.gesture {
            if !g.is_scroll() {
                return (false, vec![]);
            }
            delta = ScrubMath::wheel_delta(g.delta_x, g.delta_y);
            precise = g.precise;
        }
        if !self.is_enabled
            || self.is_editing()
            || self.is_dragging
            || !ScrubMath::wheel_accepts(modifiers.contains(InputModifiers::OPTION), self.hovering, focused)
        {
            return (false, vec![]);
        }
        let n = self.wheel.add(delta, precise);
        if n == 0 {
            return (true, vec![]);
        }
        let v = ScrubMath::wheel_value(
            self.value,
            n,
            self.step,
            modifiers.contains(InputModifiers::SHIFT),
            modifiers.contains(InputModifiers::COMMAND),
            &self.range,
        );
        (true, self.burst_apply(v, now))
    }

    fn burst_apply(&mut self, v: f64, now: f64) -> Vec<Event> {
        if v == self.value {
            return vec![];
        }
        let mut out = vec![];
        if self.burst.step() {
            self.gesture_start = Some(self.value);
            out.push(Event::Begin);
        }
        self.burst_last = now;
        self.value = v;
        out.push(Event::Change(v));
        out
    }

    /// Closes an arrow or wheel burst.
    pub fn end_step_burst(&mut self) -> Vec<Event> {
        self.wheel.reset();
        if !self.burst.end() {
            return vec![];
        }
        self.gesture_start = None;
        vec![Event::End(self.value)]
    }

    /// Esc: closes the editor without committing, or returns an open drag / burst to its start.
    pub fn cancel_gesture(&mut self, cx: &mut UiCx) -> Vec<Event> {
        if self.is_editing() {
            self.editor = None;
            return vec![];
        }
        let Some(start) = self.gesture_start else { return vec![] };
        if self.is_dragging {
            self.is_dragging = false;
            self.pressed = false;
            cx.requests.pointer_lock = false;
        } else {
            self.wheel.reset();
            if !self.burst.end() {
                self.gesture_start = None;
                return vec![];
            }
        }
        self.gesture_start = None;
        self.value = start;
        vec![Event::Cancel(start)]
    }

    /// Back to the default value (the row's reset arrow).
    pub fn reset_to_default(&mut self) -> Vec<Event> {
        let mut out = self.end_step_burst();
        let Some(v) = ScrubMath::reset_target(self.value, self.default_value, &self.range) else { return out };
        self.value = v;
        out.extend([Event::Begin, Event::Change(v), Event::End(v)]);
        out
    }

    // Typing

    /// Opens the editor.
    pub fn begin_editing(&mut self) {
        if self.editor.is_some() || !self.is_enabled {
            return;
        }
        let text = if self.is_mixed {
            String::new()
        } else {
            match &self.value_formatter {
                Some(f) => f(self.value),
                None => ScrubMath::format(self.value, self.decimals, ""),
            }
        };
        self.editor = Some(TextEditState::new(&text));
    }

    /// Commits the typed text: simple maths (`+10`, `*2`) unless a parser is set; invalid text keeps the old value.
    pub fn commit_editing(&mut self) -> Vec<Event> {
        let Some(e) = self.editor.take() else { return vec![] };
        let text = e.string();
        if self.is_mixed && trim_spaces(&text, false).is_empty() {
            return vec![];
        }
        let parsed = match &self.value_parser {
            Some(p) => p(&text),
            None => ScrubMath::evaluate(
                &text,
                &self.unit,
                if self.is_mixed { 0.0 } else { self.value },
                *self.range.start() < 0.0,
            ),
        };
        let Some(v) = parsed else { return vec![] };
        let clamped = ScrubMath::clamp(v, &self.range);
        if clamped == self.value && !self.is_mixed {
            return vec![];
        }
        self.value = clamped;
        vec![Event::Begin, Event::Change(clamped), Event::End(clamped)]
    }

    /// Focus moved away (a click elsewhere, Tab): commit typing, close a drag or burst.
    pub fn resign_focus(&mut self, cx: &mut UiCx) -> Vec<Event> {
        let mut out = self.end_step_burst();
        if self.is_editing() {
            out.extend(self.commit_editing());
        }
        if self.is_dragging {
            self.is_dragging = false;
            self.pressed = false;
            self.gesture_start = None;
            out.push(Event::End(self.value));
            cx.requests.pointer_lock = false;
        }
        out
    }

    // Drawing (ScrubField.draw)

    /// The focus ring shows while the field takes keys (typing). A field the pointer only scrubbed stays the owner of the
    /// wheel and arrow keys (`focused`) but shows no ring: the ring is for keyboard focus (PRUEF-LIN-3 D4).
    pub fn shows_focus_ring(&self, focused: bool) -> bool {
        focused && (self.is_editing() || self.keyboard_focus)
    }

    /// The pointer shape over the field: the I-beam while typing, else the horizontal drag arrows (the field scrubs).
    pub fn cursor(&self) -> Option<DrawCursor> {
        if !self.is_enabled {
            None
        } else if self.is_editing() {
            Some(DrawCursor::IBeam)
        } else {
            Some(DrawCursor::ResizeLeftRight)
        }
    }

    /// Draws the field in `bounds`. A field with `well` rests as a sunken well (kit `.field`: fill and edge at rest, a
    /// stronger edge on hover, the accent ring while typing). A panel number rests as plain text: the `surface-well` fill
    /// shows on hover, and the focus ring while it is dragged or typed in.
    pub fn draw(&self, c: &mut Canvas, bounds: CGRect, t: &DrawTheme, focused: bool, cx: &mut UiCx) {
        let boxed = Self::box_in(bounds);
        let dim = if self.is_enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        let ring = self.shows_focus_ring(focused);
        if self.well {
            let touch =
                Touch { hovering: self.hovering && !ring, pressed: false, disabled: !self.is_enabled, focused: ring };
            c.stone_field(boxed, f64::from(rd::FIELD), self.is_editing(), touch, t);
        } else {
            self.draw_flat_body(c, boxed, t, ring);
        }
        if self.hovering {
            cx.hover.request(self.cursor());
        }
        let value_color = self.value_tint.unwrap_or_else(|| t.label());
        let size = type_size::BODY as f64;
        if let Some(e) = &self.editor {
            InspectorDraw::edit_text(c, e, boxed.inset_by(Self::PAD, 0.0), size, t.label(), !self.leading_text, t, cx);
            return;
        }
        if self.is_mixed {
            let (align, inset) =
                if self.leading_text { (TextAlign::Left, Self::PAD) } else { (TextAlign::Right, Self::PAD) };
            c.draw_text_in("\u{2013}", boxed, size, t.label3(), align, inset, 0);
            return;
        }
        let (value_text, unit_text) = self.shown_text();
        let (line, unit) = if self.well {
            Self::place(c, boxed, &value_text, &unit_text, self.leading_text)
        } else {
            Self::place_flat(c, boxed, &value_text, &unit_text, self.leading_text)
        };
        // A value wider than the well starts at the left pad (the sign stays) and is cut at the well's right pad, never run
        // into the next field.
        c.save_gstate();
        c.clip_to(boxed.inset_by(Self::PAD_MIN, 0.0));
        c.draw_text_in(&value_text, line, size, faded(value_color, dim), TextAlign::Left, 0.0, 0);
        if let Some(r) = unit {
            c.draw_text_in(&unit_text, r, size, faded(t.label2(), dim), TextAlign::Left, 0.0, 0);
        }
        c.restore_gstate();
    }

    /// The body of a panel number: nothing at rest, the `surface-well` fill on hover, the ring while dragged or typed in.
    fn draw_flat_body(&self, c: &mut Canvas, boxed: CGRect, t: &DrawTheme, ring: bool) {
        let hot = self.is_enabled && (self.is_dragging || self.is_editing());
        let shown = self.is_enabled && (self.hovering || hot);
        c.stone_flat_field(boxed, f64::from(rd::FIELD), shown, hot || ring, t);
    }

    /// The number and its unit as drawn: the unit muted after the number (board `.hv` / `.un`), empty when there is none.
    /// A custom formatter (Rotation's turns, "1x 30.0 °") that ends in the unit splits the same way, so every unit,
    /// degrees included, is drawn as the number and the unit column.
    fn shown_text(&self) -> (String, String) {
        let value_text = self.display_text();
        if !self.unit.is_empty() && value_text.ends_with(&self.unit) {
            let keep = value_text.chars().count() - self.unit.chars().count();
            let number = trim_spaces(&value_text.chars().take(keep).collect::<String>(), false).to_string();
            return (number, self.unit.clone());
        }
        if self.leading_text {
            let trimmed = value_text.trim_start_matches(' ');
            if let Some((a, b)) = trimmed.split_once(' ').filter(|(_, b)| !b.is_empty())
                && a.replace(',', ".").parse::<f64>().is_ok()
                && b.parse::<f64>().is_err()
            {
                return (a.to_string(), b.to_string());
            }
        }
        (value_text, String::new())
    }

    /// Where the number and the unit go inside the well `boxed`. The padding gives way before a long value ("-1080.0",
    /// "100.0 %") is cut, so both texts always stay inside the well.
    pub fn place(c: &mut Canvas, boxed: CGRect, value: &str, unit: &str, leading: bool) -> (CGRect, Option<CGRect>) {
        let size = type_size::BODY as f64;
        let vw = c.size_of(value, size, 0).width;
        let gap = c.size_of(" ", size, 0).width; // the unit sits a space after the number, muted ("0.0 °", kit)
        let uw = if unit.is_empty() { 0.0 } else { c.size_of(unit, size, 0).width + gap };
        let pad = Self::PAD.min(((boxed.width - vw - uw) / 2.0).max(Self::PAD_MIN));
        let x0 = if leading { boxed.min_x() + pad } else { (boxed.max_x() - pad - vw - uw).max(boxed.min_x() + pad) };
        let line = CGRect::new(x0, boxed.min_y(), vw, boxed.height);
        let unit = (!unit.is_empty()).then(|| CGRect::new(x0 + vw + gap, boxed.min_y(), uw - gap, boxed.height));
        (line, unit)
    }

    /// Where the number and the unit go in a panel number: padding 5, the value right-aligned against a unit column 13
    /// wide (kept free when the field has a unit, so the numbers of a column line up).
    /// The unit column is at least `UNIT_COLUMN` and grows to the measured unit ("px" is wider than 13 pt): a unit rect
    /// narrower than its text made the draw cut it to "…" ("0 px" showed "0…").
    pub fn place_flat(
        c: &mut Canvas,
        boxed: CGRect,
        value: &str,
        unit: &str,
        leading: bool,
    ) -> (CGRect, Option<CGRect>) {
        let size = type_size::BODY as f64;
        let has_unit = !unit.is_empty();
        let vw = c.size_of(value, size, 0).width.ceil();
        let measured = if has_unit { c.size_of(unit, size, 0).width.ceil() } else { 0.0 };
        let mut unit_w = if has_unit { Self::UNIT_COLUMN.max(measured) } else { 0.0 };
        let mut pad = Self::FLAT_PAD;
        // A wide value ("100.0 %" in the 50 pt field) first gives back the unit column's slack, then the side padding, so the
        // value never runs into the unit ("100.0%" touched).
        if has_unit && boxed.width < 2.0 * pad + vw + Self::UNIT_GAP + unit_w {
            unit_w = measured;
            pad = ((boxed.width - vw - Self::UNIT_GAP - unit_w) / 2.0).clamp(Self::PAD_MIN, Self::FLAT_PAD);
        }
        let column = if has_unit { unit_w + Self::UNIT_GAP } else { 0.0 };
        let right = boxed.max_x() - pad - column;
        let x0 = if leading { boxed.min_x() + pad } else { (right - vw).max(boxed.min_x() + pad) };
        let line = CGRect::new(x0, boxed.min_y(), vw, boxed.height);
        let unit = has_unit.then(|| {
            CGRect::new((right + Self::UNIT_GAP).max(x0 + vw + Self::UNIT_GAP), boxed.min_y(), unit_w, boxed.height)
        });
        (line, unit)
    }

    /// The well of a field drawn in `bounds`: capsule height, centered in the row (so every row's fields share one height).
    pub fn box_in(bounds: CGRect) -> CGRect {
        let h = (InspectorTokens::CAPSULE as f64).min(bounds.height);
        CGRect::new(bounds.min_x(), bounds.min_y() + ((bounds.height - h) / 2.0).round(), bounds.width, h)
    }
}

/// Counts clicks like the Mac's `clickCount`: a press within `INTERVAL` seconds and `SLOP` pixels of the last one adds one.
#[derive(Clone, Copy, Debug)]
pub struct ClickCounter {
    last_time: f64,
    last_x: f32,
    last_y: f32,
    count: i64,
}

impl Default for ClickCounter {
    fn default() -> Self {
        ClickCounter { last_time: -1.0, last_x: 0.0, last_y: 0.0, count: 0 }
    }
}

impl ClickCounter {
    /// Longest gap between two presses of one click series.
    pub const INTERVAL: f64 = 0.5;
    /// Furthest the pointer may move between them.
    pub const SLOP: f32 = 4.0;

    /// A counter with no history.
    pub fn new() -> ClickCounter {
        ClickCounter::default()
    }

    /// A press at (`x`, `y`); returns its click count.
    pub fn press(&mut self, x: f32, y: f32, now: f64) -> i64 {
        if self.last_time >= 0.0
            && now - self.last_time <= Self::INTERVAL
            && (x - self.last_x).abs() <= Self::SLOP
            && (y - self.last_y).abs() <= Self::SLOP
        {
            self.count += 1;
        } else {
            self.count = 1;
        }
        self.last_time = now;
        self.last_x = x;
        self.last_y = y;
        self.count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NO: InputModifiers = InputModifiers::NONE;

    /// Every number and unit of a Controls field sits inside its well, also the widest values of the grid's 50 pt field.
    #[test]
    fn numbers_and_units_stay_inside_the_well() {
        let mut c = Canvas::with_size(200.0, 40.0, None, 1.0);
        let bounds = CGRect::new(10.0, 4.0, 50.0, 24.0);
        for (value, unit, decimals) in [
            (-1080.0, "", 1),
            (100.0, "%", 1),
            (-400.0, "px", 1),
            (359.9, "\u{b0}", 1),
            (0.0, "", 1),
            (1920.0, "px", 0),
        ] {
            let mut f = ScrubFieldControl::new(value);
            f.decimals = decimals;
            f.unit = unit.to_string();
            let boxed = ScrubFieldControl::box_in(bounds);
            let (v, u) = f.shown_text();
            let (line, unit_rect) = ScrubFieldControl::place(&mut c, boxed, &v, &u, false);
            for r in std::iter::once(line).chain(unit_rect) {
                assert!(
                    r.min_x() >= boxed.min_x() && r.max_x() <= boxed.max_x(),
                    "{value} {unit}: text {r:?} leaves the well {boxed:?}"
                );
            }
            assert_eq!(boxed.height, InspectorTokens::CAPSULE as f64, "every field well has the one capsule height");
        }
    }

    /// "0 px" showed "0…". Every unit kind of the inspector (px, %, deg, s, dB, frames) and the widest short
    /// values fit the default 50 pt column whole: value and unit rects hold their text and stay inside the field.
    #[test]
    fn short_numbers_with_every_unit_kind_fit_the_default_column_whole() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = crate::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let mut c = Canvas::with_size(200.0, 40.0, Some(&atlas), 1.0);
        let size = type_size::BODY as f64;
        let boxed =
            ScrubFieldControl::box_in(CGRect::new(10.0, 4.0, sq_uikit::controls_grid::tokens::VALUE_WIDTH, 24.0));
        for (v, u) in [
            ("0", "px"),
            ("100", "%"),
            ("-180", "\u{b0}"),
            ("0.0", "s"),
            ("-12", "dB"),
            ("24", "f"),
            ("-100", "px"),
            ("360", "\u{b0}"),
        ] {
            let (line, unit) = ScrubFieldControl::place_flat(&mut c, boxed, v, u, false);
            let unit = unit.expect("unit rect");
            assert!(c.size_of(v, size, 0).width <= line.width, "{v}: value rect cuts the text");
            assert!(c.size_of(u, size, 0).width <= unit.width, "{u}: unit rect cuts the text");
            assert!(line.min_x() >= boxed.min_x() && unit.max_x() <= boxed.max_x(), "{v} {u} leaves the field");
            assert!(line.max_x() <= unit.min_x(), "{v} {u}: value runs into the unit");
        }
    }

    /// Tilt and Rotation are both degrees: the number and the muted degree sign are drawn the same way, whether the text
    /// comes from the plain format or from Rotation's turns formatter ("0.0°" next to "0.0 °").
    #[test]
    fn every_degree_value_splits_into_number_and_unit_the_same_way() {
        let mut tilt = ScrubFieldControl::new(0.0);
        tilt.decimals = 1;
        tilt.unit = "\u{b0}".to_string();
        let mut rotation = ScrubFieldControl::new(0.0);
        rotation.unit = "\u{b0}".to_string();
        rotation.value_formatter = Some(Box::new(sq_uikit::rotation_text::format));
        assert_eq!(tilt.shown_text(), ("0.0".to_string(), "\u{b0}".to_string()));
        assert_eq!(rotation.shown_text(), tilt.shown_text());
        rotation.value = 390.0;
        assert_eq!(rotation.shown_text(), ("1x 30.0".to_string(), "\u{b0}".to_string()));
    }

    /// The unit never touches the value ("100.0%"): at least `UNIT_GAP` between their rects, for every unit kind,
    /// also for the widest short value in the default field.
    #[test]
    fn value_and_unit_never_touch_for_px_percent_degree_and_db() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = crate::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let mut c = Canvas::with_size(200.0, 40.0, Some(&atlas), 1.0);
        let boxed =
            ScrubFieldControl::box_in(CGRect::new(10.0, 4.0, sq_uikit::controls_grid::tokens::VALUE_WIDTH, 24.0));
        for (v, u) in [
            ("100.0", "%"),
            ("38.0", "%"),
            ("-100.0", "px"),
            ("0", "px"),
            ("-180.0", "\u{b0}"),
            ("-12.0", "dB"),
            ("100.0", "dB"),
        ] {
            let (line, unit) = ScrubFieldControl::place_flat(&mut c, boxed, v, u, false);
            let unit = unit.expect("unit rect");
            assert!(
                unit.min_x() - line.max_x() >= ScrubFieldControl::UNIT_GAP,
                "{v} {u}: gap {}",
                unit.min_x() - line.max_x()
            );
        }
    }

    /// The narrowest field of a pair (`ControlsGrid::MIN_FIELD`) holds the widest angle text of the Inspector, "-180.0 °",
    /// whole: number, gap, unit and the minimum side padding all inside the well.
    #[test]
    fn the_narrowest_field_holds_a_negative_angle_with_its_unit() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = crate::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let mut c = Canvas::with_size(200.0, 40.0, Some(&atlas), 1.0);
        let size = type_size::BODY as f64;
        let needed = c.size_of("-180.0", size, 0).width.ceil()
            + ScrubFieldControl::UNIT_GAP
            + c.size_of("\u{b0}", size, 0).width.ceil()
            + 2.0 * ScrubFieldControl::PAD_MIN;
        let w = sq_uikit::controls_grid::ControlsGrid::MIN_FIELD;
        assert!(w >= needed, "MIN_FIELD {w} < needed {needed}");
        let boxed = ScrubFieldControl::box_in(CGRect::new(10.0, 4.0, w, 24.0));
        let (line, unit) = ScrubFieldControl::place_flat(&mut c, boxed, "-180.0", "\u{b0}", false);
        let unit = unit.expect("unit rect");
        assert!(line.min_x() >= boxed.min_x() + ScrubFieldControl::PAD_MIN - 0.01, "sign cut: {line:?} in {boxed:?}");
        assert!(unit.max_x() <= boxed.max_x() - ScrubFieldControl::PAD_MIN + 0.01, "unit cut: {unit:?} in {boxed:?}");
    }

    /// A value far wider than the well starts at the left pad, so its sign stays visible; the draw clips it to the well.
    #[test]
    fn a_huge_negative_value_keeps_its_sign_and_is_cut_at_the_well() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let atlas = crate::GlyphAtlas::inter(&root).expect("bundled Inter loads");
        let mut c = Canvas::with_size(200.0, 40.0, Some(&atlas), 1.0);
        let boxed = ScrubFieldControl::box_in(CGRect::new(10.0, 4.0, 50.0, 24.0));
        let (line, _) = ScrubFieldControl::place(&mut c, boxed, "-9876543210.2", "", false);
        assert_eq!(line.min_x(), boxed.min_x() + ScrubFieldControl::PAD_MIN);
        assert!(line.max_x() > boxed.max_x(), "the test value must overflow the well");
    }

    /// A panel number rests as plain text (no quad at all), shows the well on hover and the ring while dragged;
    /// a form field (`well`) keeps its box at rest.
    #[test]
    fn a_panel_number_draws_no_well_at_rest_and_one_on_hover() {
        let t = DrawTheme::default();
        let bounds = CGRect::new(4.0, 2.0, 60.0, 24.0);
        let quads = |f: &ScrubFieldControl| {
            let mut c = Canvas::with_size(80.0, 30.0, None, 1.0);
            let mut cx = UiCx::new();
            f.draw(&mut c, bounds, &t, false, &mut cx);
            c.list.quads().len()
        };
        let mut f = ScrubFieldControl::new(5.0);
        assert_eq!(quads(&f), 0, "rest draws no body");
        f.hovering = true;
        let hover = quads(&f);
        assert!(hover >= 1, "hover draws the well");
        f.hovering = false;
        f.begin_editing();
        assert!(quads(&f) > hover, "typing adds the ring to the well");
        let mut boxed = ScrubFieldControl::new(5.0);
        boxed.well = true;
        assert!(quads(&boxed) >= 1, "a form field keeps its box at rest");
    }

    #[test]
    fn a_resting_field_asks_for_the_drag_cursor_and_a_typing_one_for_the_text_cursor() {
        let mut f = ScrubFieldControl::new(1.0);
        assert_eq!(f.cursor(), Some(DrawCursor::ResizeLeftRight));
        f.is_enabled = false;
        assert_eq!(f.cursor(), None);
    }

    #[test]
    fn drag_scrubs_with_modifiers_and_ends_once() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(10.0);
        f.step = 1.0;
        assert!(f.mouse_down(100.0, 1).is_empty());
        assert!(f.mouse_dragged(101.0, NO, 1.0, &mut cx).is_empty());
        let ev = f.mouse_dragged(110.0, NO, 1.0, &mut cx);
        assert_eq!(ev.first(), Some(&Event::Begin));
        let base = f.value;
        f.mouse_dragged(111.0, InputModifiers::SHIFT, 1.0, &mut cx);
        assert!(f.value > base);
        assert_eq!(f.mouse_up(&mut cx), vec![Event::End(f.value)]);
        assert!(!f.is_editing());
    }

    /// The host pins the pointer while a field scrubs, from the drag's start to its end, cancel or focus loss.
    #[test]
    fn scrub_drag_requests_pointer_lock_until_it_ends() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(10.0);
        f.mouse_down(100.0, 1);
        f.mouse_dragged(101.0, NO, 1.0, &mut cx);
        assert!(!cx.requests.pointer_lock);
        f.mouse_dragged(110.0, NO, 1.0, &mut cx);
        assert!(cx.requests.pointer_lock);
        f.mouse_up(&mut cx);
        assert!(!cx.requests.pointer_lock);
        f.mouse_down(0.0, 1);
        f.mouse_dragged(20.0, NO, 1.0, &mut cx);
        assert!(cx.requests.pointer_lock);
        f.key(InputKey::Escape, NO, 0.0, &mut cx);
        assert!(!cx.requests.pointer_lock);
        f.mouse_down(0.0, 1);
        f.mouse_dragged(20.0, NO, 1.0, &mut cx);
        f.resign_focus(&mut cx);
        assert!(!cx.requests.pointer_lock);
    }

    #[test]
    fn a_field_that_is_not_typed_in_passes_shortcuts_on() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(10.0);
        f.begin_editing();
        for ch in ['4', '0'] {
            assert!(f.key_used(InputKey::Character(ch), NO, 0.0, &mut cx).1, "typing is the field's");
        }
        let (events, used) = f.key_used(InputKey::Enter, NO, 0.0, &mut cx);
        assert!(used && !events.is_empty() && !f.is_editing(), "Enter commits");
        let cmd = InputModifiers::COMMAND;
        assert!(!f.key_used(InputKey::Character('s'), cmd, 0.0, &mut cx).1, "Cmd+S is the app's");
        assert!(!f.key_used(InputKey::Character('1'), NO, 0.0, &mut cx).1, "a stray character is not the field's");
        assert!(f.key_used(InputKey::Up, NO, 0.0, &mut cx).1, "an arrow steps the field");
    }

    #[test]
    fn click_types_and_enter_commits_math() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(10.0);
        f.mouse_down(0.0, 1);
        assert!(f.mouse_up(&mut cx).is_empty());
        assert!(f.is_editing());
        for ch in "*2".chars() {
            f.key(InputKey::Character(ch), NO, 0.0, &mut cx);
        }
        // A leading operator applies to the current value (ScrubMath::evaluate).
        assert_eq!(f.key(InputKey::Enter, NO, 0.0, &mut cx), vec![Event::Begin, Event::Change(20.0), Event::End(20.0)]);
        f.begin_editing();
        for ch in "abc".chars() {
            f.key(InputKey::Character(ch), NO, 0.0, &mut cx);
        }
        assert!(f.key(InputKey::Enter, NO, 0.0, &mut cx).is_empty());
        assert!(f.value == 20.0 && !f.is_editing());
    }

    /// Every numeric field of the app (Color sliders, Inspector rows, Export sizes, Settings numbers) is this control: a
    /// typed value commits as one gesture (Begin, Change, End) on Enter, Tab and focus loss, and Esc reverts.
    #[test]
    fn a_typed_value_commits_the_same_way_in_every_field_family() {
        // (range, decimals, start, typed text, committed value)
        let families = [
            (-100.0..=100.0, 0, 0.0, "40", 40.0),       // Color Temperature
            (-5.0..=5.0, 2, 0.0, "1", 1.0),             // Color Exposure
            (0.0..=100.0, 1, 100.0, "50", 50.0),        // Inspector Opacity
            (16.0..=8192.0, 0, 1920.0, "1280", 1280.0), // Export width
            (1.0..=100.0, 0, 50.0, "75", 75.0),         // Settings number
            (0.0..=100.0, 0, 10.0, "500", 100.0),       // clamped to the range
        ];
        for (range, decimals, start, text, want) in families {
            for end in ["enter", "tab", "focus loss", "escape"] {
                let mut cx = UiCx::new();
                let mut f = ScrubFieldControl::new(start);
                f.range = range.clone();
                f.decimals = decimals;
                f.begin_editing();
                for ch in text.chars() {
                    f.key(InputKey::Character(ch), NO, 0.0, &mut cx);
                }
                let events = match end {
                    "enter" => f.key(InputKey::Enter, NO, 0.0, &mut cx),
                    "tab" | "focus loss" => f.resign_focus(&mut cx),
                    _ => f.key(InputKey::Escape, NO, 0.0, &mut cx),
                };
                let label = format!("{range:?} typed {text}, {end}");
                if end == "escape" {
                    assert!(events.is_empty() && f.value == start && !f.is_editing(), "{label}");
                } else {
                    assert_eq!(events, vec![Event::Begin, Event::Change(want), Event::End(want)], "{label}");
                    assert!(f.value == want && !f.is_editing(), "{label}");
                }
            }
        }
    }

    #[test]
    fn escape_returns_a_drag_to_its_start() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(5.0);
        f.mouse_down(0.0, 1);
        f.mouse_dragged(20.0, NO, 1.0, &mut cx);
        assert_ne!(f.value, 5.0);
        assert_eq!(f.key(InputKey::Escape, NO, 0.0, &mut cx), vec![Event::Cancel(5.0)]);
        assert!(f.value == 5.0 && !f.is_dragging());
    }

    #[test]
    fn shift_drag_steps_ten_times_per_two_pixels() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(0.0);
        f.step = 1.0;
        f.mouse_down(100.0, 1);
        f.mouse_dragged(104.0, InputModifiers::SHIFT, 1.0, &mut cx);
        assert_eq!(f.value, 20.0);
    }

    #[test]
    fn double_click_types_with_the_whole_value_selected_and_never_resets() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(50.0);
        f.default_value = Some(100.0);
        assert!(f.mouse_down(0.0, 2).is_empty(), "no value change");
        assert!(f.is_editing());
        assert!(f.editor().is_some_and(|e| e.selection() == (0..e.text().len())), "the whole value is selected");
        assert_eq!(f.value, 50.0);
        // The second click of a series on an open field selects everything again after a caret move.
        f.mouse_down(0.0, 1);
        f.mouse_up(&mut cx);
        f.mouse_down(0.0, 2);
        assert!(f.editor().is_some_and(|e| e.selection() == (0..e.text().len())));
        assert!(f.is_editing());
        // Typing replaces the value; Reset still works through the row's arrow.
        assert_eq!(f.reset_to_default(), vec![Event::Begin, Event::Change(100.0), Event::End(100.0)]);
    }

    #[test]
    fn a_press_in_the_open_field_keeps_it_open_and_typing_replaces_the_value() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(20.0);
        f.mouse_down(0.0, 1);
        f.mouse_up(&mut cx);
        assert_eq!(f.mouse_down(0.0, 1), vec![], "a second single press does not commit");
        f.mouse_up(&mut cx);
        assert!(f.is_editing());
        cx.typed_text = Some("7".into());
        f.key(InputKey::Character('7'), InputModifiers::NONE, 0.0, &mut cx);
        cx.typed_text = None;
        let events = f.key(InputKey::Enter, InputModifiers::NONE, 0.0, &mut cx);
        assert_eq!(events, vec![Event::Begin, Event::Change(7.0), Event::End(7.0)]);
    }

    #[test]
    fn arrow_burst_is_one_gesture_until_idle() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(0.0);
        assert_eq!(f.key(InputKey::Up, NO, 0.0, &mut cx), vec![Event::Begin, Event::Change(1.0)]);
        assert_eq!(f.key(InputKey::Up, InputModifiers::SHIFT, 0.1, &mut cx), vec![Event::Change(11.0)]);
        assert!(f.tick(0.3).is_empty());
        assert_eq!(f.tick(0.7), vec![Event::End(11.0)]);
    }

    #[test]
    fn option_wheel_steps_only_when_hovered_or_focused() {
        let cx = UiCx::new();
        let mut f = ScrubFieldControl::new(0.0);
        assert!(!f.scroll(1.0, false, InputModifiers::OPTION, false, 0.0, &cx).0);
        f.hovering = true;
        let r = f.scroll(1.0, false, InputModifiers::OPTION, false, 0.0, &cx);
        assert!(r.0 && r.1 == vec![Event::Begin, Event::Change(1.0)]);
        assert!(!f.scroll(1.0, false, NO, false, 0.0, &cx).0);
    }

    #[test]
    fn click_counter_counts_nearby_quick_presses() {
        let mut k = ClickCounter::new();
        assert_eq!(k.press(0.0, 0.0, 0.0), 1);
        assert_eq!(k.press(1.0, 1.0, 0.2), 2);
        assert_eq!(k.press(30.0, 1.0, 0.3), 1);
        assert_eq!(k.press(30.0, 1.0, 1.5), 1);
    }

    /// PRUEF-LIN-3 D4: a drag that ends leaves the field focused for the wheel but without a ring; typing shows it.
    #[test]
    fn no_focus_ring_after_a_mouse_drag_only_while_typing() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(0.0);
        f.mouse_down(100.0, 1);
        for n in 1..=12 {
            f.mouse_dragged(100.0 + n as f32, NO, 1.0, &mut cx);
        }
        f.mouse_up(&mut cx);
        assert!(!f.is_editing() && !f.shows_focus_ring(true), "a finished drag shows no ring");
        f.begin_editing();
        assert!(f.shows_focus_ring(true), "typing shows the ring");
        assert!(!f.shows_focus_ring(false), "an unfocused field never does");
        let mut k = ScrubFieldControl::new(100.0);
        assert!(!k.shows_focus_ring(true), "a field that merely owns the wheel shows no ring");
        k.keyboard_focus = true;
        assert!(k.shows_focus_ring(true), "keyboard focus shows the ring without typing");
    }

    /// PRUEF-LIN-3 D2: real pointers move in 1 px events; 20 px right are +10 steps (not +9), Shift +100.
    #[test]
    fn a_drag_in_one_pixel_moves_counts_from_the_press_point() {
        for scale in [1.0_f32, 2.0] {
            for (shift, want) in [(NO, 10.0), (InputModifiers::SHIFT, 100.0)] {
                let mut cx = UiCx::new();
                let mut f = ScrubFieldControl::new(0.0);
                f.mouse_down(100.0, 1);
                for n in 1..=20 {
                    f.mouse_dragged(100.0 + n as f32 * scale, shift, scale, &mut cx);
                }
                assert_eq!(f.value, want, "scale {scale}, shift {}", shift == InputModifiers::SHIFT);
            }
        }
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(0.0);
        f.mouse_down(100.0, 1);
        for n in 1..=10 {
            f.mouse_dragged(100.0 - n as f32, NO, 1.0, &mut cx);
        }
        assert_eq!(f.value, -5.0, "10 px left");
    }

    /// Gestures (w71): the value is the pointer at every move, Esc restores, no smoothing.
    #[test]
    fn a_scrub_follows_the_pointer_at_every_move_and_escape_restores() {
        let mut cx = UiCx::new();
        let mut f = ScrubFieldControl::new(10.0);
        f.mouse_down(100.0, 1);
        f.mouse_dragged(104.0, NO, 1.0, &mut cx); // crosses the threshold with its own travel
        assert_eq!(f.value, 12.0, "2 px are one step");
        for n in 5..=30 {
            let before = f.value;
            let ev = f.mouse_dragged(100.0 + n as f32, NO, 1.0, &mut cx);
            assert_eq!(f.value, 10.0 + (n as f64 / 2.0).round(), "move {n}");
            let want = if f.value == before { vec![] } else { vec![Event::Live(f.value)] };
            assert_eq!(ev, want, "a live value only when a step was crossed");
        }
        // Back past the start: still the pointer, in both directions.
        f.mouse_dragged(90.0, NO, 1.0, &mut cx);
        assert_eq!(f.value, 5.0);
        assert_eq!(f.cancel_gesture(&mut cx), vec![Event::Cancel(10.0)]);
        assert_eq!(f.value, 10.0);
        assert!(f.mouse_dragged(120.0, NO, 1.0, &mut cx).is_empty(), "after Esc the drag is over");
    }
}
