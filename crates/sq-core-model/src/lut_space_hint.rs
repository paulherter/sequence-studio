// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LUTSpaceHint.swift

use crate::ColorSpaceID;
use crate::labels::path_extension;

/// Guesses which source color space a LUT file expects from its file name (camera LUTs are named after the log
/// curve), so the Color inspector can warn when the clip is in another space. Pure name matching: a LUT whose name says
/// nothing has no expectation and never warns.
const TABLE: [(&[&str], ColorSpaceID); 15] = [
    (&["slog3", "s-log3", "slog-3"], ColorSpaceID::SLog3SGamut3Cine),
    (&["vlog", "v-log"], ColorSpaceID::VLogVGamut),
    (&["applelog", "apple log"], ColorSpaceID::AppleLog),
    (&["dlog", "d-log"], ColorSpaceID::DLogDGamut),
    (&["clog3", "canonlog3", "c-log3", "canon log 3"], ColorSpaceID::CanonLog3CinemaGamut),
    (&["clog2", "canonlog2", "c-log2", "canon log 2"], ColorSpaceID::CanonLog2CinemaGamut),
    (&["clog", "canonlog", "c-log", "canon log"], ColorSpaceID::CanonLogCinemaGamut),
    (&["logc4", "log-c4"], ColorSpaceID::LogC4WideGamut4),
    (&["logc3", "logc", "log-c"], ColorSpaceID::LogC3WideGamut3),
    (&["log3g10"], ColorSpaceID::Log3G10RedWideGamut),
    (&["flog2", "f-log2"], ColorSpaceID::FLog2FGamutC),
    (&["nlog", "n-log"], ColorSpaceID::NLogBT2020),
    (&["acescct"], ColorSpaceID::AcesCCTAP1),
    (&["hlg"], ColorSpaceID::HlgBT2020),
    (&["rec709", "rec.709", "rec 709", "bt709", "bt.709"], ColorSpaceID::Rec709),
];

/// The space the LUT's name implies, `None` when unknown.
pub fn expected_space(file_name: &str) -> Option<ColorSpaceID> {
    let stem = &file_name[..file_name.len() - path_extension(file_name).len()];
    let stem = stem.strip_suffix('.').unwrap_or(stem).to_lowercase();
    TABLE.iter().find(|(tokens, _)| tokens.iter().any(|t| stem.contains(t))).map(|(_, space)| *space)
}

/// Same transfer curve, any gamut variant (Canon's three gamut variants of one log are one family).
fn family(s: ColorSpaceID) -> i32 {
    use ColorSpaceID::*;
    match s {
        CanonLogCinemaGamut | CanonLogBT2020 | CanonLogBT709 => 1,
        CanonLog2CinemaGamut | CanonLog2BT2020 | CanonLog2BT709 => 2,
        CanonLog3CinemaGamut | CanonLog3BT2020 | CanonLog3BT709 => 3,
        other => 100 + other as i32,
    }
}

/// Short name for warnings.
fn hint_name(s: ColorSpaceID) -> &'static str {
    use ColorSpaceID::*;
    match s {
        Rec709 => "Rec.709",
        SLog3SGamut3Cine => "S-Log3",
        HlgBT2020 => "HLG",
        PqBT2020 => "PQ",
        VLogVGamut => "V-Log",
        AppleLog => "Apple Log",
        DLogDGamut => "D-Log",
        CanonLogCinemaGamut | CanonLogBT2020 | CanonLogBT709 => "Canon Log",
        CanonLog2CinemaGamut | CanonLog2BT2020 | CanonLog2BT709 => "Canon Log 2",
        CanonLog3CinemaGamut | CanonLog3BT2020 | CanonLog3BT709 => "Canon Log 3",
        LogC3WideGamut3 => "LogC3",
        LogC4WideGamut4 => "LogC4",
        Log3G10RedWideGamut => "Log3G10",
        BmdFilmGen5WideGamut => "Blackmagic Film",
        NLogBT2020 => "N-Log",
        FLog2FGamutC => "F-Log2",
        AcesCCTAP1 => "ACEScct",
    }
}

/// The warning for a LUT picked on a clip in `source`, as `(expected space, message)`; `None` when it fits or the LUT's
/// name gives no hint.
pub fn mismatch(lut_file_name: &str, source: ColorSpaceID) -> Option<(ColorSpaceID, String)> {
    let want = expected_space(lut_file_name).filter(|w| family(*w) != family(source))?;
    Some((want, format!("This LUT looks made for {} footage; the clip is {}.", hint_name(want), hint_name(source))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_map_to_spaces() {
        assert_eq!(expected_space("SLog3_to_Rec709.cube"), Some(ColorSpaceID::SLog3SGamut3Cine));
        assert_eq!(expected_space("Canon_CLog2_v2.cube"), Some(ColorSpaceID::CanonLog2CinemaGamut));
        assert_eq!(expected_space("Warm Film.cube"), None);
    }

    #[test]
    fn mismatch_only_when_different() {
        assert!(mismatch("VLog_look.cube", ColorSpaceID::Rec709).is_some());
        assert!(mismatch("VLog_look.cube", ColorSpaceID::VLogVGamut).is_none());
        assert!(mismatch("CLog3.cube", ColorSpaceID::CanonLog3BT709).is_none());
        assert!(mismatch("Warm.cube", ColorSpaceID::Rec709).is_none());
    }

    #[test]
    fn the_message_names_both_spaces() {
        let m = mismatch("VLog_look.cube", ColorSpaceID::Rec709).map(|(_, text)| text);
        assert_eq!(m.as_deref(), Some("This LUT looks made for V-Log footage; the clip is Rec.709."));
    }
}
