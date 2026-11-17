// Swift: GraphEditorGeometry.swift
//! Maps the speed curves to view points (origin top-left, y down) and hit-tests. Pure.

use std::collections::BTreeSet;
use std::ops::RangeInclusive;

use sq_core_model::keyframes_editing::{PropertyID, SummaryMember};
use sq_core_model::keyframes_graph::SpeedGraphSegment;
use sq_core_model::keyframes_speed_overlay::{KeySide, SpeedOverlayCurve, SpeedOverlayHandle, SpeedOverlayKey};
use sq_core_time::EaseHandle;
use sq_uikit::keyframe_graph_geometry::{GraphMath, Point, Rect};

use crate::ec::effect_controls_model::lane_geometry::KeyframeLaneGeometry;
use crate::ec::effect_controls_model::property::EffectProperty;

/// One property in the Graph Editor: its speed curve, its color slot (one color per property) and its display units.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEditorCurve {
    pub property: PropertyID,
    pub title: String,
    pub curve: SpeedOverlayCurve,
    pub color_index: usize,
    /// Native -> display units (Opacity and Scale x100); the hover readout shows display units per second.
    pub scale: f64,
    pub unit: String,
}

impl GraphEditorCurve {
    /// Swift default arguments: `scale: 1`, `unit: ""`.
    pub fn new(property: PropertyID, title: String, curve: SpeedOverlayCurve, color_index: usize) -> GraphEditorCurve {
        GraphEditorCurve { property, title, curve, color_index, scale: 1.0, unit: String::new() }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphEditorHit {
    Key(SummaryMember),
    Handle(SummaryMember, KeySide),
    Empty,
}

/// One drawn segment: its points and the factor from relative speed to display units per second.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEditorLine {
    pub points: Vec<Point>,
    pub units_per_relative: f64,
}

/// The curve under the pointer and its real speed there.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEditorHover {
    pub property: PropertyID,
    pub speed: f64,
}

/// Maps the speed curves to view points (origin top-left, y down) and hit-tests.
/// x: the keyframe lanes' mapping (`KeyframeLaneGeometry`), so keys sit under the ruler exactly as in the lanes.
/// y: one shared RELATIVE speed axis for every curve: speed / the segment's average speed (Steady = flat 1x, Smooth =
/// a bell to about 1.5-2x, 0 at the plot bottom). The same ease therefore looks the same on every property, whatever its
/// units; this is exactly what `EaseHandle` stores (dy/dx). Real units appear in the hover readout.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEditorGeometry {
    pub lane: KeyframeLaneGeometry,
    pub height: f64,
    pub curves: Vec<GraphEditorCurve>,
    /// Relative speed at the bottom (always 0) and top of the plot.
    pub range: RangeInclusive<f64>,
}

impl GraphEditorGeometry {
    pub const KEY_HIT_RADIUS: f64 = 7.0;
    pub const HANDLE_HIT_RADIUS: f64 = 9.0;
    pub const HOVER_RADIUS: f64 = 6.0;
    pub const TOP_INSET: f64 = 12.0;
    /// The toolbar sits at the bottom of the graph area, under the plot.
    pub const TOOLBAR_HEIGHT: f64 = 28.0;
    pub const BOTTOM_INSET: f64 = Self::TOOLBAR_HEIGHT + 8.0;
    /// The axis always shows at least 0...2.2x, so Steady (1x) and a normal Smooth fit without rescaling.
    pub const MIN_TOP: f64 = 2.2;

    pub fn new(lane: KeyframeLaneGeometry, height: f64, curves: Vec<GraphEditorCurve>) -> GraphEditorGeometry {
        let mut hi = 0.0f64;
        for c in &curves {
            for seg in &c.curve.segments {
                let Some(avg) = Self::average(c, seg) else { continue };
                for s in &seg.samples {
                    hi = hi.max(s.speed.abs() / avg);
                }
            }
            for h in &c.curve.handles {
                hi = hi.max(Self::relative(h).abs());
            }
        }
        GraphEditorGeometry { lane, height, curves, range: 0.0..=(hi * 1.1).max(Self::MIN_TOP) }
    }

    /// Never shrinks the axis below `other`'s top (used while a drag runs, so the plot does not jump under the pointer).
    pub fn growing(&self, other: &GraphEditorGeometry) -> GraphEditorGeometry {
        let mut g = self.clone();
        g.range = 0.0..=self.range.end().max(*other.range.end());
        g
    }

    pub fn plot_top(&self) -> f64 {
        Self::TOP_INSET
    }

    pub fn plot_bottom(&self) -> f64 {
        (self.height - Self::BOTTOM_INSET).max(self.plot_top() + 1.0)
    }

    pub fn y(&self, v: f64) -> f64 {
        let f = (v - self.range.start()) / (self.range.end() - self.range.start());
        self.plot_bottom() - f * (self.plot_bottom() - self.plot_top())
    }

    pub fn speed_at_y(&self, y: f64) -> f64 {
        let f = (self.plot_bottom() - y) / (self.plot_bottom() - self.plot_top());
        self.range.start() + f * (self.range.end() - self.range.start())
    }

    // MARK: Relative speed

    /// Average |speed| of a segment (native units per second); nil for Hold and zero-span segments.
    pub(crate) fn average(c: &GraphEditorCurve, seg: &SpeedGraphSegment) -> Option<f64> {
        let h = c.curve.handles.iter().find(|h| {
            (h.key_id == seg.from_id && h.side == KeySide::Outgoing)
                || (h.key_id == seg.to_id && h.side == KeySide::Incoming)
        })?;
        if h.segment_seconds <= 0.0 {
            return None;
        }
        let avg = h.span.abs() / h.segment_seconds;
        if avg > 1e-12 { Some(avg) } else { None }
    }

    /// A handle's speed relative to its segment's average (= EaseHandle slope dy/dx).
    pub(crate) fn relative(h: &SpeedOverlayHandle) -> f64 {
        let avg = if h.segment_seconds > 0.0 { h.span.abs() / h.segment_seconds } else { 0.0 };
        if avg > 1e-12 { h.speed / avg } else { 0.0 }
    }

    pub fn curve(&self, p: &PropertyID) -> Option<&GraphEditorCurve> {
        self.curves.iter().find(|c| c.property == *p)
    }

    /// A key sits at its outgoing speed (the incoming one for the last key); 0 next to Hold.
    pub fn key_point(&self, c: &GraphEditorCurve, k: &SpeedOverlayKey) -> Point {
        let h = c
            .curve
            .handles
            .iter()
            .find(|h| h.key_id == k.id && h.side == KeySide::Outgoing)
            .or_else(|| c.curve.handles.iter().find(|h| h.key_id == k.id));
        Point::new(self.lane.x_seconds(k.seconds), self.y(h.map_or(0.0, |h| Self::relative(h).abs())))
    }

    /// Handle position: x = key ± influence x a third of the segment (influence 1 stops at one third, short of the
    /// neighbor key, as in Premiere), y = its relative speed. Drawn, hit and dragged at the same point (no offset, no jump).
    pub fn handle_point(&self, c: &GraphEditorCurve, h: &SpeedOverlayHandle) -> Option<Point> {
        let k = c.curve.keys.iter().find(|k| k.id == h.key_id)?;
        let dir = if h.side == KeySide::Outgoing { 1.0 } else { -1.0 };
        let s = k.seconds + dir * h.influence * GraphMath::HANDLE_REACH * h.segment_seconds;
        Some(Point::new(self.lane.x_seconds(s), self.y(Self::relative(h).abs())))
    }

    pub fn handle_true_point(&self, c: &GraphEditorCurve, h: &SpeedOverlayHandle) -> Option<Point> {
        self.handle_point(c, h)
    }

    /// Drawn segments of a curve; a curve without keys, or a zero-span segment, is a flat line at 0. Hold draws nothing.
    pub fn lines(&self, c: &GraphEditorCurve) -> Vec<GraphEditorLine> {
        if c.curve.keys.is_empty() {
            return vec![GraphEditorLine {
                points: vec![Point::new(0.0, self.plot_bottom()), Point::new(self.lane.width, self.plot_bottom())],
                units_per_relative: 0.0,
            }];
        }
        c.curve
            .segments
            .iter()
            .filter_map(|seg| {
                let (first, last) = (seg.samples.first()?, seg.samples.last()?);
                let Some(avg) = Self::average(c, seg) else {
                    // Hold: nothing; zero span (both keys equal): flat at 0.
                    let is_hold =
                        !c.curve.handles.iter().any(|h| h.key_id == seg.from_id && h.side == KeySide::Outgoing);
                    return if is_hold {
                        None
                    } else {
                        Some(GraphEditorLine {
                            points: vec![
                                Point::new(self.lane.x_seconds(first.time), self.plot_bottom()),
                                Point::new(self.lane.x_seconds(last.time), self.plot_bottom()),
                            ],
                            units_per_relative: 0.0,
                        })
                    };
                };
                Some(GraphEditorLine {
                    points: seg
                        .samples
                        .iter()
                        .map(|s| Point::new(self.lane.x_seconds(s.time), self.y(s.speed.abs() / avg)))
                        .collect(),
                    units_per_relative: avg * c.scale,
                })
            })
            .collect()
    }

    pub fn polylines(&self, c: &GraphEditorCurve) -> Vec<Vec<Point>> {
        self.lines(c).into_iter().map(|l| l.points).collect()
    }

    /// Curve under the pointer (nearest within `HOVER_RADIUS` vertically) and its real speed there, display units/s.
    pub fn hover(&self, p: Point) -> Option<GraphEditorHover> {
        let mut best: Option<(PropertyID, f64, f64)> = None;
        for c in &self.curves {
            for line in self.lines(c) {
                for w in line.points.windows(2) {
                    let (a, b) = (w[0], w[1]);
                    if a.x <= p.x && p.x <= b.x {
                        let f = if b.x > a.x { (p.x - a.x) / (b.x - a.x) } else { 0.0 };
                        let y = a.y + f * (b.y - a.y);
                        let d = (y - p.y).abs();
                        if d <= Self::HOVER_RADIUS && d < best.as_ref().map_or(f64::INFINITY, |b| b.2) {
                            best = Some((c.property.clone(), self.speed_at_y(y) * line.units_per_relative, d));
                        }
                    }
                }
            }
        }
        best.map(|b| GraphEditorHover { property: b.0, speed: b.1 })
    }

    /// Round relative speeds for the y-axis labels and horizontal grid lines (about four lines).
    pub fn speed_ticks(&self) -> Vec<f64> {
        let step = Self::nice_step(self.range.end() / 4.0);
        if step <= 0.0 {
            return Vec::new();
        }
        Self::stride(step, step, *self.range.end())
    }

    /// Times (clip-local seconds) of the vertical grid lines, about every `spacing` points (Swift default 90).
    pub fn time_ticks(&self, spacing: f64) -> Vec<f64> {
        if self.lane.points_per_second() <= 0.0 {
            return Vec::new();
        }
        let step = Self::nice_step(spacing / self.lane.points_per_second());
        if step <= 0.0 {
            return Vec::new();
        }
        let start = (self.lane.view_start() / step).ceil() * step;
        Self::stride(start, step, self.lane.view_start() + self.lane.view_span())
    }

    /// Swift `stride(from:through:by:)` over doubles.
    fn stride(from: f64, by: f64, through: f64) -> Vec<f64> {
        let mut out = Vec::new();
        let mut i = 0.0f64;
        loop {
            let v = from + i * by;
            if v > through + by * 1e-9 {
                break;
            }
            out.push(v);
            i += 1.0;
            if out.len() > 100_000 {
                break;
            }
        }
        out
    }

    pub(crate) fn nice_step(raw: f64) -> f64 {
        if !(raw > 0.0 && raw.is_finite()) {
            return 0.0;
        }
        let mag = 10f64.powf(raw.log10().floor());
        let n = raw / mag;
        (if n <= 1.0 {
            1.0
        } else if n <= 2.0 {
            2.0
        } else if n <= 5.0 {
            5.0
        } else {
            10.0
        }) * mag
    }

    /// Priority: handles of selected keys, then keys (nearest wins), else empty.
    pub fn hit_test(&self, p: Point, selected: &BTreeSet<SummaryMember>) -> GraphEditorHit {
        let mut best: Option<(GraphEditorHit, f64)> = None;
        for c in &self.curves {
            for h in &c.curve.handles {
                if !selected.contains(&SummaryMember::new(c.property.clone(), h.key_id)) {
                    continue;
                }
                let Some(hp) = self.handle_point(c, h) else { continue };
                let d = (hp.x - p.x).hypot(hp.y - p.y);
                if d <= Self::HANDLE_HIT_RADIUS && d < best.as_ref().map_or(f64::INFINITY, |b| b.1) {
                    best = Some((GraphEditorHit::Handle(SummaryMember::new(c.property.clone(), h.key_id), h.side), d));
                }
            }
        }
        if let Some(b) = best {
            return b.0;
        }
        for c in &self.curves {
            for k in &c.curve.keys {
                let kp = self.key_point(c, k);
                let d = (kp.x - p.x).hypot(kp.y - p.y);
                if d <= Self::KEY_HIT_RADIUS && d < best.as_ref().map_or(f64::INFINITY, |b| b.1) {
                    best = Some((GraphEditorHit::Key(SummaryMember::new(c.property.clone(), k.id)), d));
                }
            }
        }
        best.map_or(GraphEditorHit::Empty, |b| b.0)
    }

    /// Every key drawn on the same spot as `m` (keys of several properties at one time and speed, e.g. two eased keys
    /// at 0): a click takes the whole stack.
    pub fn stack(&self, m: &SummaryMember) -> BTreeSet<SummaryMember> {
        let Some(c) = self.curve(&m.property) else { return BTreeSet::from([m.clone()]) };
        let Some(k) = c.curve.keys.iter().find(|k| k.id == m.key_id) else { return BTreeSet::from([m.clone()]) };
        let p = self.key_point(c, k);
        let mut out = BTreeSet::from([m.clone()]);
        for c in &self.curves {
            for k in &c.curve.keys {
                let q = self.key_point(c, k);
                if (q.x - p.x).abs() < 1.5 && (q.y - p.y).abs() < 1.5 {
                    out.insert(SummaryMember::new(c.property.clone(), k.id));
                }
            }
        }
        out
    }

    /// Keys whose marker lies inside `rect` (marquee), across all curves.
    pub fn members_in(&self, rect: Rect) -> BTreeSet<SummaryMember> {
        let mut out = BTreeSet::new();
        for c in &self.curves {
            for k in &c.curve.keys {
                if rect.contains(self.key_point(c, k)) {
                    out.insert(SummaryMember::new(c.property.clone(), k.id));
                }
            }
        }
        out
    }

    /// The handle a drag to `target` (view point) gives: influence from the horizontal distance to the key, relative
    /// speed (= slope) from the height. Influence is kept in 1...100 %.
    pub fn drag_handle(&self, m: &SummaryMember, side: KeySide, target: Point) -> Option<EaseHandle> {
        let c = self.curve(&m.property)?;
        let h = c.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == side)?;
        let k = c.curve.keys.iter().find(|k| k.id == m.key_id)?;
        let dir = if side == KeySide::Outgoing { 1.0 } else { -1.0 };
        let reach_pts = h.segment_seconds * GraphMath::HANDLE_REACH * self.lane.points_per_second();
        if reach_pts <= 0.0 {
            return None;
        }
        let influence = ((target.x - self.lane.x_seconds(k.seconds)) * dir / reach_pts).clamp(0.01, 1.0);
        let mut rel = self.speed_at_y(target.y).max(0.0);
        if (self.y(rel) - self.plot_bottom()).abs() <= 4.0 {
            rel = 0.0; // snaps to a full stop near the zero line
        }
        if Self::relative(h) < 0.0 {
            rel = -rel;
        }
        Some(EaseHandle { dx: influence, dy: rel * influence })
    }
}

/// Color slot per property: Position, Scale, Rotation, Opacity, Anchor, Volume, Shutter keep fixed slots; effect
/// parameters take the next slots in list order.
pub enum GraphEditorPalette {}

impl GraphEditorPalette {
    pub const COUNT: usize = 12;
    const FIXED_COUNT: usize = 7;

    pub fn slots(properties: &[EffectProperty]) -> Vec<usize> {
        let mut next = 0usize;
        properties
            .iter()
            .map(|p| {
                let fixed = match p {
                    EffectProperty::Position => Some(0),
                    EffectProperty::Scale => Some(1),
                    EffectProperty::Rotation => Some(2),
                    EffectProperty::Opacity => Some(3),
                    EffectProperty::Anchor => Some(4),
                    EffectProperty::Volume => Some(5),
                    EffectProperty::ShutterAngle => Some(6),
                    _ => None,
                };
                if let Some(f) = fixed {
                    return f;
                }
                let slot = Self::FIXED_COUNT + next % (Self::COUNT - Self::FIXED_COUNT);
                next += 1;
                slot
            })
            .collect()
    }
}

/// One mouse gesture in the Graph Editor (down, drag..., up). Pure: the view feeds it points and turns the results
/// into model calls (key moves and handle edits act on the whole selection, as After Effects).
#[derive(Clone, Debug, PartialEq)]
pub struct GraphEditorGesture {
    pub kind: GraphEditorGestureKind,
    pub origin: Point,
    pub geometry: GraphEditorGeometry,
    pub base_selection: BTreeSet<SummaryMember>,
    /// Selection right after mouse-down (what a key drag moves).
    selection: BTreeSet<SummaryMember>,
    moved: bool,
    collapse_to: Option<BTreeSet<SummaryMember>>,
    handle_axis: Option<GraphGestureAxis>,
    grab: Point,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GraphGestureAxis {
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphEditorGestureKind {
    Keys,
    Handle(SummaryMember, KeySide),
    Marquee { additive: bool },
    None,
}

#[derive(Clone, Debug, PartialEq)]
pub enum GraphEditorAction {
    /// Move the selected keys by this many seconds from where they were at mouse-down.
    MoveKeys {
        seconds: f64,
    },
    /// Give every selected key this handle on `side`.
    SetHandle(EaseHandle, KeySide),
    Select {
        members: BTreeSet<SummaryMember>,
        marquee: Option<Rect>,
    },
    Nothing,
}

impl GraphEditorGesture {
    /// Keys and marquee start after this distance; handles follow the pointer from the first pixel.
    pub const DRAG_THRESHOLD: f64 = 3.0;

    pub fn new(
        p: Point,
        shift: bool,
        geometry: GraphEditorGeometry,
        selection: BTreeSet<SummaryMember>,
    ) -> GraphEditorGesture {
        let mut grab = p;
        let mut sel = selection.clone();
        let mut collapse_to = None;
        let kind;
        match geometry.hit_test(p, &selection) {
            GraphEditorHit::Handle(m, side) => {
                kind = GraphEditorGestureKind::Handle(m.clone(), side);
                if let Some(c) = geometry.curve(&m.property)
                    && let Some(h) = c.curve.handles.iter().find(|h| h.key_id == m.key_id && h.side == side)
                    && let Some(tp) = geometry.handle_point(c, h)
                {
                    grab = tp;
                }
            }
            GraphEditorHit::Key(m) => {
                let stack = geometry.stack(&m);
                if shift {
                    if selection.contains(&m) {
                        for s in &stack {
                            sel.remove(s);
                        }
                        kind = GraphEditorGestureKind::None;
                    } else {
                        sel.extend(stack);
                        kind = GraphEditorGestureKind::Keys;
                    }
                } else {
                    if selection.contains(&m) {
                        collapse_to = Some(stack);
                    } else {
                        sel = stack;
                    }
                    kind = GraphEditorGestureKind::Keys;
                }
            }
            GraphEditorHit::Empty => {
                if !shift {
                    sel = BTreeSet::new();
                }
                kind = GraphEditorGestureKind::Marquee { additive: shift };
            }
        }
        GraphEditorGesture {
            kind,
            origin: p,
            geometry,
            base_selection: selection,
            selection: sel,
            moved: false,
            collapse_to,
            handle_axis: None,
            grab,
        }
    }

    pub fn selection(&self) -> &BTreeSet<SummaryMember> {
        &self.selection
    }

    pub fn moved(&self) -> bool {
        self.moved
    }

    /// `constrain`: Shift held, a handle drag keeps to the axis it started along.
    pub fn drag(&mut self, p: Point, constrain: bool) -> GraphEditorAction {
        if !self.moved {
            let is_handle = matches!(self.kind, GraphEditorGestureKind::Handle(..));
            let started = if is_handle {
                p != self.origin
            } else {
                (p.x - self.origin.x).hypot(p.y - self.origin.y) >= Self::DRAG_THRESHOLD
            };
            if !started {
                return GraphEditorAction::Nothing;
            }
            self.moved = true;
        }
        match self.kind.clone() {
            GraphEditorGestureKind::Keys => GraphEditorAction::MoveKeys {
                seconds: (p.x - self.origin.x) / self.geometry.lane.points_per_second().max(1e-9),
            },
            GraphEditorGestureKind::Handle(m, side) => {
                let mut dx = p.x - self.origin.x;
                let mut dy = p.y - self.origin.y;
                if constrain {
                    if self.handle_axis.is_none() {
                        self.handle_axis = Some(if dx.abs() >= dy.abs() {
                            GraphGestureAxis::Horizontal
                        } else {
                            GraphGestureAxis::Vertical
                        });
                    }
                    if self.handle_axis == Some(GraphGestureAxis::Horizontal) {
                        dy = 0.0;
                    } else {
                        dx = 0.0;
                    }
                }
                // The handle follows the pointer 1:1 from where it is drawn (no jump under the pointer).
                match self.geometry.drag_handle(&m, side, Point::new(self.grab.x + dx, self.grab.y + dy)) {
                    Some(h) => GraphEditorAction::SetHandle(h, side),
                    None => GraphEditorAction::Nothing,
                }
            }
            GraphEditorGestureKind::Marquee { additive } => {
                let rect = Rect::new(
                    self.origin.x.min(p.x),
                    self.origin.y.min(p.y),
                    (p.x - self.origin.x).abs(),
                    (p.y - self.origin.y).abs(),
                );
                let hit = self.geometry.members_in(rect);
                self.selection = if additive { self.base_selection.union(&hit).cloned().collect() } else { hit };
                GraphEditorAction::Select { members: self.selection.clone(), marquee: Some(rect) }
            }
            GraphEditorGestureKind::None => GraphEditorAction::Nothing,
        }
    }

    /// Selection after mouse-up: a plain click on an already-selected key collapses the selection to it (its stack).
    pub fn end_selection(&self) -> BTreeSet<SummaryMember> {
        if !self.moved
            && let Some(m) = &self.collapse_to
        {
            return m.clone();
        }
        self.selection.clone()
    }
}
