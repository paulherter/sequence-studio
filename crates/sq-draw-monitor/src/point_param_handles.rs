// Swift: PointParamHandles.swift
//! Point parameters (an effect's center, Corner Warp corners) as draggable handles in the Program monitor.

use sq_core_model::{ClipEffect, ClipTransform};
use sq_core_time::Vec2;
use sq_editor_session::es02_timeline_ops::{SnapGuides, SnapResult, SnapTargets};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// A point parameter (an effect's center, a shape corner, ...) shown as a draggable handle in the Program monitor.
/// `offset` is in sequence px from the canvas center, y down (same space as `ClipTransform.position`).
#[derive(Clone, Debug, PartialEq)]
pub struct PointHandle {
    /// The handle's id (`effect|key`).
    pub id: String,
    /// Sequence px from the canvas center.
    pub offset: Vec2,
}

/// Snapping of a handle drag.
#[derive(Clone, Debug, PartialEq)]
pub struct PointHandleSnap {
    /// The guide targets.
    pub targets: SnapTargets,
    /// Snap distance in view points.
    pub view_threshold: f64,
}

/// The offset a drag ends at and the guides it snapped to.
#[derive(Clone, Debug, PartialEq)]
pub struct DragResult {
    /// The new offset.
    pub offset: Vec2,
    /// The guide lines to draw.
    pub guides: SnapResult,
}

/// Pure geometry for point-parameter handles: view <-> offset mapping, hit test, snapped drag.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointHandleGeometry {
    /// The sequence size in px.
    pub sequence_size: CGSize,
    /// Where the canvas is shown.
    pub view_rect: CGRect,
}

impl PointHandleGeometry {
    /// Grab radius in view points.
    pub const HIT_RADIUS: f64 = 8.0;

    /// A geometry.
    pub fn new(sequence_size: CGSize, view_rect: CGRect) -> PointHandleGeometry {
        PointHandleGeometry { sequence_size, view_rect }
    }

    /// View points per sequence px.
    pub fn view_scale(&self) -> f64 {
        if self.sequence_size.width > 0.0 { self.view_rect.width / self.sequence_size.width } else { 1.0 }
    }

    /// Offset to view point.
    pub fn view_point_from_offset(&self, o: Vec2) -> CGPoint {
        CGPoint::new(self.view_rect.mid_x() + o.x * self.view_scale(), self.view_rect.mid_y() + o.y * self.view_scale())
    }

    /// View point to offset.
    pub fn offset_from_view(&self, p: CGPoint) -> Vec2 {
        Vec2::new(
            (p.x - self.view_rect.mid_x()) / self.view_scale(),
            (p.y - self.view_rect.mid_y()) / self.view_scale(),
        )
    }

    /// Offset to 0...1 canvas coordinates (top-left origin), the usual stored form of a point parameter.
    pub fn normalized(&self, o: Vec2) -> Vec2 {
        Vec2::new(o.x / self.sequence_size.width + 0.5, o.y / self.sequence_size.height + 0.5)
    }

    /// 0...1 canvas coordinates to offset.
    pub fn offset_from_normalized(&self, n: Vec2) -> Vec2 {
        Vec2::new((n.x - 0.5) * self.sequence_size.width, (n.y - 0.5) * self.sequence_size.height)
    }

    /// Nearest handle within `radius` of `p`.
    pub fn hit_test(&self, p: CGPoint, handles: &[PointHandle], radius: f64) -> Option<String> {
        let mut best: Option<(&str, f64)> = None;
        for h in handles {
            let c = self.view_point_from_offset(h.offset);
            let d = (c.x - p.x).hypot(c.y - p.y);
            if d <= radius && d < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((&h.id, d));
            }
        }
        best.map(|b| b.0.to_string())
    }

    /// New offset for `handle` dragged from `grab` (where the mouse went down) to `p`. The point keeps its distance to
    /// the cursor; Shift (`lock_axis`) keeps the dominant axis of the movement; `snap` pulls it onto the guide targets.
    pub fn dragged(
        &self,
        handle: &PointHandle,
        grab: CGPoint,
        p: CGPoint,
        lock_axis: bool,
        snap: Option<&PointHandleSnap>,
    ) -> DragResult {
        let mut dx = (p.x - grab.x) / self.view_scale();
        let mut dy = (p.y - grab.y) / self.view_scale();
        if lock_axis {
            if dx.abs() >= dy.abs() {
                dy = 0.0;
            } else {
                dx = 0.0;
            }
        }
        let mut o = Vec2::new(handle.offset.x + dx, handle.offset.y + dy);
        let Some(snap) = snap.filter(|_| self.view_scale() > 0.0) else {
            return DragResult { offset: o, guides: SnapResult::none() };
        };
        let r = SnapGuides::snap_point(o, &snap.targets, snap.view_threshold / self.view_scale())
            .locking(lock_axis && dx == 0.0, lock_axis && dy == 0.0);
        o = Vec2::new(o.x + r.dx, o.y + r.dy);
        DragResult { offset: o, guides: r }
    }
}

/// Point parameters are px from the layer's center in its own (unscaled, unrotated) frame; on the canvas they follow the
/// clip's transform like any layer point: `offset = position + R(rotation) * S(scale) * (local - anchor)`.
pub enum PointHandleMapping {}

impl PointHandleMapping {
    /// Group Transform (an ungrouped Group's Motion) works in canvas px, not in the clip's frame: its Position and Anchor
    /// handles sit at their value (px from the canvas center) and its Scale has no handle.
    pub fn has_handle(kind: &str, key: &str) -> bool {
        kind != ClipEffect::GROUP_TRANSFORM_KIND || key != ClipEffect::GROUP_SCALE_KEY
    }

    /// The effect works in canvas px.
    pub fn is_canvas_space(kind: &str) -> bool {
        kind == ClipEffect::GROUP_TRANSFORM_KIND
    }

    /// Canvas offset of a local point of `kind`.
    pub fn offset(kind: &str, l: Vec2, t: &ClipTransform) -> Vec2 {
        if Self::is_canvas_space(kind) { l } else { Self::offset_for_local(l, t) }
    }

    /// Local point of a canvas offset of `kind`.
    pub fn local(kind: &str, o: Vec2, t: &ClipTransform) -> Vec2 {
        if Self::is_canvas_space(kind) { o } else { Self::local_for_offset(o, t) }
    }

    /// Canvas offset of a point in the layer's own frame.
    pub fn offset_for_local(l: Vec2, t: &ClipTransform) -> Vec2 {
        let d = Vec2::new((l.x - t.anchor.x) * t.scale.x, (l.y - t.anchor.y) * t.scale.y);
        let a = t.rotation * std::f64::consts::PI / 180.0;
        Vec2::new(t.position.x + d.x * a.cos() - d.y * a.sin(), t.position.y + d.x * a.sin() + d.y * a.cos())
    }

    /// Point in the layer's own frame for a canvas offset.
    pub fn local_for_offset(o: Vec2, t: &ClipTransform) -> Vec2 {
        let a = -t.rotation * std::f64::consts::PI / 180.0;
        let d = Vec2::new(o.x - t.position.x, o.y - t.position.y);
        let r = Vec2::new(d.x * a.cos() - d.y * a.sin(), d.x * a.sin() + d.y * a.cos());
        let sx = if t.scale.x.abs() > 1e-9 { t.scale.x } else { 1.0 };
        let sy = if t.scale.y.abs() > 1e-9 { t.scale.y } else { 1.0 };
        Vec2::new(r.x / sx + t.anchor.x, r.y / sy + t.anchor.y)
    }

    // MARK: Corner Warp

    /// Corner Warp stores each corner as an offset (px) from the picture's own corner; its handle sits at the warped corner.
    pub fn is_corner_offset(kind: &str) -> bool {
        kind == ClipEffect::CORNER_PIN_KIND
    }

    /// The unwarped corner of parameter `key` in layer-local px from the layer center (y down); `None` for a non-corner key.
    pub fn corner_base(key: &str, frame: CGSize) -> Option<Vec2> {
        let hw = frame.width / 2.0;
        let hh = frame.height / 2.0;
        match key {
            ClipEffect::CORNER_PIN_TOP_LEFT_KEY => Some(Vec2::new(-hw, -hh)),
            ClipEffect::CORNER_PIN_TOP_RIGHT_KEY => Some(Vec2::new(hw, -hh)),
            ClipEffect::CORNER_PIN_BOTTOM_RIGHT_KEY => Some(Vec2::new(hw, hh)),
            ClipEffect::CORNER_PIN_BOTTOM_LEFT_KEY => Some(Vec2::new(-hw, hh)),
            _ => None,
        }
    }

    /// Local position of the warped corner for the stored offset `value`.
    pub fn corner_local(key: &str, value: Vec2, frame: CGSize) -> Vec2 {
        let b = Self::corner_base(key, frame).unwrap_or(Vec2::ZERO);
        Vec2::new(b.x + value.x, b.y + value.y)
    }

    /// Stored offset for a handle dragged to layer-local position `local`.
    pub fn corner_value(key: &str, local: Vec2, frame: CGSize) -> Vec2 {
        let b = Self::corner_base(key, frame).unwrap_or(Vec2::ZERO);
        Vec2::new(local.x - b.x, local.y - b.y)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geo() -> PointHandleGeometry {
        PointHandleGeometry::new(CGSize::new(1920.0, 1080.0), CGRect::new(100.0, 50.0, 960.0, 540.0))
    }

    #[test]
    fn view_and_offset_round_trip_and_hit_the_nearest() {
        let g = geo();
        let p = g.view_point_from_offset(Vec2::new(100.0, 50.0));
        assert_eq!(g.offset_from_view(p), Vec2::new(100.0, 50.0));
        let hs = [
            PointHandle { id: "a".into(), offset: Vec2::new(100.0, 50.0) },
            PointHandle { id: "b".into(), offset: Vec2::new(110.0, 50.0) },
        ];
        assert_eq!(g.hit_test(p, &hs, PointHandleGeometry::HIT_RADIUS).as_deref(), Some("a"));
        assert_eq!(g.hit_test(CGPoint::new(0.0, 0.0), &hs, PointHandleGeometry::HIT_RADIUS), None);
    }

    #[test]
    fn drag_keeps_the_grab_offset_and_locks_an_axis() {
        let g = geo();
        let h = PointHandle { id: "a".into(), offset: Vec2::new(0.0, 0.0) };
        let grab = g.view_point_from_offset(h.offset);
        let r = g.dragged(&h, grab, CGPoint::new(grab.x + 10.0, grab.y + 5.0), false, None);
        assert_eq!(r.offset, Vec2::new(20.0, 10.0));
        let locked = g.dragged(&h, grab, CGPoint::new(grab.x + 10.0, grab.y + 5.0), true, None);
        assert_eq!(locked.offset, Vec2::new(20.0, 0.0));
    }

    #[test]
    fn local_and_offset_are_inverse_and_group_transform_is_canvas_space() {
        let mut t = ClipTransform::IDENTITY;
        t.position = Vec2::new(40.0, -20.0);
        t.rotation = 30.0;
        t.scale = Vec2::new(2.0, 0.5);
        let l = Vec2::new(10.0, 15.0);
        let back = PointHandleMapping::local_for_offset(PointHandleMapping::offset_for_local(l, &t), &t);
        assert!((back.x - l.x).abs() < 1e-9 && (back.y - l.y).abs() < 1e-9);
        assert_eq!(PointHandleMapping::offset(ClipEffect::GROUP_TRANSFORM_KIND, l, &t), l);
        assert!(!PointHandleMapping::has_handle(ClipEffect::GROUP_TRANSFORM_KIND, ClipEffect::GROUP_SCALE_KEY));
    }

    #[test]
    fn corner_warp_offsets_round_trip() {
        let frame = CGSize::new(100.0, 50.0);
        let local = PointHandleMapping::corner_local(ClipEffect::CORNER_PIN_TOP_RIGHT_KEY, Vec2::new(3.0, 4.0), frame);
        assert_eq!(local, Vec2::new(53.0, -21.0));
        assert_eq!(
            PointHandleMapping::corner_value(ClipEffect::CORNER_PIN_TOP_RIGHT_KEY, local, frame),
            Vec2::new(3.0, 4.0)
        );
        assert_eq!(PointHandleMapping::corner_base("nope", frame), None);
    }
}
