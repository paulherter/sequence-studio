// Swift: CaptionDrag.swift
//! Dragging a caption in the Program monitor: the caption's own position moves by the drag, and its text block snaps to
//! the canvas center lines and the action / title safe zones (offset space: sequence px from the canvas center, y down).

use sq_core_model::CaptionPosition;
use sq_core_time::Vec2;
use sq_editor_session::{SafeArea, SnapGuides, SnapResult};
use sq_uikit::keyframe_graph_geometry::{Rect, Size};

/// Caption drag.
pub struct CaptionDrag;

impl CaptionDrag {
    /// - `start`: the caption's effective position when the drag began (alignment is kept, only the offset moves).
    /// - `text_rect`: the drawn text block at `start`.
    /// - `delta`: drag distance so far (sequence px).
    /// - `threshold`: snap distance (sequence px); 0 turns snapping off (Option held).
    /// - `zone`: platform UI zone in offset space; the box snaps softly to its edges, nothing is forced.
    pub fn moved(
        start: CaptionPosition,
        text_rect: Rect,
        delta: Vec2,
        canvas: Size,
        threshold: f64,
        zone: Option<Rect>,
    ) -> (CaptionPosition, SnapResult) {
        let mut dx = delta.x;
        let mut dy = delta.y;
        let mut guides = SnapResult::default();
        if threshold > 0.0 {
            let targets = SnapGuides::targets(canvas, &[], &SafeArea::ALL, zone);
            let box_ = Rect::new(text_rect.x + delta.x, text_rect.y + delta.y, text_rect.width, text_rect.height);
            guides = SnapGuides::snap_box(box_, &targets, threshold);
            dx += guides.dx;
            dy += guides.dy;
        }
        let w = canvas.width.max(1.0);
        let h = canvas.height.max(1.0);
        let p = CaptionPosition {
            vertical: start.vertical,
            horizontal: start.horizontal,
            offset_x: start.offset_x + dx / w,
            offset_y: start.offset_y + dy / h,
        };
        (p, guides)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{CaptionHorizontal, CaptionVertical};

    fn default_position() -> CaptionPosition {
        CaptionPosition {
            vertical: CaptionVertical::Bottom,
            horizontal: CaptionHorizontal::Center,
            offset_x: 0.0,
            offset_y: 0.0,
        }
    }

    fn rect() -> Rect {
        Rect::new(-300.0, 300.0, 600.0, 80.0)
    }

    const CANVAS: Size = Size::new(1920.0, 1080.0);

    #[test]
    fn drag_moves_by_the_delta_as_fraction_of_the_canvas() {
        let r = CaptionDrag::moved(default_position(), rect(), Vec2 { x: 192.0, y: -108.0 }, CANVAS, 0.0, None);
        assert!((r.0.offset_x - 0.1).abs() < 1e-9 && (r.0.offset_y + 0.1).abs() < 1e-9);
        assert!(r.0.vertical == CaptionVertical::Bottom && r.0.horizontal == CaptionHorizontal::Center);
    }

    #[test]
    fn drag_snaps_to_centre_and_safe_zones() {
        let r = CaptionDrag::moved(default_position(), rect(), Vec2 { x: 5.0, y: 0.0 }, CANVAS, 8.0, None);
        assert_eq!(r.0.offset_x, 0.0);
        assert!(r.1.vertical_lines.contains(&0.0));
        // Title safe bottom edge: 540 - 108 = 432. Block bottom at 380, moved 50 down -> snaps to 432 (dy 52).
        let s = CaptionDrag::moved(default_position(), rect(), Vec2 { x: 0.0, y: 50.0 }, CANVAS, 8.0, None);
        assert!((s.0.offset_y - 52.0 / 1080.0).abs() < 1e-9);
        assert!(s.1.horizontal_lines.iter().any(|l| (l - 432.0).abs() < 1e-6));
    }

    #[test]
    fn no_snap_when_threshold_is_zero() {
        let r = CaptionDrag::moved(default_position(), rect(), Vec2 { x: 5.0, y: 0.0 }, CANVAS, 0.0, None);
        assert!((r.0.offset_x - 5.0 / 1920.0).abs() < 1e-9 && r.1.vertical_lines.is_empty());
    }
}
