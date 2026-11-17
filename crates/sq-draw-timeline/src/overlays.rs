// Swift: TimelinePanel+Overlays.swift
//! Clip overlays the host feeds (grade outline, analysis progress, Magic mask confidence) and the confidence-strip
//! click, translated from ClipDrawing+GradeOutline / +AnalysisProgress, TrackConfidenceStrip and
//! TimelineView+TrackConfidence.
//! The live duck curve (`duckContext`, `drawDuckCurve`) is here too.

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use crate::skin::TimelineSkin;
use sq_core_audio::live_ducking::LiveDucking;
use sq_core_masks::HealthSpan;
use sq_core_model::Clip;
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::Canvas;
use sq_editor_session::TimelineTool;
use sq_timeline_ui::{ClipBodyMetrics, TrackConfidenceStrip, TrackHeightStore};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::radius;
use std::collections::BTreeSet;

impl TimelinePanel {
    /// `drawGradeOutline`: a 2 pt yellow outline just inside the clip.
    pub(crate) fn draw_grade_outline(&self, cv: &mut Canvas, rect: CGRect) {
        if rect.width < 4.0 {
            return;
        }
        cv.stroke_rounded(rect.inset(1.0, 1.0), f64::from(radius::SMALL), 2.0, self.theme.yellow().with_alpha(0.9));
    }

    /// `drawAnalysisProgress`: a 3 pt strip along the bottom edge showing the share done.
    pub(crate) fn draw_analysis_progress(&self, cv: &mut Canvas, rect: CGRect, progress: f64) {
        if rect.width < 12.0 {
            return;
        }
        let h = 3.0;
        let strip = CGRect::new(rect.min_x() + 1.0, rect.max_y() - h - 1.0, rect.width - 2.0, h);
        cv.fill(strip, self.theme.accent().with_alpha(0.3));
        cv.fill(
            CGRect::new(strip.min_x(), strip.min_y(), strip.width * progress.clamp(0.0, 1.0), h),
            self.theme.accent(),
        );
    }

    /// `drawTrackConfidence`: amber stretches along the bottom of the body where tracking is weak, a tick where each
    /// begins.
    pub(crate) fn draw_track_confidence(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect) {
        if rect.width < 12.0 || rect.height < ClipBodyMetrics::BODY_MIN_HEIGHT {
            return;
        }
        let Some(spans) = self.track_weak_spans.as_ref().and_then(|f| f(c)) else { return };
        let fd = self.geometry.frame_duration;
        let (start, len) = (c.start, c.duration());
        let source = |f: f64| {
            let t = start + Time::new((len.value() as f64 * f).round() as i64, len.timescale());
            let s = c.source_time(t, fd);
            s.value() as f64 / s.timescale() as f64
        };
        let weak = TrackConfidenceStrip::weak_ranges(rect.width, 2.0, &source, &spans);
        if weak.is_empty() {
            return;
        }
        let body = rect.inset(0.0, TimelineSkin::CLIP_INSET);
        let h = TrackConfidenceStrip::HEIGHT;
        let warning = self.skin().warning();
        // Clipped to the body rectangle, not its rounded corners (a 3 pt strip under a 4 pt radius), as in Swift.
        cv.save_gstate();
        cv.clip_to(body.intersection(&visible));
        for r in weak {
            cv.fill(CGRect::new(rect.min_x() + r.start(), body.max_y() - h, r.end() - r.start(), h), warning);
            cv.fill(CGRect::new(rect.min_x() + r.start(), body.max_y() - h - 3.0, 2.0, h + 3.0), warning);
        }
        cv.restore_gstate();
    }

    /// `jumpToWeakStretch`: a click on a weak stretch seeks to where it begins.
    pub(crate) fn weak_stretch_jump(&self, p: CGPoint) -> Option<Time> {
        if self.tool_state().timeline_tool() != TimelineTool::Selection {
            return None;
        }
        let spans_of = self.track_weak_spans.as_ref()?;
        let row = self.rows().into_iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != sq_core_model::TrackKind::Video {
            return None;
        }
        let track = self.timeline.tracks.iter().find(|t| t.id == row.track)?;
        let clip = track
            .clips()
            .iter()
            .find(|c| self.geometry.x(c.start) <= p.x && p.x < self.geometry.x(c.timeline().end()))?;
        let weak: Vec<HealthSpan> = spans_of(clip)?;
        let (x0, x1) = (self.geometry.x(clip.start), self.geometry.x(clip.timeline().end()));
        let rect = CGRect::new(x0, row.y, x1 - x0, row.height);
        if rect.width < 12.0 || !TrackConfidenceStrip::hit_band(&rect).has(p) {
            return None;
        }
        TrackConfidenceStrip::jump_target(clip, &weak, self.geometry.time(p.x), self.geometry.frame_duration)
    }

    /// `computeDuckCurveContext`: the ducked Music clips and the ranges that duck them (`None` = nothing to draw).
    // shortcut: recomputed per draw (the Mac caches it until the timeline or the setting changes); cache it when a long
    // sequence with ducking draws slowly.
    pub(crate) fn duck_context(&self) -> Option<(LiveDucking, Vec<TimeRange>, BTreeSet<Id>)> {
        let src = self.duck_curve.as_ref()?;
        let d = (src.ducking)().filter(|d| !d.is_off())?;
        let clips = LiveDucking::ducked_clip_ids(&self.timeline);
        if clips.is_empty() {
            return None;
        }
        let ranges = LiveDucking::dialogue_ranges(&self.timeline, None, src.silences.as_deref());
        if ranges.is_empty() { None } else { Some((d, ranges, clips)) }
    }

    /// `drawDuckCurve`: an amber line that dips under speaking dialogue, with a dark shadow line under it.
    pub(crate) fn draw_duck_curve(
        &self,
        cv: &mut Canvas,
        clip_rect: CGRect,
        visible: CGRect,
        ranges: &[TimeRange],
        d: &LiveDucking,
    ) {
        if ranges.is_empty() || clip_rect.height < 40.0 {
            return; // `duckCurveMinRowHeight`
        }
        let area = clip_rect.intersection(&visible);
        if area.is_empty_rect() {
            return;
        }
        let pad = d.reach();
        let window =
            TimeRange::from_end(self.geometry.time(area.min_x()) - pad, self.geometry.time(area.max_x()) + pad);
        let pts = d.curve(ranges, &window);
        if pts.len() < 2 {
            return;
        }
        let top = clip_rect.min_y() + 4.0;
        let depth = (clip_rect.height * 0.45).min(28.0);
        let span = (1.0 - f64::from(d.floor_gain())).max(0.0001);
        let path: Vec<CGPoint> = pts
            .iter()
            .map(|p| CGPoint { x: self.geometry.x(p.time), y: top + (1.0 - f64::from(p.gain)) / span * depth })
            .collect();
        let shadow: Vec<CGPoint> = path.iter().map(|p| CGPoint { x: p.x, y: p.y + 1.0 }).collect();
        cv.save_gstate();
        cv.clip_to(area);
        cv.stroke_polyline(&shadow, 1.5, self.skin().badge_edge());
        cv.stroke_polyline(&path, 1.5, self.skin().warning().with_alpha(0.9)); // `Theme.TimelineSkin.duckCurve`
        cv.restore_gstate();
    }

    // MARK: Hold-S and height persistence

    /// Hold-S during a drag flips snapping until the key comes up; the running drag is recomputed at once (the Mac
    /// `setSnapInverted`). The host calls it with false on the S key-up.
    pub fn set_snap_inverted(&mut self, on: bool) -> Vec<TimelineAction> {
        if !(self.is_dragging() || !on) || self.interaction.snap_inverted == on {
            return Vec::new();
        }
        self.interaction.snap_inverted = on;
        match self.last_drag {
            Some(p) => self.mouse_dragged(p),
            None => Vec::new(),
        }
    }

    /// Keeps the user's heights and split for this sequence (`TrackHeightStore`, the Mac host's
    /// `onTrackHeightsChanged`).
    pub(crate) fn persist_heights(&self) {
        let Some(defaults) = &self.height_store else { return };
        let mut defaults = defaults.borrow_mut();
        let mut store = TrackHeightStore::new(&mut *defaults);
        store.save(&self.geometry.height_overrides, self.timeline.id);
        store.save_split(self.geometry.split_fraction, self.timeline.id);
    }
}
