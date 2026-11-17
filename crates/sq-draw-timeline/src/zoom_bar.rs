// Swift: TimelinePanel+ZoomBar.swift
//! The zoom scroll bar under the tracks (`TimelineView.wireZoomBar` / `layoutChildren`): `ZoomScrollBarControl` at the
//! bottom of the content column, the footer fill left of it, and the same `TimelineZoom` math for handles, drags,
//! pans and fit.

use crate::geom::RectExt as _;
use crate::panel::{Gesture, TimelinePanel, ZoomBarSnapshot};
use sq_draw::Canvas;
use sq_timeline_ui::{TimelineGeometry, TimelineZoom};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::zoom_scroll_bar_gesture::Output as ZoomBarOutput;

impl TimelinePanel {
    pub(crate) fn zoom_bar_rect(&self) -> CGRect {
        CGRect::new(
            TimelineGeometry::CONTENT_ORIGIN_X,
            (self.size.height - Self::ZOOM_BAR_HEIGHT).max(0.0),
            (self.size.width - TimelineGeometry::CONTENT_ORIGIN_X).max(0.0),
            Self::ZOOM_BAR_HEIGHT,
        )
    }

    /// `zoomBarSnapshot`.
    pub(crate) fn zoom_bar_snapshot(&self) -> ZoomBarSnapshot {
        let (scroll_x, viewport, pps) =
            (self.geometry.scroll_x, self.content_viewport_width(), self.geometry.points_per_second);
        let end = self.content_end();
        let seconds = end.value() as f64 / end.timescale() as f64;
        ZoomBarSnapshot {
            scroll_x,
            viewport,
            scale: pps,
            extent: TimelineZoom::bar_extent(seconds, scroll_x, viewport, pps),
        }
    }

    pub(crate) fn zoom_bar_handles(&self) -> (f64, f64) {
        let s = self.zoom_bar_snapshot();
        TimelineZoom::handles(s.scroll_x, s.viewport, s.scale, s.extent)
    }

    /// A press on the bar; false = not on it.
    pub(crate) fn zoom_bar_down(&mut self, p: CGPoint, clicks: i64) -> bool {
        let bar = self.zoom_bar_rect();
        if !bar.has(p) {
            return false;
        }
        let mut snapshot = self.zoom_bar_snapshot();
        let handles = self.zoom_bar_handles();
        for o in self.zoom_bar.mouse_down(p, clicks, bar, handles) {
            if o == ZoomBarOutput::Begin {
                snapshot = self.zoom_bar_snapshot();
            }
            self.apply_zoom_bar(o, &snapshot);
        }
        self.gesture = if self.zoom_bar.is_dragging() { Some(Gesture::ZoomBar(snapshot)) } else { None };
        true
    }

    pub(crate) fn zoom_bar_dragged(&mut self, p: CGPoint, s: &ZoomBarSnapshot) {
        let bar = self.zoom_bar_rect();
        if let Some(o) = self.zoom_bar.mouse_dragged(p, bar) {
            self.apply_zoom_bar(o, s);
        }
    }

    pub(crate) fn zoom_bar_up(&mut self) {
        self.zoom_bar.mouse_up();
    }

    fn apply_zoom_bar(&mut self, o: ZoomBarOutput, s: &ZoomBarSnapshot) {
        match o {
            ZoomBarOutput::Begin => {}
            ZoomBarOutput::Fit => self.zoom_to_fit(),
            ZoomBarOutput::Handle { lower, fraction } => {
                let r = TimelineZoom::drag_handle(
                    lower,
                    fraction,
                    s.scroll_x,
                    s.viewport,
                    s.scale,
                    s.extent,
                    &self.zoom_limits(),
                );
                self.apply_zoom(r.0, r.1);
            }
            ZoomBarOutput::Pan { start_fraction } => {
                self.apply_zoom(s.scale, start_fraction.max(0.0) * s.extent * s.scale)
            }
        }
    }

    /// `TimelineView.applyZoom`.
    pub(crate) fn apply_zoom(&mut self, pps: f64, scroll_x: f64) {
        self.geometry.points_per_second = TimelineZoom::clamp(pps, &self.zoom_limits());
        self.geometry.scroll_x = scroll_x;
        self.clamp_scroll();
    }

    pub(crate) fn draw_zoom_bar(&self, cv: &mut Canvas) {
        let bar = self.zoom_bar_rect();
        cv.fill(CGRect::new(0.0, bar.min_y(), TimelineGeometry::CONTENT_ORIGIN_X, bar.height), self.theme.timeline());
        self.zoom_bar.draw(cv, bar, self.zoom_bar_handles(), &self.theme, Some(self.theme.timeline()));
    }
}
