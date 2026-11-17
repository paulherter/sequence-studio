// Swift: TimelinePanel+SpeedBand.swift
//! The Time Remapping speed band, translated from TimelineView+SpeedBand.swift: the same `SpeedBand` geometry and
//! gesture; `onSpeedEdit` becomes `SpeedEdit` (the session's `apply_speed_edit` makes one undo step of a drag).

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::timeline_magnetic_moves::MagneticGesturesExt as _;
use sq_core_model::{Clip, SpeedKeys, Timeline};
use sq_core_time::{Id, Time};
use sq_draw::{Canvas, InputModifiers};
use sq_editor_session::{
    SpeedBand, SpeedBandGesture, SpeedBandGestureStart, SpeedBandHit, SpeedBandKeyHit, SpeedBandKeyKind,
    SpeedEditPhase, TimelineTool,
};
use sq_timeline_ui::{ClipBodyMetrics, TimelineGeometry, TransitionLayout, VolumeLine};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use std::sync::Arc;

/// One speed band drag (`SpeedDrag` of the Mac view).
#[derive(Clone)]
pub(crate) struct SpeedBandDrag {
    pub clip: Id,
    pub gesture: SpeedBandGesture,
    pub last: SpeedKeys,
    pub tip: Option<String>,
    /// The sequence at mouse-down: Esc puts it back (`cancel_speed_drag`).
    pub original: Timeline,
}

/// The video clip, its rectangle and lane under a point, when the band is shown there.
pub(crate) struct SpeedTarget {
    pub clip: Clip,
    pub rect: CGRect,
    pub lane: CGRect,
}

impl TimelinePanel {
    /// The video clip, its rectangle and lane under `p`, when the band is shown there (`speedTarget`).
    pub(crate) fn speed_target(&self, p: CGPoint) -> Option<SpeedTarget> {
        if self.tool_state().timeline_tool() != TimelineTool::Selection
            || self.speed_band_clips.is_empty()
            || p.x < TimelineGeometry::CONTENT_ORIGIN_X
        {
            return None;
        }
        let rows = self.rows();
        let row = rows.iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != sq_core_model::TrackKind::Video || !SpeedBand::is_available(row.height) {
            return None;
        }
        let track = self.timeline.track(row.track)?;
        if track.is_locked {
            return None;
        }
        let clip = track.clips().iter().find(|c| {
            self.speed_band_clips.contains(&c.id)
                && self.geometry.x(c.timeline().start) - 6.0 <= p.x
                && p.x < self.geometry.x(c.timeline().end()) + 6.0
        })?;
        let (x0, x1) = (self.geometry.x(clip.timeline().start), self.geometry.x(clip.timeline().end()));
        let rect = CGRect::new(x0, row.y, x1 - x0, row.height);
        Some(SpeedTarget { clip: clip.clone(), rect, lane: ClipBodyMetrics::waveform_rect(&rect) })
    }

    /// Key or transition under `p`, for the context menu ("Delete Speed Keyframe", "Remove Speed Transition").
    pub fn speed_key_hit(&self, p: CGPoint) -> Option<(Id, SpeedBandKeyHit)> {
        let g = &self.geometry;
        let t = self.speed_target(p)?;
        let keys = t.clip.speed_keys.as_ref()?;
        let h = SpeedBand::hit(keys, t.clip.start, t.lane, p, |x| g.x(x))?;
        match h {
            SpeedBandHit::Key(b) => Some((t.clip.id, SpeedBandKeyHit::new(SpeedBandKeyKind::Key(b)))),
            SpeedBandHit::Ramp(i) | SpeedBandHit::RampHandle(i) => {
                Some((t.clip.id, SpeedBandKeyHit::new(SpeedBandKeyKind::Ramp(i))))
            }
            SpeedBandHit::Segment(_) => None,
        }
    }

    /// The clip whose band line is under `p`: the menu offers "Add Speed Point" there.
    pub fn speed_segment_clip(&self, p: CGPoint) -> Option<Id> {
        let g = &self.geometry;
        let t = self.speed_target(p)?;
        match SpeedBand::hit(&SpeedKeys::of(&t.clip), t.clip.start, t.lane, p, |x| g.x(x))? {
            SpeedBandHit::Segment(_) => Some(t.clip.id),
            _ => None,
        }
    }

    /// `beginSpeedDrag`; `None` = the press is not on the band.
    pub(crate) fn speed_down(&mut self, p: CGPoint, mods: InputModifiers) -> Option<Vec<TimelineAction>> {
        // A transition box sits on the clip edge and wins over the band underneath it.
        if TransitionLayout::hit_test(p, &self.timeline, &self.geometry, TimelineGeometry::MAX_TRIM_HANDLE_WIDTH)
            .is_some()
        {
            return None;
        }
        let t = self.speed_target(p)?;
        let keys = SpeedKeys::of(&t.clip);
        let g = self.geometry.clone();
        let hit = SpeedBand::hit(&keys, t.clip.start, t.lane, p, |x| g.x(x))?;
        let cmd = mods.contains(InputModifiers::COMMAND);
        if !cmd && VolumeLine::edge_wins(p, &t.rect) {
            return None; // trimming wins at the edges
        }
        let key = matches!(hit, SpeedBandHit::Segment(_)) && cmd;
        // A segment drag without Cmd edits its speed; Cmd-click adds a key. Keys and transitions need no modifier.
        let gc = self.geometry.clone();
        let gesture = SpeedBandGesture::new(SpeedBandGestureStart {
            keys: keys.clone(),
            clip_start: t.clip.start,
            hit: Some(hit),
            start: p,
            lane: t.lane,
            frame_duration: self.timeline.format.frame_duration,
            add_key: key,
            option: mods.contains(InputModifiers::OPTION),
            shift: mods.contains(InputModifiers::SHIFT),
            time_at: Arc::new(move |x| gc.time(x)),
        });
        let mut out = Vec::new();
        if self.selection != std::collections::BTreeSet::from([t.clip.id]) {
            self.selection = std::collections::BTreeSet::from([t.clip.id]);
            self.interaction.set_selection(std::collections::BTreeSet::from([t.clip.id]));
            out.push(TimelineAction::Select {
                clips: std::collections::BTreeSet::from([t.clip.id]),
                captions: std::collections::BTreeSet::new(),
            });
        }
        out.push(TimelineAction::SpeedEdit {
            clip: t.clip.id,
            keys: keys.clone(),
            phase: SpeedEditPhase::Began,
            keeping_keys: gesture.keeps_keys(),
        });
        self.gesture = Some(Gesture::Speed(Box::new(SpeedBandDrag {
            clip: t.clip.id,
            gesture,
            last: keys,
            tip: None,
            original: self.committed.clone(),
        })));
        if key {
            out.extend(self.speed_dragged(p));
        }
        Some(out)
    }

    pub(crate) fn speed_dragged(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        let Some(Gesture::Speed(d)) = &self.gesture else { return Vec::new() };
        let mut d = (**d).clone();
        let k = d.gesture.update(p);
        d.tip = d.gesture.tooltip(p);
        if k == d.last {
            self.gesture = Some(Gesture::Speed(Box::new(d)));
            return Vec::new();
        }
        d.last = k.clone();
        let keeping_keys = d.gesture.keeps_keys();
        let clip = d.clip;
        self.gesture = Some(Gesture::Speed(Box::new(d)));
        let mut ids = self.fresh_ids();
        let preview = k.clone();
        let _ = self.timeline.magnetic_edit_speed_keys(clip, keeping_keys, false, move |_| Some(preview), &mut ids); // the preview
        vec![TimelineAction::SpeedEdit { clip, keys: k, phase: SpeedEditPhase::Changed, keeping_keys }]
    }

    pub(crate) fn speed_up(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        let mut out = self.speed_dragged(p);
        if let Some(Gesture::Speed(d)) = &self.gesture {
            out.push(TimelineAction::SpeedEdit {
                clip: d.clip,
                keys: d.last.clone(),
                phase: SpeedEditPhase::Ended,
                keeping_keys: d.gesture.keeps_keys(),
            });
        }
        out
    }

    /// Esc during a speed band drag: the session goes back to the sequence at mouse-down and drops the drag's undo step
    /// (the Mac view has no Esc here; the draw-list panel cancels every drag the same way). The preview reverts in
    /// `cancel_gesture`.
    pub(crate) fn cancel_speed_drag(&mut self) -> Vec<TimelineAction> {
        let Some(Gesture::Speed(d)) = &self.gesture else { return Vec::new() };
        vec![TimelineAction::CancelSpeedEdit { clip: d.clip, restoring: Box::new(d.original.clone()) }]
    }

    // MARK: Drawing

    /// `drawSpeedBand`: the key strip, shaded transitions, the rubber band, speed labels, key triangles, ramp handles.
    pub(crate) fn draw_speed_band(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect, selected: bool) {
        let lane = ClipBodyMetrics::waveform_rect(&rect);
        let keys = SpeedKeys::of(c);
        let g = &self.geometry;
        let xs = |t: Time| g.x(t);
        let skin = self.skin();
        cv.save_gstate();
        cv.clip_to(visible.intersection(&rect));
        let strip = SpeedBand::strip(lane);
        cv.fill(strip, self.theme.fill_hover());
        let ramps = SpeedBand::ramp_marks(&keys, c.start, lane, xs);
        for r in &ramps {
            cv.fill(CGRect::new(r.x0, strip.min_y(), (r.x1 - r.x0).max(1.0), strip.height), self.theme.label3());
        }
        let pts = SpeedBand::line_points(&keys, c.start, lane, xs);
        let shifted: Vec<CGPoint> = pts.iter().map(|p| CGPoint { x: p.x, y: p.y + 1.0 }).collect();
        cv.stroke_polyline(&shifted, 1.0, skin.badge_edge());
        cv.stroke_polyline(&pts, 1.0, skin.badge_fill().with_alpha(if selected { 0.95 } else { 0.8 }));
        let area = SpeedBand::line_area(lane);
        let starts = keys.boundaries();
        let size = f64::from(type_size::CAPTION);
        for (i, s) in keys.segments.iter().enumerate() {
            let x0 = xs(c.start + starts[i]);
            let x1 = xs(c.start + starts[i + 1]);
            if x1 - x0 <= 44.0 {
                continue;
            }
            let mid = s.speed_value(Time::new(s.duration.value(), s.duration.timescale() * 2));
            let text = SpeedBand::label(mid);
            let y = SpeedBand::y_for_speed(mid, area);
            cv.draw_text(
                &text,
                CGPoint { x: (x0 + x1) / 2.0 - cv.size_of(&text, size, 0).width / 2.0, y: y + 3.0 },
                size,
                self.theme.on_clip(),
                f64::INFINITY,
                0,
            );
        }
        for k in SpeedBand::key_marks(&keys, c.start, xs) {
            let tri = if k.is_half {
                let dir = if k.is_left_half { 1.0 } else { -1.0 }; // a left half points into the transition
                [
                    CGPoint { x: k.x, y: strip.min_y() },
                    CGPoint { x: k.x, y: strip.max_y() },
                    CGPoint { x: k.x + 4.0 * dir, y: strip.mid_y() },
                ]
            } else {
                [
                    CGPoint { x: k.x - 4.0, y: strip.min_y() },
                    CGPoint { x: k.x + 4.0, y: strip.min_y() },
                    CGPoint { x: k.x, y: strip.max_y() },
                ]
            };
            cv.fill_polygon(&tri, skin.badge_fill());
            cv.stroke_polygon(&tri, 1.0, skin.badge_edge());
        }
        for r in &ramps {
            let dot = CGRect::new(r.handle.x - 3.5, r.handle.y - 3.5, 7.0, 7.0);
            cv.fill_ellipse(dot, self.theme.accent());
            cv.stroke_ellipse(dot, 1.0, skin.badge_fill());
        }
        cv.restore_gstate();
    }

    /// `drawSpeedTip`: "Speed 250%" next to the press while a segment is dragged.
    pub(crate) fn draw_speed_tip(&self, cv: &mut Canvas) {
        let Some(Gesture::Speed(d)) = &self.gesture else { return };
        let Some(tip) = &d.tip else { return };
        let size = f64::from(type_size::BODY);
        let s = cv.size_of(tip, size, 0);
        let origin = CGPoint { x: d.gesture.start.x + 12.0, y: d.gesture.start.y - s.height - 10.0 };
        let box_ = CGRect::new(origin.x, origin.y, s.width, s.height).inset(-6.0, -3.0);
        cv.fill_rounded(box_, f64::from(radius::SMALL), self.skin().hud_fill());
        cv.draw_text(tip, origin, size, self.theme.on_clip(), f64::INFINITY, 0);
    }
}
