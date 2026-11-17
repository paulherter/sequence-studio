// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ZoneBoard.swift
//! The Zone Board (v94): a four-zone color control (Global, Shadows, Midtones, Highlights) with a color puck, a
//! saturation and an exposure value per zone. Every value runs 0...1 with 0.5 as "no change". The saved types live in
//! `sq-core-model`; this module adds the maths.

use sq_core_model::{WheelValue, ZoneBoard, ZoneSetting};
use std::f32::consts::PI;

/// The four tonal zones of the Zone Board.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BoardZone {
    /// Whole picture.
    Global,
    /// Shadows.
    Shadows,
    /// Midtones.
    Midtones,
    /// Highlights.
    Highlights,
}

impl BoardZone {
    /// Every zone in declaration order (Swift `allCases`).
    pub const ALL: [BoardZone; 4] = [BoardZone::Global, BoardZone::Shadows, BoardZone::Midtones, BoardZone::Highlights];

    /// Name shown in the UI.
    pub fn title(self) -> &'static str {
        match self {
            BoardZone::Global => "Global",
            BoardZone::Shadows => "Shadows",
            BoardZone::Midtones => "Midtones",
            BoardZone::Highlights => "Highlights",
        }
    }
}

/// Zone maths on [`ZoneSetting`].
pub trait ZoneSettingExt {
    /// Every value in 0...1; a non-finite value becomes 0.5.
    fn clamped(&self) -> ZoneSetting;
    /// The puck as a color wheel value: hue in degrees (0 = right, counter-clockwise, red = 0) and amount 0...1 of the
    /// radius. A puck outside the unit circle is clamped to the rim.
    fn wheel_value(&self) -> WheelValue;
    /// The puck position `(x, y)` for a wheel value (inverse of `wheel_value`).
    fn puck(w: &WheelValue) -> (f32, f32);
    /// Saturation factor: 0 -> 0 (gray), 0.5 -> 1, 1 -> 2.
    fn saturation_factor(&self) -> f32;
    /// Exposure in stops: 0.5 -> 0, the ends are -1.5 / +1.5 stops.
    fn exposure_stops(&self) -> f32;
}

impl ZoneSettingExt for ZoneSetting {
    fn clamped(&self) -> ZoneSetting {
        fn c(v: f32) -> f32 {
            if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.5 }
        }
        ZoneSetting {
            puck_x: c(self.puck_x),
            puck_y: c(self.puck_y),
            saturation: c(self.saturation),
            exposure: c(self.exposure),
        }
    }

    fn wheel_value(&self) -> WheelValue {
        let dx = (self.puck_x - 0.5) * 2.0;
        let dy = (self.puck_y - 0.5) * 2.0;
        let len = (dx * dx + dy * dy).sqrt();
        if len.is_nan() || len <= 1e-6 {
            return WheelValue::default();
        }
        let mut hue = dy.atan2(dx) * 180.0 / PI;
        if hue < 0.0 {
            hue += 360.0;
        }
        WheelValue { hue, amount: len.min(1.0) }
    }

    fn puck(w: &WheelValue) -> (f32, f32) {
        let a = w.amount.clamp(0.0, 1.0);
        let r = w.hue * PI / 180.0;
        (0.5 + 0.5 * a * r.cos(), 0.5 + 0.5 * a * r.sin())
    }

    fn saturation_factor(&self) -> f32 {
        self.saturation.clamp(0.0, 1.0) * 2.0
    }

    fn exposure_stops(&self) -> f32 {
        (self.exposure.clamp(0.0, 1.0) - 0.5) * 3.0
    }
}

/// Zone lookup and clamping on [`ZoneBoard`].
pub trait ZoneBoardExt {
    /// The setting of one zone (Swift subscript getter).
    fn zone(&self, zone: BoardZone) -> ZoneSetting;
    /// Replaces the setting of one zone (Swift subscript setter).
    fn set_zone(&mut self, zone: BoardZone, value: ZoneSetting);
    /// Every zone clamped.
    fn clamped(&self) -> ZoneBoard;
    /// Resets one zone.
    fn reset(&mut self, zone: BoardZone);
}

impl ZoneBoardExt for ZoneBoard {
    fn zone(&self, zone: BoardZone) -> ZoneSetting {
        match zone {
            BoardZone::Global => self.global,
            BoardZone::Shadows => self.shadows,
            BoardZone::Midtones => self.midtones,
            BoardZone::Highlights => self.highlights,
        }
    }

    fn set_zone(&mut self, zone: BoardZone, value: ZoneSetting) {
        match zone {
            BoardZone::Global => self.global = value,
            BoardZone::Shadows => self.shadows = value,
            BoardZone::Midtones => self.midtones = value,
            BoardZone::Highlights => self.highlights = value,
        }
    }

    fn clamped(&self) -> ZoneBoard {
        let mut r = *self;
        for z in BoardZone::ALL {
            r.set_zone(z, self.zone(z).clamped());
        }
        r
    }

    fn reset(&mut self, zone: BoardZone) {
        self.set_zone(zone, ZoneSetting::default());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color_effect::NeutralExt;

    fn setting(puck_x: f32, puck_y: f32, saturation: f32, exposure: f32) -> ZoneSetting {
        ZoneSetting { puck_x, puck_y, saturation, exposure }
    }

    #[test]
    fn fresh_board_is_neutral_and_writes_nothing() {
        let b = ZoneBoard::default();
        assert!(b.is_neutral() && b == b.clamped());
        assert_eq!(serde_json::to_string(&b).unwrap_or_default(), "{}");
        let s = ZoneSetting::default();
        assert!(s.saturation_factor() == 1.0 && s.exposure_stops() == 0.0 && s.wheel_value().is_neutral());
    }

    #[test]
    fn puck_maps_to_wheel_value_and_back() {
        let at = |puck_x, puck_y| setting(puck_x, puck_y, 0.5, 0.5).wheel_value();
        assert!(at(1.0, 0.5).hue == 0.0 && at(1.0, 0.5).amount == 1.0);
        assert!((at(0.5, 1.0).hue - 90.0).abs() < 1e-3);
        assert!((at(0.0, 0.5).hue - 180.0).abs() < 1e-3);
        assert_eq!(at(1.0, 1.0).amount, 1.0, "outside the circle: rim");
        let (x, y) = ZoneSetting::puck(&WheelValue { hue: 270.0, amount: 0.5 });
        assert!((x - 0.5).abs() < 1e-5 && (y - 0.25).abs() < 1e-5);
    }

    #[test]
    fn saturation_and_exposure_scales() {
        assert_eq!(setting(0.5, 0.5, 0.0, 0.5).saturation_factor(), 0.0);
        assert_eq!(setting(0.5, 0.5, 1.0, 0.5).saturation_factor(), 2.0);
        assert_eq!(setting(0.5, 0.5, 1.0, 1.0).exposure_stops(), 1.5);
        assert_eq!(setting(0.5, 0.5, 1.0, 0.0).exposure_stops(), -1.5);
        assert_eq!(setting(0.5, 0.5, 1.0, 7.0).clamped().exposure, 1.0);
        assert_eq!(setting(0.5, 0.5, 1.0, f32::NAN).clamped().exposure, 0.5);
    }

    #[test]
    fn reset_returns_a_zone_to_neutral() {
        let mut b = ZoneBoard::default();
        b.set_zone(BoardZone::Highlights, setting(0.8, 0.6, 0.4, 0.55));
        assert!(!b.is_neutral());
        b.reset(BoardZone::Highlights);
        assert!(b.is_neutral());
    }
}
