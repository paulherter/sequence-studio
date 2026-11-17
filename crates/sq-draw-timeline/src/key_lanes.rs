// Swift: TimelinePanel+KeyLanes.swift
//! The key lane of one selected clip as the Effect Controls side computes it: the panel draws it and reports presses
//! (the lane drawing itself is [`crate::lanes::draw_key_lane`]).

use crate::action::TimelineAction;
use crate::lanes::{KeyLaneDraw, draw_key_lane};
use crate::panel::TimelinePanel;
use sq_core_model::Clip;
use sq_draw::Canvas;
use sq_editor_session::TimelineTool;
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl TimelinePanel {
    /// `drawKeyLane`: the strip under the visible part and the diamonds, picked keys in the accent.
    pub(crate) fn draw_key_lane_of(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect, selected: bool) {
        let Some(source) = &self.key_lanes else { return };
        draw_key_lane(
            cv,
            &self.theme,
            source.as_ref(),
            &KeyLaneDraw { geometry: &self.geometry, clip: c, rect, visible, selected },
        );
    }

    /// `beginKeyLaneClick`: a press on a glyph of a selected clip's lane picks that key in Effect Controls.
    pub(crate) fn key_lane_down(&mut self, p: CGPoint, shift: bool) -> Option<Vec<TimelineAction>> {
        let source = self.key_lanes.clone()?;
        if self.tool_state().timeline_tool() != TimelineTool::Selection {
            return None;
        }
        let rows = self.rows();
        let row = rows.iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        let track = self.timeline.track(row.track)?;
        if track.is_locked {
            return None;
        }
        let clip = track.clips().iter().find(|c| {
            self.selection.contains(&c.id)
                && self.geometry.x(c.timeline().start) - 6.0 <= p.x
                && p.x < self.geometry.x(c.timeline().end()) + 6.0
        })?;
        let (x0, x1) = (self.geometry.x(clip.timeline().start), self.geometry.x(clip.timeline().end()));
        let t = source.key_lane_hit(clip, CGRect::new(x0, row.y, x1 - x0, row.height), p, &self.geometry)?;
        let mut out = Vec::new();
        if !self.selected_line_keys.is_empty() {
            self.selected_line_keys.clear();
            out.push(TimelineAction::LineKeyClick { key: None, extend: false });
        }
        out.push(TimelineAction::KeyLaneClick { clip: clip.id, time: t, extend: shift });
        Some(out)
    }
}
