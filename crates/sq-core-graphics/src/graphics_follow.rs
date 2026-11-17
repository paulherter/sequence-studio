// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+Follow.swift (logic; the saved types `GraphicsEdges`, `GraphicsFollow`, `GraphicsEdgePadding` live in
// `sq-core-model`)
//
// G11 Follow. A layer's chosen edges stay at the same edges of another layer or of the frame, `padding` px apart: outside a
// layer (a box behind a title grows with it), inside the frame (a safe margin). Shapes and paths pinned on both edges of an
// axis take the target's extent; text layers only move (both edges = centered). Resolved per instant into static values,
// so playback, export and the Graphics overlay draw from the same `resolving_follow` result. The stored layer is never
// changed.

use crate::graphics_editing::{
    GraphicsDocumentEditingExt as _, GraphicsLayerGeometryExt as _, GraphicsRect, GraphicsTextMeasure,
    Vec2PropertyExt as _,
};
use sq_core_model::graphics_item_range::GraphicsTextTime;
use sq_core_model::{
    AnimatedProperty, Clip, ClipEffect, FollowTarget, GeneratorRef, GraphicsDocument, GraphicsEdgePadding,
    GraphicsEdges, GraphicsFollow, GraphicsLayer, SequenceFormat, ShapeKind,
};
use sq_core_time::{Id, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// Longest follow chain that resolves (a layer following a layer following ... the frame). Deeper layers draw as authored.
pub const MAX_FOLLOW_DEPTH: usize = 16;

/// Set operations on the edge set (Swift `OptionSet`).
pub trait GraphicsEdgesExt {
    /// Every edge of `other` is in `self`.
    fn contains(self, other: GraphicsEdges) -> bool;
    /// No edge.
    fn is_empty(&self) -> bool;
    /// No edge in common.
    fn is_disjoint(&self, other: GraphicsEdges) -> bool;
    /// Both sets together.
    fn union(self, other: GraphicsEdges) -> GraphicsEdges;
    /// `self` without the edges of `other`.
    fn subtracting(self, other: GraphicsEdges) -> GraphicsEdges;
}

impl GraphicsEdgesExt for GraphicsEdges {
    fn contains(self, other: GraphicsEdges) -> bool {
        self.0 & other.0 == other.0
    }
    fn is_empty(&self) -> bool {
        self.0 == 0
    }
    fn is_disjoint(&self, other: GraphicsEdges) -> bool {
        self.0 & other.0 == 0
    }
    fn union(self, other: GraphicsEdges) -> GraphicsEdges {
        GraphicsEdges(self.0 | other.0)
    }
    fn subtracting(self, other: GraphicsEdges) -> GraphicsEdges {
        GraphicsEdges(self.0 & !other.0)
    }
}

/// Constructor of equal padding.
pub trait GraphicsEdgePaddingExt {
    /// `v` on every edge.
    fn all(v: f64) -> GraphicsEdgePadding;
}

impl GraphicsEdgePaddingExt for GraphicsEdgePadding {
    fn all(v: f64) -> GraphicsEdgePadding {
        GraphicsEdgePadding { left: v, top: v, right: v, bottom: v }
    }
}

/// Construction and padding of a `GraphicsFollow`.
pub trait GraphicsFollowExt {
    /// All edges, no padding.
    fn to_target(target: FollowTarget) -> GraphicsFollow;
    /// The four paddings in effect.
    fn resolved_padding(&self) -> GraphicsEdgePadding;
    /// Replaces one edge's padding; four equal values collapse back to the single `padding`. Anything but one single edge is
    /// ignored.
    fn set_padding(&mut self, v: f64, edge: GraphicsEdges);
}

impl GraphicsFollowExt for GraphicsFollow {
    fn to_target(target: FollowTarget) -> GraphicsFollow {
        GraphicsFollow { target, edges: GraphicsEdges::ALL, padding: 0.0, edge_padding: None }
    }

    fn resolved_padding(&self) -> GraphicsEdgePadding {
        self.edge_padding.unwrap_or_else(|| GraphicsEdgePadding::all(self.padding))
    }

    fn set_padding(&mut self, v: f64, edge: GraphicsEdges) {
        let mut p = self.resolved_padding();
        if edge == GraphicsEdges::LEFT {
            p.left = v;
        } else if edge == GraphicsEdges::TOP {
            p.top = v;
        } else if edge == GraphicsEdges::RIGHT {
            p.right = v;
        } else if edge == GraphicsEdges::BOTTOM {
            p.bottom = v;
        } else {
            return;
        }
        if p.left == p.top && p.top == p.right && p.right == p.bottom {
            self.padding = p.left;
            self.edge_padding = None;
        } else {
            self.edge_padding = Some(p);
        }
    }
}

/// A text measure that also gets the text layer's id (evaluation's stand-in for a text not laid out yet).
pub type GraphicsKeyedTextMeasure<'a> = &'a dyn Fn(&GeneratorRef, Id, GraphicsTextTime) -> Option<GraphicsRect>;

/// Text bounds for Follow at evaluation time. This crate cannot lay out text, so the app supplies this (Swift installs it
/// once as `GraphicsTextBounds`; here it is passed to `follow_hook`). Same box as the editor's `GraphicsTextMeasure`: the
/// raster at the identity transform, offset from the canvas center.
///
/// Arguments: the text generator, the graphics clip's id, the text layer's id, the text time, the clip duration, the canvas
/// (layout format) and `exact`. `exact`: lay the text out on the calling thread if needed (export); otherwise a text that
/// is not laid out yet is never laid out on the caller (the render thread): the provider answers with a stand-in or `None`
/// and warms it in the background. Swift keeps `exact` in a task-local; here the app passes it to `follow_hook`.
pub type GraphicsTextBoundsProvider<'a> =
    &'a dyn Fn(&GeneratorRef, Id, Id, Time, Time, &SequenceFormat, bool) -> Option<GraphicsRect>;

/// The `LayerHooks::resolve_follow` closure of `sq-core-effects` for a text bounds provider (or none: text targets then have
/// no size). The app wires it like this:
/// `let follow = follow_hook(provider, exact); let hooks = LayerHooks { resolve_follow: &follow, ..LayerHooks::plain() };`
pub fn follow_hook<'a>(
    provider: Option<GraphicsTextBoundsProvider<'a>>,
    exact: bool,
) -> impl Fn(&Clip, &GraphicsDocument, Time, Vec2, &SequenceFormat) -> Option<Vec<GraphicsLayer>> + 'a {
    move |c, doc, local, frame, layout| {
        if !doc.has_follow() {
            return None;
        }
        let duration = c.duration();
        let keyed = |r: &GeneratorRef, layer: Id, t: GraphicsTextTime| {
            provider.and_then(|m| m(r, c.id, layer, t.local, t.duration.unwrap_or(duration), layout, exact))
        };
        let keyed_ref: Option<GraphicsKeyedTextMeasure> = provider.map(|_| &keyed as GraphicsKeyedTextMeasure);
        Some(doc.resolving_follow_keyed(local, frame, keyed_ref).layers)
    }
}

/// Runs `f` with the keyed measure narrowed to layer `l` (`None` for other than text layers).
fn with_text<R>(
    keyed: Option<GraphicsKeyedTextMeasure>,
    l: &GraphicsLayer,
    f: impl FnOnce(Option<GraphicsTextMeasure>) -> R,
) -> R {
    match keyed {
        Some(k) if l.is_text() => {
            let id = l.id;
            let m = move |r: &GeneratorRef, t: GraphicsTextTime| k(r, id, t);
            f(Some(&m))
        }
        _ => f(None),
    }
}

/// Copies parameter `key` of `src` onto `dst`, removing it when `src` has none (Swift assigns the optional).
fn copy_param(dst: &mut ClipEffect, src: &ClipEffect, key: &str) {
    match src.parameters.get(key) {
        Some(p) => dst.parameters.insert(key.to_string(), p.clone()),
        None => dst.parameters.remove(key),
    };
}

fn shape_index(l: &GraphicsLayer) -> Option<usize> {
    l.effects.iter().position(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND)
}

const LR: GraphicsEdges = GraphicsEdges(GraphicsEdges::LEFT.0 | GraphicsEdges::RIGHT.0);
const TB: GraphicsEdges = GraphicsEdges(GraphicsEdges::TOP.0 | GraphicsEdges::BOTTOM.0);

/// Follow on a Graphic.
pub trait GraphicsFollowDocumentExt {
    /// Any layer follows something (cheap: no allocation; evaluation checks it every frame).
    fn has_follow(&self) -> bool;
    /// The document as drawn at clip-local `t`: every following layer's position (and, for shapes, Width / Height) replaced
    /// by static values that put its edges at the target's. `canvas`: the graphic's canvas in px (frame target). Unchanged
    /// when nothing follows. Order: targets before their followers; cycles, chains deeper than `MAX_FOLLOW_DEPTH`, unknown
    /// targets and targets without a size (empty text, a switched-off shape) leave the follower as authored.
    fn resolving_follow(&self, t: Time, canvas: Vec2, text: Option<GraphicsTextMeasure>) -> GraphicsDocument;
    /// Evaluation's variant: the measure also gets the text layer's id.
    fn resolving_follow_keyed(
        &self,
        t: Time,
        canvas: Vec2,
        keyed: Option<GraphicsKeyedTextMeasure>,
    ) -> GraphicsDocument;
    /// `resolving_follow` plus the ids of the layers Follow actually placed (a follower of an empty or switched-off target, a
    /// cycle member or a too deep chain is not among them: it is drawn as authored).
    fn resolved_follow(
        &self,
        t: Time,
        canvas: Vec2,
        keyed: Option<GraphicsKeyedTextMeasure>,
    ) -> (GraphicsDocument, BTreeSet<Id>);
    /// Runs a geometric edit (align, distribute, corner resize) on what is drawn at `t`: `body` edits the document with Follow
    /// resolved, then the result is carried back to the stored layers. A layer whose follow resolves keeps what Follow sets:
    /// its position on a pinned axis (left/right = x, top/bottom = y) and a stretched Width / Height; its other position
    /// changes (as an offset), Scale and the rest of its size are taken. Other layers take the result as is (they are drawn
    /// as stored). Plain `body` when nothing follows.
    fn editing_resolved(
        &mut self,
        t: Time,
        canvas: Vec2,
        text: Option<GraphicsTextMeasure>,
        body: impl FnOnce(&mut GraphicsDocument),
    );
    /// Monitor drag: moves `ids` (and their groups) by `delta`. A pinned layer's dragged axis (left/right = x, top/bottom =
    /// y) is unpinned: the layer first takes the place and stretched size Follow gives it at `t`, so it moves from where it
    /// is drawn; the other axis stays pinned. A follow left without edges is removed. Plain `translate` when nothing follows.
    fn move_editing_resolved(
        &mut self,
        ids: &[Id],
        delta: Vec2,
        t: Time,
        canvas: Vec2,
        text: Option<GraphicsTextMeasure>,
    );
    /// Layers `id` may follow without a cycle, front first (the Follows popup). Empty for an unknown id.
    fn follow_candidates(&self, id: Id) -> Vec<GraphicsLayer>;
}

/// Following `start`'s chain reaches `id` (bounded by the layer count).
fn leads_to(doc: &GraphicsDocument, id: Id, start: Id) -> bool {
    let mut cur = start;
    for _ in 0..=doc.layers.len() {
        let Some(FollowTarget::Layer(next)) = doc.layer(cur).and_then(|l| l.follow.as_ref()).map(|f| f.target) else {
            return false;
        };
        if next == id {
            return true;
        }
        cur = next;
    }
    false
}

/// (follower index, target index or -1 for the frame), targets first; only follows that resolve.
fn follow_plan(doc: &GraphicsDocument) -> Vec<(usize, i64)> {
    let n = doc.layers.len();
    // -1 = none, -2 = frame, else the target's index.
    let mut target = vec![-1_i64; n];
    for (i, (slot, layer)) in target.iter_mut().zip(&doc.layers).enumerate() {
        let Some(f) = layer.follow.as_ref().filter(|f| !f.edges.is_empty()) else { continue };
        match f.target {
            FollowTarget::Frame => *slot = -2,
            FollowTarget::Layer(id) => {
                if let Some(j) = doc.index_of(id).filter(|j| *j != i) {
                    *slot = j as i64;
                }
            }
        }
    }
    // A cycle member's follow is ignored (each layer has at most one target, so a walk of n steps that does not return to
    // the start never will). Members are found against the raw targets, so the result does not depend on order.
    let mut eff = target.clone();
    for i in 0..n {
        if target[i] < 0 {
            continue;
        }
        let (mut k, mut steps) = (target[i], 0);
        while k >= 0 && k != i as i64 && steps < n {
            k = target[k as usize];
            steps += 1;
        }
        if k == i as i64 {
            eff[i] = -1;
        }
    }
    // Depth = links down to an anchor (the frame, or a layer that follows nothing that resolves).
    let mut plan: Vec<(usize, usize)> = Vec::new();
    for i in 0..n {
        if eff[i] == -1 {
            continue;
        }
        let (mut d, mut k) = (1_usize, eff[i]);
        while k >= 0 && eff[k as usize] != -1 && d <= n {
            d += 1;
            k = eff[k as usize];
        }
        if d <= MAX_FOLLOW_DEPTH {
            plan.push((d, i));
        }
    }
    plan.sort();
    plan.into_iter().map(|(_, i)| (i, if eff[i] == -2 { -1 } else { eff[i] })).collect()
}

impl GraphicsFollowDocumentExt for GraphicsDocument {
    fn has_follow(&self) -> bool {
        self.layers.iter().any(|l| l.follow.as_ref().is_some_and(|f| !f.edges.is_empty()))
    }

    fn resolving_follow(&self, t: Time, canvas: Vec2, text: Option<GraphicsTextMeasure>) -> GraphicsDocument {
        if !self.has_follow() {
            return self.clone();
        }
        match text {
            Some(m) => {
                let keyed = |r: &GeneratorRef, _: Id, t: GraphicsTextTime| m(r, t);
                self.resolving_follow_keyed(t, canvas, Some(&keyed))
            }
            None => self.resolving_follow_keyed(t, canvas, None),
        }
    }

    fn resolving_follow_keyed(
        &self,
        t: Time,
        canvas: Vec2,
        keyed: Option<GraphicsKeyedTextMeasure>,
    ) -> GraphicsDocument {
        self.resolved_follow(t, canvas, keyed).0
    }

    fn resolved_follow(
        &self,
        t: Time,
        canvas: Vec2,
        keyed: Option<GraphicsKeyedTextMeasure>,
    ) -> (GraphicsDocument, BTreeSet<Id>) {
        if !self.has_follow() {
            return (self.clone(), BTreeSet::new());
        }
        let mut placed = BTreeSet::new();
        let mut out = self.clone();
        let frame = GraphicsRect {
            min_x: -canvas.x / 2.0,
            min_y: -canvas.y / 2.0,
            max_x: canvas.x / 2.0,
            max_y: canvas.y / 2.0,
        };
        for (i, j) in follow_plan(self) {
            let Some(f) = self.layers[i].follow.clone() else { continue };
            let reference = if j < 0 {
                frame
            } else {
                let target = &out.layers[j as usize];
                let Some(b) = with_text(keyed, target, |m| target.bounds(t, m)) else { continue };
                b
            };
            let mut l = out.layers[i].clone();
            with_text(keyed, &l.clone(), |m| l.apply_follow(&f, &reference, j < 0, t, m));
            out.layers[i] = l;
            placed.insert(out.layers[i].id);
        }
        (out, placed)
    }

    fn editing_resolved(
        &mut self,
        t: Time,
        canvas: Vec2,
        text: Option<GraphicsTextMeasure>,
        body: impl FnOnce(&mut GraphicsDocument),
    ) {
        if !self.has_follow() {
            body(self);
            return;
        }
        let keyed_fn = text.map(|m| move |r: &GeneratorRef, _: Id, t: GraphicsTextTime| m(r, t));
        let keyed: Option<GraphicsKeyedTextMeasure> = keyed_fn.as_ref().map(|k| k as GraphicsKeyedTextMeasure);
        let (before, placed) = self.resolved_follow(t, canvas, keyed);
        let mut after = before.clone();
        body(&mut after);
        let mut pinned: BTreeMap<Id, GraphicsEdges> = BTreeMap::new();
        for (i, _) in follow_plan(self) {
            if placed.contains(&self.layers[i].id)
                && let Some(f) = &self.layers[i].follow
            {
                pinned.insert(self.layers[i].id, f.edges);
            }
        }
        let mut out = after;
        for k in 0..out.layers.len() {
            let id = out.layers[k].id;
            let (Some(e), Some(stored), Some(b)) = (pinned.get(&id).copied(), self.layer(id), before.layer(id)) else {
                continue;
            };
            let a = out.layers[k].clone();
            let mut l = stored.clone();
            if a != *b {
                let mut d = a.animation.position.value_at_local(t) - b.animation.position.value_at_local(t);
                if !e.is_disjoint(LR) {
                    d.x = 0.0;
                }
                if !e.is_disjoint(TB) {
                    d.y = 0.0;
                }
                if d != Vec2::new(0.0, 0.0) {
                    l.animation.position = l.animation.position.offset_by(d);
                }
                l.animation.scale = a.animation.scale.clone();
                let stretch = !stored.is_text() && stored.animation.rotation.value_at_local(t).abs() < 1e-9;
                if let (Some(ka), Some(ks)) = (shape_index(&a), shape_index(&l)) {
                    if !(stretch && e.contains(LR)) {
                        copy_param(&mut l.effects[ks], &a.effects[ka], ClipEffect::SHAPE_WIDTH_KEY);
                    }
                    if !(stretch && e.contains(TB)) {
                        copy_param(&mut l.effects[ks], &a.effects[ka], ClipEffect::SHAPE_HEIGHT_KEY);
                    }
                }
            }
            out.layers[k] = l;
        }
        *self = out;
    }

    fn move_editing_resolved(
        &mut self,
        ids: &[Id],
        delta: Vec2,
        t: Time,
        canvas: Vec2,
        text: Option<GraphicsTextMeasure>,
    ) {
        if !self.has_follow() || delta == Vec2::new(0.0, 0.0) {
            self.translate(ids, delta);
            return;
        }
        let keyed_fn = text.map(|m| move |r: &GeneratorRef, _: Id, t: GraphicsTextTime| m(r, t));
        let keyed: Option<GraphicsKeyedTextMeasure> = keyed_fn.as_ref().map(|k| k as GraphicsKeyedTextMeasure);
        let (shown, placed) = self.resolved_follow(t, canvas, keyed);
        for id in self.expanded(ids) {
            if !placed.contains(&id) {
                continue;
            }
            let Some(i) = self.index_of(id) else { continue };
            if self.layers[i].is_locked {
                continue;
            }
            let (Some(mut f), Some(r)) = (self.layers[i].follow.clone(), shown.layer(id)) else { continue };
            let mut unpin = GraphicsEdges(0);
            if delta.x != 0.0 && !f.edges.is_disjoint(LR) {
                unpin = unpin.union(LR);
            }
            if delta.y != 0.0 && !f.edges.is_disjoint(TB) {
                unpin = unpin.union(TB);
            }
            if unpin.is_empty() {
                continue;
            }
            let mut l = self.layers[i].clone();
            let d = r.animation.position.value_at_local(t) - l.animation.position.value_at_local(t);
            if d != Vec2::new(0.0, 0.0) {
                l.animation.position = l.animation.position.offset_by(d);
            }
            if let (Some(ks), Some(kr)) = (shape_index(&l), shape_index(r)) {
                if f.edges.contains(LR) && unpin.contains(GraphicsEdges::LEFT) {
                    copy_param(&mut l.effects[ks], &r.effects[kr], ClipEffect::SHAPE_WIDTH_KEY);
                }
                if f.edges.contains(TB) && unpin.contains(GraphicsEdges::TOP) {
                    copy_param(&mut l.effects[ks], &r.effects[kr], ClipEffect::SHAPE_HEIGHT_KEY);
                }
            }
            f.edges = f.edges.subtracting(unpin);
            l.follow = if f.edges.is_empty() { None } else { Some(f) };
            self.layers[i] = l;
        }
        self.translate(ids, delta);
    }

    fn follow_candidates(&self, id: Id) -> Vec<GraphicsLayer> {
        if self.index_of(id).is_none() {
            return Vec::new();
        }
        self.layers.iter().rev().filter(|l| l.id != id && !leads_to(self, id, l.id)).cloned().collect()
    }
}

/// Follow on one layer.
pub trait GraphicsLayerFollowExt {
    /// Puts the followed edges at `r` grown by the padding (`inside`: shrunk, the frame). Static values at `t` only.
    fn apply_follow(
        &mut self,
        f: &GraphicsFollow,
        r: &GraphicsRect,
        inside: bool,
        t: Time,
        text: Option<GraphicsTextMeasure>,
    );
}

impl GraphicsLayerFollowExt for GraphicsLayer {
    fn apply_follow(
        &mut self,
        f: &GraphicsFollow,
        r: &GraphicsRect,
        inside: bool,
        t: Time,
        text: Option<GraphicsTextMeasure>,
    ) {
        let pad = f.resolved_padding();
        let sign = if inside { -1.0 } else { 1.0 };
        let want = GraphicsRect {
            min_x: r.min_x - sign * pad.left,
            min_y: r.min_y - sign * pad.top,
            max_x: r.max_x + sign * pad.right,
            max_y: r.max_y + sign * pad.bottom,
        };
        let e = f.edges;
        let (both_x, both_y) = (e.contains(LR), e.contains(TB));
        // Size: shapes and paths stretch to the extent in their own (unscaled) px; a line keeps its thickness. A rotated
        // layer only moves (its box is not its Width x Height, so sizing would not fit the target).
        if !self.is_text()
            && (both_x || both_y)
            && self.animation.rotation.value_at_local(t).abs() < 1e-9
            && let Some(st) = self.shape_style(t)
            && let Some(k) = shape_index(self)
        {
            let s = self.animation.scale.value_at_local(t);
            let is_line = st.kind == ShapeKind::Line && st.path.is_none();
            if both_x && s.x > 1e-6 {
                self.effects[k].parameters.insert(
                    ClipEffect::SHAPE_WIDTH_KEY.to_string(),
                    AnimatedProperty::new((want.width() / s.x).max(1.0)),
                );
            }
            if both_y && !is_line && s.y > 1e-6 {
                self.effects[k].parameters.insert(
                    ClipEffect::SHAPE_HEIGHT_KEY.to_string(),
                    AnimatedProperty::new((want.height() / s.y).max(1.0)),
                );
            }
        }
        // Position: the bounding box (Motion applied) moves onto the followed edges; both edges = centered.
        let Some(b) = self.bounds(t, text) else { return };
        let mut d = Vec2::new(0.0, 0.0);
        if both_x {
            d.x = want.mid_x() - b.mid_x();
        } else if e.contains(GraphicsEdges::LEFT) {
            d.x = want.min_x - b.min_x;
        } else if e.contains(GraphicsEdges::RIGHT) {
            d.x = want.max_x - b.max_x;
        }
        if both_y {
            d.y = want.mid_y() - b.mid_y();
        } else if e.contains(GraphicsEdges::TOP) {
            d.y = want.min_y - b.min_y;
        } else if e.contains(GraphicsEdges::BOTTOM) {
            d.y = want.max_y - b.max_y;
        }
        self.animation.position = AnimatedProperty::new(self.animation.position.value_at_local(t) + d);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::{project, s};
    use crate::graphics_editing::ProjectGraphicsExt as _;
    use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation as _};
    use sq_core_model::project_media_ops::GeneratorPlacement;
    use sq_core_model::{EffectColor, GraphicsContent, Timeline, TrackKind};
    use sq_core_time::{IdSource, Keyframe, SequentialIds};

    const CANVAS: Vec2 = Vec2 { x: 1920.0, y: 1080.0 };
    const Z: Vec2 = Vec2 { x: 0.0, y: 0.0 };

    fn v(x: f64, y: f64) -> Vec2 {
        Vec2::new(x, y)
    }

    /// A rectangle `w` x `h` at `pos`.
    fn rect(ids: &mut SequentialIds, w: f64, h: f64, pos: Vec2, name: &str) -> GraphicsLayer {
        let mut l = GraphicsLayer::shape(ids, ShapeKind::Rectangle, 1920, 1080);
        l.set_shape_size(w, h);
        l.animation.position = AnimatedProperty::new(pos);
        l.name = name.to_string();
        l
    }

    fn text_ref(s: &str) -> GeneratorRef {
        GeneratorRef { kind: "text".to_string(), payload: s.as_bytes().to_vec(), payload_version: 1 }
    }

    /// A fake text payload: its measured box is 10 px per payload byte wide and 40 px high, centered on the canvas center.
    fn text_layer(ids: &mut SequentialIds, s: &str, pos: Vec2) -> GraphicsLayer {
        let mut l = GraphicsLayer::text(ids.next_id(), text_ref(s), "Text");
        l.animation.position = AnimatedProperty::new(pos);
        l
    }

    fn measure_fn(r: &GeneratorRef, _: GraphicsTextTime) -> Option<GraphicsRect> {
        let w = r.payload.len() as f64 * 10.0;
        Some(GraphicsRect { min_x: -w / 2.0, min_y: -20.0, max_x: w / 2.0, max_y: 20.0 })
    }
    const MEASURE: GraphicsTextMeasure<'static> = &measure_fn;

    fn no_measure_fn(_: &GeneratorRef, _: GraphicsTextTime) -> Option<GraphicsRect> {
        None
    }
    const NO_MEASURE: GraphicsTextMeasure<'static> = &no_measure_fn;

    fn r(min_x: f64, min_y: f64, max_x: f64, max_y: f64) -> GraphicsRect {
        GraphicsRect { min_x, min_y, max_x, max_y }
    }

    fn near(a: Option<GraphicsRect>, b: GraphicsRect) -> bool {
        a.is_some_and(|a| {
            (a.min_x - b.min_x).abs() < 1e-6
                && (a.min_y - b.min_y).abs() < 1e-6
                && (a.max_x - b.max_x).abs() < 1e-6
                && (a.max_y - b.max_y).abs() < 1e-6
        })
    }

    fn follow(target: Id) -> GraphicsFollow {
        GraphicsFollow::to_target(FollowTarget::Layer(target))
    }

    fn with(mut f: GraphicsFollow, edges: GraphicsEdges, padding: f64) -> GraphicsFollow {
        f.edges = edges;
        f.padding = padding;
        f
    }

    fn pad(target: Id, padding: f64) -> GraphicsFollow {
        with(follow(target), GraphicsEdges::ALL, padding)
    }

    fn edges(list: &[GraphicsEdges]) -> GraphicsEdges {
        list.iter().fold(GraphicsEdges(0), |a, e| a.union(*e))
    }

    fn doc(layers: Vec<GraphicsLayer>) -> GraphicsDocument {
        GraphicsDocument { layers, groups: Vec::new() }
    }

    fn resolved(d: &GraphicsDocument, t: Time) -> GraphicsDocument {
        d.resolving_follow(t, CANVAS, Some(MEASURE))
    }

    fn bx(d: &GraphicsDocument, id: Id, t: Time) -> Option<GraphicsRect> {
        resolved(d, t).bounds_of(id, t, Some(MEASURE))
    }

    fn b0(d: &GraphicsDocument, id: Id) -> Option<GraphicsRect> {
        bx(d, id, Time::ZERO)
    }

    #[test]
    fn defaults_and_coding() {
        let mut n = SequentialIds::default();
        let l = rect(&mut n, 100.0, 50.0, Z, "Rect");
        assert!(l.follow.is_none());
        // No follow: the key is absent, so the bytes equal what a v62 build wrote.
        assert!(!serde_json::to_string(&l).unwrap().contains("follow"));
        let mut f = l.clone();
        f.follow = Some(with(follow(Id::from_u128(9)), edges(&[GraphicsEdges::LEFT, GraphicsEdges::BOTTOM]), 12.0));
        let back: GraphicsLayer = serde_json::from_str(&serde_json::to_string(&f).unwrap()).unwrap();
        assert_eq!(back, f);
        let frame = GraphicsFollow::to_target(FollowTarget::Frame);
        assert!(frame.edges == GraphicsEdges::ALL && frame.padding == 0.0);
        let back: GraphicsFollow = serde_json::from_str(&serde_json::to_string(&frame).unwrap()).unwrap();
        assert_eq!(back, frame);
    }

    #[test]
    fn shape_following_text_grows_with_measured_bounds_plus_padding() {
        let mut n = SequentialIds::default();
        let text = text_layer(&mut n, "Hello", v(100.0, 50.0)); // 50 x 40 at (100, 50)
        let mut bg = rect(&mut n, 10.0, 10.0, v(-500.0, -300.0), "bg");
        bg.follow = Some(pad(text.id, 24.0));
        let (bgid, tid) = (bg.id, text.id);
        let mut d = doc(vec![bg, text]);
        assert!(near(b0(&d, bgid), r(75.0 - 24.0, 30.0 - 24.0, 125.0 + 24.0, 70.0 + 24.0)));
        // Longer text: the box grows with it.
        d.update(tid, |l| l.content = GraphicsContent::Text { generator: text_ref("Hello world") });
        assert!(near(b0(&d, bgid), r(45.0 - 24.0, 30.0 - 24.0, 155.0 + 24.0, 70.0 + 24.0)));
        // The stored layer is untouched: only the evaluated picture follows.
        assert_eq!(d.layer(bgid).unwrap().animation.position.value, v(-500.0, -300.0));
    }

    #[test]
    fn one_edge_moves_without_resizing() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, Z, "a"); // -100...100, -50...50
        let mut b = rect(&mut n, 40.0, 20.0, v(300.0, 300.0), "b");
        b.follow = Some(with(follow(a.id), GraphicsEdges::LEFT, 10.0));
        let d = doc(vec![a.clone(), b.clone()]);
        // Left edge 10 px outside A's left edge; y and size unchanged.
        assert!(near(b0(&d, b.id), r(-110.0, 290.0, -70.0, 310.0)));
        let mut c = b.clone();
        c.follow = Some(with(follow(a.id), edges(&[GraphicsEdges::RIGHT, GraphicsEdges::BOTTOM]), -10.0));
        let d2 = doc(vec![a, c.clone()]);
        // Negative padding = inside the target.
        assert!(near(b0(&d2, c.id), r(50.0, 20.0, 90.0, 40.0)));
    }

    #[test]
    fn text_only_moves() {
        let mut n = SequentialIds::default();
        let shape = rect(&mut n, 400.0, 200.0, v(-200.0, 100.0), "s"); // -400...0, 0...200
        let mut t = text_layer(&mut n, "Hi", v(500.0, 500.0)); // 20 x 40
        t.follow = Some(pad(shape.id, 24.0));
        let d = doc(vec![shape.clone(), t.clone()]);
        // Both edges on both axes: a text layer cannot stretch, it is centered on the target.
        assert!(near(b0(&d, t.id), r(-210.0, 80.0, -190.0, 120.0)));
        assert_eq!(resolved(&d, Time::ZERO).layer(t.id).unwrap().animation.scale.value, v(1.0, 1.0));
        let mut t2 = t.clone();
        t2.follow = Some(with(follow(shape.id), GraphicsEdges::TOP, -8.0));
        assert!(near(b0(&doc(vec![shape, t2.clone()]), t2.id), r(490.0, 8.0, 510.0, 48.0)));
    }

    #[test]
    fn frame_target_insets_by_padding() {
        let mut n = SequentialIds::default();
        let mut bar = rect(&mut n, 10.0, 10.0, Z, "bar");
        bar.follow = Some(with(GraphicsFollow::to_target(FollowTarget::Frame), GraphicsEdges::ALL, 48.0));
        let mut logo = rect(&mut n, 100.0, 60.0, Z, "logo");
        logo.follow = Some(with(
            GraphicsFollow::to_target(FollowTarget::Frame),
            edges(&[GraphicsEdges::RIGHT, GraphicsEdges::BOTTOM]),
            48.0,
        ));
        let d = doc(vec![bar.clone(), logo.clone()]);
        assert!(near(b0(&d, bar.id), r(-912.0, -492.0, 912.0, 492.0)));
        assert!(near(b0(&d, logo.id), r(812.0, 432.0, 912.0, 492.0)));
        // Another canvas (a format variant): the pin follows it.
        let var = d.resolving_follow(Time::ZERO, v(1080.0, 1920.0), None);
        assert!(near(var.bounds_of(logo.id, Time::ZERO, None), r(392.0, 852.0, 492.0, 912.0)));
    }

    #[test]
    fn scaled_follower_keeps_its_scale_and_fits_the_extent() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, Z, "a");
        let mut b = rect(&mut n, 10.0, 10.0, v(400.0, 0.0), "b");
        b.animation.scale = AnimatedProperty::new(v(2.0, 0.5));
        b.follow = Some(pad(a.id, 0.0));
        let res = resolved(&doc(vec![a, b.clone()]), Time::ZERO);
        assert!(near(res.bounds_of(b.id, Time::ZERO, Some(MEASURE)), r(-100.0, -50.0, 100.0, 50.0)));
        let st = res.layer(b.id).unwrap().shape_style(Time::ZERO).unwrap();
        assert_eq!((st.width, st.height), (100.0, 200.0));
    }

    #[test]
    fn line_keeps_its_thickness_and_paths_stretch() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 300.0, 100.0, Z, "a");
        let mut line = GraphicsLayer::shape(&mut n, ShapeKind::Line, 1920, 1080);
        line.follow =
            Some(with(follow(a.id), edges(&[GraphicsEdges::LEFT, GraphicsEdges::RIGHT, GraphicsEdges::BOTTOM]), 0.0));
        let red = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
        let mut path = GraphicsLayer::path(&mut n, &[v(0.0, 0.0), v(10.0, 20.0), v(20.0, 0.0)], true, red, 2.0);
        path.follow = Some(follow(a.id));
        let res = resolved(&doc(vec![a, line.clone(), path.clone()]), Time::ZERO);
        let lb = res.bounds_of(line.id, Time::ZERO, None).unwrap();
        assert!((lb.width() - 300.0).abs() < 1e-6 && (lb.max_y - 50.0).abs() < 1e-6);
        let h = |l: &GraphicsLayer| l.shape_style(Time::ZERO).unwrap().height;
        assert_eq!(h(res.layer(line.id).unwrap()), h(&line));
        assert!(near(res.bounds_of(path.id, Time::ZERO, None), r(-150.0, -50.0, 150.0, 50.0)));
    }

    #[test]
    fn keyed_target_is_followed_at_every_instant() {
        let mut n = SequentialIds::default();
        let mut a = rect(&mut n, 100.0, 100.0, Z, "a");
        a.animation.position.track.insert(Keyframe::new(n.next_id(), Time::ZERO, v(0.0, 0.0)));
        a.animation.position.track.insert(Keyframe::new(n.next_id(), s(2), v(200.0, 0.0)));
        let mut b = rect(&mut n, 10.0, 10.0, Z, "b");
        b.follow = Some(pad(a.id, 5.0));
        let d = doc(vec![a, b.clone()]);
        assert!(near(bx(&d, b.id, Time::ZERO), r(-55.0, -55.0, 55.0, 55.0)));
        assert!(near(bx(&d, b.id, s(2)), r(145.0, -55.0, 255.0, 55.0)));
    }

    #[test]
    fn chains_resolve_in_dependency_order_whatever_the_list_order() {
        let mut n = SequentialIds::default();
        let a = text_layer(&mut n, "abcd", v(0.0, 0.0)); // 40 x 40
        let mut b = rect(&mut n, 1.0, 1.0, Z, "B");
        b.follow = Some(pad(a.id, 10.0)); // 60 x 60
        let mut c = rect(&mut n, 1.0, 1.0, Z, "C");
        c.follow = Some(pad(b.id, 10.0)); // 80 x 80
        for order in [[&c, &b, &a], [&a, &b, &c], [&b, &c, &a]] {
            let d = doc(order.iter().map(|l| (*l).clone()).collect());
            assert!(near(b0(&d, c.id), r(-40.0, -40.0, 40.0, 40.0)));
        }
    }

    #[test]
    fn cycles_are_ignored() {
        let mut n = SequentialIds::default();
        let mut a = rect(&mut n, 100.0, 100.0, v(-300.0, 0.0), "A");
        let mut b = rect(&mut n, 50.0, 50.0, v(300.0, 0.0), "B");
        a.follow = Some(follow(b.id));
        b.follow = Some(follow(a.id));
        let mut self1 = rect(&mut n, 20.0, 20.0, v(0.0, 300.0), "self");
        self1.follow = Some(follow(self1.id));
        // D follows a cycle member: the member draws as authored, D follows that.
        let mut d1 = rect(&mut n, 1.0, 1.0, Z, "D");
        d1.follow = Some(pad(a.id, 0.0));
        let d = doc(vec![a.clone(), b.clone(), self1.clone(), d1.clone()]);
        let res = resolved(&d, Time::ZERO);
        assert!(res.layer(a.id) == Some(&a) && res.layer(b.id) == Some(&b) && res.layer(self1.id) == Some(&self1));
        assert!(near(res.bounds_of(d1.id, Time::ZERO, None), r(-350.0, -50.0, -250.0, 50.0)));
    }

    #[test]
    fn chains_deeper_than_the_limit_are_ignored() {
        let mut n = SequentialIds::default();
        let mut layers = vec![rect(&mut n, 100.0, 100.0, Z, "root")];
        for k in 1..=(MAX_FOLLOW_DEPTH + 3) {
            let mut l = rect(&mut n, 1.0, 1.0, v(k as f64 * 10.0, 0.0), &format!("L{k}"));
            l.follow = Some(pad(layers[k - 1].id, 1.0));
            layers.push(l);
        }
        let d = doc(layers.iter().rev().cloned().collect());
        let res = resolved(&d, Time::ZERO);
        let limit = MAX_FOLLOW_DEPTH;
        let w = 100.0 + 2.0 * limit as f64;
        assert!(near(res.bounds_of(layers[limit].id, Time::ZERO, None), r(-w / 2.0, -w / 2.0, w / 2.0, w / 2.0)));
        // Beyond the limit: as authored.
        for l in &layers[limit + 1..] {
            assert_eq!(res.layer(l.id), Some(l));
        }
    }

    #[test]
    fn unknown_or_deleted_target_unpins() {
        let mut n = SequentialIds::default();
        let mut b = rect(&mut n, 40.0, 40.0, v(10.0, 10.0), "b");
        b.follow = Some(follow(Id::from_u128(777)));
        assert_eq!(resolved(&doc(vec![b.clone()]), Time::ZERO).layer(b.id), Some(&b));
        let a = rect(&mut n, 100.0, 100.0, Z, "a");
        let mut c = rect(&mut n, 40.0, 40.0, Z, "c");
        c.follow = Some(follow(a.id));
        let mut other = rect(&mut n, 40.0, 40.0, Z, "o");
        other.follow = Some(GraphicsFollow::to_target(FollowTarget::Frame));
        let mut d = doc(vec![a.clone(), c.clone(), other.clone()]);
        d.remove(&[a.id].into_iter().collect());
        assert!(d.layer(c.id).unwrap().follow.is_none()); // deleting the target unpins the follower
        assert_eq!(d.layer(other.id).unwrap().follow, Some(GraphicsFollow::to_target(FollowTarget::Frame)));
    }

    #[test]
    fn empty_text_target_leaves_the_follower_as_authored() {
        let mut n = SequentialIds::default();
        let t = text_layer(&mut n, "", Z);
        let mut b = rect(&mut n, 40.0, 40.0, v(10.0, 10.0), "b");
        b.follow = Some(follow(t.id));
        let res = doc(vec![t, b.clone()]).resolving_follow(Time::ZERO, CANVAS, Some(NO_MEASURE));
        assert_eq!(res.layer(b.id), Some(&b));
    }

    #[test]
    fn no_follow_returns_the_document_unchanged() {
        let mut n = SequentialIds::default();
        let r0 = rect(&mut n, 10.0, 10.0, Z, "r");
        let t = text_layer(&mut n, "x", Z);
        let d = doc(vec![r0, t]);
        assert!(!d.has_follow());
        assert_eq!(resolved(&d, Time::ZERO), d);
        let mut e = d.clone();
        e.layers[0].follow = Some(with(GraphicsFollow::to_target(FollowTarget::Frame), GraphicsEdges(0), 0.0));
        // A follow without edges changes nothing in the picture.
        let res = resolved(&e, Time::ZERO);
        assert_eq!(res.layers[0].animation, e.layers[0].animation);
        assert_eq!(res.layers[0].effects, e.layers[0].effects);
    }

    #[test]
    fn candidates_exclude_self_and_cycles() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 10.0, 10.0, Z, "A");
        let mut b = rect(&mut n, 10.0, 10.0, Z, "B");
        b.follow = Some(follow(a.id));
        let mut c = rect(&mut n, 10.0, 10.0, Z, "C");
        c.follow = Some(follow(b.id));
        let d = doc(vec![a.clone(), b.clone(), c.clone()]);
        // A cannot follow B or C (both lead back to A); front first like the layer list.
        let ids = |v: Vec<GraphicsLayer>| v.into_iter().map(|l| l.id).collect::<Vec<_>>();
        assert!(ids(d.follow_candidates(a.id)).is_empty());
        assert_eq!(ids(d.follow_candidates(c.id)), vec![b.id, a.id]);
        assert_eq!(ids(d.follow_candidates(b.id)), vec![a.id]);
        assert!(d.follow_candidates(Id::from_u128(999)).is_empty());
    }

    #[test]
    fn duplicate_keeps_the_follow_and_repins_copies_of_the_set() {
        use crate::graphics_editing::GraphicsDocumentEditingExt as _;
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 10.0, 10.0, Z, "a");
        let mut b = rect(&mut n, 10.0, 10.0, Z, "b");
        b.follow = Some(pad(a.id, 3.0));
        let mut d = doc(vec![a, b.clone()]);
        let ids = d.duplicate(&[b.id], &mut n);
        assert_eq!(d.layer(ids[0]).unwrap().follow, b.follow);
        let title = text_layer(&mut n, "Title", Z);
        let mut bg = rect(&mut n, 10.0, 10.0, Z, "bg");
        bg.follow = Some(pad(title.id, 8.0));
        let other = rect(&mut n, 50.0, 50.0, Z, "other");
        let mut free = rect(&mut n, 5.0, 5.0, Z, "free");
        free.follow = Some(follow(other.id));
        let mut d = doc(vec![bg.clone(), title.clone(), other.clone(), free.clone()]);
        let ids = d.duplicate(&[bg.id, title.id, free.id], &mut n);
        assert_eq!(d.layer(ids[0]).unwrap().follow, Some(pad(ids[1], 8.0)));
        assert_eq!(d.layer(bg.id).unwrap().follow.as_ref().map(|f| f.target), Some(FollowTarget::Layer(title.id)));
        assert_eq!(d.layer(ids[2]).unwrap().follow.as_ref().map(|f| f.target), Some(FollowTarget::Layer(other.id)));
    }

    #[test]
    fn align_measures_what_is_drawn_and_leaves_pinned_axes_to_follow() {
        use crate::graphics_editing::{GraphicsAlign, GraphicsDocumentEditingExt as _};
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, Z, "a"); // -100...100
        let mut b = rect(&mut n, 40.0, 20.0, v(600.0, 300.0), "b");
        b.follow = Some(with(follow(a.id), GraphicsEdges::LEFT, 10.0)); // drawn at min_x -110
        let c = rect(&mut n, 20.0, 20.0, v(400.0, -200.0), "c");
        let (bid, cid) = (b.id, c.id);
        let mut d = doc(vec![a, b, c]);
        d.editing_resolved(Time::ZERO, CANVAS, Some(MEASURE), |x| {
            x.align(&[bid, cid], GraphicsAlign::Left, CANVAS, Time::ZERO, Some(MEASURE), false)
        });
        // C goes to B's drawn left edge (not its authored 580); B's x stays Follow's, its stored x is untouched.
        assert!((b0(&d, cid).map_or(0.0, |x| x.min_x) - -110.0).abs() < 1e-6);
        assert_eq!(d.layer(bid).unwrap().animation.position.value.x, 600.0);
        d.editing_resolved(Time::ZERO, CANVAS, Some(MEASURE), |x| {
            x.align(&[bid, cid], GraphicsAlign::Top, CANVAS, Time::ZERO, Some(MEASURE), false)
        });
        // Top is not pinned: B moves there (its stored y changes), C stays the top-most.
        assert!((b0(&d, bid).map_or(0.0, |x| x.min_y) - -210.0).abs() < 1e-6);
        assert!((b0(&d, cid).map_or(0.0, |x| x.min_y) - -210.0).abs() < 1e-6);
    }

    #[test]
    fn a_follower_whose_target_has_no_size_is_edited_like_any_layer() {
        use crate::graphics_editing::GraphicsDocumentEditingExt as _;
        let mut n = SequentialIds::default();
        let t = text_layer(&mut n, "", Z);
        let mut b = rect(&mut n, 40.0, 40.0, v(10.0, 10.0), "b");
        b.follow = Some(with(follow(t.id), edges(&[GraphicsEdges::LEFT, GraphicsEdges::TOP]), 0.0));
        let bid = b.id;
        let mut d = doc(vec![t, b]);
        d.editing_resolved(Time::ZERO, CANVAS, Some(NO_MEASURE), |x| x.translate(&[bid], v(190.0, 90.0)));
        assert_eq!(d.layer(bid).unwrap().animation.position.value, v(200.0, 100.0));
    }

    #[test]
    fn resize_of_a_stretched_follower_keeps_the_stretched_size() {
        use crate::graphics_editing::{GraphicsCorner, GraphicsDocumentEditingExt as _, ResizeDrag};
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, Z, "a");
        let mut b = rect(&mut n, 10.0, 10.0, Z, "b");
        b.follow = Some(with(follow(a.id), edges(&[GraphicsEdges::LEFT, GraphicsEdges::RIGHT]), 5.0)); // width stretched
        let bid = b.id;
        let mut d = doc(vec![a, b]);
        assert!(near(b0(&d, bid), r(-105.0, -5.0, 105.0, 5.0)));
        let mut ids = SequentialIds::default();
        d.editing_resolved(Time::ZERO, CANVAS, Some(MEASURE), |x| {
            x.resize(
                bid,
                ResizeDrag { corner: GraphicsCorner::BottomRight, to: v(300.0, 45.0), keep_aspect: false },
                Time::ZERO,
                Some(MEASURE),
                &mut ids,
            )
        });
        // Height follows the drag from the drawn top edge (-5 -> 45 = 50); width stays Follow's.
        let rr = b0(&d, bid).unwrap();
        assert!((rr.height() - 50.0).abs() < 1e-6 && (rr.min_x - -105.0).abs() < 1e-6);
        assert!((rr.max_x - 105.0).abs() < 1e-6 && (rr.min_y - -5.0).abs() < 1e-6);
        assert_eq!(d.layer(bid).unwrap().shape_style(Time::ZERO).unwrap().width, 10.0);
    }

    #[test]
    fn rotated_shape_follower_only_moves() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, v(300.0, 0.0), "a");
        let mut b = rect(&mut n, 40.0, 20.0, v(-500.0, 0.0), "b");
        b.animation.rotation = AnimatedProperty::new(30.0);
        b.follow = Some(pad(a.id, 10.0));
        let res = resolved(&doc(vec![a, b.clone()]), Time::ZERO);
        let st = res.layer(b.id).unwrap().shape_style(Time::ZERO).unwrap();
        assert_eq!((st.width, st.height), (40.0, 20.0));
        let bb = res.bounds_of(b.id, Time::ZERO, Some(MEASURE)).unwrap();
        assert!((bb.mid_x() - 300.0).abs() < 1e-6 && bb.mid_y().abs() < 1e-6);
    }

    fn eval_timeline(layers: Vec<GraphicsLayer>) -> Timeline {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video], &mut ids);
        let at = GeneratorPlacement { timeline: tl, track: tr[0], start: Time::ZERO, duration: s(5) };
        p.add_graphics_clip(at, layers, &mut ids).unwrap();
        p.timelines.remove(0)
    }

    fn none(_: Id) -> Option<&'static Timeline> {
        None
    }

    fn provider_fn(
        r: &GeneratorRef,
        _: Id,
        _: Id,
        _: Time,
        _: Time,
        _: &SequenceFormat,
        _: bool,
    ) -> Option<GraphicsRect> {
        measure_fn(r, GraphicsTextTime { local: Time::ZERO, duration: None })
    }

    #[test]
    fn evaluation_draws_the_resolved_layers() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, v(100.0, 0.0), "a");
        let mut b = rect(&mut n, 10.0, 10.0, v(-600.0, 0.0), "b");
        b.follow = Some(pad(a.id, 10.0));
        let tl = eval_timeline(vec![b.clone(), a.clone()]);
        let hook = follow_hook(Some(&provider_fn), false);
        let hooks = LayerHooks { resolve_follow: &hook, ..LayerHooks::plain() };
        let reqs = tl.video_layers(s(1), &none, &hooks, None);
        let rb = reqs.iter().find(|q| q.clip == b.id).unwrap();
        let shape = rb.shape.as_ref().unwrap();
        assert_eq!((shape.width, shape.height), (220.0, 120.0));
        assert_eq!(rb.transform.position, v(100.0, 0.0));
        // Same picture as the resolved document (the Graphics overlay draws from it).
        let res = resolved(&doc(vec![b.clone(), a]), s(1));
        assert_eq!(rb.shape, res.layer(b.id).unwrap().shape_style(s(1)));
    }

    #[test]
    fn layers_without_follow_evaluate_identically() {
        let mut n = SequentialIds::default();
        let a = rect(&mut n, 200.0, 100.0, v(100.0, 0.0), "a");
        let b = rect(&mut n, 10.0, 10.0, v(-600.0, 0.0), "b");
        let mut b2 = b.clone();
        b2.follow = Some(with(follow(a.id), GraphicsEdges(0), 0.0));
        let (t0, t1) = (eval_timeline(vec![b, a.clone()]), eval_timeline(vec![b2, a]));
        let hook = follow_hook(Some(&provider_fn), false);
        let hooks = LayerHooks { resolve_follow: &hook, ..LayerHooks::plain() };
        let (r0, r1) = (t0.video_layers(s(1), &none, &hooks, None), t1.video_layers(s(1), &none, &hooks, None));
        assert!(r0.len() == 2 && r1.len() == 2);
        for (x, y) in r0.iter().zip(&r1) {
            assert!(x.transform == y.transform && x.shape == y.shape && x.effects == y.effects);
        }
    }

    fn drag_setup(n: &mut SequentialIds) -> (GraphicsDocument, Id, Id) {
        let t = text_layer(n, "Title", Z); // 50 x 40 at the center
        let mut b = rect(n, 10.0, 10.0, v(300.0, 300.0), "Box");
        b.follow = Some(pad(t.id, 10.0));
        let (tid, bid) = (t.id, b.id);
        (doc(vec![b, t]), tid, bid)
    }

    fn drawn(d: &GraphicsDocument, id: Id) -> GraphicsRect {
        d.resolving_follow(Time::ZERO, CANVAS, Some(MEASURE)).bounds_of(id, Time::ZERO, Some(MEASURE)).unwrap()
    }

    #[test]
    fn drag_unpins_the_moved_axis_and_keeps_the_drawn_box() {
        let mut n = SequentialIds::default();
        let (mut d, _, b) = drag_setup(&mut n);
        let shown = drawn(&d, b);
        d.move_editing_resolved(&[b], v(40.0, 0.0), Time::ZERO, CANVAS, Some(MEASURE));
        assert_eq!(
            d.layer(b).unwrap().follow.as_ref().map(|f| f.edges),
            Some(edges(&[GraphicsEdges::TOP, GraphicsEdges::BOTTOM]))
        );
        let after = drawn(&d, b);
        assert!((after.min_x - (shown.min_x + 40.0)).abs() < 1e-6 && (after.max_x - (shown.max_x + 40.0)).abs() < 1e-6);
        assert!((after.min_y - shown.min_y).abs() < 1e-6 && (after.max_y - shown.max_y).abs() < 1e-6);
    }

    #[test]
    fn drag_on_both_axes_drops_the_follow() {
        let mut n = SequentialIds::default();
        let (mut d, _, b) = drag_setup(&mut n);
        d.move_editing_resolved(&[b], v(5.0, 5.0), Time::ZERO, CANVAS, Some(MEASURE));
        assert!(d.layer(b).unwrap().follow.is_none());
    }

    #[test]
    fn targets_and_free_layers_just_move() {
        let mut n = SequentialIds::default();
        let (mut d, text, b) = drag_setup(&mut n);
        d.move_editing_resolved(&[text], v(7.0, 0.0), Time::ZERO, CANVAS, Some(MEASURE));
        assert_eq!(d.layer(text).unwrap().animation.position.value, v(7.0, 0.0));
        assert_eq!(d.layer(b).unwrap().follow.as_ref().map(|f| f.edges), Some(GraphicsEdges::ALL));
    }

    #[test]
    fn padding_per_edge_collapses_when_equal() {
        let mut f = GraphicsFollow::to_target(FollowTarget::Frame);
        f.padding = 4.0;
        f.set_padding(9.0, GraphicsEdges::LEFT);
        assert_eq!(f.edge_padding, Some(GraphicsEdgePadding { left: 9.0, top: 4.0, right: 4.0, bottom: 4.0 }));
        f.set_padding(4.0, GraphicsEdges::LEFT);
        assert!(f.edge_padding.is_none() && f.padding == 4.0);
        f.set_padding(1.0, GraphicsEdges::ALL); // not a single edge: ignored
        assert!(f.edge_padding.is_none());
    }
}
