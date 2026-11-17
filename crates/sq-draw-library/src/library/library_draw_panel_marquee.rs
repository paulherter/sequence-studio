// Swift: LibraryDrawPanel+Marquee.swift
//! Rubber-band selection on the grid's empty background: the AppKit grid is an `NSCollectionView`, which selects the tiles
//! a drag from empty space crosses (Cmd or Shift keeps the earlier selection). The list has none (`NSTableView`).

use crate::geom::intersects;
use crate::library::library_draw_panel::{LibraryDrawPanel, Marquee};
use crate::library::library_panel_model::LibraryViewMode;
use sq_draw::{Canvas, DrawTheme, InputModifiers};
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl LibraryDrawPanel {
    pub(crate) fn content_point(&mut self, p: CGPoint) -> CGPoint {
        let lr = self.list_rect();
        CGPoint::new(p.x - lr.min_x(), p.y - lr.min_y() + self.scroll())
    }

    pub(crate) fn begin_marquee(&mut self, p: CGPoint, m: InputModifiers) {
        if self.model.view_mode() != LibraryViewMode::Grid
            || m.contains(InputModifiers::SECONDARY)
            || !self.list_rect().contains(p)
        {
            return;
        }
        let q = self.content_point(p);
        let keep = m.contains(InputModifiers::COMMAND) || m.contains(InputModifiers::SHIFT);
        self.marquee =
            Some(Marquee { start: q, current: q, base: if keep { self.selected.clone() } else { Default::default() } });
    }

    pub(crate) fn drag_marquee(&mut self, p: CGPoint) {
        let Some(mut mq) = self.marquee.take() else { return };
        let lr = self.list_rect();
        mq.current = self.content_point(CGPoint::new(p.x.clamp(lr.min_x(), lr.max_x()), p.y));
        let band = mq.rect();
        let hit: Vec<String> = self
            .placed()
            .iter()
            .filter(|pl| !self.cells()[pl.index].is_header() && intersects(&pl.frame, &band))
            .map(|pl| self.cells()[pl.index].key())
            .collect();
        let mut next = mq.base.clone();
        next.extend(hit);
        self.marquee = Some(mq);
        if next == self.selected {
            return;
        }
        self.selected = next;
        self.preview_selection();
    }

    pub(crate) fn draw_marquee(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let Some(mq) = &self.marquee else { return };
        let band = mq.rect();
        if band.width <= 0.0 && band.height <= 0.0 {
            return;
        }
        let lr = self.list_rect();
        let scroll = self.scroll();
        let r = CGRect::new(band.x + lr.min_x(), band.y + lr.min_y() - scroll, band.width, band.height);
        c.fill(r, t.accent().with_alpha(0.18));
        c.stroke_rounded(r, 0.0, 1.0, t.accent());
    }
}
