// Swift: EffectKeyframeLanesDraw.swift
//! The keyframe lanes of Effect Controls on the shared toolkit: `EffectKeyframeLanesView` translated. Hit testing,
//! selection, the key drag (one undo step, Option leaves copies, Shift snaps), the marquee, zoom / pan and the key menu
//! are the Mac code paths on the same model calls; only drawing and event glue are new. Coordinates: lane points,
//! y down, (0, 0) = the lanes' top-left; rows are placed at `row.y - scroll_y` like the rows column beside them.

use std::collections::BTreeSet;

use crate::ec::prelude::*;
use sq_core_model::keyframes_editing::{SummaryKey, SummaryMember};
use sq_core_model::keyframes_premiere::KeyInterpolationChoice;
use sq_core_model::keyframes_speed_overlay::KeySide;
use sq_core_time::{EaseSide, EasingCurve, Id, Time};
use sq_draw::draw_list::Color;
use sq_draw::scroll::ScrollGesture;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, InspectorDraw, TextAlign};
use sq_editor_session::EffectSection;
use sq_editor_session::TimecodeFormat;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::key_glyph::{KeyGlyph, KeyShape};
use sq_uikit::keyframe_viewport::KeyframeSnap;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::inline_speed_graph_draw::OuterMarquee;
use super::{MenuEntry, MenuOutput, ModelMenu, PromptRequest, draw_marquee, offset_by, rect_from, text_in};
use crate::ec::controls_metrics::ControlsMetrics;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::lane_geometry::KeyframeLaneGeometry;
use crate::ec::effect_controls_model::layout::{EffectControlsLayout, EffectRow, EffectRowKind};
use crate::ec::effect_controls_model::premiere::SpatialChoice;
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::effect_controls_model::section::EffectSectionExt;
use crate::keyframes::easing_menu_spec::EasingMenuSpec;
use crate::keyframes::key_tools_input::{KeyToolPrompt, KeyToolsInput, SideSpeed};
use crate::keyframes::keyframe_ruler::KeyframeRulerLayout;
use crate::keyframes::keyframe_zoom_input::{KeyframeScroll, KeyframeZoomInput};
use crate::keyframes::property_track_glyphs::PropertyTrackGlyphs;
use sq_core_time::ease_names::ease_name;

const DRAG_THRESHOLD: f64 = 3.0;

/// What lies under a lane point.
#[derive(Clone, Debug, PartialEq)]
pub enum Hit {
    /// A key of a property row (property, key id, clip-local time).
    Key(EffectProperty, Id, Time),
    /// A summary key of a collapsed section.
    Summary(EffectSection, Time),
    /// A summary key of a closed color group.
    GroupSummary(Id, String, Time),
    /// Nothing.
    None,
}

enum Drag {
    Keys { down_x: f64, down_time: Time, started: bool, hit: Hit, shift: bool, was_selected: bool, duplicate: bool },
    Marquee { origin: CGPoint, base: BTreeSet<SummaryMember>, shift: bool },
}

type Glyph = (KeyShape, CGPoint, f64);

/// The keyframe lanes beside the rows column.
pub struct EffectKeyframeLanesDraw {
    /// The rows (shared with the rows column).
    pub rows: Vec<EffectRow>,
    /// Size of the lanes in points.
    pub size: CGSize,
    /// The rows column's scroll offset (the lanes scroll with it).
    pub scroll_y: f64,
    /// Where the rows column's content ends; the "No keyframes" hint starts below it.
    pub content_bottom: f64,
    /// True when the host can show a key tool dialog; false leaves those tools out of the menu (Swift `onPrompt != nil`).
    pub has_prompt: bool,
    drag: Option<Drag>,
    marquee: Option<CGRect>,
    hover_hit: Hit,
    escape_cancelled: bool,
    menu: Option<(ModelMenu, CGRect)>,
}

impl Default for EffectKeyframeLanesDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl EffectKeyframeLanesDraw {
    /// Hit radius of a key in points.
    pub const HIT_RADIUS: f64 = EffectKeyframeLanesGeometry::HIT_RADIUS;

    /// Empty lanes.
    pub fn new() -> EffectKeyframeLanesDraw {
        EffectKeyframeLanesDraw {
            rows: Vec::new(),
            size: CGSize::default(),
            scroll_y: 0.0,
            content_bottom: 0.0,
            has_prompt: false,
            drag: None,
            marquee: None,
            hover_hit: Hit::None,
            escape_cancelled: false,
            menu: None,
        }
    }

    /// The key menu a right click asked for (items and anchor in lane points); the host shows it with its one menu system.
    pub fn take_menu(&mut self) -> Option<(ModelMenu, CGRect)> {
        self.menu.take()
    }

    /// The marquee rectangle while one is dragged.
    pub fn marquee(&self) -> Option<CGRect> {
        self.marquee
    }

    fn geometry(&self, model: &EffectControlsModel) -> KeyframeLaneGeometry {
        model.lane_geometry(self.size.width)
    }
    fn content_y(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y + self.scroll_y)
    }

    // MARK: Drawing (EffectKeyframeLanesView.draw + buildCache)

    /// Draws the lanes.
    pub fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.lane()); // v9 `.kg > .r`
        let geo = self.geometry(model);
        let slack = Self::HIT_RADIUS * 2.0;
        let in_view = |x: f64| x >= -slack && x <= self.size.width + slack;
        let (mut plain, mut selected, mut tracked, mut tracked_selected): (
            Vec<Glyph>,
            Vec<Glyph>,
            Vec<Glyph>,
            Vec<Glyph>,
        ) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for row in &self.rows {
            let top = row.y - self.scroll_y;
            if !(top + row.height > 0.0 && top < self.size.height) {
                continue;
            }
            c.fill(CGRect::new(0.0, top + row.height - 1.0, self.size.width, 1.0), t.row_line()); // one 1 pt line per row
            let cy = top + row.height / 2.0;
            let side = ControlsMetrics::KEY_SIDE;
            match &row.kind {
                EffectRowKind::Property(p) => {
                    let sel = model.selected_key_ids(p);
                    for k in model.track_of(p).map(|t| t.glyphs()).unwrap_or_default() {
                        let x = geo.x(k.time);
                        if !in_view(x) {
                            continue;
                        }
                        let g = (k.glyph.shape(), CGPoint::new(x, cy), side);
                        if sel.contains(&k.id) { selected.push(g) } else { plain.push(g) }
                    }
                }
                EffectRowKind::Section(s) => {
                    if !self.shows_section_summary(model, s) {
                        continue;
                    }
                    for key in model.summary_keys(s) {
                        self.add_summary(model, &key, cy, &geo, &mut plain, &mut selected);
                    }
                }
                EffectRowKind::ColorGroup { effect, key } => {
                    if !self.shows_group_summary(model, *effect, key) {
                        continue;
                    }
                    for k in model.color_group_summary_keys(*effect, key) {
                        self.add_summary(model, &k, cy, &geo, &mut plain, &mut selected);
                    }
                }
                EffectRowKind::MaskControls(id) => {
                    let p = EffectProperty::MaskPath(*id);
                    let sel = model.selected_key_ids(&p);
                    for k in model.track_of(&p).map(|t| t.glyphs()).unwrap_or_default() {
                        let x = geo.x(k.time);
                        if !in_view(x) {
                            continue;
                        }
                        let g = (k.glyph.shape(), CGPoint::new(x, cy), side);
                        if sel.contains(&k.id) { selected.push(g) } else { plain.push(g) }
                    }
                    for k in model.magic_keys(*id) {
                        let x = geo.x(k.time);
                        if !in_view(x) {
                            continue;
                        }
                        let at = CGPoint::new(x, cy);
                        let on = sel.contains(&k.id);
                        if k.is_correction {
                            if on {
                                selected.push((KeyShape::Diamond, at, side))
                            } else {
                                plain.push((KeyShape::Diamond, at, side))
                            }
                        } else if on {
                            tracked_selected.push((KeyShape::Diamond, at, side * ControlsMetrics::TRACKED_KEY_SCALE));
                        } else {
                            tracked.push((KeyShape::Diamond, at, side * ControlsMetrics::TRACKED_KEY_SCALE));
                        }
                    }
                }
                _ => {}
            }
        }
        if let Some(hc) = self.hover_center(model) {
            let r = Self::HIT_RADIUS + 2.0;
            c.fill_rounded(CGRect::new(hc.x - r, hc.y - r, 2.0 * r, 2.0 * r), radius::SMALL as f64, t.fill_hover());
        }
        // v9 `.dm`: every key sits on a 1.5 pt ring of the lane color, so neighbors stay apart.
        for (shape, at, side) in plain.iter().chain(&selected) {
            Self::glyph(c, *shape, *at, *side, ControlsMetrics::KEY_RING, t.lane());
        }
        for (shape, at, side) in &tracked {
            Self::glyph(c, *shape, *at, *side, 0.0, t.keyframe_tracked());
        }
        for (shape, at, side) in &plain {
            Self::glyph(c, *shape, *at, *side, 0.0, t.keyframe());
        }
        for (shape, at, side) in selected.iter().chain(&tracked_selected) {
            Self::glyph(c, *shape, *at, *side, 0.0, t.accent());
        }
        if let Some(m) = self.marquee {
            draw_marquee(c, offset_by(m, 0.0, -self.scroll_y), t);
        }
        self.draw_empty_hint(model, c, t);
        if model.playhead_in_clip() {
            // v9 `.kph`: 2 pt
            c.fill(CGRect::new(geo.x(model.local_playhead()).round() - 1.0, 0.0, 2.0, self.size.height), t.playhead());
        }
        c.restore_gstate();
    }

    /// `KeyGlyphPath.add`: diamond = steady, circle = eased, square = hold, pointed square = hold ahead; `grow` widens
    /// the glyph on every side (the lane-colored ring under a key).
    // known limit: the diamond's 1.5 pt corner rounding is not drawn (the canvas fills straight polygons); upgrade with a
    // rounded-polygon primitive.
    pub fn glyph(c: &mut Canvas, shape: KeyShape, p: CGPoint, side: f64, grow: f64, color: Color) {
        let root2 = 2.0f64.sqrt();
        match shape {
            KeyShape::Diamond => c.fill_polygon(&InspectorDraw::diamond(p, side * root2 + 2.0 * grow * root2), color),
            KeyShape::Circle => {
                let d = side + 1.0 + 2.0 * grow; // v9 `.dm.k-e`: 10 pt beside the 9 pt diamond
                c.fill_ellipse(CGRect::new(p.x - d / 2.0, p.y - d / 2.0, d, d), color);
            }
            KeyShape::Ahead => c.fill_polygon(&KeyShape::Ahead.corners(p, (side + 2.0 * grow) / 0.82), color),
            KeyShape::Square => {
                let s = side + 2.0 * grow;
                c.fill_rounded(CGRect::new(p.x - s / 2.0, p.y - s / 2.0, s, s), 1.0 + grow, color);
            }
        }
    }

    fn add_summary(
        &self,
        model: &EffectControlsModel,
        key: &SummaryKey,
        cy: f64,
        geo: &KeyframeLaneGeometry,
        plain: &mut Vec<Glyph>,
        selected: &mut Vec<Glyph>,
    ) {
        let x = geo.x(key.time);
        if !(x >= -Self::HIT_RADIUS * 2.0 && x <= self.size.width + Self::HIT_RADIUS * 2.0) {
            return;
        }
        let g = (
            EffectKeyframeLanesGeometry::summary_glyph(key, model).shape(),
            CGPoint::new(x, cy),
            ControlsMetrics::KEY_SIDE,
        );
        if model.is_selected(key) { selected.push(g) } else { plain.push(g) }
    }

    /// "No keyframes" under the rows while the clip has no key (INTERACTION-AUDIT section 10, `EmptyStateView`).
    fn draw_empty_hint(&self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let bottom = self.rows.last().map_or(0.0, |r| r.y + r.height).max(self.content_bottom);
        let top = bottom - self.scroll_y;
        let h = self.size.height - top;
        if !(EffectKeyframeLanesGeometry::shows_no_keys_hint(model) && h >= 48.0) {
            return;
        }
        let mid_y = top + h / 2.0;
        text_in(
            c,
            &SQL10n::string("No keyframes"),
            CGRect::new(8.0, mid_y - 18.0, (self.size.width - 16.0).max(0.0), 16.0),
            type_size::BODY as f64,
            t.label2(),
            TextAlign::Center,
        );
        text_in(
            c,
            &SQL10n::string("Click a property's diamond to animate it"),
            CGRect::new(8.0, mid_y + 2.0, (self.size.width - 16.0).max(0.0), 14.0),
            type_size::CAPTION as f64,
            t.label3(),
            TextAlign::Center,
        );
    }

    /// A section or group row carries summary keys only while it is collapsed (a key never shows twice).
    pub fn shows_section_summary(&self, model: &EffectControlsModel, s: &EffectSection) -> bool {
        model.collapsed_sections().contains(s)
    }
    /// A color group row carries summary keys only while it is closed.
    pub fn shows_group_summary(&self, model: &EffectControlsModel, id: Id, key: &str) -> bool {
        !model.open_color_groups.contains(&EffectControlsModel::color_group_id(id, key))
    }

    // MARK: Hit testing (EffectKeyframeLanesView.hit)

    /// What lies under `p0` (lane points).
    pub fn hit(&self, model: &EffectControlsModel, p0: CGPoint) -> Hit {
        let p = self.content_y(p0);
        let Some(row) = EffectControlsLayout::row_at(p.y, &self.rows) else { return Hit::None };
        let geo = self.geometry(model);
        let start = model.clip().map_or(Time::ZERO, |c| c.start);
        match &row.kind {
            EffectRowKind::Property(prop) => {
                let ks = model.keys(prop);
                let locals: Vec<Time> = ks.iter().map(|k| k.1 - start).collect();
                if let Some(i) = geo.nearest_index(p.x, &locals, Self::HIT_RADIUS) {
                    return Hit::Key(prop.clone(), ks[i].0, locals[i]);
                }
            }
            EffectRowKind::Section(s) => {
                if self.shows_section_summary(model, s) {
                    let groups = model.summary_keys(s);
                    let times: Vec<Time> = groups.iter().map(|g| g.time).collect();
                    if let Some(i) = geo.nearest_index(p.x, &times, Self::HIT_RADIUS) {
                        return Hit::Summary(s.clone(), groups[i].time);
                    }
                }
            }
            EffectRowKind::ColorGroup { effect, key } => {
                if self.shows_group_summary(model, *effect, key) {
                    let groups = model.color_group_summary_keys(*effect, key);
                    let times: Vec<Time> = groups.iter().map(|g| g.time).collect();
                    if let Some(i) = geo.nearest_index(p.x, &times, Self::HIT_RADIUS) {
                        return Hit::GroupSummary(*effect, key.clone(), groups[i].time);
                    }
                }
            }
            EffectRowKind::MaskControls(id) => {
                let mp = EffectProperty::MaskPath(*id);
                let ks = model.lane_keys(&mp);
                let times: Vec<Time> = ks.iter().map(|k| k.1).collect();
                if let Some(i) = geo.nearest_index(p.x, &times, Self::HIT_RADIUS) {
                    return Hit::Key(mp, ks[i].0, ks[i].1);
                }
            }
            _ => {}
        }
        Hit::None
    }

    fn summary_at(model: &EffectControlsModel, h: &Hit) -> Option<SummaryKey> {
        match h {
            Hit::Summary(s, t) => model.summary_keys(s).into_iter().find(|k| k.time == *t),
            Hit::GroupSummary(id, key, t) => {
                model.color_group_summary_keys(*id, key).into_iter().find(|k| k.time == *t)
            }
            _ => None,
        }
    }

    fn select(model: &mut EffectControlsModel, h: &Hit, extend: bool) {
        match h {
            Hit::Key(p, id, _) => model.select_key(p, *id, extend),
            Hit::Summary(..) | Hit::GroupSummary(..) => {
                if let Some(k) = Self::summary_at(model, h) {
                    model.select_summary(&k, extend);
                }
            }
            Hit::None => {}
        }
    }

    fn is_selected(model: &EffectControlsModel, h: &Hit) -> bool {
        match h {
            Hit::Key(p, id, _) => model.selected_key_ids(p).contains(id),
            Hit::Summary(..) | Hit::GroupSummary(..) => {
                Self::summary_at(model, h).is_some_and(|k| model.is_selected(&k))
            }
            Hit::None => false,
        }
    }

    /// Center of the hovered glyph in lane points (nil = nothing hovered).
    fn hover_center(&self, model: &EffectControlsModel) -> Option<CGPoint> {
        let (row, time) = match &self.hover_hit {
            Hit::Key(p, _, t) => (self.rows.iter().find(|r| EffectKeyframeLanesGeometry::row_shows(r, p)), *t),
            Hit::Summary(s, t) => (self.rows.iter().find(|r| r.kind == EffectRowKind::Section(s.clone())), *t),
            Hit::GroupSummary(id, key, t) => {
                (self.rows.iter().find(|r| r.kind == EffectRowKind::ColorGroup { effect: *id, key: key.clone() }), *t)
            }
            Hit::None => return None,
        };
        let row = row?;
        Some(CGPoint::new(self.geometry(model).x(time), row.y - self.scroll_y + row.height / 2.0))
    }

    /// The hovered key's shape name (Linear, Eased, Hold, Hold Ahead): the tooltip.
    pub fn help(&self, model: &EffectControlsModel, p: CGPoint) -> Option<String> {
        let Hit::Key(prop, id, _) = self.hit(model, p) else { return None };
        let g = model.track_of(&prop)?.glyphs().into_iter().find(|g| g.id == id)?;
        Some(g.glyph.shape().title().to_string())
    }

    // MARK: Mouse (EffectKeyframeLanesView.mouseDown / Dragged / Up)

    /// The pointer moved over the lanes (`None`: it left).
    pub fn mouse_moved(&mut self, model: &EffectControlsModel, p: Option<CGPoint>) {
        if self.drag.is_some() {
            return;
        }
        self.hover_hit = p.map_or(Hit::None, |p| self.hit(model, p));
    }

    /// Press at `p0`.
    pub fn mouse_down(&mut self, model: &mut EffectControlsModel, p0: CGPoint, modifiers: InputModifiers) {
        self.escape_cancelled = false;
        if modifiers.contains(InputModifiers::SECONDARY) {
            self.context_menu(model, p0);
            return;
        }
        let p = self.content_y(p0);
        let shift = modifiers.contains(InputModifiers::SHIFT);
        let h = self.hit(model, p0);
        if h == Hit::None {
            if let Some(row) = EffectControlsLayout::row_at(p.y, &self.rows)
                && let EffectRowKind::Property(prop) = &row.kind
            {
                model.focused_property = Some(prop.clone());
            }
            let base = if shift { model.selection().clone() } else { BTreeSet::new() };
            if !shift {
                model.clear_selection();
            }
            self.drag = Some(Drag::Marquee { origin: p, base, shift });
            return;
        }
        let was = Self::is_selected(model, &h);
        if shift {
            Self::select(model, &h, true);
        } else if !was {
            Self::select(model, &h, false);
        }
        let down_time = self.geometry(model).time(p.x, model.frame_duration);
        self.drag = Some(Drag::Keys {
            down_x: p.x,
            down_time,
            started: false,
            hit: h,
            shift,
            was_selected: was,
            duplicate: false,
        });
    }

    /// Drag to `p0`.
    pub fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p0: CGPoint, modifiers: InputModifiers) {
        if self.escape_cancelled {
            return;
        }
        let p = self.content_y(p0);
        match self.drag.take() {
            Some(Drag::Keys { down_x, down_time, started, hit, shift, was_selected, duplicate }) => {
                let mut duplicate = duplicate;
                if !started {
                    if (p.x - down_x).abs() < DRAG_THRESHOLD {
                        self.drag =
                            Some(Drag::Keys { down_x, down_time, started, hit, shift, was_selected, duplicate });
                        return;
                    }
                    model.begin_gesture();
                    self.hover_hit = Hit::None;
                    duplicate = modifiers.contains(InputModifiers::OPTION); // Option-drag leaves copies behind
                }
                let geo = self.geometry(model);
                let now = geo.unclamped_time(p.x, model.frame_duration);
                let mut delta = now - down_time;
                if modifiers.contains(InputModifiers::SHIFT) {
                    // Shift snaps to the playhead and other keys
                    delta = model
                        .snapped_move_delta(delta, KeyframeSnap::THRESHOLD_POINTS / geo.points_per_second().max(1e-6));
                }
                model.move_selection(delta, duplicate);
                self.drag = Some(Drag::Keys { down_x, down_time, started: true, hit, shift, was_selected, duplicate });
            }
            Some(Drag::Marquee { origin, base, shift }) => {
                let r = rect_from(origin, p);
                self.marquee = Some(r);
                let mut sel: BTreeSet<SummaryMember> = if shift { base.clone() } else { BTreeSet::new() };
                sel.extend(self.marquee_members(model, r));
                model.select(&sel.into_iter().collect::<Vec<_>>(), false);
                self.drag = Some(Drag::Marquee { origin, base, shift });
            }
            None => {}
        }
    }

    /// Release at `p`.
    pub fn mouse_up(&mut self, model: &mut EffectControlsModel, p: CGPoint) {
        if self.escape_cancelled {
            self.escape_cancelled = false;
            return;
        }
        let drag = self.drag.take();
        self.marquee = None;
        if let Some(Drag::Keys { started, hit, shift, was_selected, .. }) = drag {
            if started {
                model.end_key_move(); // one undo step; the moved keys are deselected
            } else if was_selected && !shift {
                Self::select(model, &hit, false); // plain click on a selected key collapses the selection to it
            }
        }
        self.hover_hit = self.hit(model, p);
    }

    /// True while a key drag or a marquee runs.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some()
    }

    /// A marquee that started in an opened row's curve and reaches into the lanes (`externalMarquee` of the Mac view):
    /// `rect` in content coordinates, nil when it ends. Draws it here too and returns the lane keys inside; the caller
    /// owns the selection.
    pub fn external_marquee(&mut self, model: &EffectControlsModel, rect: Option<CGRect>) -> BTreeSet<SummaryMember> {
        let Some(rect) = rect else {
            self.marquee = None;
            return BTreeSet::new();
        };
        self.marquee = Some(rect);
        self.marquee_members(model, rect)
    }

    /// The keys a marquee (content coordinates) covers: every key of the rows it touches whose time lies under it.
    fn marquee_members(&self, model: &EffectControlsModel, r: CGRect) -> BTreeSet<SummaryMember> {
        let mut props: BTreeSet<EffectProperty> = BTreeSet::new();
        let mut group_summaries: Vec<SummaryKey> = Vec::new();
        for row in self.rows.iter().filter(|row| row.y < r.max_y() && row.y + row.height > r.min_y()) {
            match &row.kind {
                EffectRowKind::Property(p) => {
                    props.insert(p.clone());
                }
                EffectRowKind::MaskControls(id) => {
                    props.insert(EffectProperty::MaskPath(*id));
                }
                EffectRowKind::Section(s) if model.collapsed_sections().contains(s) => props.extend(s.key_properties()),
                EffectRowKind::ColorGroup { effect, key } => {
                    group_summaries.extend(model.color_group_summary_keys(*effect, key)); // closed groups only
                }
                _ => {}
            }
        }
        let geo = self.geometry(model);
        let fd = model.frame_duration;
        let half = Time::new(fd.value(), fd.timescale() * 2);
        let lo = geo.time(r.min_x(), fd) - half;
        let hi = geo.time(r.max_x(), fd) + half;
        let mut hit = model.keys_in(&(lo..=hi), &props);
        for k in group_summaries.iter().filter(|k| k.time >= lo && k.time <= hi) {
            hit.extend(k.members.iter().cloned());
        }
        hit
    }

    // MARK: Wheel and keys

    /// Horizontal wheel pans, Option / Ctrl + vertical zooms around the pointer; plain vertical is left to the rows.
    pub fn scroll(
        &self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        dx: f64,
        dy: f64,
        modifiers: InputModifiers,
        published: Option<&ScrollGesture>,
    ) -> bool {
        let geo = self.geometry(model);
        match KeyframeZoomInput::classify(dx, dy, modifiers, published) {
            KeyframeScroll::Zoom { factor } => {
                model.zoom(factor, Some(geo.seconds(p.x)));
                true
            }
            KeyframeScroll::Pan { points } => {
                model.pan_viewport(-points / geo.points_per_second().max(1e-6));
                true
            }
            KeyframeScroll::None => false,
        }
    }

    /// Escape during a key drag puts the keys back; + / - / \ zoom; Delete removes the selected keys (or the effect).
    pub fn key(&mut self, model: &mut EffectControlsModel, k: InputKey, modifiers: InputModifiers) -> bool {
        if k == InputKey::Escape && matches!(self.drag, Some(Drag::Keys { started: true, .. })) {
            let _ = model.move_selection(Time::ZERO, false);
            model.end_key_move();
            self.drag = None;
            self.marquee = None;
            self.escape_cancelled = true;
            return true;
        }
        if KeyframeZoomInput::key(k, modifiers, model) {
            return true;
        }
        match k {
            InputKey::Delete | InputKey::Backspace => {
                model.delete_selection_or_effect();
                true
            }
            _ => false,
        }
    }

    // MARK: Right-click menu (temporal interpolation, copy, paste, delete)

    /// Right click: selects what is under `p` and queues the key menu for the host (`take_menu`).
    pub fn context_menu(&mut self, model: &mut EffectControlsModel, p: CGPoint) {
        let h = self.hit(model, p);
        if h != Hit::None && !Self::is_selected(model, &h) {
            Self::select(model, &h, false);
        }
        if let Hit::Key(prop, _, _) = &h {
            model.focused_property = Some(prop.clone());
        }
        let menu = self.make_key_items(model, h != Hit::None);
        self.menu = Some((menu, CGRect::new(p.x, p.y, 0.0, 0.0)));
    }

    /// `EffectKeyframeLanesView.makeKeyItems`: the same entries; the dialogs go through the host's key tool prompt.
    pub fn make_key_items(&self, model: &EffectControlsModel, on_key: bool) -> ModelMenu {
        Self::key_items(model, on_key, self.has_prompt)
    }

    /// The key menu rows; `has_prompt` is whether the host can show the key tool dialogs.
    pub fn key_items(model: &EffectControlsModel, on_key: bool, has_prompt: bool) -> ModelMenu {
        let has = !model.selection().is_empty();
        let mut items: Vec<MenuEntry> = Vec::new();
        let plain = |title: &str, run: fn(&mut EffectControlsModel)| {
            MenuEntry::action(SQMenuItem::new(title), move |m, _| run(m))
        };
        if on_key && has {
            let ahead: Vec<KeyInterpolationChoice> =
                if model.selection_takes_hold_ahead() { vec![KeyInterpolationChoice::HoldAhead] } else { Vec::new() };
            let mut first = vec![
                KeyInterpolationChoice::Linear,
                KeyInterpolationChoice::EasyEase,
                KeyInterpolationChoice::EaseIn,
                KeyInterpolationChoice::EaseOut,
                KeyInterpolationChoice::Hold,
            ];
            first.extend(&ahead);
            for choice in first {
                items.push(MenuEntry::action(SQMenuItem::new(choice.title()), move |m, _| {
                    m.apply_interpolation(choice)
                }));
            }
            items.push(plain(ease_name::CUSTOM_MENU, |m| m.reveal_custom_curve()));
            let mut temporal_choices = vec![
                KeyInterpolationChoice::Linear,
                KeyInterpolationChoice::Bezier,
                KeyInterpolationChoice::AutoBezier,
                KeyInterpolationChoice::ContinuousBezier,
                KeyInterpolationChoice::Hold,
            ];
            temporal_choices.extend(&ahead);
            temporal_choices.extend([KeyInterpolationChoice::EaseIn, KeyInterpolationChoice::EaseOut]);
            let temporal: Vec<MenuEntry> = temporal_choices
                .into_iter()
                .map(|choice| {
                    MenuEntry::action(SQMenuItem::new(choice.full_title()), move |m, _| m.apply_interpolation(choice))
                })
                .collect();
            items.push(MenuEntry::submenu(SQMenuItem::new("Temporal Interpolation"), temporal));
            if model.has_selected_vector_key() {
                let spatial: Vec<MenuEntry> = SpatialChoice::ALL
                    .into_iter()
                    .map(|choice| {
                        MenuEntry::action(SQMenuItem::new(choice.title()), move |m, _| {
                            m.apply_spatial_interpolation(choice)
                        })
                    })
                    .collect();
                items.push(MenuEntry::submenu(SQMenuItem::new("Spatial Interpolation"), spatial));
            }
            items.push(MenuEntry::plain(SQMenuItem::separator()));
            if has_prompt {
                items.push(MenuEntry::action(SQMenuItem::new("Keyframe Velocity\u{2026}"), Self::ask_velocity));
                items.push(MenuEntry::action(SQMenuItem::new("Scale Time\u{2026}"), |_, out| {
                    out.push(MenuOutput::Prompt(PromptRequest {
                        prompt: KeyToolPrompt::scale_time(),
                        done: std::rc::Rc::new(|m, t| {
                            if let Some(r) = t.and_then(|t| t.first().and_then(|s| KeyToolsInput::time_scale_ratio(s)))
                            {
                                m.scale_selection_time(r.num, r.den);
                            }
                        }),
                    }));
                }));
            }
            if model.has_selected_vector_key() {
                items.push(MenuEntry::action(SQMenuItem::new("Rove"), |m, _| {
                    m.rove_selected_keys();
                }));
            }
            if has_prompt {
                items.push(MenuEntry::action(SQMenuItem::new("Loop\u{2026}"), |_, out| {
                    out.push(MenuOutput::Prompt(PromptRequest {
                        prompt: KeyToolPrompt::loop_prompt(),
                        done: std::rc::Rc::new(|m, t| {
                            if let Some(n) =
                                t.and_then(|t| t.first().and_then(|s| KeyToolsInput::whole_number(s, 1..=100)))
                            {
                                m.loop_selected_tracks(n);
                            }
                        }),
                    }));
                }));
            }
            items.push(MenuEntry::action(SQMenuItem::new("Convert to Keys"), |m, _| {
                m.bake_selected_keys(30);
            }));
            if has_prompt && has_selected_scalar_key(model) {
                items.push(MenuEntry::action(SQMenuItem::new("Wiggle\u{2026}"), |_, out| {
                    out.push(MenuOutput::Prompt(PromptRequest {
                        prompt: KeyToolPrompt::wiggle(),
                        done: std::rc::Rc::new(|m, t| {
                            let Some(t) = t else { return };
                            if t.len() >= 3
                                && let Some(r) = KeyToolsInput::wiggle(&t[0], &t[1], &t[2])
                            {
                                m.wiggle_selected_keys(r.per_second, r.amount, r.seed);
                            }
                        }),
                    }));
                }));
            }
            items.push(MenuEntry::plain(SQMenuItem::separator()));
            let mut presets: Vec<MenuEntry> = Vec::new();
            let mut curves = vec![
                EasingCurve::fast_start(),
                EasingCurve::fast_end(),
                EasingCurve::premiere_default(),
                EasingCurve::ease_out_100(),
                EasingCurve::ease_in_100(),
            ];
            curves.extend(model.easing_library.user_curves().iter().cloned());
            for c in curves {
                presets.push(MenuEntry::action(SQMenuItem::new(&EasingMenuSpec::title(&c)), move |m, _| {
                    m.apply_easing(&c, EaseSide::Both)
                }));
            }
            if has_prompt {
                presets.push(MenuEntry::plain(SQMenuItem::separator()));
                presets.push(MenuEntry::action(SQMenuItem::new("Save as preset\u{2026}"), |_, out| {
                    out.push(MenuOutput::Prompt(PromptRequest {
                        prompt: KeyToolPrompt::save_curve(),
                        done: std::rc::Rc::new(|m, t| {
                            let Some(name) = t.and_then(|t| {
                                t.first().map(|n| n.trim_matches(|c: char| c == ' ' || c == '\t').to_string())
                            }) else {
                                return;
                            };
                            if !name.is_empty() {
                                m.save_curve_from_selection(&name);
                            }
                        }),
                    }));
                }));
            }
            items.push(MenuEntry::submenu(SQMenuItem::new("Presets"), presets));
            items.push(MenuEntry::plain(SQMenuItem::separator()));
            let mut copy = SQMenuItem::new("Copy");
            copy.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('c');
            items.push(MenuEntry::action(copy, |m, _| {
                m.copy_keys();
            }));
        }
        if model.can_paste_keys() {
            let mut paste = SQMenuItem::new("Paste");
            paste.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('v');
            items.push(MenuEntry::action(paste, |m, _| {
                m.paste_keys();
            }));
        }
        if on_key && has {
            items.push(MenuEntry::plain(SQMenuItem::separator()));
            let mut del = SQMenuItem::new("Delete");
            del.shortcut = sq_uikit::key_binding_text::KeyBindingText::delete_hint_here();
            items.push(MenuEntry::action(del, |m, _| m.delete_selection()));
        }
        ModelMenu { entries: items }
    }

    fn ask_velocity(model: &mut EffectControlsModel, out: &mut Vec<MenuOutput>) {
        let Some(m) = model.selection().iter().next().cloned() else { return };
        let inc = model.graph_velocity(&m, KeySide::Incoming);
        let outg = model.graph_velocity(&m, KeySide::Outgoing);
        let Some(unit) = outg.as_ref().or(inc.as_ref()).map(|v| v.unit.clone()) else { return };
        let side = |v: &Option<crate::ec::key_tools::GraphVelocity>| {
            v.as_ref().map(|v| SideSpeed { speed: v.speed, influence: v.influence })
        };
        let (has_in, has_out) = (inc.is_some(), outg.is_some());
        out.push(MenuOutput::Prompt(PromptRequest {
            prompt: KeyToolPrompt::velocity(side(&inc), side(&outg), &unit),
            done: std::rc::Rc::new(move |m, t| {
                let Some(t) = t else { return };
                let r = KeyToolPrompt::velocity_answer(&t, has_in, has_out);
                if let Some(i) = r.incoming {
                    m.set_graph_velocity(i.speed, i.influence, KeySide::Incoming);
                }
                if let Some(o) = r.outgoing {
                    m.set_graph_velocity(o.speed, o.influence, KeySide::Outgoing);
                }
            }),
        }));
    }
}

/// The lanes as the opened rows' curves see them: the lane keys inside a marquee that left the curve.
pub struct LanesBeside<'a> {
    /// The lanes.
    pub lanes: &'a mut EffectKeyframeLanesDraw,
    /// Top of the opened row in content coordinates.
    pub row_y: f64,
}

impl OuterMarquee for LanesBeside<'_> {
    fn outer_marquee(&mut self, model: &EffectControlsModel, rect: Option<CGRect>) -> BTreeSet<SummaryMember> {
        let y = self.row_y;
        self.lanes.external_marquee(model, rect.map(|r| offset_by(r, 0.0, y)))
    }
}

/// The keyframe ruler above the lanes on the shared toolkit (`KeyframeRulerView` translated): ticks, short timecode labels,
/// the playhead; a press or drag scrubs the session playhead (Shift snaps to keys), the wheel zooms and pans.
pub struct KeyframeRulerDraw {
    /// Size in points.
    pub size: CGSize,
    dragging: bool,
    hover_x: Option<f64>,
}

impl Default for KeyframeRulerDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl KeyframeRulerDraw {
    /// A ruler without a size.
    pub fn new() -> KeyframeRulerDraw {
        KeyframeRulerDraw { size: CGSize::default(), dragging: false, hover_x: None }
    }

    fn geometry(&self, model: &EffectControlsModel) -> KeyframeLaneGeometry {
        model.lane_geometry(self.size.width)
    }

    /// Draws the ruler.
    pub fn draw(&self, model: &EffectControlsModel, c: &mut Canvas, t: &DrawTheme) {
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        let rh = self.size.height;
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.lane());
        if let Some(clip) = model.clip() {
            let geo = self.geometry(model);
            let tc = TimecodeFormat::new(model.frame_duration, false);
            // v9 `.kruler span`: a caption label with an 8 pt tick at its left, at the bottom of the row; minor ticks 4 pt.
            for tick in KeyframeRulerLayout::ticks(&geo, model.frame_duration, tc.nominal_fps) {
                let x = geo.x(tick.local).round();
                if tick.major {
                    c.fill(CGRect::new(x, rh - 8.0, 1.0, 8.0), t.ruler_line());
                    let label = KeyframeRulerLayout::short_label(
                        &tc.string_for_time(clip.start + tick.local, model.frame_duration),
                    );
                    text_in(
                        c,
                        &label,
                        CGRect::new(x + 4.0, 5.0, 80.0, 13.0),
                        type_size::CAPTION as f64,
                        t.label3(),
                        TextAlign::Left,
                    );
                } else {
                    c.fill(CGRect::new(x, rh - 4.0, 1.0, 4.0), t.ruler_minor());
                }
            }
            if let Some(hx) = self.hover_x
                && !self.dragging
            {
                c.fill(CGRect::new(hx.round() - 0.5, 0.0, 1.0, rh), t.label3());
            }
            if model.playhead_in_clip() {
                let x = geo.x(model.local_playhead()).round();
                c.fill(CGRect::new(x - 1.0, 0.0, 2.0, rh), t.playhead());
                // The same head and token as the timeline playhead (`DrawTheme::playhead_head`).
                t.playhead_head(x, 0.0).draw(c);
            }
        }
        c.fill(CGRect::new(0.0, rh - 1.0, self.size.width, 1.0), t.row_line());
        c.restore_gstate();
    }

    fn target(&self, model: &EffectControlsModel, p: CGPoint, shift: bool) -> Option<Time> {
        model.clip()?;
        let geo = self.geometry(model);
        let local = geo.time(p.x, model.frame_duration);
        Some(model.scrub_target(local, shift, KeyframeSnap::THRESHOLD_POINTS / geo.points_per_second().max(1e-6)))
    }

    /// The pointer moved over the ruler (`None`: it left).
    pub fn mouse_moved(&mut self, model: &EffectControlsModel, p: Option<CGPoint>) {
        self.hover_x = if model.clip().is_none() { None } else { p.map(|p| p.x) };
    }

    /// Press at `p`.
    pub fn mouse_down(&mut self, model: &mut EffectControlsModel, p: CGPoint, modifiers: InputModifiers) {
        if self.dragging {
            model.scrub_up();
            self.dragging = false; // a lost mouse-up must not leave the ruler stuck
        }
        if let Some(t) = self.target(model, p, modifiers.contains(InputModifiers::SHIFT)) {
            self.dragging = true;
            model.scrub_down(t);
        }
    }

    /// Drag to `p`.
    pub fn mouse_dragged(&mut self, model: &mut EffectControlsModel, p: CGPoint, modifiers: InputModifiers) {
        if !self.dragging {
            return;
        }
        if let Some(t) = self.target(model, p, modifiers.contains(InputModifiers::SHIFT)) {
            model.scrub_drag(t);
        }
    }

    /// Release.
    pub fn mouse_up(&mut self, model: &mut EffectControlsModel) {
        if self.dragging {
            model.scrub_up();
        }
        self.dragging = false;
    }

    /// Wheel: Option / Ctrl + vertical zooms around the pointer, horizontal pans.
    pub fn scroll(
        &self,
        model: &mut EffectControlsModel,
        p: CGPoint,
        dx: f64,
        dy: f64,
        modifiers: InputModifiers,
        published: Option<&ScrollGesture>,
    ) -> bool {
        let geo = self.geometry(model);
        match KeyframeZoomInput::classify(dx, dy, modifiers, published) {
            KeyframeScroll::Zoom { factor } => {
                model.zoom(factor, Some(geo.seconds(p.x)));
                true
            }
            KeyframeScroll::Pan { points } => {
                model.pan_viewport(-points / geo.points_per_second().max(1e-6));
                true
            }
            KeyframeScroll::None => false,
        }
    }
}

/// The lane rules shared by the Mac lanes view and the shared-toolkit lanes.
pub enum EffectKeyframeLanesGeometry {}

impl EffectKeyframeLanesGeometry {
    /// Hit radius of a key in points.
    pub const HIT_RADIUS: f64 = 6.0;

    /// Summary glyph: per side hold if every member is hold, eased if any member is eased, else linear.
    pub fn summary_glyph(key: &SummaryKey, model: &EffectControlsModel) -> KeyGlyph {
        let mut glyphs: Vec<KeyGlyph> = Vec::new();
        for m in &key.members {
            let prop = EffectProperty::from_raw_value(&m.property.0).unwrap_or(EffectProperty::Opacity);
            if let Some(g) = model.track_of(&prop).and_then(|t| t.glyphs().into_iter().find(|g| g.id == m.key_id)) {
                glyphs.push(g.glyph);
            }
        }
        KeyGlyph::merged(&glyphs)
    }

    /// True while the shown clip has no keyframe on any property or mask path.
    pub fn shows_no_keys_hint(model: &EffectControlsModel) -> bool {
        let Some(c) = model.clip() else { return false };
        !EffectControlsModel::all_properties(c).iter().any(|p| model.is_animated(p))
            && !c
                .masks()
                .iter()
                .any(|m| m.source() == sq_core_model::MaskSource::Magic && !model.magic_keys(m.id).is_empty())
    }

    /// The row whose lane carries the keys of `p`: its own row, or for a mask's Path the mask's controls row.
    pub fn row_shows(r: &EffectRow, p: &EffectProperty) -> bool {
        match &r.kind {
            EffectRowKind::Property(q) => q == p,
            EffectRowKind::MaskControls(id) => *p == EffectProperty::MaskPath(*id),
            _ => false,
        }
    }
}

/// True when a selected key sits on a number track (the only kind Wiggle applies to); `has_selected_scalar_key` of the model
/// needs `&mut` for its working clip, a menu only reads.
fn has_selected_scalar_key(model: &EffectControlsModel) -> bool {
    use sq_core_model::keyframes_editing::{KeyframeSummary, PropertyTrack};
    let Some(c) = model.clip() else { return false };
    let tracks = KeyframeSummary::new(EffectControlsModel::tracks_of(c)).tracks;
    model.selection().iter().any(|m| matches!(tracks.get(&m.property), Some(PropertyTrack::Scalar(_))))
}
