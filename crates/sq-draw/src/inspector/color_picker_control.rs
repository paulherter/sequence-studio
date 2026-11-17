// Swift: ColorPickerControl.swift
//! The SQ color picker (uikit `SQColorPickerView`) on the canvas, for every host (inspector color wells, monitor,
//! shell): the saturation/brightness square, the hue bar, the alpha bar (optional), the row with the color pill, the hex
//! capsule and the eyedropper, and the recent colors. Coordinates are the picker's own points (origin top left, the
//! popover chrome included); the host places it with `frame`, translates and routes events.
//! Recents: the host loads them (`sqcolor_recents::load`) into `recents` and stores `value` with `sqcolor_recents::remember`
//! when `commit_recent()` says so.

use super::inspector_controls::{InspectorDraw, InspectorTokens};
use super::text_edit_state::{Outcome as EditOutcome, TextEditState};
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::glyph_atlas::TextAlign;
use crate::input::{InputKey, InputModifiers};
use crate::theme::{self, DrawTheme};
use crate::ui_cx::UiCx;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqcolor_recents;
use sq_uikit::sqcolor_value::SQColorValue;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuLayout;

/// A part of the picker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    /// The saturation/brightness square.
    Field,
    /// The hue bar.
    Hue,
    /// The alpha bar.
    Alpha,
    /// The hex capsule.
    Hex,
    /// The eyedropper button.
    Eyedropper,
    /// A recent color.
    Recent(usize),
}

/// What a press or key did: nothing, a new `value`, or the eyedropper button (the host samples and calls `pick`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing.
    None,
    /// `value` changed.
    Changed,
    /// The eyedropper was pressed.
    Eyedropper,
}

/// The color picker popover.
#[derive(Clone, Debug, PartialEq)]
pub struct ColorPickerControl {
    /// The color.
    pub value: SQColorValue,
    /// Whether the alpha bar shows.
    pub shows_alpha: bool,
    /// The eyedropper button (hidden when the host cannot sample the screen).
    pub shows_eyedropper: bool,
    /// Recent colors as `sqcolor_recents` keys, newest first; the section is hidden while empty.
    pub recents: Vec<String>,
    /// The pointer is over the eyedropper.
    pub hover_eyedropper: bool,
    hex: Option<TextEditState>,
    dragging: Option<Part>,
    changed: bool,
}

impl ColorPickerControl {
    /// Popover width.
    pub const WIDTH: f64 = 232.0;
    /// Padding.
    pub const PAD: f64 = 12.0;
    /// Gap between sections.
    pub const GAP: f64 = 10.0;
    /// Bar height.
    pub const BAR_HEIGHT: f64 = 10.0;
    /// Bar knob size.
    pub const BAR_KNOB: f64 = 14.0;
    /// Field height.
    pub const FIELD_HEIGHT: f64 = 140.0;
    /// Field corner radius.
    pub const FIELD_RADIUS: f64 = 6.0;
    /// Field knob size.
    pub const FIELD_KNOB: f64 = 10.0;
    /// Row height.
    pub const ROW_HEIGHT: f64 = 22.0;
    /// Recent dot size.
    pub const DOT: f64 = 16.0;
    /// Gap between recent dots.
    pub const DOT_GAP: f64 = 6.0;
    /// Color pill size.
    pub const PILL: CGSize = CGSize::new(38.0, 20.0);
    /// Eyedropper button width.
    pub const ICON_WIDTH: f64 = 24.0;
    /// Caption height.
    pub const CAPTION_HEIGHT: f64 = 13.0;

    /// A picker for `value`.
    pub fn new(
        value: SQColorValue,
        shows_alpha: bool,
        shows_eyedropper: bool,
        recents: Vec<String>,
    ) -> ColorPickerControl {
        ColorPickerControl {
            value,
            shows_alpha,
            shows_eyedropper,
            recents,
            hover_eyedropper: false,
            hex: None,
            dragging: None,
            changed: false,
        }
    }

    /// The hex capsule's editor while it edits.
    pub fn hex(&self) -> Option<&TextEditState> {
        self.hex.as_ref()
    }

    // Layout

    fn inner(&self) -> f64 {
        Self::WIDTH - 2.0 * Self::PAD
    }
    /// The saturation/brightness square.
    pub fn field_frame(&self) -> CGRect {
        CGRect::new(Self::PAD, Self::PAD, self.inner(), Self::FIELD_HEIGHT)
    }
    /// The hue bar.
    pub fn hue_frame(&self) -> CGRect {
        CGRect::new(Self::PAD, self.field_frame().max_y() + Self::GAP, self.inner(), Self::BAR_HEIGHT)
    }
    /// The alpha bar, when shown.
    pub fn alpha_frame(&self) -> Option<CGRect> {
        self.shows_alpha
            .then(|| CGRect::new(Self::PAD, self.hue_frame().max_y() + Self::GAP, self.inner(), Self::BAR_HEIGHT))
    }
    fn row_y(&self) -> f64 {
        self.alpha_frame().unwrap_or_else(|| self.hue_frame()).max_y() + Self::GAP
    }
    /// The color pill.
    pub fn pill_frame(&self) -> CGRect {
        CGRect::new(
            Self::PAD,
            self.row_y() + (Self::ROW_HEIGHT - Self::PILL.height) / 2.0,
            Self::PILL.width,
            Self::PILL.height,
        )
    }
    /// The eyedropper button, when shown.
    pub fn eyedropper_frame(&self) -> Option<CGRect> {
        self.shows_eyedropper.then(|| {
            CGRect::new(Self::PAD + self.inner() - Self::ICON_WIDTH, self.row_y(), Self::ICON_WIDTH, Self::ROW_HEIGHT)
        })
    }
    /// The hex capsule.
    pub fn hex_frame(&self) -> CGRect {
        let x = self.pill_frame().max_x() + 8.0;
        let end = self.eyedropper_frame().map(|e| e.min_x() - 8.0).unwrap_or(Self::PAD + self.inner());
        CGRect::new(x, self.row_y(), end - x, Self::ROW_HEIGHT)
    }
    fn recent_colors(&self) -> Vec<SQColorValue> {
        self.recents.iter().filter_map(|h| SQColorValue::parse_hex(h, 1.0)).collect()
    }
    fn caption_y(&self) -> f64 {
        self.row_y() + Self::ROW_HEIGHT + Self::GAP
    }
    /// The dot of recent color `i`.
    pub fn recent_frame(&self, i: usize) -> CGRect {
        CGRect::new(
            Self::PAD + i as f64 * (Self::DOT + Self::DOT_GAP),
            self.caption_y() + Self::CAPTION_HEIGHT + Self::GAP,
            Self::DOT,
            Self::DOT,
        )
    }
    /// The popover's size.
    pub fn size(&self) -> CGSize {
        let bottom = if self.recent_colors().is_empty() {
            self.row_y() + Self::ROW_HEIGHT
        } else {
            self.recent_frame(0).max_y()
        };
        CGSize::new(Self::WIDTH, bottom + Self::PAD)
    }

    /// The popover frame for `anchor` (host points): below the anchor, above when it does not fit, kept inside
    /// `visible` (SQPopoverLogic: gap 4, margin 6, centered on the anchor).
    pub fn frame(&self, anchor: CGRect, visible: CGRect) -> CGRect {
        let s = self.size();
        let (gap, margin) = (4.0, 6.0);
        let area = visible.inset_by(margin, margin);
        let mut y = anchor.max_y() + gap;
        if y + s.height > area.max_y() && anchor.min_y() - gap - s.height >= area.min_y() {
            y = anchor.min_y() - gap - s.height;
        }
        let x = (anchor.mid_x() - s.width / 2.0).max(area.min_x()).min(area.min_x().max(area.max_x() - s.width));
        CGRect::new(x, y, s.width, s.height)
    }

    /// The part under `p`.
    pub fn part(&self, p: CGPoint) -> Option<Part> {
        let k = (Self::BAR_KNOB - Self::BAR_HEIGHT) / 2.0;
        if self.field_frame().contains(p) {
            return Some(Part::Field);
        }
        if self.hue_frame().inset_by(0.0, -k).contains(p) {
            return Some(Part::Hue);
        }
        if self.alpha_frame().is_some_and(|a| a.inset_by(0.0, -k).contains(p)) {
            return Some(Part::Alpha);
        }
        if self.hex_frame().contains(p) {
            return Some(Part::Hex);
        }
        if self.eyedropper_frame().is_some_and(|e| e.contains(p)) {
            return Some(Part::Eyedropper);
        }
        (0..self.recent_colors().len()).find(|i| self.recent_frame(*i).contains(p)).map(Part::Recent)
    }

    // Input

    /// A press at `p`.
    pub fn mouse_down(&mut self, p: CGPoint) -> Outcome {
        let hit = self.part(p);
        if hit != Some(Part::Hex) {
            self.end_hex_edit();
        }
        match hit {
            Some(Part::Field | Part::Hue | Part::Alpha) => {
                self.dragging = hit;
                self.track(p)
            }
            Some(Part::Hex) => {
                if self.hex.is_none() {
                    self.hex = Some(TextEditState::new(&self.value.hex()));
                }
                Outcome::None
            }
            Some(Part::Eyedropper) => Outcome::Eyedropper,
            Some(Part::Recent(i)) => {
                let mut n = self.recent_colors()[i];
                if !self.shows_alpha {
                    n.a = 1.0;
                }
                self.apply(n)
            }
            None => Outcome::None,
        }
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint) -> Outcome {
        if self.dragging.is_none() { Outcome::None } else { self.track(p) }
    }

    /// The button went up.
    pub fn mouse_up(&mut self) {
        self.dragging = None;
    }

    /// The pointer moved.
    pub fn mouse_moved(&mut self, p: CGPoint) {
        self.hover_eyedropper = self.part(p) == Some(Part::Eyedropper);
    }

    /// A key: the hex capsule while it edits (every valid text applies at once), else arrows nudge the last dragged
    /// part (0.01, 0.1 with Shift). Esc in the capsule ends the edit; the host closes the popover on Esc otherwise.
    /// Returns whether the key was taken and what it did.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> (bool, Outcome) {
        if let Some(e) = self.hex.as_mut() {
            let out = e.handle(k, modifiers, cx);
            let text = e.string();
            return match out {
                EditOutcome::Commit | EditOutcome::Cancel => {
                    self.end_hex_edit();
                    (true, Outcome::None)
                }
                EditOutcome::Edited => match SQColorValue::parse_hex(&text, self.value.a) {
                    Some(v) => (true, self.apply(v)),
                    None => (true, Outcome::None),
                },
                EditOutcome::Moved => (true, Outcome::None),
                EditOutcome::Ignored => (false, Outcome::None),
            };
        }
        let step = if modifiers.contains(InputModifiers::SHIFT) { 0.1 } else { 0.01 };
        let mut v = self.value;
        match k {
            InputKey::Left => v.h = (v.h - step).max(0.0),
            InputKey::Right => v.h = (v.h + step).min(0.9999),
            InputKey::Up => v.b = (v.b + step).min(1.0),
            InputKey::Down => v.b = (v.b - step).max(0.0),
            _ => return (false, Outcome::None),
        }
        (true, self.apply(v))
    }

    /// The eyedropper picked `c` (the current alpha stays).
    pub fn pick(&mut self, c: SQColorValue) -> Outcome {
        let mut v = c;
        v.a = self.value.a;
        self.apply(v)
    }

    /// The color gesture ended (popover closed, hex edit done): true when `value` changed since the last call, then
    /// it leads the recents and the host stores it.
    pub fn commit_recent(&mut self) -> bool {
        if !self.changed {
            return false;
        }
        self.changed = false;
        self.recents =
            sqcolor_recents::adding(&sqcolor_recents::key_for(&self.value), &self.recents, sqcolor_recents::MAX_COUNT);
        true
    }

    fn end_hex_edit(&mut self) {
        self.hex = None;
    }

    fn apply(&mut self, v: SQColorValue) -> Outcome {
        if v == self.value {
            return Outcome::None;
        }
        self.value = v;
        self.changed = true;
        Outcome::Changed
    }

    fn track(&mut self, p: CGPoint) -> Outcome {
        let mut v = self.value;
        match self.dragging {
            Some(Part::Field) => {
                let r = self.field_frame();
                v.s = ((p.x - r.min_x()) / r.width).clamp(0.0, 1.0);
                v.b = 1.0 - ((p.y - r.min_y()) / r.height).clamp(0.0, 1.0);
            }
            Some(d @ (Part::Hue | Part::Alpha)) => {
                let r = self.hue_frame();
                let k = Self::BAR_KNOB / 2.0;
                let t = ((p.x - r.min_x() - k) / (r.width - 2.0 * k)).clamp(0.0, 1.0);
                if d == Part::Hue {
                    v.h = t.min(0.9999);
                } else {
                    v.a = t;
                }
            }
            _ => return Outcome::None,
        }
        self.apply(v)
    }

    // Drawing

    /// Draws the popover (chrome and content) with its top left at the current origin.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let s = self.size();
        let bounds = CGRect::new(0.0, 0.0, s.width, s.height);
        let radius = SQMenuLayout::CORNER_RADIUS;
        c.shadow(bounds, radius, 10.0, 4.0, Color::new(0.0, 0.0, 0.0, 0.25), false);
        let bg = bounds.inset_by(0.25, 0.25);
        c.fill_rounded(bg, radius, t.overlay());
        c.stroke_rounded(bg, radius, 0.5, t.ink_fill(0.14));
        self.draw_field(c);
        self.draw_bar(c, self.hue_frame(), false);
        if let Some(a) = self.alpha_frame() {
            self.draw_bar(c, a, true);
        }
        self.draw_pill(c, t);
        self.draw_hex(c, t, cx);
        if let Some(e) = self.eyedropper_frame() {
            if self.hover_eyedropper {
                c.fill_rounded(e, InspectorTokens::radius(e), t.fill_hover());
            }
            let s = 14.0;
            c.draw_icon(
                SQIcon::Eyedropper,
                CGPoint { x: e.mid_x() - s / 2.0, y: e.mid_y() - s / 2.0 },
                s,
                t.label2(),
                None,
            );
        }
        let colors = self.recent_colors();
        if colors.is_empty() {
            return;
        }
        c.draw_text(
            "Recent",
            CGPoint { x: Self::PAD, y: self.caption_y() },
            theme::type_size::CAPTION as f64,
            t.label3(),
            f64::INFINITY,
            0,
        );
        for (i, v) in colors.iter().enumerate() {
            let r = self.recent_frame(i);
            if v.a < 1.0 {
                Self::checker(c, r, 4.0, true);
            }
            c.fill_ellipse(r, Self::draw_color(v));
            c.stroke_rounded(r.inset_by(0.25, 0.25), r.height / 2.0, 0.5, t.ink_fill(0.14));
        }
    }

    /// The draw color of a picker value.
    pub fn draw_color(v: &SQColorValue) -> Color {
        let (r, g, b) = v.rgb();
        Color::new(r as f32, g as f32, b as f32, v.a as f32)
    }

    /// The transparency checkerboard (`Theme.Palette.checker`), cells kept inside the capsule when `round`.
    pub(crate) fn checker(c: &mut Canvas, r: CGRect, cell: f64, round: bool) {
        c.fill_rounded(r, if round { r.height / 2.0 } else { 0.0 }, DrawTheme::CHECKER_DARK);
        c.save_gstate();
        c.clip_to(r);
        let rad = r.height / 2.0;
        let rows = (r.height / cell).ceil() as i64;
        let cols = (r.width / cell).ceil() as i64;
        for y in 0..rows {
            for x in 0..cols {
                if (x + y) % 2 != 1 {
                    continue;
                }
                let q = CGRect::new(r.min_x() + x as f64 * cell, r.min_y() + y as f64 * cell, cell, cell);
                if round && !Self::inside(q, r, rad) {
                    continue;
                }
                c.fill(q, DrawTheme::CHECKER_LIGHT);
            }
        }
        c.restore_gstate();
    }

    /// The cell's center lies inside the rounded rect `r`.
    fn inside(q: CGRect, r: CGRect, radius: f64) -> bool {
        let cx = q.mid_x().max(r.min_x() + radius).min(r.max_x() - radius);
        let cy = q.mid_y().max(r.min_y() + radius).min(r.max_y() - radius);
        let (dx, dy) = (q.mid_x() - cx, q.mid_y() - cy);
        dx * dx + dy * dy <= radius * radius
    }

    /// Hue fill, white to clear left to right, clear to black top to bottom: per point exactly HSB(h, s, b).
    /// known limit: 3 pt cells with the corners cut by the cell center, upgrade to a gradient quad kind (one quad) if the
    /// steps show.
    fn draw_field(&self, c: &mut Canvas) {
        let r = self.field_frame();
        let cell = 3.0;
        let cols = (r.width / cell).ceil() as i64;
        let rows = (r.height / cell).ceil() as i64;
        for y in 0..rows {
            for x in 0..cols {
                let q = CGRect::new(
                    r.min_x() + x as f64 * cell,
                    r.min_y() + y as f64 * cell,
                    cell.min(r.max_x() - r.min_x() - x as f64 * cell),
                    cell.min(r.max_y() - r.min_y() - y as f64 * cell),
                );
                if !Self::inside(q, r, Self::FIELD_RADIUS) {
                    continue;
                }
                let s = (q.mid_x() - r.min_x()) / r.width;
                let b = 1.0 - (q.mid_y() - r.min_y()) / r.height;
                c.fill(q, Self::draw_color(&SQColorValue::new(self.value.h, s, b, 1.0)));
            }
        }
        let kr = CGRect::new(
            r.min_x() + self.value.s * r.width - Self::FIELD_KNOB / 2.0,
            r.min_y() + (1.0 - self.value.b) * r.height - Self::FIELD_KNOB / 2.0,
            Self::FIELD_KNOB,
            Self::FIELD_KNOB,
        );
        c.stroke_rounded(kr.inset_by(-1.0, -1.0), kr.width / 2.0 + 1.0, 1.0, Color::new(0.0, 0.0, 0.0, 0.5));
        c.stroke_rounded(kr, kr.width / 2.0, 2.0, Color::WHITE);
    }

    /// The hue or alpha bar: a capsule gradient (alpha over the checker) and the white knob.
    /// shortcut: one quad per point column, ends as filled half circles, upgrade with a gradient quad kind.
    fn draw_bar(&self, c: &mut Canvas, r: CGRect, alpha: bool) {
        let rad = r.height / 2.0;
        let color = |t: f64| {
            if alpha {
                let mut v = self.value;
                v.a = t;
                Self::draw_color(&v)
            } else {
                Self::draw_color(&SQColorValue::new(t.min(0.9999), 1.0, 1.0, 1.0))
            }
        };
        if alpha {
            Self::checker(c, r, 4.0, true);
        }
        c.fill_ellipse(CGRect::new(r.min_x(), r.min_y(), r.height, r.height), color(0.0));
        c.fill_ellipse(CGRect::new(r.max_x() - r.height, r.min_y(), r.height, r.height), color(1.0));
        let span = r.width - 2.0 * rad;
        let mut x = r.min_x() + rad;
        while x < r.max_x() - rad {
            let w = 1.0_f64.min(r.max_x() - rad - x);
            c.fill(CGRect::new(x, r.min_y(), w, r.height), color((x + w / 2.0 - r.min_x() - rad) / span));
            x += 1.0;
        }
        let k = Self::BAR_KNOB;
        let t = if alpha { self.value.a } else { self.value.h };
        let kr = CGRect::new(r.min_x() + t * (r.width - k), r.mid_y() - k / 2.0, k, k);
        c.shadow(kr, k / 2.0, 3.0, 1.0, Color::new(0.0, 0.0, 0.0, 0.9), false);
        c.fill_ellipse(kr, Color::WHITE);
    }

    fn draw_pill(&self, c: &mut Canvas, t: &DrawTheme) {
        let r = self.pill_frame();
        if self.value.a < 1.0 {
            Self::checker(c, r, 5.0, true);
        }
        c.fill_rounded(r, r.height / 2.0, Self::draw_color(&self.value));
        c.stroke_rounded(r.inset_by(0.25, 0.25), r.height / 2.0, 0.5, t.track_header_line());
    }

    fn draw_hex(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let r = self.hex_frame();
        let rad = InspectorTokens::radius(r);
        let size = theme::type_size::BODY as f64;
        c.fill_rounded(r, rad, t.field());
        if self.hex.is_some() {
            c.fill_rounded(r, rad, t.accent_tint());
            InspectorDraw::focus_line(c, r, rad, t);
        }
        c.draw_text_in(
            "#",
            CGRect::new(r.min_x() + 8.0, r.min_y(), 10.0, r.height),
            size,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        let text = CGRect::new(r.min_x() + 17.0, r.min_y(), r.width - 23.0, r.height);
        if let Some(e) = &self.hex {
            InspectorDraw::edit_text(c, e, text, size, t.label(), false, t, cx);
        } else {
            c.draw_text_in(&self.value.hex(), text, size, t.label(), TextAlign::Left, 0.0, 0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inspector::inspector_controls::tests::render;

    fn red() -> SQColorValue {
        SQColorValue::new(0.0, 1.0, 1.0, 1.0)
    }
    fn picker(v: SQColorValue) -> ColorPickerControl {
        ColorPickerControl::new(v, false, true, vec![])
    }
    fn at(r: CGRect) -> CGPoint {
        CGPoint { x: r.mid_x(), y: r.mid_y() }
    }

    #[test]
    fn drag_in_the_field_sets_saturation_and_brightness() {
        let mut p = picker(red());
        let f = p.field_frame();
        let o = p.mouse_down(CGPoint { x: f.mid_x(), y: f.min_y() + f.height * 0.25 });
        assert_eq!(o, Outcome::Changed);
        assert!((p.value.s - 0.5).abs() < 0.01 && (p.value.b - 0.75).abs() < 0.01);
        p.mouse_dragged(CGPoint { x: f.max_x() + 50.0, y: f.max_y() + 50.0 });
        assert!(p.value.s == 1.0 && p.value.b == 0.0);
        p.mouse_up();
        assert_eq!(p.mouse_dragged(CGPoint { x: f.min_x(), y: f.min_y() }), Outcome::None);
    }

    #[test]
    fn hue_bar_caps_below_one_and_alpha_bar_only_when_shown() {
        let mut p = picker(red());
        assert!(p.alpha_frame().is_none());
        let h = p.hue_frame();
        p.mouse_down(CGPoint { x: h.max_x() - 1.0, y: h.mid_y() });
        assert_eq!(p.value.h, 0.9999);
        let mut a = ColorPickerControl::new(red(), true, true, vec![]);
        let af = a.alpha_frame();
        assert!(af.is_some());
        let af = af.unwrap_or_default();
        a.mouse_down(CGPoint { x: af.min_x(), y: af.mid_y() });
        assert_eq!(a.value.a, 0.0);
        assert!(a.size().height > p.size().height);
    }

    #[test]
    fn hex_edit_applies_every_valid_text_and_keeps_alpha() {
        let mut cx = UiCx::new();
        let mut p = ColorPickerControl::new(SQColorValue::new(0.0, 1.0, 1.0, 0.5), true, true, vec![]);
        p.mouse_down(at(p.hex_frame()));
        assert_eq!(p.hex().map(|e| e.string()).as_deref(), Some("FF0000"));
        for ch in "00FF".chars() {
            p.key(InputKey::Character(ch), InputModifiers::NONE, &mut cx);
        }
        assert_eq!(p.value.hex(), "0000FF");
        p.key(InputKey::Character('0'), InputModifiers::NONE, &mut cx);
        let r = p.key(InputKey::Character('0'), InputModifiers::NONE, &mut cx);
        assert!(r.0 && r.1 == Outcome::Changed);
        assert!(p.value.hex() == "00FF00" && p.value.a == 0.5);
        p.key(InputKey::Enter, InputModifiers::NONE, &mut cx);
        assert!(p.hex().is_none());
    }

    #[test]
    fn recents_show_after_commit_and_pick_without_alpha() {
        let mut p = picker(red());
        let empty = p.size().height;
        assert!(!p.commit_recent());
        p.mouse_down(at(p.field_frame()));
        p.mouse_up();
        assert!(p.commit_recent());
        assert!(p.recents.len() == 1 && p.size().height > empty);
        p.recents.insert(0, "0000FF80".to_string());
        let d = p.recent_frame(0);
        assert_eq!(p.mouse_down(at(d)), Outcome::Changed);
        assert!(p.value.hex() == "0000FF" && p.value.a == 1.0);
    }

    #[test]
    fn eyedropper_is_a_host_hook_and_pick_keeps_alpha() {
        let mut p = ColorPickerControl::new(SQColorValue::new(0.0, 1.0, 1.0, 0.25), true, true, vec![]);
        let e = p.eyedropper_frame().unwrap_or_default();
        assert_eq!(p.mouse_down(at(e)), Outcome::Eyedropper);
        assert_eq!(p.pick(SQColorValue::from_rgb(0.0, 0.0, 1.0, 1.0)), Outcome::Changed);
        assert!(p.value.hex() == "0000FF" && p.value.a == 0.25);
        let none = ColorPickerControl::new(red(), false, false, vec![]);
        assert!(none.eyedropper_frame().is_none() && none.hex_frame().max_x() > p.hex_frame().max_x());
    }

    #[test]
    fn popover_flips_above_and_stays_on_screen() {
        let p = picker(red());
        let screen = CGRect::new(0.0, 0.0, 800.0, 600.0);
        let below = p.frame(CGRect::new(100.0, 50.0, 38.0, 20.0), screen);
        assert_eq!(below.min_y(), 74.0);
        let above = p.frame(CGRect::new(790.0, 560.0, 38.0, 20.0), screen);
        assert!(above.max_y() == 556.0 && above.max_x() <= 794.0);
    }

    #[test]
    fn draws_the_field_color_under_the_cursor_point() {
        let mut cx = UiCx::new();
        let p = picker(red());
        let s = p.size();
        let mut c = Canvas::with_size(s.width as f32, s.height as f32, None, 1.0);
        p.draw(&mut c, &DrawTheme::default(), &mut cx);
        let img = render(&c, s.width as usize, s.height as usize);
        let f = p.field_frame();
        let (x, y) = (f.min_x() as usize + 10, f.min_y() as usize + 4);
        let i = (y * img.width + x) * 4;
        assert!(img.pixels[i..i + 3].iter().all(|v| *v > 200));
        let yb = f.max_y() as usize - 2;
        assert!(img.pixels[(yb * img.width + x) * 4] < 20);
    }
}
