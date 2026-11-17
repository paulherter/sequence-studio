// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+Editing.swift, and the Project verbs of Graphics.swift (`addGraphicsClip`, `addGraphicsLayer`)

use sq_core_model::graphics_item_range::GraphicsTextTime;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{
    AnimatedProperty, ClipEffect, EditError, GeneratorRef, GraphicsContent, GraphicsDocument, GraphicsGroup,
    GraphicsLayer, Project, ShapeKind,
};
use sq_core_time::{Id, IdSource, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// An axis-aligned rectangle in a graphic's canvas px: offset from the canvas center, y down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GraphicsRect {
    /// Left edge.
    pub min_x: f64,
    /// Top edge.
    pub min_y: f64,
    /// Right edge.
    pub max_x: f64,
    /// Bottom edge.
    pub max_y: f64,
}

impl GraphicsRect {
    /// `max_x - min_x`.
    pub fn width(&self) -> f64 {
        self.max_x - self.min_x
    }
    /// `max_y - min_y`.
    pub fn height(&self) -> f64 {
        self.max_y - self.min_y
    }
    /// Horizontal center.
    pub fn mid_x(&self) -> f64 {
        (self.min_x + self.max_x) / 2.0
    }
    /// Vertical center.
    pub fn mid_y(&self) -> f64 {
        (self.min_y + self.max_y) / 2.0
    }
    /// The smallest rectangle holding both.
    pub fn union(&self, o: &GraphicsRect) -> GraphicsRect {
        GraphicsRect {
            min_x: self.min_x.min(o.min_x),
            min_y: self.min_y.min(o.min_y),
            max_x: self.max_x.max(o.max_x),
            max_y: self.max_y.max(o.max_y),
        }
    }
    /// `p` lies inside or on the edge.
    pub fn contains(&self, p: Vec2) -> bool {
        p.x >= self.min_x && p.x <= self.max_x && p.y >= self.min_y && p.y <= self.max_y
    }
}

/// Measures a text layer: the rectangle its raster covers at the identity transform (offset from the canvas center), at
/// the item's text time (`GraphicsLayer::text_time`: range-local for an item with a range, as render draws it). Supplied
/// by the text renderer's owner (this crate cannot lay out text).
pub type GraphicsTextMeasure<'a> = &'a dyn Fn(&GeneratorRef, GraphicsTextTime) -> Option<GraphicsRect>;

/// Where Align puts the selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsAlign {
    /// Left edges.
    Left,
    /// Horizontal centers.
    CenterX,
    /// Right edges.
    Right,
    /// Top edges.
    Top,
    /// Vertical centers.
    CenterY,
    /// Bottom edges.
    Bottom,
}

/// The axis Distribute spreads along.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsAxis {
    /// Left to right.
    Horizontal,
    /// Top to bottom.
    Vertical,
}

/// How Reorder moves layers in the stack.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsReorder {
    /// One unit up.
    Forward,
    /// One unit down.
    Backward,
    /// To the top.
    Front,
    /// To the bottom.
    Back,
}

/// A corner handle of a layer's box, in `GraphicsLayerGeometryExt::corners` order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsCorner {
    /// Top left.
    TopLeft,
    /// Top right.
    TopRight,
    /// Bottom right.
    BottomRight,
    /// Bottom left.
    BottomLeft,
}

impl GraphicsCorner {
    /// The four corners in order.
    pub const ALL: [GraphicsCorner; 4] =
        [GraphicsCorner::TopLeft, GraphicsCorner::TopRight, GraphicsCorner::BottomRight, GraphicsCorner::BottomLeft];

    /// Side of the content center the corner is on (x, y: -1 or 1).
    fn sign(self) -> (f64, f64) {
        match self {
            GraphicsCorner::TopLeft => (-1.0, -1.0),
            GraphicsCorner::TopRight => (1.0, -1.0),
            GraphicsCorner::BottomRight => (1.0, 1.0),
            GraphicsCorner::BottomLeft => (-1.0, 1.0),
        }
    }

    /// The corner across the box.
    pub fn opposite(self) -> GraphicsCorner {
        match self {
            GraphicsCorner::TopLeft => GraphicsCorner::BottomRight,
            GraphicsCorner::TopRight => GraphicsCorner::BottomLeft,
            GraphicsCorner::BottomRight => GraphicsCorner::TopLeft,
            GraphicsCorner::BottomLeft => GraphicsCorner::TopRight,
        }
    }
}

/// A corner handle drag.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResizeDrag {
    /// The handle.
    pub corner: GraphicsCorner,
    /// Where the pointer is, canvas px.
    pub to: Vec2,
    /// Both sides by one factor.
    pub keep_aspect: bool,
}

/// The layer list verbs of a Graphic (Swift `extension GraphicsDocument`). `add` is `GraphicsDocument::add` in the model.
pub trait GraphicsDocumentEditingExt {
    /// Removes layers; a group left with fewer than two members dissolves, and a layer that followed a removed one is
    /// unpinned (G11).
    fn remove(&mut self, ids: &BTreeSet<Id>);
    /// Copies each layer right above its original, with fresh ids and outside any group. Returns the copies' ids. A copy
    /// that followed another layer of the same set follows that layer's copy (G11); other targets stay.
    fn duplicate(&mut self, ids: &[Id], new_ids: &mut dyn IdSource) -> Vec<Id>;
    /// Runs `body` on layer `id`.
    fn update(&mut self, id: Id, body: impl FnOnce(&mut GraphicsLayer));
    /// `ids` plus every member of a group one of them belongs to.
    fn expanded(&self, ids: &[Id]) -> BTreeSet<Id>;
    /// Groups the layers (with the groups they already belong to) under a new group; the members are gathered right below
    /// the topmost one, keeping their order. `None` (nothing changed) for fewer than two layers.
    fn group_layers(&mut self, ids: &[Id], name: &str, new_ids: &mut dyn IdSource) -> Option<Id>;
    /// Dissolves group `id`.
    fn ungroup(&mut self, id: Id);
    /// The selection as units that move together: each group touched is one unit, every other layer its own. Bottom first.
    fn units(&self, ids: &[Id]) -> Vec<Vec<Id>>;
    /// Moves the layers (whole groups when a member is named) one step or all the way up or down, keeping their order.
    fn reorder(&mut self, ids: &[Id], how: GraphicsReorder);
    /// Moves the layers to `index` of the list without them (0 = bottom), keeping their order.
    fn move_to_index(&mut self, ids: &BTreeSet<Id>, index: i64);
    /// Layer list drag: moves the layers to `index` (as `move_to_index`) and puts them into `group` (`None` or an unknown
    /// id = out of any group). A group left with fewer than two members dissolves.
    fn move_to_index_in_group(&mut self, ids: &BTreeSet<Id>, index: i64, group: Option<Id>);
    /// Option-drag in the layer list: copies of the layers go where `move_to_index_in_group` would put the layers (`index`
    /// counts the list without them); the originals stay. Copies of a whole group form a new group "<name> copy". Returns
    /// the copies' ids, bottom first.
    fn copy_to_index(
        &mut self,
        ids: &BTreeSet<Id>,
        index: i64,
        group: Option<Id>,
        new_ids: &mut dyn IdSource,
    ) -> Vec<Id>;
    /// Renames a group (trimmed; an empty name is ignored).
    fn rename_group(&mut self, id: Id, name: &str);
    /// Moves the layers (and their groups' other members) by `delta` canvas px; a keyed position moves with all its keys.
    /// Locked layers stay.
    fn translate(&mut self, ids: &[Id], delta: Vec2);
    /// The layer's on-canvas bounding box at clip-local `t` (Motion applied). `None` when it has no size: an empty shape, or a
    /// text layer without `text` measure.
    fn bounds_of(&self, id: Id, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect>;
    /// Aligns the selection: one unit (one layer or one group) to the canvas, several to their joint bounds. `to_frame`:
    /// every unit aligns to the canvas on its own, also when there are several.
    fn align(
        &mut self,
        ids: &[Id],
        edge: GraphicsAlign,
        canvas: Vec2,
        t: Time,
        text: Option<GraphicsTextMeasure>,
        to_frame: bool,
    );
    /// Spreads three or more units so the gaps between them are equal; the outermost two stay.
    fn distribute(&mut self, ids: &[Id], axis: GraphicsAxis, t: Time, text: Option<GraphicsTextMeasure>);
    /// Corner handle drag: the layer's `corner` goes to canvas point `p`, the opposite corner stays. Shapes and paths change
    /// Width x Height (a line only its length; `keep_aspect`: both by one factor), text changes its Scale uniformly. Keyed
    /// properties get a key at `t`. Locked layers and layers without a size stay.
    fn resize(
        &mut self,
        id: Id,
        drag: ResizeDrag,
        t: Time,
        text: Option<GraphicsTextMeasure>,
        new_ids: &mut dyn IdSource,
    );
    /// The topmost visible, unlocked layer whose bounds contain canvas point `p` at clip-local `t` (selection click).
    fn hit_test(&self, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Id>;
    /// Every pickable layer under `p`, topmost first (the list order of a deep select).
    fn hit_stack(&self, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Vec<Id>;
    /// Marquee: every pickable layer whose bounds touch `rect` (canvas px).
    fn layers_touching(&self, rect: &GraphicsRect, t: Time, text: Option<GraphicsTextMeasure>) -> BTreeSet<Id>;
    /// Deep select: the next layer under `p` below `current` (the one the last click picked); wraps to the top. Without
    /// `current` in the stack it is the topmost.
    fn hit_below(&self, current: Option<Id>, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Id>;
    /// Where Select Layer Above / Below goes from `selection`: one step from the topmost (up) or lowest (down) selected
    /// layer; with nothing selected the top (up) or bottom (down) pickable layer.
    fn step_target(&self, selection: &BTreeSet<Id>, up: bool) -> Option<Id>;
    /// The layer one step above (`up`) or below `id` in the stack that is visible and unlocked; `None` at the end.
    fn neighbor(&self, id: Id, up: bool) -> Option<Id>;
}

fn pickable(l: &GraphicsLayer) -> bool {
    l.is_visible && !l.is_locked
}

fn fresh_copy(l: &GraphicsLayer, new_ids: &mut dyn IdSource) -> GraphicsLayer {
    let mut c = l.clone();
    c.id = new_ids.next_id();
    c.animation.position = c.animation.position.with_fresh_key_ids(new_ids);
    c.animation.scale = c.animation.scale.with_fresh_key_ids(new_ids);
    c.animation.rotation = c.animation.rotation.with_fresh_key_ids(new_ids);
    c.animation.opacity = c.animation.opacity.with_fresh_key_ids(new_ids);
    c.animation.anchor = c.animation.anchor.with_fresh_key_ids(new_ids);
    for e in &mut c.effects {
        e.id = new_ids.next_id();
    }
    c
}

/// A group left with fewer than two members dissolves.
fn prune_groups(doc: &mut GraphicsDocument) {
    let mut count: BTreeMap<Id, usize> = BTreeMap::new();
    for l in &doc.layers {
        if let Some(g) = l.group {
            *count.entry(g).or_insert(0) += 1;
        }
    }
    let dead: BTreeSet<Id> =
        doc.groups.iter().map(|g| g.id).filter(|g| count.get(g).copied().unwrap_or(0) < 2).collect();
    if dead.is_empty() {
        return;
    }
    doc.groups.retain(|g| !dead.contains(&g.id));
    for l in &mut doc.layers {
        if l.group.is_some_and(|g| dead.contains(&g)) {
            l.group = None;
        }
    }
}

fn unit_bounds(doc: &GraphicsDocument, u: &[Id], t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect> {
    let rs: Vec<GraphicsRect> = u.iter().filter_map(|id| doc.bounds_of(*id, t, text)).collect();
    let first = *rs.first()?;
    Some(rs.iter().skip(1).fold(first, |a, b| a.union(b)))
}

fn translate_unit(doc: &mut GraphicsDocument, u: &[Id], d: Vec2) {
    for l in &mut doc.layers {
        if u.contains(&l.id) && !l.is_locked {
            l.animation.position = l.animation.position.offset_by(d);
        }
    }
}

fn set_param(e: &mut ClipEffect, key: &str, v: f64, t: Time, ids: &mut dyn IdSource) {
    let mut prop = e.parameters.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(v));
    prop.set_at_local(v, t, ids);
    e.parameters.insert(key.to_string(), prop);
}

impl GraphicsDocumentEditingExt for GraphicsDocument {
    fn remove(&mut self, ids: &BTreeSet<Id>) {
        self.layers.retain(|l| !ids.contains(&l.id));
        for l in &mut self.layers {
            if matches!(l.follow.as_ref().map(|f| f.target), Some(sq_core_model::FollowTarget::Layer(t)) if ids.contains(&t))
            {
                l.follow = None;
            }
        }
        prune_groups(self);
    }

    fn duplicate(&mut self, ids: &[Id], new_ids: &mut dyn IdSource) -> Vec<Id> {
        let mut out = Vec::new();
        let mut copy_of: BTreeMap<Id, Id> = BTreeMap::new();
        for id in ids {
            if copy_of.contains_key(id) {
                continue;
            }
            let Some(i) = self.index_of(*id) else { continue };
            let mut c = fresh_copy(&self.layers[i], new_ids);
            c.group = None;
            c.name = format!("{} copy", self.layers[i].name);
            out.push(c.id);
            copy_of.insert(*id, c.id);
            self.layers.insert(i + 1, c);
        }
        for cid in &out {
            let Some(i) = self.index_of(*cid) else { continue };
            let Some(sq_core_model::FollowTarget::Layer(t)) = self.layers[i].follow.as_ref().map(|f| f.target) else {
                continue;
            };
            if let (Some(nt), Some(f)) = (copy_of.get(&t), self.layers[i].follow.as_mut()) {
                f.target = sq_core_model::FollowTarget::Layer(*nt);
            }
        }
        out
    }

    fn update(&mut self, id: Id, body: impl FnOnce(&mut GraphicsLayer)) {
        if let Some(i) = self.index_of(id) {
            body(&mut self.layers[i]);
        }
    }

    fn expanded(&self, ids: &[Id]) -> BTreeSet<Id> {
        let set: BTreeSet<Id> = ids.iter().copied().collect();
        let gs: BTreeSet<Id> = self.layers.iter().filter(|l| set.contains(&l.id)).filter_map(|l| l.group).collect();
        let mut out = set;
        out.extend(self.layers.iter().filter(|l| l.group.is_some_and(|g| gs.contains(&g))).map(|l| l.id));
        out
    }

    fn group_layers(&mut self, ids: &[Id], name: &str, new_ids: &mut dyn IdSource) -> Option<Id> {
        let members = self.expanded(ids);
        let top = self.layers.iter().rposition(|l| members.contains(&l.id))?;
        if members.len() < 2 {
            return None;
        }
        let g = GraphicsGroup::new(new_ids.next_id(), name);
        let old: BTreeSet<Id> =
            self.layers.iter().filter(|l| members.contains(&l.id)).filter_map(|l| l.group).collect();
        self.groups.retain(|x| !old.contains(&x.id));
        self.groups.push(g.clone());
        let moving: Vec<GraphicsLayer> = self
            .layers
            .iter()
            .filter(|l| members.contains(&l.id))
            .map(|l| GraphicsLayer { group: Some(g.id), ..l.clone() })
            .collect();
        let below = self.layers[..top].iter().filter(|l| !members.contains(&l.id)).cloned();
        let above = self.layers[top + 1..].iter().filter(|l| !members.contains(&l.id)).cloned();
        self.layers = below.chain(moving).chain(above).collect();
        Some(g.id)
    }

    fn ungroup(&mut self, id: Id) {
        self.groups.retain(|g| g.id != id);
        for l in &mut self.layers {
            if l.group == Some(id) {
                l.group = None;
            }
        }
    }

    fn units(&self, ids: &[Id]) -> Vec<Vec<Id>> {
        let set: BTreeSet<Id> = ids.iter().copied().collect();
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        let touched: BTreeSet<Id> =
            self.layers.iter().filter(|l| set.contains(&l.id)).filter_map(|l| l.group).collect();
        for l in self.layers.iter().filter(|l| set.contains(&l.id) || l.group.is_some_and(|g| touched.contains(&g))) {
            if let Some(g) = l.group {
                if !seen.insert(g) {
                    continue;
                }
                out.push(self.layers.iter().filter(|x| x.group == Some(g)).map(|x| x.id).collect());
            } else {
                out.push(vec![l.id]);
            }
        }
        out
    }

    fn reorder(&mut self, ids: &[Id], how: GraphicsReorder) {
        let set = self.expanded(ids);
        if set.is_empty() {
            return;
        }
        let rest_count = self.layers.iter().filter(|l| !set.contains(&l.id)).count() as i64;
        match how {
            GraphicsReorder::Front => self.move_to_index(&set, rest_count),
            GraphicsReorder::Back => self.move_to_index(&set, 0),
            GraphicsReorder::Forward | GraphicsReorder::Backward => {
                // One step = past the next unit (a group counts as one) above / below the selection.
                let (Some(lo), Some(hi)) = (
                    self.layers.iter().position(|l| set.contains(&l.id)),
                    self.layers.iter().rposition(|l| set.contains(&l.id)),
                ) else {
                    return;
                };
                let below = self.layers[..lo].iter().filter(|l| !set.contains(&l.id)).count() as i64;
                let size_of = |l: &GraphicsLayer| -> i64 {
                    l.group.map_or(1, |g| {
                        self.layers.iter().filter(|x| x.group == Some(g) && !set.contains(&x.id)).count() as i64
                    })
                };
                let target = if how == GraphicsReorder::Forward {
                    if hi + 1 >= self.layers.len() {
                        return;
                    }
                    let size = size_of(&self.layers[hi + 1]);
                    self.layers[..=hi].iter().filter(|l| !set.contains(&l.id)).count() as i64 + size
                } else {
                    if lo == 0 {
                        return;
                    }
                    below - size_of(&self.layers[lo - 1])
                };
                self.move_to_index(&set, target.clamp(0, rest_count));
            }
        }
    }

    fn move_to_index(&mut self, ids: &BTreeSet<Id>, index: i64) {
        let moving: Vec<GraphicsLayer> = self.layers.iter().filter(|l| ids.contains(&l.id)).cloned().collect();
        let mut rest: Vec<GraphicsLayer> = self.layers.iter().filter(|l| !ids.contains(&l.id)).cloned().collect();
        let at = index.clamp(0, rest.len() as i64) as usize;
        rest.splice(at..at, moving);
        self.layers = rest;
    }

    fn move_to_index_in_group(&mut self, ids: &BTreeSet<Id>, index: i64, group: Option<Id>) {
        self.move_to_index(ids, index);
        let g = group.filter(|g| self.groups.iter().any(|x| x.id == *g));
        for l in &mut self.layers {
            if ids.contains(&l.id) {
                l.group = g;
            }
        }
        prune_groups(self);
    }

    fn copy_to_index(
        &mut self,
        ids: &BTreeSet<Id>,
        index: i64,
        group: Option<Id>,
        new_ids: &mut dyn IdSource,
    ) -> Vec<Id> {
        let originals: Vec<Id> = self.layers.iter().filter(|l| ids.contains(&l.id)).map(|l| l.id).collect();
        if originals.is_empty() {
            return Vec::new();
        }
        let rest: Vec<&GraphicsLayer> = self.layers.iter().filter(|l| !ids.contains(&l.id)).collect();
        let anchor = usize::try_from(index).ok().and_then(|i| rest.get(i)).map(|l| l.id);
        let mut work = self.clone();
        let copies = work.duplicate(&originals, new_ids);
        let mut made: Vec<GraphicsLayer> = copies.iter().filter_map(|c| work.layer(*c).cloned()).collect();
        let mut g = group.filter(|g| self.groups.iter().any(|x| x.id == *g));
        if let Some(own) = g {
            let members: BTreeSet<Id> = self.layers.iter().filter(|l| l.group == Some(own)).map(|l| l.id).collect();
            if members == *ids {
                let name = self.group(own).map_or("Group", |g| g.name.as_str());
                let n = GraphicsGroup::new(new_ids.next_id(), &format!("{name} copy"));
                g = Some(n.id);
                self.groups.push(n);
            }
        }
        for m in &mut made {
            m.group = g;
        }
        let at = anchor.and_then(|a| self.index_of(a)).unwrap_or(self.layers.len());
        self.layers.splice(at..at, made);
        prune_groups(self);
        copies
    }

    // shortcut: `str::trim` instead of Foundation's whitespacesAndNewlines set (differs for U+200B and U+FEFF), upgrade when
    // `sq_core_time::text` has the shared trim helper.
    fn rename_group(&mut self, id: Id, name: &str) {
        let n = name.trim();
        if n.is_empty() {
            return;
        }
        if let Some(g) = self.groups.iter_mut().find(|g| g.id == id) {
            g.name = n.to_string();
        }
    }

    fn translate(&mut self, ids: &[Id], delta: Vec2) {
        let set = self.expanded(ids);
        for l in &mut self.layers {
            if set.contains(&l.id) && !l.is_locked {
                l.animation.position = l.animation.position.offset_by(delta);
            }
        }
    }

    fn bounds_of(&self, id: Id, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect> {
        self.layer(id)?.bounds(t, text)
    }

    fn align(
        &mut self,
        ids: &[Id],
        edge: GraphicsAlign,
        canvas: Vec2,
        t: Time,
        text: Option<GraphicsTextMeasure>,
        to_frame: bool,
    ) {
        let us: Vec<(Vec<Id>, GraphicsRect)> =
            self.units(ids).into_iter().filter_map(|u| unit_bounds(self, &u, t, text).map(|b| (u, b))).collect();
        let Some(first) = us.first().map(|x| x.1) else { return };
        let r = if us.len() == 1 || to_frame {
            GraphicsRect {
                min_x: -canvas.x / 2.0,
                min_y: -canvas.y / 2.0,
                max_x: canvas.x / 2.0,
                max_y: canvas.y / 2.0,
            }
        } else {
            us.iter().skip(1).fold(first, |a, x| a.union(&x.1))
        };
        for (u, b) in &us {
            let d = match edge {
                GraphicsAlign::Left => Vec2::new(r.min_x - b.min_x, 0.0),
                GraphicsAlign::CenterX => Vec2::new(r.mid_x() - b.mid_x(), 0.0),
                GraphicsAlign::Right => Vec2::new(r.max_x - b.max_x, 0.0),
                GraphicsAlign::Top => Vec2::new(0.0, r.min_y - b.min_y),
                GraphicsAlign::CenterY => Vec2::new(0.0, r.mid_y() - b.mid_y()),
                GraphicsAlign::Bottom => Vec2::new(0.0, r.max_y - b.max_y),
            };
            if d != Vec2::new(0.0, 0.0) {
                translate_unit(self, u, d);
            }
        }
    }

    fn distribute(&mut self, ids: &[Id], axis: GraphicsAxis, t: Time, text: Option<GraphicsTextMeasure>) {
        let h = axis == GraphicsAxis::Horizontal;
        let mut us: Vec<(Vec<Id>, GraphicsRect)> =
            self.units(ids).into_iter().filter_map(|u| unit_bounds(self, &u, t, text).map(|b| (u, b))).collect();
        if us.len() < 3 {
            return;
        }
        let mid = |b: &GraphicsRect| if h { b.mid_x() } else { b.mid_y() };
        us.sort_by(|a, b| mid(&a.1).partial_cmp(&mid(&b.1)).unwrap_or(std::cmp::Ordering::Equal));
        let lo = if h { us[0].1.min_x } else { us[0].1.min_y };
        let hi = us.iter().map(|x| if h { x.1.max_x } else { x.1.max_y }).fold(f64::NEG_INFINITY, f64::max);
        let sizes: Vec<f64> = us.iter().map(|x| if h { x.1.width() } else { x.1.height() }).collect();
        let gap = (hi - lo - sizes.iter().sum::<f64>()) / (us.len() - 1) as f64;
        let mut cursor = lo;
        for (k, (u, b)) in us.iter().enumerate() {
            let start = if h { b.min_x } else { b.min_y };
            if k > 0 && k < us.len() - 1 {
                let d = cursor - start;
                if d != 0.0 {
                    translate_unit(self, u, if h { Vec2::new(d, 0.0) } else { Vec2::new(0.0, d) });
                }
            }
            cursor += sizes[k] + gap;
        }
    }

    fn resize(
        &mut self,
        id: Id,
        drag: ResizeDrag,
        t: Time,
        text: Option<GraphicsTextMeasure>,
        new_ids: &mut dyn IdSource,
    ) {
        let ResizeDrag { corner, to: p, keep_aspect } = drag;
        let Some(i) = self.index_of(id) else { return };
        if self.layers[i].is_locked {
            return;
        }
        let Some(r) = self.layers[i].content_rect(t, text) else { return };
        let mut l = self.layers[i].clone();
        let m = motion(&l, t);
        let c = Vec2::new(r.mid_x(), r.mid_y());
        let (hw, hh) = (r.width() / 2.0, r.height() / 2.0);
        let o = corner.opposite().sign();
        let k = corner.sign();
        let fixed = m.apply(c, Vec2::new(o.0 * hw, o.1 * hh));
        // Pointer relative to the fixed corner, in the layer's rotated frame (scaled px).
        let d = m.unrotate(p - fixed);
        let sx = m.scale.x.abs().max(1e-6);
        let sy = m.scale.y.abs().max(1e-6);
        if l.is_text() {
            let diag = Vec2::new(k.0 * r.width() * sx, k.1 * r.height() * sy);
            let len2 = diag.x * diag.x + diag.y * diag.y;
            if len2 <= 0.0 {
                return;
            }
            let f = ((d.x * diag.x + d.y * diag.y) / len2).max(0.01);
            let s1 = m.scale * f;
            l.animation.scale.set_at_local(s1, t, new_ids);
            let mut m1 = m;
            m1.scale = s1;
            let pos = m.position + fixed - m1.apply(c, Vec2::new(o.0 * hw, o.1 * hh));
            l.animation.position.set_at_local(pos, t, new_ids);
        } else {
            let Some(st) = l.shape_style(t) else { return };
            let is_line = st.kind == ShapeKind::Line && st.path.is_none();
            let mut w = (k.0 * d.x / sx).max(1.0);
            let mut h = if is_line { st.height } else { (k.1 * d.y / sy).max(1.0) };
            if keep_aspect && r.width() > 0.0 && r.height() > 0.0 {
                let f = if is_line {
                    w / r.width()
                } else {
                    ((k.0 * d.x / sx) / r.width()).max((k.1 * d.y / sy) / r.height())
                };
                w = (r.width() * f).max(1.0);
                h = if is_line { st.height } else { (r.height() * f).max(1.0) };
            }
            let Some(e) = l.effects.iter().position(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND) else { return };
            set_param(&mut l.effects[e], ClipEffect::SHAPE_WIDTH_KEY, w, t, new_ids);
            if !is_line {
                set_param(&mut l.effects[e], ClipEffect::SHAPE_HEIGHT_KEY, h, t, new_ids);
            }
            let hh1 = if is_line { hh } else { h / 2.0 };
            let q = Vec2::new(o.0 * w / 2.0, o.1 * hh1);
            let pos = m.position + fixed - m.apply(Vec2::new(0.0, 0.0), q);
            l.animation.position.set_at_local(pos, t, new_ids);
        }
        self.layers[i] = l;
    }

    fn hit_test(&self, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Id> {
        self.hit_stack(p, t, text).first().copied()
    }

    fn hit_stack(&self, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Vec<Id> {
        self.layers
            .iter()
            .rev()
            .filter(|l| pickable(l) && l.is_shown(t) && l.bounds(t, text).is_some_and(|b| b.contains(p)))
            .map(|l| l.id)
            .collect()
    }

    fn layers_touching(&self, rect: &GraphicsRect, t: Time, text: Option<GraphicsTextMeasure>) -> BTreeSet<Id> {
        self.layers
            .iter()
            .filter(|l| {
                if !pickable(l) || !l.is_shown(t) {
                    return false;
                }
                let Some(b) = l.bounds(t, text) else { return false };
                b.min_x <= rect.max_x && b.max_x >= rect.min_x && b.min_y <= rect.max_y && b.max_y >= rect.min_y
            })
            .map(|l| l.id)
            .collect()
    }

    fn hit_below(&self, current: Option<Id>, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Id> {
        let stack = self.hit_stack(p, t, text);
        let Some(i) = current.and_then(|c| stack.iter().position(|x| *x == c)) else { return stack.first().copied() };
        Some(stack[(i + 1) % stack.len()])
    }

    fn step_target(&self, selection: &BTreeSet<Id>, up: bool) -> Option<Id> {
        let idx = selection.iter().filter_map(|id| self.index_of(*id));
        let edge = if up { idx.max() } else { idx.min() };
        let Some(edge) = edge else {
            return if up {
                self.layers.iter().rev().find(|l| pickable(l)).map(|l| l.id)
            } else {
                self.layers.iter().find(|l| pickable(l)).map(|l| l.id)
            };
        };
        self.neighbor(self.layers[edge].id, up)
    }

    fn neighbor(&self, id: Id, up: bool) -> Option<Id> {
        let i = self.index_of(id)?;
        if up {
            self.layers[i + 1..].iter().find(|l| pickable(l)).map(|l| l.id)
        } else {
            self.layers[..i].iter().rev().find(|l| pickable(l)).map(|l| l.id)
        }
    }
}

/// The geometry of one layer (Swift `extension GraphicsLayer`).
pub trait GraphicsLayerGeometryExt {
    /// The content's rectangle at the identity transform: center offset (text: where the template places it) and size.
    fn content_rect(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect>;
    /// The box corners on the canvas at clip-local `t` (top-left, top-right, bottom-right, bottom-left of the content): a
    /// content point q (relative to the content center c) lands on position + c + R S (q - anchor), as the compositor draws it.
    fn corners(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Vec<Vec2>>;
    /// On-canvas bounding box at clip-local `t` (Motion applied).
    fn bounds(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect>;
}

#[derive(Clone, Copy)]
struct Motion {
    position: Vec2,
    scale: Vec2,
    anchor: Vec2,
    cos: f64,
    sin: f64,
}

impl Motion {
    /// R v.
    fn rotate(&self, v: Vec2) -> Vec2 {
        Vec2::new(v.x * self.cos - v.y * self.sin, v.x * self.sin + v.y * self.cos)
    }
    /// R^-1 v.
    fn unrotate(&self, v: Vec2) -> Vec2 {
        Vec2::new(v.x * self.cos + v.y * self.sin, -v.x * self.sin + v.y * self.cos)
    }
    /// Canvas point of content point q (relative to the content center c).
    fn apply(&self, c: Vec2, q: Vec2) -> Vec2 {
        self.position
            + c
            + self.rotate(Vec2::new(
                (q.x - self.anchor.x) * self.scale.x.max(0.0),
                (q.y - self.anchor.y) * self.scale.y.max(0.0),
            ))
    }
}

fn motion(l: &GraphicsLayer, t: Time) -> Motion {
    let a = &l.animation;
    let rad = a.rotation.value_at_local(t) * std::f64::consts::PI / 180.0;
    Motion {
        position: a.position.value_at_local(t),
        scale: a.scale.value_at_local(t),
        anchor: a.anchor.value_at_local(t),
        cos: rad.cos(),
        sin: rad.sin(),
    }
}

/// Exact for axis-aligned boxes: snaps float noise of 0 / 90 degree rotations.
fn snap(v: f64) -> f64 {
    let r = v.round();
    if (v - r).abs() < 1e-9 { r } else { v }
}

impl GraphicsLayerGeometryExt for GraphicsLayer {
    fn content_rect(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect> {
        if let GraphicsContent::Text { generator } = &self.content {
            return text.and_then(|m| m(generator, self.text_time(t)));
        }
        let s = self.shape_style(t)?;
        let w = s.width;
        let h = if s.kind == ShapeKind::Line && s.path.is_none() { s.stroke_width } else { s.height };
        Some(GraphicsRect { min_x: -w / 2.0, min_y: -h / 2.0, max_x: w / 2.0, max_y: h / 2.0 })
    }

    fn corners(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Vec<Vec2>> {
        let r = self.content_rect(t, text)?;
        let m = motion(self, t);
        let c = Vec2::new(r.mid_x(), r.mid_y());
        let (hw, hh) = (r.width() / 2.0, r.height() / 2.0);
        Some(
            GraphicsCorner::ALL
                .iter()
                .map(|k| {
                    let s = k.sign();
                    m.apply(c, Vec2::new(s.0 * hw, s.1 * hh))
                })
                .collect(),
        )
    }

    fn bounds(&self, t: Time, text: Option<GraphicsTextMeasure>) -> Option<GraphicsRect> {
        let cs = self.corners(t, text)?;
        let fold = |f: fn(f64, f64) -> f64, init: f64, pick: fn(&Vec2) -> f64| cs.iter().map(pick).fold(init, f);
        Some(GraphicsRect {
            min_x: snap(fold(f64::min, f64::INFINITY, |p| p.x)),
            min_y: snap(fold(f64::min, f64::INFINITY, |p| p.y)),
            max_x: snap(fold(f64::max, f64::NEG_INFINITY, |p| p.x)),
            max_y: snap(fold(f64::max, f64::NEG_INFINITY, |p| p.y)),
        })
    }
}

/// Position edits of a Vec2 property (Swift `extension AnimatedProperty where V == Vec2`).
pub trait Vec2PropertyExt {
    /// The static value and every key moved by `d` (ids and easing kept).
    fn offset_by(&self, d: Vec2) -> Self;
    /// Typing or dragging the base position of a text or graphic layer: the position shown at clip-local `t` becomes `target`
    /// and the whole motion (static value and every key) moves with it, so a fly-in keeps its shape. A static position just
    /// takes the value. Keys stay; no key is added at `t`.
    fn moved_base(&self, target: Vec2, t: Time) -> Self;
}

impl Vec2PropertyExt for AnimatedProperty<Vec2> {
    fn offset_by(&self, d: Vec2) -> Self {
        let mut c = self.clone();
        c.value = self.value + d;
        for k in &mut c.track.keys {
            k.value = k.value + d;
        }
        c
    }

    fn moved_base(&self, target: Vec2, t: Time) -> Self {
        if !self.is_animated() {
            return AnimatedProperty { value: target, track: self.track.clone() };
        }
        self.offset_by(target - self.value_at_local(t))
    }
}

/// The Project verbs of a Graphic (Swift `extension Project` in Graphics.swift).
pub trait ProjectGraphicsExt {
    /// Places an empty Graphics clip (overwrite, like any generator drop). Errors like `Project::add_generator_clip`.
    fn add_graphics_clip(
        &mut self,
        at: GeneratorPlacement,
        layers: Vec<GraphicsLayer>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Adds `layer` on top of graphics clip `clip_id`. Returns its id.
    fn add_graphics_layer(&mut self, layer: GraphicsLayer, clip_id: Id) -> Result<Id, EditError>;
}

impl ProjectGraphicsExt for Project {
    fn add_graphics_clip(
        &mut self,
        at: GeneratorPlacement,
        layers: Vec<GraphicsLayer>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let timeline = at.timeline;
        let id = self.add_generator_clip(GeneratorRef::graphics_clip(), Some("Graphic"), at, ids)?;
        self.edit(timeline, |t| {
            for track in &mut t.tracks {
                let Some(mut c) = track.clip(id).cloned() else { continue };
                c.set_graphics(Some(GraphicsDocument { layers, groups: Vec::new() }));
                track.replace(c);
                return Ok(());
            }
            Err(EditError::ClipNotFound)
        })?;
        Ok(id)
    }

    fn add_graphics_layer(&mut self, layer: GraphicsLayer, clip_id: Id) -> Result<Id, EditError> {
        self.edit_graphics(clip_id, |doc| Ok(doc.add(layer, None)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::rect;
    use sq_core_time::SequentialIds;

    fn sized(ids: &mut SequentialIds, w: f64, h: f64, at: Vec2) -> GraphicsLayer {
        let mut l = rect(ids, "r", None);
        l.set_shape_size(w, h);
        l.animation.position = AnimatedProperty::new(at);
        l
    }

    fn named(ids: &mut SequentialIds, name: &str) -> GraphicsLayer {
        rect(ids, name, None)
    }

    fn near(a: Vec2, b: Vec2) -> bool {
        (a.x - b.x).abs() < 1e-6 && (a.y - b.y).abs() < 1e-6
    }

    const Z: Vec2 = Vec2 { x: 0.0, y: 0.0 };

    fn ids_of(d: &GraphicsDocument) -> Vec<Id> {
        d.layers.iter().map(|l| l.id).collect()
    }

    fn set(v: &[Id]) -> BTreeSet<Id> {
        v.iter().copied().collect()
    }

    // Panel editing

    #[test]
    fn drag_into_a_group_joins_it() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let b = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let c = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let g = d.group_layers(&[b, c], "Group", &mut n).unwrap();
        d.move_to_index_in_group(&set(&[a]), 1, Some(g)); // between b and c
        assert_eq!(ids_of(&d), vec![b, a, c]);
        assert!(d.layers.iter().all(|l| l.group == Some(g)));
    }

    #[test]
    fn drag_out_of_a_group_dissolves_a_single_member_group() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let b = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let c = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let g = d.group_layers(&[b, c], "Group", &mut n).unwrap();
        d.move_to_index_in_group(&set(&[c]), 0, None);
        assert_eq!(ids_of(&d), vec![c, a, b]);
        assert!(d.layer(c).unwrap().group.is_none() && d.layer(b).unwrap().group.is_none());
        assert!(d.group(g).is_none());
    }

    #[test]
    fn move_into_an_unknown_group_means_no_group() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let b = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        d.move_to_index_in_group(&set(&[a]), 1, Some(Id::from_u128(999)));
        assert_eq!(ids_of(&d), vec![b, a]);
        assert!(d.layer(a).unwrap().group.is_none());
    }

    #[test]
    fn several_layers_align_to_the_frame_each_on_its_own() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let b = d.add(sized(&mut n, 20.0, 20.0, Vec2::new(100.0, 50.0)), None);
        let canvas = Vec2::new(1920.0, 1080.0);
        let t = Time::ZERO;
        let bx = |d: &GraphicsDocument, id| d.bounds_of(id, t, None).unwrap();
        d.align(&[a, b], GraphicsAlign::Left, canvas, t, None, false);
        assert_eq!((bx(&d, a).min_x, bx(&d, b).min_x), (-5.0, -5.0));
        d.align(&[a, b], GraphicsAlign::Left, canvas, t, None, true);
        assert_eq!((bx(&d, a).min_x, bx(&d, b).min_x), (-960.0, -960.0));
        d.align(&[a, b], GraphicsAlign::Bottom, canvas, t, None, true);
        assert_eq!((bx(&d, a).max_y, bx(&d, b).max_y), (540.0, 540.0));
        d.align(&[a, b], GraphicsAlign::Top, canvas, t, None, false);
        assert_eq!((bx(&d, a).min_y, bx(&d, b).min_y), (520.0, 520.0));
    }

    #[test]
    fn rename_group_trims_and_refuses_empty() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let b = d.add(sized(&mut n, 10.0, 10.0, Z), None);
        let g = d.group_layers(&[a, b], "Group", &mut n).unwrap();
        d.rename_group(g, "  Lower third ");
        assert_eq!(d.group(g).unwrap().name, "Lower third");
        d.rename_group(g, "   ");
        assert_eq!(d.group(g).unwrap().name, "Lower third");
    }

    // Option-drag copy

    #[test]
    fn copy_lands_at_the_drop_index_and_the_original_stays() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let copies = d.copy_to_index(&set(&[a]), 2, None, &mut n);
        assert_eq!(copies.len(), 1);
        assert_eq!(ids_of(&d), vec![a, b, c, copies[0]]);
        assert_eq!(d.layer(copies[0]).unwrap().name, "a copy");
    }

    #[test]
    fn copy_to_the_bottom_and_between() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let bottom = d.copy_to_index(&set(&[c]), 0, None, &mut n);
        assert_eq!(ids_of(&d), vec![bottom[0], a, b, c]);
        let mut e = GraphicsDocument::default();
        let x = e.add(named(&mut n, "x"), None);
        let y = e.add(named(&mut n, "y"), None);
        let z = e.add(named(&mut n, "z"), None);
        let mid = e.copy_to_index(&set(&[z]), 1, None, &mut n);
        assert_eq!(ids_of(&e), vec![x, mid[0], y, z]);
    }

    #[test]
    fn copy_into_a_group_joins_it_and_out_of_a_group_leaves() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let g = d.group_layers(&[b, c], "G", &mut n).unwrap();
        let into = d.copy_to_index(&set(&[a]), 1, Some(g), &mut n);
        assert!(d.layer(into[0]).unwrap().group == Some(g) && d.layer(a).unwrap().group.is_none());
        assert_eq!(ids_of(&d), vec![a, b, into[0], c]);
        let out = d.copy_to_index(&set(&[c]), 0, None, &mut n);
        assert!(d.layer(out[0]).unwrap().group.is_none() && d.layer(c).unwrap().group == Some(g));
    }

    #[test]
    fn copying_a_whole_group_makes_a_new_group() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let g = d.group_layers(&[b, c], "G", &mut n).unwrap();
        let copies = d.copy_to_index(&set(&[b, c]), 0, Some(g), &mut n);
        assert!(copies.len() == 2 && d.groups.len() == 2);
        let ng = d.layer(copies[0]).unwrap().group.unwrap();
        assert!(ng != g && d.layer(copies[1]).unwrap().group == Some(ng) && d.group(ng).unwrap().name == "G copy");
        assert_eq!(ids_of(&d), vec![copies[0], copies[1], a, b, c]);
        assert!(d.layer(b).unwrap().group == Some(g) && d.layer(c).unwrap().group == Some(g));
    }

    // Monitor picking

    #[test]
    fn a_locked_layer_is_not_picked_and_the_one_below_is() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let t = Time::ZERO;
        assert_eq!(d.hit_test(Z, t, None), Some(b));
        d.update(b, |l| l.is_locked = true);
        assert_eq!(d.hit_test(Z, t, None), Some(a));
        assert_eq!(d.hit_stack(Z, t, None), vec![a]);
    }

    #[test]
    fn deep_select_walks_down_and_wraps() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let t = Time::ZERO;
        assert_eq!(d.hit_stack(Z, t, None), vec![c, b, a]);
        assert_eq!(d.hit_below(None, Z, t, None), Some(c));
        assert_eq!(d.hit_below(Some(c), Z, t, None), Some(b));
        assert_eq!(d.hit_below(Some(a), Z, t, None), Some(c));
        assert_eq!(d.hit_below(Some(Id::from_u128(999)), Z, t, None), Some(c));
        assert_eq!(d.hit_below(None, Vec2::new(99999.0, 0.0), t, None), None);
    }

    #[test]
    fn neighbor_skips_hidden_and_locked_layers() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        assert_eq!(d.neighbor(a, true), Some(b));
        d.update(b, |l| l.is_locked = true);
        assert_eq!(d.neighbor(a, true), Some(c));
        assert_eq!(d.neighbor(c, true), None);
        assert_eq!(d.neighbor(c, false), Some(a));
        assert_eq!(d.neighbor(a, false), None);
    }

    #[test]
    fn steps_from_the_selection_edge_or_starts_at_the_end() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        assert_eq!(d.step_target(&set(&[]), true), Some(c));
        assert_eq!(d.step_target(&set(&[]), false), Some(a));
        assert_eq!(d.step_target(&set(&[b]), true), Some(c));
        assert_eq!(d.step_target(&set(&[a, b]), true), Some(c));
        assert_eq!(d.step_target(&set(&[a, b]), false), None);
        assert_eq!(d.step_target(&set(&[c]), true), None);
    }

    #[test]
    fn marquee_takes_touched_unlocked_layers_only() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let near_box = GraphicsRect { min_x: -1.0, min_y: -1.0, max_x: 1.0, max_y: 1.0 };
        let t = Time::ZERO;
        assert_eq!(d.layers_touching(&near_box, t, None), set(&[a, b]));
        d.update(b, |l| l.is_locked = true);
        assert_eq!(d.layers_touching(&near_box, t, None), set(&[a]));
        let far = GraphicsRect { min_x: 9000.0, min_y: 9000.0, max_x: 9100.0, max_y: 9100.0 };
        assert!(d.layers_touching(&far, t, None).is_empty());
    }

    // Resize

    #[test]
    fn corners_follow_motion() {
        let mut n = SequentialIds::default();
        let l = sized(&mut n, 200.0, 100.0, Vec2::new(10.0, 20.0));
        let c = l.corners(Time::ZERO, None).unwrap();
        assert!(near(c[0], Vec2::new(-90.0, -30.0)) && near(c[1], Vec2::new(110.0, -30.0)));
        assert!(near(c[2], Vec2::new(110.0, 70.0)) && near(c[3], Vec2::new(-90.0, 70.0)));
    }

    #[test]
    fn resize_keeps_the_opposite_corner() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let id = d.add(sized(&mut n, 200.0, 100.0, Z), None);
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: Vec2::new(150.0, 100.0), keep_aspect: false },
            Time::ZERO,
            None,
            &mut n,
        );
        let l = d.layer(id).unwrap();
        let st = l.shape_style(Time::ZERO).unwrap();
        assert_eq!((st.width, st.height), (250.0, 150.0));
        assert_eq!(l.animation.position.value, Vec2::new(25.0, 25.0));
        let b = d.bounds_of(id, Time::ZERO, None);
        assert_eq!(b, Some(GraphicsRect { min_x: -100.0, min_y: -50.0, max_x: 150.0, max_y: 100.0 }));
    }

    #[test]
    fn resize_under_rotation_scale_and_anchor() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let mut l = sized(&mut n, 200.0, 100.0, Vec2::new(30.0, -40.0));
        l.animation.rotation = AnimatedProperty::new(30.0);
        l.animation.scale = AnimatedProperty::new(Vec2::new(2.0, 1.5));
        l.animation.anchor = AnimatedProperty::new(Vec2::new(10.0, 5.0));
        let id = d.add(l, None);
        let before = d.layer(id).unwrap().corners(Time::ZERO, None).unwrap();
        let target = before[2] + Vec2::new(40.0, 25.0);
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: target, keep_aspect: false },
            Time::ZERO,
            None,
            &mut n,
        );
        let after = d.layer(id).unwrap().corners(Time::ZERO, None).unwrap();
        assert!(near(after[0], before[0]) && near(after[2], target));
    }

    #[test]
    fn top_left_corner_and_minimum_size() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let id = d.add(sized(&mut n, 200.0, 100.0, Z), None);
        // Dragged past the opposite corner: clamped at 1 px, the bottom-right corner stays.
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::TopLeft, to: Vec2::new(500.0, 500.0), keep_aspect: false },
            Time::ZERO,
            None,
            &mut n,
        );
        let c = d.layer(id).unwrap().corners(Time::ZERO, None).unwrap();
        assert!(near(c[2], Vec2::new(100.0, 50.0)));
        assert_eq!(d.layer(id).unwrap().shape_style(Time::ZERO).unwrap().width, 1.0);
    }

    #[test]
    fn keep_aspect_scales_both_sides() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let id = d.add(sized(&mut n, 200.0, 100.0, Z), None);
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: Vec2::new(300.0, 60.0), keep_aspect: true },
            Time::ZERO,
            None,
            &mut n,
        );
        let st = d.layer(id).unwrap().shape_style(Time::ZERO).unwrap();
        assert!((st.width / st.height - 2.0).abs() < 1e-9);
        let c = d.layer(id).unwrap().corners(Time::ZERO, None).unwrap();
        assert!(near(c[0], Vec2::new(-100.0, -50.0)));
    }

    #[test]
    fn a_line_resizes_its_length_only() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let mut l = GraphicsLayer::shape(&mut n, ShapeKind::Line, 1920, 1080);
        l.set_shape_size(400.0, 0.0);
        let id = d.add(l, None);
        let h0 = d.layer(id).unwrap().shape_style(Time::ZERO).unwrap().height;
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: Vec2::new(300.0, 400.0), keep_aspect: false },
            Time::ZERO,
            None,
            &mut n,
        );
        let st = d.layer(id).unwrap().shape_style(Time::ZERO).unwrap();
        assert_eq!((st.width, st.height), (500.0, h0));
    }

    #[test]
    fn text_scales_uniformly() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let g = GeneratorRef { kind: "text".to_string(), payload: vec![1], payload_version: 1 };
        let id = d.add(GraphicsLayer::text(n.next_id(), g, "T"), None);
        let measure = |_: &GeneratorRef, _: GraphicsTextTime| {
            Some(GraphicsRect { min_x: -40.0, min_y: -20.0, max_x: 60.0, max_y: 20.0 })
        };
        let m: GraphicsTextMeasure = &measure;
        let before = d.layer(id).unwrap().corners(Time::ZERO, Some(m)).unwrap();
        // Twice the diagonal from the fixed top-left corner.
        let to = before[0] + (before[2] - before[0]) * 2.0;
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to, keep_aspect: false },
            Time::ZERO,
            Some(m),
            &mut n,
        );
        let l = d.layer(id).unwrap();
        assert!(near(l.animation.scale.value, Vec2::new(2.0, 2.0)));
        assert!(near(l.corners(Time::ZERO, Some(m)).unwrap()[0], before[0]));
    }

    #[test]
    fn keyed_properties_get_keys_and_locked_layers_stay() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let mut l = sized(&mut n, 200.0, 100.0, Z);
        l.animation.position.toggle_keyframing_at_local(Time::ZERO, &mut n);
        let id = d.add(l, None);
        let one = Time::new(1, 1);
        d.resize(
            id,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: Vec2::new(150.0, 100.0), keep_aspect: false },
            one,
            None,
            &mut n,
        );
        let pos = &d.layer(id).unwrap().animation.position;
        assert_eq!(pos.track.keys.len(), 2);
        assert_eq!(pos.value_at_local(one), Vec2::new(25.0, 25.0));
        let mut locked = sized(&mut n, 200.0, 100.0, Z);
        locked.is_locked = true;
        let lid = d.add(locked, None);
        d.resize(
            lid,
            ResizeDrag { corner: GraphicsCorner::BottomRight, to: Vec2::new(150.0, 100.0), keep_aspect: false },
            Time::ZERO,
            None,
            &mut n,
        );
        assert_eq!(d.layer(lid).unwrap().shape_style(Time::ZERO).unwrap().width, 200.0);
    }

    // Logic without a Swift test of its own

    #[test]
    fn remove_unpins_followers_and_dissolves_small_groups() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        let c = d.add(named(&mut n, "c"), None);
        let g = d.group_layers(&[a, b], "G", &mut n).unwrap();
        d.update(c, |l| {
            l.follow = Some(sq_core_model::GraphicsFollow {
                target: sq_core_model::FollowTarget::Layer(a),
                edges: sq_core_model::GraphicsEdges::ALL,
                padding: 0.0,
                edge_padding: None,
            })
        });
        d.remove(&set(&[a]));
        assert!(d.layer(c).unwrap().follow.is_none() && d.group(g).is_none() && d.layer(b).unwrap().group.is_none());
    }

    #[test]
    fn duplicate_follows_the_copy_and_reorder_moves_whole_groups() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(named(&mut n, "a"), None);
        let b = d.add(named(&mut n, "b"), None);
        d.update(b, |l| {
            l.follow = Some(sq_core_model::GraphicsFollow {
                target: sq_core_model::FollowTarget::Layer(a),
                edges: sq_core_model::GraphicsEdges::ALL,
                padding: 0.0,
                edge_padding: None,
            })
        });
        let copies = d.duplicate(&[a, b], &mut n);
        assert_eq!(copies.len(), 2);
        let f = d.layer(copies[1]).unwrap().follow.as_ref().unwrap();
        assert_eq!(f.target, sq_core_model::FollowTarget::Layer(copies[0]));
        let c = d.add(named(&mut n, "c"), None);
        let d2 = d.add(named(&mut n, "d"), None);
        let g = d.group_layers(&[c, d2], "G", &mut n);
        assert!(g.is_some());
        d.reorder(&[a], GraphicsReorder::Front);
        assert_eq!(ids_of(&d).last(), Some(&a));
        d.reorder(&[a], GraphicsReorder::Backward); // past the whole group
        let pos = |id| d.index_of(id).unwrap();
        assert_eq!(pos(a) + 2, pos(c).max(pos(d2)));
        d.reorder(&[a], GraphicsReorder::Back);
        assert_eq!(d.index_of(a), Some(0));
    }

    #[test]
    fn distribute_spaces_the_middle_units_equally() {
        let mut n = SequentialIds::default();
        let mut d = GraphicsDocument::default();
        let a = d.add(sized(&mut n, 10.0, 10.0, Vec2::new(0.0, 0.0)), None);
        let b = d.add(sized(&mut n, 10.0, 10.0, Vec2::new(30.0, 0.0)), None);
        let c = d.add(sized(&mut n, 10.0, 10.0, Vec2::new(100.0, 0.0)), None);
        d.distribute(&[a, b, c], GraphicsAxis::Horizontal, Time::ZERO, None);
        assert_eq!(d.layer(b).unwrap().animation.position.value, Vec2::new(50.0, 0.0));
        let moved = Vec2::new(5.0, 7.0);
        let p = AnimatedProperty::new(Z).moved_base(moved, Time::ZERO);
        assert_eq!(p.value, moved);
    }
}
