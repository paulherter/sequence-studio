// Swift: SpeedGraphGeometry.swift
//! Pure geometry of the inline speed graph.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_model::keyframes_speed_hill::{EaseTrackSegment, SpeedHill};
use sq_core_time::{EaseSide, Id};
use sq_uikit::keyframe_graph_geometry::{HandleReach, KeyframeGraphGeometry, Point, Rect};

use crate::ec::effect_controls_model::lane_geometry::KeyframeLaneGeometry;

/// What a press in the inline speed graph grabs (row = index into the drawn rows).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedGraphHit {
    Handle { row: usize, segment: usize, side: EaseSide },
    Key { row: usize, id: Id },
    Curve { row: usize, segment: usize },
    Empty,
}

/// A key diamond of a drawn row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedGraphKeyPoint {
    pub id: Id,
    pub point: Point,
}

/// A handle drawn for a row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeedGraphHandleRef {
    pub segment: usize,
    pub side: EaseSide,
}

/// Pure geometry of the inline speed graph (build.py `egraph`): time across (the same x mapping as the keyframe lanes),
/// speed up. Speed 0 is the baseline 22 pt above the bottom edge, 1.0x (Steady) sits 40 pt above it. A key sits at its
/// own speed; its handle is horizontal and as long as its Reach (a share of the segment).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedGraphGeometry {
    pub lane: KeyframeLaneGeometry,
    pub height: f64,
    /// Highest speed that has to fit (the unit height shrinks for a hill taller than the plot).
    pub peak: f64,
    /// Lowest speed that has to fit, 0 or negative (a key speed below 0: wind-up, overshoot). The baseline moves up to
    /// make room for it. 0 in the keyframe rows; the curve editor (`EaseSpeedEditorView`) sets it.
    pub low: f64,
}

impl SpeedGraphGeometry {
    pub const BASELINE_INSET: f64 = 22.0;
    pub const UNIT: f64 = 40.0;
    pub const TOP_INSET: f64 = 10.0;

    /// Height of the opened row (`ControlsMetrics.graph`).
    pub const DEFAULT_HEIGHT: f64 = 120.0;

    /// The plot scales down to fit a hill of at most this many times the steady speed. A taller one (two long handles
    /// make a sharp peak, a cusp when both are at 100 %) runs off the top and is clipped there, as in Premiere, so the
    /// Steady line and the rest of the hill stay readable instead of being squashed flat.
    pub const PEAK_CAP: f64 = 4.0;

    /// A handle is drawn at least this far from its key (shrinking with very narrow segments), so it can be seen and
    /// grabbed even at a tiny influence. Drags keep the grab offset, so the drawn minimum never makes a handle jump.
    pub const MIN_HANDLE_LENGTH: f64 = 12.0;
    pub(crate) const KEY_HIT_RADIUS: f64 = 6.0;
    pub(crate) const HANDLE_HIT_RADIUS: f64 = 7.0;
    pub(crate) const CURVE_HIT_DISTANCE: f64 = 4.0;

    /// Swift `init(lane:height:peak:)` with the default height 120 and peak 1.
    pub fn new(lane: KeyframeLaneGeometry) -> SpeedGraphGeometry {
        SpeedGraphGeometry { lane, height: Self::DEFAULT_HEIGHT, peak: 1.0, low: 0.0 }
    }

    pub fn with(lane: KeyframeLaneGeometry, height: f64, peak: f64) -> SpeedGraphGeometry {
        SpeedGraphGeometry { lane, height, peak, low: 0.0 }
    }

    /// Speeds below 0 the plot makes room for (0...`PEAK_CAP`).
    fn depth(&self) -> f64 {
        (-self.low).clamp(0.0, Self::PEAK_CAP)
    }

    /// y of speed 0.
    pub fn baseline(&self) -> f64 {
        self.height - Self::BASELINE_INSET - self.depth() * self.unit_height()
    }

    /// Points per 1.0x of speed.
    pub fn unit_height(&self) -> f64 {
        Self::UNIT.min(
            (self.height - Self::BASELINE_INSET - Self::TOP_INSET)
                / (self.peak.clamp(1.0, Self::PEAK_CAP) + self.depth()),
        )
    }

    /// The speed a point at `y` stands for (not clamped: a drag may leave the row).
    pub fn speed_at_y(&self, y: f64) -> f64 {
        if self.unit_height() > 0.0 { (self.baseline() - y) / self.unit_height() } else { 0.0 }
    }

    /// y of a key or handle at `speed`: kept inside the row, so it can always be seen and grabbed.
    pub fn y(&self, speed: f64) -> f64 {
        (self.baseline() - speed * self.unit_height()).max(2.0).min(self.height - 2.0)
    }

    /// y of a curve point at `speed`: not kept inside the row (the view clips), so a peak taller than the plot keeps
    /// its true flanks instead of a flat top.
    pub fn curve_y(&self, speed: f64) -> f64 {
        let y = self.baseline() - if speed.is_finite() { speed } else { 0.0 } * self.unit_height();
        y.max(-4.0 * self.height).min(4.0 * self.height)
    }

    pub fn x(&self, seg: &EaseTrackSegment, share: f64) -> f64 {
        let a = self.lane.x(seg.start);
        let b = self.lane.x(seg.end);
        a + share * (b - a)
    }

    pub fn width(&self, seg: &EaseTrackSegment) -> f64 {
        self.lane.x(seg.end) - self.lane.x(seg.start)
    }

    /// The hill of one segment (Swift default `count: 97`). 97 samples spread along the bezier parameter, which packs
    /// them where time stands nearly still, i.e. exactly around a sharp peak.
    pub fn points(&self, seg: &EaseTrackSegment) -> Vec<Point> {
        self.points_count(seg, 97)
    }

    pub fn points_count(&self, seg: &EaseTrackSegment, count: usize) -> Vec<Point> {
        let mut s = SpeedHill::samples(&seg.shape, count);
        // Both handles at 100 % make a cusp: time stands still for an instant, the speed there has no finite value and
        // the sample reads 0. Drawn as it is, the tip of the peak would dive to the baseline: keep it on its flanks.
        if s.len() > 2 {
            for i in 1..(s.len() - 1) {
                if s[i].speed == 0.0 && s[i - 1].speed > Self::PEAK_CAP && s[i + 1].speed > Self::PEAK_CAP {
                    s[i].speed = s[i - 1].speed.max(s[i + 1].speed);
                }
            }
        }
        s.iter().map(|p| Point::new(self.x(seg, p.x), self.curve_y(p.speed * seg.scale))).collect()
    }

    /// Where the key on `side` (`.out` = left key, `.in` = right key) sits.
    pub fn key(&self, seg: &EaseTrackSegment, side: EaseSide) -> Point {
        if side == EaseSide::In {
            Point::new(self.x(seg, 1.0), self.y(seg.shape.speed_in() * seg.scale))
        } else {
            Point::new(self.x(seg, 0.0), self.y(seg.shape.speed_out() * seg.scale))
        }
    }

    /// Points between a key and its handle at 100 % influence: half of the segment (`HandleReach.fullInfluence`).
    pub fn handle_span(&self, seg: &EaseTrackSegment) -> f64 {
        self.width(seg) * HandleReach::FULL_INFLUENCE
    }

    /// Where the handle on `side` really is: level with its key, influence x `handleSpan` away from it.
    pub fn handle_true_end(&self, seg: &EaseTrackSegment, side: EaseSide) -> Point {
        let k = self.key(seg, side);
        let span = self.handle_span(seg);
        if side == EaseSide::In {
            Point::new(k.x - seg.shape.reach_in() * span, k.y)
        } else {
            Point::new(k.x + seg.shape.reach_out() * span, k.y)
        }
    }

    /// Where the handle is drawn and hit: the true end, pushed out to at least `minHandleLength` (at most 40 % of the
    /// full-influence span, so a narrow segment's two handles still never meet).
    pub fn handle_end(&self, seg: &EaseTrackSegment, side: EaseSide) -> Point {
        let k = self.key(seg, side);
        let e = self.handle_true_end(seg, side);
        let dir = if side == EaseSide::In { -1.0 } else { 1.0 };
        let min_len = Self::MIN_HANDLE_LENGTH.min(self.handle_span(seg) * 0.4 + 2.0);
        if (e.x - k.x) * dir >= min_len { e } else { Point::new(k.x + dir * min_len, k.y) }
    }

    /// Influence (0...1) for a handle end at `x`: 0 at the key, exactly 1 at `handleSpan`, clamped beyond.
    /// Only x counts: moving the pointer up or down changes nothing.
    pub fn reach(&self, x: f64, seg: &EaseTrackSegment, side: EaseSide) -> f64 {
        let span = self.handle_span(seg);
        if span <= 0.0 {
            return 0.0;
        }
        let k = self.key(seg, side);
        let r = if side == EaseSide::In { k.x - x } else { x - k.x } / span;
        if !r.is_finite() {
            return 0.0;
        }
        // The stop itself is exactly 100 % (no 99.99999 % from point rounding).
        if r >= 1.0 - 1e-9 { 1.0 } else { r.max(0.0) }
    }

    // MARK: Hit testing (pure)

    /// Keys of one drawn row in time order with the point their diamond sits at (outgoing speed; the last key its
    /// arriving speed).
    pub fn key_points(&self, segments: &[EaseTrackSegment]) -> Vec<SpeedGraphKeyPoint> {
        let Some(last) = segments.last() else { return Vec::new() };
        let mut out: Vec<SpeedGraphKeyPoint> =
            segments.iter().map(|s| SpeedGraphKeyPoint { id: s.from, point: self.key(s, EaseSide::Out) }).collect();
        out.push(SpeedGraphKeyPoint { id: last.to, point: self.key(last, EaseSide::In) });
        out
    }

    /// The handles drawn for a row: the side of a segment whose key is selected (Premiere shows handles on selected
    /// keys only), never on Hold.
    pub fn visible_handles(&self, segments: &[EaseTrackSegment], selected: &BTreeSet<Id>) -> Vec<SpeedGraphHandleRef> {
        let mut out: Vec<SpeedGraphHandleRef> = Vec::new();
        for (i, s) in segments.iter().enumerate() {
            if s.shape.interpolation().is_hold() {
                continue;
            }
            if selected.contains(&s.from) {
                out.push(SpeedGraphHandleRef { segment: i, side: EaseSide::Out });
            }
            if selected.contains(&s.to) {
                out.push(SpeedGraphHandleRef { segment: i, side: EaseSide::In });
            }
        }
        out
    }

    /// What a press at `p` grabs. Priority: handle > key > curve > empty (empty starts a marquee).
    /// `rows` are the drawn rows' segments, `selected` their selected key ids (same order).
    pub fn hit_test(&self, p: Point, rows: &[Vec<EaseTrackSegment>], selected: &[BTreeSet<Id>]) -> SpeedGraphHit {
        let none = BTreeSet::new();
        let mut best: Option<(SpeedGraphHit, f64)> = None;
        for (r, segs) in rows.iter().enumerate() {
            for h in self.visible_handles(segs, selected.get(r).unwrap_or(&none)) {
                let e = self.handle_end(&segs[h.segment], h.side);
                let d = (e.x - p.x).hypot(e.y - p.y);
                if d <= Self::HANDLE_HIT_RADIUS && d < best.map_or(f64::INFINITY, |b| b.1) {
                    best = Some((SpeedGraphHit::Handle { row: r, segment: h.segment, side: h.side }, d));
                }
            }
        }
        if let Some(b) = best {
            return b.0;
        }
        for (r, segs) in rows.iter().enumerate() {
            for k in self.key_points(segs) {
                let d = (k.point.x - p.x).hypot(k.point.y - p.y);
                if d <= Self::KEY_HIT_RADIUS && d < best.map_or(f64::INFINITY, |b| b.1) {
                    best = Some((SpeedGraphHit::Key { row: r, id: k.id }, d));
                }
            }
        }
        if let Some(b) = best {
            return b.0;
        }
        for (r, segs) in rows.iter().enumerate() {
            for (i, s) in segs.iter().enumerate() {
                let pts = self.points(s);
                for w in pts.windows(2) {
                    if KeyframeGraphGeometry::distance(p, w[0], w[1]) <= Self::CURVE_HIT_DISTANCE {
                        return SpeedGraphHit::Curve { row: r, segment: i };
                    }
                }
            }
        }
        SpeedGraphHit::Empty
    }

    /// Marquee: per row, the keys whose diamond or visible handle end lies inside `rect`. Rows without a hit are left out.
    pub fn keys_in(
        &self,
        rect: Rect,
        rows: &[Vec<EaseTrackSegment>],
        selected: &[BTreeSet<Id>],
    ) -> BTreeMap<usize, BTreeSet<Id>> {
        let none = BTreeSet::new();
        let mut out: BTreeMap<usize, BTreeSet<Id>> = BTreeMap::new();
        for (r, segs) in rows.iter().enumerate() {
            let mut ids: BTreeSet<Id> =
                self.key_points(segs).iter().filter(|k| rect.contains(k.point)).map(|k| k.id).collect();
            for h in self.visible_handles(segs, selected.get(r).unwrap_or(&none)) {
                let s = &segs[h.segment];
                if rect.contains(self.handle_end(s, h.side)) {
                    ids.insert(if h.side == EaseSide::Out { s.from } else { s.to });
                }
            }
            if !ids.is_empty() {
                out.insert(r, ids);
            }
        }
        out
    }

    /// Highest speed of the given segments (at least 1, so the Steady line always fits).
    pub fn peak_of(segments: &[EaseTrackSegment]) -> f64 {
        segments.iter().fold(1.0, |r, s| {
            r.max(SpeedHill::peak(&s.shape) * s.scale)
                .max(s.shape.speed_out() * s.scale)
                .max(s.shape.speed_in() * s.scale)
        })
    }

    /// Lowest speed of `segments`, at most 0 (for `low`).
    pub fn low_of(segments: &[EaseTrackSegment]) -> f64 {
        segments.iter().fold(0.0, |r, s| {
            let dip = SpeedHill::samples(&s.shape, 97)
                .iter()
                .map(|p| p.speed)
                .filter(|v| v.is_finite())
                .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.min(v))))
                .unwrap_or(0.0);
            r.min(dip * s.scale).min(s.shape.speed_out() * s.scale).min(s.shape.speed_in() * s.scale)
        })
    }
}

/// Line weights of the speed graph (thin curve, hairline stems, small knobs): the Mac painter and the draw pane.
pub enum SpeedGraphLook {}

impl SpeedGraphLook {
    pub const CURVE_WIDTH: f64 = 1.5;
    pub const STEM_WIDTH: f64 = 1.0;
    pub const KNOB_DIAMETER: f64 = 7.0;
    /// Ring of a handle knob (v9 `.hh`: well fill, 1.5 pt inner ring).
    pub const KNOB_RING: f64 = 1.5;
    /// Share of the curve's own color under it (v9 `path.fl`: 12 %).
    pub const FILL_ALPHA: f64 = 0.12;
    pub const KEY_SIDE: f64 = 7.0;
}
