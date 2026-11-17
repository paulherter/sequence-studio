// Swift: ToolStrip.swift
//! The tool column on the shared toolkit, translated from the Mac `ToolStripView`: the same `ToolStripLayout` geometry
//! and `ToolStripTools` list and menus. It is the content of the dockable Tools panel (36 wide, a grip in the panel
//! header, the tools in two groups): the dock draws the card and the header line and moves the panel, the strip draws the
//! grip dots and the tools into the frame the host gives it. Holding a slot with variants (or a right press on it) opens
//! its variants.

use crate::header::TimelineTips;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputModifiers, UiCx};
use sq_editor_session::{TimelineTool, ToolState};
use sq_timeline_ui::{ToolStripEdge, ToolStripLayout, ToolStripTools};
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// A menu the tool strip asks the host to open (built with `ToolStrip::items`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolStripMenu {
    /// The hold / right-click variants of a slot (Slip, Create, Mask).
    Variants(TimelineTool),
    /// Every tool with its key (right-click on the bar).
    AllTools,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ToolStripAction {
    /// The picked tool state: the host hands it to the timeline panel.
    SetTool(ToolState),
    /// Open `menu` at the point (window points).
    Menu(ToolStripMenu, CGPoint),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Press {
    Tool(usize, f64),
    /// The hold menu opened: the release is ignored.
    Done,
}

/// The strip.
pub struct ToolStrip {
    pub theme: DrawTheme,
    /// Seconds clock (injectable for tests).
    pub clock: Box<dyn Fn() -> f64>,
    /// The panel frame (header included) in window points.
    strip: CGRect,
    scale: f32,
    hovered: Option<usize>,
    press: Option<Press>,
}

fn uptime() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

impl ToolStrip {
    /// Design v9: hold 450 ms.
    pub const HOLD_DELAY: f64 = 0.45;
    const GLYPH_SIZE: f64 = 16.0;
    /// The glyph while a key-only tool's name chip sits under it, and the chip's type size.
    const BADGE_GLYPH: f64 = 12.0;
    const BADGE_SIZE: f64 = 8.0;

    /// Where the glyph and the name chip of a button `r` go: the glyph centered, or (with a name `name_w` wide) smaller at
    /// the top with the chip below it inside the button, so the two never touch.
    pub(crate) fn glyph_and_badge(r: CGRect, name_w: Option<f64>) -> (CGRect, Option<CGRect>) {
        let Some(w) = name_w else {
            let g = Self::GLYPH_SIZE;
            return (CGRect::new(r.mid_x() - g / 2.0, r.mid_y() - g / 2.0, g, g), None);
        };
        let g = Self::BADGE_GLYPH;
        let glyph = CGRect::new(r.mid_x() - g / 2.0, r.min_y() + 2.0, g, g);
        let w = (w + 4.0).min(r.width - 2.0);
        let top = glyph.max_y() + 1.0;
        (glyph, Some(CGRect::new(r.mid_x() - w / 2.0, top, w, (r.max_y() - 1.0 - top).max(0.0))))
    }

    pub fn new(theme: DrawTheme) -> Self {
        ToolStrip {
            theme,
            clock: Box::new(uptime),
            strip: CGRect::new(0.0, 0.0, 0.0, 0.0),
            scale: 1.0,
            hovered: None,
            press: None,
        }
    }

    fn tool_count() -> usize {
        ToolStripTools::ORDER.len()
    }

    pub fn is_dragging(&self) -> bool {
        self.press.is_some()
    }

    /// The panel frame in window points (empty while the panel is hidden).
    pub fn strip(&self) -> CGRect {
        self.strip
    }

    pub fn hovered(&self) -> Option<usize> {
        self.hovered
    }

    // MARK: Layout

    /// Puts the strip into the Tools panel's `frame` (window points, header included).
    pub fn place(&mut self, frame: CGRect, scale: f32) {
        self.scale = scale;
        self.strip = frame;
    }

    /// Grip and tool rects in window points.
    pub fn slots(&self) -> (CGRect, Vec<CGRect>) {
        let (grip, tools) = ToolStripLayout::slots(
            ToolStripEdge::Left,
            Self::tool_count(),
            CGSize { width: self.strip.width, height: self.strip.height },
        );
        let (ox, oy) = (self.strip.x, self.strip.y);
        let off = |r: CGRect| CGRect::new(r.x + ox, r.y + oy, r.width, r.height);
        // A tool below the panel's bottom edge (a window too short for the whole column) gets an empty rect: it is not
        // drawn and takes no press, so the column never runs over the status bar. Indices stay those of `ORDER`.
        // The last slot that fits goes to the overflow button (`overflow_frame`), so every hidden tool stays reachable.
        let bottom = self.strip.max_y();
        let mut tools: Vec<CGRect> = tools.into_iter().map(off).collect();
        let fits = |r: &CGRect| self.strip.height <= 0.0 || r.max_y() <= bottom + 0.5;
        let shown = tools.iter().take_while(|r| fits(r)).count();
        if shown < tools.len() {
            let keep = shown.saturating_sub(1);
            for r in &mut tools[keep..] {
                *r = CGRect::default();
            }
        }
        (off(grip), tools)
    }

    /// The overflow button ("»") while the panel is too short for the whole column: it takes the place of the last tool
    /// that fits and opens the all-tools menu with every tool and its key.
    pub fn overflow_frame(&self) -> Option<CGRect> {
        if self.strip.width <= 0.0 || self.strip.height <= 0.0 {
            return None;
        }
        let (_, tools) = ToolStripLayout::slots(
            ToolStripEdge::Left,
            Self::tool_count(),
            CGSize { width: self.strip.width, height: self.strip.height },
        );
        let bottom = self.strip.max_y();
        let raw: Vec<CGRect> =
            tools.into_iter().map(|r| CGRect::new(r.x + self.strip.x, r.y + self.strip.y, r.width, r.height)).collect();
        let shown = raw.iter().take_while(|r| r.max_y() <= bottom + 0.5).count();
        if shown >= raw.len() {
            return None;
        }
        raw.get(shown.saturating_sub(1)).copied()
    }

    /// The tool area of the panel (below the header, where the strip takes presses).
    pub fn contains(&self, x: f32, y: f32) -> bool {
        let p = CGPoint { x: f64::from(x / self.scale), y: f64::from(y / self.scale) };
        self.strip.width > 0.0 && self.strip.contains(p) && !self.slots().0.contains(p)
    }

    // MARK: Drawing

    /// Draws the grip and the tools (the dock draws the card and the line under the header) in window points.
    pub fn draw(&self, cv: &mut Canvas, state: &ToolState) {
        if self.strip.width <= 0.0 {
            return;
        }
        let t = &self.theme;
        let b = self.strip;
        let (grip, tools) = self.slots();
        // The dots-six grip in the panel header (spec 9, Tools).
        for (dx, dy) in [(-2.5, -5.0), (2.5, -5.0), (-2.5, 0.0), (2.5, 0.0), (-2.5, 5.0), (2.5, 5.0)] {
            cv.fill_ellipse(CGRect::new(grip.mid_x() + dx - 1.0, grip.mid_y() + dy - 1.0, 2.0, 2.0), t.label3());
        }
        if let Some(r) = self.overflow_frame() {
            if self.hovered == Some(usize::MAX) {
                cv.stone_button(r, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
            }
            // The same "»" as the menu bar's overflow title.
            cv.draw_text_in("»", r, 16.0, t.label3(), sq_draw::TextAlign::Center, 0.0, 0);
        }
        for (i, tool) in ToolStripTools::ORDER.iter().enumerate() {
            let Some(r) = tools.get(i).copied().filter(|r| r.width > 0.0) else { continue };
            let on = *tool == ToolStripTools::slot_tool(state.tool);
            // On = raised stone, hover = the quiet button's fill; the glyph is text3 off and text on.
            let hover = self.hovered == Some(i);
            if on {
                cv.stone_button(r, ButtonKind::Raised, Touch::default(), t);
            } else if hover {
                cv.stone_button(r, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
            }
            // A 16 pt separator between the two groups of a column.
            if i + 1 == ToolStripLayout::GROUP_SPLIT {
                let y = (r.max_y() + ToolStripLayout::GROUP_BREAK / 2.0 + ToolStripLayout::V_GAP / 2.0).floor();
                cv.fill(CGRect::new(b.min_x() + 10.0, y, 16.0, 1.0), t.track_header_line());
            }
            let badge = if on { ToolStripTools::badge(state.tool) } else { None };
            let name_w = badge.map_or(0.0, |n| cv.size_of(n, Self::BADGE_SIZE, 0).width);
            let (glyph, pill) = Self::glyph_and_badge(r, badge.map(|_| name_w));
            cv.draw_icon(
                ToolStripTools::icon(*tool, state),
                CGPoint { x: glyph.min_x(), y: glyph.min_y() },
                glyph.width,
                if on { t.label() } else { t.label3() },
                None,
            );
            if let (Some(name), Some(pill)) = (badge, pill) {
                // A key-only tool (B, R, ...) lights its group button: its short name sits in a chip under the glyph.
                cv.fill_rounded(pill, 3.0, t.panel());
                cv.draw_text_in(name, pill, Self::BADGE_SIZE, t.label(), sq_draw::TextAlign::Center, 0.0, 0);
            }
            if *tool == sq_editor_session::TimelineTool::Mask
                && state.mask_mode == sq_editor_session::MaskToolMode::Magic
                && sq_draw::experimental::prefs().shows_mark()
            {
                // The corner mark: 9 pt flask bottom right, on a disc in the panel color so it reads over the glyph.
                let s = 9.0;
                let o = CGPoint { x: r.max_x() - s - 3.0, y: r.max_y() - s - 3.0 };
                cv.fill_ellipse(CGRect::new(o.x - 1.5, o.y - 1.5, s + 3.0, s + 3.0), t.panel());
                cv.draw_icon(
                    sq_uikit::sqicon::SQIcon::Flask,
                    o,
                    s,
                    t.token(sq_uikit::redesign_tokens::color::EXP_TEXT),
                    None,
                );
            }
            // Flat icons: the artifact draws no variant triangle; variants open on long press as before.
        }
    }

    // MARK: Input

    fn pt(&self, x: f32, y: f32) -> CGPoint {
        let k = f64::from(self.scale);
        CGPoint { x: f64::from(x) / k, y: f64::from(y) / k }
    }

    /// The tip of the slot (or the grip) at window point `p`.
    pub fn tip_at(&self, p: CGPoint, state: &ToolState, map: &CommandMap) -> Option<String> {
        let (grip, tools) = self.slots();
        if grip.contains(p) {
            return Some(ToolStripTools::GRIP_TIP.to_string());
        }
        if self.overflow_frame().is_some_and(|r| r.contains(p)) {
            return Some("More tools".to_string());
        }
        let i = tools.iter().position(|r| r.contains(p))?;
        ToolStripTools::ORDER.get(i).map(|t| {
            let tip = TimelineTips::tool(*t, state, map);
            if *t == sq_editor_session::TimelineTool::Mask && state.mask_mode == sq_editor_session::MaskToolMode::Magic
            {
                return sq_draw::experimental::Feature::MagicMask.tooltip().replacen("Magic Mask", &tip, 1);
            }
            tip
        })
    }

    /// Handles one host event (device pixels); `None` = not the strip's (the host passes it on).
    pub fn handle(
        &mut self,
        e: &InputEvent,
        state: &ToolState,
        cx: &mut UiCx,
        map: &CommandMap,
    ) -> Option<Vec<ToolStripAction>> {
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                if !self.contains(x, y) {
                    return None;
                }
                Some(self.mouse_down(self.pt(x, y), modifiers.contains(InputModifiers::SECONDARY)))
            }
            InputEvent::MouseDragged { .. } => {
                self.press?;
                Some(Vec::new())
            }
            InputEvent::MouseUp { x, y } => {
                self.press?;
                Some(self.mouse_up(self.pt(x, y), state))
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.pt(x, y);
                self.hovered = self.slots().1.iter().position(|r| r.contains(p));
                if self.overflow_frame().is_some_and(|r| r.contains(p)) {
                    self.hovered = Some(usize::MAX);
                }
                if !self.contains(x, y) && !self.slots().0.contains(p) {
                    return None;
                }
                let tip = self.tip_at(p, state, map);
                cx.hover.offer_tip(tip.as_deref());
                Some(Vec::new())
            }
            InputEvent::Scroll { x, y, .. } => self.contains(x, y).then(Vec::new),
            _ => None,
        }
    }

    /// The hold menu of a slot with variants once the press lasted `HOLD_DELAY`.
    pub fn tick(&mut self) -> Vec<ToolStripAction> {
        let Some(Press::Tool(i, started)) = self.press else { return Vec::new() };
        if (self.clock)() - started < Self::HOLD_DELAY {
            return Vec::new();
        }
        self.press = Some(Press::Done);
        self.variants_menu(i).into_iter().collect()
    }

    fn variants_menu(&self, i: usize) -> Option<ToolStripAction> {
        let r = *self.slots().1.get(i)?;
        // v9: below the tool.
        Some(ToolStripAction::Menu(
            ToolStripMenu::Variants(*ToolStripTools::ORDER.get(i)?),
            CGPoint { x: r.min_x(), y: r.max_y() },
        ))
    }

    fn mouse_down(&mut self, p: CGPoint, secondary: bool) -> Vec<ToolStripAction> {
        let tools = self.slots().1;
        if let Some(r) = self.overflow_frame().filter(|r| r.contains(p)) {
            return vec![ToolStripAction::Menu(ToolStripMenu::AllTools, CGPoint { x: r.min_x(), y: r.max_y() })];
        }
        if let Some(i) = tools.iter().position(|r| r.contains(p)) {
            let tool = ToolStripTools::ORDER[i];
            if secondary {
                if ToolStripTools::has_variants(tool) {
                    return self.variants_menu(i).into_iter().collect();
                }
                return vec![ToolStripAction::Menu(ToolStripMenu::AllTools, p)];
            }
            self.press = Some(Press::Tool(i, (self.clock)()));
            return Vec::new();
        }
        if secondary {
            return vec![ToolStripAction::Menu(ToolStripMenu::AllTools, p)];
        }
        Vec::new()
    }

    fn mouse_up(&mut self, p: CGPoint, state: &ToolState) -> Vec<ToolStripAction> {
        let Some(Press::Tool(i, _)) = self.press.take() else { return Vec::new() };
        if !self.slots().1.get(i).is_some_and(|r| r.contains(p)) {
            return Vec::new();
        }
        let mut s = *state;
        s.tool = ToolStripTools::ORDER[i];
        vec![ToolStripAction::SetTool(s)]
    }

    /// The items of `menu`; picking a tool calls `commit` with the new state.
    pub fn items(
        &self,
        menu: ToolStripMenu,
        state: &ToolState,
        map: &CommandMap,
        commit: Rc<dyn Fn(ToolState)>,
    ) -> Vec<SQMenuItem> {
        match menu {
            ToolStripMenu::Variants(t) => ToolStripTools::variant_items(t, state, commit),
            ToolStripMenu::AllTools => ToolStripTools::all_tool_items(state, map, commit),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn strip_with_clock(now: Rc<Cell<f64>>) -> ToolStrip {
        let mut s = ToolStrip::new(DrawTheme::default());
        s.clock = Box::new(move || now.get());
        s.place(CGRect::new(0.0, 0.0, 36.0, 600.0), 1.0);
        s
    }

    /// The name chip of a key-only tool never meets the glyph and stays inside its button (Rip, Rate, Slide, ...).
    #[test]
    fn the_badge_never_overlaps_the_glyph() {
        let r = CGRect::new(5.0, 40.0, ToolStripLayout::V_TOOL_W, ToolStripLayout::V_TOOL_H);
        for t in sq_editor_session::TimelineTool::ALL {
            let Some(name) = ToolStripTools::badge(t) else { continue };
            // The widest a name gets: about 0.6 of the type size per letter.
            let w = name.chars().count() as f64 * ToolStrip::BADGE_SIZE * 0.6;
            let (glyph, pill) = ToolStrip::glyph_and_badge(r, Some(w));
            let pill = pill.unwrap_or_else(|| panic!("{name} has a chip"));
            assert!(pill.min_y() >= glyph.max_y(), "{name}: chip {pill:?} touches glyph {glyph:?}");
            assert!(pill.min_x() >= r.min_x() && pill.max_x() <= r.max_x(), "{name}: chip leaves the button");
            assert!(pill.max_y() <= r.max_y() && pill.height >= ToolStrip::BADGE_SIZE, "{name}: chip {pill:?} too low");
            assert!(glyph.min_x() >= r.min_x() && glyph.max_x() <= r.max_x() && glyph.min_y() >= r.min_y());
        }
    }

    fn at(r: CGRect) -> (f32, f32) {
        (r.mid_x() as f32, r.mid_y() as f32)
    }

    fn down(s: &mut ToolStrip, p: (f32, f32), secondary: bool) -> Option<Vec<ToolStripAction>> {
        let modifiers = if secondary { InputModifiers::SECONDARY } else { InputModifiers::NONE };
        s.handle(
            &InputEvent::MouseDown { x: p.0, y: p.1, modifiers },
            &ToolState::default(),
            &mut UiCx::new(),
            &CommandMap::current(),
        )
    }

    fn up(s: &mut ToolStrip, p: (f32, f32)) -> Option<Vec<ToolStripAction>> {
        s.handle(
            &InputEvent::MouseUp { x: p.0, y: p.1 },
            &ToolState::default(),
            &mut UiCx::new(),
            &CommandMap::current(),
        )
    }

    #[test]
    fn the_strip_fills_the_panel_frame_with_the_grip_in_the_header() {
        let now = Rc::new(Cell::new(0.0));
        let s = strip_with_clock(now);
        let (grip, tools) = s.slots();
        assert_eq!((grip.width, grip.height), (36.0, ToolStripLayout::GRIP_LENGTH));
        assert_eq!(tools.len(), ToolStripTools::ORDER.len());
        assert!(tools.iter().all(|r| r.min_y() >= grip.max_y() && s.strip().contains_rect(r)));
        assert!(!s.contains(18.0, 5.0), "the header belongs to the dock");
        assert!(s.contains(18.0, 300.0));
    }

    /// A panel too short for the whole column shows the tools that fit and none below its bottom edge (640x400: the
    /// last tool was drawn over the status bar).
    #[test]
    fn a_short_panel_shows_only_the_tools_that_fit() {
        let mut s = ToolStrip::new(DrawTheme::default());
        s.place(CGRect::new(0.0, 28.0, 36.0, 200.0), 1.0);
        let (_, tools) = s.slots();
        let shown: Vec<&CGRect> = tools.iter().filter(|r| r.width > 0.0).collect();
        assert!(!shown.is_empty() && shown.len() < tools.len(), "{} of {}", shown.len(), tools.len());
        assert!(shown.iter().all(|r| r.max_y() <= 228.0 + 0.5));
        let last = tools.iter().rposition(|r| r.width > 0.0).unwrap_or(0);
        assert!(tools[last + 1..].iter().all(|r| r.width == 0.0), "hidden tools are the last ones");
    }

    /// 640x400: every tool is a rail button or sits in the overflow menu (the button takes the last fitting slot).
    #[test]
    fn every_tool_is_reachable_on_a_short_panel() {
        let mut s = ToolStrip::new(DrawTheme::default());
        s.place(CGRect::new(0.0, 28.0, 36.0, 200.0), 1.0);
        let (_, tools) = s.slots();
        let over = s.overflow_frame().expect("overflow button");
        assert!(over.max_y() <= 228.5 && tools.iter().all(|r| r.width == 0.0 || r.max_y() <= over.min_y() + 0.5));
        let hidden = tools.iter().filter(|r| r.width == 0.0).count();
        assert!(hidden > 0);
        let out = down(&mut s, at(over), false).unwrap_or_default();
        let [ToolStripAction::Menu(ToolStripMenu::AllTools, _)] = out.as_slice() else { panic!("{out:?}") };
        let items = s.items(ToolStripMenu::AllTools, &ToolState::default(), &CommandMap::current(), Rc::new(|_| {}));
        for t in ToolStripTools::ORDER {
            let title = ToolStripTools::symbol(t).map_or("", |x| x.1);
            assert!(items.iter().any(|i| i.title == title), "{title} missing from the overflow menu");
        }
        // A tall panel has no overflow button.
        s.place(CGRect::new(0.0, 28.0, 36.0, 600.0), 1.0);
        assert!(s.overflow_frame().is_none());
    }

    #[test]
    fn a_click_on_a_tool_sets_it() {
        let now = Rc::new(Cell::new(0.0));
        let mut s = strip_with_clock(now);
        let r = s.slots().1[1];
        assert_eq!(down(&mut s, at(r), false), Some(Vec::new()));
        let out = up(&mut s, at(r)).unwrap_or_default();
        let want = ToolState { tool: ToolStripTools::ORDER[1], ..ToolState::default() };
        assert_eq!(out, vec![ToolStripAction::SetTool(want)]);
        // Released elsewhere: nothing.
        down(&mut s, at(r), false);
        assert_eq!(up(&mut s, (18.0, 500.0)), Some(Vec::new()));
    }

    #[test]
    fn holding_a_slot_opens_its_variants_and_ignores_the_release() {
        let now = Rc::new(Cell::new(0.0));
        let mut s = strip_with_clock(Rc::clone(&now));
        let i = ToolStripTools::ORDER.iter().position(|t| ToolStripTools::has_variants(*t)).unwrap_or(0);
        let r = s.slots().1[i];
        down(&mut s, at(r), false);
        now.set(0.2);
        assert!(s.tick().is_empty());
        now.set(0.5);
        let out = s.tick();
        assert_eq!(
            out,
            vec![ToolStripAction::Menu(
                ToolStripMenu::Variants(ToolStripTools::ORDER[i]),
                CGPoint { x: r.min_x(), y: r.max_y() }
            )]
        );
        assert_eq!(up(&mut s, at(r)), Some(Vec::new()));
        assert!(s.tick().is_empty());
    }

    #[test]
    fn a_secondary_press_opens_variants_or_all_tools() {
        let now = Rc::new(Cell::new(0.0));
        let mut s = strip_with_clock(now);
        let tools = s.slots().1;
        let plain = ToolStripTools::ORDER.iter().position(|t| !ToolStripTools::has_variants(*t)).unwrap_or(0);
        let out = down(&mut s, at(tools[plain]), true).unwrap_or_default();
        assert!(matches!(out.as_slice(), [ToolStripAction::Menu(ToolStripMenu::AllTools, _)]));
        let var = ToolStripTools::ORDER.iter().position(|t| ToolStripTools::has_variants(*t)).unwrap_or(0);
        let out = down(&mut s, at(tools[var]), true).unwrap_or_default();
        assert!(matches!(out.as_slice(), [ToolStripAction::Menu(ToolStripMenu::Variants(_), _)]));
    }

    #[test]
    fn the_all_tools_menu_has_no_dock_choices() {
        let now = Rc::new(Cell::new(0.0));
        let s = strip_with_clock(now);
        let items = s.items(ToolStripMenu::AllTools, &ToolState::default(), &CommandMap::current(), Rc::new(|_| {}));
        assert!(items.iter().all(|i| !i.title.starts_with("Dock") && i.title != "Float" && i.title != "Hide Tool Bar"));
    }

    #[test]
    fn tips_name_the_grip_and_the_tools() {
        let now = Rc::new(Cell::new(0.0));
        let s = strip_with_clock(now);
        let map = CommandMap::current();
        let st = ToolState::default();
        let (grip, tools) = s.slots();
        assert_eq!(
            s.tip_at(CGPoint { x: grip.mid_x(), y: grip.mid_y() }, &st, &map).as_deref(),
            Some(ToolStripTools::GRIP_TIP)
        );
        let tip = s.tip_at(CGPoint { x: tools[0].mid_x(), y: tools[0].mid_y() }, &st, &map).unwrap_or_default();
        assert!(tip.contains("Select, move and trim clips."));
        assert_eq!(s.tip_at(CGPoint { x: 500.0, y: 500.0 }, &st, &map), None);
    }

    #[test]
    fn events_outside_are_not_the_strips() {
        let now = Rc::new(Cell::new(0.0));
        let mut s = strip_with_clock(now);
        assert_eq!(down(&mut s, (600.0, 300.0), false), None);
        assert_eq!(up(&mut s, (600.0, 300.0)), None);
    }
}
