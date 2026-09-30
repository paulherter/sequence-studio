import SSCore

public enum SocialPlatform: String, Sendable, Codable, CaseIterable {
    case tiktok, reels, shorts
    public var displayName: String {
        switch self { case .tiktok: "TikTok"; case .reels: "Instagram Reels"; case .shorts: "YouTube Shorts" }
    }
}

public struct ExportPreset: Sendable, Hashable, Identifiable {
    public let platform: SocialPlatform
    public let codec: VideoCodec
    public var id: String { "\(platform.rawValue)-\(codec.rawValue)" }
    public var name: String { "\(platform.displayName) (\(codec == .h264 ? "H.264" : codec == .hevc ? "HEVC" : "ProRes 422 HQ"))" }

    public static func preset(_ platform: SocialPlatform, _ codec: VideoCodec) -> ExportPreset {
        ExportPreset(platform: platform, codec: codec)
    }
    public static let all: [ExportPreset] = SocialPlatform.allCases.flatMap { p in
        [VideoCodec.h264, .hevc].map { ExportPreset(platform: p, codec: $0) }
    }
    public static let `default` = ExportPreset(platform: .tiktok, codec: .h264)

    /// 1080x1920, 30 fps, Rec.709 1-1-1, AAC 48 kHz stereo.
    public var settings: ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.video.width = 1080; s.video.height = 1920
        s.video.frameDuration = Time(1, 30)
        let avg: Int
        switch (platform, codec) {
        case (.tiktok, .h264): avg = 12_000_000
        case (.reels, .h264): avg = 10_000_000
        case (.shorts, .h264): avg = 14_000_000
        case (.tiktok, .hevc): avg = 8_000_000
        case (.reels, .hevc): avg = 7_000_000
        case (.shorts, .hevc): avg = 10_000_000
        case (_, .prores422HQ): avg = 12_000_000   // unused; social presets are H.264/HEVC only
        }
        s.video.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2)
        s.video.keyframeInterval = 60
        s.video.profile = codec == .h264 ? .high : .main
        s.color = .rec709
        s.audio.bitrate = 192_000
        return s
    }
}

public extension ExportSettings {
    /// Default = TikTok 9:16 H.264.
    static var socialDefault: ExportSettings { ExportPreset.default.settings }
}
