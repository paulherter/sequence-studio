// Swift: ShellCardBrowser.swift
//! The card import board inside the import dialog (the Mac CardImportView): Videos / Photos segments with counts, the
//! sort popup and the list / grid switch on top; the files as 140 x 80 tiles with a checkbox (or list rows) on the left,
//! the last clicked file's picture, name, date and size on the right; "n selected" under it. Click selects one, Shift-click
//! a range, Ctrl-click (Command on the Mac) or the checkbox toggles one; Ctrl-A selects all files of the kind.
//!
//! Mapping: the browser is a shared handle (`Rc<RefCell<..>>`): the dialog owns one clone as its content, the import flow
//! keeps another to read the ticked files after the dialog closed (Swift shared the class instance). The scroll body's
//! clock is the time since the board was made (the content gets no frame clock). A text measure borrows the glyph atlas
//! and cannot be stored, so the widths layout needs are measured in `layout` and kept.

use crate::project_list_view::ProjectPoster;
use crate::shell_dialog::{PopupRequest, ShellDialogContent};
use crate::shell_form::segment_draw;
use sq_core_time::Timestamp;
use sq_draw::inspector::inspector_controls::CheckState;
use sq_draw::scroll::ScrollBody;
use sq_draw::theme::{metrics, radius, type_size};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, InspectorDraw, TextAlign, TextMeasure};
use sq_library::card_import::{CardCandidate, CardMediaKind, CardSelection, CardSort};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqbyte_size::SQByteSize;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Instant;

/// `SQDialogMetrics.lBodyHeight` (heightL 640 - header 48 - footer 56 - side pad 20).
const L_BODY_HEIGHT: f64 = 640.0 - 48.0 - 56.0 - 20.0;

/// A card file's picture for the board (Windows: the FFmpeg thumbnail atlas); `None` = the kind's icon.
pub type CardPoster = Box<dyn Fn(&CardCandidate) -> Option<ProjectPoster>>;

/// List rows or picture tiles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CardLayout {
    /// Picture tiles.
    Grid,
    /// One row per file.
    List,
}

mod m {
    pub const TOOLBAR: f64 = super::metrics::CAPSULE as f64;
    pub const TOOLBAR_GAP: f64 = 12.0;
    pub const TOOLBAR_TOP: f64 = 4.0;
    pub const TOOLBAR_BOTTOM: f64 = 10.0;
    pub const TOOLBAR_SIDE: f64 = 16.0;
    pub const SORT_WIDTH: f64 = 150.0;
    pub const LAYOUT_SEGMENT: f64 = 40.0;
    // art.html 42: four columns
    pub const TILE_W: f64 = 132.0;
    pub const TILE_H: f64 = 75.0;
    pub const TILE_NAME: f64 = 19.0;
    pub const TILE_GAP_X: f64 = 12.0;
    pub const TILE_GAP_Y: f64 = 14.0;
    pub const GRID_PAD: f64 = 16.0;
    pub const CHECK: f64 = 12.0;
    pub const CHECK_INSET: f64 = 6.0;
    pub const ROW_HEIGHT: f64 = 24.0;
    pub const ROW_THUMB: f64 = 20.0;
    pub const SIZE_COLUMN: f64 = 70.0;
    pub const PREVIEW_WIDTH: f64 = 261.0;
    pub const PREVIEW_PAD: f64 = 16.0;
    pub const PREVIEW_PICTURE: f64 = 168.0;
    pub const FONT: f64 = super::type_size::BODY as f64;
    pub const MINI: f64 = super::type_size::CAPTION as f64;
}

struct Inner {
    items: Vec<CardCandidate>,
    kind: CardMediaKind,
    sort: CardSort,
    layout: CardLayout,
    selection: CardSelection,
    preview_id: Option<String>,
    poster: Option<CardPoster>,
    frame: CGRect,
    kind_frames: Vec<(CardMediaKind, CGRect)>,
    sort_frame: CGRect,
    toolbar_frame: CGRect,
    layout_frames: Vec<(CardLayout, CGRect)>,
    list_frame: CGRect,
    preview_frame: CGRect,
    scroll: ScrollBody,
    hovered: Option<String>,
    /// Measured in `layout`: the width of each kind title, of the widest sort title and of every file's date.
    kind_title_widths: Vec<f64>,
    sort_width: f64,
    date_widths: BTreeMap<String, f64>,
    /// Sorts picked in the popup since the last event.
    picked: Rc<RefCell<Vec<CardSort>>>,
    popup: Option<PopupRequest>,
    started: Instant,
}

/// The card import board; clones share one board.
#[derive(Clone)]
pub struct ShellCardBrowser(Rc<RefCell<Inner>>);

/// `DateFormatter` medium date, short time, in the user's zone and the interface language's order.
pub(crate) fn date_text(t: Timestamp) -> String {
    sq_uikit::local_format::medium_date_short_time(t)
}

impl ShellCardBrowser {
    /// A board for `items`, starting on videos when there are any.
    pub fn new(items: Vec<CardCandidate>) -> ShellCardBrowser {
        let kind = if items.is_empty() || items.iter().any(|i| i.kind == CardMediaKind::Video) {
            CardMediaKind::Video
        } else {
            CardMediaKind::Photo
        };
        ShellCardBrowser(Rc::new(RefCell::new(Inner {
            items,
            kind,
            sort: CardSort::NewestFirst,
            layout: CardLayout::Grid,
            selection: CardSelection::new(),
            preview_id: None,
            poster: None,
            frame: CGRect::default(),
            kind_frames: Vec::new(),
            sort_frame: CGRect::default(),
            toolbar_frame: CGRect::default(),
            layout_frames: Vec::new(),
            list_frame: CGRect::default(),
            preview_frame: CGRect::default(),
            scroll: ScrollBody::new(0.0),
            hovered: None,
            kind_title_widths: Vec::new(),
            sort_width: m::SORT_WIDTH,
            date_widths: BTreeMap::new(),
            picked: Rc::new(RefCell::new(Vec::new())),
            popup: None,
            started: Instant::now(),
        })))
    }

    /// A file's picture for the board (Windows: the FFmpeg thumbnail atlas); `None` = the kind's icon.
    pub fn set_poster(&self, poster: CardPoster) {
        self.0.borrow_mut().poster = Some(poster);
    }

    /// The shown kind.
    pub fn kind(&self) -> CardMediaKind {
        self.0.borrow().kind
    }

    /// The chosen order.
    pub fn sort(&self) -> CardSort {
        self.0.borrow().sort
    }

    /// Grid or list.
    pub fn layout_mode(&self) -> CardLayout {
        self.0.borrow().layout
    }

    /// The files of the shown kind in the chosen order.
    pub fn visible(&self) -> Vec<CardCandidate> {
        self.0.borrow().visible()
    }

    /// The ticked files in the shown order (what an import takes).
    pub fn selected(&self) -> Vec<CardCandidate> {
        self.0.borrow().selected()
    }

    /// The file whose picture and facts the right side shows.
    pub fn preview(&self) -> Option<CardCandidate> {
        self.0.borrow().preview()
    }

    /// Files of `k`.
    pub fn count(&self, k: CardMediaKind) -> usize {
        self.0.borrow().count(k)
    }

    /// Switches the shown kind.
    pub fn set_kind(&self, k: CardMediaKind) {
        self.0.borrow_mut().set_kind(k);
    }

    /// Changes the order.
    pub fn set_sort(&self, s: CardSort) {
        self.0.borrow_mut().sort = s;
    }

    /// Grid or list.
    pub fn set_layout(&self, l: CardLayout) {
        self.0.borrow_mut().set_layout(l);
    }

    /// Ticks every file of the shown kind.
    pub fn select_all(&self) {
        let mut i = self.0.borrow_mut();
        let ids = i.visible_ids();
        i.selection.select_all(&ids);
    }

    /// A click on file `id`.
    pub fn click(&self, id: &str, shift: bool, toggle: bool) {
        self.0.borrow_mut().click(id, shift, toggle);
    }

    /// "n selected" under the board.
    pub fn status_text(&self) -> String {
        SQL10n::format("%@ selected", &[&self.0.borrow().selected().len().to_string()])
    }
}

impl Inner {
    fn visible(&self) -> Vec<CardCandidate> {
        let of_kind: Vec<CardCandidate> = self.items.iter().filter(|i| i.kind == self.kind).cloned().collect();
        self.sort.apply(&of_kind)
    }

    fn visible_ids(&self) -> Vec<String> {
        self.visible().iter().map(CardCandidate::id).collect()
    }

    fn selected(&self) -> Vec<CardCandidate> {
        self.visible().into_iter().filter(|i| self.selection.ids().contains(&i.id())).collect()
    }

    fn preview(&self) -> Option<CardCandidate> {
        let id = self.preview_id.as_ref()?;
        self.items.iter().find(|i| &i.id() == id).cloned()
    }

    fn count(&self, k: CardMediaKind) -> usize {
        self.items.iter().filter(|i| i.kind == k).count()
    }

    fn set_kind(&mut self, k: CardMediaKind) {
        if k == self.kind {
            return;
        }
        self.kind = k;
        self.scroll.assign(0.0);
        let ids = self.visible_ids();
        self.selection.prune(&ids);
        if self.preview_id.as_ref().is_some_and(|p| !ids.contains(p)) {
            self.preview_id = None;
        }
    }

    fn set_layout(&mut self, l: CardLayout) {
        self.layout = l;
        self.scroll.assign(0.0);
        self.relayout();
    }

    fn click(&mut self, id: &str, shift: bool, toggle: bool) {
        let ids = self.visible_ids();
        self.selection.click(id, &ids, shift, toggle);
        self.preview_id = Some(id.to_string());
    }

    fn kind_title(&self, k: CardMediaKind) -> String {
        SQL10n::format(
            if k == CardMediaKind::Video { "Videos (%@)" } else { "Photos (%@)" },
            &[&self.count(k).to_string()],
        )
    }

    fn relayout(&mut self) {
        // Board: 4 above, 22 high controls, 10 below, 16 at the sides, 12 between; a 1 pt line closes the band.
        let f = self.frame;
        let control_y = f.min_y() + m::TOOLBAR_TOP;
        let (inner_min, inner_max) = (f.min_x() + m::TOOLBAR_SIDE, f.max_x() - m::TOOLBAR_SIDE);
        let mut x = inner_min;
        self.kind_frames = CardMediaKind::ALL
            .iter()
            .enumerate()
            .map(|(n, k)| {
                let w = self.kind_title_widths.get(n).map_or(80.0, |w| w.ceil()) + 24.0;
                let r = CGRect::new(x, control_y, w, m::TOOLBAR);
                x += w;
                (*k, r)
            })
            .collect();
        self.layout_frames = vec![
            (
                CardLayout::List,
                CGRect::new(inner_max - 2.0 * m::LAYOUT_SEGMENT, control_y, m::LAYOUT_SEGMENT, m::TOOLBAR),
            ),
            (CardLayout::Grid, CGRect::new(inner_max - m::LAYOUT_SEGMENT, control_y, m::LAYOUT_SEGMENT, m::TOOLBAR)),
        ];
        self.sort_frame = CGRect::new(
            inner_max - 2.0 * m::LAYOUT_SEGMENT - m::TOOLBAR_GAP - self.sort_width,
            control_y,
            self.sort_width,
            m::TOOLBAR,
        );
        self.toolbar_frame =
            CGRect::new(f.min_x(), f.min_y(), f.width, m::TOOLBAR_TOP + m::TOOLBAR + m::TOOLBAR_BOTTOM);
        let top = self.toolbar_frame.max_y() + 1.0;
        let body_h = (f.max_y() - top).max(0.0);
        self.preview_frame = CGRect::new(f.max_x() - m::PREVIEW_WIDTH, top, m::PREVIEW_WIDTH, body_h);
        self.list_frame = CGRect::new(f.min_x(), top, self.preview_frame.min_x() - 1.0 - f.min_x(), body_h);
        let max = (self.content_height() - self.list_frame.height).max(0.0);
        let at = self.scroll.position().max(0.0).min(max);
        self.scroll.assign(at);
    }

    fn columns(&self) -> usize {
        (((self.list_frame.width - 2.0 * m::GRID_PAD + m::TILE_GAP_X) / (m::TILE_W + m::TILE_GAP_X)) as i64).max(1)
            as usize
    }

    fn content_height(&self) -> f64 {
        let n = self.visible().len();
        match self.layout {
            CardLayout::List => n as f64 * m::ROW_HEIGHT,
            CardLayout::Grid => {
                let rows = n.div_ceil(self.columns());
                if rows == 0 {
                    0.0
                } else {
                    2.0 * m::GRID_PAD + rows as f64 * (m::TILE_H + m::TILE_NAME) + (rows - 1) as f64 * m::TILE_GAP_Y
                }
            }
        }
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// The tile (grid) or row (list) of the `i`th visible file, scrolled.
    fn cell_frame(&mut self, i: usize) -> CGRect {
        let scroll = self.scroll.position();
        let l = self.list_frame;
        match self.layout {
            CardLayout::List => {
                CGRect::new(l.min_x(), l.min_y() + i as f64 * m::ROW_HEIGHT - scroll, l.width, m::ROW_HEIGHT)
            }
            CardLayout::Grid => {
                let cols = self.columns();
                let (col, row) = (i % cols, i / cols);
                CGRect::new(
                    l.min_x() + m::GRID_PAD + col as f64 * (m::TILE_W + m::TILE_GAP_X),
                    l.min_y() + m::GRID_PAD + row as f64 * (m::TILE_H + m::TILE_NAME + m::TILE_GAP_Y) - scroll,
                    m::TILE_W,
                    m::TILE_H + m::TILE_NAME,
                )
            }
        }
    }

    fn check_frame(&self, cell: CGRect) -> CGRect {
        match self.layout {
            CardLayout::List => CGRect::new(cell.min_x() + 8.0, cell.mid_y() - m::CHECK / 2.0, m::CHECK, m::CHECK),
            CardLayout::Grid => {
                CGRect::new(cell.min_x() + m::CHECK_INSET, cell.min_y() + m::CHECK_INSET, m::CHECK, m::CHECK)
            }
        }
    }

    fn hit(&mut self, p: CGPoint) -> Option<usize> {
        if !self.list_frame.contains(p) {
            return None;
        }
        let n = self.visible().len();
        (0..n).find(|i| self.cell_frame(*i).contains(p))
    }

    /// Applies the sorts the popup picked since the last event.
    fn sync(&mut self) {
        let picked: Vec<CardSort> = self.picked.borrow_mut().drain(..).collect();
        if let Some(s) = picked.last() {
            self.sort = *s;
        }
    }

    /// The poster fitted whole into `r` (the viewer color in the bars); `ground` is the color behind the rounded frame (its corners are painted back; none
    /// where the row color varies and the radius is a hairline).
    fn picture(
        &self,
        c: &mut Canvas,
        item: &CardCandidate,
        r: CGRect,
        rad: f64,
        ground: Option<sq_draw::Color>,
        t: &DrawTheme,
    ) {
        c.fill_rounded(r, rad, t.fill());
        if let Some(p) = self.poster.as_ref().and_then(|f| f(item)) {
            p.draw_fit(c, r, Some(t.viewer()));
            if let Some(ground) = ground {
                c.round_picture_corners(r, rad, ground);
            }
        } else {
            let s = (r.height * 0.4).min(24.0);
            let icon = if item.kind == CardMediaKind::Video { SQIcon::Film } else { SQIcon::Image };
            c.draw_icon(icon, CGPoint { x: r.mid_x() - s / 2.0, y: r.mid_y() - s / 2.0 }, s, t.label3(), None);
        }
    }

    fn draw_toolbar(&self, c: &mut Canvas, t: &DrawTheme) {
        let frames: Vec<CGRect> = self.kind_frames.iter().map(|k| k.1).collect();
        Self::segmented(c, &frames, self.kind_frames.iter().position(|k| k.0 == self.kind), t);
        for (k, r) in &self.kind_frames {
            c.draw_text_in(&self.kind_title(*k), *r, m::FONT, t.label(), TextAlign::Center, 0.0, 0);
        }
        InspectorDraw::popup(
            c,
            &SQL10n::string(self.sort.title()),
            self.sort_frame,
            false,
            false,
            true,
            false,
            f64::INFINITY,
            None,
            t,
        );
        let frames: Vec<CGRect> = self.layout_frames.iter().map(|k| k.1).collect();
        Self::segmented(c, &frames, self.layout_frames.iter().position(|k| k.0 == self.layout), t);
        for (l, r) in &self.layout_frames {
            let s = 14.0;
            let icon = if *l == CardLayout::Grid { SQIcon::Grid } else { SQIcon::List };
            c.draw_icon(icon, CGPoint { x: r.mid_x() - s / 2.0, y: r.mid_y() - s / 2.0 }, s, t.label(), None);
        }
    }

    /// One segmented control in the shared `SegmentDraw` look, the selected segment inset 1.
    fn segmented(c: &mut Canvas, frames: &[CGRect], selected: Option<usize>, t: &DrawTheme) {
        let (Some(first), Some(last)) = (frames.first(), frames.last()) else { return };
        let (x0, y0) = (first.min_x().min(last.min_x()), first.min_y().min(last.min_y()));
        let (x1, y1) = (first.max_x().max(last.max_x()), first.max_y().max(last.max_y()));
        segment_draw::track(c, CGRect::new(x0, y0, x1 - x0, y1 - y0), t);
        if let Some(n) = selected {
            segment_draw::selected(c, frames[n].inset_by(1.0, 1.0), t);
        }
    }

    fn draw_tile(&self, c: &mut Canvas, item: &CardCandidate, r: CGRect, t: &DrawTheme) {
        let pic = CGRect::new(r.min_x(), r.min_y(), m::TILE_W, m::TILE_H);
        let rad = radius::CONTROL as f64;
        self.picture(c, item, pic, rad, Some(t.content()), t);
        let id = item.id();
        if self.preview_id.as_ref() == Some(&id) {
            c.stroke_rounded(pic.inset_by(1.0, 1.0), rad, 2.0, t.label());
        } else if self.hovered.as_ref() == Some(&id) {
            c.stroke_rounded(pic.inset_by(0.5, 0.5), rad, 1.0, t.label3());
        }
        let state = if self.selection.ids().contains(&id) { CheckState::On } else { CheckState::Off };
        InspectorDraw::checkbox(c, state, self.check_frame(r), false, false, true, false, t);
        c.save_gstate();
        c.clip_to(CGRect::new(r.min_x(), pic.max_y(), r.width, m::TILE_NAME));
        c.draw_text_in(
            &item.name(),
            CGRect::new(r.min_x(), pic.max_y() + 5.0, r.width, m::TILE_NAME - 5.0),
            m::FONT,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        c.restore_gstate();
    }

    fn draw_row(&self, c: &mut Canvas, item: &CardCandidate, r: CGRect, t: &DrawTheme) {
        let id = item.id();
        let on = self.selection.ids().contains(&id);
        if on {
            c.fill(r, t.accent_fill().with_alpha(0.35));
        } else if self.preview_id.as_ref() == Some(&id) || self.hovered.as_ref() == Some(&id) {
            c.fill(r, t.fill());
        }
        InspectorDraw::checkbox(
            c,
            if on { CheckState::On } else { CheckState::Off },
            self.check_frame(r),
            false,
            false,
            true,
            false,
            t,
        );
        let thumb = CGRect::new(r.min_x() + 28.0, r.mid_y() - m::ROW_THUMB / 2.0, m::ROW_THUMB, m::ROW_THUMB);
        self.picture(c, item, thumb, 3.0, None, t);
        let size_r = CGRect::new(r.max_x() - 8.0 - m::SIZE_COLUMN, r.min_y(), m::SIZE_COLUMN, r.height);
        c.draw_text_in(&SQByteSize::string(item.size), size_r, m::MINI, t.label3(), TextAlign::Right, 0.0, 0);
        let date = date_text(item.modified);
        let date_w = self.date_widths.get(&id).map_or(110.0, |w| w.ceil());
        let date_r = CGRect::new(size_r.min_x() - 12.0 - date_w, r.min_y(), date_w, r.height);
        c.draw_text_in(&date, date_r, m::MINI, t.label3(), TextAlign::Left, 0.0, 0);
        let name_r = CGRect::new(
            thumb.max_x() + 8.0,
            r.min_y(),
            (date_r.min_x() - 12.0 - thumb.max_x() - 8.0).max(0.0),
            r.height,
        );
        c.save_gstate();
        c.clip_to(name_r);
        c.draw_text_in(&item.name(), name_r, m::FONT, t.label(), TextAlign::Left, 0.0, 0);
        c.restore_gstate();
    }

    fn draw_preview(&self, c: &mut Canvas, t: &DrawTheme) {
        let pf = self.preview_frame;
        let inner = pf.inset_by(m::PREVIEW_PAD, 0.0);
        let pic = CGRect::new(inner.min_x(), pf.min_y() + m::PREVIEW_PAD, inner.width, m::PREVIEW_PICTURE);
        let Some(item) = self.preview() else {
            c.fill_rounded(pic, radius::CONTROL as f64, t.fill());
            return;
        };
        self.picture(c, &item, pic, radius::CONTROL as f64, Some(t.overlay()), t);
        c.save_gstate();
        c.clip_to(CGRect::new(inner.min_x(), pic.max_y(), inner.width, 60.0));
        c.draw_text_in(
            &item.name(),
            CGRect::new(inner.min_x(), pic.max_y() + 8.0, inner.width, 16.0),
            m::FONT,
            t.label(),
            TextAlign::Left,
            0.0,
            c.semibold(),
        );
        c.draw_text_in(
            &format!("{} · {}", date_text(item.modified), SQByteSize::string(item.size)),
            CGRect::new(inner.min_x(), pic.max_y() + 32.0, inner.width, 14.0),
            m::MINI,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        c.restore_gstate();
    }
}

impl ShellDialogContent for ShellCardBrowser {
    fn height(&mut self, _width: f64) -> f64 {
        L_BODY_HEIGHT
    }

    fn layout(&mut self, frame: CGRect, tm: &TextMeasure) {
        let mut i = self.0.borrow_mut();
        i.frame = frame;
        i.kind_title_widths = CardMediaKind::ALL.iter().map(|k| tm.width(&i.kind_title(*k), m::FONT, 0)).collect();
        // `SQPopup.intrinsicContentSize`: the widest title plus the 10 pt inset, the 8 gap, the 7 chevron and its 7 inset.
        i.sort_width =
            CardSort::ALL.iter().map(|s| tm.width(&SQL10n::string(s.title()), m::FONT, 0)).fold(0.0, f64::max).ceil()
                + 32.0;
        i.date_widths = i.items.iter().map(|it| (it.id(), tm.width(&date_text(it.modified), m::MINI, 0))).collect();
        i.relayout();
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let mut i = self.0.borrow_mut();
        i.sync();
        let f = i.frame;
        c.fill(f, t.overlay());
        c.fill(i.list_frame, t.content());
        c.fill(CGRect::new(f.min_x(), i.toolbar_frame.max_y(), f.width, 1.0), t.separator());
        c.fill(CGRect::new(i.list_frame.max_x(), i.list_frame.min_y(), 1.0, i.list_frame.height), t.separator());
        i.draw_toolbar(c, t);
        c.save_gstate();
        c.clip_to(i.list_frame);
        let shown = i.visible();
        for (n, item) in shown.iter().enumerate() {
            let r = i.cell_frame(n);
            if r.max_y() < i.list_frame.min_y() || r.min_y() > i.list_frame.max_y() {
                continue;
            }
            if i.layout == CardLayout::Grid {
                i.draw_tile(c, item, r, t);
            } else {
                i.draw_row(c, item, r, t);
            }
        }
        if shown.is_empty() {
            let text =
                if i.kind == CardMediaKind::Video { "No videos on this card." } else { "No photos on this card." };
            c.draw_text_in(&SQL10n::string(text), i.list_frame, m::FONT, t.label3(), TextAlign::Center, 0.0, 0);
        }
        c.restore_gstate();
        let (viewport, content, now) = (i.list_frame, i.content_height(), i.now());
        i.scroll.draw_scroller(c, viewport, content, t, now);
        i.draw_preview(c, t);
    }

    fn handle(&mut self, e: &InputEvent, scale: f32) -> bool {
        let mut i = self.0.borrow_mut();
        i.sync();
        let (viewport, content, now) = (i.list_frame, i.content_height(), i.now());
        if i.scroll.scroller_event(e, scale, viewport, content, now) {
            return true;
        }
        let s = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint { x: f64::from(x) / s, y: f64::from(y) / s };
        match e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(*x, *y);
                if let Some(k) = i.kind_frames.iter().find(|k| k.1.contains(p)).map(|k| k.0) {
                    i.set_kind(k);
                    return true;
                }
                if let Some(l) = i.layout_frames.iter().find(|l| l.1.contains(p)).map(|l| l.0) {
                    i.set_layout(l);
                    return true;
                }
                if i.sort_frame.contains(p) {
                    let current = i.sort;
                    let picked = Rc::clone(&i.picked);
                    let items = CardSort::ALL
                        .iter()
                        .map(|s| {
                            let (s, picked) = (*s, Rc::clone(&picked));
                            let mut item = SQMenuItem::new(&SQL10n::string(s.title()));
                            item.is_checked = s == current;
                            item.action = Some(Rc::new(move || picked.borrow_mut().push(s)));
                            item
                        })
                        .collect();
                    i.popup = Some(PopupRequest { items, below: i.sort_frame });
                    return true;
                }
                if let Some(n) = i.hit(p) {
                    let id = i.visible()[n].id();
                    let cell = i.cell_frame(n);
                    if i.check_frame(cell).inset_by(-3.0, -3.0).contains(p) {
                        i.click(&id, false, true);
                    } else {
                        i.click(
                            &id,
                            modifiers.contains(InputModifiers::SHIFT),
                            modifiers.contains(InputModifiers::COMMAND),
                        );
                    }
                }
                i.frame.contains(p)
            }
            InputEvent::MouseMoved { x, y } => {
                let p = pt(*x, *y);
                i.hovered = i.hit(p).map(|n| i.visible()[n].id());
                false
            }
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                if !i.list_frame.contains(pt(*x, *y)) {
                    return false;
                }
                let max = (content - viewport.height).max(0.0);
                i.scroll.wheel(None, *dx, *dy, s, max, viewport.height, now);
                true
            }
            InputEvent::KeyDown { key: InputKey::Character(ch), modifiers }
                if modifiers.contains(InputModifiers::COMMAND) && ch.eq_ignore_ascii_case(&'a') =>
            {
                let ids = i.visible_ids();
                i.selection.select_all(&ids);
                true
            }
            _ => false,
        }
    }

    fn take_popup(&mut self) -> Option<PopupRequest> {
        self.0.borrow_mut().popup.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn item(name: &str, kind: CardMediaKind, size: i64, secs: f64) -> CardCandidate {
        CardCandidate {
            url: PathBuf::from(format!("/card/{name}")),
            kind,
            size,
            modified: Timestamp::from_unix_seconds(secs),
        }
    }

    fn board() -> ShellCardBrowser {
        ShellCardBrowser::new(vec![
            item("A001.mov", CardMediaKind::Video, 30, 100.0),
            item("A002.mov", CardMediaKind::Video, 20, 300.0),
            item("B001.jpg", CardMediaKind::Photo, 10, 200.0),
        ])
    }

    #[test]
    fn starts_on_videos_newest_first() {
        let b = board();
        assert_eq!(b.kind(), CardMediaKind::Video);
        let names: Vec<String> = b.visible().iter().map(CardCandidate::name).collect();
        assert_eq!(names, ["A002.mov", "A001.mov"]);
        assert_eq!(
            ShellCardBrowser::new(vec![item("p.jpg", CardMediaKind::Photo, 1, 1.0)]).kind(),
            CardMediaKind::Photo
        );
        assert_eq!(ShellCardBrowser::new(Vec::new()).kind(), CardMediaKind::Video);
    }

    #[test]
    fn clicking_selects_and_previews_and_a_kind_switch_prunes() {
        let b = board();
        b.click("/card/A001.mov", false, false);
        b.click("/card/A002.mov", false, true);
        assert_eq!(b.selected().len(), 2);
        assert_eq!(b.status_text(), "2 selected");
        assert_eq!(b.preview().map(|p| p.name()).as_deref(), Some("A002.mov"));
        b.set_kind(CardMediaKind::Photo);
        assert!(b.selected().is_empty());
        assert!(b.preview().is_none());
        b.select_all();
        assert_eq!(b.selected().len(), 1);
    }

    #[test]
    fn counts_and_sort() {
        let b = board();
        assert_eq!((b.count(CardMediaKind::Video), b.count(CardMediaKind::Photo)), (2, 1));
        b.set_sort(CardSort::Size);
        assert_eq!(b.visible()[0].name(), "A001.mov");
    }

    #[test]
    fn dates_are_written_like_the_mac_board() {
        let at = |secs: f64, lang| {
            let c = sq_core_time::local_time::civil_at_offset(Timestamp::from_unix_seconds(secs), 0);
            sq_uikit::local_format::date_time_of(&c, lang, false)
        };
        assert_eq!(at(0.0, "en"), "Jan 1, 1970, 12:00 AM");
        assert_eq!(at(0.0, "de"), "01.01.1970, 00:00");
        assert!(!date_text(Timestamp::from_unix_seconds(0.0)).is_empty());
        assert_eq!(at(1_794_001_500.0, "en"), "Nov 6, 2026, 9:45 PM");
    }
}
