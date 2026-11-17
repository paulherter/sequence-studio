// Swift: WindowChrome.swift:44 (StatusBarContent, StatusBarDraw)
//! The status bar of the editing window: format, save state and message from the left; version, playback quality,
//! grade text and the Linked Selection chip from the right; the export ring at the right end.

use sq_draw::{Canvas, Color, DrawTheme, TextAlign};
use sq_editor_session::{MonitorQuality, SaveStatus, SaveStatusKind};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{spacing, type_size};

/// The warning chip while Linked Selection is off.
const LINKED_SELECTION_OFF: &str = "Linked Selection off";
/// Space between the bar's items (the frame's gap), and the bar's own side padding.
const PAD: f64 = spacing::LG as f64;
const EDGE: f64 = 14.0;
/// The idle background-tasks ring (11 pt, 1.5 pt stroke).
const IDLE_RING: f64 = 11.0;
const DOT: f64 = 6.0;
const ICON_TO_LABEL: f64 = 5.0;
const RING_SIDE: f64 = 20.0;
const FONT: f64 = type_size::BODY as f64;
const CHIP_FONT: f64 = type_size::CAPTION as f64;

/// The bar's texts, one value per frame.
#[derive(Clone, Debug, PartialEq)]
pub struct StatusBarContent {
    /// "1920 × 1080 · 25 fps".
    pub format: String,
    /// The save state with its dot; `None` hides both.
    pub save: Option<SaveStatus>,
    /// Flash messages and job lines.
    pub message: String,
    /// "Playback: Full · GPU"; empty hides it.
    pub playback: String,
    /// "Sequence Studio 0.1 Alpha".
    pub version: String,
    /// The Color page's grade text; empty hides it.
    pub grade: String,
    /// The warning chip while Linked Selection is off.
    pub linked_selection_off: bool,
    /// The background relink offer ("Found 4 offline files · Reconnect"); empty hides it.
    pub relink_offer: String,
    /// The ring (0...1) for exports and background work; `None` hides it.
    pub export_progress: Option<f64>,
}

impl Default for StatusBarContent {
    fn default() -> StatusBarContent {
        StatusBarContent {
            format: String::new(),
            save: None,
            message: String::new(),
            playback: String::new(),
            version: sq_uikit::app_version::AppVersion::full_name(),
            grade: String::new(),
            linked_selection_off: false,
            relink_offer: String::new(),
            export_progress: None,
        }
    }
}

impl StatusBarContent {
    /// "1920 × 1080 · 25 fps", with two decimals for a fractional rate, " VFR" when the footage varies.
    pub fn format_text(width: i64, height: i64, fps: f64, variable_frame_rate: bool) -> String {
        let rate = if fps.round() == fps { format!("{}", fps as i64) } else { format!("{fps:.2}") };
        format!("{width} × {height} · {rate} fps{}", if variable_frame_rate { " VFR" } else { "" })
    }

    /// "Playback: Full · GPU".
    pub fn playback_text(q: MonitorQuality) -> String {
        format!("Playback: {} · GPU", q.title())
    }
}

/// Where each part sits, in the bar's coordinates (points).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StatusFrames {
    pub format: Option<CGRect>,
    pub dot: Option<CGRect>,
    pub save: Option<CGRect>,
    pub message: Option<CGRect>,
    pub version: Option<CGRect>,
    pub playback: Option<CGRect>,
    pub grade: Option<CGRect>,
    pub link: Option<CGRect>,
    pub relink: Option<CGRect>,
    pub ring: Option<CGRect>,
}

/// The clickable parts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusPart {
    Relink,
    Ring,
}

/// Lays the parts out in `bar`. A narrow bar drops the version first, then the playback and grade texts.
/// `width` measures a text at the bar's font, `chip_width` at the chip's.
pub fn layout(
    s: &StatusBarContent,
    bar: CGRect,
    width: &dyn Fn(&str) -> f64,
    chip_width: &dyn Fn(&str) -> f64,
) -> StatusFrames {
    let mut f = StatusFrames::default();
    let text = |x: f64, w: f64| CGRect::new(x, bar.min_y(), w.ceil(), bar.height);
    let mut left = bar.min_x() + EDGE;
    if !s.format.is_empty() {
        let w = width(&s.format);
        f.format = Some(text(left, w));
        left += w.ceil() + PAD;
    }
    if let Some(save) = &s.save {
        f.dot = Some(CGRect::new(left, (bar.mid_y() - DOT / 2.0).round(), DOT, DOT));
        let r = text(left + DOT + ICON_TO_LABEL, width(&save.text));
        left = r.max_x() + PAD;
        f.save = Some(r);
    }
    let mut right = bar.max_x() - EDGE;
    if s.export_progress.is_some() {
        let ring = CGRect::new(right - RING_SIDE + 3.0, (bar.mid_y() - RING_SIDE / 2.0).round(), RING_SIDE, RING_SIDE);
        right = ring.min_x() - PAD + 3.0;
        f.ring = Some(ring);
    } else {
        let ring = CGRect::new(right - IDLE_RING, (bar.mid_y() - IDLE_RING / 2.0).round(), IDLE_RING, IDLE_RING);
        right = ring.min_x() - PAD;
        f.ring = Some(ring);
    }
    let mut place = |slot: &mut Option<CGRect>, w: f64, least: f64| {
        if right - w >= least {
            *slot = Some(text(right - w, w));
            right -= w + PAD;
        }
    };
    if !s.version.is_empty() {
        place(&mut f.version, width(&s.version).ceil(), left + 320.0);
    }
    if !s.playback.is_empty() {
        place(&mut f.playback, width(&s.playback).ceil(), left + 160.0);
    }
    if !s.grade.is_empty() {
        place(&mut f.grade, width(&s.grade).ceil(), left + 160.0);
    }
    if s.linked_selection_off {
        place(&mut f.link, width(LINKED_SELECTION_OFF).ceil(), left);
    }
    if !s.relink_offer.is_empty() {
        place(&mut f.relink, chip_width(&s.relink_offer).ceil(), left);
    }
    if !s.message.is_empty() && right > left {
        f.message = Some(CGRect::new(left, bar.min_y(), right - left, bar.height));
    }
    f
}

/// The part under `p` (window points).
pub fn part_at(
    p: CGPoint,
    s: &StatusBarContent,
    bar: CGRect,
    width: &dyn Fn(&str) -> f64,
    chip_width: &dyn Fn(&str) -> f64,
) -> Option<StatusPart> {
    let f = layout(s, bar, width, chip_width);
    if f.relink.is_some_and(|r| r.contains(p)) {
        Some(StatusPart::Relink)
    } else if f.ring.is_some_and(|r| r.contains(p)) {
        Some(StatusPart::Ring)
    } else {
        None
    }
}

/// The amber tail of the status bar's experimental grade text.
const EXPERIMENTAL_WORD: &str = "experimental";

/// Draws the bar.
pub fn draw(c: &mut Canvas, s: &StatusBarContent, bar: CGRect, t: &DrawTheme) {
    c.fill(bar, t.titlebar());
    let f = {
        let c = &*c;
        layout(s, bar, &|x| c.size_of(x, FONT, 0).width, &|x| c.size_of(x, CHIP_FONT, 0).width)
    };
    let warning = t.warning();
    let put = |c: &mut Canvas, text: &str, r: Option<CGRect>, size: f64, color: Color| {
        if let Some(r) = r {
            c.draw_text_in(text, r, size, color, TextAlign::Left, 0.0, 0);
        }
    };
    put(c, &s.format, f.format, FONT, t.label3());
    if let (Some(r), Some(save)) = (f.dot, &s.save) {
        let ok = matches!(save.kind, SaveStatusKind::Saved | SaveStatusKind::Empty);
        c.fill_ellipse(r, if ok { t.green() } else { warning });
        put(c, &save.text, f.save, FONT, t.label3());
    }
    put(c, &s.message, f.message, FONT, t.label2());
    put(c, &s.version, f.version, FONT, t.label3());
    put(c, &s.playback, f.playback, FONT, t.label3());
    match (f.grade, s.grade.strip_suffix(EXPERIMENTAL_WORD)) {
        // "No Pro grade · experimental": the word is amber like the flask (kit status bar).
        (Some(r), Some(head)) => {
            let w = c.draw_text_in(head, r, FONT, t.label3(), TextAlign::Left, 0.0, 0);
            let word = CGRect::new(r.x + w, r.y, (r.width - w).max(0.0), r.height);
            c.draw_text_in(
                EXPERIMENTAL_WORD,
                word,
                FONT,
                t.token(sq_uikit::redesign_tokens::color::EXP_TEXT),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        _ => put(c, &s.grade, f.grade, FONT, t.label3()),
    }
    put(c, LINKED_SELECTION_OFF, f.link, FONT, warning);
    put(c, &s.relink_offer, f.relink, CHIP_FONT, warning);
    match (f.ring, s.export_progress) {
        (Some(r), Some(p)) => draw_ring(c, r, p, t),
        (Some(r), None) => c.stroke_ellipse(r.inset_by(0.75, 0.75), 1.5, t.label4()),
        _ => {}
    }
}

/// A 2 pt track in the hover fill and the grey (text 3) arc clockwise from 12 o'clock.
fn draw_ring(c: &mut Canvas, r: CGRect, progress: f64, t: &DrawTheme) {
    let o = r.inset_by(4.0, 4.0);
    c.stroke_ellipse(o, 2.0, t.fill_hover());
    let p = progress.clamp(0.0, 1.0);
    if p <= 0.0 {
        return;
    }
    let steps = ((48.0 * p) as usize).max(2);
    let rad = o.width / 2.0;
    let points: Vec<CGPoint> = (0..=steps)
        .map(|i| {
            let a = -std::f64::consts::FRAC_PI_2 + 2.0 * std::f64::consts::PI * p * i as f64 / steps as f64;
            CGPoint::new(o.mid_x() + rad * a.cos(), o.mid_y() + rad * a.sin())
        })
        .collect();
    c.stroke_polyline(&points, 2.0, t.label2());
}

#[cfg(test)]
mod experimental_word_tests {
    /// The amber word is the tail of `experimental::tooltip`, which the Color grade text is built with.
    #[test]
    fn the_grade_text_ends_in_the_amber_word() {
        let text = sq_draw::experimental::tooltip("No Pro grade");
        assert_eq!(text.strip_suffix(super::EXPERIMENTAL_WORD), Some("No Pro grade \u{b7} "));
    }
}
