// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextStyle.swift (saved text style types, same JSON keys as the Swift Codable output)

use crate::caption_karaoke::TextHighlight;
use crate::inter_font;
use crate::style_kit_text::TextStyleTokens;
use crate::text_layout::TextRect;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{BTreeMap, BTreeSet};

/// sRGB color with components clamped to 0...1.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct RGBAColor {
    /// Red.
    pub red: f64,
    /// Green.
    pub green: f64,
    /// Blue.
    pub blue: f64,
    /// Alpha.
    pub alpha: f64,
}

impl RGBAColor {
    /// Opaque white.
    pub const WHITE: RGBAColor = RGBAColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };
    /// Opaque black.
    pub const BLACK: RGBAColor = RGBAColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    /// Fully transparent.
    pub const CLEAR: RGBAColor = RGBAColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0 };

    /// Components clamped to 0...1.
    pub fn new(red: f64, green: f64, blue: f64, alpha: f64) -> Self {
        fn c(v: f64) -> f64 {
            1.0_f64.min(0.0_f64.max(v))
        }
        RGBAColor { red: c(red), green: c(green), blue: c(blue), alpha: c(alpha) }
    }

    /// Opaque color.
    pub fn rgb(red: f64, green: f64, blue: f64) -> Self {
        Self::new(red, green, blue, 1.0)
    }
}

/// Font weight, CSS-style numbers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum FontWeight {
    /// 100.
    Thin = 100,
    /// 300.
    Light = 300,
    /// 400.
    Regular = 400,
    /// 500.
    Medium = 500,
    /// 600.
    Semibold = 600,
    /// 700.
    Bold = 700,
    /// 800.
    Heavy = 800,
    /// 900.
    Black = 900,
}

impl FontWeight {
    /// The number stored in files.
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// The weight for a stored number.
    pub fn from_raw(v: i64) -> Option<Self> {
        Some(match v {
            100 => Self::Thin,
            300 => Self::Light,
            400 => Self::Regular,
            500 => Self::Medium,
            600 => Self::Semibold,
            700 => Self::Bold,
            800 => Self::Heavy,
            900 => Self::Black,
            _ => return None,
        })
    }
}

impl Serialize for FontWeight {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for FontWeight {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = i64::deserialize(d)?;
        Self::from_raw(v).ok_or_else(|| serde::de::Error::custom(format!("unknown font weight {v}")))
    }
}

/// Horizontal alignment.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextAlignment {
    /// Left.
    Left,
    /// Center.
    Center,
    /// Right.
    Right,
}

/// Vertical placement of the text inside an area text box (point text has no box height, so it never applies).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextVerticalAlignment {
    /// Top.
    Top,
    /// Middle.
    Middle,
    /// Bottom.
    Bottom,
}

/// Base writing direction of a paragraph. `TextStyle.direction == None` is automatic: the first strong character decides.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextDirection {
    /// Left to right.
    LeftToRight,
    /// Right to left.
    RightToLeft,
}

impl TextDirection {
    /// Whether a paragraph is laid out right to left: the override, else the first strong character (Hebrew, Arabic,
    /// Syriac, Thaana, N'Ko and their presentation forms are right to left; any other letter is left to right).
    pub fn is_right_to_left(paragraph: &str, override_direction: Option<TextDirection>) -> bool {
        if let Some(o) = override_direction {
            return o == TextDirection::RightToLeft;
        }
        for u in paragraph.chars() {
            if Self::is_strong_rtl(u as u32) {
                return true;
            }
            if u.is_alphabetic() {
                return false;
            }
        }
        false
    }

    fn is_strong_rtl(v: u32) -> bool {
        matches!(v, 0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF | 0x10800..=0x10FFF | 0x1E800..=0x1EFFF)
    }
}

fn at_least_one<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    Ok(f64::deserialize(d)?.max(1.0))
}

fn not_negative<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    Ok(f64::deserialize(d)?.max(0.0))
}

fn not_negative_or_zero<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    Ok(Option::<f64>::deserialize(d)?.unwrap_or(0.0).max(0.0))
}

/// Area text box in sequence pixels. `width` makes the text wrap; `height` gives the vertical alignment room.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextBox {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl TextBox {
    /// Both sides at least 1.
    pub fn new(width: f64, height: f64) -> Self {
        TextBox { width: width.max(1.0), height: height.max(1.0) }
    }
}

/// Space between the text and its background box.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct BoxPadding {
    /// Left and right.
    pub horizontal: f64,
    /// Top and bottom.
    pub vertical: f64,
}

impl BoxPadding {
    /// No padding.
    pub const ZERO: BoxPadding = BoxPadding { horizontal: 0.0, vertical: 0.0 };

    /// Both at least 0.
    pub fn new(horizontal: f64, vertical: f64) -> Self {
        BoxPadding { horizontal: horizontal.max(0.0), vertical: vertical.max(0.0) }
    }
}

/// Where the stroke sits on the glyph outline. `width` is the visible thickness either way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StrokePosition {
    /// Outside the glyphs: the fill stays whole, the ink grows by the width (the default, and what older files mean).
    #[default]
    Outside,
    /// Centered on the outline, drawn over the fill: half of it eats into the glyph, the ink grows by half the width.
    Centre,
}

/// Footage fill: the glyphs take their look from the picture below the text clip instead of a color.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextFootageFill {
    /// The glyphs are a window onto what is below: it shows only inside them, the rest of the frame is cleared.
    Stencil,
    /// The glyphs invert what is below them.
    Inverted,
}

/// Outline around the glyphs.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextStroke {
    /// Stroke color.
    pub color: RGBAColor,
    /// Visible thickness.
    #[serde(deserialize_with = "not_negative")]
    pub width: f64,
    /// Where it sits on the outline.
    #[serde(default)]
    pub position: StrokePosition,
}

impl TextStroke {
    /// Width at least 0.
    pub fn new(color: RGBAColor, width: f64, position: StrokePosition) -> Self {
        TextStroke { color, width: width.max(0.0), position }
    }

    /// How far the stroke reaches beyond the glyph outline.
    pub fn reach(&self) -> f64 {
        if self.position == StrokePosition::Outside { self.width } else { self.width / 2.0 }
    }
}

/// Box behind the text.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextBackground {
    /// Fill color.
    pub color: RGBAColor,
    /// Space around the text.
    pub padding: BoxPadding,
    /// Corner radius.
    pub corner_radius: f64,
}

impl TextBackground {
    /// Corner radius at least 0.
    pub fn new(color: RGBAColor, padding: BoxPadding, corner_radius: f64) -> Self {
        TextBackground { color, padding, corner_radius: corner_radius.max(0.0) }
    }
}

/// Drop shadow.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextShadow {
    /// Shadow color.
    pub color: RGBAColor,
    /// Offset in layout space (sequence pixels, y down): positive `offset_y` moves the shadow down.
    pub offset_x: f64,
    /// See `offset_x`.
    pub offset_y: f64,
    /// Blur radius.
    pub blur: f64,
    /// The light angle remembered while the distance is 0 (the offset alone cannot carry it); `None` = never set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resting_angle: Option<f64>,
    /// Premiere's shadow "Size": the glyph shape grows by this many px (layout space) before the blur, so thin glyphs still
    /// cast a dense shadow. 0 = off (projects saved before it existed decode as 0). Never negative: use `set_spread`.
    #[serde(default, deserialize_with = "not_negative_or_zero")]
    pub spread: f64,
}

impl TextShadow {
    /// Offset form; blur at least 0.
    pub fn new(color: RGBAColor, offset_x: f64, offset_y: f64, blur: f64) -> Self {
        TextShadow { color, offset_x, offset_y, blur: blur.max(0.0), resting_angle: None, spread: 0.0 }
    }

    /// Photoshop/Premiere convention: `angle` is the light direction in degrees (0 = from the right, counter-clockwise),
    /// so 135 casts the shadow down and to the right.
    pub fn from_angle(color: RGBAColor, angle: f64, distance: f64, blur: f64) -> Self {
        let a = angle * std::f64::consts::PI / 180.0;
        let mut s = Self::new(color, -a.cos() * distance, a.sin() * distance, blur);
        let mut n = angle % 360.0;
        if n < 0.0 {
            n += 360.0;
        }
        s.resting_angle = Some(n);
        s
    }

    /// Sets the spread, clamped to 0 or more.
    pub fn set_spread(&mut self, v: f64) {
        self.spread = if v < 0.0 { 0.0 } else { v };
    }

    /// Light angle in degrees, 0..<360 (135 when there is no offset).
    pub fn angle(&self) -> f64 {
        if self.distance() <= 1e-9 {
            return self.resting_angle.unwrap_or(135.0);
        }
        let mut d = self.offset_y.atan2(-self.offset_x) * 180.0 / std::f64::consts::PI;
        if d < 0.0 {
            d += 360.0;
        }
        d
    }

    /// Length of the offset.
    pub fn distance(&self) -> f64 {
        (self.offset_x * self.offset_x + self.offset_y * self.offset_y).sqrt()
    }

    /// Shadow opacity = alpha of the color.
    pub fn opacity(&self) -> f64 {
        self.color.alpha
    }
}

/// List marker put in front of every non-empty paragraph (`None` = plain text, every older file).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextListKind {
    /// A dot.
    Bullet,
    /// 1. 2. 3.
    Numbered,
}

impl TextListKind {
    /// The marker of the `number`-th (1-based) non-empty paragraph, with its trailing gap.
    pub fn marker(self, number: i64) -> String {
        match self {
            Self::Bullet => "\u{2022} ".to_string(),
            Self::Numbered => format!("{number}. "),
        }
    }
}

/// Two-color linear gradient that fills the glyphs instead of `TextStyle.color`. `angle` is in degrees, 0 = start at the
/// left and end at the right, 90 = start at the top and end at the bottom (y down).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextGradient {
    /// Start color.
    pub start: RGBAColor,
    /// End color.
    pub end: RGBAColor,
    /// Degrees.
    pub angle: f64,
}

/// A point (x, y) in layout space.
pub type TextPoint = (f64, f64);

impl TextGradient {
    /// Start and end points of the gradient axis across `rect` (layout space): the axis runs through the center and
    /// spans the rect's extent along the angle, so corners take the pure end colors.
    pub fn axis(&self, rect: &TextRect) -> (TextPoint, TextPoint) {
        let a = self.angle * std::f64::consts::PI / 180.0;
        let dx = a.cos();
        let dy = a.sin();
        let half = ((rect.width * dx).abs() + (rect.height * dy).abs()) / 2.0;
        let cx = rect.x + rect.width / 2.0;
        let cy = rect.y + rect.height / 2.0;
        ((cx - dx * half, cy - dy * half), (cx + dx * half, cy + dy * half))
    }
}

/// The look of the second line of a two-style text (N4: small top line over a big bottom line). Only the glyph look
/// changes; stroke, shadow, background, alignment, tracking and line spacing stay block-wide (the clip style).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextLineStyle {
    /// Font.
    pub font_name: String,
    /// Size, at least 1.
    #[serde(deserialize_with = "at_least_one")]
    pub size: f64,
    /// Weight.
    pub weight: FontWeight,
    /// Fill color.
    pub color: RGBAColor,
    /// Italic.
    #[serde(default)]
    pub italic: bool,
}

impl TextLineStyle {
    /// Size at least 1.
    pub fn new(font_name: &str, size: f64, weight: FontWeight, color: RGBAColor, italic: bool) -> Self {
        TextLineStyle { font_name: font_name.to_string(), size: size.max(1.0), weight, color, italic }
    }

    /// The glyph look of `style` (a fresh second line starts as the first one).
    pub fn from_style(style: &TextStyle) -> Self {
        Self::new(&style.font_name, style.size, style.weight, style.color, style.italic)
    }
}

/// The look of a text.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextStyle {
    /// PostScript name (e.g. "Helvetica-Bold") or family name; resolved by the layout/renderer.
    pub font_name: String,
    /// Size, at least 1.
    #[serde(deserialize_with = "at_least_one")]
    pub size: f64,
    /// Weight.
    pub weight: FontWeight,
    /// Fill color.
    pub color: RGBAColor,
    /// Outline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke: Option<TextStroke>,
    /// Box behind the text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<TextBackground>,
    /// Drop shadow.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow: Option<TextShadow>,
    /// Alignment.
    pub alignment: TextAlignment,
    /// Extra spacing between lines in points (added to the font's natural leading).
    pub line_spacing: f64,
    /// Extra space after every character in points (Premiere "Tracking"); negative tightens.
    #[serde(default)]
    pub tracking: f64,
    /// Italic.
    #[serde(default)]
    pub italic: bool,
    /// Only used for area text (a box with a height).
    #[serde(default = "default_vertical_alignment")]
    pub vertical_alignment: TextVerticalAlignment,
    /// All caps: the glyphs are drawn in capitals, the stored text stays as typed.
    #[serde(default)]
    pub all_caps: bool,
    /// Line styles: a bar under the baseline, through the x-height and over the capitals, drawn in the fill color across
    /// each line (`TextDecorations`). Block-wide; older files decode as off.
    #[serde(default)]
    pub underline: bool,
    /// See `underline`.
    #[serde(default)]
    pub strikethrough: bool,
    /// See `underline`.
    #[serde(default)]
    pub overline: bool,
    /// Two-style text: every paragraph after the first is drawn in this look. `None` = one style (all older files).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub second_line: Option<TextLineStyle>,
    /// W8.3: fields bound to the project's style kit tokens (see `resolved`). `None` = every field is a literal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<TextStyleTokens>,
    /// Footage fill (`None` = the `color` fills the glyphs, every older file). Drawn as a white glyph without outline, shadow
    /// or background (`drawn`); the compositor turns it into a stencil or an inversion.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub footage_fill: Option<TextFootageFill>,
    /// Base writing direction; `None` = automatic per paragraph (every older file). Alignment stays physical
    /// (left/center/right), the direction changes how mixed-direction runs order and where punctuation sits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direction: Option<TextDirection>,
    /// Variable-font axis values by four-letter tag ("wght", "wdth", "opsz", "slnt"). `None` = no axis set (every older
    /// file): the discrete `weight` picks the face. A value wins over `weight` for its axis and is clamped to the
    /// font's range; tags the font lacks are ignored. Animate by interpolating (`interpolate_axes`). Optional JSON key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_axes: Option<BTreeMap<String, f64>>,
    /// Shrink to box: in an area text box the glyphs scale down until the block fits the box (never up). `None`/false = off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_fit: Option<bool>,
    /// Bullets or numbers in front of every non-empty paragraph. `None` = plain.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub list: Option<TextListKind>,
    /// Gradient fill of the glyphs (`None` = the solid `color`). Karaoke highlights and footage fills win over it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gradient: Option<TextGradient>,
    /// Per-paragraph looks: paragraph `i` is drawn in `line_styles[i]`; paragraphs past the list fall back to
    /// `second_line`, then the clip style. `None` = none (every older file).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_styles: Option<Vec<TextLineStyle>>,
}

fn default_vertical_alignment() -> TextVerticalAlignment {
    TextVerticalAlignment::Top
}

impl Default for TextStyle {
    fn default() -> Self {
        TextStyle {
            font_name: Self::default_font_name().to_string(),
            size: 48.0,
            weight: FontWeight::Regular,
            color: RGBAColor::WHITE,
            stroke: None,
            background: None,
            shadow: None,
            alignment: TextAlignment::Center,
            line_spacing: 0.0,
            tracking: 0.0,
            italic: false,
            vertical_alignment: TextVerticalAlignment::Top,
            all_caps: false,
            underline: false,
            strikethrough: false,
            overline: false,
            second_line: None,
            tokens: None,
            footage_fill: None,
            direction: None,
            font_axes: None,
            auto_fit: None,
            list: None,
            gradient: None,
            line_styles: None,
        }
    }
}

impl TextStyle {
    /// Font of new text and captions: bundled Inter (`inter_font`). Saved styles keep the font they were saved with.
    pub fn default_font_name() -> &'static str {
        inter_font::FAMILY_NAME
    }

    /// The default style with the given font, size (at least 1), weight and color.
    pub fn new(font_name: &str, size: f64, weight: FontWeight, color: RGBAColor) -> Self {
        TextStyle { font_name: font_name.to_string(), size: size.max(1.0), weight, color, ..Self::default() }
    }

    /// The style the raster is drawn in: the style itself, or for a footage fill the plain glyph without outline, shadow
    /// and background (the picture below supplies the look). A stencil keeps the fill color at full opacity (only the
    /// glyph's coverage matters to the stencil, and a transition side that draws it plain shows the title's own color);
    /// an inverted fill is white, which Difference turns into the negative.
    pub fn drawn(&self) -> TextStyle {
        let Some(fill) = self.footage_fill else { return self.clone() };
        let mut s = self.clone();
        s.color = Self::footage_color(self.color, fill);
        s.stroke = None;
        s.shadow = None;
        s.background = None;
        if let Some(second) = s.second_line.as_mut() {
            second.color = Self::footage_color(second.color, fill);
        }
        s.gradient = None;
        if let Some(own) = s.line_styles.as_mut() {
            for l in own.iter_mut() {
                l.color = Self::footage_color(l.color, fill);
            }
        }
        s
    }

    /// `highlight` (karaoke) in the look of `drawn`.
    pub fn drawn_highlight(&self, highlight: Option<TextHighlight>) -> Option<TextHighlight> {
        let (Some(fill), Some(mut h)) = (self.footage_fill, highlight.clone()) else { return highlight };
        h.color = Self::footage_color(h.color, fill);
        Some(h)
    }

    fn footage_color(c: RGBAColor, fill: TextFootageFill) -> RGBAColor {
        match fill {
            TextFootageFill::Inverted => RGBAColor::WHITE,
            TextFootageFill::Stencil => RGBAColor::rgb(c.red, c.green, c.blue),
        }
    }

    /// The style line group `index` is drawn in: 0 = the first paragraph (this style), 1 = every later paragraph (the
    /// `second_line` look over this style's block-wide values). Both come back without a `second_line`.
    pub fn line_style(&self, index: usize) -> TextStyle {
        let mut s = self.clone();
        s.second_line = None;
        s.line_styles = None;
        let l = if let Some(own) = self.line_styles.as_ref().and_then(|o| o.get(index)) {
            own
        } else if let (true, Some(second)) = (index > 0, self.second_line.as_ref()) {
            second
        } else {
            return s;
        };
        s.font_name = l.font_name.clone();
        s.size = l.size;
        s.weight = l.weight;
        s.color = l.color;
        s.italic = l.italic;
        s
    }

    /// How many distinct paragraph looks the layout needs: 1 plain, 2 with a second line; per-paragraph styles add the
    /// looks of the list plus one for the paragraphs after it.
    pub fn line_style_count(&self) -> usize {
        let base = if self.second_line.is_none() { 1 } else { 2 };
        match &self.line_styles {
            None => base,
            Some(own) => own.len().max(base) + 1,
        }
    }

    /// Whether paragraphs differ in look (the fill pass then colors every line itself).
    pub fn has_line_looks(&self) -> bool {
        self.line_style_count() > 1
    }

    /// Axis values between `a` and `b` at `t` (0...1), per tag; a tag set on one side only keeps that value.
    pub fn interpolate_axes(
        a: Option<&BTreeMap<String, f64>>,
        b: Option<&BTreeMap<String, f64>>,
        t: f64,
    ) -> Option<BTreeMap<String, f64>> {
        if a.is_none() && b.is_none() {
            return None;
        }
        let mut out = BTreeMap::new();
        let keys: BTreeSet<&String> =
            a.into_iter().flat_map(|m| m.keys()).chain(b.into_iter().flat_map(|m| m.keys())).collect();
        for k in keys {
            match (a.and_then(|m| m.get(k)), b.and_then(|m| m.get(k))) {
                (Some(x), Some(y)) => {
                    out.insert(k.clone(), x + (y - x) * t);
                }
                (Some(x), None) => {
                    out.insert(k.clone(), *x);
                }
                (None, Some(y)) => {
                    out.insert(k.clone(), *y);
                }
                (None, None) => {}
            }
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_sane() {
        let s = TextStyle::default();
        assert!(s.size > 0.0);
        assert_eq!(s.alignment, TextAlignment::Center);
        assert!(s.stroke.is_none() && s.background.is_none() && s.shadow.is_none());
        assert_eq!(s.color, RGBAColor::WHITE);
    }

    #[test]
    fn codable_round_trip_full_style() {
        let s = TextStyle {
            font_name: "Helvetica-Bold".into(),
            size: 64.0,
            weight: FontWeight::Bold,
            color: RGBAColor::new(1.0, 0.5, 0.25, 0.9),
            stroke: Some(TextStroke::new(RGBAColor::BLACK, 4.0, StrokePosition::Outside)),
            background: Some(TextBackground::new(RGBAColor::new(0.0, 0.0, 0.0, 0.6), BoxPadding::new(16.0, 8.0), 12.0)),
            shadow: Some(TextShadow::new(RGBAColor::BLACK, 2.0, -3.0, 5.0)),
            alignment: TextAlignment::Right,
            line_spacing: 6.0,
            ..TextStyle::default()
        };
        let json = serde_json::to_string(&s).unwrap_or_default();
        let back: Result<TextStyle, _> = serde_json::from_str(&json);
        assert_eq!(back.ok(), Some(s));
    }

    #[test]
    fn styles_with_different_sizes_differ() {
        let a = TextStyle::default();
        let mut b = TextStyle::default();
        assert_eq!(a, b);
        b.size = a.size + 1.0;
        assert_ne!(a, b);
        let mut c = a.clone();
        c.shadow = Some(TextShadow::new(RGBAColor::BLACK, 1.0, 1.0, 2.0));
        assert_ne!(c, TextStyle::default());
    }

    #[test]
    fn color_clamps_to_unit_range() {
        let c = RGBAColor::new(2.0, -1.0, 0.5, 5.0);
        assert!(c.red == 1.0 && c.green == 0.0 && c.blue == 0.5 && c.alpha == 1.0);
    }

    #[test]
    fn weight_ordering_and_value() {
        assert!(FontWeight::Regular < FontWeight::Bold);
        assert_eq!(FontWeight::Bold.raw_value(), 700);
    }

    #[test]
    fn size_and_padding_are_non_negative() {
        assert_eq!(TextStyle::new("Inter", -5.0, FontWeight::Regular, RGBAColor::WHITE).size, 1.0);
        let p = BoxPadding::new(-1.0, 2.0);
        assert!(p.horizontal == 0.0 && p.vertical == 2.0);
    }

    #[test]
    fn shadow_spread_defaults_to_zero_and_old_projects_still_decode() {
        let old = r#"{"color":{"red":0,"green":0,"blue":0,"alpha":0.5},"offsetX":1,"offsetY":2,"blur":3}"#;
        let s: Result<TextShadow, _> = serde_json::from_str(old);
        let s = s.ok();
        assert_eq!(s.map(|s| (s.spread, s.blur, s.offset_y)), Some((0.0, 3.0, 2.0)));
        let mut sh = TextShadow::new(RGBAColor::BLACK, 0.0, 0.0, 0.0);
        sh.set_spread(7.0);
        let back: Result<TextShadow, _> = serde_json::from_str(&serde_json::to_string(&sh).unwrap_or_default());
        assert_eq!(back.ok().map(|b| b.spread), Some(7.0));
    }

    #[test]
    fn negative_spread_is_clamped_to_zero() {
        let mut s = TextShadow::new(RGBAColor::BLACK, 0.0, 0.0, 0.0);
        s.set_spread(-5.0);
        assert_eq!(s.spread, 0.0);
    }

    #[test]
    fn shadow_angle_round_trips_and_rests() {
        let s = TextShadow::from_angle(RGBAColor::BLACK, 135.0, 10.0, 2.0);
        assert!((s.angle() - 135.0).abs() < 1e-9);
        let rest = TextShadow::from_angle(RGBAColor::BLACK, 45.0, 0.0, 2.0);
        assert_eq!(rest.angle(), 45.0);
        assert_eq!(TextShadow::new(RGBAColor::BLACK, 0.0, 0.0, 0.0).angle(), 135.0);
    }

    #[test]
    fn direction_follows_first_strong_character() {
        assert!(TextDirection::is_right_to_left("שלום", None));
        assert!(!TextDirection::is_right_to_left("123 abc", None));
        assert!(TextDirection::is_right_to_left("abc", Some(TextDirection::RightToLeft)));
    }

    #[test]
    fn line_styles_and_axes() {
        let mut s = TextStyle::default();
        assert_eq!(s.line_style_count(), 1);
        s.second_line = Some(TextLineStyle::from_style(&TextStyle { size: 20.0, ..TextStyle::default() }));
        assert_eq!(s.line_style_count(), 2);
        assert_eq!(s.line_style(1).size, 20.0);
        assert_eq!(s.line_style(0).size, 48.0);
        let a: BTreeMap<String, f64> = [("wght".to_string(), 100.0)].into();
        let b: BTreeMap<String, f64> = [("wght".to_string(), 300.0), ("wdth".to_string(), 80.0)].into();
        let m = TextStyle::interpolate_axes(Some(&a), Some(&b), 0.5);
        assert_eq!(m.as_ref().and_then(|m| m.get("wght")), Some(&200.0));
        assert_eq!(m.as_ref().and_then(|m| m.get("wdth")), Some(&80.0));
    }
}
