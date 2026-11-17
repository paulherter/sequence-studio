// Swift: KeyframeGraphGeometry.swift
//! Value graph and speed graph geometry: data space to view space, hit testing and the grid.

use sq_core_model::keyframes_graph::{EaseHandleSpeed, KeyframeGraph};
use sq_core_time::{Id, Keyframe, KeyframeTrack, Time};
use std::collections::BTreeSet;
use std::ops::RangeInclusive;

/// A point in view space (CGFloat is `f64`).
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A size in view space.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A rectangle in view space, origin top-left, y down.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Point {
    pub const ZERO: Point = Point { x: 0.0, y: 0.0 };

    pub const fn new(x: f64, y: f64) -> Point {
        Point { x, y }
    }
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Size {
        Size { width, height }
    }
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect { x, y, width, height }
    }

    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    /// Shrinks the rect by `dx` / `dy` on every side (negative grows it).
    pub fn inset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width - 2.0 * dx, self.height - 2.0 * dy)
    }

    /// True when `r` lies fully inside this rect (edges may touch).
    pub fn contains_rect(&self, r: &Rect) -> bool {
        self.min_x() <= r.min_x() && r.max_x() <= self.max_x() && self.min_y() <= r.min_y() && r.max_y() <= self.max_y()
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }

    /// Like `CGRect.contains(point)`: the max edges are outside.
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.min_x() && p.x < self.max_x() && p.y >= self.min_y() && p.y < self.max_y()
    }
}

/// Value graph (property value over time) or speed graph (dv/dt over time, AE style).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphMode {
    Value,
    Speed,
}

/// Which handle of a key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphHandleSide {
    InSide,
    OutSide,
}

/// What a point of the graph hits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GraphHit {
    Key(Id),
    Handle(Id, GraphHandleSide),
    /// Point on the curve between two keys.
    Segment {
        from: Id,
        to: Id,
    },
    Empty,
}

/// Space around the plot.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GraphInsets {
    pub top: f64,
    pub left: f64,
    pub bottom: f64,
    pub right: f64,
}

impl Default for GraphInsets {
    fn default() -> Self {
        GraphInsets { top: 12.0, left: 40.0, bottom: 12.0, right: 16.0 }
    }
}

/// `Array.min()`: the first element that no later one undercuts with `<`.
fn min_of(ys: &[f64]) -> Option<f64> {
    ys.iter().copied().reduce(|m, x| if x < m { x } else { m })
}

/// `Array.max()`.
fn max_of(ys: &[f64]) -> Option<f64> {
    ys.iter().copied().reduce(|m, x| if x > m { x } else { m })
}

/// Visible data ranges. Computed once (auto-fit) and frozen while a gesture runs, so the graph does not
/// rescale under the pointer.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphFit {
    /// Seconds (clip-local).
    pub time: RangeInclusive<f64>,
    pub value: RangeInclusive<f64>,
}

impl GraphFit {
    /// Covers keys, sampled curve (so overshoot is visible) and all handle points, plus headroom.
    /// `time_range` (clip-local seconds, normally the clip's 0...duration) is always included, so the graph lines up
    /// with the keyframe lanes and has no empty band; keys outside it widen the range.
    /// `visible_time` (the keyframe area's zoom window) overrides the time range, so the graph shows exactly the span
    /// the lanes and ruler show; the value range still covers the whole curve.
    pub fn make(
        track: &KeyframeTrack<f64>,
        mode: GraphMode,
        headroom: f64,
        time_range: Option<RangeInclusive<f64>>,
        visible_time: Option<RangeInclusive<f64>>,
    ) -> GraphFit {
        let keys = &track.keys;
        let mut t0 = keys.first().map_or(0.0, |k| GraphMath::seconds(k.time));
        let mut t1 = keys.last().map_or(1.0, |k| GraphMath::seconds(k.time));
        if let Some(r) = time_range {
            t0 = if keys.is_empty() { *r.start() } else { t0.min(*r.start()) };
            t1 = if keys.is_empty() { *r.end() } else { t1.max(*r.end()) };
        }
        if t1 - t0 < 1e-6 {
            t0 -= 0.5;
            t1 += 0.5;
        }

        let mut ys: Vec<f64> = Vec::new();
        match mode {
            GraphMode::Value => {
                ys.extend(keys.iter().map(|k| k.value));
                for seg in track.value_graph(32) {
                    ys.extend(seg.samples.iter().map(|s| s.value));
                }
            }
            GraphMode::Speed => {
                ys.push(0.0);
                for seg in track.speed_graph(32) {
                    ys.extend(seg.samples.iter().map(|s| s.speed));
                }
            }
        }
        for k in keys {
            for side in [GraphHandleSide::InSide, GraphHandleSide::OutSide] {
                if let Some(p) = GraphMath::handle_point(track, k.id, side, mode) {
                    ys.push(p.value);
                }
            }
        }
        let mut lo = min_of(&ys).unwrap_or(0.0);
        let mut hi = max_of(&ys).unwrap_or(1.0);
        if hi - lo < 1e-9 {
            lo -= 1.0;
            hi += 1.0;
        }
        let pad = (hi - lo) * headroom;
        let mut time = t0..=t1;
        if let Some(v) = visible_time.filter(|v| *v.end() - *v.start() > 1e-9) {
            time = v;
        }
        GraphFit { time, value: (lo - pad)..=(hi + pad) }
    }

    /// `make` with the standard headroom (0.12) and no forced time range.
    pub fn auto(track: &KeyframeTrack<f64>, mode: GraphMode) -> GraphFit {
        Self::make(track, mode, 0.12, None, None)
    }
}

/// A point in graph data space: seconds and value (or speed).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GraphDataPoint {
    pub seconds: f64,
    pub value: f64,
}

/// How far an ease handle is drawn: influence 1.0 (100 %, the strongest ease) sits at this share of its segment, the
/// middle. So the two handles of a segment meet there at most; a handle never crosses the other one or touches the
/// neighboring key. UI mapping only: the stored `EaseHandle.dx` (0.001...1) and the core evaluation are unchanged.
/// Used by every graph (value graph, inline speed graph, Graph Editor, transition curve) so the rule cannot drift apart.
pub struct HandleReach;

impl HandleReach {
    pub const FULL_INFLUENCE: f64 = 0.5;
}

/// One segment of a track: left key, right key, duration, signed value delta.
pub struct GraphSegment<'a> {
    pub a: &'a Keyframe<f64>,
    pub b: &'a Keyframe<f64>,
    pub dur: Time,
    pub delta: f64,
}

/// Shared pure helpers (data space).
pub struct GraphMath;

impl GraphMath {
    /// See `HandleReach::FULL_INFLUENCE`.
    pub const HANDLE_REACH: f64 = HandleReach::FULL_INFLUENCE;

    pub fn seconds(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    /// Segment starting at `index`: left key, right key, duration, signed value delta.
    pub fn segment(track: &KeyframeTrack<f64>, from: isize) -> Option<GraphSegment<'_>> {
        let i = usize::try_from(from).ok()?;
        if i + 1 >= track.keys.len() {
            return None;
        }
        let (a, b) = (&track.keys[i], &track.keys[i + 1]);
        Some(GraphSegment { a, b, dur: b.time - a.time, delta: b.value - a.value })
    }

    /// Y of a key glyph in the speed graph: outgoing speed, or arriving speed for the last key.
    pub fn key_speed(track: &KeyframeTrack<f64>, index: usize) -> f64 {
        if let Some(s) = Self::segment(track, index as isize) {
            if s.a.interpolation.is_hold() {
                return 0.0;
            }
            return s.a.out_handle.speed_handle(s.delta, s.dur).speed;
        }
        if let Some(s) = index.checked_sub(1).and_then(|i| Self::segment(track, i as isize)) {
            if s.a.interpolation.is_hold() {
                return 0.0;
            }
            return s.b.in_handle.speed_handle(s.delta, s.dur).speed;
        }
        0.0
    }

    pub fn key_point(track: &KeyframeTrack<f64>, index: usize, mode: GraphMode) -> GraphDataPoint {
        let k = &track.keys[index];
        GraphDataPoint {
            seconds: Self::seconds(k.time),
            value: if mode == GraphMode::Value { k.value } else { Self::key_speed(track, index) },
        }
    }

    /// Data-space handle position; `None` when the handle does not exist (no neighbor, or the segment is hold).
    pub fn handle_point(
        track: &KeyframeTrack<f64>,
        key_id: Id,
        side: GraphHandleSide,
        mode: GraphMode,
    ) -> Option<GraphDataPoint> {
        let i = track.keys.iter().position(|k| k.id == key_id)?;
        let k = &track.keys[i];
        match side {
            GraphHandleSide::OutSide => {
                let s = Self::segment(track, i as isize).filter(|s| !s.a.interpolation.is_hold())?;
                let t = Self::seconds(k.time) + s.a.out_handle.dx * Self::HANDLE_REACH * Self::seconds(s.dur);
                let v = if mode == GraphMode::Value {
                    k.value + s.a.out_handle.dy * Self::HANDLE_REACH * s.delta
                } else {
                    s.a.out_handle.speed_handle(s.delta, s.dur).speed
                };
                Some(GraphDataPoint { seconds: t, value: v })
            }
            GraphHandleSide::InSide => {
                let s = Self::segment(track, i as isize - 1).filter(|s| !s.a.interpolation.is_hold())?;
                let t = Self::seconds(k.time) - s.b.in_handle.dx * Self::HANDLE_REACH * Self::seconds(s.dur);
                let v = if mode == GraphMode::Value {
                    k.value - s.b.in_handle.dy * Self::HANDLE_REACH * s.delta
                } else {
                    s.b.in_handle.speed_handle(s.delta, s.dur).speed
                };
                Some(GraphDataPoint { seconds: t, value: v })
            }
        }
    }
}

/// The curve of one segment in view coordinates.
#[derive(Clone, Debug, PartialEq)]
pub struct CurvePolyline {
    pub from: Id,
    pub to: Id,
    pub points: Vec<Point>,
}

/// Maps graph data (seconds, value/speed) to view points (origin top-left, y down) and hit-tests.
/// Pure: no UI toolkit.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyframeGraphGeometry {
    pub size: Size,
    pub insets: GraphInsets,
    pub fit: GraphFit,
    pub mode: GraphMode,
}

impl KeyframeGraphGeometry {
    pub const KEY_HIT_RADIUS: f64 = 8.0;
    /// Hit target radius of a handle knob (24 pt wide).
    pub const HANDLE_HIT_RADIUS: f64 = 12.0;
    /// A handle is drawn at least this far (points) from its key, whatever the zoom, so it can always be seen and grabbed.
    pub const MIN_HANDLE_LENGTH: f64 = 24.0;
    pub const HANDLE_KNOB_DIAMETER: f64 = 7.0;
    pub const HANDLE_LINE_WIDTH: f64 = 1.5;
    pub const SEGMENT_HIT_DISTANCE: f64 = 5.0;
    pub const CURVE_SAMPLES: usize = 48;

    /// A geometry with the default insets.
    pub fn new(size: Size, fit: GraphFit, mode: GraphMode) -> Self {
        KeyframeGraphGeometry { size, insets: GraphInsets::default(), fit, mode }
    }

    pub fn plot(&self) -> Rect {
        Rect {
            x: self.insets.left,
            y: self.insets.top,
            width: (self.size.width - self.insets.left - self.insets.right).max(1.0),
            height: (self.size.height - self.insets.top - self.insets.bottom).max(1.0),
        }
    }

    pub fn points_per_second(&self) -> f64 {
        self.plot().width / (self.fit.time.end() - self.fit.time.start())
    }

    fn value_span(&self) -> f64 {
        self.fit.value.end() - self.fit.value.start()
    }

    pub fn points_per_value(&self) -> f64 {
        self.plot().height / self.value_span()
    }

    // MARK: Mapping

    pub fn x(&self, seconds: f64) -> f64 {
        self.plot().min_x() + (seconds - self.fit.time.start()) * self.points_per_second()
    }

    pub fn seconds_at_x(&self, x: f64) -> f64 {
        self.fit.time.start() + (x - self.plot().min_x()) / self.points_per_second()
    }

    pub fn y(&self, value: f64) -> f64 {
        self.plot().max_y() - (value - self.fit.value.start()) * self.points_per_value()
    }

    pub fn value_at_y(&self, y: f64) -> f64 {
        self.fit.value.start() + (self.plot().max_y() - y) / self.points_per_value()
    }

    pub fn point(&self, p: GraphDataPoint) -> Point {
        Point { x: self.x(p.seconds), y: self.y(p.value) }
    }

    pub fn data(&self, p: Point) -> GraphDataPoint {
        GraphDataPoint { seconds: self.seconds_at_x(p.x), value: self.value_at_y(p.y) }
    }

    // MARK: Layout of graph elements

    pub fn key_point(&self, track: &KeyframeTrack<f64>, index: usize) -> Point {
        self.point(GraphMath::key_point(track, index, self.mode))
    }

    /// Where the handle really is (its influence), without the minimum drawn length. Drags start from here.
    pub fn handle_true_point(&self, track: &KeyframeTrack<f64>, key_id: Id, side: GraphHandleSide) -> Option<Point> {
        GraphMath::handle_point(track, key_id, side, self.mode).map(|p| self.point(p))
    }

    /// Where the handle is drawn and hit-tested: the true point, pushed out to at least `MIN_HANDLE_LENGTH` from its key.
    pub fn handle_point(&self, track: &KeyframeTrack<f64>, key_id: Id, side: GraphHandleSide) -> Option<Point> {
        let p = self.handle_true_point(track, key_id, side)?;
        let i = track.keys.iter().position(|k| k.id == key_id)?;
        let kx = self.key_point(track, i).x;
        let dir = if side == GraphHandleSide::OutSide { 1.0 } else { -1.0 };
        let len = (p.x - kx) * dir;
        // Zoomed far out the segment is only a few points wide: the minimum shrinks with it (at most 40 % of the
        // distance to the neighboring key), so the two handles of a segment keep their share and never overlap.
        let neighbour = if side == GraphHandleSide::OutSide { i as isize + 1 } else { i as isize - 1 };
        let mut min_len = Self::MIN_HANDLE_LENGTH;
        if neighbour >= 0 && (neighbour as usize) < track.keys.len() {
            min_len = min_len.min((self.key_point(track, neighbour as usize).x - kx).abs() * 0.4);
        }
        Some(if len >= min_len { p } else { Point { x: kx + dir * min_len, y: p.y } })
    }

    /// One polyline per segment, in view coordinates.
    pub fn curve_polylines(&self, track: &KeyframeTrack<f64>) -> Vec<CurvePolyline> {
        let n = Self::CURVE_SAMPLES;
        match self.mode {
            GraphMode::Value => track
                .value_graph(n)
                .into_iter()
                .map(|seg| CurvePolyline {
                    from: seg.from_id,
                    to: seg.to_id,
                    points: seg
                        .samples
                        .iter()
                        .map(|s| self.point(GraphDataPoint { seconds: s.time, value: s.value }))
                        .collect(),
                })
                .collect(),
            GraphMode::Speed => track
                .speed_graph(n)
                .into_iter()
                .map(|seg| CurvePolyline {
                    from: seg.from_id,
                    to: seg.to_id,
                    points: seg
                        .samples
                        .iter()
                        .map(|s| self.point(GraphDataPoint { seconds: s.time, value: s.speed }))
                        .collect(),
                })
                .collect(),
        }
    }

    // MARK: Hit testing

    /// Priority: handles of selected keys, keys, curve segments, empty.
    pub fn hit_test(&self, p: Point, track: &KeyframeTrack<f64>, selected: &BTreeSet<Id>) -> GraphHit {
        let mut best_handle: Option<(GraphHit, f64)> = None;
        for k in track.keys.iter().filter(|k| selected.contains(&k.id)) {
            for side in [GraphHandleSide::OutSide, GraphHandleSide::InSide] {
                let Some(hp) = self.handle_point(track, k.id, side) else { continue };
                let d = (hp.x - p.x).hypot(hp.y - p.y);
                if d <= Self::HANDLE_HIT_RADIUS && d < best_handle.map_or(f64::INFINITY, |b| b.1) {
                    best_handle = Some((GraphHit::Handle(k.id, side), d));
                }
            }
        }
        if let Some(h) = best_handle {
            return h.0;
        }

        let mut best_key: Option<(Id, f64)> = None;
        for i in 0..track.keys.len() {
            let kp = self.key_point(track, i);
            let d = (kp.x - p.x).hypot(kp.y - p.y);
            if d <= Self::KEY_HIT_RADIUS && d <= best_key.map_or(f64::INFINITY, |b| b.1) {
                best_key = Some((track.keys[i].id, d));
            }
        }
        if let Some(k) = best_key {
            return GraphHit::Key(k.0);
        }

        for seg in self.curve_polylines(track) {
            let mut best = f64::INFINITY;
            for w in seg.points.windows(2) {
                best = best.min(Self::distance(p, w[0], w[1]));
            }
            if best <= Self::SEGMENT_HIT_DISTANCE {
                return GraphHit::Segment { from: seg.from, to: seg.to };
            }
        }
        GraphHit::Empty
    }

    /// Keys whose glyph center, or whose drawn handle (handles show on `selected` keys only), lies inside `rect` (marquee).
    pub fn keys_in(&self, rect: Rect, track: &KeyframeTrack<f64>, selected: &BTreeSet<Id>) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for i in 0..track.keys.len() {
            if rect.contains(self.key_point(track, i)) {
                out.insert(track.keys[i].id);
            }
        }
        for k in track.keys.iter().filter(|k| selected.contains(&k.id)) {
            for side in [GraphHandleSide::InSide, GraphHandleSide::OutSide] {
                if let Some(h) = self.handle_point(track, k.id, side)
                    && rect.contains(h)
                {
                    out.insert(k.id);
                }
            }
        }
        out
    }

    /// Distance of `p` to the segment `a`-`b`.
    pub fn distance(p: Point, a: Point, b: Point) -> f64 {
        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let l2 = dx * dx + dy * dy;
        if l2 <= 0.0 {
            return (p.x - a.x).hypot(p.y - a.y);
        }
        let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2).clamp(0.0, 1.0);
        (p.x - (a.x + t * dx)).hypot(p.y - (a.y + t * dy))
    }

    // MARK: Grid

    /// "Nice" (1/2/5 x 10^n) horizontal grid values inside the visible value range.
    pub fn grid_values(&self, target_count: usize) -> Vec<f64> {
        let span = self.value_span();
        if span.is_nan() || span <= 0.0 || target_count == 0 {
            return vec![];
        }
        let raw = span / target_count as f64;
        let mag = 10f64.powf(raw.log10().floor());
        let norm = raw / mag;
        let step = (if norm < 1.5 {
            1.0
        } else if norm < 3.5 {
            2.0
        } else if norm < 7.5 {
            5.0
        } else {
            10.0
        }) * mag;
        let mut v = (self.fit.value.start() / step).ceil() * step;
        let mut out = Vec::new();
        while v <= self.fit.value.end() + step * 1e-9 && out.len() < 100 {
            out.push(if v.abs() < step * 1e-9 { 0.0 } else { v });
            v += step;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{EaseHandle, Interpolation};

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }
    const A: u128 = 1;
    const B: u128 = 2;
    const C: u128 = 3;

    fn key(i: u128, sec: i64, v: f64, interp: Interpolation, out: EaseHandle, inn: EaseHandle) -> Keyframe<f64> {
        Keyframe {
            interpolation: interp,
            in_handle: inn,
            out_handle: out,
            ..Keyframe::new(id(i), Time::new(sec, 1), v)
        }
    }

    fn lin(i: u128, sec: i64, v: f64) -> Keyframe<f64> {
        key(i, sec, v, Interpolation::Linear, EaseHandle::LINEAR, EaseHandle::LINEAR)
    }

    /// 0s -> 0, 2s -> 100, 4s -> 50, all linear.
    fn track3() -> KeyframeTrack<f64> {
        KeyframeTrack { keys: vec![lin(A, 0, 0.0), lin(B, 2, 100.0), lin(C, 4, 50.0)] }
    }

    fn geo(t: &KeyframeTrack<f64>, mode: GraphMode) -> KeyframeGraphGeometry {
        KeyframeGraphGeometry::new(Size { width: 440.0, height: 212.0 }, GraphFit::auto(t, mode), mode)
    }

    fn none() -> BTreeSet<Id> {
        BTreeSet::new()
    }

    #[test]
    fn mapping_round_trips() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        for s in [0.0, 1.3, 4.0] {
            assert!((g.seconds_at_x(g.x(s)) - s).abs() < 1e-9);
        }
        for v in [-5.0, 0.0, 50.0, 100.0] {
            assert!((g.value_at_y(g.y(v)) - v).abs() < 1e-9);
        }
        // y grows downward: higher value = smaller y
        assert!(g.y(100.0) < g.y(0.0));
    }

    #[test]
    fn auto_fit_covers_keys_with_padding_and_insets() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        assert_eq!(g.fit.time, 0.0..=4.0);
        assert!(*g.fit.value.start() < 0.0 && *g.fit.value.end() > 100.0);
        assert!((g.x(0.0) - g.plot().min_x()).abs() < 1e-9);
        assert!((g.x(4.0) - g.plot().max_x()).abs() < 1e-9);
        assert!(g.y(100.0) > g.plot().min_y()); // headroom: top key not glued to the edge
    }

    #[test]
    fn auto_fit_includes_overshoot_and_flat_tracks() {
        let mut t = KeyframeTrack {
            keys: vec![
                key(A, 0, 0.0, Interpolation::Linear, EaseHandle { dx: 0.3, dy: 6.0 }, EaseHandle::LINEAR),
                lin(B, 1, 10.0),
            ],
        };
        let handle = GraphMath::handle_point(&t, id(A), GraphHandleSide::OutSide, GraphMode::Value)
            .map_or(f64::NAN, |p| p.value); // 6 x 10 x reach = 20
        assert!(handle > 15.0 && *GraphFit::auto(&t, GraphMode::Value).value.end() > handle);
        t = KeyframeTrack { keys: vec![lin(A, 0, 5.0)] };
        let f = GraphFit::auto(&t, GraphMode::Value);
        assert!(*f.value.start() < 5.0 && *f.value.end() > 5.0);
        assert!(f.time.end() > f.time.start());
    }

    #[test]
    fn speed_fit_includes_zero() {
        let f = GraphFit::auto(&track3(), GraphMode::Speed);
        assert!(*f.value.start() < 0.0 && *f.value.end() > 50.0); // +50/s then -25/s
    }

    #[test]
    fn hit_test_priority() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let kb = g.key_point(&t, 1);
        assert_eq!(g.hit_test(kb, &t, &none()), GraphHit::Key(id(B)));
        assert_eq!(g.hit_test(Point { x: kb.x + 3.0, y: kb.y + 3.0 }, &t, &none()), GraphHit::Key(id(B)));
        // middle of segment A-B
        let mid = g.point(GraphDataPoint { seconds: 1.0, value: 50.0 });
        assert_eq!(g.hit_test(mid, &t, &none()), GraphHit::Segment { from: id(A), to: id(B) });
        assert_eq!(g.hit_test(Point { x: mid.x, y: mid.y - 40.0 }, &t, &none()), GraphHit::Empty);
    }

    #[test]
    fn handles_only_on_selected_keys_and_only_where_they_exist() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        assert!(g.handle_point(&t, id(B), GraphHandleSide::OutSide).is_some());
        assert!(g.handle_point(&t, id(A), GraphHandleSide::InSide).is_none()); // first key: no in-handle
        assert!(g.handle_point(&t, id(C), GraphHandleSide::OutSide).is_none()); // last key: no out-handle
        let hp = g.handle_point(&t, id(B), GraphHandleSide::OutSide).unwrap_or_default();
        let sel: BTreeSet<Id> = [id(B)].into();
        assert_eq!(g.hit_test(hp, &t, &sel), GraphHit::Handle(id(B), GraphHandleSide::OutSide));
        assert_ne!(g.hit_test(hp, &t, &none()), GraphHit::Handle(id(B), GraphHandleSide::OutSide));
    }

    #[test]
    fn hold_segment_has_no_handles() {
        let t = KeyframeTrack {
            keys: vec![key(A, 0, 0.0, Interpolation::Hold, EaseHandle::LINEAR, EaseHandle::LINEAR), lin(B, 2, 100.0)],
        };
        let g = geo(&t, GraphMode::Value);
        assert!(g.handle_point(&t, id(A), GraphHandleSide::OutSide).is_none());
        assert!(g.handle_point(&t, id(B), GraphHandleSide::InSide).is_none());
    }

    #[test]
    fn value_handle_position_matches_bezier_control_points() {
        let t = KeyframeTrack {
            keys: vec![
                key(A, 0, 0.0, Interpolation::Linear, EaseHandle { dx: 0.25, dy: 0.5 }, EaseHandle::LINEAR),
                key(B, 2, 100.0, Interpolation::Linear, EaseHandle::LINEAR, EaseHandle { dx: 0.5, dy: 0.2 }),
            ],
        };
        // The drawn handle is the Bezier control point scaled by the reach (1/3): same tangent, shorter arm.
        let r = GraphMath::HANDLE_REACH;
        let out = GraphMath::handle_point(&t, id(A), GraphHandleSide::OutSide, GraphMode::Value)
            .unwrap_or(GraphDataPoint { seconds: f64::NAN, value: f64::NAN });
        assert!((out.seconds - 0.25 * 2.0 * r).abs() < 1e-9 && (out.value - 50.0 * r).abs() < 1e-9);
        let inn = GraphMath::handle_point(&t, id(B), GraphHandleSide::InSide, GraphMode::Value)
            .unwrap_or(GraphDataPoint { seconds: f64::NAN, value: f64::NAN });
        assert!((inn.seconds - (2.0 - 0.5 * 2.0 * r)).abs() < 1e-9 && (inn.value - (100.0 - 20.0 * r)).abs() < 1e-9);
    }

    #[test]
    fn speed_handle_matches_core_conversion() {
        let h = EaseHandle { dx: 0.25, dy: 0.5 };
        let t = KeyframeTrack {
            keys: vec![key(A, 0, 0.0, Interpolation::Linear, h, EaseHandle::LINEAR), lin(B, 2, 100.0)],
        };
        let p = GraphMath::handle_point(&t, id(A), GraphHandleSide::OutSide, GraphMode::Speed)
            .unwrap_or(GraphDataPoint { seconds: f64::NAN, value: f64::NAN });
        let s = h.speed_handle(100.0, Time::new(2, 1));
        assert!((p.value - s.speed).abs() < 1e-9 && (p.seconds - 0.25 * 2.0 * GraphMath::HANDLE_REACH).abs() < 1e-9);
    }

    #[test]
    fn marquee_selects_keys_inside_rect() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let a = g.key_point(&t, 0);
        let b = g.key_point(&t, 1);
        let r =
            Rect { x: a.x - 10.0, y: a.y.min(b.y) - 10.0, width: (b.x - a.x) + 20.0, height: (a.y - b.y).abs() + 20.0 };
        let expect: BTreeSet<Id> = [id(A), id(B)].into();
        assert_eq!(g.keys_in(r, &t, &none()), expect);
    }

    #[test]
    fn nice_grid() {
        let g = KeyframeGraphGeometry::new(
            Size { width: 440.0, height: 212.0 },
            GraphFit { time: 0.0..=1.0, value: -3.0..=103.0 },
            GraphMode::Value,
        );
        let v = g.grid_values(5);
        assert!(v.contains(&0.0) && v.contains(&100.0));
        assert!(v.iter().all(|x| *x >= -3.0 && *x <= 103.0));
    }
}
