// Swift: SQAppShell/MarkerListHost.swift
//! The Marker List panel in a dock slot: a filter field on top (Export CSV is in the panel's ••• menu), then the table of the sequence's markers
//! (flag, Time, Name, Length, Comment). A click goes to the marker, the row the playhead is in stays selected.

use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_draw::glyph_atlas::TextAlign;
use sq_draw::inspector::text_field_control::{Alignment, TextFieldControl};
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers};
use sq_editor_session::{Change, EditorSession};
use sq_export::formats::MarkerCsv;
use sq_timeline_ui::marker_index_model::{MarkerIndexModel, MarkerSortKey};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::Cell;
use std::rc::Rc;

const PAD: f64 = spacing::SM as f64;
const FIELD_HEIGHT: f64 = 22.0;
const ROW_HEIGHT: f64 = 24.0;
const HEADER_HEIGHT: f64 = 24.0;
/// Column widths (the last, Comment, takes the rest).
/// Narrowest the panel is laid out at: dot, time, a shortened name and length fit without cutting any of them.
#[cfg(test)]
const MIN_WIDTH: f64 = 260.0; // mirrors PanelID::MarkerList.min_size()
/// Height of the hint line under a non-empty list.
const FOOTER_HEIGHT: f64 = 34.0;
/// Line height of the hint.
const HINT_LINE: f64 = 15.0;
/// The hint under the list.
const HINT: &str =
    "Click a row to jump there. Double-click a name to edit it. Export CSV is in the \u{2022}\u{2022}\u{2022} menu.";
const COLUMNS: [(&str, f64); 5] = [("", 22.0), ("Time", 84.0), ("Name", 140.0), ("Length", 76.0), ("Comment", 200.0)];

/// The Marker List panel.
pub struct MarkerListHost {
    model: MarkerIndexModel,
    frame: CGRect,
    selected: Option<usize>,
    scroll: f64,
    search: TextFieldControl,
    hovered: Option<usize>,
    /// The cells whose text was cut at the last draw with their full text (the tooltip).
    cut_cells: Vec<(CGRect, String)>,
    /// The ••• button in the dock strip (set by the root; `None` hides it) and its hover.
    options: Option<CGRect>,
    options_hover: bool,
    /// Set by the menu row "Export CSV"; run by [`MarkerListHost::pump`].
    export_asked: Rc<Cell<bool>>,
    /// The ••• menu waiting for the root to open it, with its anchor.
    menu: Option<(Vec<SQMenuItem>, CGPoint)>,
    /// The name field of a row being renamed (double-click on its name) and that marker.
    rename: TextFieldControl,
    renaming: Option<sq_core_time::Id>,
    /// The last row click, for the double click.
    last_click: Option<(usize, std::time::Instant)>,
    /// The sequence the model was last read from and the project version of that read.
    loaded: Option<sq_core_time::Id>,
    synced_edit: u64,
}

impl MarkerListHost {
    /// A cell text cut in the middle to the cell width (6 pt inset each side); `full` is set when it was cut.
    fn cut(c: &Canvas, text: &str, cell: CGRect, size: f64) -> sq_draw::middle_fit::TruncatedLabel {
        let room = (cell.width - 12.0).max(0.0);
        sq_draw::middle_fit::truncate_name(text, |n| c.size_of(n, size, 0).width <= room)
    }

    /// An empty list.
    pub fn new() -> MarkerListHost {
        let mut search = TextFieldControl::new("");
        search.alignment = Alignment::Left;
        search.quiet = true;
        search.font_size = f64::from(type_size::BODY);
        search.text_inset = 28.0;
        "Filter markers".clone_into(&mut search.placeholder);
        MarkerListHost {
            model: MarkerIndexModel::new(),
            frame: CGRect::default(),
            selected: None,
            scroll: 0.0,
            search,
            hovered: None,
            cut_cells: Vec::new(),
            options: None,
            options_hover: false,
            export_asked: Rc::new(Cell::new(false)),
            menu: None,
            rename: {
                let mut f = TextFieldControl::new("");
                f.alignment = Alignment::Left;
                f.font_size = f64::from(type_size::BODY);
                f
            },
            renaming: None,
            last_click: None,
            loaded: None,
            synced_edit: u64::MAX,
        }
    }

    /// The rows after the filter, the playhead's row selected.
    pub fn model(&self) -> &MarkerIndexModel {
        &self.model
    }

    /// The selected row (index into the filtered rows).
    pub fn selected_row(&self) -> Option<usize> {
        self.selected
    }

    fn field_rect(&self) -> CGRect {
        CGRect::new(
            self.frame.min_x() + PAD,
            self.frame.min_y() + PAD,
            (self.frame.width - 2.0 * PAD).max(60.0),
            FIELD_HEIGHT,
        )
    }

    /// Sets where the ••• button sits (the root reads it from the dock's strip); `None` hides it.
    pub fn set_options_rect(&mut self, r: Option<CGRect>) {
        self.options = r;
        if r.is_none() {
            self.options_hover = false;
        }
    }

    /// The ••• menu: Export CSV (disabled without markers).
    pub fn options_items(&self) -> Vec<SQMenuItem> {
        let asked = Rc::clone(&self.export_asked);
        let mut item = SQMenuItem::new("Export CSV\u{2026}");
        item.is_enabled = !self.model.entries().is_empty();
        item.action = Some(Rc::new(move || asked.set(true)));
        vec![item]
    }

    /// The ••• menu a click asked for, with its anchor; the root opens it.
    pub fn take_menu(&mut self) -> Option<(Vec<SQMenuItem>, CGPoint)> {
        self.menu.take()
    }

    /// Runs what a picked menu row asked for.
    pub fn pump(&mut self, cx: &mut HostCx) {
        if self.export_asked.replace(false) {
            self.export_csv(cx);
        }
    }

    /// The sort a column head stands for.
    fn sort_key_of(col: usize) -> Option<MarkerSortKey> {
        match col {
            1 => Some(MarkerSortKey::Time),
            2 => Some(MarkerSortKey::Name),
            3 => Some(MarkerSortKey::Length),
            _ => None,
        }
    }

    /// The column widths for a table `total` wide: dot, time and length keep their size, the name gives way first (down to
    /// 60 pt) and the comment takes what is left, so a narrow panel never cuts a column at its edge.
    fn column_widths(total: f64) -> [f64; 5] {
        let fixed = COLUMNS[0].1 + COLUMNS[1].1 + COLUMNS[3].1;
        let name = (total - fixed).clamp(60.0, COLUMNS[2].1);
        let comment = (total - fixed - name).max(0.0);
        [COLUMNS[0].1, COLUMNS[1].1, name, COLUMNS[3].1, comment]
    }

    fn header_column_at(&self, p: CGPoint) -> Option<usize> {
        let t = self.table_rect();
        if p.y < t.min_y() || p.y >= t.min_y() + HEADER_HEIGHT {
            return None;
        }
        let mut x = t.min_x();
        for (i, w) in Self::column_widths(t.width).iter().enumerate() {
            let end = if i == COLUMNS.len() - 1 { t.max_x() } else { x + w };
            if p.x >= x && p.x < end {
                return Some(i);
            }
            x = end;
        }
        None
    }

    fn table_rect(&self) -> CGRect {
        let top = self.frame.min_y() + PAD * 2.0 + FIELD_HEIGHT;
        CGRect::new(self.frame.min_x(), top, self.frame.width, (self.frame.max_y() - top).max(0.0))
    }

    fn list_rect(&self) -> CGRect {
        let t = self.table_rect();
        let footer = if self.model.entries().is_empty() { 0.0 } else { FOOTER_HEIGHT };
        CGRect::new(t.min_x(), t.min_y() + HEADER_HEIGHT, t.width, (t.height - HEADER_HEIGHT - footer).max(0.0))
    }

    fn max_scroll(&self) -> f64 {
        (self.model.rows().len() as f64 * ROW_HEIGHT - self.list_rect().height).max(0.0)
    }

    fn row_rect(&self, i: usize) -> CGRect {
        let l = self.list_rect();
        CGRect::new(l.min_x(), l.min_y() + i as f64 * ROW_HEIGHT - self.scroll, l.width, ROW_HEIGHT)
    }

    fn row_at(&self, p: CGPoint) -> Option<usize> {
        let l = self.list_rect();
        if !l.contains(p) {
            return None;
        }
        let i = ((p.y - l.min_y() + self.scroll) / ROW_HEIGHT).floor();
        (i >= 0.0 && (i as usize) < self.model.rows().len()).then_some(i as usize)
    }

    /// Reloads when the sequence or its markers changed and keeps the playhead's row selected (the Mac `syncMarkerList`).
    fn refresh(&mut self, session: &EditorSession) {
        let Some(t) = session.active_timeline() else { return };
        let stamp = session.version(Change::PROJECT);
        if self.loaded != Some(t.id) || self.synced_edit != stamp {
            self.model.reload(t);
            self.loaded = Some(t.id);
            self.synced_edit = stamp;
        }
        let now = self.model.current_row(session.playhead());
        if now != self.selected {
            self.selected = now;
            if let Some(i) = now {
                self.reveal(i);
            }
        }
    }

    fn reveal(&mut self, i: usize) {
        let (r, l) = (self.row_rect(i), self.list_rect());
        if r.min_y() < l.min_y() {
            self.scroll -= l.min_y() - r.min_y();
        } else if r.max_y() > l.max_y() {
            self.scroll += r.max_y() - l.max_y();
        }
        self.scroll = self.scroll.clamp(0.0, self.max_scroll());
    }

    /// Export CSV: every marker of the sequence, written where the user picks (the Mac `exportMarkersCSV`).
    pub fn export_csv(&self, cx: &mut HostCx) {
        let Some(t) = cx.session.active_timeline() else {
            cx.emit(AppEvent::Status("There is no sequence to export.".to_string()));
            return;
        };
        if MarkerCsv::rows(t).is_empty() {
            cx.emit(AppEvent::Status("There are no markers to export.".to_string()));
            return;
        }
        let (name, text) = (format!("{} Markers.csv", t.name), MarkerCsv::export(t).text);
        let Some(path) = cx.services.panel_files.choose_csv_location(&name) else { return };
        let line = match std::fs::write(&path, text) {
            Ok(()) => {
                format!("Exported {}.", path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()))
            }
            Err(e) => format!("Could not write the CSV file: {e}"),
        };
        cx.emit(AppEvent::Status(line));
    }

    /// The cell of column `col` of row `i`.
    fn cell_rect(&self, i: usize, col: usize) -> CGRect {
        let rr = self.row_rect(i);
        let widths = Self::column_widths(rr.width);
        let x: f64 = widths[..col].iter().sum();
        let w = if col == COLUMNS.len() - 1 { (rr.width - x).max(0.0) } else { widths[col] };
        CGRect::new(rr.min_x() + x, rr.min_y(), w, rr.height)
    }

    /// Starts renaming row `i` in place.
    fn begin_rename(&mut self, i: usize) {
        let Some(e) = self.model.rows().get(i).map(|e| (e.marker, e.name.clone())) else { return };
        self.rename.text = e.1;
        self.rename.cancel();
        self.rename.mouse_down(None, 1);
        self.renaming = Some(e.0);
    }

    /// Whether a marker name field is open.
    pub(crate) fn is_renaming(&self) -> bool {
        self.renaming.is_some()
    }

    /// Commits the open name field and closes the search field (a menu chord, the window losing the keyboard).
    pub(crate) fn end_text_edits(&mut self, cx: &mut HostCx) {
        self.end_rename(true, cx);
        if self.search.is_editing() {
            let _ = self.search.commit();
        }
    }

    /// Ends the rename: `accept` writes the typed name to the marker (one undo step); an unchanged name does nothing.
    pub(crate) fn end_rename(&mut self, accept: bool, cx: &mut HostCx) {
        let Some(id) = self.renaming.take() else { return };
        let typed = self.rename.editor().map(|e| e.string());
        self.rename.cancel();
        let Some(name) = typed.filter(|_| accept) else { return };
        let Some(e) = self.model.entries().iter().find(|e| e.marker == id).cloned() else { return };
        if e.name != name {
            cx.session.edit_marker(id, &name, e.color, &e.comment);
        }
    }

    fn key(&mut self, key: InputKey, m: InputModifiers, cx: &mut HostCx) -> bool {
        if self.renaming.is_some() {
            match key {
                InputKey::Escape => self.end_rename(false, cx),
                InputKey::Enter => self.end_rename(true, cx),
                _ => {
                    let _ = self.rename.key(key, m, cx.ui);
                }
            }
            return true;
        }
        if !self.search.is_editing() {
            return false;
        }
        if key == InputKey::Escape {
            self.search.cancel();
            self.search.text.clear();
        } else {
            let _ = self.search.key(key, m, cx.ui);
        }
        self.model.query = self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string());
        self.selected = self.model.current_row(cx.session.playhead());
        self.scroll = self.scroll.min(self.max_scroll());
        true
    }
}

impl Default for MarkerListHost {
    fn default() -> Self {
        MarkerListHost::new()
    }
}

impl AppHost for MarkerListHost {
    fn sync(&mut self, session: &EditorSession) {
        self.refresh(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        self.refresh(cx.session);
        self.scroll = self.scroll.min(self.max_scroll());
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        if self.frame.width <= 0.0 || self.frame.height <= 0.0 {
            return;
        }
        let body = f64::from(type_size::BODY);
        let caption = f64::from(type_size::CAPTION);
        let field = self.field_rect();
        let editing = self.search.is_editing();
        self.search.draw(c, field, t, editing, cx.ui);
        c.draw_icon(SQIcon::Search, CGPoint::new(field.min_x() + 9.0, field.mid_y() - 6.0), 12.0, t.label3(), None);
        if let Some(r) = self.options {
            if self.options_hover {
                c.fill_rounded(r, f64::from(radius::SMALL), t.fill_hover());
            }
            c.draw_icon(SQIcon::Ellipsis, CGPoint::new(r.mid_x() - 7.0, r.mid_y() - 7.0), 14.0, t.label2(), None);
        }
        let table = self.table_rect();
        let header = CGRect::new(table.min_x(), table.min_y(), table.width, HEADER_HEIGHT);
        c.fill(CGRect::new(header.min_x(), header.max_y() - 1.0, header.width, 1.0), t.separator());
        let mut x = header.min_x();
        let widths = Self::column_widths(table.width);
        for (i, (title, _)) in COLUMNS.iter().enumerate() {
            let w = if i == COLUMNS.len() - 1 { (header.max_x() - x).max(0.0) } else { widths[i] };
            if !title.is_empty() && w >= 40.0 {
                let cell = CGRect::new(x, header.min_y(), w, header.height);
                c.draw_text_in(title, cell, caption, t.label3(), TextAlign::Left, 6.0, 0);
                if Self::sort_key_of(i) == Some(self.model.sort.0) {
                    let icon = if self.model.sort.1 { SQIcon::ChevronUp } else { SQIcon::ChevronDown };
                    // Directly after the title (kit), not at the column's right edge.
                    let tw = sq_draw::TextMeasure::new(c.atlas(), c.scale).width(title, caption, 0);
                    let at = CGPoint::new((cell.min_x() + 6.0 + tw + 3.0).min(cell.max_x() - 12.0), cell.mid_y() - 5.0);
                    c.draw_icon(icon, at, 10.0, t.label2(), None);
                }
            }
            x += w;
        }
        let list = self.list_rect();
        let rows = self.model.rows();
        if rows.is_empty() {
            let empty = self.model.entries().is_empty();
            let title = if empty { "No markers" } else { "No matches" };
            let r = CGRect::new(list.min_x(), list.mid_y() - 18.0, list.width, 18.0);
            c.draw_text_in(title, r, body, t.label2(), TextAlign::Center, 0.0, 0);
            if empty {
                let r = CGRect::new(list.min_x(), list.mid_y(), list.width, 16.0);
                c.draw_text_in(
                    "Press M to add a marker at the playhead",
                    r,
                    caption,
                    t.label3(),
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            return;
        }
        let widths = Self::column_widths(table.width);
        c.save_gstate();
        c.clip_to(list);
        let mut cut_cells: Vec<(CGRect, String)> = Vec::new();
        for (i, e) in rows.iter().enumerate() {
            let rr = self.row_rect(i);
            if rr.max_y() < list.min_y() || rr.min_y() > list.max_y() {
                continue;
            }
            let pill = rr.inset_by(f64::from(spacing::XS), 1.0);
            if Some(i) == self.selected {
                c.fill_rounded(pill, f64::from(radius::SMALL), t.current());
            } else if Some(i) == self.hovered {
                c.fill_rounded(pill, f64::from(radius::SMALL), t.fill_hover());
            }
            let mut cx_ = rr.min_x();
            for (ci, &width) in widths.iter().enumerate() {
                let w = if ci == COLUMNS.len() - 1 { (rr.max_x() - cx_).max(0.0) } else { width };
                let cell = CGRect::new(cx_, rr.min_y(), w, rr.height);
                cx_ += w;
                match ci {
                    0 => {
                        // The marker's color as a dot.
                        let dot = CGRect::new(cell.mid_x() - 4.0, cell.mid_y() - 4.0, 8.0, 8.0);
                        c.fill_rounded(dot, 4.0, sq_draw_timeline::skin::marker_color(e.color, t));
                    }
                    1 => {
                        c.draw_text_in(&self.model.text(e.time), cell, caption, t.label2(), TextAlign::Left, 6.0, 0);
                    }
                    2 => {
                        if self.renaming == Some(e.marker) {
                            self.rename.draw(c, cell.inset_by(2.0, 1.0), t, true, cx.ui);
                        } else {
                            let ink = if e.name.is_empty() { t.label2() } else { t.label() };
                            let cut = Self::cut(c, e.display_name(), cell, body);
                            if let Some(full) = cut.full {
                                cut_cells.push((cell, full));
                            }
                            c.draw_text_in(&cut.shown, cell, body, ink, TextAlign::Left, 6.0, 0);
                        }
                    }
                    3 => {
                        c.draw_text_in(
                            &self.model.duration_text(e),
                            cell,
                            caption,
                            t.label2(),
                            TextAlign::Left,
                            6.0,
                            0,
                        );
                    }
                    _ => {
                        let cut = Self::cut(c, &e.comment, cell, body);
                        if let Some(full) = cut.full {
                            cut_cells.push((cell, full));
                        }
                        c.draw_text_in(&cut.shown, cell, body, t.label2(), TextAlign::Left, 6.0, 0);
                    }
                }
            }
        }
        c.restore_gstate();
        self.cut_cells = cut_cells;
        let hint = CGRect::new(list.min_x(), list.max_y(), list.width, FOOTER_HEIGHT);
        for (i, line) in hint_lines(c, hint.width - 2.0 * PAD, caption).iter().enumerate() {
            let row = CGRect::new(hint.min_x(), hint.min_y() + i as f64 * HINT_LINE, hint.width, HINT_LINE);
            c.draw_text_in(line, row, caption, t.label3(), TextAlign::Left, PAD, 0);
        }
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let k = f64::from(cx.scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                self.hovered = if self.frame.contains(p) { self.row_at(p) } else { None };
                self.options_hover = self.options.is_some_and(|r| r.contains(p));
                self.search.hovering = self.field_rect().contains(p);
                let tip = self.cut_cells.iter().find(|(r, _)| r.contains(p)).map(|(_, full)| full.as_str());
                cx.ui.hover.offer_tip(tip);
                false
            }
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(x, y);
                if let Some(r) =
                    self.options.filter(|r| r.contains(p) && !modifiers.contains(InputModifiers::SECONDARY))
                {
                    self.menu = Some((self.options_items(), CGPoint::new(r.min_x(), r.max_y())));
                    return true;
                }
                if !self.frame.contains(p) {
                    if self.search.is_editing() {
                        let _ = self.search.commit();
                    }
                    return false;
                }
                if self.field_rect().contains(p) {
                    if !self.search.is_editing() {
                        self.search.mouse_down(None, 1);
                    }
                    return true;
                }
                if self.search.is_editing() {
                    let _ = self.search.commit();
                }
                if self.renaming.is_some() {
                    let inside = self.row_at(p).is_some_and(|i| {
                        self.renaming == Some(self.model.rows()[i].marker) && self.cell_rect(i, 2).contains(p)
                    });
                    if inside {
                        return true;
                    }
                    self.end_rename(true, cx);
                }
                if let Some(col) = self.header_column_at(p)
                    && let Some(key) = Self::sort_key_of(col)
                {
                    self.model.toggle_sort(key);
                    self.selected = self.model.current_row(cx.session.playhead());
                    return true;
                }
                if let Some(i) = self.row_at(p) {
                    let again = self.last_click.is_some_and(|(r, at)| r == i && at.elapsed().as_millis() < 400);
                    self.last_click = Some((i, std::time::Instant::now()));
                    if again && self.cell_rect(i, 2).contains(p) {
                        self.begin_rename(i);
                        return true;
                    }
                    self.selected = Some(i);
                    let time = self.model.rows()[i].time;
                    cx.session.seek(time);
                }
                true
            }
            InputEvent::MouseDragged { .. } | InputEvent::MouseUp { .. } => false,
            InputEvent::Scroll { x, y, dy, .. } => {
                if !self.list_rect().contains(pt(x, y)) {
                    return false;
                }
                self.scroll = (self.scroll - f64::from(dy) / k).clamp(0.0, self.max_scroll());
                true
            }
            InputEvent::KeyDown { key, modifiers } => self.key(key, modifiers, cx),
        }
    }
}

/// The hint in at most two lines, broken at word boundaries; what still does not fit ends in an ellipsis after a
/// whole word, never in the middle of one.
fn hint_lines(c: &Canvas, width: f64, size: f64) -> Vec<String> {
    let mut lines = c.wrap(HINT, width, size);
    if lines.len() > 2 {
        let rest = lines.split_off(1).join(" ");
        let words: Vec<&str> = rest.split(' ').collect();
        let mut keep = words.len();
        let cut = |n: usize| format!("{}\u{2026}", words[..n].join(" "));
        while keep > 0 && c.size_of(&cut(keep), size, 0).width > width {
            keep -= 1;
        }
        lines.push(if keep == 0 { String::new() } else { cut(keep) });
    }
    lines
}

#[cfg(test)]
mod tests;
