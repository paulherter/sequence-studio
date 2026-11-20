// Swift: TimelinePanel+Captions.swift
//! The caption tracks, translated from `TimelineView.drawCaptionLanes`, `drawCaptionHeaders` and `CaptionWordDrawing`:
//! the same rows (`caption_rows`), culling, slivers, word boxes (`CaptionWordLayout`) and flat preview blocks.

use crate::geom::RectExt as _;
use crate::header::TrackHeaderLayout;
use crate::panel::TimelinePanel;
use crate::skin::TimelineSkin;
use sq_core_audio::caption_handover::TimelineCaptionsExt as _;
use sq_core_audio::caption_item::CaptionWordExt as _;
use sq_core_model::CaptionItem;
use sq_core_time::Id;
use sq_draw::{Canvas, Color, TextAlign};
use sq_timeline_ui::{CaptionDrawing, CaptionRow, CaptionWordLayout, TimelineGeometry};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use sq_uikit::redesign_tokens::color;
use sq_uikit::sqicon::SQIcon;

impl TimelinePanel {
    /// `Theme.Colors.clipCaption` (the caption label color).
    fn caption_fill(&self) -> Color {
        self.theme.token(color::RAISED)
    }

    /// The word boxes: the same chip color (draft `.tl-cap`, `surface-raised`).
    fn caption_word_fill(&self) -> Color {
        self.theme.token(color::RAISED)
    }

    pub(crate) fn draw_caption_lanes(&self, cv: &mut Canvas, clip: CGRect) {
        let visible_x = CGRect::new(clip.min_x(), 0.0, clip.width, self.size.height);
        let skin = self.skin();
        for row in self.geometry.caption_rows(&self.timeline) {
            let lane_rect = CGRect::new(clip.min_x(), row.y, clip.width, row.height);
            let Some(track) = self.timeline.caption_track(row.track) else { continue };
            if !lane_rect.intersects(&clip) {
                continue;
            }
            cv.fill(lane_rect, self.theme.timeline()); // design v9: a plain lane
            cv.fill(CGRect::new(clip.min_x(), row.max_y() - 1.0, clip.width, 1.0), self.theme.track_row_line());
            let items = track.items();
            let mut i = CaptionWordLayout::first_index(self.geometry.time(clip.min_x() - 2.0), items).saturating_sub(1);
            let word_zoom = self.geometry.points_per_second >= CaptionWordLayout::WORD_LEVEL_POINTS_PER_SECOND;
            let mut last_sliver = f64::MIN;
            let shown = self.interaction.word_selection();
            while i < items.len() {
                let item = &items[i];
                i += 1;
                let x0 = self.geometry.x(item.range.start);
                let x1 = self.geometry.x(item.range.end());
                if x1 < clip.min_x() {
                    continue;
                }
                if x0 > clip.max_x() {
                    break;
                }
                let selected = self.caption_selection.contains(&item.id);
                let rect = CGRect::new(x0, row.y, x1 - x0, row.height);
                if x1 - x0 < CaptionWordLayout::SLIVER_WIDTH {
                    // Zoomed far out a caption is narrower than its own outline: one plain sliver per pixel column.
                    let column = x0.floor();
                    if column == last_sliver && !selected {
                        continue;
                    }
                    last_sliver = column;
                    cv.fill(
                        CGRect::new(x0, row.y + 1.0, (x1 - x0).max(1.0), row.height - 2.0),
                        if selected { self.theme.yellow() } else { self.caption_fill() },
                    );
                } else if word_zoom && CaptionWordLayout::shows_words(item, &self.geometry) {
                    self.draw_caption_words(
                        cv,
                        item,
                        rect,
                        &row,
                        clip,
                        selected,
                        shown.filter(|s| s.caption == item.id).map(|s| s.index),
                        self.word_field.as_ref().and_then(|f| f.hidden_word(item.id)),
                    );
                } else {
                    self.draw_caption_block(cv, &CaptionDrawing::preview(item), rect, visible_x, selected, &skin);
                }
            }
        }
    }

    /// `ClipDrawing.draw(name:style: .caption, flat: true)`: a flat clip-style block named with the caption's text.
    fn draw_caption_block(
        &self,
        cv: &mut Canvas,
        name: &str,
        rect: CGRect,
        visible: CGRect,
        selected: bool,
        skin: &TimelineSkin,
    ) {
        let body = rect.inset(0.0, 1.0);
        let x0 = body.min_x().max(visible.min_x() - 8.0);
        let x1 = body.max_x().min(visible.max_x() + 8.0);
        if x1 <= x0 {
            return;
        }
        let drawn = CGRect::new(x0, body.min_y(), x1 - x0, body.height);
        let rad = f64::from(radius::SMALL).min(body.height / 2.0);
        cv.fill_rounded(drawn, rad, self.caption_fill());
        cv.stroke_rounded(drawn.inset(0.25, 0.25), rad, 0.5, skin.clip_edge());
        if selected {
            // Draft `.tl-cap.sel`: the clip selection ring, its dark edge outside.
            cv.stroke_rounded(drawn.inset(1.0, 1.0), (rad - 1.0).max(0.0), 2.0, self.theme.yellow());
            cv.stroke_rounded(drawn.inset(0.5, 0.5), rad, 1.0, self.theme.token(color::CLIP_SELECTION_EDGE));
        }
        let text_left = body.min_x().max(visible.min_x()) + 6.0;
        let text_width = body.max_x().min(visible.max_x()) - text_left - 4.0;
        if text_width < 14.0 || name.is_empty() {
            return;
        }
        let size = f64::from(type_size::CLIP_NAME);
        let medium = cv.medium();
        let line_h = cv.size_of("Ag", size, medium).height;
        let mid = if body.height >= 18.0 { body.min_y() + 12.5 - 3.5 } else { body.min_y() + 10.0 - 3.5 };
        cv.save_gstate();
        cv.clip_to(CGRect::new(text_left, body.min_y(), text_width, body.height));
        let shown = cv.ellipsized(name, size, medium, text_width);
        cv.draw_text(
            &shown,
            CGPoint { x: text_left, y: (mid - line_h / 2.0).round() },
            size,
            self.theme.token(color::TEXT),
            f64::INFINITY,
            medium,
        );
        cv.restore_gstate();
    }

    /// `CaptionWordDrawing.draw`: the quiet plate, its edge or selection ring, one box per word, the shown word's ring,
    /// the word text (centered while it fits) and the unsure mark.
    #[allow(clippy::too_many_arguments)]
    fn draw_caption_words(
        &self,
        cv: &mut Canvas,
        item: &CaptionItem,
        rect: CGRect,
        row: &CaptionRow,
        visible: CGRect,
        selected: bool,
        selected_word: Option<usize>,
        hidden_word: Option<usize>,
    ) {
        let skin = self.skin();
        let body = rect.inset(0.0, 1.0);
        if body.width <= 0.0 {
            return;
        }
        let rad = f64::from(radius::SMALL).min(body.height / 2.0);
        let (ring_width, edge_width) = (2.0, 0.5);
        let min_x = body.min_x().max(visible.min_x() - 8.0); // Spacing.sm
        let max_x = body.max_x().min(visible.max_x() + 8.0);
        if max_x <= min_x {
            return;
        }
        cv.save_gstate();
        cv.clip_to(CGRect::new(min_x, body.min_y(), max_x - min_x, body.height));
        cv.fill_rounded(body, rad, self.caption_fill().with_alpha(0.32)); // `Theme.State.captionPlateAlpha`
        let inset = (if selected { ring_width } else { edge_width }) / 2.0;
        cv.stroke_rounded(
            body.inset(inset, inset),
            (rad - inset).max(0.0),
            if selected { ring_width } else { edge_width },
            if selected { self.theme.yellow() } else { skin.clip_edge() },
        );
        cv.restore_gstate();

        let (text_inset, min_text_box) = (4.0, 16.0); // Spacing.xs, Spacing.lg
        let size = f64::from(type_size::CLIP_NAME);
        let line_h = cv.size_of("Ag", size, 0).height;
        for (i, w) in item.effective_words().iter().enumerate() {
            let b = CaptionWordLayout::box_of(&w.range, &self.geometry, row);
            if b.max_x() < visible.min_x() - 2.0 {
                continue;
            }
            if b.min_x() > visible.max_x() + 2.0 {
                break;
            }
            if Some(i) == hidden_word {
                continue; // the open field stands on it
            }
            let br = (f64::from(radius::SMALL) - 1.0).min(b.width / 2.0);
            cv.fill_rounded(b, br, self.caption_word_fill());
            if Some(i) == selected_word && b.width >= text_inset {
                let lw = 1.5;
                cv.stroke_rounded(b.inset(lw / 2.0, lw / 2.0), (br - lw / 2.0).max(0.0), lw, self.theme.on_clip());
            }
            if b.width < min_text_box {
                continue;
            }
            let tw = cv.size_of(&w.text, size, 0).width;
            let x = Self::word_text_x(b.min_x(), b.max_x(), visible, tw, text_inset);
            let y = (b.mid_y() - line_h / 2.0).round();
            cv.save_gstate();
            cv.clip_to(b.inset(text_inset - 1.0, 0.0));
            cv.draw_text(&w.text, CGPoint { x, y }, size, self.theme.token(color::TEXT), f64::INFINITY, 0);
            cv.restore_gstate();
            if w.is_unsure() && b.max_x() - text_inset > b.min_x() + text_inset {
                // `drawUnsureMark`: 1 pt under the text
                cv.fill(
                    CGRect::new(b.min_x() + text_inset, y + line_h, b.width - 2.0 * text_inset, 1.0),
                    skin.warning(),
                );
            }
        }
    }

    /// Left edge of a word's text: centered in the part of the box that is on screen (a box wider than the lane, as at
    /// the deepest zoom, has its middle far outside it), at the inset when the text does not fit.
    pub(crate) fn word_text_x(min_x: f64, max_x: f64, visible: CGRect, text_width: f64, inset: f64) -> f64 {
        let (left, right) = (min_x.max(visible.min_x()), max_x.min(visible.max_x()));
        if text_width <= right - left - 2.0 * inset { (left + right) / 2.0 - text_width / 2.0 } else { left + inset }
    }

    // MARK: Headers

    /// `captionEyeRect`: the same place and size as a video track's eye.
    pub(crate) fn caption_eye_rect(row: &CaptionRow) -> CGRect {
        let s = TrackHeaderLayout::button_size(row.height);
        let right =
            TimelineGeometry::TOOL_COLUMN_WIDTH + TimelineGeometry::HEADER_WIDTH - TrackHeaderLayout::RIGHT_PADDING;
        CGRect::new(right - s, row.y + ((row.height - s) / 2.0).round(), s, s)
    }

    /// The caption track whose eye is under `p` (3 pt slack, like the Mac).
    pub(crate) fn caption_eye_hit(&self, p: CGPoint) -> Option<Id> {
        if p.y < TimelineGeometry::RULER_HEIGHT {
            return None;
        }
        let row = self
            .geometry
            .caption_rows(&self.timeline)
            .into_iter()
            .find(|r| Self::caption_eye_rect(r).inset(-3.0, -3.0).has(p))?;
        self.timeline.caption_track(row.track)?;
        Some(row.track)
    }

    /// `drawCaptionHeaders` with `drawHeaderRow`: panel fill, row line, separator, chip, name, eye.
    pub(crate) fn draw_caption_headers(&self, cv: &mut Canvas) {
        let x = TimelineGeometry::TOOL_COLUMN_WIDTH;
        let width = TimelineGeometry::HEADER_WIDTH;
        let skin = self.skin();
        for row in self.geometry.caption_rows(&self.timeline) {
            if !(row.max_y() > TimelineGeometry::RULER_HEIGHT && row.y < self.size.height) {
                continue;
            }
            let track = self.timeline.caption_track(row.track);
            let r = CGRect::new(x, row.y, width, row.height);
            cv.fill(r, self.theme.panel());
            cv.fill(CGRect::new(r.min_x(), r.max_y() - 1.0, r.width, 1.0), self.theme.track_row_line());
            cv.fill(CGRect::new(r.max_x() - 1.0, r.min_y(), 1.0, r.height), self.theme.separator());
            let mut chip = TrackHeaderLayout::chip_rect(row.height);
            chip = CGRect::new(chip.x + x + self.patch_column_offset(), chip.y + row.y, chip.width, chip.height);
            if !row.label.is_empty() {
                cv.fill_rounded(chip, f64::from(radius::SMALL), self.theme.fill());
                cv.draw_text_in(&row.label, chip, 10.0, self.theme.label2(), TextAlign::Center, 0.0, 0);
            }
            let eye = Self::caption_eye_rect(&row);
            let name = track.map_or("Captions", |t| t.name.as_str());
            let name_x = chip.max_x() + TrackHeaderLayout::BUTTON_GAP;
            let w = eye.min_x() - TrackHeaderLayout::BUTTON_GAP - name_x;
            if !name.is_empty() && w > 12.0 {
                cv.draw_text(
                    name,
                    CGPoint { x: name_x, y: (row.y + (row.height - 14.0) / 2.0).round() },
                    f64::from(type_size::BODY),
                    self.theme.label2(),
                    w,
                    0,
                );
            }
            let visible = track.is_none_or(|t| t.is_visible);
            cv.draw_icon(
                if visible { SQIcon::Eye } else { SQIcon::EyeOff },
                CGPoint { x: eye.mid_x() - 6.0, y: eye.mid_y() - 6.0 },
                12.0,
                if visible { self.theme.label3() } else { skin.warning() },
                None,
            );
        }
    }
}
