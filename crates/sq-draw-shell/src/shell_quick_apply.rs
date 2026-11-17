// Swift: ShellQuickApply.swift
//! The Quick Apply palette on the shared shell (the Mac `QuickApplyPanel`, Option+Space): a search field on top, the ranked
//! rows below (Recent first on an empty search). Up/Down move, Return applies, Escape or a press outside closes. For a
//! transition with selected clips Return swaps the content for a Start/End question (Left = start, Right = end, Down =
//! both, Return confirms, Escape goes back). The model (`QuickApplyModel`) is the Mac one; this only draws and reports.
//!
//! Mapping: `onChoose` / `onClose` are the queue [`QuickApplyPopup::take_events`]; `canChooseTransitionEnd` is an argument of
//! `handle`; the model's `onChange` is a call of `model_changed` after each model call; `measure` is passed to `draw`.
// The palette moves by dragging its grip strip or its background (the Mac panel `isMovableByWindowBackground`) and keeps
// its spot while it resizes. The spot is not remembered between openings, as in Swift `ShellQuickApply`. While the
// pointer is down the card sits exactly at pointer minus grab offset: no easing, no frame of lag in the model.

use sq_draw::ui_cx::DrawCursor;
use sq_draw::{
    Alignment, Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextFieldControl,
    TextMeasure, UiCx,
};
use sq_editor_session::{QuickApplyItem, QuickApplyModel, QuickApplyModelOutcome, TransitionEnd};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use sq_uikit::localization::SQL10n;

/// What the palette reports to the shell.
#[derive(Clone, Debug, PartialEq)]
pub enum QuickApplyEvent {
    /// The palette closed (Escape, a press outside, or after a choice).
    Close,
    /// The row the user confirmed, with the transition end when one was asked.
    Choose(QuickApplyItem, Option<TransitionEnd>),
}

/// The Quick Apply palette (Swift `QuickApplyPopup`).
pub struct QuickApplyPopup {
    /// The ranked rows and the selection.
    pub model: QuickApplyModel,
    frame: CGRect,
    scroll: usize,
    field: TextFieldControl,
    hover_row: Option<usize>,
    hover_end: Option<usize>,
    window: CGRect,
    events: Vec<QuickApplyEvent>,
    /// Where the user dragged the top-left corner to (`None`: the default spot).
    placed: Option<CGPoint>,
    /// The grab offset inside the card while a drag runs.
    grab: Option<CGPoint>,
    /// The pointer rests on a spot that drags the card (the grip strip or the background).
    over_grip: bool,
}

impl QuickApplyPopup {
    /// The palette's width.
    pub const WIDTH: f64 = 640.0;
    /// The grip strip on top of the card: it shows the grip bar and drags the card.
    const HANDLE_HEIGHT: f64 = 12.0;
    const GRIP_WIDTH: f64 = 36.0;
    const GRIP_THICKNESS: f64 = 4.0;
    const HEADER_HEIGHT: f64 = 52.0;
    const ROW_HEIGHT: f64 = 28.0;
    const MAX_ROWS: usize = 8;
    const ASK_HEIGHT: f64 = 132.0;
    const EMPTY_HEIGHT: f64 = 72.0;
    const PAD: f64 = 14.0;
    const BUTTON_WIDTH: f64 = 100.0;
    const ENDS: [TransitionEnd; 3] = [TransitionEnd::Start, TransitionEnd::Both, TransitionEnd::End];

    /// A palette over `model`.
    pub fn new(model: QuickApplyModel) -> QuickApplyPopup {
        let mut field = TextFieldControl::new("");
        field.alignment = Alignment::Left;
        field.dialog_style = true;
        field.font_size = f64::from(type_size::DISPLAY);
        field.placeholder = SQL10n::string("Apply effect, transition or preset");
        QuickApplyPopup {
            model,
            frame: CGRect::new(0.0, 0.0, 0.0, 0.0),
            scroll: 0,
            field,
            hover_row: None,
            hover_end: None,
            window: CGRect::new(0.0, 0.0, 0.0, 0.0),
            events: Vec::new(),
            placed: None,
            grab: None,
            over_grip: false,
        }
    }

    /// The palette's rectangle in window points.
    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// The index of the first visible row.
    pub fn scroll(&self) -> usize {
        self.scroll
    }

    /// Close and choice reports since the last call.
    pub fn take_events(&mut self) -> Vec<QuickApplyEvent> {
        std::mem::take(&mut self.events)
    }

    /// Opens with the last search selected (typing replaces it, Delete clears it), like the Mac panel.
    pub fn open(&mut self, window: CGRect) {
        self.model.reopen();
        self.field.text = self.model.query().to_string();
        self.field.mouse_down(None, 1);
        self.scroll = 0;
        self.layout(window);
    }

    fn asking(&self) -> Option<&QuickApplyItem> {
        self.model.pending_transition()
    }

    fn visible_rows(&self) -> usize {
        self.model.results().len().saturating_sub(self.scroll).min(Self::MAX_ROWS)
    }

    fn no_results(&self) -> bool {
        self.asking().is_none() && self.model.results().is_empty() && !self.model.query().trim().is_empty()
    }

    fn height(&self) -> f64 {
        if self.asking().is_some() {
            return Self::ASK_HEIGHT;
        }
        let rows = self.model.results().len().min(Self::MAX_ROWS);
        Self::HEADER_HEIGHT
            + if rows > 0 {
                rows as f64 * Self::ROW_HEIGHT + 10.0
            } else if self.no_results() {
                Self::EMPTY_HEIGHT
            } else {
                0.0
            }
    }

    /// Centered, with the top edge 28 % below the window's top (the Mac default spot); the top stays put when it resizes.
    pub fn layout(&mut self, window: CGRect) {
        self.window = window;
        let low = window.min_x() + 8.0;
        let x = (window.mid_x() - Self::WIDTH / 2.0).max(low).min((window.max_x() - Self::WIDTH - 8.0).max(low));
        let default = CGPoint::new(x, window.min_y() + window.height * 0.28);
        let at = self.placed.map_or(default, |p| self.clamped(p, window));
        self.frame = CGRect::new(at.x, at.y, Self::WIDTH, self.height());
    }

    /// `at` kept inside the window with an 8 pt margin (a title strip of the card always stays reachable).
    fn clamped(&self, at: CGPoint, window: CGRect) -> CGPoint {
        let low_x = window.min_x() + 8.0;
        let low_y = window.min_y() + 8.0;
        CGPoint::new(
            at.x.max(low_x).min((window.max_x() - Self::WIDTH - 8.0).max(low_x)),
            at.y.max(low_y).min((window.max_y() - Self::HEADER_HEIGHT - 8.0).max(low_y)),
        )
    }

    /// True when a press at `p` lands on the card's background: not the field, a row or an end button.
    fn is_background(&self, p: CGPoint) -> bool {
        !self.field_rect().contains(p)
            && !(self.scroll..self.scroll + self.visible_rows()).any(|i| self.row_rect(i).contains(p))
            && !(self.asking().is_some() && (0..Self::ENDS.len()).any(|i| self.end_rect(i).contains(p)))
    }

    /// The Swift `model.onChange`: keeps the selected row visible and fits the card to the rows.
    fn model_changed(&mut self) {
        let n = self.model.results().len();
        let i = self.model.selected_index();
        if i < n {
            if i < self.scroll {
                self.scroll = i;
            } else if i >= self.scroll + Self::MAX_ROWS {
                self.scroll = i + 1 - Self::MAX_ROWS;
            }
        } else {
            self.scroll = 0;
        }
        self.scroll = self.scroll.min(n.saturating_sub(Self::MAX_ROWS));
        self.layout(self.window);
    }

    fn field_rect(&self) -> CGRect {
        let top = self.frame.min_y() + Self::HANDLE_HEIGHT + 2.0;
        CGRect::new(self.frame.min_x() + Self::PAD, top, self.frame.width - Self::PAD * 2.0, 32.0)
    }

    /// The grip bar, centered in the strip on top of the card.
    fn grip_rect(&self) -> CGRect {
        CGRect::new(
            self.frame.mid_x() - Self::GRIP_WIDTH / 2.0,
            self.frame.min_y() + (Self::HANDLE_HEIGHT - Self::GRIP_THICKNESS) / 2.0,
            Self::GRIP_WIDTH,
            Self::GRIP_THICKNESS,
        )
    }

    fn row_rect(&self, i: usize) -> CGRect {
        CGRect::new(
            self.frame.min_x() + 6.0,
            self.frame.min_y() + Self::HEADER_HEIGHT + (i - self.scroll) as f64 * Self::ROW_HEIGHT,
            self.frame.width - 12.0,
            Self::ROW_HEIGHT,
        )
    }

    fn end_rect(&self, i: usize) -> CGRect {
        CGRect::new(self.frame.mid_x() - 160.0 + i as f64 * 110.0, self.frame.min_y() + 52.0, Self::BUTTON_WIDTH, 28.0)
    }

    // MARK: Drawing

    /// Draws the palette over the window.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, m: &TextMeasure, cx: &mut UiCx) {
        if self.frame.width <= 0.0 {
            return;
        }
        let r = f64::from(radius::CONTROL);
        c.shadow(self.frame, r, 24.0, 8.0, Color::new(0.0, 0.0, 0.0, 0.4), true);
        c.fill_rounded(self.frame, r, t.overlay());
        c.stroke_rounded(self.frame, r, 1.0, t.separator());
        let grip = self.grip_rect();
        let lit = self.over_grip || self.grab.is_some();
        c.fill_rounded(grip, grip.height / 2.0, if lit { t.label2() } else { t.label3() });
        if let Some(item) = self.asking() {
            c.draw_text_in(
                &format!(
                    "{}: {}",
                    item.title,
                    SQL10n::string("add at the start, the end or both ends of the selected clips")
                ),
                CGRect::new(self.frame.min_x() + 16.0, self.frame.min_y() + 14.0, self.frame.width - 32.0, 20.0),
                f64::from(type_size::TITLE),
                t.label(),
                TextAlign::Center,
                0.0,
                0,
            );
            for (i, end) in Self::ENDS.iter().enumerate() {
                let title = match end {
                    TransitionEnd::Start => "Start",
                    TransitionEnd::End => "End",
                    TransitionEnd::Both => "Both",
                };
                let on = self.model.transition_end() == *end;
                let rect = self.end_rect(i);
                let fill = if on {
                    t.accent_fill()
                } else if self.hover_end == Some(i) {
                    t.fill_hover()
                } else {
                    t.fill()
                };
                c.fill_rounded(rect, r, fill);
                c.draw_text_in(
                    &SQL10n::string(title),
                    rect,
                    f64::from(type_size::BODY),
                    if on { Color::WHITE } else { t.label() },
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            c.draw_text_in(
                &SQL10n::string("Left = start, Right = end, Down = both, Return confirms, Esc goes back"),
                CGRect::new(self.frame.min_x() + 16.0, self.frame.max_y() - 28.0, self.frame.width - 32.0, 16.0),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
            return;
        }
        self.field.draw(c, self.field_rect(), t, true, cx);
        let rows = self.model.results().len().min(Self::MAX_ROWS);
        if rows > 0 || self.no_results() {
            c.fill(
                CGRect::new(self.frame.min_x(), self.frame.min_y() + Self::HEADER_HEIGHT - 1.0, self.frame.width, 1.0),
                t.separator(),
            );
        }
        if self.no_results() {
            let rect = CGRect::new(
                self.frame.min_x(),
                self.frame.min_y() + Self::HEADER_HEIGHT,
                self.frame.width,
                Self::EMPTY_HEIGHT,
            );
            c.draw_text_in(
                &SQL10n::string("No results"),
                CGRect::new(rect.min_x(), rect.min_y() + 12.0, rect.width, 20.0),
                f64::from(type_size::TITLE),
                t.label(),
                TextAlign::Center,
                0.0,
                0,
            );
            c.draw_text_in(
                &SQL10n::string("Try another name, or press Esc to close."),
                CGRect::new(rect.min_x(), rect.min_y() + 34.0, rect.width, 16.0),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
        for i in self.scroll..self.scroll + self.visible_rows() {
            let Some(item) = self.model.results().get(i) else { break };
            let rect = self.row_rect(i);
            let active = i == self.model.selected_index();
            if active {
                c.fill_rounded(rect, f64::from(radius::SMALL), t.accent_fill());
            } else {
                c.fill_rounded_if(rect, f64::from(radius::SMALL), t.fill_hover(), self.hover_row == Some(i));
            }
            let kind = SQL10n::string(if self.model.is_recent_row(item) { "Recent" } else { item.category.as_str() });
            let kind_width = m.width(&kind, f64::from(type_size::BODY), 0);
            c.draw_text_in(
                &item.title,
                CGRect::new(rect.min_x() + 10.0, rect.min_y(), rect.width - kind_width - 40.0, rect.height),
                f64::from(type_size::TITLE),
                if active { Color::WHITE } else { t.label() },
                TextAlign::Left,
                0.0,
                0,
            );
            c.draw_text_in(
                &kind,
                CGRect::new(rect.max_x() - kind_width - 10.0, rect.min_y(), kind_width, rect.height),
                f64::from(type_size::BODY),
                if active { Color::WHITE.with_alpha(0.8) } else { t.label2() },
                TextAlign::Right,
                0.0,
                0,
            );
        }
    }

    // MARK: Events (window points; `scale` converts the event's pixels)

    /// True when the palette took the event (it is modal: a press outside closes it, and it owns the keyboard: the shell
    /// checks the palette's own key before it gets here). `can_choose_end`: a transition
    /// can go to the start or end of selected clips (then Return asks which).
    pub fn handle(&mut self, e: &InputEvent, scale: f32, can_choose_end: bool, cx: &mut UiCx) -> bool {
        let k = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                self.over_grip = self.grab.is_none() && self.frame.contains(p) && self.is_background(p);
                if self.over_grip {
                    cx.hover.request(Some(DrawCursor::OpenHand));
                }
                self.hover_row = if self.asking().is_none() && self.frame.contains(p) {
                    (self.scroll..self.scroll + self.visible_rows()).find(|i| self.row_rect(*i).contains(p))
                } else {
                    None
                };
                self.hover_end = if self.asking().is_some() {
                    (0..Self::ENDS.len()).find(|i| self.end_rect(*i).contains(p))
                } else {
                    None
                };
                true
            }
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                if !self.frame.contains(p) {
                    self.events.push(QuickApplyEvent::Close);
                    return true;
                }
                if self.is_background(p) {
                    self.grab = Some(CGPoint::new(p.x - self.frame.min_x(), p.y - self.frame.min_y()));
                    cx.hover.request(Some(DrawCursor::ClosedHand));
                    return true;
                }
                if self.asking().is_some() {
                    if let Some(i) = (0..Self::ENDS.len()).find(|i| self.end_rect(*i).contains(p)) {
                        self.model.choose_end(Self::ENDS[i]);
                        self.model_changed();
                        self.confirm(can_choose_end);
                    }
                } else if let Some(i) =
                    (self.scroll..self.scroll + self.visible_rows()).find(|i| self.row_rect(*i).contains(p))
                {
                    self.model.select(i);
                    self.model_changed();
                    self.confirm(can_choose_end);
                }
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                if let Some(g) = self.grab {
                    let p = pt(x, y);
                    self.placed = Some(CGPoint::new(p.x - g.x, p.y - g.y));
                    self.layout(self.window);
                    cx.hover.request(Some(DrawCursor::ClosedHand));
                }
                true
            }
            InputEvent::MouseUp { x, y } => {
                if self.grab.take().is_some() {
                    let p = pt(x, y);
                    self.over_grip = self.frame.contains(p) && self.is_background(p);
                    if self.over_grip {
                        cx.hover.request(Some(DrawCursor::OpenHand));
                    }
                }
                true
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                if self.asking().is_some() || !self.frame.contains(pt(x, y)) {
                    return true;
                }
                let rows_per_pixel = 1.0 / Self::ROW_HEIGHT / k;
                let moved = (f64::from(dy) * rows_per_pixel).round() as i64;
                let top = self.model.results().len().saturating_sub(Self::MAX_ROWS) as i64;
                self.scroll = (self.scroll as i64 - moved).clamp(0, top) as usize;
                true
            }
            InputEvent::KeyDown { key, modifiers } => self.handle_key(key, modifiers, can_choose_end, cx),
        }
    }

    fn handle_key(&mut self, key: InputKey, m: InputModifiers, can_choose_end: bool, cx: &mut UiCx) -> bool {
        let asking = self.asking().is_some();
        match key {
            InputKey::Up if !asking => self.model.move_selection(-1),
            InputKey::Down if !asking => self.model.move_selection(1),
            InputKey::Left if asking => self.model.choose_end(TransitionEnd::Start),
            InputKey::Right if asking => self.model.choose_end(TransitionEnd::End),
            InputKey::Down if asking => self.model.choose_end(TransitionEnd::Both),
            InputKey::Enter => {
                self.confirm(can_choose_end);
                return true;
            }
            InputKey::Escape => {
                if asking {
                    self.model.cancel_end_choice();
                } else {
                    self.events.push(QuickApplyEvent::Close);
                    return true;
                }
            }
            _ => {
                // no typing while the question is up
                if asking {
                    return true;
                }
                let _ = self.field.key(key, m, cx);
                let q = self.field.editor().map_or_else(|| self.field.text.clone(), |e| e.string());
                // the field keeps the focus
                if !self.field.is_editing() {
                    self.field.text = q.clone();
                    self.field.mouse_down(None, 1);
                }
                if q != self.model.query() {
                    self.model.set_query(&q);
                }
            }
        }
        self.model_changed();
        true
    }

    fn confirm(&mut self, can_choose_end: bool) {
        match self.model.confirm(can_choose_end) {
            QuickApplyModelOutcome::None => {}
            QuickApplyModelOutcome::AskEnd(_) => self.model_changed(),
            QuickApplyModelOutcome::Apply { item, end } => {
                self.events.push(QuickApplyEvent::Close);
                self.events.push(QuickApplyEvent::Choose(item, end));
            }
        }
    }
}
