// Swift: AppearancePalette.swift
//! The user's Appearance choice and the palette resolved from it (design B v7 theme engine).

use std::fmt;
use std::ops::RangeInclusive;

use crate::redesign_tokens::color as tk;

/// User settings (Swift `UserDefaults`), injected: the app provides the real store.
pub trait UiDefaults {
    /// The stored string; `None` when the key is not set or holds another type.
    fn string(&self, key: &str) -> Option<String>;
    /// The stored integer; `None` when the key is not set or holds another type.
    fn integer(&self, key: &str) -> Option<i64>;
    /// The stored string list; `None` when the key is not set or holds another type.
    fn string_array(&self, key: &str) -> Option<Vec<String>>;
    /// The stored bytes; `None` when the key is not set or holds another type.
    fn data(&self, key: &str) -> Option<Vec<u8>>;
    /// Stores a string.
    fn set_string(&mut self, key: &str, value: &str);
    /// Stores an integer.
    fn set_integer(&mut self, key: &str, value: i64);
    /// Stores a string list.
    fn set_string_array(&mut self, key: &str, value: &[String]);
    /// Stores bytes.
    fn set_data(&mut self, key: &str, value: &[u8]);
    /// Removes a key.
    fn remove(&mut self, key: &str);
}

/// Dark (default), Light (derived from the dark app palette) or System (follows the operating system's look).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AppearanceMode {
    Dark,
    Light,
    System,
}

impl AppearanceMode {
    /// Every mode, in declaration order.
    pub const ALL: [AppearanceMode; 3] = [AppearanceMode::Dark, AppearanceMode::Light, AppearanceMode::System];

    /// Dark or Light: System becomes what the system currently shows (`system_dark`), the others stay as they are.
    pub fn resolved(self, system_dark: bool) -> AppearanceMode {
        match self {
            AppearanceMode::System if system_dark => AppearanceMode::Dark,
            AppearanceMode::System => AppearanceMode::Light,
            other => other,
        }
    }

    /// The stored name.
    pub fn raw_value(self) -> &'static str {
        match self {
            AppearanceMode::Dark => "dark",
            AppearanceMode::Light => "light",
            AppearanceMode::System => "system",
        }
    }

    /// The mode stored under `raw`.
    pub fn from_raw(raw: &str) -> Option<AppearanceMode> {
        Self::ALL.into_iter().find(|m| m.raw_value() == raw)
    }
}

/// The user's Appearance choice: mode, Background (-6 to +6) and Contrast (0 to 100, 50 = the app values).
/// Persisted as `sq.appearance.mode` / `.background` / `.contrast`. Background and contrast stay clamped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppearanceSettings {
    pub mode: AppearanceMode,
    background: i64,
    contrast: i64,
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        Self::new(AppearanceMode::Dark, 0, 50)
    }
}

impl AppearanceSettings {
    pub const BACKGROUND_RANGE: RangeInclusive<i64> = -6..=6;
    pub const CONTRAST_RANGE: RangeInclusive<i64> = 0..=100;
    pub const MODE_KEY: &'static str = "sq.appearance.mode";
    pub const BACKGROUND_KEY: &'static str = "sq.appearance.background";
    pub const CONTRAST_KEY: &'static str = "sq.appearance.contrast";

    /// The default choice: dark, background 0, contrast 50.
    pub fn standard() -> Self {
        Self::default()
    }

    /// Out-of-range values are clamped.
    pub fn new(mode: AppearanceMode, background: i64, contrast: i64) -> Self {
        AppearanceSettings {
            mode,
            background: clamp(background, Self::BACKGROUND_RANGE),
            contrast: clamp(contrast, Self::CONTRAST_RANGE),
        }
    }

    /// Reads the saved choice; missing values take the defaults.
    pub fn from_defaults(defaults: &dyn UiDefaults) -> Self {
        let mode =
            defaults.string(Self::MODE_KEY).and_then(|s| AppearanceMode::from_raw(&s)).unwrap_or(AppearanceMode::Dark);
        let bg = defaults.integer(Self::BACKGROUND_KEY).unwrap_or(0);
        let ct = defaults.integer(Self::CONTRAST_KEY).unwrap_or(50);
        Self::new(mode, bg, ct)
    }

    /// Writes the choice.
    pub fn save(&self, defaults: &mut dyn UiDefaults) {
        defaults.set_string(Self::MODE_KEY, self.mode.raw_value());
        defaults.set_integer(Self::BACKGROUND_KEY, self.background);
        defaults.set_integer(Self::CONTRAST_KEY, self.contrast);
    }

    /// Background shift, -6...6.
    pub fn background(&self) -> i64 {
        self.background
    }

    /// Sets the background, clamped to -6...6.
    pub fn set_background(&mut self, v: i64) {
        self.background = clamp(v, Self::BACKGROUND_RANGE);
    }

    /// Contrast, 0...100.
    pub fn contrast(&self) -> i64 {
        self.contrast
    }

    /// Sets the contrast, clamped to 0...100.
    pub fn set_contrast(&mut self, v: i64) {
        self.contrast = clamp(v, Self::CONTRAST_RANGE);
    }
}

impl fmt::Display for AppearanceSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} bg {} ct {}", self.mode.raw_value(), self.background, self.contrast)
    }
}

fn clamp(v: i64, r: RangeInclusive<i64>) -> i64 {
    v.max(*r.start()).min(*r.end())
}

/// An sRGB color, components 0...255, alpha 0...1. Pure, so the palette math is testable without a UI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaletteColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl PaletteColor {
    pub const WHITE: PaletteColor = PaletteColor::rgb_hex(0xFFFFFF);
    pub const BLACK: PaletteColor = PaletteColor::rgb_hex(0x000000);

    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Self {
        PaletteColor { r, g, b, a }
    }

    const fn rgb_hex(hex: u32) -> Self {
        PaletteColor { r: ((hex >> 16) & 0xFF) as f64, g: ((hex >> 8) & 0xFF) as f64, b: (hex & 0xFF) as f64, a: 1.0 }
    }

    /// `0xRRGGBB` with alpha.
    pub fn from_hex(hex: u32, alpha: f64) -> Self {
        PaletteColor { a: alpha, ..Self::rgb_hex(hex) }
    }

    /// Rounded to whole 0...255 steps (the design's `toHex`).
    fn quantized(self) -> Self {
        let q = |v: f64| v.clamp(0.0, 255.0).round();
        PaletteColor::new(q(self.r), q(self.g), q(self.b), self.a)
    }

    fn map(self, f: impl Fn(f64) -> f64) -> Self {
        PaletteColor::new(f(self.r), f(self.g), f(self.b), self.a)
    }

    /// The same color with another alpha.
    pub fn with_alpha(self, alpha: f64) -> Self {
        PaletteColor::new(self.r, self.g, self.b, alpha)
    }

    /// This color with `ink` laid over it at `alpha` (opaque result).
    pub fn over(self, ink: PaletteColor, alpha: f64) -> Self {
        PaletteColor::new(
            self.r + (ink.r - self.r) * alpha,
            self.g + (ink.g - self.g) * alpha,
            self.b + (ink.b - self.b) * alpha,
            1.0,
        )
        .quantized()
    }

    /// WCAG relative luminance.
    pub fn luminance(&self) -> f64 {
        fn lin(v: f64) -> f64 {
            let c = v / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        }
        0.2126 * lin(self.r) + 0.7152 * lin(self.g) + 0.0722 * lin(self.b)
    }

    /// WCAG contrast ratio (1...21).
    pub fn contrast_with(&self, o: PaletteColor) -> f64 {
        let x = self.luminance();
        let y = o.luminance();
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }
}

/// The resolved surfaces and text of one `AppearanceSettings` (port of the design's `resolve(mode, background, contrast)`).
/// Translucent tokens (fills, lines) are built in the theme from `ink` and `line_scale`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AppearancePalette {
    pub mode: AppearanceMode,
    pub canvas: PaletteColor,
    pub divider: PaletteColor,
    pub titlebar: PaletteColor,
    pub panel: PaletteColor,
    pub content: PaletteColor,
    pub lane: PaletteColor,
    pub timeline: PaletteColor,
    pub overlay: PaletteColor,
    pub label: PaletteColor,
    pub label2: PaletteColor,
    pub label3: PaletteColor,
    /// Secondary text lifted to 4.5:1 on the selection and menu surfaces, where the design's `text-secondary` falls short.
    pub label2_on_raised: PaletteColor,
    /// Disabled text (t4); fixed, not part of the 4.5:1 guard.
    pub label4: PaletteColor,
    /// Destructive menu rows.
    pub err_text: PaletteColor,
    /// White in dark mode, black in light: the ink of every translucent fill and line.
    pub ink: PaletteColor,
    /// Multiplier of hairline alphas (Contrast slider).
    pub line_scale: f64,
    pub accent: PaletteColor,
    pub accent_fill: PaletteColor,
    pub warning: PaletteColor,
    pub red: PaletteColor,
    pub keyframe: PaletteColor,
}

/// Surfaces in field order (canvas, divider, titlebar, panel, content, lane, timeline, overlay), from the redesign
/// tokens: canvas, divider and content are the seam, titlebar the chrome, timeline the lane, overlay the menu.
const fn surfaces(dark: bool) -> [u32; 8] {
    [
        tk::SEAM.rgb(dark),
        tk::SEAM.rgb(dark),
        tk::CHROME.rgb(dark),
        tk::PANEL.rgb(dark),
        tk::SEAM.rgb(dark),
        tk::LANE.rgb(dark),
        tk::LANE.rgb(dark),
        tk::MENU.rgb(dark),
    ]
}
const DARK_SURFACES: [u32; 8] = surfaces(true);
const LIGHT_SURFACES: [u32; 8] = surfaces(false);
const DARK_TEXT: [u32; 3] = [tk::TEXT.rgb(true), tk::TEXT2.rgb(true), tk::TEXT3.rgb(true)];
const LIGHT_TEXT: [u32; 3] = [tk::TEXT.rgb(false), tk::TEXT2.rgb(false), tk::TEXT3.rgb(false)];

impl AppearancePalette {
    /// True for the dark mode.
    pub fn is_dark(&self) -> bool {
        self.mode == AppearanceMode::Dark
    }

    /// Fill alpha in this mode for a dark-mode alpha (light uses black ink, a little softer).
    pub fn fill_alpha(&self, dark: f64) -> f64 {
        if self.is_dark() { dark } else { dark * 0.65 }
    }

    /// Hairline alpha for a dark-mode alpha, scaled by Contrast.
    pub fn line_alpha(&self, dark: f64) -> f64 {
        dark * self.line_scale * if self.is_dark() { 1.0 } else { 0.8 }
    }

    /// Opaque selection over the panel (the text contrast checks run on it).
    pub fn selection_on_panel(&self) -> PaletteColor {
        self.panel.over(self.ink, 0.14)
    }

    /// Opaque field over the panel (the text contrast checks run on it).
    pub fn field_on_panel(&self) -> PaletteColor {
        self.panel.over(PaletteColor::BLACK, if self.is_dark() { 0.28 } else { 0.05 })
    }

    /// The resting surfaces that carry text of every level: panel, title bar, lane and field. The seam (canvas, divider,
    /// content) carries no text. Menus and selected rows only carry the two main levels (see `lowest_text_contrast`).
    fn text_surfaces(&self) -> [PaletteColor; 4] {
        [self.panel, self.titlebar, self.lane, self.field_on_panel()]
    }

    /// The lowest text contrast over the resting surfaces (shown in the Appearance popover; never under 4.5).
    /// shortcut: the design's tertiary text (#85858D) reads 4.0:1 on the dark menu, so label3 is not guarded on
    /// menus; upgrade when the design lightens text3 or darkens the menu.
    pub fn lowest_text_contrast(&self) -> f64 {
        let mut m = f64::INFINITY;
        for t in [self.label, self.label2, self.label3] {
            for s in self.text_surfaces() {
                m = m.min(t.contrast_with(s));
            }
        }
        for t in [self.label, self.label2_on_raised] {
            m = m.min(t.contrast_with(self.selection_on_panel()));
            m = m.min(t.contrast_with(self.overlay));
        }
        m
    }

    /// Resolves the palette of `s`.
    pub fn resolve(s: &AppearanceSettings) -> AppearancePalette {
        let system_dark = s.mode != AppearanceMode::System || sq_os::appearance::prefers_dark();
        Self::resolve_with(s, system_dark)
    }

    /// Resolves the palette of `s` when the system shows a dark look (`system_dark`) or a light one.
    pub fn resolve_with(s: &AppearanceSettings, system_dark: bool) -> AppearancePalette {
        let mode = s.mode.resolved(system_dark);
        let d = mode == AppearanceMode::Dark;
        let ct = s.contrast() as f64;
        let bg = s.background() as f64;
        let k = if ct <= 50.0 { 0.4 + ct * 0.012 } else { 1.0 + (ct - 50.0) * 0.016 };
        let f = if d { 2.2 } else { 1.6 };
        let anchor = if d { tk::CHROME.palette_color(true) } else { PaletteColor::WHITE };
        let src = if d { DARK_SURFACES } else { LIGHT_SURFACES }.map(PaletteColor::rgb_hex);
        // Seam surfaces (canvas, divider, content; dark) only follow Background; every other surface spreads away from
        // the anchor with Contrast.
        let surf: Vec<PaletteColor> = src
            .iter()
            .enumerate()
            .map(|(i, c)| {
                if d && (i < 2 || i == 4) {
                    return c.map(|v| v + bg * f).quantized();
                }
                PaletteColor::new(
                    anchor.r + (c.r - anchor.r) * k + bg * f,
                    anchor.g + (c.g - anchor.g) * k + bg * f,
                    anchor.b + (c.b - anchor.b) * k + bg * f,
                    1.0,
                )
                .quantized()
            })
            .collect();
        let pick = |t: crate::redesign_token::Token| t.palette_color(d);
        let mut p = AppearancePalette {
            mode,
            canvas: surf[0],
            divider: surf[1],
            titlebar: surf[2],
            panel: surf[3],
            content: surf[4],
            lane: surf[5],
            timeline: surf[6],
            overlay: surf[7],
            label: PaletteColor::WHITE,
            label2: PaletteColor::WHITE,
            label3: PaletteColor::WHITE,
            label2_on_raised: PaletteColor::WHITE,
            label4: pick(tk::TEXT4),
            err_text: pick(tk::RED),
            ink: if d { PaletteColor::WHITE } else { PaletteColor::BLACK },
            line_scale: if ct <= 50.0 { 0.5 + ct * 0.01 } else { 1.0 + (ct - 50.0) * 0.016 },
            accent: pick(tk::ACCENT),
            accent_fill: pick(tk::ACCENT_FILL),
            warning: pick(tk::WARNING),
            red: pick(tk::RED),
            keyframe: pick(tk::KEYFRAME),
        };
        // Text: app values at contrast 50, shifted with the sliders, then raised until every resting surface reads at 4.5:1.
        let surfaces = p.text_surfaces();
        let text = if d { DARK_TEXT } else { LIGHT_TEXT }.map(PaletteColor::rgb_hex);
        let mut out = Vec::with_capacity(3);
        for (i, t) in text.iter().enumerate() {
            let shift = (ct - 50.0) * (if i == 0 { 0.2 } else { 0.6 }) + bg * f * 0.6;
            let step = if d { shift } else { -shift };
            let mut c = t.map(|v| v + step).quantized();
            // The resting surfaces decide the text color itself; selection and menu get their own lifted value below.
            let mut guard_steps = 0;
            while guard_steps < 255 && !surfaces.iter().all(|s| c.contrast_with(*s) >= 4.5) {
                c = c.map(|v| v + if d { 1.0 } else { -1.0 }).quantized();
                guard_steps += 1;
            }
            if i == 1 {
                let mut raised = c;
                let extra = [p.selection_on_panel(), p.overlay];
                let mut steps = 0;
                while steps < 255 && !extra.iter().all(|s| raised.contrast_with(*s) >= 4.5) {
                    raised = raised.map(|v| v + if d { 1.0 } else { -1.0 }).quantized();
                    steps += 1;
                }
                p.label2_on_raised = raised;
            }
            out.push(c);
        }
        p.label = out[0];
        p.label2 = out[1];
        p.label3 = out[2];
        p
    }
}

/// In-memory `UiDefaults` for the tests of this crate.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct MemoryDefaults(pub std::collections::BTreeMap<String, Stored>);

#[cfg(test)]
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Stored {
    Str(String),
    Int(i64),
    List(Vec<String>),
    Bytes(Vec<u8>),
}

#[cfg(test)]
impl UiDefaults for MemoryDefaults {
    fn string(&self, key: &str) -> Option<String> {
        match self.0.get(key) {
            Some(Stored::Str(s)) => Some(s.clone()),
            _ => None,
        }
    }
    fn integer(&self, key: &str) -> Option<i64> {
        match self.0.get(key) {
            Some(Stored::Int(n)) => Some(*n),
            _ => None,
        }
    }
    fn string_array(&self, key: &str) -> Option<Vec<String>> {
        match self.0.get(key) {
            Some(Stored::List(l)) => Some(l.clone()),
            _ => None,
        }
    }
    fn data(&self, key: &str) -> Option<Vec<u8>> {
        match self.0.get(key) {
            Some(Stored::Bytes(b)) => Some(b.clone()),
            _ => None,
        }
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.insert(key.to_string(), Stored::Str(value.to_string()));
    }
    fn set_integer(&mut self, key: &str, value: i64) {
        self.0.insert(key.to_string(), Stored::Int(value));
    }
    fn set_string_array(&mut self, key: &str, value: &[String]) {
        self.0.insert(key.to_string(), Stored::List(value.to_vec()));
    }
    fn set_data(&mut self, key: &str, value: &[u8]) {
        self.0.insert(key.to_string(), Stored::Bytes(value.to_vec()));
    }
    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(h: u32) -> PaletteColor {
        PaletteColor::from_hex(h, 1.0)
    }

    #[test]
    fn contrast_ratio_matches_wcag() {
        assert!((PaletteColor::WHITE.contrast_with(PaletteColor::BLACK) - 21.0).abs() <= 0.01);
        assert!((hex(0x777777).contrast_with(PaletteColor::WHITE) - 4.48).abs() <= 0.01);
    }

    #[test]
    fn dark_default_keeps_the_app_values() {
        let p = AppearancePalette::resolve(&AppearanceSettings::standard());
        assert_eq!(p.panel, hex(0x1C1C1E));
        assert_eq!(p.titlebar, hex(0x1C1C1E));
        assert_eq!(p.content, hex(0x0E0E10));
        assert_eq!(p.timeline, hex(0x161618));
        assert_eq!(p.overlay, hex(0x29292C));
        assert_eq!(p.divider, hex(0x0E0E10));
        assert_eq!(p.canvas, hex(0x0E0E10));
        assert_eq!(p.label, hex(0xE2E2E5));
        assert_eq!(p.label2, hex(0x8D8D93));
        assert_eq!(p.label2_on_raised, hex(0xA6A6AC));
        assert_eq!(p.label3, hex(0x8D8D93));
        assert_eq!(p.label4, hex(0x5E5E65));
        assert_eq!(p.accent, hex(0x0A84FF));
        assert_eq!(p.accent_fill, hex(0x0A84FF));
    }

    #[test]
    fn light_is_derived_and_uses_the_filled_accent() {
        let p = AppearancePalette::resolve(&AppearanceSettings::new(AppearanceMode::Light, 0, 50));
        assert_eq!(p.panel, hex(0xF1F1F3));
        assert_eq!(p.accent, hex(0x0A7AF0));
        assert_eq!(p.accent_fill, hex(0x0A6CF0));
        assert!(p.label.luminance() < 0.05);
        assert!(PaletteColor::WHITE.contrast_with(p.accent_fill) >= 4.5);
    }

    #[test]
    fn text_reaches_four_point_five_everywhere() {
        for mode in AppearanceMode::ALL {
            for bg in AppearanceSettings::BACKGROUND_RANGE {
                for ct in (0..=100).step_by(5) {
                    let s = AppearanceSettings::new(mode, bg, ct);
                    let p = AppearancePalette::resolve(&s);
                    assert!(p.lowest_text_contrast() >= 4.5, "{s}");
                }
            }
        }
    }

    #[test]
    fn contrast_spreads_surfaces_from_the_canvas() {
        let low = AppearancePalette::resolve(&AppearanceSettings::new(AppearanceMode::Dark, 0, 0));
        let high = AppearancePalette::resolve(&AppearanceSettings::new(AppearanceMode::Dark, 0, 100));
        assert!(low.overlay.contrast_with(low.canvas) < high.overlay.contrast_with(high.canvas));
        let darker = AppearancePalette::resolve(&AppearanceSettings::new(AppearanceMode::Dark, -6, 50));
        assert!(
            darker.panel.luminance() < AppearancePalette::resolve(&AppearanceSettings::standard()).panel.luminance()
        );
    }

    #[test]
    fn system_follows_the_os_look_and_the_other_modes_ignore_it() {
        for os_dark in [true, false] {
            assert_eq!(AppearanceMode::Dark.resolved(os_dark), AppearanceMode::Dark);
            assert_eq!(AppearanceMode::Light.resolved(os_dark), AppearanceMode::Light);
        }
        assert_eq!(AppearanceMode::System.resolved(true), AppearanceMode::Dark);
        assert_eq!(AppearanceMode::System.resolved(false), AppearanceMode::Light);
        let sys = AppearanceSettings::new(AppearanceMode::System, 0, 50);
        let dark = AppearancePalette::resolve_with(&sys, true);
        let light = AppearancePalette::resolve_with(&sys, false);
        assert_eq!(dark, AppearancePalette::resolve_with(&AppearanceSettings::standard(), false));
        assert_eq!(
            light,
            AppearancePalette::resolve_with(&AppearanceSettings::new(AppearanceMode::Light, 0, 50), true)
        );
        assert!(dark.is_dark() && !light.is_dark());
        assert_eq!(AppearanceMode::from_raw("system"), Some(AppearanceMode::System));
    }

    #[test]
    fn settings_clamp_and_persist() {
        let s = AppearanceSettings::new(AppearanceMode::Light, 40, -3);
        assert_eq!(s.background(), 6);
        assert_eq!(s.contrast(), 0);
        let mut d = MemoryDefaults::default();
        assert_eq!(AppearanceSettings::from_defaults(&d), AppearanceSettings::standard());
        s.save(&mut d);
        assert_eq!(d.string("sq.appearance.mode").as_deref(), Some("light"));
        assert_eq!(AppearanceSettings::from_defaults(&d), s);
    }
}
