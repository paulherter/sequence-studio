// Swift: SQAppShell/Monitors/MonitorHost+PictureTools.swift (toggleDynamicZoomEdit, refreshDynamicZoomEdit, zoomEditChanged)
//! The Dynamic Zoom editor on the Program card: the host starts it on the selected picture clip, feeds it the clip's
//! windows and the layer geometry each frame, and writes its drags back as one undo step per drag.

use super::MonitorHost;
use sq_core_effects::dynamic_zoom::ZoomEase;
use sq_core_time::Id;
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::monitor::zoom_edit_geometry::ZoomEditGeometry;
use sq_draw_monitor::transform_overlay::Phase;
use sq_draw_monitor::zoom_edit_overlay::{ZoomEditEvent, ZoomEditOverlay};
use sq_editor_session::{EditorSession, OverlayTarget};
use sq_uikit::controls_grid::CGSize;

/// Swift `zoomEditRun`: the clip being edited, its ease, and the state of the running drag.
#[derive(Clone, Copy, Debug)]
pub(super) struct ZoomRun {
    clip: Id,
    ease: ZoomEase,
    dragging: bool,
    wrote: bool,
}

impl MonitorHost {
    /// Sequence > Video Options > Edit Dynamic Zoom: starts the editor on the selected picture clip under the playhead,
    /// or ends it when it runs. `false` when there is no such clip.
    pub fn toggle_dynamic_zoom_edit(&mut self, session: &EditorSession) -> bool {
        if self.zoom_run.is_some() {
            self.end_dynamic_zoom_edit();
            return true;
        }
        let Some((clip, _)) = zoom_edit_target(session) else { return false };
        let Some(w) = session.dynamic_zoom_windows(&clip) else { return false };
        let mut z = ZoomEditOverlay::new();
        z.start = w.start;
        z.set_end(w.end);
        self.panel.zoom_edit = Some(z);
        self.zoom_run = Some(ZoomRun { clip: clip.id, ease: w.ease, dragging: false, wrote: false });
        self.refresh_dynamic_zoom_edit(session);
        true
    }

    /// Closes the editor.
    pub fn end_dynamic_zoom_edit(&mut self) {
        self.panel.zoom_edit = None;
        self.zoom_run = None;
    }

    /// Whether the editor runs (the menu check, tests).
    pub fn is_editing_dynamic_zoom(&self) -> bool {
        self.zoom_run.is_some()
    }

    /// Per frame: the editor closes when its clip is no longer the one shown; otherwise it takes the clip's windows and
    /// the layer geometry.
    pub(super) fn refresh_dynamic_zoom_edit(&mut self, session: &EditorSession) {
        let Some(run) = self.zoom_run else { return };
        if self.panel.zoom_edit.is_none() {
            return;
        }
        let (seq, canvas) = (self.panel.sequence_size(), self.panel.canvas_rect());
        let Some((clip, target)) = zoom_edit_target(session).filter(|(c, _)| c.id == run.clip) else {
            self.end_dynamic_zoom_edit();
            return;
        };
        let Some(z) = self.panel.zoom_edit.as_mut() else { return };
        let size = target.size;
        let aspect = if size.height > 0.0 { size.width / size.height } else { 16.0 / 9.0 };
        z.geometry = ZoomEditGeometry::new(TransformOverlayGeometry::new(
            seq,
            canvas,
            aspect,
            target.display_transform(),
            Some(CGSize::new(size.width, size.height)),
        ));
        if !run.dragging
            && let Some(w) = session.dynamic_zoom_windows(&clip)
        {
            if z.start != w.start {
                z.start = w.start;
            }
            if z.end() != w.end {
                z.set_end(w.end);
            }
            if let Some(r) = self.zoom_run.as_mut() {
                r.ease = w.ease;
            }
        }
    }

    /// Runs what the editor reported: live window changes become one undo step per drag, Done closes it.
    pub(super) fn route_zoom_edit(&mut self, session: &mut EditorSession) {
        let events = self.panel.zoom_edit.as_mut().map(|z| std::mem::take(&mut z.events)).unwrap_or_default();
        for e in events {
            let Some(run) = self.zoom_run else { return };
            match e {
                ZoomEditEvent::Done => self.end_dynamic_zoom_edit(),
                ZoomEditEvent::Change(Phase::Began, ..) => {
                    session.stop_playback();
                    if let Some(r) = self.zoom_run.as_mut() {
                        r.dragging = true;
                        r.wrote = false;
                    }
                }
                ZoomEditEvent::Change(phase, start, end) => {
                    if session.set_dynamic_zoom_windows(run.clip, &start, &end, run.ease, run.wrote)
                        && let Some(r) = self.zoom_run.as_mut()
                    {
                        r.wrote = true;
                    }
                    if phase == Phase::Ended {
                        if let Some(r) = self.zoom_run.as_mut() {
                            r.dragging = false;
                        }
                        self.refresh_dynamic_zoom_edit(session);
                    }
                }
            }
        }
    }
}

/// The selected, shown picture clip (not text, not a graphic) and its overlay target.
fn zoom_edit_target(session: &EditorSession) -> Option<(sq_core_model::Clip, OverlayTarget)> {
    let tl = session.display_timeline()?;
    let clip = session.displayed_selected_clip()?;
    let t = OverlayTarget::make(&clip, session.project(), &tl, session.playhead(), session.active_variant_id())?;
    (!t.is_text && !t.is_graphics).then_some((clip, t))
}
