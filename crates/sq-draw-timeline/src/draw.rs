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
use sq_uikit::sqicon::SQIcon;
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
        self.cut_tips.borrow_mut().clear();
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
        self.draw_state_overlay(cv, &rows, content);
        cv.restore_gstate();
        self.draw_vertical_scroll_hint(cv);
        self.draw_headers(cv, &rows);
        self.draw_item_lane_headers(cv, &rows);
        self.draw_zoom_bar(cv); // over the header column's foot, like the Mac footer subview
        self.draw_ruler(cv);
    }

    /// r8 states of the lanes: skeleton clips while the project opens (r8:1121), "Drag Clips Here" while no track holds a
    /// clip (r8:641, 796). Over everything in the lane area, the playhead included.
    fn draw_state_overlay(&self, cv: &mut Canvas, rows: &[TrackRow], content: CGRect) {
        self.empty_import.set(None);
        if self.loading {
            cv.fill(content, self.theme.timeline()); // the clips are hidden while the project opens
            let (bar, r) = (self.theme.pressed().with_alpha(0.65), sq_uikit::redesign_tokens::radius::CLIP as f64);
            for (i, row) in rows.iter().enumerate() {
                // shortcut: a fixed pattern of blocks per row, no pulse; upgrade when a real open reports its clips.
                let blocks: &[(f64, f64)] = match i % 4 {
                    0 => &[(0.0, 0.34), (0.36, 0.26)],
                    1 => &[(0.0, 0.2)],
                    2 => &[(0.0, 0.5), (0.52, 0.2)],
                    _ => &[(0.0, 0.9)],
                };
                for (x, w) in blocks {
                    let b = CGRect::new(
                        content.min_x() + x * content.width,
                        row.y + 2.0,
                        w * content.width,
                        (row.height - 4.0).max(0.0),
                    );
                    cv.fill_rounded(b, r, bar);
                }
            }
            return;
        }
        if !self.timeline.tracks.iter().all(|t| t.clips().is_empty()) {
            return;
        }
        let t = self.theme;
        cv.fill(content, t.lane());
        let text = (
            sq_uikit::localization::SQL10n::string("Drag Clips Here"),
            sq_uikit::localization::SQL10n::string(
                "Drop media from the Library or Project on a track, or import new files.",
            ),
            sq_uikit::localization::SQL10n::string("Import\u{2026}"),
        );
        let pane = sq_draw::empty_pane::EmptyPane {
            icon: SQIcon::Import,
            title: &text.0,
            hint: &text.1,
            button: Some(&text.2),
        };
        let hover = self.hover_point;
        let b = sq_draw::empty_pane::draw_empty_pane(cv, &t, content, &pane, |b| hover.is_some_and(|h| b.contains(h)));
        self.empty_import.set(b);
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
            if track.is_locked {
                self.draw_lock_hatch(cv, lane_rect);
            }
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

    /// A locked lane's hatch (draft `.lane.locked`): 135 degree hairlines every 7 pt in `border-row`.
    fn draw_lock_hatch(&self, cv: &mut Canvas, lane: CGRect) {
        use sq_uikit::redesign_tokens::color;
        const STEP: f64 = 7.0;
        let ink = self.theme.token(color::ROW_LINE);
        cv.save_gstate();
        cv.clip_to(lane);
        let mut x = lane.min_x() - lane.height + (STEP - lane.min_x().rem_euclid(STEP)) % STEP;
        while x < lane.max_x() {
            cv.stroke_polyline(
                &[CGPoint { x, y: lane.max_y() }, CGPoint { x: x + lane.height, y: lane.min_y() }],
                1.0,
                ink,
            );
            x += STEP;
        }
        cv.restore_gstate();
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
        self.draw_clip_content(cv, c, rect, visible, selected, track);
        self.draw_clip_pressed_veil(cv, rect, visible);
        self.draw_clip_ring(cv, rect, visible, selected);
    }

    /// The pressed clip darkens (`brightness(.88)`, draft `.clip.is-down`): a black veil of 12 % under the ring. The
    /// pressed clip is the one under the pointer while a clip gesture runs.
    fn draw_clip_pressed_veil(&self, cv: &mut Canvas, rect: CGRect, visible: CGRect) {
        use sq_uikit::redesign_tokens::color;
        if !matches!(self.gesture, Some(Gesture::Clips)) {
            return;
        }
        let body = rect.inset(0.0, TimelineSkin::CLIP_INSET);
        let x0 = body.min_x().max(visible.min_x() - 8.0);
        let x1 = body.max_x().min(visible.max_x() + 8.0);
        let drawn = CGRect::new(x0, body.min_y(), (x1 - x0).max(0.0), body.height);
        if body.width < 3.0 || !self.hover_point.is_some_and(|p| drawn.has(p)) {
            return;
        }
        cv.fill_rounded(drawn, Self::CLIP_RADIUS.min(body.height / 2.0), self.theme.token(color::CLIP_PRESSED));
    }

    /// The ring above everything in the clip (r8:433-436): `clip-ring`, `clip-hover` under the pointer, and selected =
    /// `inset 3px clip-selection` (white) under `inset 1px clip-selection-edge`.
    fn draw_clip_ring(&self, cv: &mut Canvas, rect: CGRect, visible: CGRect, selected: bool) {
        use sq_uikit::redesign_tokens::color;
        let body = rect.inset(0.0, TimelineSkin::CLIP_INSET);
        if body.width < 3.0 {
            return;
        }
        let x0 = body.min_x().max(visible.min_x() - 8.0);
        let x1 = body.max_x().min(visible.max_x() + 8.0);
        let drawn = CGRect::new(x0, body.min_y(), (x1 - x0).max(0.0), body.height);
        let radius = Self::CLIP_RADIUS.min(body.height / 2.0);
        if selected {
            let w = 3.0;
            cv.stroke_rounded(
                drawn.inset(w / 2.0, w / 2.0),
                (radius - w / 2.0).max(0.0),
                w,
                self.theme.token(color::USE),
            );
            cv.stroke_rounded(drawn.inset(0.5, 0.5), radius, 1.0, self.theme.token(color::CLIP_SELECTION_EDGE));
            return;
        }
        let hover = self.gesture.is_none() && self.hover_point.is_some_and(|p| drawn.has(p));
        let ring = if hover { color::CLIP_HOVER } else { color::CLIP_RING };
        cv.stroke_rounded(drawn.inset(0.5, 0.5), radius, 1.0, self.theme.token(ring));
    }

    fn draw_clip_content(
        &self,
        cv: &mut Canvas,
        c: &Clip,
        rect: CGRect,
        visible: CGRect,
        selected: bool,
        track: &Track,
    ) {
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
        if offline {
            // r8:645-647: the clip is `surface-raised`, only the name band is `state-error`.
            cv.fill_rounded(drawn, radius, fill_color);
            cv.save_gstate();
            cv.clip_to(CGRect::new(drawn.min_x(), drawn.min_y(), drawn.width, band_h));
            cv.fill_rounded(drawn, radius, self.theme.token(sq_uikit::redesign_tokens::color::RED));
            cv.restore_gstate();
        } else if drawn.height < ClipBodyMetrics::BODY_MIN_HEIGHT {
            cv.fill_rounded(drawn, radius, band_color);
        } else {
            cv.fill_rounded(drawn, radius, self.theme.clip_body(self.labels.label(c)));
            cv.save_gstate();
            cv.clip_to(CGRect::new(drawn.min_x(), drawn.min_y(), drawn.width, band_h));
            cv.fill_rounded(drawn, radius, band_color);
            cv.restore_gstate();
        }
        if selected {
            self.draw_trim_hints(cv, body, drawn);
        }
        let flat = c.generator.is_some() || c.sequence.is_some() || offline;
        let tall = !flat && drawn.height >= ClipBodyMetrics::BODY_MIN_HEIGHT;
        let thumbs = if tall && track.kind == TrackKind::Video {
            self.draw_thumbnails(cv, c, &ClipFrame { rect, body, drawn, radius, visible })
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
        // Selecting never moves the name: the white ring is an overlay, the band keeps its place.
        let band_in = 0.0;
        let text_left = (body.min_x() + thumb_w).max(visible.min_x()) + 6.0 + lane_reserve + band_in;
        let text_width = body.max_x().min(visible.max_x()) - text_left - 4.0 - fx_reserve - thumbs.1 - band_in;
        if text_width < 14.0 {
            return;
        }
        // An offline clip keeps its file name next to the notice.
        let full = format!("{}{}", c.name, SpeedLabel::name_suffix(c));
        let name = if offline { format!("Media offline \u{2013} {full}") } else { full };
        let color = if offline { self.theme.on_clip() } else { TimelineSkin::text_on(fill_color) };
        let size = f64::from(sq_uikit::redesign_tokens::type_size::SMALL);
        let medium = cv.medium();
        let line_h = cv.size_of("Ag", size, medium).height;
        // The name is centered in the 14 pt band.
        let band_top = body.min_y() + band_in;
        let mid = band_top + band_h / 2.0;
        cv.save_gstate();
        cv.clip_to(CGRect::new(
            text_left,
            band_top,
            text_width,
            (body.height - band_in).min(f64::from(metrics::CLIP_NAME_BAND) + 6.0),
        ));
        let cut = sq_draw::middle_fit::truncate_name(&name, |t| cv.size_of(t, size, medium).width <= text_width);
        if let Some(full) = cut.full {
            let at = CGRect::new(text_left, band_top, text_width, band_h);
            self.cut_tips.borrow_mut().push((at, full));
        }
        let shown = cut.shown;
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

#[cfg(test)]
mod hover_ring_tests {
    use crate::panel::TimelinePanel;
    use sq_draw::{Canvas, DrawTheme};
    use sq_uikit::controls_grid::{CGPoint, CGRect};

    /// The ring's colors drawn for one clip with the pointer at `at`.
    fn ring_colors(at: Option<CGPoint>, selected: bool) -> Vec<sq_draw::Color> {
        let mut p = TimelinePanel::new(DrawTheme::default());
        p.hover_point = at;
        let mut cv = Canvas::with_size(400.0, 100.0, None, 1.0);
        let rect = CGRect::new(10.0, 10.0, 200.0, 60.0);
        p.draw_clip_ring(&mut cv, rect, CGRect::new(0.0, 0.0, 400.0, 100.0), selected);
        cv.list.quads().iter().map(|q| q.color).collect()
    }

    #[test]
    fn a_clip_under_the_pointer_draws_the_clip_hover_ring() {
        use sq_uikit::redesign_tokens::color;
        let t = DrawTheme::default();
        let (hover, rest) = (t.token(color::CLIP_HOVER), t.token(color::CLIP_RING));
        let under = ring_colors(Some(CGPoint::new(60.0, 40.0)), false);
        assert!(!under.is_empty() && under.iter().all(|c| *c == hover), "hover ring expected: {under:?}");
        let away = ring_colors(Some(CGPoint::new(300.0, 40.0)), false);
        assert!(!away.is_empty() && away.iter().all(|c| *c == rest), "rest ring expected: {away:?}");
        assert_ne!(hover, rest);
    }
}

/// Selecting a clip changes only the ring; hovering the ruler or a track head highlights nothing.
#[cfg(test)]
mod select_hover_tests {
    use crate::panel::TimelinePanel;
    use crate::tests::{clip, track, uid};
    use sq_core_model::TrackKind;
    use sq_draw::{Canvas, DrawTheme, GlyphAtlas, text_log};
    use sq_uikit::controls_grid::{CGPoint, CGRect};

    fn atlas() -> Option<GlyphAtlas> {
        let fonts = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        GlyphAtlas::inter(&fonts)
    }

    /// The text boxes a clip's content draws.
    fn clip_text(selected: bool, kind: TrackKind, atlas: &GlyphAtlas) -> Vec<(String, (f32, f32, f32, f32))> {
        let p = TimelinePanel::new(DrawTheme::default());
        let mut c = clip(1, 0, 100, kind);
        c.name = "C2176.mp4".into();
        let tr = track(2, kind, vec![c.clone()]);
        let mut cv = Canvas::with_size(600.0, 120.0, Some(atlas), 1.0);
        let rect = CGRect::new(10.0, 10.0, 400.0, 60.0);
        text_log::start();
        p.draw_clip_content(&mut cv, &c, rect, CGRect::new(0.0, 0.0, 600.0, 120.0), selected, &tr);
        text_log::finish().into_iter().map(|r| (r.asked, r.rect)).collect()
    }

    #[test]
    fn a_selected_clip_keeps_its_name_where_it_was() {
        let Some(atlas) = atlas() else { return };
        for kind in [TrackKind::Video, TrackKind::Audio] {
            let (off, on) = (clip_text(false, kind, &atlas), clip_text(true, kind, &atlas));
            assert!(off.iter().any(|(t, _)| t.contains("C2176")), "the name is drawn: {off:?}");
            assert_eq!(off, on, "selecting moved the text of a {kind:?} clip");
        }
    }

    #[test]
    fn hovering_a_track_head_away_from_its_buttons_draws_no_highlight() {
        let tr = track(2, TrackKind::Video, Vec::new());
        let draw = |hover: bool| {
            let mut p = TimelinePanel::new(DrawTheme::default());
            if hover {
                p.hover_track = Some(tr.id);
                p.hover_point = Some(CGPoint::new(80.0, 5.0));
            }
            let mut cv = Canvas::with_size(300.0, 80.0, None, 1.0);
            p.draw_header(&mut cv, &tr, "V1", 140.0, 40.0, false);
            cv.list.quads().iter().map(|q| (q.rect, q.color)).collect::<Vec<_>>()
        };
        assert_eq!(draw(false), draw(true));
        let _ = uid(0);
    }

    #[test]
    fn hovering_the_ruler_draws_no_highlight() {
        let draw = |hover: bool| {
            let mut p = TimelinePanel::new(DrawTheme::default());
            p.hover_point = hover.then(|| CGPoint::new(300.0, 5.0));
            let mut cv = Canvas::with_size(800.0, 60.0, None, 1.0);
            p.draw_ruler(&mut cv);
            cv.list.quads().iter().map(|q| (q.rect, q.color)).collect::<Vec<_>>()
        };
        assert_eq!(draw(false), draw(true));
    }

    /// Proof render (`cargo test -p sq-draw-timeline select_proof -- --ignored`, `SQ_PROOF_DIR`): the same clip unselected
    /// and selected as PPM files, and the pixel diff of the name region inside the ring.
    #[test]
    #[ignore = "writes proof images"]
    fn select_proof_renders() {
        use sq_draw::{SoftwareRenderer, Sources};
        let Some(atlas) = atlas() else { panic!("Inter not found") };
        let dir = std::path::PathBuf::from(std::env::var("SQ_PROOF_DIR").expect("SQ_PROOF_DIR"));
        std::fs::create_dir_all(&dir).unwrap();
        let scale = 2.0_f32;
        let render = |selected: bool| {
            let p = TimelinePanel::new(DrawTheme::default());
            let mut c = clip(1, 0, 100, TrackKind::Video);
            c.name = "C2176.mp4".into();
            let tr = track(2, TrackKind::Video, vec![c.clone()]);
            let mut cv = Canvas::with_size(420.0, 80.0, Some(&atlas), scale);
            let (rect, vis) = (CGRect::new(10.0, 6.0, 400.0, 64.0), CGRect::new(0.0, 0.0, 420.0, 80.0));
            cv.fill(vis, p.theme.timeline());
            p.draw_clip(&mut cv, &c, rect, vis, selected, &tr);
            let src = Sources { atlas: Some(&atlas), video: None, images: &[] };
            SoftwareRenderer::render(&cv.list, 840, 160, p.theme.timeline(), &src)
        };
        let (off, on) = (render(false), render(true));
        for (name, img) in [("clip-unselected", &off), ("clip-selected", &on)] {
            let mut ppm = format!("P6\n{} {}\n255\n", img.width, img.height).into_bytes();
            ppm.extend(img.pixels.chunks(4).flat_map(|p| [p[0], p[1], p[2]]));
            std::fs::write(dir.join(format!("{name}.ppm")), ppm).unwrap();
        }
        // The name region inside the ring (3 pt = 6 px in from the clip edge), in pixels.
        let (x0, x1, y0, y1) = (
            ((10.0 + 8.0) * scale) as usize,
            ((410.0 - 8.0) * scale) as usize,
            ((6.0 + 4.0) * scale) as usize,
            ((6.0 + 20.0) * scale) as usize,
        );
        let mut differ = 0;
        for y in y0..y1 {
            for x in x0..x1 {
                let i = (y * off.width + x) * 4;
                if off.pixels[i..i + 3] != on.pixels[i..i + 3] {
                    differ += 1;
                }
            }
        }
        std::fs::write(
            dir.join("text-region-diff.txt"),
            format!("region x {x0}..{x1} y {y0}..{y1} (px): {differ} differing pixels of {}\n", (x1 - x0) * (y1 - y0)),
        )
        .unwrap();
    }
}
