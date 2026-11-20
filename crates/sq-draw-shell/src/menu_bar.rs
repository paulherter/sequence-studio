// Swift: MenuBar.swift
//! The in-window menu bar of the Windows app: the Mac main menu (`ShellMenuBar::build`) as a row of titles, each opening its
//! SQMenu below it (the Mac shows the same trees in the system bar). Usual menu bar behavior: a click opens or closes a menu,
//! moving over another title while one is open switches to it, Left/Right at the root switch menus, Esc closes. By keyboard:
//! Alt alone or F10 puts the focus on the bar (the host sends `alt_tapped`; F10 is handled here), then Left/Right move it,
//! Down/Enter open the menu, a title's mnemonic letter opens that menu, Esc leaves.

use crate::menu_controller::MenuController;
use crate::shell_menu_bar::ShellMenu;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextMeasure};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqmenu_model::SQMenuItem;

/// Rebuilds the menus right before one opens (state such as Undo names and recents changes all the time). Swift's
/// `MenuBar.refresh` closure captured the host; here the host lends it with each call, `None` keeps the menus as set.
pub type MenuRefresh<'a> = Option<&'a mut dyn FnMut() -> Vec<ShellMenu>>;

const TITLE_PAD: f64 = 8.0;
const FONT_SIZE: f64 = 11.0;
const TITLE_RADIUS: f64 = 4.0;
/// The open title's pill height (the redesign's title bar buttons).
const TITLE_H: f64 = 24.0;
const OVERFLOW_TITLE: &str = "»";

/// The in-window menu bar (Swift `MenuBar`).
pub struct MenuBar {
    height: f64,
    /// False when the bar sits on a title bar the host already painted: no fill, no bottom edge.
    pub draws_background: bool,
    shows_titles: bool,
    menus: Vec<ShellMenu>,
    /// Opens the bar's popups (also the Workspace popup).
    pub controller: MenuController,
    title_frames: Vec<CGRect>,
    open: Option<usize>,
    /// The title the keyboard holds while no menu is open (after Alt or F10); a pointer press or any other key lets go.
    kbd: Option<usize>,
    /// The title under the pointer (index; the overflow title is `title_frames().len()`).
    hover: Option<usize>,
    origin: CGPoint,
    max_width: Option<f64>,
    /// A second limit set by what shares the row (the start screen's search field, the title row's Export button).
    room_limit: Option<f64>,
    overflow_frame: Option<CGRect>,
    /// The titles sit in the window's title row (the edit window): the row paints the bar, this draws icon and titles.
    merged: bool,
}

impl Default for MenuBar {
    fn default() -> MenuBar {
        MenuBar::new()
    }
}

impl MenuBar {
    /// Bar height alone, in points.
    pub const DEFAULT_HEIGHT: f64 = sq_uikit::redesign_tokens::size::TOP_BAR as f64;
    /// Where the first title's frame starts: the 18 pt app icon at 12 pt and 8 pt of gap, less the title's own padding.
    pub const FIRST_TITLE_X: f64 = 30.0;

    /// An empty bar; the controller reports Left/Right at the root to the bar.
    pub fn new() -> MenuBar {
        let mut controller = MenuController::new();
        controller.side_keys = true;
        MenuBar {
            height: Self::DEFAULT_HEIGHT,
            draws_background: true,
            shows_titles: true,
            menus: Vec::new(),
            controller,
            title_frames: Vec::new(),
            open: None,
            kbd: None,
            origin: CGPoint::ZERO,
            max_width: None,
            room_limit: None,
            overflow_frame: None,
            hover: None,
            merged: false,
        }
    }

    /// Bar height in points: 28 alone, or the host's title bar height when the titles sit in it (Windows: the 44 pt top bar).
    pub fn height(&self) -> f64 {
        self.height
    }

    /// Sets the bar height and lays the titles out again.
    pub fn set_height(&mut self, h: f64, m: &TextMeasure) {
        self.height = h;
        self.layout_titles(m);
    }

    /// False on the Mac: the shared menus live in the system menu bar, the window shows no titles. The controller still
    /// opens the bar's popups (the Workspace popup).
    pub fn shows_titles(&self) -> bool {
        self.shows_titles
    }

    /// The app runs with the system menu bar (macOS): no titles, no strip, no height. The controller still opens popups.
    pub fn use_system_bar(&mut self) {
        self.shows_titles = false;
        self.draws_background = false;
        self.height = 0.0;
        self.title_frames = Vec::new();
        self.overflow_frame = None;
    }

    /// The titles sit in the title row (true) or the bar owns its own strip (the start screen).
    pub fn set_merged(&mut self, on: bool) {
        self.merged = on;
    }

    /// Shows or hides the titles.
    pub fn set_shows_titles(&mut self, on: bool, m: &TextMeasure) {
        self.shows_titles = on;
        self.layout_titles(m);
    }

    /// The menus.
    pub fn menus(&self) -> &[ShellMenu] {
        &self.menus
    }

    /// Replaces the menus and lays the titles out again.
    pub fn set_menus(&mut self, menus: Vec<ShellMenu>, m: &TextMeasure) {
        self.menus = if self.shows_titles { Self::merge_app_menu(menus) } else { menus };
        self.layout_titles(m);
    }

    /// The drawn bar has no app title (Windows and Linux): About, Settings and Keyboard Shortcuts follow File's rows, then
    /// Exit, and the "Sequence Studio" menu is dropped. A list without that menu or without File stays as it is.
    pub fn merge_app_menu(mut menus: Vec<ShellMenu>) -> Vec<ShellMenu> {
        use sq_uikit::sqmenu_model::SQMenuItemKind as K;
        if menus.len() < 2 || menus[0].title != "Sequence Studio" || menus[1].title != "File" {
            return menus;
        }
        let app = menus.remove(0);
        let mut rows: Vec<SQMenuItem> = app.items.into_iter().filter(|i| i.kind != K::Separator).collect();
        let exit = rows.pop();
        let file = &mut menus[0].items;
        file.push(SQMenuItem::separator());
        file.extend(rows);
        file.push(SQMenuItem::separator());
        file.extend(exit);
        menus
    }

    /// The title frames, one per shown menu.
    pub fn title_frames(&self) -> &[CGRect] {
        &self.title_frames
    }

    /// The open menu's index (`title_frames().len()` for the overflow title).
    pub fn open(&self) -> Option<usize> {
        self.open
    }

    /// Where the bar starts.
    pub fn origin(&self) -> CGPoint {
        self.origin
    }

    /// Moves the bar and lays the titles out again.
    pub fn set_origin(&mut self, origin: CGPoint, m: &TextMeasure) {
        self.origin = origin;
        self.layout_titles(m);
    }

    /// Room for the titles from `origin.x` (points); `None` = unlimited.
    pub fn max_width(&self) -> Option<f64> {
        self.max_width
    }

    /// Titles that do not fit fold into the overflow title ("»"), whose menu lists them as submenus (a narrow Windows
    /// window).
    pub fn set_max_width(&mut self, w: Option<f64>, m: &TextMeasure) {
        if self.max_width != w {
            self.max_width = w;
            self.layout_titles(m);
        }
    }

    /// Limits the titles to `w` points from `origin.x` on top of [`MenuBar::set_max_width`] (the smaller one wins); `None` lifts it.
    /// Titles past it fold into the overflow title, a title is never cut.
    pub fn set_room_limit(&mut self, w: Option<f64>, m: &TextMeasure) {
        if self.room_limit != w {
            self.room_limit = w;
            self.layout_titles(m);
        }
    }

    /// The right edge of all titles when nothing folds (window points).
    pub fn natural_right(&self, m: &TextMeasure) -> f64 {
        if !self.shows_titles {
            return self.origin.x;
        }
        self.origin.x
            + Self::FIRST_TITLE_X
            + self.menus.iter().map(|menu| m.width(&menu.title, FONT_SIZE, 0) + 2.0 * TITLE_PAD).sum::<f64>()
    }

    /// The overflow title while some titles are folded; its index for `open_menu` is `title_frames().len()`.
    pub fn overflow_frame(&self) -> Option<CGRect> {
        self.overflow_frame
    }

    /// Lays the titles out for the current menus, width and measure.
    pub fn layout_titles(&mut self, m: &TextMeasure) {
        self.overflow_frame = None;
        if !self.shows_titles {
            self.title_frames = Vec::new();
            return;
        }
        let mut x = self.origin.x + Self::FIRST_TITLE_X;
        let all: Vec<CGRect> = self
            .menus
            .iter()
            .map(|menu| {
                let w = m.width(&menu.title, FONT_SIZE, 0) + 2.0 * TITLE_PAD;
                let r = CGRect::new(x, self.origin.y, w, self.height);
                x += w;
                r
            })
            .collect();
        let room = match (self.max_width, self.room_limit) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let (Some(max_width), Some(last)) = (room, all.last()) else {
            self.title_frames = all;
            return;
        };
        if last.max_x() <= self.origin.x + max_width {
            self.title_frames = all;
            return;
        }
        let more_w = m.width(OVERFLOW_TITLE, FONT_SIZE, 0) + 2.0 * TITLE_PAD;
        let limit = self.origin.x + max_width - more_w;
        self.title_frames = all.iter().copied().take_while(|r| r.max_x() <= limit).collect();
        self.overflow_frame = Some(CGRect::new(
            self.title_frames.last().map_or(self.origin.x + Self::FIRST_TITLE_X, |r| r.max_x()),
            self.origin.y,
            more_w,
            self.height,
        ));
    }

    /// The menus folded into the overflow title.
    fn folded_menus(&self) -> &[ShellMenu] {
        if self.overflow_frame.is_none() { &[] } else { &self.menus[self.title_frames.len().min(self.menus.len())..] }
    }

    /// The title under `p`: an index into `menus`, or `title_frames().len()` for the overflow title.
    pub fn title_at(&self, p: CGPoint) -> Option<usize> {
        if let Some(i) = self.title_frames.iter().position(|r| r.contains(p)) {
            return Some(i);
        }
        self.overflow_frame.filter(|r| r.contains(p)).map(|_| self.title_frames.len())
    }

    /// The number of titles a click or Left/Right can open (the overflow title counts as one).
    fn openable_count(&self) -> usize {
        self.title_frames.len() + usize::from(self.overflow_frame.is_some())
    }

    /// Opens menu `i` (rebuilt first when `refresh` is given), optionally with its first row highlighted.
    pub fn open_menu(
        &mut self,
        i: usize,
        pointer: Option<CGPoint>,
        highlight_first: bool,
        m: &TextMeasure,
        refresh: &mut MenuRefresh,
    ) {
        if let Some(r) = refresh.as_mut() {
            self.menus = if self.shows_titles { Self::merge_app_menu(r()) } else { r() };
            self.layout_titles(m);
        }
        if let Some(more) = self.overflow_frame
            && i == self.title_frames.len()
        {
            self.open = Some(i);
            let folded: Vec<SQMenuItem> = self
                .folded_menus()
                .iter()
                .map(|menu| {
                    let mut item = SQMenuItem::new(&menu.title);
                    item.submenu = Some(menu.items.clone());
                    item
                })
                .collect();
            self.controller.pop_up(folded, more, pointer, m);
            self.open = Some(i);
            if highlight_first {
                self.press_down(m);
            }
            return;
        }
        if !(i < self.menus.len() && (i < self.title_frames.len() || !self.shows_titles)) {
            return;
        }
        self.open = Some(i);
        let below = self.title_frames.get(i).copied().unwrap_or_default();
        self.controller.pop_up(self.menus[i].items.clone(), below, pointer, m);
        // `present` dismisses the previous menu first, which cleared `open` in Swift.
        self.open = Some(i);
        if highlight_first {
            self.press_down(m);
        }
    }

    fn press_down(&mut self, m: &TextMeasure) {
        let _ = self.controller.handle(
            &InputEvent::KeyDown { key: InputKey::Down, modifiers: InputModifiers::NONE },
            1.0,
            m,
        );
    }

    /// Closes the open menu.
    pub fn dismiss(&mut self) {
        self.controller.dismiss();
        self.take_controller_events_without_steps();
    }

    fn take_controller_events_without_steps(&mut self) {
        if self.controller.take_dismissed() {
            self.open = None;
        }
    }

    /// Alt pressed and released alone, or F10 (the Windows menu key rule): puts the keyboard focus on the first title, a second
    /// press (or one with a menu open) lets go. No titles (the Mac's system bar): nothing.
    pub fn alt_tapped(&mut self, _m: &TextMeasure, _refresh: &mut MenuRefresh) {
        if self.open.is_some() {
            self.dismiss();
            self.kbd = None;
        } else if self.kbd.is_some() || !self.shows_titles || self.openable_count() == 0 {
            self.kbd = None;
        } else {
            self.kbd = Some(0);
        }
    }

    /// Whether the keyboard holds a title (after Alt or F10): the keys go to the bar before any panel.
    pub fn keyboard_focus(&self) -> Option<usize> {
        self.kbd
    }

    /// The mnemonic of each shown title: its first letter no earlier title uses (lowercase), the one after Alt or F10 that opens it.
    pub fn mnemonics(&self) -> Vec<Option<char>> {
        let mut used = Vec::new();
        let titles = self.menus.iter().take(self.title_frames.len()).map(|m| m.title.as_str());
        let mut out: Vec<Option<char>> = titles
            .map(|t| {
                let pick = t
                    .chars()
                    .filter(|c| c.is_alphanumeric())
                    .map(|c| c.to_ascii_lowercase())
                    .find(|c| !used.contains(c));
                used.extend(pick);
                pick
            })
            .collect();
        if self.overflow_frame.is_some() {
            out.push(None);
        }
        out
    }

    /// Alt held with a letter (the Windows and Linux mnemonic chord): opens the menu whose mnemonic the letter is. False when
    /// no shown title has it (the press is then free for a shortcut or a panel) or the bar has no titles (the Mac).
    pub fn open_mnemonic(&mut self, c: char, m: &TextMeasure, refresh: &mut MenuRefresh) -> bool {
        if !self.shows_titles {
            return false;
        }
        let Some(i) = self.mnemonics().iter().position(|x| *x == Some(c.to_ascii_lowercase())) else { return false };
        self.kbd = None;
        self.open_menu(i, None, true, m, refresh);
        true
    }

    /// A key while the keyboard holds a title: true when the bar took it (it takes every key until it lets go).
    fn handle_bar_key(
        &mut self,
        k: usize,
        key: InputKey,
        mods: InputModifiers,
        m: &TextMeasure,
        refresh: &mut MenuRefresh,
    ) -> bool {
        let n = self.openable_count();
        match key {
            InputKey::Left | InputKey::Right if n > 0 => {
                let d = if key == InputKey::Right { 1 } else { n as isize - 1 };
                self.kbd = Some((k + d as usize) % n);
            }
            InputKey::Down | InputKey::Up | InputKey::Enter | InputKey::Space => {
                self.kbd = None;
                self.open_menu(k, None, true, m, refresh);
            }
            InputKey::Character(c) if !mods.contains(InputModifiers::COMMAND) => {
                let hit = self.mnemonics().iter().position(|x| *x == Some(c.to_ascii_lowercase()));
                self.kbd = None;
                if let Some(i) = hit {
                    self.open_menu(i, None, true, m, refresh);
                }
            }
            _ => self.kbd = None,
        }
        true
    }

    fn step(&mut self, d: isize, m: &TextMeasure, refresh: &mut MenuRefresh) {
        let n = if self.shows_titles { self.openable_count() } else { self.menus.len() };
        let Some(o) = self.open else { return };
        if n == 0 {
            return;
        }
        let next = (o as isize + d).rem_euclid(n as isize) as usize;
        self.open_menu(next, None, true, m, refresh);
    }

    /// What the controller reported since the last call: the open title clears on dismiss, Left/Right switch menus.
    fn sync_events(&mut self, m: &TextMeasure, refresh: &mut MenuRefresh) {
        self.take_controller_events_without_steps();
        if let Some(right) = self.controller.take_side_key() {
            self.step(if right { 1 } else { -1 }, m, refresh);
        }
    }

    /// True when the bar or its open menu took the event.
    pub fn handle(&mut self, e: &InputEvent, scale: f32, m: &TextMeasure, refresh: &mut MenuRefresh) -> bool {
        self.take_controller_events_without_steps();
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        if matches!(e, InputEvent::MouseDown { .. } | InputEvent::Scroll { .. }) {
            self.kbd = None;
        }
        match *e {
            InputEvent::KeyDown { key: InputKey::Function(10), modifiers } if modifiers == InputModifiers::NONE => {
                if self.shows_titles {
                    self.alt_tapped(m, refresh);
                    return true;
                }
            }
            InputEvent::KeyDown { key, modifiers } if self.kbd.is_some() && self.open.is_none() => {
                if let Some(k) = self.kbd {
                    return self.handle_bar_key(k, key, modifiers, m, refresh);
                }
            }
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                if let Some(i) = self.title_at(p) {
                    if self.open == Some(i) {
                        self.dismiss();
                    } else {
                        self.open_menu(i, Some(p), false, m, refresh);
                    }
                    return true;
                }
            }
            InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } => {
                self.hover = self.title_at(pt(x, y));
                if let Some(o) = self.open
                    && let Some(i) = self.title_at(pt(x, y))
                    && i != o
                {
                    self.open_menu(i, Some(pt(x, y)), false, m, refresh);
                    return true;
                }
            }
            _ => {}
        }
        let took = self.controller.handle(e, scale, m);
        self.sync_events(m, refresh);
        took
    }

    /// Draws the titles.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, width: f64) {
        if self.draws_background && !self.merged {
            c.fill(CGRect::new(self.origin.x, self.origin.y, width, self.height), t.titlebar());
            c.fill(CGRect::new(self.origin.x, self.origin.y + self.height - 1.0, width, 1.0), t.hair());
        }
        if self.shows_titles {
            let icon =
                CGRect::new(self.origin.x + 12.0, self.origin.y + ((self.height - 18.0) / 2.0).round(), 18.0, 18.0);
            crate::ShellAppIcon::draw_ink_flush(icon, c);
        }
        let face = c.medium();
        for (i, menu) in self.menus.iter().enumerate() {
            let Some(r) = self.title_frames.get(i).copied() else { continue };
            self.draw_title(c, t, r, &menu.title, i, face);
        }
        if let Some(r) = self.overflow_frame {
            self.draw_title(c, t, r, OVERFLOW_TITLE, self.title_frames.len(), face);
        }
    }

    /// One title: text 2 at rest, a white 6 % pill on hover, the raised stone while its menu is open (`Menus/BarTitle`).
    fn draw_title(&self, c: &mut Canvas, t: &DrawTheme, r: CGRect, text: &str, i: usize, face: usize) {
        let open = self.open == Some(i);
        let focused = self.kbd == Some(i);
        let hovered = self.hover == Some(i) || focused;
        let pill = r.inset_by(0.0, 3.0_f64.max((r.height - TITLE_H) / 2.0));
        if open {
            c.stone_button(pill, ButtonKind::Raised, Touch::default(), t);
        } else if hovered {
            c.fill_rounded(pill, TITLE_RADIUS, t.row_hover());
        }
        c.draw_text_in(
            text,
            r,
            FONT_SIZE,
            if open || hovered { t.label() } else { t.label2() },
            TextAlign::Center,
            0.0,
            face,
        );
        // While the keyboard holds the bar, the letter that opens a title is underlined (the Windows mnemonic look).
        if self.kbd.is_some()
            && let Some(Some(letter)) = self.mnemonics().get(i)
            && let Some(at) = text.chars().position(|ch| ch.to_ascii_lowercase() == *letter)
        {
            let m = TextMeasure::new(c.atlas(), c.scale);
            let before: String = text.chars().take(at).collect();
            let one: String = text.chars().skip(at).take(1).collect();
            let x = r.mid_x() - m.width(text, FONT_SIZE, face) / 2.0 + m.width(&before, FONT_SIZE, face);
            let y = r.mid_y() + FONT_SIZE / 2.0 + 1.0;
            c.fill(CGRect::new(x, y, m.width(&one, FONT_SIZE, face), 1.0), t.label());
        }
    }

    /// The open menu on top of everything (call last).
    pub fn draw_menus(&self, c: &mut Canvas, t: &DrawTheme) {
        self.controller.draw(c, t);
    }
}

#[cfg(test)]
mod title_row_tests {
    use super::*;

    #[test]
    fn the_bar_is_the_40_pt_title_row_and_the_first_title_starts_after_the_app_icon() {
        let mut bar = MenuBar::new();
        assert_eq!(bar.height(), 40.0);
        let m = TextMeasure::new(None, 1.0);
        bar.set_menus(vec![ShellMenu { title: "File".into(), items: Vec::new() }], &m);
        let first = bar.title_frames()[0];
        // The 18 pt icon sits at 12; its 8 pt gap and the title's 8 pt padding put the text at x 38.
        assert_eq!(first.min_x() + 8.0, 12.0 + 18.0 + 8.0);
        assert_eq!(first.height, 40.0);
    }
}
