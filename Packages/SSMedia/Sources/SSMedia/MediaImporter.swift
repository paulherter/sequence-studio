import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import SSCore

public enum MediaImporter {
    public static func probe(_ url: URL) async throws -> (MediaRef, MediaInfo) {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), let dur = Time(duration) else { throw MediaError.unreadable }
        let vTrack = try? await asset.loadTracks(withMediaType: .video).first
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first
        guard vTrack != nil || aTrack != nil else { throw MediaError.unreadable }

        var video: VideoTrackInfo?
        if let vTrack {
            let demux = try await AVDemuxer(url: url)
            video = try videoInfo(format: demux.formatDescription, index: demux.index)
        }
        var audio: AudioTrackInfo?
        if let aTrack, let fd = try? await aTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            audio = AudioTrackInfo(sampleRate: Int(asbd.mSampleRate.rounded()), channels: Int(asbd.mChannelsPerFrame),
                                   codec: fourCC(CMFormatDescriptionGetMediaSubType(fd)))
        }
        var info = MediaInfo(duration: dur, video: video, audio: audio)
        if let v = video {
            // Detected once here; Sony metadata and the embedded camera LUT are best-effort (nil on any error).
            let sony = try? SonyMetadata.read(forClip: url)
            info.detectedColorSpace = ColorDetection.detect(colorPrimaries: v.colorPrimaries, transfer: v.transfer, sony: sony)
            if let lut = (try? EmbeddedMeta.lut(inClip: url)) ?? nil {
                info.embeddedLUTName = lut.name ?? "Embedded LUT"
            }
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let fp = MediaFingerprint(size: size, modified: attrs?[.modificationDate] as? Date, headHash: headHash(url))
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            ?? url.bookmarkData()
        let ref = MediaRef(name: url.lastPathComponent, path: url.path, bookmark: bookmark, fingerprint: fp,
                           duration: dur, info: info)
        return (ref, info)
    }

    static func videoInfo(format fd: CMFormatDescription, index: SampleIndex) throws -> VideoTrackInfo {
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let sub = CMFormatDescriptionGetMediaSubType(fd)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let (chroma, depth) = chromaAndDepth(subType: sub, extensions: ext)

        // Frame duration: most common pts delta; VFR when deltas are not (almost) constant.
        var counts: [Time: Int] = [:]
        let e = index.entries
        for i in 1..<max(1, e.count) { counts[e[i].pts - e[i - 1].pts, default: 0] += 1 }
        let modal = counts.max { $0.value < $1.value }?.key ?? e.first?.duration ?? Time(1, 30)
        // Sequence-facing rate: average over the whole clip snapped to a standard rate (a per-sample delta misleads on VFR).
        let nominal = e.count > 1 ? FrameRate.sequenceFrameDuration(frameCount: e.count, duration: index.duration) : modal
        let vfr = counts.count > 1 && counts.keys.contains { abs(Int128($0.value) * Int128(modal.timescale) - Int128(modal.value) * Int128($0.timescale)) * 50 > Int128(modal.value) * Int128($0.timescale) }

        func tag(_ key: CFString) -> String? { ext[key as String] as? String }
        return VideoTrackInfo(width: Int(dims.width), height: Int(dims.height), codec: fourCC(sub), bitDepth: depth, chroma: chroma,
                              nominalFrameDuration: nominal, isVariableFrameRate: vfr,
                              colorPrimaries: tag(kCMFormatDescriptionExtension_ColorPrimaries),
                              transfer: tag(kCMFormatDescriptionExtension_TransferFunction),
                              matrix: tag(kCMFormatDescriptionExtension_YCbCrMatrix))
    }

    static func chromaAndDepth(subType: FourCharCode, extensions ext: [String: Any]) -> (String, Int) {
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Data] ?? [:]
        switch fourCC(subType) {
        case "avc1", "avc3":
            if let d = atoms["avcC"], let r = CodecConfig.avc(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 8)
        case "hvc1", "hev1":
            if let d = atoms["hvcC"], let r = CodecConfig.hevc(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 10)
        case "apch", "apcn", "apcs", "apco": return ("4:2:2", 10)
        case "ap4h", "ap4x": return ("4:4:4", (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int) ?? 12)
        default: return ("4:2:0", (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int) ?? 8)
        }
    }

    private static func headHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func fourCC(_ c: FourCharCode) -> String {
    String(decoding: [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)], as: UTF8.self)
}
