//! The design tokens of the portable UI (Swift `DrawTheme`): surfaces and text from the shared `AppearancePalette`,
//! metrics, radii and type sizes re-exported from `sq_uikit::design_tokens` (one source of values).

use crate::draw_list::Color;
use sq_core_model::LabelColor;
use sq_core_model::MarkerColor;
use sq_uikit::appearance_palette::{AppearanceMode, AppearancePalette, AppearanceSettings, PaletteColor};
use sq_uikit::design_tokens::sq_tokens as tok;
use sq_uikit::redesign_token::Token;
use sq_uikit::redesign_tokens::color as tk;

pub(crate) fn color(c: PaletteColor) -> Color {
    Color::new((c.r / 255.0) as f32, (c.g / 255.0) as f32, (c.b / 255.0) as f32, c.a as f32)
}

/// The app's design tokens for the portable UI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DrawTheme {
    /// The resolved palette (the same resolve the Mac app runs).
    pub palette: AppearancePalette,
    /// Device pixels per point.
    pub scale: f32,
}

/// The playhead head: pentagon points, fill and (light theme only) outline.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlayheadHead {
    /// Flat on top, pointing down onto the line.
    pub points: [sq_uikit::controls_grid::CGPoint; 5],
    /// The playhead token.
    pub fill: Color,
    /// Clear in dark.
    pub outline: Color,
}

impl PlayheadHead {
    /// Draws the head.
    pub fn draw(&self, cv: &mut crate::canvas::Canvas) {
        cv.fill_polygon(&self.points, self.fill);
        if self.outline.a > 0.0 {
            cv.stroke_polygon(&self.points, 1.0, self.outline);
        }
    }
}

/// `Theme.Metrics` in points.
pub mod metrics {
    pub use sq_uikit::design_tokens::sq_tokens::metrics::{
        CAPSULE, CLIP_NAME_BAND, MONITOR_DIM_HEIGHT, MONITOR_DIM_WIDTH, MONITOR_FOOTER, MONITOR_HEADER,
        MONITOR_SLIDER_HEIGHT, MONITOR_SLIDER_MAX_WIDTH, MONITOR_STRIP, PANE_DIVIDER, PANEL_HEADER, RULER, SCRUB_BAR,
        SEQUENCE_TABS, STATUS_BAR, TOP_BAR, TRACK_A1, TRACK_HEADER, TRACK_OTHER, TRACK_V1,
    };
}
/// Motion tokens (durations in seconds, easings): the one source, docs/rust/MOTION.md.
pub use crate::motion::{Ease, OPEN_SCALE, duration as motion_duration};
/// Row and control heights in points.
pub use sq_uikit::design_tokens::sq_tokens::height;
/// `Theme.Radius` in points.
pub use sq_uikit::design_tokens::sq_tokens::radius;
/// `Theme.Spacing` in points.
pub use sq_uikit::design_tokens::sq_tokens::spacing;
/// Type sizes in points (ladder 10 / 11 / 12 / 13 / 15 / 18; clip name is caption).
pub use sq_uikit::design_tokens::sq_tokens::type_size;

impl Default for DrawTheme {
    fn default() -> Self {
        DrawTheme::new(&AppearanceSettings::standard(), 1.0)
    }
}

impl DrawTheme {
    /// Transparency checkerboard gray in the dark theme.
    pub const CHECKER_DARK: Color = Color::rgb(0.30, 0.30, 0.30);
    /// Transparency checkerboard gray in the light theme.
    pub const CHECKER_LIGHT: Color = Color::rgb(0.45, 0.45, 0.45);
    /// The neutral middle stop of the color ramps.
    pub const RAMP_NEUTRAL: Color = Color::rgb(0.54, 0.54, 0.54);

    /// The theme of `settings` at `scale` device pixels per point.
    pub fn new(settings: &AppearanceSettings, scale: f32) -> DrawTheme {
        DrawTheme { palette: AppearancePalette::resolve(settings), scale }
    }

    /// Points to whole pixels.
    pub fn px(&self, pt: f32) -> f32 {
        (pt * self.scale).round()
    }

    fn dark(&self) -> bool {
        self.palette.is_dark()
    }
    fn ink(&self, dark: f64, light: f64) -> Color {
        color(self.palette.ink.with_alpha(if self.dark() { dark } else { light }))
    }
    /// A redesign token of the current mode, exactly as in tokens.json.
    pub fn token(&self, t: Token) -> Color {
        Color::hex(t.rgb(self.dark()), t.alpha(self.dark()) as f32)
    }
    /// A translucent redesign token scaled by the Contrast slider (1.0 at the default).
    fn token_line(&self, t: Token) -> Color {
        let a = (t.alpha(self.dark()) * self.palette.line_scale).min(1.0);
        Color::hex(t.rgb(self.dark()), a as f32)
    }

    /// The 2 px seam showing between and around the panel cards (`color/seam`).
    pub fn panel_ground(&self) -> Color {
        self.token(tk::SEAM)
    }
    /// The corner radius of a panel card in points: square (`radius/panel` is 0).
    pub fn panel_radius(&self) -> f64 {
        f64::from(sq_uikit::redesign_tokens::radius::PANEL)
    }

    // Surfaces and text
    /// Window canvas.
    pub fn canvas(&self) -> Color {
        color(self.palette.canvas)
    }
    /// Divider between panels.
    pub fn divider(&self) -> Color {
        color(self.palette.divider)
    }
    /// Title bar.
    pub fn titlebar(&self) -> Color {
        color(self.palette.titlebar)
    }
    /// Panel body.
    pub fn panel(&self) -> Color {
        color(self.palette.panel)
    }
    /// Content well.
    pub fn content(&self) -> Color {
        color(self.palette.content)
    }
    /// Track lane.
    pub fn lane(&self) -> Color {
        color(self.palette.lane)
    }
    /// Timeline background.
    pub fn timeline(&self) -> Color {
        color(self.palette.timeline)
    }
    /// Popups and menus.
    pub fn overlay(&self) -> Color {
        color(self.palette.overlay)
    }
    /// Primary text.
    pub fn label(&self) -> Color {
        color(self.palette.label)
    }
    /// Secondary text.
    pub fn label2(&self) -> Color {
        color(self.palette.label2)
    }
    /// Tertiary text.
    pub fn label3(&self) -> Color {
        color(self.palette.label3)
    }
    /// Quaternary text.
    pub fn label4(&self) -> Color {
        color(self.palette.label4)
    }
    /// Secondary button surface.
    pub fn raised(&self) -> Color {
        self.token(tk::RAISED_BOTTOM)
    }
    /// Secondary button surface, hovered.
    pub fn raised_hover(&self) -> Color {
        self.token(tk::RAISED_TOP)
    }
    /// Pressed button.
    pub fn pressed(&self) -> Color {
        self.token(tk::PRESSED_TOP)
    }
    /// Field, popup and check body.
    pub fn well(&self) -> Color {
        self.token(tk::WELL)
    }
    /// Artifact ring `--hair`.
    pub fn hair(&self) -> Color {
        self.token(tk::LINE)
    }
    /// Artifact ring `--hair2`.
    pub fn hair2(&self) -> Color {
        self.token(tk::LINE2)
    }
    /// Artifact `--edge`.
    pub fn edge(&self) -> Color {
        self.token(tk::LINE2)
    }
    /// Artifact `--current`.
    pub fn current(&self) -> Color {
        self.ink(tok::line::CURRENT_DARK, tok::line::CURRENT_LIGHT)
    }
    /// Artifact `--hover`.
    pub fn hover(&self) -> Color {
        self.token(tk::HOVER)
    }
    /// Row separator inside Effect Controls (white .075 dark, black .075 light).
    pub fn row_line(&self) -> Color {
        self.token(tk::ROW_LINE)
    }
    /// Error text.
    pub fn err_text(&self) -> Color {
        color(self.palette.err_text)
    }
    /// Accent.
    pub fn accent(&self) -> Color {
        color(self.palette.accent)
    }
    /// Accent fill.
    pub fn accent_fill(&self) -> Color {
        color(self.palette.accent_fill)
    }

    // Translucent tokens
    /// `Theme.inkFill`: ink at a fill alpha.
    pub fn ink_fill(&self, a: f64) -> Color {
        color(self.palette.ink.with_alpha(self.palette.fill_alpha(a)))
    }
    /// `Theme.inkLine`: ink at a line alpha.
    pub fn ink_line(&self, a: f64) -> Color {
        color(self.palette.ink.with_alpha(self.palette.line_alpha(a)))
    }
    /// Resting fill.
    pub fn fill(&self) -> Color {
        self.token(tk::HOVER)
    }
    /// Hovered fill.
    pub fn fill_hover(&self) -> Color {
        self.token(tk::HOVER)
    }
    /// Pressed fill.
    pub fn fill_pressed(&self) -> Color {
        self.ink_fill(tok::alpha::FILL_PRESSED)
    }
    /// Separator line.
    pub fn separator(&self) -> Color {
        self.token_line(tk::LINE)
    }
    /// Menu separator and hover row.
    pub fn separator_strong(&self) -> Color {
        self.hair2()
    }
    /// Menu edge.
    pub fn menu_edge(&self) -> Color {
        color(self.palette.ink.with_alpha(if self.dark() { tok::alpha::OVERLAY_EDGE } else { 0.14 }))
    }
    /// Swatch edge.
    pub fn swatch_edge(&self) -> Color {
        color(self.palette.ink.with_alpha(tok::alpha::SWATCH_EDGE))
    }
    /// Line between list rows.
    pub fn row_separator(&self) -> Color {
        self.divider()
    }
    /// Row hover (white 6 % dark, black 5 % light).
    pub fn row_hover(&self) -> Color {
        self.token(tk::HOVER)
    }
    /// Menu row hover: the raised stone tone on dark (`MenuItem/Hover` fill `color/raised_on`); light keeps the plain
    /// hover tint because the light raised tone equals the menu itself.
    pub fn menu_row_hover(&self) -> Color {
        if self.dark() { self.token(tk::RAISED_ON) } else { self.token(tk::HOVER) }
    }
    /// Destructive menu label (`MenuItem/Destructive` text `#FF6A60`).
    pub fn menu_destructive(&self) -> Color {
        Color::hex(0xFF6A60, 1.0)
    }
    /// Track row line.
    pub fn track_row_line(&self) -> Color {
        self.token_line(tk::LINE)
    }
    /// Track header line.
    pub fn track_header_line(&self) -> Color {
        self.token_line(tk::LINE2)
    }
    /// Ruler line.
    pub fn ruler_line(&self) -> Color {
        self.token_line(tk::LINE3)
    }
    /// Ruler minor tick.
    pub fn ruler_minor(&self) -> Color {
        self.ink_line(tok::alpha::RULER_MINOR)
    }
    /// Playhead.
    pub fn playhead(&self) -> Color {
        self.token(tk::PLAYHEAD)
    }
    /// The playhead head over a line at `center_x`, top at `top`: the one shape and token the timeline and the keyframe lane
    /// share (redesign rule: white in dark, almost black in light, never pink or blue).
    pub fn playhead_head(&self, center_x: f64, top: f64) -> PlayheadHead {
        use sq_uikit::controls_grid::CGPoint;
        let w = f64::from(sq_uikit::redesign_tokens::size::PLAYHEAD_HEAD_W);
        let h = f64::from(sq_uikit::redesign_tokens::size::PLAYHEAD_HEAD_H);
        let (l, shoulder) = (center_x - w / 2.0, top + h * 0.58);
        let outline = if self.palette.is_dark() {
            Color::CLEAR
        } else {
            self.playhead().with_alpha(tok::alpha::HEAD_OUTLINE_LIGHT as f32)
        };
        PlayheadHead {
            points: [
                CGPoint { x: l, y: top },
                CGPoint { x: l + w, y: top },
                CGPoint { x: l + w, y: shoulder },
                CGPoint { x: center_x, y: top + h },
                CGPoint { x: l, y: shoulder },
            ],
            fill: self.playhead(),
            outline,
        }
    }
    /// Backdrop of the monitor.
    pub fn monitor_backdrop(&self) -> Color {
        self.token(tk::VIEWER)
    }
    /// This theme for text drawn on the always-dark monitor backdrop: in Light the label tones are the dark theme's.
    pub fn on_viewer(&self) -> DrawTheme {
        if self.dark() {
            return *self;
        }
        let dark = AppearancePalette::resolve(&AppearanceSettings::new(AppearanceMode::Dark, 0, 50));
        let mut d = *self;
        d.palette.label = dark.label;
        d.palette.label2 = dark.label2;
        d.palette.label3 = dark.label3;
        d
    }
    /// The picture well behind a preview.
    pub fn viewer(&self) -> Color {
        self.token(tk::VIEWER)
    }
    /// Monitor guides.
    pub fn guide(&self) -> Color {
        Color::WHITE.with_alpha(tok::alpha::GUIDE as f32)
    }
    /// Monitor HUD.
    pub fn viewer_hud(&self) -> Color {
        Color::BLACK.with_alpha(tok::alpha::VIEWER_HUD as f32)
    }
    /// Platform mock overlay.
    pub fn platform_mock(&self) -> Color {
        Color::WHITE.with_alpha(tok::alpha::PLATFORM_MOCK as f32)
    }
    /// Handles and outlines drawn over the picture.
    pub fn on_picture_stroke(&self) -> Color {
        Color::WHITE
    }
    /// Shadow of those handles.
    pub fn on_picture_shadow(&self) -> Color {
        Color::BLACK.with_alpha(tok::alpha::ON_PICTURE_SHADOW as f32)
    }
    /// Snap guide.
    pub fn guide_snap(&self) -> Color {
        Color::hex(tok::hex::GUIDE_SNAP, 1.0)
    }
    /// Caption clip teal, painted for every caption clip.
    pub fn caption_clip(&self) -> Color {
        Color::rgb(0.05, 0.54, 0.51)
    }
    /// Yellow.
    pub fn yellow(&self) -> Color {
        self.token(tk::USE)
    }
    /// Text on a clip.
    pub fn on_clip(&self) -> Color {
        Color::WHITE
    }

    /// A clip's body color for its label.
    pub fn clip(&self, label: LabelColor) -> Color {
        Color::hex(label.rgb(), 1.0)
    }
    /// A clip's body color: the band color one step darker (the `color/clip_*_body` token of a kind's band color, else
    /// the band mixed 27 % toward black).
    pub fn clip_body(&self, label: LabelColor) -> Color {
        let band = label.rgb();
        for (b, body) in [
            (tk::CLIP_VIDEO_BAND, tk::CLIP_VIDEO_BODY),
            (tk::CLIP_AUDIO_BAND, tk::CLIP_AUDIO_BODY),
            (tk::CLIP_GRAPHIC_BAND, tk::CLIP_GRAPHIC_BODY),
            (tk::CLIP_ADJUST_BAND, tk::CLIP_ADJUST_BODY),
            (tk::CLIP_NESTED_BAND, tk::CLIP_NESTED_BODY),
        ] {
            if b.rgb(true) == band {
                return self.token(body);
            }
        }
        let c = self.clip(label);
        Color::new(c.r * 0.73, c.g * 0.73, c.b * 0.73, c.a)
    }
    /// A clip's edge (11 % toward white).
    pub fn clip_edge(&self, label: LabelColor) -> Color {
        self.clip(label).lifted(0.11)
    }

    /// `Theme.Palette.marker`: one marker color per `MarkerColor`.
    pub fn marker(c: MarkerColor) -> Color {
        let t = match c {
            MarkerColor::Green => tk::MARKER_GREEN,
            MarkerColor::Red => tk::MARKER_RED,
            MarkerColor::Purple => tk::MARKER_PURPLE,
            MarkerColor::Orange => tk::MARKER_ORANGE,
            MarkerColor::Yellow => tk::MARKER_YELLOW,
            MarkerColor::White => tk::MARKER_WHITE,
            MarkerColor::Blue => tk::MARKER_BLUE,
            MarkerColor::Cyan => tk::MARKER_CYAN,
        };
        Color::hex(t.rgb(true), 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_uikit::design_tokens::sq_tokens as t;
    use sq_uikit::redesign_tokens::ALL_COLORS;

    /// Swift `DesignTokensTests.drawThemeReadsTheTokens`: the theme's values are the uikit tokens.
    #[test]
    fn metrics_spacing_radius_sizes_are_the_tokens() {
        assert_eq!(metrics::TOP_BAR, t::metrics::TOP_BAR);
        assert_eq!(metrics::TRACK_HEADER, 190.0);
        assert_eq!(metrics::PANE_DIVIDER, t::metrics::PANE_DIVIDER);
        assert_eq!((spacing::XXS, spacing::SNUG, spacing::XXL), (2.0, 6.0, 32.0));
        assert_eq!((radius::PANEL, radius::MENU, radius::CARD), (4.0, 10.0, 12.0));
        assert_eq!((height::COMPACT, height::LARGE, height::PANEL_LIST), (22.0, 28.0, 24.0));
        assert_eq!((type_size::CAPTION, type_size::BODY, type_size::DISPLAY), (10.0, 11.0, 18.0));
        assert_eq!(type_size::CLIP_NAME, type_size::CAPTION);
        // No draw reader: pinned to the old Theme.Metrics value.
        assert_eq!(
            (t::metrics::PUSH_BUTTON, t::metrics::QUIET_BUTTON, t::metrics::QUIET_FIELD, t::metrics::BAR_CONTROL),
            (22.0, 22.0, 22.0, 22.0)
        );
    }

    #[test]
    fn row_hover_and_selection_follow_the_redesign_tokens() {
        for mode in [AppearanceMode::Dark, AppearanceMode::Light] {
            let th = DrawTheme::new(&AppearanceSettings::new(mode, 0, 50), 1.0);
            assert_eq!(th.row_hover(), th.token(tk::HOVER));
            assert_eq!(th.selection(), th.token(tk::RAISED));
        }
        assert_eq!(DrawTheme::default().row_separator(), DrawTheme::default().divider());
    }

    #[test]
    fn alphas_are_the_tokens() {
        let th = DrawTheme::default();
        assert_eq!(th.fill(), th.token(tk::HOVER));
        assert_eq!(th.fill_hover(), th.token(tk::HOVER));
        assert_eq!(th.separator(), th.token(tk::LINE));
        assert_eq!(th.ruler_line(), th.token(tk::LINE3));
        assert_eq!(th.monitor_backdrop(), Color::hex(0x0E0E0F, 1.0));
        assert_eq!(th.viewer(), Color::hex(0x0E0E0F, 1.0));
        assert_eq!(th.yellow(), Color::hex(0xFFD60A, 1.0));
        assert!(th.fill().a > 0.0);
        assert_eq!(th.viewer_hud().a, t::alpha::VIEWER_HUD as f32);
        assert_eq!(th.guide().a, t::alpha::GUIDE as f32);
        assert_eq!(th.platform_mock().a, t::alpha::PLATFORM_MOCK as f32);
        assert_eq!((t::alpha::BADGE_FILL, t::alpha::BADGE_EDGE, t::alpha::CLIP_EDGE), (0.95, 0.6, 0.22));
        assert_eq!(
            (t::alpha::THUMB_RULE, t::alpha::IN_OUT_BAND, t::alpha::IN_OUT_BAND_EDGE, t::alpha::CLIP_SHADE),
            (0.35, 0.13, 0.38, 0.22)
        );
        assert_eq!(t::timeline::SELECTION_OUTLINE_WIDTH, 1.5);
    }

    #[test]
    fn contrast_slider_scales_the_lines_not_the_fills() {
        let hi = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Dark, 0, 100), 1.0);
        let lo = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Dark, 0, 0), 1.0);
        assert!(hi.separator().a > DrawTheme::default().separator().a);
        assert!(lo.separator().a < DrawTheme::default().separator().a);
        assert_eq!(hi.hair(), lo.hair());
    }

    #[test]
    fn light_theme_uses_light_surfaces_and_on_viewer_keeps_dark_labels() {
        let light = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Light, 0, 50), 2.0);
        assert_eq!(light.well(), Color::hex(0xFFFFFF, 1.0));
        assert_eq!(light.px(5.4), 11.0);
        let dark = DrawTheme::default();
        assert_eq!(light.on_viewer().label(), dark.label());
        assert_eq!(dark.on_viewer(), dark);
    }

    #[test]
    fn the_playhead_head_is_the_line_token_in_both_themes_never_pink_or_blue() {
        let light = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Light, 0, 50), 2.0);
        let dark = DrawTheme::default();
        for th in [dark, light] {
            let head = th.playhead_head(100.0, 0.0);
            assert_eq!(head.fill, th.playhead(), "head and line share one token");
            assert!((head.fill.r - head.fill.g).abs() < 0.02 && (head.fill.g - head.fill.b).abs() < 0.02, "neutral");
            assert_eq!(head.points[3].x, 100.0, "the tip sits on the line");
        }
        assert!(dark.playhead().r > 0.95, "white in dark");
        assert!(light.playhead().r < 0.15, "almost black in light");
        assert_eq!(dark.playhead_head(0.0, 0.0).outline, Color::CLEAR);
        assert!(light.playhead_head(0.0, 0.0).outline.a > 0.0);
    }

    /// The color a code token of the old TOKEN-MAP resolves to in this theme.
    fn old_color(th: &DrawTheme, old: &str) -> Option<Color> {
        use LabelColor as L;
        Some(match old {
            "canvas" => th.canvas(),
            "divider" => th.divider(),
            "titlebar" => th.titlebar(),
            "panel" => th.panel(),
            "content" => th.content(),
            "lane" => th.lane(),
            "timeline" => th.timeline(),
            "overlay" => th.overlay(),
            "label" => th.label(),
            "label2" => th.label2(),
            "label3" => th.label3(),
            "label4" => th.label4(),
            "err_text" => th.err_text(),
            "accent" => th.accent(),
            "accent_fill" => th.accent_fill(),
            "accent_tint" => th.accent_tint(),
            "warning" => th.warning(),
            "red" => th.red(),
            "keyframe" => th.keyframe(),
            "yellow" => th.yellow(),
            "green" => th.green(),
            "support" => th.token(tk::SUPPORT),
            "fill" => th.fill(),
            "fill_hover" => th.fill_hover(),
            "separator" => th.separator(),
            "track_row_line" => th.track_row_line(),
            "track_header_line" => th.track_header_line(),
            "ruler_line" => th.ruler_line(),
            "hair" => th.hair(),
            "hair2" => th.hair2(),
            "edge" => th.edge(),
            "row_hover" => th.row_hover(),
            "selection" => th.selection(),
            "field" => th.field(),
            "field_edge" => th.field_edge(),
            "row_line" => th.row_line(),
            "raised" => th.raised(),
            "raised_hover" => th.raised_hover(),
            "pressed" => th.pressed(),
            "well" => th.well(),
            "slider_knob" => th.token(tk::KNOB_TOP),
            "monitor_backdrop" => th.monitor_backdrop(),
            "viewer" => th.viewer(),
            "playhead" => th.playhead(),
            "clip_blue" => th.clip(L::Blue),
            "clip_green" => th.clip(L::Green),
            "clip_violet" => th.clip(L::Violet),
            "clip_cerulean" => th.clip(L::Cerulean),
            "clip_tan" => th.clip(L::Tan),
            "marker_green" => DrawTheme::marker(MarkerColor::Green),
            "marker_red" => DrawTheme::marker(MarkerColor::Red),
            "marker_purple" => DrawTheme::marker(MarkerColor::Purple),
            "marker_orange" => DrawTheme::marker(MarkerColor::Orange),
            "marker_yellow" => DrawTheme::marker(MarkerColor::Yellow),
            "marker_white" => DrawTheme::marker(MarkerColor::White),
            "marker_blue" => DrawTheme::marker(MarkerColor::Blue),
            "marker_cyan" => DrawTheme::marker(MarkerColor::Cyan),
            _ => return None,
        })
    }

    fn assert_close(got: Color, want: u32, what: &str) {
        let w = Color::hex(want >> 8, (want & 0xFF) as f32 / 255.0);
        let d = (got.r - w.r).abs().max((got.g - w.g).abs()).max((got.b - w.b).abs()).max((got.a - w.a).abs());
        assert!(d < 0.003, "{what}: got {got:?}, want #{want:08X}");
    }

    /// Every `color/` row of docs/redesign/TOKEN-MAP.md resolves to its new value: Dark from the table, Light from the
    /// new token's Light value in tokens.json (both through the theme the draw code reads).
    #[test]
    fn every_token_map_row_resolves_to_its_new_value() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/redesign/TOKEN-MAP.md");
        let table = std::fs::read_to_string(path).unwrap();
        let hex = |s: &str| {
            let h = s.trim().trim_matches('`').trim_start_matches('#').to_string();
            u32::from_str_radix(&if h.len() == 6 { format!("{h}FF") } else { h }, 16).unwrap()
        };
        let dark = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Dark, 0, 50), 1.0);
        let light = DrawTheme::new(&AppearanceSettings::new(AppearanceMode::Light, 0, 50), 1.0);
        let mut rows = 0;
        for line in table.lines() {
            let cells: Vec<&str> = line.split('|').map(str::trim).collect();
            if cells.len() < 6 || !cells[1].starts_with("`color/") || !cells[3].starts_with("`color/") {
                continue;
            }
            let old = cells[1].trim_matches('`').trim_start_matches("color/");
            let new = cells[3].trim_matches('`');
            let new_light = ALL_COLORS.iter().find(|(n, _)| *n == new).unwrap_or_else(|| panic!("no token {new}")).1;
            let what = format!("{old} -> {new}");
            let got = old_color(&dark, old).unwrap_or_else(|| panic!("no accessor for {old}"));
            assert_close(got, hex(cells[4]), &format!("{what} Dark"));
            let got = old_color(&light, old).unwrap();
            assert_close(got, new_light.rgba(false), &format!("{what} Light"));
            rows += 1;
        }
        assert_eq!(rows, 57, "color rows of the map");
    }

    #[test]
    fn rgb_hex_rounds_and_drops_alpha() {
        assert_eq!(Color::hex(0x2A8E8A, 0.3).rgb_hex(), 0x2A8E8A);
    }
}
