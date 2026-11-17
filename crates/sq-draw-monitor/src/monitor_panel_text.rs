// Swift: MonitorPanel+Text.swift
//! The Program monitor's Type tool and text double-click (the Mac ProgramSurfaceView `typeTool` press and
//! `mouseDown(clickCount: 2)`): a click places point text, a drag out of more than 4 pt draws an area text box, a
//! double-click on the picture asks the host to edit the text under it. The host owns the text model.

use crate::cg::RectExt;
use crate::monitor_panel::{MonitorPanel, PanelEvent};
use sq_core_time::Vec2;
use sq_draw::canvas::Canvas;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl MonitorPanel {
    pub(crate) const TYPE_DRAG_THRESHOLD: f64 = 4.0;
    pub(crate) const DOUBLE_CLICK_INTERVAL: f64 = 0.4;

    /// A press on the picture: the Type tool takes it (Program only), else the second press of a double-click edits the
    /// text under the pointer. False lets the press go on to the transform box and the pick.
    pub(crate) fn begin_text_press(&mut self, p: CGPoint) -> bool {
        if self.model.mode != MonitorMode::Program {
            return false;
        }
        if self.type_tool_on && self.wiring.type_tool {
            self.last_press = None;
            self.type_press = Some((p, p));
            return true;
        }
        let now = self.now;
        if let Some((time, at)) = self.last_press
            && now - time <= Self::DOUBLE_CLICK_INTERVAL
            && (p.x - at.x).hypot(p.y - at.y) <= Self::TYPE_DRAG_THRESHOLD
            && self.wiring.text_double_click
            && let Some(pos) = self.sequence_position(p)
        {
            self.last_press = None;
            self.events.push(PanelEvent::TextDoubleClick(pos));
            return true;
        }
        self.last_press = Some((now, p));
        false
    }

    /// Hand tool press: starts a pan; the second press of a double-click fits the picture.
    pub(crate) fn begin_hand_press(&mut self, p: CGPoint) {
        let now = self.now;
        if let Some((time, at)) = self.last_press
            && now - time <= Self::DOUBLE_CLICK_INTERVAL
            && (p.x - at.x).hypot(p.y - at.y) <= Self::TYPE_DRAG_THRESHOLD
        {
            self.last_press = None;
            self.zoom_gesture(sq_core_edit::viewer_zoom::ViewerZoom::Fit);
            return;
        }
        self.last_press = Some((now, p));
        self.hand_last = Some(p);
    }

    /// The Type tool press ended: a drag drew a box (center and size in sequence px), a click places point text.
    pub(crate) fn end_type_press(&mut self, p: CGPoint) {
        let Some((start, _)) = self.type_press.take() else { return };
        let Some(a) = self.sequence_position(start) else { return };
        if (p.x - start.x).hypot(p.y - start.y) > Self::TYPE_DRAG_THRESHOLD
            && let Some(b) = self.sequence_position(p)
        {
            let size = Vec2::new((b.x - a.x).abs(), (b.y - a.y).abs());
            if size.x >= 1.0 && size.y >= 1.0 {
                self.events.push(PanelEvent::TypeBox { center: Vec2::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0), size });
                return;
            }
        }
        self.events.push(PanelEvent::TypeClick(a));
    }

    /// The box being dragged out, in view points (`None` while no Type tool press is under way or it is still a click).
    pub(crate) fn type_drag_rect(&self) -> Option<CGRect> {
        let (start, now) = self.type_press?;
        if (now.x - start.x).hypot(now.y - start.y) <= Self::TYPE_DRAG_THRESHOLD {
            return None;
        }
        CGRect::new(start.x.min(now.x), start.y.min(now.y), (now.x - start.x).abs(), (now.y - start.y).abs())
            .intersection(&self.canvas_rect)
    }

    pub(crate) fn draw_text_tools(&mut self, c: &mut Canvas) {
        if let Some(r) = self.type_drag_rect() {
            c.stroke_dashed_rounded(r, 0.0, 1.0, 4.0, 3.0, self.theme.accent());
        }
        let (canvas, theme) = (self.canvas_rect, self.theme);
        self.text_field.draw(c, canvas, &theme, &mut self.draw_cx);
    }

    /// Sequence px from the canvas center for a view point (clamped onto the canvas, as the pick does).
    pub(crate) fn sequence_position(&self, p: CGPoint) -> Option<Vec2> {
        self.mapping().click_position(CGPoint::new(p.x - self.slot.min_x(), p.y - self.slot.min_y()))
    }
}
