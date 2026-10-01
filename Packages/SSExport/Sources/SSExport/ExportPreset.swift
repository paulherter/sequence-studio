import SSCore

public enum SocialPlatform: String, Sendable, Codable, CaseIterable {
    case tiktok, reels, shorts
    public var displayName: String {
        switch self { case .tiktok: "TikTok"; case .reels: "Instagram Reels"; case .shorts: "YouTube Shorts" }
    }
}

public struct ExportPreset: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case matchSource, youtube1080, youtube4K, social, proRes
    }
    public let kind: Kind
    /// Only for `.social` presets.
    public let platform: SocialPlatform?
    public let codec: VideoCodec

    public var id: String {
        switch kind {
        case .social: "\(platform?.rawValue ?? "social")-\(codec.rawValue)"
        default: kind.rawValue
        }
    }
    public var name: String {
        switch kind {
        case .matchSource: "Match Source – High bitrate (H.264)"
        case .youtube1080: "YouTube 1080p Full HD"
        case .youtube4K: "YouTube 4K Ultra HD"
        case .proRes: "ProRes 422 HQ (master)"
        case .social: "\(platform?.displayName ?? "Vertical") 1080×1920 (\(codec == .h264 ? "H.264" : codec == .hevc ? "HEVC" : "ProRes 422 HQ"))"
        }
    }

    public static func preset(_ platform: SocialPlatform, _ codec: VideoCodec) -> ExportPreset {
        ExportPreset(kind: .social, platform: platform, codec: codec)
    }
    public static let matchSource = ExportPreset(kind: .matchSource, platform: nil, codec: .h264)
    public static let youtube1080 = ExportPreset(kind: .youtube1080, platform: nil, codec: .h264)
    public static let youtube4K = ExportPreset(kind: .youtube4K, platform: nil, codec: .h264)
    public static let proRes = ExportPreset(kind: .proRes, platform: nil, codec: .prores422HQ)

    /// TikTok / Reels / Shorts, H.264 and HEVC.
    public static let social: [ExportPreset] = SocialPlatform.allCases.flatMap { p in
        [VideoCodec.h264, .hevc].map { ExportPreset(kind: .social, platform: p, codec: $0) }
    }
    /// Everything the Export sheet offers, in menu order.
    public static let all: [ExportPreset] = [.matchSource, .youtube1080, .youtube4K] + social + [.proRes]
    public static let `default` = ExportPreset(kind: .social, platform: .tiktok, codec: .h264)

    /// Settings with the sequence's frame size / rate where the preset follows the source
    /// (Match Source: size and rate, ProRes: size and rate, YouTube: rate; social presets stay 1080x1920 30 fps).
    public func settings(matching format: SequenceFormat?) -> ExportSettings {
        var s = settings
        guard let f = format, f.isValid else { return s }
        let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
        switch kind {
        case .matchSource, .proRes:
            s.video.width = f.width & ~1; s.video.height = f.height & ~1
            s.video.frameDuration = f.frameDuration
            if kind == .matchSource {
                let bps = Double(s.video.width * s.video.height) * fps * 0.18
                let avg = Int(min(max(bps, 8_000_000), 80_000_000))
                s.video.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2)
                s.video.keyframeInterval = max(1, Int(fps.rounded()) * 2)
            }
        case .youtube1080, .youtube4K:
            s.video.frameDuration = f.frameDuration
            if fps > 30 {
                let b = s.video.bitrate.averageBitsPerSecond * 3 / 2
                s.video.bitrate = .averageAndMax(average: b, max: b * 3 / 2)
            }
            s.video.keyframeInterval = max(1, Int(fps.rounded()) * 2)
        case .social: break
        }
        return s
    }

    /// Preset defaults: 1080x1920 30 fps for social, 1080p / 2160p 30 fps for YouTube, Rec.709 1-1-1, AAC 48 kHz stereo.
    public var settings: ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.color = .rec709
        s.audio.bitrate = 192_000
        switch kind {
        case .proRes:
            return .proRes422HQMaster
        case .matchSource:
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 20_000_000, max: 30_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000
        case .youtube1080:
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 12_000_000, max: 18_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000   // AAC stereo at 48 kHz tops out at 320 kbit/s: more fails with "Cannot Encode Media"
        case .youtube4K:
            s.video.width = 3840; s.video.height = 2160
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 45_000_000, max: 68_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000   // AAC stereo at 48 kHz tops out at 320 kbit/s: more fails with "Cannot Encode Media"
        case .social:
            s.video.width = 1080; s.video.height = 1920
            s.video.frameDuration = Time(1, 30)
            let avg: Int
            switch (platform ?? .tiktok, codec) {
            case (.tiktok, .h264): avg = 12_000_000
            case (.reels, .h264): avg = 10_000_000
            case (.shorts, .h264): avg = 14_000_000
            case (.tiktok, .hevc): avg = 8_000_000
            case (.reels, .hevc): avg = 7_000_000
            case (.shorts, .hevc): avg = 10_000_000
            case (_, .prores422HQ): avg = 12_000_000
            }
            s.video.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2)
            s.video.keyframeInterval = 60
            s.video.profile = codec == .h264 ? .high : .main
        }
        return s
    }
}

public extension ExportSettings {
    /// Default = TikTok 9:16 H.264.
    static var socialDefault: ExportSettings { ExportPreset.default.settings }
}
