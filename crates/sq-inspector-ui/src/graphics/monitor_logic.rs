// Swift: GraphicsMonitorLogic.swift
//! Snapping of graphic layers on the Program monitor: frame edges, frame center and the safe margins (the same snap targets
//! the clip overlay uses). All values are canvas px of the graphic (offset from its center, y down).

use sq_core_graphics::graphics_editing::{GraphicsDocumentEditingExt, GraphicsRect, GraphicsTextMeasure};
use sq_core_model::GraphicsDocument;
use sq_core_time::{Id, Time, Vec2};
use sq_editor_session::{SafeArea, SnapGuides, SnapResult, SnapTargets};
use sq_uikit::keyframe_graph_geometry::{Rect, Size};

use crate::graphics::canvas_mapping::GraphicsCanvasMapping;

/// Snapping of graphic layers on the Program monitor.
pub enum GraphicsSnap {}

impl GraphicsSnap {
    /// The frame's snap lines in the graphic's canvas space, or `None` when the graphic is rotated (the frame lines are no
    /// longer axis-aligned there, so nothing snaps). The frame is the sequence canvas; the graphic's Motion maps it back.
    pub fn targets(canvas: Vec2, mapping: &GraphicsCanvasMapping, safe_areas: &[SafeArea]) -> Option<SnapTargets> {
        let t = &mapping.transform;
        if (t.rotation % 360.0).abs() >= 1e-9 {
            return None;
        }
        let sx = if t.scale.x.abs() > 1e-9 { t.scale.x } else { 1e-9 };
        let sy = if t.scale.y.abs() > 1e-9 { t.scale.y } else { 1e-9 };
        let seq = SnapGuides::targets(Size::new(canvas.x, canvas.y), &[], safe_areas, None);
        Some(SnapTargets::new(
            seq.xs.iter().map(|x| (x - t.position.x) / sx + t.anchor.x).collect(),
            seq.ys.iter().map(|y| (y - t.position.y) / sy + t.anchor.y).collect(),
        ))
    }

    /// View points as canvas px: the same on-screen distance stays the same however far the graphic is scaled down.
    /// `view_scale`: view points per sequence px.
    pub fn threshold(view_points: f64, view_scale: f64, mapping: &GraphicsCanvasMapping) -> f64 {
        let s = mapping.transform.scale.x.abs().max(mapping.transform.scale.y.abs()).max(1e-9);
        view_points / (view_scale.max(1e-9) * s)
    }

    /// A single dragged point (a resize handle) pulled onto the nearest line.
    pub fn snap_point(p: Vec2, targets: &SnapTargets, threshold: f64) -> (Vec2, SnapResult) {
        let r = SnapGuides::snap_point(p, targets, threshold);
        (Vec2::new(p.x + r.dx, p.y + r.dy), r)
    }
}

/// One move drag: follows the pointer, pulls the selection's box (edges and center) onto the snap lines. Returns the canvas
/// delta still to apply, so the caller's incremental `translate` ends exactly on the snapped position.
pub struct GraphicsMoveSnapper {
    start_box: GraphicsRect,
    start: Vec2,
    targets: Option<SnapTargets>,
    threshold: f64,
    applied: Vec2,
}

impl GraphicsMoveSnapper {
    pub fn new(
        start_box: GraphicsRect,
        start: Vec2,
        targets: Option<SnapTargets>,
        threshold: f64,
    ) -> GraphicsMoveSnapper {
        GraphicsMoveSnapper { start_box, start, targets, threshold, applied: Vec2::ZERO }
    }

    pub fn step(&mut self, q: Vec2, snapping: bool) -> (Vec2, SnapResult) {
        let raw = q - self.start;
        let mut want = raw;
        let mut guides = SnapResult::none();
        if let (true, Some(targets)) = (snapping, &self.targets) {
            let b = &self.start_box;
            let rect = Rect::new(b.min_x + raw.x, b.min_y + raw.y, b.width(), b.height());
            guides = SnapGuides::snap_box(rect, targets, self.threshold);
            want = Vec2::new(raw.x + guides.dx, raw.y + guides.dy);
        }
        let delta = want - self.applied;
        self.applied = want;
        (delta, guides)
    }
}

/// The topmost visible layer under `p` when it is an unlocked text layer (what the Type tool edits); `None` otherwise, also
/// when something else lies above the text.
pub fn text_layer_at(doc: &GraphicsDocument, p: Vec2, t: Time, text: Option<GraphicsTextMeasure>) -> Option<Id> {
    let id = doc.hit_test(p, t, text)?;
    let l = doc.layer(id)?;
    (!l.is_locked && l.is_text()).then_some(id)
}
