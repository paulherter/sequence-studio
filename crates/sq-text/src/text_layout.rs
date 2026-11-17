// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextLayout.swift

use crate::font_resolver::FontResolver;
use crate::text_backend::LineTypesetting;
use crate::text_backend_portable::PlatformFont;
use crate::text_style::{TextAlignment, TextDirection, TextStyle, TextVerticalAlignment};
use serde::{Deserialize, Serialize};
use sq_core_graphics::text_animator_model::Utf16Range;
use sq_core_time::text::graphemes;
use sq_core_time::word_segmentation;

/// Number of UTF-16 units of `s` (Swift `(s as NSString).length`).
pub(crate) fn utf16_len(s: &str) -> i64 {
    s.encode_utf16().count() as i64
}

/// The UTF-16 range `[start, start + length)` of `s` (Swift `NSString.substring(with:)`).
fn utf16_substring(s: &str, start: i64, length: i64) -> String {
    let units: Vec<u16> = s.encode_utf16().collect();
    let a = (start.max(0) as usize).min(units.len());
    let b = ((start + length).max(0) as usize).min(units.len());
    String::from_utf16_lossy(&units[a..b.max(a)])
}

/// Rectangle in layout space: sequence pixels (points = pixels, scale 1), origin top-left, y down.
/// See docs/ARCHITECTURE.md "Coordinate convention". Renderers convert to their own space at their boundary.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextRect {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl TextRect {
    /// The empty rect at the origin.
    pub const ZERO: TextRect = TextRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

    /// A rect.
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        TextRect { x, y, width, height }
    }

    /// Right edge.
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    /// Bottom edge.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// Grown by the given amounts on each side.
    pub fn expanded(&self, left: f64, top: f64, right: f64, bottom: f64) -> TextRect {
        TextRect {
            x: self.x - left,
            y: self.y - top,
            width: self.width + left + right,
            height: self.height + top + bottom,
        }
    }

    /// Grown by `d` on every side.
    pub fn expanded_by(&self, d: f64) -> TextRect {
        self.expanded(d, d, d, d)
    }

    /// Moved by (`dx`, `dy`).
    pub fn offset_by(&self, dx: f64, dy: f64) -> TextRect {
        TextRect { x: self.x + dx, y: self.y + dy, width: self.width, height: self.height }
    }

    /// The smallest rect holding both.
    pub fn union(&self, o: &TextRect) -> TextRect {
        let x0 = self.x.min(o.x);
        let y0 = self.y.min(o.y);
        let x1 = self.max_x().max(o.max_x());
        let y1 = self.max_y().max(o.max_y());
        TextRect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
    }
}

/// One laid-out line. Coordinates: sequence pixels (points = pixels), origin top-left, y grows downward.
/// The layout origin (0, 0) is the top-left of the text block; callers place the block in the sequence.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLine {
    /// Line content without the trailing whitespace that caused the wrap.
    pub text: String,
    /// Aligned left edge.
    pub x: f64,
    /// Top of the line box.
    pub y: f64,
    /// Typographic width (trailing whitespace excluded).
    pub width: f64,
    /// ascent + descent of the runs actually used on this line (fallback fonts such as emoji included, never
    /// less than the main font); no leading / line spacing.
    pub height: f64,
    /// Distance from `y` to the baseline.
    pub baseline: f64,
    /// UTF-16 offset of `text` in `TextLayoutResult.display_text` (so word spans can be mapped onto the line).
    pub location: i64,
    /// Which style the line is drawn in (`TextStyle::line_style`): 0 = the clip style, 1 = the second-line style.
    pub style_index: usize,
    /// `rect()` grown by the style's stroke width and shadow (offset + blur); equals `rect()` without either.
    pub ink_bounds: TextRect,
    /// The paragraph this line belongs to is laid out right to left (`TextStyle.direction`, else its first strong
    /// character). One value per paragraph, so a wrapped line that starts with a Latin word keeps the direction.
    pub is_right_to_left: bool,
    /// UTF-16 length of the list marker ("• ", "2. ") at the start of `text`; 0 on every other line. The marker is not part
    /// of `display_text`: display_text index `i` sits at line index `i - location + marker_length`.
    pub marker_length: i64,
}

impl TextLine {
    /// The line box.
    pub fn rect(&self) -> TextRect {
        TextRect { x: self.x, y: self.y, width: self.width, height: self.height }
    }

    /// The line's text without the list marker.
    pub fn content(&self) -> String {
        if self.marker_length > 0 {
            let len = utf16_len(&self.text);
            utf16_substring(&self.text, self.marker_length.min(len), len)
        } else {
            self.text.clone()
        }
    }
}

/// The result of laying a text out.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayoutResult {
    /// The lines.
    pub lines: Vec<TextLine>,
    /// Union of all line rects (tight around the text, without stroke/shadow).
    pub bounds: TextRect,
    /// Everything that can be painted: text, stroke, background box and shadow (offset + blur). Use for clipping
    /// and dirty regions. Equals `bounds` for a plain style; nil-text gives `ZERO`.
    pub ink_bounds: TextRect,
    /// `bounds` expanded by the style's background padding; `None` without background or text.
    pub background_rect: Option<TextRect>,
    /// The text as drawn (capitals when the style says All Caps; the stored text is untouched).
    pub display_text: String,
    /// UTF-16 ranges of the words in `display_text`, found once on the original text with one whitespace definition
    /// (`Character.isWhitespace`, the same as `CaptionItem.tokens`). A word the wrap breaks across lines stays one word.
    pub word_spans: Vec<Utf16Range>,
}

/// Deterministic pure function of (text, style, max_width).
///
/// Coordinate convention (docs/ARCHITECTURE.md): all output is in sequence pixels (font size and widths are
/// points = pixels, scale 1), origin top-left of the text block, y down.
pub enum TextLayout {}

struct Measured {
    text: String,
    width: f64,
    ascent: f64,
    descent: f64,
    leading: f64,
    location: i64,
    style_index: usize,
    right_to_left: bool,
    marker: i64,
}

impl TextLayout {
    /// - `max_width`: wrap width in points; `None` disables wrapping. Also the alignment container
    ///   (`None`: the widest line).
    /// - `box_height`: area text: the box is `max_width` x `box_height`; the block is placed in it by
    ///   `style.vertical_alignment` and `bounds` is the box. Without it (point text, or a wrap width only) the block is
    ///   the text itself.
    pub fn layout(
        original: &str,
        style: &TextStyle,
        max_width: Option<f64>,
        box_height: Option<f64>,
    ) -> TextLayoutResult {
        // All caps changes the glyphs only: the caller keeps the text as typed, the layout (and so the renderer, which
        // draws the line texts) sees the capitals.
        if let (true, Some(w), Some(h)) = (style.auto_fit == Some(true), max_width, box_height) {
            let mut plain = Self::fitted_style(original, style, w, h);
            plain.auto_fit = None;
            return Self::layout(original, &plain, max_width, box_height);
        }
        let (text, word_spans) = TextWords::display(original, style.all_caps);
        // Paragraph looks: the first paragraph in the clip style, every later one in the second-line style, or each in its
        // own `line_styles` entry.
        let fonts: Vec<PlatformFont> =
            (0..style.line_style_count()).map(|i| Self::make_font(&style.line_style(i))).collect();
        let wrap = max_width.map(|w| w.max(1.0)).unwrap_or(f64::MAX);

        let mut raw: Vec<Measured> = Vec::new();
        if !text.is_empty() {
            let mut base: i64 = 0;
            let mut list_number = 0;
            for (i, para) in text.split('\n').enumerate() {
                let si = i.min(fonts.len() - 1);
                let rtl = TextDirection::is_right_to_left(para, style.direction);
                match (para.is_empty(), style.list) {
                    (false, Some(kind)) => {
                        list_number += 1;
                        let marker = kind.marker(list_number);
                        let pre = utf16_len(&marker);
                        let mut wrapped = Self::wrap_paragraph(
                            &format!("{marker}{para}"),
                            base - pre,
                            &fonts[si],
                            wrap,
                            style.tracking,
                            si,
                            rtl,
                        );
                        if let Some(first) = wrapped.first_mut() {
                            first.location = base;
                            first.marker = pre;
                        }
                        raw.extend(wrapped);
                    }
                    (true, _) => raw.push(Measured {
                        text: String::new(),
                        width: 0.0,
                        ascent: 0.0,
                        descent: 0.0,
                        leading: 0.0,
                        location: base,
                        style_index: si,
                        right_to_left: rtl,
                        marker: 0,
                    }),
                    (false, None) => {
                        raw.extend(Self::wrap_paragraph(para, base, &fonts[si], wrap, style.tracking, si, rtl))
                    }
                }
                base += utf16_len(para) + 1;
            }
        }
        if raw.is_empty() {
            return TextLayoutResult {
                lines: Vec::new(),
                bounds: TextRect::ZERO,
                ink_bounds: TextRect::ZERO,
                background_rect: None,
                display_text: text,
                word_spans,
            };
        }

        let container = max_width
            .map(|w| w.max(1.0))
            .unwrap_or_else(|| raw.iter().map(|m| m.width).fold(f64::NEG_INFINITY, f64::max));
        let mut lines: Vec<TextLine> = Vec::new();
        let mut y = 0.0;
        for m in &raw {
            // Runs in fallback fonts (emoji, CJK) may be taller than the main font; never shorter than it.
            let font = &fonts[m.style_index];
            let fm = Self::font_metrics(font);
            let ascent = fm.ascent.max(m.ascent);
            let descent = fm.descent.max(m.descent);
            let leading = fm.leading.max(m.leading);
            let x = match style.alignment {
                TextAlignment::Left => 0.0,
                TextAlignment::Center => (container - m.width) / 2.0,
                TextAlignment::Right => container - m.width,
            };
            let bx = TextRect::new(x, y, m.width, ascent + descent);
            lines.push(TextLine {
                text: m.text.clone(),
                x,
                y,
                width: m.width,
                height: ascent + descent,
                baseline: ascent,
                location: m.location,
                style_index: m.style_index,
                ink_bounds: Self::ink_rect(&bx, style),
                is_right_to_left: m.right_to_left,
                marker_length: m.marker,
            });
            y += ascent + descent + leading + style.line_spacing;
        }
        let min_x = lines.iter().map(|l| l.x).fold(f64::INFINITY, f64::min);
        let max_x = lines.iter().map(|l| l.x + l.width).fold(f64::NEG_INFINITY, f64::max);
        let last_max_y = lines.last().map(|l| l.rect().max_y()).unwrap_or(0.0);
        let mut text_bounds = TextRect::new(min_x, 0.0, max_x - min_x, last_max_y - lines[0].y);
        let mut bounds = text_bounds;
        if let (Some(box_h), Some(w)) = (box_height, max_width) {
            let h = box_h.max(1.0);
            let cw = w.max(1.0);
            let dy = match style.vertical_alignment {
                TextVerticalAlignment::Top => 0.0,
                TextVerticalAlignment::Middle => (h - text_bounds.height) / 2.0,
                TextVerticalAlignment::Bottom => h - text_bounds.height,
            };
            if dy != 0.0 {
                for l in lines.iter_mut() {
                    l.y += dy;
                    l.ink_bounds = l.ink_bounds.offset_by(0.0, dy);
                }
                text_bounds = text_bounds.offset_by(0.0, dy);
            }
            bounds = TextRect::new(0.0, 0.0, cw, h);
        }
        let bg = style.background.map(|b| {
            TextRect::new(
                text_bounds.x - b.padding.horizontal,
                text_bounds.y - b.padding.vertical,
                text_bounds.width + 2.0 * b.padding.horizontal,
                text_bounds.height + 2.0 * b.padding.vertical,
            )
        });
        let ink = Self::ink_rect(&bounds.union(&text_bounds).union(&bg.unwrap_or(text_bounds)), style);
        TextLayoutResult { lines, bounds, ink_bounds: ink, background_rect: bg, display_text: text, word_spans }
    }

    /// The style scaled down (never up) until the text fits `width` x `height`: sizes, tracking and line spacing follow one
    /// factor, found by bisection (the layout is monotone in the factor). Text that cannot fit even at the smallest size
    /// (a word wider than the box) is returned at that smallest size.
    pub fn fitted_style(text: &str, style: &TextStyle, width: f64, height: f64) -> TextStyle {
        let mut base = style.clone();
        base.auto_fit = None;
        let fits = |s: &TextStyle| {
            let r = Self::layout(text, s, Some(width), None);
            if r.lines.is_empty() {
                return true;
            }
            r.bounds.height <= height + 1e-6 && r.lines.iter().all(|l| l.width <= width + 1e-6)
        };
        if fits(&base) {
            return base;
        }
        let scaled = |f: f64| {
            let mut s = base.clone();
            s.size = 1.0_f64.max(base.size * f);
            s.tracking = base.tracking * f;
            s.line_spacing = base.line_spacing * f;
            if let Some(l) = s.second_line.as_mut() {
                l.size = 1.0_f64.max(l.size * f);
            }
            if let Some(own) = s.line_styles.as_mut() {
                for l in own.iter_mut() {
                    l.size = 1.0_f64.max(l.size * f);
                }
            }
            s
        };
        let mut lo = 0.02;
        let mut hi = 1.0;
        if !fits(&scaled(lo)) {
            return scaled(lo);
        }
        for _ in 0..14 {
            let mid = (lo + hi) / 2.0;
            if fits(&scaled(mid)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        scaled(lo)
    }

    /// `rect` grown by how far the stroke reaches (its width outside, half of it centered) and united with its shadow.
    /// Shadow offset is in layout space (positive y = down); blur is taken as full radius.
    pub fn ink_rect(rect: &TextRect, style: &TextStyle) -> TextRect {
        let grown = rect.expanded_by(style.stroke.map(|s| s.reach()).unwrap_or(0.0));
        let Some(sh) = style.shadow else { return grown };
        grown.union(&grown.offset_by(sh.offset_x, sh.offset_y).expanded_by(sh.blur + sh.spread))
    }

    pub(crate) fn make_font(style: &TextStyle) -> PlatformFont {
        FontResolver::font_for(style)
    }

    fn trim_trailing_whitespace(s: &str) -> String {
        let gs: Vec<&str> = graphemes(s).collect();
        let mut end = gs.len();
        while end > 0 && is_whitespace_character(gs[end - 1]) {
            end -= 1;
        }
        gs[..end].concat()
    }

    /// UTF-16 offsets where a line may start: after each whitespace run that is followed by a word (FB-M: lines break only
    /// at whitespace, never inside a word or at a hyphen). Whitespace is `Character.isWhitespace`, as in `TextWords`.
    pub fn break_opportunities(para: &str) -> Vec<i64> {
        let mut out = Vec::new();
        let mut offset: i64 = 0;
        let mut prev_space = false;
        let mut saw_word = false; // leading whitespace stays with the first word
        let mut prev: Option<&str> = None;
        for ch in graphemes(para) {
            let space = is_whitespace_character(ch);
            if !space && prev_space && saw_word {
                out.push(offset);
            } else if let (false, false, Some(p)) = (space, prev_space, prev)
                && CJKBreaking::can_break(p, ch)
            {
                // CJK has no spaces: a line may also break between an ideograph/kana and its neighbor, except before
                // a closing mark or after an opening one (kinsoku).
                out.push(offset);
            }
            if !space {
                saw_word = true;
            }
            prev_space = space;
            prev = Some(ch);
            offset += utf16_len(ch);
        }
        out
    }

    /// Greedy word wrap: each line takes as many whole words as fit `max_width` (trailing whitespace not counted); a word
    /// wider than `max_width` gets a line of its own and overflows. Returns the UTF-16 length of each line, trailing
    /// whitespace included (as Core Text counts it).
    pub fn line_lengths(ts: &dyn LineTypesetting, length: i64, breaks: &[i64], max_width: f64) -> Vec<i64> {
        let width = |a: i64, b: i64| {
            let m = ts.line(a, b - a);
            0.0_f64.max(m.width - m.trailing_whitespace)
        };
        let mut out = Vec::new();
        let mut start = 0;
        let mut k = 0; // breaks[k] is the first opportunity after `start`
        while start < length {
            while k < breaks.len() && breaks[k] <= start {
                k += 1;
            }
            let mut end = if k < breaks.len() { breaks[k] } else { length }; // at least one word
            let mut j = k;
            while end < length {
                let next = if j + 1 < breaks.len() { breaks[j + 1] } else { length };
                if width(start, next) > max_width + 1e-6 {
                    break;
                }
                end = next;
                j += 1;
            }
            out.push(end - start);
            start = end;
        }
        out
    }

    fn wrap_paragraph(
        para: &str,
        base: i64,
        font: &PlatformFont,
        max_width: f64,
        tracking: f64,
        style_index: usize,
        right_to_left: bool,
    ) -> Vec<Measured> {
        let ts = Self::typesetter(para, font, tracking, Some(right_to_left));
        let len = utf16_len(para);
        let mut out = Vec::new();
        let mut start = 0;
        let counts = if max_width >= f64::MAX {
            vec![len]
        } else {
            Self::line_lengths(ts.as_ref(), len, &Self::break_opportunities(para), max_width)
        };
        for count in counts.into_iter().filter(|&c| c > 0) {
            // Typographic bounds cover all runs actually used, including fallback fonts.
            let lm = ts.line(start, count);
            let w = 0.0_f64.max(lm.width - lm.trailing_whitespace);
            let piece = utf16_substring(para, start, count);
            // Leading whitespace is significant (drawn and measured); only the wrap-causing trailing run is dropped.
            out.push(Measured {
                text: Self::trim_trailing_whitespace(&piece),
                width: w,
                ascent: lm.ascent,
                descent: lm.descent,
                leading: lm.leading,
                location: base + start,
                style_index,
                right_to_left,
                marker: 0,
            });
            start += count;
        }
        out
    }
}

/// `Character.isWhitespace`: the first scalar of the grapheme is whitespace.
fn is_whitespace_character(g: &str) -> bool {
    g.chars().next().is_some_and(char::is_whitespace)
}

/// Words of a text. One definition for the whole app (`word_segmentation`): whitespace and every CJK character separate words.
pub enum TextWords {}

impl TextWords {
    /// The text as drawn and the UTF-16 spans of its words, computed once. With `all_caps` each character is
    /// capitalised on its own, so a length-changing capital (German sharp s becomes two capital S) moves the spans but never splits or
    /// merges a word, and the spans still describe the words of the original text.
    pub fn display(original: &str, all_caps: bool) -> (String, Vec<Utf16Range>) {
        let chars: Vec<&str> = graphemes(original).collect();
        let mut out = String::new();
        let mut offsets: Vec<usize> = vec![0]; // UTF-16 offset of each character of the displayed text
        for ch in &chars {
            if all_caps {
                out.push_str(&ch.to_uppercase());
            } else {
                out.push_str(ch);
            }
            offsets.push(utf16_len(&out) as usize);
        }
        let spans = word_segmentation::spans(&chars)
            .into_iter()
            .map(|r| Utf16Range { location: offsets[r.start], length: offsets[r.end] - offsets[r.start] })
            .collect();
        (out, spans)
    }
}

/// Line breaking inside unspaced CJK text (a pragmatic subset of UAX 14, enough for subtitles and titles).
pub enum CJKBreaking {}

/// May not start a line (same set as the closing marks of `word_segmentation`, which keeps it private).
const NO_LINE_START: &str =
    "、。，．・：；！？）〕］｝〉》」』】〙〗〟'”ゝゞヽヾーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ々〻)]}!?,.:;%";
/// May not end a line (the opening marks of `word_segmentation`).
const NO_LINE_END: &str = "（〔［｛〈《「『【〘〖〝‘“([{";

impl CJKBreaking {
    fn in_set(c: &str, set: &str) -> bool {
        let mut it = c.chars();
        matches!((it.next(), it.next()), (Some(x), None) if set.contains(x))
    }

    /// Whether a line may break between the characters `a` and `b`.
    pub fn can_break(a: &str, b: &str) -> bool {
        if !(word_segmentation::is_cjk(a) || word_segmentation::is_cjk(b)) {
            return false;
        }
        !Self::in_set(b, NO_LINE_START) && !Self::in_set(a, NO_LINE_END)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;
    use crate::text_style::{RGBAColor, StrokePosition, TextListKind, TextStroke};

    /// FB-M word rule: a line breaks only at whitespace. A word is never split across lines (not mid-word, not at a hyphen);
    /// a word wider than the box gets a line of its own.
    fn style() -> TextStyle {
        set_fonts_root(&test_fonts_root());
        TextStyle { font_name: "Helvetica".into(), size: 40.0, alignment: TextAlignment::Left, ..TextStyle::default() }
    }

    fn width(s: &str) -> f64 {
        TextLayout::layout(s, &style(), None, None).lines[0].width
    }

    fn lines(s: &str, w: f64) -> Vec<String> {
        TextLayout::layout(s, &style(), Some(w), None).lines.into_iter().map(|l| l.text).collect()
    }

    #[test]
    fn overlong_word_stays_on_one_line() {
        let word = "Geschwindigkeitsbegrenzung";
        assert_eq!(lines(word, width(word) / 3.0), vec![word]);
    }

    #[test]
    fn overlong_word_gets_its_own_line_between_others() {
        let word = "Geschwindigkeitsbegrenzung";
        assert_eq!(lines(&format!("die {word} gilt"), width(word) / 2.0), vec!["die", word, "gilt"]);
    }

    #[test]
    fn hyphenated_word_is_not_broken_at_the_hyphen() {
        // Room for "ausprobieren-" but not for "ausprobieren-das": the compound stays whole on its own line.
        let w = width("ausprobieren-") + 2.0;
        assert_eq!(lines("ausprobieren-das Rennen", w), vec!["ausprobieren-das", "Rennen"]);
    }

    #[test]
    fn greedy_fill_still_works() {
        let w = width("one two") + 1.0;
        assert_eq!(lines("one two three", w), vec!["one two", "three"]);
        assert_eq!(lines("one two three", width("one two three") + 1.0), vec!["one two three"]);
    }

    #[test]
    fn words_are_never_split_or_lost_at_any_width() {
        let text = "Heute probieren wir Kaffeemaschinenreiniger und Donau-Dampfschifffahrt aus, ganz schnell";
        let words: Vec<&str> = text.split(' ').collect();
        let mut w = 20.0;
        while w <= 900.0 {
            let ls = lines(text, w);
            let got: Vec<String> = ls.iter().flat_map(|l| l.split(' ').map(str::to_string)).collect();
            assert_eq!(got, words, "width {w}: {ls:?}");
            w += 37.0;
        }
    }

    #[test]
    fn explicit_line_breaks_stay() {
        assert_eq!(lines("eins zwei\ndrei", 2000.0), vec!["eins zwei", "drei"]);
    }

    #[test]
    fn words_display_text_and_spans_follow_all_caps() {
        let (text, spans) = TextWords::display("straße ab", true);
        assert_eq!(text, "STRASSE AB");
        let units: Vec<(usize, usize)> = spans.iter().map(|s| (s.location, s.length)).collect();
        assert_eq!(units, vec![(0, 7), (8, 2)]);
    }

    #[test]
    fn cjk_breaks_between_characters_but_not_before_closing_marks() {
        assert!(CJKBreaking::can_break("日", "本"));
        assert!(!CJKBreaking::can_break("日", "。"));
        assert!(!CJKBreaking::can_break("「", "本"));
        assert!(!CJKBreaking::can_break("a", "b"));
    }

    #[test]
    fn list_markers_and_ink_bounds() {
        let mut s = style();
        s.list = Some(TextListKind::Numbered);
        s.stroke = Some(TextStroke::new(RGBAColor::BLACK, 10.0, StrokePosition::Outside));
        let r = TextLayout::layout("a\nb", &s, None, None);
        assert_eq!(r.lines[0].text, "1. a");
        assert_eq!(r.lines[0].marker_length, 3);
        assert_eq!(r.lines[0].content(), "a");
        assert_eq!(r.lines[1].location, 2);
        assert!((r.ink_bounds.width - r.bounds.width - 20.0).abs() < 1e-9);
    }
}
