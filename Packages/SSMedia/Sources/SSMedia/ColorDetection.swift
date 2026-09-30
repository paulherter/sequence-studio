import AVFoundation
import CoreMedia
import Foundation
import SSCore

/// Source colour space detection, done once at import.
public enum ColorDetection {
    /// Order: explicit file tag (HLG transfer; primaries may be missing or P3) first, then Sony NonRealTimeMeta (S-Log3 / S-Gamut3.Cine; Sony files
    /// are untagged), else Rec.709. Tag values are the CoreMedia extension strings.
    public static func detect(colorPrimaries: String?, transfer: String?, sony: SonyMetadata?) -> ColorSpaceID {
        let t = transfer?.lowercased() ?? ""
        let p = colorPrimaries?.lowercased() ?? ""
        // TODO: PQ / HDR10 (ITU_R_2100_PQ / SMPTE_ST_2084) is not supported in V1 and falls through to Rec.709.
        if t.contains("hlg") { return .hlgBT2020 }
        if let sony, sony.isSLog3SGamut3Cine { return .sLog3SGamut3Cine }
        return .rec709
    }

    /// Probes the file (tags, Sony metadata, embedded LUT) for media whose `MediaInfo.needsColorDetection` is true.
    /// nil if the file has no readable video track. Call on project open / relink and store into `MediaInfo`.
    public static func detect(url: URL) async -> (space: ColorSpaceID, embeddedLUTName: String?)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return nil }
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let sony = try? SonyMetadata.read(forClip: url)
        let space = detect(colorPrimaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                           transfer: ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String, sony: sony)
        let lut = (try? EmbeddedMeta.lut(inClip: url)) ?? nil
        return (space, lut.map { $0.name ?? "Embedded LUT" })
    }
}
