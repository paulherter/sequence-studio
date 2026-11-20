// Swift: ShellShortcuts+Draw.swift
//! Layout, drawing and events of the Shortcuts page of Settings (kit frame `Settings / Shortcuts`): one scrolling page with
//! the title, the search, the keyboard picture (colors per area, click a modifier for its layer, click a key for its
//! commands), the legend, the key-set tabs, and the commands grouped by area with "+ N more"; the footer holds
//! "Changes apply right away.", Reset to Defaults and Done. Set Shortcut, Assign and Remove are links in the row.

use crate::menu_list_view::MenuListView;
use crate::shell_dialog::m as dm;
use crate::shell_shortcuts::{ShellShortcutsEditor, ShortcutsFlow, TemplateChoice};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextMeasure, UiCx};
use sq_editor_session::{KeyCap, KeyboardLayout};
use sq_os::Platform;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::key_binding::{Key, KeyBinding};
use sq_uikit::key_group::KeyGroup;
use sq_uikit::keymap_store::KeymapPreset;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;

/// Kit metrics (`redesign/src/prefs.html`, `.kb`, `.key`, `.scrow`, `.seg3`).
pub(crate) struct M;

#[allow(missing_docs)]
impl M {
    pub(crate) const SIDEBAR_W: f64 = 212.0;
    pub(crate) const FOOTER: f64 = 56.0;
    pub(crate) const SIDE: f64 = 20.0;
    pub(crate) const PAD: f64 = 32.0;
    pub(crate) const RADIUS: f64 = sq_uikit::design_tokens::sq_tokens::radius::CARD as f64;
    pub(crate) const CONTROL: f64 = 24.0;
    pub(crate) const ROW: f64 = 30.0;
    pub(crate) const SEARCH_Y: f64 = 96.0;
    pub(crate) const SEARCH_H: f64 = 28.0;
    pub(crate) const WELL_PAD: f64 = 12.0;
    pub(crate) const KEY_H: f64 = 38.0;
    pub(crate) const KEY_GAP: f64 = 5.0;
    pub(crate) const WELL_H: f64 = 2.0 * Self::WELL_PAD + 5.0 * Self::KEY_H + 4.0 * Self::KEY_GAP;
    pub(crate) const KEY_RADIUS: f64 = 5.0;
    pub(crate) const CARD_RADIUS: f64 = 8.0;
    pub(crate) const F_BODY: f64 = sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64;
    pub(crate) const F_SMALL: f64 = 11.0;
    /// The smallest keycap label (a label that still does not fit at this size is cut with an ellipsis).
    pub(crate) const F_CAP_MIN: f64 = 8.0;
    /// The keycap command name: standard size and the smallest one it shrinks to.
    pub(crate) const F_CAP_COMMAND: f64 = 8.5;
    pub(crate) const F_CAP_COMMAND_MIN: f64 = 7.0;
    pub(crate) const LEGEND_ROW: f64 = 14.0;
    /// Rows a group shows before "+ N more".
    pub(crate) const SHOWN: usize = 8;
}

/// What the pointer is over.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Hit {
    /// A key-set tab (index into [`KeymapPreset::ALL`]).
    KeySet(usize),
    /// The "Key set" label: the full template and layout menu.
    KeySetMenu,
    Import,
    Reset,
    /// A modifier key of the picture (index into `modifier_choices`).
    Modifier(usize),
    Key(Key),
    Search,
    ClearSearch,
    Row(usize),
    RowSet(usize),
    RowAssign(usize),
    RowRemove(usize),
    /// "+ N more" / "Show fewer" of the group at this `KeyGroup::ALL` index.
    Expand(usize),
    ShowAll,
    Done,
    Side(usize),
    SideSearch,
}

/// One titled card of the list.
pub(crate) struct Section {
    pub(crate) title: String,
    /// The index in `KeyGroup::ALL`, for the groups of the plain list.
    pub(crate) group: Option<usize>,
    /// Indices into `rows`.
    pub(crate) rows: Vec<usize>,
    /// Rows hidden behind "+ N more".
    pub(crate) more: usize,
    /// An opened group offers "Show fewer".
    pub(crate) collapsible: bool,
    /// "show all" after the title (a picked key).
    pub(crate) link: bool,
    pub(crate) note: Option<&'static str>,
}

pub(crate) struct SectionLayout {
    title: CGRect,
    link: Option<CGRect>,
    card: CGRect,
    rows: Vec<(usize, CGRect)>,
    extra: Option<CGRect>,
}

#[derive(Default)]
pub(crate) struct Parts {
    pub(crate) card: CGRect,
    /// The scrolling part of the page (above the footer).
    pub(crate) body: CGRect,
    pub(crate) main: CGRect,
    /// The page's origin: the card top shifted by the scroll.
    origin_y: f64,
    x0: f64,
    pub(crate) width: f64,
    search: CGRect,
    well: CGRect,
    legend_top: f64,
    seg: CGRect,
    segments: Vec<CGRect>,
    keyset: CGRect,
    import: CGRect,
    sections: Vec<SectionLayout>,
    pub(crate) content_h: f64,
    reset: CGRect,
    done: CGRect,
    pub(crate) side: Vec<CGRect>,
    pub(crate) side_search: CGRect,
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> CGRect {
    CGRect::new(x, y, w, h)
}

impl ShellShortcutsEditor {
    fn text_width(m: &TextMeasure, s: &str, size: f64) -> f64 {
        m.width(&SQL10n::string(s), size, 0).ceil()
    }

    /// What a keycap prints and at which size: the standard size, shrunk in half points until `width_at(text, size)`
    /// fits `avail` (Super, Ctrl and Bksp on a narrow cap), never below `F_CAP_MIN`. A word that still does not fit
    /// becomes its glyph (Tab, Enter, Bksp, Shift, Caps) or its short name (Super: Sup).
    pub(crate) fn cap_label(label: &str, avail: f64, width_at: impl Fn(&str, f64) -> f64) -> (String, f64) {
        let fit = |text: &str| {
            let mut size = M::F_SMALL;
            while size > M::F_CAP_MIN && width_at(text, size) > avail {
                size -= 0.5;
            }
            (width_at(text, size) <= avail).then_some(size)
        };
        if let Some(size) = fit(label) {
            return (label.to_string(), size);
        }
        let glyph = match label {
            "Tab" => "\u{21e5}",
            "Enter" => "\u{21a9}",
            "Bksp" => "\u{232b}",
            "Shift" => "\u{21e7}",
            "Caps" => "\u{21ea}",
            "Super" => "Sup",
            _ => label,
        };
        if let Some(size) = fit(glyph) {
            return (glyph.to_string(), size);
        }
        // Still too wide: the leading letters with an ellipsis, down to one letter; a cap never loses its label.
        let chars: Vec<char> = glyph.chars().collect();
        for n in (1..chars.len()).rev() {
            let cut = format!("{}\u{2026}", chars[..n].iter().collect::<String>());
            if let Some(size) = fit(&cut) {
                return (cut, size);
            }
        }
        (chars.iter().take(1).collect(), M::F_CAP_MIN)
    }

    /// The command name a keycap prints under its label and its size: the whole name (down to 7 pt), else its leading
    /// whole words with an ellipsis (the shared word-boundary rule), else nothing. Never a cut inside a word.
    pub(crate) fn cap_command(title: &str, avail: f64, width_at: impl Fn(&str, f64) -> f64) -> Option<(String, f64)> {
        let mut size = M::F_CAP_COMMAND;
        while size >= M::F_CAP_COMMAND_MIN {
            if width_at(title, size) <= avail {
                return Some((title.to_string(), size));
            }
            size -= 0.5;
        }
        let size = M::F_CAP_COMMAND_MIN;
        let words: Vec<&str> = title.split_whitespace().collect();
        (1..words.len()).rev().find_map(|n| {
            let cut = format!("{}\u{2026}", words[..n].join(" "));
            (width_at(&cut, size) <= avail).then_some((cut, size))
        })
    }

    fn button_width(m: &TextMeasure, title: &str) -> f64 {
        (Self::text_width(m, title, dm::BUTTON_FONT) + 2.0 * dm::BUTTON_PADDING).max(64.0)
    }

    /// The lists the page shows: by area, the commands of a search, or the commands of the picked key.
    pub(crate) fn sections(&self) -> Vec<Section> {
        let q = self.query();
        let plain = |title: String, rows: Vec<usize>| Section {
            title,
            group: None,
            rows,
            more: 0,
            collapsible: false,
            link: false,
            note: None,
        };
        if !q.is_empty() {
            let n = self.rows.len();
            let title = format!("{n} shortcut{} for “{q}”", if n == 1 { "" } else { "s" });
            return vec![plain(title, (0..n).collect())];
        }
        if let Some(k) = self.selected_key {
            let b = KeyBinding::new(k, self.modifiers);
            let rows: Vec<usize> =
                (0..self.rows.len()).filter(|i| self.rows[*i].entry.is_some_and(|e| e.binding == b)).collect();
            let note = rows.is_empty().then_some("No command uses this key.");
            let mut s = plain(format!("Key {}", self.key_text(&b)), rows);
            s.link = true;
            s.note = note;
            return vec![s];
        }
        KeyGroup::ALL
            .iter()
            .enumerate()
            .filter_map(|(gi, g)| {
                let all: Vec<usize> =
                    (0..self.rows.len()).filter(|i| KeyGroup::of(&self.rows[*i].command) == *g).collect();
                if all.is_empty() {
                    return None;
                }
                let open = self.expanded.contains(&gi);
                let more = if open { 0 } else { all.len().saturating_sub(M::SHOWN) };
                let rows = if open { all.clone() } else { all.iter().copied().take(M::SHOWN).collect() };
                Some(Section {
                    title: g.title().to_string(),
                    group: Some(gi),
                    rows,
                    more,
                    collapsible: open && all.len() > M::SHOWN,
                    link: false,
                    note: None,
                })
            })
            .collect()
    }

    /// "Every key and what it does. …" with the count.
    fn subtitle(&self) -> String {
        format!(
            "{} Hold a modifier below to see that layer. {}",
            SQL10n::string(crate::shell_preferences::Page::Shortcuts.subtitle()),
            self.count_text()
        )
    }

    pub(crate) fn parts(&mut self, m: &TextMeasure) -> Parts {
        let scroll = self.scroll_body.position();
        let p = self.parts_at(m, scroll);
        self.scroll_body.max_offset = (p.content_h - p.body.height).max(0.0);
        p
    }

    fn parts_at(&self, m: &TextMeasure, scroll: f64) -> Parts {
        let mut p = Parts::default();
        let f = self.frame;
        // The Settings window's own card: one size and place on every page, so the sidebar never jumps; the page scrolls inside.
        p.card = crate::shell_preferences::settings_card(f);
        let (w, h) = (p.card.width, p.card.height);
        p.main = rect(p.card.min_x() + M::SIDEBAR_W + 1.0, p.card.min_y(), w - M::SIDEBAR_W - 1.0, h);
        p.body = rect(p.main.min_x(), p.card.min_y(), p.main.width, (h - M::FOOTER).max(0.0));
        p.side_search = rect(p.card.min_x() + 12.0, p.card.min_y() + 16.0, M::SIDEBAR_W - 24.0, 26.0);
        p.side = (0..self.pages.len())
            .map(|i| {
                rect(p.card.min_x() + 8.0, p.card.min_y() + 16.0 + 38.0 + i as f64 * 30.0, M::SIDEBAR_W - 16.0, 28.0)
            })
            .collect();
        p.x0 = p.card.min_x() + M::SIDEBAR_W + M::PAD;
        p.width = (p.card.max_x() - M::PAD - p.x0).max(0.0);
        p.origin_y = p.card.min_y() - scroll;
        let o = p.origin_y;
        p.search = rect(p.x0, o + M::SEARCH_Y, p.width, M::SEARCH_H);
        p.well = rect(p.x0, p.search.max_y() + 16.0, p.width, M::WELL_H);
        p.legend_top = p.well.max_y() + 10.0;
        let legend_rows = Self::legend_layout(m, p.x0, p.width, p.legend_top)
            .last()
            .map_or(1.0, |l| (l.2 - p.legend_top) / M::LEGEND_ROW + 1.0);
        let row_y = p.legend_top + legend_rows * M::LEGEND_ROW + 12.0;
        // Key-set tabs: a well with a 2 px pad, 20 high segments with 10 px of text padding.
        let mut x = p.x0 + 2.0;
        for pr in KeymapPreset::ALL {
            let sw = Self::text_width(m, pr.title(), M::F_BODY) + 20.0;
            p.segments.push(rect(x, row_y + 2.0, sw, 20.0));
            x += sw + 2.0;
        }
        p.seg = rect(p.x0, row_y, x - p.x0, M::CONTROL);
        let lw = Self::text_width(m, "Key set", M::F_SMALL);
        p.keyset = rect(p.seg.max_x() + 8.0, row_y, lw + 18.0, M::CONTROL);
        let iw = Self::button_width(m, "Import Key Map…").max(Self::text_width(m, "Import Key Map…", M::F_BODY) + 28.0);
        p.import = rect(p.x0 + p.width - iw, row_y, iw, M::CONTROL);
        let mut y = row_y + M::CONTROL + 20.0;
        for s in self.sections() {
            let title = rect(p.x0 + 2.0, y, p.width, 16.0);
            let link = s.link.then(|| {
                let tw = Self::text_width(m, &s.title, M::F_SMALL);
                rect(p.x0 + 2.0 + tw + 8.0, y, Self::text_width(m, &format!("· show all {}", self.rows.len()), M::F_SMALL) + 4.0, 16.0)
            });
            let card_y = y + 24.0;
            let mut rows = Vec::new();
            let mut ry = card_y;
            for i in &s.rows {
                rows.push((*i, rect(p.x0, ry, p.width, M::ROW)));
                ry += M::ROW;
            }
            let extra = (s.more > 0 || s.collapsible || s.note.is_some()).then(|| rect(p.x0, ry, p.width, M::ROW));
            if extra.is_some() {
                ry += M::ROW;
            }
            let card = rect(p.x0, card_y, p.width, ry - card_y);
            p.sections.push(SectionLayout { title, link, card, rows, extra });
            y = ry + 20.0;
        }
        p.content_h = y + 4.0 - p.origin_y;
        let bh = dm::BUTTON_HEIGHT;
        let by = p.card.max_y() - M::FOOTER + ((M::FOOTER - bh) / 2.0).round();
        let note_w = Self::text_width(m, "Changes apply right away.", M::F_SMALL);
        p.reset = rect(p.x0 + note_w + 8.0, by, Self::text_width(m, "Reset to Defaults", M::F_BODY) + 22.0, bh);
        let dw = Self::button_width(m, "Done");
        p.done = rect(p.card.max_x() - M::SIDE - dw, by, dw, bh);
        p
    }

    /// The items of the legend: group, x and y of each, in a wrapping row 10 apart.
    fn legend_layout(m: &TextMeasure, x0: f64, width: f64, top: f64) -> Vec<(KeyGroup, f64, f64)> {
        let (mut x, mut y) = (x0, top);
        let mut out = Vec::new();
        for g in KeyGroup::ALL {
            let w = 15.0 + Self::text_width(m, g.title(), M::F_SMALL);
            if x > x0 && x + w > x0 + width {
                x = x0;
                y += M::LEGEND_ROW;
            }
            out.push((g, x, y));
            x += w + 10.0;
        }
        out
    }

    /// The caps with their rects: each row shares its width by the model's key widths, 5 apart (`.kr` flex).
    pub(crate) fn laid_caps(&self, p: &Parts) -> Vec<(KeyCap, CGRect)> {
        let caps = self.caps();
        let row_of = |c: &KeyCap| (c.y / (KeyboardLayout::KEY_HEIGHT + KeyboardLayout::GAP)).round() as usize;
        let inner = p.well.width - 2.0 * M::WELL_PAD;
        let mut out = Vec::new();
        for row in 0..5 {
            let cs: Vec<&KeyCap> = caps.iter().filter(|c| row_of(c) == row).collect();
            let total: f64 = cs.iter().map(|c| c.w).sum();
            let avail = inner - M::KEY_GAP * (cs.len() as f64 - 1.0).max(0.0);
            let y = p.well.min_y() + M::WELL_PAD + row as f64 * (M::KEY_H + M::KEY_GAP);
            let mut x = p.well.min_x() + M::WELL_PAD;
            for c in cs {
                let w = avail * c.w / total;
                if !c.is_ghost {
                    out.push((c.clone(), rect(x, y, w, M::KEY_H)));
                }
                x += w + M::KEY_GAP;
            }
        }
        out
    }

    /// The caps of the picture; Windows names the modifier and edit keys in words.
    pub(crate) fn caps(&self) -> Vec<KeyCap> {
        let caps = KeyboardLayout::caps(self.style);
        if self.platform == Platform::Mac {
            return caps;
        }
        // The key between Ctrl and Alt: "Win" on Windows, "Super" on Linux.
        let logo = if self.platform == Platform::Linux { "Super" } else { "Win" };
        let words = [
            ("fn", "Fn"),
            ("⌃", logo),
            ("⌥", "Alt"),
            ("⌘", "Ctrl"),
            ("⇧", "Shift"),
            ("⇪", "Caps"),
            ("⇥", "Tab"),
            ("↩", "Enter"),
            ("⌫", "Bksp"),
        ];
        caps.into_iter()
            .map(|mut c| {
                if let Some((_, w)) = words.iter().find(|(k, _)| *k == c.label) {
                    c.label = (*w).to_string();
                }
                c
            })
            .collect()
    }

    /// The modifier a cap stands for (its glyph or word equals a choice of the layer toggles).
    fn cap_modifier(&self, cap: &KeyCap) -> Option<usize> {
        if cap.key.is_some() {
            return None;
        }
        self.modifier_choices().iter().position(|(g, _)| *g == cap.label)
    }

    /// A row's pieces from the right: the chip, the scope, the links.
    fn row_links(
        &self,
        r: CGRect,
        i: usize,
        m: &TextMeasure,
    ) -> (CGRect, Option<CGRect>, Option<CGRect>, Option<CGRect>) {
        let shortcut = &self.rows[i].listing.shortcut;
        let cw = (m.width(shortcut, 11.5, 0).ceil() + 12.0).max(22.0);
        let chip = rect(r.max_x() - 14.0 - cw, r.mid_y() - 10.0, cw, 20.0);
        let mut x = chip.min_x() - 12.0 - 110.0 - 12.0;
        let selected = self.selected_index == Some(i);
        let link = |x: &mut f64, title: &str| {
            let w = Self::text_width(m, title, M::F_SMALL) + 4.0;
            *x -= w;
            let l = rect(*x, r.min_y(), w, r.height);
            *x -= 12.0;
            l
        };
        let remove = (selected && self.rows[i].entry.is_some()).then(|| link(&mut x, "Remove"));
        let assign = (selected && self.selected_key.is_some()).then(|| link(&mut x, &self.assign_title()));
        let set = Some(link(
            &mut x,
            if self.capturing && selected { "Press the new shortcut (Esc cancels)" } else { "Set Shortcut…" },
        ));
        (chip, set, assign, remove)
    }

    pub(crate) fn scroll_to_row(&mut self, i: usize) {
        // The page does not depend on the text widths in y, so a measure without an atlas will do.
        let m = TextMeasure::new(None, 1.0);
        let p = self.parts_at(&m, 0.0);
        let Some(r) = p.sections.iter().flat_map(|s| s.rows.iter()).find(|(k, _)| *k == i).map(|(_, r)| *r) else {
            return;
        };
        let (top, bottom) = (r.min_y() - p.card.min_y(), r.max_y() - p.card.min_y());
        let scroll = self.scroll_body.position();
        if top < scroll {
            self.scroll_body.assign(top);
        } else if bottom > scroll + p.body.height {
            self.scroll_body.assign(bottom - p.body.height);
        }
    }

    // MARK: Hit testing

    pub(crate) fn hit(&mut self, q: CGPoint, m: &TextMeasure) -> Option<Hit> {
        let p = self.parts(m);
        if let Some(i) = p.side.iter().position(|r| r.contains(q)) {
            return Some(Hit::Side(i));
        }
        if p.side_search.contains(q) {
            return Some(Hit::SideSearch);
        }
        if p.reset.contains(q) {
            return Some(Hit::Reset);
        }
        if p.done.contains(q) {
            return Some(Hit::Done);
        }
        if !p.body.contains(q) {
            return None;
        }
        if p.well.contains(q) {
            let laid = self.laid_caps(&p);
            let found = laid.iter().find(|(_, r)| r.contains(q))?;
            if let Some(i) = self.cap_modifier(&found.0) {
                return Some(Hit::Modifier(i));
            }
            return found.0.key.map(Hit::Key);
        }
        if p.search.contains(q) {
            return Some(if !self.query().is_empty() && q.x > p.search.max_x() - 28.0 {
                Hit::ClearSearch
            } else {
                Hit::Search
            });
        }
        if let Some(i) = p.segments.iter().position(|r| r.contains(q)) {
            return Some(Hit::KeySet(i));
        }
        if p.keyset.contains(q) {
            return Some(Hit::KeySetMenu);
        }
        if p.import.contains(q) {
            return Some(Hit::Import);
        }
        let secs = self.sections();
        for (s, l) in secs.iter().zip(&p.sections) {
            if l.link.is_some_and(|r| r.contains(q)) {
                return Some(Hit::ShowAll);
            }
            if let (Some(gi), Some(r)) = (s.group, l.extra)
                && r.contains(q)
            {
                return Some(Hit::Expand(gi));
            }
            for (i, r) in &l.rows {
                if !r.contains(q) {
                    continue;
                }
                let (_, set, assign, remove) = self.row_links(*r, *i, m);
                if remove.is_some_and(|l| l.contains(q)) {
                    return Some(Hit::RowRemove(*i));
                }
                if assign.is_some_and(|l| l.contains(q)) {
                    return Some(Hit::RowAssign(*i));
                }
                if set.is_some_and(|l| l.contains(q)) {
                    return Some(Hit::RowSet(*i));
                }
                return Some(Hit::Row(*i));
            }
        }
        None
    }

    // MARK: Events

    /// Every event while the editor is up (it is modal). `scale` turns pixels into points. Steps that wait for a dialog
    /// are queued in `queue`, a changed key map sets `commit_pending`, Done sets `wants_close` (the host reads them).
    pub(crate) fn handle(&mut self, e: &InputEvent, scale: f32, m: &TextMeasure, ui: &mut UiCx, now: f64) {
        let k = f64::from(scale.max(0.01));
        self.menu.bounds = self.frame;
        if self.menu.is_open() {
            let _ = self.menu.handle(e, scale, m);
            ui.hover.offer_tip(self.menu.tip_at(e, scale, m).as_deref());
            return;
        }
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let q = pt(x, y);
                if self.capturing {
                    self.end_capture();
                }
                let h = self.hit(q, m);
                if h != Some(Hit::Search) && h != Some(Hit::ClearSearch) && self.search.is_editing() {
                    let _ = self.search.commit();
                }
                self.pressed = h;
                if let Some(h) = h {
                    self.press(h, m);
                }
            }
            InputEvent::MouseUp { .. } => self.pressed = None,
            InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } => {
                self.hover = self.hit(pt(x, y), m);
            }
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                let p = self.parts(m);
                if !p.body.contains(pt(x, y)) {
                    return;
                }
                let max_scroll = (p.content_h - p.body.height).max(0.0);
                self.scroll_body.wheel(Some(ui.gesture_or_wheel(dx, dy)), dx, dy, k, max_scroll, p.body.height, now);
            }
            InputEvent::KeyDown { key, modifiers } => self.key_down(key, modifiers, ui),
        }
    }

    fn key_down(&mut self, key: InputKey, m: InputModifiers, ui: &mut UiCx) {
        if self.capturing {
            self.capture(key, m);
            return;
        }
        match key {
            InputKey::Up | InputKey::Down => {
                if self.rows.is_empty() {
                    return;
                }
                let next =
                    self.selected_index.map_or(0, |i| if key == InputKey::Down { i + 1 } else { i.saturating_sub(1) });
                self.select(Some(next.min(self.rows.len() - 1)));
                return;
            }
            InputKey::Escape => {
                if self.search.is_editing() && !self.query().is_empty() {
                    self.set_query("");
                    self.search.mouse_down(None, 1);
                    return;
                }
                self.wants_close = true;
                return;
            }
            InputKey::Enter => {
                if self.search.is_editing() {
                    let _ = self.search.commit();
                }
                self.wants_close = true;
                return;
            }
            InputKey::Character('f' | 'F') if m == InputModifiers::COMMAND => {
                self.search.mouse_down(None, 1);
                return;
            }
            _ => {}
        }
        if !self.search.is_editing() {
            // Typing goes to the search field (the Mac window keeps it first responder).
            let shift_only = m == InputModifiers::NONE || m == InputModifiers::SHIFT;
            if !shift_only || !matches!(key, InputKey::Character(_)) {
                return;
            }
            self.search.mouse_down(None, 1);
        }
        let _ = self.search.key(key, m, ui);
        self.query_changed();
    }

    pub(crate) fn press(&mut self, h: Hit, m: &TextMeasure) {
        let p = self.parts(m);
        match h {
            Hit::KeySet(i) => {
                if let Some(pr) = KeymapPreset::ALL.get(i).copied()
                    && !(self.config.active_set().is_none() && self.config.preset == pr)
                {
                    self.queue.borrow_mut().push(ShortcutsFlow::ChooseTemplate(TemplateChoice::Preset(pr)));
                }
            }
            Hit::KeySetMenu => {
                let mut items = self.template_menu_items();
                items.push(sq_uikit::sqmenu_model::SQMenuItem::separator());
                items.push(sq_uikit::sqmenu_model::SQMenuItem::header("Keyboard layout"));
                items.extend(self.layout_menu_items());
                self.menu.pop_up(items, p.keyset, None, m);
            }
            Hit::Import => self.queue.borrow_mut().push(ShortcutsFlow::ImportShortcuts),
            Hit::Reset => {
                if self.can_reset() {
                    self.queue.borrow_mut().push(ShortcutsFlow::ResetAll);
                }
            }
            Hit::Modifier(i) => {
                if let Some((_, m)) = self.modifier_choices().get(i).copied() {
                    self.toggle_modifier(m);
                }
            }
            Hit::Key(key) => self.select_key(if self.selected_key == Some(key) { None } else { Some(key) }),
            Hit::Search => self.search.mouse_down(None, 1),
            Hit::ClearSearch => self.set_query(""),
            Hit::Row(i) => self.select(Some(i)),
            Hit::RowSet(i) => {
                self.select(Some(i));
                self.begin_capture();
            }
            Hit::RowAssign(i) => {
                self.select(Some(i));
                self.queue.borrow_mut().push(ShortcutsFlow::AssignToKey);
            }
            Hit::RowRemove(i) => {
                self.select(Some(i));
                self.remove_shortcut();
            }
            Hit::Expand(gi) => {
                if !self.expanded.remove(&gi) {
                    self.expanded.insert(gi);
                }
            }
            Hit::ShowAll => self.select_key(None),
            Hit::Done => self.wants_close = true,
            Hit::Side(i) => {
                if let Some(page) =
                    self.pages.get(i).copied().filter(|p| *p != crate::shell_preferences::Page::Shortcuts)
                {
                    self.open_page = Some((page, false));
                }
            }
            Hit::SideSearch => self.open_page = Some((crate::shell_preferences::Page::General, true)),
        }
    }

    // MARK: Drawing

    /// The strip color of an area: ten neutral steps from the text color to the faintest text color (the legend and the
    /// key strips share it). The hue is gone on purpose (r8 uses neutrals plus the one accent); the step order is the
    /// order of `KeyGroup::ALL`.
    fn color(g: KeyGroup, t: &DrawTheme) -> Color {
        let i = KeyGroup::ALL.iter().position(|x| *x == g).unwrap_or(9);
        t.label().mix(t.label4(), i as f32 / 9.0)
    }

    fn touch(&self, h: Hit) -> Touch {
        Touch { hovering: self.hover == Some(h), pressed: self.pressed == Some(h), ..Touch::default() }
    }

    /// Draws the editor over the window.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, ui: &mut UiCx) {
        let m = TextMeasure::new(c.atlas(), c.scale);
        let p = self.parts(&m);
        let dark = t.palette.is_dark();
        c.fill(self.frame, Color::new(0.0, 0.0, 0.0, if dark { dm::SCRIM_ALPHA } else { dm::SCRIM_ALPHA_LIGHT }));
        c.shadow(p.card, M::RADIUS, dm::SHADOW_BLUR, dm::SHADOW_DY, Color::new(0.0, 0.0, 0.0, dm::SHADOW_ALPHA), true);
        c.fill_rounded(p.card, M::RADIUS, t.panel());
        c.stroke_rounded(p.card.inset_by(0.25, 0.25), M::RADIUS, 0.5, MenuListView::overlay_edge(t));
        self.draw_side(c, t, &p);
        c.save_gstate();
        c.clip_to(p.body);
        self.draw_header(c, t, &p);
        self.draw_search(c, t, &p, ui);
        self.draw_keyboard(c, t, &p);
        self.draw_legend(c, t, &p, &m);
        self.draw_key_sets(c, t, &p);
        self.draw_list(c, t, &p, &m);
        c.restore_gstate();
        self.draw_footer(c, t, &p);
        self.menu.draw(c, t);
    }

    fn draw_header(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts) {
        let (x, o) = (p.x0 + 2.0, p.origin_y);
        c.draw_text_in(
            "Shortcuts",
            rect(x, o + 26.0, 500.0, 24.0),
            sq_uikit::design_tokens::sq_tokens::type_size::DISPLAY as f64,
            t.label(),
            TextAlign::Left,
            0.0,
            c.semibold(),
        );
        for (n, line) in c.wrap(&self.subtitle(), p.width - 2.0, M::F_BODY).iter().enumerate() {
            c.draw_text_in(
                line,
                rect(x, o + 49.0 + n as f64 * 14.0, p.width, 14.0),
                M::F_BODY,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    fn draw_search(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts, ui: &mut UiCx) {
        let f = p.search;
        c.stone_field(f, 4.0, self.search.is_editing(), Touch::default(), t);
        c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 10.0, f.mid_y() - 6.0), 12.0, t.label3(), None);
        let text_rect = rect(f.min_x() + 30.0, f.min_y(), f.width - 30.0 - 32.0, f.height);
        self.search.draw(c, text_rect, t, self.search.is_editing(), ui);
        if self.query().is_empty() {
            c.draw_text_in(
                &SQL10n::string("Search shortcuts by name or key, e.g. blade or ⌘K"),
                text_rect,
                M::F_BODY,
                t.label4(),
                TextAlign::Left,
                0.0,
                0,
            );
        } else {
            c.draw_icon(
                SQIcon::CloseCircleFilled,
                CGPoint::new(f.max_x() - 24.0, f.mid_y() - 8.0),
                16.0,
                t.label3(),
                None,
            );
        }
    }

    fn draw_keyboard(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts) {
        c.fill_rounded(p.well, 8.0, t.token(sq_uikit::redesign_tokens::color::GROUP));
        let model = self.layout_model();
        let found = self.found_keys();
        for (cap, r) in self.laid_caps(p) {
            let modifier = self.cap_modifier(&cap);
            let layer_on = modifier
                .and_then(|i| self.modifier_choices().get(i).copied())
                .is_some_and(|(_, mm)| self.modifiers.contains(mm));
            let is_mod = cap.key.is_none()
                && matches!(
                    cap.label.as_str(),
                    "⌃" | "⌥" | "⇧" | "⌘" | "fn" | "Win" | "Super" | "Alt" | "Ctrl" | "Shift"
                );
            let kind = if layer_on {
                ButtonKind::Accent
            } else if is_mod {
                ButtonKind::RaisedMenu
            } else {
                ButtonKind::Raised
            };
            let hit = match (modifier, cap.key) {
                (Some(i), _) => Hit::Modifier(i),
                (None, Some(k)) => Hit::Key(k),
                _ => Hit::Done, // never equal to the pointer's hit for a plain cap below
            };
            let touch = if cap.key.is_none() && modifier.is_none() { Touch::default() } else { self.touch(hit) };
            c.stone_button(r, kind, touch, t);
            let group = cap.key.and_then(|k| model.group(k));
            if let Some(g) = group {
                c.fill_rounded(rect(r.min_x() + 1.5, r.max_y() - 3.0, r.width - 3.0, 3.0), 1.5, Self::color(g, t));
            }
            let label_color = if layer_on {
                t.token(sq_uikit::redesign_tokens::color::ON_ACCENT)
            } else if is_mod {
                t.label3()
            } else {
                t.label()
            };
            let face = c.semibold();
            let (label, label_size) =
                Self::cap_label(&cap.label, r.width - 8.0, |text, sz| c.size_of(text, sz, face).width);
            c.draw_text_in(
                &label,
                rect(r.min_x() + 5.0, r.min_y() + 4.0, r.width - 8.0, 14.0),
                label_size,
                label_color,
                TextAlign::Left,
                0.0,
                c.semibold(),
            );
            if let Some(e) = cap.key.and_then(|k| model.entries(k).first().copied())
                && let Some((name, size)) =
                    Self::cap_command(&SQL10n::string(&e.command.title()), r.width - 9.0, |text, sz| {
                        c.size_of(text, sz, 0).width
                    })
            {
                c.draw_text_in(
                    &name,
                    rect(r.min_x() + 5.0, r.max_y() - 16.0, r.width - 9.0, 10.0),
                    size,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            let picked = cap.key.is_some() && cap.key == self.selected_key;
            if picked || cap.key.is_some_and(|k| found.contains(&k)) {
                c.stroke_rounded(r.inset_by(-1.0, -1.0), M::KEY_RADIUS + 1.0, 2.0, t.accent());
            }
        }
    }

    fn draw_legend(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts, m: &TextMeasure) {
        for (g, x, y) in Self::legend_layout(m, p.x0, p.width, p.legend_top) {
            c.fill_rounded(rect(x, y + 5.5, 10.0, 3.0), 1.0, Self::color(g, t));
            c.draw_text_in(
                &SQL10n::string(g.title()),
                rect(x + 15.0, y, 400.0, M::LEGEND_ROW),
                M::F_SMALL,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    fn draw_key_sets(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts) {
        c.stone_segment_track(p.seg, Touch::default(), t);
        for (i, (pr, r)) in KeymapPreset::ALL.iter().zip(&p.segments).enumerate() {
            let on = self.config.active_set().is_none() && self.config.preset == *pr;
            c.stone_segment(*r, on, self.touch(Hit::KeySet(i)), t);
            c.draw_text_in(
                &SQL10n::string(pr.title()),
                *r,
                M::F_BODY,
                if on { t.label() } else { t.label3() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
        let hot = self.hover == Some(Hit::KeySetMenu);
        c.draw_text_in(
            "Key set",
            rect(p.keyset.min_x(), p.keyset.min_y(), p.keyset.width, p.keyset.height),
            M::F_SMALL,
            if hot { t.label2() } else { t.label3() },
            TextAlign::Left,
            0.0,
            0,
        );
        c.draw_icon(
            SQIcon::ChevronDown,
            CGPoint::new(p.keyset.max_x() - 12.0, p.keyset.mid_y() - 4.0),
            8.0,
            t.label4(),
            None,
        );
        let r = c.stone_button(p.import, ButtonKind::Raised, self.touch(Hit::Import), t);
        c.draw_text_in("Import Key Map…", r, M::F_BODY, t.label(), TextAlign::Center, 0.0, 0);
    }

    fn draw_list(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts, m: &TextMeasure) {
        let secs = self.sections();
        let hover_row = match self.hover {
            Some(Hit::Row(i) | Hit::RowSet(i) | Hit::RowAssign(i) | Hit::RowRemove(i)) => Some(i),
            _ => None,
        };
        for (s, l) in secs.iter().zip(&p.sections) {
            if l.card.min_y() > p.body.max_y() || l.card.max_y() < p.body.min_y() {
                continue;
            }
            c.draw_text_in(
                &SQL10n::string(&s.title),
                l.title,
                M::F_SMALL,
                t.label3(),
                TextAlign::Left,
                0.0,
                c.semibold(),
            );
            if let Some(r) = l.link {
                let hot = self.hover == Some(Hit::ShowAll);
                c.draw_text_in(
                    &format!("· show all {}", self.rows.len()),
                    r,
                    M::F_SMALL,
                    if hot { t.label2() } else { t.label4() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            c.fill_rounded(l.card, M::CARD_RADIUS, t.token(sq_uikit::redesign_tokens::color::GROUP));
            for (n, (i, r)) in l.rows.iter().enumerate() {
                let last = n + 1 == l.rows.len() && l.extra.is_none();
                let selected = self.selected_index == Some(*i);
                if selected {
                    c.fill_rounded(*r, 4.0, t.current());
                }
                if !last {
                    c.fill(rect(r.min_x(), r.max_y() - 1.0, r.width, 1.0), t.row_line());
                }
                let row = &self.rows[*i];
                let (chip, set, assign, remove) = self.row_links(*r, *i, m);
                let ctx = rect(chip.min_x() - 12.0 - 110.0, r.min_y(), 110.0, r.height);
                c.draw_text_in(
                    &SQL10n::string(&row.listing.command),
                    rect(r.min_x() + 14.0, r.min_y(), ctx.min_x() - r.min_x() - 28.0, r.height),
                    M::F_BODY,
                    t.label(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                if selected || hover_row == Some(*i) {
                    for (link, title, live) in [
                        (remove, "Remove".to_string(), true),
                        (assign, self.assign_title(), true),
                        (set, "Set Shortcut…".to_string(), true),
                    ] {
                        let Some(rr) = link.filter(|_| live) else { continue };
                        let text = if title == "Set Shortcut…" && self.capturing && selected {
                            "Press the new shortcut (Esc cancels)".to_string()
                        } else {
                            title
                        };
                        c.draw_text_in(&SQL10n::string(&text), rr, M::F_SMALL, t.accent(), TextAlign::Left, 0.0, 0);
                    }
                }
                c.draw_text_in(
                    &SQL10n::string(&row.listing.scope),
                    ctx,
                    M::F_SMALL,
                    t.label4(),
                    TextAlign::Right,
                    0.0,
                    0,
                );
                // A menu-only row has no key: no empty chip that reads as a missing value (the kit shows the label only).
                if row.listing.shortcut.is_empty() {
                    continue;
                }
                c.stone_field(chip, 4.0, false, Touch::default(), t);
                c.draw_text_in(&row.listing.shortcut, chip, 11.5, t.label(), TextAlign::Center, 0.0, 0);
            }
            if let Some(r) = l.extra {
                let text = if let Some(n) = s.note {
                    n.to_string()
                } else if s.more > 0 {
                    format!("+ {} more", s.more)
                } else {
                    "Show fewer".to_string()
                };
                let hot = self.hover == s.group.map(Hit::Expand);
                c.draw_text_in(
                    &SQL10n::string(&text),
                    rect(r.min_x() + 14.0, r.min_y(), r.width - 28.0, r.height),
                    M::F_SMALL,
                    if hot { t.label3() } else { t.label4() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
        if self.rows.is_empty() {
            c.draw_text_in(
                "No matching shortcuts",
                rect(p.x0, p.well.max_y() + 160.0, p.width, 16.0),
                M::F_BODY,
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    /// The Settings page list: search box, then a tile and the title per page; Shortcuts is the picked one.
    fn draw_side(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts) {
        let chrome = t.token(sq_uikit::redesign_tokens::color::CHROME);
        let col = rect(p.card.min_x(), p.card.min_y(), M::SIDEBAR_W, p.card.height);
        c.fill_rounded(rect(col.min_x(), col.min_y(), col.width, 48.0), 12.0, chrome);
        c.fill(rect(col.min_x() + 12.0, col.min_y(), col.width - 12.0, col.height), chrome);
        c.fill(rect(col.min_x(), col.min_y() + 24.0, col.width, col.height - 24.0), chrome);
        let f = p.side_search;
        c.stone_field(f, 4.0, false, Touch::default(), t);
        c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 8.0, f.mid_y() - 6.0), 12.0, t.label3(), None);
        c.draw_text_in(
            "Search settings",
            rect(f.min_x() + 26.0, f.min_y(), f.width - 34.0, f.height),
            M::F_BODY,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        for (i, page) in self.pages.iter().enumerate() {
            let r = p.side[i];
            let on = *page == crate::shell_preferences::Page::Shortcuts;
            if on || self.hover == Some(Hit::Side(i)) {
                c.fill_rounded(
                    r,
                    sq_uikit::design_tokens::sq_tokens::radius::SMALL as f64,
                    if on { t.current() } else { t.hover() },
                );
            }
            // r8 `.nav`: a 16 pt line icon in the text color, no tile.
            c.draw_icon(page.icon(), CGPoint::new(r.min_x() + 7.0, (r.mid_y() - 8.0).round()), 16.0, t.label(), None);
            c.draw_text_in(
                &SQL10n::string(page.title()),
                rect(r.min_x() + 32.0, r.min_y(), r.width - 42.0, r.height),
                M::F_BODY,
                if on { t.label() } else { t.label2() },
                TextAlign::Left,
                0.0,
                0,
            );
        }
        c.fill(rect(p.main.min_x() - 1.0, p.card.min_y(), 1.0, p.card.height), t.hair());
    }

    fn draw_footer(&self, c: &mut Canvas, t: &DrawTheme, p: &Parts) {
        c.fill(rect(p.main.min_x(), p.card.max_y() - M::FOOTER, p.main.width, 1.0), t.hair());
        c.fill(rect(p.main.min_x(), p.card.max_y() - M::FOOTER + 1.0, p.main.width, M::FOOTER - 1.0), t.panel());
        c.draw_text_in(
            "Changes apply right away.",
            rect(p.x0, p.reset.min_y(), p.reset.min_x() - p.x0, p.reset.height),
            M::F_SMALL,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        let touch = Touch { disabled: !self.can_reset(), ..self.touch(Hit::Reset) };
        let r = c.stone_button(p.reset, ButtonKind::Raised, touch, t);
        c.draw_text_in(
            "Reset to Defaults",
            r,
            dm::BUTTON_FONT,
            if touch.disabled { t.label4() } else { t.label() },
            TextAlign::Center,
            0.0,
            c.medium(),
        );
        let r = c.stone_button(p.done, ButtonKind::Primary, self.touch(Hit::Done), t);
        c.draw_text_in("Done", r, dm::BUTTON_FONT, t.primary_button_text(), TextAlign::Center, 0.0, c.medium());
    }
}
