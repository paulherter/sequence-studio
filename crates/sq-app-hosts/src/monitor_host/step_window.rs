// Swift: ColorPageHost.swift (refreshStepWindow, makeStepWindow)
//! The Color page's Step window handles on the Program card: shown while a windowed Step of the clip on the monitor is
//! selected (not for a text or graphic, not while text is typed); the host hands each drag to the grade controller.

use super::MonitorHost;
use sq_core_model::StepWindow;
use sq_draw::monitor::step_window_edit_geometry::StepWindowEditGeometry;
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::monitor::zoom_edit_geometry::ZoomEditGeometry;
use sq_draw_monitor::step_window_overlay::StepWindowOverlay;
use sq_draw_monitor::transform_overlay::Phase;
use sq_editor_session::{EditorSession, OverlayTarget};
use sq_inspector_ui::color::color_grade_controller::WindowEditTarget;
use sq_uikit::controls_grid::CGSize;

impl MonitorHost {
    /// Per frame: the handles follow the Step's window and the layer's geometry; they go when the Step, the clip or the
    /// page no longer fits (a running drag keeps them).
    pub fn refresh_step_window(&mut self, session: &EditorSession, edit: Option<&WindowEditTarget>) {
        let target = edit.and_then(|t| {
            let (tl, clip) =
                (session.display_timeline()?, session.displayed_selected_clip().filter(|c| c.id == t.clip)?);
            OverlayTarget::make(&clip, session.project(), &tl, session.playhead(), session.active_variant_id())
                .filter(|o| !o.is_text && !o.is_graphics)
                .map(|o| (o, t.window.clone()))
        });
        let Some((target, window)) = target.filter(|_| !self.panel.text_field.is_editing()) else {
            if !self.panel.step_window_edit.as_ref().is_some_and(StepWindowOverlay::is_dragging) {
                self.panel.step_window_edit = None;
            }
            return;
        };
        let (seq, canvas) = (self.panel.sequence_size(), self.panel.canvas_rect());
        let v = self.panel.step_window_edit.get_or_insert_with(StepWindowOverlay::new);
        let size = target.size;
        let aspect = if size.height > 0.0 { size.width / size.height } else { 16.0 / 9.0 };
        v.geometry = StepWindowEditGeometry::new(ZoomEditGeometry::new(TransformOverlayGeometry::new(
            seq,
            canvas,
            aspect,
            target.display_transform(),
            Some(CGSize::new(size.width, size.height)),
        )));
        if !v.is_dragging() && v.step_window != window {
            v.step_window = window;
        }
    }

    /// The window drags since the last call, for the grade controller (begin, change* and end of one drag).
    pub fn take_step_window_events(&mut self) -> Vec<(Phase, StepWindow)> {
        self.panel.step_window_edit.as_mut().map(|s| std::mem::take(&mut s.events)).unwrap_or_default()
    }
}
