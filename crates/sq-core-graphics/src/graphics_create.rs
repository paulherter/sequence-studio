// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Graphics+Create.swift (logic only; saved types live in `sq-core-model`)

use crate::graphics_editing::GraphicsRect;
use sq_core_model::{AnimatedProperty, ClipEffect, GraphicsLayer, ShapeKind, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, Vec2};
use std::collections::BTreeSet;

/// Geometry of a Create tool drag (Rectangle, Ellipse, Line) in any flat space with y down.
pub struct CreateDrag;

impl CreateDrag {
    /// The box a drag from `a` to `b` spans. `square`: both sides take the longer one (square / circle). `from_center`: `a`
    /// is the box's center instead of a corner.
    pub fn box_from(a: Vec2, b: Vec2, square: bool, from_center: bool) -> GraphicsRect {
        let mut d = b - a;
        if square {
            let side = d.x.abs().max(d.y.abs());
            d = Vec2::new(if d.x < 0.0 { -side } else { side }, if d.y < 0.0 { -side } else { side });
        }
        let p = if from_center { a - d } else { a };
        let q = a + d;
        GraphicsRect { min_x: p.x.min(q.x), min_y: p.y.min(q.y), max_x: p.x.max(q.x), max_y: p.y.max(q.y) }
    }

    /// The two ends of a line dragged from `a` to `b`. `constrain`: the direction snaps to 45 degree steps, the length
    /// stays. `from_center`: the line grows the same way on both sides of `a`.
    pub fn line(a: Vec2, b: Vec2, constrain: bool, from_center: bool) -> (Vec2, Vec2) {
        let mut d = b - a;
        if constrain && d.length() > 0.0 {
            let step = std::f64::consts::FRAC_PI_4;
            let angle = (d.y.atan2(d.x) / step).round() * step;
            let unit = Vec2::new(angle.cos(), angle.sin());
            // Exact axes and diagonals: no float noise in the snapped direction.
            let clean = Vec2::new(
                if unit.x.abs() < 1e-9 { 0.0 } else { unit.x },
                if unit.y.abs() < 1e-9 { 0.0 } else { unit.y },
            );
            d = clean * d.length();
        }
        (if from_center { a - d } else { a }, a + d)
    }
}

/// A hand-drawn stroke made calm: smoothed, then reduced to the points that carry its shape.
pub struct PathSmoothing;

impl PathSmoothing {
    /// `points` smoothed (one 1-2-1 pass, ends kept) and reduced (Ramer-Douglas-Peucker): no smoothed point lies farther
    /// than `tolerance` from the result. The first and last point are kept as recorded.
    pub fn smooth(points: &[Vec2], tolerance: f64) -> Vec<Vec2> {
        if points.len() <= 2 {
            return points.to_vec();
        }
        let mut soft = points.to_vec();
        for i in 1..points.len() - 1 {
            soft[i] = Vec2::new(
                (points[i - 1].x + 2.0 * points[i].x + points[i + 1].x) / 4.0,
                (points[i - 1].y + 2.0 * points[i].y + points[i + 1].y) / 4.0,
            );
        }
        let mut keep = vec![false; soft.len()];
        keep[0] = true;
        keep[soft.len() - 1] = true;
        let mut stack = vec![(0, soft.len() - 1)];
        while let Some((lo, hi)) = stack.pop() {
            if hi <= lo + 1 {
                continue;
            }
            let (mut worst, mut at) = (0.0, lo);
            for (i, p) in soft.iter().enumerate().take(hi).skip(lo + 1) {
                let d = Self::distance(*p, soft[lo], soft[hi]);
                if d > worst {
                    worst = d;
                    at = i;
                }
            }
            if worst <= tolerance.max(0.0) {
                continue;
            }
            keep[at] = true;
            stack.push((lo, at));
            stack.push((at, hi));
        }
        soft.iter().zip(&keep).filter(|(_, k)| **k).map(|(p, _)| *p).collect()
    }

    /// Distance from `p` to the segment `a`-`b`.
    fn distance(p: Vec2, a: Vec2, b: Vec2) -> f64 {
        let d = b - a;
        let l2 = d.x * d.x + d.y * d.y;
        if l2 <= 0.0 {
            return (p - a).length();
        }
        let t = (((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2).clamp(0.0, 1.0);
        (p - (a + d * t)).length()
    }
}

/// Layers made from a Create tool drag.
pub trait GraphicsLayerCreateExt {
    /// A rectangle or ellipse filling `box_` (canvas px, offsets from the canvas center, y down), with the look a new shape
    /// of that kind starts with.
    fn shape_in_box(
        ids: &mut dyn IdSource,
        kind: ShapeKind,
        box_: GraphicsRect,
        canvas_width: i64,
        canvas_height: i64,
    ) -> GraphicsLayer;

    /// A line from `a` to `b` (canvas px, offsets from the canvas center): Width is its length, the layer's rotation its
    /// direction.
    fn line_between(ids: &mut dyn IdSource, a: Vec2, b: Vec2, canvas_width: i64, canvas_height: i64) -> GraphicsLayer;
}

impl GraphicsLayerCreateExt for GraphicsLayer {
    fn shape_in_box(
        ids: &mut dyn IdSource,
        kind: ShapeKind,
        box_: GraphicsRect,
        canvas_width: i64,
        canvas_height: i64,
    ) -> GraphicsLayer {
        let mut l = GraphicsLayer::shape(ids, kind, canvas_width, canvas_height);
        l.set_shape_size(box_.width().max(1.0), box_.height().max(1.0));
        l.animation.position = AnimatedProperty::new(Vec2::new(box_.mid_x(), box_.mid_y()));
        l
    }

    fn line_between(ids: &mut dyn IdSource, a: Vec2, b: Vec2, canvas_width: i64, canvas_height: i64) -> GraphicsLayer {
        let mut l = GraphicsLayer::shape(ids, ShapeKind::Line, canvas_width, canvas_height);
        let d = b - a;
        if let Some(e) = l.effects.iter_mut().find(|e| e.kind == ClipEffect::SHAPE_EFFECT_KIND) {
            e.parameters.insert(ClipEffect::SHAPE_WIDTH_KEY.to_string(), AnimatedProperty::new(d.length().max(1.0)));
        }
        l.animation.position = AnimatedProperty::new(Vec2::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0));
        l.animation.rotation = AnimatedProperty::new(d.y.atan2(d.x) * 180.0 / std::f64::consts::PI);
        l
    }
}

/// Which Graphic a Create tool adds to.
pub trait GraphicCreateTargetExt {
    /// The Graphic clip a Create tool adds its new item to at `time`: the single selected Graphic when the playhead is
    /// inside it, else the Graphic under the playhead on the topmost targeted video track. Locked tracks take nothing.
    /// `None`: a new Graphic clip is made.
    fn graphic_create_target(&self, selection: &BTreeSet<Id>, at: Time) -> Option<Id>;
}

impl GraphicCreateTargetExt for Timeline {
    fn graphic_create_target(&self, selection: &BTreeSet<Id>, at: Time) -> Option<Id> {
        fn graphic(track: &sq_core_model::Track, time: Time, pick: impl Fn(Id) -> bool) -> Option<Id> {
            if track.kind != TrackKind::Video || track.is_locked {
                return None;
            }
            track.clips().iter().find(|c| c.is_graphics() && c.timeline().contains(time) && pick(c.id)).map(|c| c.id)
        }
        if let (1, Some(id)) = (selection.len(), selection.iter().next().copied()) {
            for track in &self.tracks {
                if let Some(hit) = graphic(track, at, |c| c == id) {
                    return Some(hit);
                }
            }
        }
        for track in self.tracks.iter().rev().filter(|t| t.is_targeted) {
            if let Some(hit) = graphic(track, at, |_| true) {
                return Some(hit);
            }
        }
        None
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use sq_core_model::{GraphicsLayer, Project, SequenceFormat, ShapeKind, Timeline, Track, TrackKind};
    use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};

    pub fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// A project with one sequence of `kinds` tracks. Returns the project, the sequence id and the track ids.
    pub fn project(kinds: &[TrackKind], ids: &mut SequentialIds) -> (Project, Id, Vec<Id>) {
        let tracks: Vec<Track> = kinds.iter().map(|k| Track::new(ids.next_id(), *k)).collect();
        let track_ids = tracks.iter().map(|t| t.id).collect();
        let t = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), tracks);
        let tl = t.id;
        (Project::new(ids.next_id(), "P", Vec::new(), vec![t]), tl, track_ids)
    }

    /// A 1920 x 1080 rectangle layer.
    pub fn rect(ids: &mut SequentialIds, name: &str, range: Option<TimeRange>) -> GraphicsLayer {
        let mut l = GraphicsLayer::shape(ids, ShapeKind::Rectangle, 1920, 1080);
        l.name = name.to_string();
        l.range = range;
        l
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use crate::graphics_editing::ProjectGraphicsExt as _;
    use sq_core_model::project_media_ops::GeneratorPlacement;
    use sq_core_model::{EditError, GraphicsContent, GraphicsDocument};
    use sq_core_time::SequentialIds;

    #[test]
    fn box_spans_the_drag_in_any_direction() {
        let r = CreateDrag::box_from(Vec2::new(10.0, 20.0), Vec2::new(-30.0, 80.0), false, false);
        assert_eq!(r, GraphicsRect { min_x: -30.0, min_y: 20.0, max_x: 10.0, max_y: 80.0 });
    }

    #[test]
    fn shift_makes_a_square_on_the_longer_side() {
        let r = CreateDrag::box_from(Vec2::new(0.0, 0.0), Vec2::new(-40.0, 100.0), true, false);
        assert_eq!(r, GraphicsRect { min_x: -100.0, min_y: 0.0, max_x: 0.0, max_y: 100.0 });
    }

    #[test]
    fn option_draws_from_the_center() {
        let (a, b) = (Vec2::new(50.0, 50.0), Vec2::new(80.0, 60.0));
        assert_eq!(
            CreateDrag::box_from(a, b, false, true),
            GraphicsRect { min_x: 20.0, min_y: 40.0, max_x: 80.0, max_y: 60.0 }
        );
        assert_eq!(
            CreateDrag::box_from(a, b, true, true),
            GraphicsRect { min_x: 20.0, min_y: 20.0, max_x: 80.0, max_y: 80.0 }
        );
    }

    #[test]
    fn shift_snaps_a_line_to_45_degree_steps() {
        let zero = Vec2::new(0.0, 0.0);
        let (_, hb) = CreateDrag::line(zero, Vec2::new(100.0, 8.0), true, false);
        assert!(hb.y.abs() < 1e-9);
        assert!((hb.x - Vec2::new(100.0, 8.0).length()).abs() < 1e-9);
        let (_, db) = CreateDrag::line(zero, Vec2::new(90.0, -110.0), true, false);
        assert!((db.x + db.y).abs() < 1e-9 && db.x > 0.0);
        let (fa, fb) = CreateDrag::line(Vec2::new(1.0, 2.0), Vec2::new(100.0, 8.0), false, false);
        assert_eq!((fa, fb), (Vec2::new(1.0, 2.0), Vec2::new(100.0, 8.0)));
    }

    #[test]
    fn option_grows_a_line_both_ways() {
        let (a, b) = CreateDrag::line(Vec2::new(10.0, 10.0), Vec2::new(40.0, 10.0), false, true);
        assert_eq!((a, b), (Vec2::new(-20.0, 10.0), Vec2::new(40.0, 10.0)));
    }

    #[test]
    fn a_shape_layer_fills_the_dragged_box() {
        let mut ids = SequentialIds::default();
        let b = GraphicsRect { min_x: -100.0, min_y: 50.0, max_x: 300.0, max_y: 150.0 };
        for kind in [ShapeKind::Rectangle, ShapeKind::Ellipse] {
            let l = GraphicsLayer::shape_in_box(&mut ids, kind, b, 1920, 1080);
            assert_eq!(l.bounds(Time::ZERO, None), Some(b));
            assert_eq!(l.name, kind.title());
        }
    }

    use crate::graphics_editing::GraphicsLayerGeometryExt as _;

    #[test]
    fn a_line_layer_runs_between_the_two_points() {
        let mut ids = SequentialIds::default();
        let l = GraphicsLayer::line_between(&mut ids, Vec2::new(0.0, 0.0), Vec2::new(300.0, 400.0), 1920, 1080);
        assert_eq!(l.animation.position.value, Vec2::new(150.0, 200.0));
        let w = l.shape_effect().and_then(|e| e.parameters.get(ClipEffect::SHAPE_WIDTH_KEY)).map(|p| p.value);
        assert!((w.unwrap_or(0.0) - 500.0).abs() < 1e-9);
        assert!((l.animation.rotation.value - 400f64.atan2(300.0) * 180.0 / std::f64::consts::PI).abs() < 1e-9);
        assert!(matches!(l.content, GraphicsContent::Shape { kind: ShapeKind::Line }));
    }

    #[test]
    fn a_shaky_straight_stroke_becomes_two_points() {
        let pts: Vec<Vec2> =
            (0..=100).map(|i| Vec2::new(f64::from(i) * 4.0, if i % 2 == 0 { 0.6 } else { -0.6 })).collect();
        let out = PathSmoothing::smooth(&pts, 2.0);
        assert_eq!(out.len(), 2);
        assert_eq!((out[0], out[1]), (pts[0], pts[100]));
    }

    #[test]
    fn a_curve_keeps_its_shape_with_far_fewer_points() {
        let pts: Vec<Vec2> = (0..=360)
            .map(|i| {
                let a = f64::from(i) * std::f64::consts::PI / 180.0 * 0.75;
                let jitter = if i % 2 == 0 { 0.8 } else { -0.8 };
                Vec2::new(a.cos() * (200.0 + jitter), a.sin() * (200.0 + jitter))
            })
            .collect();
        let out = PathSmoothing::smooth(&pts, 2.0);
        assert!(out.len() < pts.len() / 5 && out.len() >= 6);
        assert_eq!((out[0], out[out.len() - 1]), (pts[0], pts[360]));
        for p in &pts {
            let d = out.windows(2).map(|w| PathSmoothing::distance(*p, w[0], w[1])).fold(f64::INFINITY, f64::min);
            assert!(d <= 2.0 + 0.8 + 1e-6);
        }
    }

    #[test]
    fn short_inputs_pass_through_and_a_corner_survives() {
        assert!(PathSmoothing::smooth(&[], 2.0).is_empty());
        let two = [Vec2::new(0.0, 0.0), Vec2::new(5.0, 5.0)];
        assert_eq!(PathSmoothing::smooth(&two, 2.0), two.to_vec());
        let corner: Vec<Vec2> = (0..=20)
            .map(|i| Vec2::new(f64::from(i) * 5.0, 0.0))
            .chain((1..=20).map(|i| Vec2::new(100.0, f64::from(i) * 5.0)))
            .collect();
        let out = PathSmoothing::smooth(&corner, 2.0);
        assert!(out.len() >= 3 && out.iter().any(|p| (p.x - 100.0).abs() < 3.0 && p.y.abs() < 3.0));
    }

    /// Two Graphics (low 0..5 on V1, top 2..7 on V2) and a late one (10..12 on V1).
    fn sequence() -> (Timeline, Id, Id, Id) {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video, TrackKind::Video, TrackKind::Audio], &mut ids);
        let mut add = |start, track: usize, dur| {
            let at = GeneratorPlacement { timeline: tl, track: tr[track], start: s(start), duration: s(dur) };
            p.add_graphics_clip(at, Vec::new(), &mut ids).unwrap()
        };
        let (low, top, late) = (add(0, 0, 5), add(2, 1, 5), add(10, 0, 2));
        (p.timelines[0].clone(), top, low, late)
    }

    fn sel(ids: &[Id]) -> BTreeSet<Id> {
        ids.iter().copied().collect()
    }

    #[test]
    fn a_selected_graphic_under_the_playhead_takes_the_item() {
        let (t, top, low, late) = sequence();
        assert_eq!(t.graphic_create_target(&sel(&[low]), s(3)), Some(low));
        assert_eq!(t.graphic_create_target(&sel(&[top]), s(3)), Some(top));
        assert_eq!(t.graphic_create_target(&sel(&[late]), s(3)), None);
    }

    #[test]
    fn without_selection_the_graphic_on_a_targeted_track_takes_it() {
        let (mut t, top, low, _) = sequence();
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(3)), None); // no track targeted
        t.tracks[0].is_targeted = true;
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(3)), Some(low));
        t.tracks[1].is_targeted = true;
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(3)), Some(top)); // the upper targeted track wins
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(1)), Some(low));
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(8)), None);
        t.tracks[1].is_locked = true;
        assert_eq!(t.graphic_create_target(&BTreeSet::new(), s(3)), Some(low));
        assert_eq!(t.graphic_create_target(&sel(&[top]), s(3)), Some(low)); // a locked graphic takes nothing
    }

    #[test]
    fn add_graphics_layer_puts_the_layer_on_top() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video], &mut ids);
        let at = GeneratorPlacement { timeline: tl, track: tr[0], start: s(0), duration: s(2) };
        let clip = p.add_graphics_clip(at, Vec::new(), &mut ids).unwrap();
        let (a, b) = (rect(&mut ids, "a", None), rect(&mut ids, "b", None));
        let (ia, ib) = (a.id, b.id);
        p.add_graphics_layer(a, clip).unwrap();
        p.add_graphics_layer(b, clip).unwrap();
        let doc: &GraphicsDocument = p.graphics_clip(clip).and_then(|c| c.graphics()).unwrap();
        assert_eq!(doc.layers.iter().map(|l| l.id).collect::<Vec<_>>(), vec![ia, ib]);
        assert_eq!(p.add_graphics_layer(rect(&mut ids, "x", None), Id::NIL), Err(EditError::ClipNotFound));
    }
}
