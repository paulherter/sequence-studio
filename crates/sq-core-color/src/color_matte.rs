// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorMatte.swift
//! Color Matte: a flat color layer for when there is no video. It is the `solid` generator the engine already
//! renders (transition dips, imported mattes), as an ordinary clip: move, trim, effects, opacity and blend modes work.
//! The payload is three display-encoded RGB bytes, so no project file change.

use sq_core_model::{Clip, GeneratorRef};

/// The kind of the solid generator.
const SOLID_KIND: &str = "solid";

/// A Color Matte color: three display-encoded RGB bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ColorMatteColor {
    /// Red.
    pub r: u8,
    /// Green.
    pub g: u8,
    /// Blue.
    pub b: u8,
}

impl ColorMatteColor {
    /// The color a new Color Matte starts with.
    pub const DEFAULT: ColorMatteColor = ColorMatteColor { r: 40, g: 40, b: 46 };

    /// The three bytes of the generator payload.
    pub fn bytes(self) -> [u8; 3] {
        [self.r, self.g, self.b]
    }
}

/// Color Matte view of a [`GeneratorRef`].
pub trait ColorMatteGeneratorExt {
    /// The solid generator of a Color Matte color.
    fn color_matte(c: ColorMatteColor) -> GeneratorRef;
    /// The color of a solid generator; `None` for other kinds or a payload that is not three bytes.
    fn matte_color(&self) -> Option<ColorMatteColor>;
}

impl ColorMatteGeneratorExt for GeneratorRef {
    fn color_matte(c: ColorMatteColor) -> GeneratorRef {
        GeneratorRef { kind: SOLID_KIND.to_string(), payload: c.bytes().to_vec(), payload_version: 1 }
    }

    fn matte_color(&self) -> Option<ColorMatteColor> {
        match (self.kind == SOLID_KIND, self.payload.as_slice()) {
            (true, [r, g, b]) => Some(ColorMatteColor { r: *r, g: *g, b: *b }),
            _ => None,
        }
    }
}

/// Color Matte view of a [`Clip`].
pub trait ColorMatteClipExt {
    /// A Color Matte clip (solid generator).
    fn is_color_matte(&self) -> bool;
    /// The matte's color.
    fn matte_color(&self) -> Option<ColorMatteColor>;
}

impl ColorMatteClipExt for Clip {
    fn is_color_matte(&self) -> bool {
        self.generator.as_ref().is_some_and(|g| g.kind == SOLID_KIND)
    }

    fn matte_color(&self) -> Option<ColorMatteColor> {
        self.generator.as_ref().and_then(GeneratorRef::matte_color)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_payload_is_three_bytes_and_round_trips() {
        let c = ColorMatteColor { r: 1, g: 2, b: 3 };
        let g = GeneratorRef::color_matte(c);
        assert_eq!((g.kind.as_str(), g.payload.as_slice()), ("solid", [1_u8, 2, 3].as_slice()));
        assert_eq!(g.matte_color(), Some(c));
        assert_eq!(GeneratorRef::color_matte(ColorMatteColor::DEFAULT).payload, [40, 40, 46]);
        let bad = GeneratorRef { payload: vec![1, 2], ..g.clone() };
        assert_eq!(bad.matte_color(), None);
        assert_eq!(GeneratorRef { kind: "text".into(), ..g }.matte_color(), None);
    }
}
