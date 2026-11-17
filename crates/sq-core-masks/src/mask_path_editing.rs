// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MaskPathEditing.swift (the `MaskTracking` protocol, a Mac-only tracker interface, is not ported)
//! Mask pen handles and mask tracking. Pure path maths; the Program monitor overlay and the Vision tracker call into it.
//! Points are frame fractions (0...1, y down) like everything in `MaskPath`.

use crate::mask_motion::{MaskMotion, MaskPathMotionExt};
use crate::masks::{CURVE_SUBDIVISIONS, ClipMasksExt};
use sq_core_model::{Clip, MaskPath, MaskVertex};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeValue, Time, Vec2};
use std::collections::BTreeSet;
use std::ops::Range;

/// An axis-aligned box in frame fractions (y down): what the object tracker follows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskTrackBox {
    /// Middle of the box.
    pub center: Vec2,
    /// Width and height.
    pub size: Vec2,
}

impl MaskTrackBox {
    /// Axis-aligned bounds of `points` (none: a zero box at the frame center).
    pub fn bounding(points: &[Vec2]) -> MaskTrackBox {
        let Some(f) = points.first() else {
            return MaskTrackBox { center: Vec2::new(0.5, 0.5), size: Vec2::ZERO };
        };
        let (mut lo, mut hi) = (*f, *f);
        for p in &points[1..] {
            lo = Vec2::new(lo.x.min(p.x), lo.y.min(p.y));
            hi = Vec2::new(hi.x.max(p.x), hi.y.max(p.y));
        }
        MaskTrackBox { center: (lo + hi) * 0.5, size: hi - lo }
    }
}

/// Where a point nearest to a path lies.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NearestSegment {
    /// The segment (vertex i to vertex i+1).
    pub segment: usize,
    /// Curve parameter on it.
    pub t: f64,
    /// Distance in px of the `frame`-sized picture.
    pub distance: f64,
}

type Bezier = (Vec2, Vec2, Vec2, Vec2);

/// Logic Swift keeps on `MaskPath` in `MaskPathEditing.swift`.
pub trait MaskPathEditingExt: Sized {
    /// Bounding box of the flattened outline (an empty path: a zero box at the frame center).
    fn bounds(&self) -> MaskTrackBox;
    /// The path moved (and with `scale`, sized per axis) the way box `a` became box `b`. Tangents scale along.
    fn tracked(&self, a: &MaskTrackBox, b: &MaskTrackBox, scale: bool) -> MaskPath;
    /// A vertex added on segment `i` at curve parameter `t` (de Casteljau): the shape does not change. A straight
    /// segment gets a corner. The new vertex sits at index `i + 1` (the end for the closing segment).
    fn splitting(&self, segment: usize, t: f64) -> MaskPath;
    /// The segment nearest to `p` (frame fractions), its curve parameter and the distance in px of a `frame`-sized
    /// picture.
    fn nearest_segment(&self, p: Vec2, frame: Vec2) -> Option<NearestSegment>;
    /// Pen tool: a vertex placed on segment `i` at `t` (see `splitting`) whose handles are pulled to `handle` (its out
    /// tangent, offset from the new point; the in tangent mirrors unless `independent`). A zero handle is a plain split.
    fn placing_vertex(&self, segment: usize, t: f64, handle: Vec2, independent: bool) -> MaskPath;
    /// The path without vertex `i`; `None` when that would leave fewer than three vertices or `i` is out of range.
    fn removing_vertex(&self, i: usize) -> Option<MaskPath>;
    /// Corner <-> smooth (Option-click a vertex): a corner gets tangents along the chord of its neighbors, a third of
    /// the way to each; a smooth or broken vertex becomes a corner.
    fn toggling_smooth(&self, i: usize) -> MaskPath;
    /// Drags one tangent handle (offset from the vertex). The other side mirrors it unless `independent` (Option).
    fn set_tangent(&mut self, i: usize, is_out: bool, offset: Vec2, independent: bool);
    /// This path with `anchor - end` added, scaled by `weight`, to every vertex (point and tangents); same vertex count
    /// assumed.
    #[doc(hidden)]
    fn corrected(&self, end: &MaskPath, anchor: &MaskPath, weight: f64) -> MaskPath;
}

fn is_corner(v: &MaskVertex) -> bool {
    v.in_tangent == Vec2::ZERO && v.out_tangent == Vec2::ZERO
}

/// Bezier control points of segment `i` (vertex i to vertex i+1, the last one closes the path).
fn control_points(path: &MaskPath, i: usize) -> Bezier {
    let a = &path.vertices[i];
    let b = &path.vertices[(i + 1) % path.vertices.len()];
    (a.point, a.point + a.out_tangent, b.point + b.in_tangent, b.point)
}

fn bezier(c: &Bezier, t: f64) -> Vec2 {
    let u = 1.0 - t;
    c.0 * (u * u * u) + c.1 * (3.0 * u * u * t) + c.2 * (3.0 * u * t * t) + c.3 * (t * t * t)
}

impl MaskPathEditingExt for MaskPath {
    fn bounds(&self) -> MaskTrackBox {
        MaskTrackBox::bounding(&self.polygon())
    }

    fn tracked(&self, a: &MaskTrackBox, b: &MaskTrackBox, scale: bool) -> MaskPath {
        let sx = if scale && a.size.x > 1e-9 { b.size.x / a.size.x } else { 1.0 };
        let sy = if scale && a.size.y > 1e-9 { b.size.y / a.size.y } else { 1.0 };
        let s = |v: Vec2| Vec2::new(v.x * sx, v.y * sy);
        MaskPath {
            vertices: self
                .vertices
                .iter()
                .map(|v| MaskVertex {
                    point: b.center + s(v.point - a.center),
                    in_tangent: s(v.in_tangent),
                    out_tangent: s(v.out_tangent),
                })
                .collect(),
        }
    }

    fn splitting(&self, i: usize, t: f64) -> MaskPath {
        if i >= self.vertices.len() {
            return self.clone();
        }
        let t = t.clamp(0.0, 1.0);
        let n = self.vertices.len();
        let (a, b) = (self.vertices[i], self.vertices[(i + 1) % n]);
        let mut out = self.clone();
        if a.out_tangent == Vec2::ZERO && b.in_tangent == Vec2::ZERO {
            out.vertices.insert(i + 1, MaskVertex::corner(Vec2::lerp(&a.point, &b.point, t)));
            return out;
        }
        let (p0, p1, p2, p3) = control_points(self, i);
        let p01 = Vec2::lerp(&p0, &p1, t);
        let p12 = Vec2::lerp(&p1, &p2, t);
        let p23 = Vec2::lerp(&p2, &p3, t);
        let q0 = Vec2::lerp(&p01, &p12, t);
        let q1 = Vec2::lerp(&p12, &p23, t);
        let m = Vec2::lerp(&q0, &q1, t);
        out.vertices[i].out_tangent = p01 - p0;
        out.vertices[(i + 1) % n].in_tangent = p23 - p3;
        out.vertices.insert(i + 1, MaskVertex { point: m, in_tangent: q0 - m, out_tangent: q1 - m });
        out
    }

    fn nearest_segment(&self, p: Vec2, frame: Vec2) -> Option<NearestSegment> {
        if self.vertices.len() < 2 {
            return None;
        }
        let px = |v: Vec2| Vec2::new(v.x * frame.x, v.y * frame.y);
        let target = px(p);
        let mut best: Option<NearestSegment> = None;
        let steps = CURVE_SUBDIVISIONS * 4;
        for i in 0..self.vertices.len() {
            let c = control_points(self, i);
            let straight = c.0 == c.1 && c.2 == c.3; // `splitting` places points linearly on straight segments
            let mut prev = px(c.0);
            for s in 1..=steps {
                let t1 = s as f64 / steps as f64;
                let cur = px(if straight { Vec2::lerp(&c.0, &c.3, t1) } else { bezier(&c, t1) });
                let e = cur - prev;
                let w = target - prev;
                let ee = e.x * e.x + e.y * e.y;
                let k = if ee > 0.0 { ((w.x * e.x + w.y * e.y) / ee).clamp(0.0, 1.0) } else { 0.0 };
                let d = (w - e * k).length();
                if d < best.map_or(f64::INFINITY, |b| b.distance) {
                    best = Some(NearestSegment { segment: i, t: ((s - 1) as f64 + k) / steps as f64, distance: d });
                }
                prev = cur;
            }
        }
        best
    }

    fn placing_vertex(&self, segment: usize, t: f64, handle: Vec2, independent: bool) -> MaskPath {
        if segment >= self.vertices.len() {
            return self.clone();
        }
        let mut out = self.splitting(segment, t);
        if handle != Vec2::ZERO {
            out.set_tangent(segment + 1, true, handle, independent);
        }
        out
    }

    fn removing_vertex(&self, i: usize) -> Option<MaskPath> {
        if i >= self.vertices.len() || self.vertices.len() <= 3 {
            return None;
        }
        let mut out = self.clone();
        out.vertices.remove(i);
        Some(out)
    }

    fn toggling_smooth(&self, i: usize) -> MaskPath {
        let n = self.vertices.len();
        if i >= n || n < 3 {
            return self.clone();
        }
        let mut out = self.clone();
        let v = self.vertices[i];
        if !is_corner(&v) {
            out.vertices[i].in_tangent = Vec2::ZERO;
            out.vertices[i].out_tangent = Vec2::ZERO;
            return out;
        }
        let prev = self.vertices[(i + n - 1) % n].point;
        let next = self.vertices[(i + 1) % n].point;
        let chord = next - prev;
        let len = chord.length();
        if len <= 1e-12 {
            return self.clone();
        }
        let dir = chord * (1.0 / len);
        out.vertices[i].out_tangent = dir * ((next - v.point).length() / 3.0);
        out.vertices[i].in_tangent = dir * (-(prev - v.point).length() / 3.0);
        out
    }

    fn set_tangent(&mut self, i: usize, is_out: bool, offset: Vec2, independent: bool) {
        let Some(v) = self.vertices.get_mut(i) else { return };
        if is_out {
            v.out_tangent = offset;
        } else {
            v.in_tangent = offset;
        }
        if independent {
            return;
        }
        if is_out {
            v.in_tangent = offset * -1.0;
        } else {
            v.out_tangent = offset * -1.0;
        }
    }

    fn corrected(&self, end: &MaskPath, anchor: &MaskPath, weight: f64) -> MaskPath {
        if end.vertices.len() != self.vertices.len() || anchor.vertices.len() != self.vertices.len() {
            return self.clone();
        }
        MaskPath {
            vertices: (0..self.vertices.len())
                .map(|i| {
                    let (v, e, a) = (self.vertices[i], end.vertices[i], anchor.vertices[i]);
                    MaskVertex {
                        point: v.point + (a.point - e.point) * weight,
                        in_tangent: v.in_tangent + (a.in_tangent - e.in_tangent) * weight,
                        out_tangent: v.out_tangent + (a.out_tangent - e.out_tangent) * weight,
                    }
                })
                .collect(),
        }
    }
}

/// Logic Swift keeps on `Clip` in `MaskPathEditing.swift`.
pub trait MaskTrackingExt {
    /// Adds a vertex on segment `segment` at curve parameter `t` to the path value and every path key (same place in
    /// each), so the keys keep the same vertex count and still blend.
    fn insert_mask_vertex(&mut self, id: Id, segment: usize, t: f64);
    /// Pen tool: `insert_mask_vertex` plus pulled handles on the new vertex of the shape shown at `t` (a key there when
    /// the path is animated). Other keys only get the point.
    #[allow(clippy::too_many_arguments)]
    fn place_mask_vertex(
        &mut self,
        id: Id,
        segment: usize,
        t: f64,
        handle: Vec2,
        independent: bool,
        local: Time,
        ids: &mut dyn IdSource,
    );
    /// Deletes vertex `index` from the path value and every key. False when the path would get fewer than three vertices.
    fn remove_mask_vertex(&mut self, id: Id, index: usize) -> bool;
    /// Clip-local frame times a track visits, starting at `l0` and stepping one frame to the clip's first or last frame.
    /// Empty when `l0` is outside the clip.
    fn mask_track_times(&self, l0: Time, forward: bool, frame_duration: Time) -> Vec<Time>;
    /// Writes a tracked mask: a path key at every `times[i]` whose box is known (up to the first lost frame), the shape
    /// shown at `times[0]` moved (and with `scale`, sized) like `boxes[0]` became `boxes[i]`. Path keys inside the
    /// tracked span are replaced. Returns the number of keys written (0: nothing changed).
    fn apply_mask_track_boxes(
        &mut self,
        id: Id,
        times: &[Time],
        boxes: &[Option<MaskTrackBox>],
        scale: bool,
        ids: &mut dyn IdSource,
    ) -> usize;
    /// Writes a tracked mask from motions (frame fractions, from the shape shown at `times[0]`): a path key at every time
    /// up to the first `None`; path keys inside the tracked span are replaced. Returns the number of keys written.
    fn apply_mask_track_motions(
        &mut self,
        id: Id,
        times: &[Time],
        motions: &[Option<MaskMotion>],
        ids: &mut dyn IdSource,
    ) -> usize;
    /// Indices of `times` (not the first) holding a key the user set: a key in a run of 3 or more consecutive visited
    /// frames is an earlier tracking result, not an anchor (re-tracking replaces it).
    #[doc(hidden)]
    fn mask_track_anchors(&self, id: Id, times: &[Time]) -> Vec<usize>;
    /// Index ranges of `times` a track runs in, split at the anchors: an anchor ends one range and starts the next (they
    /// share that index). Without anchors: one range.
    fn mask_track_segments(&self, id: Id, times: &[Time]) -> Vec<Range<usize>>;
    /// Writes a track made per `mask_track_segments` range. `motions[s]` belongs to `segments[s]` (one per frame, from
    /// the shape shown at the range's first frame; `None` = lost). A range that ends on an anchor key is pulled onto it:
    /// the error between where the tracker ended and the key is spread linearly over the range. A lost frame ends the run
    /// (later ranges are not written). Keys inside the written span are replaced. Returns the number of keys written.
    fn apply_mask_track_segments(
        &mut self,
        id: Id,
        times: &[Time],
        segments: &[Range<usize>],
        motions: &[Vec<Option<MaskMotion>>],
        ids: &mut dyn IdSource,
    ) -> usize;
}

/// Replaces the path keys in `lo...hi` by `written`.
fn replace_keys(clip: &mut Clip, id: Id, written: Vec<(Time, MaskPath)>, ids: &mut dyn IdSource) -> usize {
    let (Some(lo), Some(hi)) = (written.iter().map(|w| w.0).min(), written.iter().map(|w| w.0).max()) else {
        return 0;
    };
    let count = written.len();
    clip.update_mask(id, |m| {
        let doomed: Vec<Id> = m.path.track.keys.iter().filter(|k| k.time >= lo && k.time <= hi).map(|k| k.id).collect();
        for k in doomed {
            m.path.track.remove(k);
        }
        for (t, p) in written {
            m.path.track.insert(Keyframe::new(ids.next_id(), t, p));
        }
    });
    count
}

impl MaskTrackingExt for Clip {
    fn insert_mask_vertex(&mut self, id: Id, segment: usize, t: f64) {
        self.update_mask(id, |m| {
            m.path.value = m.path.value.splitting(segment, t);
            let updates: Vec<(Id, MaskPath)> = m
                .path
                .track
                .keys
                .iter()
                .filter(|k| k.value.vertices.len() > segment)
                .map(|k| (k.id, k.value.splitting(segment, t)))
                .collect();
            for (kid, v) in updates {
                m.path.track.set(kid, v);
            }
        });
    }

    fn place_mask_vertex(
        &mut self,
        id: Id,
        segment: usize,
        t: f64,
        handle: Vec2,
        independent: bool,
        local: Time,
        ids: &mut dyn IdSource,
    ) {
        self.insert_mask_vertex(id, segment, t);
        if handle == Vec2::ZERO {
            return;
        }
        let Some(m) = self.mask(id) else { return };
        let mut shown = m.path.value_at_local(local);
        if segment + 1 >= shown.vertices.len() {
            return;
        }
        shown.set_tangent(segment + 1, true, handle, independent);
        self.set_mask_path(id, shown, local, ids);
    }

    fn remove_mask_vertex(&mut self, id: Id, index: usize) -> bool {
        let Some(m) = self.mask(id) else { return false };
        let shapes: Vec<MaskPath> = if m.path.is_animated() {
            m.path.track.keys.iter().map(|k| k.value.clone()).collect()
        } else {
            vec![m.path.value.clone()]
        };
        if !shapes.iter().all(|s| s.removing_vertex(index).is_some()) {
            return false;
        }
        self.update_mask(id, |m| {
            if let Some(v) = m.path.value.removing_vertex(index) {
                m.path.value = v;
            }
            let updates: Vec<(Id, MaskPath)> =
                m.path.track.keys.iter().filter_map(|k| k.value.removing_vertex(index).map(|r| (k.id, r))).collect();
            for (kid, r) in updates {
                m.path.track.set(kid, r);
            }
        });
        true
    }

    fn mask_track_times(&self, l0: Time, forward: bool, fd: Time) -> Vec<Time> {
        if !(fd > Time::ZERO && l0 >= Time::ZERO && l0 < self.duration()) {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut t = l0;
        while t >= Time::ZERO && t < self.duration() {
            out.push(t);
            t = if forward { t + fd } else { t - fd };
        }
        out
    }

    fn apply_mask_track_boxes(
        &mut self,
        id: Id,
        times: &[Time],
        boxes: &[Option<MaskTrackBox>],
        scale: bool,
        ids: &mut dyn IdSource,
    ) -> usize {
        let Some(b0) = boxes.first().copied().flatten() else { return 0 };
        let motions: Vec<Option<MaskMotion>> =
            boxes.iter().map(|b| b.map(|b| MaskMotion::from_boxes(&b0, &b, scale))).collect();
        self.apply_mask_track_motions(id, times, &motions, ids)
    }

    fn apply_mask_track_motions(
        &mut self,
        id: Id,
        times: &[Time],
        motions: &[Option<MaskMotion>],
        ids: &mut dyn IdSource,
    ) -> usize {
        let Some(m) = self.mask(id) else { return 0 };
        let (Some(first), true) = (times.first(), motions.first().is_some_and(|m| m.is_some())) else { return 0 };
        let base = m.path.value_at_local(*first);
        let mut written: Vec<(Time, MaskPath)> = Vec::new();
        for (t, h) in times.iter().zip(motions) {
            let Some(h) = h else { break };
            written.push((*t, base.transformed(h)));
        }
        replace_keys(self, id, written, ids)
    }

    fn mask_track_anchors(&self, id: Id, times: &[Time]) -> Vec<usize> {
        let Some(m) = self.mask(id) else { return Vec::new() };
        if times.is_empty() {
            return Vec::new();
        }
        let keyed: BTreeSet<Time> = m.path.track.keys.iter().map(|k| k.time).collect();
        let has: Vec<bool> = times.iter().map(|t| keyed.contains(t)).collect();
        let mut anchors = Vec::new();
        let mut i = 0;
        while i < times.len() {
            if !has[i] {
                i += 1;
                continue;
            }
            let mut j = i;
            while j + 1 < times.len() && has[j + 1] {
                j += 1;
            }
            if j - i < 2 && i > 0 {
                anchors.push(i);
            }
            i = j + 1;
        }
        anchors
    }

    fn mask_track_segments(&self, id: Id, times: &[Time]) -> Vec<Range<usize>> {
        if times.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut lo = 0;
        for a in self.mask_track_anchors(id, times) {
            out.push(lo..a + 1);
            lo = a;
        }
        if lo + 1 < times.len() || out.is_empty() {
            out.push(lo..times.len());
        }
        out
    }

    fn apply_mask_track_segments(
        &mut self,
        id: Id,
        times: &[Time],
        segments: &[Range<usize>],
        motions: &[Vec<Option<MaskMotion>>],
        ids: &mut dyn IdSource,
    ) -> usize {
        let Some(m) = self.mask(id) else { return 0 };
        if segments.len() != motions.len() {
            return 0;
        }
        let anchors: BTreeSet<usize> = self.mask_track_anchors(id, times).into_iter().collect();
        let mut written: Vec<(Time, MaskPath)> = Vec::new();
        for (si, (seg, ms)) in segments.iter().zip(motions).enumerate() {
            if ms.len() != seg.len() || !ms.first().is_some_and(|m| m.is_some()) {
                break;
            }
            let base = m.path.value_at_local(times[seg.start]);
            let mut path: Vec<MaskPath> = ms.iter().filter_map(|h| h.as_ref().map(|h| base.transformed(h))).collect();
            let lost = path.len() < ms.len();
            if !lost && anchors.contains(&(seg.end - 1)) && path.len() > 1 {
                let end = path[path.len() - 1].clone();
                let target = m.path.value_at_local(times[seg.end - 1]);
                let n = (path.len() - 1) as f64;
                for (k, p) in path.iter_mut().enumerate() {
                    *p = p.corrected(&end, &target, k as f64 / n);
                }
            }
            // A range after the first starts on the anchor the one before ended on (already written).
            for (k, p) in path.into_iter().enumerate() {
                if si == 0 || k > 0 {
                    written.push((times[seg.start + k], p));
                }
            }
            if lost {
                break;
            }
        }
        replace_keys(self, id, written, ids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mask_motion::{MaskMotionFit, MaskTrackMode};
    use sq_core_time::IdSource;

    use crate::test_util::{SplitMix, test_clip};
    use sq_core_model::{AnimatedProperty, ClipMask, MaskShapeKind};
    use sq_core_time::SequentialIds;

    fn v(x: f64, y: f64) -> Vec2 {
        Vec2::new(x, y)
    }
    fn rect(a: (f64, f64), b: (f64, f64)) -> MaskPath {
        MaskPath::rectangle(v(a.0, a.1), v(b.0, b.1))
    }
    fn ellipse(r: f64) -> MaskPath {
        MaskPath::ellipse(v(0.5, 0.5), v(r, r))
    }
    fn close(a: Vec2, b: Vec2) -> bool {
        (a - b).length() < 1e-9
    }
    fn near(a: Vec2, b: Vec2, tol: f64) -> bool {
        (a - b).length() < tol
    }
    fn t(n: i64, d: i64) -> Time {
        Time::new(n, d)
    }
    fn clip_with(m: sq_core_model::ClipMask) -> (Clip, Id) {
        let id = m.id;
        let mut c = test_clip();
        c.set_masks(vec![m]);
        (c, id)
    }
    fn key(ids: &mut SequentialIds, time: Time, p: MaskPath) -> Keyframe<MaskPath> {
        Keyframe::new(ids.next_id(), time, p)
    }

    #[test]
    fn splitting_a_straight_segment_adds_a_corner_on_the_line() {
        let p = rect((0.0, 0.0), (1.0, 1.0)).splitting(0, 0.25);
        assert_eq!(p.vertices.len(), 5);
        assert!(close(p.vertices[1].point, v(0.25, 0.0)));
        assert!(is_corner(&p.vertices[1]));
        assert_eq!(p.polygon().len(), 5);
    }

    #[test]
    fn splitting_a_curve_keeps_its_shape() {
        let e = ellipse(0.2);
        let p = e.splitting(1, 0.5);
        assert_eq!(p.vertices.len(), 5);
        assert!(((p.vertices[2].point - v(0.5, 0.5)).length() - 0.2).abs() < 0.001);
        for q in p.polygon() {
            assert!(((q - v(0.5, 0.5)).length() - 0.2).abs() < 0.001);
        }
        assert!(close(p.vertices[1].out_tangent, e.vertices[1].out_tangent * 0.5));
        assert!(close(p.vertices[3].in_tangent, e.vertices[2].in_tangent * 0.5));
    }

    #[test]
    fn splitting_the_closing_segment_appends_at_the_end() {
        let p = rect((0.0, 0.0), (1.0, 1.0)).splitting(3, 0.5);
        assert_eq!(p.vertices.len(), 5);
        assert!(close(p.vertices[4].point, v(0.0, 0.5)));
        assert!(close(p.vertices[0].point, v(0.0, 0.0)));
    }

    #[test]
    fn nearest_segment_finds_the_edge_under_the_pointer() {
        let p = rect((0.25, 0.25), (0.75, 0.75));
        let hit = p.nearest_segment(v(0.5, 0.26), v(100.0, 100.0));
        let hit = hit.unwrap_or(NearestSegment { segment: 99, t: 0.0, distance: 0.0 });
        assert_eq!(hit.segment, 0);
        assert!((hit.t - 0.5).abs() < 0.01);
        assert!((hit.distance - 1.0).abs() < 0.01);
        let right = p.nearest_segment(v(0.76, 0.375), v(100.0, 100.0)).unwrap_or(hit);
        assert!(right.segment == 1 && (right.t - 0.25).abs() < 0.01);
    }

    #[test]
    fn removing_a_vertex_keeps_at_least_three() {
        let r = rect((0.0, 0.0), (1.0, 1.0));
        let three = r.removing_vertex(1);
        assert_eq!(three.as_ref().map(|p| p.vertices.len()), Some(3));
        assert!(three.and_then(|p| p.removing_vertex(0)).is_none());
        assert!(r.removing_vertex(9).is_none());
    }

    #[test]
    fn toggling_smooth_gives_tangents_along_the_neighbours_and_back() {
        let r = rect((0.0, 0.0), (1.0, 1.0));
        let s = r.toggling_smooth(0);
        let vx = s.vertices[0];
        assert!(!is_corner(&vx));
        assert!((vx.out_tangent.x + vx.in_tangent.x).abs() < 1e-9 && (vx.out_tangent.y + vx.in_tangent.y).abs() < 1e-9);
        assert!(vx.out_tangent.x > 0.0 && vx.out_tangent.y < 0.0);
        assert!(is_corner(&s.toggling_smooth(0).vertices[0]));
    }

    #[test]
    fn dragging_a_tangent_mirrors_unless_independent() {
        let mut p = ellipse(0.2);
        p.set_tangent(0, true, v(0.3, 0.1), false);
        assert_eq!(p.vertices[0].out_tangent, v(0.3, 0.1));
        assert!(close(p.vertices[0].in_tangent, v(-0.3, -0.1)));
        p.set_tangent(0, false, v(0.0, 0.2), true);
        assert!(p.vertices[0].in_tangent == v(0.0, 0.2) && p.vertices[0].out_tangent == v(0.3, 0.1));
    }

    #[test]
    fn inserting_a_vertex_changes_every_key_so_they_still_blend() {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        m.path.track.insert(key(&mut ids, Time::ZERO, rect((0.0, 0.0), (0.5, 0.5))));
        m.path.track.insert(key(&mut ids, t(2, 1), rect((0.5, 0.5), (1.0, 1.0))));
        let (mut c, id) = clip_with(m);
        c.insert_mask_vertex(id, 0, 0.5);
        let mask = |c: &Clip| {
            c.mask(id).cloned().unwrap_or_else(|| {
                ClipMask::make(IdSource::next_id(&mut SequentialIds::default()), MaskShapeKind::Ellipse, "x")
            })
        };
        assert!(mask(&c).path.track.keys.iter().all(|k| k.value.vertices.len() == 5));
        let mid = mask(&c).path.value_at_local(t(1, 1));
        assert!(close(mid.vertices[1].point, v(0.5, 0.25)));
        assert!(c.remove_mask_vertex(id, 1));
        assert!(mask(&c).path.track.keys.iter().all(|k| k.value.vertices.len() == 4));
    }

    #[test]
    fn inserting_into_a_static_path_changes_the_value() {
        let mut ids = SequentialIds::default();
        let (mut c, id) = clip_with(ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M"));
        c.insert_mask_vertex(id, 2, 0.5);
        assert_eq!(c.mask(id).map(|m| m.path.value.vertices.len()), Some(5));
        assert_eq!(c.mask(id).map(|m| m.path.is_animated()), Some(false));
    }

    #[test]
    fn placing_a_vertex_without_a_drag_is_a_plain_split() {
        let r = rect((0.0, 0.0), (1.0, 1.0));
        assert_eq!(r.placing_vertex(0, 0.5, Vec2::ZERO, false), r.splitting(0, 0.5));
    }

    #[test]
    fn dragging_while_placing_pulls_mirrored_handles_and_option_breaks_them() {
        let r = rect((0.0, 0.0), (1.0, 1.0));
        let p = r.placing_vertex(0, 0.5, v(0.2, -0.1), false);
        assert_eq!(p.vertices.len(), 5);
        assert!(close(p.vertices[1].point, v(0.5, 0.0)));
        assert!(close(p.vertices[1].out_tangent, v(0.2, -0.1)) && close(p.vertices[1].in_tangent, v(-0.2, 0.1)));
        let q = r.placing_vertex(0, 0.5, v(0.2, -0.1), true);
        assert!(close(q.vertices[1].out_tangent, v(0.2, -0.1)) && q.vertices[1].in_tangent == Vec2::ZERO);
    }

    #[test]
    fn placing_a_vertex_on_a_clip_adds_it_to_every_key_and_shapes_the_shown_path() {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        m.path.track.insert(key(&mut ids, Time::ZERO, rect((0.0, 0.0), (0.5, 0.5))));
        m.path.track.insert(key(&mut ids, t(2, 1), rect((0.5, 0.5), (1.0, 1.0))));
        let (mut c, id) = clip_with(m);
        c.place_mask_vertex(id, 0, 0.5, v(0.1, 0.0), false, Time::ZERO, &mut ids);
        let mut keys = c.mask(id).map(|m| m.path.track.keys.clone()).unwrap_or_default();
        keys.sort_by_key(|k| k.time);
        assert!(keys.iter().all(|k| k.value.vertices.len() == 5));
        assert!(close(keys[0].value.vertices[1].out_tangent, v(0.1, 0.0)));
        assert!(is_corner(&keys[1].value.vertices[1])); // other keys only get the point
    }

    #[test]
    fn bounds_and_tracked_path_follow_the_box() {
        let p = rect((0.2, 0.2), (0.4, 0.6));
        let b = p.bounds();
        assert!(close(b.center, v(0.3, 0.4)) && close(b.size, v(0.2, 0.4)));
        let target = MaskTrackBox { center: v(0.5, 0.5), size: v(0.4, 0.4) };
        let moved = p.tracked(&b, &target, true);
        assert!(close(moved.vertices[0].point, v(0.3, 0.3)));
        assert!(close(moved.vertices[2].point, v(0.7, 0.7)));
        let shifted = p.tracked(&b, &target, false);
        assert!(close(shifted.vertices[0].point, v(0.4, 0.3)));
    }

    #[test]
    fn track_times_step_frames_to_the_clip_edge() {
        let c = test_clip();
        let fd = t(1, 2);
        assert_eq!(c.mask_track_times(t(3, 1), true, fd), vec![t(3, 1), t(7, 2)]);
        assert_eq!(c.mask_track_times(t(1, 1), false, fd), vec![t(1, 1), t(1, 2), Time::ZERO]);
        assert!(c.mask_track_times(t(9, 1), true, fd).is_empty());
    }

    #[test]
    fn applying_a_track_keys_every_frame_and_replaces_keys_in_the_span() {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        let start = rect((0.1, 0.1), (0.3, 0.3));
        m.path = AnimatedProperty::new(start.clone());
        m.path.track.insert(key(&mut ids, t(1, 2), rect((0.8, 0.8), (0.9, 0.9)))); // replaced
        m.path.track.insert(key(&mut ids, t(3, 1), start)); // kept (outside)
        let (mut c, id) = clip_with(m);
        let times = [Time::ZERO, t(1, 2), t(1, 1), t(3, 2)];
        let bx = |x: f64| Some(MaskTrackBox { center: v(x, 0.2), size: v(0.2, 0.2) });
        let boxes = [bx(0.2), bx(0.3), bx(0.4), None];
        let n = c.apply_mask_track_boxes(id, &times, &boxes, true, &mut ids);
        assert_eq!(n, 3);
        let mut keys = c.mask(id).map(|m| m.path.track.keys.clone()).unwrap_or_default();
        keys.sort_by_key(|k| k.time);
        assert_eq!(keys.iter().map(|k| k.time).collect::<Vec<_>>(), vec![Time::ZERO, t(1, 2), t(1, 1), t(3, 1)]);
        let shown0 = keys[0].value.clone();
        assert!(close(keys[1].value.vertices[0].point, shown0.vertices[0].point + v(0.1, 0.0)));
        assert!(close(keys[2].value.vertices[0].point, shown0.vertices[0].point + v(0.2, 0.0)));
    }

    #[test]
    fn applying_a_track_without_results_changes_nothing() {
        let mut ids = SequentialIds::default();
        let (mut c, id) = clip_with(ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M"));
        let before = c.clone();
        assert_eq!(c.apply_mask_track_boxes(id, &[Time::ZERO], &[None], true, &mut ids), 0);
        assert_eq!(c, before);
    }

    #[test]
    fn backward_track_keys_only_the_tracked_span() {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        let value = m.path.value.clone();
        m.path.track.insert(key(&mut ids, t(3, 1), value));
        let (mut c, id) = clip_with(m);
        let b = c
            .mask(id)
            .map(|m| m.path.value_at_local(t(1, 1)).bounds())
            .unwrap_or(MaskTrackBox { center: Vec2::ZERO, size: Vec2::ZERO });
        let n = c.apply_mask_track_boxes(id, &[t(1, 1), t(1, 2)], &[Some(b), Some(b)], false, &mut ids);
        assert_eq!(n, 2);
        let mut times: Vec<Time> =
            c.mask(id).map(|m| m.path.track.keys.iter().map(|k| k.time).collect()).unwrap_or_default();
        times.sort();
        assert_eq!(times, vec![t(1, 2), t(1, 1), t(3, 1)]);
    }

    // Long-track drift (MaskReAnchorTests).

    fn square(x: f64) -> MaskPath {
        rect((x, 0.4), (x + 0.2, 0.6))
    }

    /// 3 s clip at 10 fps; a mask whose path has a key (frame, left edge x) per entry.
    fn anchored(keys: &[(i64, f64)]) -> (Clip, Id, SequentialIds) {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        m.path = AnimatedProperty::new(square(0.1));
        for (f, x) in keys {
            m.path.track.insert(key(&mut ids, t(*f, 10), square(*x)));
        }
        let (mut c, id) = clip_with(m);
        c.source = sq_core_time::TimeRange::new(Time::ZERO, t(3, 1));
        c.start = Time::ZERO;
        (c, id, ids)
    }
    fn times(n: i64) -> Vec<Time> {
        (0..n).map(|i| t(i, 10)).collect()
    }
    fn shift(dx: f64) -> Option<MaskMotion> {
        Some(MaskMotion::translation(v(dx, 0.0)))
    }
    fn sorted_keys(c: &Clip, id: Id) -> Vec<Keyframe<MaskPath>> {
        let mut keys = c.mask(id).map(|m| m.path.track.keys.clone()).unwrap_or_default();
        keys.sort_by_key(|k| k.time);
        keys
    }

    #[test]
    fn no_keys_is_one_segment() {
        let (c, id, _) = anchored(&[]);
        assert_eq!(c.mask_track_segments(id, &times(10)), vec![0..10]);
    }

    #[test]
    fn a_lone_key_splits_the_track() {
        let (c, id, _) = anchored(&[(5, 0.5)]);
        assert_eq!(c.mask_track_segments(id, &times(10)), vec![0..6, 5..10]);
    }

    #[test]
    fn a_tracked_run_is_not_an_anchor() {
        let keys: Vec<(i64, f64)> = (2..=8).map(|i| (i, i as f64 / 10.0)).collect();
        let (c, id, _) = anchored(&keys);
        assert_eq!(c.mask_track_segments(id, &times(10)), vec![0..10]);
    }

    #[test]
    fn backward_track_splits_in_visit_order() {
        let (c, id, _) = anchored(&[(4, 0.4)]);
        let mut ts = times(10);
        ts.reverse();
        assert_eq!(c.mask_track_segments(id, &ts), vec![0..6, 5..10]);
    }

    #[test]
    fn end_error_is_spread_over_the_stretch() {
        let (mut c, id, mut ids) = anchored(&[(0, 0.1), (5, 0.5)]);
        let ts = times(6);
        let segs = c.mask_track_segments(id, &ts);
        assert_eq!(segs, vec![0..6]);
        let motions = vec![(0..6).map(|i| shift(0.04 * f64::from(i))).collect::<Vec<_>>()];
        assert_eq!(c.apply_mask_track_segments(id, &ts, &segs, &motions, &mut ids), 6);
        let keys = sorted_keys(&c, id);
        assert_eq!(keys.len(), 6);
        assert!(near(keys[0].value.vertices[0].point, v(0.1, 0.4), 1e-6));
        assert!(near(keys[3].value.vertices[0].point, v(0.1 + 0.12 + 0.2 * 3.0 / 5.0, 0.4), 1e-6));
        assert!(near(keys[5].value.vertices[0].point, v(0.5, 0.4), 1e-6));
    }

    #[test]
    fn each_segment_starts_from_its_anchor_and_chains() {
        let (mut c, id, mut ids) = anchored(&[(0, 0.1), (3, 0.3)]);
        let ts = times(7);
        let segs = c.mask_track_segments(id, &ts);
        assert_eq!(segs, vec![0..4, 3..7]);
        let a: Vec<_> = (0..4).map(|i| shift(0.1 * f64::from(i))).collect();
        let b: Vec<_> = (0..4).map(|i| shift(0.01 * f64::from(i))).collect();
        assert_eq!(c.apply_mask_track_segments(id, &ts, &segs, &[a, b], &mut ids), 7);
        let keys = sorted_keys(&c, id);
        assert!(near(keys[3].value.vertices[0].point, v(0.3, 0.4), 1e-6)); // pulled onto the anchor
        assert!(near(keys[6].value.vertices[0].point, v(0.33, 0.4), 1e-6)); // last stretch has no end anchor: raw
    }

    #[test]
    fn lost_object_stops_the_whole_run() {
        let (mut c, id, mut ids) = anchored(&[(0, 0.1), (3, 0.3)]);
        let ts = times(7);
        let segs = c.mask_track_segments(id, &ts);
        let a = vec![Some(MaskMotion::IDENTITY), shift(0.01), None, None];
        let b = vec![Some(MaskMotion::IDENTITY); 4];
        assert_eq!(c.apply_mask_track_segments(id, &ts, &segs, &[a, b], &mut ids), 2); // frames 0 and 1 only
    }

    // Motion model and fits (MaskMotionTests).

    /// Ground truth: rotate by `deg` and scale by `s` about `c`, then move by `t` (pixel space).
    fn similarity(p: Vec2, deg: f64, s: f64, c: Vec2, tr: Vec2) -> Vec2 {
        let a = deg * std::f64::consts::PI / 180.0;
        let d = p - c;
        c + tr + v((a.cos() * d.x - a.sin() * d.y) * s, (a.sin() * d.x + a.cos() * d.y) * s)
    }

    fn grid(lo: Vec2, hi: Vec2, n: usize) -> Vec<Vec2> {
        let mut out = Vec::new();
        for i in 0..n {
            for j in 0..n {
                out.push(v(
                    lo.x + (hi.x - lo.x) * i as f64 / (n - 1) as f64,
                    lo.y + (hi.y - lo.y) * j as f64 / (n - 1) as f64,
                ));
            }
        }
        out
    }

    #[test]
    fn motion_applies_composes_and_inverts() {
        let tr = MaskMotion::translation(v(3.0, -2.0));
        let r = MaskMotion::rotation(std::f64::consts::PI / 2.0, v(1.0, 1.0));
        assert!(near(tr.apply(v(1.0, 1.0)), v(4.0, -1.0), 1e-6));
        assert!(near(r.apply(v(2.0, 1.0)), v(1.0, 2.0), 1e-6)); // y down: +90 deg turns +x into +y
        let both = tr.then(&r);
        assert!(near(both.apply(v(0.0, 0.0)), r.apply(tr.apply(v(0.0, 0.0))), 1e-6));
        let inv = both.inverse().unwrap_or(MaskMotion::IDENTITY);
        assert!(near(inv.apply(both.apply(v(5.0, 7.0))), v(5.0, 7.0), 1e-6));
        assert!(near(MaskMotion::IDENTITY.apply(v(0.3, 0.4)), v(0.3, 0.4), 1e-6));
    }

    #[test]
    fn pixel_motion_maps_to_frame_fractions() {
        let px = MaskMotion::rotation(0.3, v(960.0, 540.0));
        let f = px.in_fractions(1920.0, 1080.0);
        let p = v(0.7, 0.2);
        let via_px = px.apply(v(p.x * 1920.0, p.y * 1080.0));
        assert!(near(f.apply(p), v(via_px.x / 1920.0, via_px.y / 1080.0), 1e-9));
        assert!(near(f.in_pixels(1920.0, 1080.0).apply(v(100.0, 50.0)), px.apply(v(100.0, 50.0)), 1e-6));
    }

    #[test]
    fn box_motion_matches_the_old_box_tracking() {
        let p = rect((0.2, 0.2), (0.4, 0.6));
        let a = p.bounds();
        let b = MaskTrackBox { center: v(0.5, 0.5), size: v(0.4, 0.4) };
        for scale in [true, false] {
            let old = p.tracked(&a, &b, scale);
            let new = p.transformed(&MaskMotion::from_boxes(&a, &b, scale));
            for (o, n) in old.vertices.iter().zip(&new.vertices) {
                assert!(
                    near(o.point, n.point, 1e-6)
                        && near(o.in_tangent, n.in_tangent, 1e-6)
                        && near(o.out_tangent, n.out_tangent, 1e-6)
                );
            }
        }
    }

    #[test]
    fn fits_each_mode_exactly_from_clean_points() {
        let src = grid(v(100.0, 80.0), v(220.0, 200.0), 6);
        let c = v(160.0, 140.0);
        let tr = v(12.0, -7.0);
        let dst: Vec<Vec2> = src.iter().map(|p| similarity(*p, 17.0, 1.12, c, tr)).collect();
        let rot = MaskMotionFit::fit(&src, &dst, MaskTrackMode::Rotation);
        let Some(rot) = rot else { panic!("no rotation fit") };
        for (s, d) in src.iter().zip(&dst) {
            assert!(near(rot.motion.apply(*s), *d, 1e-6));
        }
        assert!(rot.rms < 1e-6 && rot.inliers == src.len());
        let Some(pos) = MaskMotionFit::fit(&src, &dst, MaskTrackMode::Position) else { panic!("no position fit") };
        assert!(near(pos.motion.apply(c), c + tr, 1e-6));
        assert!(near(pos.motion.apply(v(0.0, 0.0)) - pos.motion.apply(v(1.0, 0.0)), v(-1.0, 0.0), 1e-9));
        let scaled: Vec<Vec2> = src.iter().map(|p| similarity(*p, 0.0, 0.8, c, tr)).collect();
        let Some(sc) = MaskMotionFit::fit(&src, &scaled, MaskTrackMode::Scale) else { panic!("no scale fit") };
        assert!(near(sc.motion.apply(v(220.0, 200.0)), similarity(v(220.0, 200.0), 0.0, 0.8, c, tr), 1e-6));
        let h = MaskMotion { m: [1.05, 0.08, 4.0, -0.03, 0.97, 9.0, 0.0004, -0.0002, 1.0] };
        let warped: Vec<Vec2> = src.iter().map(|p| h.apply(*p)).collect();
        let Some(persp) = MaskMotionFit::fit(&src, &warped, MaskTrackMode::Perspective) else {
            panic!("no perspective fit")
        };
        for s in &src {
            assert!(near(persp.motion.apply(*s), h.apply(*s), 1e-5));
        }
    }

    #[test]
    fn robust_fit_ignores_outliers() {
        let mut rng = SplitMix::new(7);
        let src = grid(v(0.0, 0.0), v(200.0, 120.0), 8);
        let mut dst: Vec<Vec2> = src.iter().map(|p| similarity(*p, -9.0, 1.0, v(100.0, 60.0), v(5.0, 3.0))).collect();
        // Small noise on all, 15 % gross outliers (background flow leaking into the region).
        for d in &mut dst {
            *d = *d + v(rng.unit() * 0.2, rng.unit() * 0.2);
        }
        for i in (0..dst.len()).step_by(7) {
            dst[i] = dst[i] + v(40.0 * rng.unit(), 40.0 * rng.unit());
        }
        for mode in [MaskTrackMode::Rotation, MaskTrackMode::Perspective] {
            let Some(fit) = MaskMotionFit::fit(&src, &dst, mode) else { panic!("no fit for {mode:?}") };
            for p in [v(0.0, 0.0), v(200.0, 120.0), v(0.0, 120.0)] {
                let truth = similarity(p, -9.0, 1.0, v(100.0, 60.0), v(5.0, 3.0));
                assert!((fit.motion.apply(p) - truth).length() < 0.5, "mode {mode:?}");
            }
            assert!(fit.inliers < src.len());
        }
    }

    #[test]
    fn fit_needs_enough_points() {
        let p = [v(0.0, 0.0), v(1.0, 0.0), v(0.0, 1.0)];
        assert!(MaskMotionFit::fit(&p, &p, MaskTrackMode::Perspective).is_none());
        assert!(MaskMotionFit::fit(&[], &[], MaskTrackMode::Position).is_none());
        assert!(
            MaskMotionFit::fit(&[v(1.0, 1.0), v(1.0, 1.0)], &[v(2.0, 2.0), v(2.0, 2.0)], MaskTrackMode::Rotation)
                .is_none()
        );
    }

    #[test]
    fn sample_points_stay_inside_the_polygon() {
        let tri = [v(0.0, 0.0), v(100.0, 0.0), v(0.0, 100.0)];
        let pts = MaskMotionFit::sample_points(&tri, 10.0, 400);
        assert!(pts.len() > 30 && pts.len() < 60);
        assert!(pts.iter().all(|p| p.x + p.y < 100.0 && p.x > 0.0 && p.y > 0.0));
        assert!(MaskMotionFit::sample_points(&tri, 10.0, 12).len() <= 12);
    }

    #[test]
    fn transformed_path_rotates_points_and_tangents() {
        let p = ellipse(0.2);
        let r = p.transformed(&MaskMotion::rotation(std::f64::consts::PI / 2.0, v(0.5, 0.5)));
        for (a, b) in p.vertices.iter().zip(&r.vertices) {
            let d = a.point - v(0.5, 0.5);
            assert!(near(b.point, v(0.5 - d.y, 0.5 + d.x), 1e-6));
            assert!(near(b.out_tangent, v(-a.out_tangent.y, a.out_tangent.x), 1e-6));
        }
    }

    #[test]
    fn applying_motions_keys_turned_shapes() {
        let mut ids = SequentialIds::default();
        let mut m = ClipMask::make(ids.next_id(), MaskShapeKind::Rectangle, "M");
        m.path = AnimatedProperty::new(rect((0.4, 0.4), (0.6, 0.6)));
        let (mut c, id) = clip_with(m);
        let turn = MaskMotion::rotation(std::f64::consts::PI / 4.0, v(0.5, 0.5));
        let n = c.apply_mask_track_motions(
            id,
            &[Time::ZERO, t(1, 2), t(1, 1)],
            &[Some(MaskMotion::IDENTITY), Some(turn), None],
            &mut ids,
        );
        assert_eq!(n, 2);
        let keys = sorted_keys(&c, id);
        assert_eq!(keys.len(), 2);
        assert!(near(keys[1].value.vertices[0].point, turn.apply(v(0.4, 0.4)), 1e-6));
    }

    #[test]
    fn mode_titles_and_point_use() {
        let titles: Vec<&str> = MaskTrackMode::ALL.iter().map(|m| m.title()).collect();
        assert_eq!(titles, vec!["Position", "+ Scale", "+ Rotation", "Perspective"]);
        assert!(!MaskTrackMode::Position.uses_points() && !MaskTrackMode::Scale.uses_points());
        assert!(MaskTrackMode::Rotation.uses_points() && MaskTrackMode::Perspective.uses_points());
        assert_eq!(MaskTrackMode::DEFAULT, MaskTrackMode::Scale);
    }
}
