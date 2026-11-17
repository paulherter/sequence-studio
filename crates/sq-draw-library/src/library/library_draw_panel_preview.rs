// Swift: LibraryDrawPanel+Preview.swift
//! The preview bar and the dividers of the Library panel (the AppKit `LibraryPreviewBar` and its resize strip): viewer
//! (video picture or a larger photo), scrub bar with times, skip back, play/pause, skip forward, mute and volume, a drag
//! handle on the bar's top edge (viewer height, stored under the AppKit key) and one on the sidebar's edge (sidebar width).
//! Playback is `LibraryPreviewPlayer` on the model, never the timeline engine.

use crate::geom::dist;
use crate::library::library_draw_panel::{
    BarDrag, DragPhase, LibraryDrawPanel, LibraryPanelEvent, PictureFn, get_double, set_double,
};
use crate::library::library_panel_logic::{LibraryDragPayload, LibraryLabels};
use crate::library::library_panel_model::LibraryItem;
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Canvas, Color, DrawTheme, InputModifiers, TextAlign};
use sq_library::library_preview_math::{self, PreviewMode};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;

impl LibraryDrawPanel {
    /// Top strip of the bar that grabs the divider drag, and the grab zone either side of the sidebar edge.
    const HANDLE_ZONE: f64 = spacing::SM as f64;
    const SIDEBAR_GRAB: f64 = 3.0;
    /// The button row; the scrub row above it is shorter, so the bar reads as part of the controls under the picture.
    const CONTROL_ROW: f64 = 26.0;
    const SCRUB_ROW: f64 = 16.0;
    const VIDEO_VIEWER_HEIGHT: f64 = 150.0;
    const IMAGE_VIEWER_HEIGHT: f64 = 190.0;
    const SKIP_SECONDS: f64 = 5.0;
    const TIME_WIDTH: f64 = 38.0;
    const VOLUME_WIDTH: f64 = 72.0;
    const BUTTON_SIZE: f64 = 24.0;

    // MARK: Geometry

    /// The sidebar width in points: stored (or default), within the limits for this panel width.
    pub fn sidebar_w(&self) -> f64 {
        let w = library_preview_math::sidebar_width(self.stored_sidebar_width, self.size.width);
        let room = self.size.width - Self::CONTENT_MIN_WIDTH;
        if room >= library_preview_math::MIN_SIDEBAR_WIDTH { w.min(room) } else { w }
    }

    /// Narrowest content area right of the sidebar: pad, the Media | Presets switch (128), a gap and Import (72), pad.
    /// A panel with less room hides the sidebar instead of cutting the switch or the search field.
    pub(crate) const CONTENT_MIN_WIDTH: f64 = 2.0 * Self::PAD + 128.0 + Self::PAD + 72.0;

    /// What the bar shows; none = no bar (nothing previewed, the Presets section, a search without hits).
    pub fn preview_mode(&self) -> Option<PreviewMode> {
        if self.model.is_showing_presets() || self.is_no_hits() || self.model.preview_item().is_none() {
            return None;
        }
        self.model.preview.mode()
    }

    fn has_transport(&self) -> bool {
        matches!(self.preview_mode(), Some(PreviewMode::Audio | PreviewMode::Video))
    }
    /// The buttons and the scrub bar work for a file that loaded. The sound notes a read problem while it retries and
    /// plays on; locking the bar then left only Space and the volume alive. A file that never got a length stays locked.
    fn can_play(&self) -> bool {
        self.has_transport() && (self.model.preview.error_message().is_none() || self.model.preview.duration() > 0.0)
    }

    fn stored_viewer_height(&self) -> Option<f64> {
        get_double(self.defaults(), Self::VIEWER_HEIGHT_KEY)
    }

    fn clamped_viewer_height(&self, h: Option<f64>) -> f64 {
        let fallback = if self.preview_mode() == Some(PreviewMode::Video) {
            Self::VIDEO_VIEWER_HEIGHT
        } else {
            Self::IMAGE_VIEWER_HEIGHT
        };
        library_preview_math::viewer_height(h.or_else(|| self.stored_viewer_height()), fallback, self.size.height)
    }

    /// The viewer's height (video and image previews).
    pub fn viewer_height(&self) -> f64 {
        if matches!(self.preview_mode(), Some(PreviewMode::Video | PreviewMode::Image)) {
            self.clamped_viewer_height(None)
        } else {
            0.0
        }
    }
    fn message_height(&self) -> f64 {
        if self.model.preview.error_message().is_some() || self.preview_mode() == Some(PreviewMode::Image) {
            18.0
        } else {
            0.0
        }
    }
    fn transport_height(&self) -> f64 {
        if self.has_transport() { Self::SCRUB_ROW + Self::CONTROL_ROW + spacing::XS as f64 } else { 0.0 }
    }

    /// The bar's height (the AppKit `heightConstraint`); 0 = hidden.
    pub fn preview_bar_height(&self) -> f64 {
        if self.preview_mode().is_none() {
            return 0.0;
        }
        let v = self.viewer_height();
        let (xs, sm) = (spacing::XS as f64, spacing::SM as f64);
        let top = if v > 0.0 { sm + v } else { xs };
        top + self.message_height() + self.transport_height() + if v == 0.0 && !self.has_transport() { 0.0 } else { xs }
    }

    /// The bar's rect.
    pub fn preview_bar_rect(&self) -> CGRect {
        let h = self.preview_bar_height();
        CGRect::new(self.content_x(), (self.size.height - h).max(0.0), (self.size.width - self.content_x()).max(0.0), h)
    }

    /// The viewer's rect.
    pub fn viewer_rect(&self) -> Option<CGRect> {
        let v = self.viewer_height();
        if v <= 0.0 {
            return None;
        }
        let b = self.preview_bar_rect();
        let sm = spacing::SM as f64;
        Some(CGRect::new(b.min_x() + sm, b.min_y() + sm, (b.width - 2.0 * sm).max(0.0), v))
    }

    fn message_rect(&self) -> CGRect {
        let b = self.preview_bar_rect();
        let sm = spacing::SM as f64;
        CGRect::new(
            b.min_x() + sm,
            self.viewer_rect().map_or(b.min_y() + spacing::XS as f64, |v| v.max_y()),
            (b.width - 2.0 * sm).max(0.0),
            18.0,
        )
    }

    fn scrub_row_rect(&self) -> CGRect {
        let b = self.preview_bar_rect();
        let sm = spacing::SM as f64;
        CGRect::new(
            b.min_x() + sm,
            b.max_y() - spacing::XS as f64 - Self::CONTROL_ROW - Self::SCRUB_ROW,
            (b.width - 2.0 * sm).max(0.0),
            Self::SCRUB_ROW,
        )
    }

    fn control_row_rect(&self) -> CGRect {
        let r = self.scrub_row_rect();
        CGRect::new(r.x, r.y + Self::SCRUB_ROW, r.width, Self::CONTROL_ROW)
    }

    fn elapsed_rect(&self) -> CGRect {
        let r = self.scrub_row_rect();
        CGRect::new(r.min_x(), r.min_y(), Self::TIME_WIDTH, Self::SCRUB_ROW)
    }
    fn total_rect(&self) -> CGRect {
        let r = self.scrub_row_rect();
        CGRect::new(r.max_x() - Self::TIME_WIDTH, r.min_y(), Self::TIME_WIDTH, Self::SCRUB_ROW)
    }
    /// The scrub bar between the two times.
    pub fn scrub_track_rect(&self) -> CGRect {
        let sm = spacing::SM as f64;
        let r = self.scrub_row_rect();
        let (e, t) = (self.elapsed_rect(), self.total_rect());
        CGRect::new(e.max_x() + sm, r.min_y(), (t.min_x() - e.max_x() - 2.0 * sm).max(0.0), r.height)
    }

    fn button(&self, i: usize) -> CGRect {
        let r = self.control_row_rect();
        CGRect::new(
            r.min_x() + i as f64 * (Self::BUTTON_SIZE + spacing::XS as f64),
            r.mid_y() - Self::BUTTON_SIZE / 2.0,
            Self::BUTTON_SIZE,
            Self::BUTTON_SIZE,
        )
    }
    /// The skip-back button.
    pub fn back_button_rect(&self) -> CGRect {
        self.button(0)
    }
    /// The play / pause button.
    pub fn play_button_rect(&self) -> CGRect {
        self.button(1)
    }
    /// The skip-forward button.
    pub fn forward_button_rect(&self) -> CGRect {
        self.button(2)
    }
    fn volume_rect(&self) -> CGRect {
        let r = self.control_row_rect();
        CGRect::new(r.max_x() - Self::VOLUME_WIDTH, r.min_y(), Self::VOLUME_WIDTH, r.height)
    }
    fn mute_button_rect(&self) -> CGRect {
        let r = self.control_row_rect();
        CGRect::new(
            self.volume_rect().min_x() - spacing::XS as f64 - Self::BUTTON_SIZE,
            r.mid_y() - Self::BUTTON_SIZE / 2.0,
            Self::BUTTON_SIZE,
            Self::BUTTON_SIZE,
        )
    }

    fn sidebar_divider_rect(&self) -> CGRect {
        if !self.shows_sidebar() {
            return CGRect::default();
        }
        CGRect::new(
            self.sidebar_w() - Self::SIDEBAR_GRAB,
            Self::SEARCH_ROW_HEIGHT,
            2.0 * Self::SIDEBAR_GRAB,
            (self.size.height - Self::SEARCH_ROW_HEIGHT).max(0.0),
        )
    }

    // MARK: Play / pause

    /// Space while the Library has focus: pauses or plays the previewed item. False when nothing playable is previewed
    /// (the app then plays the sequence).
    pub fn handle_play_pause(&mut self) -> bool {
        if self.model.is_showing_presets() {
            return false;
        }
        let Some(item) = self.model.preview_item() else { return false };
        match library_preview_math::mode(item.entry.kind) {
            Some(mode) if mode != PreviewMode::Image => {}
            _ => return false,
        }
        self.model.preview.toggle_play_pause();
        true
    }

    /// The panel left the screen (another dock tab, a closed window) or the sequence started: the preview pauses.
    pub fn pause_preview(&mut self) {
        if self.model.preview.is_playing() {
            self.model.preview.pause();
        }
    }

    fn set_muted(&mut self, on: bool) {
        if self.model.preview.mode() == Some(PreviewMode::Video) {
            self.model.preview.video_muted = on;
        } else {
            self.model.preview.audio_muted = on;
        }
    }

    // MARK: Cursor, help

    pub(crate) fn cursor_at(&self, p: CGPoint) -> Option<DrawCursor> {
        match self.bar_drag {
            Some(BarDrag::Sidebar { .. }) => return Some(DrawCursor::ResizeLeftRight),
            Some(BarDrag::Viewer { .. }) => return Some(DrawCursor::ResizeUpDown),
            _ => {}
        }
        if self.shows_sidebar() && self.sidebar_divider_rect().contains(p) {
            return Some(DrawCursor::ResizeLeftRight);
        }
        let b = self.preview_bar_rect();
        if b.height > 0.0
            && self.viewer_rect().is_some()
            && CGRect::new(b.min_x(), b.min_y(), b.width, Self::HANDLE_ZONE).contains(p)
        {
            return Some(DrawCursor::ResizeUpDown);
        }
        None
    }

    pub(crate) fn preview_help(&self, p: CGPoint) -> Option<String> {
        if self.preview_bar_height() <= 0.0 || !self.preview_bar_rect().contains(p) || !self.has_transport() {
            return None;
        }
        let pv = &self.model.preview;
        let s = if self.back_button_rect().contains(p) {
            "Back 5 s"
        } else if self.play_button_rect().contains(p) {
            if pv.is_playing() { "Pause" } else { "Play" }
        } else if self.forward_button_rect().contains(p) {
            "Forward 5 s"
        } else if self.mute_button_rect().contains(p) {
            if pv.is_muted() { "Unmute" } else { "Mute" }
        } else if self.volume_rect().contains(p) {
            "Volume"
        } else if self.scrub_track_rect().contains(p) {
            "Position"
        } else {
            return None;
        };
        Some(s.to_string())
    }

    // MARK: Events

    /// A press on a divider or the bar; true when it took the press.
    pub(crate) fn mouse_down_preview(&mut self, p: CGPoint, m: InputModifiers) -> bool {
        if self.shows_sidebar() && self.sidebar_divider_rect().contains(p) && !m.contains(InputModifiers::SECONDARY) {
            self.end_search_editing();
            self.bar_drag = Some(BarDrag::Sidebar { start_width: self.sidebar_w(), start_x: p.x });
            return true;
        }
        let b = self.preview_bar_rect();
        if b.height <= 0.0 || !b.contains(p) {
            return false;
        }
        self.end_search_editing();
        if m.contains(InputModifiers::SECONDARY) {
            return true;
        }
        if p.y <= b.min_y() + Self::HANDLE_ZONE
            && let Some(v) = self.viewer_rect()
        {
            self.bar_drag = Some(BarDrag::Viewer { start_height: v.height, start_y: p.y });
            return true;
        }
        if !self.has_transport() {
            if self.viewer_rect().is_some_and(|v| v.contains(p)) {
                self.bar_drag = Some(BarDrag::FileOut { start: p });
            }
            return true;
        }
        if self.can_play() {
            if self.back_button_rect().contains(p) {
                self.model.preview.skip(-Self::SKIP_SECONDS);
                return true;
            }
            if self.play_button_rect().contains(p) {
                self.model.preview.toggle_play_pause();
                return true;
            }
            if self.forward_button_rect().contains(p) {
                self.model.preview.skip(Self::SKIP_SECONDS);
                return true;
            }
            if self.scrub_track_rect().inset_by(-4.0, -4.0).contains(p) && self.model.preview.duration() > 0.0 {
                self.bar_drag = Some(BarDrag::Scrub);
                self.set_scrub(p.x);
                return true;
            }
        }
        if self.mute_button_rect().contains(p) {
            let muted = self.model.preview.is_muted();
            self.set_muted(!muted);
            return true;
        }
        if self.volume_rect().inset_by(-4.0, 0.0).contains(p) {
            self.bar_drag = Some(BarDrag::Volume);
            self.set_volume(p.x);
            return true;
        }
        if self.viewer_rect().is_some_and(|v| v.contains(p)) {
            self.bar_drag = Some(BarDrag::FileOut { start: p });
        }
        true
    }

    fn set_scrub(&mut self, x: f64) {
        let r = self.scrub_track_rect();
        self.model.preview.scrub((x - r.min_x()) / r.width.max(1.0));
    }

    fn set_volume(&mut self, x: f64) {
        let r = self.volume_rect();
        let f = ((x - r.min_x() - 5.0) / (r.width - 10.0).max(1.0)).clamp(0.0, 1.0);
        self.model.preview.volume = f as f32;
        if self.model.preview.is_muted() && f > 0.0 {
            self.set_muted(false);
        }
    }

    pub(crate) fn drag_preview(&mut self, p: CGPoint) {
        match self.bar_drag {
            Some(BarDrag::Viewer { start_height, start_y }) => {
                // Up (smaller y) = taller viewer.
                let h = library_preview_math::resized_height(start_height, p.y - start_y);
                let clamped = self.clamped_viewer_height(Some(h));
                set_double(self.defaults_mut(), Self::VIEWER_HEIGHT_KEY, clamped);
            }
            Some(BarDrag::Sidebar { start_width, start_x }) => {
                self.stored_sidebar_width =
                    Some(library_preview_math::sidebar_width(Some(start_width + (p.x - start_x)), self.size.width));
            }
            Some(BarDrag::Scrub) => self.set_scrub(p.x),
            Some(BarDrag::Volume) => self.set_volume(p.x),
            Some(BarDrag::FileOut { start }) => {
                if self.is_dragging || dist(p, start) < Self::DRAG_SLOP {
                    if self.is_dragging
                        && let Some(d) = self.drag_payload.clone()
                    {
                        self.push_drag(d, DragPhase::Moved, p);
                    }
                    return;
                }
                let Some(url) = self.model.preview_item().map(|i| i.url.clone()) else {
                    self.bar_drag = None;
                    return;
                };
                self.drag_payload = Some(LibraryDragPayload::Files(vec![url.clone()]));
                self.is_dragging = true;
                self.push_drag(LibraryDragPayload::Files(vec![url]), DragPhase::Moved, p);
            }
            None => {}
        }
    }

    pub(crate) fn end_preview_drag(&mut self, p: CGPoint) {
        match self.bar_drag {
            Some(BarDrag::Sidebar { .. }) => {
                if let Some(w) = self.stored_sidebar_width {
                    set_double(self.defaults_mut(), Self::SIDEBAR_WIDTH_KEY, w);
                }
                let (max, s) = (self.max_scroll(), self.scroll());
                self.set_scroll(s.min(max));
            }
            Some(BarDrag::Viewer { .. }) => {
                let (max, s) = (self.max_scroll(), self.scroll());
                self.set_scroll(s.min(max));
            }
            Some(BarDrag::FileOut { .. }) => {
                if !self.is_dragging {
                    return;
                }
                let Some(d) = self.drag_payload.clone() else { return };
                let inside = CGRect::new(0.0, 0.0, self.size.width, self.size.height).contains(p);
                self.push_drag(d, if inside { DragPhase::Canceled } else { DragPhase::Ended }, p);
            }
            _ => {}
        }
    }

    fn push_drag(&mut self, d: LibraryDragPayload, phase: DragPhase, p: CGPoint) {
        self.push_event(LibraryPanelEvent::Drag(d, phase, p));
    }

    // MARK: Drawing

    pub(crate) fn draw_preview_bar(&mut self, c: &mut Canvas, t: &DrawTheme, picture: PictureFn) {
        let b = self.preview_bar_rect();
        let (Some(mode), Some(item)) = (self.preview_mode(), self.model.preview_item().cloned()) else { return };
        if b.height <= 0.0 {
            return;
        }
        c.fill(b, t.panel());
        c.fill(CGRect::new(b.min_x(), b.min_y(), b.width, 1.0), t.separator());
        if let Some(v) = self.viewer_rect() {
            self.draw_viewer(c, t, v, mode, &item, picture);
        }
        let err = self.model.preview.error_message().map(str::to_string);
        if err.is_some() || mode == PreviewMode::Image {
            c.draw_text_in(
                err.as_deref().unwrap_or(item.entry.name()),
                self.message_rect(),
                type_size::BODY as f64,
                if err.is_some() { t.label2() } else { t.label3() },
                TextAlign::Left,
                0.0,
                0,
            );
        }
        if !self.has_transport() {
            return;
        }
        let player = &self.model.preview;
        let enabled = self.can_play();
        let ink = if enabled { t.label2() } else { t.label3() };
        let mono = type_size::BODY as f64;
        c.draw_text_in(
            &library_preview_math::time_text(player.seconds()),
            self.elapsed_rect(),
            mono,
            t.label3(),
            TextAlign::Right,
            0.0,
            0,
        );
        c.draw_text_in(
            &library_preview_math::time_text(player.duration()),
            self.total_rect(),
            mono,
            t.label3(),
            TextAlign::Left,
            2.0,
            0,
        );
        let tr = self.scrub_track_rect();
        let track = CGRect::new(tr.min_x(), tr.mid_y() - 2.0, tr.width, 4.0);
        c.stone_track(track, t);
        if player.duration() > 0.0 {
            let kx = track.min_x() + player.fraction() * track.width;
            c.fill_rounded(
                CGRect::new(track.min_x(), track.min_y() + 1.0, (kx - track.min_x()).max(0.0), 2.0),
                1.0,
                t.accent(),
            );
            c.fill_rounded(CGRect::new(kx - 5.0, tr.mid_y() - 5.0, 10.0, 10.0), 5.0, Color::WHITE);
        }
        let play_icon = if player.is_playing() { SQIcon::Pause } else { SQIcon::Play };
        for (rect, icon) in [
            (self.back_button_rect(), SQIcon::Reset),
            (self.play_button_rect(), play_icon),
            (self.forward_button_rect(), SQIcon::RotateCW),
        ] {
            if enabled && self.hover.is_some_and(|h| rect.contains(h)) {
                c.fill_rounded(rect, radius::SMALL as f64, t.fill());
            }
            c.draw_icon(icon, CGPoint::new(rect.mid_x() - 6.0, rect.mid_y() - 6.0), 12.0, ink, None);
        }
        let muted = player.is_muted();
        let mr = self.mute_button_rect();
        if self.hover.is_some_and(|h| mr.contains(h)) {
            c.fill_rounded(mr, radius::SMALL as f64, t.fill());
        }
        let vol_icon = if muted || player.volume == 0.0 { SQIcon::VolumeOff } else { SQIcon::Volume };
        c.draw_icon(
            vol_icon,
            CGPoint::new(mr.mid_x() - 6.0, mr.mid_y() - 6.0),
            12.0,
            if muted { t.label3() } else { t.label2() },
            None,
        );
        let vr = self.volume_rect();
        let vt = CGRect::new(vr.min_x(), vr.mid_y() - 1.0, vr.width, 2.0);
        c.fill_rounded(vt, 1.0, t.fill());
        let vk = vt.min_x() + 5.0 + f64::from(player.volume.clamp(0.0, 1.0)) * (vt.width - 10.0);
        c.fill_rounded(
            CGRect::new(vt.min_x(), vt.min_y(), (vk - vt.min_x()).max(0.0), 2.0),
            1.0,
            if muted { t.label3() } else { t.accent() },
        );
        c.fill_rounded(
            CGRect::new(vk - 5.0, vr.mid_y() - 5.0, 10.0, 10.0),
            5.0,
            if muted { t.label2() } else { Color::WHITE },
        );
    }

    fn draw_viewer(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        v: CGRect,
        mode: PreviewMode,
        item: &LibraryItem,
        picture: PictureFn,
    ) {
        let corner = radius::CONTROL as f64;
        c.fill_rounded(v, corner, t.viewer());
        let live = self.preview_frame.filter(|p| p.size.width > 0.0 && p.size.height > 0.0);
        // Whole picture at its own aspect, bars (the viewer color) around it, at every viewer height.
        if let (PreviewMode::Video, Some(frame)) = (mode, live) {
            c.draw_image_fit(frame.slot, v, frame.source, frame.size, Color::WHITE, None);
        } else if let Some(poster) = picture(item, v) {
            c.draw_image_fit(poster.slot, v, poster.source, poster.size, Color::WHITE, None);
        } else {
            c.draw_icon(
                LibraryLabels::symbol(item.entry.kind),
                CGPoint::new(v.mid_x() - 11.0, v.mid_y() - 11.0),
                22.0,
                t.label3(),
                None,
            );
        }
        // The picture is square-cornered: give the rounded frame its corners back.
        c.round_picture_corners(v, corner, t.panel());
    }
}
