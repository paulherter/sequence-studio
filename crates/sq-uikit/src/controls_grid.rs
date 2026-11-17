//! Port of `SQUIKit/Sources/SQUIKit/ControlsGrid.swift`.
//! Also home of the geometry value types (`CGPoint`, `CGSize`, `CGRect`, all `f64` like Swift's `CGFloat`) that the menu
//! layout and the graph gestures share.

/// Swift `CGPoint`, `CGSize`, `CGRect`: one definition, in `keyframe_graph_geometry`.
pub use crate::keyframe_graph_geometry::{Point as CGPoint, Rect as CGRect, Size as CGSize};

/// The `Theme.Inspector` / `Theme.Row` numbers the grid is built from. `Theme` is AppKit, so off the Mac they are
/// the literals at UI scale 1.
/// shortcut: literals off the Mac, ControlsGridTokenTests checks they match `Theme`; upgrade when the tokens move to
/// a portable file.
pub mod tokens {
    pub const RING_X: f64 = 8.0;
    pub const TOGGLE_WIDTH: f64 = 14.0;
    pub const COLUMN_GAP: f64 = 6.0;
    pub const NAME_WIDTH: f64 = 88.0;
    pub const ROW_INDENT: f64 = 12.0;
    pub const VALUE_WIDTH: f64 = 50.0;
    pub const TRAILING: f64 = 12.0;
    pub const RESET_WIDTH: f64 = 22.0;
    pub const NAVIGATION_WIDTH: f64 = 72.0;
    pub const LABEL_HEIGHT: f64 = 14.0;
    pub const ROW_HEIGHT: f64 = 24.0;
    pub const SECTION_GAP: f64 = 4.0;
    pub const CONTROL_HEIGHT: f64 = 22.0;
    pub const NAME_X: f64 = RING_X + TOGGLE_WIDTH + COLUMN_GAP;
    pub const CONTROL_X: f64 = NAME_X + NAME_WIDTH + COLUMN_GAP;
    pub const CONTROL_COLUMN_WIDTH: f64 = 3.0 * VALUE_WIDTH + 2.0 * COLUMN_GAP;
}

/// The one column grid of the Controls column (Effect Controls) and every inspector row. All rows of all sections use
/// it at every panel width, so column edges, row heights and gaps are the same everywhere. Numbers: `Theme.Inspector`.
///
/// ```text
/// | inset | indent | toggle | gap | label | gap | value 0 | gap | value 1 | gap | ... | gap | tail | trailing |
/// ```
///
/// A section header has no indent (`HEADER_TOGGLE_X`, `HEADER_LABEL_X`); the rows of an opened section sit one step
/// (`Theme.Inspector.rowIndent`) to the right of it, and a group header inside a section sits on the row edges.
///
/// Edges are outer bounds of the control in the column (button, field, swatch, checkbox), never the text inside it.
/// The keyframe lanes start where the column ends; a lane row has the y and height of its control row.
/// Portable (Windows too): the draw-list Controls panel places its rows with the same grid.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlsGrid {
    /// Width of the row (the Controls column up to the divider).
    pub width: f64,
}

impl ControlsGrid {
    // Fixed edges (independent of the width).
    /// Section header: chevron column and title, at the panel's inset.
    pub const HEADER_TOGGLE_X: f64 = tokens::RING_X;
    pub const HEADER_LABEL_X: f64 = tokens::NAME_X;
    pub const HEADER_TOGGLE_MID_X: f64 = Self::HEADER_TOGGLE_X + Self::TOGGLE_WIDTH / 2.0;
    /// The step the rows of an opened section (and a group inside it) move right of their header.
    pub const ROW_INDENT: f64 = tokens::ROW_INDENT;
    pub const TOGGLE_X: f64 = Self::HEADER_TOGGLE_X + Self::ROW_INDENT;
    pub const TOGGLE_WIDTH: f64 = tokens::TOGGLE_WIDTH;
    pub const TOGGLE_MID_X: f64 = Self::TOGGLE_X + Self::TOGGLE_WIDTH / 2.0;
    pub const GAP: f64 = tokens::COLUMN_GAP;
    pub const LABEL_X: f64 = Self::HEADER_LABEL_X + Self::ROW_INDENT;
    pub const LABEL_WIDTH: f64 = tokens::NAME_WIDTH;
    pub const VALUE_X: f64 = tokens::CONTROL_X + Self::ROW_INDENT;
    pub const VALUE_WIDTH: f64 = tokens::VALUE_WIDTH;
    /// Widest a control of a row grows (`Theme.Inspector.controlColumnWidth`), measured from `VALUE_X`.
    pub const CONTROL_COLUMN_WIDTH: f64 = tokens::CONTROL_COLUMN_WIDTH;
    pub const TRAILING: f64 = tokens::TRAILING;
    pub const RESET_WIDTH: f64 = tokens::RESET_WIDTH;
    pub const NAVIGATION_WIDTH: f64 = tokens::NAVIGATION_WIDTH;
    /// One nesting level (a group header inside a section): its chevron and title sit on the rows' toggle and label
    /// columns, one step right of the section header.
    pub const LEVEL_INDENT: f64 = Self::ROW_INDENT;

    // Heights.
    pub const ROW_HEIGHT: f64 = tokens::ROW_HEIGHT;
    pub const HEADER_HEIGHT: f64 = tokens::ROW_HEIGHT;
    pub const SECTION_GAP: f64 = tokens::SECTION_GAP;
    pub const CONTROL_HEIGHT: f64 = tokens::CONTROL_HEIGHT;
    /// The link button after a pair of fields.
    pub const LINK_WIDTH: f64 = tokens::CONTROL_HEIGHT;
    /// The narrowest a number field gets before a pair of them stacks: "0.0" at body size with the field's 8 pt insets.
    pub const MIN_FIELD: f64 = 38.0;
    pub const LABEL_HEIGHT: f64 = tokens::LABEL_HEIGHT;

    pub fn new(width: f64) -> ControlsGrid {
        ControlsGrid { width }
    }

    /// Left edge of the n-th value column.
    pub fn value_column(index: i64) -> f64 {
        Self::VALUE_X + index as f64 * (Self::VALUE_WIDTH + Self::GAP)
    }

    // Width dependent edges.
    /// Right edge of the tail column and of every control that fills its row.
    pub fn tail_max_x(&self) -> f64 {
        self.width - Self::TRAILING
    }

    pub fn reset_x(&self) -> f64 {
        self.tail_max_x() - Self::RESET_WIDTH
    }

    /// The key navigation sits left of the reset slot, which every keyframable row reserves at the trailing edge.
    pub fn navigation_x(&self) -> f64 {
        self.reset_x() - Self::GAP - Self::NAVIGATION_WIDTH
    }

    /// Right edge of the values of a row that has key navigation in its tail.
    pub fn value_max_x(&self) -> f64 {
        self.navigation_x() - Self::GAP
    }

    // Frames in a row `height` high.
    pub fn toggle_frame(&self, height: f64) -> CGRect {
        CGRect::new(Self::TOGGLE_X, 0.0, Self::TOGGLE_WIDTH, height)
    }

    /// The chevron of a section header.
    pub fn header_toggle_frame(&self, height: f64) -> CGRect {
        CGRect::new(Self::HEADER_TOGGLE_X, 0.0, Self::TOGGLE_WIDTH, height)
    }

    /// A `size` square (checkbox, ring) centered in the toggle column.
    pub fn toggle_box(&self, size: f64, height: f64) -> CGRect {
        CGRect::new(Self::TOGGLE_MID_X - size / 2.0, ((height - size) / 2.0).round(), size, size)
    }

    /// The label, from the label column to `max_x` (default: the value column).
    pub fn label_frame(&self, height: f64, max_x: Option<f64>) -> CGRect {
        let end = max_x.unwrap_or(Self::VALUE_X) - Self::GAP;
        CGRect::new(
            Self::LABEL_X,
            ((height - Self::LABEL_HEIGHT) / 2.0).round(),
            (end - Self::LABEL_X).max(0.0),
            Self::LABEL_HEIGHT,
        )
    }

    /// Whether a name `text_width` wide does not fit a label `frame_width` wide (it gets the middle cut and the tooltip).
    pub fn truncates(text_width: f64, frame_width: f64) -> bool {
        text_width > frame_width + 0.5
    }

    /// A control `width` wide and `control_height` high starting at `x`, centered in the row.
    pub fn control_frame(&self, x: f64, width: f64, height: f64, control_height: f64) -> CGRect {
        CGRect::new(x, ((height - control_height) / 2.0).round(), width.max(0.0), control_height)
    }

    /// The n-th number field.
    pub fn value_frame(&self, index: i64, height: f64) -> CGRect {
        self.control_frame(Self::value_column(index), Self::VALUE_WIDTH, height, Self::CONTROL_HEIGHT)
    }

    /// A control from the value column to `max_x` (default: the trailing inset), at most `max_width` wide
    /// (`f64::MAX` for no limit, Swift's `greatestFiniteMagnitude`).
    pub fn fill_frame(&self, height: f64, max_x: Option<f64>, max_width: f64) -> CGRect {
        let width = (max_x.unwrap_or(self.tail_max_x()) - Self::VALUE_X).min(max_width);
        self.control_frame(Self::VALUE_X, width, height, Self::CONTROL_HEIGHT)
    }

    /// Right edge of the number fields: the key navigation's left edge, or, where the panel is too narrow for the
    /// navigation to leave any room (below `VALUE_X + MIN_FIELD`), the reset slot's.
    pub fn field_limit(&self) -> f64 {
        if self.value_max_x() - Self::VALUE_X >= Self::MIN_FIELD {
            self.value_max_x()
        } else {
            self.reset_x() - Self::GAP
        }
    }

    /// Width the `count` fields of a row (and the link button after them, when `has_link`) can have side by side, or
    /// `None` when even `MIN_FIELD` each does not fit: the row then stacks its fields.
    fn side_by_side_width(&self, count: usize, has_link: bool) -> Option<f64> {
        let n = count.max(1) as f64;
        let link = if has_link && count > 1 { Self::GAP + Self::LINK_WIDTH } else { 0.0 };
        let w =
            ((self.field_limit() - Self::VALUE_X - link - (n - 1.0) * Self::GAP) / n).floor().min(Self::VALUE_WIDTH);
        if count <= 1 { Some(w.max(Self::MIN_FIELD)) } else { (w >= Self::MIN_FIELD).then_some(w) }
    }

    /// Whether the `count` fields of a row do not fit side by side at this width (they stack under the label).
    pub fn fields_stack(&self, count: usize, has_link: bool) -> bool {
        count > 1 && self.side_by_side_width(count, has_link).is_none()
    }

    /// Height of a parameter row with `count` fields: one row, or `count` rows when the fields stack.
    pub fn fields_row_height(&self, count: usize, has_link: bool) -> f64 {
        if self.fields_stack(count, has_link) { count as f64 * Self::ROW_HEIGHT } else { Self::ROW_HEIGHT }
    }

    /// Width of one number field of a row with `count` fields: `VALUE_WIDTH` where there is room, shrinking to
    /// `MIN_FIELD` before the row stacks.
    pub fn field_width(&self, count: usize, has_link: bool) -> f64 {
        match self.side_by_side_width(count, has_link) {
            Some(w) => w,
            None => (self.field_limit() - Self::VALUE_X).clamp(Self::MIN_FIELD, Self::VALUE_WIDTH),
        }
    }

    /// The `index`-th of `count` number fields in a row `row_height` high (`fields_row_height`): beside each other, or one
    /// per `ROW_HEIGHT` strip when stacked.
    pub fn field_frame(&self, index: usize, count: usize, has_link: bool, row_height: f64) -> CGRect {
        let w = self.field_width(count, has_link);
        if self.fields_stack(count, has_link) {
            let strip = row_height / count as f64;
            let mut f = self.control_frame(Self::VALUE_X, w, strip, Self::CONTROL_HEIGHT);
            f.y += index as f64 * strip;
            f
        } else {
            let x = Self::VALUE_X + index as f64 * (w + Self::GAP);
            self.control_frame(x, w, row_height, Self::CONTROL_HEIGHT)
        }
    }

    /// The link button (or eyedropper) after the fields: right of the last field, centered in the row.
    pub fn link_frame_after(&self, count: usize, has_link: bool, row_height: f64) -> CGRect {
        let w = self.field_width(count, has_link);
        let n = if self.fields_stack(count, has_link) { 1.0 } else { count.max(1) as f64 };
        let x = Self::VALUE_X + n * w + (n - 1.0) * Self::GAP + Self::GAP;
        self.control_frame(x, Self::CONTROL_HEIGHT, row_height, Self::CONTROL_HEIGHT)
    }

    pub fn reset_frame(&self, height: f64) -> CGRect {
        CGRect::new(self.reset_x(), 0.0, Self::RESET_WIDTH, height)
    }

    pub fn navigation_frame(&self, height: f64) -> CGRect {
        CGRect::new(self.navigation_x(), 0.0, Self::NAVIGATION_WIDTH, height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_edges_follow_the_tokens() {
        assert_eq!(tokens::NAME_X, 28.0);
        assert_eq!(tokens::CONTROL_X, 122.0);
        assert_eq!(tokens::CONTROL_COLUMN_WIDTH, 162.0);
        assert_eq!(ControlsGrid::TOGGLE_X, 20.0);
        assert_eq!(ControlsGrid::TOGGLE_MID_X, 27.0);
        assert_eq!(ControlsGrid::HEADER_TOGGLE_MID_X, 15.0);
        assert_eq!(ControlsGrid::LABEL_X, 40.0);
        assert_eq!(ControlsGrid::VALUE_X, 134.0);
        assert_eq!(ControlsGrid::value_column(2), 134.0 + 2.0 * 56.0);
    }

    #[test]
    fn width_dependent_edges() {
        let g = ControlsGrid::new(400.0);
        assert_eq!(g.tail_max_x(), 388.0);
        assert_eq!(g.reset_x(), 366.0);
        assert_eq!(g.navigation_x(), 288.0);
        assert_eq!(g.value_max_x(), 282.0);
        assert_eq!(g.reset_frame(24.0), CGRect::new(366.0, 0.0, 22.0, 24.0));
    }

    #[test]
    fn frames_are_centered_in_the_row() {
        let g = ControlsGrid::new(400.0);
        assert_eq!(g.value_frame(1, 24.0), CGRect::new(190.0, 1.0, 50.0, 22.0));
        assert_eq!(g.toggle_box(12.0, 24.0), CGRect::new(21.0, 6.0, 12.0, 12.0));
        assert_eq!(g.label_frame(24.0, None), CGRect::new(40.0, 5.0, 88.0, 14.0));
        assert_eq!(g.label_frame(24.0, Some(30.0)).width, 0.0);
        assert_eq!(g.fill_frame(24.0, None, f64::MAX).width, 388.0 - 134.0);
        assert_eq!(g.fill_frame(24.0, Some(300.0), 100.0).width, 100.0);
        assert!(!ControlsGrid::truncates(100.5, 100.0) && ControlsGrid::truncates(100.6, 100.0));
    }

    /// Every pair of fields stays inside the row at every width the panel can have: side by side with at least
    /// `MIN_FIELD` each, or stacked.
    #[test]
    fn pairs_fit_every_width_down_to_the_real_640x400_panel() {
        for width in [229.0, 240.0, 300.0, 330.0, 360.0, 420.0, 640.0] {
            let g = ControlsGrid::new(width);
            for (count, link) in [(2, false), (2, true), (1, true), (1, false)] {
                let h = g.fields_row_height(count, link);
                for i in 0..count {
                    let f = g.field_frame(i, count, link, h);
                    assert!(f.width >= ControlsGrid::MIN_FIELD, "{width}: field {i} is {}", f.width);
                    assert!(f.max_x() <= g.tail_max_x() + 0.01, "{width}: field {i} ends at {}", f.max_x());
                    assert!(f.min_y() >= 0.0 && f.max_y() <= h, "{width}: field {i} leaves the row");
                }
                if count == 2 {
                    let (a, b) = (g.field_frame(0, 2, link, h), g.field_frame(1, 2, link, h));
                    assert!(a.max_x() <= b.min_x() || a.max_y() <= b.min_y(), "{width}: fields overlap");
                }
            }
        }
        // 229 pt (the panel of the 640x400 layout) stacks; the minimum Controls width keeps the full size side by side.
        assert!(ControlsGrid::new(229.0).fields_stack(2, false));
        assert_eq!(ControlsGrid::new(229.0).fields_row_height(2, false), 2.0 * ControlsGrid::ROW_HEIGHT);
        assert!(!ControlsGrid::new(360.0).fields_stack(2, false));
        assert_eq!(
            ControlsGrid::new(360.0).field_frame(1, 2, false, 24.0),
            ControlsGrid::new(360.0).value_frame(1, 24.0)
        );
        assert_eq!(ControlsGrid::new(360.0).link_frame_after(2, false, 24.0).min_x(), ControlsGrid::value_column(2));
    }
}
