import Foundation
import SQCore

/// The portable half of color detection (no AVFoundation): the tag rules shared with `ColorDetection` (Mac) and the
/// probe for containers FFmpeg reads (Windows). Tags use the CoreMedia strings ("ITU_R_709_2", "SMPTE_ST_2084_PQ").
public enum ColorTagDetection {
    /// Order: explicit file tag (HLG or PQ transfer; primaries may be missing or P3; Apple Log) first, then a Dolby Vision
    /// base layer, then Sony NonRealTimeMeta (S-Log3 / S-Gamut3.Cine; Sony files are untagged), then Canon's clip metadata,
    /// else Rec.709.
    public static func detect(colorPrimaries: String?, transfer: String?, sony: SonyMetadata?,
                              dolbyVision: DolbyVisionConfig? = nil, canon: CanonMetadata? = nil) -> ColorSpaceID {
        let t = transfer?.lowercased() ?? ""
        if t.contains("hlg") { return .hlgBT2020 }
        if t.contains("2084") || t.contains("_pq") { return .pqBT2020 }
        if t.filter({ $0 != "_" && $0 != "." && $0 != "-" }).contains("applelog") { return .appleLog }
        if let dv = dolbyVision?.baseLayerColorSpace, dv.isHDR { return dv }
        if let sony, sony.isSLog3SGamut3Cine { return .sLog3SGamut3Cine }
        if let space = canon?.colorSpace { return space }
        return .rec709
    }

    /// Detection for a clip file from its stream tags plus the camera metadata beside or inside it (Sony XML sidecar or
    /// `xml ` box, Canon maker notes) and the name of an embedded look LUT.
    public static func detect(url: URL, colorPrimaries: String?, transfer: String?) -> (space: ColorSpaceID, embeddedLUTName: String?) {
        let camera = CameraMetadata.read(forClip: url)
        let space = detect(colorPrimaries: colorPrimaries, transfer: transfer, sony: camera.sony, canon: camera.canon)
        let lut = (try? EmbeddedMeta.lutHeader(inClip: url)) ?? nil
        return (space, lut.map { $0.name ?? "Embedded LUT" })
    }
}
