// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipColor.swift (logic of the saved types), ColorBypass.swift (`ClipColor.ungraded`)
//! Logic on the saved color types of `sq-core-model`: neutral checks, section reset, Color Range clamping and the
//! `ClipColor` effect list edits.

use crate::color_graph::ColorGraphExt;
use sq_core_model::{
    BasicCorrection, ClipColor, ColorEffect, ColorSectionKind, ColorWheels, CreativeLook, HSLSecondary, HueCurves,
    LUTRef, RGBCurves, Vignette, WheelValue,
};

/// `isNeutral` of the types that have no neutral check in the model.
pub trait NeutralExt {
    /// The value does nothing to the picture.
    fn is_neutral(&self) -> bool;
}

impl NeutralExt for WheelValue {
    fn is_neutral(&self) -> bool {
        self.amount == 0.0
    }
}

impl NeutralExt for ColorWheels {
    fn is_neutral(&self) -> bool {
        *self == ColorWheels::default()
    }
}

impl NeutralExt for Vignette {
    fn is_neutral(&self) -> bool {
        self.amount == 0.0
    }
}

impl NeutralExt for CreativeLook {
    fn is_neutral(&self) -> bool {
        !self.has_tone() && !self.has_look()
    }
}

/// Tone and look checks of [`CreativeLook`].
pub trait CreativeLookExt {
    /// The look LUT and its intensity are ignored when judging the tone part.
    fn has_tone(&self) -> bool;
    /// A real look LUT (not none, not automatic) with intensity above 0.
    fn has_look(&self) -> bool;
}

impl CreativeLookExt for CreativeLook {
    fn has_tone(&self) -> bool {
        self.faded_film != 0.0
            || self.vibrance != 0.0
            || self.saturation != 100.0
            || !self.shadow_tint.is_neutral()
            || !self.highlight_tint.is_neutral()
    }

    fn has_look(&self) -> bool {
        self.look.is_some() && self.look != Some(LUTRef::Automatic) && self.intensity > 0.0
    }
}

/// Titles and the full list of [`ColorSectionKind`].
pub trait ColorSectionKindExt: Sized {
    /// Every section in panel and processing order (Swift `allCases`).
    const ALL: [Self; 7];
    /// Name shown in the UI.
    fn title(self) -> &'static str;
}

impl ColorSectionKindExt for ColorSectionKind {
    const ALL: [ColorSectionKind; 7] = [
        ColorSectionKind::BasicCorrection,
        ColorSectionKind::Creative,
        ColorSectionKind::Curves,
        ColorSectionKind::Wheels,
        ColorSectionKind::ZoneBoard,
        ColorSectionKind::HslSecondary,
        ColorSectionKind::Vignette,
    ];

    fn title(self) -> &'static str {
        match self {
            ColorSectionKind::BasicCorrection => "Basic",
            ColorSectionKind::Creative => "Creative",
            ColorSectionKind::Curves => "Curves",
            ColorSectionKind::Wheels => "Wheels & Match",
            ColorSectionKind::HslSecondary => "Color Range",
            ColorSectionKind::ZoneBoard => "Zone Board",
            ColorSectionKind::Vignette => "Vignette",
        }
    }
}

/// Clamping of the Color Range.
pub trait HSLSecondaryExt {
    /// The Color Range exposure limits in stops.
    const EXPOSURE_RANGE: (f32, f32);
    /// Every value in its range; a crossed min / max pair is swapped; the hue center wraps into 0..<360.
    fn clamped(&self) -> HSLSecondary;
}

impl HSLSecondaryExt for HSLSecondary {
    const EXPOSURE_RANGE: (f32, f32) = (-3.0, 3.0);

    fn clamped(&self) -> HSLSecondary {
        fn c(v: f32, lo: f32, hi: f32) -> f32 {
            if v.is_finite() { v.max(lo).min(hi) } else { lo }
        }
        let mut r = self.clone();
        let h = if self.hue_center.is_finite() { self.hue_center % 360.0 } else { 0.0 };
        r.hue_center = if h < 0.0 { h + 360.0 } else { h };
        r.hue_width = c(self.hue_width, 0.0, 360.0);
        (r.sat_min, r.sat_max) =
            (c(self.sat_min.min(self.sat_max), 0.0, 100.0), c(self.sat_min.max(self.sat_max), 0.0, 100.0));
        (r.lum_min, r.lum_max) =
            (c(self.lum_min.min(self.lum_max), 0.0, 100.0), c(self.lum_min.max(self.lum_max), 0.0, 100.0));
        r.softness = c(self.softness, 0.0, 100.0);
        r.volume_sat = c(self.volume_sat, 0.0, 100.0);
        r.volume_lum = c(self.volume_lum, 0.0, 100.0);
        r.volume_radius = c(self.volume_radius, 0.0, 100.0);
        r.hue_shift = c(self.hue_shift, -180.0, 180.0);
        r.saturation = c(self.saturation, 0.0, 200.0);
        r.exposure = c(self.exposure, Self::EXPOSURE_RANGE.0, Self::EXPOSURE_RANGE.1);
        r.temperature = c(self.temperature, -100.0, 100.0);
        r.tint = c(self.tint, -100.0, 100.0);
        r
    }
}

/// Section checks and reset of one [`ColorEffect`].
pub trait ColorEffectExt {
    /// The Input LUT does nothing when it is none or automatic (automatic only acts for S-Log3 media with an embedded
    /// look; the caller decides that).
    fn input_lut_is_neutral(&self) -> bool;
    /// Has no effect on the picture (neutral parameters), ignoring the toggle.
    fn is_neutral(&self, k: ColorSectionKind) -> bool;
    /// Resets one section to its defaults (keeps the toggle). The first effect's Input LUT returns to `Automatic`.
    fn reset(&mut self, k: ColorSectionKind, is_primary: bool);
}

impl ColorEffectExt for ColorEffect {
    fn input_lut_is_neutral(&self) -> bool {
        matches!(self.input_lut, None | Some(LUTRef::Automatic))
    }

    fn is_neutral(&self, k: ColorSectionKind) -> bool {
        match k {
            ColorSectionKind::BasicCorrection => self.basic.is_neutral() && self.input_lut_is_neutral(),
            ColorSectionKind::Creative => NeutralExt::is_neutral(&self.creative),
            ColorSectionKind::Curves => self.curves.is_neutral() && self.hue_curves.is_neutral(),
            ColorSectionKind::Wheels => NeutralExt::is_neutral(&self.wheels),
            ColorSectionKind::HslSecondary => self.hsl_secondary.as_ref().is_none_or(|h| h.is_correction_neutral()),
            ColorSectionKind::ZoneBoard => self.zone_board.as_ref().is_none_or(|z| z.is_neutral()),
            ColorSectionKind::Vignette => NeutralExt::is_neutral(&self.vignette),
        }
    }

    fn reset(&mut self, k: ColorSectionKind, is_primary: bool) {
        match k {
            ColorSectionKind::BasicCorrection => {
                self.basic = BasicCorrection::default();
                self.input_lut = if is_primary { Some(LUTRef::Automatic) } else { None };
                self.input_lut_intensity = 100.0;
            }
            ColorSectionKind::Creative => self.creative = CreativeLook::default(),
            ColorSectionKind::Curves => {
                self.curves = RGBCurves::default();
                self.hue_curves = HueCurves::default();
            }
            ColorSectionKind::Wheels => self.wheels = ColorWheels::default(),
            ColorSectionKind::HslSecondary => self.hsl_secondary = None,
            ColorSectionKind::ZoneBoard => self.zone_board = None,
            ColorSectionKind::Vignette => self.vignette = Vignette::default(),
        }
    }
}

/// Effect list queries and edits of [`ClipColor`].
pub trait ClipColorExt {
    /// The grade is the default one (`ClipColor.default`).
    fn is_default(&self) -> bool;
    /// The first effect: its Input LUT is the conversion step.
    fn primary(&self) -> &ColorEffect;
    /// True when the picture is unchanged: every enabled section of every effect is neutral. A non-Rec.709 source
    /// always needs the conversion, so it is never identity.
    fn is_identity(&self, rec709_source: bool) -> bool;
    /// The effect with this inspector id.
    fn effect(&self, id: i64) -> Option<&ColorEffect>;
    /// Appends a default Color effect; returns its id.
    fn add_effect(&mut self) -> i64;
    /// Removes an effect; the last one cannot be removed (reset it instead).
    fn remove_effect(&mut self, id: i64);
    /// Resets one section of an effect to its defaults (keeps its toggle).
    fn reset_section(&mut self, k: ColorSectionKind, id: i64);
    /// The same footage without a grade: the source interpretation (color space override, embedded camera LUT switch)
    /// stays, so log footage is still converted to the display; every Color effect returns to the default one.
    fn ungraded(&self) -> ClipColor;
}

impl ClipColorExt for ClipColor {
    fn is_default(&self) -> bool {
        *self == ClipColor::default()
    }

    fn primary(&self) -> &ColorEffect {
        &self.effects()[0]
    }

    fn is_identity(&self, rec709_source: bool) -> bool {
        if !rec709_source {
            return false;
        }
        if let Some(graph) = &self.graph {
            return graph.is_neutral() && matches!(graph.input_lut, None | Some(LUTRef::Automatic));
        }
        self.effects()
            .iter()
            .all(|e| ColorSectionKind::ALL.iter().all(|&k| !e.is_enabled(k) || ColorEffectExt::is_neutral(e, k)))
    }

    fn effect(&self, id: i64) -> Option<&ColorEffect> {
        self.effects().iter().find(|e| e.id == id)
    }

    fn add_effect(&mut self) -> i64 {
        let id = self.effects().iter().map(|e| e.id).max().unwrap_or(0) + 1;
        self.edit_effects(|fx| fx.push(ColorEffect::new(id, None)));
        id
    }

    fn remove_effect(&mut self, id: i64) {
        if self.effects().len() <= 1 {
            return;
        }
        self.edit_effects(|fx| fx.retain(|e| e.id != id));
    }

    fn reset_section(&mut self, k: ColorSectionKind, id: i64) {
        let Some(i) = self.effects().iter().position(|e| e.id == id) else { return };
        self.edit_effects(|fx| fx[i].reset(k, i == 0));
    }

    fn ungraded(&self) -> ClipColor {
        ClipColor::new(self.source, self.use_embedded_lut, Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::ZoneBoard;

    #[test]
    fn zone_board_section_neutral_reset_and_toggle() {
        let mut e = ColorEffect::new(1, None);
        assert!(e.zone_board.is_none() && ColorEffectExt::is_neutral(&e, ColorSectionKind::ZoneBoard));
        e.zone_board = Some(ZoneBoard::default());
        assert!(ColorEffectExt::is_neutral(&e, ColorSectionKind::ZoneBoard));
        if let Some(z) = e.zone_board.as_mut() {
            z.shadows.exposure = 0.7;
        }
        assert!(!ColorEffectExt::is_neutral(&e, ColorSectionKind::ZoneBoard));
        assert!(!ClipColor::new(None, true, vec![e.clone()]).is_identity(true));
        e.set_enabled(ColorSectionKind::ZoneBoard, false);
        assert!(ClipColor::new(None, true, vec![e.clone()]).is_identity(true));
        e.reset(ColorSectionKind::ZoneBoard, true);
        assert!(e.zone_board.is_none() && !e.is_enabled(ColorSectionKind::ZoneBoard));
    }

    #[test]
    fn color_range_clamps_and_swaps() {
        let wild = HSLSecondary { volume_radius: 400.0, volume_sat: -3.0, ..HSLSecondary::default() };
        assert!(wild.clamped().volume_radius == 100.0 && wild.clamped().volume_sat == 0.0);
        let crossed = HSLSecondary { sat_min: 90.0, sat_max: 20.0, hue_center: -30.0, ..wild };
        let c = crossed.clamped();
        assert!(c.sat_min == 20.0 && c.sat_max == 90.0 && c.hue_center == 330.0);
    }

    #[test]
    fn effect_list_edits_keep_one_effect() {
        let mut c = ClipColor::default();
        assert!(c.is_default());
        assert_eq!(c.add_effect(), 2);
        c.remove_effect(1);
        assert_eq!(c.effects().len(), 1);
        c.remove_effect(2);
        assert_eq!(c.effects().len(), 1, "the last effect cannot be removed");
        c.reset_section(ColorSectionKind::BasicCorrection, 2);
        assert_eq!(c.primary().input_lut, Some(LUTRef::Automatic), "the first effect gets the automatic LUT back");
        assert!(c.ungraded().is_default());
    }
}
