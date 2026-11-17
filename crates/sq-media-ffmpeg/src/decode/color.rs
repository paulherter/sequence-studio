use crate::shim::VideoInfo;
use sq_core_model::FieldOrder;
use sq_frame::sqframe::SQFrameColorSpace;

// FFmpeg's AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace numbers as the CoreMedia tag strings the
// Mac import stores in `VideoTrackInfo` (detection and the smart-render check compare these). Unknown: `None`.

/// Tag for an AVColorPrimaries value.
/// The field order of an interlaced stream from FFmpeg's `AVFieldOrder` (2 TT, 3 BB, 4 TB, 5 BT); `None` for progressive
/// and unknown. As Swift (`MediaImporter.fieldOrder`): the bottom field is first only when the stream says so.
pub fn field_order_of(av: i32) -> Option<FieldOrder> {
    match av {
        2 | 4 => Some(FieldOrder::TopFirst),
        3 | 5 => Some(FieldOrder::BottomFirst),
        _ => None,
    }
}

pub fn primaries_tag(v: i32) -> Option<&'static str> {
    match v {
        1 => Some("ITU_R_709_2"),
        5 => Some("EBU_3213"),
        6 => Some("SMPTE_C"),
        9 => Some("ITU_R_2020"),
        11 | 12 => Some("P3_D65"),
        _ => None,
    }
}

/// Tag for an AVColorTransferCharacteristic value.
pub fn transfer_tag(v: i32) -> Option<&'static str> {
    match v {
        1 => Some("ITU_R_709_2"),
        14 | 15 => Some("ITU_R_2020"),
        16 => Some("SMPTE_ST_2084_PQ"),
        18 => Some("ITU_R_2100_HLG"),
        _ => None,
    }
}

/// Tag for an AVColorSpace value.
pub fn matrix_tag(v: i32) -> Option<&'static str> {
    match v {
        1 => Some("ITU_R_709_2"),
        5 | 6 => Some("ITU_R_601_4"),
        9 | 10 => Some("ITU_R_2020"),
        _ => None,
    }
}

/// True when the stream's own flag says full range (AVCOL_RANGE_JPEG = 2).
pub fn flagged_full_range(i: &VideoInfo) -> bool {
    i.color_range == 2
}

/// The neutral color space of a stream's tags and whether its pictures are read as full range: the stream's own flag, at
/// every bit depth. Swift does the same: AVFoundation turns the flag into `kCMFormatDescriptionExtension_FullRangeVideo`
/// (Sony XAVC S-I S-Log3 4:2:2 10-bit: `FullRangeVideo 1`) and `DecodePixelFormat.isFullRange` reads it. Reading such
/// codes as video range stretches them (luma x1023/876, chroma x1023/896), which the camera LUT turns into a clearly
/// harder, more saturated picture.
pub fn frame_color(i: &VideoInfo) -> (SQFrameColorSpace, bool) {
    let full = flagged_full_range(i);
    let space = match (i.color_primaries, i.color_transfer, i.color_matrix) {
        (9, 16, _) | (_, 16, 9) => SQFrameColorSpace::Rec2020PQ,
        (9, 18, _) | (_, 18, 9) => SQFrameColorSpace::Rec2020HLG,
        (9, _, _) | (_, _, 9) | (_, _, 10) => SQFrameColorSpace::Rec2020,
        (1, _, _) | (_, _, 1) => SQFrameColorSpace::Rec709,
        (5, _, _) | (6, _, _) | (_, _, 5) | (_, _, 6) => SQFrameColorSpace::Rec601,
        _ => SQFrameColorSpace::Unspecified,
    };
    (space, full)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(primaries: i32, transfer: i32, matrix: i32, range: i32) -> VideoInfo {
        VideoInfo {
            width: 0,
            height: 0,
            tb_num: 1,
            tb_den: 1,
            fr_num: 0,
            fr_den: 0,
            rotation: 0,
            bit_depth: 8,
            codec: String::new(),
            pix_fmt: String::new(),
            color_primaries: primaries,
            color_transfer: transfer,
            color_matrix: matrix,
            color_range: range,
            field_order: 0,
            bits_per_coded_sample: 0,
            codec_tag: 0,
            sar_num: 0,
            sar_den: 0,
            dolby_vision: None,
        }
    }

    #[test]
    fn field_order_follows_ffmpeg_and_the_swift_rule() {
        assert_eq!(
            [0, 1, 2, 3, 4, 5].map(field_order_of),
            [
                None,
                None,
                Some(FieldOrder::TopFirst),
                Some(FieldOrder::BottomFirst),
                Some(FieldOrder::TopFirst),
                Some(FieldOrder::BottomFirst)
            ]
        );
    }

    #[test]
    fn tags_follow_the_ffmpeg_numbers() {
        assert_eq!(primaries_tag(1), Some("ITU_R_709_2"));
        assert_eq!(primaries_tag(12), Some("P3_D65"));
        assert_eq!(transfer_tag(16), Some("SMPTE_ST_2084_PQ"));
        assert_eq!(transfer_tag(2), None);
        assert_eq!(matrix_tag(6), Some("ITU_R_601_4"));
        assert_eq!(matrix_tag(0), None);
    }

    #[test]
    fn a_deep_stream_flagged_full_is_read_as_full_range_like_swift() {
        // C2177.MP4 (Sony ZV-E1, S-Log3, yuv422p10le): color_range=pc, no color tags; AVFoundation: FullRangeVideo 1.
        let mut deep = info(2, 2, 2, 2);
        deep.bit_depth = 10;
        assert!(flagged_full_range(&deep));
        assert!(frame_color(&deep).1, "10-bit full-flagged codes are read full range");
        assert!(frame_color(&info(1, 1, 1, 2)).1, "8-bit full range stays full");
        let mut video = info(2, 2, 2, 1);
        video.bit_depth = 10;
        assert!(!frame_color(&video).1, "an unflagged stream stays video range");
    }

    #[test]
    fn frame_color_picks_the_hdr_and_rec_spaces() {
        assert_eq!(frame_color(&info(9, 16, 9, 2)), (SQFrameColorSpace::Rec2020PQ, true));
        assert_eq!(frame_color(&info(9, 18, 9, 1)), (SQFrameColorSpace::Rec2020HLG, false));
        assert_eq!(frame_color(&info(9, 1, 9, 1)).0, SQFrameColorSpace::Rec2020);
        assert_eq!(frame_color(&info(1, 1, 1, 1)).0, SQFrameColorSpace::Rec709);
        assert_eq!(frame_color(&info(6, 6, 6, 1)).0, SQFrameColorSpace::Rec601);
        assert_eq!(frame_color(&info(2, 2, 2, 0)).0, SQFrameColorSpace::Unspecified);
    }
}
