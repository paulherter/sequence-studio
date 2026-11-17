// Swift: MonitorPanel+PictureTools.swift
//! Tools on the Program / Source picture, translated from the Mac ProgramSurfaceView, ZoomEditOverlayView,
//! StepWindowOverlayView and AnglesGridView: the Dynamic Zoom and Color Step window editors, the multi-angle tiles, the
//! Create tool drag (shapes, lines, freehand strokes) and the caption press (drag moves it with snapping, double-click
//! edits it). The host owns the model edits; the panel reports positions in sequence px from the canvas center.

use crate::angle_tile::AnglesGridLayout;
use crate::cg::RectExt;
use crate::create_tool_drag::{CreateOutline, CreateToolDrag};
use crate::monitor_panel::{MonitorPanel, PanelEvent};
use crate::monitor_panel_model::MonitorEvent;
use crate::transform_overlay::TransformOverlay;
use sq_app_shell::HostCx;
use sq_core_model::ShapeKind;
use sq_core_time::Vec2;
use sq_draw::canvas::Canvas;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::theme::{DrawTheme, spacing, type_size};
use sq_draw::{InputKey, InputModifiers, TextAlign};
use sq_editor_session::es01_session_core::CreateToolMode;
use sq_editor_session::es02_timeline_ops::SnapResult;
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl MonitorPanel {
    /// Smallest drag (view points) that moves a caption; a click on the text only selects it (ProgramSurfaceView).
    pub(crate) const MIN_CAPTION_DRAG: f64 = 3.0;

    pub(crate) fn picture_tool_dragging(&self) -> bool {
        self.create_drag.is_some()
            || self.caption_press.is_some()
            || self.zoom_edit.as_ref().is_some_and(|z| z.is_dragging())
            || self.step_window_edit.as_ref().is_some_and(|s| s.is_dragging())
    }

    /// The press on the picture for one of the tools here; false lets it go on (guides, transform box, pick).
    pub(crate) fn begin_picture_tool_press(&mut self, p: CGPoint, _modifiers: InputModifiers, cx: &mut HostCx) -> bool {
        if self.shows_angles_grid() {
            if let Some(i) = AnglesGridLayout::index(p, &self.angle_cells()) {
                self.model.emit(MonitorEvent::PickAngle(i));
            }
            return true;
        }
        if self.model.mode != MonitorMode::Program {
            return false;
        }
        let now = self.now;
        let slot = self.slot;
        let scale = self.scale;
        if let Some(z) = self.zoom_edit.as_mut() {
            let double = self.last_press.is_some_and(|(time, at)| {
                now - time <= Self::DOUBLE_CLICK_INTERVAL && (p.x - at.x).hypot(p.y - at.y) <= 4.0
            });
            self.last_press = Some((now, p));
            z.layout(slot);
            let _ = z.mouse_down(p, if double { 2 } else { 1 }, scale);
            return true; // the Mac editor view covers the picture: a press outside its windows reaches nothing else
        }
        if let Some(s) = self.step_window_edit.as_mut()
            && s.mouse_down(p)
        {
            return true;
        }
        if let Some(mode) = self.create_mode_now
            && mode != CreateToolMode::Text
            && self.wiring.create_tool
        {
            self.last_press = None;
            self.create_drag = Some(CreateToolDrag::new(mode, CGPoint::new(p.x - slot.min_x(), p.y - slot.min_y())));
            return true;
        }
        self.begin_caption_press(p, cx)
    }

    pub(crate) fn picture_tool_dragged(&mut self, p: CGPoint, cx: &mut HostCx) {
        let mods = self.overlay.modifiers_now.unwrap_or(InputModifiers::NONE);
        let scale = self.scale;
        if let Some(z) = self.zoom_edit.as_mut()
            && z.is_dragging()
        {
            z.mouse_dragged(p, mods, scale, cx.ui);
            return;
        }
        if let Some(s) = self.step_window_edit.as_mut()
            && s.is_dragging()
        {
            s.mouse_dragged(p);
            return;
        }
        let slot = self.slot;
        if let Some(d) = self.create_drag.as_mut() {
            d.move_to(
                CGPoint::new(p.x - slot.min_x(), p.y - slot.min_y()),
                mods.contains(InputModifiers::SHIFT),
                mods.contains(InputModifiers::OPTION),
            );
            return;
        }
        let k = self.view_points_per_pixel();
        let Some((start, moved, guides)) = self.caption_press.as_mut() else { return };
        if !*moved && (p.x - start.x).abs() < Self::MIN_CAPTION_DRAG && (p.y - start.y).abs() < Self::MIN_CAPTION_DRAG {
            return;
        }
        *moved = true;
        let snap = if mods.contains(InputModifiers::OPTION) { 0.0 } else { TransformOverlay::SNAP_DISTANCE / k };
        let delta = Vec2::new((p.x - start.x) / k, (p.y - start.y) / k);
        if let Some(host) = self.captions.as_mut() {
            *guides = host.caption_drag_moved(cx.session, delta, snap);
        } else {
            *guides = SnapResult::none();
        }
    }

    pub(crate) fn picture_tool_ended(&mut self, p: CGPoint, cx: &mut HostCx) {
        if let Some(z) = self.zoom_edit.as_mut()
            && z.is_dragging()
        {
            z.mouse_up(p, cx.ui);
            return;
        }
        if let Some(s) = self.step_window_edit.as_mut()
            && s.is_dragging()
        {
            s.mouse_up(p);
            return;
        }
        if let Some(mut d) = self.create_drag.take() {
            let mods = self.overlay.modifiers_now.unwrap_or(InputModifiers::NONE);
            d.move_to(
                CGPoint::new(p.x - self.slot.min_x(), p.y - self.slot.min_y()),
                mods.contains(InputModifiers::SHIFT),
                mods.contains(InputModifiers::OPTION),
            );
            self.finish_create_drag(&d);
            return;
        }
        if let Some((_, moved, _)) = self.caption_press.take()
            && moved
            && let Some(host) = self.captions.as_mut()
        {
            host.caption_drag_ended(cx.session);
        }
    }

    /// Esc ends a Create drag without making anything, puts a dragged Step window back, closes the Dynamic Zoom editor.
    pub(crate) fn picture_tool_key(&mut self, key: InputKey, modifiers: InputModifiers, cx: &mut HostCx) -> bool {
        let now = self.now;
        if let Some(z) = self.zoom_edit.as_mut()
            && z.key(key, modifiers, now, cx.ui)
        {
            return true;
        }
        if key != InputKey::Escape {
            return false;
        }
        if self.create_drag.is_some() {
            self.create_drag = None;
            return true;
        }
        if let Some(s) = self.step_window_edit.as_mut()
            && s.cancel_drag()
        {
            return true;
        }
        false
    }

    /// View points per sequence px.
    pub(crate) fn view_points_per_pixel(&self) -> f64 {
        let m = self.mapping();
        (m.scale() / m.backing_scale).max(1e-6)
    }

    // MARK: Create tool

    fn finish_create_drag(&mut self, d: &CreateToolDrag) {
        if !d.is_drag(CreateToolDrag::MIN_DRAG) {
            return;
        }
        let m = self.mapping();
        let seq = |p: Vec2| m.sequence_offset(CGPoint::new(p.x, p.y));
        match d.outline() {
            CreateOutline::Boxed(r, ellipse) => self.events.push(PanelEvent::CreateShape(
                if ellipse { ShapeKind::Ellipse } else { ShapeKind::Rectangle },
                seq(Vec2::new(r.min_x, r.min_y)),
                seq(Vec2::new(r.max_x, r.max_y)),
            )),
            CreateOutline::Line(a, b) => self.events.push(PanelEvent::CreateShape(ShapeKind::Line, seq(a), seq(b))),
            CreateOutline::Stroke(pts) => {
                let tolerance = CreateToolDrag::STROKE_TOLERANCE / self.view_points_per_pixel();
                self.events.push(PanelEvent::CreateStroke(pts.into_iter().map(seq).collect(), tolerance));
            }
        }
    }

    // MARK: Captions

    /// Select tool press on a caption's text: the second press of a double-click edits it, a press selects it and a drag
    /// moves it. Only when no Type or Create tool is on (the host's hit test answers false for the Mask tool).
    fn begin_caption_press(&mut self, p: CGPoint, cx: &mut HostCx) -> bool {
        if self.type_tool_on || self.create_mode_now.is_some() || self.overlay.mask_tool.is_some() {
            return false;
        }
        let Some(pos) = self.sequence_position(p) else { return false };
        let Some(host) = self.captions.as_mut() else { return false };
        if !host.caption_hit_test(cx.session, pos) {
            return false;
        }
        let now = self.now;
        if let Some((time, at)) = self.last_press
            && now - time <= Self::DOUBLE_CLICK_INTERVAL
            && (p.x - at.x).hypot(p.y - at.y) <= Self::TYPE_DRAG_THRESHOLD
        {
            self.last_press = None;
            self.events.push(PanelEvent::CaptionDoubleClick(pos));
            return true;
        }
        self.last_press = Some((now, p));
        if host.caption_drag_began(cx.session, pos) {
            self.caption_press = Some((p, false, SnapResult::none()));
        }
        true
    }

    // MARK: Angles

    /// Source monitor: every angle of the Angles clip under the playhead side by side (`model.angle_tiles`).
    pub(crate) fn shows_angles_grid(&self) -> bool {
        self.model.mode == MonitorMode::Source && self.model.angle_tiles.is_some()
    }

    pub(crate) fn angle_cells(&self) -> Vec<CGRect> {
        let gap = spacing::SM as f64;
        let aspect = if self.sequence_size.height > 0.0 {
            self.sequence_size.width / self.sequence_size.height
        } else {
            16.0 / 9.0
        };
        AnglesGridLayout::cells(
            self.model.angle_tiles.as_ref().map_or(0, Vec::len),
            self.slot.inset_by(gap, gap),
            aspect,
            gap,
        )
    }

    pub(crate) fn draw_angles_grid(&self, c: &mut Canvas) {
        let t = self.theme;
        let Some(tiles) = &self.model.angle_tiles else { return };
        for (i, r) in self.angle_cells().into_iter().enumerate() {
            let Some(tile) = tiles.get(i) else { continue };
            c.fill(r, t.lane());
            if let Some(pic) = tile.picture {
                c.draw_image_slot(pic.slot, r, [pic.u0, pic.v0, pic.u1, pic.v1], sq_draw::Color::WHITE);
            }
            c.draw_text(
                &format!("{}  {}", i + 1, tile.name),
                CGPoint::new(r.min_x() + spacing::SM as f64, r.min_y() + spacing::XS as f64),
                type_size::CAPTION as f64,
                t.label(),
                f64::INFINITY,
                0,
            );
            if tile.is_active || self.angle_hover == Some(i) {
                c.stroke_polygon(
                    &r.inset_by(1.0, 1.0).corner_points(),
                    if tile.is_active { 2.0 } else { 1.0 },
                    if tile.is_active { t.accent() } else { t.label3() },
                );
            }
        }
    }

    // MARK: Drawing

    pub(crate) fn draw_picture_tools(&mut self, c: &mut Canvas) {
        let t = self.theme;
        if let Some(d) = &self.create_drag
            && d.is_drag(CreateToolDrag::MIN_DRAG)
        {
            self.draw_create_drag(c, d, &t);
        }
        if let Some((_, moved, guides)) = &self.caption_press
            && *moved
        {
            self.draw_caption_guides(c, guides, &t);
        }
        if let Some(s) = &self.step_window_edit {
            s.draw(c, &t);
        }
        let slot = self.slot;
        if let Some(z) = self.zoom_edit.as_mut() {
            z.layout(slot);
            z.draw(c, &t, &mut self.draw_cx);
        }
    }

    /// ProgramSurfaceView's CreateToolPreviewView: the outline on a shadow, the size in a pill under it.
    fn draw_create_drag(&self, c: &mut Canvas, d: &CreateToolDrag, t: &DrawTheme) {
        let o = CGPoint::new(self.slot.min_x(), self.slot.min_y());
        let v = |p: Vec2| CGPoint::new(o.x + p.x, o.y + p.y);
        match d.outline() {
            CreateOutline::Boxed(r, ellipse) => {
                let rect = CGRect::new(o.x + r.min_x, o.y + r.min_y, r.width(), r.height());
                if ellipse {
                    c.stroke_ellipse(rect, 3.0, t.on_picture_shadow());
                    c.stroke_ellipse(rect, 1.5, t.on_picture_stroke());
                } else {
                    c.stroke_polygon(&rect.corner_points(), 3.0, t.on_picture_shadow());
                    c.stroke_polygon(&rect.corner_points(), 1.5, t.on_picture_stroke());
                }
            }
            CreateOutline::Line(a, b) => {
                c.stroke_line(v(a), v(b), 3.0, t.on_picture_shadow());
                c.stroke_line(v(a), v(b), 1.5, t.on_picture_stroke());
            }
            CreateOutline::Stroke(pts) => {
                let vp: Vec<CGPoint> = pts.into_iter().map(v).collect();
                c.stroke_polyline(&vp, 3.0, t.on_picture_shadow());
                c.stroke_polyline(&vp, 1.5, t.on_picture_stroke());
            }
        }
        let Some(label) = d.size_label(self.view_points_per_pixel()) else { return };
        let b = d.bounds().offset_by(o.x, o.y);
        let size = type_size::CAPTION as f64;
        let w = c.size_of(&label, size, 0).width + 12.0;
        let h = 16.0;
        let pill = CGRect::new((b.mid_x() - w / 2.0).round(), b.max_y() + spacing::XS as f64, w, h);
        c.fill_rounded(pill, h / 2.0, t.viewer_hud());
        c.draw_text_in(&label, pill, size, t.label(), TextAlign::Center, 0.0, 0);
    }

    /// The center / safe-zone lines a caption drag snapped to (GuideLinesView on the Mac).
    fn draw_caption_guides(&self, c: &mut Canvas, g: &SnapResult, t: &DrawTheme) {
        let r = self.canvas_rect;
        let k = self.view_points_per_pixel();
        for x in &g.vertical_lines {
            let vx = r.mid_x() + x * k;
            c.stroke_line(CGPoint::new(vx, r.min_y()), CGPoint::new(vx, r.max_y()), 1.0, t.guide_snap());
        }
        for y in &g.horizontal_lines {
            let vy = r.mid_y() + y * k;
            c.stroke_line(CGPoint::new(r.min_x(), vy), CGPoint::new(r.max_x(), vy), 1.0, t.guide_snap());
        }
    }
}
