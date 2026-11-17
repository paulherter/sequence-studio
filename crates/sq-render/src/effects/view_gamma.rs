// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ViewGamma.swift
//! How the monitors show Rec.709 code values: a display preview only (export is never touched). The layer is tagged
//! CoreMedia 709 (effective gamma 1.96), so `Mac` leaves the picture unchanged; `Web` and `Broadcast` show what a 2.2 or
//! 2.4 display makes of the same code values.

/// The monitors' display gamma choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ViewGamma {
    /// How QuickTime and Mac apps show Rec.709 video.
    Mac,
    /// A typical web browser or phone screen.
    Web,
    /// A broadcast or grading monitor in a dim room.
    Broadcast,
}

/// The tag of the layer's own decode (CoreMedia 709), which `Mac` is defined by.
pub const LAYER_GAMMA: f32 = 1.96;

impl ViewGamma {
    /// Every choice, in menu order.
    pub const ALL: [ViewGamma; 3] = [ViewGamma::Mac, ViewGamma::Web, ViewGamma::Broadcast];

    /// The display gamma the choice stands for.
    pub fn gamma(self) -> f32 {
        match self {
            ViewGamma::Mac => 1.96,
            ViewGamma::Web => 2.2,
            ViewGamma::Broadcast => 2.4,
        }
    }

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            ViewGamma::Mac => "Mac 1.96",
            ViewGamma::Web => "Web 2.2",
            ViewGamma::Broadcast => "Broadcast 2.4",
        }
    }

    /// Menu tooltip.
    pub fn tooltip(self) -> &'static str {
        match self {
            ViewGamma::Mac => "How QuickTime and Mac apps show Rec.709 video.",
            ViewGamma::Web => "A typical web browser or phone screen (sRGB-like, about 2.2).",
            ViewGamma::Broadcast => "A broadcast or grading monitor in a dim room (2.4); darker midtones.",
        }
    }

    /// Power applied to the code values before they reach the layer: code' ^ 1.96 == code ^ gamma. 1 for `Mac`.
    pub fn exponent(self) -> f32 {
        self.gamma() / LAYER_GAMMA
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exponents_follow_the_layer_decode() {
        assert_eq!(ViewGamma::Mac.exponent(), 1.0);
        assert!((ViewGamma::Web.exponent() - 2.2 / 1.96).abs() < 1e-6);
        assert!((ViewGamma::Broadcast.exponent() - 2.4 / 1.96).abs() < 1e-6);
        assert!(ViewGamma::ALL.iter().all(|g| !g.tooltip().is_empty() && !g.title().is_empty()));
    }
}
