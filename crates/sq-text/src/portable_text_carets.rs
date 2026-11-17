// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/PortableTextCarets.swift

use crate::portable_text_renderer::{GlyphPlacer, PortableTextRenderer};
use crate::text_layout::{TextLayout, utf16_len};
use crate::text_style::TextStyle;
use sq_core_graphics::graphics_editing::GraphicsRect;
use sq_core_model::anchored_animation::{AnimationSample, AnimationSet};
use sq_core_model::{GeneratorRef, SequenceFormat};
use sq_core_time::{Time, text::graphemes};

use crate::text_generator::{TextGenerator, TextGeneratorError};

/// One line of a `TextCaretMap`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaretLine {
    /// Top in layout px from the raster's top-left.
    pub top: f64,
    /// Height.
    pub height: f64,
}

/// One caret.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Caret {
    /// Index of its line.
    pub line: usize,
    /// Horizontal position in layout px from the raster's left.
    pub x: f64,
}

/// Caret positions of a text block where the portable raster draws its glyphs: one caret per character boundary of the
/// stored text, in layout px relative to the raster's top-left (the ink origin, the monitor's text frame corner).
/// The monitor's on-canvas text field draws its caret and selection from it and maps a click to a character.
#[derive(Clone, Debug, PartialEq)]
pub struct TextCaretMap {
    /// The lines.
    pub lines: Vec<CaretLine>,
    /// `text.count + 1` entries: caret `i` sits before character `i` (the last one after the text).
    pub carets: Vec<Caret>,
}

impl TextCaretMap {
    /// The caret nearest to (`x`, `y`): the line under `y` (clamped to the first / last), then the nearest caret on it.
    pub fn index_at(&self, x: f64, y: f64) -> usize {
        if self.lines.is_empty() || self.carets.is_empty() {
            return 0;
        }
        let row = self.lines.iter().rposition(|l| l.top <= y).unwrap_or(0);
        let mut best = 0;
        let mut best_distance = f64::INFINITY;
        for (i, c) in self.carets.iter().enumerate() {
            if c.line != row {
                continue;
            }
            let d = (c.x - x).abs();
            if d < best_distance {
                best = i;
                best_distance = d;
            }
        }
        if best_distance.is_finite() {
            best
        } else if y < self.lines[0].top {
            0
        } else {
            self.carets.len() - 1
        }
    }
}

impl PortableTextRenderer {
    /// The caret map of `text` as `render` lays it out (same style, wrap and box). `None` when nothing would be drawn.
    /// known limit: carets of right-to-left lines run left to right (the raster does not reorder them either), and All Caps
    /// letters that change length (ß) shift the carets after them; upgrade with HarfBuzz shaping.
    pub fn caret_map(
        text: &str,
        style: &TextStyle,
        max_width: Option<f64>,
        box_height: Option<f64>,
    ) -> Option<TextCaretMap> {
        let style = style.drawn();
        let layout = TextLayout::layout(text, &style, max_width, box_height);
        let ink = layout.ink_bounds;
        if layout.lines.is_empty() || !ink.x.is_finite() || !ink.y.is_finite() {
            return None;
        }
        let pens = GlyphPlacer::new(&layout, &style, &ink, 1.0).carets;
        let lines: Vec<CaretLine> =
            layout.lines.iter().map(|l| CaretLine { top: l.y - ink.y, height: l.height }).collect();
        // The layout's lines in display-text order (UTF-16 location); a caret belongs to the last line starting at or
        // before it. Offsets past a line's end (the break, a wrapped space) sit at its end.
        let caret = |u: i64| {
            let li = layout.lines.iter().rposition(|l| l.location <= u).unwrap_or(0);
            let l = &layout.lines[li];
            let local = u - l.location + l.marker_length;
            let map = &pens[li];
            let end = map.keys().max().and_then(|k| map.get(k)).copied().unwrap_or(l.x);
            let start = map.get(&l.marker_length).copied().unwrap_or(l.x);
            let x = if local < l.marker_length { start } else { map.get(&local).copied().unwrap_or(end) };
            Caret { line: li, x: x - ink.x }
        };
        let mut carets = Vec::new();
        let mut u: i64 = 0;
        for ch in graphemes(text) {
            carets.push(caret(u));
            u += utf16_len(ch);
        }
        carets.push(caret(u));
        Some(TextCaretMap { lines, carets })
    }
}

/// The text frame of a clip without drawing it: where `portableFrame` would place its raster (scale 1) and the
/// animation at `local_time`. The monitor's text frame, Type tool hits and the font-size handles on Windows read it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PortableTextBox {
    /// Left.
    pub x: f64,
    /// Top.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
    /// Animation opacity.
    pub opacity: f64,
    /// Animation scale.
    pub scale: f64,
    /// Animation offset x.
    pub offset_x: f64,
    /// Animation offset y.
    pub offset_y: f64,
    /// Animation rotation.
    pub rotation: f64,
}

/// `extension TextGenerator` of PortableTextCarets.swift.
pub trait TextGeneratorBoxExt {
    /// `portableFrame(ref:…)`'s placement from the layout alone (no raster): `None` for empty text or ink.
    fn portable_box(
        reference: &GeneratorRef,
        local_time: Time,
        clip_duration: Time,
        canvas: &SequenceFormat,
    ) -> Result<Option<PortableTextBox>, TextGeneratorError>;

    /// `graphicsRect` from `portable_box`: a text layer's box in a graphic (offset from the canvas center, y down).
    fn portable_graphics_rect(
        reference: &GeneratorRef,
        local_time: Time,
        clip_duration: Time,
        canvas: &SequenceFormat,
    ) -> Option<GraphicsRect>;
}

impl TextGeneratorBoxExt for TextGenerator {
    fn portable_box(
        reference: &GeneratorRef,
        local_time: Time,
        clip_duration: Time,
        canvas: &SequenceFormat,
    ) -> Result<Option<PortableTextBox>, TextGeneratorError> {
        let (template, set) = TextGenerator::decode(reference)?;
        let layout = TextLayout::layout(
            &template.text,
            &template.style.drawn(),
            template.box_.map(|b| b.width),
            template.box_.map(|b| b.height),
        );
        let ink = layout.ink_bounds;
        let w = ink.width.ceil();
        let h = ink.height.ceil();
        if layout.lines.is_empty()
            || !w.is_finite()
            || !h.is_finite()
            || w <= 0.0
            || h <= 0.0
            || !ink.x.is_finite()
            || !ink.y.is_finite()
        {
            return Ok(None);
        }
        let set = set.or_else(|| AnimationSet::single(template.animation.as_ref()));
        let a: AnimationSample = set.map(|s| s.sample(local_time, clip_duration)).unwrap_or(AnimationSample::REST);
        let b = layout.bounds;
        Ok(Some(PortableTextBox {
            x: (canvas.display_width() as f64 - b.width) / 2.0 + (ink.x - b.x),
            y: (canvas.height as f64 - b.height) / 2.0 + (ink.y - b.y),
            width: w,
            height: h,
            opacity: a.opacity,
            scale: a.scale,
            offset_x: a.offset.x,
            offset_y: a.offset.y,
            rotation: a.rotation,
        }))
    }

    fn portable_graphics_rect(
        reference: &GeneratorRef,
        local_time: Time,
        clip_duration: Time,
        canvas: &SequenceFormat,
    ) -> Option<GraphicsRect> {
        let f = Self::portable_box(reference, local_time, clip_duration, canvas).ok()??;
        let min_x = f.x - canvas.display_width() as f64 / 2.0 + f.offset_x;
        let min_y = f.y - canvas.height as f64 / 2.0 + f.offset_y;
        Some(GraphicsRect { min_x, min_y, max_x: min_x + f.width, max_y: min_y + f.height })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;
    use crate::text_style::{RGBAColor, StrokePosition, TextAlignment, TextBox, TextStroke};
    use crate::text_template::TextTemplate;
    use sq_core_model::anchored_animation::{AnimationAnchor, AnimationTrack, KeyframeTemplate, SegmentShape};

    /// The text box without a raster (`TextGenerator::portable_box`, the monitor's text frame on Windows) and the caret map of
    /// the portable raster (`PortableTextRenderer::caret_map`, the on-canvas field's caret and click positions).
    fn canvas() -> SequenceFormat {
        set_fonts_root(&test_fonts_root());
        SequenceFormat { width: 1920, height: 1080, ..SequenceFormat::new(Time::new(1, 30)) }
    }

    #[test]
    fn box_matches_the_portable_frame() {
        let canvas = canvas();
        let fade = KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 0.0, SegmentShape::Linear), (Time::new(1, 5), 1.0, SegmentShape::Linear)],
            )],
            duration: Time::new(1, 5),
            anchor: AnimationAnchor::Start,
            ..KeyframeTemplate::none()
        };
        let style = TextStyle {
            size: 90.0,
            color: RGBAColor::WHITE,
            stroke: Some(TextStroke::new(RGBAColor::rgb(0.0, 0.0, 0.0), 4.0, StrokePosition::Outside)),
            ..TextStyle::default()
        };
        for b in [None, Some(TextBox::new(900.0, 500.0))] {
            let template = TextTemplate { box_: b, ..TextTemplate::new("t", "Hello\nWorld", style.clone()) };
            let reference = TextGenerator::make_ref(&template, Some(&AnimationSet::new(Some(fade.clone()), None))).ok();
            let Some(reference) = reference else { panic!("ref") };
            for t in [Time::ZERO, Time::new(1, 10)] {
                let f =
                    TextGenerator::portable_frame(&reference, t, Time::new(3, 1), &canvas, 1.0, None).ok().flatten();
                let bx = TextGenerator::portable_box(&reference, t, Time::new(3, 1), &canvas).ok().flatten();
                let (Some(f), Some(b)) = (f, bx) else { panic!("frame and box") };
                assert!((b.x - f.x).abs() < 1e-9 && (b.y - f.y).abs() < 1e-9);
                assert!((b.width - f.width).abs() < 1e-9 && (b.height - f.height).abs() < 1e-9);
                assert!(
                    b.offset_x == f.offset_x
                        && b.offset_y == f.offset_y
                        && b.scale == f.scale
                        && b.rotation == f.rotation
                );
                let r = TextGenerator::portable_graphics_rect(&reference, t, Time::new(3, 1), &canvas);
                let Some(r) = r else { panic!("rect") };
                assert!(
                    (r.min_x - (f.x - 960.0 + f.offset_x)).abs() < 1e-9 && ((r.max_x - r.min_x) - f.width).abs() < 1e-9
                );
            }
        }
        let empty = TextGenerator::make_ref(&TextTemplate::new("e", "", style), None).ok();
        let Some(empty) = empty else { panic!("ref") };
        assert_eq!(TextGenerator::portable_box(&empty, Time::ZERO, Time::new(3, 1), &canvas).ok(), Some(None));
    }

    #[test]
    fn carets_follow_the_glyphs_line_by_line() {
        let _ = canvas();
        let style = TextStyle { size: 100.0, alignment: TextAlignment::Center, ..TextStyle::default() };
        let text = "Wide line\nab";
        let map = PortableTextRenderer::caret_map(text, &style, None, None);
        let raster = PortableTextRenderer::render(text, &style, None, None, 1.0, None);
        let (Some(map), Some(raster)) = (map, raster) else { panic!("map and raster") };
        assert_eq!(map.carets.len(), text.chars().count() + 1);
        assert_eq!(map.lines.len(), 2);
        // "Wide line" sits on line 0, its end (before the break) too; "ab" and the end on line 1.
        assert!(map.carets[0..10].iter().all(|c| c.line == 0));
        assert!(map.carets[10..].iter().all(|c| c.line == 1));
        for r in [0..10, 10..13] {
            let xs: Vec<f64> = map.carets[r].iter().map(|c| c.x).collect();
            assert!(xs.windows(2).all(|w| w[0] < w[1]), "carets grow along a line");
        }
        // Each line's carets span its typographic width, placed where the raster's layout aligns it (ink origin = 0).
        for (li, (lo, hi)) in [(0usize, (0usize, 9usize)), (1, (10, 12))] {
            let l = &raster.layout.lines[li];
            let first = map.carets[lo].x;
            let last = map.carets[hi].x;
            assert!((first - (l.x - raster.origin_x)).abs() < 0.01);
            assert!(((last - first) - l.width).abs() < 1.0, "line {li}: {} vs {}", last - first, l.width);
            assert!((map.lines[li].top - (l.y - raster.origin_y)).abs() < 1e-9 && map.lines[li].height == l.height);
        }
        // Centered: the short line starts right of the long one.
        assert!(map.carets[10].x > map.carets[0].x + 50.0);
    }

    #[test]
    fn wrapped_space_and_empty_lines_keep_a_caret() {
        let _ = canvas();
        let style = TextStyle { size: 60.0, ..TextStyle::default() };
        let text = "one two three\n\nx";
        let map = PortableTextRenderer::caret_map(text, &style, Some(200.0), None);
        let Some(map) = map else { panic!("map") };
        assert_eq!(map.carets.len(), text.chars().count() + 1);
        assert!(map.lines.len() >= 4);
        let lines: Vec<usize> = map.carets.iter().map(|c| c.line).collect();
        assert!(lines.windows(2).all(|w| w[0] <= w[1]), "lines never go back");
        assert_eq!(lines.last().copied(), Some(map.lines.len() - 1));
        // The empty paragraph has a caret of its own line.
        let empty_index = text.find("\n\n").map(|i| i + 1).unwrap_or(0);
        assert_eq!(map.carets[empty_index].line, map.lines.len() - 2);
    }

    #[test]
    fn caret_index_finds_the_nearest_character() {
        let _ = canvas();
        let style = TextStyle { size: 100.0, ..TextStyle::default() };
        let text = "abc\nde";
        let map = PortableTextRenderer::caret_map(text, &style, None, None);
        let Some(map) = map else { panic!("map") };
        for i in 0..=text.chars().count() {
            let c = map.carets[i];
            let (x, y) = (c.x + 0.1, map.lines[c.line].top + map.lines[c.line].height / 2.0);
            assert_eq!(map.index_at(x, y), i, "caret {i}");
        }
        assert_eq!(map.index_at(-500.0, -500.0), 0);
        assert_eq!(map.index_at(5000.0, 5000.0), text.chars().count());
    }
}
