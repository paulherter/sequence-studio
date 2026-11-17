//! The row pill of the kit: list rows (Project panel, Library, Effects) and dialog sidebar rows share one look. A hovered
//! row shows the `hover` token at once, a selected row is the `current` token (the hover fill never paints over it), both as an
//! inset rounded pill. An "Offline" pill gets a layout that keeps it out of the next column.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::stone::hover_level;
use crate::theme::{DrawTheme, radius};
use sq_uikit::controls_grid::CGRect;

/// Horizontal and vertical inset of a row pill inside its row rect.
pub const ROW_PILL_INSET: (f64, f64) = (4.0, 1.0);

/// The fill of a row pill: `current` when selected, else the hover token scaled by `hover` (0 or 1); `None` at rest.
pub fn row_pill_fill(selected: bool, hover: f32, t: &DrawTheme) -> Option<Color> {
    if selected {
        Some(t.current())
    } else if hover > 0.0 {
        let h = t.hover();
        Some(h.with_alpha(h.a * hover.clamp(0.0, 1.0)))
    } else {
        None
    }
}

/// Where the name text and the "Offline" pill go in a name cell `[name_x, name_end]` (pill text width `tag_w`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OfflineLayout {
    /// Width left for the name text.
    pub name_w: f64,
    /// The pill; `None` when the cell is too narrow (the name wins, the pill is dropped).
    pub pill: Option<CGRect>,
}

/// Name first, pill second: the pill is right-aligned to `name_end` and never reaches left of `name_x + min_name`; if it
/// would, it is dropped and the name takes the whole cell. Nothing is ever drawn right of `name_end` (the Format column).
pub fn offline_layout(name_x: f64, name_end: f64, tag_w: f64, row: CGRect, offline: bool) -> OfflineLayout {
    const GAP: f64 = 6.0;
    const PAD: f64 = 6.0;
    const ICON: f64 = 12.0;
    const MIN_NAME: f64 = 48.0;
    let full = (name_end - name_x - 4.0).max(0.0);
    if !offline {
        return OfflineLayout { name_w: full, pill: None };
    }
    let pill_w = PAD + ICON + 3.0 + tag_w + PAD;
    if full < MIN_NAME + GAP + pill_w {
        return OfflineLayout { name_w: full, pill: None };
    }
    let h = 16.0_f64.min(row.height);
    let x = name_end - 4.0 - pill_w;
    OfflineLayout { name_w: (x - GAP - name_x).max(0.0), pill: Some(CGRect::new(x, row.mid_y() - h / 2.0, pill_w, h)) }
}

impl Canvas<'_> {
    /// Paints the pill on exactly `pill` (hover is instant), for rows whose frame is already inset.
    pub fn stone_pill(&mut self, pill: CGRect, selected: bool, hovering: bool, t: &DrawTheme) {
        let level = hover_level(hovering);
        if let Some(fill) = row_pill_fill(selected, level, t) {
            self.fill_rounded(pill, f64::from(radius::CONTROL), fill);
        }
    }

    /// Paints the row pill for the full-width row at `row` and returns the pill rect.
    pub fn stone_row_pill(&mut self, row: CGRect, selected: bool, hovering: bool, t: &DrawTheme) -> CGRect {
        let pill = row.inset_by(ROW_PILL_INSET.0, ROW_PILL_INSET.1);
        self.stone_pill(pill, selected, hovering, t);
        pill
    }
}

#[cfg(test)]
#[path = "stone_rows_tests.rs"]
mod tests;
