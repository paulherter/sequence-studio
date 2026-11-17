// Swift: InlineSpeedGraphDraw.swift
//! The right pane of an opened keyframe row on the shared toolkit: `InlineSpeedGraphView` and `SpeedGraphPainter`
//! translated (geometry and every edit stay in `SpeedGraphGeometry` / `EffectControlsModel`). One hill per drawn row in
//! the row's color, a faint 0 baseline and a dashed Steady line; handles of selected keys; press: handle > key > curve >
//! marquee; right click: the curve presets plus the row's key items. Coordinates: points, y down, (0, 0) = the pane's
//! top-left.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_model::keyframes_editing::SummaryMember;
use sq_core_model::keyframes_speed_hill::{EaseTrackSegment, SpeedHill};
use sq_core_time::{EaseSide, Id};
use sq_draw::draw_list::Color;
use sq_draw::{Canvas, DrawTheme, InspectorDraw};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqmenu_model::SQMenuItem;

use super::{MenuEntry, ModelMenu, draw_marquee, rect_from};
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::speed_graph::SpeedCurveChip;
use crate::keyframes::ease_handle_drag_math::EaseHandleDragMath;
use crate::keyframes::speed_graph_geometry::{SpeedGraphGeometry, SpeedGraphHit, SpeedGraphLook};

/// What the pane needs from the lanes beside it: a marquee that leaves the graph goes on over the lanes (Swift
/// `outerMarquee`; set by the panel).
pub trait OuterMarquee {
    /// The marquee in this pane's coordinates (`None` when it ends); returns the lane keys inside.
    fn outer_marquee(&mut self, model: &EffectControlsModel, rect: Option<CGRect>) -> BTreeSet<SummaryMember>;
}

/// No lanes beside the pane.
pub struct NoOuterMarquee;

impl OuterMarquee for NoOuterMarquee {
    fn outer_marquee(&mut self, _model: &EffectControlsModel, _rect: Option<CGRect>) -> BTreeSet<SummaryMember> {
        BTreeSet::new()
    }
}

/// A grabbed or hovered handle.
#[derive(Clone, Debug, PartialEq)]
pub struct Handle {
    /// The row.
    pub property: EffectProperty,
    /// The segment.
    pub segment: EaseTrackSegment,
    /// Which end.
    pub side: EaseSide,
}

impl Handle {
    fn is_same(&self, o: Option<&Handle>) -> bool {
        let Some(o) = o else { return false };
        self.property == o.property
            && self.segment.from == o.segment.from
            && self.segment.to == o.segment.to
            && self.side == o.side
    }
}

struct Marquee {
    origin: CGPoint,
    base: BTreeSet<SummaryMember>,
}

/// What one row draws.
#[derive(Clone, Copy)]
pub struct RowPaint<'a> {
    /// Width of the pane.
    pub width: f64,
    /// The row's segments.
    pub segments: &'a [EaseTrackSegment],
    /// Selected keys (handles and accent diamonds).
    pub selected: &'a BTreeSet<Id>,
    /// Curve color; alpha 0 draws keys and handles only.
    pub color: Color,
}

type Curves = Vec<(EffectProperty, Vec<EaseTrackSegment>)>;

/// The curve pane of one opened row.
pub struct InlineSpeedGraphDraw {
    /// The row this pane opened under.
    pub property: EffectProperty,
    /// Size of the pane in points.
    pub size: CGSize,
    drag: Option<Handle>,
    grab_offset: f64,
    grab_y: f64,
    press_y: f64,
    vertical: bool,
    hovered: Option<Handle>,
    marquee: Option<Marquee>,
    marquee_rect: Option<CGRect>,
}

impl InlineSpeedGraphDraw {
    /// A pane for `property`.
    pub fn new(property: EffectProperty) -> InlineSpeedGraphDraw {
        InlineSpeedGraphDraw {
            property,
            size: CGSize::default(),
            drag: None,
            grab_offset: 0.0,
            grab_y: 0.0,
            press_y: 0.0,
            vertical: false,
            hovered: None,
            marquee: None,
            marquee_rect: None,
        }
    }

    /// The marquee rectangle while one is dragged.
    pub fn marquee_rect(&self) -> Option<CGRect> {
        self.marquee_rect
    }
    /// The handle under the pointer.
    pub fn hovered(&self) -> Option<&Handle> {
        self.hovered.as_ref()
    }

    // MARK: Content (as the Mac view)

    fn curves(&self, model: &EffectControlsModel) -> Curves {
        model
            .speed_graph_rows(&self.property)
            .into_iter()
            .map(|p| {
                let s = model.speed_segments(&p);
                (p, s)
            })
            .collect()
    }

    /// The pane's geometry for the current rows.
    pub fn geometry(&self, model: &EffectControlsModel) -> SpeedGraphGeometry {
        let all: Vec<EaseTrackSegment> = self.curves(model).into_iter().flat_map(|c| c.1).collect();
        SpeedGraphGeometry::with(
            model.lane_geometry(self.size.width),
            self.size.height,
            SpeedGraphGeometry::peak_of(&all),
        )
    }

    fn hit(&self, model: &EffectControlsModel, p: CGPoint) -> (SpeedGraphHit, Curves) {
        let c = self.curves(model);
        let rows: Vec<Vec<EaseTrackSegment>> = c.iter().map(|r| r.1.clone()).collect();
        let selected: Vec<BTreeSet<Id>> = c.iter().map(|r| model.selected_key_ids(&r.0)).collect();
        (self.geometry(model).hit_test(p, &rows, &selected), c)
    }

    /// The handle at `p`.
    pub fn handle_at(&self, model: &EffectControlsModel, p: CGPoint) -> Option<Handle> {
        let (h, c) = self.hit(model, p);
        let SpeedGraphHit::Handle { row, segment, side } = h else { return None };
        Some(Handle { property: c[row].0.clone(), segment: c[row].1[segment].clone(), side })
    }

    /// Color of the n-th drawn row (`ControlsMetrics.curveColor`): accent, label, then the graph palette.
    pub fn curve_color(t: &DrawTheme, index: usize) -> Color {
        match index {
            0 => t.accent(),
            1 => t.label(),
            _ => {
                let palette = t.graph_curve();
                palette[(index - 2) % palette.len()]
            }
        }
    }

    // MARK: Drawing (SpeedGraphPainter)

    /// Draws the pane.
    pub fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        let geo = self.geometry(model);
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.content());
        let b = geo.baseline();
        let w = self.size.width;
        c.fill(CGRect::new(0.0, b.round(), w, 1.0), t.graph_grid());
        Self::dashed_h(c, (b - geo.unit_height()).round(), 0.0, w, t.graph_grid());
        c.fill(CGRect::new(0.0, self.size.height - 1.0, w, 1.0), t.separator());
        for (i, row) in self.curves(model).iter().enumerate() {
            let hovered = self.hovered.as_ref();
            let drag = self.drag.as_ref();
            let hot = |s: &EaseTrackSegment, side: EaseSide| {
                let this = Handle { property: row.0.clone(), segment: s.clone(), side };
                this.is_same(hovered) || this.is_same(drag)
            };
            let selected = model.selected_key_ids(&row.0);
            Self::draw_row(
                c,
                &geo,
                t,
                &RowPaint { width: w, segments: &row.1, selected: &selected, color: Self::curve_color(t, i) },
                &hot,
            );
        }
        if let Some(m) = self.marquee_rect {
            draw_marquee(c, m, t);
        }
        if model.playhead_in_clip() {
            c.fill(
                CGRect::new(model.lane_geometry(w).x(model.local_playhead()).round() - 1.0, 0.0, 2.0, self.size.height),
                t.playhead(),
            );
        }
        c.restore_gstate();
    }

    /// A 2-on / 3-off dashed hairline (CGContext `setLineDash([2, 3])`).
    pub fn dashed_h(c: &mut Canvas, y: f64, x0: f64, x1: f64, color: Color) {
        let mut x = x0;
        while x < x1 {
            c.fill(CGRect::new(x, y, 2.0f64.min(x1 - x), 1.0), color);
            x += 5.0;
        }
    }
    fn dashed_v(c: &mut Canvas, x: f64, y0: f64, y1: f64, color: Color) {
        let mut y = y0;
        while y < y1 {
            c.fill(CGRect::new(x, y, 1.0, 2.0f64.min(y1 - y)), color);
            y += 5.0;
        }
    }

    /// One row (SpeedGraphPainter.drawRow): the filled hill, key stems, the curve, handles of selected keys, the keys.
    pub fn draw_row(
        c: &mut Canvas,
        geo: &SpeedGraphGeometry,
        t: &DrawTheme,
        row: &RowPaint,
        hot: &dyn Fn(&EaseTrackSegment, EaseSide) -> bool,
    ) {
        let RowPaint { width, segments, selected, color } = *row;
        let (Some(first), Some(last)) = (segments.first(), segments.last()) else { return };
        let b = geo.baseline();
        let mut line = vec![CGPoint::new(0.0, b), CGPoint::new(geo.x(first, 0.0), b)];
        for s in segments {
            line.extend(geo.points(s));
        }
        line.extend([CGPoint::new(geo.x(last, 1.0), b), CGPoint::new(width, b)]);
        if color.a > 0.0 {
            c.fill_polygon(&line, color.with_alpha(SpeedGraphLook::FILL_ALPHA as f32));
        }
        for k in geo.key_points(segments) {
            Self::dashed_v(c, k.point.x.round(), 0.0, k.point.y, t.graph_grid());
        }
        if color.a > 0.0 {
            c.stroke_polyline(&line, SpeedGraphLook::CURVE_WIDTH, color);
        }
        for h in geo.visible_handles(segments, selected) {
            let s = &segments[h.segment];
            let k = geo.key(s, h.side);
            let e = geo.handle_end(s, h.side);
            let is_hot = hot(s, h.side);
            let y = k.y.round();
            c.fill(CGRect::new(k.x.min(e.x), y, (e.x - k.x).abs(), SpeedGraphLook::STEM_WIDTH), t.graph_handle_line());
            let d = SpeedGraphLook::KNOB_DIAMETER + if is_hot { 2.0 } else { 0.0 };
            let knob = CGRect::new(e.x - d / 2.0, y + 0.5 - d / 2.0, d, d);
            c.fill_ellipse(knob, if is_hot { t.accent() } else { t.label2() });
            c.fill_ellipse(knob.inset_by(SpeedGraphLook::KNOB_RING, SpeedGraphLook::KNOB_RING), t.content());
        }
        for k in geo.key_points(segments) {
            c.fill_polygon(
                &InspectorDraw::diamond(k.point, SpeedGraphLook::KEY_SIDE * 2.0f64.sqrt()),
                if selected.contains(&k.id) { t.accent() } else { t.keyframe() },
            );
        }
    }

    // MARK: Mouse (InlineSpeedGraphView.press / dragGesture / release)

    /// The pointer moved over the pane (`None`: it left).
    pub fn mouse_moved(&mut self, model: &EffectControlsModel, p: Option<CGPoint>) {
        if self.drag.is_some() || self.marquee.is_some() {
            return;
        }
        self.hovered = p.and_then(|p| self.handle_at(model, p));
    }

    /// Press at `p`.
    pub fn press(&mut self, model: &mut EffectControlsModel, p: CGPoint, shift: bool) {
        if self.begin_drag(model, p) {
            return;
        }
        let (h, c) = self.hit(model, p);
        match h {
            SpeedGraphHit::Handle { .. } => {}
            SpeedGraphHit::Key { row, id } => {
                let mut ids = model.selected_key_ids(&c[row].0);
                if shift {
                    if !ids.remove(&id) {
                        ids.insert(id);
                    }
                } else if !ids.contains(&id) {
                    ids = BTreeSet::from([id]);
                }
                Self::select(model, &c, &BTreeMap::from([(row, ids)]), !shift);
            }
            SpeedGraphHit::Curve { row, segment } => {
                let s = &c[row].1[segment];
                let ids: BTreeSet<Id> = if shift {
                    let mut u = model.selected_key_ids(&c[row].0);
                    u.extend([s.from, s.to]);
                    u
                } else {
                    BTreeSet::from([s.from, s.to])
                };
                Self::select(model, &c, &BTreeMap::from([(row, ids)]), !shift);
            }
            SpeedGraphHit::Empty => {
                if !shift {
                    model.clear_selection();
                }
                self.marquee =
                    Some(Marquee { origin: p, base: if shift { model.selection().clone() } else { BTreeSet::new() } });
            }
        }
    }

    /// Drag to `p`.
    pub fn drag_gesture(
        &mut self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        shift: bool,
        outer: &mut dyn OuterMarquee,
    ) {
        if self.drag.is_some() {
            self.continue_drag(model, p, shift);
            return;
        }
        let Some(m) = &self.marquee else { return };
        let rect = rect_from(m.origin, p);
        self.marquee_rect = Some(rect);
        let c = self.curves(model);
        let rows: Vec<Vec<EaseTrackSegment>> = c.iter().map(|r| r.1.clone()).collect();
        let selected: Vec<BTreeSet<Id>> = c
            .iter()
            .map(|row| m.base.iter().filter(|b| b.property == row.0.id()).map(|b| b.key_id).collect())
            .collect();
        let hits = self.geometry(model).keys_in(rect, &rows, &selected);
        let mut sel = m.base.clone();
        for (r, ids) in hits {
            for id in ids {
                sel.insert(SummaryMember::new(c[r].0.id(), id));
            }
        }
        sel.extend(outer.outer_marquee(model, Some(rect)));
        if &sel != model.selection() {
            let v: Vec<SummaryMember> = sel.into_iter().collect();
            model.select(&v, false);
        }
    }

    /// Release.
    pub fn release(&mut self, model: &mut EffectControlsModel, outer: &mut dyn OuterMarquee) {
        if self.drag.is_some() {
            self.end_drag(model);
            return;
        }
        if self.marquee.is_some() {
            let _ = outer.outer_marquee(model, None);
        }
        self.marquee = None;
        self.marquee_rect = None;
    }

    /// True while a handle or a marquee is dragged.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some() || self.marquee.is_some()
    }

    fn select(model: &mut EffectControlsModel, rows: &Curves, ids: &BTreeMap<usize, BTreeSet<Id>>, replacing: bool) {
        for (i, r) in rows.iter().enumerate() {
            if let Some(s) = ids.get(&i) {
                if &model.selected_key_ids(&r.0) != s {
                    model.set_selection_for(&r.0, s);
                }
            } else if replacing && !model.selected_key_ids(&r.0).is_empty() {
                model.set_selection_for(&r.0, &BTreeSet::new());
            }
        }
    }

    /// Starts a handle drag when `p` is on a handle.
    pub fn begin_drag(&mut self, model: &mut EffectControlsModel, p: CGPoint) -> bool {
        let Some(h) = self.handle_at(model, p) else { return false };
        let geo = self.geometry(model);
        self.grab_offset = geo.handle_true_end(&h.segment, h.side).x - p.x;
        let speed = if h.side == EaseSide::In { h.segment.shape.speed_in() } else { h.segment.shape.speed_out() };
        self.grab_y = geo.baseline() - speed * h.segment.scale * geo.unit_height() - p.y;
        self.press_y = p.y;
        self.vertical = false;
        model.select_speed_segment(&h.property, h.segment.from, h.segment.to);
        model.begin_gesture();
        self.drag = Some(h);
        true
    }

    /// One drag step of the grabbed handle.
    pub fn continue_drag(&mut self, model: &mut EffectControlsModel, p: CGPoint, shift: bool) {
        let Some(h) = self.drag.clone() else { return };
        let geo = self.geometry(model);
        let reach = geo.reach(p.x + self.grab_offset, &h.segment, h.side);
        self.vertical = EaseHandleDragMath::is_vertical(self.vertical, self.press_y, p.y, shift);
        if !(self.vertical && h.segment.scale > 0.0) {
            model.set_reach(reach, h.side, &self.property);
            return;
        }
        let pointer = geo.speed_at_y(p.y + self.grab_y) / h.segment.scale;
        let speed = EaseHandleDragMath::speed(true, pointer, 0.0, reach.max(SpeedHill::MIN_REACH), Some(&(-2.0..=3.0)));
        model.set_handle(reach, speed, h.side, &self.property, None);
    }

    /// Ends the handle drag.
    pub fn end_drag(&mut self, model: &mut EffectControlsModel) {
        if self.drag.is_none() {
            return;
        }
        model.end_gesture();
        self.drag = None;
    }

    // MARK: Right click (InlineSpeedGraphView.rightMouseDown)

    /// Selects what the right click is over (as the Mac view), then returns the menu: presets, then `extra` (the key items).
    pub fn context_menu(&self, model: &mut EffectControlsModel, p: CGPoint, extra: ModelMenu) -> ModelMenu {
        let (h, c) = self.hit(model, p);
        match h {
            SpeedGraphHit::Key { row, id } if !model.selected_key_ids(&c[row].0).contains(&id) => {
                Self::select(model, &c, &BTreeMap::from([(row, BTreeSet::from([id]))]), true);
            }
            SpeedGraphHit::Curve { row, segment } => {
                let s = &c[row].1[segment];
                let have = model.selected_key_ids(&c[row].0);
                if !(have.contains(&s.from) && have.contains(&s.to)) {
                    Self::select(model, &c, &BTreeMap::from([(row, BTreeSet::from([s.from, s.to]))]), true);
                }
            }
            _ => {}
        }
        self.curve_menu_items(model, extra)
    }

    /// Steady, Smooth, Smooth In, Smooth Out, Hold, Hold Ahead (applied to the selected keys), then the row's key items.
    pub fn curve_menu_items(&self, model: &EffectControlsModel, extra: ModelMenu) -> ModelMenu {
        let on = model.speed_chip(&self.property);
        let ahead = !self.property.is_animation_row() && model.selection_takes_hold_ahead();
        let mut menu = ModelMenu::default();
        for chip in SpeedCurveChip::ALL.into_iter().filter(|c| *c != SpeedCurveChip::HoldAhead || ahead) {
            let mut item = SQMenuItem::new(chip.title());
            item.is_checked = Some(chip) == on;
            let property = self.property.clone();
            menu.entries.push(MenuEntry::action(item, move |m, _| m.apply_speed_chip(chip, &property)));
        }
        if !extra.is_empty() {
            menu.entries.push(MenuEntry::plain(SQMenuItem::separator()));
            menu.extend(extra);
        }
        menu
    }
}
