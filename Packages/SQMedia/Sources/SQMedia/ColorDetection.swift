import AVFoundation
import CoreMedia
import Foundation
import SQCore

/// Source color space detection, done once at import.
public enum ColorDetection {
    /// Order: explicit file tag (HLG or PQ transfer; primaries may be missing or P3; Apple Log) first, then Sony
    /// NonRealTimeMeta (S-Log3 / S-Gamut3.Cine; Sony files are untagged), then Canon's clip metadata (Canon Log, Log 2
    /// or Log 3 with the gamut the camera recorded, only when both are named), else Rec.709. Tag values are the CoreMedia
    /// extension strings. Panasonic V-Log and DJI D-Log files carry no usable tag: the clip or project input setting
    /// covers them (`ColorSpaceID.effective`).
    /// A Dolby Vision record (iPhone profile 8.4) only decides when the file has no HDR / Log transfer tag (a remux that
    /// dropped the `colr` atom): its base-layer compatibility id then names HLG or PQ.
    public static func detect(colorPrimaries: String?, transfer: String?, sony: SonyMetadata?,
                              dolbyVision: DolbyVisionConfig? = nil, canon: CanonMetadata? = nil) -> ColorSpaceID {
        let t = transfer?.lowercased() ?? ""
        if t.contains("hlg") { return .hlgBT2020 }
        if t.contains("2084") || t.contains("_pq") { return .pqBT2020 }
        // Apple Log: the CoreMedia value is a reverse-DNS id ("com.apple.log") from kCMFormatDescriptionLogTransferFunction_AppleLog (see `transferTag`), matched with separators stripped; Apple Log 2 also maps to Apple Log (no separate curve yet).
        if t.filter({ $0 != "_" && $0 != "." && $0 != "-" }).contains("applelog") { return .appleLog }
        if let dv = dolbyVision?.baseLayerColorSpace, dv.isHDR { return dv }
        if let sony, sony.isSLog3SGamut3Cine { return .sLog3SGamut3Cine }
        if let space = canon?.colorSpace { return space }
        return .rec709
    }

    /// The Dolby Vision configuration record of a format description (`dvvC` / `dvcC` / `dvwC` sample description atom).
    public static func dolbyVision(of fd: CMFormatDescription) -> DolbyVisionConfig? {
        dolbyVision(extensions: CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:])
    }

    static func dolbyVision(extensions ext: [String: Any]) -> DolbyVisionConfig? {
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        for name in CodecConfig.dolbyVisionAtoms {
            if let d = atoms[name] as? Data, let c = CodecConfig.dolbyVision(d) { return c }
        }
        return nil
    }

    /// The transfer tag detection works on. Apple Log is not a `TransferFunction` value: iPhone files carry a regular
    /// transfer (Rec.709) plus the separate `LogTransferFunction` key (macOS 14.2+), which therefore wins when present.
    public static func transferTag(of fd: CMFormatDescription) -> String? {
        transferTag(extensions: CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:])
    }

    static func transferTag(extensions ext: [String: Any]) -> String? {
        if #available(macOS 14.2, *), let log = ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String { return log }
        return ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
    }

    /// Detection straight from a format description (tags plus optional Sony metadata).
    public static func detect(formatDescription fd: CMFormatDescription, sony: SonyMetadata?) -> ColorSpaceID {
        detect(colorPrimaries: CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
               transfer: transferTag(of: fd), sony: sony, dolbyVision: dolbyVision(of: fd))
    }

    /// Probes the file (tags, Sony metadata, embedded LUT) for media whose `MediaInfo.needsColorDetection` is true.
    /// nil if the file has no readable video track. Call on project open / relink and store into `MediaInfo`.
    public static func detect(url: URL) async -> (space: ColorSpaceID, embeddedLUTName: String?)? {
        if WebMFile.isWebM(url) {
            guard let d = try? await WebMDemuxer(url: url) else { return nil }
            let ext = CMFormatDescriptionGetExtensions(d.formatDescription) as? [String: Any] ?? [:]
            return (detect(colorPrimaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                           transfer: transferTag(extensions: ext), sony: nil), nil)
        }
        if MXFFile.isMXF(url) {
            guard let d = try? await MXFDemuxer(url: url) else { return nil }
            let ext = CMFormatDescriptionGetExtensions(d.formatDescription) as? [String: Any] ?? [:]
            let camera = CameraMetadata.read(forClip: url, boxes: false)
            return (detect(colorPrimaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                           transfer: transferTag(extensions: ext), sony: camera.sony, canon: camera.canon), nil)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return nil }
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let camera = CameraMetadata.read(forClip: url)
        let space = detect(colorPrimaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                           transfer: transferTag(extensions: ext), sony: camera.sony, dolbyVision: dolbyVision(extensions: ext),
                           canon: camera.canon)
        let lut = (try? EmbeddedMeta.lut(inClip: url)) ?? nil
        return (space, lut.map { $0.name ?? "Embedded LUT" })
    }
}
