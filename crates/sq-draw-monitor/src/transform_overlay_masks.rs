// Swift: TransformOverlay+Masks.swift
//! Masks on the canvas overlay: the mask parts of the Mac `TransformOverlayView` translated (hit order, pen handles,
//! Mask tool presses, shape rubber band, drawing). Math: the shared `MaskOverlayGeometry`, `MaskPath`, `MaskShapeDrag`.

use crate::cg::RectExt;
use crate::mask_handle_edit::MaskHandleEdit;
use crate::transform_overlay::{Drag, OverlayEvent, Phase, TransformOverlay};
use sq_core_masks::mask_inputs::MaskShapeDrag;
use sq_core_masks::mask_path_editing::MaskPathEditingExt;
use sq_core_masks::masks::MaskPathExt;
use sq_core_model::MaskPath;
use sq_core_time::Vec2;
use sq_draw::InputModifiers;
use sq_draw::canvas::Canvas;
use sq_draw::monitor::mask_overlay_geometry::MaskOverlayGeometry;
use sq_draw::theme::{DrawTheme, radius, spacing, type_size};
use sq_editor_session::es01_session_core::MaskToolMode;
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// What a press at a point lands on, nearest kind first.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum MaskHit {
    /// A Bezier handle: mask, vertex, out side.
    Tangent(usize, usize, bool),
    /// A vertex: mask, vertex.
    Vertex(usize, usize),
    /// The outline: mask, segment, t.
    Segment(usize, usize, f64),
    /// The inside of a mask.
    Inside(usize),
}

impl TransformOverlay {
    pub(crate) fn mask_geometry(&self, r: CGRect) -> MaskOverlayGeometry {
        MaskOverlayGeometry::new(&self.geometry(r).quad())
    }

    /// Where the Mask Tint lands: the layer quad as an image rect with its source (mirrored layers flip the source).
    // known limit: `None` on a rotated or skewed layer, the image quad is axis-aligned (the Mac stretches the tint over the
    // turned quad); upgrade when the draw list gets a textured quad with four corners.
    fn mask_tint_placement(&self, r: CGRect) -> Option<(CGRect, [f32; 4])> {
        let g = self.mask_geometry(r);
        if !(g.x_axis.dy.abs() < 0.01
            && g.y_axis.dx.abs() < 0.01
            && g.x_axis.dx.abs() >= 0.5
            && g.y_axis.dy.abs() >= 0.5)
        {
            return None;
        }
        let x1 = g.origin.x + g.x_axis.dx;
        let y1 = g.origin.y + g.y_axis.dy;
        let rect = CGRect::new(g.origin.x.min(x1), g.origin.y.min(y1), g.x_axis.dx.abs(), g.y_axis.dy.abs());
        let (u0, u1) = if g.x_axis.dx >= 0.0 { (0.0, 1.0) } else { (1.0, 0.0) };
        let (v0, v1) = if g.y_axis.dy >= 0.0 { (0.0, 1.0) } else { (1.0, 0.0) };
        Some((rect, [u0, v0, u1, v1]))
    }

    /// The tint in the Mac color: `Theme.Colors.yellow`, the 30 % already in the coverage's alpha.
    pub(crate) fn draw_mask_tint(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        let (Some(slot), Some(p)) = (self.mask_tint_slot, self.mask_tint_placement(r)) else { return };
        c.draw_image_slot(slot, p.0, p.1, t.yellow().with_alpha(1.0));
    }

    /// The Add | Remove switch: two segments top left of the picture area.
    fn magic_switch_rects(&self, r: CGRect) -> (CGRect, CGRect) {
        let inset = spacing::SM as f64;
        let (w, h) = (64.0, 22.0);
        let add = CGRect::new(r.min_x() + inset, r.min_y() + inset, w, h);
        (add, add.offset_by(w, 0.0))
    }

    /// Which segment `p` is on: false = Add, true = Remove, `None` = not on the switch.
    pub(crate) fn magic_switch_hit(&self, p: CGPoint, r: CGRect) -> Option<bool> {
        if r.is_empty_rect() {
            return None;
        }
        let (add, remove) = self.magic_switch_rects(r);
        if add.contains(p) {
            return Some(false);
        }
        if remove.contains(p) {
            return Some(true);
        }
        None
    }

    pub(crate) fn draw_magic_switch(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        if r.is_empty_rect() {
            return;
        }
        let (add, remove) = self.magic_switch_rects(r);
        let rad = radius::CONTROL as f64;
        let size = type_size::CAPTION as f64;
        let both = CGRect::new(add.x, add.y, add.width + remove.width, add.height);
        c.fill_rounded(both, rad, t.viewer_hud());
        let on = if self.magic_subtract { remove } else { add };
        c.fill_rounded(on.inset_by(2.0, 2.0), rad - 1.0, t.accent_fill());
        c.draw_text_in("Add", add, size, t.label(), sq_draw::TextAlign::Center, 0.0, 0);
        c.draw_text_in("Remove", remove, size, t.label(), sq_draw::TextAlign::Center, 0.0, 0);
    }

    /// The frame fraction under `p` when it lies on the layer.
    pub(crate) fn mask_frame_point(&self, p: CGPoint, r: CGRect) -> Option<Vec2> {
        let n = self.mask_geometry(r).frame_point(p)?;
        ((0.0..=1.0).contains(&n.x) && (0.0..=1.0).contains(&n.y)).then_some(n)
    }

    /// The pointer at `p` (view point): with the Magic tool the host hears where it rests on the layer
    /// (`MaskToolHover`).
    pub fn pointer_moved(&mut self, p: CGPoint, r: CGRect) {
        let mut n = None;
        if self.is_shown && self.mask_tool == Some(MaskToolMode::Magic) && !r.is_empty_rect() {
            n = self.mask_frame_point(p, r);
        }
        if n == self.magic_hover_point {
            return;
        }
        self.magic_hover_point = n;
        if self.mask_tool == Some(MaskToolMode::Magic) || n.is_none() {
            self.events.push(OverlayEvent::MaskToolHover(n));
        }
    }

    /// Mask handles under `p`, nearest kind first: tangent handles and vertices, then the active outline, then its inside.
    pub(crate) fn mask_hit(&self, p: CGPoint, r: CGRect) -> Option<MaskHit> {
        if self.masks.is_empty() {
            return None;
        }
        let g = self.mask_geometry(r);
        if let Some(h) = g.hit_tangent(p, &self.masks) {
            return Some(MaskHit::Tangent(h.mask, h.vertex, h.out));
        }
        if let Some((m, v)) = g.hit_vertex(p, &self.masks) {
            return Some(MaskHit::Vertex(m, v));
        }
        if let Some(h) = g.hit_segment(p, &self.masks) {
            return Some(MaskHit::Segment(h.mask, h.segment, h.t));
        }
        g.hit_inside(p, &self.masks).map(MaskHit::Inside)
    }

    /// Selection tool press on the masks' handles; true when they took it.
    pub(crate) fn mask_handles_down(&mut self, p: CGPoint, modifiers: InputModifiers) -> bool {
        let Some(hit) = self.mask_hit(p, self.canvas_rect) else { return false };
        self.press_mask(hit, p, modifiers)
    }

    /// Mask tool press: Pen and shapes keep the masks' own handles (shapes: not the outline), anything else on the layer
    /// is a tool press; Magic reports a click, or a box when the press was dragged (the host says when it cannot pick).
    pub(crate) fn mask_tool_down(&mut self, p: CGPoint, modifiers: InputModifiers) -> bool {
        let Some(mode) = self.mask_tool else { return false };
        if mode != MaskToolMode::Magic
            && let Some(hit) = self.mask_hit(p, self.canvas_rect)
        {
            let mut usable = true;
            if mode != MaskToolMode::Pen && matches!(hit, MaskHit::Segment(..)) {
                usable = false;
            }
            if usable && self.press_mask(hit, p, modifiers) {
                return true;
            }
        }
        let Some(n) = self.mask_frame_point(p, self.canvas_rect) else { return false };
        self.set_drag(Some(Drag::MaskTool { mode, start: n, start_view: p, modifiers, moved: false }));
        true
    }

    /// A press on mask handles: a vertex selects its mask; Cmd / Ctrl removes it, Option / Alt toggles smooth, else it
    /// drags. Tangents, the outline (pen) and the inside (move) start their drags.
    fn press_mask(&mut self, hit: MaskHit, p: CGPoint, modifiers: InputModifiers) -> bool {
        match hit {
            MaskHit::Tangent(mi, vi, is_out) => {
                let m = &self.masks[mi];
                let v = &m.path.vertices[vi];
                let offset = if is_out { v.out_tangent } else { v.in_tangent };
                let independent = modifiers.contains(InputModifiers::OPTION);
                let id = m.id;
                self.set_drag(Some(Drag::MaskTangent { id, vertex: vi, out: is_out, last: offset, independent }));
                self.events.push(OverlayEvent::MaskEdit(
                    Phase::Began,
                    MaskHandleEdit::Tangent { mask: id, vertex: vi, out: is_out, offset, independent },
                ));
            }
            MaskHit::Vertex(mi, vi) => {
                let m = &self.masks[mi];
                let (id, point) = (m.id, m.path.vertices[vi].point);
                self.events.push(OverlayEvent::MaskSelect(id));
                if modifiers.contains(InputModifiers::COMMAND) {
                    self.click(MaskHandleEdit::Remove { mask: id, vertex: vi });
                } else if modifiers.contains(InputModifiers::OPTION) {
                    self.click(MaskHandleEdit::ToggleSmooth { mask: id, vertex: vi });
                } else {
                    self.set_drag(Some(Drag::MaskVertex(id, vi)));
                    self.events.push(OverlayEvent::MaskVertex(Phase::Began, id, vi, point));
                }
            }
            MaskHit::Segment(mi, seg, t) => {
                let id = self.masks[mi].id;
                let base = self.masks[mi].path.clone();
                self.set_drag(Some(Drag::MaskPen { id, segment: seg, t, base, last: Vec2::ZERO, independent: false }));
                let edit = MaskHandleEdit::Pen { mask: id, segment: seg, t, handle: Vec2::ZERO, independent: false };
                self.events.push(OverlayEvent::MaskEdit(Phase::Began, edit));
                self.events.push(OverlayEvent::MaskEdit(Phase::Changed, edit));
                self.masks[mi].path = self.masks[mi].path.splitting(seg, t);
            }
            MaskHit::Inside(mi) => {
                let Some(n) = self.mask_geometry(self.canvas_rect).frame_point(p) else { return true };
                let id = self.masks[mi].id;
                let base = self.masks[mi].path.clone();
                self.set_drag(Some(Drag::MaskMove { id, start: n, base, last: Vec2::ZERO }));
                self.events
                    .push(OverlayEvent::MaskEdit(Phase::Began, MaskHandleEdit::Move { mask: id, delta: Vec2::ZERO }));
            }
        }
        true
    }

    fn click(&mut self, e: MaskHandleEdit) {
        self.events.push(OverlayEvent::MaskEdit(Phase::Began, e));
        self.events.push(OverlayEvent::MaskEdit(Phase::Ended, e));
    }

    pub(crate) fn mask_dragged(&mut self, d: &Drag, p: CGPoint, shift: bool, option: bool) {
        let g = self.mask_geometry(self.canvas_rect);
        match d {
            Drag::MaskVertex(id, i) => {
                let Some(n) = g.frame_point(p) else { return };
                if let Some(mi) = self.masks.iter().position(|m| m.id == *id) {
                    self.masks[mi].path.move_vertex(*i, n);
                }
                self.events.push(OverlayEvent::MaskVertex(Phase::Changed, *id, *i, n));
            }
            Drag::MaskTangent { id, vertex, out, .. } => {
                let Some(n) = g.frame_point(p) else { return };
                let Some(mi) = self.masks.iter().position(|m| m.id == *id) else { return };
                if *vertex >= self.masks[mi].path.vertices.len() {
                    return;
                }
                let offset = n - self.masks[mi].path.vertices[*vertex].point;
                self.masks[mi].path.set_tangent(*vertex, *out, offset, option);
                self.drag =
                    Some(Drag::MaskTangent { id: *id, vertex: *vertex, out: *out, last: offset, independent: option });
                self.events.push(OverlayEvent::MaskEdit(
                    Phase::Changed,
                    MaskHandleEdit::Tangent { mask: *id, vertex: *vertex, out: *out, offset, independent: option },
                ));
            }
            Drag::MaskPen { id, segment, t, base, .. } => {
                let Some(n) = g.frame_point(p) else { return };
                let Some(mi) = self.masks.iter().position(|m| m.id == *id) else { return };
                if *segment >= base.vertices.len() {
                    return;
                }
                let handle = n - base.splitting(*segment, *t).vertices[*segment + 1].point;
                self.masks[mi].path = base.placing_vertex(*segment, *t, handle, option);
                self.drag = Some(Drag::MaskPen {
                    id: *id,
                    segment: *segment,
                    t: *t,
                    base: base.clone(),
                    last: handle,
                    independent: option,
                });
                self.events.push(OverlayEvent::MaskEdit(
                    Phase::Changed,
                    MaskHandleEdit::Pen { mask: *id, segment: *segment, t: *t, handle, independent: option },
                ));
            }
            Drag::MaskMove { id, start, base, .. } => {
                let Some(n) = g.frame_point(p) else { return };
                let mut delta = n - *start;
                if shift {
                    // Shift: one axis
                    if delta.x.abs() >= delta.y.abs() {
                        delta.y = 0.0;
                    } else {
                        delta.x = 0.0;
                    }
                }
                if let Some(mi) = self.masks.iter().position(|m| m.id == *id) {
                    self.masks[mi].path = base.translated(delta);
                }
                self.drag = Some(Drag::MaskMove { id: *id, start: *start, base: base.clone(), last: delta });
                self.events.push(OverlayEvent::MaskEdit(Phase::Changed, MaskHandleEdit::Move { mask: *id, delta }));
            }
            Drag::MaskTool { mode, start, start_view, modifiers, moved } => {
                let far = !MaskShapeDrag::is_click((p.x - start_view.x).hypot(p.y - start_view.y));
                if !(*moved || far) {
                    return;
                }
                if !*moved {
                    self.drag = Some(Drag::MaskTool {
                        mode: *mode,
                        start: *start,
                        start_view: *start_view,
                        modifiers: *modifiers,
                        moved: true,
                    });
                }
                let (Some(kind), Some(n)) = (mode.shape_kind(), g.frame_point(p)) else { return };
                self.draw_preview =
                    Some(MaskShapeDrag { kind, start: *start }.path(n, shift, option, g.frame_extent()));
            }
            _ => {}
        }
    }

    pub(crate) fn mask_up(&mut self, d: &Drag, p: CGPoint) {
        self.masks_at_press = None;
        let g = self.mask_geometry(self.canvas_rect);
        match d {
            Drag::MaskVertex(id, i) => {
                let n = g.frame_point(p).or_else(|| {
                    self.masks.iter().find(|m| m.id == *id).and_then(|m| m.path.vertices.get(*i)).map(|v| v.point)
                });
                self.events.push(OverlayEvent::MaskVertex(Phase::Ended, *id, *i, n.unwrap_or(Vec2::ZERO)));
            }
            Drag::MaskTangent { id, vertex, out, last, independent } => {
                self.events.push(OverlayEvent::MaskEdit(
                    Phase::Ended,
                    MaskHandleEdit::Tangent {
                        mask: *id,
                        vertex: *vertex,
                        out: *out,
                        offset: *last,
                        independent: *independent,
                    },
                ));
            }
            Drag::MaskPen { id, segment, t, last, independent, .. } => {
                self.events.push(OverlayEvent::MaskEdit(
                    Phase::Ended,
                    MaskHandleEdit::Pen {
                        mask: *id,
                        segment: *segment,
                        t: *t,
                        handle: *last,
                        independent: *independent,
                    },
                ));
            }
            Drag::MaskMove { id, last, .. } => {
                self.events
                    .push(OverlayEvent::MaskEdit(Phase::Ended, MaskHandleEdit::Move { mask: *id, delta: *last }));
            }
            Drag::MaskTool { mode, start, start_view, modifiers, moved } => {
                if *mode == MaskToolMode::Magic {
                    // A drag is a box prompt, a click a point prompt.
                    match g.frame_point(p).filter(|_| *moved) {
                        Some(end) => self.events.push(OverlayEvent::MaskToolBox(*start, end, *modifiers)),
                        None => self.events.push(OverlayEvent::MaskToolClick(*start, *modifiers)),
                    }
                    return;
                }
                let shape = self.draw_preview.take();
                if *moved && let Some(kind) = mode.shape_kind() {
                    if let Some(shape) = shape {
                        self.events.push(OverlayEvent::MaskShapeDrawn(kind, shape));
                    }
                    return;
                }
                // A click: inside another mask with a shape mode selects that mask, else the tool's click (Pen point,
                // default-size shape centered there).
                if *mode != MaskToolMode::Pen
                    && let Some(mi) = g.hit_any_inside(*start_view, &self.masks)
                {
                    self.events.push(OverlayEvent::MaskSelect(self.masks[mi].id));
                    return;
                }
                self.events.push(OverlayEvent::MaskToolClick(*start, *modifiers));
            }
            _ => {}
        }
    }

    // MARK: Drawing

    /// Mask outlines (flattened paths) and their vertices, on the layer: the active mask with filled squares and its
    /// Bezier handles, the others hollow.
    pub(crate) fn draw_masks(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        if self.masks.is_empty() {
            return;
        }
        let g = self.mask_geometry(r);
        let shadow = t.on_picture_shadow();
        for m in &self.masks {
            let pts = g.outline(&m.path);
            if pts.len() <= 1 {
                continue;
            }
            c.stroke_polygon(&pts, 3.0, shadow);
            c.stroke_polygon(&pts, 1.0, t.yellow());
            if m.active {
                self.draw_tangent_handles(c, &m.path, &g, t);
            }
            for v in &m.path.vertices {
                let p = g.view_point(v.point);
                let sq = CGRect::new(p.x - 3.5, p.y - 3.5, 7.0, 7.0);
                c.fill(sq, if m.active { t.yellow() } else { shadow });
                c.stroke_polygon(&sq.corner_points(), 1.0, shadow);
                if !m.active {
                    c.stroke_polygon(&sq.inset_by(1.0, 1.0).corner_points(), 1.0, t.yellow());
                }
            }
        }
    }

    /// The Rectangle / Ellipse being dragged out, as the committed mask will look.
    pub(crate) fn draw_shape_preview(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        let Some(path) = &self.draw_preview else { return };
        let pts = self.mask_geometry(r).outline(path);
        if pts.len() <= 1 {
            return;
        }
        c.stroke_polygon(&pts, 3.0, t.on_picture_shadow());
        c.stroke_polygon(&pts, 1.0, t.yellow());
    }

    fn draw_tangent_handles(&self, c: &mut Canvas, path: &MaskPath, g: &MaskOverlayGeometry, t: &DrawTheme) {
        let mut dots: Vec<CGPoint> = Vec::new();
        for v in &path.vertices {
            let p = g.view_point(v.point);
            for tan in [v.in_tangent, v.out_tangent] {
                if tan != Vec2::ZERO {
                    let h = g.view_point(v.point + tan);
                    c.stroke_line(p, h, 1.0, t.label2());
                    dots.push(h);
                }
            }
        }
        for h in dots {
            let dot = CGRect::new(h.x - 3.5, h.y - 3.5, 7.0, 7.0);
            c.fill_ellipse(dot, t.yellow());
            c.stroke_ellipse(dot, 1.0, t.on_picture_shadow());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MaskShapeKind;
    use sq_core_time::Id;
    use sq_draw::monitor::mask_overlay_geometry::MaskOverlay;
    use sq_uikit::controls_grid::CGSize;

    fn rect() -> CGRect {
        CGRect::new(100.0, 50.0, 960.0, 540.0)
    }

    fn overlay_with_mask(tool: Option<MaskToolMode>) -> TransformOverlay {
        let mut o = TransformOverlay::new();
        o.is_shown = true;
        o.media_pixel_size = Some(CGSize::new(1920.0, 1080.0));
        o.mask_tool = tool;
        let path = MaskPath::rectangle(Vec2::new(0.25, 0.25), Vec2::new(0.75, 0.75));
        o.masks = vec![MaskOverlay::new(Id::from_u128(1), path, true)];
        o
    }

    #[test]
    fn a_vertex_press_selects_its_mask_and_drags_it() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let v = o.mask_geometry(r).view_point(Vec2::new(0.25, 0.25));
        assert!(o.mouse_down(v, InputModifiers::NONE, r));
        assert!(o.is_dragging());
        let events = o.take_events();
        assert!(matches!(events[0], OverlayEvent::MaskSelect(_)));
        assert!(matches!(events[1], OverlayEvent::MaskVertex(Phase::Began, ..)));
        o.mouse_dragged(CGPoint::new(v.x + 20.0, v.y));
        assert!(o.masks[0].path.vertices[0].point.x > 0.25);
        // Esc puts the masks back as they were at the press.
        assert!(o.cancel_drag());
        assert_eq!(o.masks[0].path.vertices[0].point, Vec2::new(0.25, 0.25));
    }

    #[test]
    fn a_mask_tool_click_inside_the_layer_reports_the_frame_fraction() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Pen));
        let p = CGPoint::new(r.x + r.width * 0.1, r.y + r.height * 0.1);
        assert!(o.mouse_down(p, InputModifiers::NONE, r));
        o.mouse_up(p);
        let clicks: Vec<Vec2> = o
            .take_events()
            .iter()
            .filter_map(|e| if let OverlayEvent::MaskToolClick(v, _) = e { Some(*v) } else { None })
            .collect();
        assert_eq!(clicks.len(), 1);
        assert!((clicks[0].x - 0.1).abs() < 1e-6 && (clicks[0].y - 0.1).abs() < 1e-6);
    }

    #[test]
    fn dragging_with_the_ellipse_tool_draws_a_shape_on_release() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Ellipse));
        let a = CGPoint::new(r.x + 20.0, r.y + 20.0);
        assert!(o.mouse_down(a, InputModifiers::NONE, r));
        o.mouse_dragged(CGPoint::new(a.x + 100.0, a.y + 80.0));
        assert!(o.draw_preview.is_some());
        o.mouse_up(CGPoint::new(a.x + 100.0, a.y + 80.0));
        assert!(o.take_events().iter().any(|e| matches!(e, OverlayEvent::MaskShapeDrawn(..))));
        assert!(o.draw_preview.is_none());
    }

    #[test]
    fn the_magic_switch_flips_add_and_remove() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Magic));
        let (add, remove) = o.magic_switch_rects(r);
        assert!(o.mouse_down(CGPoint::new(remove.mid_x(), remove.mid_y()), InputModifiers::NONE, r));
        assert!(o.magic_subtract);
        assert!(o.mouse_down(CGPoint::new(add.mid_x(), add.mid_y()), InputModifiers::NONE, r));
        assert!(!o.magic_subtract);
    }

    #[test]
    fn magic_click_reports_a_point_and_a_drag_reports_a_box() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Magic));
        assert!(o.mouse_down(view(0.4, 0.4), InputModifiers::NONE, r));
        o.mouse_up(view(0.4, 0.4));
        assert!(matches!(o.take_events().as_slice(), [OverlayEvent::MaskToolClick(..)]));
        assert!(o.mouse_down(view(0.2, 0.3), InputModifiers::NONE, r));
        o.mouse_dragged(view(0.6, 0.7));
        o.mouse_up(view(0.6, 0.7));
        let events = o.take_events();
        let [OverlayEvent::MaskToolBox(a, b, _)] = events.as_slice() else {
            panic!("expected one box, got {events:?}")
        };
        assert!(near(*a, Vec2::new(0.2, 0.3)) && near(*b, Vec2::new(0.6, 0.7)));
    }

    #[test]
    fn magic_hover_reports_only_changes() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Magic));
        let inside = CGPoint::new(r.mid_x(), r.mid_y());
        o.pointer_moved(inside, r);
        o.pointer_moved(inside, r);
        o.pointer_moved(CGPoint::new(0.0, 0.0), r);
        let hovers = o.take_events().iter().filter(|e| matches!(e, OverlayEvent::MaskToolHover(_))).count();
        assert_eq!(hovers, 2);
    }

    fn view(x: f64, y: f64) -> CGPoint {
        let r = rect();
        CGPoint::new(r.x + 960.0 * x, r.y + 540.0 * y)
    }

    fn near(a: Vec2, b: Vec2) -> bool {
        (a.x - b.x).abs() < 1e-6 && (a.y - b.y).abs() < 1e-6
    }

    fn edits(o: &mut TransformOverlay) -> Vec<(Phase, MaskHandleEdit)> {
        o.take_events()
            .into_iter()
            .filter_map(|e| if let OverlayEvent::MaskEdit(p, e) = e { Some((p, e)) } else { None })
            .collect()
    }

    #[test]
    fn vertex_drag_reports_the_new_point_and_no_transform() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let id = o.masks[0].id;
        assert!(o.mouse_down(view(0.25, 0.25), InputModifiers::NONE, r));
        o.mouse_dragged(view(0.3, 0.35));
        o.mouse_up(view(0.3, 0.35));
        let ev = o.take_events();
        let v: Vec<(Phase, Vec2)> = ev
            .iter()
            .filter_map(|e| {
                if let OverlayEvent::MaskVertex(p, i, _, v) = e {
                    assert_eq!(*i, id);
                    Some((*p, *v))
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(v.iter().map(|x| x.0).collect::<Vec<_>>(), [Phase::Began, Phase::Changed, Phase::Ended]);
        assert!(near(v[2].1, Vec2::new(0.3, 0.35)));
        assert!(!ev.iter().any(|e| matches!(e, OverlayEvent::Transform(..))));
    }

    #[test]
    fn ctrl_click_removes_a_vertex_and_alt_click_toggles_smooth() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let id = o.masks[0].id;
        let i =
            o.masks[0].path.vertices.iter().position(|v| near(v.point, Vec2::new(0.75, 0.25))).unwrap_or(usize::MAX);
        o.mouse_down(view(0.75, 0.25), InputModifiers::COMMAND, r);
        assert!(!o.is_dragging());
        let e = edits(&mut o);
        assert_eq!(e.iter().map(|x| x.0).collect::<Vec<_>>(), [Phase::Began, Phase::Ended]);
        assert_eq!(e.last().map(|x| x.1), Some(MaskHandleEdit::Remove { mask: id, vertex: i }));
        o.mouse_down(view(0.75, 0.25), InputModifiers::OPTION, r);
        assert_eq!(edits(&mut o).last().map(|x| x.1), Some(MaskHandleEdit::ToggleSmooth { mask: id, vertex: i }));
    }

    #[test]
    fn drag_inside_moves_the_whole_mask_and_esc_puts_it_back() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let before = o.masks.clone();
        let id = o.masks[0].id;
        assert!(o.mouse_down(view(0.5, 0.5), InputModifiers::NONE, r));
        o.mouse_dragged(view(0.6, 0.5));
        let Some((_, MaskHandleEdit::Move { mask, delta })) = edits(&mut o).into_iter().last() else {
            panic!("no move")
        };
        assert!(mask == id && near(delta, Vec2::new(0.1, 0.0)));
        assert!(o.masks != before);
        assert!(o.cancel_drag());
        assert!(o.masks == before);
        assert_eq!(o.take_events().iter().filter(|e| **e == OverlayEvent::DragCanceled).count(), 1);
    }

    #[test]
    fn press_on_the_outline_adds_a_vertex_and_pulls_its_handle() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let count = o.masks[0].path.vertices.len();
        assert!(o.mouse_down(view(0.5, 0.25), InputModifiers::NONE, r));
        assert_eq!(o.masks[0].path.vertices.len(), count + 1);
        o.mouse_dragged(view(0.55, 0.25));
        o.mouse_up(view(0.55, 0.25));
        let Some((phase, MaskHandleEdit::Pen { handle, .. })) = edits(&mut o).into_iter().last() else {
            panic!("no pen edit")
        };
        assert_eq!(phase, Phase::Ended);
        assert!(near(handle, Vec2::new(0.05, 0.0)));
    }

    #[test]
    fn rectangle_tool_drag_draws_one_shape_and_no_transform() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Rectangle));
        o.masks = Vec::new();
        assert!(o.mouse_down(view(0.1, 0.1), InputModifiers::NONE, r));
        o.mouse_dragged(view(0.2, 0.3));
        assert!(o.draw_preview.is_some());
        o.mouse_up(view(0.2, 0.3));
        let ev = o.take_events();
        assert_eq!(
            ev.iter().filter(|e| matches!(e, OverlayEvent::MaskShapeDrawn(MaskShapeKind::Rectangle, _))).count(),
            1
        );
        assert!(!ev.iter().any(|e| matches!(e, OverlayEvent::MaskToolClick(..) | OverlayEvent::Transform(..))));
        assert!(o.draw_preview.is_none());
    }

    #[test]
    fn pen_tool_click_reports_the_frame_point_and_off_the_layer_falls_through() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Pen));
        assert!(o.mouse_down(view(0.1, 0.9), InputModifiers::NONE, r));
        o.mouse_up(view(0.1, 0.9));
        let clicks: Vec<Vec2> = o
            .take_events()
            .into_iter()
            .filter_map(|e| if let OverlayEvent::MaskToolClick(v, _) = e { Some(v) } else { None })
            .collect();
        assert!(clicks.len() == 1 && near(clicks[0], Vec2::new(0.1, 0.9)));
        // Off the layer the tool takes nothing: the press falls through to the monitor.
        assert!(!o.mouse_down(CGPoint::new(50.0, 20.0), InputModifiers::NONE, r));
    }

    #[test]
    fn shape_tool_click_inside_another_mask_selects_it() {
        let r = rect();
        let mut o = overlay_with_mask(Some(MaskToolMode::Ellipse));
        let id = o.masks[0].id;
        o.masks[0].active = false; // the active mask's inside moves it; another mask's inside selects it
        o.mouse_down(view(0.5, 0.5), InputModifiers::NONE, r);
        o.mouse_up(view(0.5, 0.5));
        let ev = o.take_events();
        assert!(!ev.iter().any(|e| matches!(e, OverlayEvent::MaskToolClick(..))));
        assert_eq!(
            ev.iter().rev().find_map(|e| if let OverlayEvent::MaskSelect(i) = e { Some(*i) } else { None }),
            Some(id)
        );
    }

    #[test]
    fn mask_outline_and_vertices_are_drawn_and_the_tint_needs_a_slot() {
        let r = rect();
        let mut o = overlay_with_mask(None);
        let mut c = sq_draw::canvas::Canvas::with_size(1200.0, 700.0, None, 1.0);
        o.draw(&mut c, r, &sq_draw::theme::DrawTheme::default());
        assert!(c.list.quads().len() > 10);
        o.mask_tool = Some(MaskToolMode::Pen);
        o.mask_tint_slot = Some(3);
        let mut c2 = sq_draw::canvas::Canvas::with_size(1200.0, 700.0, None, 1.0);
        o.draw(&mut c2, r, &sq_draw::theme::DrawTheme::default());
        assert!(c2.list.quads().iter().any(|q| q.kind == sq_draw::QuadKind::Image && q.slot == 3.0));
    }
}
