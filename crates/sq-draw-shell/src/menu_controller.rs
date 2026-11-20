// Swift: MenuController.swift
//! Shows one SQMenu inside the window: one `MenuListView` per open level, driven by `SQMenuNavigator`. `SQMenuController`
//! translated: the navigator, placement (`SQMenuLayout::placement`, `submenu_top`, `origin`) and the release rule
//! (`SQMenuReleaseRule`) are the Mac ones; floating panels become levels drawn on top of the window, event monitors become
//! `handle`. Window points, y down; the Mac math is y up, so `flip` converts at the boundary.

use crate::menu_list_view::MenuListView;
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, TextMeasure};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqmenu_model::{
    SQMenuItem, SQMenuLayout, SQMenuMove, SQMenuNavigator, SQMenuReleaseOutcome, SQMenuReleaseRule, SQMenuResult,
};
use std::rc::Rc;
use std::time::Instant;

/// How a chosen row's action is run (see [`MenuController::run`]).
pub type RunAction = Box<dyn Fn(Rc<dyn Fn()>)>;

/// Shows one menu with its submenus (Swift `MenuController`).
pub struct MenuController {
    nav: SQMenuNavigator,
    views: Vec<MenuListView>,
    /// The control the menu dropped from (window points): a press on it closes the menu and goes no further.
    anchor_rect: Option<CGRect>,
    anchor_top: Option<f64>,
    anchor: CGPoint,
    opened_at: f64,
    open_point: CGPoint,
    pressed_in_list: bool,
    keyboard_move: bool,
    /// Draw the open with its fade and grow; false once a key drove the menu (keyboard actions never animate).
    animate: bool,
    /// Window size in points (the "screen" the menu must stay inside).
    pub bounds: CGRect,
    /// Other areas of the canvas a menu may open in (the floating windows' rectangles): a menu opened at a point inside one
    /// stays inside it, so the window that was clicked shows it.
    pub regions: Vec<CGRect>,
    region: Option<CGRect>,
    /// Seconds clock for the release rule (tests set it).
    pub clock: Box<dyn Fn() -> f64>,
    /// Runs a chosen row's action after the menu closed (the host may defer it past the current event).
    pub run: RunAction,
    /// Left/Right at the root level with no submenu to open or close go to `take_side_key` (the menu bar moves to the
    /// neighbor menu); false: Left at the root closes the menu.
    pub side_keys: bool,
    dismissed: bool,
    side_key: Option<bool>,
    /// The press that closed the menu landed on its opener: where that opener places a menu and when. The same click (its
    /// release opens menus on most buttons) must not open the menu again, whatever the opener is; this is what makes a second
    /// click on the opener toggle the menu closed, for every opener that reports a placement point.
    reopen_guard: Option<(CGPoint, f64)>,
}

/// How long after a closing press the same opener stays blocked (seconds): long enough for the release and the host's
/// deferred open, short enough that the next deliberate click opens it.
const REOPEN_GUARD_SECS: f64 = 0.4;
/// Two placement points closer than this (points) belong to the same opener.
const SAME_OPENER: f64 = 2.0;

impl Default for MenuController {
    fn default() -> MenuController {
        MenuController::new()
    }
}

impl MenuController {
    /// A closed controller over a 1280 x 800 window.
    pub fn new() -> MenuController {
        let start = Instant::now();
        MenuController {
            nav: SQMenuNavigator::new(Vec::new()),
            views: Vec::new(),
            anchor_rect: None,
            anchor_top: None,
            anchor: CGPoint::ZERO,
            opened_at: 0.0,
            open_point: CGPoint::ZERO,
            pressed_in_list: false,
            keyboard_move: false,
            animate: true,
            bounds: CGRect::new(0.0, 0.0, 1280.0, 800.0),
            regions: Vec::new(),
            region: None,
            clock: Box::new(move || start.elapsed().as_secs_f64()),
            run: Box::new(|action| action()),
            side_keys: false,
            dismissed: false,
            side_key: None,
            reopen_guard: None,
        }
    }

    /// The open levels, outermost first.
    pub fn views(&self) -> &[MenuListView] {
        &self.views
    }

    /// Whether a menu is showing.
    pub fn is_open(&self) -> bool {
        !self.views.is_empty()
    }

    /// Open levels of the navigator.
    pub fn depth(&self) -> usize {
        self.nav.depth()
    }

    /// The rows of the open root level (empty when closed): what a right-click showed, for tests and the parity shots.
    pub fn root_items(&self) -> Vec<SQMenuItem> {
        if self.is_open() { self.nav.items_at(0) } else { Vec::new() }
    }

    /// The menu closed since the last call (Swift `onDismiss`).
    pub fn take_dismissed(&mut self) -> bool {
        std::mem::take(&mut self.dismissed)
    }

    /// A Left/Right key the menu bar must act on since the last call (Swift `onSideKey(right)`).
    pub fn take_side_key(&mut self) -> Option<bool> {
        self.side_key.take()
    }

    /// Shows `items` with the top-left corner at `point`. `anchor_top` (the control's top edge) lets the menu flip above it.
    pub fn present(
        &mut self,
        items: Vec<SQMenuItem>,
        point: CGPoint,
        anchor: Option<CGRect>,
        anchor_top: Option<f64>,
        pointer: Option<CGPoint>,
        m: &TextMeasure,
    ) {
        if let Some((guard, at)) = self.reopen_guard.take()
            && (self.clock)() - at < REOPEN_GUARD_SECS
            && (guard.x - point.x).hypot(guard.y - point.y) < SAME_OPENER
        {
            // The click that just closed this opener's menu asks for it again: it stays closed.
            self.reopen_guard = Some((guard, at));
            return;
        }
        self.dismiss_quietly();
        if items.is_empty() {
            return;
        }
        self.anchor_rect = anchor;
        let at = pointer.unwrap_or(point);
        self.region = self.regions.iter().copied().find(|r| r.contains(at));
        self.nav = SQMenuNavigator::new(items);
        self.animate = true;
        self.opened_at = (self.clock)();
        self.pressed_in_list = false;
        self.open_point = at;
        self.anchor_top = anchor_top;
        self.anchor = point;
        self.sync(m);
    }

    /// SQ rows below a control (a pull-down), top-left at its lower-left corner (`SQContextMenu.popUp(items:below:)`).
    pub fn pop_up(&mut self, items: Vec<SQMenuItem>, below: CGRect, pointer: Option<CGPoint>, m: &TextMeasure) {
        self.present(items, CGPoint::new(below.min_x(), below.max_y()), Some(below), Some(below.min_y()), pointer, m);
    }

    /// The open still fades and grows (false once a key opened or drove the menu).
    pub fn animates(&self) -> bool {
        self.animate
    }

    /// Closes the menu and reports it.
    pub fn dismiss(&mut self) {
        let was = self.is_open();
        self.dismiss_quietly();
        if was {
            self.dismissed = true;
        }
    }

    fn dismiss_quietly(&mut self) {
        self.anchor_rect = None;
        self.region = None;
        self.views.clear();
    }

    // MARK: Levels follow the navigator

    fn screen(&self) -> CGRect {
        self.region.unwrap_or(self.bounds)
    }

    fn flip(&self, y: f64) -> f64 {
        let s = self.screen();
        s.max_y() - y + s.min_y()
    }

    fn sync(&mut self, m: &TextMeasure) {
        self.views.truncate(self.nav.depth());
        for level in 0..self.nav.depth() {
            let items = self.nav.items_at(level);
            if level >= self.views.len() {
                self.add_level(level, items, m);
            } else if self.views[level].items != items || self.views[level].filter != self.nav.filter_at(level) {
                self.views[level].filter = self.nav.filter_at(level).to_string();
                self.views[level].items = items;
                self.views[level].relayout(m);
            }
            self.views[level].highlighted = self.nav.highlighted_at(level);
            if let Some(h) = self.views[level].highlighted
                && self.keyboard_move
            {
                self.views[level].reveal(h);
            }
        }
        self.keyboard_move = false;
    }

    fn add_level(&mut self, level: usize, items: Vec<SQMenuItem>, m: &TextMeasure) {
        let has_submenu = items.iter().any(|i| i.submenu.is_some());
        let mut view = MenuListView::new(items);
        view.max_height = Some(SQMenuLayout::max_height(self.screen()));
        // Never wider than the window: a long row is cut Finder-style and carries its full title as a tooltip.
        view.max_width = Some((self.screen().width - 2.0 * SQMenuLayout::SCREEN_MARGIN).max(SQMenuLayout::MIN_WIDTH));
        // Only a menu dropped from a real control is a value list that scrolls after ten rows; a context menu opened at a
        // point (a zero-size anchor) is as tall as its rows, flipped upward when the room below is short.
        let from_control = self.anchor_rect.is_some_and(|r| r.width > 0.0 && r.height > 0.0);
        if level == 0 && from_control && !has_submenu {
            view.max_height = Some(view.max_height.unwrap_or(f64::MAX).min(SQMenuLayout::LIST_CAP_HEIGHT));
        }
        view.relayout(m);
        if level == 0 {
            let content = CGSize::new(
                view.content_size().width,
                view.content_size().height.min(view.max_height.unwrap_or(f64::MAX)),
            );
            let r = SQMenuLayout::placement(
                content,
                CGPoint::new(self.anchor.x, self.flip(self.anchor.y)),
                self.anchor_top.map(|t| self.flip(t)),
                self.screen(),
            );
            view.max_height = Some(r.height.min(view.max_height.unwrap_or(r.height)));
            view.relayout(m);
            view.origin = CGPoint::new(r.min_x(), self.flip(r.max_y()));
        } else {
            // Submenu: right of the parent at the parent row, flipped to the left when it does not fit.
            let parent = &self.views[level - 1];
            let row = parent.row_frames[self.nav.highlighted_at(level - 1).unwrap_or(0)];
            let size = view.visible_size();
            let top_y = SQMenuLayout::submenu_top(self.flip(parent.frame().min_y()), row.min_y(), parent.scroll_offset);
            let screen = self.screen();
            let mut o = SQMenuLayout::origin(
                size,
                CGPoint::new(parent.frame().max_x() - SQMenuLayout::SUBMENU_OVERLAP, top_y),
                screen,
            );
            if parent.frame().max_x() - SQMenuLayout::SUBMENU_OVERLAP + size.width > screen.max_x() {
                o.x = screen.min_x().max(parent.frame().min_x() - size.width + SQMenuLayout::SUBMENU_OVERLAP);
            }
            view.origin = CGPoint::new(o.x, self.flip(o.y + size.height));
        }
        self.views.push(view);
    }

    // MARK: Events

    fn level_and_row(&self, p: CGPoint) -> Option<(usize, Option<usize>)> {
        (0..self.views.len()).rev().find(|&l| self.views[l].frame().contains(p)).map(|l| (l, self.views[l].index_at(p)))
    }

    fn on_anchor(&self, p: CGPoint) -> bool {
        self.anchor_rect.is_some_and(|r| r.contains(p))
    }

    /// Feeds one window event (points). True when the menu took it; a press outside closes the menu and returns false so the
    /// press still reaches its target, except on the control the menu came from.
    pub fn handle(&mut self, e: &InputEvent, scale: f32, m: &TextMeasure) -> bool {
        if !self.is_open() {
            return false;
        }
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        match *e {
            InputEvent::KeyDown { key, modifiers } => {
                self.handle_key(key, modifiers, m);
                true
            }
            InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } => {
                if let Some((level, row)) = self.level_and_row(pt(x, y)) {
                    // Same row whose submenu is already open: leave it alone.
                    if self.nav.depth() > level + 1 && self.nav.highlighted_at(level) == row {
                        return true;
                    }
                    self.nav.hover(row, Some(level));
                    if let Some(r) = row
                        && self.nav.items_at(level).get(r).is_some_and(|i| i.submenu.is_some())
                    {
                        let _ = self.nav.activate();
                    }
                    self.sync(m);
                }
                true
            }
            InputEvent::MouseDown { x, y, .. } => {
                let p = pt(x, y);
                if self.level_and_row(p).is_some() {
                    self.pressed_in_list = true;
                    return true;
                }
                let anchored = self.on_anchor(p);
                // A press on a point-anchored opener (no rect) cannot be told from any other press outside: the guard
                // blocks the same placement point instead.
                self.reopen_guard = Some((self.anchor, (self.clock)()));
                self.dismiss();
                anchored
            }
            InputEvent::MouseUp { x, y } => {
                let p = pt(x, y);
                let hit = self.level_and_row(p);
                let outcome = SQMenuReleaseRule::outcome(
                    self.pressed_in_list,
                    hit.is_some_and(|h| h.1.is_some()),
                    self.on_anchor(p),
                    (p.x - self.open_point.x).hypot(p.y - self.open_point.y),
                    (self.clock)() - self.opened_at,
                );
                self.pressed_in_list = false;
                match outcome {
                    SQMenuReleaseOutcome::Activate => {
                        if let Some((level, Some(r))) = hit {
                            self.nav.hover(Some(r), Some(level));
                            self.activate(m);
                        }
                    }
                    SQMenuReleaseOutcome::Dismiss => self.dismiss(),
                    SQMenuReleaseOutcome::Ignore => {}
                }
                true
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = pt(x, y);
                let level = (0..self.views.len())
                    .rev()
                    .find(|&l| self.views[l].frame().contains(p))
                    .or_else(|| self.views.len().checked_sub(1));
                if let Some(level) = level {
                    self.views[level].scroll(-f64::from(dy / scale));
                }
                true
            }
        }
    }

    fn handle_key(&mut self, k: InputKey, m: InputModifiers, tm: &TextMeasure) {
        self.keyboard_move = true;
        self.animate = false;
        match k {
            InputKey::Down => self.nav.move_highlight(SQMenuMove::Down),
            InputKey::Up => self.nav.move_highlight(SQMenuMove::Up),
            InputKey::Home => self.nav.move_highlight(SQMenuMove::First),
            InputKey::End => self.nav.move_highlight(SQMenuMove::Last),
            InputKey::PageUp => self.nav.move_highlight(SQMenuMove::First),
            InputKey::PageDown => self.nav.move_highlight(SQMenuMove::Last),
            InputKey::Right => {
                if self.nav.right_key() == SQMenuResult::None && self.nav.depth() == 1 {
                    self.side_key = Some(true);
                    return;
                }
            }
            InputKey::Left => {
                if !self.nav.left_key() {
                    if self.side_keys {
                        self.side_key = Some(false);
                    } else {
                        self.dismiss();
                    }
                    return;
                }
            }
            InputKey::Enter | InputKey::Space => {
                self.activate(tm);
                return;
            }
            InputKey::Escape => {
                if !self.nav.clear_filter() {
                    self.dismiss();
                    return;
                }
            }
            InputKey::Backspace => {
                let _ = self.nav.delete_filter_character();
            }
            InputKey::Character(c) => {
                if !m.contains(InputModifiers::COMMAND) && (c.is_alphabetic() || c.is_numeric()) {
                    self.nav.type_filter(c);
                }
            }
            InputKey::Plus | InputKey::Minus | InputKey::Delete | InputKey::Function(_) => {}
        }
        self.sync(tm);
    }

    fn activate(&mut self, m: &TextMeasure) {
        match self.nav.activate() {
            SQMenuResult::None => {}
            SQMenuResult::OpenedSubmenu => self.sync(m),
            SQMenuResult::Run(path) => {
                let action = self.nav.item_at(&path).and_then(|i| i.action);
                self.dismiss();
                if let Some(action) = action {
                    (self.run)(action);
                }
            }
        }
    }

    /// The tooltip for a mouse move over a row whose title was cut (its full title); `None` for any other event or spot.
    /// The host offers it with `Hover::offer_tip` while it routes the move.
    pub fn tip_at(&self, e: &InputEvent, scale: f32, m: &TextMeasure) -> Option<String> {
        let InputEvent::MouseMoved { x, y } = *e else { return None };
        let (level, row) = self.level_and_row(CGPoint::new(f64::from(x / scale), f64::from(y / scale)))?;
        self.views[level].title_tip(row?, m)
    }

    // MARK: Drawing

    /// Draws every open level.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        for (i, v) in self.views.iter().enumerate() {
            if self.animate {
                // Level 0 opens out of the click point or control; a submenu out of its parent row's side.
                let trigger = if i == 0 {
                    self.anchor
                } else {
                    let p = self.views[i - 1].frame();
                    CGPoint::new(p.max_x(), p.min_y())
                };
                let frame = v.frame();
                let origin = sq_draw::canvas::corner_toward(frame, trigger);
                c.open_motion_from(origin, 2 + i as u32, true, |c| v.draw(c, t));
            } else {
                v.draw(c, t);
            }
        }
    }
}
