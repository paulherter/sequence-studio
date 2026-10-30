import Foundation

/// Where a sequence is meant to be published. Drives the export preset and the loudness target.
public enum DeliveryPlatform: String, Sendable, Hashable, Codable, CaseIterable {
    case tiktok, reels, shorts
    /// 4:5 and 1:1 social feed posts: they share the vertical loudness group.
    case socialFeed
    case youtube

    /// Zone table: the platform UI zone of this delivery platform (nil = none: feed posts, YouTube). Data lives in `SafeZone.zone(for:)`.
    public var safeZonePlatform: CutCheckPlatform? {
        switch self {
        case .tiktok: .tiktok
        case .reels: .reels
        case .shorts: .shorts
        case .socialFeed, .youtube: nil
        }
    }
    public var safeZone: SafeZone? { safeZonePlatform.map(SafeZone.zone(for:)) }

    public var loudnessGroup: LoudnessGroup {
        switch self {
        case .tiktok, .reels, .shorts, .socialFeed: .vertical
        case .youtube: .horizontal
        }
    }
}

/// The two loudness groups (the maintainer, docs/ROADMAP.md "Decisions by the maintainer" 4): vertical (TikTok = Reels = Shorts) and horizontal (YouTube).
///
/// Values, researched 2026-10-01. None of the platforms publishes a binding delivery spec; the numbers are what the
/// platforms normalize playback to, as measured and reported by third parties:
/// - Vertical: -14 LUFS integrated, -1 dBTP true peak (TikTok normalizes to about -14 LUFS:
///   https://www.criticallisteninglab.com/en/learn/loudness/social-media ; one target that holds on TikTok, Reels and Shorts:
///   https://mrvocal.com/posts/loudness-for-shorts ; https://trackgleam.com/learn/master-for-tiktok-reels-shorts).
///   Instagram's own behavior is undocumented, some sources advise -16 LUFS as a conservative figure; we keep -14
///   because every platform here only turns louder material down.
/// - Horizontal (YouTube): -14 LUFS integrated, -1 dBTP (YouTube lowers louder material to about -14 LUFS and does not raise
///   quieter material: https://www.criticallisteninglab.com/en/learn/loudness/youtube ;
///   https://audio.rswaver.com/blog/youtube-loudness-standards). The -23 LUFS of EBU R128 is broadcast, not web delivery.
/// The -1 dBTP ceiling is the common true-peak headroom for lossy (AAC/Opus) re-encoding on these platforms.
public enum LoudnessGroup: String, Sendable, Hashable, Codable {
    case vertical, horizontal

    public var targetLUFS: Double {
        switch self { case .vertical, .horizontal: AudioTag.dialogue.targetLUFS }
    }
    public var truePeakDB: Double {
        switch self { case .vertical: -1; case .horizontal: -1 }
    }
}

/// A sequence's delivery target: platform plus audio loudness (LUFS) and true-peak ceiling (dBTP).
/// Optional on `Timeline`; absent in older files (no project version bump).
public struct DeliveryTarget: Sendable, Hashable, Codable {
    public var platform: DeliveryPlatform
    public var targetLUFS: Double
    public var truePeakDB: Double

    public init(platform: DeliveryPlatform) {
        self.platform = platform
        targetLUFS = platform.loudnessGroup.targetLUFS
        truePeakDB = platform.loudnessGroup.truePeakDB
    }

    public init(platform: DeliveryPlatform, targetLUFS: Double, truePeakDB: Double) {
        self.platform = platform; self.targetLUFS = targetLUFS; self.truePeakDB = truePeakDB
    }

    private enum CodingKeys: String, CodingKey { case platform, targetLUFS, truePeakDB }

    /// Tolerant: missing loudness values default from the platform's group.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let p = try c.decode(DeliveryPlatform.self, forKey: .platform)
        platform = p
        targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS) ?? p.loudnessGroup.targetLUFS
        truePeakDB = try c.decodeIfPresent(Double.self, forKey: .truePeakDB) ?? p.loudnessGroup.truePeakDB
    }
}

extension Project {
    /// Sets (or clears) a sequence's delivery target.
    public mutating func setDeliveryTarget(_ target: DeliveryTarget?, of id: Timeline.ID) throws {
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        timelines[i].deliveryTarget = target
    }
}
