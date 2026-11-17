//! Port of the portable parts of `SQMedia/Sources/SQMedia/WebM/WebMDemuxer.swift`.
//!
//! The Swift demuxer builds CoreMedia format descriptions and sample buffers and registers VideoToolbox decoders; the
//! Windows build of the package leaves it out. Only the codec naming is plain logic.

/// Matroska codec ID of H.264.
pub const AVC_ID: &str = "V_MPEG4/ISO/AVC";
/// Matroska codec ID of HEVC.
pub const HEVC_ID: &str = "V_MPEGH/ISO/HEVC";

/// Readable name of a Matroska codec ID for messages ("V_VP8" -> "VP8").
pub fn codec_name(id: &str) -> String {
    match id.strip_prefix("V_").or_else(|| id.strip_prefix("A_")) {
        Some(rest) => rest.to_string(),
        None => id.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_names_drop_the_track_type_prefix() {
        assert_eq!(codec_name("V_VP8"), "VP8");
        assert_eq!(codec_name("A_OPUS"), "OPUS");
        assert_eq!(codec_name(AVC_ID), "MPEG4/ISO/AVC");
        assert_eq!(codec_name("S_TEXT/UTF8"), "S_TEXT/UTF8");
        assert_eq!(codec_name(""), "");
    }
}
