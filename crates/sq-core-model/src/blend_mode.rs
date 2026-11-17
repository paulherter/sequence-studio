// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BlendMode.swift

use serde::{Deserialize, Serialize};

/// Opacity > Blend Mode (v22). Normal is plain alpha-over.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BlendMode {
    /// `normal`.
    Normal,
    /// `dissolve`.
    Dissolve,
    /// `darken`.
    Darken,
    /// `multiply`.
    Multiply,
    /// `colorBurn`.
    ColorBurn,
    /// `linearBurn`.
    LinearBurn,
    /// `darkerColor`.
    DarkerColor,
    /// `lighten`.
    Lighten,
    /// `screen`.
    Screen,
    /// `colorDodge`.
    ColorDodge,
    /// `add`.
    Add,
    /// `lighterColor`.
    LighterColor,
    /// `overlay`.
    Overlay,
    /// `softLight`.
    SoftLight,
    /// `hardLight`.
    HardLight,
    /// `vividLight`.
    VividLight,
    /// `linearLight`.
    LinearLight,
    /// `pinLight`.
    PinLight,
    /// `hardMix`.
    HardMix,
    /// `difference`.
    Difference,
    /// `exclusion`.
    Exclusion,
    /// `subtract`.
    Subtract,
    /// `divide`.
    Divide,
    /// `hue`.
    Hue,
    /// `saturation`.
    Saturation,
    /// `color`.
    Color,
    /// `luminosity`.
    Luminosity,
}

impl BlendMode {
    /// Every mode in the editors' standard menu order (Swift `allCases`).
    pub const ALL: [BlendMode; 27] = [
        BlendMode::Normal,
        BlendMode::Dissolve,
        BlendMode::Darken,
        BlendMode::Multiply,
        BlendMode::ColorBurn,
        BlendMode::LinearBurn,
        BlendMode::DarkerColor,
        BlendMode::Lighten,
        BlendMode::Screen,
        BlendMode::ColorDodge,
        BlendMode::Add,
        BlendMode::LighterColor,
        BlendMode::Overlay,
        BlendMode::SoftLight,
        BlendMode::HardLight,
        BlendMode::VividLight,
        BlendMode::LinearLight,
        BlendMode::PinLight,
        BlendMode::HardMix,
        BlendMode::Difference,
        BlendMode::Exclusion,
        BlendMode::Subtract,
        BlendMode::Divide,
        BlendMode::Hue,
        BlendMode::Saturation,
        BlendMode::Color,
        BlendMode::Luminosity,
    ];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            BlendMode::Normal => "Normal",
            BlendMode::Dissolve => "Dissolve",
            BlendMode::Darken => "Darken",
            BlendMode::Multiply => "Multiply",
            BlendMode::ColorBurn => "Color Burn",
            BlendMode::LinearBurn => "Linear Burn",
            BlendMode::DarkerColor => "Darker Color",
            BlendMode::Lighten => "Lighten",
            BlendMode::Screen => "Screen",
            BlendMode::ColorDodge => "Color Dodge",
            BlendMode::Add => "Add",
            BlendMode::LighterColor => "Lighter Color",
            BlendMode::Overlay => "Overlay",
            BlendMode::SoftLight => "Soft Light",
            BlendMode::HardLight => "Hard Light",
            BlendMode::VividLight => "Vivid Light",
            BlendMode::LinearLight => "Linear Light",
            BlendMode::PinLight => "Pin Light",
            BlendMode::HardMix => "Hard Mix",
            BlendMode::Difference => "Difference",
            BlendMode::Exclusion => "Exclusion",
            BlendMode::Subtract => "Subtract",
            BlendMode::Divide => "Divide",
            BlendMode::Hue => "Hue",
            BlendMode::Saturation => "Saturation",
            BlendMode::Color => "Color",
            BlendMode::Luminosity => "Luminosity",
        }
    }

    /// The menu section this mode belongs to (0 Normal, 1 Darken, 2 Lighten, 3 Contrast, 4 Inversion, 5 Component).
    pub fn group(self) -> i64 {
        match self {
            BlendMode::Normal | BlendMode::Dissolve => 0,
            BlendMode::Darken
            | BlendMode::Multiply
            | BlendMode::ColorBurn
            | BlendMode::LinearBurn
            | BlendMode::DarkerColor => 1,
            BlendMode::Lighten
            | BlendMode::Screen
            | BlendMode::ColorDodge
            | BlendMode::Add
            | BlendMode::LighterColor => 2,
            BlendMode::Overlay
            | BlendMode::SoftLight
            | BlendMode::HardLight
            | BlendMode::VividLight
            | BlendMode::LinearLight
            | BlendMode::PinLight
            | BlendMode::HardMix => 3,
            BlendMode::Difference | BlendMode::Exclusion | BlendMode::Subtract | BlendMode::Divide => 4,
            BlendMode::Hue | BlendMode::Saturation | BlendMode::Color | BlendMode::Luminosity => 5,
        }
    }

    /// `ALL` cut into the menu sections (a separator goes between two of them).
    pub fn menu_sections() -> Vec<Vec<BlendMode>> {
        let mut out: Vec<Vec<BlendMode>> = Vec::new();
        for m in Self::ALL {
            match out.last_mut() {
                Some(section) if section.last().is_some_and(|l| l.group() == m.group()) => section.push(m),
                _ => out.push(vec![m]),
            }
        }
        out
    }

    /// The five modes of v22. Every other one needs a newer build to open (`minimum_file_version`).
    pub fn is_legacy(self) -> bool {
        self.minimum_file_version() == 22
    }

    /// The first project file version that knows this mode: 22 for the first five, 41 for the W9.6 set, 55 for the
    /// rest of the standard set.
    pub fn minimum_file_version(self) -> i64 {
        match self {
            BlendMode::Normal | BlendMode::Multiply | BlendMode::Screen | BlendMode::Add | BlendMode::Overlay => 22,
            BlendMode::Darken
            | BlendMode::ColorBurn
            | BlendMode::LinearBurn
            | BlendMode::Lighten
            | BlendMode::ColorDodge
            | BlendMode::SoftLight
            | BlendMode::HardLight
            | BlendMode::Difference
            | BlendMode::Exclusion => 41,
            _ => 55,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn the_full_set_has_27_modes_in_six_sections() {
        assert_eq!(BlendMode::ALL.len(), 27);
        let sections = BlendMode::menu_sections();
        assert_eq!(sections.len(), 6);
        assert_eq!(sections[0], [BlendMode::Normal, BlendMode::Dissolve]);
        assert_eq!(
            sections[1],
            [
                BlendMode::Darken,
                BlendMode::Multiply,
                BlendMode::ColorBurn,
                BlendMode::LinearBurn,
                BlendMode::DarkerColor
            ]
        );
        assert_eq!(sections[3].len(), 7);
        assert_eq!(sections[4], [BlendMode::Difference, BlendMode::Exclusion, BlendMode::Subtract, BlendMode::Divide]);
        assert_eq!(sections[5], [BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity]);
    }

    #[test]
    fn titles_are_unique_and_add_is_plain() {
        let titles: BTreeSet<_> = BlendMode::ALL.iter().map(|m| m.title()).collect();
        assert_eq!(titles.len(), 27);
        assert_eq!(BlendMode::Add.title(), "Add");
        assert_eq!(BlendMode::Luminosity.title(), "Luminosity");
    }

    #[test]
    fn every_mode_knows_the_file_version_it_needs() {
        for m in BlendMode::ALL.iter().filter(|m| m.is_legacy()) {
            assert_eq!(m.minimum_file_version(), 22);
        }
        let v41 = [
            BlendMode::Darken,
            BlendMode::ColorBurn,
            BlendMode::LinearBurn,
            BlendMode::Lighten,
            BlendMode::ColorDodge,
            BlendMode::SoftLight,
            BlendMode::HardLight,
            BlendMode::Difference,
            BlendMode::Exclusion,
        ];
        for m in v41 {
            assert_eq!(m.minimum_file_version(), 41);
        }
        let v55: Vec<_> = BlendMode::ALL.iter().filter(|m| !m.is_legacy() && !v41.contains(m)).collect();
        assert_eq!(v55.len(), 13);
        assert!(v55.iter().all(|m| m.minimum_file_version() == 55));
    }
}
