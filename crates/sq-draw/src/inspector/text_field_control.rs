// Swift: TextFieldControl.swift
//! The SQ text field (SQTextField, sq.css `.fld`) on the canvas, plus the quiet button and progress bar.

use super::inspector_controls::{InspectorDraw, InspectorTokens, faded};
use super::text_edit_state::{Outcome, TextEditState};
use crate::canvas::Canvas;
use crate::glyph_atlas::TextAlign;
use crate::input::{InputKey, InputModifiers};
use crate::stone::{ButtonKind, Touch};
use crate::theme::{self, DrawTheme};
use crate::ui_cx::UiCx;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::redesign_tokens::color as tk;
use sq_uikit::redesign_tokens::radius as rd;

/// Tab arrives as the character "\t" (no own case, so the hosts' exhaustive key switches stay valid): it moves focus
/// to the next field, Shift+Tab to the previous one.
pub const TAB: InputKey = InputKey::Character('\t');

/// "-12 dB" drawn as "−12 dB": a hyphen that starts the text or follows a space and precedes a digit becomes U+2212.
pub fn typographic_minus(s: &str) -> String {
    if !s.contains('-') {
        return s.to_string();
    }
    let mut out = String::new();
    let mut prev: Option<char> = None;
    let chars: Vec<char> = s.chars().collect();
    for (i, &ch) in chars.iter().enumerate() {
        if ch == '-' && (prev.is_none() || prev == Some(' ')) && i + 1 < chars.len() && chars[i + 1].is_numeric() {
            out.push('\u{2212}');
        } else {
            out.push(ch);
        }
        prev = Some(ch);
    }
    out
}

/// Where the text sits in a field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    /// Leading.
    Left,
    /// Centered.
    Center,
    /// Trailing.
    Right,
}

impl Alignment {
    /// The draw list's text alignment.
    pub fn list_align(self) -> TextAlign {
        match self {
            Alignment::Left => TextAlign::Left,
            Alignment::Center => TextAlign::Center,
            Alignment::Right => TextAlign::Right,
        }
    }
}

/// The SQ text field: a 22 pt capsule with the `field` fill, the text centered or leading; a click opens the editor with
/// everything selected, Enter or a click elsewhere commits, Esc cancels.
#[derive(Clone, Debug, PartialEq)]
pub struct TextFieldControl {
    /// The committed text.
    pub text: String,
    /// Text alignment.
    pub alignment: Alignment,
    /// Font size in points.
    pub font_size: f64,
    /// Whether the field reacts.
    pub is_enabled: bool,
    /// The dialog field (`SQDialog.makeField`): the whole 28 pt row, 6 pt corners, no hairline (inspector fields are 22 pt capsules).
    pub dialog_style: bool,
    /// Draws "-" before a digit as the true minus sign (dialogs, art.html).
    pub true_minus: bool,
    /// The pointer is over the field.
    pub hovering: bool,
    /// The quiet search field (`SQSearchField`): the `fill2` body (0.06 ink) and no hairline.
    pub quiet: bool,
    /// Draws only the text: the host paints the field body and focus ring (Start and Shortcuts search rows).
    pub bare: bool,
    /// Text inset from the frame's side: 6, or 8 for a dialog field whose frame bleeds 2 pt past its alignment rect.
    pub text_inset: f64,
    /// Gray text in the empty field (the Mac placeholder string).
    pub placeholder: String,
    editor: Option<TextEditState>,
}

impl TextFieldControl {
    /// A field showing `text`.
    pub fn new(text: &str) -> TextFieldControl {
        TextFieldControl {
            text: text.to_string(),
            alignment: Alignment::Center,
            font_size: theme::type_size::CAPTION as f64,
            is_enabled: true,
            dialog_style: false,
            true_minus: false,
            hovering: false,
            quiet: false,
            bare: false,
            text_inset: 6.0,
            placeholder: String::new(),
            editor: None,
        }
    }

    /// The open editor.
    pub fn editor(&self) -> Option<&TextEditState> {
        self.editor.as_ref()
    }
    /// Whether the editor is open.
    pub fn is_editing(&self) -> bool {
        self.editor.is_some()
    }

    /// A press: opens the editor (all selected); a press inside an open editor places the caret.
    /// `click_count`: a double click selects the word under the caret, a triple click everything (the Mac field editor).
    pub fn mouse_down(&mut self, caret: Option<usize>, click_count: i64) {
        if !self.is_enabled {
            return;
        }
        if self.editor.is_none() {
            self.editor = Some(TextEditState::new(&self.text));
            return;
        }
        let (Some(caret), Some(e)) = (caret, self.editor.as_mut()) else { return };
        e.place(caret, false);
        if click_count == 2 {
            e.select_word(caret);
        } else if click_count >= 3 {
            e.select_all();
        }
    }

    /// The pointer moved with the button down inside the open editor: the selection runs from the press to `caret` (the Mac
    /// field editor). `from` is the caret index of the press when the editor opened with that same press (all selected).
    pub fn mouse_dragged(&mut self, caret: usize, from: Option<usize>) {
        let Some(e) = self.editor.as_mut() else { return };
        if let Some(start) = from {
            e.place(start, false);
        }
        e.place(caret, true);
    }

    /// A key while editing. Returns the committed text on Enter (and on Tab, which the caller also uses to move focus).
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> Option<String> {
        let e = self.editor.as_mut()?;
        if k == TAB {
            return self.commit();
        }
        match e.handle(k, modifiers, cx) {
            Outcome::Commit => self.commit(),
            Outcome::Cancel => {
                self.editor = None;
                None
            }
            _ => None,
        }
    }

    /// Ends editing and hands out the typed text (`None` when nothing was open).
    pub fn commit(&mut self) -> Option<String> {
        let e = self.editor.take()?;
        self.text = e.string();
        Some(self.text.clone())
    }

    /// Closes the editor without committing.
    pub fn cancel(&mut self) {
        self.editor = None;
    }

    /// The capsule `draw` puts in `bounds`.
    pub fn boxed(bounds: CGRect) -> CGRect {
        let h = (InspectorTokens::CAPSULE as f64).min(bounds.height);
        CGRect::new(bounds.min_x(), bounds.min_y() + ((bounds.height - h) / 2.0).round(), bounds.width, h)
    }

    /// Where `draw` puts the text inside `bounds`.
    pub fn text_rect(bounds: CGRect) -> CGRect {
        Self::boxed(bounds).inset_by(6.0, 0.0)
    }

    /// The caret index under `x` for a press inside the open editor drawn in `bounds` (`None` while closed): pass it to
    /// `mouse_down`.
    pub fn caret_index(&self, c: &Canvas, x: f64, bounds: CGRect) -> Option<usize> {
        let e = self.editor.as_ref()?;
        let area = if self.dialog_style { bounds } else { Self::boxed(bounds) };
        Some(InspectorDraw::caret_index(
            c,
            e,
            x,
            area.inset_by(self.text_inset, 0.0),
            self.font_size,
            self.alignment == Alignment::Right,
        ))
    }

    /// Draws the field in `bounds`.
    pub fn draw(&self, c: &mut Canvas, bounds: CGRect, t: &DrawTheme, focused: bool, cx: &mut UiCx) {
        let boxed = if self.dialog_style { bounds } else { Self::boxed(bounds) };
        let dim = if self.is_enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        // Number fields are radius `field` (3), form and search fields radius `control` (4) (specs 02-icon-buttons-fields).
        let radius = f64::from(if self.dialog_style { rd::CONTROL } else { rd::FIELD });
        if !self.bare {
            if self.quiet {
                c.fill_rounded(boxed, radius, faded(t.ink_fill(0.06), dim));
            } else {
                let touch = Touch { hovering: self.hovering, pressed: false, disabled: !self.is_enabled, focused };
                c.stone_field(boxed, radius, self.is_editing(), touch, t);
            }
            if self.quiet && self.hovering && self.is_enabled && !self.is_editing() {
                c.stroke_rounded(boxed.inset_by(0.5, 0.5), radius - 0.5, 1.0, t.field_edge_hover());
            }
            if self.quiet && (focused || self.is_editing()) {
                InspectorDraw::focus_line(c, boxed, radius, t);
            }
        }
        let inner = (if self.dialog_style { bounds } else { Self::boxed(bounds) }).inset_by(self.text_inset, 0.0);
        // `setQuietPlaceholder` / `placeholderString`: label3 while the field (or its open editor) is empty.
        let current = self.editor.as_ref().map(|e| e.string()).unwrap_or_else(|| self.text.clone());
        if !self.placeholder.is_empty() && current.is_empty() {
            c.draw_text_in(
                &self.placeholder,
                inner,
                self.font_size,
                faded(t.label3(), dim),
                self.alignment.list_align(),
                0.0,
                0,
            );
        }
        if let Some(e) = &self.editor {
            InspectorDraw::edit_text(c, e, inner, self.font_size, t.label(), self.alignment == Alignment::Right, t, cx);
            return;
        }
        let shown = if self.true_minus { typographic_minus(&self.text) } else { self.text.clone() };
        c.draw_text_in(&shown, inner, self.font_size, faded(t.label(), dim), self.alignment.list_align(), 0.0, 0);
    }
}

impl InspectorDraw {
    /// SQButton's padding.
    pub const BUTTON_PADDING: f64 = 11.0;

    /// The button's natural width for `title` (SQButton.intrinsicContentSize).
    pub fn button_width(c: &Canvas, title: &str) -> f64 {
        (c.size_of(title, theme::type_size::BODY as f64, 0).width + Self::BUTTON_PADDING * 2.0).ceil()
    }

    /// SQButton's quiet look: `fill` body (hover `fillHover`, pressed `fillPressed`), 11 pt padding, `label` title;
    /// `accent` = the one filled blue variant.
    #[allow(clippy::too_many_arguments)]
    pub fn button(
        c: &mut Canvas,
        title: &str,
        rect: CGRect,
        hovering: bool,
        pressed: bool,
        enabled: bool,
        accent: bool,
        height: f64,
        t: &DrawTheme,
    ) {
        Self::button_kind(
            c,
            title,
            rect,
            hovering,
            pressed,
            enabled,
            if accent { ButtonKind::Accent } else { ButtonKind::Raised },
            height,
            t,
        );
    }

    /// `button` with an explicit stone kind (`OnViewer` for a button on the black viewer).
    #[allow(clippy::too_many_arguments)]
    pub fn button_kind(
        c: &mut Canvas,
        title: &str,
        rect: CGRect,
        hovering: bool,
        pressed: bool,
        enabled: bool,
        kind: ButtonKind,
        height: f64,
        t: &DrawTheme,
    ) {
        let h = height.min(rect.height);
        let boxed = CGRect::new(rect.min_x(), rect.min_y() + ((rect.height - h) / 2.0).round(), rect.width, h);
        let a = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        let touch = Touch { hovering, pressed, disabled: !enabled, focused: false };
        let body = c.stone_button(boxed, kind, touch, t);
        let text = match kind {
            ButtonKind::Accent => t.token(tk::ON_ACCENT),
            ButtonKind::OnViewer => t.token(tk::VIEWER_BUTTON_TEXT),
            _ => t.label(),
        };
        c.draw_text_in(
            title,
            body.inset_by(4.0, 0.0),
            theme::type_size::BODY as f64,
            faded(text, a),
            TextAlign::Center,
            0.0,
            0,
        );
    }

    /// The thin progress bar (TranscribeProgressBar): `fill` track, `accentFill` share, 2 pt ends.
    pub fn progress(c: &mut Canvas, fraction: f64, rect: CGRect, t: &DrawTheme) {
        let r = 2.0_f64.min(rect.height / 2.0);
        c.fill_rounded(rect, r, t.fill());
        let w = rect.width * fraction.clamp(0.0, 1.0);
        if w > 0.0 {
            c.fill_rounded(CGRect::new(rect.min_x(), rect.min_y(), w, rect.height), r, t.accent_fill());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glyph_atlas::tests::atlas;
    use crate::inspector::inspector_controls::tests::render;

    #[test]
    fn click_edits_enter_commits_escape_cancels() {
        let mut cx = UiCx::new();
        let mut f = TextFieldControl::new("00:00:01:00");
        f.mouse_down(None, 1);
        assert!(f.is_editing());
        for ch in "12".chars() {
            f.key(InputKey::Character(ch), InputModifiers::NONE, &mut cx);
        }
        assert_eq!(f.key(InputKey::Enter, InputModifiers::NONE, &mut cx), Some("12".to_string()));
        assert!(!f.is_editing() && f.text == "12");
        f.mouse_down(None, 1);
        f.key(InputKey::Character('9'), InputModifiers::NONE, &mut cx);
        assert_eq!(f.key(InputKey::Escape, InputModifiers::NONE, &mut cx), None);
        assert!(!f.is_editing() && f.text == "12");
    }

    #[test]
    fn a_press_inside_the_open_editor_places_the_caret_under_the_pointer() {
        let mut cx = UiCx::new();
        let a = atlas();
        let c = Canvas::with_size(200.0, 40.0, Some(&a), 1.0);
        let mut f = TextFieldControl::new("Balance");
        f.alignment = Alignment::Left;
        let bounds = CGRect::new(10.0, 0.0, 160.0, 22.0);
        assert_eq!(f.caret_index(&c, 50.0, bounds), None);
        f.mouse_down(None, 1);
        let inner = TextFieldControl::text_rect(bounds);
        assert_eq!(inner.min_x(), bounds.min_x() + 6.0);
        assert_eq!(f.caret_index(&c, bounds.min_x(), bounds), Some(0));
        assert_eq!(f.caret_index(&c, bounds.max_x(), bounds), Some(7));
        let x3 = inner.min_x() + c.size_of("Bal", f.font_size, 0).width;
        let i = f.caret_index(&c, x3, bounds);
        assert_eq!(i, Some(3));
        f.mouse_down(i, 1);
        assert!(f.editor().is_some_and(|e| e.caret() == 3 && !e.has_selection()));
        f.key(InputKey::Character('X'), InputModifiers::NONE, &mut cx);
        assert_eq!(f.key(InputKey::Enter, InputModifiers::NONE, &mut cx), Some("BalXance".to_string()));
    }

    #[test]
    fn tab_commits_without_typing_a_tab() {
        let mut cx = UiCx::new();
        let mut f = TextFieldControl::new("a");
        f.mouse_down(None, 1);
        f.key(InputKey::Character('b'), InputModifiers::NONE, &mut cx);
        assert_eq!(f.key(TAB, InputModifiers::NONE, &mut cx), Some("b".to_string()));
        assert_eq!(f.text, "b");
    }

    #[test]
    fn disabled_field_does_not_open() {
        let mut f = TextFieldControl::new("x");
        f.is_enabled = false;
        f.mouse_down(None, 1);
        assert!(!f.is_editing());
    }

    #[test]
    fn double_click_in_the_open_field_selects_a_word_triple_everything() {
        let mut f = TextFieldControl::new("alpha beta");
        f.mouse_down(None, 1);
        f.mouse_down(Some(7), 1);
        assert!(f.editor().is_some_and(|e| e.caret() == 7 && !e.has_selection()));
        f.mouse_down(Some(7), 2);
        assert_eq!(f.editor().and_then(|e| e.selected_text()).as_deref(), Some("beta"));
        f.mouse_down(Some(7), 3);
        assert_eq!(f.editor().and_then(|e| e.selected_text()).as_deref(), Some("alpha beta"));
    }

    #[test]
    fn button_and_progress_draw() {
        let mut c = Canvas::with_size(100.0, 30.0, None, 1.0);
        let t = DrawTheme::default();
        InspectorDraw::button(&mut c, "Start", CGRect::new(0.0, 0.0, 60.0, 30.0), false, false, true, true, 22.0, &t);
        InspectorDraw::progress(&mut c, 0.5, CGRect::new(0.0, 26.0, 100.0, 4.0), &t);
        let img = render(&c, 100, 30);
        let at = |x: usize, y: usize| img.pixels[(y * 100 + x) * 4 + 2];
        assert!(at(30, 15) > 100);
        assert!(at(20, 28) > at(80, 28));
    }

    #[test]
    fn a_hyphen_before_a_digit_becomes_the_true_minus() {
        assert_eq!(typographic_minus("-12 dB"), "\u{2212}12 dB");
        assert_eq!(typographic_minus("a-b"), "a-b");
        assert_eq!(typographic_minus("1 -2"), "1 \u{2212}2");
    }
}
