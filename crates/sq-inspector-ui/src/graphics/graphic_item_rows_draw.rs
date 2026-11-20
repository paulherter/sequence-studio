// Swift: Draw/GraphicItemRowsDraw.swift
//! Controls > Graphic, the basics of the selected items (the Mac `GraphicItemRows`): the text box of a selected text item,
//! then Corners (rectangles), Fill (color, opacity) and Outline (color, width) of two or more shape items. They read and
//! write the same Shape values as the Graphics panel through the one `GraphicsEditor`, at the playhead, so keys are kept.
//! Coordinates: points, y down, (0, 0) = the rows' top-left.
//!
//! The Swift class held the editor; here the rows are generic over the host context `C` ([`ItemRowsHost`]: the editor and
//! the session the host owns), the same way [`GraphicsFormDraw`] is. The Rust `GraphicsEditor` has no Shape property
//! accessors yet, so the host trait names the ones the rows use.

use std::rc::Rc;

use sq_core_model::ClipEffect;
use sq_core_model::EffectCatalog;
use sq_core_model::{EffectColor, GraphicsLayer};
use sq_draw::inspector::inspector_controls::InspectorDraw;
use sq_draw::inspector::scrub_field_control::ClickCounter;
use sq_draw::inspector::text_edit_state::{Outcome, TextEditState};
use sq_draw::inspector::text_field_control::TAB;
use sq_draw::stone::Touch;
use sq_draw::theme::type_size;
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};

use super::form_draw::{ColorRequest, GraphicsFormDraw, Kind, MenuRequest};
use super::panel_logic;

/// What the rows need of the Graphics editor, at the playhead; `key` is a Shape effect parameter key.
pub trait ItemRowsHost {
    /// The selected items, bottom first.
    fn target_layers(&self) -> Vec<GraphicsLayer>;
    /// The selected text item's string.
    fn text(&self) -> Option<String>;
    /// A gesture opens: one undo step.
    fn begin_gesture(&mut self);
    /// Sets the text item's string ("Edit Text").
    fn update_text(&mut self, text: &str);
    /// The parameter has keys.
    fn is_keyed(&self, key: &str) -> bool;
    /// The parameter's value; `None` = the items differ.
    fn value(&self, key: &str) -> Option<f64>;
    /// Writes the parameter.
    fn set_value(&mut self, key: &str, v: f64);
    /// A plain (unkeyed) shape value such as the fill or outline switch.
    fn shape_value(&self, key: &str) -> Option<f64>;
    /// Writes a plain shape value.
    fn set_shape_value(&mut self, key: &str, v: f64);
    /// A color parameter; `None` = mixed.
    fn color(&self, key: &str) -> Option<EffectColor>;
    /// Writes a color parameter.
    fn set_color(&mut self, key: &str, c: EffectColor);
    /// The alpha of a color parameter, 0...1.
    fn color_alpha(&self, key: &str) -> Option<f64>;
    /// Writes the alpha of a color parameter.
    fn set_color_alpha(&mut self, key: &str, a: f64);
}

pub struct GraphicItemRowsDraw<C: ItemRowsHost + 'static> {
    pub form: GraphicsFormDraw<C>,
    theme: DrawTheme,
    width: f64,
    structure_key: String,
    /// The selected text item's string (`None`: no text item, no box).
    box_text: Option<String>,
    typing: Option<TextEditState>,
    typed: bool,
    counter: ClickCounter,
    box_hover: bool,
    box_pressed: bool,
    form_pressed: bool,
}

impl<C: ItemRowsHost + 'static> Default for GraphicItemRowsDraw<C> {
    fn default() -> Self {
        GraphicItemRowsDraw::new()
    }
}

impl<C: ItemRowsHost + 'static> GraphicItemRowsDraw<C> {
    /// The Mac TextBoxView: 52 pt high, 2 pt below the row top, the row one gap taller.
    pub const BOX_HEIGHT: f64 = 52.0;
    pub const LINE_HEIGHT: f64 = type_size::BODY as f64 + 5.0;

    pub fn new() -> GraphicItemRowsDraw<C> {
        let mut form = GraphicsFormDraw::default();
        form.begin_gesture = Some(Rc::new(|c: &mut C| c.begin_gesture()));
        GraphicItemRowsDraw {
            form,
            theme: DrawTheme::default(),
            width: 320.0,
            structure_key: String::new(),
            box_text: None,
            typing: None,
            typed: false,
            counter: ClickCounter::new(),
            box_hover: false,
            box_pressed: false,
            form_pressed: false,
        }
    }

    pub fn set_theme(&mut self, theme: DrawTheme) {
        self.theme = theme;
        self.form.theme = theme;
    }

    pub fn set_width(&mut self, w: f64) {
        self.width = w;
        self.form.width = w;
    }

    pub fn structure_key(&self) -> &str {
        &self.structure_key
    }

    pub fn box_text(&self) -> Option<&str> {
        self.box_text.as_deref()
    }

    pub fn is_typing(&self) -> bool {
        self.typing.is_some()
    }

    pub fn box_hover(&self) -> bool {
        self.box_hover
    }

    pub fn box_row_height(&self) -> f64 {
        if self.box_text.is_some() { Self::BOX_HEIGHT + ControlsGrid::GAP } else { 0.0 }
    }

    pub fn box_frame(&self) -> CGRect {
        CGRect::new(
            ControlsGrid::LABEL_X,
            2.0,
            (self.width - ControlsGrid::LABEL_X - ControlsGrid::TRAILING).max(0.0),
            Self::BOX_HEIGHT,
        )
    }

    pub fn height(&self) -> f64 {
        self.box_row_height() + self.form.height()
    }

    /// The menu the form asked for, in the rows' coordinates.
    pub fn take_menu(&mut self) -> Option<MenuRequest> {
        let dy = self.box_row_height();
        self.form.take_menu().map(|m| MenuRequest { anchor: shifted(m.anchor, dy), ..m })
    }

    /// The color picker the form asked for, in the rows' coordinates; answer with [`Self::change_color`].
    pub fn take_color_request(&mut self) -> Option<ColorRequest> {
        let dy = self.box_row_height();
        self.form.take_color_request().map(|r| ColorRequest { anchor: shifted(r.anchor, dy), ..r })
    }

    /// The picker reported a color (`None` = canceled).
    pub fn change_color(&mut self, row: usize, color: Option<EffectColor>, ctx: &mut C) {
        self.form.change_color(row, color, ctx);
    }

    /// Applies the popup choices made since the last call.
    pub fn flush(&mut self, ctx: &mut C) {
        self.form.flush(ctx);
    }

    /// Rebuilds the rows when the selection's kinds changed and loads the text item's string (not while typing).
    /// True when the height changed.
    pub fn sync(&mut self, ctx: &mut C, cx: &mut UiCx) -> bool {
        let before = self.height();
        let text = ctx.text();
        if self.typing.is_none() {
            self.box_text = text;
        } else if text.is_none() {
            self.end_typing(ctx);
            self.box_text = None;
        }
        let layers = panel_logic::item_row_layers(&ctx.target_layers());
        let key = if layers.is_empty() {
            String::new()
        } else {
            format!("{}|{}", panel_logic::all_rectangles(&layers), layers.iter().all(panel_logic::is_line_like))
        };
        if key != self.structure_key {
            self.structure_key = key;
            self.rebuild(&layers, ctx, cx);
        }
        self.height() != before
    }

    fn rebuild(&mut self, layers: &[GraphicsLayer], ctx: &mut C, cx: &mut UiCx) {
        self.form.reset(cx, ctx);
        self.form.width = self.width;
        if layers.is_empty() {
            return;
        }
        let kind = ClipEffect::SHAPE_EFFECT_KIND;
        if panel_logic::all_rectangles(layers) {
            let key = ClipEffect::SHAPE_CORNER_RADIUS_KEY;
            let def = EffectCatalog::param(kind, key).map(|p| p.default_value);
            self.form.numbers(
                "Corners",
                "px",
                Some(Rc::new(move |c: &C| c.is_keyed(key))),
                0,
                def.as_ref().map(std::slice::from_ref),
                Some(0.0..=f64::MAX),
                vec![(Rc::new(move |c: &C| c.value(key)), Rc::new(move |c: &mut C, v| c.set_value(key, v.max(0.0))))],
                None,
                None,
                ctx,
            );
        }
        if !layers.iter().all(panel_logic::is_line_like) {
            let key = ClipEffect::SHAPE_FILL_COLOR_KEY;
            self.form.appearance(
                Kind::Appearance {
                    title: "Fill".to_string(),
                    key: "fill".to_string(),
                    on: Rc::new(|c: &C| c.shape_value(ClipEffect::SHAPE_FILL_KEY).map(|v| v >= 0.5)),
                    set_on: Rc::new(|c: &mut C, on| {
                        c.set_shape_value(ClipEffect::SHAPE_FILL_KEY, if on { 1.0 } else { 0.0 })
                    }),
                    color: Rc::new(move |c: &C| c.color(key)),
                    set_color: Rc::new(move |c: &mut C, v| c.set_color(key, v)),
                    has_detail: false,
                },
                Rc::new(move |c: &C| c.color_alpha(key).map(|a| a * 100.0)),
                Rc::new(move |c: &mut C, v| c.set_color_alpha(key, v.clamp(0.0, 100.0) / 100.0)),
                "%",
                100.0,
                ctx,
            );
        }
        let (width, stroke) = (ClipEffect::SHAPE_STROKE_WIDTH_KEY, ClipEffect::SHAPE_STROKE_COLOR_KEY);
        self.form.appearance(
            Kind::Appearance {
                title: "Outline".to_string(),
                key: "outline".to_string(),
                on: Rc::new(|c: &C| c.shape_value(ClipEffect::SHAPE_STROKE_KEY).map(|v| v >= 0.5)),
                set_on: Rc::new(|c: &mut C, on| {
                    c.set_shape_value(ClipEffect::SHAPE_STROKE_KEY, if on { 1.0 } else { 0.0 })
                }),
                color: Rc::new(move |c: &C| c.color(stroke)),
                set_color: Rc::new(move |c: &mut C, v| c.set_color(stroke, v)),
                has_detail: false,
            },
            Rc::new(move |c: &C| c.value(width)),
            Rc::new(move |c: &mut C, v| c.set_value(width, v.max(0.0))),
            "px",
            8.0,
            ctx,
        );
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, ctx: &C, cx: &mut UiCx) {
        if self.box_text.is_some() {
            self.draw_box(c, self.box_frame(), cx);
        }
        c.save_gstate();
        c.translate_by(0.0, self.box_row_height());
        self.form.draw(c, ctx, cx);
        c.restore_gstate();
    }

    /// The text box as in the Text section (`TextBlockDraw::draw_box`): field capsule, the open editor while typing.
    // shortcut: a copy of TextBlockDraw's box drawing; share one TextBoxDraw when a third text box is needed.
    fn draw_box(&self, c: &mut Canvas, f: CGRect, cx: &mut UiCx) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let r = f64::from(sq_uikit::redesign_tokens::radius::CONTROL);
        let touch = Touch { hovering: self.box_hover, ..Touch::default() };
        c.stone_field(f, r, self.typing.is_some(), touch, &t);
        let inner = CGRect::new(f.x + 8.0, f.y + 4.0, (f.width - 16.0).max(0.0), (f.height - 8.0).max(0.0));
        c.save_gstate();
        c.clip_to(inner);
        if let Some(e) = &self.typing {
            InspectorDraw::edit_lines(c, e, inner, Self::LINE_HEIGHT, fs, t.label(), &t, cx);
        } else {
            for (i, line) in self.box_text.as_deref().unwrap_or("").split('\n').enumerate() {
                let rect = CGRect::new(inner.x, inner.y + i as f64 * Self::LINE_HEIGHT, inner.width, Self::LINE_HEIGHT);
                c.draw_text_in(line, rect, fs, t.label(), TextAlign::Left, 0.0, 0);
            }
        }
        c.restore_gstate();
    }

    // MARK: Pointer and keys

    fn in_form(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y - self.box_row_height())
    }

    fn over_box(&self, p: CGPoint) -> bool {
        self.box_text.is_some() && self.box_frame().contains(p)
    }

    fn caret(&self, e: &TextEditState, p: CGPoint, measure: Option<&Canvas>) -> Option<usize> {
        let f = self.box_frame();
        let inner = CGRect::new(f.x + 8.0, f.y + 4.0, (f.width - 16.0).max(0.0), (f.height - 8.0).max(0.0));
        Some(InspectorDraw::caret_index_at(measure?, e, p, inner, Self::LINE_HEIGHT, f64::from(type_size::BODY)))
    }

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.box_hover = p.is_some_and(|p| self.over_box(p));
        let below = p.filter(|p| p.y >= self.box_row_height()).map(|p| self.in_form(p));
        self.form.mouse_moved(below);
    }

    pub fn mouse_down(
        &mut self,
        p: CGPoint,
        click_count: Option<i64>,
        ctx: &mut C,
        measure: Option<&Canvas>,
        cx: &mut UiCx,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        if self.over_box(p) {
            self.form.resign_focus(ctx, cx);
            self.box_pressed = true;
            let mut e = match self.typing.take() {
                Some(e) => e,
                None => {
                    self.typed = false;
                    TextEditState::with_select_all(self.box_text.as_deref().unwrap_or(""), false)
                }
            };
            if n >= 3 {
                e.select_all();
            } else if let Some(i) = self.caret(&e, p, measure) {
                e.place(i, false);
            }
            self.typing = Some(e);
            return;
        }
        self.end_typing(ctx);
        if p.y < self.box_row_height() {
            return;
        }
        self.form_pressed = true;
        let q = self.in_form(p);
        self.form.mouse_down(q, Some(n), ctx, cx);
    }

    pub fn mouse_dragged(
        &mut self,
        p: CGPoint,
        modifiers: InputModifiers,
        scale: f32,
        ctx: &mut C,
        measure: Option<&Canvas>,
        cx: &mut UiCx,
    ) {
        if self.box_pressed
            && let Some(mut e) = self.typing.take()
        {
            if let Some(i) = self.caret(&e, p, measure) {
                e.place(i, true);
            }
            self.typing = Some(e);
            return;
        }
        if self.form_pressed {
            let q = self.in_form(p);
            self.form.mouse_dragged(q, modifiers, scale, ctx, cx);
        }
    }

    pub fn mouse_up(&mut self, p: CGPoint, ctx: &mut C, cx: &mut UiCx) {
        if self.box_pressed {
            self.box_pressed = false;
            return;
        }
        if self.form_pressed {
            self.form_pressed = false;
            let q = self.in_form(p);
            self.form.mouse_up(q, ctx, cx);
        }
    }

    /// Typing in the box (Return breaks the line; Esc, Tab or a click elsewhere end it), else the focused value field.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, ctx: &mut C, cx: &mut UiCx) -> bool {
        if let Some(mut e) = self.typing.take() {
            if k == InputKey::Escape || k == TAB {
                self.typing = Some(e);
                self.end_typing(ctx);
                return true;
            }
            let outcome = e.handle_lines(k, modifiers, cx);
            let s = e.string();
            self.typing = Some(e);
            if outcome != Outcome::Edited {
                return true;
            }
            // One undo step per typing run (the Mac TextBoxView onBegin / onChange).
            if !self.typed {
                self.typed = true;
                ctx.begin_gesture();
            }
            ctx.update_text(&s);
            self.box_text = Some(s);
            return true;
        }
        self.form.key(k, modifiers, ctx, cx)
    }

    pub fn scroll(
        &mut self,
        p: CGPoint,
        dy: f64,
        precise: bool,
        modifiers: InputModifiers,
        ctx: &mut C,
        cx: &mut UiCx,
    ) -> bool {
        p.y >= self.box_row_height() && {
            let q = self.in_form(p);
            self.form.scroll(q, dy, precise, modifiers, ctx, cx)
        }
    }

    pub fn end_typing(&mut self, ctx: &C) {
        self.typing = None;
        self.typed = false;
        self.box_text = ctx.text();
    }

    pub fn resign_focus(&mut self, ctx: &mut C, cx: &mut UiCx) {
        self.end_typing(ctx);
        self.form.resign_focus(ctx, cx);
    }

    pub fn tick(&mut self, ctx: &mut C, now: f64) {
        self.form.tick(ctx, now);
    }
}

fn shifted(r: CGRect, dy: f64) -> CGRect {
    CGRect::new(r.x, r.y + dy, r.width, r.height)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::ShapeKind;
    use sq_core_time::SequentialIds;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Host {
        layers: Vec<GraphicsLayer>,
        text: Option<String>,
        values: HashMap<String, f64>,
        gestures: usize,
        edits: Vec<String>,
    }

    impl ItemRowsHost for Host {
        fn target_layers(&self) -> Vec<GraphicsLayer> {
            self.layers.clone()
        }
        fn text(&self) -> Option<String> {
            self.text.clone()
        }
        fn begin_gesture(&mut self) {
            self.gestures += 1;
        }
        fn update_text(&mut self, text: &str) {
            self.edits.push(text.to_string());
            self.text = Some(text.to_string());
        }
        fn is_keyed(&self, _key: &str) -> bool {
            false
        }
        fn value(&self, key: &str) -> Option<f64> {
            self.values.get(key).copied()
        }
        fn set_value(&mut self, key: &str, v: f64) {
            self.values.insert(key.to_string(), v);
        }
        fn shape_value(&self, key: &str) -> Option<f64> {
            self.values.get(key).copied()
        }
        fn set_shape_value(&mut self, key: &str, v: f64) {
            self.values.insert(key.to_string(), v);
        }
        fn color(&self, _key: &str) -> Option<EffectColor> {
            Some(EffectColor { red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0 })
        }
        fn set_color(&mut self, _key: &str, _c: EffectColor) {}
        fn color_alpha(&self, _key: &str) -> Option<f64> {
            Some(1.0)
        }
        fn set_color_alpha(&mut self, _key: &str, _a: f64) {}
    }

    fn layer(ids: &mut SequentialIds, kind: ShapeKind) -> GraphicsLayer {
        GraphicsLayer::shape(ids, kind, 1920, 1080)
    }

    fn titles(d: &GraphicItemRowsDraw<Host>) -> Vec<String> {
        d.form
            .rows()
            .iter()
            .filter_map(|r| match &*r.kind {
                Kind::Numbers { title, .. } | Kind::Appearance { title, .. } => Some(title.clone()),
                _ => None,
            })
            .collect()
    }

    fn rig(kinds: &[ShapeKind]) -> (GraphicItemRowsDraw<Host>, Host, UiCx) {
        let mut ids = SequentialIds::default();
        let host = Host { layers: kinds.iter().map(|k| layer(&mut ids, *k)).collect(), ..Host::default() };
        let mut d = GraphicItemRowsDraw::new();
        d.set_width(360.0);
        (d, host, UiCx::new())
    }

    #[test]
    fn several_rectangles_show_corners_fill_outline() {
        let (mut d, mut host, mut cx) = rig(&[ShapeKind::Rectangle, ShapeKind::Rectangle]);
        assert!(d.sync(&mut host, &mut cx));
        assert_eq!(titles(&d), ["Corners", "Fill", "Outline"]);
        assert_eq!(d.height(), 3.0 * ControlsGrid::ROW_HEIGHT);
        assert!(!d.sync(&mut host, &mut cx));
    }

    #[test]
    fn nothing_picked_means_no_rows() {
        let (mut d, mut host, mut cx) = rig(&[ShapeKind::Rectangle]);
        d.sync(&mut host, &mut cx);
        assert!(titles(&d).is_empty() && d.height() == 0.0);
    }

    #[test]
    fn an_ellipse_drops_corners_and_lines_drop_fill() {
        let (mut d, mut host, mut cx) = rig(&[ShapeKind::Rectangle, ShapeKind::Ellipse]);
        d.sync(&mut host, &mut cx);
        assert_eq!(titles(&d), ["Fill", "Outline"]);
        let (mut d, mut host, mut cx) = rig(&[ShapeKind::Line, ShapeKind::Arrow]);
        d.sync(&mut host, &mut cx);
        assert_eq!(titles(&d), ["Outline"]);
    }

    #[test]
    fn a_text_item_shows_the_box_and_types_one_undo_step() {
        let (mut d, mut host, mut cx) = rig(&[]);
        host.text = Some("Hello".to_string());
        assert!(d.sync(&mut host, &mut cx));
        assert_eq!(d.box_text(), Some("Hello"));
        assert_eq!(d.box_row_height(), GraphicItemRowsDraw::<Host>::BOX_HEIGHT + ControlsGrid::GAP);
        let b = d.box_frame();
        let at = CGPoint::new(b.max_x() - 2.0, b.max_y() - 2.0);
        d.mouse_down(at, Some(1), &mut host, None, &mut cx);
        d.mouse_up(at, &mut host, &mut cx);
        assert!(d.is_typing());
        for ch in "ab".chars() {
            assert!(d.key(InputKey::Character(ch), InputModifiers::NONE, &mut host, &mut cx));
        }
        assert_eq!(host.gestures, 1);
        assert_eq!(host.edits.len(), 2);
        assert!(host.text.as_deref().is_some_and(|t| t.ends_with("ab")));
        assert!(d.key(InputKey::Escape, InputModifiers::NONE, &mut host, &mut cx));
        assert!(!d.is_typing());
    }

    #[test]
    fn the_fill_check_turns_the_fill_off() {
        let (mut d, mut host, mut cx) = rig(&[ShapeKind::Rectangle, ShapeKind::Ellipse]);
        d.sync(&mut host, &mut cx);
        host.values.insert(ClipEffect::SHAPE_FILL_KEY.to_string(), 1.0);
        let Some((r, y)) = d
            .form
            .visible()
            .into_iter()
            .find(|(r, _)| matches!(&*d.form.rows()[*r].kind, Kind::Appearance { title, .. } if title == "Fill"))
        else {
            panic!("no Fill row")
        };
        let Some(f) = d.form.frame(super::super::form_draw::Part::AppCheck, &d.form.rows()[r], y) else {
            panic!("no check")
        };
        let at = CGPoint::new(f.mid_x(), f.mid_y());
        d.mouse_down(at, Some(1), &mut host, None, &mut cx);
        d.mouse_up(at, &mut host, &mut cx);
        assert_eq!(host.values.get(ClipEffect::SHAPE_FILL_KEY), Some(&0.0));
        assert_eq!(host.gestures, 1);
    }
    #[test]
    fn the_item_text_box_is_a_stone_field_not_a_hand_drawn_capsule() {
        let (d, _host, mut cx) = rig(&[ShapeKind::Rectangle]);
        let mut c = Canvas::with_size(360.0, 100.0, None, 1.0);
        d.draw_box(&mut c, CGRect::new(10.0, 10.0, 200.0, 60.0), &mut cx);
        let at = |radius: f32| {
            c.list.quads().iter().any(|q| {
                q.stroke == 0.0
                    && (q.rect.x, q.rect.y, q.rect.w, q.rect.h) == (10.0, 10.0, 200.0, 60.0)
                    && q.radius == radius
            })
        };
        assert!(at(6.0) && !at(4.0));
    }
}
