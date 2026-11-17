// Swift: GraphicsEditor.swift (GraphicsCanvasMapping), CreateToolShape.swift, CreateToolMenuShape.swift
//! Graphics clip space <-> sequence space (offsets from the canvas center, y down) through the clip's Motion at the
//! playhead. The graphic's content is the whole canvas, so its content center is the canvas center.

use sq_core_graphics::graphics_create::GraphicsLayerCreateExt;
use sq_core_graphics::graphics_editing::GraphicsRect;
use sq_core_model::{AnimatedProperty, ClipTransform, GraphicsContent, GraphicsLayer, ShapeKind};
use sq_core_time::{IdSource, Vec2};

#[derive(Clone, Debug, PartialEq)]
pub struct GraphicsCanvasMapping {
    pub transform: ClipTransform,
}

impl GraphicsCanvasMapping {
    pub fn new(transform: ClipTransform) -> GraphicsCanvasMapping {
        GraphicsCanvasMapping { transform }
    }

    fn rad(&self) -> f64 {
        self.transform.rotation * std::f64::consts::PI / 180.0
    }

    pub fn sequence_offset_from_canvas(&self, q: Vec2) -> Vec2 {
        let t = &self.transform;
        let d = q - t.anchor;
        let (x, y) = (d.x * t.scale.x, d.y * t.scale.y);
        let rad = self.rad();
        t.position + Vec2::new(x * rad.cos() - y * rad.sin(), x * rad.sin() + y * rad.cos())
    }

    pub fn canvas_point_from_sequence(&self, p: Vec2) -> Vec2 {
        let t = &self.transform;
        let d = p - t.position;
        let rad = self.rad();
        let (x, y) = (d.x * rad.cos() + d.y * rad.sin(), -d.x * rad.sin() + d.y * rad.cos());
        let sx = if t.scale.x.abs() > 1e-9 { t.scale.x } else { 1e-9 };
        let sy = if t.scale.y.abs() > 1e-9 { t.scale.y } else { 1e-9 };
        Vec2::new(x / sx, y / sy) + t.anchor
    }

    /// A sequence-space drag delta as a canvas delta.
    pub fn canvas_delta_from_sequence(&self, d: Vec2) -> Vec2 {
        self.canvas_point_from_sequence(d + self.transform.position)
            - self.canvas_point_from_sequence(self.transform.position)
    }

    /// The item box that shows as the upright box from `a` to `b` on the picture (sequence px): its center in the
    /// Graphic's canvas, its size with the clip's scale taken out, and the item rotation that undoes the clip's rotation.
    pub fn canvas_box_from_sequence(&self, a: Vec2, b: Vec2) -> CanvasBox {
        let t = &self.transform;
        let center = self.canvas_point_from_sequence(Vec2::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0));
        let rad = t.rotation * std::f64::consts::PI / 180.0;
        let sx = t.scale.x.abs().max(1e-9);
        let sy = t.scale.y.abs().max(1e-9);
        // How long a canvas unit along the item's own axes is on the picture (the same on both for a uniform scale).
        let along = (sx * rad.cos() * sx * rad.cos() + sy * rad.sin() * sy * rad.sin()).sqrt();
        let across = (sx * rad.sin() * sx * rad.sin() + sy * rad.cos() * sy * rad.cos()).sqrt();
        CanvasBox {
            center,
            size: Vec2::new((b.x - a.x).abs() / along.max(1e-9), (b.y - a.y).abs() / across.max(1e-9)),
            rotation: -t.rotation,
        }
    }
}

/// `canvasBox(fromSequence:)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CanvasBox {
    pub center: Vec2,
    pub size: Vec2,
    pub rotation: f64,
}

/// The item a Create drag from `a` to `b` (sequence px, offsets from the picture center) makes in a Graphic shown through
/// `mapping`: it lands where the drag's preview was, also when the clip is moved, scaled or rotated.
pub fn created_shape(
    ids: &mut dyn IdSource,
    kind: ShapeKind,
    a: Vec2,
    b: Vec2,
    mapping: &GraphicsCanvasMapping,
    canvas: Vec2,
) -> GraphicsLayer {
    let (w, h) = (canvas.x as i64, canvas.y as i64);
    if kind == ShapeKind::Line || kind == ShapeKind::Arrow {
        let mut l = GraphicsLayer::line_between(
            ids,
            mapping.canvas_point_from_sequence(a),
            mapping.canvas_point_from_sequence(b),
            w,
            h,
        );
        if kind == ShapeKind::Arrow {
            l.content = GraphicsContent::Shape { kind: ShapeKind::Arrow };
        }
        return l;
    }
    let bx = mapping.canvas_box_from_sequence(a, b);
    let rect = GraphicsRect {
        min_x: bx.center.x - bx.size.x / 2.0,
        min_y: bx.center.y - bx.size.y / 2.0,
        max_x: bx.center.x + bx.size.x / 2.0,
        max_y: bx.center.y + bx.size.y / 2.0,
    };
    let mut l = GraphicsLayer::shape_in_box(ids, kind, rect, w, h);
    if bx.rotation != 0.0 {
        l.animation.rotation = AnimatedProperty::new(bx.rotation);
    }
    l
}

/// The drag Sequence > New Shape stands for: a box one third of the picture height, centered; lines run horizontally. The
/// menu item takes the Create tool's path, so it is only a command alias of it.
pub fn menu_shape_drag(kind: ShapeKind, canvas: Vec2) -> (Vec2, Vec2) {
    let half = canvas.y / 6.0;
    if kind == ShapeKind::Line || kind == ShapeKind::Arrow {
        return (Vec2::new(-half, 0.0), Vec2::new(half, 0.0));
    }
    (Vec2::new(-half, -half), Vec2::new(half, half))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn mapping(position: Vec2, scale: f64, rotation: f64) -> GraphicsCanvasMapping {
        let mut t = ClipTransform::IDENTITY;
        t.position = position;
        t.scale = Vec2::new(scale, scale);
        t.rotation = rotation;
        GraphicsCanvasMapping::new(t)
    }

    #[test]
    fn points_round_trip_through_a_moved_scaled_rotated_clip() {
        let m = mapping(Vec2::new(100.0, -40.0), 0.5, 30.0);
        let q = Vec2::new(70.0, 25.0);
        let back = m.canvas_point_from_sequence(m.sequence_offset_from_canvas(q));
        assert!((back.x - q.x).abs() < 1e-9 && (back.y - q.y).abs() < 1e-9);
    }

    #[test]
    fn a_drag_box_in_a_plain_graphic_is_the_drag() {
        let m = mapping(Vec2::ZERO, 1.0, 0.0);
        let b = m.canvas_box_from_sequence(Vec2::new(-50.0, -20.0), Vec2::new(50.0, 20.0));
        assert_eq!((b.center, b.size, b.rotation), (Vec2::ZERO, Vec2::new(100.0, 40.0), -0.0));
    }

    #[test]
    fn a_scaled_graphic_gets_a_bigger_box_and_an_undoing_rotation() {
        let m = mapping(Vec2::ZERO, 0.5, 90.0);
        let b = m.canvas_box_from_sequence(Vec2::new(-10.0, -10.0), Vec2::new(10.0, 10.0));
        assert!((b.size.x - 40.0).abs() < 1e-9 && (b.size.y - 40.0).abs() < 1e-9);
        assert_eq!(b.rotation, -90.0);
    }

    #[test]
    fn created_shapes_land_where_the_drag_was() {
        let mut ids = SequentialIds::default();
        let m = mapping(Vec2::ZERO, 1.0, 0.0);
        let r = created_shape(
            &mut ids,
            ShapeKind::Rectangle,
            Vec2::new(-10.0, -5.0),
            Vec2::new(30.0, 15.0),
            &m,
            Vec2::new(1920.0, 1080.0),
        );
        assert_eq!(r.animation.position.value, Vec2::new(10.0, 5.0));
        let arrow =
            created_shape(&mut ids, ShapeKind::Arrow, Vec2::ZERO, Vec2::new(100.0, 0.0), &m, Vec2::new(1920.0, 1080.0));
        assert_eq!(arrow.content, GraphicsContent::Shape { kind: ShapeKind::Arrow });
    }

    #[test]
    fn the_menu_drag_is_a_third_of_the_picture_height() {
        let c = Vec2::new(1920.0, 1080.0);
        assert_eq!(menu_shape_drag(ShapeKind::Rectangle, c), (Vec2::new(-180.0, -180.0), Vec2::new(180.0, 180.0)));
        assert_eq!(menu_shape_drag(ShapeKind::Line, c), (Vec2::new(-180.0, 0.0), Vec2::new(180.0, 0.0)));
    }
}
