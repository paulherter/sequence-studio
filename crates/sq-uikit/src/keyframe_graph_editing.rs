//! Port of `SQUIKit/Sources/SQUIKit/KeyframeGraphEditing.swift`.

use crate::keyframe_graph_geometry::{
    GraphDataPoint, GraphHandleSide, GraphHit, GraphMath, GraphMode, KeyframeGraphGeometry, Point, Rect,
};
use sq_core_model::keyframes_editing::KeyframeTrackEditing as _;
use sq_core_model::keyframes_graph::{SpeedHandle, ease_handle_from_speed_handle};
use sq_core_time::{EaseHandle, Id, Interpolation, KeyframeTrack, Time};
use std::collections::BTreeSet;

/// Limits for time edits (clip-local times).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GraphEditLimits {
    pub frame_duration: Time,
    pub min_time: Time,
    pub max_time: Option<Time>,
}

impl GraphEditLimits {
    /// Limits from `Time::ZERO` on, with no upper bound.
    pub fn new(frame_duration: Time) -> GraphEditLimits {
        GraphEditLimits { frame_duration, min_time: Time::ZERO, max_time: None }
    }
}

/// Pure edit math for the keyframe graph. Every function takes the track as it was at mouse-down (`base`)
/// and returns the new track, so a drag never accumulates rounding.
pub struct KeyframeGraphEditing;

impl KeyframeGraphEditing {
    /// Smallest time influence a dragged handle can have. dx == 0 would collapse the handle onto its key
    /// (and lose the speed value in the speed graph), so the drag stops just short of it.
    pub const MIN_INFLUENCE: f64 = 0.01;

    /// Moves all selected keys by the same frame-snapped delta. The anchor key decides the snap.
    /// The group is clamped so it never crosses or touches a non-selected neighbor (one frame apart at least)
    /// and stays within `limits`.
    pub fn move_keys(
        base: &KeyframeTrack<f64>,
        selected: &BTreeSet<Id>,
        anchor: Id,
        delta_seconds: f64,
        limits: &GraphEditLimits,
    ) -> KeyframeTrack<f64> {
        let Some(anchor_key) = base.key(anchor) else { return base.clone() };
        if !selected.contains(&anchor) {
            return base.clone();
        }
        let fd = limits.frame_duration;
        let fd_secs = GraphMath::seconds(fd);
        let frames = ((GraphMath::seconds(anchor_key.time) + delta_seconds) / fd_secs).round();
        if !frames.is_finite() || frames.abs() >= 1e12 {
            return base.clone();
        }
        let mut delta = Time::frames(frames as i64, fd) - anchor_key.time;

        let mut lo: Option<Time> = None;
        let mut hi: Option<Time> = None;
        let mut tighten = |l: Option<Time>, h: Option<Time>| {
            if let Some(l) = l {
                lo = Some(lo.map_or(l, |x| x.max(l)));
            }
            if let Some(h) = h {
                hi = Some(hi.map_or(h, |x| x.min(h)));
            }
        };
        let keys = &base.keys;
        for (i, k) in keys.iter().enumerate().filter(|(_, k)| selected.contains(&k.id)) {
            tighten(Some(limits.min_time - k.time), None);
            if let Some(m) = limits.max_time {
                tighten(None, Some(m - k.time));
            }
            if i > 0 && !selected.contains(&keys[i - 1].id) {
                tighten(Some(keys[i - 1].time + fd - k.time), None);
            }
            if i + 1 < keys.len() && !selected.contains(&keys[i + 1].id) {
                tighten(None, Some(keys[i + 1].time - fd - k.time));
            }
        }
        if let (Some(l), Some(h)) = (lo, hi)
            && l > h
        {
            return base.clone();
        }
        if let Some(l) = lo {
            delta = delta.max(l);
        }
        if let Some(h) = hi {
            delta = delta.min(h);
        }
        if delta == Time::ZERO {
            return base.clone();
        }

        let mut t = base.clone();
        t.move_keys(selected, delta);
        t
    }

    /// Adds `delta` to the value of every selected key (relative multi-key editing).
    pub fn offset_values(base: &KeyframeTrack<f64>, selected: &BTreeSet<Id>, delta: f64) -> KeyframeTrack<f64> {
        if delta == 0.0 || !delta.is_finite() {
            return base.clone();
        }
        let mut t = base.clone();
        for id in selected {
            t.update(*id, |k| k.value += delta);
        }
        t
    }

    /// Converts a handle dragged to `target` (graph data space) to a core handle.
    /// Value graph: dx = time fraction of the segment, dy = value fraction of the segment delta.
    /// Speed graph: influence from time, speed from the vertical position, converted with
    /// `ease_handle_from_speed_handle`. dx is clamped to `MIN_INFLUENCE...1`, dy is free.
    /// A segment with zero value delta keeps dy (value graph) or gets dy 0 (speed graph; speed is meaningless there).
    pub fn drag_handle(
        base: &KeyframeTrack<f64>,
        key_id: Id,
        side: GraphHandleSide,
        target: GraphDataPoint,
        mode: GraphMode,
    ) -> KeyframeTrack<f64> {
        let Some(i) = base.keys.iter().position(|k| k.id == key_id) else { return base.clone() };
        let out_side = side == GraphHandleSide::OutSide;
        let seg_index = if out_side { i as isize } else { i as isize - 1 };
        let Some(s) = GraphMath::segment(base, seg_index) else { return base.clone() };
        if s.a.interpolation.is_hold() {
            return base.clone();
        }
        let secs = GraphMath::seconds(s.dur);
        if secs <= 0.0 {
            return base.clone();
        }
        let k = &base.keys[i];

        let time_offset = if out_side {
            target.seconds - GraphMath::seconds(k.time)
        } else {
            GraphMath::seconds(k.time) - target.seconds
        };
        // Half of the segment is influence 1.0 (see `GraphMath::HANDLE_REACH`).
        let influence = (time_offset / (secs * GraphMath::HANDLE_REACH)).clamp(Self::MIN_INFLUENCE, 1.0);
        let old = if out_side { s.a.out_handle } else { s.b.in_handle };

        let handle = match mode {
            GraphMode::Value => {
                let dy = if s.delta == 0.0 {
                    old.dy
                } else {
                    // The drawn arm is the control point scaled by the reach (same tangent), so undo that here.
                    (if out_side { target.value - k.value } else { k.value - target.value })
                        / (s.delta * GraphMath::HANDLE_REACH)
                };
                EaseHandle { dx: influence, dy }
            }
            GraphMode::Speed => {
                ease_handle_from_speed_handle(SpeedHandle { speed: target.value, influence }, s.delta, s.dur)
            }
        };
        if !(handle.dx.is_finite() && handle.dy.is_finite()) {
            return base.clone();
        }

        let mut t = base.clone();
        t.update(key_id, |k| {
            if out_side {
                k.out_handle = handle;
            } else {
                k.in_handle = handle;
            }
            if k.interpolation == Interpolation::Linear {
                k.interpolation = Interpolation::Bezier;
            }
        });
        t
    }
}

// MARK: - Gesture reducer

/// What a gesture grabbed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphGestureKind {
    Key(Id),
    Handle(Id, GraphHandleSide),
    Marquee {
        additive: bool,
    },
    /// Click on a segment or a toggled-off key: no drag.
    None,
}

/// Axis a drag is locked to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphAxis {
    Horizontal,
    Vertical,
}

/// The state after a gesture step.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphGestureResult {
    pub selection: BTreeSet<Id>,
    /// Preview track (equals the base until something changed).
    pub track: KeyframeTrack<f64>,
    pub marquee: Option<Rect>,
    /// True on `end` when the gesture changed the track: call `onEdit` once.
    pub commit: bool,
}

/// One mouse gesture (down, drag..., up). Pure: the view feeds it points and applies the results.
#[derive(Clone, Debug)]
pub struct GraphGestureState {
    kind: GraphGestureKind,
    origin: Point,
    base: KeyframeTrack<f64>,
    base_selection: BTreeSet<Id>,
    /// Geometry frozen at mouse-down (the graph must not rescale while dragging).
    geometry: KeyframeGraphGeometry,
    limits: GraphEditLimits,
    moved: bool,
    /// Axis a key drag is locked to, decided when the drag starts (the dominant direction of the first movement).
    /// Value graph only; the speed graph edits time only. Shift while dragging frees both axes.
    axis: Option<GraphAxis>,
    /// Axis a handle drag is locked to (see `GraphAxisLock`): horizontal stays horizontal, vertical only when clearly
    /// vertical. Undecided (None) until the pointer has moved a few points; the handle waits until then.
    handle_axis: Option<GraphAxis>,
    free: bool,
    /// Plain press on an already-selected key: a click without drag collapses the selection to it.
    collapse_to: Option<Id>,
    selection: BTreeSet<Id>,
}

impl GraphGestureState {
    pub const DRAG_THRESHOLD: f64 = 3.0;

    pub fn new(
        p: Point,
        shift: bool,
        geometry: KeyframeGraphGeometry,
        track: KeyframeTrack<f64>,
        selection: BTreeSet<Id>,
        limits: GraphEditLimits,
    ) -> GraphGestureState {
        let mut sel = selection.clone();
        let mut collapse_to = None;
        let kind = match geometry.hit_test(p, &track, &selection) {
            GraphHit::Handle(id, side) => GraphGestureKind::Handle(id, side),
            GraphHit::Key(id) => {
                if shift {
                    if selection.contains(&id) {
                        sel.remove(&id);
                        GraphGestureKind::None
                    } else {
                        sel.insert(id);
                        GraphGestureKind::Key(id)
                    }
                } else {
                    if selection.contains(&id) {
                        collapse_to = Some(id);
                    } else {
                        sel = BTreeSet::from([id]);
                    }
                    GraphGestureKind::Key(id)
                }
            }
            GraphHit::Segment { from, to } => {
                sel = if shift {
                    selection.iter().copied().chain([from, to]).collect()
                } else {
                    BTreeSet::from([from, to])
                };
                GraphGestureKind::None
            }
            GraphHit::Empty => {
                if !shift {
                    sel = BTreeSet::new();
                }
                GraphGestureKind::Marquee { additive: shift }
            }
        };
        GraphGestureState {
            kind,
            origin: p,
            base: track,
            base_selection: selection,
            geometry,
            limits,
            moved: false,
            axis: None,
            handle_axis: None,
            free: false,
            collapse_to,
            selection: sel,
        }
    }

    pub fn kind(&self) -> GraphGestureKind {
        self.kind
    }

    pub fn moved(&self) -> bool {
        self.moved
    }

    pub fn axis(&self) -> Option<GraphAxis> {
        self.axis
    }

    pub fn handle_axis(&self) -> Option<GraphAxis> {
        self.handle_axis
    }

    pub fn current(&self) -> GraphGestureResult {
        GraphGestureResult { selection: self.selection.clone(), track: self.base.clone(), marquee: None, commit: false }
    }

    pub fn drag(&mut self, p: Point, free: bool) -> GraphGestureResult {
        self.free = free;
        if !self.moved {
            if (p.x - self.origin.x).hypot(p.y - self.origin.y) < Self::DRAG_THRESHOLD {
                return self.current();
            }
            self.moved = true;
        }
        match self.kind {
            GraphGestureKind::Key(id) => {
                let dx = p.x - self.origin.x;
                let dy = p.y - self.origin.y;
                if self.axis.is_none() {
                    self.axis = Some(if dx.abs() >= dy.abs() { GraphAxis::Horizontal } else { GraphAxis::Vertical });
                }
                let lock = if self.geometry.mode == GraphMode::Value && !free { self.axis } else { None };
                let mut t = self.base.clone();
                if lock != Some(GraphAxis::Vertical) {
                    t = KeyframeGraphEditing::move_keys(
                        &self.base,
                        &self.selection,
                        id,
                        dx / self.geometry.points_per_second(),
                        &self.limits,
                    );
                }
                if self.geometry.mode == GraphMode::Value && lock != Some(GraphAxis::Horizontal) {
                    let dv = self.geometry.value_at_y(p.y) - self.geometry.value_at_y(self.origin.y);
                    t = KeyframeGraphEditing::offset_values(&t, &self.selection, dv);
                }
                GraphGestureResult { selection: self.selection.clone(), track: t, marquee: None, commit: false }
            }
            GraphGestureKind::Handle(id, side) => {
                let Some(hp) = self.geometry.handle_true_point(&self.base, id, side) else { return self.current() };
                let mut dx = p.x - self.origin.x;
                let mut dy = p.y - self.origin.y;
                if !free {
                    if self.handle_axis.is_none() {
                        self.handle_axis = crate::keyframe_viewport::GraphAxisLock::decide(dx, dy);
                    }
                    match self.handle_axis {
                        Some(GraphAxis::Horizontal) => dy = 0.0,
                        Some(GraphAxis::Vertical) => dx = 0.0,
                        None => return self.current(),
                    }
                }
                // Keep the grab offset: the handle follows the pointer's movement, it does not jump under it.
                let target = self.geometry.data(Point { x: hp.x + dx, y: hp.y + dy });
                let t = KeyframeGraphEditing::drag_handle(&self.base, id, side, target, self.geometry.mode);
                GraphGestureResult { selection: self.selection.clone(), track: t, marquee: None, commit: false }
            }
            GraphGestureKind::Marquee { additive } => {
                let rect = Rect {
                    x: self.origin.x.min(p.x),
                    y: self.origin.y.min(p.y),
                    width: (p.x - self.origin.x).abs(),
                    height: (p.y - self.origin.y).abs(),
                };
                let seed = if additive { self.base_selection.clone() } else { BTreeSet::new() };
                let hit = self.geometry.keys_in(rect, &self.base, &seed);
                self.selection = if additive { self.base_selection.union(&hit).copied().collect() } else { hit };
                GraphGestureResult {
                    selection: self.selection.clone(),
                    track: self.base.clone(),
                    marquee: Some(rect),
                    commit: false,
                }
            }
            GraphGestureKind::None => self.current(),
        }
    }

    /// Finishes the gesture. `commit` is true only if the track differs from the base.
    pub fn end(&mut self, p: Point) -> GraphGestureResult {
        let mut r = self.drag(p, self.free);
        if !self.moved
            && let Some(id) = self.collapse_to
        {
            self.selection = BTreeSet::from([id]);
        }
        // A key that was just moved is deselected: a value change at the playhead afterwards makes a new key.
        r.commit = self.moved && r.track != self.base;
        if r.commit && matches!(self.kind, GraphGestureKind::Key(_)) {
            self.selection = BTreeSet::new();
        }
        r.selection = self.selection.clone();
        r.marquee = None;
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keyframe_graph_geometry::{GraphFit, Size};
    use sq_core_time::Keyframe;

    const FD: Time = Time::new(1, 30);

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }
    const A: u128 = 1;
    const B: u128 = 2;
    const C: u128 = 3;

    fn set(ids: &[u128]) -> BTreeSet<Id> {
        ids.iter().map(|n| id(*n)).collect()
    }

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

    fn track(keys: Vec<Keyframe<f64>>) -> KeyframeTrack<f64> {
        KeyframeTrack { keys }
    }

    /// 0s -> 0, 2s -> 100, 4s -> 50, all linear.
    fn track3() -> KeyframeTrack<f64> {
        track(vec![lin(A, 0, 0.0), lin(B, 2, 100.0), lin(C, 4, 50.0)])
    }

    fn geo(t: &KeyframeTrack<f64>, mode: GraphMode) -> KeyframeGraphGeometry {
        KeyframeGraphGeometry::new(Size { width: 440.0, height: 212.0 }, GraphFit::auto(t, mode), mode)
    }

    fn limits() -> GraphEditLimits {
        GraphEditLimits::new(FD)
    }

    fn time_of(t: &KeyframeTrack<f64>, n: u128) -> Option<Time> {
        t.key(id(n)).map(|k| k.time)
    }

    fn value_of(t: &KeyframeTrack<f64>, n: u128) -> f64 {
        t.key(id(n)).map_or(f64::NAN, |k| k.value)
    }

    // MARK: KeyframeGraphEditing

    #[test]
    fn move_keys_snaps_to_frames_and_moves_group() {
        let lim = GraphEditLimits { min_time: Time::new(-10, 1), ..limits() };
        let r = KeyframeGraphEditing::move_keys(&track3(), &set(&[A, B]), id(B), 0.51, &lim);
        assert_eq!(time_of(&r, B), Some(Time::new(2, 1) + FD * 15)); // 0.5 s = 15 frames
        assert_eq!(time_of(&r, A), Some(FD * 15));
        assert_eq!(time_of(&r, C), Some(Time::new(4, 1)));
    }

    #[test]
    fn move_clamps_against_unselected_neighbours() {
        let r = KeyframeGraphEditing::move_keys(&track3(), &set(&[B]), id(B), 10.0, &limits());
        assert_eq!(time_of(&r, B), Some(Time::new(4, 1) - FD)); // one frame before C, never onto it
        assert_eq!(r.keys.iter().map(|k| k.id).collect::<Vec<_>>(), vec![id(A), id(B), id(C)]);
        let l = KeyframeGraphEditing::move_keys(&track3(), &set(&[B]), id(B), -10.0, &limits());
        assert_eq!(time_of(&l, B), Some(FD));
    }

    /// A Hold Ahead moves like any key and stays one.
    #[test]
    fn a_hold_ahead_moves_and_clamps_like_any_key() {
        let t = track(vec![
            lin(A, 0, 0.0),
            key(B, 2, 100.0, Interpolation::HoldAhead, EaseHandle::LINEAR, EaseHandle::LINEAR),
            lin(C, 4, 50.0),
        ]);
        let r = KeyframeGraphEditing::move_keys(&t, &set(&[B]), id(B), 1.0, &limits());
        let b = r.key(id(B));
        assert!(
            b.is_some_and(|k| k.time == Time::new(3, 1) && k.interpolation == Interpolation::HoldAhead)
                && r.keys.len() == 3
        );
        assert_eq!(r.value(Time::new(3, 1)), Some(100.0));
        assert_eq!(r.value(Time::new(3, 1) + FD), Some(50.0));
        let far = KeyframeGraphEditing::move_keys(&t, &set(&[B]), id(B), 10.0, &limits());
        assert_eq!(time_of(&far, B), Some(Time::new(4, 1) - FD));
        let a = KeyframeGraphEditing::move_keys(&t, &set(&[A]), id(A), 10.0, &limits());
        assert_eq!(time_of(&a, A), Some(Time::new(2, 1) - FD));
    }

    #[test]
    fn move_clamps_at_min_time_and_max_time() {
        let l = KeyframeGraphEditing::move_keys(&track3(), &set(&[A, B, C]), id(A), -5.0, &limits());
        assert_eq!(time_of(&l, A), Some(Time::ZERO));
        assert_eq!(time_of(&l, C), Some(Time::new(4, 1))); // group keeps its shape
        let lim = GraphEditLimits { max_time: Some(Time::new(5, 1)), ..limits() };
        let r = KeyframeGraphEditing::move_keys(&track3(), &set(&[B, C]), id(C), 9.0, &lim);
        assert_eq!(time_of(&r, C), Some(Time::new(5, 1)));
        assert_eq!(time_of(&r, B), Some(Time::new(3, 1)));
    }

    #[test]
    fn zero_move_returns_base() {
        let t = track3();
        assert_eq!(KeyframeGraphEditing::move_keys(&t, &set(&[B]), id(B), 0.001, &limits()), t);
    }

    #[test]
    fn offset_values_is_relative() {
        let r = KeyframeGraphEditing::offset_values(&track3(), &set(&[A, B]), 7.0);
        assert!(value_of(&r, A) == 7.0 && value_of(&r, B) == 107.0 && value_of(&r, C) == 50.0);
    }

    fn two_keys() -> KeyframeTrack<f64> {
        track(vec![lin(A, 0, 0.0), lin(B, 2, 100.0)])
    }

    fn point(seconds: f64, value: f64) -> GraphDataPoint {
        GraphDataPoint { seconds, value }
    }

    #[test]
    fn value_handle_drag_sets_influence_and_overshoot() {
        let t = two_keys();
        let reach = GraphMath::HANDLE_REACH;
        let r = KeyframeGraphEditing::drag_handle(
            &t,
            id(A),
            GraphHandleSide::OutSide,
            point(0.5 * 2.0 * reach, 150.0 * reach),
            GraphMode::Value,
        );
        let h = r.key(id(A)).map(|k| k.out_handle).unwrap_or(EaseHandle::LINEAR);
        assert!((h.dx - 0.5).abs() < 1e-9 && (h.dy - 1.5).abs() < 1e-9); // dy free: overshoot allowed
        assert_eq!(r.key(id(A)).map(|k| k.interpolation), Some(Interpolation::Bezier));
        assert_eq!(r.key(id(B)).map(|k| k.in_handle), Some(EaseHandle::LINEAR)); // other side untouched
        let i = KeyframeGraphEditing::drag_handle(
            &t,
            id(B),
            GraphHandleSide::InSide,
            point(2.0 - 0.25 * 2.0 * reach, 100.0 - 10.0 * reach),
            GraphMode::Value,
        );
        let ih = i.key(id(B)).map(|k| k.in_handle).unwrap_or(EaseHandle::LINEAR);
        assert!((ih.dx - 0.25).abs() < 1e-9 && (ih.dy - 0.1).abs() < 1e-9);
    }

    #[test]
    fn handle_influence_is_clamped() {
        let t = two_keys();
        let far =
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(9.0, 10.0), GraphMode::Value);
        assert_eq!(far.key(id(A)).map(|k| k.out_handle.dx), Some(1.0));
        let behind =
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(-3.0, 10.0), GraphMode::Value);
        assert_eq!(behind.key(id(A)).map(|k| k.out_handle.dx), Some(KeyframeGraphEditing::MIN_INFLUENCE));
    }

    #[test]
    fn speed_handle_drag_uses_core_conversion() {
        let t = two_keys(); // linear speed 50/s
        let reach = GraphMath::HANDLE_REACH;
        // 2x speed, 25 % influence
        let r = KeyframeGraphEditing::drag_handle(
            &t,
            id(A),
            GraphHandleSide::OutSide,
            point(0.25 * 2.0 * reach, 100.0),
            GraphMode::Speed,
        );
        let expected =
            ease_handle_from_speed_handle(SpeedHandle { speed: 100.0, influence: 0.25 }, 100.0, Time::new(2, 1));
        assert_eq!(r.key(id(A)).map(|k| k.out_handle), Some(expected));
        // Round trip through the graph position.
        let p = GraphMath::handle_point(&r, id(A), GraphHandleSide::OutSide, GraphMode::Speed);
        assert!(p.is_some_and(|p| (p.value - 100.0).abs() < 1e-9 && (p.seconds - 0.25 * 2.0 * reach).abs() < 1e-9));
    }

    #[test]
    fn speed_handle_on_flat_segment_keeps_dy_zero() {
        let t = track(vec![lin(A, 0, 5.0), lin(B, 2, 5.0)]);
        let r =
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(1.0, 40.0), GraphMode::Speed);
        assert_eq!(r.key(id(A)).map(|k| k.out_handle.dy), Some(0.0));
    }

    #[test]
    fn hold_segment_handle_drag_is_ignored() {
        let t =
            track(vec![key(A, 0, 0.0, Interpolation::Hold, EaseHandle::LINEAR, EaseHandle::LINEAR), lin(B, 2, 100.0)]);
        assert_eq!(
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(1.0, 1.0), GraphMode::Value),
            t
        );
    }

    // MARK: Gestures

    fn begin(p: Point, shift: bool, t: &KeyframeTrack<f64>, sel: &[u128], mode: GraphMode) -> GraphGestureState {
        GraphGestureState::new(p, shift, geo(t, mode), t.clone(), set(sel), limits())
    }

    fn pt(x: f64, y: f64) -> Point {
        Point { x, y }
    }

    #[test]
    fn click_selects_and_shift_click_toggles() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let (pa, pb) = (g.key_point(&t, 0), g.key_point(&t, 1));
        let mut s = begin(pa, false, &t, &[], GraphMode::Value);
        assert_eq!(s.end(pa).selection, set(&[A]));
        s = begin(pb, true, &t, &[A], GraphMode::Value);
        assert_eq!(s.end(pb).selection, set(&[A, B]));
        s = begin(pb, true, &t, &[A, B], GraphMode::Value);
        let r = s.end(pb);
        assert!(r.selection == set(&[A]) && !r.commit);
    }

    #[test]
    fn click_on_empty_clears_selection() {
        let t = track3();
        let mut s = begin(pt(100.0, 5.0), false, &t, &[A], GraphMode::Value);
        let r = s.end(pt(100.0, 5.0));
        assert!(r.selection.is_empty() && !r.commit);
    }

    #[test]
    fn click_on_segment_selects_both_keys() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let mid = g.point(point(1.0, 50.0));
        let mut s = begin(mid, false, &t, &[], GraphMode::Value);
        assert_eq!(s.end(mid).selection, set(&[A, B]));
    }

    #[test]
    fn marquee_selects_and_shift_extends() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let (pb, pc) = (g.key_point(&t, 1), g.key_point(&t, 2));
        let mut s = begin(pt(pb.x - 20.0, 2.0), false, &t, &[], GraphMode::Value);
        let mid = s.drag(pt(pb.x + 20.0, pb.y + 20.0), false);
        assert!(mid.selection == set(&[B]) && mid.marquee.is_some());
        assert_eq!(s.end(pt(pb.x + 20.0, pb.y + 20.0)).selection, set(&[B]));
        s = begin(pt(pc.x - 20.0, 2.0), true, &t, &[B], GraphMode::Value);
        s.drag(pt(pc.x + 14.0, pc.y + 20.0), false);
        assert_eq!(s.end(pt(pc.x + 14.0, pc.y + 20.0)).selection, set(&[B, C]));
    }

    #[test]
    fn key_drag_moves_time_and_value_and_commits_once() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Value);
        let to = pt(p0.x + 0.5 * g.points_per_second(), p0.y - 10.0 * g.points_per_value());
        let mid = s.drag(to, true); // Shift: both axes
        assert!(!mid.commit); // nothing committed while dragging
        let r = s.end(to);
        assert!(r.commit);
        assert_eq!(time_of(&r.track, B), Some(Time::new(2, 1) + FD * 15));
        assert!((value_of(&r.track, B) - 110.0).abs() < 1e-6);
        assert!(r.selection.is_empty()); // a moved key is deselected
    }

    #[test]
    fn mostly_horizontal_drag_changes_only_time() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Value);
        let to = pt(p0.x + 0.5 * g.points_per_second(), p0.y - 12.0); // clearly more x than y
        let r = s.end(to);
        assert_eq!(value_of(&r.track, B), 100.0);
        assert_eq!(time_of(&r.track, B), Some(Time::new(2, 1) + FD * 15));
        assert_eq!(s.axis(), Some(GraphAxis::Horizontal));
    }

    #[test]
    fn mostly_vertical_drag_changes_only_value() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Value);
        let to = pt(p0.x + 8.0, p0.y - 10.0 * g.points_per_value());
        let r = s.end(to);
        assert_eq!(time_of(&r.track, B), Some(Time::new(2, 1)));
        assert!((value_of(&r.track, B) - 110.0).abs() < 1e-6);
        assert_eq!(s.axis(), Some(GraphAxis::Vertical));
    }

    #[test]
    fn handle_influence_stays_within_the_segment() {
        let t = track(vec![
            key(A, 0, 0.0, Interpolation::Bezier, EaseHandle::LINEAR, EaseHandle::LINEAR),
            lin(B, 2, 100.0),
            lin(C, 4, 50.0),
        ]);
        let out =
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(9.0, 0.0), GraphMode::Value);
        assert_eq!(out.key(id(A)).map(|k| k.out_handle.dx), Some(1.0)); // 100 % of the segment, never beyond
        let low =
            KeyframeGraphEditing::drag_handle(&t, id(A), GraphHandleSide::OutSide, point(-3.0, 0.0), GraphMode::Value);
        assert_eq!(low.key(id(A)).map(|k| k.out_handle.dx), Some(KeyframeGraphEditing::MIN_INFLUENCE));
    }

    #[test]
    fn speed_mode_key_drag_moves_time_only() {
        let t = track3();
        let g = geo(&t, GraphMode::Speed);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Speed);
        let to = pt(p0.x + 0.25 * g.points_per_second(), p0.y - 40.0);
        let r = s.end(to);
        assert_eq!(value_of(&r.track, B), 100.0);
        assert!(time_of(&r.track, B).is_some_and(|t| t > Time::new(2, 1)));
    }

    #[test]
    fn tiny_movement_is_a_click_not_a_drag() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Value);
        let r = s.end(pt(p0.x + 1.0, p0.y + 1.0));
        assert!(!r.commit && r.track == t);
    }

    #[test]
    fn press_on_selected_key_drags_whole_group_and_click_collapses() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let pa = g.key_point(&t, 0);
        let mut s = begin(pa, false, &t, &[A, B], GraphMode::Value);
        assert_eq!(s.end(pa).selection, set(&[A])); // click without drag collapses
        s = begin(pa, false, &t, &[A, B], GraphMode::Value);
        let to = pt(pa.x + 0.5 * g.points_per_second(), pa.y);
        let r = s.end(to);
        assert!(r.selection.is_empty());
        assert!(
            time_of(&r.track, B).is_some_and(|t| t > Time::new(2, 1))
                && time_of(&r.track, A).is_some_and(|t| t > Time::ZERO)
        );
    }

    #[test]
    fn handle_drag_edits_only_that_handle() {
        let t = two_keys();
        let g = geo(&t, GraphMode::Value);
        let hp = g.handle_point(&t, id(A), GraphHandleSide::OutSide).unwrap_or_default();
        let mut s = begin(hp, false, &t, &[A], GraphMode::Value);
        let to = pt(hp.x + 30.0, hp.y - 20.0);
        s.drag(to, true); // Shift: both axes
        let r = s.end(to);
        assert!(r.commit && r.selection == set(&[A])); // a handle drag keeps the key selected
        let h = r.track.key(id(A)).map(|k| k.out_handle).unwrap_or(EaseHandle::LINEAR);
        assert!(h.dx > EaseHandle::LINEAR.dx && h.dy > EaseHandle::LINEAR.dy);
        assert_eq!(r.track.key(id(B)), t.key(id(B)));
    }

    // MARK: Handle axis lock

    fn axis_setup(mode: GraphMode) -> (KeyframeTrack<f64>, KeyframeGraphGeometry, Point) {
        let t = track(vec![
            key(A, 0, 0.0, Interpolation::Bezier, EaseHandle::LINEAR, EaseHandle::LINEAR),
            lin(B, 4, 100.0),
        ]);
        let g = geo(&t, mode);
        let hp = g.handle_point(&t, id(A), GraphHandleSide::OutSide).unwrap_or_default();
        (t, g, hp)
    }

    fn axis_begin(t: &KeyframeTrack<f64>, g: &KeyframeGraphGeometry, p: Point) -> GraphGestureState {
        GraphGestureState::new(p, false, g.clone(), t.clone(), set(&[A]), limits())
    }

    fn handle_at(t: &KeyframeTrack<f64>, mode: GraphMode) -> GraphDataPoint {
        GraphMath::handle_point(t, id(A), GraphHandleSide::OutSide, mode).unwrap_or(point(f64::NAN, f64::NAN))
    }

    #[test]
    fn horizontal_drag_keeps_the_speed_and_only_changes_influence() {
        let (t, g, hp) = axis_setup(GraphMode::Speed);
        let before = handle_at(&t, GraphMode::Speed);
        let mut s = axis_begin(&t, &g, hp);
        let to = pt(hp.x + 40.0, hp.y + 9.0); // wobbly but mostly horizontal
        s.drag(to, false);
        let r = s.end(to);
        assert_eq!(s.handle_axis(), Some(GraphAxis::Horizontal));
        let after = handle_at(&r.track, GraphMode::Speed);
        assert!((after.value - before.value).abs() < 1e-6); // speed unchanged
        assert!(after.seconds > before.seconds); // influence moved
    }

    #[test]
    fn vertical_drag_keeps_the_influence() {
        let (t, g, hp) = axis_setup(GraphMode::Speed);
        let before = handle_at(&t, GraphMode::Speed);
        let mut s = axis_begin(&t, &g, hp);
        let to = pt(hp.x + 2.0, hp.y - 40.0);
        s.drag(to, false);
        let r = s.end(to);
        assert_eq!(s.handle_axis(), Some(GraphAxis::Vertical));
        let after = handle_at(&r.track, GraphMode::Speed);
        assert!((after.seconds - before.seconds).abs() < 1e-6);
        assert!(after.value > before.value);
    }

    #[test]
    fn handle_does_not_move_before_the_axis_is_decided() {
        let (t, g, hp) = axis_setup(GraphMode::Speed);
        let mut s = axis_begin(&t, &g, hp);
        // past the click threshold, below the lock distance
        let r = s.drag(pt(hp.x + 3.5, hp.y + 0.5), false);
        assert_eq!(r.track, t);
    }

    #[test]
    fn shift_frees_both_axes() {
        let (t, g, hp) = axis_setup(GraphMode::Speed);
        let mut s = axis_begin(&t, &g, hp);
        let r = s.drag(pt(hp.x + 30.0, hp.y - 30.0), true);
        let before = handle_at(&t, GraphMode::Speed);
        let after = handle_at(&r.track, GraphMode::Speed);
        assert!(after.seconds > before.seconds && after.value != before.value);
    }

    #[test]
    fn moved_key_is_deselected_clicked_key_is_not() {
        let t = track3();
        let g = geo(&t, GraphMode::Value);
        let p0 = g.key_point(&t, 1);
        let mut s = begin(p0, false, &t, &[], GraphMode::Value);
        let to = pt(p0.x + 0.5 * g.points_per_second(), p0.y);
        s.drag(to, false);
        let moved = s.end(to);
        assert!(moved.commit && moved.selection.is_empty());
        let mut c = begin(p0, false, &t, &[], GraphMode::Value);
        assert_eq!(c.end(p0).selection, set(&[B])); // a plain click still selects
    }
}
