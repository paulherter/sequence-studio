// SPDX-License-Identifier: GPL-3.0-or-later
//! Color emoji for the UI text path: one rasterizer for the three system emoji fonts, as a premultiplied RGBA bitmap at the
//! asked pixel size.
//!
//! - Bitmap fonts (Apple Color Emoji `sbix`, Noto Color Emoji `CBDT`): the nearest strike that is not smaller than the size,
//!   PNG decoded, box-filtered down to the size. Apple's file (about 190 MB) is not loaded: only its small tables stay in
//!   memory and a glyph's PNG is read from the file when asked (`SbixFile`); Noto (10 MB) is read whole.
//! - Layered fonts (Segoe UI Emoji `COLR` v0): each layer is drawn with the outline rasterizer in its palette color.
//!
//! known limit: no shaping, so a ZWJ family, a skin tone or a flag draws as its parts; `COLR` v1 paint graphs (gradients,
//! transforms) are not read, only the v0 layer records Segoe keeps for every glyph (see `sfnt_color_glyphs`).

use crate::glyph_raster::GlyphRasterFont;
use crate::sbix_file::SbixFile;
use crate::sfnt_face::SfntFace;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use ttf_parser::{Face, GlyphId, RasterImageFormat};

/// A color glyph at one size: premultiplied RGBA rows top to bottom. `left`/`top` place it from the pen on the baseline,
/// as [`crate::glyph_raster::GlyphBitmap`] does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColorBitmap {
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
    /// Offset of the left column from the pen.
    pub left: i64,
    /// Offset of the top row above the baseline.
    pub top: i64,
    /// Premultiplied RGBA, 4 bytes a pixel.
    pub rgba: Vec<u8>,
}

enum Source {
    /// The whole file and the face number in it (ttf-parser reads the strikes).
    Bitmap {
        data: Vec<u8>,
        index: u32,
    },
    /// An `sbix` file read by range.
    Sbix(Box<SbixFile>),
    Layers(Box<GlyphRasterFont>),
}

impl std::fmt::Debug for EmojiFont {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EmojiFont").field("units_per_em", &self.units_per_em).finish_non_exhaustive()
    }
}

/// A color emoji font, opened lazily by the glyph atlas.
pub struct EmojiFont {
    source: Source,
    /// The GSUB reader of a `Bitmap` font (its data parsed a second time, on the first emoji sequence only).
    sequences: OnceLock<Option<SfntFace>>,
    /// Font units per em.
    pub units_per_em: i64,
}

impl EmojiFont {
    /// Opens a font file (`path#n` names face `n` of a collection); `None` when it holds no color glyphs.
    pub fn from_path(path: &Path) -> Option<EmojiFont> {
        let (file, index) = crate::system_fonts::split_face(path);
        if SbixFile::is_sbix(&file, index) {
            let sbix = SbixFile::open(&file, index)?;
            let units_per_em = i64::from(sbix.face()?.units_per_em());
            return Some(EmojiFont { source: Source::Sbix(Box::new(sbix)), sequences: OnceLock::new(), units_per_em });
        }
        Self::new(std::fs::read(file).ok()?, index)
    }

    /// Parses font number `index` of `data`.
    pub fn new(data: Vec<u8>, index: u32) -> Option<EmojiFont> {
        let (bitmap, upem) = {
            let face = Face::parse(&data, index).ok()?;
            let t = face.tables();
            (t.sbix.is_some() || t.cbdt.is_some(), i64::from(face.units_per_em()))
        };
        if bitmap {
            return Some(EmojiFont {
                source: Source::Bitmap { data, index },
                sequences: OnceLock::new(),
                units_per_em: upem,
            });
        }
        let font = GlyphRasterFont::new_face(data, index)?;
        font.face.color_glyphs()?;
        Some(EmojiFont {
            units_per_em: font.units_per_em,
            sequences: OnceLock::new(),
            source: Source::Layers(Box::new(font)),
        })
    }

    /// Whether the glyphs are stored as bitmaps (`sbix`, `CBDT`), which no outline fallback face can draw.
    pub fn is_bitmap(&self) -> bool {
        matches!(self.source, Source::Bitmap { .. } | Source::Sbix(_))
    }

    /// Bytes of font data held in memory.
    #[cfg(test)]
    pub(crate) fn resident_bytes(&self) -> usize {
        match &self.source {
            Source::Bitmap { data, .. } => data.len(),
            Source::Sbix(f) => f.resident_bytes(),
            Source::Layers(_) => 0, // not measured: only the sbix path is checked
        }
    }

    /// Glyph index of a character; 0 when the font has no color image for it (Segoe and Apple also hold plain text glyphs
    /// of letters and digits, which the UI's own faces draw).
    pub fn glyph_for(&self, c: char) -> i64 {
        match &self.source {
            Source::Bitmap { data, index } => Face::parse(data, *index)
                .ok()
                .and_then(|f| {
                    let g = f.glyph_index(c)?;
                    f.glyph_raster_image(g, 160).map(|_| i64::from(g.0))
                })
                .unwrap_or(0),
            Source::Sbix(f) => f
                .face()
                .and_then(|face| {
                    let g = face.glyph_index(c)?;
                    f.image(g.0, 160, true).map(|_| i64::from(g.0))
                })
                .unwrap_or(0),
            Source::Layers(font) => {
                let g = font.glyph_for(c);
                if font.face.color_glyphs().is_some_and(|l| l.layers(g).is_some()) { g } else { 0 }
            }
        }
    }

    /// The glyphs the font draws for an emoji sequence (ZWJ family, skin tone, flag, keycap), made by its GSUB: one glyph
    /// (a ligature), or several that differ from the plain characters' glyphs (Segoe composes a family of small overlapping
    /// parts, each placed by its own advance). Every glyph has a color image; else `None` (the caller draws the parts).
    /// Apple's `sbix` font keeps its ligatures in `morx`: the installed shaper answers one glyph, see
    /// [`install_emoji_sequence_shaper`].
    pub fn sequence_glyphs(&self, chars: &[char]) -> Option<Vec<i64>> {
        let face: &SfntFace = match &self.source {
            Source::Layers(font) => &font.face,
            Source::Bitmap { data, index } => {
                self.sequences.get_or_init(|| SfntFace::new_face(data.clone(), *index)).as_ref()?
            }
            Source::Sbix(_) => {
                let g = i64::from(SHAPED.get_or_init(Default::default).glyph(chars, SHAPER.get().copied())?);
                return self.has_image(g).then(|| vec![g]);
            }
        };
        let subst = face.substitution()?;
        // A font may expect the text of a sequence without its U+FE0F: try both.
        let with: Vec<char> = chars.to_vec();
        let without: Vec<char> = chars.iter().copied().filter(|&c| c != '\u{FE0F}').collect();
        for seq in [with, without] {
            let plain: Vec<i64> = seq.iter().map(|&c| face.glyph_for(c)).collect();
            if plain.contains(&0) {
                continue;
            }
            let out = subst.apply(&plain);
            if out != plain && !out.contains(&0) && out.iter().all(|&g| self.has_image(g)) {
                return Some(out);
            }
        }
        None
    }

    /// Whether the font draws glyph `g` in color.
    fn has_image(&self, g: i64) -> bool {
        let Ok(id) = u16::try_from(g) else { return false };
        match &self.source {
            Source::Bitmap { data, index } => {
                Face::parse(data, *index).ok().is_some_and(|f| f.glyph_raster_image(GlyphId(id), 160).is_some())
            }
            Source::Sbix(f) => f.image(id, 160, true).is_some(),
            Source::Layers(font) => font.face.color_glyphs().is_some_and(|l| l.layers(g).is_some()),
        }
    }

    /// Advance of a glyph in font units.
    pub fn advance(&self, glyph: i64) -> i64 {
        match &self.source {
            Source::Bitmap { data, index } => Face::parse(data, *index)
                .ok()
                .and_then(|f| f.glyph_hor_advance(GlyphId(glyph as u16)))
                .map_or(0, i64::from),
            Source::Sbix(f) => f.face().and_then(|f| f.glyph_hor_advance(GlyphId(glyph as u16))).map_or(0, i64::from),
            Source::Layers(font) => font.advance(glyph),
        }
    }

    /// The glyph at `px` pixels per em; `None` when it has no color image.
    pub fn rasterize(&self, glyph: i64, px: f64) -> Option<ColorBitmap> {
        if px <= 0.0 || !(0..=i64::from(u16::MAX)).contains(&glyph) {
            return None;
        }
        match &self.source {
            Source::Bitmap { data, index } => {
                let face = Face::parse(data, *index).ok()?;
                let img = face.glyph_raster_image(GlyphId(glyph as u16), px.ceil() as u16)?;
                if img.format != RasterImageFormat::PNG || img.pixels_per_em == 0 {
                    return None;
                }
                finish(img.data, img.x, img.y, img.pixels_per_em, px)
            }
            Source::Sbix(f) => {
                let img = f.image(glyph as u16, px.ceil() as u16, false)?;
                finish(&img.png, img.x, img.y, img.ppem, px)
            }
            Source::Layers(font) => layered(font, glyph, px),
        }
    }
}

/// A stored PNG placed at `(x, y)` in a strike of `ppem`, drawn at `px`.
/// The host's shaper for emoji sequences: the text of a cluster to the one glyph the platform's emoji font draws for it
/// (`None` when it draws several). Apple Color Emoji keeps its ligatures in `morx`, which only CoreText reads: the Mac app
/// installs a CoreText shaper (sq-platform-mac) at startup. Without one an `sbix` font draws the parts.
static SHAPER: OnceLock<fn(&str) -> Option<u16>> = OnceLock::new();

/// Installs the sequence shaper (the first call wins).
pub fn install_emoji_sequence_shaper(f: fn(&str) -> Option<u16>) {
    let _ = SHAPER.set(f);
}

/// The shaper's answers per cluster text, so drawing never shapes a cluster twice.
#[derive(Default)]
struct ShapeCache(Mutex<HashMap<String, Option<u16>>>);

impl ShapeCache {
    fn glyph(&self, chars: &[char], shaper: Option<fn(&str) -> Option<u16>>) -> Option<u16> {
        let shaper = shaper?;
        let text: String = chars.iter().collect();
        let mut cache = self.0.lock().ok()?;
        *cache.entry(text.clone()).or_insert_with(|| shaper(&text))
    }
}

static SHAPED: OnceLock<ShapeCache> = OnceLock::new();

fn finish(png: &[u8], x: i16, y: i16, ppem: u16, px: f64) -> Option<ColorBitmap> {
    let (w, h, rgba) = decode_png(png)?;
    Some(scale_image(&rgba, w, h, f64::from(x), f64::from(y), px / f64::from(ppem)))
}

/// PNG to straight-alpha RGBA8: (width, height, pixels).
fn decode_png(data: &[u8]) -> Option<(usize, usize, Vec<u8>)> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(data));
    dec.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let (w, h) = (info.width as usize, info.height as usize);
    let src = &buf[..info.buffer_size()];
    let mut out = Vec::with_capacity(w * h * 4);
    match info.color_type {
        png::ColorType::Rgba => out.extend_from_slice(src),
        png::ColorType::Rgb => {
            let (px, _) = src.as_chunks::<3>();
            px.iter().for_each(|p| out.extend_from_slice(&[p[0], p[1], p[2], 255]));
        }
        png::ColorType::GrayscaleAlpha => {
            let (px, _) = src.as_chunks::<2>();
            px.iter().for_each(|p| out.extend_from_slice(&[p[0], p[0], p[0], p[1]]));
        }
        png::ColorType::Grayscale => src.iter().for_each(|&g| out.extend_from_slice(&[g, g, g, 255])),
        png::ColorType::Indexed => return None,
    }
    (out.len() == w * h * 4).then_some((w, h, out))
}

/// The source pixels a span `[s0, s1)` of the source axis covers and by how much (source pixels), clipped to `0..n`.
fn cover(s0: f64, s1: f64, n: usize) -> Vec<(usize, f32)> {
    let (s0, s1) = (s0.max(0.0), s1.min(n as f64));
    let mut v = Vec::new();
    let mut i = s0.floor() as usize;
    while (i as f64) < s1 {
        let w = (s1.min((i + 1) as f64) - s0.max(i as f64)) as f32;
        if w > 0.0 {
            v.push((i, w));
        }
        i += 1;
    }
    v
}

/// Straight RGBA8 `w` x `h` placed with its left edge `ox` and bottom edge `oy` (pixels at the source scale) from the pen
/// on the baseline, scaled by `scale` with a box filter. The result is premultiplied.
fn scale_image(rgba: &[u8], w: usize, h: usize, ox: f64, oy: f64, scale: f64) -> ColorBitmap {
    let (left_f, right_f) = (ox * scale, (ox + w as f64) * scale);
    let (bottom_f, top_f) = (oy * scale, (oy + h as f64) * scale);
    let dl = left_f.floor() as i64;
    let dr = (right_f.ceil() as i64).max(dl + 1);
    let db = bottom_f.floor() as i64;
    let dt = (top_f.ceil() as i64).max(db + 1);
    let (dw, dh) = ((dr - dl) as usize, (dt - db) as usize);
    // Destination column `i` spans [dl+i, dl+i+1) on the x axis; row `j` (from the top) spans [dt-1-j, dt-j) on the y-up axis,
    // which reads source rows from the top edge `top_f`.
    let cols: Vec<_> = (0..dw)
        .map(|i| cover(((dl + i as i64) as f64 - left_f) / scale, ((dl + i as i64 + 1) as f64 - left_f) / scale, w))
        .collect();
    let mut out = vec![0u8; dw * dh * 4];
    let norm = (scale * scale) as f32;
    for j in 0..dh {
        let (lo, hi) = ((dt - 1 - j as i64) as f64, (dt - j as i64) as f64);
        let ys = cover((top_f - hi) / scale, (top_f - lo) / scale, h);
        for (i, xs) in cols.iter().enumerate() {
            let mut acc = [0f32; 4];
            for &(r, wy) in &ys {
                for &(c, wx) in xs {
                    let p = &rgba[(r * w + c) * 4..][..4];
                    let a = f32::from(p[3]) / 255.0;
                    let k = wx * wy;
                    acc[0] += f32::from(p[0]) * a * k;
                    acc[1] += f32::from(p[1]) * a * k;
                    acc[2] += f32::from(p[2]) * a * k;
                    acc[3] += 255.0 * a * k;
                }
            }
            let d = &mut out[(j * dw + i) * 4..][..4];
            for (d, a) in d.iter_mut().zip(acc) {
                *d = (a * norm).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    ColorBitmap { width: dw as i64, height: dh as i64, left: dl, top: dt, rgba: out }
}

/// A `COLR` v0 glyph: its layers, each a coverage bitmap in a palette color, stacked bottom first.
fn layered(font: &GlyphRasterFont, glyph: i64, px: f64) -> Option<ColorBitmap> {
    let layers = font.face.color_glyphs()?.layers(glyph)?;
    let parts: Vec<_> = layers
        .iter()
        .map(|l| (font.rasterize(l.glyph, px), l.color))
        .filter(|(b, _)| b.width > 0 && b.height > 0)
        .collect();
    let left = parts.iter().map(|(b, _)| b.left).min()?;
    let top = parts.iter().map(|(b, _)| b.top).max()?;
    let right = parts.iter().map(|(b, _)| b.left + b.width).max()?;
    let bottom = parts.iter().map(|(b, _)| b.top - b.height).min()?;
    let (w, h) = ((right - left) as usize, (top - bottom) as usize);
    let mut canvas = vec![0f32; w * h * 4];
    for (b, color) in &parts {
        // shortcut: a layer in the text color (palette 0xFFFF) draws black; the UI text color is not known here.
        let c = color.map_or([0.0, 0.0, 0.0, 1.0], |c| [c.red as f32, c.green as f32, c.blue as f32, c.alpha as f32]);
        for row in 0..b.height as usize {
            let y = (top - b.top) as usize + row;
            for col in 0..b.width as usize {
                let a = f32::from(b.coverage[row * b.width as usize + col]) / 255.0 * c[3];
                if a <= 0.0 {
                    continue;
                }
                let d = &mut canvas[(y * w + (b.left - left) as usize + col) * 4..][..4];
                for k in 0..3 {
                    d[k] = c[k] * a + d[k] * (1.0 - a);
                }
                d[3] = a + d[3] * (1.0 - a);
            }
        }
    }
    let rgba = canvas.iter().map(|v| (v * 255.0).round().clamp(0.0, 255.0) as u8).collect();
    Some(ColorBitmap { width: w as i64, height: h as i64, left, top, rgba })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The test fonts folder (`SQ_TEST_EMOJI_FONTS`): `AppleColorEmoji.ttc`, `NotoColorEmoji.ttf`, `seguiemj.ttf`.
    /// Font-dependent tests skip when it or a file is missing.
    pub(crate) fn test_fonts() -> Vec<(&'static str, EmojiFont)> {
        let Some(dir) = std::env::var_os("SQ_TEST_EMOJI_FONTS") else { return Vec::new() };
        ["AppleColorEmoji.ttc", "NotoColorEmoji.ttf", "seguiemj.ttf"]
            .into_iter()
            .filter_map(|n| EmojiFont::from_path(&Path::new(&dir).join(n)).map(|f| (n, f)))
            .collect()
    }

    static SHAPER_CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    fn fake_shaper(text: &str) -> Option<u16> {
        SHAPER_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        (text.chars().count() == 3).then_some(777)
    }

    /// The seam of the `sbix` path (an sbix font cannot be built in a test): the injected shaper's glyph comes back, each
    /// cluster is shaped once, and without a shaper there is no glyph (the parts draw).
    #[test]
    fn the_injected_shaper_answers_once_per_cluster() {
        let cache = ShapeCache::default();
        let family: Vec<char> = "\u{1F44D}\u{1F3FD}\u{200D}".chars().collect();
        assert_eq!(cache.glyph(&family, Some(fake_shaper)), Some(777));
        assert_eq!(cache.glyph(&family, Some(fake_shaper)), Some(777));
        assert_eq!(SHAPER_CALLS.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(cache.glyph(&['a', 'b'], Some(fake_shaper)), None);
        assert_eq!(cache.glyph(&family, None), None, "no shaper installed");
        assert_eq!(ShapeCache::default().glyph(&family, None), None);
    }

    #[test]
    fn box_filter_halves_a_solid_square_and_keeps_alpha_at_the_edge() {
        // 4x4 opaque red, left edge at 0, bottom edge on the baseline, half size: 2x2 solid red.
        let img: Vec<u8> = std::iter::repeat_n([255u8, 0, 0, 255], 16).flatten().collect();
        let b = scale_image(&img, 4, 4, 0.0, 0.0, 0.5);
        assert_eq!((b.width, b.height, b.left, b.top), (2, 2, 0, 2));
        assert!(b.rgba.chunks(4).all(|p| p == [255, 0, 0, 255]));
        // Shifted by half a destination pixel: the edge pixels are half covered (premultiplied: alpha and red agree).
        let b = scale_image(&img, 4, 4, 1.0, 0.0, 0.5);
        assert_eq!((b.width, b.left), (3, 0));
        assert_eq!(b.rgba[0..4], [128, 0, 0, 128]);
    }

    #[test]
    fn png_decodes_to_straight_rgba() {
        let mut data = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut data, 2, 1);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().unwrap().write_image_data(&[10, 20, 30, 40, 1, 2, 3, 255]).unwrap();
        }
        assert_eq!(decode_png(&data), Some((2, 1, vec![10, 20, 30, 40, 1, 2, 3, 255])));
        assert_eq!(decode_png(b"nope"), None);
    }

    #[test]
    fn apple_sbix_stays_small_in_memory_and_draws_the_same_as_the_whole_file() {
        let Some(dir) = std::env::var_os("SQ_TEST_EMOJI_FONTS") else { return };
        let path = Path::new(&dir).join("AppleColorEmoji.ttc");
        let Some(font) = EmojiFont::from_path(&path) else { return };
        assert!(matches!(font.source, Source::Sbix(_)));
        let resident = font.resident_bytes();
        sq_os::errln!("sbix resident bytes: {resident}");
        assert!(resident < 5_000_000, "resident {resident}");
        let data = std::fs::read(&path).unwrap();
        let face = Face::parse(&data, 0).unwrap();
        for c in ['\u{1F600}', '\u{1F680}', '\u{2764}'] {
            let g = font.glyph_for(c);
            assert!(g > 0, "{c}");
            assert_eq!(font.advance(g), face.glyph_hor_advance(GlyphId(g as u16)).map_or(0, i64::from));
            for px in [16.0, 28.0] {
                let img = face.glyph_raster_image(GlyphId(g as u16), px as u16).unwrap();
                let want = finish(img.data, img.x, img.y, img.pixels_per_em, px);
                assert!(want.is_some() && font.rasterize(g, px) == want, "{c} @{px}");
            }
        }
    }

    /// Glyph ids read independently from Apple's `cmap` (format 12) and every emoji of the font drawn like the whole-file path.
    #[test]
    fn apple_emoji_glyphs_match_the_cmap_and_the_whole_file_for_every_emoji() {
        let Some(dir) = std::env::var_os("SQ_TEST_EMOJI_FONTS") else { return };
        let path = Path::new(&dir).join("AppleColorEmoji.ttc");
        let Some(font) = EmojiFont::from_path(&path) else { return };
        let data = std::fs::read(&path).unwrap();
        let face = Face::parse(&data, 0).unwrap();
        for (c, want) in [('\u{1F4B8}', 1847), ('\u{1F4E4}', 1891), ('\u{1F914}', 2521), ('\u{1F4F8}', 1911)] {
            assert_eq!(font.glyph_for(c), want, "{c:?}");
        }
        let mut bad = Vec::new();
        for cp in 0x2190u32..0x1FAFF {
            let Some(c) = char::from_u32(cp) else { continue };
            let g = font.glyph_for(c);
            let whole = face.glyph_index(c).filter(|g| face.glyph_raster_image(*g, 160).is_some());
            if whole.map_or(0, |g| i64::from(g.0)) != g {
                bad.push(format!("{c:?} sbix {g} whole {whole:?}"));
                continue;
            }
            if g > 0
                && font.rasterize(g, 28.0)
                    != face
                        .glyph_raster_image(GlyphId(g as u16), 28)
                        .and_then(|i| finish(i.data, i.x, i.y, i.pixels_per_em, 28.0))
            {
                bad.push(format!("{c:?} pixels differ"));
            }
        }
        assert!(bad.is_empty(), "{} differ: {:?}", bad.len(), &bad[..bad.len().min(20)]);
    }

    #[test]
    fn a_missing_font_file_opens_nothing() {
        assert!(EmojiFont::from_path(Path::new("/nonexistent/emoji.ttf")).is_none());
    }

    #[test]
    fn system_emoji_fonts_draw_color_at_the_text_size() {
        for (name, font) in test_fonts() {
            let g = font.glyph_for('\u{1F600}');
            assert!(g > 0, "{name}: no glyph for U+1F600");
            for px in [12.0, 16.0, 28.0] {
                let b = font.rasterize(g, px).unwrap_or_else(|| panic!("{name}: no bitmap at {px}"));
                assert_eq!(b.rgba.len() as i64, b.width * b.height * 4, "{name}");
                // The face is one to 1.25 em tall (Noto's art is 1.17 em) and inside its advance (Apple 1 em, Noto 1.25 em, Segoe 1.33 em).
                let adv = (font.advance(g) as f64 * px / font.units_per_em as f64).round() as i64;
                sq_os::errln!("{name} @{px}: {}x{} advance {adv} left {} top {}", b.width, b.height, b.left, b.top);
                assert!(
                    b.height as f64 >= px - 1.0 && b.height as f64 <= px * 1.25 + 1.0,
                    "{name} @{px}: height {}",
                    b.height
                );
                assert!(
                    b.left + b.width <= adv + 1 && b.width >= px as i64 - 1,
                    "{name} @{px}: width {} adv {adv}",
                    b.width
                );
                // Real color: some opaque pixel is far from gray; an alpha edge: the corners are transparent.
                let colorful =
                    b.rgba.chunks(4).any(|p| p[3] > 200 && p[0].max(p[1]).max(p[2]) - p[0].min(p[1]).min(p[2]) > 60);
                assert!(colorful, "{name} @{px}: gray");
                assert_eq!(b.rgba[3], 0, "{name} @{px}: corner not transparent");
                assert!(b.rgba.chunks(4).any(|p| p[3] > 0 && p[3] < 255), "{name} @{px}: no soft edge");
                // Sits on the baseline: the bitmap reaches from about the descent to above the baseline.
                assert!(b.top > 0 && b.top - b.height <= 0, "{name} @{px}: top {} height {}", b.top, b.height);
            }
        }
    }
}
