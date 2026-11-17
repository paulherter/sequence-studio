// Swift: InspectorControls.swift
//! Control tokens and drawing of the portable inspector controls, translated from the Mac views (ring, navigation,
//! checkbox, popup, slider, well).

use super::text_edit_state::TextEditState;
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::glyph_atlas::TextAlign;
use crate::stone::{ButtonKind, Touch};
use crate::theme::{self, DrawTheme, color};
use crate::ui_cx::UiCx;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::keyframe_control_state::{KeyframeControlState, ScrubKeyframeState};
use sq_uikit::redesign_tokens::color as tk;
use sq_uikit::redesign_tokens::radius as rd;
use sq_uikit::sqicon::SQIcon;

/// Control tokens of the portable inspector (`Theme.Metrics` / `Theme.State` / `Theme.Radius` of the Mac controls).
/// shortcut: literals of the Mac tokens at UI scale 1 (Theme is AppKit); the token tests keep them in step. Upgrade when
/// the uikit tokens carry them.
pub struct InspectorTokens;

impl InspectorTokens {
    /// Height of a field capsule.
    pub const CAPSULE: f32 = 22.0;
    /// Checkbox side.
    pub const CHECKBOX: f64 = 14.0;
    /// Checkbox corner radius.
    pub const CHECKBOX_RADIUS: f64 = 4.0;
    /// Control corner radius.
    pub const CONTROL_RADIUS: f64 = 6.0;
    /// Inner corner radius.
    pub const INNER_RADIUS: f64 = 4.0;
    /// Keyboard focus line width.
    pub const FOCUS_LINE_WIDTH: f64 = 1.5;
    /// Alpha of a disabled control.
    pub const DISABLED_ALPHA: f32 = 0.4;
    /// Slider track height.
    pub const SLIDER_TRACK: f64 = 4.0;
    /// Slider knob width.
    pub const SLIDER_KNOB: f64 = 12.0;
    /// Slider knob height.
    pub const SLIDER_KNOB_HEIGHT: f64 = 12.0;
    /// Slider corner radius.
    pub const SLIDER_RADIUS: f64 = 2.0;
    /// Slider knob ring radius.
    pub const SLIDER_RING_RADIUS: f64 = 3.0;
    /// Keyframe ring (KeyframeToggleView): 10 pt diamond.
    pub const RING_DIAMOND: f64 = 10.0;
    /// Keyframe ring dot radius.
    pub const RING_DOT: f64 = 1.2;
    /// Controls animation switch (`ControlsMetrics.toggleSide`).
    pub const SWITCH_SIDE: f64 = 7.0;
    /// Key-navigation chevrons (`IconButton.symbolSize`).
    pub const NAV_ICON: f64 = 10.0;

    /// Corner radius of a control body (6 pt, never more than half the height).
    pub fn radius(r: CGRect) -> f64 {
        Self::CONTROL_RADIUS.min(r.height / 2.0)
    }
}

impl DrawTheme {
    /// The number field / popup body: the artifact `--well`.
    pub fn field(&self) -> Color {
        self.well()
    }
    /// `Theme.Colors.fieldEdgeHover`.
    pub fn field_edge_hover(&self) -> Color {
        self.ink_fill(0.18)
    }
    /// `Theme.Colors.accentTint`: an editing field, a selected row.
    pub fn accent_tint(&self) -> Color {
        self.token(tk::ACCENT_ZONE)
    }
    /// The keyboard focus line.
    pub fn focus_line(&self) -> Color {
        self.accent()
    }
    /// `Theme.Colors.selection` / `Theme.Selection.fill`: a selected row (ink at .14 in both appearances).
    pub fn selection(&self) -> Color {
        self.token(tk::RAISED)
    }
    /// `Theme.Colors.graphPane`: an opened curve row and its pane.
    pub fn graph_pane(&self) -> Color {
        Color::WHITE.with_alpha(0.03)
    }
    /// `Theme.Colors.fieldEdge`: a plot's grid and baseline.
    pub fn field_edge(&self) -> Color {
        self.token(tk::EDGE_DARK)
    }
    /// `Theme.Colors.red`: a curve channel.
    pub fn red(&self) -> Color {
        color(self.palette.red)
    }
    /// The warning color.
    pub fn warning(&self) -> Color {
        color(self.palette.warning)
    }
    /// `Theme.Colors.green`: a curve channel.
    pub fn green(&self) -> Color {
        self.token(tk::GREEN)
    }
    /// `Theme.Palette.channelBlue`: a curve channel.
    pub fn channel_blue(&self) -> Color {
        Color::hex(0x4D8CFF, 1.0)
    }
    /// `Theme.Palette.channelDots`: master, red, green, blue.
    pub fn channel_dots(&self) -> [Color; 4] {
        [Color::WHITE.with_alpha(0.9), self.red(), self.green(), self.channel_blue()]
    }
    /// `Theme.Colors.keyframe`: a key glyph in the lanes.
    pub fn keyframe(&self) -> Color {
        color(self.palette.keyframe)
    }
    /// A Magic mask's tracked frame (label3).
    pub fn keyframe_tracked(&self) -> Color {
        self.label3()
    }
    /// `Theme.Colors.graphGrid`: the speed graph's baseline and dashed guides.
    pub fn graph_grid(&self) -> Color {
        Color::WHITE.with_alpha(0.06)
    }
    /// `Theme.Colors.graphHandleLine`: a handle's stem.
    pub fn graph_handle_line(&self) -> Color {
        Color::WHITE.with_alpha(0.60)
    }
    /// `Theme.Palette.graphCurve`: the third and later rows of one speed graph.
    pub fn graph_curve(&self) -> [Color; 12] {
        [
            0xFF8FC0, 0xFF5A4E, 0x3FD0E0, 0x5FE3B8, 0xC58AF9, 0x5FD068, 0xFF9F0A, 0xFFD60A, 0x64B5FF, 0x9FD98A,
            0xE0C080, 0xB0B0B0,
        ]
        .map(|h| Color::hex(h, 1.0))
    }
    /// `Theme.OnPicture.shadow`: the dark edge around a handle.
    pub fn handle_shadow(&self) -> Color {
        Color::BLACK.with_alpha(0.5)
    }
}

/// `col` with its alpha multiplied by `a`.
pub(crate) fn faded(col: Color, a: f32) -> Color {
    col.with_alpha(col.a * a)
}

/// Direction of a chevron.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    /// Points left.
    Left,
    /// Points right.
    Right,
    /// Points down.
    Down,
    /// Points up.
    Up,
}

/// State of the SQ checkbox.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CheckState {
    /// Unchecked.
    Off,
    /// Checked.
    On,
    /// Mixed.
    Mixed,
}

/// Drawing of the inspector controls, translated from the Mac views (ring, navigation, checkbox, popup, slider, well).
pub enum InspectorDraw {}

impl InspectorDraw {
    /// Keyboard focus (sq.css `.foc`): inner 1.5 pt accent line.
    pub fn focus_line(c: &mut Canvas, r: CGRect, radius: f64, t: &DrawTheme) {
        let w = InspectorTokens::FOCUS_LINE_WIDTH;
        c.stroke_rounded(r.inset_by(w, w), (radius - w).max(0.0), w, t.focus_line());
    }

    /// A diamond `size` pt corner to corner (KeyframeToggleView.diamondPath).
    pub fn diamond(center: CGPoint, size: f64) -> [CGPoint; 4] {
        let h = size / 2.0;
        [
            CGPoint { x: center.x, y: center.y - h },
            CGPoint { x: center.x + h, y: center.y },
            CGPoint { x: center.x, y: center.y + h },
            CGPoint { x: center.x - h, y: center.y },
        ]
    }

    /// The animate ring of a keyframable row (KeyframeToggleView.drawRing).
    pub fn ring(c: &mut Canvas, state: ScrubKeyframeState, hovering: bool, p: CGPoint, t: &DrawTheme) {
        let d = Self::diamond(p, InspectorTokens::RING_DIAMOND);
        let r = InspectorTokens::RING_DOT;
        let dot = CGRect::new(p.x - r, p.y - r, 2.0 * r, 2.0 * r);
        match state {
            ScrubKeyframeState::None => {
                let tint = if hovering { t.label2() } else { t.label3() };
                c.stroke_polygon(&d, 1.2, tint);
                c.fill_ellipse(dot, tint);
            }
            ScrubKeyframeState::Between => {
                c.stroke_polygon(&d, 1.2, t.accent());
                c.fill_ellipse(dot, t.accent());
            }
            ScrubKeyframeState::OnKey => {
                c.fill_polygon(&d, t.accent());
                c.stroke_polygon(&d, 1.2, t.accent());
                c.fill_ellipse(dot, Color::WHITE);
            }
        }
    }

    /// The animation switch of a Controls row (AnimateDiamondView `.an`): a 7 pt square turned 45 degrees; a hollow 1.2 pt
    /// outline while the parameter is static, filled accent while it has keys.
    pub fn animate_switch(c: &mut Canvas, animated: bool, hovering: bool, p: CGPoint, t: &DrawTheme) {
        let side = InspectorTokens::SWITCH_SIDE;
        let h = side * 2.0_f64.sqrt() / 2.0;
        if animated {
            c.fill_polygon(&Self::diamond(p, 2.0 * h), t.label());
        } else {
            let inner = (side - 1.2) * 2.0_f64.sqrt();
            c.stroke_polygon(&Self::diamond(p, inner), 1.2, if hovering { t.label2() } else { t.label3() });
        }
    }

    /// Prev / key / next in three equal slots (KeyframeNavigationView), `rect` = the navigation frame. Like the Mac
    /// IconButtons: caret chevrons (10 pt), the key diamond (`KeyframeToggleView.diamondImage`: 9 pt, 1.1 pt line, a
    /// 1.1 pt dot, cut out of the fill on a key; `behind` = the row color showing through), disabled ones dimmed.
    pub fn navigation(
        c: &mut Canvas,
        s: &KeyframeControlState,
        rect: CGRect,
        enabled: bool,
        behind: Option<Color>,
        t: &DrawTheme,
    ) {
        if !s.shows_navigation {
            return;
        }
        let w = rect.width / 3.0;
        let dim = |col: Color, on: bool| if on && enabled { col } else { faded(col, InspectorTokens::DISABLED_ALPHA) };
        let prev = CGRect::new(rect.min_x(), rect.min_y(), w, rect.height);
        let next = CGRect::new(rect.min_x() + 2.0 * w, rect.min_y(), w, rect.height);
        let side = InspectorTokens::NAV_ICON;
        for (r, icon, on) in
            [(prev, SQIcon::ChevronLeft, s.can_go_previous), (next, SQIcon::ChevronRight, s.can_go_next)]
        {
            let at = CGPoint { x: (r.mid_x() - side / 2.0).round(), y: (r.mid_y() - side / 2.0).round() };
            c.draw_icon(icon, at, side, dim(t.label2(), on), None);
        }
        let mid = CGPoint { x: rect.min_x() + 1.5 * w, y: rect.mid_y() };
        let d = Self::diamond(mid, 9.0);
        let kt = dim(if s.key_is_on { t.accent() } else { t.label3() }, s.can_toggle_key);
        let dot_r = 1.1;
        let dot = CGRect::new(mid.x - dot_r, mid.y - dot_r, 2.0 * dot_r, 2.0 * dot_r);
        if s.key_is_on {
            c.fill_polygon(&d, kt);
            c.stroke_polygon(&d, 1.1, kt);
            c.fill_ellipse(dot, behind.unwrap_or_else(|| t.panel()));
        } else {
            c.stroke_polygon(&d, 1.1, kt);
            c.fill_ellipse(dot, kt);
        }
    }

    /// A chevron (`SQIcon` caret): `size` is the glyph's long side; the Phosphor caret fills two thirds of its box, so the box is
    /// 1.5 times larger, centered in `rect`.
    pub fn chevron(c: &mut Canvas, rect: CGRect, direction: Direction, color: Color, size: f64) {
        let boxed = size * 1.5;
        let icon = match direction {
            Direction::Left => SQIcon::ChevronLeft,
            Direction::Right => SQIcon::ChevronRight,
            Direction::Down => SQIcon::ChevronDown,
            Direction::Up => SQIcon::ChevronUp,
        };
        c.draw_icon(icon, CGPoint { x: rect.mid_x() - boxed / 2.0, y: rect.mid_y() - boxed / 2.0 }, boxed, color, None);
    }

    /// The SQ checkbox (SQCheckbox.draw): 14 pt box, 4 pt corners; on = accent fill and a white check, mixed = a dash.
    #[allow(clippy::too_many_arguments)]
    pub fn checkbox(
        c: &mut Canvas,
        s: CheckState,
        boxed: CGRect,
        hovering: bool,
        pressed: bool,
        enabled: bool,
        focused: bool,
        t: &DrawTheme,
    ) {
        let a = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        let touch = Touch { hovering, pressed, disabled: !enabled, focused };
        match s {
            CheckState::On => c.stone_checkbox(boxed, true, touch, t),
            CheckState::Off => c.stone_checkbox(boxed, false, touch, t),
            CheckState::Mixed => {
                c.stone_checkbox(boxed, false, touch, t);
                c.fill(
                    CGRect::new(boxed.min_x() + boxed.width * 0.27, boxed.mid_y() - 0.75, boxed.width * 0.46, 1.5),
                    t.label().with_alpha(a),
                );
            }
        }
    }

    /// The SQ popup button (SQPopup): field body, title left, chevron-down right; `plain` = no body at rest (grid rows).
    #[allow(clippy::too_many_arguments)]
    pub fn popup(
        c: &mut Canvas,
        title: &str,
        rect: CGRect,
        hovering: bool,
        open: bool,
        enabled: bool,
        plain: bool,
        max_height: f64,
        font_size: Option<f64>,
        t: &DrawTheme,
    ) {
        let h = max_height.min(rect.height);
        let boxed = CGRect::new(rect.min_x(), rect.min_y() + ((rect.height - h) / 2.0).round(), rect.width, h);
        let a = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        if plain {
            // A plain popup (grid rows) is a quiet button: nothing at rest, the hover fill, the press look while open.
            let kind = ButtonKind::Quiet;
            let touch = Touch { hovering, pressed: open, disabled: !enabled, focused: false };
            c.stone_button(boxed, kind, touch, t);
        } else {
            // The sunken dropdown (`Field/Dropdown/Sunken`): a well, the accent ring while open.
            let touch = Touch { hovering, pressed: false, disabled: !enabled, focused: false };
            c.stone_field(boxed, f64::from(rd::FIELD), open, touch, t);
        }
        let size = font_size.unwrap_or(theme::type_size::BODY as f64);
        let chevron_w = 16.0;
        // A title wider than the popup ends in an ellipsis instead of running under the chevron or past the window edge.
        let text_w = (boxed.width - 8.0 - chevron_w).max(0.0);
        let title = c.ellipsized(title, size, 0, text_w);
        c.draw_text_in(
            &title,
            CGRect::new(boxed.min_x() + 8.0, boxed.min_y(), text_w, boxed.height),
            size,
            faded(t.label(), a),
            TextAlign::Left,
            0.0,
            0,
        );
        Self::popup_chevron(c, CGRect::new(boxed.max_x() - 7.0 - 7.0, boxed.min_y(), 7.0, boxed.height), t, a);
    }

    /// `SQPopup.drawChevron`: a 1.2 pt round stroke in a 7 pt box, `#999` on a dark palette (the chevron is 4.6 wide, 2.3 tall).
    pub fn popup_chevron(c: &mut Canvas, r: CGRect, t: &DrawTheme, alpha: f32) {
        let base = t.label3();
        let m = r.mid_y();
        c.stroke_polyline(
            &[
                CGPoint { x: r.min_x() + 1.2, y: m - 1.1 },
                CGPoint { x: r.min_x() + 3.5, y: m + 1.2 },
                CGPoint { x: r.min_x() + 5.8, y: m - 1.1 },
            ],
            1.2,
            faded(base, alpha),
        );
    }

    /// The SQ slider (`Slider/Fill`): 4 pt sunken track, `text3` (gray) fill up to the knob, 12 pt ball knob.
    /// `origin` is the fraction the fill starts from (0 = the left end; 0.5 for a bipolar slider such as Pan, art.html 21).
    pub fn slider(c: &mut Canvas, fraction: f64, origin: f64, rect: CGRect, enabled: bool, t: &DrawTheme) {
        let k = InspectorTokens::SLIDER_KNOB;
        let x0 = rect.min_x() + k / 2.0;
        let x1 = rect.max_x() - k / 2.0;
        let f = fraction.clamp(0.0, 1.0);
        let kx = x0 + (x1 - x0) * f;
        let touch = Touch { hovering: false, pressed: false, disabled: !enabled, focused: false };
        let ox = x0 + (x1 - x0) * origin.clamp(0.0, 1.0);
        let fill = if origin > 0.0 { (ox.min(kx), ox.max(kx)) } else { (rect.min_x(), kx) };
        c.stone_slider_track(rect, Some(fill), touch, t);
        c.stone_slider_knob(kx, rect.mid_y(), false, touch, t);
    }

    /// Fraction of a slider for a pointer at `x` (inverse of `slider`).
    pub fn slider_fraction(x: f64, rect: CGRect) -> f64 {
        let k = InspectorTokens::SLIDER_KNOB;
        let x0 = rect.min_x() + k / 2.0;
        let x1 = rect.max_x() - k / 2.0;
        if x1 <= x0 {
            return 0.0;
        }
        ((x - x0) / (x1 - x0)).clamp(0.0, 1.0)
    }

    /// A color swatch (SQColorWell): the color in a rounded box with a hairline edge.
    pub fn color_well(c: &mut Canvas, col: Color, rect: CGRect, hovering: bool, t: &DrawTheme) {
        let h = (InspectorTokens::CAPSULE as f64 - 4.0).min(rect.height);
        let boxed = CGRect::new(rect.min_x(), rect.min_y() + ((rect.height - h) / 2.0).round(), rect.width, h);
        c.fill_rounded(boxed, InspectorTokens::INNER_RADIUS, col);
        c.stroke_rounded(
            boxed.inset_by(0.25, 0.25),
            InspectorTokens::INNER_RADIUS,
            0.5,
            if hovering { t.field_edge_hover() } else { t.track_header_line() },
        );
    }

    /// The text of an open editor: selection tint, text, caret (1 pt accent bar). The caret goes to `cx.requests`.
    #[allow(clippy::too_many_arguments)]
    pub fn edit_text(
        c: &mut Canvas,
        e: &TextEditState,
        r: CGRect,
        size: f64,
        color: Color,
        align_right: bool,
        t: &DrawTheme,
        cx: &mut UiCx,
    ) {
        let s = e.string();
        let w = c.size_of(&s, size, 0).width;
        let x0 = if align_right { r.min_x().max(r.max_x() - w) } else { r.min_x() };
        let x_at = |c: &Canvas, i: usize| x0 + c.size_of(&e.text()[..i].iter().collect::<String>(), size, 0).width;
        let line_h = c.size_of("0", size, 0).height;
        let y = r.mid_y() - line_h / 2.0;
        if e.has_selection() {
            let sel = e.selection();
            // text longer than the field is clipped; so is its selection tint
            let (a, b) = (x_at(c, sel.start).min(r.max_x()), x_at(c, sel.end).min(r.max_x()));
            c.fill(CGRect::new(a, y, b - a, line_h), t.accent().with_alpha(0.45));
        }
        c.save_gstate();
        c.clip_to(r);
        c.draw_text(&s, CGPoint { x: x0, y }, size, color, f64::INFINITY, 0);
        c.restore_gstate();
        let caret_x = x_at(c, if e.has_selection() { e.selection().start } else { e.caret() }).min(r.max_x() - 1.0);
        let caret = CGRect::new(caret_x, y, 1.0, line_h);
        if !e.has_selection() {
            c.fill(caret, t.accent());
        }
        cx.requests.caret = Some(c.px(caret));
    }

    /// Caret index for a click at `x` in an editor drawn by `edit_text`.
    pub fn caret_index(c: &Canvas, e: &TextEditState, x: f64, r: CGRect, size: f64, align_right: bool) -> usize {
        let w = Self::line_width(c, &e.string(), size);
        let x0 = if align_right { r.min_x().max(r.max_x() - w) } else { r.min_x() };
        let (mut best, mut best_d) = (0, f64::MAX);
        for i in 0..=e.text().len() {
            let d = (x0 + Self::line_width(c, &e.text()[..i].iter().collect::<String>(), size) - x).abs();
            if d < best_d {
                best = i;
                best_d = d;
            }
        }
        best
    }

    /// Width of `s`; without a glyph atlas (headless tests) an average advance of 0.55 em per character, like
    /// `TextMeasure`, so caret placement stays ordered.
    fn line_width(c: &Canvas, s: &str, size: f64) -> f64 {
        if c.atlas().is_none() { s.chars().count() as f64 * size * 0.55 } else { c.size_of(s, size, 0).width }
    }

    /// The open editor of a multi-line box (the text clip's text box): line `i` sits `i * line_height` below `r.min_y()`;
    /// the selection is tinted per line, the caret is a 1 pt accent bar on its line. Clipped to `r`.
    #[allow(clippy::too_many_arguments)]
    pub fn edit_lines(
        c: &mut Canvas,
        e: &TextEditState,
        r: CGRect,
        line_height: f64,
        size: f64,
        color: Color,
        t: &DrawTheme,
        cx: &mut UiCx,
    ) {
        let starts = e.line_starts();
        let glyph_h = c.size_of("0", size, 0).height;
        let sel = e.selection();
        c.save_gstate();
        c.clip_to(r);
        for (l, &start) in starts.iter().enumerate() {
            let end = if l + 1 < starts.len() { starts[l + 1] - 1 } else { e.text().len() };
            let line: Vec<char> = e.text()[start..end].to_vec();
            let y = r.min_y() + l as f64 * line_height + ((line_height - glyph_h) / 2.0).round();
            let x_at = |c: &Canvas, i: usize| {
                let n = (i - start).min(line.len());
                r.min_x() + Self::line_width(c, &line[..n].iter().collect::<String>(), size)
            };
            if e.has_selection() && sel.start <= end && sel.end >= start {
                let a = sel.start.max(start);
                let b = sel.end.min(end);
                // A selected line break shows as a small tail after the line.
                let tail = if sel.end > end && l + 1 < starts.len() { 4.0 } else { 0.0 };
                let (xa, xb) = (x_at(c, a), x_at(c, b));
                c.fill(CGRect::new(xa, y, xb - xa + tail, glyph_h), t.accent().with_alpha(0.45));
            }
            c.draw_text(&line.iter().collect::<String>(), CGPoint { x: r.min_x(), y }, size, color, f64::INFINITY, 0);
            let at = if e.has_selection() { sel.start } else { e.caret() };
            if at >= start && at <= end {
                let caret = CGRect::new(x_at(c, at), y, 1.0, glyph_h);
                if !e.has_selection() {
                    c.fill(caret, t.accent());
                }
                cx.requests.caret = Some(c.px(caret));
            }
        }
        c.restore_gstate();
    }

    /// Caret index for a click at `p` in an editor drawn by `edit_lines`: the line under `p.y` (clamped), then the
    /// nearest character edge to `p.x` on it.
    pub fn caret_index_at(c: &Canvas, e: &TextEditState, p: CGPoint, r: CGRect, line_height: f64, size: f64) -> usize {
        let starts = e.line_starts();
        let l = (((p.y - r.min_y()) / line_height.max(1.0)).floor() as i64).clamp(0, starts.len() as i64 - 1) as usize;
        let start = starts[l];
        let end = if l + 1 < starts.len() { starts[l + 1] - 1 } else { e.text().len() };
        let line = &e.text()[start..end];
        let (mut best, mut best_d) = (start, f64::MAX);
        for i in 0..=line.len() {
            let d = (r.min_x() + Self::line_width(c, &line[..i].iter().collect::<String>(), size) - p.x).abs();
            if d < best_d {
                best = start + i;
                best_d = d;
            }
        }
        best
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::software::{RgbaImage, SoftwareRenderer, Sources};

    pub(crate) fn render(c: &Canvas, w: usize, h: usize) -> RgbaImage {
        SoftwareRenderer::render(&c.list, w, h, Color::BLACK, &Sources::default())
    }
    fn red(img: &RgbaImage, x: usize, y: usize) -> u8 {
        img.pixels[(y * img.width + x) * 4]
    }
    fn lum(img: &RgbaImage, x: usize, y: usize) -> i32 {
        (0..3).map(|i| img.pixels[(y * img.width + x) * 4 + i] as i32).sum()
    }

    #[test]
    fn animate_switch_is_hollow_when_static_and_solid_when_animated() {
        let t = DrawTheme::default();
        let mut hollow = Canvas::with_size(20.0, 20.0, None, 1.0);
        InspectorDraw::animate_switch(&mut hollow, false, false, CGPoint { x: 10.0, y: 10.0 }, &t);
        let mut solid = Canvas::with_size(20.0, 20.0, None, 1.0);
        InspectorDraw::animate_switch(&mut solid, true, false, CGPoint { x: 10.0, y: 10.0 }, &t);
        let (h, f) = (render(&hollow, 20, 20), render(&solid, 20, 20));
        assert!(lum(&h, 10, 10) == 0 && lum(&h, 10, 5) + lum(&h, 10, 6) > 0);
        assert!(lum(&f, 10, 10) > 0 && lum(&f, 10, 7) > 0);
    }

    #[test]
    fn key_button_cuts_the_dot_out_of_the_filled_diamond() {
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(40.0, 20.0, None, 1.0);
        let s = KeyframeControlState {
            ring: ScrubKeyframeState::OnKey,
            shows_navigation: true,
            can_go_previous: true,
            can_go_next: true,
            can_toggle_key: true,
            key_is_on: true,
        };
        InspectorDraw::navigation(&mut c, &s, CGRect::new(0.0, 0.0, 36.0, 20.0), true, Some(Color::BLACK), &t);
        let img = render(&c, 40, 20);
        assert!(lum(&img, 18, 10) < lum(&img, 18, 7) / 3);
    }

    /// The key diamond reads disabled (dimmed, as in Swift `navigation`) while the playhead is outside the clip.
    #[test]
    fn the_key_diamond_is_dimmed_when_it_cannot_toggle() {
        let t = DrawTheme::default();
        let glow = |can: bool| {
            let mut c = Canvas::with_size(40.0, 20.0, None, 1.0);
            let s = KeyframeControlState {
                ring: ScrubKeyframeState::None,
                shows_navigation: true,
                can_go_previous: false,
                can_go_next: false,
                can_toggle_key: can,
                key_is_on: false,
            };
            InspectorDraw::navigation(&mut c, &s, CGRect::new(0.0, 0.0, 36.0, 20.0), true, None, &t);
            let img = render(&c, 40, 20);
            (13..24).flat_map(|x| (3..17).map(move |y| (x, y))).map(|(x, y)| lum(&img, x, y)).sum::<i32>()
        };
        let (on, off) = (glow(true), glow(false));
        assert!(off > 0 && off < on * 3 / 4, "disabled {off} vs enabled {on}");
    }

    /// A popup title wider than the popup is cut with an ellipsis inside the popup (Captions language, 96 pt).
    #[test]
    fn a_long_popup_title_stays_inside_the_popup() {
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(300.0, 28.0, None, 1.0);
        let rect = CGRect::new(0.0, 0.0, 96.0, 28.0);
        InspectorDraw::popup(&mut c, "English (United States)", rect, false, false, true, false, 28.0, None, &t);
        let img = render(&c, 300, 28);
        let outside: i32 = (100..300).flat_map(|x| (0..28).map(move |y| (x, y))).map(|(x, y)| lum(&img, x, y)).sum();
        assert_eq!(outside, 0, "nothing is drawn right of the popup");
    }

    #[test]
    fn polygon_fill_covers_the_inside_only() {
        let mut c = Canvas::with_size(20.0, 20.0, None, 1.0);
        c.fill_polygon(&InspectorDraw::diamond(CGPoint { x: 10.0, y: 10.0 }, 16.0), Color::WHITE);
        let img = render(&c, 20, 20);
        assert_eq!(red(&img, 10, 10), 255);
        assert_eq!(red(&img, 10, 3), 255);
        assert_eq!(red(&img, 3, 3), 0);
        assert_eq!(red(&img, 17, 17), 0);
    }

    /// An open editor reports its caret in device px (IME placement); a selection reports its start.
    #[test]
    fn open_editors_report_their_caret() {
        let mut cx = UiCx::new();
        let mut c = Canvas::with_size(400.0, 200.0, None, 2.0);
        c.translate_by(10.0, 20.0);
        let mut e = TextEditState::with_select_all("ab\ncd", false);
        e.place(5, false);
        let t = DrawTheme::default();
        let r = CGRect::new(0.0, 0.0, 100.0, 60.0);
        InspectorDraw::edit_lines(&mut c, &e, r, 20.0, 10.0, Color::WHITE, &t, &mut cx);
        assert!(cx.requests.caret.is_some_and(|r| r.y > 40.0 && r.x > 20.0));
        cx.requests.caret = None;
        let r = CGRect::new(0.0, 0.0, 100.0, 20.0);
        InspectorDraw::edit_text(&mut c, &TextEditState::new("abc"), r, 10.0, Color::WHITE, false, &t, &mut cx);
        assert_eq!(cx.requests.caret.map(|r| r.x), Some(20.0));
    }

    /// Gestures (w71): the slider value is linear in the pointer, every pixel, clamped at both ends (no easing).
    #[test]
    fn a_slider_drag_is_linear_in_the_pointer_and_clamps_at_the_ends() {
        let r = CGRect::new(0.0, 0.0, 104.0, 20.0);
        let k = InspectorTokens::SLIDER_KNOB;
        let (x0, w) = (k / 2.0, 104.0 - k);
        for px in 0..=104 {
            let want = ((f64::from(px) - x0) / w).clamp(0.0, 1.0);
            assert_eq!(InspectorDraw::slider_fraction(f64::from(px), r), want, "pointer {px}");
        }
        assert_eq!(InspectorDraw::slider_fraction(-50.0, r), 0.0);
        assert_eq!(InspectorDraw::slider_fraction(500.0, r), 1.0);
    }

    #[test]
    fn slider_fraction_inverts_the_knob_position() {
        let r = CGRect::new(0.0, 0.0, 110.0, 20.0);
        assert_eq!(InspectorDraw::slider_fraction(1.0, r), 0.0);
        assert_eq!(InspectorDraw::slider_fraction(55.0, r), 0.5);
        assert_eq!(InspectorDraw::slider_fraction(200.0, r), 1.0);
    }

    #[test]
    fn checkbox_on_draws_accent_and_a_white_check() {
        let mut c = Canvas::with_size(20.0, 20.0, None, 1.0);
        let t = DrawTheme::default();
        InspectorDraw::checkbox(
            &mut c,
            CheckState::On,
            CGRect::new(3.0, 3.0, 14.0, 14.0),
            false,
            false,
            true,
            false,
            &t,
        );
        let img = render(&c, 20, 20);
        assert!(img.pixels[(10 * 20 + 4) * 4 + 2] > 100);
        assert_eq!(red(&img, 0, 0), 0);
    }

    #[test]
    fn click_picks_the_line_under_the_pointer() {
        let e = TextEditState::with_select_all("ab\ncd\nef", false);
        let c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let r = CGRect::new(0.0, 10.0, 100.0, 60.0);
        let at = |x, y| InspectorDraw::caret_index_at(&c, &e, CGPoint { x, y }, r, 16.0, 12.0);
        assert_eq!(at(1.0, 12.0), 0);
        assert_eq!(at(8.0, 30.0), 4);
        assert_eq!(at(99.0, 500.0), 8);
        assert_eq!(at(1.0, -50.0), 0);
    }

    #[test]
    fn draws_selection_across_lines_without_traps() {
        let mut cx = UiCx::new();
        let mut e = TextEditState::new("ab\n\ncd");
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let r = CGRect::new(0.0, 0.0, 100.0, 60.0);
        InspectorDraw::edit_lines(&mut c, &e, r, 16.0, 12.0, Color::WHITE, &DrawTheme::default(), &mut cx);
        e.place(3, false);
        InspectorDraw::edit_lines(&mut c, &e, r, 16.0, 12.0, Color::WHITE, &DrawTheme::default(), &mut cx);
    }
}
