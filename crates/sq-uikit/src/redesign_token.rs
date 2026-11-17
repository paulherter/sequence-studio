//! One redesign color token: a `0xRRGGBBAA` value for Dark and one for Light.

use crate::appearance_palette::PaletteColor;

/// A color with a Dark and a Light value, each `0xRRGGBBAA` (alpha `FF` for opaque colors).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Token {
    dark: u32,
    light: u32,
}

impl Token {
    /// A token from its Dark and Light `0xRRGGBBAA` values.
    pub const fn new(dark: u32, light: u32) -> Self {
        Token { dark, light }
    }

    /// The `0xRRGGBBAA` value of the mode.
    pub const fn rgba(self, dark: bool) -> u32 {
        if dark { self.dark } else { self.light }
    }

    /// The `0xRRGGBB` part of the mode's value.
    pub const fn rgb(self, dark: bool) -> u32 {
        self.rgba(dark) >> 8
    }

    /// The alpha (0...1) of the mode's value.
    pub fn alpha(self, dark: bool) -> f64 {
        f64::from(self.rgba(dark) & 0xFF) / 255.0
    }

    /// The mode's value as a palette color.
    pub fn palette_color(self, dark: bool) -> PaletteColor {
        PaletteColor::from_hex(self.rgb(dark), self.alpha(dark))
    }
}
