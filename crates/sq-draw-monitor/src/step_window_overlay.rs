// Swift: StepWindowOverlay.swift
//! The window of the selected Color Step on the Program monitor (the Mac `StepWindowOverlayView` on the draw list): its
//! outline, a center handle, edge handles that resize, a rotate handle and the body to move it. Maths in
//! `StepWindowEditGeometry`; the host writes each change into the Step (one drag = one undo step). A press that hits no
//! handle and not the body goes on to the monitor. Window points, like `MonitorPanel`.

use crate::transform_overlay::Phase;
use sq_core_model::{ClipTransform, StepWindow, StepWindowShape};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::step_window_edit_geometry::{Edge, Hit, StepWindowEditGeometry};
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::monitor::zoom_edit_geometry::ZoomEditGeometry;
use sq_draw::theme::DrawTheme;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// The Step window editor.
pub struct StepWindowOverlay {
    /// The geometry over the picture, set by the host.
    pub geometry: StepWindowEditGeometry,
    /// The window shown.
    pub step_window: StepWindow,
    /// The window changed (live): the host writes it into the Step.
    pub events: Vec<(Phase, StepWindow)>,
    drag: Option<(Hit, CGPoint, StepWindow)>,
}

impl Default for StepWindowOverlay {
    fn default() -> Self {
        Self::new()
    }
}

impl StepWindowOverlay {
    /// Grab radius of a handle in view points.
    const HANDLE_RADIUS: f64 = 8.0;

    /// An editor over a 1920 x 1080 layer.
    pub fn new() -> StepWindowOverlay {
        let layer = TransformOverlayGeometry::new(
            CGSize::new(1920.0, 1080.0),
            CGRect::default(),
            16.0 / 9.0,
            ClipTransform::IDENTITY,
            None,
        );
        StepWindowOverlay {
            geometry: StepWindowEditGeometry::new(ZoomEditGeometry::new(layer)),
            step_window: StepWindow::default(),
            events: Vec::new(),
            drag: None,
        }
    }

    /// A drag runs.
    pub fn is_dragging(&self) -> bool {
        self.drag.is_some()
    }

    /// A left press; true when a handle or the body took it.
    pub fn mouse_down(&mut self, p: CGPoint) -> bool {
        let Some(hit) = self.geometry.hit_test(p, &self.step_window, Self::HANDLE_RADIUS) else { return false };
        self.drag = Some((hit, p, self.step_window.clone()));
        self.events.push((Phase::Began, self.step_window.clone()));
        true
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint) {
        let Some((hit, press, base)) = &self.drag else { return };
        self.step_window = self.geometry.dragged(*hit, *press, p, base);
        self.events.push((Phase::Changed, self.step_window.clone()));
    }

    /// The button went up.
    pub fn mouse_up(&mut self, _p: CGPoint) {
        if self.drag.take().is_none() {
            return;
        }
        self.events.push((Phase::Ended, self.step_window.clone()));
    }

    /// Esc during a drag puts the window back where the press found it.
    pub fn cancel_drag(&mut self) -> bool {
        let Some((_, _, base)) = self.drag.take() else { return false };
        self.step_window = base;
        self.events.push((Phase::Ended, self.step_window.clone()));
        true
    }

    /// Draws the window.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        let w = &self.step_window;
        let pts = self.geometry.outline(w, 64);
        if pts.len() < 2 {
            return;
        }
        if w.shape == StepWindowShape::Linear {
            c.stroke_polyline(&pts, 3.0, t.on_picture_shadow());
            c.stroke_polyline(&pts, 1.5, t.accent());
        } else {
            c.stroke_polygon(&pts, 3.0, t.on_picture_shadow());
            c.stroke_polygon(&pts, 1.5, t.accent());
        }
        let dot = |c: &mut Canvas, p: CGPoint, filled: bool| {
            let h = CGRect::new(p.x - 4.0, p.y - 4.0, 8.0, 8.0);
            c.fill_ellipse(h, if filled { t.accent() } else { t.on_picture_stroke() });
            c.stroke_ellipse(h, 1.0, t.on_picture_shadow());
        };
        for e in Edge::ALL {
            if let Some(p) = self.geometry.edge_point(e, w) {
                dot(c, p, true);
            }
        }
        let center = self.geometry.center_point(w);
        let r = self.geometry.rotate_point(w);
        c.stroke_line(center, r, 1.0, t.guide());
        dot(c, r, false);
        dot(c, center, true);
    }
}
