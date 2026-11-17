// Swift: TimelinePanel+Skimmer.swift
//! The Fast Cut skimmer, translated from TimelineView+Skimmer.swift and `Skimmer`; `onSkim` becomes `Skim`.

use crate::action::TimelineAction;
use crate::panel::TimelinePanel;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt as _;
use sq_draw::Canvas;
use sq_draw::Color;
use sq_editor_session::TimelineTool;
use sq_timeline_ui::TimelineGeometry;
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl TimelinePanel {
    /// `updateSkimmer(pointer:)`: shows, moves or hides the line; tells the host once per frame change.
    pub(crate) fn update_skimmer(&mut self, pointer: Option<CGPoint>) -> Vec<TimelineAction> {
        if !(self.timeline.is_fast_cut() || self.skimmer_time.is_some()) {
            return Vec::new();
        }
        // `Skimmer.time`: Fast Cut, no gesture, no playback, not the razor, and the pointer over the track lanes.
        let mut t = None;
        if let Some(p) = pointer
            && self.timeline.is_fast_cut()
            && !self.is_dragging()
            && !self.is_playing
            && self.tool_state().timeline_tool() != TimelineTool::Razor
            && p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT
            && p.y < self.size.height - Self::ZOOM_BAR_HEIGHT
        {
            t = Some(self.geometry.time(p.x));
        }
        if t == self.skimmer_time {
            return Vec::new();
        }
        self.skimmer_time = t;
        vec![TimelineAction::Skim(t)]
    }

    /// The 2 pt line over the tracks in `Theme.Colors.skimmer`.
    pub(crate) fn draw_skimmer(&self, cv: &mut Canvas) {
        let Some(t) = self.skimmer_time else { return };
        let ruler = TimelineGeometry::RULER_HEIGHT;
        // `Skimmer.lineRect` / `Theme.PlayheadSkin.lineFrame`: 2 pt, centered on the frame's x, ruler to zoom bar.
        let h = (self.size.height - Self::ZOOM_BAR_HEIGHT - ruler).max(0.0);
        cv.fill(CGRect::new(self.geometry.x(t).round() - 1.0, ruler, 2.0, h), Color::hex(0xFFE566, 1.0));
    }
}
