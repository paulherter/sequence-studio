// Swift: TimelinePanel+FastCut.swift
//! Fast Cut marks and the attach drag, translated from ClipDrawing+MagneticHint.swift and TimelineView+AttachDrag.swift:
//! the same `FastCutMarks` / `AttachPointDrag` geometry; `onSetAttachPoint` becomes `SetAttachPoint` (one undo step).

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt as _;
use sq_core_model::Track;
use sq_core_time::{Id, Time};
use sq_draw::{Canvas, InputModifiers};
use sq_editor_session::TimelineTool;
use sq_timeline_ui::{AttachPointDrag, ClipZone, FastCutMarks, TimelineHit, TrackRow};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::radius;

impl TimelinePanel {
    /// The main track's row while the sequence is magnetic.
    pub(crate) fn fast_cut_main_row(&self, rows: &[TrackRow]) -> Option<TrackRow> {
        if !self.timeline.is_fast_cut() {
            return None;
        }
        let id = self.timeline.main_track_id()?;
        rows.iter().find(|r| r.track == id).cloned()
    }

    /// `drawSpacer`: thin diagonal hatch in the lane line color, framed by a 1 pt outline.
    pub(crate) fn draw_spacers(&self, cv: &mut Canvas, track: &Track, row: &TrackRow, clip: CGRect) {
        for r in FastCutMarks::spacers_on(track) {
            let x0 = self.geometry.x(r.start);
            let x1 = self.geometry.x(r.end());
            if !(x1 >= clip.min_x() && x0 <= clip.max_x() && x1 - x0 >= 2.0 && row.height >= 4.0) {
                continue;
            }
            let body = CGRect::new(x0, row.y, x1 - x0, row.height).inset(0.5, 1.5);
            let vis = body.intersection(&clip);
            if vis.is_empty_rect() {
                continue;
            }
            cv.save_gstate();
            cv.clip_to(vis);
            let step = 6.0;
            let h = body.height;
            let origin = body.min_x() - h;
            let mut x = origin + step * (((vis.min_x() - h - origin) / step).floor()).max(0.0);
            while x <= vis.max_x() {
                cv.stroke_line(
                    CGPoint { x, y: body.max_y() },
                    CGPoint { x: x + h, y: body.min_y() },
                    1.0,
                    self.theme.track_row_line(),
                );
                x += step;
            }
            cv.restore_gstate();
            let left = body.min_x().max(clip.min_x() - 2.0);
            cv.stroke_rounded(
                CGRect::new(left, body.min_y(), body.max_x().min(clip.max_x() + 2.0) - left, h),
                0.0,
                1.0,
                self.theme.track_row_line(),
            );
        }
    }

    /// `drawMagneticHint`: the host of a selected attached clip gets a faint accent tint and a bracket along its lower edge.
    pub(crate) fn draw_magnetic_hint(&self, cv: &mut Canvas, rect: CGRect) {
        if !(rect.width >= 8.0 && rect.height >= 12.0) {
            return;
        }
        cv.fill_rounded(rect.inset(1.0, 1.0), f64::from(radius::SMALL), self.theme.accent().with_alpha(0.12));
        let (inset, tick) = (3.0, 4.0);
        let y = rect.max_y() - 3.0;
        let (x0, x1) = (rect.min_x() + inset, rect.max_x() - inset);
        cv.stroke_polyline(
            &[
                CGPoint { x: x0, y: y - tick },
                CGPoint { x: x0, y },
                CGPoint { x: x1, y },
                CGPoint { x: x1, y: y - tick },
            ],
            1.5,
            self.theme.accent().with_alpha(0.85),
        );
    }

    /// `drawAttachThread`: the line from the attached clip to its host plus the triangle on the host edge.
    pub(crate) fn draw_attach_thread(&self, cv: &mut Canvas, clip_rect: CGRect, x: f64, main: &TrackRow) {
        let Some(g) = FastCutMarks::attach_thread_geometry(&clip_rect, x, main.y, main.max_y())
            .or_else(|| FastCutMarks::attach_marker(&clip_rect, x, main.y, main.max_y()))
        else {
            return;
        };
        let color = self.theme.accent().with_alpha(0.85);
        if g.from != g.to {
            cv.stroke_line(g.from, g.to, 1.0, color);
        }
        cv.fill_polygon(&g.triangle, color);
    }

    // MARK: Attach drag and Cmd+Opt click

    /// `beginAttachDrag`: Selection tool, no modifier, on a thread (a trim edge under it keeps its trim meaning).
    pub(crate) fn attach_down(&mut self, p: CGPoint, mods: InputModifiers) -> bool {
        if self.tool_state().timeline_tool() != TimelineTool::Selection
            || !self.timeline.is_fast_cut()
            || mods.contains(InputModifiers::COMMAND)
            || mods.contains(InputModifiers::OPTION)
            || mods.contains(InputModifiers::SHIFT)
        {
            return false;
        }
        let Some(id) = AttachPointDrag::hit(p, &self.timeline, &self.geometry) else { return false };
        if let TimelineHit::Clip(_, zone) = self.geometry.hit_test(p, &self.timeline)
            && zone != ClipZone::Body
        {
            return false;
        }
        let c = self.timeline.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id);
        let time = c.map_or(Time::ZERO, |c| c.start + c.attachment.as_ref().map_or(Time::ZERO, |a| a.point));
        self.gesture = Some(Gesture::Attach { clip: id, original: Box::new(self.timeline.clone()), time });
        true
    }

    /// `updateAttachDrag`: previews the new attach point on a copy of the timeline.
    pub(crate) fn attach_dragged(&mut self, p: CGPoint) {
        let Some(Gesture::Attach { clip, original, time }) = &self.gesture else { return };
        let (id, original, time) = (*clip, original.clone(), *time);
        let Some(t) = AttachPointDrag::target(p.x, id, &original, &self.geometry, self.playhead, self.snapping())
        else {
            return;
        };
        if t == time {
            return;
        }
        let mut preview = (*original).clone();
        if preview.set_attach_point(id, t).is_ok() {
            self.gesture = Some(Gesture::Attach { clip: id, original, time: t });
            self.timeline = preview;
        }
    }

    /// `endAttachDrag`: reports once when the point moved; the session's edit brings the new timeline back.
    pub(crate) fn attach_up(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        self.attach_dragged(p);
        let Some(Gesture::Attach { clip, original, time }) = &self.gesture else { return Vec::new() };
        let (id, original, time) = (*clip, original.clone(), *time);
        self.timeline = (*original).clone();
        let c = original.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id);
        match c {
            Some(c) if c.start + c.attachment.as_ref().map_or(Time::ZERO, |a| a.point) != time => {
                vec![TimelineAction::SetAttachPoint { clip: id, time }]
            }
            _ => Vec::new(),
        }
    }

    /// `attachPointClick`: Cmd+Opt+click on an attached clip's body sets its attach point to the clicked time.
    pub(crate) fn attach_point_click(&self, p: CGPoint, mods: InputModifiers) -> Option<Id> {
        if !(self.timeline.is_fast_cut()
            && self.tool_state().timeline_tool() == TimelineTool::Selection
            && mods.contains(InputModifiers::COMMAND)
            && mods.contains(InputModifiers::OPTION)
            && !mods.contains(InputModifiers::SHIFT))
        {
            return None;
        }
        match self.geometry.hit_test(p, &self.timeline) {
            TimelineHit::Clip(id, ClipZone::Body) if self.timeline.is_attachable(id) => Some(id),
            _ => None,
        }
    }
}
