import Foundation

/// FFmpeg's AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace numbers as the CoreMedia tag strings the
/// Mac import stores in `VideoTrackInfo` (detection and the smart-render check compare these). Unknown or unspecified: nil.
enum FFmpegColorTags {
    static func primaries(_ v: Int) -> String? {
        switch v {
        case 1: "ITU_R_709_2"
        case 5: "EBU_3213"
        case 6: "SMPTE_C"
        case 9: "ITU_R_2020"
        case 11, 12: "P3_D65"
        default: nil
        }
    }

    static func transfer(_ v: Int) -> String? {
        switch v {
        case 1: "ITU_R_709_2"
        case 14, 15: "ITU_R_2020"
        case 16: "SMPTE_ST_2084_PQ"
        case 18: "ITU_R_2100_HLG"
        default: nil
        }
    }

    static func matrix(_ v: Int) -> String? {
        switch v {
        case 1: "ITU_R_709_2"
        case 5, 6: "ITU_R_601_4"
        case 9, 10: "ITU_R_2020"
        default: nil
        }
    }
}
