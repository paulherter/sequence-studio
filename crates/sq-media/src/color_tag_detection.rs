//! Port of `SQMedia/Sources/SQMedia/ColorTagDetection.swift`.
//!
//! The portable half of color detection (no AVFoundation): the tag rules shared with `ColorDetection` (Mac) and the probe
//! for containers FFmpeg reads (Windows). Tags use the CoreMedia strings ("ITU_R_709_2", "SMPTE_ST_2084_PQ").

use sq_core_color::ColorSpaceIdExt;
use sq_core_model::ColorSpaceID;

use crate::canon_metadata::CanonMetadata;
use crate::codec_config::DolbyVisionConfig;
use crate::sony_metadata::SonyMetadata;

/// The tag rules that pick a clip's input color space.
pub struct ColorTagDetection;

impl ColorTagDetection {
    /// Order: explicit file tag (HLG or PQ transfer; primaries may be missing or P3; Apple Log) first, then a Dolby Vision
    /// base layer, then Sony NonRealTimeMeta (S-Log3 / S-Gamut3.Cine; Sony files are untagged), then Canon's clip metadata,
    /// else Rec.709.
    pub fn detect(
        _color_primaries: Option<&str>,
        transfer: Option<&str>,
        sony: Option<&SonyMetadata>,
        dolby_vision: Option<&DolbyVisionConfig>,
        canon: Option<&CanonMetadata>,
    ) -> ColorSpaceID {
        let t = transfer.map(str::to_lowercase).unwrap_or_default();
        if t.contains("hlg") {
            return ColorSpaceID::HlgBT2020;
        }
        if t.contains("2084") || t.contains("_pq") {
            return ColorSpaceID::PqBT2020;
        }
        if t.chars().filter(|c| !matches!(c, '_' | '.' | '-')).collect::<String>().contains("applelog") {
            return ColorSpaceID::AppleLog;
        }
        if let Some(dv) = dolby_vision.and_then(DolbyVisionConfig::base_layer_color_space)
            && dv.is_hdr()
        {
            return dv;
        }
        if sony.is_some_and(SonyMetadata::is_slog3_sgamut3_cine) {
            return ColorSpaceID::SLog3SGamut3Cine;
        }
        if let Some(space) = canon.and_then(CanonMetadata::color_space) {
            return space;
        }
        ColorSpaceID::Rec709
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SONY_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
<Device manufacturer="Sony" modelName="ZV-E1"/>
<AcquisitionRecord><Group name="CameraUnitMetadataSet">
<Item name="CaptureGammaEquation" value="s-log3-cine"/>
<Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
</Group></AcquisitionRecord>
</NonRealTimeMeta>"#;

    #[test]
    fn transfer_tags_decide() {
        let detect = |p, t| ColorTagDetection::detect(p, t, None, None, None);
        assert_eq!(detect(Some("ITU_R_2020"), Some("ITU_R_2100_HLG")), ColorSpaceID::HlgBT2020);
        assert_eq!(detect(Some("ITU_R_2020"), Some("SMPTE_ST_2084_PQ")), ColorSpaceID::PqBT2020);
        assert_eq!(detect(None, None), ColorSpaceID::Rec709);
        assert_eq!(detect(None, Some("Apple_Log")), ColorSpaceID::AppleLog);
    }

    #[test]
    fn untagged_sony_clip_is_slog3() {
        let sony = SonyMetadata::from_xml(SONY_XML.as_bytes()).ok();
        assert!(sony.is_some());
        assert_eq!(ColorTagDetection::detect(None, None, sony.as_ref(), None, None), ColorSpaceID::SLog3SGamut3Cine);
    }
}
