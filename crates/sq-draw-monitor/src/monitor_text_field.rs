// Swift: MonitorTextField.swift
//! The Program monitor's on-canvas text field (the Mac ProgramSurfaceView text editor, `beginTextEditing`): typed
//! text goes to the layer at once (the composite draws it), the field draws the layer's frame, the selection and the
//! caret over it. Return breaks the line, Esc or a click outside ends the edit, Ctrl+B / Ctrl+I toggle bold / italic.
//! The host maps the text style to plain values (this crate does not see SQText) and gives the caret positions of the
//! drawn glyphs (`caret_source`, the portable raster's caret map); without it the UI font's advances stand in.
// known limit: the stand-in carets are the UI font's advances scaled to the layer and do not wrap area text; hosts with a
// text layout set `caret_source`.

use sq_draw::canvas::Canvas;
use sq_draw::inspector::text_edit_state::{Outcome, TextEditState};
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::theme::DrawTheme;
use sq_draw::{InputKey, InputModifiers, UiCx};
use sq_editor_session::es02_timeline_ops::OverlayTarget;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// What the field reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextFieldEvent {
    /// `onEdited`: the text after a change.
    Edited(String),
    /// `onEnded`: the final text.
    Ended(String),
    /// `onStyleToggle`.
    StyleToggle(StyleToggle),
}

/// Ctrl+B / Ctrl+I.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StyleToggle {
    /// Bold.
    Bold,
    /// Italic.
    Italic,
}

/// One text line of a caret map.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaretLine {
    /// Top in the layer's frame.
    pub top: f64,
    /// Line height.
    pub height: f64,
}

/// One caret position.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Caret {
    /// The line it sits on.
    pub line: usize,
    /// Distance from the frame's left edge.
    pub x: f64,
}

/// Caret placement in the layer's frame (x right, y down from its top-left corner): the lines' tops and heights and
/// one caret per character boundary of the text (`count + 1`; caret `i` sits before character `i`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Carets {
    /// The lines.
    pub lines: Vec<CaretLine>,
    /// The carets.
    pub carets: Vec<Caret>,
}

impl Carets {
    /// Layer px to view points (`sx` across, `sy` down).
    fn scaled(&self, sx: f64, sy: f64) -> Carets {
        Carets {
            lines: self.lines.iter().map(|l| CaretLine { top: l.top * sy, height: l.height * sy }).collect(),
            carets: self.carets.iter().map(|c| Caret { line: c.line, x: c.x * sx }).collect(),
        }
    }

    /// The caret nearest to `p`: the line under it (clamped to the first / last), then the nearest caret on that line.
    pub fn index_at(&self, p: CGPoint) -> usize {
        if self.lines.is_empty() || self.carets.is_empty() {
            return 0;
        }
        let row = self.lines.iter().rposition(|l| l.top <= p.y).unwrap_or(0);
        let on_row: Vec<usize> = (0..self.carets.len()).filter(|i| self.carets[*i].line == row).collect();
        // Swift min(by:) keeps the first of equal elements, like Iterator::min_by.
        on_row
            .into_iter()
            .min_by(|a, b| (self.carets[*a].x - p.x).abs().total_cmp(&(self.carets[*b].x - p.x).abs()))
            .unwrap_or(if p.y < self.lines[0].top { 0 } else { self.carets.len() - 1 })
    }
}

/// The host's caret map of a text as the picture draws it.
pub type CaretSource = Box<dyn Fn(&str) -> Option<Carets>>;

/// The text style values the stand-in carets need.
#[derive(Clone, Copy)]
struct CaretStyle {
    font_size: f64,
    line_spacing: f64,
    alignment: f64,
    is_box: bool,
}

/// The frame of the layer in view points: origin and the unit axes.
struct Frame {
    o: CGPoint,
    ux: CGPoint,
    uy: CGPoint,
    size: CGSize,
}

/// The on-canvas text field.
pub struct MonitorTextField {
    edit: Option<TextEditState>,
    target: Option<OverlayTarget>,
    /// The sequence size in px.
    pub sequence_size: CGSize,
    /// Font size in sequence px.
    pub font_size: f64,
    /// Horizontal alignment (0 left, 0.5 center, 1 right).
    pub alignment: f64,
    /// Area text (a box: lines start at its top).
    pub is_box: bool,
    /// The extra line spacing in px.
    pub line_spacing: f64,
    /// The caret map of a text as the picture draws it: layer px from the frame's top-left (the layer's unscaled size).
    pub caret_source: Option<CaretSource>,
    /// What the field reported since the owner last took it.
    pub events: Vec<TextFieldEvent>,
    /// The stand-in carets of the last draw (the canvas measures the UI font only while drawing); a press reads them.
    drawn_carets: Option<Carets>,
}

impl Default for MonitorTextField {
    fn default() -> Self {
        Self::new()
    }
}

impl MonitorTextField {
    /// A closed field.
    pub fn new() -> MonitorTextField {
        MonitorTextField {
            edit: None,
            target: None,
            sequence_size: CGSize::new(1920.0, 1080.0),
            font_size: 100.0,
            alignment: 0.5,
            is_box: false,
            line_spacing: 0.0,
            caret_source: None,
            events: Vec::new(),
            drawn_carets: None,
        }
    }

    /// The field is open.
    pub fn is_editing(&self) -> bool {
        self.edit.is_some()
    }

    /// The text being edited.
    pub fn text(&self) -> String {
        self.edit.as_ref().map(TextEditState::string).unwrap_or_default()
    }

    /// The editor state.
    pub fn edit(&self) -> Option<&TextEditState> {
        self.edit.as_ref()
    }

    /// The layer the field sits on.
    pub fn target(&self) -> Option<&OverlayTarget> {
        self.target.as_ref()
    }

    /// Opens the field on `target` with `text`; `select_all` for a new layer (typing replaces "Text"). `caret_at` (sequence
    /// px from the canvas center, the click that opened it) puts the caret at the nearest character, else it goes to the end.
    pub fn begin(&mut self, text: &str, target: OverlayTarget, select_all: bool, caret_at: Option<sq_core_time::Vec2>) {
        let mut e = TextEditState::with_select_all(text, select_all);
        self.target = Some(target);
        self.drawn_carets = None;
        if !select_all && let Some(p) = caret_at {
            // The frame in sequence px (one view point per px), so the click maps before anything is drawn.
            let r = CGRect::new(0.0, 0.0, self.sequence_size.width, self.sequence_size.height);
            let view = CGPoint::new(r.mid_x() + p.x, r.mid_y() + p.y);
            if let Some(f) = self.frame(&self.quad(r)) {
                let carets = self.carets(&f, text, false, &|s: &str| s.chars().count() as f64 * 7.2);
                e.place(carets.index_at(Self::local(view, &f)), false);
            }
        }
        self.edit = Some(e);
    }

    /// The layer moved or resized (style edits, playhead): the field follows.
    pub fn retarget(&mut self, t: OverlayTarget) {
        if self.is_editing() {
            self.target = Some(t);
        }
    }

    /// Ends the edit once (Esc, a click outside, the host closing it) and reports the final text.
    pub fn end(&mut self) {
        let Some(e) = self.edit.take() else { return };
        self.target = None;
        self.drawn_carets = None;
        self.events.push(TextFieldEvent::Ended(e.string()));
    }

    /// A key while editing; true when the field took it (every key does, so shortcuts do not run under the caret).
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        let Some(mut e) = self.edit.take() else { return false };
        if modifiers.contains(InputModifiers::COMMAND)
            && let InputKey::Character(c) = k
        {
            match c.to_lowercase().next() {
                Some('b') => {
                    self.edit = Some(e);
                    self.events.push(TextFieldEvent::StyleToggle(StyleToggle::Bold));
                    return true;
                }
                Some('i') => {
                    self.edit = Some(e);
                    self.events.push(TextFieldEvent::StyleToggle(StyleToggle::Italic));
                    return true;
                }
                _ => {}
            }
        }
        if k == InputKey::Escape {
            self.edit = Some(e);
            self.end();
            return true;
        }
        let outcome = e.handle_lines(k, modifiers, cx);
        let text = e.string();
        self.edit = Some(e);
        if outcome == Outcome::Edited {
            self.events.push(TextFieldEvent::Edited(text));
        }
        true
    }

    // MARK: Geometry

    /// The layer's corners in view points (top-left, top-right, bottom-right, bottom-left) inside `canvas_rect`.
    pub fn quad(&self, r: CGRect) -> Vec<CGPoint> {
        let Some(t) = &self.target else { return Vec::new() };
        let aspect = if t.size.height > 0.0 { t.size.width / t.size.height } else { 16.0 / 9.0 };
        TransformOverlayGeometry::new(self.sequence_size, r, aspect, t.display_transform(), Some(t.size)).quad()
    }

    fn style(&self) -> CaretStyle {
        CaretStyle {
            font_size: self.font_size,
            line_spacing: self.line_spacing,
            alignment: self.alignment,
            is_box: self.is_box,
        }
    }

    /// The stand-in carets from the UI font: lines in a frame `size` view points large; `measure` gives the width of a
    /// string at the canvas's UI font; `view_per_pixel` converts sequence px to view points.
    pub fn layout(&self, size: CGSize, view_per_pixel: f64, measure: &dyn Fn(&str) -> f64) -> Carets {
        Self::stand_in(&self.text(), size, view_per_pixel, self.style(), measure)
    }

    fn stand_in(
        text: &str,
        size: CGSize,
        view_per_pixel: f64,
        style: CaretStyle,
        measure: &dyn Fn(&str) -> f64,
    ) -> Carets {
        let CaretStyle { font_size, line_spacing, alignment, is_box } = style;
        let lines: Vec<&str> = text.split('\n').collect();
        let font_view = font_size * view_per_pixel;
        let lh = (font_view * 1.2 + line_spacing * view_per_pixel).max(1.0);
        let reference = measure("M").max(0.001);
        let k = font_view * 0.8 / reference; // the UI font's em scaled to the layer's
        let top = if is_box { 0.0 } else { (size.height - lh * lines.len() as f64) / 2.0 };
        let mut out_lines = Vec::new();
        let mut carets = Vec::new();
        for (i, line) in lines.iter().enumerate() {
            let mut xs = vec![0.0];
            let mut prefix = String::new();
            for ch in line.chars() {
                prefix.push(ch);
                xs.push(measure(&prefix) * k);
            }
            let left = (size.width - xs.last().copied().unwrap_or(0.0)) * alignment;
            out_lines.push(CaretLine { top: top + lh * i as f64, height: lh });
            // the last one stands for the line break
            carets.extend(xs.into_iter().map(|x| Caret { line: i, x: x + left }));
        }
        Carets { lines: out_lines, carets }
    }

    /// The carets in view points for the frame `f`: the host's caret map, else the stand-in. `measure` is the UI font
    /// while drawing (`drawing`: kept for the next press), else an even advance of 0.6 em per character.
    fn carets(&mut self, f: &Frame, text: &str, drawing: bool, measure: &dyn Fn(&str) -> f64) -> Carets {
        let Some(t) = &self.target else { return Carets::default() };
        if !(t.size.width > 0.0 && t.size.height > 0.0) {
            return Carets::default();
        }
        let sx = f.size.width / t.size.width;
        let sy = f.size.height / t.size.height;
        let count = text.chars().count();
        if let Some(c) = self.caret_source.as_ref().and_then(|src| src(text))
            && c.carets.len() == count + 1
        {
            return c.scaled(sx, sy);
        }
        if !drawing && let Some(d) = self.drawn_carets.as_ref().filter(|d| d.carets.len() == count + 1) {
            return d.clone();
        }
        let c = Self::stand_in(text, f.size, sx, self.style(), measure);
        if drawing {
            self.drawn_carets = Some(c.clone());
        }
        c
    }

    // MARK: Drawing and pointer

    fn frame(&self, q: &[CGPoint]) -> Option<Frame> {
        if q.len() != 4 {
            return None;
        }
        let w = (q[1].x - q[0].x).hypot(q[1].y - q[0].y);
        let h = (q[3].x - q[0].x).hypot(q[3].y - q[0].y);
        if !(w > 0.5 && h > 0.5) {
            return None;
        }
        Some(Frame {
            o: q[0],
            ux: CGPoint::new((q[1].x - q[0].x) / w, (q[1].y - q[0].y) / w),
            uy: CGPoint::new((q[3].x - q[0].x) / h, (q[3].y - q[0].y) / h),
            size: CGSize::new(w, h),
        })
    }

    /// A view point in the frame's own axes.
    fn local(p: CGPoint, f: &Frame) -> CGPoint {
        let d = CGPoint::new(p.x - f.o.x, p.y - f.o.y);
        CGPoint::new(d.x * f.ux.x + d.y * f.ux.y, d.x * f.uy.x + d.y * f.uy.y)
    }

    /// Draws the frame, the selection and the caret over the layer; the caret rect goes to `cx.requests.caret`.
    pub fn draw(&mut self, c: &mut Canvas, r: CGRect, t: &DrawTheme, cx: &mut UiCx) {
        let Some(e) = self.edit.clone() else { return };
        let Some(f) = self.frame(&self.quad(r)) else { return };
        let pt = |x: f64, y: f64| CGPoint::new(f.o.x + f.ux.x * x + f.uy.x * y, f.o.y + f.ux.y * x + f.uy.y * y);
        c.stroke_polygon(
            &[pt(0.0, 0.0), pt(f.size.width, 0.0), pt(f.size.width, f.size.height), pt(0.0, f.size.height)],
            1.0,
            t.accent(),
        );
        let m = self.carets(&f, &e.string(), true, &|s: &str| c.size_of(s, 12.0, 0).width);
        if m.carets.len() != e.text().len() + 1 {
            return;
        }
        let sel = e.selection();
        if !sel.is_empty() {
            for (li, line) in m.lines.iter().enumerate() {
                let xs: Vec<f64> =
                    (sel.start..=sel.end).filter(|i| m.carets[*i].line == li).map(|i| m.carets[i].x).collect();
                let (Some(x0), Some(x1)) = (xs.iter().copied().reduce(f64::min), xs.iter().copied().reduce(f64::max))
                else {
                    continue;
                };
                if xs.len() < 2 || x1 <= x0 {
                    continue;
                }
                let (y0, y1) = (line.top, line.top + line.height);
                c.fill_polygon(&[pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)], t.accent().with_alpha(0.3));
            }
        }
        let caret = m.carets[e.caret().min(m.carets.len() - 1)];
        if let Some(line) = m.lines.get(caret.line) {
            let (a, b) = (pt(caret.x, line.top), pt(caret.x, line.top + line.height));
            c.stroke_line(a, b, 2.0, t.accent());
            cx.requests.caret =
                Some(c.px(CGRect::new(a.x.min(b.x), a.y.min(b.y), (a.x - b.x).abs(), (a.y - b.y).abs())));
        }
    }

    /// A press while editing: inside the frame it places the caret (Shift extends) and returns true; outside it ends the
    /// edit and returns false so the press goes on (the Type tool's next click).
    pub fn mouse_down(&mut self, p: CGPoint, modifiers: InputModifiers, r: CGRect) -> bool {
        let Some(mut e) = self.edit.clone() else { return false };
        let Some(f) = self.frame(&self.quad(r)) else { return false };
        let l = Self::local(p, &f);
        if !(l.x >= -4.0 && l.y >= -4.0 && l.x <= f.size.width + 4.0 && l.y <= f.size.height + 4.0) {
            self.end();
            return false;
        }
        let text = e.string();
        let carets = self.carets(&f, &text, false, &|s: &str| s.chars().count() as f64 * 7.2);
        e.place(carets.index_at(l), modifiers.contains(InputModifiers::SHIFT));
        self.edit = Some(e);
        true
    }
}

/// A text layer of `width` x `height` px with the identity transform (panel tests).
#[cfg(test)]
pub(crate) fn tests_target(width: f64, height: f64) -> OverlayTarget {
    use sq_core_model::ClipTransform;
    use sq_core_time::keyframes_model::KeyframeTrack;
    use sq_core_time::{Id, Vec2};
    OverlayTarget::new(
        Id::from_u128(1),
        CGSize::new(width, height),
        true,
        ClipTransform::IDENTITY,
        Vec2::ZERO,
        KeyframeTrack::default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Vec2;

    fn target() -> OverlayTarget {
        tests_target(800.0, 200.0)
    }

    #[test]
    fn text_field_types_ends_on_esc_and_toggles_style() {
        let mut cx = UiCx::new();
        let mut f = MonitorTextField::new();
        f.begin("Text", target(), true, None);
        assert!(f.key(InputKey::Character('H'), InputModifiers::NONE, &mut cx));
        assert!(f.key(InputKey::Character('i'), InputModifiers::NONE, &mut cx));
        assert!(f.key(InputKey::Enter, InputModifiers::NONE, &mut cx)); // Return breaks the line
        assert!(f.key(InputKey::Character('b'), InputModifiers::COMMAND, &mut cx));
        assert_eq!(
            f.events,
            [
                TextFieldEvent::Edited("H".into()),
                TextFieldEvent::Edited("Hi".into()),
                TextFieldEvent::Edited("Hi\n".into()),
                TextFieldEvent::StyleToggle(StyleToggle::Bold),
            ]
        );
        assert!(f.key(InputKey::Escape, InputModifiers::NONE, &mut cx));
        assert_eq!(f.events.last(), Some(&TextFieldEvent::Ended("Hi\n".into())));
        assert!(!f.is_editing());
        assert!(!f.key(InputKey::Character('x'), InputModifiers::NONE, &mut cx)); // closed: keys go on
    }

    #[test]
    fn layout_centers_lines_and_index_finds_the_nearest_character() {
        let mut f = MonitorTextField::new();
        f.begin("ab\ncd", target(), false, None);
        f.font_size = 100.0;
        // 10 pt per character in the UI font, "M" 10 pt: k = fontView * 0.8 / 10.
        let l = f.layout(CGSize::new(800.0, 200.0), 1.0, &|s: &str| s.chars().count() as f64 * 10.0);
        assert_eq!(l.lines.len(), 2);
        assert_eq!(l.lines[0].height, 120.0);
        assert_eq!(l.lines[0].top, -20.0); // (200 - 240) / 2: centered vertically
        assert_eq!(l.carets.len(), 6);
        let xs: Vec<f64> = l.carets[0..=2].iter().map(|c| c.x).collect();
        assert!(((xs[0] + xs[2]) / 2.0 - 400.0).abs() < 0.01); // centered horizontally
        assert_eq!(l.index_at(CGPoint::new(xs[2] + 5.0, 0.0)), 2);
        assert_eq!(l.index_at(CGPoint::new(l.carets[4].x, 110.0)), 4);
    }

    /// A caret map in layer px: "abc" on one 100 px line, carets every 50 px from x 10.
    fn map() -> Carets {
        Carets {
            lines: vec![CaretLine { top: 0.0, height: 100.0 }],
            carets: (0..=3).map(|i| Caret { line: 0, x: 10.0 + f64::from(i) * 50.0 }).collect(),
        }
    }

    #[test]
    fn opening_at_a_click_puts_the_caret_at_that_character() {
        let mut f = MonitorTextField::new();
        f.sequence_size = CGSize::new(1920.0, 1080.0);
        f.caret_source = Some(Box::new(|text| (text == "abc").then(map)));
        // The layer is 200 x 100 px centered on the canvas: its top-left at (-100, -50) from the center.
        let t = tests_target(200.0, 100.0);
        f.begin("abc", t.clone(), false, Some(Vec2::new(-100.0 + 62.0, 0.0))); // nearest caret: x 60
        assert!(f.edit().is_some_and(|e| e.caret() == 1 && e.selection().is_empty()));
        f.begin("abc", t.clone(), false, Some(Vec2::new(90.0, 0.0))); // past the end
        assert_eq!(f.edit().map(|e| e.caret()), Some(3));
        f.begin("abc", t.clone(), false, None);
        assert_eq!(f.edit().map(|e| e.caret()), Some(3));
        f.begin("abc", t, true, Some(Vec2::new(-100.0 + 62.0, 0.0))); // a new text selects all
        assert_eq!(f.edit().map(|e| e.selection()), Some(0..3));
    }
}
