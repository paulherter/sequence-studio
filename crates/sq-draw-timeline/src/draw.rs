// Swift: TimelinePanel+Draw.swift
//! Painting, translated from `TimelineView.drawTimeline`, `ClipDrawing`, `TimelineView+Transitions` and the gesture
//! overlay: the same rects, colors and order, drawn through `Canvas` instead of NSBezierPath.

use crate::geom::RectExt as _;
use crate::item_lanes::ItemLaneMetrics;
use crate::lanes::SilencePreview;
use crate::media::ClipFrame;
use crate::panel::{Gesture, TimelinePanel};
use crate::skin::TimelineSkin;
use sq_core_edit::clip_markers::ClipMarkersExt as _;
use sq_core_edit::sync_offsets::SyncOffsetsExt as _;
use sq_core_effects::transition::TransitionKindExt as _;
use sq_core_effects::transition::{ResolvedTransition, TrackTransitions as _};
use sq_core_effects::transition_layer::ClipTransitionLayer as _;
use sq_core_model::{Clip, Track, TrackKind, TransitionKind};
use sq_core_time::{Id, Time};
use sq_draw::{Canvas, Color, InputModifiers};
use sq_editor_session::{EdgeEdits, SpeedBand, SpeedLabel, TimelineTool};
use sq_timeline_ui::{
    ClipBodyMetrics, ClipMarkerFlags, FXBadgeState, FastCutMarks, OpacityLine, TimelineGeometry, TimelineInteraction,
    TrackRow, TransitionLayout, VolumeLine,
};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{metrics, radius, type_size};
use std::collections::BTreeSet;

/// A run of touching sub-3 pt clips of one color (and one veil) drawn as a single fill.
struct SliverRun {
    min_x: f64,
    max_x: f64,
    y: f64,
    height: f64,
    fill: Color,
    fade: Option<f32>,
}

impl SliverRun {
    fn flush(&self, cv: &mut Canvas, lane_color: Color) {
        let r = CGRect::new(self.min_x, self.y, self.max_x - self.min_x, self.height);
        cv.fill(r, self.fill);
        if let Some(fade) = self.fade {
            cv.fill(r, lane_color.with_alpha(fade));
        }
    }
}

impl TimelinePanel {
    /// Clip corner radius: the kit's `radius/clip` (2) plus 2 pt, a rounder look by request.
    pub(crate) const CLIP_RADIUS: f64 = sq_uikit::redesign_tokens::radius::CLIP as f64 + 2.0;

    pub(crate) fn skin(&self) -> TimelineSkin<'_> {
        TimelineSkin { theme: &self.theme }
    }

    pub(crate) fn draw_timeline(&mut self, cv: &mut Canvas) {
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        let origin = TimelineGeometry::CONTENT_ORIGIN_X;
        let ruler = TimelineGeometry::RULER_HEIGHT;
        cv.fill(bounds, self.theme.timeline());
        let content =
            CGRect::new(origin, ruler, (self.size.width - origin).max(0.0), (self.size.height - ruler).max(0.0));
        let rows = self.rows();
        cv.save_gstate();
        cv.clip_to(content);
        self.draw_lanes_through_cache(cv, &rows, content);
        self.draw_lane_decorations(cv, &rows, content);
        self.draw_lane_veils(cv, &rows, content);
        self.draw_item_lanes(cv, &rows, content);
        self.draw_caption_lanes(cv, content);
        self.draw_transitions(cv, &rows, content);
        self.draw_silence_preview(cv, content);
        self.draw_in_out_tint(cv, content);
        self.draw_playhead_line(cv, content);
        self.draw_skimmer(cv);
        self.draw_gesture_overlay(cv, &rows, content);
        self.draw_drop_preview(cv, &rows, content);
        self.draw_keystone_overlay(cv, &rows);
        self.draw_item_lane_move_ghost(cv);
        self.draw_speed_tip(cv);
        self.draw_word_field(cv, content);
        cv.restore_gstate();
        self.draw_vertical_scroll_hint(cv);
        self.draw_headers(cv, &rows);
        self.draw_item_lane_headers(cv, &rows);
        self.draw_zoom_bar(cv); // over the header column's foot, like the Mac footer subview
        self.draw_ruler(cv);
    }

    /// The thumb of the lanes' vertical scroll hint in panel points: `None` while everything fits. It sits at the right
    /// edge over the lanes (view `top`..`top + view_height`), as tall as the visible share of the content.
    pub(crate) fn vertical_thumb(
        width: f64,
        top: f64,
        view_height: f64,
        scroll_y: f64,
        max_scroll_y: f64,
    ) -> Option<CGRect> {
        if max_scroll_y <= 0.0 || view_height <= 0.0 {
            return None;
        }
        let h = (view_height * view_height / (view_height + max_scroll_y)).max(24.0).min(view_height);
        let y = top + (scroll_y / max_scroll_y).clamp(0.0, 1.0) * (view_height - h);
        Some(CGRect::new(width - 7.0, y, 4.0, h))
    }

    /// A thin overlay scroll bar so a timeline with more tracks than fit shows that there are more (no layout cost).
    fn draw_vertical_scroll_hint(&self, cv: &mut Canvas) {
        let top = TimelineGeometry::RULER_HEIGHT;
        let view = self.track_area_height() - top;
        if let Some(r) = Self::vertical_thumb(self.size.width, top, view, self.geometry.scroll_y, self.max_scroll_y()) {
            cv.fill_rounded(r, 2.0, self.theme.label3().with_alpha(0.5));
        }
    }

    /// What sits on the clips but belongs to someone else's live state: Effect Controls' key lanes (selected clips), the
    /// duck curve and the Magic mask confidence strips. Drawn every frame over the cached clip layer.
    fn draw_lane_decorations(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let duck = self.duck_context();
        let keyed = self.key_lanes.is_some() && !self.selection.is_empty();
        let weak = self.track_weak_spans.is_some();
        if duck.is_none() && !keyed && !weak {
            return;
        }
        let visible_x = CGRect::new(clip.min_x(), 0.0, clip.width, self.size.height);
        for row in rows {
            let lane = CGRect::new(clip.min_x(), row.y, clip.width, row.height);
            let Some(track) = self.timeline.track(row.track) else { continue };
            if !lane.intersects(&clip) {
                continue;
            }
            let confidence = weak && track.kind == TrackKind::Video;
            let ducked = duck.is_some() && track.kind == TrackKind::Audio;
            if !(keyed || confidence || ducked) {
                continue;
            }
            for c in &track.clips()[self.visible_clip_indices(track, clip.min_x(), clip.max_x())] {
                let x0 = self.geometry.x(c.start);
                let x1 = self.geometry.x(c.timeline().end());
                if !(x1 >= clip.min_x() && x0 <= clip.max_x()) {
                    continue;
                }
                let rect = CGRect::new(x0, row.y, x1 - x0, row.height);
                if rect.width >= 3.0 {
                    // the LOD sliver draws the body only
                    if keyed && self.selection.contains(&c.id) {
                        self.draw_key_lane_of(cv, c, rect, visible_x, true);
                    }
                    if ducked
                        && let Some((d, ranges, clips)) = &duck
                        && clips.contains(&c.id)
                    {
                        self.draw_duck_curve(cv, rect, visible_x, ranges, d);
                    }
                }
                if confidence {
                    self.draw_track_confidence(cv, c, rect, visible_x);
                }
            }
        }
    }

    /// Remove Silences preview: the ranges the open dialog would cut, shaded red (TimelinePanel+SilencePreview.swift).
    fn draw_silence_preview(&self, cv: &mut Canvas, clip: CGRect) {
        SilencePreview::draw(cv, &self.theme, &self.geometry, &self.silence_preview, clip);
    }

    // MARK: Lanes and clips (`drawLanes`)

    pub(crate) fn draw_lanes(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let split = Self::split_row(rows);
        let solo_active = Self::audio_solo_active(&self.timeline);
        let visible_x = CGRect::new(clip.min_x(), 0.0, clip.width, self.size.height);
        let skin = self.skin();
        let main_row = self.fast_cut_main_row(rows);
        let magnetic_hosts = if main_row.is_none() {
            BTreeSet::new()
        } else {
            FastCutMarks::attach_hosts(&self.selection, &self.timeline)
        };
        let mut threads: Vec<(CGRect, f64)> = Vec::new();
        for (row_index, row) in rows.iter().enumerate() {
            let lane_rect = CGRect::new(clip.min_x(), row.y, clip.width, row.height);
            let Some(track) = self.timeline.tracks.iter().find(|t| t.id == row.track) else { continue };
            if !lane_rect.intersects(&clip) {
                continue;
            }
            let lane_color = if Self::is_alt_lane(row_index, rows) { self.theme.lane() } else { self.theme.timeline() };
            cv.fill(lane_rect, lane_color);
            if let Some(m) = &main_row
                && row.track == m.track
            {
                self.draw_spacers(cv, track, row, clip);
            }
            // Design v9: 1 pt lane line, 2 pt strong line under the last video row (`.lane.vsplit`).
            let line_height = if Some(row_index) == split { 2.0 } else { 1.0 };
            cv.fill(
                CGRect::new(clip.min_x(), row.max_y() - line_height, clip.width, line_height),
                if Some(row_index) == split { self.theme.panel_ground() } else { self.theme.track_row_line() },
            );
            let ink = if track.kind == TrackKind::Audio { self.waveform_ink(track) } else { Color::CLEAR };
            let inactive = Self::is_inactive(track, solo_active);
            let mut run: Option<SliverRun> = None;
            for c in &track.clips()[self.visible_clip_indices(track, clip.min_x(), clip.max_x())] {
                let x0 = self.geometry.x(c.start);
                let x1 = self.geometry.x(c.timeline().end());
                if !(x1 >= clip.min_x() && x0 <= clip.max_x()) {
                    continue;
                }
                let rect = CGRect::new(x0, row.y, x1 - x0, row.height);
                let selected = self.selection.contains(&c.id);
                if rect.width < 3.0 {
                    // LOD: slivers of one color that touch become one fill (and one veil), so a zoomed-out hour is a few quads.
                    let body = rect.inset(0.0, TimelineSkin::CLIP_INSET);
                    let fill = if selected {
                        self.theme.yellow()
                    } else if self.is_offline(c) {
                        skin.offline_clip()
                    } else {
                        self.theme.clip(self.labels.label(c))
                    };
                    let fade: Option<f32> = if inactive {
                        Some(if selected { 0.5 } else { 0.72 })
                    } else if c.is_enabled {
                        None
                    } else {
                        Some(0.68)
                    };
                    match &mut run {
                        Some(r) if r.fill == fill && r.fade == fade && body.min_x() - r.max_x <= 0.25 => {
                            r.max_x = r.max_x.max(body.max_x());
                        }
                        _ => {
                            if let Some(r) = &run {
                                r.flush(cv, lane_color);
                            }
                            run = Some(SliverRun {
                                min_x: body.min_x(),
                                max_x: body.max_x(),
                                y: body.min_y(),
                                height: body.height,
                                fill,
                                fade,
                            });
                        }
                    }
                } else {
                    if let Some(r) = run.take() {
                        r.flush(cv, lane_color);
                    }
                    self.draw_clip(cv, c, rect, clip, selected, track);
                }
                if c.markers.as_ref().is_some_and(|m| !m.is_empty()) {
                    self.draw_clip_marker_flags(cv, c, rect, clip);
                }
                if rect.width >= 3.0 {
                    // the LOD sliver draws the body only
                    if let Some(n) = self.sync_badges.get(&c.id) {
                        self.draw_sync_badge(cv, *n, rect, visible_x);
                    }
                    if track.kind == TrackKind::Audio {
                        self.draw_waveform(cv, c, rect, clip, ink);
                        if VolumeLine::is_available(row.height) {
                            self.draw_volume_line(cv, c, rect, clip, selected, &self.hidden_fade_handles(c));
                        }
                    } else {
                        let speed_band = self.speed_band_clips.contains(&c.id);
                        if speed_band && SpeedBand::is_available(row.height) {
                            self.draw_speed_band(cv, c, rect, clip, selected);
                        }
                        if OpacityLine::is_visible(c, selected, row.height) && !speed_band {
                            self.draw_opacity_line(cv, c, rect, clip, selected);
                        }
                        if Self::has_applied_fx(c) {
                            self.draw_fx_badge(cv, rect, visible_x);
                        }
                    }
                    if self.grade_outline.contains(&c.id) {
                        self.draw_grade_outline(cv, rect);
                    }
                    if let Some(p) = self.analysis_progress.get(&c.id) {
                        self.draw_analysis_progress(cv, rect, *p);
                    }
                }
                if magnetic_hosts.contains(&c.id) {
                    self.draw_magnetic_hint(cv, rect);
                }
                if let Some(m) = &main_row
                    && row.track != m.track
                    && let Some(a) = &c.attachment
                {
                    threads.push((rect, self.geometry.x(c.timeline().start + a.point)));
                }
            }
            if let Some(r) = run {
                r.flush(cv, lane_color);
            }
        }
        if let Some(m) = &main_row {
            for (rect, x) in threads.iter().filter(|t| t.1 >= clip.min_x() - 4.0 && t.1 <= clip.max_x() + 4.0) {
                self.draw_attach_thread(cv, *rect, *x, m);
            }
        }
    }

    pub(crate) fn refresh_draw_caches(&mut self) {
        self.content_revision = self.content_revision.wrapping_add(1);
        self.transition_layer_tracks = self
            .timeline
            .tracks
            .iter()
            .filter(|t| t.clips().iter().any(|c| c.is_transition_layer()))
            .map(|t| t.id)
            .collect();
        self.sync_badges = self.timeline.sync_offsets();
        let mut ends = std::collections::BTreeMap::new();
        for t in self.timeline.tracks.iter() {
            let mut run: Vec<Time> = Vec::with_capacity(t.clips().len());
            let mut top = Time::ZERO;
            for (i, c) in t.clips().iter().enumerate() {
                let e = c.timeline().end();
                if i == 0 || e > top {
                    top = e;
                }
                run.push(top);
            }
            ends.insert(t.id, run);
        }
        self.prefix_ends = ends;
    }

    /// Clips of `track` that can touch view x range `from...to`: clips are sorted by start, and the prefix-max of the
    /// ends is monotone, so both bounds are binary searches (the per-clip test in the loop stays the exact one).
    pub(crate) fn visible_clip_indices(&self, track: &Track, from: f64, to: f64) -> std::ops::Range<usize> {
        let n = track.clips().len();
        let Some(ends) = self.prefix_ends.get(&track.id).filter(|e| n > 64 && e.len() == n) else { return 0..n };
        let pad = self.geometry.frame_duration * 2;
        let t0 = self.geometry.unsnapped_time(from) - pad;
        let t1 = self.geometry.unsnapped_time(to) + pad;
        let (mut lo, mut hi) = (0, n); // first index whose prefix end reaches t0
        while lo < hi {
            let m = (lo + hi) / 2;
            if ends[m] < t0 { lo = m + 1 } else { hi = m }
        }
        let (mut a, mut b) = (lo, n); // first index starting after t1
        while a < b {
            let m = (a + b) / 2;
            if track.clips()[m].start > t1 { b = m } else { a = m + 1 }
        }
        lo..lo.max(a)
    }

    /// `ClipDrawing.draw`: body, trim hints, edge, selection ring, thumbnail well and name.
    fn draw_clip(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect, selected: bool, track: &Track) {
        let skin = self.skin();
        let body = rect.inset(0.0, TimelineSkin::CLIP_INSET);
        let offline = self.is_offline(c);
        let fill_color = if offline { skin.offline_clip() } else { self.theme.clip(self.labels.label(c)) };
        if body.width < 3.0 {
            // LOD: a sliver is one plain fill
            cv.fill(body, if selected { self.theme.label() } else { fill_color });
            return;
        }
        // Clamp to the visible span (8 pt slack) so a long clip's rounded ends never draw far off-screen.
        let x0 = body.min_x().max(visible.min_x() - 8.0);
        let x1 = body.max_x().min(visible.max_x() + 8.0);
        let drawn = CGRect::new(x0, body.min_y(), (x1 - x0).max(0.0), body.height);
        let radius = Self::CLIP_RADIUS.min(body.height / 2.0);
        // The band (name strip) carries the clip color, the body is one step darker; selected lifts the band 12 %.
        let band_h = ClipBodyMetrics::NAME_STRIP_HEIGHT.min(drawn.height);
        let band_color = if selected && !offline { fill_color.lifted(0.12) } else { fill_color };
        if offline || drawn.height < ClipBodyMetrics::BODY_MIN_HEIGHT {
            cv.fill_rounded(drawn, radius, band_color);
        } else {
            cv.fill_rounded(drawn, radius, self.theme.clip_body(self.labels.label(c)));
            cv.save_gstate();
            cv.clip_to(CGRect::new(drawn.min_x(), drawn.min_y(), drawn.width, band_h));
            cv.fill_rounded(drawn, radius, band_color);
            cv.restore_gstate();
        }
        if offline {
            cv.fill(
                CGRect::new(drawn.min_x() + radius, body.min_y(), (drawn.width - 2.0 * radius).max(0.0), 2.0),
                skin.red(),
            );
        }
        if selected {
            self.draw_trim_hints(cv, body, drawn);
        }
        // 1 px inner ring (`color/clip_ring`), then the selection: 1.5 px white inside.
        cv.stroke_rounded(
            drawn.inset(0.5, 0.5),
            radius,
            1.0,
            self.theme.token(sq_uikit::redesign_tokens::color::CLIP_RING),
        );
        if selected {
            let w = f64::from(sq_uikit::redesign_tokens::size::FOCUS_FRAME);
            cv.stroke_rounded(drawn.inset(w / 2.0, w / 2.0), (radius - w / 2.0).max(0.0), w, Color::WHITE);
            // Light theme (spec 13): a 1 px outline in the ink color around the white one, so it reads on pale lanes.
            if !self.theme.palette.is_dark() {
                cv.stroke_rounded(drawn.inset(-0.5, -0.5), radius + 0.5, 1.0, self.theme.label());
            }
        }
        let flat = c.generator.is_some() || c.sequence.is_some() || offline;
        let tall = !flat && drawn.height >= ClipBodyMetrics::BODY_MIN_HEIGHT;
        let thumbs = if tall && track.kind == TrackKind::Video {
            self.draw_thumbnails(cv, c, &ClipFrame { rect, body, drawn, radius, selected, visible })
        } else {
            (0.0, 0.0)
        };
        let thumb_w = thumbs.0;
        let fx_reserve = if track.kind == TrackKind::Video && sq_timeline_ui::FXBadge::state(c) == FXBadgeState::Applied
        {
            Self::fx_badge_reserve(rect.width, cv)
        } else {
            0.0
        };
        self.draw_item_lane_chevron(cv, c, rect, visible);
        let lane_reserve = if self.item_lanes_offered(c) { ItemLaneMetrics::chevron_reserve(rect.width) } else { 0.0 };
        let text_left = (body.min_x() + thumb_w).max(visible.min_x()) + 6.0 + lane_reserve;
        let text_width = body.max_x().min(visible.max_x()) - text_left - 4.0 - fx_reserve - thumbs.1;
        if text_width < 14.0 {
            return;
        }
        let name =
            if offline { "Media offline".to_string() } else { format!("{}{}", c.name, SpeedLabel::name_suffix(c)) };
        let color = if offline { skin.offline_text() } else { TimelineSkin::text_on(fill_color) };
        let size = f64::from(sq_uikit::redesign_tokens::type_size::SMALL);
        let medium = cv.medium();
        let line_h = cv.size_of("Ag", size, medium).height;
        // The name is centered in the 14 pt band.
        let mid = body.min_y() + band_h / 2.0;
        cv.save_gstate();
        cv.clip_to(CGRect::new(
            text_left,
            body.min_y(),
            text_width,
            body.height.min(f64::from(metrics::CLIP_NAME_BAND) + 6.0),
        ));
        let shown = cv.ellipsized(&name, size, medium, text_width);
        cv.draw_text(
            &shown,
            CGPoint { x: text_left, y: (mid - line_h / 2.0).round() },
            size,
            color,
            f64::INFINITY,
            medium,
        );
        cv.restore_gstate();
    }

    /// `ClipDrawing.drawTrimHints`: shaded bars at both ends with a grip line, as wide as the trim handle.
    fn draw_trim_hints(&self, cv: &mut Canvas, body: CGRect, drawn: CGRect) {
        let w = TimelineGeometry::trim_handle_width(body.width);
        if w < 3.0 {
            return;
        }
        let grip_h = (body.height - 6.0).min(8.0);
        for left in [true, false] {
            let x = if left { body.min_x() } else { body.max_x() - w };
            if !(x + w >= drawn.min_x() && x <= drawn.max_x()) {
                continue;
            }
            cv.fill(CGRect::new(x, body.min_y(), w, body.height), self.skin().clip_shade());
            if grip_h > 0.0 {
                cv.fill(
                    CGRect::new((x + w / 2.0 - 0.5).round(), body.mid_y() - grip_h / 2.0, 1.0, grip_h),
                    self.theme.label2(),
                );
            }
        }
    }

    /// A clip whose media is missing from the project (the Mac also reads the media status; this has the project only).
    pub(crate) fn is_offline(&self, c: &Clip) -> bool {
        c.generator.is_none() && c.sequence.is_none() && self.media.as_ref().is_some_and(|m| m.is_offline(c.media))
    }

    /// `ClipMarkerFlags.draw`: a flag in the marker's color at the clip's bottom edge.
    fn draw_clip_marker_flags(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect) {
        if rect.width < ClipMarkerFlags::MIN_CLIP_WIDTH {
            return;
        }
        let (w, h) = (ClipMarkerFlags::FLAG_WIDTH, ClipMarkerFlags::FLAG_HEIGHT);
        for m in c.visible_markers(self.geometry.frame_duration) {
            let x = self.geometry.x(c.start + m.time);
            if !(x >= visible.min_x() - w && x <= visible.max_x() + w) {
                continue;
            }
            let p = |x: f64, y: f64| CGPoint { x, y };
            cv.fill_polygon(
                &[p(x, rect.max_y()), p(x + w / 2.0, rect.max_y() - h), p(x - w / 2.0, rect.max_y() - h)],
                self.theme.label2(),
            );
        }
    }

    // MARK: Transitions (`TimelineView+Transitions`)

    fn draw_transitions(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let fd = self.timeline.format.frame_duration;
        for row in rows {
            if !(row.max_y() > clip.min_y() && row.y < clip.max_y()) {
                continue;
            }
            let Some(track) = self.timeline.tracks.iter().find(|t| t.id == row.track) else { continue };
            if track.transitions.is_empty() {
                continue;
            }
            for r in track.resolved_transitions(fd) {
                let b = TransitionLayout::rect(&r, row, &self.geometry);
                if b.max_x() >= clip.min_x() && b.min_x() <= clip.max_x() {
                    self.draw_transition(cv, &r, b, Some(r.id) == self.selected_transition);
                }
            }
        }
        self.draw_transition_layer_clips(cv, rows, clip);
    }

    /// `TimelineView.heldHatchRects`, copied (the Mac copy lives in an AppKit file).
    pub(crate) fn held_hatch_rects(r: &ResolvedTransition, b: CGRect) -> Vec<CGRect> {
        let total = r.frames() as f64;
        if !(total > 0.0 && r.is_held()) {
            return Vec::new();
        }
        let fd = r.frame_duration;
        let before = r.before.frame_index(fd) as f64;
        let after = r.after.frame_index(fd) as f64;
        let cut_x = b.min_x() + b.width * (before / total);
        let mut out = Vec::new();
        if r.held_before > 0 {
            let w = b.width * (r.held_before as f64 / total);
            out.push(CGRect::new(cut_x - w, b.min_y(), w, b.height));
        }
        if r.held_after > 0 {
            let w = b.width * ((r.held_after as f64).min(after) / total);
            out.push(CGRect::new(cut_x, b.min_y(), w, b.height));
        }
        out
    }

    fn draw_transition(&self, cv: &mut Canvas, r: &ResolvedTransition, b: CGRect, selected: bool) {
        let skin = self.skin();
        let shape = b.inset(0.5, 0.5);
        let rad = f64::from(radius::SMALL);
        cv.fill_rounded(shape, rad, skin.clip_shade());
        cv.stroke_line(
            CGPoint { x: b.min_x() + 1.0, y: b.max_y() - 2.0 },
            CGPoint { x: b.max_x() - 1.0, y: b.min_y() + 2.0 },
            1.0,
            if selected { self.theme.on_clip() } else { self.theme.label2() },
        );
        cv.stroke_rounded(
            shape,
            rad,
            if selected { TimelineSkin::SELECTION_OUTLINE_WIDTH } else { 1.0 },
            if selected { skin.selection_outline() } else { self.theme.label2() },
        );
        for area in Self::held_hatch_rects(r, b) {
            cv.save_gstate();
            cv.clip_to(area.inset(0.0, 1.0));
            let mut x = area.min_x() - area.height;
            while x < area.max_x() {
                cv.stroke_line(
                    CGPoint { x, y: area.min_y() },
                    CGPoint { x: x + area.height, y: area.max_y() },
                    1.0,
                    skin.transition_issue(),
                );
                x += 5.0;
            }
            cv.restore_gstate();
        }
        if r.is_clamped() {
            cv.fill(CGRect::new(b.max_x() - 3.0, b.min_y() + 1.0, 2.0, b.height - 2.0), skin.red());
        }
        if b.width >= 74.0 && b.height >= 28.0 {
            let name = TransitionKind::name(r.kind);
            let fs = f64::from(type_size::CAPTION);
            let s = cv.size_of(name, fs, 0);
            if s.width + 10.0 < b.width {
                cv.draw_text(
                    name,
                    CGPoint { x: b.mid_x() - s.width / 2.0, y: b.max_y() - s.height - 3.0 },
                    fs,
                    self.theme.on_clip(),
                    f64::INFINITY,
                    0,
                );
            }
        }
    }

    // MARK: In/Out tint, playhead line, gesture overlay

    fn draw_in_out_tint(&self, cv: &mut Canvas, clip: CGRect) {
        let Some(io) = self.timeline.in_out.filter(|io| !io.is_empty()) else { return };
        let (x0, x1) = (self.geometry.x(io.start), self.geometry.x(io.end()));
        if !(x1 > clip.min_x() && x0 < clip.max_x()) {
            return;
        }
        cv.fill(
            CGRect::new(x0, clip.min_y(), x1 - x0, clip.height).intersection(&clip),
            self.theme.label().with_alpha(0.04),
        );
        // work-area bar under the ruler (artifact)
        cv.fill(CGRect::new(x0, clip.min_y(), x1 - x0, 2.0).intersection(&clip), self.theme.accent());
        if x0 >= clip.min_x() {
            cv.fill(CGRect::new(x0, clip.min_y(), 1.0, clip.height), self.theme.hair());
        }
        if x1 - 1.0 <= clip.max_x() {
            cv.fill(CGRect::new(x1 - 1.0, clip.min_y(), 1.0, clip.height), self.theme.hair());
        }
    }

    fn draw_playhead_line(&self, cv: &mut Canvas, clip: CGRect) {
        let x = self.geometry.x(self.playhead);
        if !(x >= clip.min_x() - 2.0 && x <= clip.max_x() + 2.0) {
            return;
        }
        cv.fill(TimelineSkin::line_frame(x, clip.min_y(), clip.height), self.theme.playhead());
    }

    /// `updateRazorGuide`: where a click would cut, with the live Shift (every track) and Option (ignore links) as held.
    fn razor_guide_rects(&self, rows: &[TrackRow], clip: CGRect) -> Vec<CGRect> {
        let Some(p) = self.hover_point else { return Vec::new() };
        if !(self.tool_state().timeline_tool() == TimelineTool::Razor
            && self.gesture.is_none()
            && p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT
            && p.y < self.size.height - Self::ZOOM_BAR_HEIGHT)
        {
            return Vec::new();
        }
        let live = self.live_mods();
        let tracks = self.interaction.razor_guide_tracks(
            p,
            live.contains(InputModifiers::SHIFT),
            live.contains(InputModifiers::OPTION),
        );
        if tracks.is_empty() {
            return Vec::new();
        }
        let set: std::collections::BTreeSet<Id> = tracks.into_iter().collect();
        sq_timeline_ui::RazorGuide::rects(self.geometry.x(self.interaction.razor_cut_time(p.x)), &set, rows)
            .into_iter()
            .filter(|r| r.intersects(&clip))
            .collect()
    }

    fn draw_gesture_overlay(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        let skin = self.skin();
        for r in self.razor_guide_rects(rows, clip) {
            cv.fill(r, Color::WHITE);
        }
        if let Some(t) = self.interaction.snap_time().or(self.scrub_snap_time) {
            let x = self.geometry.x(t).round();
            cv.fill(CGRect::new(x - 0.5, clip.min_y(), 1.0, clip.height), skin.snap_line());
        }
        let bold = f64::from(type_size::BODY);
        let audio_rows: Vec<&TrackRow> = rows.iter().filter(|r| r.kind == TrackKind::Audio).collect();
        if let Some(g) = self.interaction.split_roll_ghost()
            && let Some(first) = audio_rows.first()
        {
            let x = self.geometry.x(g.cut).round();
            for row in &audio_rows {
                cv.fill(CGRect::new(x - 1.0, row.y + 1.0, 2.0, row.height - 2.0), self.theme.label2());
            }
            let label = g.label(self.timeline.format.frame_duration);
            let s = cv.size_of(&label, bold, 0);
            let b = CGRect::new(self.geometry.x(g.cut + g.offset) + 6.0, first.y + 4.0, s.width + 10.0, s.height + 4.0);
            cv.fill_rounded(b, f64::from(radius::SMALL), skin.hud_fill());
            cv.draw_text(
                &label,
                CGPoint { x: b.min_x() + 5.0, y: b.min_y() + 2.0 },
                bold,
                self.theme.on_clip(),
                f64::INFINITY,
                0,
            );
        }
        if let Some(g) = self.interaction.reorder_ghost()
            && let Some(row) = rows.iter().find(|r| r.track == g.track)
        {
            let (x0, x1) = (self.geometry.x(g.range.start), self.geometry.x(g.range.end()));
            let r = CGRect::new(x0, row.y + 1.0, (x1 - x0).max(2.0), row.height - 2.0);
            cv.fill_rounded(r, f64::from(radius::SMALL), skin.hud_fill());
            cv.stroke_rounded(r, f64::from(radius::SMALL), 1.5, skin.snap_line());
            cv.draw_text(
                &g.name,
                CGPoint { x: r.min_x() + 6.0, y: r.min_y() + 4.0 },
                bold,
                self.theme.on_clip(),
                (r.width - 12.0).max(0.0),
                0,
            );
        }
        if let Some(g) = self.interaction.gap_selection()
            && let Some(row) = rows.iter().find(|r| r.track == g.track)
        {
            let (x0, x1) = (self.geometry.x(g.range.start), self.geometry.x(g.range.end()));
            let r = CGRect::new(x0, row.y + 1.0, x1 - x0, row.height - 2.0);
            let w = TimelineSkin::SELECTION_OUTLINE_WIDTH;
            cv.stroke_rounded(r.inset(w / 2.0, w / 2.0), 0.0, w, skin.selection_outline());
        }
        if let Some(e) = self.interaction.edge_selection() {
            let color = if e.ripple { skin.warning() } else { self.theme.accent() };
            for r in &e.edges {
                let Some(t) = EdgeEdits::time(*r, &self.timeline) else { continue };
                let Some((_, tr)) = self.clip_and_track(r.clip) else { continue };
                let Some(row) = rows.iter().find(|row| row.track == tr) else { continue };
                let x = self.geometry.x(t).round();
                cv.fill(
                    CGRect::new(
                        if r.edge == sq_core_model::ClipEdge::Head { x } else { x - 3.0 },
                        row.y + 1.0,
                        3.0,
                        row.height - 2.0,
                    ),
                    color,
                );
            }
        }
        if let Some(Gesture::Zoom { start: a, current: b, .. }) = &self.gesture
            && (b.x - a.x).hypot(b.y - a.y) >= TimelineInteraction::DRAG_THRESHOLD
        {
            let r = CGRect::new(a.x.min(b.x), a.y.min(b.y), (a.x - b.x).abs(), (a.y - b.y).abs());
            cv.fill(r, skin.accent_tint());
            cv.stroke_rounded(r.inset(0.5, 0.5), 0.0, 1.0, self.theme.accent());
        }
        if let Some(m) = self.interaction.marquee() {
            cv.fill(m, skin.accent_tint());
            cv.stroke_rounded(m.inset(0.5, 0.5), 0.0, 1.0, self.theme.accent());
        }
    }
}
