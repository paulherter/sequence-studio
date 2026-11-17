// Swift: Color/ColorRangeModel.swift
//! One slider of the Color Range (HSL secondary) section. Not keyframable: the range lives in the effect's grade data
//! (`ColorEffect.hslSecondary`), like the curves.

use super::color_inspector_model::{ColorInspectorModel, ColorTrack};
use sq_core_color::HSLSecondaryExt;
use sq_core_model::{HSLMaskMode, HSLSecondary};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColorRangeParam {
    // Qualifier ("Range" group).
    HueCenter,
    HueWidth,
    SatMin,
    SatMax,
    LumMin,
    LumMax,
    Softness,
    // Correction inside the range ("Correction" group).
    HueShift,
    Saturation,
    Exposure,
    Temperature,
    Tint,
    // Color-volume mask (v94): the ball's saturation, luma and radius (its hue is `HueCenter`).
    VolumeSat,
    VolumeLum,
    VolumeRadius,
}

impl ColorRangeParam {
    /// Swift `allCases`.
    pub const ALL: [ColorRangeParam; 15] = [
        ColorRangeParam::HueCenter,
        ColorRangeParam::HueWidth,
        ColorRangeParam::SatMin,
        ColorRangeParam::SatMax,
        ColorRangeParam::LumMin,
        ColorRangeParam::LumMax,
        ColorRangeParam::Softness,
        ColorRangeParam::HueShift,
        ColorRangeParam::Saturation,
        ColorRangeParam::Exposure,
        ColorRangeParam::Temperature,
        ColorRangeParam::Tint,
        ColorRangeParam::VolumeSat,
        ColorRangeParam::VolumeLum,
        ColorRangeParam::VolumeRadius,
    ];

    pub fn raw_value(self) -> i64 {
        Self::ALL.iter().position(|p| *p == self).unwrap_or(0) as i64
    }

    pub fn title(self) -> &'static str {
        use ColorRangeParam::*;
        match self {
            HueCenter => "Hue",
            HueWidth => "Hue Width",
            SatMin => "Sat Min",
            SatMax => "Sat Max",
            LumMin => "Luma Min",
            LumMax => "Luma Max",
            Softness => "Softness",
            HueShift => "Hue Shift",
            Saturation => "Saturation",
            Exposure => "Exposure",
            Temperature => "Temperature",
            Tint => "Tint",
            VolumeSat => "Saturation",
            VolumeLum => "Luma",
            VolumeRadius => "Radius",
        }
    }

    /// A row of the Range group: the qualifier sliders (ranges mode) or the color-volume sliders.
    pub fn is_qualifier(self) -> bool {
        self.raw_value() <= ColorRangeParam::Softness.raw_value()
    }

    pub fn is_volume(self) -> bool {
        matches!(self, ColorRangeParam::VolumeSat | ColorRangeParam::VolumeLum | ColorRangeParam::VolumeRadius)
    }

    /// A row of the Correction group.
    pub fn is_correction(self) -> bool {
        !self.is_qualifier() && !self.is_volume()
    }

    /// Whether the row shows in this mask mode (Hue and Softness serve both).
    pub fn is_shown(self, mode: HSLMaskMode) -> bool {
        if self.is_correction() {
            return true;
        }
        if self == ColorRangeParam::HueCenter || self == ColorRangeParam::Softness {
            return true;
        }
        self.is_volume() == (mode == HSLMaskMode::Volume)
    }

    /// Lower and upper bound of the slider.
    pub fn range(self) -> (f32, f32) {
        use ColorRangeParam::*;
        match self {
            HueCenter | HueWidth => (0.0, 360.0),
            SatMin | SatMax | LumMin | LumMax | Softness | VolumeSat | VolumeLum | VolumeRadius => (0.0, 100.0),
            HueShift => (-180.0, 180.0),
            Saturation => (0.0, 200.0),
            Exposure => HSLSecondary::EXPOSURE_RANGE,
            Temperature | Tint => (-100.0, 100.0),
        }
    }

    /// The value of a new range (double-click / reset goes back here).
    pub fn neutral(self) -> f32 {
        self.read(&HSLSecondary::default())
    }

    pub fn decimals(self) -> i64 {
        if self == ColorRangeParam::Exposure { 2 } else { 1 }
    }

    pub fn track(self) -> ColorTrack {
        match self {
            ColorRangeParam::Temperature => ColorTrack::Temperature,
            ColorRangeParam::Tint => ColorTrack::Tint,
            _ => ColorTrack::Plain,
        }
    }

    pub fn read(self, r: &HSLSecondary) -> f32 {
        use ColorRangeParam::*;
        match self {
            HueCenter => r.hue_center,
            HueWidth => r.hue_width,
            SatMin => r.sat_min,
            SatMax => r.sat_max,
            LumMin => r.lum_min,
            LumMax => r.lum_max,
            Softness => r.softness,
            HueShift => r.hue_shift,
            Saturation => r.saturation,
            Exposure => r.exposure,
            Temperature => r.temperature,
            Tint => r.tint,
            VolumeSat => r.volume_sat,
            VolumeLum => r.volume_lum,
            VolumeRadius => r.volume_radius,
        }
    }

    /// Clamps to `range` and writes; a min / max pair never crosses (the other end is pushed along).
    pub fn write(self, value: f32, r: &mut HSLSecondary) {
        use ColorRangeParam::*;
        let (lo, hi) = self.range();
        let v = value.max(lo).min(hi);
        match self {
            HueCenter => r.hue_center = v,
            HueWidth => r.hue_width = v,
            SatMin => {
                r.sat_min = v;
                r.sat_max = r.sat_max.max(v);
            }
            SatMax => {
                r.sat_max = v;
                r.sat_min = r.sat_min.min(v);
            }
            LumMin => {
                r.lum_min = v;
                r.lum_max = r.lum_max.max(v);
            }
            LumMax => {
                r.lum_max = v;
                r.lum_min = r.lum_min.min(v);
            }
            Softness => r.softness = v,
            HueShift => r.hue_shift = v,
            Saturation => r.saturation = v,
            Exposure => r.exposure = v,
            Temperature => r.temperature = v,
            Tint => r.tint = v,
            VolumeSat => r.volume_sat = v,
            VolumeLum => r.volume_lum = v,
            VolumeRadius => r.volume_radius = v,
        }
    }
}

/// `HSLSecondary.MaskMode.title`.
pub fn mask_mode_title(m: HSLMaskMode) -> &'static str {
    if m == HSLMaskMode::Ranges { "Ranges" } else { "Color Volume" }
}

impl ColorInspectorModel {
    /// The effect's Color Range; nil = none yet (the panel shows the defaults of a new one).
    pub fn color_range(&self, effect: i64) -> Option<HSLSecondary> {
        self.effect_by_id(effect).and_then(|e| e.hsl_secondary.clone())
    }

    pub fn range_value(&self, effect: i64, p: ColorRangeParam) -> f32 {
        p.read(&self.color_range(effect).unwrap_or_default())
    }

    /// Writes one value; the first edit creates the range (skin tones, nothing corrected) and applies the value.
    pub fn set_range(&mut self, effect: i64, p: ColorRangeParam, v: f32) {
        self.edit_effect(effect, |e| {
            let mut r = e.hsl_secondary.clone().unwrap_or_default();
            p.write(v, &mut r);
            e.hsl_secondary = Some(r);
        });
    }

    /// No range yet: every value already shows its default, so nothing is created (no undo step, no v48 file).
    pub fn reset_range_parameter(&mut self, effect: i64, p: ColorRangeParam) {
        if self.color_range(effect).is_none() {
            return;
        }
        self.gesture(|s| s.set_range(effect, p, p.neutral()));
    }

    /// How the mask is picked: three ranges, or a ball in the 3D color volume. One undo step.
    pub fn set_range_mask_mode(&mut self, effect: i64, mode: HSLMaskMode) {
        self.gesture(|s| {
            s.edit_effect(effect, |e| {
                let mut r = e.hsl_secondary.clone().unwrap_or_default();
                r.mask_mode = mode;
                e.hsl_secondary = Some(r);
            })
        });
    }

    pub fn range_mask_mode(&self, effect: i64) -> HSLMaskMode {
        self.color_range(effect).map_or(HSLMaskMode::Ranges, |r| r.mask_mode)
    }

    /// Invert: correct everything outside the range. One undo step.
    pub fn set_range_invert(&mut self, effect: i64, on: bool) {
        self.gesture(|s| {
            s.edit_effect(effect, |e| {
                let mut r = e.hsl_secondary.clone().unwrap_or_default();
                r.invert = on;
                e.hsl_secondary = Some(r);
            })
        });
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
    fn a_min_max_pair_never_crosses() {
        let mut r = HSLSecondary::default();
        ColorRangeParam::SatMin.write(90.0, &mut r);
        assert!(r.sat_max >= 90.0);
        ColorRangeParam::LumMax.write(0.0, &mut r);
        assert_eq!(r.lum_min, 0.0);
    }

    #[test]
    fn rows_show_by_mask_mode() {
        assert!(ColorRangeParam::HueCenter.is_shown(HSLMaskMode::Volume));
        assert!(ColorRangeParam::SatMin.is_shown(HSLMaskMode::Ranges));
        assert!(!ColorRangeParam::SatMin.is_shown(HSLMaskMode::Volume));
        assert!(ColorRangeParam::VolumeRadius.is_shown(HSLMaskMode::Volume));
        assert!(ColorRangeParam::Tint.is_shown(HSLMaskMode::Ranges));
    }

    #[test]
    fn the_first_edit_creates_the_range_and_reset_without_one_does_nothing() {
        let mut m = model();
        m.reset_range_parameter(1, ColorRangeParam::Softness);
        assert!(m.take_events().is_empty());
        assert!(m.color_range(1).is_none());
        m.set_range(1, ColorRangeParam::Softness, 40.0);
        assert_eq!(m.range_value(1, ColorRangeParam::Softness), 40.0);
        m.set_range_invert(1, true);
        assert!(m.color_range(1).is_some_and(|r| r.invert));
    }
}
