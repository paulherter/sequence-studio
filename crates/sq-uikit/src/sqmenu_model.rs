//! Port of `SQUIKit/Sources/SQUIKit/SQMenuModel.swift`.
//! A menu image is whatever the host's image cache hands out (`SQMenuImageBox` holds it opaquely). The text measurer
//! that Swift keeps in two mutable globals (`measureLines`, `lineHeight`) is the explicit `SQMenuTextMetrics` argument.

use crate::appearance_palette::PaletteColor;
use crate::controls_grid::{CGPoint, CGRect, CGSize};
use crate::key_binding::KeyModifiers;
use crate::localization::SQL10n;
use crate::sqicon::SQIcon;
use sq_os::{KeyTextStyle, Platform};
use std::any::Any;
use std::fmt;
use std::rc::Rc;

// SQMenu: the app's own context menu (FB-S). This file is the pure part (model, navigation, layout, icon table, switch), portable
// (the Windows app draws it through SQDrawKit). The existing menu builders keep working through `SQMenuItem`.

/// A tint is a palette color (the shared toolkit converts it).
pub type SQMenuTint = PaletteColor;

/// Reference box so a platform image can sit in a comparable enum; equal when it is the same image.
#[derive(Clone)]
pub struct SQMenuImageBox {
    pub image: Rc<dyn Any>,
}

impl SQMenuImageBox {
    pub fn new(image: Rc<dyn Any>) -> SQMenuImageBox {
        SQMenuImageBox { image }
    }
}

impl fmt::Debug for SQMenuImageBox {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SQMenuImageBox")
    }
}

#[derive(Clone, Debug)]
pub enum SQMenuIcon {
    None,
    /// Icon from the one icon set.
    Symbol(SQIcon),
    /// Eased progress samples 0...1 drawn as a small curve (interpolation menus).
    Curve(Vec<f64>),
    /// Label color chip, 0xRRGGBB.
    Swatch(u32),
    /// Any prepared image (template images are tinted with the row color).
    Image(SQMenuImageBox),
}

impl PartialEq for SQMenuIcon {
    fn eq(&self, other: &SQMenuIcon) -> bool {
        match (self, other) {
            (SQMenuIcon::None, SQMenuIcon::None) => true,
            (SQMenuIcon::Symbol(x), SQMenuIcon::Symbol(y)) => x == y,
            (SQMenuIcon::Curve(x), SQMenuIcon::Curve(y)) => x == y,
            (SQMenuIcon::Swatch(x), SQMenuIcon::Swatch(y)) => x == y,
            (SQMenuIcon::Image(x), SQMenuIcon::Image(y)) => Rc::ptr_eq(&x.image, &y.image),
            _ => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQMenuItemKind {
    Action,
    Separator,
    Header,
    Caption,
}

#[derive(Clone)]
pub struct SQMenuItem {
    pub kind: SQMenuItemKind,
    pub title: String,
    pub icon: SQMenuIcon,
    /// Pre-formatted shortcut text, e.g. "⇧⌘V" (right column).
    pub shortcut: String,
    pub is_enabled: bool,
    pub is_checked: bool,
    pub submenu: Option<Vec<SQMenuItem>>,
    pub action: Option<Rc<dyn Fn()>>,
    /// Optional leading icon drawn left of the title (opt-in; `icon` stays the swatch/curve slot). Tint nil = row color.
    pub leading_symbol: Option<SQIcon>,
    pub leading_tint: Option<SQMenuTint>,
    /// Help text drawn as a caption line under the title (the SQ replacement for `NSMenuItem.toolTip`).
    pub help: Option<String>,
    /// Destructive row (red text): set by title, so callers need no edit.
    pub is_destructive: bool,
    /// Experimental feature row: the flask follows the title (set by title, so callers need no edit).
    pub is_experimental: bool,
}

impl fmt::Debug for SQMenuItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SQMenuItem").field("kind", &self.kind).field("title", &self.title).finish_non_exhaustive()
    }
}

impl SQMenuItem {
    const DESTRUCTIVE_TITLES: [&'static str; 6] =
        ["Delete", "Ripple Delete", "Delete Track", "Remove Folder", "Close Panel", "Clear Used Media"];

    /// Red rows (artifact `RED`): the listed titles and every title that starts with Delete, Discard or Move to Trash ("Remove In and Out" only clears marks, so it is no red row).
    fn is_destructive_title(title: &str) -> bool {
        Self::DESTRUCTIVE_TITLES.contains(&title)
            || ["Delete", "Ripple Delete", "Discard", "Move to Trash"].iter().any(|p| title.starts_with(p))
    }

    // Keep in step with `sq_draw::experimental::Feature`: the rows that open an experimental feature.
    const EXPERIMENTAL_TITLES: [&'static str; 4] = ["Stabilize", "Magic", "Magic Mask", "Use Pro Grade (Color Graph)"];

    /// An enabled action row: translated title, no icon, shortcut, check, help, submenu or action.
    pub fn new(title: &str) -> SQMenuItem {
        SQMenuItem {
            kind: SQMenuItemKind::Action,
            title: SQL10n::string(title),
            icon: SQMenuIcon::None,
            shortcut: String::new(),
            is_enabled: true,
            is_checked: false,
            submenu: None,
            action: None,
            leading_symbol: None,
            leading_tint: None,
            help: None,
            is_destructive: Self::is_destructive_title(title),
            is_experimental: Self::EXPERIMENTAL_TITLES.contains(&title),
        }
    }

    /// The row with a (translated) help line under its title.
    pub fn with_help(mut self, help: &str) -> SQMenuItem {
        self.help = Some(SQL10n::string(help));
        self
    }

    pub fn separator() -> SQMenuItem {
        let mut i = SQMenuItem::new("");
        i.kind = SQMenuItemKind::Separator;
        i.is_enabled = false;
        i
    }

    pub fn header(title: &str) -> SQMenuItem {
        let mut i = SQMenuItem::new(title);
        i.kind = SQMenuItemKind::Header;
        i.is_enabled = false;
        i
    }

    /// A wrapping, non-selectable explanation row in the secondary text color (never truncated; the menu widens to `caption_width`).
    pub fn caption(text: &str) -> SQMenuItem {
        let mut i = SQMenuItem::new(text);
        i.kind = SQMenuItemKind::Caption;
        i.is_enabled = false;
        i
    }

    /// Row with a leading icon (optionally tinted, e.g. the support color).
    pub fn with_leading(&self, symbol: SQIcon, tint: Option<SQMenuTint>) -> SQMenuItem {
        let mut i = self.clone();
        i.leading_symbol = Some(symbol);
        i.leading_tint = tint;
        i
    }

    /// Can the highlight rest on this row?
    pub fn is_selectable(&self) -> bool {
        self.kind == SQMenuItemKind::Action && self.is_enabled
    }
}

impl PartialEq for SQMenuItem {
    fn eq(&self, b: &SQMenuItem) -> bool {
        self.kind == b.kind
            && self.leading_symbol == b.leading_symbol
            && self.title == b.title
            && self.icon == b.icon
            && self.shortcut == b.shortcut
            && self.is_experimental == b.is_experimental
            && self.is_enabled == b.is_enabled
            && self.is_checked == b.is_checked
            && self.help == b.help
            && self.submenu == b.submenu
    }
}

// MARK: Navigation (pure)

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQMenuMove {
    Up,
    Down,
    First,
    Last,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SQMenuResult {
    None,
    OpenedSubmenu,
    /// Index path from the root to the chosen leaf item.
    Run(Vec<usize>),
}

/// `source` is the full list; `items` the rows shown (filtered once the user types). `highlighted` indexes `items`,
/// `parent_index` and result paths index `source`.
#[derive(Clone, Debug)]
struct Level {
    source: Vec<SQMenuItem>,
    filter: String,
    highlighted: Option<usize>,
    parent_index: usize,
}

impl Level {
    fn map(&self) -> Vec<usize> {
        SQMenuFilter::indices(&self.source, &self.filter)
    }

    fn items(&self) -> Vec<SQMenuItem> {
        if self.filter.is_empty() {
            self.source.clone()
        } else {
            self.map().into_iter().map(|i| self.source[i].clone()).collect()
        }
    }
}

#[derive(Clone, Debug)]
pub struct SQMenuNavigator {
    levels: Vec<Level>,
}

impl SQMenuNavigator {
    pub fn new(items: Vec<SQMenuItem>) -> SQMenuNavigator {
        // The root level has no parent row; its index is never read (Swift uses -1).
        SQMenuNavigator {
            levels: vec![Level { source: items, filter: String::new(), highlighted: None, parent_index: 0 }],
        }
    }

    fn top(&self) -> usize {
        self.levels.len() - 1
    }

    /// Filter text of the innermost level; empty means no filter row is shown.
    pub fn filter(&self) -> &str {
        &self.levels[self.top()].filter
    }

    pub fn filter_at(&self, level: usize) -> &str {
        self.levels.get(level).map_or("", |l| l.filter.as_str())
    }

    pub fn depth(&self) -> usize {
        self.levels.len()
    }

    /// Highlighted row of the innermost open level.
    pub fn highlighted(&self) -> Option<usize> {
        self.levels[self.top()].highlighted
    }

    pub fn highlighted_at(&self, level: usize) -> Option<usize> {
        self.levels.get(level).and_then(|l| l.highlighted)
    }

    pub fn items_at(&self, level: usize) -> Vec<SQMenuItem> {
        self.levels.get(level).map_or_else(Vec::new, Level::items)
    }

    pub fn item_at(&self, path: &[usize]) -> Option<SQMenuItem> {
        let mut items = self.levels[0].source.clone();
        let mut found: Option<SQMenuItem> = None;
        for &i in path {
            let it = items.get(i)?.clone();
            items = it.submenu.clone().unwrap_or_default();
            found = Some(it);
        }
        found
    }

    pub fn move_highlight(&mut self, m: SQMenuMove) {
        let top = self.top();
        let items = self.levels[top].items();
        let sel: Vec<usize> = (0..items.len()).filter(|&i| items[i].is_selectable()).collect();
        if sel.is_empty() {
            return;
        }
        let cur = self.levels[top].highlighted;
        self.levels[top].highlighted = match m {
            SQMenuMove::First => sel.first().copied(),
            SQMenuMove::Last => sel.last().copied(),
            SQMenuMove::Down => cur.and_then(|c| sel.iter().find(|&&i| i > c).copied()).or(sel.first().copied()),
            SQMenuMove::Up => cur.and_then(|c| sel.iter().rev().find(|&&i| i < c).copied()).or(sel.last().copied()),
        };
    }

    /// Mouse over row `index` of `level` (default: innermost). Hovering a shallower level closes the deeper ones.
    pub fn hover(&mut self, index: Option<usize>, level: Option<usize>) {
        let top = self.top();
        let l = level.unwrap_or(top);
        if l >= self.levels.len() {
            return;
        }
        if l < top {
            self.levels.truncate(l + 1);
        }
        let items = self.levels[l].items();
        self.levels[l].highlighted = index.filter(|&i| items.get(i).is_some_and(SQMenuItem::is_selectable));
    }

    /// Return / click on the highlighted row.
    pub fn activate(&mut self) -> SQMenuResult {
        let top = self.top();
        let Some(h) = self.highlighted() else { return SQMenuResult::None };
        let items = self.levels[top].items();
        if !items[h].is_selectable() {
            return SQMenuResult::None;
        }
        if items[h].submenu.is_some() {
            return if self.open_submenu(h) { SQMenuResult::OpenedSubmenu } else { SQMenuResult::None };
        }
        let mut path: Vec<usize> = self.levels.iter().skip(1).map(|l| l.parent_index).collect();
        path.push(self.levels[top].map()[h]);
        SQMenuResult::Run(path)
    }

    pub fn right_key(&mut self) -> SQMenuResult {
        let top = self.top();
        let Some(h) = self.highlighted() else { return SQMenuResult::None };
        let items = self.levels[top].items();
        if !(items[h].is_selectable() && items[h].submenu.is_some()) {
            return SQMenuResult::None;
        }
        if self.open_submenu(h) { SQMenuResult::OpenedSubmenu } else { SQMenuResult::None }
    }

    /// Closes the innermost submenu; false at the root.
    pub fn left_key(&mut self) -> bool {
        if self.levels.len() <= 1 {
            return false;
        }
        self.levels.pop();
        true
    }

    fn open_submenu(&mut self, index: usize) -> bool {
        let top = self.top();
        let sub = self.levels[top].items()[index].submenu.clone().unwrap_or_default();
        if sub.is_empty() {
            return false;
        }
        let parent_index = self.levels[top].map()[index];
        self.levels.push(Level { source: sub, filter: String::new(), highlighted: None, parent_index });
        self.move_highlight(SQMenuMove::First);
        true
    }

    /// Type-to-filter: the first character creates the filter (row appears), later ones extend it.
    pub fn type_filter(&mut self, c: char) {
        let top = self.top();
        self.levels[top].filter.push(c);
        self.refilter();
    }

    /// Removes the last filter character; false when there was no filter.
    pub fn delete_filter_character(&mut self) -> bool {
        let top = self.top();
        if self.levels[top].filter.is_empty() {
            return false;
        }
        self.levels[top].filter.pop();
        self.refilter();
        true
    }

    /// Clears the filter; false when there was none (Esc then closes the menu).
    pub fn clear_filter(&mut self) -> bool {
        let top = self.top();
        if self.levels[top].filter.is_empty() {
            return false;
        }
        self.levels[top].filter.clear();
        self.refilter();
        true
    }

    fn refilter(&mut self) {
        let top = self.top();
        self.levels[top].highlighted = None;
        self.move_highlight(SQMenuMove::First);
    }
}

/// Case-insensitive substring filter over action titles; headers and separators drop out while filtering.
pub struct SQMenuFilter;

impl SQMenuFilter {
    pub fn indices(items: &[SQMenuItem], matching: &str) -> Vec<usize> {
        let f = matching.to_lowercase();
        if f.is_empty() {
            return (0..items.len()).collect();
        }
        (0..items.len())
            .filter(|&i| items[i].kind == SQMenuItemKind::Action && items[i].title.to_lowercase().contains(&f))
            .collect()
    }
}

// MARK: Shortcut text, layout, icons, switch

pub struct SQMenuShortcut;

impl SQMenuShortcut {
    /// "⌃⌥⇧⌘" + key, in Apple's order: the glyph text of `glyphs(key:modifiers:)` from a portable modifier set
    /// (on Windows: "Ctrl+Alt+Shift+Key").
    pub fn glyphs(key: &str, key_modifiers: KeyModifiers) -> String {
        Self::glyphs_for(Platform::current(), key, key_modifiers)
    }

    /// `glyphs` for a given system: symbols on the Mac, words elsewhere.
    pub fn glyphs_for(platform: Platform, key: &str, key_modifiers: KeyModifiers) -> String {
        if key.is_empty() {
            return String::new();
        }
        match platform.key_text_style() {
            KeyTextStyle::Symbols => Self::mac_text(key, key_modifiers),
            KeyTextStyle::Words => Self::windows_text(key, key_modifiers),
        }
    }

    /// "Ctrl+Alt+Shift+Key" (Command and Control both read as Ctrl, Option as Alt): what Windows shows in a menu row.
    pub fn windows_text(key: &str, m: KeyModifiers) -> String {
        if key.is_empty() {
            return String::new();
        }
        let mut parts: Vec<String> = Vec::new();
        if m.contains(KeyModifiers::COMMAND) || m.contains(KeyModifiers::CONTROL) {
            parts.push("Ctrl".to_string());
        }
        if m.contains(KeyModifiers::OPTION) {
            parts.push("Alt".to_string());
        }
        if m.contains(KeyModifiers::SHIFT) {
            parts.push("Shift".to_string());
        }
        parts.push(match key {
            "\u{8}" | "\u{7F}" => "Backspace".to_string(),
            "\r" | "\u{3}" => "Enter".to_string(),
            "\u{1B}" => "Esc".to_string(),
            " " => "Space".to_string(),
            _ => {
                if key == "ß" {
                    key.to_string()
                } else {
                    key.to_uppercase()
                }
            }
        });
        parts.join("+")
    }

    pub fn mac_text(key: &str, m: KeyModifiers) -> String {
        let mut s = String::new();
        if m.contains(KeyModifiers::CONTROL) {
            s.push('\u{2303}');
        }
        if m.contains(KeyModifiers::OPTION) {
            s.push('\u{2325}');
        }
        if m.contains(KeyModifiers::SHIFT) {
            s.push('\u{21E7}');
        }
        if m.contains(KeyModifiers::COMMAND) {
            s.push('\u{2318}');
        }
        s + &Self::key_text(key)
    }

    pub fn key_text(key: &str) -> String {
        match key {
            "\u{8}" | "\u{7F}" => "\u{232B}".to_string(),
            "\r" | "\u{3}" => "\u{21A9}".to_string(),
            "\u{1B}" => "\u{238B}".to_string(),
            " " => "Space".to_string(),
            // "ß" must stay "ß": uppercasing it would print two letters.
            _ => {
                if key == "ß" {
                    key.to_string()
                } else {
                    key.to_uppercase()
                }
            }
        }
    }
}

/// Off the Mac the toolkit measures text: lines of `text` wrapped at `width` in the `size` pt UI font (help: caption 10,
/// caption rows: body 11), and the height of one such line. The host sets these once its font is loaded.
#[derive(Clone, Copy)]
pub struct SQMenuTextMetrics {
    pub measure_lines: fn(text: &str, width: f64, size: f64) -> i64,
    pub line_height: fn(size: f64) -> f64,
}

impl Default for SQMenuTextMetrics {
    fn default() -> SQMenuTextMetrics {
        SQMenuTextMetrics {
            measure_lines: |t, w, s| ((t.chars().count() as f64 * s * 0.55 / w).ceil() as i64).max(1),
            line_height: |s| (s * 1.21).ceil(),
        }
    }
}

pub struct SQMenuLayout;

impl SQMenuLayout {
    // Artifact (`.menu`, `.mi`, `.msep`, `.mcap`): layer fill `overlay`, radius 10, padding 5, rows 24 with radius 4, padding
    // 8 each side, 8 gaps, check column 12 (only when a row is checked), separator 1 px with 4/6 margin (9 high), shortcut gap 28.
    // Width min 200.
    // The `Theme.Menu` values (OverlayTokens.swift is AppKit); the Mac build reads them from Theme.
    pub const ROW_HEIGHT: f64 = 24.0;
    pub const SEPARATOR_HEIGHT: f64 = 9.0;
    /// Extra row height for a help caption line.
    pub const HELP_HEIGHT: f64 = 12.0;
    /// A help line wraps at this text width (one more `HELP_HEIGHT` per extra line), so one long sentence never widens a menu.
    pub const HELP_WIDTH: f64 = 220.0;
    /// A menu dropped from a control (a value list) shows at most this many rows, then scrolls.
    pub const MAX_LIST_ROWS: i64 = 10;
    /// Tallest a list menu dropped from a control (no submenus) may be.
    pub const LIST_CAP_HEIGHT: f64 = Self::INSET * 2.0 + Self::MAX_LIST_ROWS as f64 * Self::ROW_HEIGHT;
    pub const HEADER_HEIGHT: f64 = 22.0;
    /// Header text sits this far above the header row's bottom.
    pub const HEADER_BOTTOM: f64 = 4.0;
    pub const SHORTCUT_GAP: f64 = 28.0;
    pub const SWATCH_SIZE: f64 = 10.0;
    pub const SWATCH_RADIUS: f64 = 3.0;
    pub const SEP_PAD: f64 = 6.0;
    pub const SUBMENU_OVERLAP: f64 = 8.0;
    pub const INSET: f64 = 4.0;
    pub const ROW_PAD: f64 = 8.0;
    /// Row left padding before the check column (`MenuItem` padding 6) and right padding after the shortcut or arrow (10).
    pub const ROW_PAD_LEFT: f64 = 6.0;
    pub const ROW_PAD_RIGHT: f64 = 10.0;
    pub const GAP: f64 = 8.0;
    pub const CHECK_COLUMN: f64 = 12.0;
    pub const DOT_COLUMN: f64 = 18.0;
    pub const CORNER_RADIUS: f64 = 7.0;
    pub const ROW_RADIUS: f64 = 4.0;
    pub const MIN_WIDTH: f64 = 200.0;
    pub const ICON_COLUMN: f64 = 22.0;
    /// Wrap width of a caption row's text, and the room a leading symbol takes.
    pub const CAPTION_WIDTH: f64 = 240.0;
    pub const CAPTION_PAD: f64 = 6.0;
    pub const SYMBOL_COLUMN: f64 = 22.0;
    /// Gap kept between a menu and the screen edge.
    pub const SCREEN_MARGIN: f64 = 8.0;
    /// Below this a side is not worth squeezing a long menu into; the menu uses the whole screen height instead.
    pub const MIN_SIDE_HEIGHT: f64 = 160.0;

    pub fn help_lines(i: &SQMenuItem, m: &SQMenuTextMetrics) -> i64 {
        match &i.help {
            Some(h) if !h.is_empty() => (m.measure_lines)(h, Self::HELP_WIDTH, 10.0),
            _ => 0,
        }
    }

    pub fn caption_height(text: &str, m: &SQMenuTextMetrics) -> f64 {
        (m.measure_lines)(text, Self::CAPTION_WIDTH, 11.0) as f64 * (m.line_height)(11.0) + 2.0 * Self::CAPTION_PAD
    }

    pub fn heights(items: &[SQMenuItem], m: &SQMenuTextMetrics) -> Vec<f64> {
        items
            .iter()
            .map(|i| match i.kind {
                SQMenuItemKind::Separator => Self::SEPARATOR_HEIGHT,
                SQMenuItemKind::Header => Self::HEADER_HEIGHT,
                SQMenuItemKind::Caption => Self::caption_height(&i.title, m),
                SQMenuItemKind::Action => Self::ROW_HEIGHT + Self::help_lines(i, m) as f64 * Self::HELP_HEIGHT,
            })
            .collect()
    }

    /// Content height of a menu: inset + the rows + inset (what the list view lays out; the panel clamps it to the screen).
    pub fn content_height(items: &[SQMenuItem], m: &SQMenuTextMetrics) -> f64 {
        Self::INSET * 2.0 + Self::heights(items, m).iter().sum::<f64>()
    }

    /// Tallest a menu may be on `screen` (its visible frame).
    pub fn max_height(screen: CGRect) -> f64 {
        (screen.height - 2.0 * Self::SCREEN_MARGIN).max(Self::ROW_HEIGHT)
    }

    /// Screen frame (y up) of a menu with `content` size. `anchor` is the top-left corner when it opens downward;
    /// `anchor_top` (the control's top edge, y) allows flipping above the control. The height is clamped to the screen's
    /// visible frame minus a margin, and the frame always lies fully inside it. The menu opens below if the whole content fits
    /// there, else above if it fits, else on the roomier side shortened to that room (it scrolls), else it fills the screen height.
    pub fn placement(content: CGSize, anchor: CGPoint, anchor_top: Option<f64>, screen: CGRect) -> CGRect {
        let area = screen.inset_by(Self::SCREEN_MARGIN, Self::SCREEN_MARGIN);
        let full = content.height.min(area.height);
        let w = content.width.min(area.width);
        let x = area.min_x().max(anchor.x.min(area.max_x() - w));
        let below = (anchor.y - area.min_y()).max(0.0);
        let mut h = full;
        let mut y = anchor.y - full;
        // A context menu has no control to flip around: it may open upward with its bottom edge at the click, so a menu
        // near the bottom of the screen with room above shows whole instead of scrolling.
        let anchor_top = anchor_top.or(Some(anchor.y));
        if full > below
            && let Some(top) = anchor_top
        {
            let above = (area.max_y() - top).max(0.0);
            if full <= above {
                y = top;
            } else if below.max(above) >= Self::MIN_SIDE_HEIGHT {
                h = full.min(below.max(above));
                y = if below >= above { anchor.y - h } else { top };
            }
        }
        y = area.min_y().max(y.min(area.max_y() - h));
        CGRect::new(x, y, w, h)
    }

    /// Screen y (up) of the top of a submenu opened from a row of a possibly scrolled parent.
    pub fn submenu_top(parent_max_y: f64, row_min_y: f64, parent_scroll: f64) -> f64 {
        parent_max_y - (row_min_y - parent_scroll) + Self::INSET
    }

    /// Bottom-left origin (screen coordinates, y up) for a menu whose top-left corner is at `anchor`; kept inside `screen`.
    pub fn origin(size: CGSize, anchor: CGPoint, screen: CGRect) -> CGPoint {
        let mut x = anchor.x;
        let mut y = anchor.y - size.height;
        x = screen.min_x().max(x.min(screen.max_x() - size.width));
        y = screen.min_y().max(y.min(screen.max_y() - size.height));
        CGPoint::new(x, y)
    }
}

/// What a mouse release does in a menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQMenuReleaseOutcome {
    Activate,
    Dismiss,
    Ignore,
}

/// The mouse-release rule of a menu (the usual menu rule). The click that opens a menu never selects. A row is chosen by a
/// new press inside the list followed by its release, or by releasing the opening press on a row after the pointer clearly
/// moved and a short delay passed.
pub struct SQMenuReleaseRule;

impl SQMenuReleaseRule {
    pub const MIN_DISTANCE: f64 = 4.0;
    pub const MIN_DELAY: f64 = 0.2;

    /// `pressed_in_list`: a press landed inside the open list before this release. `moved`: distance in points from where the menu
    /// opened to the release. `held`: seconds since the menu opened.
    /// `over_anchor`: the release is over the control the menu opened from; that never closes the menu.
    pub fn outcome(
        pressed_in_list: bool,
        over_row: bool,
        over_anchor: bool,
        moved: f64,
        held: f64,
    ) -> SQMenuReleaseOutcome {
        if pressed_in_list {
            return if over_row { SQMenuReleaseOutcome::Activate } else { SQMenuReleaseOutcome::Ignore };
        }
        if !(moved >= Self::MIN_DISTANCE && held >= Self::MIN_DELAY) {
            return SQMenuReleaseOutcome::Ignore;
        }
        if over_row {
            return SQMenuReleaseOutcome::Activate;
        }
        if over_anchor { SQMenuReleaseOutcome::Ignore } else { SQMenuReleaseOutcome::Dismiss }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SQMenuReleaseOutcome::*;

    const SCREEN: CGRect = CGRect::new(0.0, 0.0, 1440.0, 900.0);
    const M: f64 = SQMenuLayout::SCREEN_MARGIN;

    fn place(w: f64, h: f64, ax: f64, ay: f64, top: Option<f64>, screen: CGRect) -> CGRect {
        SQMenuLayout::placement(CGSize::new(w, h), CGPoint::new(ax, ay), top, screen)
    }

    #[test]
    fn short_menu_opens_below_the_anchor() {
        assert_eq!(place(200.0, 300.0, 100.0, 700.0, Some(724.0), SCREEN), CGRect::new(100.0, 400.0, 200.0, 300.0));
    }

    #[test]
    fn menu_flips_above_when_below_is_too_small_but_above_fits() {
        assert_eq!(place(200.0, 300.0, 100.0, 200.0, Some(224.0), SCREEN), CGRect::new(100.0, 224.0, 200.0, 300.0));
    }

    #[test]
    fn tall_menu_is_clamped_to_the_roomier_side_and_scrolls() {
        // Anchor near the top: below has 700 - 8, above has 900 - 8 - 724 = 168.
        let r = place(200.0, 2000.0, 100.0, 700.0, Some(724.0), SCREEN);
        assert_eq!(r.height, 700.0 - M);
        assert_eq!(r.min_y(), M);
        assert_eq!(r.max_y(), 700.0);
    }

    #[test]
    fn tall_menu_without_room_on_either_side_fills_the_screen_height() {
        let r = place(200.0, 2000.0, 100.0, 150.0, Some(170.0), CGRect::new(0.0, 0.0, 800.0, 300.0));
        assert_eq!(r.height, 300.0 - 2.0 * M);
        assert!(r.min_y() == M && r.max_y() == 300.0 - M);
    }

    #[test]
    fn menu_without_control_slides_into_the_screen() {
        // Too tall for the room above and below: it takes the roomier side, never leaves the screen.
        let r = place(200.0, 700.0, 100.0, 450.0, None, SCREEN);
        assert!(r.min_y() >= M && r.max_y() <= SCREEN.height - M, "{r:?}");
    }

    /// A context menu near the bottom of the screen with room above opens upward whole, without a scrollbar.
    #[test]
    fn context_menu_near_the_bottom_flips_upward_instead_of_scrolling() {
        // y is up: the click is 120 above the bottom edge, the 300 tall menu does not fit below, 780 are above.
        let r = place(200.0, 300.0, 100.0, 120.0, None, SCREEN);
        assert_eq!(r, CGRect::new(100.0, 120.0, 200.0, 300.0));
    }

    #[test]
    fn frame_stays_fully_on_screen_on_any_anchor() {
        let screens = [
            CGRect::new(0.0, 0.0, 1440.0, 900.0),
            CGRect::new(1440.0, -200.0, 1920.0, 1055.0),
            CGRect::new(-1280.0, 25.0, 1280.0, 775.0),
        ];
        for sc in screens {
            let area = sc.inset_by(M, M);
            for h in [100.0, 600.0, 5000.0] {
                for ax in [sc.min_x() - 50.0, sc.mid_x(), sc.max_x() - 10.0] {
                    for ay in [sc.min_y() + 5.0, sc.mid_y(), sc.max_y()] {
                        for top in [None, Some(ay + 24.0)] {
                            let r = place(220.0, h, ax, ay, top, sc);
                            assert!(area.contains_rect(&r), "{sc:?} {h} {ax} {ay} {top:?} -> {r:?}");
                            assert!(r.height <= SQMenuLayout::max_height(sc));
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn release_of_the_opening_click_never_selects() {
        // Still, short, or quick: ignored even over a row.
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 0.0, 0.05), Ignore);
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 0.0, 2.0), Ignore);
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 2.0, 2.0), Ignore);
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 30.0, 0.05), Ignore);
        // Press-drag-release: moved clearly and after a delay.
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 12.0, 0.4), Activate);
        assert_eq!(SQMenuReleaseRule::outcome(false, false, false, 12.0, 0.4), Dismiss);
    }

    #[test]
    fn release_over_the_anchor_leaves_the_menu_open() {
        assert_eq!(SQMenuReleaseRule::outcome(false, false, true, 12.0, 0.5), Ignore);
        assert_eq!(SQMenuReleaseRule::outcome(false, true, false, 12.0, 0.5), Activate);
        assert_eq!(SQMenuReleaseRule::outcome(false, false, false, 12.0, 0.5), Dismiss);
    }

    #[test]
    fn submenu_top_follows_the_parent_scroll() {
        let unscrolled = SQMenuLayout::submenu_top(800.0, 300.0, 0.0);
        let scrolled = SQMenuLayout::submenu_top(800.0, 300.0, 120.0);
        assert_eq!(scrolled, unscrolled + 120.0);
    }

    #[test]
    fn a_new_click_in_the_list_selects_on_release() {
        assert_eq!(SQMenuReleaseRule::outcome(true, true, false, 0.0, 0.05), Activate);
        assert_eq!(SQMenuReleaseRule::outcome(true, false, false, 0.0, 1.0), Ignore);
    }

    #[test]
    fn glyphs_per_system() {
        let cs = KeyModifiers::COMMAND | KeyModifiers::SHIFT;
        assert_eq!(SQMenuShortcut::glyphs_for(Platform::Mac, "v", cs), "\u{21E7}\u{2318}V");
        assert_eq!(SQMenuShortcut::glyphs_for(Platform::Windows, "v", cs), "Ctrl+Shift+V");
        assert_eq!(SQMenuShortcut::glyphs_for(Platform::Linux, "v", cs), "Ctrl+Shift+V");
        assert_eq!(SQMenuShortcut::glyphs_for(Platform::Linux, "", cs), "");
    }

    #[test]
    fn windows_text_names_the_keys() {
        let cs = KeyModifiers::COMMAND | KeyModifiers::SHIFT;
        assert_eq!(SQMenuShortcut::windows_text("v", cs), "Ctrl+Shift+V");
        assert_eq!(SQMenuShortcut::windows_text("v", KeyModifiers::COMMAND | KeyModifiers::OPTION), "Ctrl+Alt+V");
        assert_eq!(SQMenuShortcut::windows_text("g", KeyModifiers::EMPTY), "G");
        assert_eq!(SQMenuShortcut::windows_text("\u{8}", KeyModifiers::COMMAND), "Ctrl+Backspace");
        assert_eq!(SQMenuShortcut::windows_text("", KeyModifiers::COMMAND), "");
    }

    #[test]
    fn mac_text_keeps_the_glyphs() {
        assert_eq!(SQMenuShortcut::mac_text("v", KeyModifiers::COMMAND | KeyModifiers::SHIFT), "\u{21E7}\u{2318}V");
        assert_eq!(SQMenuShortcut::mac_text("ß", KeyModifiers::EMPTY), "ß");
        assert_eq!(SQMenuShortcut::key_text("\r"), "\u{21A9}");
    }

    #[test]
    fn layout_heights_and_default_metrics() {
        let m = SQMenuTextMetrics::default();
        let mut help = SQMenuItem::new("Row");
        help.help = Some("x".repeat(100));
        let items = vec![SQMenuItem::new("A"), SQMenuItem::separator(), SQMenuItem::header("H"), help];
        // 100 chars * 10 * 0.55 / 220 = 2.5 -> 3 lines.
        assert_eq!(SQMenuLayout::heights(&items, &m), vec![24.0, 9.0, 22.0, 24.0 + 3.0 * 12.0]);
        assert_eq!(SQMenuLayout::content_height(&items, &m), 8.0 + 24.0 + 9.0 + 22.0 + 60.0);
        assert_eq!(SQMenuLayout::LIST_CAP_HEIGHT, 248.0);
        // caption: 1 line of 11 pt: ceil(11 * 1.21) = 14, plus 2 * 6.
        assert_eq!(SQMenuLayout::caption_height("short", &m), 14.0 + 12.0);
    }

    fn sample() -> Vec<SQMenuItem> {
        let mut sub = SQMenuItem::new("More");
        sub.submenu = Some(vec![SQMenuItem::new("Inner One"), SQMenuItem::new("Inner Two")]);
        let mut off = SQMenuItem::new("Off");
        off.is_enabled = false;
        vec![
            SQMenuItem::header("Head"),
            SQMenuItem::new("Alpha"),
            off,
            SQMenuItem::separator(),
            sub,
            SQMenuItem::new("Delete"),
        ]
    }

    #[test]
    fn navigation_skips_rows_that_cannot_be_selected_and_wraps() {
        let mut n = SQMenuNavigator::new(sample());
        n.move_highlight(SQMenuMove::Down);
        assert_eq!(n.highlighted(), Some(1));
        n.move_highlight(SQMenuMove::Down);
        assert_eq!(n.highlighted(), Some(4));
        n.move_highlight(SQMenuMove::Down);
        n.move_highlight(SQMenuMove::Down);
        assert_eq!(n.highlighted(), Some(1));
        n.move_highlight(SQMenuMove::Up);
        assert_eq!(n.highlighted(), Some(5));
        n.move_highlight(SQMenuMove::First);
        assert_eq!(n.highlighted(), Some(1));
    }

    #[test]
    fn submenus_open_run_and_close() {
        let mut n = SQMenuNavigator::new(sample());
        n.hover(Some(4), None);
        assert_eq!(n.activate(), SQMenuResult::OpenedSubmenu);
        assert_eq!(n.depth(), 2);
        assert_eq!(n.highlighted(), Some(0));
        n.move_highlight(SQMenuMove::Down);
        assert_eq!(n.activate(), SQMenuResult::Run(vec![4, 1]));
        assert_eq!(n.item_at(&[4, 1]).map(|i| i.title), Some("Inner Two".to_string()));
        n.hover(Some(1), Some(0));
        assert_eq!(n.depth(), 1);
        assert!(!n.left_key());
        assert_eq!(n.activate(), SQMenuResult::Run(vec![1]));
    }

    #[test]
    fn typing_filters_by_title_and_paths_index_the_source() {
        let mut n = SQMenuNavigator::new(sample());
        n.type_filter('d');
        n.type_filter('E');
        assert_eq!(n.filter(), "dE");
        assert_eq!(n.items_at(0).len(), 1);
        assert_eq!(n.highlighted(), Some(0));
        assert_eq!(n.activate(), SQMenuResult::Run(vec![5]));
        assert!(n.delete_filter_character());
        assert!(n.clear_filter());
        assert!(!n.clear_filter());
        assert!(!n.delete_filter_character());
    }

    #[test]
    fn destructive_titles_are_marked() {
        assert!(SQMenuItem::new("Stabilize").is_experimental && SQMenuItem::new("Magic").is_experimental);
        assert!(!SQMenuItem::new("Gyroflow").is_experimental && !SQMenuItem::new("Alpha").is_experimental);
        assert!(SQMenuItem::new("Delete").is_destructive);
        assert!(!SQMenuItem::new("Alpha").is_destructive);
        assert!(!SQMenuItem::new("Remove In and Out").is_destructive && SQMenuItem::new("Delete Masks").is_destructive);
        assert!(SQMenuItem::new("Remove Folder").is_destructive);
    }
}
