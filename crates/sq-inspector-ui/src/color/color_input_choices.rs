// Swift: Color/ColorInputChoices.swift
//! The Color page's "Input color" rows, shared with the draw-list `ColorGradeDraw`: the color spaces "Interpret As" and
//! "Project Input" offer, and the footage row titles.

use sq_core_color::{CameraMake, ColorSpaceIdExt, DynamicRange, InputColorProfile, InputPickerState};
use sq_core_model::{ColorSpaceID, LogMode, TargetSpace};

pub struct ColorInputChoices;

const CAMERAS: [CameraMake; 7] = [
    CameraMake::Sony,
    CameraMake::IPhone,
    CameraMake::GoPro,
    CameraMake::Dji,
    CameraMake::Panasonic,
    CameraMake::Canon,
    CameraMake::Other,
];
const RANGES: [DynamicRange; 3] = [DynamicRange::Sdr, DynamicRange::Hlg, DynamicRange::Pq];

impl ColorInputChoices {
    /// Every color space the pickers offer, in menu order, each once (the first menu entry is Automatic / None).
    pub fn spaces() -> Vec<ColorSpaceID> {
        let mut out: Vec<ColorSpaceID> = Vec::new();
        let add = |out: &mut Vec<ColorSpaceID>, s: Option<ColorSpaceID>| {
            if let Some(s) = s
                && !out.contains(&s)
            {
                out.push(s);
            }
        };
        for r in RANGES {
            add(&mut out, Self::space(CameraMake::Other, false, r));
        }
        for c in CAMERAS {
            if InputColorProfile::log_available(c) {
                add(&mut out, Self::space(c, true, DynamicRange::Sdr));
            }
        }
        // A camera with several log curves / color spaces (Canon) lists each of them.
        for c in CAMERAS {
            for s in InputColorProfile::log_spaces(c) {
                add(&mut out, Some(s));
            }
        }
        for c in CAMERAS {
            for r in RANGES {
                add(&mut out, Self::space(c, false, r));
            }
        }
        // Board order (Window > Project Input Color Space): the declaration order of ColorSpaceID.
        <ColorSpaceID as ColorSpaceIdExt>::ALL.iter().copied().filter(|s| out.contains(s)).collect()
    }

    /// The spaces a picker lists for `current`: `spaces`, plus `current` at the end when it is not among them.
    pub fn shown(current: Option<ColorSpaceID>) -> Vec<ColorSpaceID> {
        let mut spaces = Self::spaces();
        if let Some(c) = current
            && !spaces.contains(&c)
        {
            spaces.push(c);
        }
        spaces
    }

    /// The color space a camera / Log / range choice stands for.
    pub fn space(camera: CameraMake, log: bool, range: DynamicRange) -> Option<ColorSpaceID> {
        let mut s = InputPickerState::new(None);
        s.set_camera(Some(camera));
        s.set_log(log);
        if !log {
            s.set_range(range);
        }
        s.space()
    }

    /// "Automatic (Rec. 709)": Interpret As without an override.
    pub fn automatic_title(detected: ColorSpaceID) -> String {
        format!("Automatic ({})", detected.display_name())
    }

    /// Project Input without a project space.
    pub const NO_PROJECT_INPUT: &'static str = "None (as tagged)";

    pub fn log_mode_title(m: LogMode) -> &'static str {
        match m {
            LogMode::CameraLUT => "Camera LUT",
            LogMode::BuiltIn => "Built-in Transform",
            LogMode::Off => "Off",
        }
    }

    pub fn target_title(t: TargetSpace) -> &'static str {
        match t {
            TargetSpace::Rec709 => "Rec. 709",
            TargetSpace::Rec2020 => "Rec. 2020",
            TargetSpace::Rec2020PQ => "Rec. 2020 PQ",
            TargetSpace::Rec2020HLG => "Rec. 2020 HLG",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spaces_are_unique_and_start_with_rec709() {
        let s = ColorInputChoices::spaces();
        assert_eq!(s.first(), Some(&ColorSpaceID::Rec709));
        for (i, a) in s.iter().enumerate() {
            assert!(!s[i + 1..].contains(a), "{a:?} twice");
        }
        assert!(s.len() > 5);
    }

    #[test]
    fn shown_appends_a_space_that_is_not_offered() {
        let all = ColorInputChoices::spaces();
        let missing = <ColorSpaceID as ColorSpaceIdExt>::ALL.iter().copied().find(|s| !all.contains(s));
        if let Some(m) = missing {
            assert_eq!(ColorInputChoices::shown(Some(m)).last(), Some(&m));
        }
        assert_eq!(ColorInputChoices::shown(None), all);
        assert_eq!(ColorInputChoices::shown(Some(ColorSpaceID::Rec709)), all);
    }

    #[test]
    fn titles() {
        assert_eq!(ColorInputChoices::automatic_title(ColorSpaceID::Rec709), "Automatic (Rec. 709)");
        assert_eq!(ColorInputChoices::log_mode_title(LogMode::BuiltIn), "Built-in Transform");
        assert_eq!(ColorInputChoices::target_title(TargetSpace::Rec2020HLG), "Rec. 2020 HLG");
    }
}
