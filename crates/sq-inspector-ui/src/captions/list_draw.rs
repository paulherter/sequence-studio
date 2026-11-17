// Swift: Draw/CaptionListDraw.swift
//! The read-only caption list on the shared toolkit. One row per caption (start time left, text right), the row at the
//! playhead and the selected captions marked, a click seeks. Only the visible rows are drawn, and the list scrolls by itself
//! inside the height its section gives it. Coordinates: points, y down, (0, 0) = the list's top-left.

use std::collections::BTreeSet;

use sq_core_time::{Id, Time};
use sq_draw::theme::{DrawTheme, type_size};
use sq_draw::{Canvas, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};

use crate::captions::list_model::CaptionListModel;

/// How a row is marked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mark {
    None,
    Playhead,
    Selected,
}

#[derive(Clone, Debug)]
pub struct CaptionListDraw {
    model: CaptionListModel,
    current: Option<usize>,
    selected_ids: BTreeSet<Id>,
    pub hovered: Option<usize>,
    scroll_y: f64,
    /// Left edge of the time column and the inset of the text's right edge: the Controls grid (label column, trailing).
    pub insets: (f64, f64),
}

impl Default for CaptionListDraw {
    fn default() -> Self {
        CaptionListDraw {
            model: CaptionListModel::new(),
            current: None,
            selected_ids: BTreeSet::new(),
            hovered: None,
            scroll_y: 0.0,
            insets: (ControlsGrid::LABEL_X, ControlsGrid::TRAILING),
        }
    }
}

impl CaptionListDraw {
    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit); upgrade when the tokens move into a
    // portable file.
    /// `Theme.Row.list`.
    pub const ROW_HEIGHT: f64 = 24.0;
    /// `Theme.Inspector.nameWidth`: the time column.
    pub const NAME_WIDTH: f64 = 88.0;
    /// Time column plus the inner gap (`Theme.Inspector.nameWidth + Theme.Inspector.columnGap`).
    pub const TIME_WIDTH: f64 = Self::NAME_WIDTH + 6.0;

    pub fn model(&self) -> &CaptionListModel {
        &self.model
    }

    pub fn current(&self) -> Option<usize> {
        self.current
    }

    pub fn scroll_y(&self) -> f64 {
        self.scroll_y
    }

    pub fn content_height(&self) -> f64 {
        self.model.rows().len() as f64 * Self::ROW_HEIGHT
    }

    /// True when the rows changed.
    pub fn set_model(&mut self, m: CaptionListModel) -> bool {
        if m == self.model {
            return false;
        }
        if self.hovered.is_some_and(|h| h >= m.rows().len()) {
            self.hovered = None;
        }
        self.model = m;
        true
    }

    pub fn set_playhead(&mut self, t: Time) {
        self.current = self.model.current_row(t);
    }

    pub fn set_selected(&mut self, ids: BTreeSet<Id>) {
        self.selected_ids = ids;
    }

    /// Selected (the stronger mark) wins over the playhead row.
    pub fn mark(&self, row: usize) -> Mark {
        let Some(r) = self.model.rows().get(row) else { return Mark::None };
        if self.selected_ids.contains(&r.id) {
            Mark::Selected
        } else if Some(row) == self.current {
            Mark::Playhead
        } else {
            Mark::None
        }
    }

    /// The row under `p` (list coordinates, visible part `height` tall).
    pub fn row_at(&self, p: CGPoint, height: f64) -> Option<usize> {
        if p.y < 0.0 || p.y >= height {
            return None;
        }
        let i = ((p.y + self.scroll_y) / Self::ROW_HEIGHT).floor() as usize;
        (i < self.model.rows().len()).then_some(i)
    }

    /// Row `i` in list coordinates (scrolled).
    pub fn rect(&self, row: usize, width: f64) -> CGRect {
        CGRect::new(0.0, row as f64 * Self::ROW_HEIGHT - self.scroll_y, width, Self::ROW_HEIGHT)
    }

    /// Frames of the time and the text of row `i`, scrolled (layout tests and drawing).
    pub fn columns(&self, row: usize, width: f64) -> (CGRect, CGRect) {
        let r = self.rect(row, width);
        let text_x = self.insets.0 + Self::TIME_WIDTH;
        (
            CGRect::new(self.insets.0, r.y, Self::NAME_WIDTH, r.height),
            CGRect::new(text_x, r.y, (width - text_x - self.insets.1).max(0.0), r.height),
        )
    }

    /// The wheel: `false` when the list cannot move further (the panel scrolls instead).
    pub fn scroll(&mut self, dy: f64, height: f64) -> bool {
        let y = (self.scroll_y - dy).clamp(0.0, (self.content_height() - height).max(0.0));
        if y == self.scroll_y {
            return false;
        }
        self.scroll_y = y;
        true
    }

    /// Keeps the scroll inside the content after the rows or the height changed.
    pub fn clamp_scroll(&mut self, height: f64) {
        self.scroll_y = self.scroll_y.min((self.content_height() - height).max(0.0));
    }

    /// A row's text cut to its column with an end ellipsis at a word boundary (a 200-character line was cut mid-glyph at the
    /// panel edge); a text that fits stays whole. Nothing when not even the ellipsis fits.
    pub fn fitted(c: &Canvas, text: &str, width: f64) -> String {
        c.ellipsized(text, f64::from(type_size::BODY), 0, width)
    }

    pub fn draw(&self, c: &mut Canvas, width: f64, height: f64, t: &DrawTheme) {
        if self.model.rows().is_empty() || height <= 0.0 {
            return;
        }
        let (h, fs) = (Self::ROW_HEIGHT, f64::from(type_size::BODY));
        let first = (self.scroll_y / h).floor().max(0.0) as usize;
        let last = (((self.scroll_y + height) / h).ceil() as usize).min(self.model.rows().len());
        if first >= last {
            return;
        }
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, width, height));
        for i in first..last {
            let r = self.rect(i, width);
            let row = &self.model.rows()[i];
            let m = self.mark(i);
            match m {
                Mark::Selected => c.fill(r, t.current()),
                Mark::Playhead => c.fill(r, t.hover()),
                Mark::None if Some(i) == self.hovered => c.fill(r, t.fill_hover()),
                Mark::None => {}
            }
            let (time, text) = self.columns(i, width);
            c.draw_text_in(&row.time, time, fs, t.label3(), TextAlign::Left, 0.0, 0);
            let shown = Self::fitted(c, &row.text, text.width);
            c.draw_text_in(
                &shown,
                text,
                fs,
                if m == Mark::None { t.label2() } else { t.label() },
                TextAlign::Left,
                0.0,
                0,
            );
        }
        c.restore_gstate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::TimeRange;

    use crate::captions::list_model::CaptionListRow;

    fn rows(n: u64) -> Vec<CaptionListRow> {
        (0..n)
            .map(|i| CaptionListRow {
                id: Id::fixed(i + 1),
                track: Id::fixed(100),
                range: TimeRange::from_end(Time::new(i as i64, 1), Time::new(i as i64 + 1, 1)),
                time: format!("00:0{i}"),
                text: format!("Line {i}"),
            })
            .collect()
    }

    fn list(n: u64) -> CaptionListDraw {
        let mut d = CaptionListDraw::default();
        d.set_model(CaptionListModel::from_rows_for_test(rows(n)));
        d
    }

    #[test]
    fn rows_hit_test_and_layout() {
        let d = list(5);
        assert_eq!(d.content_height(), 120.0);
        assert_eq!(d.row_at(CGPoint::new(10.0, 30.0), 100.0), Some(1));
        assert_eq!(d.row_at(CGPoint::new(10.0, 100.0), 100.0), None);
        assert_eq!(d.row_at(CGPoint::new(10.0, -1.0), 100.0), None);
        let (time, text) = d.columns(2, 300.0);
        assert_eq!((time.y, time.width), (48.0, 88.0));
        assert_eq!(text.x, d.insets.0 + 94.0);
        assert_eq!(text.width, 300.0 - text.x - d.insets.1);
    }

    #[test]
    fn selected_beats_the_playhead_mark() {
        let mut d = list(3);
        d.set_playhead(Time::new(1, 1));
        assert_eq!((d.current(), d.mark(1), d.mark(0)), (Some(1), Mark::Playhead, Mark::None));
        d.set_selected(BTreeSet::from([Id::fixed(2)]));
        assert_eq!(d.mark(1), Mark::Selected);
        assert_eq!(d.mark(9), Mark::None);
    }

    #[test]
    fn the_wheel_scrolls_inside_the_content_and_reports_the_end() {
        let mut d = list(10);
        assert!(!d.scroll(5.0, 100.0));
        assert!(d.scroll(-30.0, 100.0));
        assert_eq!(d.scroll_y(), 30.0);
        assert!(d.scroll(-500.0, 100.0));
        assert_eq!(d.scroll_y(), 140.0);
        assert!(!d.scroll(-5.0, 100.0));
        assert_eq!(d.row_at(CGPoint::new(1.0, 0.0), 100.0), Some(5));
        d.clamp_scroll(240.0);
        assert_eq!(d.scroll_y(), 0.0);
    }

    #[test]
    fn a_new_model_drops_a_stale_hover() {
        let mut d = list(5);
        d.hovered = Some(4);
        assert!(d.set_model(CaptionListModel::from_rows_for_test(rows(2))));
        assert_eq!(d.hovered, None);
        assert!(!d.set_model(CaptionListModel::from_rows_for_test(rows(2))));
    }

    #[test]
    fn a_long_caption_line_ends_in_an_ellipsis_inside_its_column() {
        let fonts = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let Some(atlas) = sq_draw::GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
        let c = Canvas::with_size(300.0, 100.0, Some(&atlas), 1.0);
        let long = "The quick brown fox jumps over the lazy dog and keeps running ".repeat(4);
        let d = list(1);
        let (_, col) = d.columns(0, 300.0);
        let shown = CaptionListDraw::fitted(&c, &long, col.width);
        assert!(shown.ends_with('\u{2026}') && shown.len() < long.len(), "{shown}");
        assert!(c.size_of(&shown, f64::from(type_size::BODY), 0).width <= col.width);
        let body = shown.trim_end_matches('\u{2026}');
        assert!(long.starts_with(body) && long[body.len()..].starts_with(' '), "cut at a word end: {shown}");
        assert_eq!(CaptionListDraw::fitted(&c, "Line 1", col.width), "Line 1");
    }

    #[test]
    fn drawing_an_empty_or_flat_list_draws_nothing() {
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(300.0, 100.0, None, 1.0);
        CaptionListDraw::default().draw(&mut c, 300.0, 100.0, &t);
        list(3).draw(&mut c, 300.0, 0.0, &t);
        list(3).draw(&mut c, 300.0, 100.0, &t);
    }
}
