// SPDX-License-Identifier: GPL-3.0-or-later

//! The typewriter's blinking cursor on the portable raster: the cursor glyph is rendered with the text's own style (same font,
//! size and baseline) and laid onto the text's picture right after the last revealed character. The picture grows when the
//! cursor sticks out (after the last character of a line).

use crate::portable_text_renderer::{Picture, PortableTextRenderer, Raster};
use crate::text_style::RGBAColor;
use crate::text_template::TextTemplate;
use sq_core_graphics::text_animator_model::TextUnits;
use sq_core_model::anchored_animation::TextCursor;
use sq_core_time::text::graphemes;

/// `raster` with the cursor `spec` drawn after character `after` (`TextUnitCharacter::index`). The raster is returned
/// unchanged when the glyph cannot be placed (empty glyph, no layout).
pub fn with_cursor(
    raster: Raster,
    template: &TextTemplate,
    units: &TextUnits,
    after: usize,
    spec: &TextCursor,
) -> Raster {
    place(&raster, template, units, after, spec).unwrap_or(raster)
}

fn place(
    raster: &Raster,
    template: &TextTemplate,
    units: &TextUnits,
    after: usize,
    spec: &TextCursor,
) -> Option<Raster> {
    let ch = units.characters.get(after)?;
    // Caret index = number of graphemes up to the end of the character (the unit ranges count UTF-16 of the display text).
    let end = ch.range.location + ch.range.length;
    let (mut offset, mut caret) = (0, 0);
    for g in graphemes(&template.text) {
        if offset >= end {
            break;
        }
        offset += g.encode_utf16().count();
        caret += 1;
    }
    let (w, h) = (template.box_.map(|b| b.width), template.box_.map(|b| b.height));
    let map = PortableTextRenderer::caret_map(&template.text, &template.style, w, h)?;
    let at = map.carets.get(caret)?;
    let line = map.lines.get(at.line)?;
    let ink = raster.layout.ink_bounds;
    let (caret_x, line_y) = (ink.x + at.x, ink.y + line.top);

    let mut style = template.style.clone();
    if let Some([r, g, b]) = spec.rgb() {
        style.color = RGBAColor { red: r, green: g, blue: b, alpha: style.color.alpha };
    }
    style.background = None;
    style.underline = false;
    style.strikethrough = false;
    style.overline = false;
    style.list = None;
    style.auto_fit = None;
    let s = raster.scale;
    let glyph = PortableTextRenderer::render(&spec.glyph, &style, None, None, s, None)?;
    let gmap = PortableTextRenderer::caret_map(&spec.glyph, &style, None, None)?;
    let gink = glyph.layout.ink_bounds;
    let pen = (gink.x + gmap.carets.first()?.x, gink.y + gmap.lines.first()?.top);
    // Layout position of the glyph picture's top-left.
    let (gx, gy) = (caret_x + glyph.origin_x - pen.0, line_y + glyph.origin_y - pen.1);

    // The grown picture: the text keeps its pixels (whole-pixel shift), the glyph is rounded onto the grid.
    let grow = |text_at: f64, glyph_at: f64| (((text_at - glyph_at) * s).ceil().max(0.0)) as usize;
    let (mx, my) = (grow(raster.origin_x, gx), grow(raster.origin_y, gy));
    let origin_x = raster.origin_x - mx as f64 / s;
    let origin_y = raster.origin_y - my as f64 / s;
    let (cx, cy) = (((gx - origin_x) * s).round().max(0.0) as usize, ((gy - origin_y) * s).round().max(0.0) as usize);
    let width = (mx + raster.picture.width).max(cx + glyph.picture.width);
    let height = (my + raster.picture.height).max(cy + glyph.picture.height);
    if width > 16_384 || height > 16_384 {
        return None;
    }
    let mut pixels = vec![0.0_f32; width * height * 4];
    copy(&mut pixels, width, &raster.picture, mx, my, false);
    copy(&mut pixels, width, &glyph.picture, cx, cy, true);
    Some(Raster {
        layout: raster.layout.clone(),
        scale: s,
        origin_x,
        origin_y,
        picture: Picture { width, height, pixels },
    })
}

/// Copies `src` into `dst` (row length `dst_width`) at (`x`, `y`); `over`: source-over of premultiplied pixels.
fn copy(dst: &mut [f32], dst_width: usize, src: &Picture, x: usize, y: usize, over: bool) {
    for row in 0..src.height {
        let from = row * src.width * 4;
        let to = ((y + row) * dst_width + x) * 4;
        for i in 0..src.width {
            let (sp, dp) = (from + i * 4, to + i * 4);
            if over {
                let keep = 1.0 - src.pixels[sp + 3];
                for c in 0..4 {
                    dst[dp + c] = src.pixels[sp + c] + dst[dp + c] * keep;
                }
            } else {
                dst[dp..dp + 4].copy_from_slice(&src.pixels[sp..sp + 4]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;
    use crate::text_generator::TextGenerator;
    use crate::text_style::TextStyle;
    use sq_core_model::anchored_animation::{AnimationSet, TextAnimator, TextAnimatorEffect, TextAnimatorUnit};
    use sq_core_model::{GeneratorRef, SequenceFormat};
    use sq_core_time::Time;

    /// A 2-character typewriter ("ab", 500 ms apart, no fade) with the standard cursor in `color`.
    fn typewriter_ref(color: Option<&str>) -> GeneratorRef {
        let template = TextTemplate::new("t", "ab", TextStyle::default());
        let mut a =
            TextAnimator::new(TextAnimatorEffect::Typewriter, TextAnimatorUnit::Character, Time::ZERO, Time::new(1, 2));
        a.cursor = Some(TextCursor { color: color.map(Into::into), ..TextCursor::standard() });
        let mut set = AnimationSet::new(None, None);
        set.set_text_animator(true, Some(a));
        TextGenerator::make_ref(&template, Some(&set)).unwrap_or_else(|e| panic!("{e}"))
    }

    /// Opaque pixels of `f`'s picture in the columns from `x` on.
    fn ink_from(f: &crate::text_generator_portable::PortableTextFrame, x: usize) -> usize {
        let p = &f.picture;
        (0..p.height)
            .flat_map(|y| (x..p.width).map(move |c| (y, c)))
            .filter(|&(y, c)| p.pixels[(y * p.width + c) * 4 + 3] > 0.5)
            .count()
    }

    #[test]
    fn a_still_at_mid_type_has_cursor_pixels_right_of_the_last_character() {
        set_fonts_root(&test_fonts_root());
        let canvas = SequenceFormat { width: 1920, height: 1080, ..SequenceFormat::new(Time::new(1, 30)) };
        let ms = |v: i64| Time::new(v, 1000);
        let r = typewriter_ref(Some("#ff0000"));
        let frame = |t: Time| {
            TextGenerator::portable_frame(&r, t, Time::new(5, 1), &canvas, 1.0, None).unwrap_or_else(|e| panic!("{e}"))
        };
        // 700 ms: "ab" typed since 500 ms, solid cursor after "b".
        let typing = frame(ms(0)).expect("a frame"); // only "a" is typed
        assert_eq!(typing.cursor, Some(0));
        let both = frame(ms(500)).expect("a frame");
        assert_eq!(both.cursor, Some(1));
        let off = frame(ms(500 + 530)).expect("a frame");
        assert_eq!(off.cursor, None, "off half of the blink");
        let on_again = frame(ms(500 + 100)).expect("a frame");
        // The picture with the cursor is wider than the one without, the extra pixels sit right of the last character, red.
        assert!(on_again.picture.width > off.picture.width, "{} vs {}", on_again.picture.width, off.picture.width);
        let right = off.picture.width;
        assert!(ink_from(&on_again, right.saturating_sub(1)) > 0, "cursor pixels right of the last character");
        assert!(frame(ms(500 + 600)).expect("a frame").cursor.is_none(), "gone after the hold");
        let p = &on_again.picture;
        let red = (0..p.width * p.height)
            .any(|i| p.pixels[i * 4] > 0.5 && p.pixels[i * 4 + 1] < 0.1 && p.pixels[i * 4 + 3] > 0.5);
        assert!(red, "the cursor is red");
        assert!(!on_again.shares_picture(&off));
    }
}
