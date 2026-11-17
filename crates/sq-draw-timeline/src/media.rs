// Swift: TimelinePanel+Media.swift
//! Media drawing, translated from `ClipDrawing.draw` (thumbnail tiles), `WaveformTileCache.draw`,
//! `ClipDrawing.drawVolumeLine`, `drawOpacityLine`, `drawFXBadge` and `drawSyncBadge`, and what the host knows about
//! the media behind the clips.

use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use sq_core_audio::tone_generator::ToneClipExt;
use sq_core_model::{AudioTag, Clip, Track};
use sq_core_time::{Id, Time};
use sq_draw::{Canvas, Color};
use sq_media::waveform_data::WaveformData;
use sq_timeline_ui::{ClipAudioCurves, ToneWaveform, WaveformClipping};
use sq_timeline_ui::{
    ClipBodyMetrics, FXBadge, FXBadgeState, FadeHandle, OpacityLine, ThumbnailAnchor, ThumbnailLayout, ThumbnailMode,
    ThumbnailTile, VolumeLine, WaveformTint,
};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use sq_uikit::waveform_drawing::{WaveformCache, WaveformInput, WaveformPath, WaveformStyle};
use std::sync::Arc;

/// A picture the host has uploaded: image slot `slot`, the cell `source` of it (normalized `[u0, v0, u1, v1]`, an atlas
/// cell) and the picture's pixel size (for the crop that fills a thumbnail tile).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TimelinePicture {
    /// Image slot.
    pub slot: usize,
    /// The cell `[u0, v0, u1, v1]`.
    pub source: [f32; 4],
    /// Pixel width.
    pub pixel_width: f64,
    /// Pixel height.
    pub pixel_height: f64,
}

impl TimelinePicture {
    /// The part of `source` that fills `r` cropped to its aspect (centered), as the Mac draws a picture into a tile.
    pub fn cropped_to_fill(&self, r: &CGRect) -> [f32; 4] {
        sq_draw::fill_source(self.source, CGSize::new(self.pixel_width, self.pixel_height), *r)
    }
}

/// What the host knows about the media behind the clips. Every answer may be `None` while it loads; the host redraws
/// when it arrives.
pub trait TimelineMediaSource {
    /// Peaks of `media` (`None` while loading, or media without audio).
    fn waveform(&self, media: Id) -> Option<Arc<WaveformData>>;
    /// The zoom-bucket cache the waveform columns read through; `None` = straight from the data.
    fn waveform_cache(&self) -> Option<Arc<WaveformCache>> {
        None
    }
    /// A frame of `media` at media time `at` (`None` = the poster) for the thumbnail tiles.
    fn picture(&self, _media: Id, _at: Option<Time>) -> Option<TimelinePicture> {
        None
    }
    /// The media file is missing (the clip draws as "Media offline").
    fn is_offline(&self, _media: Id) -> bool {
        false
    }
    /// A stamp that changes whenever any answer above may change. The panel replays its clip layer while the stamp
    /// holds; `None` = cannot say, the layer is drawn fresh every frame.
    fn draw_revision(&self) -> Option<u64> {
        None
    }
}

/// The rects and flags of one clip being drawn.
#[derive(Clone, Copy)]
pub(crate) struct ClipFrame {
    /// The clip's lane rect.
    pub rect: CGRect,
    /// The body inside the lane (inset top and bottom).
    pub body: CGRect,
    /// The body clamped to the visible span.
    pub drawn: CGRect,
    /// Corner radius.
    pub radius: f64,
    /// The clip is selected.
    pub selected: bool,
    /// The visible part of the lane.
    pub visible: CGRect,
}

impl TimelinePanel {
    // MARK: Thumbnails

    /// The thumbnail tiles of a video clip and the room they take from the name: (head column, tail column).
    pub(crate) fn draw_thumbnails(&self, cv: &mut Canvas, c: &Clip, f: &ClipFrame) -> (f64, f64) {
        let ClipFrame { rect, body, drawn, visible, .. } = *f;
        let column = ClipBodyMetrics::thumbnail_column(body.width, rect.height, ClipBodyMetrics::THUMBNAIL_WIDTH);
        if column <= 0.0 {
            return (0.0, 0.0);
        }
        let local = (visible.min_x() - rect.min_x() - 8.0)..=(visible.max_x() - rect.min_x() + 8.0);
        let strip = ClipBodyMetrics::NAME_STRIP_HEIGHT.min(drawn.height);
        let fd = self.geometry.frame_duration;
        let (mut head, mut tail) = (0.0, 0.0);
        for tile in ThumbnailLayout::tiles(self.thumbnail_mode, body.width, column, &local) {
            // Head mode shows the poster, as the Mac's head column does; the other modes ask for the frame of the tile.
            let at = if self.thumbnail_mode == ThumbnailMode::Head {
                None
            } else {
                Some(ThumbnailLayout::media_time(tile.anchor, c, fd))
            };
            let picture = self.media.as_ref().and_then(|m| m.picture(c.media, at));
            self.draw_thumbnail_tile(cv, f, strip, &tile, picture);
            if !tile.below_name_strip {
                if tile.anchor == ThumbnailAnchor::Tail {
                    tail = tile.width;
                } else {
                    head = tile.width;
                }
            }
        }
        (head, tail)
    }

    /// `ClipDrawing.drawThumbnailTile`: a column tile spans the body height and is ruled on its inner side; a strip
    /// tile sits under the name strip and is ruled on its right.
    fn draw_thumbnail_tile(
        &self,
        cv: &mut Canvas,
        f: &ClipFrame,
        strip: f64,
        tile: &ThumbnailTile,
        picture: Option<TimelinePicture>,
    ) {
        let ClipFrame { body, drawn, radius, selected, .. } = *f;
        let skin = self.skin();
        let inset = if selected { 2.0 } else { 0.5 };
        let top = if tile.below_name_strip { strip } else { inset };
        let mut r = CGRect::new(body.min_x() + tile.offset, body.min_y() + top, tile.width, body.height - top - inset);
        if r.min_x() < body.min_x() + inset {
            r.width -= body.min_x() + inset - r.min_x();
            r.x = body.min_x() + inset;
        }
        if r.max_x() > body.max_x() - inset {
            r.width = body.max_x() - inset - r.min_x();
        }
        if !(r.width > 0.0 && r.height > 0.0 && r.max_x() > drawn.min_x() && r.min_x() < drawn.max_x()) {
            return;
        }
        cv.save_gstate();
        cv.clip_to(r);
        // The well with the body's rounded ends (the Mac clips to the rounded body; here the well itself is rounded).
        cv.fill_rounded(body.inset(inset, inset), (radius - inset).max(0.0), skin.thumb_well());
        if let Some(p) = picture {
            draw_image_in_rounded_body(cv, p.slot, r, p.cropped_to_fill(&r), body.inset(inset, inset), radius - inset);
        }
        cv.restore_gstate();
        let rule_x =
            if tile.anchor == ThumbnailAnchor::Tail && !tile.below_name_strip { r.min_x() } else { r.max_x() - 1.0 };
        cv.fill(CGRect::new(rule_x, r.min_y(), 1.0, r.height), skin.thumb_rule());
    }

    // MARK: Waveforms

    /// The waveform of an audio clip over its body and the clipping bands over it (`WaveformTileCache.draw` and
    /// `drawClipping`).
    /// shortcut: columns are computed on every draw (the Mac caches them per tile); add a tile cache when a long
    /// audio timeline draws slowly on the PC.
    pub(crate) fn draw_waveform(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect, ink: Color) {
        let tone_data = c.tone().map(|t| Arc::new(ToneWaveform::data(&t, c.source.end())));
        if rect.width < 1.0 {
            return;
        }
        let Some(data) = tone_data.clone().or_else(|| self.media.as_ref().and_then(|m| m.waveform(c.media))) else {
            return;
        };
        let wave = ClipBodyMetrics::waveform_rect(&rect);
        if wave.height < 4.0 {
            return;
        }
        let from = ((visible.min_x() - wave.min_x()).floor() as i64).max(0);
        let to = ((visible.max_x() - wave.min_x()).ceil() as i64).min(wave.width.round() as i64);
        if to <= from {
            return;
        }
        let style = WaveformStyle::default();
        let mut input = WaveformInput::new(data, c.source, wave.width, from..to);
        input.style = style;
        input.cache = if tone_data.is_none() {
            self.media.as_ref().and_then(|m| m.waveform_cache()).map(|cache| (cache, c.media))
        } else {
            None
        };
        input.reversed = c.reversed;
        input.volume_db = ClipAudioCurves::volume_db(c);
        input.source_map = ClipAudioCurves::source_map(c);
        let columns = WaveformPath::columns(&input);
        cv.save_gstate();
        cv.clip_to(CGRect::new(visible.min_x(), wave.min_y(), visible.width, wave.height));
        for r in WaveformPath::bars(&columns, wave, style, from) {
            cv.fill(r, ink);
        }
        let bands = WaveformClipping::band_rects(&columns, wave, style, from);
        for r in bands.near {
            cv.fill(r, self.theme.yellow());
        }
        for r in bands.over {
            cv.fill(r, self.skin().red());
        }
        cv.restore_gstate();
    }

    /// `WaveformTint.color`: the row's ink by audio role.
    pub(crate) fn waveform_ink(&self, track: &Track) -> Color {
        let skin = self.skin();
        match WaveformTint::role(track, track.clips()) {
            None => Color::WHITE.with_alpha(0.55),
            Some(AudioTag::Dialogue) => self.theme.accent().with_alpha(0.85),
            Some(AudioTag::Music) => skin.green().with_alpha(0.75),
            Some(AudioTag::Sfx) => self.theme.yellow().with_alpha(0.75),
        }
    }

    // MARK: Rubber bands

    /// `ClipDrawing.drawVolumeLine`: a thin line with a diamond on every key, and the two fade handles. `hidden` are the
    /// fade handles a running drag hides.
    pub(crate) fn draw_volume_line(
        &self,
        cv: &mut Canvas,
        c: &Clip,
        rect: CGRect,
        visible: CGRect,
        selected: bool,
        hidden: &[FadeHandle],
    ) {
        let pts = VolumeLine::points(c, &rect, &visible, 3.0);
        if pts.len() < 2 {
            return;
        }
        let skin = self.skin();
        cv.save_gstate();
        cv.clip_to(visible.intersection(&rect));
        let key_ids: Vec<Id> = c.animation.volume.track.keys.iter().map(|k| k.id).collect();
        self.draw_band(cv, &pts, &VolumeLine::key_points(c, &rect), &key_ids, visible, selected);
        if rect.width >= 4.0 * VolumeLine::HANDLE_SIZE {
            let (head, tail) = VolumeLine::fade_handle_points(c, &rect);
            let size = VolumeLine::HANDLE_SIZE;
            for (which, p) in [(FadeHandle::Head, head), (FadeHandle::Tail, tail)] {
                if hidden.contains(&which) {
                    continue;
                }
                let r = CGRect::new(p.x - size / 2.0, p.y - size / 2.0, size, size);
                let a = if selected { 0.95 } else { 0.95 * 0.7 };
                cv.fill_rounded(r, 1.5, skin.badge_fill().with_alpha(a));
                cv.stroke_rounded(r, 1.5, 1.0, skin.badge_edge());
            }
        }
        cv.restore_gstate();
    }

    /// `ClipDrawing.drawOpacityLine`: the same band over a video clip's body.
    pub(crate) fn draw_opacity_line(&self, cv: &mut Canvas, c: &Clip, rect: CGRect, visible: CGRect, selected: bool) {
        let pts = OpacityLine::points(c, &rect, &visible, 3.0);
        if pts.len() < 2 {
            return;
        }
        cv.save_gstate();
        cv.clip_to(visible.intersection(&rect));
        let key_ids: Vec<Id> = c.animation.opacity.track.keys.iter().map(|k| k.id).collect();
        self.draw_band(cv, &pts, &OpacityLine::key_points(c, &rect), &key_ids, visible, selected);
        cv.restore_gstate();
    }

    fn draw_band(
        &self,
        cv: &mut Canvas,
        pts: &[CGPoint],
        keys: &[CGPoint],
        key_ids: &[Id],
        visible: CGRect,
        selected: bool,
    ) {
        let skin = self.skin();
        let shadow: Vec<CGPoint> = pts.iter().map(|p| CGPoint { x: p.x, y: p.y + 1.0 }).collect();
        cv.stroke_polyline(&shadow, 1.0, skin.badge_edge());
        cv.stroke_polyline(pts, 1.0, skin.badge_fill().with_alpha(if selected { 0.95 } else { 0.95 * 0.75 }));
        for (i, k) in keys.iter().enumerate() {
            if !(k.x >= visible.min_x() - 4.0 && k.x <= visible.max_x() + 4.0) {
                continue;
            }
            let diamond = [
                CGPoint { x: k.x, y: k.y - 4.0 },
                CGPoint { x: k.x + 4.0, y: k.y },
                CGPoint { x: k.x, y: k.y + 4.0 },
                CGPoint { x: k.x - 4.0, y: k.y },
            ];
            let picked = key_ids.get(i).is_some_and(|id| self.selected_line_keys.contains(id));
            cv.fill_polygon(&diamond, if picked { self.theme.accent() } else { skin.badge_fill() });
            cv.stroke_polygon(&diamond, 1.0, skin.badge_edge());
        }
    }

    // MARK: Badges

    /// `ClipDrawing.drawFXBadge`: a small "fx" pill at the clip's top right once an effect is applied.
    pub(crate) fn draw_fx_badge(&self, cv: &mut Canvas, rect: CGRect, visible: CGRect) {
        if rect.width < 40.0 {
            return;
        }
        let size = type_size::CLIP_NAME as f64;
        let text_w = cv.size_of("fx", size, 0).width;
        let (w, h) = (text_w + 8.0, 16.0); // draft: 16 high, radius 4
        let pill = CGRect::new(rect.max_x().min(visible.max_x()) - 3.0 - w, rect.min_y() + 4.0, w, h);
        if pill.min_x() < rect.min_x() + ClipBodyMetrics::THUMBNAIL_WIDTH {
            return;
        }
        cv.fill_rounded(pill, 4.0, Color::BLACK.with_alpha(0.5));
        cv.draw_text(
            "fx",
            CGPoint { x: pill.min_x() + 4.0, y: pill.min_y() + 2.0 },
            size,
            Color::WHITE,
            f64::INFINITY,
            0,
        );
    }

    /// Width the clip name gives up for the fx pill (`ClipDrawing.fxBadgeReserve`).
    pub(crate) fn fx_badge_reserve(clip_width: f64, cv: &Canvas) -> f64 {
        if clip_width >= 40.0 { cv.size_of("fx", type_size::CLIP_NAME as f64, 0).width + 8.0 + 3.0 } else { 0.0 }
    }

    /// `ClipDrawing.drawSyncBadge`: frames the linked partner has drifted ("+3"), red on the clip's left edge.
    pub(crate) fn draw_sync_badge(&self, cv: &mut Canvas, frames: i64, rect: CGRect, visible: CGRect) {
        if frames == 0 || rect.width < 24.0 {
            return;
        }
        let text = format!("{}{}", if frames > 0 { "+" } else { "\u{2212}" }, frames.abs());
        let size = type_size::CLIP_NAME as f64;
        let w = cv.size_of(&text, size, 0).width + 8.0;
        let y = rect.min_y()
            + if rect.height >= ClipBodyMetrics::BODY_MIN_HEIGHT {
                ClipBodyMetrics::NAME_STRIP_HEIGHT + 3.0
            } else {
                2.0
            };
        let pill = CGRect::new(rect.min_x().max(visible.min_x()) + 3.0, y, w, 12.0);
        if pill.max_x() >= rect.max_x() {
            return;
        }
        cv.fill_rounded(pill, radius::SMALL as f64, self.skin().red());
        cv.draw_text(&text, CGPoint { x: pill.min_x() + 4.0, y: pill.min_y() }, size, Color::WHITE, f64::INFINITY, 0);
    }

    /// Whether `c` carries the applied-effects badge.
    pub(crate) fn has_applied_fx(c: &Clip) -> bool {
        FXBadge::state(c) == FXBadgeState::Applied
    }
}

/// Draws an image slot in `r` inside a body of `body` with corner `radius`: where `r` touches a left or right edge of the
/// body its rows near a rounded top or bottom corner are clipped in 1 pt steps, so the picture follows the clip's corners
/// (a rectangle clip would poke out of them).
fn draw_image_in_rounded_body(cv: &mut Canvas, slot: usize, r: CGRect, source: [f32; 4], body: CGRect, radius: f64) {
    let left = r.min_x() <= body.min_x() + 0.01;
    let right = r.max_x() >= body.max_x() - 0.01;
    if radius <= 0.5 || !(left || right) {
        cv.draw_image_slot(slot, r, source, Color::WHITE);
        return;
    }
    // How far the corner arc cuts into a row whose middle is `y`.
    let cut = |y: f64| -> f64 {
        let d = (y - body.min_y()).min(body.max_y() - y);
        if d >= radius { 0.0 } else { radius - (radius * radius - (radius - d).powi(2)).max(0.0).sqrt() }
    };
    let (top_end, bottom_start) = ((body.min_y() + radius).ceil(), (body.max_y() - radius).floor());
    let mut y = r.min_y();
    while y < r.max_y() - 0.001 {
        let next = if y < top_end {
            (y + 1.0).min(top_end)
        } else if y >= bottom_start {
            (y + 1.0).min(r.max_y())
        } else {
            bottom_start.min(r.max_y())
        };
        let c = if next - y > 1.0 { 0.0 } else { cut((y + next) / 2.0) };
        let x0 = r.min_x() + if left { c } else { 0.0 };
        let x1 = r.max_x() - if right { c } else { 0.0 };
        if x1 > x0 {
            cv.save_gstate();
            cv.clip_to(CGRect::new(x0, y, x1 - x0, next - y));
            cv.draw_image_slot(slot, r, source, Color::WHITE);
            cv.restore_gstate();
        }
        y = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pic() -> TimelinePicture {
        TimelinePicture { slot: 1, source: [0.0, 0.0, 1.0, 1.0], pixel_width: 160.0, pixel_height: 90.0 }
    }

    #[test]
    fn a_thumbnail_at_the_clip_edge_follows_the_rounded_corners() {
        use sq_draw::{RgbaImage, SoftwareRenderer, Sources};
        let mut c = Canvas::with_size(40.0, 24.0, None, 1.0);
        let body = CGRect::new(0.0, 0.0, 40.0, 24.0);
        // A tile as wide as the body (touches both edges), full height.
        draw_image_in_rounded_body(&mut c, 1, body, [0.0, 0.0, 1.0, 1.0], body, 4.0);
        let white = RgbaImage { width: 4, height: 4, pixels: vec![255; 64] };
        let images = [None, Some(white), None, None, None, None];
        let img = SoftwareRenderer::render(
            &c.list,
            40,
            24,
            Color::BLACK,
            &Sources { atlas: None, video: None, images: &images },
        );
        let px = |x: usize, y: usize| img.pixels[(y * 40 + x) * 4];
        assert_eq!(px(0, 0), 0, "the corner pixel stays outside the rounded body");
        assert_eq!(px(39, 23), 0, "so does the opposite corner");
        assert!(px(20, 0) > 200 && px(0, 12) > 200 && px(20, 12) > 200, "edges and middle show the picture");
    }

    #[test]
    fn clips_are_two_points_rounder_than_the_kit() {
        assert_eq!(crate::panel::TimelinePanel::CLIP_RADIUS, f64::from(sq_uikit::redesign_tokens::radius::CLIP) + 2.0);
    }

    #[test]
    fn crop_fills_a_square_tile_from_a_wide_picture() {
        let [u0, v0, u1, v1] = pic().cropped_to_fill(&CGRect::new(0.0, 0.0, 40.0, 40.0));
        assert!((v1 - v0 - 1.0).abs() < 1e-6, "full height");
        assert!((u1 - u0 - 0.5625).abs() < 1e-6, "9/16 of the width");
        assert!(((u0 + u1) / 2.0 - 0.5).abs() < 1e-6, "centered");
    }

    #[test]
    fn crop_of_an_empty_tile_is_the_whole_cell() {
        assert_eq!(pic().cropped_to_fill(&CGRect::new(0.0, 0.0, 0.0, 10.0)), [0.0, 0.0, 1.0, 1.0]);
    }
}
