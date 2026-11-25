// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextWordRects.swift
//! Per-word background rectangles (the per-word pill of a karaoke caption): one rounded box around each word instead of one
//! around the whole block. Pure function of the layout and the style, so monitor and burn-in draw the same pills.

use crate::caption_karaoke::TextHighlight;
use crate::text_backend::LineTypesetting;
use crate::text_layout::{TextLayout, TextLayoutResult, TextLine, TextRect};
use crate::text_style::TextStyle;

/// Namespace of the word pill functions.
pub enum TextWordRects {}

impl TextWordRects {
    /// The pill rectangles of `layout`, in layout space: one per word and line (a word the wrap broke across two lines gets a
    /// box on each). Words are in reading order. Empty without a background, without text or with fewer than two words.
    /// The horizontal padding is the style's, narrowed so that neighboring pills on a line keep a small gap and never merge.
    pub fn rects(layout: &TextLayoutResult, style: &TextStyle) -> Vec<TextRect> {
        let Some(bg) = style.background else { return Vec::new() };
        if layout.word_spans.len() <= 1 || layout.lines.is_empty() {
            return Vec::new();
        }
        let mut ink: Vec<TextRect> = Vec::new(); // the words' own extents
        let mut line_of: Vec<i64> = Vec::new();
        for l in layout.lines.iter().filter(|l| !l.text.is_empty()) {
            let typesetter = Self::line_offsets(l, style);
            let offset = |i: i64| typesetter.line(0, i).width;
            let line_start = l.location;
            let line_end = l.location + crate::text_layout::utf16_len(&l.content());
            for span in &layout.word_spans {
                let (s, e) = (span.location as i64, (span.location + span.length) as i64);
                let (lo, hi) = (s.max(line_start), e.min(line_end));
                if hi <= lo {
                    continue;
                }
                let a = offset(lo - l.location + l.marker_length);
                let b = offset(lo - l.location + l.marker_length + (hi - lo));
                if b <= a {
                    continue;
                }
                ink.push(TextRect::new(l.x + a, l.y, b - a, l.height));
                line_of.push(l.location);
            }
        }
        if ink.is_empty() {
            return Vec::new();
        }
        // Smallest gap between two neighbors on one line; the padding may use at most half of it, less a hairline.
        let mut min_gap = f64::MAX;
        for (k, r) in ink.iter().enumerate() {
            if k > 0 && line_of[k] == line_of[k - 1] {
                min_gap = min_gap.min(r.x - ink[k - 1].max_x());
            }
        }
        let hairline = 1.0f64.max(style.size * 0.03);
        let pad_x = if min_gap == f64::MAX {
            bg.padding.horizontal
        } else {
            bg.padding.horizontal.min(0.0f64.max(min_gap / 2.0 - hairline))
        };
        ink.iter().map(|r| r.expanded(pad_x, bg.padding.vertical, pad_x, bg.padding.vertical)).collect()
    }

    /// The box of a background that follows the reveal: the whole block's box (`layout.background_rect`) cut on the right to the
    /// share of the text shown so far. `amounts[w]` is how much word `w` is shown (0 hidden ... 1 shown); the width grows from
    /// a round end (the box height, so an empty pill shows first) to the full box in proportion to the shown word widths. It
    /// does not depend on the play order, so the Out animator shrinks it again whatever its order. `None` without a background.
    /// shortcut: one box over all lines; upgrade to one box per line when long titles wrap.
    pub fn reveal_pill(layout: &TextLayoutResult, style: &TextStyle, amounts: &[f64]) -> Option<TextRect> {
        let full = layout.background_rect?;
        style.background?;
        let words = Self::rects(layout, style);
        let words = if words.is_empty() { vec![full] } else { words };
        let total: f64 = words.iter().map(|w| w.width).sum();
        let shown: f64 = words
            .iter()
            .enumerate()
            .map(|(k, w)| w.width * amounts.get(k).copied().unwrap_or(1.0).clamp(0.0, 1.0))
            .sum();
        let share = if total > 0.0 { (shown / total).clamp(0.0, 1.0) } else { 1.0 };
        let round = full.height.min(full.width);
        Some(TextRect::new(full.x, full.y, round + (full.width - round) * share, full.height))
    }

    /// Per drawn line: the typesetter whose widths give the x offset (layout px from `TextLine.x`) of a UTF-16 index.
    fn line_offsets(l: &TextLine, style: &TextStyle) -> Box<dyn LineTypesetting> {
        TextLayout::typesetter(
            &l.text,
            &TextLayout::make_font(&style.line_style(l.style_index)),
            style.tracking,
            Some(l.is_right_to_left),
        )
    }

    /// True when `highlight` asks for pills per word and `style` has a background.
    pub fn wants_per_word(highlight: Option<&TextHighlight>, style: &TextStyle) -> bool {
        highlight.is_some_and(|h| h.per_word_pill) && style.background.is_some()
    }
}
