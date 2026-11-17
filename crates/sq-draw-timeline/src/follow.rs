// Swift: TimelinePanel+Follow.swift
//! Playback follow and Undo reveal, translated from the Mac `EditorPanels` (`followPlayhead`, `revealInTimeline`):
//! Normal pages, Fast Cut follows continuously (`TimelineFeel`), a scroll by the user during playback wins.

use crate::panel::TimelinePanel;
use sq_core_model::TimelineEditMode;
use sq_core_time::TimeRange;
use sq_timeline_ui::{TimelineFeel, TimelineGeometry};

impl TimelinePanel {
    /// Call once per frame after `sync` with the transport state. Play pressed with the playhead off screen means the
    /// user looks elsewhere on purpose: no follow until the next play.
    pub fn follow_playback(&mut self, playing: bool) {
        if playing != self.follow_was_playing {
            self.follow_was_playing = playing;
            if playing {
                let x = self.geometry.x(self.playhead);
                self.follow.playback_started(x >= TimelineGeometry::CONTENT_ORIGIN_X && x <= self.size.width);
            }
        }
        // A zoom-to-fit ease in flight owns the scroll until it lands; a page turn jumps (Swift, no motion while playing).
        if !playing || self.gesture.is_some() || self.size.width <= 0.0 || self.is_zooming() {
            return;
        }
        let feel = TimelineFeel::for_magnetic(self.timeline.edit_mode() == TimelineEditMode::Magnetic);
        let Some(target) = self.follow.scroll(
            feel.playback_follow,
            self.geometry.x(self.playhead),
            self.geometry.scroll_x,
            TimelineGeometry::CONTENT_ORIGIN_X,
            self.size.width,
        ) else {
            return;
        };
        self.geometry.scroll_x = target;
        self.clamp_scroll();
    }

    /// Undo / Redo (`.reveal`): an affected range off screen scrolls in, its start 10% of the width from the left.
    /// Zoom stays as it is.
    pub fn reveal(&mut self, r: TimeRange) {
        let (left, right) = (TimelineGeometry::CONTENT_ORIGIN_X, self.size.width);
        let x0 = self.geometry.x(r.start);
        let x1 = self.geometry.x(r.end());
        if !(x1 < left || x0 > right) {
            return;
        }
        self.geometry.scroll_x += x0 - left - (right - left) * 0.1;
        self.clamp_scroll();
    }
}
