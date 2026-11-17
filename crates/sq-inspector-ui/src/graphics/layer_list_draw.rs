// Swift: Draw/GraphicsLayerListDraw.swift
//! The layer list of the Graphics panel on the shared toolkit: front layer first; [chevron | indent] kind icon, name, eye,
//! lock; label strip at the left edge; key ticks and the item's range under the name. Click selects (Shift range, Command
//! toggle), a press on a selected row keeps the selection for a drag, a drag moves the layers or a group (Option copies)
//! with an insertion line or a group drop target, double-click or Return renames (a double-click on a text layer opens its
//! text for typing on the Program monitor instead, like a double-click on the text there), the secondary button opens
//! the context menu. All selection and drop rules are `LayerListLogic`'s. Coordinates: points, y down, (0, 0) = the list's top-left;
//! the footer is the bottom `FOOTER_HEIGHT`.
//!
//! The Swift class held the `GraphicsEditor`; here every call that reads or changes the graphic gets the editor and the
//! session. Menu choices come back as requests: the host shows `take_menu`, then calls `flush`; `take_changed` is true
//! once after the selection or the layers changed from here (Swift `onSelectionChange`).

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

use sq_core_graphics::graphics_editing::GraphicsReorder;
use sq_core_model::{GraphicsContent, GraphicsDocument, LabelColor, ShapeKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::inspector::inspector_controls::{Direction, InspectorDraw, InspectorTokens};
use sq_draw::inspector::text_field_control::{Alignment, TextFieldControl};
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::{Canvas, ClickCounter, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuIcon, SQMenuItem};

use crate::graphics::editor::{EffectDrop, GraphicsEditor};
use crate::graphics::form_draw::MenuRequest;
use crate::graphics::key_tick_math;
use crate::graphics::layer_list_logic::{LayerDrag, LayerListLogic, LayerListRow, RowKind};

/// The buttons of the footer, left to right.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FooterButton {
    Text,
    Shape,
    Draw,
    Group,
    Duplicate,
    Delete,
}

impl FooterButton {
    pub const ALL: [FooterButton; 6] = [
        FooterButton::Text,
        FooterButton::Shape,
        FooterButton::Draw,
        FooterButton::Group,
        FooterButton::Duplicate,
        FooterButton::Delete,
    ];

    fn index(self) -> usize {
        Self::ALL.iter().position(|b| *b == self).unwrap_or(0)
    }

    fn title(self) -> &'static str {
        match self {
            FooterButton::Text => "+ Text",
            FooterButton::Shape => "+ Shape",
            FooterButton::Draw => "Draw",
            FooterButton::Group => "Group",
            FooterButton::Duplicate => "Duplicate",
            FooterButton::Delete => "Delete Layers",
        }
    }
}

/// What the pointer is over.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hover {
    Row(usize),
    Eye(usize),
    Lock(usize),
    Footer(FooterButton),
}

/// A choice made in a menu, applied by `flush`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MenuAction {
    Rename(usize),
    AddShape(ShapeKind),
    Duplicate,
    Group,
    Ungroup,
    Reorder(GraphicsReorder),
    Isolate { lock: bool },
    ShowAll,
    Label(Option<LabelColor>),
    Delete,
}

pub struct GraphicsLayerListDraw {
    pub theme: DrawTheme,
    pub size: CGSize,
    rows: Vec<LayerListRow>,
    collapsed: BTreeSet<Id>,
    scroll_y: f64,
    anchor: Option<usize>,
    hover: Option<Hover>,
    pressed_footer: Option<FooterButton>,
    press_row: Option<usize>,
    press_point: Option<CGPoint>,
    press_was_selected: bool,
    drag: Option<LayerDrag>,
    drop_gap: Option<i64>,
    drop_onto: Option<usize>,
    is_copying: bool,
    counter: ClickCounter,
    effect_target: Option<usize>,
    rename_field: Option<TextFieldControl>,
    renaming: Option<RowKind>,
    menu: Option<MenuRequest>,
    edit_text: Option<Id>,
    changed: bool,
    pending: Rc<RefCell<Vec<MenuAction>>>,
}

impl Default for GraphicsLayerListDraw {
    fn default() -> Self {
        GraphicsLayerListDraw {
            theme: DrawTheme::default(),
            size: CGSize { width: 300.0, height: 200.0 },
            rows: Vec::new(),
            collapsed: BTreeSet::new(),
            scroll_y: 0.0,
            anchor: None,
            hover: None,
            pressed_footer: None,
            press_row: None,
            press_point: None,
            press_was_selected: false,
            drag: None,
            drop_gap: None,
            drop_onto: None,
            is_copying: false,
            counter: ClickCounter::new(),
            effect_target: None,
            rename_field: None,
            renaming: None,
            menu: None,
            edit_text: None,
            changed: false,
            pending: Rc::new(RefCell::new(Vec::new())),
        }
    }
}

impl GraphicsLayerListDraw {
    // shortcut: `Theme.Row.list` at UI scale 1 as literals, upgrade when the row metrics are a shared token.
    pub const ROW_HEIGHT: f64 = 24.0;
    pub const FOOTER_HEIGHT: f64 = 32.0;
    /// The header above the rows: "Layers in this graphic" and the + Text / + Shape chips.
    pub const HEADER_HEIGHT: f64 = 28.0;
    pub const ICON_WIDTH: f64 = 22.0;
    pub const ICON_SLOT: f64 = 18.0;
    pub const TICK_HEIGHT: f64 = 4.0;

    pub fn trailing_width() -> f64 {
        Self::ICON_SLOT * 2.0 + f64::from(spacing::SM + spacing::MD)
    }

    pub fn rows(&self) -> &[LayerListRow] {
        &self.rows
    }

    pub fn collapsed(&self) -> &BTreeSet<Id> {
        &self.collapsed
    }

    pub fn scroll_y(&self) -> f64 {
        self.scroll_y
    }

    pub fn hover(&self) -> Option<Hover> {
        self.hover
    }

    pub fn drop_gap(&self) -> Option<i64> {
        self.drop_gap
    }

    pub fn drop_onto(&self) -> Option<usize> {
        self.drop_onto
    }

    pub fn effect_target(&self) -> Option<usize> {
        self.effect_target
    }

    pub fn rename_field(&self) -> Option<&TextFieldControl> {
        self.rename_field.as_ref()
    }

    pub fn is_copying(&self) -> bool {
        self.is_copying
    }

    /// The menu to show, once.
    pub fn take_menu(&mut self) -> Option<MenuRequest> {
        self.menu.take()
    }

    /// The text layer a double-click asked to edit, once: the host opens its text on the Program monitor.
    pub fn take_edit_text(&mut self) -> Option<Id> {
        self.edit_text.take()
    }

    /// True once after the selection or the layers changed from here: the panel rebuilds its rows.
    pub fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }

    pub fn reload(&mut self, ed: &GraphicsEditor, s: &EditorSession) {
        self.rows = ed.document(s).map(|d| LayerListLogic::rows(d, &self.collapsed)).unwrap_or_default();
        self.scroll_y = self.scroll_y.min(self.max_scroll());
    }

    // MARK: Layout

    pub fn list_height(&self) -> f64 {
        (self.size.height - Self::FOOTER_HEIGHT).max(0.0)
    }

    pub fn max_scroll(&self) -> f64 {
        (self.rows.len() as f64 * Self::ROW_HEIGHT - (self.list_height() - Self::HEADER_HEIGHT)).max(0.0)
    }

    pub fn name_x(r: &LayerListRow) -> f64 {
        let base = f64::from(spacing::MD);
        if r.group_id().is_some() {
            return base + Self::ICON_WIDTH;
        }
        (if r.is_indented() { base + Self::ICON_WIDTH } else { base }) + Self::ICON_WIDTH
    }

    pub fn row_index(&self, y: f64) -> Option<usize> {
        if y < Self::HEADER_HEIGHT || y >= self.list_height() {
            return None;
        }
        let i = ((y - Self::HEADER_HEIGHT + self.scroll_y) / Self::ROW_HEIGHT).floor() as usize;
        (i < self.rows.len()).then_some(i)
    }

    pub fn row_frame(&self, i: usize) -> CGRect {
        CGRect::new(
            0.0,
            Self::HEADER_HEIGHT + i as f64 * Self::ROW_HEIGHT - self.scroll_y,
            self.size.width,
            Self::ROW_HEIGHT,
        )
    }

    fn lock_frame(&self, i: usize) -> CGRect {
        let f = self.row_frame(i);
        CGRect::new(f.width - f64::from(spacing::MD) - Self::ICON_SLOT, f.min_y(), Self::ICON_SLOT, f.height)
    }

    fn eye_frame(&self, i: usize) -> CGRect {
        let l = self.lock_frame(i);
        CGRect::new(l.x - (f64::from(spacing::SM) + Self::ICON_SLOT), l.y, l.width, l.height)
    }

    pub fn strip_frame(&self, i: usize) -> CGRect {
        let f = self.row_frame(i);
        let x = Self::name_x(&self.rows[i]);
        CGRect::new(
            x,
            f.max_y() - Self::TICK_HEIGHT - 1.0,
            (f.width - x - Self::trailing_width()).max(0.0),
            Self::TICK_HEIGHT,
        )
    }

    /// Key times and range of a layer row; `None` when the row shows no strip.
    fn strip(&self, i: usize, d: &GraphicsDocument) -> Option<(Vec<Time>, Option<TimeRange>)> {
        let l = d.layer(self.rows[i].layer_id()?)?;
        let times = LayerListLogic::key_times(l);
        if times.is_empty() && l.range.is_none() { None } else { Some((times, l.range)) }
    }

    // MARK: Footer

    pub fn footer_frame(&self, b: FooterButton) -> CGRect {
        let h = ControlsGrid::CONTROL_HEIGHT;
        let y = self.list_height() + ((Self::FOOTER_HEIGHT - h) / 2.0).round();
        let top = ((Self::HEADER_HEIGHT - h) / 2.0).round();
        let (sm, xs, slot) = (f64::from(spacing::SM), f64::from(spacing::XS), 22.0);
        match b {
            // The chips sit at the trailing side of the header.
            FooterButton::Text => CGRect::new(self.size.width - sm - 70.0 - xs - 60.0, top, 60.0, h),
            FooterButton::Shape => CGRect::new(self.size.width - sm - 70.0, top, 70.0, h),
            FooterButton::Draw => CGRect::new(sm, y, slot, h),
            FooterButton::Group | FooterButton::Duplicate | FooterButton::Delete => {
                let k = (FooterButton::Delete.index() - b.index()) as f64;
                CGRect::new(self.size.width - sm - slot - k * (slot + xs), y, slot, h)
            }
        }
    }

    fn button_at(&self, p: CGPoint) -> Option<FooterButton> {
        FooterButton::ALL.into_iter().find(|b| self.footer_frame(*b).contains(p))
    }

    pub fn is_enabled(&self, b: FooterButton, ed: &GraphicsEditor, s: &EditorSession) -> bool {
        match b {
            FooterButton::Text | FooterButton::Shape | FooterButton::Draw => ed.clip(s).is_some(),
            FooterButton::Group => ed.selected_layers(s).len() >= 2,
            FooterButton::Duplicate | FooterButton::Delete => !ed.selected_layers(s).is_empty(),
        }
    }

    pub fn shape_icon(k: ShapeKind) -> SQIcon {
        match k {
            ShapeKind::Rectangle => SQIcon::ShapeRectangle,
            ShapeKind::Ellipse => SQIcon::ShapeEllipse,
            ShapeKind::Line => SQIcon::ShapeLine,
            ShapeKind::Arrow => SQIcon::ArrowUpRight,
        }
    }

    fn press(&mut self, b: FooterButton, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        if !self.is_enabled(b, ed, s) {
            return;
        }
        match b {
            FooterButton::Text => ed.add_text(s, "Text"),
            FooterButton::Shape => {
                let items = ShapeKind::ALL
                    .iter()
                    .map(|k| {
                        let mut item = self.menu_item(k.title(), MenuAction::AddShape(*k));
                        item.icon = SQMenuIcon::Symbol(Self::shape_icon(*k));
                        item
                    })
                    .collect();
                self.menu = Some(MenuRequest { items, anchor: self.footer_frame(FooterButton::Shape) });
                return;
            }
            FooterButton::Draw => ed.set_drawing(!ed.is_drawing()),
            FooterButton::Group => ed.group_selected(s),
            FooterButton::Duplicate => ed.duplicate_selected(s),
            FooterButton::Delete => ed.delete_selected(s),
        }
        self.did_change(ed, s);
    }

    fn did_change(&mut self, ed: &GraphicsEditor, s: &EditorSession) {
        self.reload(ed, s);
        self.changed = true;
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, ed: &GraphicsEditor, s: &EditorSession, focused: bool, cx: &mut UiCx) {
        let _ = focused;
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let empty = GraphicsDocument::default();
        let d = ed.document(s).unwrap_or(&empty);
        let sel = ed.selected_layers(s);
        let local: Option<Time> = ed.playhead_in_clip(s).then(|| ed.local_time(s));
        c.save_gstate();
        c.clip_to(CGRect::new(
            0.0,
            Self::HEADER_HEIGHT,
            self.size.width,
            (self.list_height() - Self::HEADER_HEIGHT).max(0.0),
        ));
        for (i, r) in self.rows.iter().enumerate() {
            let f = self.row_frame(i);
            if f.max_y() <= Self::HEADER_HEIGHT || f.min_y() >= self.list_height() {
                continue;
            }
            let hov = self.hover;
            if self.drop_onto == Some(i) || self.effect_target == Some(i) {
                c.fill(f, t.accent_tint());
            } else if LayerListLogic::is_selected(r, d, sel) {
                c.fill(f, t.current());
            } else if hov == Some(Hover::Row(i)) || hov == Some(Hover::Eye(i)) || hov == Some(Hover::Lock(i)) {
                c.fill(f, t.fill());
            }
            if let Some(label) = r.label {
                c.fill(CGRect::new(0.0, f.min_y(), f64::from(spacing::XS), f.height), t.clip(label));
            }
            let outside =
                r.layer_id().and_then(|id| d.layer(id)).is_some_and(|l| LayerListLogic::is_outside_range(l, local));
            let nx = Self::name_x(r);
            if let Some(g) = r.group_id() {
                let dir = if self.collapsed.contains(&g) { Direction::Right } else { Direction::Down };
                let rect = CGRect::new(f64::from(spacing::MD), f.min_y(), Self::ICON_WIDTH, f.height);
                InspectorDraw::chevron(c, rect, dir, t.label2(), 8.0);
            } else if let Some(sym) = r.symbol {
                let tint = if outside {
                    t.label2().with_alpha(t.label2().a * InspectorTokens::DISABLED_ALPHA)
                } else {
                    t.label2()
                };
                c.draw_icon(
                    sym,
                    CGPoint::new(nx - Self::ICON_WIDTH + 3.0, (f.mid_y() - 6.0).round()),
                    12.0,
                    tint,
                    None,
                );
            }
            let (eye, lock) = (self.eye_frame(i), self.lock_frame(i));
            let name_color = if outside || !r.is_visible { t.label3() } else { t.label() };
            if self.renaming == Some(r.kind)
                && let Some(field) = &self.rename_field
            {
                let rect = CGRect::new(nx - 4.0, f.min_y() + 1.0, (eye.min_x() - nx).max(60.0), f.height - 2.0);
                field.draw(c, rect, &t, true, cx);
            } else {
                let right = eye.min_x() - f64::from(spacing::XS);
                // The kit row: name, then the kind quiet at the trailing side ("Text", "Shape").
                let kind =
                    r.layer_id().and_then(|id| d.layer(id)).map(|l| SQL10n::string(LayerListLogic::kind_label(l)));
                let kind_w = kind.as_ref().map_or(0.0, |k| c.size_of(k, f64::from(type_size::CAPTION), 0).width.ceil());
                let show_kind = kind.is_some() && right - nx - kind_w > 60.0;
                let name_right = if show_kind { right - kind_w - f64::from(spacing::SM) } else { right };
                let rect = CGRect::new(nx, f.min_y(), (name_right - nx).max(0.0), f.height);
                c.draw_text_in(&r.name, rect, fs, name_color, TextAlign::Left, 0.0, 0);
                if let (Some(k), true) = (kind, show_kind) {
                    let kr = CGRect::new(right - kind_w, f.min_y(), kind_w, f.height);
                    c.draw_text_in(&k, kr, f64::from(type_size::CAPTION), t.label3(), TextAlign::Right, 0.0, 0);
                }
            }
            let eye_icon = if r.is_visible { SQIcon::Eye } else { SQIcon::EyeOff };
            let eye_tint = if hov == Some(Hover::Eye(i)) {
                t.label()
            } else if r.is_visible {
                t.label2()
            } else {
                t.label3()
            };
            c.draw_icon(eye_icon, CGPoint::new(eye.mid_x() - 5.5, (eye.mid_y() - 5.5).round()), 11.0, eye_tint, None);
            let lock_icon = if r.is_locked { SQIcon::TrackLock } else { SQIcon::TrackUnlock };
            let lock_tint = if hov == Some(Hover::Lock(i)) || r.is_locked { t.label() } else { t.label3() };
            c.draw_icon(
                lock_icon,
                CGPoint::new(lock.mid_x() - 5.5, (lock.mid_y() - 5.5).round()),
                11.0,
                lock_tint,
                None,
            );
            if let (Some((times, range)), Some(clip)) = (self.strip(i, d), ed.clip(s)) {
                self.draw_strip(c, self.strip_frame(i), &times, range, clip.duration(), local);
            }
        }
        if self.rows.is_empty() && ed.document(s).is_some() {
            let r = CGRect::new(
                0.0,
                Self::HEADER_HEIGHT,
                self.size.width,
                (self.list_height() - Self::HEADER_HEIGHT).max(0.0),
            );
            c.draw_empty_state(
                &SQL10n::string("No layers yet"),
                &SQL10n::string("Add text or a shape below."),
                r,
                0.0,
                &t,
            );
        }
        if let (Some(gap), None) = (self.drop_gap, self.drop_onto) {
            let y = Self::HEADER_HEIGHT + gap as f64 * Self::ROW_HEIGHT - self.scroll_y;
            let sm = f64::from(spacing::SM);
            c.fill(CGRect::new(sm, (y - 1.0).max(0.0), (self.size.width - sm * 2.0).max(0.0), 2.0), t.accent());
        }
        c.restore_gstate();
        let title = CGRect::new(f64::from(spacing::MD), 0.0, self.size.width, Self::HEADER_HEIGHT);
        let title_text = SQL10n::string("Layers in this graphic");
        // Kit: the tracked uppercase eyebrow (10 pt, semibold, +0.07 em).
        let semibold = c.semibold();
        c.draw_tracked_caps(&title_text, title, 10.0, t.label3(), semibold, 0.07);
        self.draw_footer(c, ed, s);
    }

    fn draw_strip(
        &self,
        c: &mut Canvas,
        f: CGRect,
        times: &[Time],
        range: Option<TimeRange>,
        duration: Time,
        playhead: Option<Time>,
    ) {
        let (t, w) = (self.theme, f.width);
        if w <= 0.0 {
            return;
        }
        if let Some(range) = range
            && duration.value() > 0
        {
            let (x, width) = key_tick_math::range_span(range, duration, w);
            // known limit: the range bar uses the pressed fill, not the item lane bar fill; upgrade when that token is portable.
            c.fill(CGRect::new(f.min_x() + x, f.min_y() + 1.0, width, (f.height - 2.0).max(1.0)), t.fill_pressed());
        }
        // The ticks sit on a hairline lane, so a lone key reads as a mark on a lane and not as a stray speck.
        if !times.is_empty() {
            c.fill(CGRect::new(f.min_x(), f.max_y() - 1.0, w, 1.0), t.separator());
        }
        for x in key_tick_math::positions(times, duration, w) {
            let tick_x = f.min_x() + (x - 1.0).max(0.0).min((w - 2.0).max(0.0));
            c.fill(CGRect::new(tick_x, f.min_y() + 1.0, 2.0, (f.height - 2.0).max(1.0)), t.accent());
        }
        if let Some(p) = playhead
            && duration.value() > 0
        {
            let x = key_tick_math::fraction(p, duration) * w;
            let px = f.min_x() + x.max(1.0).min((w - 1.0).max(1.0)) - 0.5;
            c.fill(CGRect::new(px, f.min_y(), 1.0, f.height), t.playhead());
        }
    }

    fn draw_footer(&self, c: &mut Canvas, ed: &GraphicsEditor, s: &EditorSession) {
        let t = self.theme;
        c.fill(CGRect::new(0.0, self.list_height(), self.size.width, 1.0), t.separator());
        for b in FooterButton::ALL {
            let (f, en) = (self.footer_frame(b), self.is_enabled(b, ed, s));
            let hov = self.hover == Some(Hover::Footer(b));
            match b {
                FooterButton::Text | FooterButton::Shape => {
                    InspectorDraw::button(
                        c,
                        &SQL10n::string(b.title()),
                        f,
                        hov,
                        self.pressed_footer == Some(b),
                        en,
                        false,
                        f64::from(InspectorTokens::CAPSULE),
                        &t,
                    );
                }
                _ => {
                    let icon = match b {
                        FooterButton::Draw => SQIcon::Draw,
                        FooterButton::Group => SQIcon::Bundle,
                        FooterButton::Duplicate => SQIcon::Duplicate,
                        _ => SQIcon::Trash,
                    };
                    let on = b == FooterButton::Draw && ed.is_drawing();
                    if hov && en {
                        c.fill_rounded(f, f64::from(radius::SMALL), t.fill_hover());
                    }
                    let base = if on {
                        t.accent()
                    } else if hov {
                        t.label()
                    } else {
                        t.label2()
                    };
                    let tint = if en { base } else { base.with_alpha(base.a * InspectorTokens::DISABLED_ALPHA) };
                    c.draw_icon(icon, CGPoint::new(f.mid_x() - 6.0, (f.mid_y() - 6.0).round()), 12.0, tint, None);
                }
            }
        }
    }

    // MARK: Pointer

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        let Some(p) = p.filter(|_| self.press_row.is_none()) else {
            self.hover = None;
            return;
        };
        if p.y >= self.list_height() || p.y < Self::HEADER_HEIGHT {
            self.hover = self.button_at(p).map(Hover::Footer);
            return;
        }
        let Some(i) = self.row_index(p.y) else {
            self.hover = None;
            return;
        };
        self.hover = Some(if self.eye_frame(i).contains(p) {
            Hover::Eye(i)
        } else if self.lock_frame(i).contains(p) {
            Hover::Lock(i)
        } else {
            Hover::Row(i)
        });
    }

    pub fn mouse_down(
        &mut self,
        p: CGPoint,
        modifiers: InputModifiers,
        click_count: Option<i64>,
        ed: &mut GraphicsEditor,
        s: &mut EditorSession,
        cx: &mut UiCx,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        if self.rename_field.is_some() {
            self.commit_rename(ed, s);
        }
        if p.y >= self.list_height() || p.y < Self::HEADER_HEIGHT {
            self.pressed_footer = self.button_at(p);
            return;
        }
        if modifiers.contains(InputModifiers::SECONDARY) {
            self.context_menu(p, ed, s);
            return;
        }
        let Some(i) = self.row_index(p.y).filter(|_| ed.document(s).is_some()) else {
            self.press_row = None;
            ed.select(s, BTreeSet::new());
            self.anchor = None;
            self.changed = true;
            return;
        };
        let r = self.rows[i].clone();
        if self.eye_frame(i).contains(p) {
            self.toggle_visible(i, ed, s);
            return;
        }
        if self.lock_frame(i).contains(p) {
            self.toggle_locked(i, ed, s);
            return;
        }
        // A click on a layer's key strip moves the playhead there (no selection change).
        if let (Some(d), Some(clip)) = (ed.document(s), ed.clip(s))
            && self.strip(i, d).is_some()
        {
            let (f, duration) = (self.strip_frame(i), clip.duration());
            if p.x >= f.min_x() && p.x <= f.max_x() && p.y >= f.min_y() - 3.0 {
                ed.seek_local(s, key_tick_math::time_at_x(p.x - f.min_x(), f.width, duration));
                return;
            }
        }
        // The chevron of a group row opens / closes it.
        if let Some(g) = r.group_id()
            && p.x < Self::name_x(&r)
        {
            if !self.collapsed.remove(&g) {
                self.collapsed.insert(g);
            }
            self.reload(ed, s);
            return;
        }
        if n == 2 {
            let is_text = |id: &Id| {
                ed.document(s)
                    .and_then(|d| d.layer(*id))
                    .is_some_and(|l| matches!(l.content, GraphicsContent::Text { .. }))
            };
            match r.layer_id().filter(is_text) {
                Some(id) => {
                    self.apply_click(i, InputModifiers::NONE, ed, s);
                    self.edit_text = Some(id);
                }
                None => self.begin_rename(i),
            }
            return;
        }
        self.press_row = Some(i);
        self.press_point = Some(p);
        let selected = ed.document(s).is_some_and(|d| LayerListLogic::is_selected(&r, d, ed.selected_layers(s)));
        self.press_was_selected = selected;
        // A press on a selected row keeps the selection until mouse up (so a drag carries all of it).
        if selected && !modifiers.contains(InputModifiers::SHIFT) && !modifiers.contains(InputModifiers::COMMAND) {
            return;
        }
        self.apply_click(i, modifiers, ed, s);
    }

    fn apply_click(&mut self, i: usize, modifiers: InputModifiers, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let range = modifiers.contains(InputModifiers::SHIFT);
        let toggle = modifiers.contains(InputModifiers::COMMAND);
        let Some(d) = ed.document(s) else { return };
        let sel = LayerListLogic::select(&self.rows, d, ed.selected_layers(s), i, self.anchor, toggle, range);
        if !range {
            self.anchor = Some(i);
        }
        ed.select(s, sel);
        self.changed = true;
    }

    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, ed: &GraphicsEditor, s: &EditorSession) {
        let (Some(i), Some(start)) = (self.press_row, self.press_point) else { return };
        let Some(d) = ed.document(s) else { return };
        if self.drag.is_none() {
            if (p.x - start.x).hypot(p.y - start.y) <= 3.0 {
                return;
            }
            let row = &self.rows[i];
            let selected = ed.selected_layers(s);
            self.drag = Some(match row.group_id() {
                Some(g) if !LayerListLogic::is_selected(row, d, selected) || *selected == ed.members(s, g) => {
                    LayerDrag::Group(g)
                }
                _ => LayerDrag::Layers(selected.iter().copied().collect()),
            });
        }
        self.is_copying = modifiers.contains(InputModifiers::OPTION);
        // Autoscroll at the edges (one step per drag event).
        if p.y < Self::HEADER_HEIGHT {
            self.scroll_y = (self.scroll_y - Self::ROW_HEIGHT / 2.0).max(0.0);
        }
        if p.y > self.list_height() {
            self.scroll_y = (self.scroll_y + Self::ROW_HEIGHT / 2.0).min(self.max_scroll());
        }
        self.update_drop_target(p);
    }

    fn update_drop_target(&mut self, p: CGPoint) {
        let h = Self::ROW_HEIGHT;
        let y = (p.y - Self::HEADER_HEIGHT + self.scroll_y).max(0.0).min(self.rows.len() as f64 * h);
        let mut gap = (y / h).round() as i64;
        let mut onto = None;
        if let Some(i) = self.row_index(p.y)
            && self.rows[i].group_id().is_some()
        {
            let f = (p.y - Self::HEADER_HEIGHT + self.scroll_y - i as f64 * h) / h;
            if f > 0.25 && f < 0.75 {
                onto = Some(i);
            } else {
                gap = if f <= 0.25 { i as i64 } else { i as i64 + 1 };
            }
        }
        self.drop_gap = Some(gap);
        self.drop_onto = onto;
    }

    pub fn mouse_up(&mut self, p: CGPoint, modifiers: InputModifiers, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        if let Some(b) = self.pressed_footer.take() {
            if self.footer_frame(b).contains(p) {
                self.press(b, ed, s);
            }
            return;
        }
        self.finish_up(modifiers, ed, s);
        self.press_row = None;
        self.press_point = None;
        self.drag = None;
        self.drop_gap = None;
        self.drop_onto = None;
        self.is_copying = false;
        self.mouse_moved(Some(p));
    }

    fn finish_up(&mut self, modifiers: InputModifiers, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        if let Some(drag) = &self.drag {
            let copy = modifiers.contains(InputModifiers::OPTION) || self.is_copying;
            let gap = self.drop_gap.unwrap_or(self.rows.len() as i64);
            let drop =
                ed.document(s).and_then(|d| LayerListLogic::drop(drag, &self.rows, d, gap, self.drop_onto, copy));
            if let Some(drop) = drop {
                if copy {
                    ed.apply_copy(s, &drop);
                } else {
                    ed.apply(s, &drop);
                }
                self.did_change(ed, s);
            }
            return;
        }
        // Plain click on an already selected row: now it becomes the only selection.
        if let Some(i) = self.press_row
            && self.press_was_selected
            && !modifiers.contains(InputModifiers::SHIFT)
            && !modifiers.contains(InputModifiers::COMMAND)
        {
            self.apply_click(i, InputModifiers::NONE, ed, s);
        }
    }

    pub fn scroll(&mut self, dy: f64) {
        self.scroll_y = (self.scroll_y - dy).max(0.0).min(self.max_scroll());
    }

    fn members(&self, r: &LayerListRow, ed: &GraphicsEditor, s: &EditorSession) -> BTreeSet<Id> {
        if let Some(id) = r.layer_id() {
            return BTreeSet::from([id]);
        }
        r.group_id().map(|g| ed.members(s, g)).unwrap_or_default()
    }

    fn toggle_visible(&mut self, i: usize, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let r = self.rows[i].clone();
        match r.layer_id() {
            Some(id) => ed.set_visible(s, id, !r.is_visible),
            None => ed.set_visible_all(s, &self.members(&r, ed, s), !r.is_visible),
        }
        self.did_change(ed, s);
    }

    fn toggle_locked(&mut self, i: usize, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let r = self.rows[i].clone();
        match r.layer_id() {
            Some(id) => ed.set_locked(s, id, !r.is_locked),
            None => ed.set_locked_all(s, &self.members(&r, ed, s), !r.is_locked),
        }
        self.did_change(ed, s);
    }

    fn context_menu(&mut self, p: CGPoint, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let row = self.row_index(p.y);
        if let Some(i) = row
            && let Some(d) = ed.document(s)
            && !LayerListLogic::is_selected(&self.rows[i], d, ed.selected_layers(s))
        {
            self.apply_click(i, InputModifiers::NONE, ed, s);
        }
        let items = self.context_items(row, ed, s);
        self.menu = Some(MenuRequest { items, anchor: CGRect::new(p.x, p.y, 0.0, 0.0) });
    }

    fn menu_item(&self, title: &str, action: MenuAction) -> SQMenuItem {
        let mut item = SQMenuItem::new(title);
        let sink = Rc::clone(&self.pending);
        item.action = Some(Rc::new(move || sink.borrow_mut().push(action)));
        item
    }

    /// Rename, Duplicate, Group, Ungroup | Bring to Front, Bring Forward, Send Backward, Send to Back | Hide Others, Lock
    /// Others, Show All Layers | Label | Delete (the Mac list's menu).
    pub fn context_items(&self, row: Option<usize>, ed: &GraphicsEditor, s: &EditorSession) -> Vec<SQMenuItem> {
        let selected = ed.selected_layers(s);
        let sel = !selected.is_empty();
        let grouped =
            selected.iter().any(|id| ed.document(s).and_then(|d| d.layer(*id)).is_some_and(|l| l.group.is_some()));
        let item = |title: &str, enabled: bool, action: MenuAction| {
            let mut i = self.menu_item(title, action);
            i.is_enabled = enabled;
            i
        };
        let mut label = SQMenuItem::new("Label");
        label.is_enabled = sel;
        label.submenu = Some(self.label_items(ed, s));
        let mut rename = item("Rename", row.is_some(), MenuAction::Rename(row.unwrap_or(0)));
        rename.is_enabled = row.is_some();
        vec![
            rename,
            item("Duplicate", sel, MenuAction::Duplicate),
            item("Group", selected.len() >= 2, MenuAction::Group),
            item("Ungroup", grouped, MenuAction::Ungroup),
            SQMenuItem::separator(),
            item("Bring to Front", sel, MenuAction::Reorder(GraphicsReorder::Front)),
            item("Bring Forward", sel, MenuAction::Reorder(GraphicsReorder::Forward)),
            item("Send Backward", sel, MenuAction::Reorder(GraphicsReorder::Backward)),
            item("Send to Back", sel, MenuAction::Reorder(GraphicsReorder::Back)),
            SQMenuItem::separator(),
            item("Hide Others", sel, MenuAction::Isolate { lock: false }),
            item("Lock Others", sel, MenuAction::Isolate { lock: true }),
            item("Show All Layers", true, MenuAction::ShowAll),
            SQMenuItem::separator(),
            label,
            SQMenuItem::separator(),
            item("Delete", sel, MenuAction::Delete),
        ]
    }

    /// "No Label" and the 16 colors; the check marks the label every selected layer shares.
    fn label_items(&self, ed: &GraphicsEditor, s: &EditorSession) -> Vec<SQMenuItem> {
        let mut shared: Vec<Option<LabelColor>> = Vec::new();
        for id in ed.selected_layers(s) {
            let l = ed.document(s).and_then(|d| d.layer(*id)).and_then(|l| l.label);
            if !shared.contains(&l) {
                shared.push(l);
            }
        }
        let mut none = self.menu_item("No Label", MenuAction::Label(None));
        none.is_checked = shared == [None];
        let mut items = vec![none, SQMenuItem::separator()];
        for l in LabelColor::ALL {
            let mut i = self.menu_item(l.display_name(), MenuAction::Label(Some(l)));
            i.icon = SQMenuIcon::Swatch(l.rgb());
            i.is_checked = shared == [Some(l)];
            items.push(i);
        }
        items
    }

    /// Applies the menu choices made since the last call.
    pub fn flush(&mut self, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let actions = std::mem::take(&mut *self.pending.borrow_mut());
        for a in actions {
            match a {
                MenuAction::Rename(row) => {
                    self.begin_rename(row);
                    continue;
                }
                MenuAction::AddShape(k) => ed.add_shape(s, k),
                MenuAction::Duplicate => ed.duplicate_selected(s),
                MenuAction::Group => ed.group_selected(s),
                MenuAction::Ungroup => ed.ungroup_selected(s),
                MenuAction::Reorder(how) => ed.reorder(s, how),
                MenuAction::Isolate { lock } => ed.isolate_selection(s, lock),
                MenuAction::ShowAll => ed.show_all_layers(s),
                MenuAction::Label(l) => {
                    let ids: Vec<Id> = ed.selected_layers(s).iter().copied().collect();
                    ed.set_label(s, &ids, l);
                    continue;
                }
                MenuAction::Delete => ed.delete_selected(s),
            }
            self.did_change(ed, s);
        }
    }

    // MARK: Effects dropped from the Effects panel (the Mac `effectDragUpdated` / `effectDrop`)

    /// `p` in list coordinates, `None` when the drag left. Group rows take no effect.
    pub fn effect_drag_over(&mut self, p: Option<CGPoint>) {
        self.effect_target = p.and_then(|p| self.row_index(p.y)).filter(|i| self.rows[*i].layer_id().is_some());
    }

    /// Effects released on a layer row: the layer is selected, then takes them. `None` when `p` is not on a layer row.
    pub fn drop_effects(
        &mut self,
        kinds: &[String],
        p: CGPoint,
        ed: &mut GraphicsEditor,
        s: &mut EditorSession,
    ) -> Option<EffectDrop> {
        self.effect_target = None;
        let id = self.row_index(p.y).and_then(|i| self.rows[i].layer_id())?;
        if !ed.selected_layers(s).contains(&id) {
            ed.select(s, BTreeSet::from([id]));
            self.did_change(ed, s);
        }
        Some(ed.add_effects(s, kinds, Some(id)))
    }

    // MARK: Rename (a TextFieldControl over the name)

    /// Starts the rename of the single selected layer's row; false when it has no row (inside a collapsed group).
    pub fn begin_rename_selected(&mut self, ed: &GraphicsEditor, s: &EditorSession) -> bool {
        let mut it = ed.selected_layers(s).iter();
        let (Some(id), None) = (it.next(), it.next()) else { return false };
        let Some(i) = self.rows.iter().position(|r| r.layer_id() == Some(*id)) else { return false };
        self.begin_rename(i);
        self.rename_field.is_some()
    }

    fn begin_rename(&mut self, i: usize) {
        if i >= self.rows.len() || self.rename_field.is_some() {
            return;
        }
        let mut f = TextFieldControl::new(&self.rows[i].name);
        f.alignment = Alignment::Left;
        f.font_size = f64::from(type_size::BODY);
        f.mouse_down(None, 1);
        self.rename_field = Some(f);
        self.renaming = Some(self.rows[i].kind);
    }

    /// Keys while renaming: Return commits, Esc cancels. False when no rename is open.
    pub fn key(
        &mut self,
        k: InputKey,
        modifiers: InputModifiers,
        ed: &mut GraphicsEditor,
        s: &mut EditorSession,
        cx: &mut UiCx,
    ) -> bool {
        let Some(f) = self.rename_field.as_mut() else { return false };
        if k == InputKey::Escape {
            self.rename_field = None;
            self.renaming = None;
            return true;
        }
        if let Some(committed) = f.key(k, modifiers, cx) {
            self.finish_rename(&committed, ed, s);
        }
        true
    }

    /// Click away commits.
    pub fn commit_rename(&mut self, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let Some(f) = self.rename_field.as_mut() else { return };
        let name = f.commit().unwrap_or_else(|| f.text.clone());
        self.finish_rename(&name, ed, s);
    }

    fn finish_rename(&mut self, name: &str, ed: &mut GraphicsEditor, s: &mut EditorSession) {
        let kind = self.renaming.take();
        self.rename_field = None;
        match kind {
            Some(RowKind::Layer(id)) => ed.rename(s, id, name),
            Some(RowKind::Group(g)) => ed.rename_group(s, g, name),
            None => {}
        }
        self.reload(ed, s);
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        if p.y >= self.list_height() || p.y < Self::HEADER_HEIGHT {
            return self.button_at(p).map(|b| SQL10n::string(b.title()));
        }
        let i = self.row_index(p.y)?;
        let r = &self.rows[i];
        if self.eye_frame(i).contains(p) {
            return Some(SQL10n::string(if r.is_visible { "Hide" } else { "Show" }));
        }
        if self.lock_frame(i).contains(p) {
            return Some(SQL10n::string(if r.is_locked { "Unlock" } else { "Lock" }));
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics::editor_tests::with_three_shapes;

    fn setup() -> (EditorSession, GraphicsEditor, GraphicsLayerListDraw, UiCx) {
        let (s, ed) = with_three_shapes();
        let mut d = GraphicsLayerListDraw::default();
        d.reload(&ed, &s);
        (s, ed, d, UiCx::new())
    }

    fn click(d: &mut GraphicsLayerListDraw, ed: &mut GraphicsEditor, s: &mut EditorSession, cx: &mut UiCx, p: CGPoint) {
        d.mouse_down(p, InputModifiers::NONE, Some(1), ed, s, cx);
        d.mouse_up(p, InputModifiers::NONE, ed, s);
    }

    #[test]
    fn rows_are_front_first_and_a_click_selects_one() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        assert_eq!(d.rows().len(), 3);
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(100.0, 64.0));
        assert_eq!(ed.selected_layers(&s).len(), 1);
        assert_eq!(ed.selected_layers(&s).iter().next().copied(), d.rows()[1].layer_id());
        assert!(d.take_changed());
    }

    #[test]
    fn shift_click_extends_the_range_and_empty_space_clears() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(100.0, 40.0));
        d.mouse_down(CGPoint::new(100.0, 88.0), InputModifiers::SHIFT, Some(1), &mut ed, &mut s, &mut cx);
        d.mouse_up(CGPoint::new(100.0, 88.0), InputModifiers::SHIFT, &mut ed, &mut s);
        assert_eq!(ed.selected_layers(&s).len(), 3);
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(100.0, 150.0));
        assert!(ed.selected_layers(&s).is_empty());
    }

    #[test]
    fn the_eye_hides_a_layer_and_the_lock_locks_it() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        let id = d.rows()[0].layer_id();
        let eye = d.eye_frame(0);
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(eye.mid_x(), eye.mid_y()));
        assert!(!d.rows()[0].is_visible);
        let lock = d.lock_frame(0);
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(lock.mid_x(), lock.mid_y()));
        assert!(d.rows()[0].is_locked);
        assert_eq!(d.rows()[0].layer_id(), id);
    }

    #[test]
    fn footer_buttons_group_duplicate_and_delete() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        ed.select_all_layers(&mut s);
        let mid = |d: &GraphicsLayerListDraw, b| {
            let f = d.footer_frame(b);
            CGPoint::new(f.mid_x(), f.mid_y())
        };
        let p = mid(&d, FooterButton::Group);
        click(&mut d, &mut ed, &mut s, &mut cx, p);
        assert!(d.rows().iter().any(|r| r.group_id().is_some()));
        let p = mid(&d, FooterButton::Delete);
        click(&mut d, &mut ed, &mut s, &mut cx, p);
        assert!(d.rows().is_empty());
        let p = mid(&d, FooterButton::Text);
        click(&mut d, &mut ed, &mut s, &mut cx, p);
        assert_eq!(d.rows().len(), 1);
    }

    #[test]
    fn the_shape_button_asks_for_a_menu_and_flush_adds_the_shape() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        let f = d.footer_frame(FooterButton::Shape);
        click(&mut d, &mut ed, &mut s, &mut cx, CGPoint::new(f.mid_x(), f.mid_y()));
        let Some(menu) = d.take_menu() else { panic!("no menu") };
        assert_eq!(menu.items.len(), 4);
        if let Some(a) = &menu.items[1].action {
            a();
        }
        d.flush(&mut ed, &mut s);
        assert_eq!(d.rows().len(), 4);
    }

    #[test]
    fn double_click_renames_and_return_commits() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        d.mouse_down(CGPoint::new(100.0, 40.0), InputModifiers::NONE, Some(2), &mut ed, &mut s, &mut cx);
        assert!(d.rename_field().is_some());
        for ch in "Hero".chars() {
            assert!(d.key(InputKey::Character(ch), InputModifiers::NONE, &mut ed, &mut s, &mut cx));
        }
        assert!(d.key(InputKey::Enter, InputModifiers::NONE, &mut ed, &mut s, &mut cx));
        assert!(d.rename_field().is_none());
        assert_eq!(d.rows()[0].name, "Hero");
    }

    #[test]
    fn a_drag_moves_a_layer_with_the_insertion_line() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        let top = d.rows()[0].layer_id();
        d.mouse_down(CGPoint::new(100.0, 40.0), InputModifiers::NONE, Some(1), &mut ed, &mut s, &mut cx);
        d.mouse_dragged(CGPoint::new(100.0, 98.0), InputModifiers::NONE, &ed, &s);
        assert_eq!(d.drop_gap(), Some(3));
        d.mouse_up(CGPoint::new(100.0, 98.0), InputModifiers::NONE, &mut ed, &mut s);
        assert_eq!(d.rows()[2].layer_id(), top);
        assert_eq!(d.drop_gap(), None);
    }

    #[test]
    fn the_context_menu_lists_every_command_and_delete_removes_the_layer() {
        let (mut s, mut ed, mut d, mut cx) = setup();
        d.mouse_down(CGPoint::new(100.0, 40.0), InputModifiers::SECONDARY, Some(1), &mut ed, &mut s, &mut cx);
        let Some(menu) = d.take_menu() else { panic!("no menu") };
        assert_eq!(menu.items.len(), 17);
        let delete = &menu.items[16];
        assert!(delete.is_enabled);
        if let Some(a) = &delete.action {
            a();
        }
        d.flush(&mut ed, &mut s);
        assert_eq!(d.rows().len(), 2);
    }

    #[test]
    fn effects_dropped_on_a_row_select_it_and_refusals_come_back() {
        let (mut s, mut ed, mut d, _cx) = setup();
        d.effect_drag_over(Some(CGPoint::new(100.0, 64.0)));
        assert_eq!(d.effect_target(), Some(1));
        let kinds = vec!["no.such.effect".to_string()];
        let r = d.drop_effects(&kinds, CGPoint::new(100.0, 64.0), &mut ed, &mut s);
        assert_eq!(r, Some(EffectDrop::Refused("That is not a layer effect.".to_string())));
        assert_eq!(ed.selected_layers(&s).len(), 1);
        assert_eq!(d.effect_target(), None);
        assert_eq!(d.drop_effects(&kinds, CGPoint::new(100.0, 150.0), &mut ed, &mut s), None);
    }

    #[test]
    fn drawing_paints_without_panicking_and_help_names_the_buttons() {
        let (s, ed, mut d, mut cx) = setup();
        let mut c = Canvas::with_size(300.0, 200.0, None, 1.0);
        d.draw(&mut c, &ed, &s, true, &mut cx);
        let f = d.footer_frame(FooterButton::Text);
        assert_eq!(d.help(CGPoint::new(f.mid_x(), f.mid_y())).as_deref(), Some("+ Text"));
        let eye = d.eye_frame(0);
        assert_eq!(d.help(CGPoint::new(eye.mid_x(), eye.mid_y())).as_deref(), Some("Hide"));
    }
}
