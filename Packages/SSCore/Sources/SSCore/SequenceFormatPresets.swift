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

    /// Ready-made targets for the New Sequence sheet: size and frame rate in one choice.
    public struct Preset: Sendable, Hashable {
        public let group: String
        public let name: String
        public let width: Int
        public let height: Int
        public let frameDuration: Time
    }

    public static let presets: [Preset] = {
        func rate(_ n: Int64) -> Time { Time(1, n) }
        var out: [Preset] = []
        for fps in [24, 25, 30, 50, 60] as [Int64] {
            out.append(Preset(group: "YouTube", name: "YouTube 1080p \(fps)", width: 1920, height: 1080, frameDuration: rate(fps)))
        }
        for fps in [24, 25, 30, 50, 60] as [Int64] {
            out.append(Preset(group: "YouTube", name: "YouTube 4K \(fps)", width: 3840, height: 2160, frameDuration: rate(fps)))
        }
        for fps in [24, 25, 30, 60] as [Int64] {
            out.append(Preset(group: "TikTok, Shorts, Reels", name: "TikTok / Shorts / Reels 1080 × 1920 \(fps)",
                              width: 1080, height: 1920, frameDuration: rate(fps)))
        }
        return out
    }()

    public static let sampleRates = [44_100, 48_000, 96_000]

    public static func size(width: Int, height: Int) -> Size? { sizes.first { $0.width == width && $0.height == height } }
    public static func frameRate(_ d: Time) -> FrameRate? { frameRates.first { $0.frameDuration == d } }

    public static let maxDimension = 16_384
}

extension SequenceFormat {
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
