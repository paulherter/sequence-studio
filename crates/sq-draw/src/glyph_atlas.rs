//! Glyph coverage packed into one 8-bit page (Swift `GlyphAtlas`): shelf packed, glyphs on whole pixels, so the GPU and
//! the software renderer read the same texels without filtering. One atlas per display scale (the size key is in pixels);
//! the renderer uploads only the dirty rect. Single-threaded UI object: state is behind a `RefCell`.
//!
//! Faces: 0 is the UI font; [`GlyphAtlas::face_for`] adds another font (look and template previews). A character the face
//! lacks draws from the bundled Inter at the same weight, so symbol keys render alike on every system.
//!
//! Color emoji: a scalar no UI face has draws from the system color emoji font ([`EmojiFont`]), opened on the first one.
//! They are not in the coverage page (it is one channel): [`GlyphAtlas::color_runs`] gives a glyph as runs of equal color
//! that the draw list fills as pixel-aligned quads, so every renderer (GPU, software) draws them without a new texture or shader.
//! shortcut: one quad per run of equal-colored pixels (about 100 to 250 for a 14 px emoji); upgrade to a color page and a
//! shader kind if a screen of hundreds of emoji ever shows in the frame time.
//! shortcut: no shaping: a ZWJ sequence, a skin tone or a flag draws as its parts (the joiner and U+FE0F draw nothing).
//! shortcut: a full page is wiped and refilled (no eviction); upgrade when UI text outgrows one 1024x1024 page.

use crate::draw_list::{Color, DrawList, Rect};
use sq_os::Platform;
use sq_text::emoji_font::EmojiFont;
use sq_text::fallback_font_files::{FallbackFontFiles, FallbackRole};
use sq_text::glyph_raster::GlyphRasterFont;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

/// Where a glyph sits on the page and how it hangs off the pen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Page x of the cell.
    pub x: u32,
    /// Page y of the cell.
    pub y: u32,
    /// Cell width (0: no ink).
    pub w: u32,
    /// Cell height.
    pub h: u32,
    /// Offset of the left column from the pen.
    pub left: i32,
    /// Pixels the top row sits above the baseline.
    pub top: i32,
}

/// `Metric::face` of a color emoji (its glyph index is the emoji font's) and of an invisible joiner (glyph 0).
pub const COLOR_FACE: usize = usize::MAX;

/// A run of `len` pixels of one straight-alpha color: row `y` and column `x` of a color glyph's bitmap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColorRun {
    /// Column of the first pixel.
    pub x: u32,
    /// Row from the top.
    pub y: u32,
    /// Pixels in the run.
    pub len: u32,
    /// The color (straight alpha, sRGB code values).
    pub color: Color,
}

/// A color glyph at one size: its runs and where its bitmap hangs off the pen.
#[derive(Debug, PartialEq)]
pub struct ColorGlyph {
    /// Offset of the left column from the pen.
    pub left: i32,
    /// Pixels the top row sits above the baseline.
    pub top: i32,
    /// Rows of the bitmap.
    pub height: u32,
    /// The runs, rows top to bottom.
    pub runs: Vec<ColorRun>,
}

/// More color glyphs than this are dropped from the cache (they are rasterized again on the next use).
const COLOR_CACHE: usize = 2048;

/// A scalar that follows an emoji and draws nothing: the emoji and text variation selectors and the zero width joiner.
fn is_invisible(c: char) -> bool {
    matches!(c, '\u{FE0E}' | '\u{FE0F}' | '\u{200D}')
}

/// A scalar that continues the cluster before it: a variation selector, the joiner, the keycap, a skin tone, a tag.
fn is_cluster_extend(c: char) -> bool {
    matches!(c as u32, 0xFE0E | 0xFE0F | 0x200D | 0x20E3 | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F)
}

fn is_regional_indicator(c: char) -> bool {
    matches!(c as u32, 0x1F1E6..=0x1F1FF)
}

/// End (exclusive) of the emoji cluster that starts at `i`: the base, its extenders, a joined scalar after each joiner,
/// a pair of regional indicators. `i + 1` for a scalar that is no part of a sequence.
fn emoji_cluster_end(chars: &[char], i: usize) -> usize {
    let c = chars[i];
    if !(is_emoji_block(c) || is_emoji_symbol(c) || c.is_ascii_digit() || matches!(c, '#' | '*')) {
        return i + 1;
    }
    let mut j = i + 1;
    if is_regional_indicator(c) && chars.get(j).is_some_and(|&n| is_regional_indicator(n)) {
        return j + 1;
    }
    while let Some(&n) = chars.get(j) {
        if is_cluster_extend(n) {
            j += 1;
            if n == '\u{200D}' && j < chars.len() {
                j += 1;
            }
        } else {
            break;
        }
    }
    j
}

/// Where the emoji blocks start: a scalar from here on is tried in the emoji font before the script faces (which may hold
/// a monochrome outline of it).
fn is_emoji_block(c: char) -> bool {
    matches!(c as u32, 0x1F000..=0x1FAFF)
}

/// A BMP symbol the emoji font may hold (arrows, dingbats, misc symbols, a few marks), tried last so a text with some
/// unknown CJK character never opens the emoji font.
fn is_emoji_symbol(c: char) -> bool {
    matches!(
        c as u32,
        0xA9 | 0xAE | 0x203C | 0x2049 | 0x2122 | 0x2139 | 0x2190..=0x2BFF | 0x3030 | 0x303D | 0x3297 | 0x3299
    )
}

/// A character's glyph and advance (font units) in the face that holds the glyph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metric {
    /// Glyph index.
    pub glyph: i64,
    /// Advance in font units.
    pub advance: i64,
    /// Face that holds the glyph (the fallback face for a missing character; [`COLOR_FACE`] for a color emoji).
    pub face: usize,
}

/// A page region changed since the last upload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirtyRect {
    /// Left.
    pub x: u32,
    /// Top.
    pub y: u32,
    /// Width.
    pub w: u32,
    /// Height.
    pub h: u32,
}

/// Horizontal alignment of a text line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextAlign {
    /// `x` is the left edge.
    Left,
    /// `x` is the center.
    Center,
    /// `x` is the right edge.
    Right,
}

struct Face {
    font: Arc<GlyphRasterFont>,
    weight: i32,
    inter: bool,
}

/// The system script fonts: the files still to open (in order) and the faces opened so far.
struct ScriptFaces {
    pending: std::collections::VecDeque<std::path::PathBuf>,
    loaded: Vec<usize>,
}

struct State {
    pixels: Vec<u8>,
    generation: u64,
    wipes: u64,
    faces: Vec<Face>,
    entries: HashMap<(i64, i64, usize), Entry>,
    metrics: HashMap<(usize, char), Metric>,
    kerns: HashMap<(usize, i64, i64), f64>,
    fallbacks: HashMap<usize, Option<usize>>,
    /// Faces of the system's own script fonts (Hebrew, Arabic, CJK, symbols), loaded on the first character nothing else has.
    scripts: Option<ScriptFaces>,
    weighted: HashMap<i32, usize>,
    shelf: (u32, u32, u32),
    /// Changed regions with the generation that made them (the last [`DIRTY_LOG`]); every renderer reads its own part.
    dirty: Vec<(u64, DirtyRect)>,
    /// Generations up to this one are no longer in `dirty`: a reader that is older re-uploads the whole page.
    dirty_floor: u64,
    cap_ratio: Option<f32>,
    /// The color emoji font: not looked for yet (`None`), none on this machine (`Some(None)`), or opened.
    emoji: Option<Option<Arc<EmojiFont>>>,
    colors: HashMap<(i64, i64), Option<Arc<ColorGlyph>>>,
    /// Color metrics of a character before U+FE0F.
    emoji_metrics: HashMap<(usize, char), Option<Metric>>,
    /// Emoji sequences (a family, a flag) that the font draws as one glyph, by the face whose units the advance is in.
    emoji_sequences: HashMap<(usize, Vec<char>), Option<Vec<Metric>>>,
}

/// One placed scalar of a line: its glyph metric, the kerning that moves it and the pen advance after it.
struct Step {
    metric: Metric,
    kern: f32,
    advance: f32,
}

/// A label up to this many characters, of several words, follows the first-word rule of [`GlyphAtlas::fitted_label`].
const SHORT_LABEL: usize = 24;
/// One font step of a label that is too narrow for its first word, in pixels, and the smallest size it goes to.
const LABEL_STEP: f32 = 1.0;
const MIN_LABEL_PX: f32 = 8.0;

/// How many dirty regions the atlas remembers for renderers that are behind.
const DIRTY_LOG: usize = 512;

/// `text` cut to what `fits` with a trailing ellipsis, ending at a word boundary: the cut never lands inside a word that
/// has a word before it. A first word that is too long alone is broken inside, as the last resort. `None` when not even the
/// ellipsis fits. Unchanged when the whole text fits. The one text-fit rule of the UI.
pub fn fit_with_ellipsis(text: &str, fits: impl Fn(&str) -> bool) -> Option<String> {
    let out = fit_with_ellipsis_inner(text, fits);
    if let Some(o) = &out
        && o != text
    {
        crate::text_log::note_cut(text, o);
    }
    out
}

fn fit_with_ellipsis_inner(text: &str, fits: impl Fn(&str) -> bool) -> Option<String> {
    if fits(text) {
        return Some(text.to_string());
    }
    let chars: Vec<char> = text.chars().collect();
    let cut = |n: usize| format!("{}\u{2026}", chars[..n].iter().collect::<String>().trim());
    let Some(mut n) = (1..chars.len()).rev().find(|&n| fits(&cut(n))) else {
        return fits("\u{2026}").then(|| "\u{2026}".to_string());
    };
    if !chars[n].is_whitespace() && !chars[n - 1].is_whitespace() {
        // Inside a word: back up to the end of the word before, when there is one.
        if let Some(i) = chars[..n].iter().rposition(|c| c.is_whitespace())
            && chars[..i].iter().any(|c| !c.is_whitespace())
        {
            n = i;
        }
    }
    // Never cut inside an emoji sequence (the part left over would draw as its pieces).
    while n > 1 && (is_cluster_extend(chars[n]) || chars[n - 1] == '\u{200D}') {
        n -= 1;
    }
    Some(cut(n))
}

/// Whether `text` is a short label of several words whose first word does not `fit`: the case the drawing handles itself
/// ([`GlyphAtlas::fitted_label`]: one font step smaller, else hidden), so a caller must not cut it inside the word first.
pub fn first_word_overflows(text: &str, fits: impl Fn(&str) -> bool) -> bool {
    let mut words = text.split_whitespace();
    let first = words.next().unwrap_or_default();
    text.chars().count() <= SHORT_LABEL && words.next().is_some() && !fits(first)
}

/// Whether `shown` (a [`fit_with_ellipsis`] result for `original`) ends inside a word that has a word before it.
pub fn cuts_mid_word(original: &str, shown: &str) -> bool {
    let Some(prefix) = shown.strip_suffix('\u{2026}') else { return false };
    let Some(rest) = original.strip_prefix(prefix) else { return true };
    let has_word_before = prefix.trim().chars().any(char::is_whitespace);
    has_word_before && !rest.is_empty() && !rest.starts_with(char::is_whitespace)
}

/// The glyph page and the text metrics that go with it.
pub struct GlyphAtlas {
    size: u32,
    point_scale: Cell<f32>,
    inter: Option<Arc<GlyphRasterFont>>,
    st: RefCell<State>,
}

impl GlyphAtlas {
    /// More faces than this fall back to the UI face.
    pub const MAX_FACES: usize = 16;
    /// Page edge in pixels.
    pub const PAGE: u32 = 1024;

    /// An atlas whose face 0 is `font`; `inter` is the regular bundled Inter missing characters fall back to (`font` itself
    /// when it is Inter: pass `None` then and mark it with [`GlyphAtlas::inter`]).
    pub fn new(font: GlyphRasterFont, inter: Option<GlyphRasterFont>) -> GlyphAtlas {
        Self::build(font, inter.map(Arc::new), false)
    }

    /// The shared UI's atlas: the Mac system font (San Francisco, with Inter for missing characters) on macOS, as Swift's
    /// `GlyphAtlas(font: GlyphRasterFont.macSystemUI ?? .inter)` (`SharedUIController.swift:199`); the bundled Inter
    /// elsewhere or when the system font does not load.
    pub fn ui(fonts_root: &std::path::Path) -> Option<GlyphAtlas> {
        let inter = GlyphRasterFont::inter(fonts_root)?;
        // `SQ_UI_FONT=inter` draws the bundled Inter on the Mac too: how Linux and Windows lay text out, for parity shots.
        let system = if std::env::var("SQ_UI_FONT").is_ok_and(|v| v == "inter") {
            None
        } else {
            GlyphRasterFont::mac_system_ui()
        };
        match system {
            Some(system) => Some(Self::new(system, Some(inter))),
            None => Some(Self::build(inter, None, true)),
        }
    }

    /// An atlas of the bundled Inter from `fonts_root` (the package's `Resources/Fonts`).
    pub fn inter(fonts_root: &std::path::Path) -> Option<GlyphAtlas> {
        Some(Self::build(GlyphRasterFont::inter(fonts_root)?, None, true))
    }

    /// An atlas of Inter from the bytes of its variable font file: for a program that carries the font inside itself (the
    /// setup program has no fonts folder next to it).
    pub fn inter_bytes(file: Vec<u8>) -> Option<GlyphAtlas> {
        Some(Self::build(GlyphRasterFont::new(file)?, None, true))
    }

    fn build(font: GlyphRasterFont, inter: Option<Arc<GlyphRasterFont>>, is_inter: bool) -> GlyphAtlas {
        let font = Arc::new(font);
        let inter = if is_inter { Some(Arc::clone(&font)) } else { inter };
        let st = State {
            pixels: vec![0; (Self::PAGE * Self::PAGE) as usize],
            generation: 0,
            wipes: 0,
            faces: vec![Face { font, weight: 400, inter: is_inter }],
            entries: HashMap::new(),
            metrics: HashMap::new(),
            kerns: HashMap::new(),
            fallbacks: HashMap::new(),
            scripts: None,
            weighted: HashMap::new(),
            shelf: (1, 1, 0),
            dirty: Vec::new(),
            dirty_floor: 0,
            cap_ratio: None,
            emoji: None,
            colors: HashMap::new(),
            emoji_metrics: HashMap::new(),
            emoji_sequences: HashMap::new(),
        };
        GlyphAtlas { size: Self::PAGE, point_scale: Cell::new(1.0), inter, st: RefCell::new(st) }
    }

    /// Page edge in pixels.
    pub fn size(&self) -> u32 {
        self.size
    }
    /// Device pixels per point of the window (the system font's tracking depends on the point size); 1 until set.
    pub fn point_scale(&self) -> f32 {
        self.point_scale.get()
    }
    /// Sets [`point_scale`](Self::point_scale).
    pub fn set_point_scale(&self, s: f32) {
        self.point_scale.set(s);
    }
    /// Bumped whenever the page changed (the renderer re-uploads the dirty rect).
    pub fn generation(&self) -> u64 {
        self.st.borrow().generation
    }
    /// Counts the times a full page was wiped: quads built before it point at cells that no longer hold those glyphs.
    pub fn wipes(&self) -> u64 {
        self.st.borrow().wipes
    }
    /// Reads the page (rows of `size` bytes).
    pub fn with_pixels<R>(&self, f: impl FnOnce(&[u8]) -> R) -> R {
        f(&self.st.borrow().pixels)
    }
    /// The region that changed after generation `seen` (union of the cells since), or the whole page when `seen` is older
    /// than the log keeps. Every renderer (the window and each floating window share one atlas) asks with its own last
    /// seen generation, so one drawing first never hides a glyph from the others.
    pub fn dirty_since(&self, seen: u64) -> Option<DirtyRect> {
        let st = self.st.borrow();
        if seen == st.generation {
            return None;
        }
        if seen < st.dirty_floor {
            return Some(DirtyRect { x: 0, y: 0, w: self.size, h: self.size });
        }
        st.dirty.iter().filter(|(g, _)| *g > seen).map(|(_, r)| *r).reduce(Self::union)
    }

    fn union(d: DirtyRect, cell: DirtyRect) -> DirtyRect {
        let (x0, y0) = (d.x.min(cell.x), d.y.min(cell.y));
        let (x1, y1) = ((d.x + d.w).max(cell.x + cell.w), (d.y + d.h).max(cell.y + cell.h));
        DirtyRect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }

    fn mark_dirty(st: &mut State, rect: DirtyRect) {
        st.generation += 1;
        let g = st.generation;
        st.dirty.push((g, rect));
        if st.dirty.len() > DIRTY_LOG {
            let (floor, _) = st.dirty.remove(0);
            st.dirty_floor = floor;
        }
    }
    /// Number of faces baked in.
    pub fn face_count(&self) -> usize {
        self.st.borrow().faces.len()
    }

    /// The face index of `font` (added on first use); 0 once [`MAX_FACES`](Self::MAX_FACES) are in.
    pub fn face_for(&self, font: &Arc<GlyphRasterFont>) -> usize {
        self.add_face(font, 400, false)
    }

    fn add_face(&self, font: &Arc<GlyphRasterFont>, weight: i32, inter: bool) -> usize {
        let mut st = self.st.borrow_mut();
        if let Some(i) = st.faces.iter().position(|f| Arc::ptr_eq(&f.font, font)) {
            return i;
        }
        if st.faces.len() >= Self::MAX_FACES {
            return 0;
        }
        st.faces.push(Face { font: Arc::clone(font), weight, inter });
        st.faces.len() - 1
    }

    fn weighted_face(&self, weight: i32) -> usize {
        let (base, inter) = {
            let st = self.st.borrow();
            if let Some(i) = st.weighted.get(&weight) {
                return *i;
            }
            (Arc::clone(&st.faces[0].font), st.faces[0].inter)
        };
        let i = match base.instance_weight(weight as f64) {
            Some(f) => self.add_face(&Arc::new(f), weight, inter),
            None => 0,
        };
        self.st.borrow_mut().weighted.insert(weight, i);
        i
    }

    /// The face of the UI font's SemiBold (panel, card and empty-state titles); the UI face without a weight axis.
    pub fn semibold_face(&self) -> usize {
        self.weighted_face(600)
    }
    /// The face of the UI font's Medium (tab titles, clip names, the Export button); the UI face without a weight axis.
    pub fn medium_face(&self) -> usize {
        self.weighted_face(500)
    }

    fn fallback_of(&self, st: &mut State, f: usize) -> Option<usize> {
        if let Some(known) = st.fallbacks.get(&f) {
            return *known;
        }
        let mut answer = None;
        if let (false, Some(inter)) = (st.faces[f].inter, &self.inter) {
            let w = st.faces[f].weight;
            let weight = if w >= 600 {
                600
            } else if w >= 500 {
                500
            } else {
                400
            };
            let font = if weight == 400 {
                Some(Arc::clone(inter))
            } else {
                inter.instance_weight(weight as f64).map(Arc::new)
            };
            if let Some(font) = font {
                let i = match st.faces.iter().position(|x| Arc::ptr_eq(&x.font, &font)) {
                    Some(i) => i,
                    None if st.faces.len() < Self::MAX_FACES => {
                        st.faces.push(Face { font, weight, inter: true });
                        st.faces.len() - 1
                    }
                    None => f,
                };
                answer = (i != f).then_some(i);
            }
        }
        st.fallbacks.insert(f, answer);
        answer
    }

    /// The face missing characters of `face` draw from; `None` for Inter itself or without a bundled Inter.
    pub fn fallback_face(&self, face: usize) -> Option<usize> {
        let mut st = self.st.borrow_mut();
        self.fallback_of(&mut st, face)
    }

    /// Cap height of the UI face per em, measured once from its "H" (Inter 0.727).
    pub fn cap_height_ratio(&self) -> f32 {
        let mut st = self.st.borrow_mut();
        if let Some(r) = st.cap_ratio {
            return r;
        }
        let font = Arc::clone(&st.faces[0].font);
        let g = font.glyph_for('H');
        let h = font.rasterize(g, 200.0).height;
        let r = if g != 0 && h > 0 { h as f32 / 200.0 } else { 0.727 };
        st.cap_ratio = Some(r);
        r
    }

    fn metric(&self, st: &mut State, c: char, face: usize) -> Metric {
        let f = if face < st.faces.len() { face } else { 0 };
        if let Some(m) = st.metrics.get(&(f, c)) {
            return *m;
        }
        let font = Arc::clone(&st.faces[f].font);
        // The Mac UI sets every digit tabular (AppKit `monospacedDigitSystemFont`).
        let mut g = font.glyph_for(c);
        if c.is_ascii_digit() {
            g = font.tabular_glyph(g);
        }
        let mut m = Metric { glyph: g, advance: font.advance(g), face: f };
        let fallback = if g == 0 && c as u32 >= 0x20 { self.fallback_of(st, f) } else { None };
        if let Some(fb) = fallback {
            let other = Arc::clone(&st.faces[fb].font);
            let h = other.glyph_for(c);
            if h != 0 {
                let adv = other.advance(h) as f64 * font.units_per_em as f64 / other.units_per_em as f64;
                m = Metric { glyph: h, advance: adv.round() as i64, face: fb };
            }
        }
        if m.glyph == 0 && is_emoji_block(c) {
            m = self.color_metric(st, c, f).unwrap_or(m);
        }
        if m.glyph == 0 && c as u32 >= 0x20 && !c.is_control() {
            // Nothing in the UI faces has it (RTL, CJK, symbols): the first system script face that does. Files open one by
            // one, only as far as a glyph needs, so a screen of Latin text never reads a CJK collection.
            let primary = Arc::clone(&st.faces[f].font);
            let mut i = 0;
            while let Some(fb) = self.script_face_at(st, i) {
                let other = Arc::clone(&st.faces[fb].font);
                let h = other.glyph_for(c);
                if h != 0 {
                    let adv = other.advance(h) as f64 * primary.units_per_em as f64 / other.units_per_em as f64;
                    m = Metric { glyph: h, advance: adv.round() as i64, face: fb };
                    break;
                }
                i += 1;
            }
        }
        if m.glyph == 0 && is_emoji_symbol(c) {
            // No outline anywhere: a symbol that only the color emoji font has.
            m = self.color_metric(st, c, f).unwrap_or(m);
        }
        st.metrics.insert((f, c), m);
        m
    }

    /// The color emoji font of this machine, opened on first use; `None` when there is none.
    fn emoji_font(&self, st: &mut State) -> Option<Arc<EmojiFont>> {
        st.emoji
            .get_or_insert_with(|| {
                FallbackFontFiles::find(Platform::current(), FallbackRole::Emoji, |k| std::env::var_os(k))
                    .iter()
                    .find_map(|p| EmojiFont::from_path(p))
                    .map(Arc::new)
            })
            .clone()
    }

    /// Replaces the color emoji font (`None`: no color emoji, the tofu box stays). Tests and hosts with their own font.
    pub fn set_emoji_font(&self, font: Option<EmojiFont>) {
        let mut st = self.st.borrow_mut();
        st.emoji = Some(font.map(Arc::new));
        st.metrics.clear();
        st.colors.clear();
        st.emoji_metrics.clear();
        st.emoji_sequences.clear();
    }

    /// The color glyphs of the emoji sequence `cluster` (two or more scalars), each with its advance in the units of face
    /// `f`: one glyph (Noto, Apple) or the few parts the font composes it of (Segoe's family, with its own advances), never
    /// more than the cluster has scalars; `None` when the font has no shaping for the whole sequence (the parts draw).
    fn sequence_metric(&self, st: &mut State, cluster: &[char], f: usize) -> Option<Vec<Metric>> {
        let key = (f, cluster.to_vec());
        if let Some(m) = st.emoji_sequences.get(&key) {
            return m.clone();
        }
        let m = self.emoji_font(st).and_then(|font| {
            let glyphs = font.sequence_glyphs(cluster).filter(|g| g.len() <= cluster.len())?;
            let upem = st.faces[f].font.units_per_em;
            Some(
                glyphs
                    .into_iter()
                    .map(|g| {
                        let advance = (font.advance(g) as f64 * upem as f64 / font.units_per_em as f64).round() as i64;
                        Metric { glyph: g, advance, face: COLOR_FACE }
                    })
                    .collect(),
            )
        });
        st.emoji_sequences.insert(key, m.clone());
        m
    }

    /// `c` as a color emoji, its advance in the units of face `f`; `None` when the emoji font lacks it.
    fn color_metric(&self, st: &mut State, c: char, f: usize) -> Option<Metric> {
        let font = self.emoji_font(st)?;
        let g = font.glyph_for(c);
        if g == 0 {
            return None;
        }
        let upem = st.faces[f].font.units_per_em;
        let advance = (font.advance(g) as f64 * upem as f64 / font.units_per_em as f64).round() as i64;
        Some(Metric { glyph: g, advance, face: COLOR_FACE })
    }

    /// The metric of the `i`-th scalar of `chars` for a run: a joiner or variation selector is invisible, and a scalar
    /// followed by U+FE0F asks for its emoji look even where a UI face has a text outline of it (a heart, a sun).
    fn run_metric(&self, st: &mut State, chars: &[char], i: usize, face: usize) -> Metric {
        let c = chars[i];
        if is_invisible(c) {
            return Metric { glyph: 0, advance: 0, face: COLOR_FACE };
        }
        if chars.get(i + 1) == Some(&'\u{FE0F}') {
            let f = if face < st.faces.len() { face } else { 0 };
            let m = match st.emoji_metrics.get(&(f, c)) {
                Some(m) => *m,
                None => {
                    let m = self.color_metric(st, c, f);
                    st.emoji_metrics.insert((f, c), m);
                    m
                }
            };
            if let Some(m) = m {
                return m;
            }
        }
        self.metric(st, c, face)
    }

    /// The color glyph `glyph` of the emoji font at `px`, rasterized on first use; `None` when it has no image.
    pub fn color_glyph(&self, glyph: i64, px: f32) -> Option<Arc<ColorGlyph>> {
        let cap_center = px * self.cap_height_ratio() / 2.0;
        let mut st = self.st.borrow_mut();
        let size_key = (px * 4.0).round() as i64;
        if let Some(c) = st.colors.get(&(glyph, size_key)) {
            return c.clone();
        }
        let font = self.emoji_font(&mut st)?;
        // The bitmap's vertical center sits on the text's cap-height center (a bitmap font puts the art's bottom on the baseline
        // or near it, so the emoji rides high beside text), in whole pixels like the text's own baseline.
        let made = font.rasterize(glyph, size_key as f64 / 4.0).map(|mut b| {
            let center = b.top as f32 - b.height as f32 / 2.0;
            b.top += (cap_center - center).round() as i64;
            Arc::new(color_runs(&b))
        });
        if st.colors.len() >= COLOR_CACHE {
            st.colors.clear();
        }
        st.colors.insert((glyph, size_key), made.clone());
        made
    }

    /// Face index of the `i`-th system script font that exists and parses on this machine (Mac, Windows and Linux font
    /// folders, fontconfig on Linux), opened on demand; `None` past the last one. A file that does not parse (bitmap
    /// emoji) is skipped; with no files at all every caller gets `None` and the tofu box stays.
    fn script_face_at(&self, st: &mut State, i: usize) -> Option<usize> {
        let list = st.scripts.get_or_insert_with(|| ScriptFaces {
            pending: FallbackFontFiles::find(Platform::current(), FallbackRole::Script, |k| std::env::var_os(k)).into(),
            loaded: Vec::new(),
        });
        while list.loaded.len() <= i {
            let path = list.pending.pop_front()?;
            if st.faces.len() >= Self::MAX_FACES {
                list.pending.clear();
                return None;
            }
            if let Some(font) = GlyphRasterFont::from_path(&path) {
                st.faces.push(Face { font: Arc::new(font), weight: 400, inter: false });
                list.loaded.push(st.faces.len() - 1);
            }
        }
        list.loaded.get(i).copied()
    }

    /// A character's glyph and advance in font units of the asked face (cached).
    pub fn metric_for(&self, c: char, face: usize) -> Metric {
        let mut st = self.st.borrow_mut();
        self.metric(&mut st, c, face)
    }

    /// Walks a line: the metric of each scalar and its pen advance in pixels (advance, kerning against the glyph before
    /// it, tracking). Kerning moves this glyph; draws place it at `pen + kern`.
    fn run(&self, text: &str, px: f32, face: usize) -> Vec<Step> {
        let mut st = self.st.borrow_mut();
        let point_scale = self.point_scale.get();
        let mut out = Vec::with_capacity(text.len());
        let mut prev: Option<Metric> = None;
        let mut tracks: HashMap<usize, f32> = HashMap::new();
        // A fallback metric's advance is in the units of the asked face (see `metric`), the kerning and tracking in its own.
        let advance_scale = px / st.faces[if face < st.faces.len() { face } else { 0 }].font.units_per_em as f32;
        let chars: Vec<char> = text.chars().collect();
        let mut sequence_end = 0;
        // The glyphs of the running emoji sequence still to place: the k-th glyph rides on the k-th scalar, the scalars after
        // the last glyph are zero-width.
        let mut queued: std::collections::VecDeque<Metric> = Default::default();
        for i in 0..chars.len() {
            if i < sequence_end {
                let metric = queued.pop_front().unwrap_or(Metric { glyph: 0, advance: 0, face: COLOR_FACE });
                out.push(Step { metric, kern: 0.0, advance: metric.advance as f32 * advance_scale });
                continue;
            }
            let end = emoji_cluster_end(&chars, i);
            let whole = if end > i + 1 {
                let f = if face < st.faces.len() { face } else { 0 };
                self.sequence_metric(&mut st, &chars[i..end], f)
            } else {
                None
            };
            let m = match whole {
                Some(ms) => {
                    sequence_end = end;
                    queued = ms[1..].iter().copied().collect();
                    ms[0]
                }
                None => self.run_metric(&mut st, &chars, i, face),
            };
            if m.face == COLOR_FACE {
                prev = None;
                out.push(Step { metric: m, kern: 0.0, advance: m.advance as f32 * advance_scale });
                continue;
            }
            let font = Arc::clone(&st.faces[m.face].font);
            let s = px / font.units_per_em as f32;
            let (mut kern, mut track) = (0.0, 0.0);
            if let Some(p) = prev.filter(|p| p.face == m.face) {
                let key = (m.face, p.glyph, m.glyph);
                let k = *st.kerns.entry(key).or_insert_with(|| font.kern_units(p.glyph, m.glyph));
                kern = k as f32 * s;
            }
            if font.has_system_typography() {
                track =
                    *tracks.entry(m.face).or_insert_with(|| font.tracking_units((px / point_scale) as f64) as f32 * s);
            }
            prev = Some(m);
            out.push(Step { metric: m, kern, advance: m.advance as f32 * advance_scale + kern + track });
        }
        out
    }

    /// Advance of `text` in pixels at `px` (pen positions round to whole pixels, as drawn).
    pub fn width_of(&self, text: &str, px: f32, face: usize) -> f32 {
        self.run(text, px, face).iter().map(|s| s.advance).sum::<f32>().round()
    }

    /// `text` shortened with a trailing ellipsis to fit `max_width`; `None` when not even the ellipsis fits (or, for a
    /// short multi-word label, when not even its first word fits one step smaller: [`GlyphAtlas::fitted_label`]).
    pub fn fitted(&self, text: &str, px: f32, max_width: f32, face: usize) -> Option<String> {
        self.fitted_label(text, px, max_width, face).map(|(t, _, _)| t)
    }

    /// Text and size one drawn label gets in `max_width`: the whole text when it fits. A short label of several words whose
    /// first word does not fit is never cut inside that word (`Engl...`): the font shrinks one step (1 px) and the text
    /// is cut at a word boundary there; when even the first word does not fit then, nothing is drawn (`None`; the caller's
    /// tooltip keeps the label). Anything else is cut by [`fit_with_ellipsis`]. Returns `(text, width, px)`.
    pub fn fitted_label(&self, text: &str, px: f32, max_width: f32, face: usize) -> Option<(String, f32, f32)> {
        let full = self.width_of(text, px, face);
        if full <= max_width {
            return Some((text.to_string(), full, px));
        }
        let first = text.split_whitespace().next().unwrap_or_default();
        let short_multi_word = text.chars().count() <= SHORT_LABEL && text.split_whitespace().nth(1).is_some();
        let mut px = px;
        if short_multi_word && self.width_of(first, px, face) > max_width {
            px -= LABEL_STEP;
            if px < MIN_LABEL_PX || self.width_of(first, px, face) > max_width {
                return None;
            }
            let whole = self.width_of(text, px, face);
            if whole <= max_width {
                return Some((text.to_string(), whole, px));
            }
        }
        let mut t = fit_with_ellipsis(text, |s| self.width_of(s, px, face) <= max_width)?;
        if short_multi_word && !t.starts_with(first) {
            // The first word fits, its ellipsis does not: the whole word alone.
            t = first.to_string();
        }
        let w = self.width_of(&t, px, face);
        Some((t, w, px))
    }

    /// Ascent in pixels at `px`.
    pub fn ascent(&self, px: f32, face: usize) -> f32 {
        let f = self.font(face);
        f.ascender as f32 * px / f.units_per_em as f32
    }
    /// Descent in pixels at `px`.
    pub fn descent(&self, px: f32, face: usize) -> f32 {
        let f = self.font(face);
        -f.descender as f32 * px / f.units_per_em as f32
    }

    /// The font of `face` (the UI face for an unknown index).
    pub fn font(&self, face: usize) -> Arc<GlyphRasterFont> {
        let st = self.st.borrow();
        Arc::clone(&st.faces.get(face).unwrap_or(&st.faces[0]).font)
    }

    /// The cell of `glyph` at `px` in `face`, rasterized on first use. Stems of the system font are darkened (Core Text
    /// smoothing draws about 1.3 times the plain outline ink); known limit: one curve for every size and weight.
    pub fn entry(&self, glyph: i64, px: f32, face: usize) -> Entry {
        let mut st = self.st.borrow_mut();
        let face = if face < st.faces.len() { face } else { 0 };
        let size_key = (px * 4.0).round() as i64;
        let key = (glyph, size_key, face);
        if let Some(e) = st.entries.get(&key) {
            return *e;
        }
        let font = Arc::clone(&st.faces[face].font);
        let bmp = font.rasterize(glyph, size_key as f64 / 4.0);
        let (w, h) = (bmp.width.max(0) as u32, bmp.height.max(0) as u32);
        if w == 0 || h == 0 || w + 2 >= self.size || h + 2 >= self.size {
            let e = Entry { x: 0, y: 0, w: 0, h: 0, left: 0, top: 0 };
            st.entries.insert(key, e);
            return e;
        }
        if st.shelf.0 + w + 1 > self.size {
            st.shelf = (1, st.shelf.1 + st.shelf.2 + 1, 0);
        }
        if st.shelf.1 + h + 1 > self.size {
            st.pixels.fill(0);
            st.entries.clear();
            st.wipes += 1;
            st.shelf = (1, 1, 0);
            Self::mark_dirty(&mut st, DirtyRect { x: 0, y: 0, w: self.size, h: self.size });
        }
        let (sx, sy, _) = st.shelf;
        let exponent = if font.has_system_typography() {
            Some(STEM_DARKENING_EXPONENT)
        } else if st.faces[0].inter && st.faces[face].inter {
            Some(INTER_DARKENING_EXPONENT)
        } else {
            None
        };
        for row in 0..h as usize {
            let dst = (sy as usize + row) * self.size as usize + sx as usize;
            let src = &bmp.coverage[row * w as usize..(row + 1) * w as usize];
            for (d, s) in st.pixels[dst..dst + w as usize].iter_mut().zip(src) {
                *d = exponent.map_or(*s, |e| stem_darkening(*s, e));
            }
        }
        let e = Entry { x: sx, y: sy, w, h, left: bmp.left as i32, top: bmp.top as i32 };
        st.shelf = (sx + w + 1, sy, st.shelf.2.max(h));
        st.entries.insert(key, e);
        Self::mark_dirty(&mut st, DirtyRect { x: sx, y: sy, w, h });
        e
    }
}

/// A color bitmap as runs of equal-colored pixels (transparent pixels give none).
fn color_runs(b: &sq_text::emoji_font::ColorBitmap) -> ColorGlyph {
    let (w, h) = (b.width.max(0) as usize, b.height.max(0) as usize);
    let mut runs: Vec<ColorRun> = Vec::new();
    for y in 0..h {
        let mut open: Option<(usize, [u8; 4])> = None;
        let close = |runs: &mut Vec<ColorRun>, open: &mut Option<(usize, [u8; 4])>, end: usize| {
            if let Some((x, p)) = open.take() {
                let a = f32::from(p[3]);
                // Premultiplied back to straight alpha.
                let c = |v: u8| (f32::from(v) / a).min(1.0);
                let color = Color::new(c(p[0]), c(p[1]), c(p[2]), a / 255.0);
                runs.push(ColorRun { x: x as u32, y: y as u32, len: (end - x) as u32, color });
            }
        };
        for x in 0..w {
            let p = [
                b.rgba[(y * w + x) * 4],
                b.rgba[(y * w + x) * 4 + 1],
                b.rgba[(y * w + x) * 4 + 2],
                b.rgba[(y * w + x) * 4 + 3],
            ];
            if open.is_some_and(|(_, q)| q != p) || p[3] == 0 {
                close(&mut runs, &mut open, x);
            }
            if p[3] > 0 && open.is_none() {
                open = Some((x, p));
            }
        }
        close(&mut runs, &mut open, w);
    }
    ColorGlyph { left: b.left as i32, top: b.top as i32, height: b.height as u32, runs }
}

/// Coverage curve exponent of Inter where it is the UI font (Linux, Windows). Plain outline coverage gives Inter about 0.9
/// of the ink the Mac shows for the same words (Core Text smoothing on San Francisco, measured on the same 1.5x shot:
/// 1645 against 1809 summed ink on the sidebar labels, 811 against 913 on a heading), and unhinted stems at 1.5x
/// then look thin and soft. 0.7 lifts the partial-coverage pixels so the ink grows by about a tenth, no more: Inter is not smoothed on the Mac.
const INTER_DARKENING_EXPONENT: f64 = 0.7;

/// Coverage curve exponent of the system font: the same 0.42 as Swift's `GlyphAtlas.stemDarkeningExponent` (Core Text's
/// font smoothing carries about 1.3x the ink of the plain outline coverage). Only the Mac system font is darkened;
/// Inter is not, in Swift and here.
const STEM_DARKENING_EXPONENT: f64 = 0.42;

fn stem_darkening(c: u8, exponent: f64) -> u8 {
    ((c as f64 / 255.0).powf(exponent) * 255.0).round() as u8
}

impl DrawList {
    #[allow(clippy::too_many_arguments)]
    fn log_text(
        &self,
        asked: &str,
        fitted: Option<&(String, f32, f32)>,
        x: f32,
        baseline: f32,
        px: f32,
        align: TextAlign,
        room: f32,
        atlas: &GlyphAtlas,
        face: usize,
    ) {
        // A hidden text keeps the room it was offered, so a test can place it.
        let (w, size) = fitted.map_or((room.max(0.0), px), |(_, w, p)| (*w, *p));
        let left = match align {
            TextAlign::Left => x,
            TextAlign::Center => x - w / 2.0,
            TextAlign::Right => x - w,
        };
        let asked = crate::text_log::original_of(asked).unwrap_or_else(|| asked.to_string());
        let (asc, desc) = (atlas.ascent(size, face), atlas.descent(size, face));
        let c = self.clip();
        crate::text_log::note(crate::text_log::TextRun {
            asked,
            drawn: fitted.map(|(t, _, _)| t.clone()),
            rect: (left, baseline - asc, w, asc + desc),
            room,
            clip: (c.x, c.y, c.w, c.h),
        });
    }

    /// One line of text with its baseline at `baseline`; `x` is the left, center or right edge per `align`. Text longer
    /// than `max_width` ends in an ellipsis. Returns the drawn width.
    #[allow(clippy::too_many_arguments)]
    pub fn text(
        &mut self,
        s: &str,
        x: f32,
        baseline: f32,
        px: f32,
        color: Color,
        atlas: &GlyphAtlas,
        align: TextAlign,
        max_width: f32,
        face: usize,
    ) -> f32 {
        let fitted = atlas.fitted_label(s, px, max_width, face);
        if crate::text_log::active() {
            self.log_text(s, fitted.as_ref(), x, baseline, px, align, max_width, atlas, face);
        }
        let Some((t, w, px)) = fitted else { return 0.0 };
        let pen = match align {
            TextAlign::Left => x,
            TextAlign::Center => x - w / 2.0,
            TextAlign::Right => x - w,
        }
        .round();
        let base = baseline.round();
        let mut advance = 0.0f32;
        for step in atlas.run(&t, px, face) {
            if step.metric.face == COLOR_FACE {
                if let Some(g) = atlas.color_glyph(step.metric.glyph, px) {
                    let (x0, y0) = (pen + (advance + step.kern).round() + g.left as f32, base - g.top as f32);
                    for r in &g.runs {
                        let color = Color { a: r.color.a * color.a, ..r.color };
                        self.fill(Rect::new(x0 + r.x as f32, y0 + r.y as f32, r.len as f32, 1.0), color, 0.0);
                    }
                }
                advance += step.advance;
                continue;
            }
            let e = atlas.entry(step.metric.glyph, px, step.metric.face);
            if e.w > 0 {
                let gx = pen + (advance + step.kern).round() + e.left as f32;
                self.glyph(Rect::new(gx, base - e.top as f32, e.w as f32, e.h as f32), e.x, e.y, color);
            }
            advance += step.advance;
        }
        w
    }

    /// Text centered vertically in `rect` (cap height centered), aligned per `align`, cut to the rect width.
    #[allow(clippy::too_many_arguments)]
    pub fn text_in(
        &mut self,
        s: &str,
        rect: Rect,
        px: f32,
        color: Color,
        atlas: &GlyphAtlas,
        align: TextAlign,
        inset: f32,
        face: usize,
    ) -> f32 {
        let baseline = rect.mid_y() + px * atlas.cap_height_ratio() / 2.0;
        let x = match align {
            TextAlign::Left => rect.x + inset,
            TextAlign::Center => rect.mid_x(),
            TextAlign::Right => rect.max_x() - inset,
        };
        self.text(s, x, baseline, px, color, atlas, align, (rect.w - 2.0 * inset).max(0.0), face)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::Path;

    pub(crate) fn fonts_root() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
    }

    pub(crate) fn atlas() -> GlyphAtlas {
        GlyphAtlas::inter(&fonts_root()).unwrap_or_else(|| panic!("bundled Inter loads"))
    }

    #[test]
    fn width_is_whole_pixels_and_grows_with_text() {
        let a = atlas();
        let w = a.width_of("Hello", 13.0, 0);
        assert_eq!(w, w.round());
        assert!(w > 20.0 && a.width_of("Hello world", 13.0, 0) > w);
    }

    #[test]
    fn kerned_pairs_set_tighter_than_the_sum_of_their_letters() {
        // Inter's GPOS pairs (AV, To, Ty) pull the letters together, as Core Text sets the same font.
        let a = atlas();
        let px = 40.0;
        for pair in ["AV", "To", "Ty"] {
            let mut chars = pair.chars();
            let (x, y) = (chars.next().unwrap_or(' '), chars.next().unwrap_or(' '));
            let sum = a.width_of(&x.to_string(), px, 0) + a.width_of(&y.to_string(), px, 0);
            assert!(a.width_of(pair, px, 0) < sum, "{pair} is kerned");
        }
    }

    #[test]
    fn entry_caches_and_marks_dirty() {
        let a = atlas();
        let m = a.metric_for('H', 0);
        let e1 = a.entry(m.glyph, 13.0, 0);
        assert!(e1.w > 0 && e1.h > 0 && e1.top > 0);
        let g = a.generation();
        assert_eq!(a.entry(m.glyph, 13.0, 0), e1);
        assert_eq!(a.generation(), g, "a hit rasterizes nothing");
        let d = a.dirty_since(g - 1).expect("the new cell is dirty");
        assert_eq!((d.x, d.y, d.w, d.h), (e1.x, e1.y, e1.w, e1.h));
        assert!(a.dirty_since(g).is_none());
        assert!(a.with_pixels(|p| p[(e1.y * a.size() + e1.x) as usize..].iter().take(2000).any(|&v| v > 0)));
    }

    #[test]
    fn every_renderer_sees_the_cells_made_since_its_own_last_look() {
        let a = atlas();
        let first = a.entry(a.metric_for('G', 0).glyph, 13.0, 0);
        let (mut window, mut float) = (0, 0);
        // The window draws and syncs; the floating window has not drawn yet.
        let w = a.dirty_since(window).expect("window sees G");
        assert_eq!((w.x, w.y), (first.x, first.y));
        window = a.generation();
        let second = a.entry(a.metric_for('z', 0).glyph, 13.0, 0);
        // The floating window syncs now: it must still get G and z, though the window already looked.
        let f = a.dirty_since(float).expect("float sees both");
        assert!(f.x <= first.x && f.x + f.w >= second.x + second.w, "float region covers G and z");
        float = a.generation();
        let w = a.dirty_since(window).expect("window sees z");
        assert_eq!((w.x, w.y, w.w, w.h), (second.x, second.y, second.w, second.h));
        assert!(a.dirty_since(float).is_none());
        // A reader that is older than the log gets the whole page.
        for c in ('a'..='z').chain('A'..='Z') {
            for px in
                [9.0, 10.0, 11.0, 12.0, 14.0, 15.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0, 28.0, 30.0, 32.0, 36.0, 40.0]
            {
                a.entry(a.metric_for(c, 0).glyph, px, 0);
            }
        }
        let all = a.dirty_since(0).expect("whole page");
        assert!(all.w > 0);
    }

    #[test]
    fn semibold_is_a_second_face_and_heavier() {
        let a = atlas();
        let semi = a.semibold_face();
        assert!(semi > 0, "Inter has a weight axis");
        assert_eq!(a.semibold_face(), semi, "the face is added once");
        assert!(a.width_of("Sequence", 13.0, semi) >= a.width_of("Sequence", 13.0, 0));
    }

    #[test]
    fn fit_with_ellipsis_ends_at_a_word_boundary() {
        let w = |s: &str| s.chars().count();
        let fits = |n: usize| move |s: &str| s.chars().count() <= n;
        // "How to save a templ…" is the old cut; the word boundary gives "How to save a…".
        let t = "How to save a template";
        let out = fit_with_ellipsis(t, fits(20)).unwrap();
        assert_eq!(out, "How to save a\u{2026}");
        assert!(!cuts_mid_word(t, &out));
        assert!(cuts_mid_word(t, "How to save a templ\u{2026}"));
        // A cut that already sits at a word start keeps its words.
        assert_eq!(fit_with_ellipsis("Repeat Edge Pixels", fits(13)).unwrap(), "Repeat Edge\u{2026}");
        // One long word: broken inside as the last resort.
        assert_eq!(fit_with_ellipsis("Supercalifragilistic", fits(6)).unwrap(), "Super\u{2026}");
        assert_eq!(fit_with_ellipsis("Short", fits(9)).unwrap(), "Short");
        assert_eq!(fit_with_ellipsis("Long text", fits(0)), None);
        // Every width: never mid-word.
        for n in 1..t.len() {
            if let Some(o) = fit_with_ellipsis(t, fits(n)) {
                assert!(!cuts_mid_word(t, &o) && w(&o) <= n, "{n}: {o}");
            }
        }
    }

    #[test]
    fn fitted_cuts_with_an_ellipsis_and_gives_up_below_the_ellipsis() {
        let a = atlas();
        let text = "A rather long clip name.mov";
        let full = a.width_of(text, 12.0, 0);
        assert_eq!(a.fitted(text, 12.0, full, 0).as_deref(), Some(text));
        let cut = a.fitted(text, 12.0, full / 2.0, 0).unwrap_or_default();
        assert!(cut.ends_with('…') && a.width_of(&cut, 12.0, 0) <= full / 2.0);
        assert_eq!(a.fitted(text, 12.0, 1.0, 0), None);
    }

    /// "English (US)" in a narrow slot: never "Engl…". The font shrinks a step when that saves the first word, else the
    /// label is not drawn at all; a long single word keeps its old cut.
    #[test]
    fn a_short_label_never_breaks_its_first_word() {
        let a = atlas();
        let (text, px) = ("English (US)", 12.0);
        let word = a.width_of("English", px, 0);
        for w in 1..=(a.width_of(text, px, 0) as u32) {
            let w = w as f32;
            match a.fitted_label(text, px, w, 0) {
                Some((shown, width, used)) => {
                    assert!(width <= w && used <= px && used >= 8.0, "{w}: {shown} at {used}");
                    assert!(!cuts_mid_word(text, &shown), "{w}: \"{shown}\"");
                    assert!(shown.starts_with("English"), "{w}: \"{shown}\"");
                }
                None => assert!(a.width_of("English", px - 1.0, 0) > w, "{w}: hidden although the first word fits"),
            }
        }
        // One step smaller saves the word where the full size could not.
        let w = (a.width_of("English", px - 1.0, 0) + word) / 2.0;
        let (shown, _, used) = a.fitted_label(text, px, w, 0).expect("fits one step smaller");
        assert!(used < px && shown.starts_with("English"), "{shown} at {used}");
        assert_eq!(a.fitted_label(text, px, 5.0, 0), None, "truly no room: hidden");
        // A single long word (a file name) is still cut inside as the last resort.
        let name = a.fitted("Supercalifragilistic", px, 40.0, 0).unwrap_or_default();
        assert!(name.ends_with('\u{2026}') && name.chars().count() > 2, "{name}");
    }

    #[test]
    fn text_emits_glyph_quads_on_whole_pixels() {
        let a = atlas();
        let mut l = DrawList::new(200.0, 40.0);
        let w = l.text("Ag 1", 10.4, 20.2, 13.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
        assert!(w > 0.0 && l.quads().len() == 3, "the space has no ink");
        for q in l.quads() {
            assert_eq!(q.rect.x, q.rect.x.round());
            assert_eq!(q.rect.y, q.rect.y.round());
        }
        let mut c = DrawList::new(200.0, 40.0);
        c.text_in("Ag", Rect::new(0.0, 0.0, 100.0, 20.0), 13.0, Color::WHITE, &a, TextAlign::Center, 0.0, 0);
        assert!(c.quads()[0].rect.x > 30.0 && c.quads()[0].rect.x < 70.0);
    }

    // Swift GlyphAtlasWeightTests
    fn ink(a: &GlyphAtlas, face: usize) -> u64 {
        let g = a.metric_for('H', face).glyph;
        a.font(face).rasterize(g, 48.0).coverage.iter().map(|&v| v as u64).sum()
    }

    /// Summed coverage the atlas page holds for `text` at `px`, against the plain outline coverage of the same glyphs.
    fn page_and_outline_ink(a: &GlyphAtlas, text: &str, px: f32) -> (u64, u64) {
        let (mut page, mut outline) = (0u64, 0u64);
        for ch in text.chars().filter(|c| !c.is_whitespace()) {
            let g = a.metric_for(ch, 0).glyph;
            let e = a.entry(g, px, 0);
            a.with_pixels(|p| {
                for row in 0..e.h as usize {
                    let at = (e.y as usize + row) * a.size() as usize + e.x as usize;
                    page += p[at..at + e.w as usize].iter().map(|&v| v as u64).sum::<u64>();
                }
            });
            outline += a.font(0).rasterize(g, px as f64).coverage.iter().map(|&v| v as u64).sum::<u64>();
        }
        (page, outline)
    }

    #[test]
    fn inter_as_the_ui_font_carries_a_tenth_more_ink_than_its_outline() {
        let a = atlas();
        for px in [13.5f32, 19.5, 24.0] {
            let (page, outline) = page_and_outline_ink(&a, "Home Recent Templates Learn What's new", px);
            let ratio = page as f64 / outline as f64;
            assert!((1.05..1.22).contains(&ratio), "ink ratio {ratio} at {px} px");
        }
    }

    #[test]
    fn stem_darkening_keeps_the_ends_and_lifts_the_middle() {
        for e in [STEM_DARKENING_EXPONENT, INTER_DARKENING_EXPONENT] {
            assert_eq!((stem_darkening(0, e), stem_darkening(255, e)), (0, 255));
            assert!(stem_darkening(128, e) > 128);
        }
        assert!(stem_darkening(128, INTER_DARKENING_EXPONENT) < stem_darkening(128, STEM_DARKENING_EXPONENT));
    }

    #[test]
    fn semibold_is_its_own_heavier_wider_face_with_more_ink() {
        let a = atlas();
        let bold = a.semibold_face();
        assert!(bold > 0);
        assert!(a.width_of("Media offline", 24.0, bold) > a.width_of("Media offline", 24.0, 0));
        assert!(ink(&a, bold) > ink(&a, 0) * 11 / 10, "the stems are thicker");
    }

    #[test]
    fn medium_sits_between_regular_and_semibold() {
        let a = atlas();
        let medium = a.medium_face();
        assert!(medium > 0 && medium != a.semibold_face());
        assert_eq!(a.medium_face(), medium);
        let s = "Media offline Sequence 01";
        let (r, m, b) = (a.width_of(s, 24.0, 0), a.width_of(s, 24.0, medium), a.width_of(s, 24.0, a.semibold_face()));
        assert!(r < m && m < b);
        assert_eq!(crate::Canvas::with_size(10.0, 10.0, None, 1.0).medium(), 0);
        assert_eq!(crate::Canvas::with_size(10.0, 10.0, None, 1.0).semibold(), 0);
    }

    #[test]
    fn the_regular_face_keeps_the_default_instance() {
        let a = atlas();
        assert!(a.font(0).coords.is_empty());
        assert!(!a.font(a.semibold_face()).coords.is_empty());
    }

    // Swift GlyphAtlasFallbackTests
    #[test]
    fn inter_keeps_its_own_glyphs() {
        let a = atlas();
        assert_eq!(a.fallback_face(0), None);
        assert_eq!(a.metric_for('⇥', 0).face, 0);
    }

    #[test]
    fn a_missing_symbol_draws_from_inter_at_the_asked_faces_scale() {
        sq_text::portable_font_match::set_fonts_root(&fonts_root());
        let Some(montserrat) = GlyphRasterFont::bundled("Montserrat", sq_text::text_style::FontWeight::Regular, false)
        else {
            eprintln!("skipping: Montserrat is not bundled here");
            return;
        };
        assert_eq!(montserrat.glyph_for('⇥'), 0);
        let upem = montserrat.units_per_em;
        let inter = GlyphRasterFont::inter(&fonts_root()).unwrap_or_else(|| panic!("inter"));
        let at = GlyphAtlas::new((*montserrat).clone(), Some(inter.clone()));
        let m = at.metric_for('⇥', 0);
        assert!(m.face > 0 && m.glyph != 0);
        let inter_adv = inter.advance(inter.glyph_for('⇥'));
        assert!((m.advance - inter_adv * upem / inter.units_per_em).abs() <= 1);
        assert!(at.width_of("⇥", 20.0, 0) > 5.0);
        assert_eq!(at.metric_for('A', 0).face, 0, "a character the face has keeps the face");
        let mut l = DrawList::new(100.0, 50.0);
        l.text("⇥↩", 10.0, 30.0, 20.0, Color::WHITE, &at, TextAlign::Left, f32::INFINITY, 0);
        assert_eq!(l.quads().len(), 2);
    }

    #[test]
    fn hebrew_and_arabic_draw_from_a_system_face_where_one_exists() {
        let root = std::env::var("SystemRoot").unwrap_or_default();
        if root.is_empty() || !std::path::Path::new(&root).join("Fonts").join("segoeui.ttf").exists() {
            return; // no Windows fonts here: the Mac atlas takes CoreText, tofu stays on bare Linux for now
        }
        let at = atlas();
        for c in ['\u{05D0}', '\u{0645}'] {
            let m = at.metric_for(c, 0);
            assert!(m.glyph != 0 && m.face != 0, "{c:?} still draws as a box");
        }
        assert!(at.width_of("\u{05E9}\u{05DC}\u{05D5}\u{05DD}", 12.0, 0) > 20.0);
    }

    #[test]
    fn every_script_draws_real_glyphs_where_the_system_has_a_font() {
        // Latin and umlauts, Chinese, Japanese, Korean, Arabic, Hebrew, a symbol and an emoji.
        let samples = [
            ("latin", "Äöüß"),
            ("chinese", "中文项目"),
            ("japanese", "日本語ひらがなカタカナ"),
            ("korean", "한국어"),
            ("arabic", "مشروع"),
            ("hebrew", "שלום"),
            ("symbol", "\u{2600}\u{2764}"),
            ("emoji", "\u{1F600}"),
        ];
        let at = atlas();
        let mut have = std::collections::BTreeMap::new();
        for (script, text) in samples {
            let drawn = text.chars().all(|c| at.metric_for(c, 0).glyph != 0);
            let width = at.width_of(text, 14.0, 0);
            assert!(width > 0.0, "{script} has no width");
            eprintln!("script {script}: {}", if drawn { "real glyphs" } else { "no system font, tofu box" });
            have.insert(script, drawn);
        }
        assert!(have["latin"]);
        // Every Mac ships Hiragino, Apple SD Gothic Neo and Geeza Pro, every Windows 11 Segoe UI, Microsoft YaHei, Malgun
        // Gothic and Arial; a skip is only allowed on Linux without Noto or DejaVu.
        if cfg!(any(target_os = "macos", target_os = "windows")) {
            for script in ["chinese", "japanese", "korean", "arabic", "hebrew"] {
                assert!(have[script], "{script} still draws as boxes");
            }
        }
    }

    #[test]
    fn a_fallback_glyph_advances_by_its_own_width_at_any_units_per_em() {
        let at = atlas();
        let c = '中';
        let m = at.metric_for(c, 0);
        if m.face == 0 {
            eprintln!("no CJK system font here: skipped");
            return;
        }
        let em = at.width_of(&c.to_string(), 100.0, 0);
        // A CJK ideograph is about one em wide; scaled by the wrong face it would be 2 em (1000 vs 2048 units per em).
        assert!((70.0..=125.0).contains(&em), "ideograph advance {em}px at 100px");
    }

    #[test]
    fn no_system_fonts_leaves_boxes_and_does_not_panic() {
        let at = atlas();
        at.st.borrow_mut().scripts = Some(ScriptFaces { pending: Default::default(), loaded: Vec::new() });
        at.set_emoji_font(None);
        for c in "中مש\u{1F600}x".chars() {
            let m = at.metric_for(c, 0);
            assert!(m.face == 0 && (c == 'x') == (m.glyph != 0), "{c:?}");
        }
        let mut l = DrawList::new(200.0, 50.0);
        l.text("中مש", 10.0, 30.0, 20.0, Color::WHITE, &at, TextAlign::Left, f32::INFINITY, 0);
        assert!(at.width_of("中", 20.0, 0) >= 0.0);
    }

    /// The emoji fonts of `SQ_TEST_EMOJI_FONTS` (`AppleColorEmoji.ttc`, `NotoColorEmoji.ttf`, `seguiemj.ttf`); none when the
    /// folder or a file is missing, and the tests that use it pass without checking anything.
    fn emoji_fonts() -> Vec<(&'static str, EmojiFont)> {
        let Some(dir) = std::env::var_os("SQ_TEST_EMOJI_FONTS") else { return Vec::new() };
        ["AppleColorEmoji.ttc", "NotoColorEmoji.ttf", "seguiemj.ttf"]
            .into_iter()
            .filter_map(|n| EmojiFont::from_path(&Path::new(&dir).join(n)).map(|f| (n, f)))
            .collect()
    }

    /// The most colorful pixel (max - min of the channels) the list draws, rendered in software.
    fn max_saturation(l: &DrawList, a: &GlyphAtlas, w: usize, h: usize) -> u8 {
        let img = crate::software::SoftwareRenderer::render(
            l,
            w,
            h,
            Color::BLACK,
            &crate::software::Sources { atlas: Some(a), ..Default::default() },
        );
        img.pixels.chunks(4).map(|p| p[0].max(p[1]).max(p[2]) - p[0].min(p[1]).min(p[2])).max().unwrap_or(0)
    }

    #[test]
    fn color_emoji_draws_in_color_on_the_baseline() {
        for (name, font) in emoji_fonts() {
            let a = atlas();
            a.set_emoji_font(Some(font));
            let m = a.metric_for('\u{1F600}', 0);
            assert_eq!(m.face, COLOR_FACE, "{name}");
            let w = a.width_of("\u{1F600}", 14.0, 0);
            assert!((12.0..=22.0).contains(&w), "{name}: advance {w}");
            let mut l = DrawList::new(60.0, 24.0);
            l.text("A\u{1F600}B", 2.0, 18.0, 14.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
            assert!(l.quads().len() > 40, "{name}: {} quads", l.quads().len());
            // The text color is white, so any saturation comes from the emoji.
            let sat = max_saturation(&l, &a, 60, 24);
            assert!(sat > 100, "{name}: saturation {sat}");
            // Text opacity still applies.
            let mut faint = DrawList::new(60.0, 24.0);
            faint.text(
                "\u{1F600}",
                2.0,
                18.0,
                14.0,
                Color::new(1.0, 1.0, 1.0, 0.5),
                &a,
                TextAlign::Left,
                f32::INFINITY,
                0,
            );
            assert!(max_saturation(&faint, &a, 60, 24) < sat, "{name}: opacity ignored");
        }
    }

    #[test]
    fn variation_selector_and_joiner_add_nothing_and_fe0f_asks_for_the_emoji_look() {
        for (name, font) in emoji_fonts() {
            let a = atlas();
            a.set_emoji_font(Some(font));
            for t in ["A", "\u{1F600}"] {
                let with = format!("{t}\u{FE0F}");
                assert_eq!(a.width_of(&with, 14.0, 0), a.width_of(t, 14.0, 0), "{name}: {t:?}");
                assert_eq!(a.width_of(&format!("{t}\u{200D}"), 14.0, 0), a.width_of(t, 14.0, 0), "{name}");
            }
            // A heart with U+FE0F is the red emoji, without it the text outline of the UI faces (or the box).
            let mut red = DrawList::new(40.0, 24.0);
            red.text("\u{2764}\u{FE0F}", 2.0, 18.0, 14.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
            assert!(max_saturation(&red, &a, 40, 24) > 100, "{name}: no red heart");
            let mut quads = DrawList::new(40.0, 24.0);
            quads.text("\u{FE0F}", 2.0, 18.0, 14.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
            assert!(quads.quads().is_empty(), "{name}: a lone selector drew");
        }
    }

    /// A ZWJ family, a skin tone, a flag and a keycap measure as ONE emoji (as wide as a single one), and the cluster is
    /// never cut by the ellipsis. Fonts with `GSUB` ligatures only (Noto, Segoe); Apple's `morx` is not read.
    /// Segoe UI Emoji composes a ZWJ family of small overlapping parts placed by their own advances (841 + 1081 of 2048 units,
    /// the last part has none): the cluster is that wide and draws all parts; a skin tone and a keycap stay one emoji wide.
    /// Needs the font file in `SQ_TEST_SEGOE` (never in the repo); skips without it.
    #[test]
    fn segoe_family_measures_as_its_composed_parts() {
        let Some(path) = std::env::var_os("SQ_TEST_SEGOE") else { return };
        let font = EmojiFont::from_path(Path::new(&path));
        assert!(font.is_some(), "SQ_TEST_SEGOE does not open as a color emoji font");
        let Some(font) = font else { return };
        let a = atlas();
        a.set_emoji_font(Some(font));
        let one = a.width_of("\u{1F600}", 20.0, 0);
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        let w = a.width_of(family, 20.0, 0);
        let want = (841.0 + 1081.0) / 2048.0 * 20.0;
        assert!((w - want).abs() <= 1.5, "family {w} vs {want}");
        let mut l = DrawList::new(120.0, 40.0);
        l.text(family, 4.0, 28.0, 20.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
        let one_quads = {
            let mut l1 = DrawList::new(120.0, 40.0);
            l1.text("\u{1F600}", 4.0, 28.0, 20.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
            l1.quads().len()
        };
        assert!(l.quads().len() > one_quads, "three parts draw more than one emoji");
        for seq in ["\u{1F44D}\u{1F3FD}", "1\u{FE0F}\u{20E3}"] {
            let w = a.width_of(seq, 20.0, 0);
            assert!((w - one).abs() <= 2.0, "{seq:?}: {w} vs {one}");
        }
    }

    #[test]
    fn emoji_sequences_measure_as_one_glyph() {
        for (name, font) in emoji_fonts() {
            // Apple's `morx` goes through the installed CoreText shaper; Segoe composes a family of parts (next test).
            if !name.starts_with("Noto") {
                continue;
            }
            let a = atlas();
            a.set_emoji_font(Some(font));
            let one = a.width_of("\u{1F600}", 20.0, 0);
            assert!(one > 10.0, "{name}: single emoji {one}");
            for (kind, seq) in [
                ("family", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
                ("skin tone", "\u{1F44D}\u{1F3FD}"),
                ("flag", "\u{1F1E9}\u{1F1EA}"),
                ("keycap", "1\u{FE0F}\u{20E3}"),
            ] {
                let w = a.width_of(seq, 20.0, 0);
                assert!((w - one).abs() <= 2.0 && w > 0.0, "{name} {kind}: {w} vs {one}");
                // Two in a row are two glyphs wide, and draw as two color glyphs.
                let two = a.width_of(&format!("{seq}{seq}"), 20.0, 0);
                assert!((two - 2.0 * w).abs() <= 2.0, "{name} {kind}: pair {two} vs {w}");
                let mut l = DrawList::new(120.0, 40.0);
                l.text(seq, 4.0, 28.0, 20.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
                // One color glyph of many runs (Noto draws the family as a gray silhouette, so no saturation check).
                assert!(l.quads().len() > 40, "{name} {kind}: {} quads", l.quads().len());
            }
            // No ligature for the whole sequence: the parts, never nothing.
            let odd = "\u{1F600}\u{200D}\u{1F600}";
            assert!(a.width_of(odd, 20.0, 0) >= one, "{name}: parts");
        }
    }

    #[test]
    fn an_ellipsis_cut_never_splits_an_emoji_sequence() {
        let chars: Vec<char> = "ab \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".chars().collect();
        assert_eq!(emoji_cluster_end(&chars, 3), chars.len());
        let flags: Vec<char> = "\u{1F1E9}\u{1F1EA}\u{1F1EB}".chars().collect();
        assert_eq!(emoji_cluster_end(&flags, 0), 2);
        let keycap: Vec<char> = "1\u{FE0F}\u{20E3}2".chars().collect();
        assert_eq!((emoji_cluster_end(&keycap, 0), emoji_cluster_end(&keycap, 3)), (3, 4));
        let cut =
            fit_with_ellipsis("x \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", |s| s.chars().count() <= 5).unwrap();
        assert!(!cut.contains('\u{200D}'), "{cut:?}");
    }

    #[test]
    fn a_missing_emoji_font_keeps_the_box() {
        let a = atlas();
        a.set_emoji_font(None);
        a.st.borrow_mut().scripts = Some(ScriptFaces { pending: Default::default(), loaded: Vec::new() });
        let m = a.metric_for('\u{1F600}', 0);
        assert!(m.face != COLOR_FACE && m.glyph == 0);
        let mut l = DrawList::new(60.0, 24.0);
        l.text("\u{1F600}", 2.0, 18.0, 14.0, Color::WHITE, &a, TextAlign::Left, f32::INFINITY, 0);
        assert!(l.quads().iter().all(|q| q.kind == crate::draw_list::QuadKind::Glyph));
    }

    #[test]
    fn color_runs_merge_equal_pixels_and_restore_straight_alpha() {
        let b = sq_text::emoji_font::ColorBitmap {
            width: 4,
            height: 1,
            left: -1,
            top: 3,
            // Two equal opaque reds, one half-transparent premultiplied red (128, 0, 0, 128), one clear pixel.
            rgba: vec![255, 0, 0, 255, 255, 0, 0, 255, 128, 0, 0, 128, 0, 0, 0, 0],
        };
        let g = color_runs(&b);
        assert_eq!((g.left, g.top), (-1, 3));
        assert_eq!(g.runs.len(), 2);
        assert_eq!((g.runs[0].x, g.runs[0].len), (0, 2));
        assert_eq!((g.runs[1].x, g.runs[1].len), (2, 1));
        assert!((g.runs[1].color.r - 1.0).abs() < 0.01 && (g.runs[1].color.a - 0.502).abs() < 0.01);
    }

    /// A color emoji's vertical center is within 1 px of the cap-height center of the UI face at body sizes, whichever emoji
    /// font the machine has (Apple's art sits on the baseline, Noto's and Segoe's reach below it).
    #[test]
    fn color_emoji_center_sits_on_the_cap_height_center() {
        for (name, font) in emoji_fonts() {
            let a = atlas();
            a.set_emoji_font(Some(font));
            let g = a.metric_for('\u{1F600}', 0).glyph;
            for px in [12.0f32, 14.0, 16.0] {
                let e = a.color_glyph(g, px).expect("emoji bitmap");
                let center = e.top as f32 - e.height as f32 / 2.0;
                let cap_center = px * a.cap_height_ratio() / 2.0;
                assert!((center - cap_center).abs() <= 1.0, "{name} @{px}: center {center} vs cap center {cap_center}");
            }
        }
    }

    #[test]
    fn cap_height_ratio_is_inters() {
        assert!((atlas().cap_height_ratio() - 0.727).abs() < 0.02);
    }
}
