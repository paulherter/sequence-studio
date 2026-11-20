//! The r8 empty state the browsers, the timeline and the viewer share: a 20 pt icon, a title, a hint (three lines at most, cut with "…") and an
//! optional button, centered in the pane, top-aligned when the pane is shorter than the block.

use crate::stone::{ButtonKind, Touch};
use sq_uikit::tokens::{space as spacing, type_size};
use crate::{Canvas, DrawTheme, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;

/// What one empty state says.
pub struct EmptyPane<'a> {
    pub icon: SQIcon,
    pub title: &'a str,
    pub hint: &'a str,
    /// The label of the button under the hint.
    pub button: Option<&'a str>,
}

const ICON: f64 = 20.0;
const TITLE_LINE: f64 = 18.0;
const HINT_LINE: f64 = 14.0;
const BUTTON_H: f64 = 20.0;

/// `s` cut at its end with "…" so it fits `width` at `size`; whole when it fits.
pub fn ellipsize(c: &Canvas, s: &str, size: f64, width: f64) -> String {
    if c.size_of(s, size, 0).width <= width {
        return s.to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    let (mut lo, mut hi) = (0usize, chars.len());
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        let cand: String = chars[..mid].iter().collect::<String>().trim_end().to_string() + "\u{2026}";
        if c.size_of(&cand, size, 0).width <= width {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    chars[..lo].iter().collect::<String>().trim_end().to_string() + "\u{2026}"
}

/// `wrap` limited to `max` lines; the last line is cut with "…" when text is left over.
fn wrapped(c: &Canvas, s: &str, size: f64, width: f64, max: usize) -> Vec<String> {
    let mut lines = c.wrap(s, width, size);
    if lines.len() > max {
        let rest = lines[max - 1..].join(" ");
        lines.truncate(max);
        lines[max - 1] = ellipsize(c, &rest, size, width);
    }
    lines
}

/// Draws the empty state in `pane`; returns the button's frame.
pub fn draw_empty_pane(
    c: &mut Canvas,
    t: &DrawTheme,
    pane: CGRect,
    e: &EmptyPane,
    hovering: impl Fn(CGRect) -> bool,
) -> Option<CGRect> {
    let body = type_size::BODY as f64;
    let gap = spacing::SM as f64;
    let w = (pane.width - 2.0 * spacing::LG as f64).max(0.0);
    let x = pane.min_x() + spacing::LG as f64;
    let semibold = c.semibold();
    let title: Vec<String> = c
        .wrap(e.title, w, body)
        .into_iter()
        .take(2)
        .collect::<Vec<_>>();
    let title = if title.is_empty() { vec![String::new()] } else { title };
    let hint = wrapped(c, e.hint, body, w, 3);
    let block = ICON
        + gap
        + title.len() as f64 * TITLE_LINE
        + if hint.is_empty() { 0.0 } else { gap + hint.len() as f64 * HINT_LINE }
        + if e.button.is_some() { spacing::XS as f64 + gap + BUTTON_H } else { 0.0 };
    let mut y = (pane.mid_y() - block / 2.0).round().max(pane.min_y() + spacing::SM as f64);
    c.draw_icon(e.icon, CGPoint::new(pane.mid_x() - ICON / 2.0, y), ICON, t.label2(), None);
    y += ICON + gap;
    for line in &title {
        let cut = ellipsize(c, line, body, w);
        c.draw_text_in(&cut, CGRect::new(x, y, w, TITLE_LINE), body, t.label(), TextAlign::Center, 0.0, semibold);
        y += TITLE_LINE;
    }
    if !hint.is_empty() {
        y += gap;
        for line in &hint {
            c.draw_text_in(line, CGRect::new(x, y, w, HINT_LINE), body, t.label2(), TextAlign::Center, 0.0, 0);
            y += HINT_LINE;
        }
    }
    let label = e.button?;
    let bw = (c.size_of(label, body, 0).width.ceil() + 2.0 * spacing::MD as f64).min(w);
    let b = CGRect::new(pane.mid_x() - bw / 2.0, y + spacing::XS as f64 + gap, bw, BUTTON_H);
    c.stone_button(b, ButtonKind::Raised, Touch { hovering: hovering(b), ..Touch::default() }, t);
    c.draw_text_in(label, b, body, t.label(), TextAlign::Center, 0.0, 0);
    Some(b)
}

/// Which skeleton an area shows while a project opens (r8:1117-1120).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkeletonKind {
    /// Inspector: a label bar at 44 and a value bar at 152 per row.
    Inspector,
    /// Library and Project: a thumbnail chip at 12 and a name bar at 34 per row.
    Browser,
}

const SKELETON_ROW: f64 = 24.0;
const SKELETON_WIDTHS: [f64; 7] = [62.0, 48.0, 70.0, 40.0, 56.0, 66.0, 44.0];

/// Grey skeleton rows on `surface-group` over `area` (r8 `.stov.skelov`): the placeholder of a panel whose content is
/// still loading. `rows` caps the row count (15 inspector, 7 library, 10 project); fewer are drawn when the area is short.
///
/// shortcut: the rows stand still at the reduced-motion opacity (.65); the .5 to .8 pulse (`--d-pulse`) needs the UI
/// clock, upgrade when a real project open reports progress.
pub fn draw_skeleton(c: &mut Canvas, t: &DrawTheme, area: CGRect, kind: SkeletonKind, rows: usize) {
    use sq_uikit::tokens::{color::surface as tk, radius};
    c.fill(area, t.token(tk::GROUP));
    let bar = t.pressed().with_alpha(0.65);
    let r = radius::FIELD as f64;
    let fit = (area.height / SKELETON_ROW).ceil() as usize;
    for i in 0..rows.min(fit) {
        let y = area.min_y() + i as f64 * SKELETON_ROW;
        let w = SKELETON_WIDTHS[i % SKELETON_WIDTHS.len()];
        match kind {
            SkeletonKind::Inspector => {
                c.fill_rounded(CGRect::new(area.min_x() + 44.0, y + 7.0, w, 10.0), r, bar);
                c.fill_rounded(CGRect::new(area.min_x() + 152.0, y + 7.0, 34.0, 10.0), r, bar);
            }
            SkeletonKind::Browser => {
                c.fill_rounded(CGRect::new(area.min_x() + 12.0, y + 6.0, 14.0, 12.0), r, bar);
                c.fill_rounded(CGRect::new(area.min_x() + 34.0, y + 7.0, w + 40.0, 10.0), r, bar);
            }
        }
    }
}

/// The viewer's loading card (r8:758): a 20 pt loader-circle over "Opening <name>…", centered in `area`.
///
/// shortcut: the circle does not turn (reduced-motion look), upgrade with the skeleton pulse.
pub fn draw_opening(c: &mut Canvas, t: &DrawTheme, area: CGRect, text: &str) {
    let label = type_size::BODY as f64; // `--t-label`, the size of the hints
    let gap = f64::from(spacing::SM);
    let block = ICON + gap + HINT_LINE;
    let top = (area.mid_y() - block / 2.0).round();
    c.draw_icon(SQIcon::LoaderCircle, CGPoint::new(area.mid_x() - ICON / 2.0, top), ICON, t.label2(), None);
    let w = (area.width - 2.0 * spacing::LG as f64).max(0.0);
    let cut = ellipsize(c, text, label, w);
    c.draw_text_in(
        &cut,
        CGRect::new(area.min_x() + spacing::LG as f64, top + ICON + gap, w, HINT_LINE),
        label,
        t.label2(),
        TextAlign::Center,
        0.0,
        0,
    );
}
