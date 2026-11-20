// Swift: TimelinePanel+Input.swift
//! Events, translated from `TimelineView.mouseDown / mouseDragged / mouseUp / scrollWheel` and the autoscroll timer:
//! the same order of hit checks and the same `sq-timeline-ui` calls; callbacks become [`TimelineAction`]s.
//!

use crate::action::TimelineAction;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_audio::tone_generator::ToneClipExt as _;
use sq_core_edit::source_edit_placement::SourceEditPlacementExt as _;
use sq_core_edit::timeline_beat_snap::TimelineBeatSnapExt as _;
use sq_core_edit::timeline_clip_markers::TimelineClipMarkersExt as _;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt as _;
use sq_core_edit::timeline_markers::TimelineMarkersExt as _;
use sq_core_edit::timeline_trim_mode::TimelineTrimModeExt as _;
use sq_core_effects::transition::TrackTransitions as _;
use sq_core_time::Time;
use sq_draw::{InputEvent, InputKey, InputModifiers, UiCx};
use sq_editor_session::{GestureModifiers, TimelineTool};
use sq_timeline_ui::{
    ClipMarkerFlags, ClipMarkerHit, InOutDrag, MarkerDrag, MarkerEndDrag, MarkerRange, PlayheadSnap,
    TimelineAutoscroll, TimelineGeometry, TimelineInteraction, TimelineZoom, TrackSizing, TrackSizingZone,
    TransitionLayout, ZoomMode as ZoomAnimationMode,
};
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::editor_command::{EditorCommand, EditorTool};
use sq_uikit::key_binding::Key;
use std::collections::BTreeMap;

impl TimelinePanel {
    /// Seconds within which a second press counts as a double-click (the host reports no click count).
    pub(crate) const DOUBLE_CLICK_TIME: f64 = 0.5;
    /// Points within which a second press counts as a double-click.
    pub(crate) const DOUBLE_CLICK_DISTANCE: f64 = 4.0;

    /// Panel points of a host event position (device pixels in the window).
    pub fn point(&self, x: f32, y: f32) -> CGPoint {
        CGPoint { x: f64::from((x - self.frame.x) / self.scale), y: f64::from((y - self.frame.y) / self.scale) }
    }

    /// Handles one host event; mouse downs and wheel events outside the frame are ignored, drags and the release of a
    /// press that began here are taken wherever the pointer is.
    pub fn handle(&mut self, e: &InputEvent, ui: &mut UiCx) -> Vec<TimelineAction> {
        // Wheel, zoom bar, hand and zoom keys while playing: the user's view beats the playback follow (the Mac
        // viewport-change hook).
        let view = (self.geometry.scroll_x, self.geometry.points_per_second);
        let out = self.handle_event(e, ui);
        let moved = view != (self.geometry.scroll_x, self.geometry.points_per_second);
        if moved {
            self.zoom_animation = None; // a scroll or drag of the view ends a running ease (Mac `setScroll`)
        }
        if self.is_playing && moved {
            self.follow.user_scrolled(true);
        }
        self.publish_hover(e, ui);
        out
    }

    fn handle_event(&mut self, e: &InputEvent, ui: &mut UiCx) -> Vec<TimelineAction> {
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                if !self.frame.contains(x, y) {
                    return Vec::new();
                }
                let p = self.point(x, y);
                // The empty state's Import button (r8:796) runs the shell's Import command.
                if self.empty_import.get().is_some_and(|b| b.contains(p)) {
                    return vec![TimelineAction::Command(EditorCommand::ImportMedia)];
                }
                // A press catches a running rubber-band spring at once (the view settles at its end, a few points away).
                if self.is_springing_back() {
                    self.end_spring_back(true);
                }
                self.mouse_down(p, modifiers)
            }
            InputEvent::MouseDragged { x, y, .. } => {
                if self.gesture.is_none() && self.word_field_drag.is_none() {
                    return Vec::new();
                }
                let p = self.point(x, y);
                self.mouse_dragged(p)
            }
            InputEvent::MouseUp { x, y } => {
                if self.gesture.is_none() && self.word_field_drag.is_none() {
                    return Vec::new();
                }
                let p = self.point(x, y);
                self.mouse_up(p)
            }
            InputEvent::MouseMoved { x, y } => {
                let p = if self.frame.contains(x, y) { Some(self.point(x, y)) } else { None };
                self.mouse_moved(p)
            }
            InputEvent::Scroll { x, y, dx, dy, modifiers } => {
                if !self.frame.contains(x, y) {
                    return Vec::new();
                }
                let p = self.point(x, y);
                let g = ui.gesture_or_wheel(dx, dy);
                self.scroll_wheel(p, &g, modifiers);
                Vec::new()
            }
            InputEvent::KeyDown { key, modifiers } => {
                let out = self.key(key, modifiers, ui);
                self.key_handled = out.is_some();
                out.unwrap_or_default()
            }
        }
    }

    pub(crate) fn gesture_modifiers(m: InputModifiers) -> GestureModifiers {
        let mut g = GestureModifiers::default();
        if m.contains(InputModifiers::SHIFT) {
            g = g | GestureModifiers::SHIFT;
        }
        if m.contains(InputModifiers::COMMAND) {
            g = g | GestureModifiers::COMMAND;
        }
        if m.contains(InputModifiers::OPTION) {
            g = g | GestureModifiers::OPTION;
        }
        g
    }

    /// 1, 2, 3... for presses close in time and place (NSEvent.clickCount).
    pub(crate) fn click_count(&mut self, p: CGPoint) -> i64 {
        let now = (self.clock)();
        let mut n = 1;
        if let Some((time, point, count)) = self.last_click
            && now - time <= Self::DOUBLE_CLICK_TIME
            && (p.x - point.x).abs() <= Self::DOUBLE_CLICK_DISTANCE
            && (p.y - point.y).abs() <= Self::DOUBLE_CLICK_DISTANCE
        {
            n = count + 1;
        }
        self.last_click = Some((now, p, n));
        n
    }

    // MARK: Mouse down

    pub(crate) fn mouse_down(&mut self, p: CGPoint, mods: InputModifiers) -> Vec<TimelineAction> {
        // The right button (`rightMouseDown`): the host builds the menu (`TimelineMenus`), which selects first.
        // An open word field: a press inside keeps editing, any other press takes the text first (the field loses focus).
        if !mods.contains(InputModifiers::SECONDARY)
            && let Some(inside) = self.word_field_press(p)
        {
            return inside;
        }
        let mut typed = self.finish_word_field(true, 0);
        if mods.contains(InputModifiers::SECONDARY) {
            self.cancel_gesture();
            typed.push(TimelineAction::ContextMenu(p));
            return typed;
        }
        self.down_modifiers = mods;
        self.press_cursor = self.cursor_at_point(p, mods);
        if self.tool_state().keep_attached {
            self.keep_attached_used = true;
        }
        // A press ends the skim (the Mac `clearSkimmer`; the host's skim returns the monitor to the playhead).
        let skim_at = self.skimmer_time;
        if skim_at.is_some() {
            typed.push(TimelineAction::Skim(None));
        }
        self.skimmer_time = None;
        typed.extend(self.pressed(p, mods, skim_at));
        typed
    }

    fn pressed(&mut self, p: CGPoint, mods: InputModifiers, skimmed_time: Option<Time>) -> Vec<TimelineAction> {
        let clicks = self.click_count(p);
        let shift = mods.contains(InputModifiers::SHIFT);
        let command = mods.contains(InputModifiers::COMMAND);
        let tool = self.tool_state().timeline_tool();
        if self.zoom_bar_down(p, clicks) {
            return Vec::new();
        }
        if self.interaction.is_idle()
            && let Some(zone) = TrackSizing::zone(p, &self.rows(), self.size.width)
        {
            if zone == TrackSizingZone::Split && clicks == 2 {
                // double-click: back to the middle
                self.geometry.split_fraction = TrackSizing::DEFAULT_SPLIT_FRACTION;
                self.clamp_scroll();
                self.persist_heights();
                return Vec::new();
            }
            self.gesture = Some(Gesture::Resize {
                zone,
                start_y: p.y,
                rows: self.rows(),
                start_fraction: self.geometry.split_fraction,
            });
            return Vec::new();
        }
        if self.patch_down(p) {
            return Vec::new(); // the patch chip comes first in its header (Mac)
        }
        // The header buttons are subviews on the Mac: they take the press before the timeline sees it.
        if let Some((id, toggle)) = self.header_hit(p) {
            self.gesture = Some(Gesture::Header);
            return vec![TimelineAction::ToggleTrack {
                track: id,
                toggle,
                shift,
                option: mods.contains(InputModifiers::OPTION),
            }];
        }
        if let Some(lane) = self.item_lane_down(p, mods) {
            return lane;
        }
        if let sq_timeline_ui::TimelineHit::Header(id) = self.geometry.hit_test(p, &self.timeline) {
            self.gesture = Some(Gesture::Header);
            if clicks == 2 {
                let heights = TrackSizing::toggled(&self.rows(), id, shift);
                self.apply_heights(heights);
                self.persist_heights();
            }
            return Vec::new();
        }
        if self.keystone_down(p) {
            return Vec::new();
        }
        let mut out: Vec<TimelineAction> = Vec::new();
        if let Some(speed) = self.speed_down(p, mods) {
            return speed;
        }
        if let Some(key) = self.key_lane_down(p, shift) {
            return key;
        }
        if self.attach_down(p, mods) {
            self.last_drag = Some(p); // Fast Cut: drag the attach thread
            return Vec::new();
        }
        if let Some(band) = self.band_down(p, command, shift) {
            return band;
        }
        // A press anywhere else drops the picked line keys (the Mac view's `onLineKeyClick(nil)`).
        if !self.selected_line_keys.is_empty() {
            self.selected_line_keys.clear();
            out.push(TimelineAction::LineKeyClick { key: None, extend: false });
        }
        if let Some(t) = self.weak_stretch_jump(p) {
            self.playhead = t;
            out.push(TimelineAction::Seek(t));
            return out;
        }
        if let Some(id) = self.attach_point_click(p, mods) {
            out.push(TimelineAction::SetAttachPoint { clip: id, time: self.geometry.time(p.x) });
            return out;
        }
        if let Some(id) = self.caption_eye_hit(p) {
            out.push(TimelineAction::ToggleCaptionTrackVisibility(id));
            return out;
        }
        if tool == TimelineTool::Selection
            && let Some(layer) = self.transition_layer_down(p, clicks)
        {
            out.extend(layer);
            return out;
        }
        if tool == TimelineTool::Selection
            && let Some(hit) =
                TransitionLayout::hit_test(p, &self.timeline, &self.geometry, TimelineGeometry::MAX_TRIM_HANDLE_WIDTH)
        {
            let keep = shift || command;
            self.selected_transition = Some(hit.id);
            out.push(TimelineAction::SelectTransition { id: Some(hit.id), keep_clips: keep });
            if clicks == 2 {
                out.push(TimelineAction::EditTransition(hit.id));
                return out;
            }
            if let Some(track) = self.timeline.track(hit.track)
                && let Some(r) =
                    track.resolved_transitions(self.timeline.format.frame_duration).into_iter().find(|r| r.id == hit.id)
            {
                self.gesture = Some(Gesture::Transition {
                    hit,
                    original: Box::new(r),
                    start_x: p.x,
                    began: false,
                    last_frames: 0,
                });
            }
            return out;
        }
        let hit = self.geometry.hit_test(p, &self.timeline);
        // Two quick Razor or Zoom clicks are two cuts / zooms; every other tool opens the item on double-click.
        let opens = clicks == 2 && tool != TimelineTool::Razor && tool != TimelineTool::Zoom;
        if opens && let sq_timeline_ui::TimelineHit::Caption(id, _) = hit {
            // The word under the pointer becomes a field; a caption without words keeps the Text panel.
            return self.begin_word_editing_at(p, id).unwrap_or_else(|| vec![TimelineAction::EditCaption(id, None)]);
        }
        if clicks == 2
            && tool == TimelineTool::Selection
            && let sq_timeline_ui::TimelineHit::Clip(id, zone) = hit
            && zone != sq_timeline_ui::ClipZone::Body
            && let Some(tr) = self.timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == id))
            && let Some(c) = tr.clips().iter().find(|c| c.id == id)
            && !tr.is_locked
            && c.sequence.is_none()
            && c.generator.is_none()
            && self.geometry.x(c.timeline().end()) - self.geometry.x(c.start)
                >= 3.0 * TimelineGeometry::MAX_TRIM_HANDLE_WIDTH
            && let Some(point) = self
                .timeline
                .trim_point(if zone == sq_timeline_ui::ClipZone::Head { c.start } else { c.timeline().end() }, tr.id)
        {
            return vec![TimelineAction::OpenTrimMode {
                point,
                pointer_before: zone == sq_timeline_ui::ClipZone::Tail,
            }];
        }
        if opens
            && let sq_timeline_ui::TimelineHit::Clip(id, _) = hit
            && let Some(clip) = self.timeline.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id)
        {
            if let Some(seq) = clip.sequence {
                return vec![TimelineAction::OpenNestedSequence(seq)];
            }
            if clip.tone().is_some() {
                return vec![TimelineAction::EditToneClip(id)];
            }
            if clip.is_graphics() {
                return vec![TimelineAction::OpenGraphicLayers(id)];
            }
            if clip.generator.is_some() {
                return vec![TimelineAction::EditTextClip(id)];
            }
            return vec![TimelineAction::OpenInSource(clip.media)];
        }
        if hit == sq_timeline_ui::TimelineHit::Ruler {
            // Above the track headers the ruler shows nothing: markers and In/Out scrolled under there cannot be grabbed.
            let on_content = p.x >= TimelineGeometry::CONTENT_ORIGIN_X;
            if clicks == 2
                && let Some(m) = self.marker_id(p)
            {
                return vec![TimelineAction::EditMarker(m)];
            }
            if let Some(h) = self.marker_end_handle_id(p)
                && let Some(m) = self.timeline.markers.iter().find(|m| m.id == h)
            {
                self.gesture =
                    Some(Gesture::MarkerDuration { id: h, start: m.time, original: m.duration, moved: false });
                return Vec::new();
            }
            if let Some(m) = self.marker_id(p)
                && let Some(time) = self.timeline.markers.iter().find(|x| x.id == m).map(|x| x.time)
            {
                self.gesture = Some(Gesture::Marker { id: m, down_x: p.x, moved: false, original: time });
                return Vec::new();
            }
            if on_content
                && let Some(io) = self.timeline.in_out.filter(|io| !io.is_empty())
                && let Some(part) = InOutDrag::part(p.x, &io, &self.geometry)
            {
                self.gesture = Some(Gesture::InOut {
                    part,
                    down_x: p.x,
                    down_time: self.geometry.time(p.x),
                    moved: false,
                    original: io,
                });
                return Vec::new();
            }
            // The ruler is the playhead's handle: the press itself begins the scrub.
            self.gesture = Some(Gesture::Scrub);
            self.last_drag = Some(p);
            let t = self.scrub_time(p, shift);
            self.playhead = t;
            return vec![TimelineAction::BeginScrub, TimelineAction::Scrub(t)];
        }
        if tool != TimelineTool::Zoom
            && tool != TimelineTool::Hand
            && let Some(h) = ClipMarkerFlags::hit(p, &self.timeline, &self.geometry)
        {
            if clicks == 2 {
                return vec![TimelineAction::EditClipMarker { clip: h.clip, marker: h.marker }];
            }
            self.gesture = Some(Gesture::ClipMarker { hit: h, down_x: p.x, moved: false }); // a drag moves the flag; a plain click does nothing
            return Vec::new();
        }
        if tool == TimelineTool::Zoom
            && p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT
        {
            self.gesture =
                Some(Gesture::Zoom { start: p, current: p, zoom_out: mods.contains(InputModifiers::OPTION) });
            return Vec::new();
        }
        if self.selected_transition.is_some() && !shift && !command {
            self.selected_transition = None;
            out.push(TimelineAction::SelectTransition { id: None, keep_clips: false });
        }
        // Fast Cut: a plain press over the tracks also puts the playhead where the skimmer was (the Mac `mouseDown`).
        if let Some(t) = skimmed_time
            && clicks == 1
            && !mods.contains(InputModifiers::SHIFT)
            && !mods.contains(InputModifiers::COMMAND)
            && !mods.contains(InputModifiers::OPTION)
        {
            self.playhead = t;
            out.push(TimelineAction::Seek(t));
        }
        self.feed_interaction();
        self.interaction.mouse_down(p, Self::gesture_modifiers(mods));
        self.gesture = Some(Gesture::Clips);
        self.last_drag = Some(p);
        out.extend(self.refresh_from_interaction());
        out
    }

    // MARK: Drag

    pub(crate) fn mouse_dragged(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        if let Some(d) = self.word_field_drag.as_mut() {
            *d = (d.0, p.x, true);
            return Vec::new();
        }
        let Some(g) = self.gesture.clone() else { return Vec::new() };
        let shift = self.drag_modifiers().contains(InputModifiers::SHIFT);
        match g {
            Gesture::Transition { hit, original, start_x, began, last_frames } => {
                let frames =
                    (self.geometry.time(p.x) - self.geometry.time(start_x)).frame_index(self.geometry.frame_duration);
                if frames == last_frames && began {
                    return Vec::new();
                }
                if !began && (p.x - start_x).abs() < TimelineInteraction::DRAG_THRESHOLD {
                    return Vec::new();
                }
                let change = TransitionLayout::drag(&original, hit.zone, frames, shift);
                let id = hit.id;
                self.gesture = Some(Gesture::Transition { hit, original, start_x, began: true, last_frames: frames });
                vec![TimelineAction::ChangeTransition { id, change, continues: began }]
            }
            Gesture::Resize { zone, start_y, rows: start_rows, start_fraction } => {
                let dy = p.y - start_y;
                match zone {
                    TrackSizingZone::Split => {
                        // Only the split moves: the heights as drawn are frozen so stretched rows do not re-fit under the pointer.
                        let frozen = TrackSizing::frozen(&start_rows);
                        if self.geometry.height_overrides != frozen {
                            self.apply_heights(frozen);
                        }
                        self.geometry.split_fraction = TrackSizing::split_fraction(
                            start_fraction,
                            dy,
                            self.geometry.split_available(&self.timeline),
                        );
                        self.clamp_scroll();
                    }
                    TrackSizingZone::TrackEdge(id) => {
                        let start = start_rows.iter().find(|r| r.track == id).map_or(0.0, |r| r.height);
                        let heights = TrackSizing::resized(&start_rows, id, start + dy, shift);
                        self.apply_heights(heights);
                    }
                }
                Vec::new()
            }
            Gesture::Zoom { start, zoom_out, .. } => {
                self.gesture = Some(Gesture::Zoom { start, current: p, zoom_out });
                Vec::new()
            }
            Gesture::InOut { part, down_x, down_time, moved, original } => {
                if !moved && (p.x - down_x).abs() < TimelineInteraction::DRAG_THRESHOLD {
                    return Vec::new();
                }
                self.gesture = Some(Gesture::InOut { part, down_x, down_time, moved: true, original });
                self.last_drag = Some(p);
                self.drag_in_out(p);
                Vec::new()
            }
            Gesture::MarkerDuration { id, start, original, .. } => {
                self.gesture = Some(Gesture::MarkerDuration { id, start, original, moved: true });
                let r = MarkerRange::duration(
                    &MarkerEndDrag {
                        time: self.geometry.unsnapped_time(p.x),
                        start,
                        marker_id: id,
                        snapping: self.snapping(),
                        playhead: Some(self.playhead),
                        beat_level: self.beat_level,
                    },
                    &self.timeline,
                    &self.geometry,
                );
                let _ = self.timeline.set_marker_duration(id, r);
                Vec::new()
            }
            Gesture::Marker { id, down_x, moved, original } => {
                if !moved && (p.x - down_x).abs() < TimelineInteraction::DRAG_THRESHOLD {
                    return Vec::new();
                }
                self.gesture = Some(Gesture::Marker { id, down_x, moved: true, original });
                self.last_drag = Some(p);
                self.drag_marker(p);
                Vec::new()
            }
            Gesture::Scrub => {
                self.last_drag = Some(p);
                let t = self.scrub_time(p, shift);
                self.playhead = t;
                vec![TimelineAction::Scrub(t)]
            }
            Gesture::TransitionLayer(d) => self.transition_layer_dragged(d, p),
            Gesture::Patch { kind, down, dragging } => {
                self.patch_dragged(kind, down, dragging, p);
                Vec::new()
            }
            Gesture::Header => Vec::new(),
            Gesture::ZoomBar(s) => {
                self.zoom_bar_dragged(p, &s);
                Vec::new()
            }
            Gesture::ClipMarker { hit, down_x, moved } => {
                if !moved && (p.x - down_x).abs() < TimelineInteraction::DRAG_THRESHOLD {
                    return Vec::new();
                }
                self.gesture = Some(Gesture::ClipMarker { hit, down_x, moved: true });
                self.last_drag = Some(p);
                let r = self.clip_marker_target(&hit, p);
                self.timeline.move_clip_marker(hit.marker, hit.clip, r.0);
                self.scrub_snap_time = r.1.map(|s| s.time);
                Vec::new()
            }
            Gesture::Band(d) => self.band_dragged(*d, p),
            Gesture::Speed(_) => self.speed_dragged(p),
            Gesture::Attach { .. } => {
                self.attach_dragged(p);
                self.last_drag = Some(p);
                Vec::new()
            }
            Gesture::Keystone(d) => {
                self.keystone_dragged(&d, p);
                Vec::new()
            }
            Gesture::ItemLane => self.item_lane_dragged(p),
            Gesture::Clips => {
                self.interaction.geometry = self.geometry.clone();
                self.interaction.mouse_dragged(p, Self::gesture_modifiers(self.drag_modifiers()));
                self.last_drag = Some(p);
                self.refresh_from_interaction()
            }
        }
    }

    // MARK: Release

    pub(crate) fn mouse_up(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        self.word_field_drag = None;
        let Some(g) = self.gesture.clone() else { return Vec::new() };
        let out = self.mouse_up_gesture(g, p);
        self.gesture = None;
        self.last_drag = None;
        self.last_autoscroll = None;
        self.interaction.snap_inverted = false;
        out
    }

    fn mouse_up_gesture(&mut self, g: Gesture, p: CGPoint) -> Vec<TimelineAction> {
        match g {
            Gesture::Resize { .. } => {
                self.persist_heights();
                Vec::new()
            }
            Gesture::TransitionLayer(_) => Vec::new(),
            Gesture::Transition { .. } | Gesture::Header => Vec::new(),
            Gesture::Patch { kind, dragging, .. } => self.patch_up(kind, dragging, p),
            Gesture::Attach { .. } => self.attach_up(p),
            Gesture::Keystone(d) => self.keystone_up(&d, p),
            Gesture::ItemLane => self.item_lane_up(p),
            Gesture::Band(d) => self.band_up(*d, p),
            Gesture::Speed(_) => self.speed_up(p),
            Gesture::ZoomBar(_) => {
                self.zoom_bar_up();
                Vec::new()
            }
            Gesture::ClipMarker { hit, moved, .. } => {
                self.scrub_snap_time = None;
                if !moved {
                    return Vec::new();
                }
                let r = self.clip_marker_target(&hit, p);
                self.timeline.move_clip_marker(hit.marker, hit.clip, hit.time); // back to the original, the session commits
                if r.0 != hit.time {
                    vec![TimelineAction::MoveClipMarker { clip: hit.clip, marker: hit.marker, to: r.0 }]
                } else {
                    Vec::new()
                }
            }
            Gesture::Zoom { start, zoom_out, .. } => {
                self.finish_zoom_drag(start, p, zoom_out);
                Vec::new()
            }
            Gesture::InOut { part, down_time, moved, original, .. } => {
                if !moved {
                    return Self::ruler_click(self.geometry.time(p.x));
                }
                let r = InOutDrag::target(
                    part,
                    &original,
                    down_time,
                    self.geometry.time(p.x),
                    self.geometry.frame_duration,
                );
                if r != original {
                    return vec![TimelineAction::MoveInOut(r, part.marked_part())];
                }
                self.timeline.set_marked_range(Some(original));
                Vec::new()
            }
            Gesture::MarkerDuration { id, original, moved, .. } => {
                let now = self.timeline.markers.iter().find(|m| m.id == id).map_or(original, |m| m.duration);
                let _ = self.timeline.set_marker_duration(id, original); // back to the original, the session commits
                if moved && now != original { vec![TimelineAction::SetMarkerDuration(id, now)] } else { Vec::new() }
            }
            Gesture::Marker { id, moved, original, .. } => {
                self.scrub_snap_time = None;
                if !moved {
                    return Self::ruler_click(self.geometry.time(p.x));
                }
                let r = MarkerDrag::target(
                    self.geometry.unsnapped_time(p.x),
                    id,
                    &self.timeline,
                    Some(self.playhead),
                    self.snapping(),
                    &self.geometry,
                    self.beat_level,
                );
                if r.0 != original {
                    return vec![TimelineAction::MoveMarker(id, r.0)];
                }
                self.timeline.move_marker(id, original);
                Vec::new()
            }
            Gesture::Scrub => {
                self.scrub_snap_time = None;
                vec![TimelineAction::EndScrub]
            }
            Gesture::Clips => {
                self.interaction.geometry = self.geometry.clone();
                let commit = self.interaction.mouse_up(p, Self::gesture_modifiers(self.drag_modifiers()));
                let mut out = self.refresh_from_interaction();
                if let Some(m) = self.interaction.released_rejection() {
                    out.push(TimelineAction::Status(m.to_string()));
                }
                if let Some(c) = commit {
                    out.push(TimelineAction::Commit(Box::new(c)));
                }
                out
            }
        }
    }

    /// Esc during a drag: the gesture is dropped and the committed timeline shows again.
    pub fn cancel_gesture(&mut self) {
        if self.gesture.is_none() {
            return;
        }
        self.interaction.cancel();
        self.slip_two_up_shown = false;
        self.gesture = None;
        self.last_drag = None;
        self.scrub_snap_time = None;
        let committed = self.committed.clone();
        self.set_timeline(committed);
    }

    // MARK: Hover, wheel, keys

    fn mouse_moved(&mut self, p: Option<CGPoint>) -> Vec<TimelineAction> {
        self.hover_point = p;
        let (bar, handles) = (self.zoom_bar_rect(), self.zoom_bar_handles());
        self.zoom_bar.hover(p, bar, handles);
        self.hover_track = match p {
            Some(p) => self
                .rows()
                .iter()
                .find(|r| p.y >= r.y && p.y < r.max_y() && p.y >= TimelineGeometry::RULER_HEIGHT)
                .map(|r| r.track),
            None => None,
        };
        self.update_skimmer(p)
    }

    /// Timeline keys: the tool letters (`TimelineTool::from_key`), zoom (`=` `-` `\`), Esc and Delete. `None` = not a
    /// timeline key, the host handles it (transport, undo...).
    pub fn key(&mut self, k: InputKey, mods: InputModifiers, ui: &mut UiCx) -> Option<Vec<TimelineAction>> {
        let out = self.key_inner(k, mods, ui);
        self.publish_key_hover(ui);
        out
    }

    fn key_inner(&mut self, k: InputKey, mods: InputModifiers, ui: &mut UiCx) -> Option<Vec<TimelineAction>> {
        if self.tool_state().keep_attached && k != InputKey::Character('`') {
            self.keep_attached_used = true; // a key edit during the ` hold
        }
        if self.word_field.is_some() {
            return Some(self.word_field_key(k, mods, ui));
        }
        if let InputKey::Character(ch) = k
            && let Some(lane) = self.item_lane_key(ch, mods)
        {
            return Some(lane);
        }
        match k {
            // Return: the selected word becomes a field
            InputKey::Enter if mods == InputModifiers::NONE => self.edit_selected_word(),
            InputKey::Escape => {
                if self.gesture.is_none() {
                    // No drag: Esc goes back to the Selection tool first (the Mac key monitor), then clears a gap or edge
                    // selection (the Mac `keyDown`); else it is the host's.
                    if self.tool_state().tool != TimelineTool::Selection {
                        self.tool_hold.clear();
                        self.tool_state_mut().select(EditorTool::Selection);
                        return Some(Vec::new());
                    }
                    if !self.interaction.clear_gap_and_edge_selection() {
                        return None;
                    }
                    return Some(self.refresh_from_interaction());
                }
                let hide_two_up = self.slip_two_up_shown;
                let mut lane = self.cancel_item_lane_drag();
                lane.extend(self.cancel_band_drag());
                lane.extend(self.cancel_speed_drag());
                self.cancel_gesture();
                Some(if hide_two_up {
                    vec![TimelineAction::SlipTwoUp(None, Box::new(self.timeline.clone()))]
                } else {
                    lane
                })
            }
            InputKey::Plus if mods == InputModifiers::NONE => {
                self.zoom_in();
                Some(Vec::new())
            }
            InputKey::Minus if mods == InputModifiers::NONE => {
                self.zoom_out();
                Some(Vec::new())
            }
            InputKey::Delete | InputKey::Backspace => {
                if ui.key_repeat {
                    return Some(Vec::new()); // a held Delete deletes once (the Mac `isRepeatable` filter)
                }
                if mods == InputModifiers::NONE
                    && let Some(word) = self.delete_selected_word()
                {
                    return Some(word); // a selected word goes alone
                }
                if (mods.bits() & !InputModifiers::SHIFT.bits()) != 0
                    || !self.interaction.has_delete_target()
                    || self.gesture.is_some()
                {
                    return None;
                }
                // The Mac order (`AppController.execute(.delete)`): a selected transition goes first, then a gap (ripple close).
                if self.selected_transition.is_some() {
                    return None;
                }
                if self.selection.is_empty()
                    && self.caption_selection.is_empty()
                    && let Some(gap) = self.interaction.gap_selection()
                {
                    return Some(vec![TimelineAction::CloseGap(*gap)]);
                }
                // Delete / Backspace lift (clear), Shift ripples (the Mac key map's clear / ripple delete).
                let Some(c) = self.interaction.delete_selection(mods.contains(InputModifiers::SHIFT)) else {
                    return Some(Vec::new());
                };
                let mut out = self.refresh_from_interaction();
                out.push(TimelineAction::Commit(Box::new(c)));
                Some(out)
            }
            InputKey::Character('s') if mods == InputModifiers::NONE && self.gesture.is_some() => {
                Some(self.set_snap_inverted(true)) // Hold-S: snapping flips until the key comes up
            }
            InputKey::Character('`') if mods == InputModifiers::NONE && self.timeline.is_fast_cut() => {
                if !self.tool_state().keep_attached {
                    self.keep_attached_used = self.gesture.is_some();
                }
                Some(self.hold_keep_attached(true)) // Fast Cut: attached clips stay on their frame while held
            }
            InputKey::Character(ch) if mods == InputModifiers::NONE => {
                if ch == '\\' {
                    self.zoom_to_fit();
                    return Some(Vec::new());
                }
                if ch == '=' {
                    self.zoom_in();
                    return Some(Vec::new());
                }
                if self.gesture.is_some() {
                    return None;
                }
                let tool = TimelineTool::from_key(ch)?;
                let lower = ch.to_lowercase().next().unwrap_or(ch);
                if !ui.key_repeat
                    && let Some(now) = sq_timeline_ui::ToolStripTools::editor_tool(self.tool_state().tool)
                    && let Some(next) = sq_timeline_ui::ToolStripTools::editor_tool(tool)
                {
                    let clock = (self.clock)();
                    self.tool_hold.press(Key::Char(lower), next, now, clock);
                }
                self.tool_state_mut().tool = tool;
                Some(Vec::new())
            }
            _ => None,
        }
    }

    // MARK: Autoscroll (`autoscrollTick`)

    /// A drag sits near the left or right edge: the host must draw every frame so the autoscroll keeps its pace even
    /// when the pointer rests (the Mac runs a 60 Hz timer for it).
    pub fn is_autoscrolling(&self) -> bool {
        let Some(l) = self.last_drag else { return false };
        if self.gesture.is_none() || self.autoscroll_off() {
            return false;
        }
        TimelineAutoscroll::velocity(l.x, TimelineGeometry::CONTENT_ORIGIN_X, self.size.width) != 0.0
    }

    fn autoscroll_off(&self) -> bool {
        matches!(self.tool_state().timeline_tool(), TimelineTool::Hand | TimelineTool::Zoom)
    }

    /// Call once per frame: a drag near the left or right edge scrolls and replays the drag at the new scroll.
    pub fn tick(&mut self) -> Vec<TimelineAction> {
        self.step_spring_back();
        self.step_zoom_animation();
        let Some(l) = self.last_drag.filter(|_| self.gesture.is_some() && !self.autoscroll_off()) else {
            self.last_autoscroll = None;
            return Vec::new();
        };
        let now = (self.clock)();
        let dt = (now - self.last_autoscroll.unwrap_or(now)).min(0.1);
        self.last_autoscroll = Some(now);
        let v = TimelineAutoscroll::velocity(l.x, TimelineGeometry::CONTENT_ORIGIN_X, self.size.width);
        if v == 0.0 || dt <= 0.0 {
            return Vec::new();
        }
        let before = self.geometry.scroll_x;
        self.geometry.scroll_x += v * dt;
        self.clamp_scroll();
        if self.geometry.scroll_x == before {
            return Vec::new();
        }
        self.replay_drag()
    }

    fn replay_drag(&mut self) -> Vec<TimelineAction> {
        let (Some(p), Some(g)) = (self.last_drag, self.gesture.clone()) else { return Vec::new() };
        match g {
            Gesture::Marker { moved: true, .. } => {
                self.drag_marker(p);
                Vec::new()
            }
            Gesture::ClipMarker { hit, moved: true, .. } => {
                let r = self.clip_marker_target(&hit, p);
                self.timeline.move_clip_marker(hit.marker, hit.clip, r.0);
                self.scrub_snap_time = r.1.map(|s| s.time);
                Vec::new()
            }
            Gesture::ItemLane => self.item_lane_dragged(p),
            Gesture::InOut { moved: true, .. } => {
                self.drag_in_out(p);
                Vec::new()
            }
            Gesture::Scrub => {
                let t = self.scrub_time(p, self.drag_modifiers().contains(InputModifiers::SHIFT));
                self.playhead = t;
                vec![TimelineAction::Scrub(t)]
            }
            Gesture::Clips => {
                if self.interaction.is_idle() {
                    return Vec::new();
                }
                self.interaction.geometry = self.geometry.clone();
                self.interaction.mouse_dragged(p, Self::gesture_modifiers(self.drag_modifiers()));
                self.refresh_from_interaction()
            }
            _ => Vec::new(),
        }
    }

    // MARK: Helpers (translated as they are)

    /// Modifiers for drag and release handling: live when the host reports them, else those of the press.
    pub(crate) fn drag_modifiers(&self) -> InputModifiers {
        self.live_modifiers.as_ref().map_or(self.down_modifiers, |f| f())
    }

    pub(crate) fn snapping(&self) -> bool {
        self.tool_state().snapping != self.interaction.snap_inverted
    }

    pub(crate) fn feed_interaction(&mut self) {
        self.interaction.geometry = self.geometry.clone();
        self.interaction.playhead = Some(self.playhead);
        let mut markers = self.timeline.marker_snap_times(self.beat_level, 4);
        markers.extend(self.timeline.clip_marker_times());
        self.interaction.markers = markers;
    }

    /// Shows the gesture's preview and reports selection changes and hints (`refreshFromInteraction`).
    pub(crate) fn refresh_from_interaction(&mut self) -> Vec<TimelineAction> {
        let mut out = Vec::new();
        // Slip: the monitor shows the clip's new first and last frame while dragging (the Mac `onSlipTwoUp`).
        if let Some(two) = self.interaction.slip_two_up() {
            self.slip_two_up_shown = true;
            out.push(TimelineAction::SlipTwoUp(Some(two), Box::new(self.interaction.preview().clone())));
        } else if self.slip_two_up_shown {
            self.slip_two_up_shown = false;
            out.push(TimelineAction::SlipTwoUp(None, Box::new(self.interaction.preview().clone())));
        }
        let hint = self.interaction.move_hint().map(str::to_string);
        if hint != self.last_hint {
            self.last_hint = hint.clone();
            if let Some(h) = hint {
                out.push(TimelineAction::Status(h));
            }
        }
        if self.interaction.geometry.scroll_x != self.geometry.scroll_x
            || self.interaction.geometry.scroll_y != self.geometry.scroll_y
        {
            self.geometry.scroll_x = self.interaction.geometry.scroll_x;
            self.geometry.scroll_y = self.interaction.geometry.scroll_y;
            self.clamp_scroll();
        }
        if *self.interaction.preview() != self.timeline {
            let preview = self.interaction.preview().clone();
            self.set_timeline(preview);
        }
        if self.interaction.selection() != &self.selection
            || self.interaction.caption_selection() != &self.caption_selection
        {
            self.selection = self.interaction.selection().clone();
            self.caption_selection = self.interaction.caption_selection().clone();
            out.push(TimelineAction::Select {
                clips: self.selection.clone(),
                captions: self.caption_selection.clone(),
            });
        }
        out
    }

    pub(crate) fn apply_heights(&mut self, h: BTreeMap<sq_core_time::Id, f64>) {
        if self.geometry.fit_all_tracks {
            self.geometry.fit_all_tracks = false;
        }
        self.geometry.height_overrides = h;
        self.clamp_scroll();
    }

    /// `scrubTime`: Shift (or Hold-S) sticks the playhead to edits, markers and 0 and shows the snap line.
    fn scrub_time(&mut self, p: CGPoint, shift: bool) -> Time {
        if !(shift || self.interaction.snap_inverted) {
            self.scrub_snap_time = None;
            return self.geometry.time(p.x);
        }
        let r =
            PlayheadSnap::resolve(self.geometry.unsnapped_time(p.x), &self.timeline, &self.geometry, self.beat_level);
        self.scrub_snap_time = r.1.map(|s| s.time);
        r.0
    }

    fn ruler_click(t: Time) -> Vec<TimelineAction> {
        vec![TimelineAction::BeginScrub, TimelineAction::Seek(t), TimelineAction::EndScrub]
    }

    fn drag_in_out(&mut self, p: CGPoint) {
        let Some(Gesture::InOut { part, down_time, original, .. }) = &self.gesture else { return };
        let r = InOutDrag::target(*part, original, *down_time, self.geometry.time(p.x), self.geometry.frame_duration);
        self.timeline.set_marked_range(Some(r));
    }

    fn drag_marker(&mut self, p: CGPoint) {
        let Some(Gesture::Marker { id, .. }) = &self.gesture else { return };
        let id = *id;
        let r = MarkerDrag::target(
            self.geometry.unsnapped_time(p.x),
            id,
            &self.timeline,
            Some(self.playhead),
            self.snapping(),
            &self.geometry,
            self.beat_level,
        );
        self.timeline.move_marker(id, r.0);
        self.scrub_snap_time = r.1.map(|s| s.time);
    }

    /// `dragClipMarker`: where the flag under the pointer lands.
    fn clip_marker_target(&self, h: &ClipMarkerHit, p: CGPoint) -> (Time, Option<sq_core_edit::snapping::SnapPoint>) {
        ClipMarkerFlags::target(
            self.geometry.unsnapped_time(p.x),
            h,
            &self.timeline,
            Some(self.playhead),
            self.snapping(),
            &self.geometry,
        )
    }

    /// `markerID(at:)`: the nearest marker flag within 6 pt in the ruler's grab band.
    pub(crate) fn marker_id(&self, p: CGPoint) -> Option<sq_core_time::Id> {
        if !(p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && MarkerRange::grab_band(TimelineGeometry::RULER_HEIGHT).contains(&p.y))
        {
            return None;
        }
        self.timeline
            .markers
            .iter()
            .map(|m| (m.id, (self.geometry.x(m.time) - p.x).abs()))
            .filter(|m| m.1 <= 6.0)
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|m| m.0)
    }

    fn marker_end_handle_id(&self, p: CGPoint) -> Option<sq_core_time::Id> {
        if !(p.x >= TimelineGeometry::CONTENT_ORIGIN_X
            && MarkerRange::grab_band(TimelineGeometry::RULER_HEIGHT).contains(&p.y))
        {
            return None;
        }
        MarkerRange::end_handle(p.x, &self.timeline.markers, &self.geometry)
    }

    /// `finishZoomDrag`: a click zooms one step in (Option: out) around the pointer, a box zooms to fit it.
    fn finish_zoom_drag(&mut self, start: CGPoint, end: CGPoint, zoom_out: bool) {
        let (dx, dy) = ((end.x - start.x).abs(), (end.y - start.y).abs());
        if dx.max(dy) < TimelineInteraction::DRAG_THRESHOLD {
            let t = self.zoom_target();
            let anchor = start.x - TimelineGeometry::CONTENT_ORIGIN_X;
            let c = TimelineZoom::zoom_click(t.0, t.1, anchor, zoom_out, &self.zoom_limits());
            self.jump_zoom(c.0, c.1, ZoomAnimationMode::Anchored { x: anchor });
            return;
        }
        let seconds = |x: f64| {
            let t = self.geometry.unsnapped_time(x);
            t.value() as f64 / t.timescale() as f64
        };
        let r = TimelineZoom::zoom_marquee(
            seconds(start.x),
            seconds(end.x),
            self.content_viewport_width(),
            &self.zoom_limits(),
        );
        self.zoom_animation = None;
        self.geometry.points_per_second = r.0;
        self.geometry.scroll_x = r.1;
        self.clamp_scroll();
    }
}
