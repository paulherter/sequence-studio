// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FontResolver+Portable.swift
//! Font resolution without a platform font manager: the bundled families, then the installed ones, looked up
//! by family name or file name, as Core Text picks them (`PortableFontMatch`: named instance nearest the weight, italic
//! file, optical size from the point size, style axes).
//! Fonts the user installed (Windows, Linux and Mac font folders) are found by `system_fonts` when a name is not bundled.

use crate::font_resolver::{Axis, FontResolver};
use crate::portable_font_match::PortableFontMatch;
use crate::text_backend_portable::{PlatformFont, PortableFont};
use crate::text_style::TextStyle;

impl FontResolver {
    /// Weight trait of the chosen face.
    pub fn weight_trait_of(font: &PlatformFont) -> f64 {
        font.choice.weight_trait
    }

    /// The variation axes of the font a name resolves to.
    pub fn axes_for_font_name(name: &str) -> Vec<Axis> {
        PortableFontMatch::axes_for_font_name(name)
    }

    /// The variation axes of a resolved font.
    pub fn axes_of(font: &PlatformFont) -> Vec<Axis> {
        font.face()
            .variations
            .as_ref()
            .map(|v| {
                v.axes
                    .iter()
                    .map(|a| Axis {
                        tag: a.tag.clone(),
                        name: a.tag.clone(),
                        minimum: a.minimum,
                        maximum: a.maximum,
                        default_value: a.default_value,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Resolves a style to a font. Never fails on a missing fonts folder or an unknown name: `choose` falls back to
    /// Inter and, without the folder, to the Inter face built into the program.
    pub(crate) fn resolve_font(style: &TextStyle) -> PlatformFont {
        let Some(choice) = PortableFontMatch::choose(
            &style.font_name,
            style.weight,
            style.italic,
            style.size,
            style.font_axes.as_ref(),
        ) else {
            // Unreachable: the built-in face is a constant that `the_built_in_inter_face_parses` checks.
            panic!("built-in Inter face does not parse");
        };
        PortableFont::new(choice, style.size)
    }
}
