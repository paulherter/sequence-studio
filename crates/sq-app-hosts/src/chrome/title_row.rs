// Swift: WindowChrome.swift:152 (TitleRowHost)
//! The title row of the editing window after the menu titles: the project name, "Edited 2 min ago" in a slot as wide as
//! its widest text, in the bar's exact middle the Edit | Color page switch, and at the right end the Workspace popup and
//! the accent Export button.

use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, DrawTheme, TextAlign, TextMeasure};
use sq_editor_session::WorkspacePage;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{spacing, type_size};
use sq_uikit::sqicon::SQIcon;
use std::time::{Duration, SystemTime};

const NAME_MAX: f64 = 360.0;
const NAME_MIN: f64 = 80.0;
const GAP: f64 = spacing::MD as f64;
const SM: f64 = spacing::SM as f64;
/// The frame's `spacing/sm` (6) between a button's icon and label, and `spacing/md` (8) between the right-end buttons.
const ICON_GAP: f64 = sq_uikit::redesign_tokens::spacing::SM as f64;
const BUTTON_GAP: f64 = sq_uikit::redesign_tokens::spacing::MD as f64;
const CONTROL: f64 = sq_uikit::redesign_tokens::size::CONTROL_BAR as f64;
const NAME_FONT: f64 = type_size::TITLE as f64;
pub(super) const SMALL_FONT: f64 = type_size::BODY as f64;
/// One segment of the page switch (`ColorPageHost.switchSegment`) and its height.
const SEGMENT: f64 = 72.0;
const SWITCH_HEIGHT: f64 = 26.0;
/// The page switch's segments with the frame's icons (`Shell/PageSwitch`: film strip, half circle).
pub(super) const PAGES: [(WorkspacePage, SQIcon, &str); 2] =
    [(WorkspacePage::Edit, SQIcon::Film, "Edit"), (WorkspacePage::Color, SQIcon::Contrast, "Color")];
/// The Export button's icon (`Button/Primary`: upload) and the Workspace popup's (`Button/RaisedMenu`: layout).
/// Side of the app icon left of the project name.
pub(super) const APP_ICON: f64 = 16.0;
pub(super) const EXPORT_ICON: SQIcon = SQIcon::Upload;
pub(super) const WORKSPACE_ICON: SQIcon = SQIcon::Layout;
/// Icon box of the buttons and of the switch segments.
const ICON: f64 = 14.0;
const SAMPLES: [&str; 5] =
    ["Edited just now", "Edited 59 min ago", "Edited 23 h ago", "Edited 99 d ago", "Saved 59 min ago"];

fn inset(r: CGRect, d: f64) -> CGRect {
    CGRect::new(r.x + d, r.y + d, r.width - 2.0 * d, r.height - 2.0 * d)
}

/// The parts that take the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TitlePart {
    Workspace,
    Export,
    Page(WorkspacePage),
}

/// What a click on the row asks for.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TitleAction {
    /// The Export button.
    Export,
    /// The Workspace popup opens below this frame.
    Workspaces(CGRect),
    /// The Edit | Color switch.
    Page(WorkspacePage),
}

/// The row's state and frames.
#[derive(Debug, Default)]
pub struct TitleRow {
    pub project_name: String,
    /// When the project last changed or was saved; `None` hides the edit time.
    pub edited: Option<SystemTime>,
    /// `edited` is the time of the last save (the status bar says "Saved"), not of an unsaved change.
    pub saved: bool,
    pub workspace_name: String,
    /// The dock shows the Color page (else the Edit page): the raised segment of the switch.
    pub color_page: bool,
    /// The menu bar in this row already carries the app icon (Windows, Linux): the bar then shows neither the name nor the
    /// edit time, as in the kit's Windows frame (one app icon, top left, menus, page switch, buttons).
    pub icon_in_menu_bar: bool,
    switch: Option<CGRect>,
    pub(super) name: Option<CGRect>,
    /// The app icon left of the project name.
    pub(super) icon: Option<CGRect>,
    pub(super) edited_slot: Option<CGRect>,
    workspace: Option<CGRect>,
    export: Option<CGRect>,
    hovered: Option<TitlePart>,
    pressed: Option<TitlePart>,
}

impl TitleRow {
    /// "Edited just now", "Edited 2 min ago", "Edited 3 h ago", "Edited 4 d ago"; "Saved ..." for the time of the last
    /// save, so the title row and the status bar's "Saved" agree.
    pub fn edited_text(edited: Option<SystemTime>, saved: bool, now: SystemTime) -> String {
        let Some(edited) = edited else { return String::new() };
        let s = now.duration_since(edited).unwrap_or(Duration::ZERO).as_secs();
        let rel = match s {
            0..60 => "just now".to_string(),
            60..3600 => format!("{} min ago", s / 60),
            3600..86_400 => format!("{} h ago", s / 3600),
            _ => format!("{} d ago", s / 86_400),
        };
        format!("{} {rel}", if saved { "Saved" } else { "Edited" })
    }

    /// The Export button's width (primary button: 11 | icon 14 | 6 | label | 14).
    pub(super) fn export_width(m: &TextMeasure) -> f64 {
        (m.width("Export", SMALL_FONT, m.semibold())).ceil() + 11.0 + ICON + ICON_GAP + 14.0
    }

    /// The room the menu titles may take from the bar's left edge: they end `GAP` before the Export button.
    pub(super) fn menu_room(right: f64, m: &TextMeasure) -> f64 {
        right - Self::export_width(m) - GAP
    }

    /// Lays the parts out in the `bar_height` tall bar of `width` points that starts at `top`, from `x` (the end of the menu titles) to
    /// `right` (the `(width, right)` pair) (where Export's right edge sits). A narrow bar shortens the name, then drops the edit time and the Workspace popup; Export stays.
    pub fn layout(
        &mut self,
        x: f64,
        (width, right): (f64, f64),
        top: f64,
        bar_height: f64,
        m: &TextMeasure,
        now: SystemTime,
    ) {
        let ch = CONTROL.min(bar_height - 4.0);
        let y = top + ((bar_height - ch) / 2.0).round();
        // Primary button: 11 | icon 14 | 6 | label | 14.
        let export_w = Self::export_width(m);
        let export = CGRect::new(right - export_w, y, export_w, ch);
        let mut min_x = export.min_x();
        self.workspace = None;
        if !self.workspace_name.is_empty() {
            // Raised menu: 8 | icon 14 | 6 | label | 6 | caret 9 | 9.
            let w = m.width(&self.workspace_name, SMALL_FONT, 0).ceil() + 8.0 + ICON + 2.0 * ICON_GAP + 9.0 + 9.0;
            let r = CGRect::new(export.min_x() - BUTTON_GAP - w, y, w, ch);
            if r.min_x() - GAP >= x + GAP {
                min_x = r.min_x();
                self.workspace = Some(r);
            }
        }
        self.export = Some(export);
        // The switch sits in the bar's exact middle when the name and the popup leave room; it takes the name's room.
        let w = 2.0 * SEGMENT;
        let sw = CGRect::new(
            ((width - w) / 2.0).round(),
            top + ((bar_height - SWITCH_HEIGHT) / 2.0).round(),
            w,
            SWITCH_HEIGHT,
        );
        let fits = sw.min_x() - GAP >= x + GAP + NAME_MIN && sw.max_x() + GAP <= min_x;
        self.switch = fits.then_some(sw);
        if fits {
            min_x = sw.min_x();
        }
        let slot = SAMPLES.iter().map(|s| m.width(s, SMALL_FONT, 0).ceil()).fold(0.0, f64::max);
        // The app icon sits left of the name while the name keeps its minimum width.
        let mut left = x + GAP;
        self.icon = None;
        if !self.icon_in_menu_bar && min_x - GAP - left >= APP_ICON + SM + NAME_MIN {
            self.icon = Some(CGRect::new(left, top + ((bar_height - APP_ICON) / 2.0).round(), APP_ICON, APP_ICON));
            left += APP_ICON + SM;
        }
        let room = (min_x - GAP - left).max(0.0);
        if self.icon_in_menu_bar {
            // The kit's Windows frame has no project name or edit time in the bar: the OS window title carries the name.
            self.name = None;
            self.edited_slot = None;
            return;
        }
        let full = m.width(&self.project_name, NAME_FONT, m.semibold()).ceil().min(NAME_MAX);
        let keeps_slot = room - SM - slot >= full.min(NAME_MIN);
        let name_w = if keeps_slot { full.min(room - SM - slot) } else { full.min(room) };
        self.name = Some(CGRect::new(left, top, name_w, bar_height));
        let text = Self::edited_text(self.edited, self.saved, now);
        self.edited_slot = (keeps_slot && !text.is_empty() && m.width(&text, SMALL_FONT, 0) <= slot)
            .then(|| CGRect::new(left + name_w + SM, top, slot, bar_height));
    }

    /// Draws the row's own parts (the bar itself belongs to the caller).
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, now: SystemTime) {
        if let Some(r) = self.icon {
            sq_draw_shell::ShellAppIcon::draw(r, c, false);
        }
        if let Some(r) = self.name.filter(|r| r.width > 0.0) {
            c.draw_text_in(&self.project_name, r, NAME_FONT, t.label(), TextAlign::Left, 0.0, c.semibold());
        }
        if let Some(r) = self.edited_slot {
            let text = Self::edited_text(self.edited, self.saved, now);
            c.draw_text_in(&text, r, SMALL_FONT, t.label3(), TextAlign::Left, 0.0, 0);
        }
        self.draw_switch(c, t);
        if let Some(r) = self.workspace {
            let touch = self.touch(TitlePart::Workspace);
            let r = c.stone_button(r, ButtonKind::RaisedMenu, touch, t);
            let icon = CGPoint::new(r.min_x() + 8.0, (r.mid_y() - ICON / 2.0).round());
            c.draw_icon(WORKSPACE_ICON, icon, ICON, t.label3(), None);
            let text = CGRect::new(
                icon.x + ICON + ICON_GAP,
                r.min_y(),
                r.width - 8.0 - ICON - 2.0 * ICON_GAP - 18.0,
                r.height,
            );
            c.draw_text_in(&self.workspace_name, text, SMALL_FONT, t.label(), TextAlign::Left, 0.0, 0);
            let at = CGPoint::new(r.max_x() - 9.0 - 9.0, (r.mid_y() - 4.5).round());
            c.draw_icon(SQIcon::ChevronDown, at, 9.0, t.label4(), None);
        }
        if let Some(r) = self.export {
            let touch = self.touch(TitlePart::Export);
            let r = c.stone_button(r, ButtonKind::Accent, touch, t);
            let white = sq_draw::Color::rgb(1.0, 1.0, 1.0);
            let icon = CGPoint::new(r.min_x() + 11.0, (r.mid_y() - ICON / 2.0).round());
            c.draw_icon(EXPORT_ICON, icon, ICON, white, None);
            let label = CGRect::new(icon.x + ICON + ICON_GAP, r.min_y(), r.width, r.height);
            c.draw_text_in("Export", label, SMALL_FONT, white, TextAlign::Left, 0.0, c.semibold());
        }
    }

    /// Pointer state of one part for the stone helpers.
    fn touch(&self, part: TitlePart) -> Touch {
        Touch { hovering: self.hovered == Some(part), pressed: self.pressed == Some(part), ..Touch::default() }
    }

    /// The frame of one segment of the switch.
    fn segment(&self, page: WorkspacePage) -> Option<CGRect> {
        let f = self.switch?;
        let i = if page == WorkspacePage::Edit { 0.0 } else { 1.0 };
        Some(CGRect::new(f.min_x() + i * SEGMENT, f.min_y(), SEGMENT, f.height))
    }

    /// The Workspace button's frame (window points), when the row shows one.
    #[cfg(test)]
    pub fn workspace_frame(&self) -> Option<CGRect> {
        self.workspace
    }

    /// The frames that take clicks; the rest of the row (name, edit time, gaps) is free for a window drag.
    pub fn controls(&self) -> Vec<CGRect> {
        [self.export, self.workspace, self.switch].into_iter().flatten().collect()
    }

    fn part_at(&self, p: CGPoint) -> Option<TitlePart> {
        let pages = PAGES.map(|(page, ..)| (TitlePart::Page(page), self.segment(page)));
        [(TitlePart::Export, self.export), (TitlePart::Workspace, self.workspace)]
            .into_iter()
            .chain(pages)
            .find(|(_, r)| r.is_some_and(|r| r.contains(p)))
            .map(|(part, _)| part)
    }

    /// The switch: one well, the shown page raised, each segment an icon and its name.
    fn draw_switch(&self, c: &mut Canvas, t: &DrawTheme) {
        let Some(f) = self.switch else { return };
        c.stone_segment_track(f, Touch::default(), t);
        for (page, icon, title) in PAGES {
            let Some(r) = self.segment(page) else { continue };
            let on = (page == WorkspacePage::Color) == self.color_page;
            c.stone_segment(inset(r, 2.0), on, self.touch(TitlePart::Page(page)), t);
            let color = if on { t.label() } else { t.label2() };
            let (icon_w, gap) = (ICON, ICON_GAP);
            let tw = c.size_of(title, SMALL_FONT, 0).width;
            let x = (r.mid_x() - (icon_w + gap + tw) / 2.0).round();
            c.draw_icon(icon, CGPoint::new(x, (r.mid_y() - icon_w / 2.0).round()), icon_w, color, None);
            let label = CGRect::new(x + icon_w + gap, r.min_y(), tw + 2.0, r.height);
            c.draw_text_in(title, label, SMALL_FONT, color, TextAlign::Left, 0.0, c.medium());
        }
    }

    /// Hover and clicks, `p` in window points. Returns whether the row took the event and what it asks for.
    pub fn mouse(&mut self, e: Mouse, p: CGPoint) -> (bool, Option<TitleAction>) {
        let part = self.part_at(p);
        match e {
            Mouse::Moved => {
                self.hovered = part;
                (false, None)
            }
            Mouse::Down => {
                let Some(part) = part else { return (false, None) };
                self.pressed = Some(part);
                if let TitlePart::Page(page) = part {
                    self.pressed = None;
                    return (true, Some(TitleAction::Page(page)));
                }
                match (part, self.workspace) {
                    (TitlePart::Workspace, Some(r)) => {
                        self.pressed = None;
                        (true, Some(TitleAction::Workspaces(r)))
                    }
                    _ => (true, None),
                }
            }
            Mouse::Up => {
                let Some(pressed) = self.pressed.take() else { return (false, None) };
                (true, (pressed == TitlePart::Export && part == Some(pressed)).then_some(TitleAction::Export))
            }
        }
    }
}

/// The pointer events the row reacts to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mouse {
    Moved,
    Down,
    Up,
}
