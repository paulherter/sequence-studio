// Swift: ShellStart+Draw.swift
//! Drawing of the start screen: the Mac `StartWindowView` parts (StartButton, RailRow, ProjectCard, PosterWell, Badge,
//! QuickSizeTile, TemplateCard, LearnCard) on the canvas with the start tokens.

use crate::project_list_view::ProjectPoster;
use crate::shell_mascot_stage::ShellMascotStage;
use crate::shell_platform_text::ShellPlatformText;
use crate::shell_start::{Element, LESSONS, ShellStartScreen, StartEnv, StartHit, StartTab, Tone, m};
use sq_core_project::project_template::ProjectTemplate;
use sq_core_project::support_policy::{SupportEntry, SupportLinks};
use sq_draw::experimental::ExperimentalMark;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::radius as theme_radius;
use sq_draw::{Canvas, Color, DrawTheme, TextAlign, UiCx};
use sq_editor_session::{RecentEntry, StartLabels, StartProjectInfo};
use sq_os::Platform;
use sq_uikit::app_version::AppVersion;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::redesign_tokens::color as tk;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmascot_model::SQMascotAnim;

/// The start screen's color names (`StartWindow.SC`) on the draw theme.
struct Colors {
    seam: Color,
    chrome: Color,
    panel: Color,
    group: Color,
    lane: Color,
    raised: Color,
    line: Color,
    line2: Color,
    row_line: Color,
    warning: Color,
    support: Color,
    badge: Color,
    badge_text: Color,
    red: Color,
}

impl Colors {
    fn new(t: &DrawTheme) -> Colors {
        let w = t.palette.warning;
        Colors {
            seam: t.token(tk::SEAM),
            chrome: t.token(tk::CHROME),
            panel: t.token(tk::PANEL),
            group: t.token(tk::GROUP),
            lane: t.token(tk::LANE),
            raised: t.token(tk::RAISED),
            line: t.token(tk::LINE),
            line2: t.token(tk::LINE2),
            row_line: t.token(tk::ROW_LINE),
            warning: Color::new((w.r / 255.0) as f32, (w.g / 255.0) as f32, (w.b / 255.0) as f32, 1.0),
            support: t.token(tk::SUPPORT),
            badge: Color::BLACK.with_alpha(0.62),
            badge_text: Color::WHITE,
            red: t.token(tk::RED_TEXT),
        }
    }

    fn tone(&self, t: &DrawTheme, tone: Tone) -> Color {
        match tone {
            Tone::Text => t.label(),
            Tone::Text2 => t.label2(),
            Tone::Text3 => t.label3(),
            Tone::Text4 => t.label4(),
        }
    }
}

/// The Command-key hint for `key` ("Ctrl+N" / "⌘N").
fn command_key(key: char) -> String {
    KeyBindingText::text(&KeyBinding::new(Key::Char(key), KeyModifiers::COMMAND), Platform::current())
}

/// The New project button's hint: File > New Project is Ctrl+Alt+N (Cmd+Option+N); Ctrl+N is New Sequence.
// The default key, not the user's remapped one: Swift draws a fixed Cmd+N here (`ShellPlatformText.commandKey("n")`).
pub(crate) fn new_project_hint() -> String {
    KeyBindingText::text(
        &KeyBinding::new(Key::Char('n'), KeyModifiers::COMMAND | KeyModifiers::OPTION),
        Platform::current(),
    )
}

/// A `StartButton`.
#[derive(Clone, Copy)]
struct Btn<'a> {
    title: &'a str,
    icon: Option<SQIcon>,
    hint: Option<&'a str>,
    primary: bool,
    hover: bool,
    /// The icon's own color (a brand mark); `None` is the neutral tint.
    tint: Option<Color>,
}

impl<'a> Btn<'a> {
    fn new(title: &'a str, primary: bool, hover: bool) -> Btn<'a> {
        Btn { title, icon: None, hint: None, primary, hover, tint: None }
    }
    fn tint(mut self, tint: Color) -> Btn<'a> {
        self.tint = Some(tint);
        self
    }
    fn icon(mut self, icon: SQIcon) -> Btn<'a> {
        self.icon = Some(icon);
        self
    }
    fn hint(mut self, hint: &'a str) -> Btn<'a> {
        self.hint = Some(hint);
        self
    }
}

/// What a `PosterWell` shows.
#[derive(Clone, Copy)]
struct Poster<'a> {
    info: Option<&'a StartProjectInfo>,
    path: Option<&'a str>,
    gone: bool,
    /// The decoded frame, when there is one.
    poster: Option<ProjectPoster>,
    /// Space between the well and the picture.
    inset: f64,
}

/// One line of text centered vertically in `r`.
fn text(c: &mut Canvas, s: &str, r: CGRect, size: f64, color: Color, align: TextAlign, face: usize) -> f64 {
    c.draw_text_in(s, r, size, color, align, 0.0, face)
}

impl ShellStartScreen {
    /// Draws the screen. `ui` is the text field's context; Pip is drawn when `draws_mascots` (hosts without real mascot views).
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, env: &StartEnv, ui: &mut UiCx, draws_mascots: bool) {
        let k = Colors::new(t);
        // The design: seam grey window, the top bar, rail and status bar in chrome, the pane one panel on 2 pt seams.
        c.fill(self.frame, k.seam);
        self.draw_top_bar(c, t, &k, env, ui);
        c.fill(self.rail_rect(), k.chrome);
        self.draw_rail(c, t, &k, env);
        self.draw_pane(c, t, &k, env);
        if draws_mascots {
            self.draw_mascots(c, env);
        }
        self.draw_status(c, t, &k, env);
    }

    /// Pip: above the empty pane's title, or peeking over the support card (clipped at the card's top edge plus the tuck, as
    /// the Mac clip view).
    fn draw_mascots(&mut self, c: &mut Canvas, env: &StartEnv) {
        if let Some(base) = self.empty_mascot_base(env) {
            let side = 120.0; // SQMascotPlace.startEmpty (AppKit-only, so not usable here)
            let r = CGRect::new(base.x - side / 2.0, base.y - side, side, side);
            ShellMascotStage::draw(&mut self.mascots, SQMascotAnim::Wink, 0, env.steady, r, c);
        } else if let Some(card) = self.mascot_card(env) {
            let side = 52.0; // SQMascotPlace.startProjects
            let top = card.min_y() - side; // peekTuck is 0
            c.save_gstate();
            c.clip_to(CGRect::new(card.min_x(), top, card.width, card.min_y() - top));
            self.mascots.draw(
                SQMascotAnim::Peek,
                1,
                env.steady,
                CGRect::new(card.max_x() - 16.0 - side, top, side, side),
                c,
            );
            c.restore_gstate();
        }
    }

    fn draw_top_bar(&mut self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv, ui: &mut UiCx) {
        if self.bar_frame.is_none() {
            let top = self.top_bar();
            c.fill(top, k.chrome);
            // The own Mac start window shows the window buttons only (art.html "Start"); the title is for hosts without them.
            if self.title_inset != m::LIGHTS {
                let face = c.semibold();
                text(
                    c,
                    "Sequence Studio",
                    CGRect::new(top.min_x() + self.title_inset, top.min_y(), 200.0, top.height),
                    m::F_HEAD,
                    t.label(),
                    TextAlign::Left,
                    face,
                );
            }
        }
        let f = self.search_rect();
        if f.width <= 0.0 {
            return;
        }
        let editing = self.search.is_editing();
        let touch = Touch { hovering: self.hover == Some(StartHit::Search), ..Touch::default() };
        c.stone_field(f, m::R_CTL, editing, touch, t);
        c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 9.0, f.mid_y() - 6.5), 13.0, t.label4(), None);
        let text_rect = CGRect::new(f.min_x() + 29.0, f.min_y(), f.width - 29.0 - 26.0, f.height);
        self.search.draw(c, text_rect, t, editing, ui);
        let query = self.query();
        if query.is_empty() && !editing {
            text(c, "Search projects", text_rect, m::F_LAB, t.label4(), TextAlign::Left, 0);
            text(c, &command_key('f'), f.inset_by(9.0, 0.0), m::F_CAP, t.label4(), TextAlign::Right, 0);
        } else if !query.is_empty() {
            c.draw_icon(
                SQIcon::CloseCircleFilled,
                CGPoint::new(self.search_clear_rect().x, self.search_clear_rect().y),
                16.0,
                t.label3(),
                None,
            );
        }
        let _ = env;
    }

    fn draw_status(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv) {
        let r = self.status_bar();
        c.fill(r, k.chrome);
        let n = env.recents.len();
        let folder = format!("Projects folder: {}", ShellPlatformText::abbreviating_home(env.projects_root));
        let count = if n == 1 { "1 project".to_string() } else { format!("{n} projects") };
        let inner = r.inset_by(16.0, 0.0);
        let open = if env.open_name.is_empty() { "No project open" } else { env.open_name };
        let version = format!("Sequence Studio {}", AppVersion::display());
        let width = |s: &str| env.measure.width(s, m::F_CAP, 0).ceil();
        let (folder_w, show_open) =
            Self::status_widths(inner.width, [width(&folder), width(&count), width(open), width(&version)]);
        let w = text(
            c,
            &folder,
            CGRect::new(inner.min_x(), inner.min_y(), folder_w, inner.height),
            m::F_CAP,
            t.label3(),
            TextAlign::Left,
            0,
        );
        text(
            c,
            &count,
            CGRect::new(inner.min_x() + w + 16.0, inner.min_y(), 200.0, inner.height),
            m::F_CAP,
            t.label3(),
            TextAlign::Left,
            0,
        );
        let vw = text(c, &version, inner, m::F_CAP, t.label3(), TextAlign::Right, 0);
        if show_open {
            text(
                c,
                open,
                CGRect::new(inner.min_x(), inner.min_y(), inner.width - vw - 16.0, inner.height),
                m::F_CAP,
                t.label3(),
                TextAlign::Right,
                0,
            );
        }
    }

    /// The status bar in `avail` pt: how wide the folder text may be, and whether the open project's name shows. Widths are
    /// [folder, count, open name, version]. The version always stays; the open name goes first and the folder is cut
    /// (ending at a word) before the count would run into the version.
    pub(crate) fn status_widths(avail: f64, [folder, count, open, version]: [f64; 4]) -> (f64, bool) {
        let gap = 16.0;
        let all = folder + gap + count + gap + open + gap + version;
        if all <= avail {
            return (folder, true);
        }
        let room = (avail - count - gap - version - gap).max(0.0);
        (folder.min(room), false)
    }

    // MARK: Rail

    fn draw_rail(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv) {
        let spots = self.rail_spots();
        let rail = self.rail_rect();
        for (r, h) in &spots {
            let hovered = self.hover.as_ref() == Some(h);
            match h {
                StartHit::NewProject => {
                    let hint = new_project_hint();
                    Self::button(c, t, k, &Btn::new("New project", true, hovered).icon(SQIcon::Plus).hint(&hint), *r)
                }
                StartHit::OpenOther => {
                    let hint = command_key('o');
                    Self::button(c, t, k, &Btn::new("Open…", false, hovered).icon(SQIcon::Folder).hint(&hint), *r)
                }
                StartHit::Tab(tb) => {
                    if *tb == StartTab::Home {
                        let face = c.semibold();
                        text(
                            c,
                            "Browse",
                            CGRect::new(rail.min_x() + 26.0, rail.min_y() + 92.0, 120.0, 14.0),
                            m::F_CAP,
                            t.label3(),
                            TextAlign::Left,
                            face,
                        );
                    }
                    // The design's nav row: raised fill when open, 14 pt icon, 12 pt medium title, count or news dot at the right.
                    let on = self.tab() == *tb || (*tb == StartTab::Home && false);
                    let ink = if on { t.label() } else { t.label2() };
                    if on {
                        c.fill_rounded(*r, m::R_CTL, k.raised);
                    } else if hovered {
                        c.fill_rounded(*r, m::R_CTL, t.hover());
                    }
                    c.draw_icon(tb.icon(), CGPoint::new(r.min_x() + 10.0, r.mid_y() - 7.0), 14.0, ink, None);
                    let face = c.medium();
                    text(
                        c,
                        tb.raw(),
                        CGRect::new(r.min_x() + 32.0, r.min_y(), r.width - 60.0, r.height),
                        m::F_LAB,
                        ink,
                        TextAlign::Left,
                        face,
                    );
                    if *tb == StartTab::Recent && !env.recents.is_empty() {
                        text(
                            c,
                            &env.recents.len().to_string(),
                            r.inset_by(10.0, 0.0),
                            m::F_CAP,
                            t.label3(),
                            TextAlign::Right,
                            0,
                        );
                    }
                    if *tb == StartTab::WhatsNew && self.whats_new_unseen() {
                        c.fill_rounded(CGRect::new(r.max_x() - 16.0, r.mid_y() - 3.0, 6.0, 6.0), 3.0, t.accent());
                    }
                }
                StartHit::ReopenLast => {
                    let b = CGRect::new(r.min_x() + 2.0, r.mid_y() - 7.0, 14.0, 14.0);
                    c.stone_checkbox(b, self.reopen_last(), Touch { hovering: hovered, ..Touch::default() }, t);
                    text(
                        c,
                        "Open last project on launch",
                        CGRect::new(b.max_x() + 8.0, r.min_y() - 1.0, r.width - 22.0, r.height),
                        m::F_LAB,
                        t.label2(),
                        TextAlign::Left,
                        0,
                    );
                }
                StartHit::Support(SupportEntry::Support) if r.width > 30.0 => {} // the card's button, drawn below
                StartHit::Appearance | StartHit::Feedback | StartHit::Support(_) => {
                    if hovered {
                        c.fill_rounded(*r, m::R_CTL, t.hover());
                    }
                    let icon = footer_icon(h);
                    let tint = if *h == StartHit::Support(SupportEntry::Support) { k.support } else { t.label3() };
                    c.draw_icon(icon, CGPoint::new(r.mid_x() - 7.0, r.mid_y() - 7.0), 14.0, tint, None);
                }
                _ => {}
            }
        }
        // Support card (not in a window too small for it).
        if !self.support_card_visible() {
            return;
        }
        let s = self.support_card_rect();
        c.fill_rounded(s, 6.0, k.group);
        c.stroke_rounded(s.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
        let face = c.semibold();
        text(
            c,
            SupportEntry::Support.menu_title(),
            CGRect::new(s.min_x() + 14.0, s.min_y() + 14.0, s.width - 26.0, 16.0),
            m::F_LAB,
            t.label(),
            TextAlign::Left,
            face,
        );
        let _ = c.draw_wrapped(
            SupportLinks::TAGLINE,
            CGRect::new(s.min_x() + 14.0, s.min_y() + 34.0, s.width - 26.0, 60.0),
            m::F_CAP,
            16.0,
            t.label2(),
        );
        let support = StartHit::Support(SupportEntry::Support);
        if let Some((r, _)) = spots.iter().find(|(r, h)| *h == support && r.height < m::CONTROL) {
            Self::flat_button(
                c,
                t,
                k,
                "Support…",
                Some((SQIcon::Heart, k.support)),
                self.hover.as_ref() == Some(&support),
                *r,
            );
        }
    }

    /// The quiet button of the design (`btn2`): flat raised, a hair edge, 22 high.
    fn flat_button(
        c: &mut Canvas,
        t: &DrawTheme,
        k: &Colors,
        title: &str,
        icon: Option<(SQIcon, Color)>,
        hover: bool,
        r: CGRect,
    ) {
        c.fill_rounded(r, m::R_CTL, if hover { t.raised_hover() } else { k.raised });
        c.stroke_rounded(r.inset_by(0.5, 0.5), m::R_CTL, 1.0, k.line2);
        let mut x = r.min_x() + 9.0;
        if let Some((i, col)) = icon {
            c.draw_icon(i, CGPoint::new(x, r.mid_y() - 6.0), 12.0, col, None);
            x += 18.0;
        }
        let face = c.medium();
        text(c, title, CGRect::new(x, r.min_y(), r.max_x() - x, r.height), m::F_LAB, t.label(), TextAlign::Left, face);
    }

    /// A stone button (`Button/Primary`, `Button/Raised`): icon, title, key hint at the right.
    fn button(c: &mut Canvas, t: &DrawTheme, k: &Colors, b: &Btn, r: CGRect) {
        let Btn { title, icon, hint, primary, hover, tint } = *b;
        if !primary && r.height <= 22.0 {
            return Self::flat_button(c, t, k, title, None, hover, r);
        }
        let kind = if primary { ButtonKind::Accent } else { ButtonKind::Raised };
        let r = c.stone_button(r, kind, Touch { hovering: hover, ..Touch::default() }, t);
        let ink = if primary { Color::WHITE } else { t.label() };
        let face = c.medium();
        let mut x = r.min_x() + 10.0;
        if let Some(icon) = icon {
            c.draw_icon(
                icon,
                CGPoint::new(x, r.mid_y() - 7.0),
                14.0,
                if primary { Color::WHITE.with_alpha(0.72) } else { tint.unwrap_or(t.label3()) },
                None,
            );
            x += 22.0;
        }
        if icon.is_none() && hint.is_none() {
            text(c, title, r, m::F_LAB, ink, TextAlign::Center, face);
        } else {
            text(c, title, CGRect::new(x, r.min_y(), r.max_x() - x, r.height), m::F_LAB, ink, TextAlign::Left, face);
        }
        if let Some(hint) = hint {
            text(
                c,
                hint,
                r.inset_by(10.0, 0.0),
                m::F_CAP,
                if primary { Color::WHITE.with_alpha(0.72) } else { t.label3() },
                TextAlign::Right,
                0,
            );
        }
    }

    // MARK: Pane

    /// The grey line after the pane title.
    pub(crate) fn pane_subtitle(&self, env: &StartEnv) -> String {
        match self.tab() {
            StartTab::Recent if !env.recents.is_empty() => {
                let n = self.shown(env).len();
                if n == 1 { "1 project".to_string() } else { format!("{n} projects") }
            }
            StartTab::Templates => "Click one, name the video, press Return.".to_string(),
            StartTab::Learn => "Short tips that save time".to_string(),
            StartTab::WhatsNew => {
                let date = self.whats_new.date_text();
                let version = AppVersion::display();
                if date.is_empty() {
                    format!("Sequence Studio {version}")
                } else {
                    format!("Sequence Studio {version} \u{b7} {date}")
                }
            }
            _ => String::new(),
        }
    }

    fn draw_pane(&mut self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv) {
        c.fill(self.pane_rect(), k.panel);
        let h = self.pane_header();
        let title_rect = CGRect::new(h.min_x() + m::S6, h.min_y() + 19.0, h.width - 2.0 * m::S6, 20.0);
        let semibold = c.semibold();
        let title_width = text(c, self.tab().raw(), title_rect, 15.0, t.label(), TextAlign::Left, semibold);
        let sub = self.pane_subtitle(env);
        if !sub.is_empty() {
            // The kit draws the grey line 3 pt higher than a baseline join of the two sizes (measured on the kit render).
            let r = CGRect::new(title_rect.min_x() + title_width + 8.0, title_rect.min_y() - 1.0, 500.0, 20.0);
            text(c, &sub, r, m::F_LAB, t.label3(), TextAlign::Left, 0);
        }
        if self.tab() == StartTab::Recent && !env.recents.is_empty() {
            let s = self.sort_rect(env);
            let hov = self.hover == Some(StartHit::Sort);
            let body = c.stone_button(s, ButtonKind::Raised, Touch { hovering: hov, ..Touch::default() }, t);
            let sw = text(
                c,
                "Sort",
                CGRect::new(body.min_x() + 9.0, body.min_y(), 60.0, body.height),
                m::F_LAB,
                t.label3(),
                TextAlign::Left,
                0,
            );
            let face = c.medium();
            text(
                c,
                self.sort().raw(),
                CGRect::new(body.min_x() + 9.0 + sw + 6.0, body.min_y(), 140.0, body.height),
                m::F_LAB,
                t.label(),
                TextAlign::Left,
                face,
            );
            c.draw_icon(
                SQIcon::ChevronDown,
                CGPoint::new(body.max_x() - 18.0, body.mid_y() - 4.5),
                9.0,
                t.label3(),
                None,
            );
            // The two layout segments: a sunken track, the chosen one raised.
            let seg = self.layout_toggle_rect(env);
            c.stone_segment_track(seg, Touch::default(), t);
            for list in [false, true] {
                let r = self.layout_segment(env, list);
                let on = self.list_layout() == list;
                let over = self.hover == Some(StartHit::Layout(list));
                c.stone_segment(r, on, Touch { hovering: over, ..Touch::default() }, t);
                c.draw_icon(
                    if list { SQIcon::List } else { SQIcon::Grid },
                    CGPoint::new(r.mid_x() - 7.0, r.mid_y() - 7.0),
                    14.0,
                    if on { t.label() } else { t.label3() },
                    None,
                );
            }
        }
        let content = self.content_rect();
        if let Some((title, body, buttons)) = self.empty_state(env) {
            let my = content.mid_y();
            let semibold = c.semibold();
            // The text wraps at word boundaries; more than two lines lift the block so it never reaches the buttons.
            let (lines, lift) = self.empty_state_body(env, &body);
            text(
                c,
                &title,
                CGRect::new(content.min_x(), my - 40.0 - lift, content.width, 20.0),
                15.0,
                t.label(),
                TextAlign::Center,
                semibold,
            );
            for (i, line) in lines.iter().enumerate() {
                text(
                    c,
                    line,
                    CGRect::new(
                        content.min_x() + m::S6,
                        my - 12.0 - lift + 16.0 * i as f64,
                        content.width - 2.0 * m::S6,
                        16.0,
                    ),
                    m::F_LAB,
                    t.label3(),
                    TextAlign::Center,
                    0,
                );
            }
            for b in &buttons {
                self.draw_element(c, t, k, env, b);
            }
            return;
        }
        c.save_gstate();
        c.clip_to(content);
        for e in self.scrolled_elements(env) {
            self.draw_element(c, t, k, env, &e);
        }
        c.restore_gstate();
        let total = self.pane_layout(env).1;
        self.scroll_body.draw_scroller(c, content, total, t, env.steady);
    }

    /// The empty pane's body text wrapped to the pane (16 pt lines) and how far title and text move up so that a third
    /// line does not reach the buttons 24 pt below the middle.
    pub(crate) fn empty_state_body(&self, env: &StartEnv, body: &str) -> (Vec<String>, f64) {
        let lines = env.measure.lines(body, self.content_rect().width - 2.0 * m::S6, m::F_LAB);
        let lift = lines.len().saturating_sub(2) as f64 * 16.0;
        (lines, lift)
    }

    fn draw_element(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv, e: &Element) {
        match e {
            Element::Heading(s, r) => {
                let face = c.semibold();
                text(c, s, *r, m::F_LAB, t.label2(), TextAlign::Left, face);
            }
            Element::Txt(s, r, size, tone, bold) | Element::TxtC(s, r, size, tone, bold) => {
                let face = if *bold { c.semibold() } else { 0 };
                let align = if matches!(e, Element::TxtC(..)) { TextAlign::Center } else { TextAlign::Left };
                text(c, s, *r, *size, k.tone(t, *tone), align, face);
            }
            Element::Wrapped(s, r, size, tone) => {
                let _ = c.draw_wrapped(s, *r, *size, 16.0, k.tone(t, *tone));
            }
            Element::WrappedC(s, r, size, tone) => {
                let color = k.tone(t, *tone);
                for (i, line) in c.wrap(s, r.width, *size).iter().enumerate() {
                    let row = CGRect::new(r.min_x(), r.min_y() + i as f64 * 16.0, r.width, 16.0);
                    text(c, line, row, *size, color, TextAlign::Center, 0);
                }
            }
            Element::Lane(r) => c.fill_rounded(*r, m::R_CTL, k.lane),
            Element::Glyph(icon, r, size, tone) => c.draw_icon(
                *icon,
                CGPoint::new(r.mid_x() - size / 2.0, r.mid_y() - size / 2.0),
                *size,
                k.tone(t, *tone),
                None,
            ),
            Element::IconSq(icon, r, size) => {
                c.fill_rounded(*r, 6.0, k.raised);
                c.stroke_rounded(r.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
                c.draw_icon(
                    *icon,
                    CGPoint::new(r.mid_x() - size / 2.0, r.mid_y() - size / 2.0),
                    *size,
                    t.label2(),
                    None,
                );
            }
            Element::Rule(r) => c.fill(CGRect::new(r.min_x(), r.max_y() - 1.0, r.width, 1.0), k.row_line),
            Element::Dot(r) => c.fill_rounded(*r, r.width / 2.0, t.label4()),
            Element::Tag(s, r, exp) => {
                if *exp {
                    // The shared flask pill (`sq_draw::experimental`).
                    c.experimental_badge(CGPoint::new(r.min_x(), r.min_y()), ExperimentalMark::Pill, t);
                } else {
                    let w = c.size_of(s, 10.0, 0).width + 10.0;
                    let rr = CGRect::new(r.min_x(), r.min_y(), w, r.height);
                    c.fill_rounded(rr, 3.0, k.raised);
                    let face = c.semibold();
                    text(c, s, rr, 10.0, t.label2(), TextAlign::Center, face);
                }
            }
            Element::Tile(r) => {
                c.fill_rounded(*r, 6.0, k.group);
                c.stroke_rounded(r.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
            }
            Element::Card(entry, r) => self.draw_card(c, t, k, env, entry, *r),
            Element::ListHeader(r) => {
                let col = Self::list_columns(*r);
                let head = |c: &mut Canvas, s: &str, x: f64, w: f64| {
                    let face = c.semibold();
                    text(c, s, CGRect::new(x, r.min_y(), w, r.height), m::F_CAP, t.label3(), TextAlign::Left, face);
                };
                head(c, "Name", col.name.min_x(), col.name.width);
                for (title, x, w) in [
                    ("Frame size", col.size, 110.0),
                    ("Aspect", col.aspect, 64.0),
                    ("Frame rate", col.rate, 92.0),
                    ("Length", col.length, 64.0),
                    ("Edited", col.edited, 96.0),
                ] {
                    if let Some(x) = x {
                        head(c, title, x, w);
                    }
                }
            }
            Element::ListRow(entry, r) => self.draw_list_row(c, t, k, env, entry, *r),
            Element::ContinueBox(entry, r) => {
                let parts = Self::continue_parts(*r);
                let pic = parts.poster;
                self.poster_well(
                    c,
                    t,
                    k,
                    &Poster {
                        info: self.infos.get(&entry.path),
                        path: Some(&entry.path),
                        gone: false,
                        poster: self.card_poster(env, &entry.path),
                        inset: 0.0,
                    },
                    pic,
                );
                let x = parts.facts_x;
                let face = c.semibold();
                text(
                    c,
                    &entry.name,
                    CGRect::new(x, parts.title_y, r.max_x() - x, 20.0),
                    15.0,
                    t.label(),
                    TextAlign::Left,
                    face,
                );
                let info = self.infos.get(&entry.path);
                let dash = || "–".to_string();
                let rows = [
                    ("Frame", info.map_or_else(dash, |i| format!("{} · {}", i.size(), i.aspect()))),
                    ("Rate", info.map_or_else(dash, StartProjectInfo::rate)),
                    ("Length", info.map_or_else(dash, StartProjectInfo::length)),
                    ("Edited", StartLabels::relative(entry.opened, env.now, env.calendar)),
                ];
                for (i, kv) in rows.iter().enumerate() {
                    let row = CGRect::new(x, parts.title_y + 24.0 + i as f64 * 26.0, parts.facts_w, 26.0);
                    text(
                        c,
                        kv.0,
                        CGRect::new(row.min_x(), row.min_y(), 72.0, 26.0),
                        m::F_CAP,
                        t.label3(),
                        TextAlign::Left,
                        0,
                    );
                    text(
                        c,
                        &kv.1,
                        CGRect::new(row.min_x() + 72.0, row.min_y(), row.width - 72.0, 26.0),
                        m::F_LAB,
                        t.label(),
                        TextAlign::Left,
                        0,
                    );
                    c.fill(CGRect::new(row.min_x(), row.max_y() - 1.0, row.width, 1.0), k.row_line);
                }
                let open = Btn::new("Open", false, self.hover == Some(StartHit::ContinueOpen)).hint("⏎");
                Self::button(c, t, k, &open, Self::open_rect(*r));
            }
            Element::Quick(tmpl, r) => self.draw_quick(c, t, k, tmpl.as_ref(), *r),
            Element::TemplateCard(tmpl, r) => {
                let hovered = self.hover == Some(StartHit::Template(tmpl.id.clone()));
                c.fill_rounded(*r, 6.0, k.group);
                c.stroke_rounded(r.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
                let media = CGRect::new(r.min_x(), r.min_y(), r.width, 108.0);
                c.fill_rounded(CGRect::new(media.min_x(), media.min_y(), media.width, 114.0), 6.0, k.lane);
                c.fill(CGRect::new(media.min_x(), media.max_y(), media.width, 8.0), k.group);
                c.stroke_rounded(r.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
                let f = &tmpl.format;
                let shapes: Vec<(f64, f64)> = if tmpl.variants.is_empty() {
                    vec![(f.width as f64, f.height as f64)]
                } else {
                    vec![(9.0, 16.0), (16.0, 9.0), (1.0, 1.0)]
                };
                let n = shapes.len();
                for (j, (w, h)) in shapes.iter().enumerate() {
                    let q = (if n > 1 { 36.0 } else { 44.0 }) / w.max(*h);
                    let (sw, sh) = (w * q, h * q);
                    let cx = media.mid_x() + (j as f64 - (n as f64 - 1.0) / 2.0) * 30.0;
                    c.stroke_rounded(
                        CGRect::new(cx - sw / 2.0, media.mid_y() - sh / 2.0, sw, sh),
                        3.0,
                        1.5,
                        t.label3(),
                    );
                }
                let face = c.semibold();
                text(
                    c,
                    &tmpl.name,
                    CGRect::new(r.min_x() + 14.0, r.min_y() + 120.0, r.width - 28.0, 16.0),
                    m::F_LAB,
                    t.label(),
                    TextAlign::Left,
                    face,
                );
                let _ = c.draw_wrapped(
                    &tmpl.summary,
                    CGRect::new(r.min_x() + 14.0, r.min_y() + 140.0, r.width - 28.0, 32.0),
                    m::F_CAP,
                    16.0,
                    t.label3(),
                );
                if hovered {
                    c.fill_rounded(*r, 6.0, Color::WHITE.with_alpha(0.04));
                }
            }
            Element::Lesson(i, r) => {
                let l = &LESSONS[*i];
                let hovered = self.hover == Some(StartHit::Lesson(*i));
                c.fill_rounded(*r, 6.0, k.group);
                c.stroke_rounded(r.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
                let sq = CGRect::new(r.min_x() + 14.0, r.min_y() + 14.0, 32.0, 32.0);
                c.fill_rounded(sq, 7.0, k.raised);
                c.stroke_rounded(sq.inset_by(0.5, 0.5), 7.0, 1.0, k.line);
                c.draw_icon(l.2, CGPoint::new(sq.mid_x() - 8.0, sq.mid_y() - 8.0), 16.0, t.label2(), None);
                let face = c.semibold();
                text(
                    c,
                    l.0,
                    CGRect::new(r.min_x() + 14.0, r.min_y() + 58.0, r.width - 28.0, 16.0),
                    m::F_LAB,
                    t.label(),
                    TextAlign::Left,
                    face,
                );
                let _ = c.draw_wrapped(
                    l.1,
                    CGRect::new(r.min_x() + 14.0, r.min_y() + 78.0, r.width - 28.0, 48.0),
                    m::F_CAP,
                    16.0,
                    t.label3(),
                );
                if !l.3.is_empty() {
                    let w = c.size_of(l.3, m::F_LAB, 0).width + 18.0;
                    Self::flat_button(
                        c,
                        t,
                        k,
                        l.3,
                        None,
                        hovered,
                        CGRect::new(r.min_x() + 14.0, r.max_y() - 36.0, w, 22.0),
                    );
                }
            }
            Element::Button(s, h, r, primary) => {
                let btn = Btn::new(s, *primary, self.hover.as_ref() == Some(h));
                let btn = match h {
                    StartHit::ReportIssue => btn.icon(SQIcon::Github).tint(t.label()),
                    StartHit::Support(SupportEntry::Discord) => {
                        btn.icon(SQIcon::Discord).tint(Color::new(88.0 / 255.0, 101.0 / 255.0, 242.0 / 255.0, 1.0))
                    }
                    _ => btn,
                };
                Self::button(c, t, k, &btn, *r)
            }
        }
    }

    fn draw_quick(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, tmpl: Option<&ProjectTemplate>, r: CGRect) {
        let h = tmpl.map_or(StartHit::AllFormats, |t| StartHit::QuickSize(t.id.clone()));
        if self.hover.as_ref() == Some(&h) {
            c.fill_rounded(r, m::R_CTL, Color::WHITE.with_alpha(0.04));
        }
        let x = r.min_x() + 6.0 + 34.0 + 12.0;
        let tile = CGRect::new(r.min_x() + 6.0, r.mid_y() - 17.0, 34.0, 34.0);
        c.fill_rounded(tile, 6.0, k.raised);
        c.stroke_rounded(tile.inset_by(0.5, 0.5), 6.0, 1.0, k.line);
        let glyph = |c: &mut Canvas, icon: SQIcon| {
            c.draw_icon(icon, CGPoint::new(tile.mid_x() - 8.0, tile.mid_y() - 8.0), 16.0, t.label2(), None)
        };
        let face = c.medium();
        if let Some(tmpl) = tmpl {
            if !tmpl.variants.is_empty() {
                glyph(c, SQIcon::Stack);
            } else {
                let f = &tmpl.format;
                if f.width == f.height {
                    Self::frame_glyph(c, f.width, f.height, t.label2(), tile.inset_by(10.0, 10.0));
                } else {
                    glyph(c, if f.height > f.width { SQIcon::DeviceMobile } else { SQIcon::Monitor });
                }
            }
            text(
                c,
                &tmpl.name,
                CGRect::new(x, r.mid_y() - 16.0, r.max_x() - x - 6.0, 16.0),
                m::F_LAB,
                t.label(),
                TextAlign::Left,
                face,
            );
            text(
                c,
                &format!("{} × {}", tmpl.format.width, tmpl.format.height),
                CGRect::new(x, r.mid_y() + 1.0, r.max_x() - x, 14.0),
                m::F_CAP,
                t.label3(),
                TextAlign::Left,
                0,
            );
        } else {
            glyph(c, SQIcon::Ellipsis);
            text(
                c,
                "All formats…",
                CGRect::new(x, r.min_y(), r.max_x() - x, r.height),
                m::F_LAB,
                t.label(),
                TextAlign::Left,
                face,
            );
        }
    }

    /// A project tile of the design: the picture (184 x 104), the name, "1080 × 1920 · 10 min ago", "…" on hover, an accent
    /// ring on the highlighted one.
    fn draw_card(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv, e: &RecentEntry, r: CGRect) {
        let gone = self.missing.contains(&e.path);
        let hovering = self.hover == Some(StartHit::Card(e.path.clone()))
            || self.hover == Some(StartHit::CardMore(e.path.clone()));
        let well = CGRect::new(r.min_x(), r.min_y(), r.width, m::MEDIA_H);
        self.poster_well(
            c,
            t,
            k,
            &Poster {
                info: self.infos.get(&e.path),
                path: Some(&e.path),
                gone,
                poster: self.card_poster(env, &e.path),
                inset: 8.0,
            },
            well,
        );
        if hovering {
            c.fill_rounded(well, m::R_CTL, Color::WHITE.with_alpha(0.04));
        }
        if self.highlighted_path(env).as_deref() == Some(e.path.as_str()) {
            c.stroke_rounded(well.inset_by(-1.0, -1.0), m::R_CTL + 1.0, 2.0, t.accent());
        }
        let when = StartLabels::relative(e.opened, env.now, env.calendar);
        let sub = if gone {
            "File not found. Click to locate it.".to_string()
        } else {
            self.infos.get(&e.path).map_or_else(|| when.clone(), |i| format!("{} · {when}", i.size()))
        };
        let face = c.medium();
        let w = r.width - m::CONTROL_SMALL;
        text(
            c,
            &e.name,
            CGRect::new(r.min_x(), well.max_y() + 8.0, w, 16.0),
            m::F_LAB,
            if gone { t.label3() } else { t.label() },
            TextAlign::Left,
            face,
        );
        text(
            c,
            &sub,
            CGRect::new(r.min_x(), well.max_y() + 26.0, r.width, 14.0),
            m::F_CAP,
            t.label3(),
            TextAlign::Left,
            0,
        );
        if hovering {
            let mr = Self::more_rect(r);
            if self.hover == Some(StartHit::CardMore(e.path.clone())) {
                c.fill_rounded(mr, m::R_INNER, t.fill_hover());
            }
            c.draw_icon(SQIcon::Ellipsis, CGPoint::new(mr.mid_x() - 6.0, mr.mid_y() - 6.0), 12.0, t.label2(), None);
        }
    }

    /// `ProjectListRow`: 40 x 32 picture, name (medium), size, aspect, rate, length, edited, "…" on hover.
    fn draw_list_row(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, env: &StartEnv, e: &RecentEntry, r: CGRect) {
        let gone = self.missing.contains(&e.path);
        let hovering = self.hover == Some(StartHit::Card(e.path.clone()))
            || self.hover == Some(StartHit::CardMore(e.path.clone()));
        if self.highlighted_path(env).as_deref() == Some(e.path.as_str()) {
            c.fill_rounded(r, m::R_CTL, t.current());
        } else if hovering {
            c.fill_rounded(r, m::R_CTL, t.hover());
        }
        let info = self.infos.get(&e.path);
        let col = Self::list_columns(r);
        let ts = Self::LIST_THUMB;
        let thumb = CGRect::new(r.min_x() + m::S2, r.mid_y() - ts.height / 2.0, ts.width, ts.height);
        c.fill_rounded(thumb, m::R_INNER, k.lane);
        if gone {
            c.draw_icon(
                SQIcon::Warning,
                CGPoint::new(thumb.mid_x() - 5.5, thumb.mid_y() - 5.5),
                m::F_CAP,
                k.warning,
                None,
            );
        } else {
            let b = thumb.inset_by(m::S2 / 2.0, m::S2 / 2.0);
            let ar = info.map_or(16.0 / 9.0, |i| i.width as f64 / i.height.max(1) as f64);
            let w = b.width.min(b.height * ar);
            let pic = CGRect::new(b.mid_x() - w / 2.0, b.mid_y() - w / ar / 2.0, w, w / ar);
            c.fill_rounded(pic, m::S1 / 2.0, t.fill());
        }
        let cell = |c: &mut Canvas, s: &str, x: Option<f64>, w: f64, color: Color| {
            if let Some(x) = x {
                text(c, s, CGRect::new(x, r.min_y(), w, r.height), m::F_LAB, color, TextAlign::Left, 0);
            }
        };
        let face = c.medium();
        let (name_room, locate) = Self::locate_row_parts(&col, r);
        let name_rect = if gone { name_room } else { col.name };
        text(c, &e.name, name_rect, m::F_LAB, if gone { t.label2() } else { t.label() }, TextAlign::Left, face);
        if gone {
            cell(c, "File not found", col.size, 110.0 + 64.0 + m::S3, k.warning);
            Self::button(c, t, k, &Btn::new("Locate…", false, false), locate);
        } else {
            let dash = || "–".to_string();
            cell(c, &info.map_or_else(dash, StartProjectInfo::size), col.size, 110.0, t.label2());
            cell(c, &info.map_or_else(dash, StartProjectInfo::aspect), col.aspect, 64.0, t.label2());
            cell(c, &info.map_or_else(dash, StartProjectInfo::rate), col.rate, 92.0, t.label2());
            cell(c, &info.map_or_else(dash, StartProjectInfo::length), col.length, 64.0, t.label2());
        }
        cell(c, &StartLabels::relative(e.opened, env.now, env.calendar), col.edited, 96.0, t.label2());
        if hovering {
            c.draw_icon(
                SQIcon::Ellipsis,
                CGPoint::new(col.more.mid_x() - m::ICON_BODY / 2.0, col.more.mid_y() - m::ICON_BODY / 2.0),
                m::ICON_BODY,
                t.label2(),
                None,
            );
        }
    }

    /// `PosterWell`: the frame in its aspect on the well, badges for aspect and length, the missing-file states.
    fn poster_well(&self, c: &mut Canvas, t: &DrawTheme, k: &Colors, p: &Poster, r: CGRect) {
        let Poster { info, path, gone, poster, inset } = *p;
        // art.html `.thumb`: the viewer color with a hair2 inset ring.
        c.fill_rounded(r, m::R_CTL, if gone { k.lane } else { t.viewer() });
        if gone {
            c.stroke_rounded(r.inset_by(0.5, 0.5), m::R_CTL, 1.0, k.line2);
        }
        let b = r.inset_by(inset, inset);
        let ar = info.map_or(16.0 / 9.0, |i| i.width as f64 / i.height.max(1) as f64);
        let w = b.width.min(b.height * ar);
        let h = w / ar;
        let pic = CGRect::new(b.mid_x() - w / 2.0, b.mid_y() - h / 2.0, w.max(0.0), h.max(0.0));
        // Viewer-relative so light mode keeps the dark placeholder (art.html light `.thumb`), not the white `raised`.
        if !gone {
            c.fill_rounded(pic, f64::from(theme_radius::SMALL), t.viewer().lifted(0.08));
        }
        let media_missing = info.is_some_and(|i| i.media_missing);
        if let Some(p) = poster.filter(|_| !gone && !media_missing) {
            p.draw_fit(c, pic, None);
            c.round_picture_corners(pic, f64::from(theme_radius::SMALL), t.viewer());
        } else if !gone && !media_missing {
            c.draw_icon(
                SQIcon::Film,
                CGPoint::new(pic.mid_x() - 6.5, pic.mid_y() - 6.5),
                m::ICON_BODY,
                t.label3(),
                None,
            );
        }
        if gone {
            c.draw_icon(SQIcon::Warning, CGPoint::new(r.mid_x() - 11.0, r.mid_y() - 11.0), 22.0, t.label4(), None);
            // The design's pill: a 11 pt warning mark, 4 pt gap, the label, 6 pt padding each side.
            let w = c.size_of("File missing", m::F_CAP, 0).width + 12.0 + 15.0;
            let pill = CGRect::new(r.min_x() + 8.0, r.max_y() - 26.0, w, 18.0);
            c.fill_rounded(pill, 3.0, k.red.with_alpha(0.14));
            c.draw_icon(SQIcon::Warning, CGPoint::new(pill.min_x() + 6.0, pill.mid_y() - 5.5), 11.0, k.red, None);
            let face = c.semibold();
            text(
                c,
                "File missing",
                CGRect::new(pill.min_x() + 21.0, pill.min_y(), pill.width - 21.0, pill.height),
                m::F_CAP,
                k.red,
                TextAlign::Left,
                face,
            );
        } else if media_missing {
            c.draw_icon(SQIcon::Unlink, CGPoint::new(r.mid_x() - 6.5, r.mid_y() - 14.0), m::ICON_BODY, k.warning, None);
            text(
                c,
                "Locate media…",
                CGRect::new(r.min_x(), r.mid_y() + 2.0, r.width, 14.0),
                m::F_CAP,
                k.warning,
                TextAlign::Center,
                0,
            );
        }
        let Some(info) = info else { return };
        if gone || path.is_none() {
            return;
        }
        // Badges (`Badge`): aspect at the bottom left with its glyph, length at the bottom right.
        let aspect = info.aspect();
        let glyph = inset == 0.0;
        let aspect_w = c.size_of(&aspect, m::F_CAP, 0).width + 12.0 + if glyph { 10.0 + m::S1 } else { 0.0 };
        let a = CGRect::new(r.min_x() + m::S2, r.max_y() - m::S2 - m::BADGE, aspect_w, m::BADGE);
        c.fill_rounded(a, 3.0, k.badge);
        let g = CGRect::new(a.min_x() + 6.0, a.mid_y() - 5.0, 10.0, 10.0);
        let text_x = if glyph {
            let gw = if ar >= 1.0 { g.width } else { g.width * ar };
            let gh = if ar >= 1.0 { g.height / ar } else { g.height };
            c.stroke_rounded(CGRect::new(g.mid_x() - gw / 2.0, g.mid_y() - gh / 2.0, gw, gh), 1.0, 1.0, k.badge_text);
            g.max_x() + m::S1
        } else {
            a.min_x() + 6.0
        };
        text(
            c,
            &aspect,
            CGRect::new(text_x, a.min_y(), a.max_x() - text_x, a.height),
            m::F_CAP,
            k.badge_text,
            TextAlign::Left,
            0,
        );
        if info.seconds > 0 {
            let length = info.length();
            let lw = c.size_of(&length, m::F_CAP, 0).width + 2.0 * m::S2;
            let l = CGRect::new(r.max_x() - m::S2 - lw, a.min_y(), lw, m::BADGE);
            c.fill_rounded(l, 3.0, k.badge);
            text(c, &length, l, m::F_CAP, k.badge_text, TextAlign::Center, 0);
        }
    }

    /// `FrameGlyph`: a rectangle in the frame's aspect, fitted in `box`, in `color`.
    fn frame_glyph(c: &mut Canvas, width: i64, height: i64, color: Color, boxed: CGRect) {
        let ar = width as f64 / height.max(1) as f64;
        let w = if ar >= 1.0 { boxed.width } else { boxed.width * ar };
        let h = if ar >= 1.0 { boxed.height / ar.max(0.01) } else { boxed.height };
        // Line glyph (art.html `.tile` phone / monitor outline), 1.25 pt stroke; a monitor gets a stand line.
        let g = CGRect::new(boxed.mid_x() - w / 2.0, boxed.mid_y() - h / 2.0, w, h);
        let wide = ar >= 1.0;
        let body = if wide { g.inset_by(0.0, 1.5) } else { g };
        let body = if wide { CGRect::new(body.x, body.y - 1.5, body.width, body.height) } else { body };
        c.stroke_rounded(body.inset_by(0.6, 0.6), f64::from(theme_radius::SMALL), 1.25, color);
        if wide {
            c.fill(CGRect::new(g.mid_x() - 3.0, body.max_y() + 1.0, 6.0, 1.25), color);
        }
    }
}

/// The icon of a footer row; GitHub and Discord use their brand marks.
fn footer_icon(h: &StartHit) -> SQIcon {
    match h {
        StartHit::Appearance => SQIcon::Info,
        StartHit::Feedback => SQIcon::Mail,
        StartHit::Support(SupportEntry::Github) => SQIcon::Github,
        StartHit::Support(SupportEntry::Discord) => SQIcon::Discord,
        _ => SQIcon::Heart,
    }
}

#[cfg(test)]
mod hint_tests {
    #[test]
    fn the_support_rows_use_the_brand_icons() {
        assert_eq!(super::footer_icon(&super::StartHit::Support(super::SupportEntry::Github)), super::SQIcon::Github);
        assert_eq!(super::footer_icon(&super::StartHit::Support(super::SupportEntry::Discord)), super::SQIcon::Discord);
    }

    use super::*;
    use sq_uikit::command_map::CommandMap;
    use sq_uikit::editor_command::EditorCommand;

    #[test]
    fn the_new_project_hint_is_the_key_the_file_menu_shows() {
        let bound = CommandMap::sq_default().binding_for(&EditorCommand::NewProject).expect("New Project has a key");
        assert_eq!(new_project_hint(), KeyBindingText::text(&bound, Platform::current()));
        assert_ne!(new_project_hint(), command_key('n'), "Ctrl+N is New Sequence");
    }
}
