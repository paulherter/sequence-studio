// Swift: Color/ColorZoneBoardModel.swift
//! The Zone Board section: four zones (Global, Shadows, Midtones, Highlights), each with a color puck, a saturation and an
//! exposure value. Lives in the effect's grade data (`ColorEffect.zoneBoard`, not keyframable, like the curves); the first
//! edit creates the board.

use super::color_inspector_model::ColorInspectorModel;
use sq_core_color::{BoardZone, ZoneBoardExt, ZoneSettingExt};
use sq_core_model::{WheelValue, ZoneBoard, ZoneSetting};

impl ColorInspectorModel {
    /// The effect's board; a fresh (neutral) one when none exists yet.
    pub fn zone_board(&self, effect: i64) -> ZoneBoard {
        self.effect_by_id(effect).and_then(|e| e.zone_board).unwrap_or_default()
    }

    fn edit_zone(&mut self, effect: i64, zone: BoardZone, change: impl FnOnce(&mut ZoneSetting)) {
        self.edit_effect(effect, |e| {
            let mut b = e.zone_board.unwrap_or_default();
            let mut z = b.zone(zone);
            change(&mut z);
            b.set_zone(zone, z.clamped());
            e.zone_board = Some(b);
        });
    }

    /// The puck as a wheel position (hue degrees, amount 0...1).
    pub fn set_zone_puck(&mut self, effect: i64, zone: BoardZone, hue: f32, amount: f32) {
        let p = ZoneSetting::puck(&WheelValue { hue, amount: amount.clamp(0.0, 1.0) });
        self.edit_zone(effect, zone, |z| {
            z.puck_x = p.0;
            z.puck_y = p.1;
        });
    }

    /// Exposure from the wheel's side slider (-1...1, 0 = unchanged).
    pub fn set_zone_exposure(&mut self, effect: i64, zone: BoardZone, slider: f32) {
        self.edit_zone(effect, zone, |z| z.exposure = 0.5 + slider.clamp(-1.0, 1.0) / 2.0);
    }

    /// Saturation in percent (0...200, 100 = unchanged).
    pub fn set_zone_saturation(&mut self, effect: i64, zone: BoardZone, percent: f32) {
        self.edit_zone(effect, zone, |z| z.saturation = percent.clamp(0.0, 200.0) / 200.0);
    }

    pub fn zone_saturation_percent(&self, effect: i64, zone: BoardZone) -> f32 {
        self.zone_board(effect).zone(zone).saturation * 200.0
    }

    pub fn zone_exposure_slider(&self, effect: i64, zone: BoardZone) -> f32 {
        (self.zone_board(effect).zone(zone).exposure - 0.5) * 2.0
    }

    pub fn zone_puck_wheel(&self, effect: i64, zone: BoardZone) -> WheelValue {
        self.zone_board(effect).zone(zone).wheel_value()
    }

    /// Resets one zone; no board yet: nothing to reset (no undo step).
    pub fn reset_zone(&mut self, effect: i64, zone: BoardZone) {
        if self.effect_by_id(effect).and_then(|e| e.zone_board).is_none() {
            return;
        }
        self.gesture(|s| s.edit_zone(effect, zone, |z| *z = ZoneSetting::default()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn model() -> ColorInspectorModel {
        ColorInspectorModel::new(Box::new(SequentialIds::default()))
    }

    #[test]
    fn reset_without_a_board_makes_no_undo_step() {
        let mut m = model();
        m.reset_zone(1, BoardZone::Global);
        assert!(m.take_events().is_empty());
    }

    #[test]
    fn saturation_and_exposure_round_trip_through_the_sliders() {
        let mut m = model();
        m.set_zone_saturation(1, BoardZone::Shadows, 150.0);
        m.set_zone_exposure(1, BoardZone::Shadows, 0.5);
        assert!((m.zone_saturation_percent(1, BoardZone::Shadows) - 150.0).abs() < 1e-4);
        assert!((m.zone_exposure_slider(1, BoardZone::Shadows) - 0.5).abs() < 1e-6);
        m.reset_zone(1, BoardZone::Shadows);
        assert!((m.zone_saturation_percent(1, BoardZone::Shadows) - 100.0).abs() < 1e-4);
    }

    #[test]
    fn the_puck_is_a_wheel_position() {
        let mut m = model();
        m.set_zone_puck(1, BoardZone::Global, 90.0, 0.5);
        let w = m.zone_puck_wheel(1, BoardZone::Global);
        assert!((w.hue - 90.0).abs() < 0.01 && (w.amount - 0.5).abs() < 0.01);
    }
}
