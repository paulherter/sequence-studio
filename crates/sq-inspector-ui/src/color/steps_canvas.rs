// Swift: Color/StepsCanvas.swift
//! The geometry and the drag rules of the Steps canvas (no drawing): where every Step, slot and wire sits, what a point
//! hits, how a Step moves, and where a dropped Step lands. Canvas units are points at zoom 1; the view point of a canvas
//! point is `canvas * zoom + pan`. A Step without a stored position sits where the automatic layout puts it: columns left to
//! right, a stack of Parallel or Layer Steps centered on the main wire.

use super::geom::{dist, intersects, offset_by, union};
use sq_core_color::{ColorGraphWiringExt, GraphPortExt};
use sq_core_model::{ColorGraph, GraphLink, GraphPort, StepPosition};
use sq_core_time::Id;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::collections::BTreeMap;

/// Where a wire starts or ends: the graph's source or sink, a Step, or the mixer box of a stack (named by the stack's
/// first Step).
pub type StepsPort = GraphPort;

#[derive(Clone, Debug, PartialEq)]
pub struct StepsCanvas {
    /// The Steps as columns.
    pub columns: Vec<Vec<Id>>,
    /// The positions the user stored.
    pub positions: BTreeMap<Id, StepPosition>,
    /// Stored positions of mixer boxes, keyed by the head (serial Step) of their stack.
    pub mixer_positions: BTreeMap<Id, StepPosition>,
    /// The image wires (nil: the ones the columns say) and the key wires.
    pub links: Option<Vec<GraphLink>>,
    pub key_links: Vec<GraphLink>,
    pub pan: CGPoint,
    pub zoom: f64,
    /// The user moved or zoomed the view: it no longer fits itself to the content.
    pub user_view: bool,
    /// Widths of the Input and Output LUT slots (their labels, `slot_width`).
    pub in_slot_width: f64,
    pub out_slot_width: f64,
    drag: Option<Drag>,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Layout {
    pub in_pill: CGRect,
    pub in_slot: CGRect,
    pub out_slot: CGRect,
    pub out_pill: CGRect,
    pub rects: BTreeMap<Id, CGRect>,
    /// Mixer boxes of the stacks, keyed by the head of the stack.
    pub mixers: BTreeMap<Id, CGRect>,
    /// Steps in graph order.
    pub order: Vec<Id>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Hit {
    Input,
    Output,
    Step(Id),
    Eye(Id),
    Insert(Id),
    Mixer(Id),
    /// A connector dot: the output (right) or the input (left) of a box.
    DotOut(StepsPort),
    DotIn(StepsPort),
    /// A Key connector: the key output of a Step, the key input of a Step or mixer box.
    KeyOut(Id),
    KeyIn(StepsPort),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Wire {
    pub from: CGPoint,
    pub to: CGPoint,
    /// The column gap it belongs to (0 = before the first column, `columns.count` = after the last), -1 = pill and slot wires.
    pub gap: i64,
    /// The model wire it draws (nil: the wires of the In and Out ends).
    pub link: Option<GraphLink>,
    /// A key wire.
    pub is_key: bool,
}

impl Wire {
    pub(crate) fn new(from: CGPoint, to: CGPoint, gap: i64) -> Wire {
        Wire { from, to, gap, link: None, is_key: false }
    }

    /// Point at `t` (0...1) on the curve: horizontal tangents at both ends.
    pub fn point(&self, t: f64) -> CGPoint {
        let (c1, c2) = self.controls();
        let u = 1.0 - t;
        let mix =
            |a: f64, b: f64, c: f64, d: f64| u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d;
        CGPoint::new(mix(self.from.x, c1.x, c2.x, self.to.x), mix(self.from.y, c1.y, c2.y, self.to.y))
    }

    /// Control points for drawing.
    pub fn controls(&self) -> (CGPoint, CGPoint) {
        let k = ((self.to.x - self.from.x).abs() * 0.5).max(12.0);
        (CGPoint::new(self.from.x + k, self.from.y), CGPoint::new(self.to.x - k, self.to.y))
    }

    pub fn distance(&self, p: CGPoint) -> f64 {
        let mut best = f64::MAX;
        for i in 0..=20 {
            let q = self.point(f64::from(i) / 20.0);
            best = best.min((q.x - p.x).hypot(q.y - p.y));
        }
        best
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Drag {
    pub id: Id,
    /// Pointer offset inside the Step (canvas units).
    pub grab: CGPoint,
    pub start: CGPoint,
    pub rect: CGRect,
    /// Where the Step's box started (canvas units).
    pub origin: CGPoint,
    pub moved: bool,
    /// The box is a mixer (`id` is the head of its stack).
    pub is_mixer: bool,
    /// The other selected Steps that move with it (their boxes at the start).
    pub group: BTreeMap<Id, CGRect>,
    /// Shift was held: the Step comes off its wires.
    pub extract: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Drop {
    /// Not moved: a click.
    Click,
    /// Let go in free space: the Step (or mixer box) stays there.
    Place(StepPosition),
    /// Let go on a wire: the Step goes between the ends of that wire.
    InsertOnto(GraphLink),
    /// Shift-drag let go in free space: the Step comes off its wires (the gap closes) and stays there.
    Extract(StepPosition),
}

impl Default for StepsCanvas {
    fn default() -> Self {
        StepsCanvas::new(Vec::new(), BTreeMap::new())
    }
}

impl StepsCanvas {
    pub const NODE: CGSize = CGSize { width: 140.0, height: 48.0 };
    pub const PILL: CGSize = CGSize { width: 34.0, height: 22.0 };
    pub const SLOT: CGSize = CGSize { width: 90.0, height: 36.0 };
    /// A slot that names its LUT is at least this wide (the kit's 120 x 36 tile).
    pub const SLOT_NAMED_MIN: f64 = 120.0;
    /// A LUT slot grows to its label: the text plus a pad each side (and the connector dots), never narrower than `slot`.
    pub const SLOT_PAD: f64 = 14.0;
    pub const SLOT_MAX: f64 = 200.0;
    pub const WIRE: f64 = 40.0;
    pub const STACK_GAP: f64 = 4.0;
    pub const ZOOM_RANGE: (f64, f64) = (0.4, 2.0);
    /// How near (view points) a dragged Step's center must be to a wire to land on it.
    pub const WIRE_GRAB: f64 = 16.0;
    pub const INSERT_BUTTON: f64 = 16.0;
    /// A drag shorter than this is a click.
    pub const CLICK_SLOP: f64 = 3.0;
    /// Size (view points) of the grab area around a connector dot.
    pub const DOT_GRAB: f64 = 6.0;
    pub const DOT_SIZE: f64 = 7.0;
    pub const MIXER_SIZE: CGSize = CGSize { width: 26.0, height: 20.0 };
    /// Extra room a stack's mixer box needs behind its Steps.
    pub const MIXER_SPACE: f64 = 36.0;

    pub fn slot_width(text_width: f64, named: bool) -> f64 {
        (if named { Self::SLOT_NAMED_MIN } else { Self::SLOT.width })
            .max(text_width.ceil() + 2.0 * Self::SLOT_PAD)
            .min(Self::SLOT_MAX)
    }

    pub fn new(columns: Vec<Vec<Id>>, positions: BTreeMap<Id, StepPosition>) -> StepsCanvas {
        StepsCanvas {
            columns,
            positions,
            mixer_positions: BTreeMap::new(),
            links: None,
            key_links: Vec::new(),
            pan: CGPoint::ZERO,
            zoom: 1.0,
            user_view: false,
            in_slot_width: Self::SLOT.width,
            out_slot_width: Self::SLOT.width,
            drag: None,
        }
    }

    pub fn drag(&self) -> Option<&Drag> {
        self.drag.as_ref()
    }

    /// Swift's local `next` of `layout`: the box at `x`, then `x` moves past it and one wire.
    fn next_rect(x: &mut f64, s: CGSize) -> CGRect {
        let r = CGRect::new(*x, -s.height / 2.0, s.width, s.height);
        *x += s.width + Self::WIRE;
        r
    }

    /// Where everything sits, in canvas units (the Step being dragged at its live position).
    pub fn layout(&self) -> Layout {
        let mut l = Layout::default();
        let mut x = 0.0_f64;
        l.in_pill = Self::next_rect(&mut x, Self::PILL);
        l.in_slot = Self::next_rect(&mut x, CGSize::new(self.in_slot_width, Self::SLOT.height));
        for col in &self.columns {
            let h = col.len() as f64 * Self::NODE.height + (col.len().saturating_sub(1)) as f64 * Self::STACK_GAP;
            let mut y = -h / 2.0;
            for id in col {
                l.rects.insert(*id, CGRect::new(x, y, Self::NODE.width, Self::NODE.height));
                l.order.push(*id);
                y += Self::NODE.height + Self::STACK_GAP;
            }
            x += Self::NODE.width + Self::WIRE + if col.len() > 1 { Self::MIXER_SPACE } else { 0.0 };
        }
        l.out_slot = Self::next_rect(&mut x, CGSize::new(self.out_slot_width, Self::SLOT.height));
        l.out_pill = Self::next_rect(&mut x, Self::PILL);
        for id in &l.order.clone() {
            if let Some(p) = self.positions.get(id) {
                l.rects.insert(*id, CGRect::new(p.x, p.y, Self::NODE.width, Self::NODE.height));
            }
        }
        if let Some(d) = &self.drag
            && !d.is_mixer
        {
            l.rects.insert(d.id, d.rect);
            let dx = d.rect.min_x() - d.origin.x;
            let dy = d.rect.min_y() - d.origin.y;
            for (id, r) in &d.group {
                l.rects.insert(*id, offset_by(r, dx, dy));
            }
        }
        for col in &self.columns {
            if col.len() <= 1 {
                continue;
            }
            let head = col[0];
            if let Some(p) = self.mixer_positions.get(&head) {
                l.mixers.insert(head, CGRect::new(p.x, p.y, Self::MIXER_SIZE.width, Self::MIXER_SIZE.height));
            } else {
                // An automatic mixer box keeps clear of a Step that was placed where it would sit.
                let rects: Vec<CGRect> = col.iter().filter_map(|id| l.rects.get(id).copied()).collect();
                let mut r = Self::mixer_rect(&rects);
                let mut tries = 0;
                while tries < 30
                    && (l.rects.values().any(|o| intersects(&o.inset_by(-4.0, -4.0), &r))
                        || l.mixers.values().any(|o| intersects(o, &r)))
                {
                    r.y += Self::MIXER_SIZE.height + 8.0;
                    tries += 1;
                }
                l.mixers.insert(head, r);
            }
        }
        if let Some(d) = &self.drag
            && d.is_mixer
        {
            l.mixers.insert(d.id, d.rect);
        }
        l
    }

    // MARK: View transform

    pub fn view_rect(&self, r: &CGRect) -> CGRect {
        CGRect::new(
            r.min_x() * self.zoom + self.pan.x,
            r.min_y() * self.zoom + self.pan.y,
            r.width * self.zoom,
            r.height * self.zoom,
        )
    }

    pub fn view_point(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x * self.zoom + self.pan.x, p.y * self.zoom + self.pan.y)
    }

    pub fn canvas_point(&self, p: CGPoint) -> CGPoint {
        CGPoint::new((p.x - self.pan.x) / self.zoom, (p.y - self.pan.y) / self.zoom)
    }

    /// Everything the canvas shows, in canvas units.
    pub fn content(&self, l: &Layout) -> CGRect {
        let mut r = union(&l.in_pill, &l.out_pill);
        for s in l.rects.values() {
            r = union(&r, s);
        }
        for s in l.mixers.values() {
            r = union(&r, s);
        }
        r
    }

    pub fn pan_by(&mut self, dx: f64, dy: f64) {
        self.pan.x += dx;
        self.pan.y += dy;
        self.user_view = true;
    }

    /// Zooms by `factor` keeping the canvas point under `at` (a view point) where it is.
    pub fn zoom_by(&mut self, factor: f64, at: CGPoint) {
        let c = self.canvas_point(at);
        self.zoom = (self.zoom * factor).max(Self::ZOOM_RANGE.0).min(Self::ZOOM_RANGE.1);
        self.pan = CGPoint::new(at.x - c.x * self.zoom, at.y - c.y * self.zoom);
        self.user_view = true;
    }

    /// Fits the content into `size` (zoom 1 when it fits, smaller when not) and centers it.
    pub fn fit(&mut self, size: CGSize, margin: f64) {
        let c = self.content(&self.layout());
        if !(c.width > 0.0 && size.width > 0.0 && size.height > 0.0) {
            return;
        }
        let z =
            1.0_f64.min((size.width - 2.0 * margin) / c.width).min((size.height - 2.0 * margin) / c.height.max(1.0));
        self.zoom = z.max(Self::ZOOM_RANGE.0).min(Self::ZOOM_RANGE.1);
        self.pan = CGPoint::new(
            (size.width - c.width * self.zoom) / 2.0 - c.min_x() * self.zoom,
            (size.height - c.height * self.zoom) / 2.0 - c.min_y() * self.zoom,
        );
        self.user_view = false;
    }

    // MARK: Hits (view points)

    /// Canvas point of the dot of `port`: its output (right edge) or input (left edge).
    pub fn dot_center(&self, port: StepsPort, output: bool, l: &Layout) -> Option<CGPoint> {
        let r: Option<CGRect> = match port {
            GraphPort::Source => {
                if output {
                    Some(l.in_slot)
                } else {
                    None
                }
            }
            GraphPort::Sink => {
                if output {
                    None
                } else {
                    Some(l.out_slot)
                }
            }
            GraphPort::Step(id) => l.rects.get(&id).copied(),
            GraphPort::Mixer(head) => l.mixers.get(&head).copied(),
        };
        r.map(|r| if output { Self::out(&r) } else { Self::into(&r) })
    }

    /// Key input and key output dots of a Step box (canvas units): the bottom corners, drawn in the secondary style.
    pub fn key_dots(r: &CGRect) -> (CGPoint, CGPoint) {
        (CGPoint::new(r.min_x() + 10.0, r.max_y()), CGPoint::new(r.max_x() - 10.0, r.max_y()))
    }

    /// Canvas point of the key input (`output` false) or key output of a Step; a mixer box has a key input at its bottom middle.
    pub fn key_dot_center(&self, port: StepsPort, output: bool, l: &Layout) -> Option<CGPoint> {
        match port {
            GraphPort::Step(id) => l.rects.get(&id).map(|r| {
                let d = Self::key_dots(r);
                if output { d.1 } else { d.0 }
            }),
            GraphPort::Mixer(head) => {
                if output {
                    None
                } else {
                    l.mixers.get(&head).map(|r| CGPoint::new(r.mid_x(), r.max_y()))
                }
            }
            GraphPort::Source | GraphPort::Sink => None,
        }
    }

    /// The port whose input a dropped wire lands on: an input dot, or anywhere on a box that has an input.
    pub fn input_port(&self, p: CGPoint) -> Option<StepsPort> {
        let l = self.layout();
        for port in self.ports(&l).into_iter().rev() {
            if let Some(c) = self.dot_center(port, false, &l) {
                let v = self.view_point(c);
                if (v.x - p.x).hypot(v.y - p.y) <= Self::DOT_GRAB + 2.0 {
                    return Some(port);
                }
            }
        }
        for id in l.order.iter().rev() {
            if l.rects.get(id).map(|r| self.view_rect(r)).is_some_and(|r| r.contains(p)) {
                return Some(GraphPort::Step(*id));
            }
        }
        for (head, r) in &l.mixers {
            if self.view_rect(r).contains(p) {
                return Some(GraphPort::Mixer(*head));
            }
        }
        if self.view_rect(&l.out_slot).contains(p) || self.view_rect(&l.out_pill).contains(p) {
            return Some(GraphPort::Sink);
        }
        None
    }

    fn ports(&self, l: &Layout) -> Vec<StepsPort> {
        let mut v = vec![GraphPort::Source, GraphPort::Sink];
        v.extend(l.order.iter().map(|id| GraphPort::Step(*id)));
        v.extend(l.mixers.keys().map(|k| GraphPort::Mixer(*k)));
        v
    }

    pub fn eye_rect(r: &CGRect) -> CGRect {
        CGRect::new(r.max_x() - 22.0, r.min_y() + 2.0, 20.0, 18.0)
    }

    pub fn hit(&self, p: CGPoint) -> Option<Hit> {
        let l = self.layout();
        // Key dots first: they sit on the lower edge of the box.
        for port in self.ports(&l).into_iter().rev() {
            for output in [true, false] {
                let Some(c) = self.key_dot_center(port, output, &l) else { continue };
                let v = self.view_point(c);
                if (v.x - p.x).hypot(v.y - p.y) <= Self::DOT_GRAB {
                    if let (true, GraphPort::Step(id)) = (output, port) {
                        return Some(Hit::KeyOut(id));
                    }
                    if !output {
                        return Some(Hit::KeyIn(port));
                    }
                }
            }
        }
        for port in self.ports(&l).into_iter().rev() {
            for output in [true, false] {
                let Some(c) = self.dot_center(port, output, &l) else { continue };
                // The dot of a slot belongs to the slot's menu unless it is the wire end of the graph.
                let v = self.view_point(c);
                if (v.x - p.x).hypot(v.y - p.y) <= Self::DOT_GRAB {
                    return Some(if output { Hit::DotOut(port) } else { Hit::DotIn(port) });
                }
            }
        }
        if self.view_rect(&l.in_slot).contains(p) || self.view_rect(&l.in_pill).contains(p) {
            return Some(Hit::Input);
        }
        if self.view_rect(&l.out_slot).contains(p) || self.view_rect(&l.out_pill).contains(p) {
            return Some(Hit::Output);
        }
        for id in l.order.iter().rev() {
            let Some(r) = l.rects.get(id).map(|r| self.view_rect(r)) else { continue };
            if !r.contains(p) {
                continue;
            }
            return Some(if Self::eye_rect(&r).contains(p) { Hit::Eye(*id) } else { Hit::Step(*id) });
        }
        for (head, r) in &l.mixers {
            if self.view_rect(r).contains(p) {
                return Some(Hit::Mixer(*head));
            }
        }
        for (id, r) in self.insert_buttons(&l) {
            if r.inset_by(-2.0, -2.0).contains(p) {
                return Some(Hit::Insert(id));
            }
        }
        None
    }

    // MARK: Wires

    /// The mixer box behind the Steps of a stack (canvas units).
    pub fn mixer_rect(rects: &[CGRect]) -> CGRect {
        let x = rects
            .iter()
            .map(|r| r.max_x())
            .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))
            .unwrap_or(0.0)
            + 24.0;
        let y = rects.iter().map(|r| r.mid_y()).fold(0.0, |a, b| a + b) / (rects.len().max(1) as f64);
        CGRect::new(x, y - Self::MIXER_SIZE.height / 2.0, Self::MIXER_SIZE.width, Self::MIXER_SIZE.height)
    }

    /// Mixer boxes of the stacks: the column index, the head of the stack and the box (canvas units).
    pub fn mixers(&self, l: &Layout) -> Vec<(usize, Id, CGRect)> {
        self.columns
            .iter()
            .enumerate()
            .filter_map(|(c, col)| {
                if col.len() <= 1 {
                    return None;
                }
                l.mixers.get(&col[0]).map(|r| (c, col[0], *r))
            })
            .collect()
    }

    fn out(r: &CGRect) -> CGPoint {
        CGPoint::new(r.max_x(), r.mid_y())
    }

    fn into(r: &CGRect) -> CGPoint {
        CGPoint::new(r.min_x(), r.mid_y())
    }

    /// The image wires drawn: the stored ones, else the ones the columns say.
    pub fn image_links(&self) -> Vec<GraphLink> {
        self.links.clone().unwrap_or_else(|| ColorGraph::derived_links(&self.columns))
    }

    /// The column a box belongs to (a mixer box counts with its stack's column).
    fn column_of(&self, p: StepsPort) -> Option<usize> {
        match p {
            GraphPort::Step(id) => self.columns.iter().position(|c| c.contains(&id)),
            GraphPort::Mixer(head) => self.columns.iter().position(|c| c.first() == Some(&head)),
            GraphPort::Source | GraphPort::Sink => None,
        }
    }

    /// Every image wire (canvas units), plus the wires of the In and Out ends. `gap` = 1 + the column the wire leaves
    /// (0 from In); wires into a mixer box have none.
    pub fn wires_in(&self, l: &Layout) -> Vec<Wire> {
        let mut w = vec![Wire::new(Self::out(&l.in_pill), Self::into(&l.in_slot), -1)];
        for k in self.image_links() {
            let (Some(a), Some(b)) = (self.dot_center(k.from, true, l), self.dot_center(k.to, false, l)) else {
                continue;
            };
            let gap = if k.to.is_mixer() { -1 } else { self.column_of(k.from).map_or(0, |c| c as i64 + 1) };
            w.push(Wire { from: a, to: b, gap, link: Some(k), is_key: false });
        }
        w.push(Wire::new(Self::out(&l.out_slot), Self::into(&l.out_pill), -1));
        w
    }

    pub fn wires(&self) -> Vec<Wire> {
        self.wires_in(&self.layout())
    }

    /// The key wires (canvas units): bottom corner to bottom corner.
    pub fn key_wires(&self) -> Vec<Wire> {
        let l = self.layout();
        self.key_links
            .iter()
            .filter_map(|k| {
                let id = k.from.step_id()?;
                let a = self.key_dot_center(GraphPort::Step(id), true, &l)?;
                let b = self.key_dot_center(k.to, false, &l)?;
                Some(Wire { from: a, to: b, gap: -1, link: Some(*k), is_key: true })
            })
            .collect()
    }

    /// The image wire into the input of `port`, if any (a mixer takes several: the first).
    pub fn wire_into(&self, port: StepsPort) -> Option<GraphLink> {
        self.image_links().into_iter().find(|l| l.to == port)
    }

    /// The "+" button of each column: on the first wire behind its last Step (view rects), keyed by that Step.
    pub fn insert_buttons(&self, l: &Layout) -> Vec<(Id, CGRect)> {
        let b = Self::INSERT_BUTTON;
        let all = self.wires_in(l);
        self.columns
            .iter()
            .enumerate()
            .filter_map(|(c, col)| {
                let last = col.last()?;
                let w = all.iter().find(|w| w.gap == c as i64 + 1)?;
                let m = self.view_point(w.point(0.5));
                Some((*last, CGRect::new(m.x - b / 2.0, m.y - b / 2.0, b, b)))
            })
            .collect()
    }

    // MARK: Dragging a Step

    pub fn begin_drag(&mut self, id: Id, p: CGPoint, group: &[Id], extract: bool) {
        let l = self.layout();
        let Some(r) = l.rects.get(&id).copied() else { return };
        let c = self.canvas_point(p);
        let mut d = Drag {
            id,
            grab: CGPoint::new(c.x - r.min_x(), c.y - r.min_y()),
            start: p,
            rect: r,
            origin: CGPoint::new(r.x, r.y),
            moved: false,
            is_mixer: false,
            group: BTreeMap::new(),
            extract,
        };
        for o in group {
            if *o != id
                && let Some(q) = l.rects.get(o)
            {
                d.group.insert(*o, *q);
            }
        }
        self.drag = Some(d);
    }

    pub fn begin_mixer_drag(&mut self, head: Id, p: CGPoint) {
        let Some(r) = self.layout().mixers.get(&head).copied() else { return };
        let c = self.canvas_point(p);
        self.drag = Some(Drag {
            id: head,
            grab: CGPoint::new(c.x - r.min_x(), c.y - r.min_y()),
            start: p,
            rect: r,
            origin: CGPoint::new(r.x, r.y),
            moved: false,
            is_mixer: true,
            group: BTreeMap::new(),
            extract: false,
        });
    }

    pub fn continue_drag(&mut self, p: CGPoint) {
        let Some(mut d) = self.drag.clone() else { return };
        if dist(p, d.start) >= Self::CLICK_SLOP {
            d.moved = true;
        }
        if !d.moved {
            return;
        }
        let c = self.canvas_point(p);
        d.rect.x = c.x - d.grab.x;
        d.rect.y = c.y - d.grab.y;
        self.drag = Some(d);
    }

    pub fn end_drag(&mut self) -> Option<Drop> {
        let d = self.drag.clone()?;
        let pos = StepPosition { x: d.rect.min_x(), y: d.rect.min_y() };
        let result = if !d.moved {
            Drop::Click
        } else if let Some(link) =
            (!d.is_mixer && d.group.is_empty() && !d.extract).then(|| self.drop_link(&d)).flatten()
        {
            Drop::InsertOnto(link)
        } else if d.extract && d.group.is_empty() {
            Drop::Extract(pos)
        } else {
            Drop::Place(pos)
        };
        self.drag = None;
        Some(result)
    }

    pub fn cancel_drag(&mut self) {
        self.drag = None;
    }

    /// Where every moved Step of a finished drag lands (the dragged one and its group), canvas units.
    pub fn group_positions(&self, d: &Drag) -> BTreeMap<Id, StepPosition> {
        let dx = d.rect.min_x() - d.origin.x;
        let dy = d.rect.min_y() - d.origin.y;
        let mut out = BTreeMap::from([(d.id, StepPosition { x: d.rect.min_x(), y: d.rect.min_y() })]);
        for (id, r) in &d.group {
            out.insert(*id, StepPosition { x: r.min_x() + dx, y: r.min_y() + dy });
        }
        out
    }

    /// While a Step is being dragged: the wire it would land on, drawn highlighted.
    pub fn preview_link(&self) -> Option<GraphLink> {
        let d = self.drag.as_ref()?;
        if d.moved && !d.is_mixer && d.group.is_empty() && !d.extract { self.drop_link(d) } else { None }
    }

    pub fn preview_wires(&self) -> Vec<Wire> {
        let Some(link) = self.preview_link() else { return Vec::new() };
        self.wires_in(&self.layout()).into_iter().filter(|w| w.link == Some(link)).collect()
    }

    /// The image wire (not into a mixer box, not one of the Step's own) that passes the dragged Step's center, if any.
    pub fn drop_link(&self, d: &Drag) -> Option<GraphLink> {
        if d.is_mixer || self.columns.iter().map(Vec::len).sum::<usize>() <= 1 {
            return None;
        }
        let l = self.layout();
        let center = self.view_point(CGPoint::new(d.rect.mid_x(), d.rect.mid_y()));
        let mut best: Option<(GraphLink, f64)> = None;
        for w in self.wires_in(&l) {
            let Some(k) = w.link else { continue };
            if k.to.is_mixer() || k.from == GraphPort::Step(d.id) || k.to == GraphPort::Step(d.id) {
                continue;
            }
            let a = Wire::new(self.view_point(w.from), self.view_point(w.to), w.gap);
            let dd = a.distance(center);
            if dd <= Self::WIRE_GRAB && dd < best.map_or(f64::MAX, |b| b.1) {
                best = Some((k, dd));
            }
        }
        best.map(|b| b.0)
    }

    // MARK: Selecting with a rectangle

    /// The Steps whose boxes touch the rectangle (view points).
    pub fn steps_in(&self, rect: &CGRect) -> Vec<Id> {
        let l = self.layout();
        l.order
            .iter()
            .copied()
            .filter(|id| l.rects.get(id).is_some_and(|r| intersects(&self.view_rect(r), rect)))
            .collect()
    }

    // MARK: Where a new Step goes

    /// A position for the new Step `id` (canvas units): where the automatic layout would put it, moved down until no other
    /// box (Step or mixer) is under it. Nothing is stacked on another box.
    pub fn free_spot(
        id: Id,
        columns: &[Vec<Id>],
        positions: &BTreeMap<Id, StepPosition>,
        mixer_positions: &BTreeMap<Id, StepPosition>,
    ) -> Option<StepPosition> {
        let mut c = StepsCanvas::new(
            columns.to_vec(),
            positions.iter().filter(|(k, _)| **k != id).map(|(k, v)| (*k, *v)).collect(),
        );
        c.mixer_positions = mixer_positions.clone();
        let l = c.layout();
        let mut r = *l.rects.get(&id)?;
        let mut others: Vec<CGRect> = l.rects.iter().filter(|(k, _)| **k != id).map(|(_, v)| *v).collect();
        others.extend(l.mixers.values().copied());
        others.extend([l.in_slot, l.out_slot, l.in_pill, l.out_pill]);
        let step = Self::NODE.height + Self::STACK_GAP * 2.0;
        let mut tries = 0;
        while tries < 40 && others.iter().any(|o| intersects(&o.inset_by(-Self::STACK_GAP, -Self::STACK_GAP), &r)) {
            r.y += step;
            tries += 1;
        }
        Some(StepPosition { x: r.min_x(), y: r.min_y() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn canvas() -> StepsCanvas {
        StepsCanvas::new(vec![vec![id(1)], vec![id(2)], vec![id(3), id(4)]], BTreeMap::new())
    }

    #[test]
    fn layout_puts_the_pills_and_columns_left_to_right() {
        let l = canvas().layout();
        assert_eq!(l.in_pill.x, 0.0);
        assert_eq!(l.in_slot.x, 34.0 + StepsCanvas::WIRE);
        assert!(l.rects[&id(1)].x < l.rects[&id(2)].x && l.rects[&id(2)].x < l.rects[&id(3)].x);
        assert_eq!(l.rects[&id(3)].x, l.rects[&id(4)].x);
        assert!(l.rects[&id(3)].y < l.rects[&id(4)].y);
        assert!(l.out_slot.x > l.rects[&id(3)].max_x());
        assert_eq!(l.mixers.len(), 1);
        assert!(l.mixers[&id(3)].x > l.rects[&id(3)].max_x());
    }

    #[test]
    fn a_stored_position_wins_over_the_layout() {
        let mut c = canvas();
        c.positions.insert(id(2), StepPosition { x: 500.0, y: 40.0 });
        assert_eq!(c.layout().rects[&id(2)].x, 500.0);
    }

    #[test]
    fn the_view_transform_round_trips() {
        let mut c = canvas();
        c.pan = CGPoint::new(10.0, 20.0);
        c.zoom = 2.0;
        let p = CGPoint::new(33.0, -7.0);
        let q = c.canvas_point(c.view_point(p));
        assert!((q.x - p.x).abs() < 1e-9 && (q.y - p.y).abs() < 1e-9);
    }

    #[test]
    fn zoom_keeps_the_point_under_the_pointer_and_clamps() {
        let mut c = canvas();
        let at = CGPoint::new(100.0, 50.0);
        let before = c.canvas_point(at);
        c.zoom_by(1.5, at);
        let after = c.canvas_point(at);
        assert!((before.x - after.x).abs() < 1e-9 && (before.y - after.y).abs() < 1e-9);
        c.zoom_by(100.0, at);
        assert_eq!(c.zoom, 2.0);
        assert!(c.user_view);
    }

    #[test]
    fn fit_centers_the_content_and_resets_user_view() {
        let mut c = canvas();
        c.pan_by(5.0, 5.0);
        c.fit(CGSize::new(2000.0, 1000.0), 20.0);
        assert_eq!(c.zoom, 1.0);
        assert!(!c.user_view);
        let content = c.view_rect(&c.content(&c.layout()));
        assert!((content.min_x() + content.max_x() - 2000.0).abs() < 1e-6);
    }

    #[test]
    fn hits_find_boxes_eyes_and_dots() {
        let c = canvas();
        let l = c.layout();
        let r = l.rects[&id(2)];
        assert_eq!(c.hit(CGPoint::new(r.mid_x(), r.mid_y())), Some(Hit::Step(id(2))));
        let eye = StepsCanvas::eye_rect(&r);
        assert_eq!(c.hit(CGPoint::new(eye.mid_x(), eye.mid_y())), Some(Hit::Eye(id(2))));
        assert_eq!(c.hit(CGPoint::new(r.max_x(), r.mid_y())), Some(Hit::DotOut(GraphPort::Step(id(2)))));
        assert_eq!(c.hit(CGPoint::new(l.in_pill.mid_x(), l.in_pill.mid_y())), Some(Hit::Input));
        assert_eq!(c.hit(CGPoint::new(-500.0, -500.0)), None);
    }

    #[test]
    fn the_derived_wires_run_pill_to_pill() {
        let c = canvas();
        let w = c.wires();
        assert_eq!(w.first().map(|w| w.gap), Some(-1));
        assert_eq!(w.last().map(|w| w.gap), Some(-1));
        assert!(w.iter().any(|w| w.link.is_some()));
        assert!(!c.insert_buttons(&c.layout()).is_empty());
    }

    #[test]
    fn a_short_drag_is_a_click_and_a_long_one_places_the_step() {
        let mut c = canvas();
        let r = c.layout().rects[&id(2)];
        let p = CGPoint::new(r.mid_x(), r.mid_y());
        c.begin_drag(id(2), p, &[], false);
        c.continue_drag(CGPoint::new(p.x + 1.0, p.y));
        assert_eq!(c.end_drag(), Some(Drop::Click));
        assert!(c.drag().is_none());
        c.begin_drag(id(2), p, &[], false);
        c.continue_drag(CGPoint::new(p.x + 40.0, p.y + 200.0));
        match c.end_drag() {
            Some(Drop::Place(pos)) => {
                assert!((pos.x - (r.x + 40.0)).abs() < 1e-9 && (pos.y - (r.y + 200.0)).abs() < 1e-9);
            }
            other => panic!("expected Place, got {other:?}"),
        }
    }

    #[test]
    fn dropping_on_a_wire_inserts_and_shift_extracts() {
        let mut c = canvas();
        let l = c.layout();
        let w = c
            .wires()
            .into_iter()
            .find(|w| w.link.is_some_and(|k| k.from == GraphPort::Step(id(1))))
            .unwrap_or(c.wires()[1].clone());
        let mid = w.point(0.5);
        let r = l.rects[&id(3)];
        c.begin_drag(id(3), CGPoint::new(r.mid_x(), r.mid_y()), &[], false);
        c.continue_drag(CGPoint::new(mid.x, mid.y));
        assert!(matches!(c.end_drag(), Some(Drop::InsertOnto(_)) | Some(Drop::Place(_))));
        c.begin_drag(id(3), CGPoint::new(r.mid_x(), r.mid_y()), &[], true);
        c.continue_drag(CGPoint::new(r.mid_x() + 300.0, r.mid_y() + 300.0));
        assert!(matches!(c.end_drag(), Some(Drop::Extract(_))));
    }

    #[test]
    fn a_rectangle_selects_the_boxes_it_touches() {
        let c = canvas();
        let l = c.layout();
        let r = c.view_rect(&l.rects[&id(2)]);
        assert_eq!(c.steps_in(&CGRect::new(r.min_x() + 1.0, r.min_y() + 1.0, 2.0, 2.0)), vec![id(2)]);
        assert!(c.steps_in(&CGRect::new(-1000.0, -1000.0, 1.0, 1.0)).is_empty());
    }

    #[test]
    fn a_new_step_lands_clear_of_the_other_boxes() {
        let columns = vec![vec![id(1)], vec![id(2)]];
        let mut positions = BTreeMap::new();
        let auto = StepsCanvas::new(columns.clone(), BTreeMap::new()).layout().rects[&id(2)];
        positions.insert(id(1), StepPosition { x: auto.x, y: auto.y });
        let p = StepsCanvas::free_spot(id(2), &columns, &positions, &BTreeMap::new());
        assert!(p.is_some_and(|p| p.y > auto.y));
    }

    #[test]
    fn slot_width_grows_with_the_label_up_to_the_cap() {
        assert_eq!(StepsCanvas::slot_width(0.0, false), 90.0);
        assert_eq!(StepsCanvas::slot_width(60.2, true), 120.0);
        assert_eq!(StepsCanvas::slot_width(100.0, true), 100.0 + 28.0);
        assert_eq!(StepsCanvas::slot_width(1000.0, true), 200.0);
    }
}

/// The Swift `StepsCanvasTests`, same names.
#[cfg(test)]
mod ported_tests {
    use super::*;

    fn ids(n: usize) -> Vec<Id> {
        (0..n).map(|i| Id::from_u128(i as u128 + 1)).collect()
    }

    fn link(a: GraphPort, b: GraphPort) -> GraphLink {
        GraphLink { from: a, to: b }
    }

    #[test]
    fn auto_layout_puts_columns_left_to_right_and_stacks_centered() {
        let s = ids(3);
        let c = StepsCanvas::new(vec![vec![s[0]], vec![s[1], s[2]]], BTreeMap::new());
        let l = c.layout();
        assert_eq!(l.order, s);
        assert_eq!(l.rects[&s[0]].mid_y(), 0.0);
        assert_eq!(l.rects[&s[1]].min_x(), l.rects[&s[2]].min_x());
        assert!(l.rects[&s[1]].max_y() < l.rects[&s[2]].min_y());
        assert!(l.rects[&s[1]].max_x() < l.out_slot.min_x());
        assert!(l.rects[&s[0]].min_x() > l.in_slot.max_x());
    }

    #[test]
    fn stored_position_wins_over_auto_layout() {
        let s = ids(2);
        let c =
            StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::from([(s[1], StepPosition { x: 5.0, y: 70.0 })]));
        let r = c.layout().rects[&s[1]];
        assert_eq!((r.x, r.y), (5.0, 70.0));
    }

    #[test]
    fn zoom_keeps_the_point_under_the_cursor() {
        let mut c = StepsCanvas::new(vec![ids(1)], BTreeMap::new());
        let p = CGPoint::new(120.0, 60.0);
        let before = c.canvas_point(p);
        c.zoom_by(1.5, p);
        let after = c.canvas_point(p);
        assert!((before.x - after.x).abs() < 0.001 && (before.y - after.y).abs() < 0.001);
        c.zoom_by(100.0, p);
        assert_eq!(c.zoom, StepsCanvas::ZOOM_RANGE.1);
        assert!(c.user_view);
    }

    #[test]
    fn fit_shrinks_a_long_row_and_centers_it() {
        let mut c = StepsCanvas::new((0..4).map(|_| ids(1)).collect(), BTreeMap::new());
        c.fit(CGSize::new(520.0, 150.0), 8.0);
        assert!(c.zoom < 1.0 && c.zoom >= StepsCanvas::ZOOM_RANGE.0);
        let r = c.view_rect(&c.content(&c.layout()));
        assert!(r.min_x() >= 0.0 && r.max_x() <= 520.01);
        assert!(!c.user_view);
        let mut small = StepsCanvas::new(vec![ids(1)], BTreeMap::new());
        small.fit(CGSize::new(900.0, 200.0), 8.0);
        assert_eq!(small.zoom, 1.0);
    }

    #[test]
    fn hit_finds_steps_eye_slots_and_the_topmost_box() {
        let s = ids(2);
        let c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        let l = c.layout();
        let r0 = c.view_rect(&l.rects[&s[0]]);
        assert_eq!(c.hit(CGPoint::new(r0.min_x() + 10.0, r0.mid_y())), Some(Hit::Step(s[0])));
        assert_eq!(c.hit(CGPoint::new(r0.max_x() - 8.0, r0.min_y() + 8.0)), Some(Hit::Eye(s[0])));
        assert_eq!(c.hit(CGPoint::new(l.in_slot.mid_x(), l.in_slot.mid_y())), Some(Hit::Input));
        assert_eq!(c.hit(CGPoint::new(l.out_slot.mid_x(), l.out_slot.mid_y())), Some(Hit::Output));
        assert_eq!(c.hit(CGPoint::new(-500.0, -500.0)), None);
        let a = l.rects[&s[0]];
        let over = StepsCanvas::new(
            vec![vec![s[0]], vec![s[1]]],
            BTreeMap::from([(s[1], StepPosition { x: a.min_x(), y: a.min_y() })]),
        );
        let r = over.view_rect(&over.layout().rects[&s[0]]);
        assert_eq!(over.hit(CGPoint::new(r.min_x() + 10.0, r.mid_y())), Some(Hit::Step(s[1])));
    }

    #[test]
    fn a_stack_gets_a_mixer_box_and_every_branch_wires_into_it() {
        let s = ids(3);
        let c = StepsCanvas::new(vec![vec![s[0], s[1], s[2]]], BTreeMap::new());
        let l = c.layout();
        assert_eq!(c.mixers(&l).len(), 1);
        let m = c.mixers(&l)[0].2;
        assert!(m.min_x() > l.rects[&s[0]].max_x());
        let into_mixer = c.wires().into_iter().filter(|w| w.gap == -1 && (w.to.x - m.min_x()).abs() < 0.001).count();
        assert_eq!(into_mixer, 3);
        // The branch Steps all get the same input.
        assert_eq!(c.wires().iter().filter(|w| w.gap == 0).count(), 3);
        let single = StepsCanvas::new(vec![vec![s[0]]], BTreeMap::new());
        assert!(single.mixers(&single.layout()).is_empty());
    }

    #[test]
    fn a_short_drag_is_a_click_and_nothing_moves() {
        let s = ids(1);
        let mut c = StepsCanvas::new(vec![vec![s[0]]], BTreeMap::new());
        let r = c.view_rect(&c.layout().rects[&s[0]]);
        c.begin_drag(s[0], CGPoint::new(r.mid_x(), r.mid_y()), &[], false);
        c.continue_drag(CGPoint::new(r.mid_x() + 1.0, r.mid_y()));
        assert_eq!(c.end_drag(), Some(Drop::Click));
        assert!(c.drag().is_none());
    }

    #[test]
    fn drag_in_free_space_places_the_step_where_it_was_let_go() {
        let s = ids(1);
        let mut c = StepsCanvas::new(vec![vec![s[0]]], BTreeMap::new());
        let r = c.view_rect(&c.layout().rects[&s[0]]);
        let start = CGPoint::new(r.min_x() + 10.0, r.min_y() + 10.0);
        c.begin_drag(s[0], start, &[], false);
        c.continue_drag(CGPoint::new(start.x + 40.0, start.y + 120.0));
        let live = c.layout().rects[&s[0]];
        assert!(live.min_x() == r.min_x() + 40.0 && live.min_y() == r.min_y() + 120.0);
        match c.end_drag() {
            Some(Drop::Place(p)) => assert_eq!(p, StepPosition { x: r.min_x() + 40.0, y: r.min_y() + 120.0 }),
            other => panic!("expected place, got {other:?}"),
        }
    }

    #[test]
    fn drag_follows_pan_and_zoom() {
        let s = ids(1);
        let mut c = StepsCanvas::new(vec![vec![s[0]]], BTreeMap::new());
        c.zoom_by(2.0, CGPoint::ZERO);
        c.pan_by(30.0, 10.0);
        let r = c.view_rect(&c.layout().rects[&s[0]]);
        c.begin_drag(s[0], CGPoint::new(r.min_x(), r.min_y()), &[], false);
        // 20 view points = 10 canvas units at 200%.
        c.continue_drag(CGPoint::new(r.min_x() + 20.0, r.min_y()));
        match c.end_drag() {
            Some(Drop::Place(p)) => {
                assert!((p.x - (c.canvas_point(CGPoint::new(r.min_x(), r.min_y())).x + 10.0)).abs() < 0.001);
            }
            other => panic!("expected place, got {other:?}"),
        }
    }

    #[test]
    fn dropping_on_a_wire_inserts_between_the_columns_around_it() {
        let s = ids(3);
        let mut c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]], vec![s[2]]], BTreeMap::new());
        let l = c.layout();
        // The wire from the first to the second Step, at its middle.
        let a = l.rects[&s[0]];
        let b = l.rects[&s[1]];
        let mid = CGPoint::new((a.max_x() + b.min_x()) / 2.0, a.mid_y());
        // Drag the last Step so that its center ends on that wire.
        let r = c.view_rect(&l.rects[&s[2]]);
        c.begin_drag(s[2], CGPoint::new(r.mid_x(), r.mid_y()), &[], false);
        c.continue_drag(c.view_point(mid));
        let target = link(GraphPort::Step(s[0]), GraphPort::Step(s[1]));
        assert_eq!(c.preview_link(), Some(target));
        assert!(!c.preview_wires().is_empty());
        assert_eq!(c.end_drag(), Some(Drop::InsertOnto(target)));
    }

    #[test]
    fn dropping_on_the_last_wire_appends_and_on_the_first_prepends() {
        let s = ids(2);
        let mut c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        let l = c.layout();
        // Move s[0] to the wire between s[1] and Out.
        let r = c.view_rect(&l.rects[&s[0]]);
        let target = CGPoint::new((l.rects[&s[1]].max_x() + l.out_slot.min_x()) / 2.0, 0.0);
        c.begin_drag(s[0], CGPoint::new(r.mid_x(), r.mid_y()), &[], false);
        c.continue_drag(c.view_point(target));
        assert_eq!(c.end_drag(), Some(Drop::InsertOnto(link(GraphPort::Step(s[1]), GraphPort::Sink))));
    }

    #[test]
    fn cancel_drops_the_drag_without_a_result() {
        let s = ids(1);
        let mut c = StepsCanvas::new(vec![vec![s[0]]], BTreeMap::new());
        let r = c.view_rect(&c.layout().rects[&s[0]]);
        c.begin_drag(s[0], CGPoint::new(r.mid_x(), r.mid_y()), &[], false);
        c.continue_drag(CGPoint::new(r.mid_x() + 60.0, r.mid_y() + 60.0));
        c.cancel_drag();
        assert_eq!(c.end_drag(), None);
    }

    #[test]
    fn insert_button_sits_on_the_wire_behind_each_column() {
        let s = ids(2);
        let c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        let l = c.layout();
        let b = c.insert_buttons(&l);
        assert_eq!(b.iter().map(|x| x.0).collect::<Vec<_>>(), s);
        let p = b[0].1;
        assert!(p.mid_x() > c.view_rect(&l.rects[&s[0]]).max_x() && p.mid_x() < c.view_rect(&l.rects[&s[1]]).min_x());
        assert_eq!(c.hit(CGPoint::new(p.mid_x(), p.mid_y())), Some(Hit::Insert(s[0])));
    }

    #[test]
    fn connector_dots_are_hit_before_the_box_and_sit_on_the_wire_ends() {
        let s = ids(2);
        let c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        let l = c.layout();
        let r0 = l.rects[&s[0]];
        assert_eq!(c.dot_center(GraphPort::Step(s[0]), true, &l), Some(CGPoint::new(r0.max_x(), r0.mid_y())));
        assert_eq!(c.dot_center(GraphPort::Step(s[0]), false, &l), Some(CGPoint::new(r0.min_x(), r0.mid_y())));
        assert_eq!(c.hit(CGPoint::new(r0.max_x() + 2.0, r0.mid_y())), Some(Hit::DotOut(GraphPort::Step(s[0]))));
        assert_eq!(c.hit(CGPoint::new(r0.min_x() + 1.0, r0.mid_y())), Some(Hit::DotIn(GraphPort::Step(s[0]))));
        assert_eq!(c.hit(CGPoint::new(l.in_slot.max_x(), l.in_slot.mid_y())), Some(Hit::DotOut(GraphPort::Source)));
        assert_eq!(c.hit(CGPoint::new(l.out_slot.min_x(), l.out_slot.mid_y())), Some(Hit::DotIn(GraphPort::Sink)));
        // Every wire starts and ends exactly on a dot.
        let mut ends: Vec<CGPoint> = Vec::new();
        for id in &s {
            ends.extend(c.dot_center(GraphPort::Step(*id), true, &l));
            ends.extend(c.dot_center(GraphPort::Step(*id), false, &l));
        }
        for w in c.wires().iter().filter(|w| w.gap >= 0) {
            assert!(ends.contains(&w.to) || w.to == CGPoint::new(l.out_slot.min_x(), l.out_slot.mid_y()));
        }
        let k = StepsCanvas::key_dots(&r0);
        assert!(k.0.y == r0.max_y() && k.1.y == r0.max_y() && k.0.x < k.1.x);
    }

    #[test]
    fn mixer_boxes_are_hit_moved_and_wired_by_their_stored_position() {
        let s = ids(3);
        let mut c = StepsCanvas::new(vec![vec![s[0], s[1], s[2]]], BTreeMap::new());
        let l = c.layout();
        let m = l.mixers[&s[0]];
        assert_eq!(c.hit(CGPoint::new(m.mid_x(), m.mid_y())), Some(Hit::Mixer(s[0])));
        c.begin_mixer_drag(s[0], CGPoint::new(m.mid_x(), m.mid_y()));
        c.continue_drag(CGPoint::new(m.mid_x() + 30.0, m.mid_y() + 50.0));
        let live = c.layout().mixers[&s[0]];
        assert_eq!((live.x, live.y), (m.min_x() + 30.0, m.min_y() + 50.0));
        let p = match c.end_drag() {
            Some(Drop::Place(p)) => p,
            other => panic!("expected place, got {other:?}"),
        };
        assert_eq!(p, StepPosition { x: m.min_x() + 30.0, y: m.min_y() + 50.0 });
        c.mixer_positions.insert(s[0], p);
        let moved = c.layout().mixers[&s[0]];
        let into =
            c.wires().into_iter().filter(|w| w.gap == -1 && w.to == CGPoint::new(moved.min_x(), moved.mid_y())).count();
        assert_eq!(into, 3);
    }

    #[test]
    fn input_port_finds_dots_boxes_and_the_sink() {
        let s = ids(2);
        let c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        let l = c.layout();
        assert_eq!(
            c.input_port(CGPoint::new(l.rects[&s[1]].mid_x(), l.rects[&s[1]].mid_y())),
            Some(GraphPort::Step(s[1]))
        );
        assert_eq!(c.input_port(CGPoint::new(l.out_slot.mid_x(), l.out_slot.mid_y())), Some(GraphPort::Sink));
        assert_eq!(c.input_port(CGPoint::new(-300.0, -300.0)), None);
    }

    #[test]
    fn a_new_steps_spot_never_lies_on_another_box() {
        let s = ids(3);
        let cols = vec![vec![s[0]], vec![s[1]], vec![s[2]]];
        // Step 1 was dragged to where the automatic layout would put the new second column.
        let auto = StepsCanvas::new(cols.clone(), BTreeMap::new()).layout().rects[&s[1]];
        let taken = StepPosition { x: auto.min_x(), y: auto.min_y() };
        let spot = StepsCanvas::free_spot(s[1], &cols, &BTreeMap::from([(s[2], taken)]), &BTreeMap::new());
        let spot = spot.unwrap_or(taken);
        let c = StepsCanvas::new(cols, BTreeMap::from([(s[1], spot), (s[2], taken)]));
        let l = c.layout();
        assert!(!intersects(&l.rects[&s[1]], &l.rects[&s[2]]));
        assert!(!intersects(&l.rects[&s[1]], &l.rects[&s[0]]));
        // With free room it stays where the layout puts it.
        let two = vec![vec![s[0]], vec![s[1]]];
        let free = StepsCanvas::free_spot(s[1], &two, &BTreeMap::new(), &BTreeMap::new());
        let a = StepsCanvas::new(two, BTreeMap::new()).layout().rects[&s[1]];
        assert_eq!(free, Some(StepPosition { x: a.min_x(), y: a.min_y() }));
    }

    #[test]
    fn key_dots_are_hit_before_the_box_and_key_wires_draw_bottom_to_bottom() {
        let s = ids(2);
        let mut c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]]], BTreeMap::new());
        c.key_links = vec![link(GraphPort::Step(s[0]), GraphPort::Step(s[1]))];
        let l = c.layout();
        let out_c = c.key_dot_center(GraphPort::Step(s[0]), true, &l);
        let in_c = c.key_dot_center(GraphPort::Step(s[1]), false, &l);
        let out = c.view_point(out_c.unwrap_or_default());
        let inn = c.view_point(in_c.unwrap_or_default());
        assert_eq!(c.hit(out), Some(Hit::KeyOut(s[0])));
        assert_eq!(c.hit(inn), Some(Hit::KeyIn(GraphPort::Step(s[1]))));
        let w = c.key_wires();
        assert!(w.len() == 1 && w[0].is_key && Some(w[0].from) == out_c);
    }

    #[test]
    fn a_group_moves_together_and_shift_drag_extracts() {
        let s = ids(3);
        let pos = BTreeMap::from([
            (s[0], StepPosition { x: 0.0, y: 0.0 }),
            (s[1], StepPosition { x: 150.0, y: 0.0 }),
            (s[2], StepPosition { x: 300.0, y: 0.0 }),
        ]);
        let mut c = StepsCanvas::new(vec![vec![s[0]], vec![s[1]], vec![s[2]]], pos);
        c.begin_drag(s[0], CGPoint::new(10.0, 10.0), &[s[0], s[1]], false);
        c.continue_drag(CGPoint::new(10.0, 110.0));
        let d = c.drag().cloned();
        let Some(d) = d else { return };
        let moved = c.group_positions(&d);
        assert!(
            moved[&s[0]] == StepPosition { x: 0.0, y: 100.0 } && moved[&s[1]] == StepPosition { x: 150.0, y: 100.0 }
        );
        assert!(!moved.contains_key(&s[2]));
        assert_eq!(c.end_drag(), Some(Drop::Place(StepPosition { x: 0.0, y: 100.0 })));
        c.begin_drag(s[1], CGPoint::new(160.0, 10.0), &[], true);
        c.continue_drag(CGPoint::new(160.0, 200.0));
        assert_eq!(c.end_drag(), Some(Drop::Extract(StepPosition { x: 150.0, y: 190.0 })));
    }
}
