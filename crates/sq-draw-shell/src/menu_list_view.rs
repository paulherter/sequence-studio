// Swift: MenuListView.swift
//! One level of a menu: rows, shortcut column, checkmarks, submenu chevrons. `SQMenuListView` translated: the layout code
//! is the same line for line, the drawing goes to the `Canvas` (points, y down) instead of AppKit. Dumb: the controller
//! (`MenuController`) owns the navigation state.

use sq_draw::middle_fit::TruncatedLabel;
use sq_draw::{Canvas, Color, DrawTheme, TextAlign, TextMeasure};
use sq_uikit::appearance_palette::PaletteColor;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::design_tokens::sq_tokens::radius;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuIcon, SQMenuItem, SQMenuItemKind, SQMenuLayout, SQMenuTextMetrics, SQMenuTint};

/// The menu font sizes (artifact `.mi` 11, `shortcutFont` 11, `captionFont` 11 semibold, help `Typography.caption` 10,
/// caption rows `Typography.body` 11).
pub enum MenuFont {}

impl MenuFont {
    /// Row title.
    pub const TITLE: f64 = 12.0;
    /// Shortcut column.
    pub const SHORTCUT: f64 = 11.5;
    /// Submenu arrow box.
    pub const ARROW: f64 = 8.0;
    /// Section header.
    pub const HEADER: f64 = 10.0;
    /// Help line under a title.
    pub const HELP: f64 = 10.0;
    /// Caption rows.
    pub const CAPTION: f64 = 11.0;
}

/// One level of a menu (Swift `MenuListView`).
#[derive(Clone, Debug)]
pub struct MenuListView {
    /// The rows.
    pub items: Vec<SQMenuItem>,
    /// Type-to-filter text; the filter row exists only while this is non-empty.
    pub filter: String,
    /// The filter row's frame while a filter is typed.
    pub filter_frame: Option<CGRect>,
    /// The highlighted row.
    pub highlighted: Option<usize>,
    /// Row frames in list space.
    pub row_frames: Vec<CGRect>,
    /// List width.
    pub width: f64,
    /// Width of the leading-symbol column (0 without symbols).
    pub symbol_width: f64,
    /// Width of the check and swatch columns.
    pub icon_width: f64,
    /// Tallest the list may be (the window's room); taller content scrolls.
    pub max_height: Option<f64>,
    /// How far the list is scrolled.
    pub scroll_offset: f64,
    /// Widest the list may be (the window less its margins); a longer row is cut Finder-style and its full title becomes the
    /// row's tooltip ([`Self::title_tip`]).
    pub max_width: Option<f64>,
    /// Top-left corner in window points (set by the controller when it places the level).
    pub origin: CGPoint,
}

impl MenuListView {
    /// A row's shortcut as `platform` shows it: a Mac glyph text ("\u{2318}C") reads "Ctrl+C" on Windows and Linux (one
    /// place for every menu, so a host that spells the glyph still shows the right keys).
    pub fn shown_shortcut_for(shortcut: &str, platform: sq_os::Platform) -> String {
        sq_uikit::platform_wording::PlatformWording::adapt(shortcut, platform)
    }

    fn shown_shortcut(shortcut: &str) -> String {
        Self::shown_shortcut_for(shortcut, sq_os::Platform::current())
    }

    /// A list over `items`; call `relayout` before use.
    pub fn new(items: Vec<SQMenuItem>) -> MenuListView {
        MenuListView {
            items,
            filter: String::new(),
            filter_frame: None,
            highlighted: None,
            row_frames: Vec::new(),
            width: SQMenuLayout::MIN_WIDTH,
            symbol_width: 0.0,
            icon_width: SQMenuLayout::ICON_COLUMN,
            max_height: None,
            max_width: None,
            scroll_offset: 0.0,
            origin: CGPoint::ZERO,
        }
    }

    /// Full size of the rows.
    pub fn content_size(&self) -> CGSize {
        CGSize::new(self.width, self.row_frames.last().map_or(SQMenuLayout::INSET, |r| r.max_y()) + SQMenuLayout::INSET)
    }

    /// What the list shows: the content, clamped to `max_height`.
    pub fn visible_size(&self) -> CGSize {
        CGSize::new(self.width, self.content_size().height.min(self.max_height.unwrap_or(f64::MAX)))
    }

    /// The list's frame in window points.
    pub fn frame(&self) -> CGRect {
        let s = self.visible_size();
        CGRect::new(self.origin.x, self.origin.y, s.width, s.height)
    }

    /// The furthest the list can scroll.
    pub fn max_scroll(&self) -> f64 {
        (self.content_size().height - self.visible_size().height).max(0.0)
    }

    /// Height of the strip with the scroll arrow at a cut edge.
    pub const SCROLL_HINT_HEIGHT: f64 = 16.0;

    /// Which edges cut rows off: (rows hidden above, rows hidden below). The list draws an arrow on each such edge.
    pub fn scroll_hints(&self) -> (bool, bool) {
        let max = self.max_scroll();
        (max > 0.0 && self.scroll_offset > 0.5, max > 0.0 && self.scroll_offset < max - 0.5)
    }

    /// Scrolls by `delta`.
    pub fn scroll(&mut self, delta: f64) {
        self.set_scroll(self.scroll_offset + delta);
    }

    fn set_scroll(&mut self, y: f64) {
        self.scroll_offset = y.min(self.max_scroll()).max(0.0);
    }

    /// Scrolls the least that shows row `i` completely.
    pub fn reveal(&mut self, i: usize) {
        let Some(r) = self.row_frames.get(i).copied() else { return };
        if r.min_y() - SQMenuLayout::INSET < self.scroll_offset {
            self.set_scroll(r.min_y() - SQMenuLayout::INSET);
        } else if r.max_y() + SQMenuLayout::INSET > self.scroll_offset + self.visible_size().height {
            self.set_scroll(r.max_y() + SQMenuLayout::INSET - self.visible_size().height);
        }
    }

    /// Lays the rows out for the current items, filter and `max_height`.
    pub fn relayout(&mut self, m: &TextMeasure) {
        let metrics = SQMenuTextMetrics::default();
        // Artifact: [check 12 + gap 8, only when a row is checked][swatch 10 + gap 8, only when a row carries one][title].
        let dots = self.items.iter().any(|i| matches!(i.icon, SQMenuIcon::Swatch(_)));
        let checks = dots || self.items.iter().any(|i| i.is_checked);
        self.icon_width = (if checks { SQMenuLayout::CHECK_COLUMN + SQMenuLayout::GAP } else { 0.0 })
            + (if dots { SQMenuLayout::DOT_COLUMN } else { 0.0 });
        // Artifact: the width is the widest single row (title + gap + its own shortcut), not widest title + widest shortcut.
        let mut max_text: f64 = 0.0;
        let mut max_row: f64 = 0.0;
        let symbols = self.items.iter().any(|i| i.leading_symbol.is_some());
        self.symbol_width = if symbols { SQMenuLayout::SYMBOL_COLUMN } else { 0.0 };
        for i in self.items.iter().filter(|i| i.kind == SQMenuItemKind::Action) {
            let mut tw = m.width(&i.title, MenuFont::TITLE, 0);
            if let Some(h) = i.help.as_deref().filter(|h| !h.is_empty()) {
                tw = tw.max(SQMenuLayout::HELP_WIDTH.min(m.width(h, MenuFont::HELP, 0).ceil()));
            }
            let own = if i.submenu.is_some() {
                MenuFont::ARROW
            } else {
                m.width(&Self::shown_shortcut(&i.shortcut), MenuFont::SHORTCUT, 0)
            };
            max_row = max_row.max(tw + if own > 0.0 { SQMenuLayout::SHORTCUT_GAP + own } else { 0.0 });
        }
        // Header rows start at the left padding (`.mcap`), left of the title column by the icon columns.
        let header_indent = -(self.icon_width + self.symbol_width);
        for i in self.items.iter().filter(|i| i.kind == SQMenuItemKind::Header) {
            max_text = max_text.max(m.width(&i.title, MenuFont::HEADER, m.semibold()) + header_indent);
        }
        max_text = max_text.max(max_row);
        // Artifact: the label list (swatch rows) is a compact 160 wide submenu, not the 200 floor of the action menus.
        self.width = (if dots { 160.0 } else { SQMenuLayout::MIN_WIDTH }).max(
            (SQMenuLayout::INSET * 2.0
                + SQMenuLayout::ROW_PAD
                + self.icon_width
                + self.symbol_width
                + max_text
                + SQMenuLayout::ROW_PAD)
                .ceil(),
        );
        if self.items.iter().any(|i| i.kind == SQMenuItemKind::Caption) {
            self.width = self
                .width
                .max((SQMenuLayout::INSET * 2.0 + SQMenuLayout::ROW_PAD * 2.0 + SQMenuLayout::CAPTION_WIDTH).ceil());
        }
        if let Some(cap) = self.max_width {
            self.width = self.width.min(cap.max(SQMenuLayout::INSET * 2.0 + SQMenuLayout::ROW_PAD * 2.0));
        }
        let mut y = SQMenuLayout::INSET;
        if self.filter.is_empty() {
            self.filter_frame = None;
        } else {
            self.filter_frame = Some(CGRect::new(
                SQMenuLayout::INSET,
                y,
                self.width - 2.0 * SQMenuLayout::INSET,
                SQMenuLayout::ROW_HEIGHT,
            ));
            y += SQMenuLayout::ROW_HEIGHT + SQMenuLayout::SEPARATOR_HEIGHT;
            let wanted = (m.width(&self.filter, MenuFont::TITLE, 0) + 40.0).ceil();
            self.width = self.width.max(self.max_width.map_or(wanted, |cap| wanted.min(cap)));
            if let Some(f) = self.filter_frame.as_mut() {
                f.width = self.width - 2.0 * SQMenuLayout::INSET;
            }
        }
        self.row_frames = Vec::new();
        for h in SQMenuLayout::heights(&self.items, &metrics) {
            self.row_frames.push(CGRect::new(SQMenuLayout::INSET, y, self.width - 2.0 * SQMenuLayout::INSET, h));
            y += h;
        }
        self.set_scroll(self.scroll_offset);
    }

    /// The title of `item` as it fits its row: whole, or cut Finder-style (start and extension stay) with the full title
    /// as the label's tooltip. `width_of` measures a text at the given font size. Layout ([`Self::title_tip`]) and drawing share it.
    fn fitted_title(&self, item: &SQMenuItem, width_of: impl Fn(&str, f64) -> f64) -> TruncatedLabel {
        let trailing = if item.submenu.is_some() {
            MenuFont::ARROW
        } else {
            width_of(&Self::shown_shortcut(&item.shortcut), MenuFont::SHORTCUT)
        };
        let room = self.width
            - 2.0 * SQMenuLayout::INSET
            - SQMenuLayout::ROW_PAD_LEFT
            - self.icon_width
            - self.symbol_width
            - SQMenuLayout::ROW_PAD_RIGHT
            - if trailing > 0.0 { SQMenuLayout::SHORTCUT_GAP + trailing } else { 0.0 };
        sq_draw::middle_fit::truncate_name(&item.title, |t| width_of(t, MenuFont::TITLE) <= room)
    }

    /// The tooltip of row `i`: its full title when the row had to cut it, else `None`.
    pub fn title_tip(&self, i: usize, m: &TextMeasure) -> Option<String> {
        let item = self.items.get(i).filter(|it| it.kind == SQMenuItemKind::Action)?;
        self.fitted_title(item, |t, size| m.width(t, size, 0)).full
    }

    /// Row under `p` (window points).
    pub fn index_at(&self, p: CGPoint) -> Option<usize> {
        let q = CGPoint::new(p.x - self.origin.x, p.y - self.origin.y + self.scroll_offset);
        if !(q.x >= 0.0
            && q.x < self.width
            && p.y - self.origin.y >= 0.0
            && p.y - self.origin.y < self.visible_size().height)
        {
            return None;
        }
        self.row_frames.iter().position(|r| r.contains(q))
    }

    // MARK: Drawing

    /// The panel shadow as the kit renders it (`Menu` in `02-Overlays/02-menus.json`: `0 14px 36px #00000099`; light
    /// `neu.html`: `0 10px 28px rgba(0,0,0,.18)`).
    pub const SHADOW_BLUR: f64 = 36.0;
    /// Shadow offset down.
    pub const SHADOW_DY: f64 = 14.0;
    /// Shadow strength on a dark theme.
    pub const SHADOW_ALPHA_DARK: f32 = 0.6;
    /// Light theme blur, offset and strength.
    pub const SHADOW_BLUR_LIGHT: f64 = 28.0;
    /// Light theme offset down.
    pub const SHADOW_DY_LIGHT: f64 = 10.0;
    /// Shadow strength on a light theme.
    pub const SHADOW_ALPHA_LIGHT: f32 = 0.18;

    /// Draws the level.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        let metrics = SQMenuTextMetrics::default();
        let vs = self.visible_size();
        let bounds = CGRect::new(0.0, 0.0, vs.width, vs.height);
        c.save_gstate();
        c.translate_by(self.origin.x, self.origin.y);
        // The panel's shadow (`SQMenuPanel.hasShadow`).
        c.shadow(
            bounds,
            f64::from(radius::MENU),
            if t.palette.is_dark() { Self::SHADOW_BLUR } else { Self::SHADOW_BLUR_LIGHT },
            if t.palette.is_dark() { Self::SHADOW_DY } else { Self::SHADOW_DY_LIGHT },
            Color::new(
                0.0,
                0.0,
                0.0,
                if t.palette.is_dark() { Self::SHADOW_ALPHA_DARK } else { Self::SHADOW_ALPHA_LIGHT },
            ),
            true,
        );
        let bg = bounds.inset_by(0.25, 0.25);
        c.fill_rounded(bg, f64::from(radius::MENU), t.token(sq_uikit::redesign_tokens::color::MENU));
        c.stroke_rounded(bounds.inset_by(0.5, 0.5), f64::from(radius::MENU) - 0.5, 1.0, t.menu_edge());

        c.save_gstate();
        c.clip_to(bounds);
        c.translate_by(0.0, -self.scroll_offset);

        if let Some(f) = self.filter_frame {
            c.draw_text_in(
                &self.filter,
                CGRect::new(f.min_x() + 8.0, f.min_y(), f.width - 8.0, f.height),
                MenuFont::TITLE,
                t.label(),
                TextAlign::Left,
                0.0,
                0,
            );
            c.fill(
                CGRect::new(
                    f.min_x() + SQMenuLayout::ROW_PAD,
                    f.max_y() + SQMenuLayout::SEPARATOR_HEIGHT / 2.0 - 0.5,
                    f.width - 2.0 * SQMenuLayout::ROW_PAD,
                    1.0,
                ),
                t.separator_strong(),
            );
        }

        for (i, item) in self.items.iter().enumerate() {
            let Some(r) = self.row_frames.get(i).copied() else { continue };
            match item.kind {
                SQMenuItemKind::Separator => {
                    c.fill(
                        CGRect::new(
                            r.min_x() + SQMenuLayout::SEP_PAD,
                            r.mid_y() - 0.5,
                            r.width - 2.0 * SQMenuLayout::SEP_PAD,
                            1.0,
                        ),
                        t.separator_strong(),
                    );
                }
                SQMenuItemKind::Header => {
                    // `.mcap`: semibold, left padding, 4 pt above the row bottom.
                    let hx = r.min_x() + SQMenuLayout::ROW_PAD;
                    let lh = (metrics.line_height)(MenuFont::HEADER);
                    let face = c.semibold();
                    c.draw_text_in(
                        &item.title,
                        CGRect::new(hx, r.max_y() - SQMenuLayout::HEADER_BOTTOM - lh, r.max_x() - hx, lh),
                        MenuFont::HEADER,
                        t.label3(),
                        TextAlign::Left,
                        0.0,
                        face,
                    );
                }
                SQMenuItemKind::Caption => {
                    let bx = CGRect::new(
                        r.min_x() + SQMenuLayout::ROW_PAD,
                        r.min_y() + SQMenuLayout::CAPTION_PAD,
                        r.width - 2.0 * SQMenuLayout::ROW_PAD,
                        r.height - 2.0 * SQMenuLayout::CAPTION_PAD,
                    );
                    c.draw_wrapped(
                        &item.title,
                        bx,
                        MenuFont::CAPTION,
                        (metrics.line_height)(MenuFont::CAPTION),
                        t.label2(),
                    );
                }
                SQMenuItemKind::Action => self.draw_row(c, item, r, self.highlighted == Some(i), t),
            }
        }
        c.restore_gstate();
        // A tall menu scrolls: a 3 pt thumb on the right edge shows there are more rows above or below.
        if self.max_scroll() > 0.0 {
            let track = bounds.height - 2.0 * SQMenuLayout::INSET;
            let h = (track * bounds.height / self.content_size().height).max(20.0);
            let y = SQMenuLayout::INSET + (track - h) * self.scroll_offset / self.max_scroll();
            c.fill_rounded(CGRect::new(bounds.max_x() - 5.0, y, 3.0, h), f64::from(radius::SMALL), t.label4());
        }
        // An arrow on each edge that cuts rows off, so a short window never looks like a menu that just ends.
        let (above, below) = self.scroll_hints();
        let menu = t.token(sq_uikit::redesign_tokens::color::MENU);
        let hint = Self::SCROLL_HINT_HEIGHT;
        let side = f64::from(radius::MENU) * 0.5;
        for (show, y, icon) in
            [(above, 1.0, SQIcon::ChevronUp), (below, bounds.height - hint - 1.0, SQIcon::ChevronDown)]
        {
            if !show {
                continue;
            }
            c.fill(CGRect::new(side, y, bounds.width - 2.0 * side, hint), menu.with_alpha(0.96));
            let size = 12.0;
            c.draw_icon(
                icon,
                CGPoint::new(bounds.mid_x() - size / 2.0, y + (hint - size) / 2.0),
                size,
                t.label2(),
                None,
            );
        }
        c.restore_gstate();
    }

    fn draw_row(&self, c: &mut Canvas, item: &SQMenuItem, r: CGRect, active: bool, t: &DrawTheme) {
        let metrics = SQMenuTextMetrics::default();
        // A disabled row never lights up: hovering it promises nothing.
        if active && item.is_enabled {
            c.fill_rounded(r, f64::from(radius::SMALL), t.menu_row_hover());
        }
        let text = if !item.is_enabled {
            t.label4()
        } else if item.is_destructive {
            t.menu_destructive()
        } else {
            t.label()
        };
        let sub = if !item.is_enabled { t.label4() } else { t.label2_on_raised() };

        let check_box =
            CGRect::new(r.min_x() + SQMenuLayout::ROW_PAD_LEFT, r.min_y(), SQMenuLayout::CHECK_COLUMN, r.height);
        if item.is_checked {
            Self::draw_check(c, if item.is_enabled { t.label() } else { t.label4() }, check_box);
        }
        let mut tx = r.min_x() + SQMenuLayout::ROW_PAD_LEFT + self.icon_width;
        if self.icon_width > SQMenuLayout::CHECK_COLUMN + SQMenuLayout::GAP {
            let chip = CGRect::new(
                check_box.max_x() + SQMenuLayout::GAP,
                r.mid_y() - SQMenuLayout::SWATCH_SIZE / 2.0,
                SQMenuLayout::SWATCH_SIZE,
                SQMenuLayout::SWATCH_SIZE,
            );
            if let SQMenuIcon::Swatch(rgb) = &item.icon {
                c.fill_rounded(
                    chip,
                    SQMenuLayout::SWATCH_RADIUS,
                    Color::hex(*rgb, if item.is_enabled { 1.0 } else { 0.4 }),
                );
            }
            c.stroke_rounded(chip.inset_by(0.25, 0.25), SQMenuLayout::SWATCH_RADIUS, 0.5, t.swatch_edge());
        }
        if let Some(sym) = item.leading_symbol {
            let tint = match item.leading_tint {
                Some(tint) => {
                    if item.is_enabled {
                        Self::color(tint)
                    } else {
                        t.label3()
                    }
                }
                None => text,
            };
            let size = 12.5;
            c.draw_icon(
                sym,
                CGPoint::new(tx + 1.0, r.min_y() + (r.height.min(SQMenuLayout::ROW_HEIGHT) - size) / 2.0),
                size,
                tint,
                None,
            );
            tx += self.symbol_width;
        }
        let has_help = item.help.as_deref().is_some_and(|h| !h.is_empty());
        let title_box = if has_help {
            CGRect::new(tx, r.min_y() - 1.0, r.max_x() - tx, SQMenuLayout::ROW_HEIGHT)
        } else {
            CGRect::new(tx, r.min_y(), r.max_x() - tx, r.height)
        };
        let title = self.fitted_title(item, |t, size| c.size_of(t, size, 0).width);
        c.draw_text_in(&title.shown, title_box, MenuFont::TITLE, text, TextAlign::Left, 0.0, 0);
        if item.is_experimental && sq_draw::experimental::prefs().shows_mark() {
            // The trailing mark: the flask right after the title (no width of its own to reserve).
            let w = c.size_of(&title.shown, MenuFont::TITLE, 0).width.ceil();
            let o = CGPoint::new(tx + w + 6.0, r.min_y() + (r.height.min(SQMenuLayout::ROW_HEIGHT) - 11.0) / 2.0);
            c.experimental_badge(o, sq_draw::experimental::ExperimentalMark::Icon, t);
        }
        if let Some(help) = item.help.as_deref().filter(|_| has_help) {
            let bx = CGRect::new(
                tx,
                r.min_y() + SQMenuLayout::ROW_HEIGHT - 2.0,
                SQMenuLayout::HELP_WIDTH + 2.0,
                SQMenuLayout::help_lines(item, &metrics) as f64 * SQMenuLayout::HELP_HEIGHT,
            );
            c.draw_wrapped(help, bx, MenuFont::HELP, SQMenuLayout::HELP_HEIGHT, sub);
        }

        if item.submenu.is_some() {
            // `MenuItem` Arrow: 9 pt, t3, 10 pt from the right edge.
            let size = MenuFont::ARROW;
            c.draw_icon(
                SQIcon::ChevronRight,
                CGPoint::new(r.max_x() - SQMenuLayout::ROW_PAD_RIGHT - size, r.mid_y() - size / 2.0 + 1.0),
                size,
                // The kit's chevron is dim and thin.
                if item.is_enabled { t.label3().with_alpha(t.label3().a * 0.75) } else { t.label4() },
                None,
            );
        } else if !item.shortcut.is_empty() {
            // One shortcut style: every key, punctuation included, is a plain glyph (no key cap) in the right column.
            c.draw_text_in(
                &Self::shown_shortcut(&item.shortcut),
                CGRect::new(
                    r.min_x(),
                    r.min_y(),
                    r.width - SQMenuLayout::ROW_PAD_RIGHT,
                    r.height.min(SQMenuLayout::ROW_HEIGHT),
                ),
                MenuFont::SHORTCUT,
                sub,
                TextAlign::Right,
                0.0,
                0,
            );
        }
    }

    /// The artifact's check: a 1.25 pt stroke, about 10 pt wide, in the 12 pt box.
    pub(crate) fn draw_check(c: &mut Canvas, color: Color, bx: CGRect) {
        c.stroke_polyline(
            &[
                CGPoint::new(bx.min_x() + 1.0, bx.mid_y() + 0.5),
                CGPoint::new(bx.min_x() + 4.5, bx.mid_y() + 3.5),
                CGPoint::new(bx.min_x() + 11.0, bx.mid_y() - 3.5),
            ],
            1.25,
            color,
        );
    }

    /// Dialog and card edge (`Theme.ink(0.14)`); the menus use `DrawTheme::menu_edge`.
    pub(crate) fn overlay_edge(t: &DrawTheme) -> Color {
        let i = t.palette.ink;
        Color::new((i.r / 255.0) as f32, (i.g / 255.0) as f32, (i.b / 255.0) as f32, 0.14)
    }

    fn color(tint: SQMenuTint) -> Color {
        let c: PaletteColor = tint;
        Color::new((c.r / 255.0) as f32, (c.g / 255.0) as f32, (c.b / 255.0) as f32, c.a as f32)
    }
}

#[cfg(test)]
mod shadow_tests {
    use super::*;

    #[test]
    fn the_menu_shadow_is_the_kit_render_in_both_themes() {
        assert_eq!(
            (MenuListView::SHADOW_BLUR, MenuListView::SHADOW_DY, MenuListView::SHADOW_ALPHA_DARK),
            (36.0, 14.0, 0.6)
        );
        assert_eq!(
            (MenuListView::SHADOW_BLUR_LIGHT, MenuListView::SHADOW_DY_LIGHT, MenuListView::SHADOW_ALPHA_LIGHT),
            (28.0, 10.0, 0.18)
        );
    }
}

#[cfg(test)]
mod shortcut_wording_tests {
    use super::*;
    use sq_os::Platform;

    #[test]
    fn a_mac_shortcut_reads_ctrl_off_the_mac() {
        assert_eq!(MenuListView::shown_shortcut_for("\u{2318}C", Platform::Mac), "\u{2318}C");
        assert_eq!(MenuListView::shown_shortcut_for("\u{2318}V", Platform::Windows), "Ctrl+V");
        assert_eq!(MenuListView::shown_shortcut_for("\u{2318}X", Platform::Linux), "Ctrl+X");
    }
}
