// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableFallback.swift
//! Font fallback of the portable text path: a scalar the primary face lacks (glyph 0, the "no glyph" box) is looked up in
//! the system symbol and emoji faces (Windows: Segoe UI Emoji, Segoe UI Symbol; Linux: Noto and DejaVu symbols), as Core Text falls back on the Mac.
//! Emoji sequences (ZWJ, skin tones, flags, keycaps) are joined by the face's GSUB features and drawn from its COLR layers
//! (`sfnt_color_glyphs`); a sequence the face cannot join shows its parts one by one.

use crate::fallback_font_files::{FallbackFontFiles, FallbackRole};
use crate::glyph_raster::GlyphRasterFont;
use sq_os::Platform;
use std::sync::{Arc, LazyLock, PoisonError, RwLock};

static FONTS: LazyLock<RwLock<Vec<Arc<GlyphRasterFont>>>> =
    LazyLock::new(|| RwLock::new(PortableFallback::system_fonts()));

/// One scalar's face and glyph.
#[derive(Clone, Debug)]
pub struct Pick {
    /// The fallback face; `None` = the primary face.
    pub font: Option<Arc<GlyphRasterFont>>,
    /// The glyph.
    pub glyph: i64,
    /// Advance in font units when the plan sets it (a zero-advance person of a ZWJ family); nil = the face's advance.
    pub advance: Option<i64>,
}

impl Pick {
    fn new(font: Option<Arc<GlyphRasterFont>>, glyph: i64) -> Pick {
        Pick { font, glyph, advance: None }
    }
}

/// Namespace of the fallback functions.
pub enum PortableFallback {}

impl PortableFallback {
    /// The fallback faces in order (the first that has the scalar wins).
    pub fn fonts() -> Vec<Arc<GlyphRasterFont>> {
        FONTS.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Replaces the fallback faces (tests).
    pub fn set_fonts(fonts: Vec<Arc<GlyphRasterFont>>) {
        *FONTS.write().unwrap_or_else(PoisonError::into_inner) = fonts;
    }

    /// The symbol and emoji faces that exist on this machine (Windows: Segoe UI Emoji and Symbol; Linux: Noto and DejaVu
    /// symbol faces from the font folders).
    pub fn system_fonts() -> Vec<Arc<GlyphRasterFont>> {
        FallbackFontFiles::find(Platform::current(), FallbackRole::Symbol, |k| std::env::var_os(k))
            .iter()
            .filter_map(|path| GlyphRasterFont::from_path(path))
            .map(Arc::new)
            .collect()
    }

    /// Scalars that only modify the one before (no glyph, no advance): variation selectors, ZWJ, skin tones, keycap.
    pub fn is_joiner(s: char) -> bool {
        matches!(u32::from(s), 0xFE00..=0xFE0F | 0x200D | 0x1F3FB..=0x1F3FF | 0x20E3 | 0xE0020..=0xE007F)
    }

    /// The advance of a glyph a ZWJ sequence leaves behind: the face's own, or (a zero advance, which the font expects GPOS
    /// to fix) the right edge of its ink, so the people stand side by side instead of on top of each other.
    /// known limit: no GPOS placement; upgrade when a font needs more than this.
    pub fn advance_of_sequence_glyph(glyph: i64, f: &GlyphRasterFont) -> i64 {
        let adv = f.advance(glyph);
        if adv > 0 {
            return adv;
        }
        let layers: Vec<i64> = match f.face.color_glyphs().and_then(|c| c.layers(glyph)) {
            Some(l) => l.iter().map(|l| l.glyph).collect(),
            None => vec![glyph],
        };
        let mut max_x = 0.0f64;
        for l in layers {
            for c in f.contours(l, &[]) {
                for p in c {
                    max_x = max_x.max(p.x);
                }
            }
        }
        max_x.round() as i64
    }

    fn is_regional_indicator(s: char) -> bool {
        (0x1F1E6..=0x1F1FF).contains(&u32::from(s))
    }

    fn is_keycap_base(s: char) -> bool {
        s == '#' || s == '*' || s.is_ascii_digit()
    }

    /// The scalars after `start` that belong to the same emoji sequence: variation selectors, skin tones, keycap, tags, ZWJ
    /// with the emoji it joins, and the second regional indicator of a flag.
    fn cluster_end(scalars: &[char], start: usize) -> usize {
        let mut i = start + 1;
        if Self::is_regional_indicator(scalars[start]) && i < scalars.len() && Self::is_regional_indicator(scalars[i]) {
            return i + 1;
        }
        while i < scalars.len() {
            if Self::is_joiner(scalars[i]) {
                i += 1;
                if u32::from(scalars[i - 1]) == 0x200D && i < scalars.len() {
                    i += 1;
                }
            } else {
                break;
            }
        }
        i
    }

    /// `plan` over the process-wide fallback faces.
    pub fn plan_default(scalars: &[char], primary: &GlyphRasterFont) -> Vec<(Pick, bool)> {
        Self::plan(scalars, primary, &Self::fonts())
    }

    /// The face and glyph for each scalar of `text`; `font == nil` means the primary face (glyph may be 0 = notdef).
    /// An emoji sequence the fallback face turns into one glyph (GSUB: ZWJ family, skin tone, flag, keycap) puts it on the
    /// first scalar and marks the rest `skip` (no glyph, no advance); the glyphs it leaves (a family is several) take the first scalars.
    pub fn plan(scalars: &[char], primary: &GlyphRasterFont, fallbacks: &[Arc<GlyphRasterFont>]) -> Vec<(Pick, bool)> {
        let mut out: Vec<(Pick, bool)> = Vec::new();
        let mut i = 0;
        while i < scalars.len() {
            let s = scalars[i];
            let skipped = || (Pick::new(None, 0), true);
            if Self::is_joiner(s) {
                out.push(skipped());
                i += 1;
                continue;
            }
            let g = primary.glyph_for(s);
            let next = |k: usize| scalars.get(i + k).map(|c| u32::from(*c));
            let keycap = Self::is_keycap_base(s)
                && i + 1 < scalars.len()
                && (next(1) == Some(0x20E3)
                    || (next(1) == Some(0xFE0F) && i + 2 < scalars.len() && next(2) == Some(0x20E3)));
            let face = fallbacks.iter().find(|f| f.glyph_for(s) != 0);
            let emoji_form = keycap || (i + 1 < scalars.len() && next(1) == Some(0xFE0F)); // keycap or VS16: the emoji face wins
            if (g != 0 && (!emoji_form || face.is_none())) || s.is_whitespace() || u32::from(s) < 0x20 {
                out.push((Pick::new(None, g), false));
                i += 1;
                continue;
            }
            let Some(f) = face else {
                out.push((Pick::new(None, 0), false));
                i += 1;
                continue;
            };
            let end = Self::cluster_end(scalars, i);
            let parts = &scalars[i..end];
            let glyphs: Vec<i64> = parts
                .iter()
                .filter_map(|p| {
                    if (0xFE00..=0xFE0F).contains(&u32::from(*p)) {
                        return None;
                    }
                    let pg = f.glyph_for(*p);
                    if pg == 0 { None } else { Some(pg) }
                })
                .collect();
            let joined = match f.face.substitution() {
                Some(sub) => sub.apply(&glyphs),
                None => glyphs,
            };
            if keycap && joined.len() != 1 {
                // the face has no keycap glyph: the digit in the text face, the rest dropped
                out.push((Pick::new(None, g), false));
                out.extend((1..parts.len()).map(|_| skipped()));
            } else {
                // The joined glyphs sit on the first scalars of the sequence (a ZWJ family stays several glyphs, each a
                // joined variant); the rest take no room.
                let several = joined.len() > 1 && parts.iter().any(|p| u32::from(*p) == 0x200D);
                for k in 0..parts.len() {
                    if let Some(&glyph) = joined.get(k) {
                        let advance = if several { Some(Self::advance_of_sequence_glyph(glyph, f)) } else { None };
                        out.push((Pick { font: Some(Arc::clone(f)), glyph, advance }, false));
                    } else {
                        out.push(skipped());
                    }
                }
            }
            i = end;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::{self, FAMILIES};
    use crate::inter_font;
    use crate::portable_font_match::{PortableFontMatch, fonts_root, use_bundled_fonts};
    use crate::text_style::FontWeight;

    fn inter() -> Arc<GlyphRasterFont> {
        use_bundled_fonts();
        PortableFontMatch::choose(inter_font::FAMILY_NAME, FontWeight::Regular, false, 20.0, None).unwrap().font
    }

    #[test]
    fn joiners_without_any_fallback_are_dropped() {
        // a thumbs up with skin tone and VS16 with no fallback face: the modifiers have no glyph and take no room
        let s: Vec<char> = "\u{1F44D}\u{1F3FD}\u{FE0F}".chars().collect();
        let plan = PortableFallback::plan(&s, &inter(), &[]);
        assert_eq!(plan.iter().map(|p| p.1).collect::<Vec<_>>(), [false, true, true]);
    }

    #[test]
    fn missing_glyph_goes_to_the_first_fallback_that_has_it() {
        let primary = inter();
        let scalar = '\u{4E2D}';
        assert_eq!(primary.glyph_for(scalar), 0);
        let root = fonts_root().unwrap();
        let other = FAMILIES
            .iter()
            .flat_map(|f| bundled_fonts::font_urls(f, &root))
            .filter_map(|u| GlyphRasterFont::from_path(&u))
            .find(|f| f.glyph_for(scalar) != 0);
        let Some(other) = other else {
            // no bundled face covers it: without a fallback the box stays
            assert_eq!(PortableFallback::plan(&[scalar], &primary, &[])[0].0.glyph, 0);
            return;
        };
        let other = Arc::new(other);
        let plan = PortableFallback::plan(&[scalar], &primary, &[Arc::clone(&other)]);
        let pick = &plan[0].0;
        assert!(pick.font.as_ref().is_some_and(|f| Arc::ptr_eq(f, &other)) && pick.glyph != 0);
    }

    #[test]
    fn spaces_stay_on_the_primary_face() {
        let plan = PortableFallback::plan(&[' ', 'A'], &inter(), &[]);
        assert!(plan.iter().all(|(pick, skip)| pick.font.is_none() && !skip));
    }

    #[test]
    fn joiner_scalars_are_the_modifiers_of_an_emoji() {
        assert!(PortableFallback::is_joiner('\u{200D}') && PortableFallback::is_joiner('\u{FE0F}'));
        assert!(!PortableFallback::is_joiner('A'));
    }

    /// Real faces of this PC: symbols come from Segoe UI Symbol / Emoji (never the "no glyph" box) and an emoji is drawn
    /// in its own colors although the text color is white.
    #[cfg(windows)]
    #[test]
    fn segoe_faces_draw_symbols_and_color_emoji() {
        use crate::portable_text_renderer::PortableTextRenderer;
        use crate::text_style::TextStyle;
        let primary = inter();
        let fonts = PortableFallback::fonts();
        assert!(!fonts.is_empty(), "no Segoe UI Emoji / Symbol on this machine");
        for scalar in ['\u{2713}', '\u{2192}', '\u{2605}', '\u{1F600}'] {
            let plan = PortableFallback::plan(&[scalar], &primary, &fonts);
            let pick = &plan[0].0;
            assert!(
                pick.glyph != 0 && (pick.font.is_some() || primary.glyph_for(scalar) != 0),
                "U+{:X} has no glyph",
                scalar as u32
            );
        }
        let ink = |text: &str| {
            let r = PortableTextRenderer::render(text, &TextStyle::default(), None, None, 1.0, None).expect("a raster");
            let p = &r.picture.pixels;
            let inked = p.chunks(4).filter(|px| px[3] > 0.2).count();
            let colored = p
                .chunks(4)
                .filter(|px| px[3] > 0.2 && (px[0].max(px[1]).max(px[2]) - px[0].min(px[1]).min(px[2])) > 0.15)
                .count();
            (inked, colored)
        };
        for symbols in ["\u{2713}", "\u{2192}", "\u{2605}"] {
            let (inked, _) = ink(symbols);
            assert!(inked > 50, "symbol {symbols} draws {inked} pixels");
        }
        let (inked, colored) = ink("\u{1F600}");
        assert!(inked > 200 && colored > 100, "emoji: {inked} pixels, {colored} colored");
        let (_, colored_text) = ink("A");
        assert_eq!(colored_text, 0, "white text stays white");
    }

    #[test]
    fn a_scalar_no_face_has_draws_as_nothing_not_as_a_no_glyph_box() {
        use crate::portable_text_renderer::PortableTextRenderer;
        use crate::text_style::TextStyle;
        use_bundled_fonts();
        PortableFallback::set_fonts(Vec::new()); // a machine without symbol or emoji fonts
        let inked = |text: &str| {
            PortableTextRenderer::render(text, &TextStyle::default(), None, None, 1.0, None)
                .map_or(0, |r| r.picture.pixels.chunks(4).filter(|px| px[3] > 0.2).count())
        };
        assert_eq!(inked("\u{1F525}"), 0, "the fire emoji without an emoji font");
        assert!(inked("A") > 50, "ordinary text still draws");
    }
}
