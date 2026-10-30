import Foundation

/// Premiere-style presets for the Sequence Settings and New Sequence sheets.
public enum SequenceFormatPresets {
    public struct Size: Sendable, Hashable {
        public let name: String
        public let width: Int
        public let height: Int
    }
    public struct FrameRate: Sendable, Hashable {
        public let label: String
        public let frameDuration: Time
    }

    public static let sizes: [Size] = [
        Size(name: "1080 × 1920 (9:16)", width: 1080, height: 1920),
        Size(name: "1920 × 1080 (16:9)", width: 1920, height: 1080),
        Size(name: "3840 × 2160 (UHD 16:9)", width: 3840, height: 2160),
        Size(name: "2160 × 3840 (UHD 9:16)", width: 2160, height: 3840),
        Size(name: "1080 × 1350 (4:5)", width: 1080, height: 1350),
        Size(name: "1080 × 1080 (1:1)", width: 1080, height: 1080),
        Size(name: "1440 × 1080 (4:3)", width: 1440, height: 1080),
    ]

    public static let frameRates: [FrameRate] = [
        FrameRate(label: "23.976", frameDuration: Time(1001, 24000)),
        FrameRate(label: "24", frameDuration: Time(1, 24)),
        FrameRate(label: "25", frameDuration: Time(1, 25)),
        FrameRate(label: "29.97", frameDuration: Time(1001, 30000)),
        FrameRate(label: "30", frameDuration: Time(1, 30)),
        FrameRate(label: "50", frameDuration: Time(1, 50)),
        FrameRate(label: "59.94", frameDuration: Time(1001, 60000)),
        FrameRate(label: "60", frameDuration: Time(1, 60)),
    ]

    public static let sampleRates = [44_100, 48_000, 96_000]

    public static func size(width: Int, height: Int) -> Size? { sizes.first { $0.width == width && $0.height == height } }
    public static func frameRate(_ d: Time) -> FrameRate? { frameRates.first { $0.frameDuration == d } }

    public static let maxDimension = 16_384

    public struct Named: Sendable, Hashable {
        public let name: String
        public let format: SequenceFormat
        /// Platform and loudness the preset is made for; nil = none.
        public let deliveryTarget: DeliveryTarget?
        public init(name: String, format: SequenceFormat, deliveryTarget: DeliveryTarget? = nil) {
            self.name = name; self.format = format; self.deliveryTarget = deliveryTarget
        }
    }

    /// New Sequence presets, social first: TikTok, Instagram Reels and YouTube Shorts (1080x1920), 4:5, 1:1, then
    /// YouTube 1080p / 4K at 24, 25, 30, 50, 60 fps and 4:3 (1440x1080). Each carries its delivery target.
    public static let named: [Named] = {
        var out: [Named] = []
        func add(_ name: String, _ w: Int, _ h: Int, _ fps: Int, _ p: DeliveryPlatform) {
            out.append(Named(name: name, format: SequenceFormat(width: w, height: h, frameDuration: Time(1, Int64(fps))),
                             deliveryTarget: DeliveryTarget(platform: p)))
        }
        for fps in [30, 60] {
            add("TikTok 1080×1920 \(fps)", 1080, 1920, fps, .tiktok)
            add("Instagram Reels 1080×1920 \(fps)", 1080, 1920, fps, .reels)
            add("YouTube Shorts 1080×1920 \(fps)", 1080, 1920, fps, .shorts)
        }
        add("Instagram 4:5 1080×1350 30", 1080, 1350, 30, .socialFeed)
        add("Square 1:1 1080×1080 30", 1080, 1080, 30, .socialFeed)
        for (label, w, h) in [("YouTube 1080p", 1920, 1080), ("YouTube 4K", 3840, 2160)] {
            for fps in [24, 25, 30, 50, 60] { add("\(label) \(fps)", w, h, fps, .youtube) }
        }
        add("Classic 4:3 1440×1080 30", 1440, 1080, 30, .youtube)
        return out
    }()

    public static func preset(matching f: SequenceFormat) -> Named? {
        named.first { $0.format.width == f.width && $0.format.height == f.height && $0.format.pixelAspect == f.pixelAspect && $0.format.frameDuration == f.frameDuration }
    }
}

extension SequenceFormat {
    /// Format for new sequences when nothing usable is known (and the stand-in for a probe that read 0).
    public static let probeFallback = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30), audioSampleRate: 48_000)

    /// This format with every field a probe could have read as 0 or garbage (size, frame duration, sample rate) taken from
    /// `fallback`, so a value copied from media info can never make a project the decoder refuses to open.
    public func sanitized(fallback: SequenceFormat = .probeFallback) -> SequenceFormat {
        var f = self
        if !(1...SequenceFormatPresets.maxDimension).contains(f.width) { f.width = fallback.width }
        if !(1...SequenceFormatPresets.maxDimension).contains(f.height) { f.height = fallback.height }
        if !(f.frameDuration > .zero) { f.frameDuration = fallback.frameDuration }
        if f.audioSampleRate <= 0 { f.audioSampleRate = fallback.audioSampleRate }
        return f
    }

    public var isValid: Bool {
        (1...SequenceFormatPresets.maxDimension).contains(width) && (1...SequenceFormatPresets.maxDimension).contains(height)
            && frameDuration > .zero && audioSampleRate > 0
    }
}

extension Project {
    /// Sets a sequence's frame size, frame rate and sample rate. Clips are untouched (Premiere: clip scale stays, the canvas changes).
    public mutating func setFormat(_ format: SequenceFormat, of id: Timeline.ID) throws {
        guard format.isValid else { throw EditError.invalidFormat }
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        timelines[i].format = format
        timelines[i].formatLocked = true
    }
}

extension Timeline {
    /// The clip Effect Controls shows for a selection: the single selected clip, or for a linked A/V pair its video clip.
    /// Any other multi-selection has none.
    public func primaryClip(of ids: Set<Clip.ID>) -> Clip? {
        let picked = tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        guard picked.count == ids.count, let first = picked.first else { return nil }
        if picked.count == 1 { return first }
        guard let link = first.link, picked.allSatisfy({ $0.link == link }) else { return nil }
        return picked.first { $0.kind != .audio } ?? first
    }
}
