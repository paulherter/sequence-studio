// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ReframeSheetOptions.swift
//! The Auto Reframe options sheet: two plain choices that map onto `ReframeOptions`.
use crate::reframe::ReframeOptions;

/// How closely the camera path of an Auto Reframe follows the subject over time (sheet row "Motion").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ReframeSmoothness {
    /// Follows quickly; small moves show.
    Quick,
    /// The default.
    Steady,
    /// Calm, slow camera; can lag behind fast subjects.
    Smooth,
}

impl ReframeSmoothness {
    /// Every case, in the sheet's order.
    pub const ALL: [ReframeSmoothness; 3] =
        [ReframeSmoothness::Quick, ReframeSmoothness::Steady, ReframeSmoothness::Smooth];

    /// The raw string value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ReframeSmoothness::Quick => "quick",
            ReframeSmoothness::Steady => "steady",
            ReframeSmoothness::Smooth => "smooth",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<ReframeSmoothness> {
        Self::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            ReframeSmoothness::Quick => "Quick",
            ReframeSmoothness::Steady => "Steady",
            ReframeSmoothness::Smooth => "Smooth",
        }
    }
}

/// How tight the framing sits on the subject (sheet row "Framing").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ReframeTightness {
    /// Just fills the frame (the default).
    Fill,
    /// A little closer.
    Closer,
    /// Tight on the subject.
    Tight,
}

impl ReframeTightness {
    /// Every case, in the sheet's order.
    pub const ALL: [ReframeTightness; 3] = [ReframeTightness::Fill, ReframeTightness::Closer, ReframeTightness::Tight];

    /// The raw string value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ReframeTightness::Fill => "fill",
            ReframeTightness::Closer => "closer",
            ReframeTightness::Tight => "tight",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<ReframeTightness> {
        Self::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            ReframeTightness::Fill => "Fill Frame",
            ReframeTightness::Closer => "Closer",
            ReframeTightness::Tight => "Tight",
        }
    }
}

impl ReframeOptions {
    /// The options of a sheet choice; Steady and Fill Frame are the unchanged defaults.
    pub fn with_choices(smoothness: ReframeSmoothness, tightness: ReframeTightness) -> ReframeOptions {
        let mut o = ReframeOptions::default();
        match smoothness {
            ReframeSmoothness::Quick => {
                o.smoothing_window = 0.4;
                o.dead_zone = 0.03;
            }
            ReframeSmoothness::Steady => {}
            ReframeSmoothness::Smooth => {
                o.smoothing_window = 2.5;
                o.dead_zone = 0.08;
            }
        }
        o.zoom = match tightness {
            ReframeTightness::Fill => 1.0,
            ReframeTightness::Closer => 1.2,
            ReframeTightness::Tight => 1.4,
        };
        o
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_unchanged() {
        assert_eq!(
            ReframeOptions::with_choices(ReframeSmoothness::Steady, ReframeTightness::Fill),
            ReframeOptions::default()
        );
    }

    #[test]
    fn smoothness_widens_the_window_and_tightness_zooms() {
        let d = ReframeOptions::default();
        let quick = ReframeOptions::with_choices(ReframeSmoothness::Quick, ReframeTightness::Fill);
        let smooth = ReframeOptions::with_choices(ReframeSmoothness::Smooth, ReframeTightness::Tight);
        assert!(quick.smoothing_window < d.smoothing_window);
        assert!(smooth.smoothing_window > d.smoothing_window && smooth.dead_zone > d.dead_zone);
        assert!(smooth.zoom > ReframeOptions::with_choices(ReframeSmoothness::Smooth, ReframeTightness::Closer).zoom);
        assert!(ReframeOptions::with_choices(ReframeSmoothness::Steady, ReframeTightness::Closer).zoom > 1.0);
    }

    #[test]
    fn raw_values_round_trip() {
        for c in ReframeSmoothness::ALL {
            assert_eq!(ReframeSmoothness::from_raw(c.raw_value()), Some(c));
        }
        for c in ReframeTightness::ALL {
            assert_eq!(ReframeTightness::from_raw(c.raw_value()), Some(c));
        }
        assert_eq!(ReframeTightness::from_raw("nope"), None);
    }
}
