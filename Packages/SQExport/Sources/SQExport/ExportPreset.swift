import SQCore

public enum SocialPlatform: String, Sendable, Codable, CaseIterable {
    case tiktok, reels, shorts
    public var displayName: String {
        switch self { case .tiktok: "TikTok"; case .reels: "Instagram Reels"; case .shorts: "YouTube Shorts" }
    }
}

public struct ExportPreset: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case matchSource, youtube1080, youtube1440, youtube4K, social, proRes
        /// X (Twitter) 1080p and Facebook 1080p, H.264.
        case xPost, facebook
        /// HEVC Main 10 at the sequence's size and rate (W9.4).
        case hevc10
        /// H.264 at the average bitrate encoded in several passes by the software encoder: the best picture for a given file size, slower.
        case bestAtSize
        case proRes422, proRes4444
        /// Instagram feed 4:5 (1080x1350) and 1:1 (1080x1080), and Instagram Stories 9:16 (1080x1920), H.264.
        case feedPortrait, feedSquare, stories
        /// Audio only: the mixed audio as an M4A (AAC 256 kbit/s) or a WAV (24-bit PCM) file, no picture.
        case audioM4A, audioWAV
        /// Audio only: lossless FLAC (24-bit).
        case audioFLAC
        /// An animated GIF, or a folder of numbered PNG images (with alpha) at the sequence's size and rate.
        case gif, imageSequence
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
        case .youtube1440: "YouTube 1440p QHD"
        case .youtube4K: "YouTube 4K Ultra HD"
        case .xPost: "X (Twitter) 1080p (H.264)"
        case .facebook: "Facebook 1080p (H.264)"
        case .proRes: "ProRes 422 HQ (master)"
        case .proRes422: "ProRes 422 (master)"
        case .proRes4444: "ProRes 4444 (master)"
        case .hevc10: "Match Source – HEVC 10-bit"
        case .bestAtSize: "Best quality at size – H.264 (multi-pass)"
        case .feedPortrait: "Instagram Feed 4:5 1080×1350 (H.264)"
        case .feedSquare: "Instagram Feed 1:1 1080×1080 (H.264)"
        case .stories: "Instagram Stories 1080×1920 (H.264)"
        case .social: "\(platform?.displayName ?? "Vertical") 1080×1920 (\(codec.displayName))"
        case .audioM4A: "Audio only – M4A (AAC)"
        case .audioWAV: "Audio only – WAV (24-bit PCM)"
        case .audioFLAC: "Audio only – FLAC (lossless)"
        case .gif: "Animated GIF"
        case .imageSequence: "Image sequence (PNG)"
        }
    }

    public var isAudioOnly: Bool { kind == .audioM4A || kind == .audioWAV || kind == .audioFLAC }

    public static func preset(_ platform: SocialPlatform, _ codec: VideoCodec) -> ExportPreset {
        ExportPreset(kind: .social, platform: platform, codec: codec)
    }
    public static let matchSource = ExportPreset(kind: .matchSource, platform: nil, codec: .h264)
    public static let youtube1080 = ExportPreset(kind: .youtube1080, platform: nil, codec: .h264)
    public static let youtube1440 = ExportPreset(kind: .youtube1440, platform: nil, codec: .h264)
    public static let xPost = ExportPreset(kind: .xPost, platform: nil, codec: .h264)
    public static let facebook = ExportPreset(kind: .facebook, platform: nil, codec: .h264)
    public static let youtube4K = ExportPreset(kind: .youtube4K, platform: nil, codec: .h264)
    public static let proRes = ExportPreset(kind: .proRes, platform: nil, codec: .prores422HQ)
    public static let proRes422 = ExportPreset(kind: .proRes422, platform: nil, codec: .prores422)
    /// Opaque until W9.2 (alpha export); the source already renders 4:4:4:4.
    public static let proRes4444 = ExportPreset(kind: .proRes4444, platform: nil, codec: .prores4444)
    public static let hevc10 = ExportPreset(kind: .hevc10, platform: nil, codec: .hevc)
    public static let bestAtSize = ExportPreset(kind: .bestAtSize, platform: nil, codec: .h264)
    public static let feedPortrait = ExportPreset(kind: .feedPortrait, platform: nil, codec: .h264)
    public static let feedSquare = ExportPreset(kind: .feedSquare, platform: nil, codec: .h264)
    public static let stories = ExportPreset(kind: .stories, platform: nil, codec: .h264)
    public static let audioM4A = ExportPreset(kind: .audioM4A, platform: nil, codec: .h264)
    public static let audioWAV = ExportPreset(kind: .audioWAV, platform: nil, codec: .h264)
    public static let audioFLAC = ExportPreset(kind: .audioFLAC, platform: nil, codec: .h264)
    public static let gif = ExportPreset(kind: .gif, platform: nil, codec: .h264)
    public static let imageSequence = ExportPreset(kind: .imageSequence, platform: nil, codec: .h264)

    /// TikTok / Reels / Shorts, H.264 and HEVC.
    public static let social: [ExportPreset] = SocialPlatform.allCases.flatMap { p in
        [VideoCodec.h264, .hevc].map { ExportPreset(kind: .social, platform: p, codec: $0) }
    }
    /// Everything the Export sheet offers, in menu order.
    public static let all: [ExportPreset] = [.matchSource, .hevc10, .bestAtSize, .youtube1080, .youtube1440, .youtube4K, .xPost, .facebook] + social + [.feedPortrait, .feedSquare, .stories, .proRes, .proRes422, .proRes4444, .audioM4A, .audioWAV, .audioFLAC, .gif, .imageSequence]
    public static let `default` = ExportPreset(kind: .social, platform: .tiktok, codec: .h264)

    /// The preset a sequence exports with by default: its target platform's (TikTok/Reels/Shorts, YouTube 1080p, 1440p or 4K by
    /// frame width), 4:5 or 1:1 for feed posts (by the sequence's shape), Match Source when the sequence has no target.
    public static func defaultPreset(format: SequenceFormat?, target: DeliveryTarget?) -> ExportPreset {
        guard let target else { return .matchSource }
        switch target.platform {
        case .tiktok: return preset(.tiktok, .h264)
        case .reels: return preset(.reels, .h264)
        case .shorts: return preset(.shorts, .h264)
        case .youtube: let w = format?.width ?? 0
            return w >= 3840 ? .youtube4K : w >= 2560 ? .youtube1440 : .youtube1080
        case .socialFeed: return (format.map { $0.width == $0.height } ?? false) ? .feedSquare : .feedPortrait
        }
    }

    /// `settings(matching:)` plus the delivery target's loudness normalization (LUFS and true-peak ceiling).
    public func settings(matching format: SequenceFormat?, target: DeliveryTarget?) -> ExportSettings {
        var s = settings(matching: format)
        if let t = target { s.audio.loudness = LoudnessNormalization(targetLUFS: t.targetLUFS, truePeakCeilingDB: t.truePeakDB) }
        return s
    }

    /// Settings with the sequence's frame size / rate where the preset follows the source
    /// (Match Source: size and rate, ProRes: size and rate, YouTube: rate; social presets keep 1080x1920 and the sequence rate between 23.976 and 60 fps, else 30).
    public func settings(matching format: SequenceFormat?) -> ExportSettings {
        var s = settings
        guard let f = format, f.isValid else { return s }
        let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
        switch kind {
        case .matchSource, .hevc10, .bestAtSize, .proRes, .proRes422, .proRes4444, .imageSequence:
            s.video.width = f.width & ~1; s.video.height = f.height & ~1
            s.video.frameDuration = f.frameDuration
            s.video.pixelAspect = f.pixelAspect   // stored size plus the file's pixel aspect (pasp); square writes nothing
            if kind == .matchSource || kind == .hevc10 || kind == .bestAtSize {
                // Bits per pixel per frame; HEVC needs about 30 % less than H.264 for the same quality.
                let bpp = kind == .hevc10 ? 0.12 : 0.18
                let bps = Double(s.video.width * s.video.height) * fps * bpp
                let avg = Int(min(max(bps, 6_000_000), 80_000_000))
                // No data rate limit: a 1.5x cap cost hard clips 3-4 VMAF (docs/research/export/F3b-quality-per-bit.md).
                s.video.bitrate = .average(avg)
                s.video.keyframeInterval = max(1, Int(fps.rounded()) * 2)
            }
        case .youtube1080, .youtube1440, .youtube4K, .xPost, .facebook:
            s.video.frameDuration = f.frameDuration
            if fps > 30 {
                let b = s.video.bitrate.averageBitsPerSecond * 3 / 2
                s.video.bitrate = .averageAndMax(average: b, max: b * 3 / 2)
            }
            s.video.keyframeInterval = max(1, Int(fps.rounded()) * 2)
        case .audioM4A, .audioWAV, .audioFLAC, .gif, .imageSequence:
            break
        case .social, .feedPortrait, .feedSquare, .stories:
            // Premiere-style: the sequence rate is kept when a platform accepts it (23.976 to 60 fps); anything else
            // (120 fps, odd rates) stays at the preset's 30 fps.
            if fps >= 23.9, fps <= 60.1 { s.video.frameDuration = f.frameDuration }
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
        case .gif, .imageSequence:
            s.frameOutput = kind == .gif ? .gif : .sequence(.pngAlpha)
            s.video.width = 1080; s.video.height = 1080
            s.video.frameDuration = kind == .gif ? Time(1, 15) : Time(1, 30)
            s.audio.enabled = false
            s.captions = .none
        case .audioM4A, .audioWAV, .audioFLAC:
            s.audioOnly = kind == .audioM4A ? .m4a : kind == .audioFLAC ? .flac : .wav
            s.audio.codec = kind == .audioM4A ? .aac : .pcm
            s.audio.bitrate = 256_000
            s.audio.pcmBitDepth = 24
            s.captions = .none
        case .proRes:
            return .proRes422HQMaster
        case .proRes422, .proRes4444:
            var m = ExportSettings.proRes422HQMaster
            m.video.codec = codec
            return m
        case .hevc10:
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .average(14_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .main10
            s.audio.bitrate = 320_000
        case .bestAtSize:
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .average(20_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000
            s.video.hardwareEncoding = false   // multi-pass runs on the software encoder only (see ExportSettings.usesMultiPass)
            s.video.allowsFrameReordering = false
            s.multiPass = true
        case .matchSource:
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .average(20_000_000)
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
        case .youtube1440:
            // YouTube's recommended SDR upload bitrates: 16 Mbit/s at 24-30 fps (raised 1.5x above 30 fps in settings(matching:)).
            s.video.width = 2560; s.video.height = 1440
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 16_000_000, max: 24_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000
        case .xPost:
            // X accepts H.264 High, AAC, up to 1920x1200 at 60 fps and 25 Mbit/s; limits in `limits`.
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 10_000_000, max: 15_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
        case .facebook:
            // Facebook's recommendation: H.264 progressive, AAC stereo, 30 fps; 1080p at about 8 Mbit/s.
            s.video.width = 1920; s.video.height = 1080
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 8_000_000, max: 12_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
        case .youtube4K:
            s.video.width = 3840; s.video.height = 2160
            s.video.frameDuration = Time(1, 30)
            s.video.bitrate = .averageAndMax(average: 45_000_000, max: 68_000_000)
            s.video.keyframeInterval = 60
            s.video.profile = .high
            s.audio.bitrate = 320_000   // AAC stereo at 48 kHz tops out at 320 kbit/s: more fails with "Cannot Encode Media"
        case .feedPortrait, .feedSquare, .stories:
            s.video.width = 1080
            s.video.height = kind == .feedPortrait ? 1350 : kind == .feedSquare ? 1080 : 1920
            s.video.frameDuration = Time(1, 30)
            let avg = kind == .stories ? 8_000_000 : 10_000_000
            s.video.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2)
            s.video.keyframeInterval = 60
            s.video.profile = .high
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
            case (_, .prores422HQ), (_, .prores422), (_, .prores4444), (_, .prores422LT), (_, .prores422Proxy): avg = 12_000_000
            }
            s.video.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2)
            s.video.keyframeInterval = 60
            s.video.profile = codec == .h264 ? .high : .main
        }
        return s
    }
}

public extension ExportPreset {
    /// Hard limits of the platform this preset targets (nil = none the dialog checks).
    var limits: DeliveryLimits? {
        kind == .xPost ? DeliveryLimits(maxDuration: Time(140, 1), maxFileBytes: 512 * 1_000_000) : nil
    }

    /// Loudness target the Export sheet offers with this preset (normalization itself stays an opt-in per export).
    /// TikTok, Instagram Reels, YouTube and YouTube Shorts play at about -14 LUFS; the ProRes master follows
    /// EBU R128 (-23 LUFS). True-peak ceiling is -1 dBTP everywhere.
    var loudness: LoudnessNormalization {
        switch kind {
        case .proRes, .proRes422, .proRes4444: LoudnessNormalization(targetLUFS: -23, truePeakCeilingDB: -1)
        default: LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)
        }
    }
}

public extension ExportSettings {
    /// Default = TikTok 9:16 H.264.
    static var socialDefault: ExportSettings { ExportPreset.default.settings }
}

/// Upload limits of a platform: the Export sheet blocks a job that would exceed them.
public struct DeliveryLimits: Sendable, Hashable {
    public var maxDuration: Time
    public var maxFileBytes: Int64
    public init(maxDuration: Time, maxFileBytes: Int64) { self.maxDuration = maxDuration; self.maxFileBytes = maxFileBytes }
}
