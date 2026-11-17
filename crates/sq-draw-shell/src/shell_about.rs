// Swift: ShellAbout.swift
//! The About and Acknowledgments bodies (`AboutDialog.makeBody` / `makeAcknowledgmentsBody`, AppController+About) on the
//! canvas: in the `SQModal.Size.sList` card, the app icon (88), the name in the display size, the version line, the tagline,
//! the link buttons (Support tinted), the license, the supporters (when any) and the credits; the second page lists what the
//! app builds on. The words are `about_content`, shared with the other windows.
//!
//! Mapping: `open` pushes [`ShellEvent::OpenUrl`] on the host's event queue; `drawsIcon` (always unused in Swift) is dropped.

use crate::shell_app_icon::ShellAppIcon;
use crate::shell_dialog::ShellDialog;
use crate::shell_dialog::{PopupRequest, ShellDialogContent};
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_project::support_policy::{SupportEntry, SupportLinks};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, TextAlign, TextMeasure};
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::about_content::{self, ACKNOWLEDGMENTS, CREDITS, LICENSE, LICENSE_NOTE, Link, TAGLINE};
use sq_uikit::app_version::AppVersion;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::platform_wording::PlatformWording;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;

/// Which About card.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AboutPage {
    /// The About card.
    About,
    /// What the app builds on.
    Acknowledgments,
}

mod m {
    pub(super) const CARD_WIDTH: f64 = 360.0; // Theme.Modal.widthSList
    pub(super) const ICON: f64 = 72.0;
    pub(super) const MD: f64 = 12.0; // Theme.Spacing.md
    pub(super) const SM: f64 = 8.0; // Theme.Spacing.sm
    pub(super) const DISPLAY: f64 = 15.0;
    pub(super) const TITLE: f64 = 13.0;
    pub(super) const BODY: f64 = 11.0;
    pub(super) const CAPTION: f64 = 11.0;
    pub(super) const TAGLINE_WIDTH: f64 = 312.0;
    pub(super) const TAGLINE: f64 = 12.0; // art.html 43: smaller, wraps after "made"
    pub(super) const SUPPORTERS_WIDTH: f64 = 300.0;
    pub(super) const SUPPORTERS_MAX_HEIGHT: f64 = 96.0;
    pub(super) const BUTTON_HEIGHT: f64 = 22.0; // Theme.Metrics.quietButton
    pub(super) const BUTTON_PADDING: f64 = 11.0; // SQButton.horizontalPadding
    pub(super) const CHIP_ICON: f64 = 12.0;
    pub(super) const SIDE_PAD: f64 = 24.0;
    pub(super) const TOP_PAD: f64 = 26.0; // `dialogs.html` about(): 26 above the icon
    pub(super) const BUTTON_GAP: f64 = 6.0;
    pub(super) const SCROLL_BAR_WIDTH: f64 = 4.0; // as the dialog forms' scroll knob
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tone {
    Label,
    Label2,
    Label3,
}

/// One drawn piece of the body, in window points after `layout`.
#[derive(Clone, Debug, PartialEq)]
enum Part {
    Icon(CGRect),
    Text { s: String, r: CGRect, size: f64, tone: Tone, medium: bool, center: bool },
    Button { s: String, r: CGRect, url: String, support: bool, icon: SQIcon },
}

/// The body of the About dialog.
pub struct ShellAboutContent {
    /// Which card.
    pub page: AboutPage,
    supporters: Vec<String>,
    links: Vec<Link>,
    open: Box<dyn Fn(&str)>,
    parts: Vec<Part>,
    hovered: Option<usize>,
    pressed: Option<usize>,
    /// The visible window of the body and how far it is scrolled (a card taller than a small window scrolls).
    view: CGRect,
    total: f64,
    scrolled: f64,
}

impl ShellAboutContent {
    /// A body for `page`; `open` opens a link.
    pub fn new(page: AboutPage, supporters: Vec<String>, discord: Option<&str>, open: Box<dyn Fn(&str)>) -> Self {
        ShellAboutContent {
            page,
            supporters,
            links: about_content::links(discord),
            open,
            parts: Vec::new(),
            hovered: None,
            pressed: None,
            view: CGRect::default(),
            total: 0.0,
            scrolled: 0.0,
        }
    }

    /// Whether a part is drawn: while the body scrolls, a line or button cut by the viewport edge is left out, so the list
    /// ends at a line boundary instead of mid-glyph above the button row.
    fn shown(&self, p: &Part) -> bool {
        let r = match p {
            Part::Icon(_) => return true,
            Part::Text { r, .. } | Part::Button { r, .. } => *r,
        };
        self.total <= self.view.height + 0.5
            || (r.min_y() >= self.view.min_y() - 0.5 && r.max_y() <= self.view.max_y() + 0.5)
    }

    /// The thin scroll knob at the right edge of the viewport (the same one the dialog forms draw); `None` when all fits.
    fn knob(&self) -> Option<CGRect> {
        if self.total <= self.view.height + 0.5 {
            return None;
        }
        let track = self.view.inset_by(0.0, 2.0);
        let knob_h = (track.height * self.view.height / self.total).max(24.0);
        let travel = (self.total - self.view.height).max(1.0);
        let ky = track.min_y() + (track.height - knob_h) * self.scrolled / travel;
        Some(CGRect::new(track.max_x() - m::SCROLL_BAR_WIDTH - 4.0, ky, m::SCROLL_BAR_WIDTH, knob_h))
    }

    fn url(l: Link) -> &'static str {
        match l {
            Link::Github => SupportLinks::GITHUB,
            Link::Support => SupportLinks::URL,
            Link::Discord => SupportLinks::DISCORD.unwrap_or(SupportLinks::URL),
        }
    }

    fn icon(l: Link) -> SQIcon {
        match l {
            Link::Github => SQIcon::Github,
            Link::Support => SQIcon::Heart,
            Link::Discord => SQIcon::Discord,
        }
    }

    /// The body stacked from `frame.y` down (the Mac NSStackView, centered column); returns the parts and the height.
    fn build(&self, frame: CGRect, m: &TextMeasure) -> (Vec<Part>, f64) {
        let mut out: Vec<Part> = Vec::new();
        let x = frame.min_x() + m::SIDE_PAD;
        let w = frame.width - 2.0 * m::SIDE_PAD;
        let mut y = frame.min_y();
        let lines = |out: &mut Vec<Part>,
                     y: &mut f64,
                     s: &str,
                     size: f64,
                     width: f64,
                     tone: Tone,
                     medium: bool,
                     center: bool,
                     left: Option<f64>| {
            let lh = m.line_height(size);
            let lx = left.unwrap_or(x + (w - width) / 2.0);
            for l in m.lines(&SQL10n::string(s), width, size) {
                out.push(Part::Text { s: l, r: CGRect::new(lx, *y, width, lh), size, tone, medium, center });
                *y += lh;
            }
        };
        match self.page {
            AboutPage::About => {
                y += m::TOP_PAD;
                out.push(Part::Icon(CGRect::new(x + (w - m::ICON) / 2.0, y, m::ICON, m::ICON)));
                y += m::ICON + 10.0;
                lines(&mut out, &mut y, "Sequence Studio", m::DISPLAY, w, Tone::Label, true, true, None);
                y += 2.0;
                lines(&mut out, &mut y, &AppVersion::about_line(), m::BODY, w, Tone::Label3, false, true, None);
                y += m::MD;
                lines(
                    &mut out,
                    &mut y,
                    &PlatformWording::adapt(TAGLINE, Platform::current()),
                    m::TAGLINE,
                    m::TAGLINE_WIDTH,
                    Tone::Label2,
                    false,
                    true,
                    None,
                );
                y += m::MD;
                let widths: Vec<f64> = self
                    .links
                    .iter()
                    .map(|l| {
                        (m.width(&SQL10n::string(l.title()), m::BODY, 0).ceil()
                            + 2.0 * m::BUTTON_PADDING
                            + (m::CHIP_ICON + 4.0))
                            .max(0.0)
                    })
                    .collect();
                let gaps = m::BUTTON_GAP * self.links.len().saturating_sub(1) as f64;
                let mut bx = x + (w - widths.iter().sum::<f64>() - gaps) / 2.0;
                for (l, bw) in self.links.iter().zip(&widths) {
                    out.push(Part::Button {
                        s: l.title().to_string(),
                        r: CGRect::new(bx, y, *bw, m::BUTTON_HEIGHT),
                        url: Self::url(*l).to_string(),
                        support: *l == Link::Support,
                        icon: Self::icon(*l),
                    });
                    bx += bw + m::BUTTON_GAP;
                }
                y += m::BUTTON_HEIGHT + m::MD;
                y += 4.0;
                lines(&mut out, &mut y, &format!("License: {LICENSE}"), m::BODY, w, Tone::Label3, false, true, None);
                if !self.supporters.is_empty() {
                    y += m::MD;
                    let left = x + (w - m::SUPPORTERS_WIDTH) / 2.0;
                    lines(
                        &mut out,
                        &mut y,
                        "Supporters",
                        m::TITLE,
                        m::SUPPORTERS_WIDTH,
                        Tone::Label,
                        true,
                        false,
                        Some(left),
                    );
                    y += m::SM;
                    // The names stop at the Mac block's max height (96) instead of scrolling, as in Swift `ShellAbout`.
                    let top = y;
                    let inner = m::SUPPORTERS_WIDTH - m::MD;
                    let body_lh = m.line_height(m::BODY);
                    for l in m.lines(&self.supporters.join("  \u{00B7}  "), inner, m::BODY) {
                        if y + body_lh > top + m::SUPPORTERS_MAX_HEIGHT {
                            continue;
                        }
                        out.push(Part::Text {
                            s: l,
                            r: CGRect::new(left, y, inner, body_lh),
                            size: m::BODY,
                            tone: Tone::Label2,
                            medium: false,
                            center: false,
                        });
                        y += body_lh;
                    }
                    y += m::SM;
                    let title = SupportEntry::Support.menu_title();
                    let bw = m.width(&SQL10n::string(title), m::BODY, 0).ceil()
                        + 2.0 * m::BUTTON_PADDING
                        + m::CHIP_ICON
                        + 4.0;
                    out.push(Part::Button {
                        s: title.to_string(),
                        r: CGRect::new(left, y, bw, m::BUTTON_HEIGHT),
                        url: SupportLinks::URL.to_string(),
                        support: true,
                        icon: SQIcon::Heart,
                    });
                    y += m::BUTTON_HEIGHT;
                }
                lines(&mut out, &mut y, CREDITS, m::CAPTION, w, Tone::Label3, false, true, None);
            }
            AboutPage::Acknowledgments => {
                for (i, a) in ACKNOWLEDGMENTS.iter().enumerate() {
                    if i > 0 {
                        y += m::MD;
                    }
                    lines(
                        &mut out,
                        &mut y,
                        &format!("{}  ·  {}", a.name, a.version),
                        m::BODY,
                        w,
                        Tone::Label,
                        true,
                        false,
                        Some(x),
                    );
                    y += 2.0;
                    lines(
                        &mut out,
                        &mut y,
                        &format!("{}. {}", a.license, a.used_for),
                        m::CAPTION,
                        w,
                        Tone::Label2,
                        false,
                        false,
                        Some(x),
                    );
                }
                y += m::MD;
                lines(&mut out, &mut y, LICENSE_NOTE, m::CAPTION, w, Tone::Label3, false, false, Some(x));
            }
        }
        (out, y - frame.min_y())
    }

    /// Where the app icon goes (window points; `None` on the Acknowledgments page). The host puts the icon there: the draw
    /// list's image slots are all taken (shortcut: a host-side picture; upgrade when the renderer gets a free slot).
    pub fn icon_frame(&self) -> Option<CGRect> {
        self.parts.iter().find_map(|p| if let Part::Icon(r) = p { Some(*r) } else { None })
    }

    /// The text lines of the laid-out card (tests).
    #[cfg(test)]
    pub(crate) fn text_lines(&self) -> Vec<String> {
        self.parts.iter().filter_map(|p| if let Part::Text { s, .. } = p { Some(s.clone()) } else { None }).collect()
    }

    /// The middle of the first link button (tests).
    #[cfg(test)]
    pub(crate) fn first_button_center(&self) -> Option<CGPoint> {
        self.parts
            .iter()
            .find_map(|p| if let Part::Button { r, .. } = p { Some(CGPoint::new(r.mid_x(), r.mid_y())) } else { None })
    }

    /// The link button index at `p`.
    fn button_at(&self, p: CGPoint) -> Option<usize> {
        if self.view.height > 0.0 && !self.view.contains(p) {
            return None;
        }
        self.parts.iter().position(|q| matches!(q, Part::Button { r, .. } if r.contains(p)))
    }
}

impl ShellDialogContent for ShellAboutContent {
    fn height(&mut self, width: f64) -> f64 {
        self.height_measured(width, &TextMeasure::new(None, 1.0))
    }

    fn height_measured(&mut self, width: f64, m: &TextMeasure) -> f64 {
        self.build(CGRect::new(0.0, 0.0, width, 0.0), m).1
    }

    fn layout(&mut self, frame: CGRect, m: &TextMeasure) {
        let (parts, total) = self.build(frame, m);
        self.parts = parts;
        self.view = frame;
        self.total = total;
        // The offset survives a new layout, clamped to the new content height.
        self.scrolled = self.scrolled.clamp(0.0, (total - frame.height).max(0.0));
        let by = self.scrolled;
        if by > 0.0 {
            for p in &mut self.parts {
                match p {
                    Part::Icon(r) | Part::Text { r, .. } | Part::Button { r, .. } => r.y -= by,
                }
            }
        }
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme) {
        if let Some(knob) = self.knob() {
            c.fill_rounded(knob, m::SCROLL_BAR_WIDTH / 2.0, t.label3());
        }
        for (i, p) in self.parts.iter().enumerate() {
            if !self.shown(p) {
                continue;
            }
            match p {
                // art.html 43: Pip's head and face, no gradient field
                Part::Icon(r) => ShellAppIcon::draw(*r, c, false),
                Part::Text { s, r, size, tone, medium, center } => {
                    let color: Color = match tone {
                        Tone::Label => t.label(),
                        Tone::Label2 => t.label2(),
                        Tone::Label3 => t.label3(),
                    };
                    let face = if *medium { c.medium() } else { 0 };
                    c.draw_text_in(
                        s,
                        *r,
                        *size,
                        color,
                        if *center { TextAlign::Center } else { TextAlign::Left },
                        0.0,
                        face,
                    );
                }
                Part::Button { s, r, icon, .. } => {
                    // art.html `.btn`: raised with a `hair2` ring; the Support chip carries the heart icon.
                    let touch = Touch {
                        hovering: self.hovered == Some(i),
                        pressed: self.pressed == Some(i),
                        ..Touch::default()
                    };
                    c.stone_button(*r, ButtonKind::Raised, touch, t);
                    let tw = c.size_of(s, m::BODY, 0).width;
                    let gw = m::CHIP_ICON + 4.0 + tw;
                    let x0 = r.mid_x() - gw / 2.0;
                    c.draw_icon(
                        *icon,
                        CGPoint::new(x0, r.mid_y() - m::CHIP_ICON / 2.0),
                        m::CHIP_ICON,
                        t.label2(),
                        None,
                    );
                    let face = c.medium();
                    c.draw_text_in(
                        s,
                        CGRect::new(x0 + m::CHIP_ICON + 4.0, r.min_y(), tw + 2.0, r.height),
                        m::BODY,
                        t.label(),
                        TextAlign::Left,
                        0.0,
                        face,
                    );
                }
            }
        }
    }

    fn handle(&mut self, e: &InputEvent, scale: f32) -> bool {
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        match *e {
            InputEvent::MouseMoved { x, y } => {
                self.hovered = self.button_at(pt(x, y));
                false
            }
            InputEvent::MouseDown { x, y, .. } => {
                self.pressed = self.button_at(pt(x, y));
                self.pressed.is_some()
            }
            InputEvent::MouseDragged { x, y, .. } => {
                self.hovered = self.button_at(pt(x, y));
                self.pressed.is_some()
            }
            InputEvent::MouseUp { x, y } => {
                let Some(p) = self.pressed.take() else { return false };
                if self.button_at(pt(x, y)) == Some(p)
                    && let Part::Button { url, .. } = &self.parts[p]
                {
                    (self.open)(url);
                }
                true
            }
            InputEvent::Scroll { dy, .. } => {
                let max = (self.total - self.view.height).max(0.0);
                if max <= 0.0 {
                    return false;
                }
                let next = (self.scrolled - f64::from(dy / scale)).clamp(0.0, max);
                let by = next - self.scrolled;
                self.scrolled = next;
                for p in &mut self.parts {
                    match p {
                        Part::Icon(r) | Part::Text { r, .. } | Part::Button { r, .. } => r.y -= by,
                    }
                }
                true
            }
            _ => false,
        }
    }

    fn take_popup(&mut self) -> Option<PopupRequest> {
        None
    }
}

impl ShellHost {
    /// One About card.
    pub(crate) fn about_dialog(&self, page: AboutPage) -> ShellDialog {
        let open = self.event_sink();
        let mut d = ShellDialog::new(if page == AboutPage::About { "" } else { "Acknowledgments" }, "");
        if page == AboutPage::About {
            d.width = m::CARD_WIDTH;
        }
        d.kit_layout = true;
        d.content = Some(Box::new(ShellAboutContent::new(
            page,
            self.about_supporters.clone(),
            SupportLinks::DISCORD,
            Box::new(move |u| open.borrow_mut().push(ShellEvent::OpenUrl(u.to_string()))),
        )));
        d.add_button("Done", SQDialogRole::Default, false);
        d.add_button(if page == AboutPage::About { "Acknowledgments" } else { "Back" }, SQDialogRole::Normal, true);
        d.ghost_buttons.insert(1); // art.html 43: Acknowledgments is a ghost button
        d
    }

    /// Sequence Studio > About (AppController+About `presentAbout`): the About card with Done and, on the left,
    /// Acknowledgments, which swaps to the Acknowledgments card with Back.
    pub async fn show_about<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let mut page = AboutPage::About;
        loop {
            let Some(d) = h.with(|r| r.shell_parts().shell.about_dialog(page)) else {
                return;
            };
            if Self::ask(&h, d).await != Some(SQDialogResponse::SECOND) {
                return;
            }
            page = if page == AboutPage::About { AboutPage::Acknowledgments } else { AboutPage::About };
        }
    }
}

#[cfg(test)]
mod brand_icon_tests {
    use super::*;
    use sq_core_project::support_policy::SupportEntry;

    #[test]
    fn about_start_and_menu_use_the_brand_icons() {
        assert_eq!(ShellAboutContent::icon(Link::Github), SQIcon::Github);
        assert_eq!(ShellAboutContent::icon(Link::Discord), SQIcon::Discord);
        // The Help menu goes through `symbol()`.
        assert_eq!(SQIcon::from_raw(SupportEntry::Github.symbol()), Some(SQIcon::Github));
        assert_eq!(SQIcon::from_raw(SupportEntry::Discord.symbol()), Some(SQIcon::Discord));
    }
}

#[cfg(test)]
mod scroll_tests {
    use super::*;

    fn ack(height: f64) -> ShellAboutContent {
        let mut c = ShellAboutContent::new(AboutPage::Acknowledgments, Vec::new(), None, Box::new(|_| {}));
        c.layout(CGRect::new(0.0, 0.0, 360.0, height), &TextMeasure::new(None, 1.0));
        c
    }

    #[test]
    fn a_scrolling_acknowledgments_list_ends_at_a_line_boundary_and_shows_a_knob() {
        let c = ack(150.0);
        let drawn: Vec<&Part> = c.parts.iter().filter(|p| c.shown(p)).collect();
        assert!(!drawn.is_empty() && drawn.len() < c.parts.len(), "the lines below the edge are left out");
        for p in drawn {
            if let Part::Text { r, .. } = p {
                assert!(r.max_y() <= c.view.max_y() + 0.5, "a drawn line is whole: {r:?}");
            }
        }
        let knob = c.knob().expect("the list is taller than the view");
        assert!(knob.min_y() >= c.view.min_y() && knob.max_y() <= c.view.max_y());
    }

    #[test]
    fn a_list_that_fits_draws_everything_and_no_knob() {
        let c = ack(5000.0);
        assert!(c.parts.iter().all(|p| c.shown(p)));
        assert!(c.knob().is_none());
    }
}
