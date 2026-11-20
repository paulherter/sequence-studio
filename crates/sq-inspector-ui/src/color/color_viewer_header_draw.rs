// Swift: Draw/ColorViewerHeaderDraw.swift
//! The viewer header of the Color page as shared-toolkit draw code: the graded clip's name and "n of m" at the left,
//! Before | After | Split and the more-actions button at the right, a hairline at the bottom. The content comes from
//! `ColorGradeController::viewer_header_content`, the segment calls `set_compare`, the more button opens the viewer menu
//! (`menu_items`: Copy Grade / Paste Grade). The clip name draws in the atlas's Medium face.
//!
//! Also the right end of the Color panels' tab strips (`ColorStripToolsDraw`): a quiet detail text, then Add Step (Steps
//! only), Copy Grade and Paste Grade as icon buttons.

use super::color_grade_controller::{ColorGradeController, ColorMenuCommand};
use super::color_page_models::ColorCompareMode;
use super::geom::union;
use sq_core_color::ActiveGrade;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{metrics, spacing, type_size};
use sq_draw::{Canvas, DrawTheme, InputModifiers, TextAlign};
use sq_editor_session::{ColorClipboard, EditorSession};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

fn row(controller: &ColorGradeController, title: &str, c: ColorMenuCommand) -> SQMenuItem {
    let sink = controller.menu_sink.clone();
    let mut i = SQMenuItem::new(title);
    i.action = Some(Rc::new(move || sink.push(c.clone())));
    i
}

/// A control of the viewer header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ViewerHeaderControl {
    Compare(ColorCompareMode),
    More,
}

/// The menu the header asked for (Swift `onMenu`).
#[derive(Clone, Debug)]
pub struct HeaderMenuRequest {
    pub items: Vec<SQMenuItem>,
    pub anchor: CGRect,
}

pub struct ColorViewerHeaderDraw {
    pub size: CGSize,
    hover: Option<ViewerHeaderControl>,
    /// The segment widths from the canvas the header drew last (before any draw: 7 points per letter).
    segment_widths: [f64; 3],
    /// Menus the header asked for, oldest first.
    pub menus: Vec<HeaderMenuRequest>,
}

impl Default for ColorViewerHeaderDraw {
    fn default() -> Self {
        let w = |m: ColorCompareMode| m.title().chars().count() as f64 * 7.0 + Self::SEGMENT_PADDING;
        ColorViewerHeaderDraw {
            size: CGSize::new(600.0, f64::from(metrics::PANEL_HEADER)),
            hover: None,
            segment_widths: [w(ColorCompareMode::Before), w(ColorCompareMode::After), w(ColorCompareMode::Split)],
            menus: Vec::new(),
        }
    }
}

impl ColorViewerHeaderDraw {
    const RIGHT: f64 = spacing::SM as f64;
    const TEXT_LEFT: f64 = 12.0;
    /// SQSegmented (compact): a segment is its label plus 20, 1 pt between the track edge and the segments.
    const SEGMENT_PADDING: f64 = 20.0;
    const TRACK_PADDING: f64 = 1.0;
    /// `Theme.Spacing.iconToLabel` between the segment and the more button; the button is `barIconWidth` wide.
    const MORE_GAP: f64 = 6.0;
    const MORE_WIDTH: f64 = 24.0;

    pub fn new() -> ColorViewerHeaderDraw {
        ColorViewerHeaderDraw::default()
    }

    pub fn hover(&self) -> Option<ViewerHeaderControl> {
        self.hover
    }

    fn mode_index(m: ColorCompareMode) -> usize {
        match m {
            ColorCompareMode::Before => 0,
            ColorCompareMode::After => 1,
            ColorCompareMode::Split => 2,
        }
    }

    /// The controls and their frames, right to left: more, then the segments (their drawn shapes inside the track).
    pub fn frames(&self) -> Vec<(ViewerHeaderControl, CGRect)> {
        let h = self.size.height;
        let ch = f64::from(metrics::CAPSULE);
        let y = ((h - ch) / 2.0).round();
        let mut x = self.size.width - Self::RIGHT - Self::MORE_WIDTH;
        let mut out = vec![(ViewerHeaderControl::More, CGRect::new(x, y, Self::MORE_WIDTH, ch))];
        x -= Self::MORE_GAP + Self::TRACK_PADDING;
        for m in ColorCompareMode::ALL.iter().rev() {
            let w = self.segment_widths[Self::mode_index(*m)];
            x -= w;
            out.push((
                ViewerHeaderControl::Compare(*m),
                CGRect::new(x, y + Self::TRACK_PADDING, w, ch - 2.0 * Self::TRACK_PADDING),
            ));
        }
        out
    }

    /// The segment's track around the segment frames of `fr` (nil without segments).
    pub fn track_rect(fr: &[(ViewerHeaderControl, CGRect)]) -> Option<CGRect> {
        let segs: Vec<CGRect> =
            fr.iter().filter(|(k, _)| matches!(k, ViewerHeaderControl::Compare(_))).map(|(_, r)| *r).collect();
        let first = segs.iter().copied().reduce(|a, b| if b.min_x() < a.min_x() { b } else { a })?;
        let last = segs.iter().copied().reduce(|a, b| if b.min_x() > a.min_x() { b } else { a })?;
        Some(union(&first, &last).inset_by(-Self::TRACK_PADDING, -Self::TRACK_PADDING))
    }

    /// A press or hover anywhere in a segment's column counts (the track padding and the full header height, as
    /// SQSegmented `columnRect`); the more button by its frame.
    pub fn control_at(&self, p: CGPoint) -> Option<ViewerHeaderControl> {
        let fr = self.frames();
        let track = Self::track_rect(&fr);
        for (k, r) in &fr {
            match k {
                ViewerHeaderControl::More => {
                    if r.contains(p) {
                        return Some(*k);
                    }
                }
                ViewerHeaderControl::Compare(m) => {
                    let (tmin, tmax) = track.map_or((r.min_x(), r.max_x()), |t| (t.min_x(), t.max_x()));
                    let lo = if *m == ColorCompareMode::Before { tmin } else { r.min_x() };
                    let hi = if *m == ColorCompareMode::Split { tmax } else { r.max_x() };
                    if p.x >= lo && p.x < hi && p.y >= 0.0 && p.y < self.size.height {
                        return Some(*k);
                    }
                }
            }
        }
        None
    }

    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, controller: &ColorGradeController) {
        let fs = f64::from(type_size::BODY);
        let b = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        c.fill(b, t.panel());
        c.fill(CGRect::new(0.0, b.max_y() - 1.0, b.width, 1.0), t.separator());
        if c.atlas().is_some() {
            for m in ColorCompareMode::ALL {
                self.segment_widths[Self::mode_index(m)] =
                    c.size_of(&SQL10n::string(m.title()), fs, 0).width.ceil() + Self::SEGMENT_PADDING;
            }
        }
        let fr = self.frames();
        let track = Self::track_rect(&fr);
        let seg_left = track.map_or(b.max_x(), |t| t.min_x());
        let content = controller.viewer_header_content();
        let mut x = Self::TEXT_LEFT;
        // The Mac layout: the text ends `iconToLabel` + `Spacing.sm` before the segment's track.
        let right = seg_left - Self::MORE_GAP;
        let room = (right - f64::from(spacing::SM) - x).max(0.0);
        let pw = content.position.as_ref().map_or(0.0, |p| c.size_of(p, fs, 0).width.ceil() + 4.0);
        let medium = c.medium();
        let nw = (c.size_of(&content.name, fs, medium).width.ceil() + 4.0)
            .min((room - pw - if pw > 0.0 { 12.0 } else { 0.0 }).max(0.0));
        let ty = ((b.height - fs - 4.0) / 2.0).round();
        c.draw_text(&content.name, CGPoint::new(x, ty), fs, t.label(), nw, medium);
        if let Some(pos) = &content.position {
            x += nw + 12.0;
            c.draw_text(pos, CGPoint::new(x, ty), fs, t.label3(), pw.min((right - x).max(0.0)), 0);
        }
        // The segment (SQSegmented compact): a `fill2` track, the picked mode `fillPressed` with white text, the others
        // in `label`, the hovered one `fillHover`.
        if let Some(track) = track {
            c.stone_segment_track(track, Touch::default(), t);
        }
        for (k, r) in &fr {
            match k {
                ViewerHeaderControl::Compare(m) => {
                    let on = controller.compare() == *m;
                    let touch = Touch { hovering: self.hover == Some(*k), ..Touch::default() };
                    c.stone_segment(*r, on, touch, t);
                    c.draw_text_in(&SQL10n::string(m.title()), *r, fs, t.label(), TextAlign::Center, 0.0, 0);
                }
                ViewerHeaderControl::More => {
                    if self.hover == Some(*k) {
                        c.stone_button(*r, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
                    }
                    c.draw_icon(
                        SQIcon::Ellipsis,
                        CGPoint::new(r.mid_x() - 6.0, r.mid_y() - 6.0),
                        12.0,
                        t.label2(),
                        None,
                    );
                }
            }
        }
    }

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p.and_then(|p| self.control_at(p));
    }

    /// The tip under the pointer: the graded clip's whole name, the compare modes and the more-actions button.
    pub fn help(&self, controller: &ColorGradeController, p: CGPoint) -> Option<String> {
        match self.control_at(p) {
            Some(ViewerHeaderControl::Compare(ColorCompareMode::Before)) => {
                Some(SQL10n::string("Before: the picture without the grade"))
            }
            Some(ViewerHeaderControl::Compare(ColorCompareMode::After)) => {
                Some(SQL10n::string("After: the graded picture"))
            }
            Some(ViewerHeaderControl::Compare(ColorCompareMode::Split)) => {
                Some(SQL10n::string("Split: ungraded on the left, graded on the right"))
            }
            Some(ViewerHeaderControl::More) => Some(SQL10n::string("More viewer actions")),
            None => {
                let name = &controller.viewer_header_content().name;
                let track = Self::track_rect(&self.frames());
                if p.x < track.map_or(self.size.width, |t| t.min_x()) && !name.is_empty() {
                    Some(name.clone())
                } else {
                    None
                }
            }
        }
    }

    pub fn mouse_down(
        &mut self,
        controller: &mut ColorGradeController,
        session: &mut EditorSession,
        clipboard: &ColorClipboard,
        p: CGPoint,
    ) {
        let Some(k) = self.control_at(p) else { return };
        let Some(r) = self.frames().into_iter().find(|f| f.0 == k).map(|f| f.1) else { return };
        match k {
            ViewerHeaderControl::Compare(m) => {
                if controller.compare() != m {
                    controller.set_compare(session, m);
                }
            }
            ViewerHeaderControl::More => {
                let items = Self::menu_items(controller, session, clipboard);
                self.menus.push(HeaderMenuRequest { items, anchor: r });
            }
        }
    }

    /// The viewer menu; a refused copy or paste beeps.
    pub fn menu_items(
        controller: &ColorGradeController,
        session: &EditorSession,
        clipboard: &ColorClipboard,
    ) -> Vec<SQMenuItem> {
        let mut copy = row(controller, "Copy Grade", ColorMenuCommand::CopyGradeOrBeep);
        copy.is_enabled = controller.can_copy_grade();
        let mut paste = row(controller, "Paste Grade", ColorMenuCommand::PasteGradeOrBeep);
        paste.is_enabled = controller.can_paste_grade(session, clipboard);
        vec![copy, paste]
    }
}

// MARK: - Strip tools

/// The panel whose strip the tools sit in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StripPanel {
    ColorInspector,
    Steps,
    Sources,
    Timeline,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StripButton {
    AddStep,
    /// The lower strips' timeline dropdowns (the bar's own controls, which the Color page drops from the timeline).
    Sequence,
    Mode,
    Fit,
    TimelineMore,
    Simple,
    Pro,
    More,
}

/// A timeline dropdown of the lower strips; the host opens the timeline header's menu of the same name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StripDropdown {
    Sequence,
    Mode,
    Fit,
    More,
}

thread_local! {
    /// The localized "Fit" label's width as the dock last measured it.
    static FIT_LABEL_WIDTH: std::cell::Cell<f64> = const { std::cell::Cell::new(0.0) };
}

/// What a press in the strip tools asks the host for (Swift `onMenu` and the controller calls).
#[derive(Clone, Debug)]
pub struct StripMenuRequest {
    pub items: Vec<SQMenuItem>,
    pub anchor: CGRect,
}

/// The right end of the Color panels' tab strips on the shared toolkit. Frames are in the strip's coordinates (the host
/// passes the strip rect in window points).
#[derive(Default)]
pub struct ColorStripToolsDraw {
    hover: Option<(StripPanel, StripButton)>,
    pressed: Option<(StripPanel, StripButton)>,
    /// Menus the tools asked for, oldest first.
    pub menus: Vec<StripMenuRequest>,
    /// Timeline dropdowns pressed, oldest first, with the button's frame (window points).
    pub dropdowns: Vec<(StripDropdown, CGRect)>,
    /// The open sequence's name and whether the timeline is in Fast Cut (the dropdowns' labels).
    pub sequence: String,
    pub fast_cut: bool,
}

impl ColorStripToolsDraw {
    /// v9 `.btn.ic`: 24 wide, the capsule's height; 2 pt between buttons, 8 pt before the strip's right edge.
    const BUTTON_WIDTH: f64 = 24.0;
    const BUTTON_GAP: f64 = 2.0;
    /// The Simple | Pro segments (SQSegmented with an icon beside the label, 14 pt icons).
    const SEGMENT_WIDTH: f64 = 54.0;
    const COLOR_RIGHT: f64 = 10.0;
    const COLOR_SEGMENT_GAP: f64 = 5.0;
    const RIGHT: f64 = spacing::SM as f64;
    const DETAIL_GAP: f64 = spacing::SM as f64;
    /// The detail never takes more than this (it is cut with an ellipsis).
    const DETAIL_MAX: f64 = 260.0;
    const FONT_SIZE: f64 = type_size::BODY as f64;
    /// The legend's swatch and the gap behind it.
    const SWATCH_ROOM: f64 = 18.0;

    pub fn new() -> ColorStripToolsDraw {
        ColorStripToolsDraw::default()
    }

    // shortcut: fixed dropdown widths (the sequence name is cut with an ellipsis), measure the labels when strips grow.
    fn width_of(b: StripButton) -> f64 {
        match b {
            StripButton::Simple | StripButton::Pro => Self::SEGMENT_WIDTH,
            StripButton::Sequence => 100.0,
            StripButton::Mode => 86.0,
            StripButton::Fit => Self::fit_button_width(FIT_LABEL_WIDTH.with(std::cell::Cell::get)),
            _ => Self::BUTTON_WIDTH,
        }
    }

    /// The Fit dropdown for a label `label_width` wide: label 8 in, chevron 2 after it, 8 pt to the edge; never narrower than
    /// the English one, so a longer translation ("Einpassen") grows the button instead of being cut to its first letters.
    pub fn fit_button_width(label_width: f64) -> f64 {
        (8.0 + label_width.ceil() + 1.0 + 2.0 + 12.0 + 8.0).max(46.0)
    }

    pub fn buttons(p: StripPanel) -> Vec<StripButton> {
        match p {
            StripPanel::ColorInspector => vec![StripButton::Simple, StripButton::Pro, StripButton::More],
            // Add Step moved into the graph header with Duplicate and Delete (redesign R4g).
            // Copy and Paste Grade live in the "..." menu.
            StripPanel::Steps | StripPanel::Sources | StripPanel::Timeline => {
                vec![StripButton::Sequence, StripButton::Mode, StripButton::Fit, StripButton::TimelineMore]
            }
        }
    }

    /// The quiet text before the buttons (the Mac header detail).
    pub fn detail(controller: &ColorGradeController, p: StripPanel) -> Option<String> {
        // The lower strips carry the legend of the yellow frames while a clip is graded (redesign R4g).
        if p != StripPanel::ColorInspector
            && let Some(l) = controller.legend()
        {
            return Some(l.to_string());
        }
        let s: Option<&str> = match p {
            StripPanel::ColorInspector | StripPanel::Steps => None,
            StripPanel::Sources => Some(ColorGradeController::SOURCES_HINT),
            StripPanel::Timeline => Some(controller.timeline_detail()),
        };
        s.filter(|s| !s.is_empty()).map(SQL10n::string)
    }

    fn is_enabled(
        controller: &ColorGradeController,
        _session: &EditorSession,
        _clipboard: &ColorClipboard,
        b: StripButton,
    ) -> bool {
        match b {
            StripButton::AddStep => controller.model().is_some_and(|m| m.graph().is_some()),
            _ => true,
        }
    }

    fn icon(b: StripButton) -> SQIcon {
        match b {
            StripButton::AddStep => SQIcon::Plus,
            StripButton::Mode => SQIcon::Stack,
            StripButton::Sequence | StripButton::Fit => SQIcon::ChevronDown,
            StripButton::TimelineMore => SQIcon::Ellipsis,
            StripButton::Simple => SQIcon::ToolMask,
            StripButton::Pro => SQIcon::SlidersHorizontal,
            StripButton::More => SQIcon::Ellipsis,
        }
    }

    /// The Mac `ColorGradeTools` tips.
    fn tip(b: StripButton) -> &'static str {
        match b {
            StripButton::AddStep => "Add a Step after the selected one",
            StripButton::Sequence => "Switch between the open sequences",
            StripButton::Mode => "Normal or Fast Cut editing",
            StripButton::Fit => "Zoom and track height",
            StripButton::TimelineMore => "Tracks, view, Copy Grade and Paste Grade",
            StripButton::Simple | StripButton::Pro => {
                "Simple: the guided controls. Pro: the Color Graph of Steps. The other grade keeps its values."
            }
            StripButton::More => "More actions",
        }
    }

    /// Room the dock leaves at the strip's right end (`ShellDock.stripTools`).
    pub fn width(controller: &ColorGradeController, p: StripPanel, measure: &dyn Fn(&str) -> f64) -> f64 {
        // shortcut: the measured Fit label rides a thread-local so the static `frames` (many callers) place the button as
        // wide as `width` reserved; the dock measures here before it asks for frames. Upgrade: pass the measure to `frames`.
        FIT_LABEL_WIDTH.with(|w| w.set(measure(&SQL10n::string("Fit"))));
        let bs = Self::buttons(p);
        let buttons = if bs.is_empty() {
            0.0
        } else {
            bs.iter().map(|b| Self::width_of(*b)).sum::<f64>() + (bs.len() as f64 - 1.0) * Self::BUTTON_GAP
                - if bs.contains(&StripButton::Simple) { Self::BUTTON_GAP } else { 0.0 }
                + if p == StripPanel::ColorInspector { Self::COLOR_SEGMENT_GAP - Self::BUTTON_GAP } else { 0.0 }
        };
        let text = Self::detail(controller, p).map_or(0.0, |d| (measure(&d).ceil() + 2.0).min(Self::DETAIL_MAX))
            + if controller.legend().is_some() && p != StripPanel::ColorInspector { Self::SWATCH_ROOM } else { 0.0 };
        let gap = if buttons > 0.0 && text > 0.0 { Self::DETAIL_GAP } else { 0.0 };
        buttons
            + text
            + gap
            + if p == StripPanel::ColorInspector { Self::COLOR_RIGHT } else { Self::RIGHT }
            + if text > 0.0 { Self::DETAIL_GAP } else { 0.0 }
    }

    /// The buttons' frames, left to right, in window points inside `strip`.
    pub fn frames(p: StripPanel, strip: CGRect) -> Vec<(StripButton, CGRect)> {
        let h = f64::from(metrics::CAPSULE);
        let y = (strip.min_y() + (strip.height - 1.0 - h) / 2.0).round();
        // The Color tab's strip keeps 10 pt after its "..." and 5 pt between the segments and it (the Mac strip).
        let mut x = strip.max_x() - if p == StripPanel::ColorInspector { Self::COLOR_RIGHT } else { Self::RIGHT };
        let mut out: Vec<(StripButton, CGRect)> = Vec::new();
        // A strip narrower than its buttons drops them (Mode, then Fit, then the sequence switch) instead of drawing them
        // past the panel's left edge.
        let mut shown = Self::buttons(p);
        let span = |bs: &[StripButton]| bs.iter().map(|b| Self::width_of(*b) + Self::BUTTON_GAP).sum::<f64>();
        for drop in [StripButton::Mode, StripButton::Fit, StripButton::Sequence] {
            if x - span(&shown) >= strip.min_x() {
                break;
            }
            shown.retain(|b| *b != drop);
        }
        for b in shown.into_iter().rev() {
            let w = Self::width_of(b);
            x -= w;
            out.insert(0, (b, CGRect::new(x, y, w, h)));
            // The two grade segments touch (one track); every other button keeps its gap.
            x -= if b == StripButton::Pro {
                0.0
            } else if b == StripButton::More && p == StripPanel::ColorInspector {
                Self::COLOR_SEGMENT_GAP
            } else {
                Self::BUTTON_GAP
            };
        }
        out
    }

    fn button_at(p: StripPanel, strip: CGRect, q: CGPoint) -> Option<StripButton> {
        Self::frames(p, strip).into_iter().find(|f| f.1.contains(q)).map(|f| f.0)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn draw(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        controller: &ColorGradeController,
        session: &EditorSession,
        clipboard: &ColorClipboard,
        p: StripPanel,
        strip: CGRect,
        reserved: f64,
    ) {
        let fr = Self::frames(p, strip);
        let seg: Vec<CGRect> =
            fr.iter().filter(|f| matches!(f.0, StripButton::Simple | StripButton::Pro)).map(|f| f.1).collect();
        if let (Some(first), Some(last)) = (seg.first(), seg.last()) {
            c.stone_segment_track(union(first, last), Touch::default(), t);
        }
        for (b, r) in &fr {
            if matches!(b, StripButton::Simple | StripButton::Pro) {
                let pro = controller.model().is_some_and(|m| m.shown_grade() == ActiveGrade::Pro);
                let on = pro == (*b == StripButton::Pro);
                // The picked segment sits 1 pt inside the 22 pt track (the Mac SQSegmented).
                let pick = r.inset_by(0.0, 1.0);
                let touch = Touch { hovering: self.hover == Some((p, *b)), ..Touch::default() };
                c.stone_segment(pick, on, touch, t);
                let title = SQL10n::string(if *b == StripButton::Pro { "Pro" } else { "Simple" });
                let tw = c.size_of(&title, Self::FONT_SIZE, 0).width.ceil();
                // Text only; Pro carries the flask after its name (Pro grading is experimental, redesign R4d).
                let mark = if *b == StripButton::Pro && sq_draw::experimental::prefs().shows_mark() {
                    sq_draw::experimental::ICON_SIZE + 4.0
                } else {
                    0.0
                };
                let x = r.mid_x() - (tw + mark) / 2.0;
                c.draw_text_in(
                    &title,
                    CGRect::new(x, r.min_y(), tw + 2.0, r.height),
                    Self::FONT_SIZE,
                    if on { t.label() } else { t.label2() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
                if mark > 0.0 {
                    let o = CGPoint::new(x + tw + 4.0, r.mid_y() - sq_draw::experimental::ICON_SIZE / 2.0);
                    c.experimental_badge(o, sq_draw::experimental::ExperimentalMark::Icon, t);
                }
                continue;
            }
            if matches!(b, StripButton::Sequence | StripButton::Mode | StripButton::Fit) {
                self.draw_dropdown(c, t, p, *b, *r);
                continue;
            }
            let on = Self::is_enabled(controller, session, clipboard, *b);
            if on && self.pressed == Some((p, *b)) {
                c.stone_button(*r, ButtonKind::Quiet, Touch { pressed: true, ..Touch::default() }, t);
            } else if on && self.hover == Some((p, *b)) {
                c.stone_button(*r, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
            }
            c.draw_icon(
                Self::icon(*b),
                CGPoint::new(r.mid_x() - 6.0, r.mid_y() - 6.0),
                12.0,
                if on { t.label2() } else { t.label3().with_alpha(0.5) },
                None,
            );
        }
        let Some(text) = Self::detail(controller, p) else { return };
        let right = fr.first().map_or(strip.max_x() - Self::RIGHT, |f| f.1.min_x() - Self::DETAIL_GAP);
        let left = (strip.max_x() - reserved + Self::DETAIL_GAP).max(strip.min_x());
        let w = (right - left).max(0.0);
        if w <= 8.0 {
            return;
        }
        let tw = (c.size_of(&text, Self::FONT_SIZE, 0).width.ceil() + 2.0).min(w);
        if controller.legend().is_some() && p != StripPanel::ColorInspector {
            // The yellow frame's swatch (12 x 9, radius 2, a 1.5 pt ring) before the words.
            let sw = CGRect::new(
                right - tw - Self::SWATCH_ROOM,
                (strip.min_y() + (strip.height - 1.0 - 9.0) / 2.0).round(),
                12.0,
                9.0,
            );
            c.stroke_rounded(sw.inset_by(0.75, 0.75), 2.0, 1.5, t.yellow());
        }
        c.draw_text(
            &text,
            CGPoint::new(right - tw, (strip.min_y() + (strip.height - 1.0 - Self::FONT_SIZE - 4.0) / 2.0).round()),
            Self::FONT_SIZE,
            t.label3(),
            tw,
            0,
        );
    }

    /// A flat popup like the timeline bar's: hover fill, label 10 pt in, chevron 8 pt from the right (Mode: stack icon first).
    fn draw_dropdown(&self, c: &mut Canvas, t: &DrawTheme, p: StripPanel, b: StripButton, r: CGRect) {
        let hot = self.hover == Some((p, b)) || self.pressed == Some((p, b));
        c.stone_button(r, ButtonKind::Quiet, Touch { hovering: hot, ..Touch::default() }, t);
        let (label, icon) = match b {
            StripButton::Sequence => (self.sequence.clone(), false),
            StripButton::Mode => (SQL10n::string(if self.fast_cut { "Fast Cut" } else { "Normal" }), true),
            _ => (SQL10n::string("Fit"), false),
        };
        let mut x = r.min_x() + 8.0;
        if icon {
            c.draw_icon(SQIcon::Stack, CGPoint::new(x, r.mid_y() - 6.0), 12.0, t.label2(), None);
            x += 16.0;
        }
        // The chevron follows the label (the board's dropdowns hug their text); a long name is cut before it.
        let room = (r.max_x() - 8.0 - 12.0 - 4.0 - x).max(0.0);
        let label = c.truncated_name(&label, Self::FONT_SIZE, 0, room).shown;
        let tw = (c.size_of(&label, Self::FONT_SIZE, 0).width.ceil() + 1.0).min(room);
        // The r8 flat drop-down (`.dd`): text-secondary, text-primary while hovered or open, a 12 pt chevron in the same ink.
        let ink = if hot { t.label() } else { t.label2() };
        c.draw_text_in(&label, CGRect::new(x, r.min_y(), tw, r.height), Self::FONT_SIZE, ink, TextAlign::Left, 0.0, 0);
        c.draw_icon(SQIcon::ChevronDown, CGPoint::new(x + tw + 2.0, r.mid_y() - 6.0), 12.0, ink, None);
    }

    pub fn mouse_moved(&mut self, p: Option<StripPanel>, strip: Option<CGRect>, q: CGPoint) {
        self.hover = match (p, strip) {
            (Some(p), Some(strip)) => Self::button_at(p, strip, q).map(|b| (p, b)),
            _ => None,
        };
    }

    /// The tip under the pointer.
    pub fn help(controller: &ColorGradeController, p: StripPanel, strip: CGRect, q: CGPoint) -> Option<String> {
        if let Some(b) = Self::button_at(p, strip, q) {
            return Some(SQL10n::string(Self::tip(b)));
        }
        Self::detail(controller, p)
    }

    /// A press in the tools: true when it hit a button (it acts on release over the same button).
    pub fn mouse_down(&mut self, p: StripPanel, strip: CGRect, q: CGPoint) -> bool {
        let Some(b) = Self::button_at(p, strip, q) else { return false };
        self.pressed = Some((p, b));
        true
    }

    #[allow(clippy::too_many_arguments)]
    pub fn mouse_up(
        &mut self,
        controller: &mut ColorGradeController,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        p: StripPanel,
        strip: CGRect,
        q: CGPoint,
        add_menu_items: Option<Vec<SQMenuItem>>,
        more_menu_items: Vec<SQMenuItem>,
    ) {
        let Some((pp, b)) = self.pressed.take() else { return };
        if pp != p || Self::button_at(p, strip, q) != Some(b) {
            return;
        }
        let Some(r) = Self::frames(p, strip).into_iter().find(|f| f.0 == b).map(|f| f.1) else { return };
        self.press(controller, session, clipboard, b, r, add_menu_items, more_menu_items);
    }

    /// The button's action; a refused one beeps.
    #[allow(clippy::too_many_arguments)]
    fn press(
        &mut self,
        controller: &mut ColorGradeController,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        b: StripButton,
        anchor: CGRect,
        add_menu_items: Option<Vec<SQMenuItem>>,
        more_menu_items: Vec<SQMenuItem>,
    ) {
        match b {
            StripButton::Sequence => self.dropdowns.push((StripDropdown::Sequence, anchor)),
            StripButton::Mode => self.dropdowns.push((StripDropdown::Mode, anchor)),
            StripButton::Fit => self.dropdowns.push((StripDropdown::Fit, anchor)),
            StripButton::TimelineMore => self.dropdowns.push((StripDropdown::More, anchor)),
            StripButton::Simple => controller.choose_grade(session, clipboard, false),
            StripButton::Pro => controller.choose_grade(session, clipboard, true),
            StripButton::More => {
                if !more_menu_items.is_empty() {
                    self.menus.push(StripMenuRequest { items: more_menu_items, anchor });
                }
            }
            StripButton::AddStep => match add_menu_items {
                Some(items) if !items.is_empty() => self.menus.push(StripMenuRequest { items, anchor }),
                _ => controller.run_menu_command(session, clipboard, ColorMenuCommand::Beep),
            },
        }
    }
}

/// Keeps `InputModifiers` in the public surface for hosts that forward presses with modifiers.
pub type PressModifiers = InputModifiers;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_fit_label_widens_the_strip_button_instead_of_being_cut() {
        assert_eq!(ColorStripToolsDraw::fit_button_width(14.0), 46.0, "English keeps the old width");
        let wide = ColorStripToolsDraw::fit_button_width(58.0);
        assert!(wide >= 58.0 + 8.0 + 2.0 + 12.0 + 8.0, "German Einpassen fits with its chevron ({wide})");
        FIT_LABEL_WIDTH.with(|w| w.set(58.0));
        let fit = ColorStripToolsDraw::frames(StripPanel::Timeline, CGRect::new(0.0, 0.0, 500.0, 31.0))
            .into_iter()
            .find(|f| f.0 == StripButton::Fit)
            .map(|f| f.1.width);
        assert_eq!(fit, Some(wide), "the frames use the measured width");
        FIT_LABEL_WIDTH.with(|w| w.set(0.0));
    }

    #[test]
    fn the_header_lays_out_right_to_left() {
        let h = ColorViewerHeaderDraw::new();
        let fr = h.frames();
        assert_eq!(fr.len(), 4);
        assert_eq!(fr[0].0, ViewerHeaderControl::More);
        assert_eq!(fr[0].1.max_x(), 600.0 - 8.0);
        let xs: Vec<f64> = fr[1..].iter().map(|f| f.1.min_x()).collect();
        assert!(xs[0] > xs[1] && xs[1] > xs[2]);
        assert_eq!(fr[3].0, ViewerHeaderControl::Compare(ColorCompareMode::Before));
        let track = ColorViewerHeaderDraw::track_rect(&fr);
        assert!(track.is_some_and(|t| t.min_x() == fr[3].1.min_x() - 1.0));
    }

    #[test]
    fn a_press_in_a_segment_column_counts_over_the_full_height() {
        let h = ColorViewerHeaderDraw::new();
        let fr = h.frames();
        let split = fr[1].1;
        assert_eq!(
            h.control_at(CGPoint::new(split.mid_x(), 1.0)),
            Some(ViewerHeaderControl::Compare(ColorCompareMode::Split))
        );
        let before = fr[3].1;
        assert_eq!(
            h.control_at(CGPoint::new(before.min_x() - 0.5, 5.0)),
            Some(ViewerHeaderControl::Compare(ColorCompareMode::Before))
        );
        assert_eq!(h.control_at(CGPoint::new(2.0, 5.0)), None);
        assert_eq!(h.control_at(CGPoint::new(fr[0].1.mid_x(), fr[0].1.mid_y())), Some(ViewerHeaderControl::More));
    }

    #[test]
    fn strip_buttons_per_panel() {
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::Steps).len(), 4);
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::Sources).len(), 4);
        let fr = ColorStripToolsDraw::frames(StripPanel::ColorInspector, CGRect::new(0.0, 0.0, 400.0, 31.0));
        assert_eq!(fr.len(), 3);
        assert_eq!(fr[2].1.max_x(), 390.0);
        // The two grade segments touch.
        assert_eq!(fr[0].1.max_x(), fr[1].1.min_x());
        assert_eq!(fr[1].1.max_x() + 5.0, fr[2].1.min_x());
    }

    #[test]
    fn the_lower_strips_say_which_file_their_yellow_frames_belong_to() {
        use sq_core_time::{Id, SequentialIds};
        let project = sq_core_model::Project::new(Id::from_u128(1), "P", Vec::new(), Vec::new());
        let session = sq_editor_session::EditorSession::new(
            project,
            sq_editor_session::SessionDeps::headless(std::env::temp_dir().join("sq-color-strip-tests")),
        );
        let mut c = ColorGradeController::new(&session, Box::new(|| Box::new(SequentialIds::default())));
        assert_eq!(ColorStripToolsDraw::detail(&c, StripPanel::Steps), None);
        assert_eq!(
            ColorStripToolsDraw::detail(&c, StripPanel::Timeline).as_deref(),
            Some(ColorGradeController::TIMELINE_HINT)
        );
        c.set_legend(Some("C2171.MP4".to_string()));
        for p in [StripPanel::Steps, StripPanel::Sources, StripPanel::Timeline] {
            assert_eq!(ColorStripToolsDraw::detail(&c, p).as_deref(), Some("Uses of C2171.MP4"));
        }
        assert_eq!(ColorStripToolsDraw::detail(&c, StripPanel::ColorInspector), None);
    }

    #[test]
    fn strip_frames_keep_two_points_between_plain_buttons() {
        let fr = ColorStripToolsDraw::frames(StripPanel::Steps, CGRect::new(10.0, 0.0, 300.0, 31.0));
        assert_eq!(fr[3].1.max_x(), 310.0 - 8.0);
        assert_eq!(fr[2].1.max_x() + 2.0, fr[3].1.min_x());
    }

    #[test]
    fn a_narrow_strip_keeps_every_button_inside_it() {
        for panel in [StripPanel::Steps, StripPanel::Sources, StripPanel::Timeline] {
            for width in (90..=400).step_by(7) {
                let strip = CGRect::new(40.0, 0.0, f64::from(width), 31.0);
                for (b, f) in ColorStripToolsDraw::frames(panel, strip) {
                    assert!(f.min_x() >= strip.min_x(), "{panel:?} {b:?} at width {width} starts at {}", f.min_x());
                }
            }
        }
    }

    #[test]
    fn a_press_must_end_on_the_same_button() {
        let mut t = ColorStripToolsDraw::new();
        let strip = CGRect::new(0.0, 0.0, 300.0, 31.0);
        let fr = ColorStripToolsDraw::frames(StripPanel::Sources, strip);
        let c = CGPoint::new(fr[0].1.mid_x(), fr[0].1.mid_y());
        assert!(t.mouse_down(StripPanel::Sources, strip, c));
        assert!(!t.mouse_down(StripPanel::Sources, strip, CGPoint::new(1.0, 1.0)));
        t.mouse_moved(Some(StripPanel::Sources), Some(strip), c);
        assert_eq!(t.hover, Some((StripPanel::Sources, StripButton::Sequence)));
        t.mouse_moved(None, None, c);
        assert_eq!(t.hover, None);
    }
}

#[cfg(test)]
mod strip_tool_tests {
    use super::*;

    #[test]
    fn the_strip_buttons_per_panel_match_the_mac_strips() {
        use StripButton::{Fit, Mode, More, Pro, Sequence, Simple, TimelineMore};
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::ColorInspector), vec![Simple, Pro, More]);
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::Steps), vec![Sequence, Mode, Fit, TimelineMore]);
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::Sources), vec![Sequence, Mode, Fit, TimelineMore]);
        assert_eq!(ColorStripToolsDraw::buttons(StripPanel::Timeline), vec![Sequence, Mode, Fit, TimelineMore]);
    }
}
