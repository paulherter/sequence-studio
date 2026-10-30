import SQCore
import SQMedia

/// An FFmpeg stream time base (seconds per tick = num / den) and exact conversions to rational `Time`.
public struct FFmpegTimeBase: Sendable, Hashable {
    public var num: Int64, den: Int64
    public init(num: Int64, den: Int64) {
        precondition(num > 0 && den > 0, "time base must be positive")
        self.num = num; self.den = den
    }

    public func time(ticks: Int64) -> Time { Time(reducing: Int128(ticks) * Int128(num), Int128(den)) }

    /// Ticks nearest to `t` (half away from zero); exact when `t` lies on the tick grid.
    public func ticks(_ t: Time) -> Int64 {
        let n = Int128(t.value) * Int128(den), d = Int128(t.timescale) * Int128(num)
        let q = n / d, r = n % d
        if 2 * r.magnitude >= d.magnitude { return Int64(n < 0 ? q - 1 : q + 1) }
        return Int64(q)
    }
}

/// One demuxed packet as the FFmpeg index pass reports it (stream ticks, decode order).
public struct FFmpegPacketTiming: Sendable, Hashable {
    public var pts: Int64, dts: Int64, duration: Int64
    public var isKey: Bool
    public init(pts: Int64, dts: Int64, duration: Int64, isKey: Bool) {
        self.pts = pts; self.dts = dts; self.duration = duration; self.isKey = isKey
    }
}

/// The `SampleIndex` of an FFmpeg-demuxed video stream, and the way back from a decoded picture's pts to its frame.
public struct FFmpegFrameTable: Sendable {
    public let index: SampleIndex
    public let timeBase: FFmpegTimeBase
    /// Smallest pts: the index starts at 0 there.
    public let originTicks: Int64
    private let presentationOfTicks: [Int64: Int]

    public init(packets: [FFmpegPacketTiming], timeBase: FFmpegTimeBase) {
        self.timeBase = timeBase
        let origin = packets.map(\.pts).min() ?? 0
        originTicks = origin
        let entries = packets.enumerated().map { ordinal, p in
            SampleIndex.Entry(pts: timeBase.time(ticks: p.pts - origin), dts: timeBase.time(ticks: p.dts - origin),
                              duration: timeBase.time(ticks: max(0, p.duration)), isSync: p.isKey, decodeOrdinal: ordinal)
        }
        index = SampleIndex(entries: entries)
        var map: [Int64: Int] = [:]
        for (i, e) in index.entries.enumerated() where e.duration > .zero || map[timeBase.ticks(e.pts) + origin] == nil {
            map[timeBase.ticks(e.pts) + origin] = i
        }
        presentationOfTicks = map
    }

    /// Presentation index of a decoded picture's pts (stream ticks); nil when no packet had that pts.
    public func presentationIndex(ofTicks ticks: Int64) -> Int? { presentationOfTicks[ticks] }

    /// Stream ticks of a sample's pts / dts (the inverse of the origin shift).
    public func ticks(_ t: Time) -> Int64 { timeBase.ticks(t) + originTicks }
}

/// Where the decoder continues after the previous call.
public struct FFmpegDecodeCursor: Sendable, Hashable {
    /// Next decode ordinal to send.
    public var nextOrdinal: Int
    /// Last presentation index the previous call returned.
    public var lastPresented: Int
    public init(nextOrdinal: Int, lastPresented: Int) { self.nextOrdinal = nextOrdinal; self.lastPresented = lastPresented }
}

/// Decode-order planning for `VideoDecoding.decode(_:)` over a `SampleIndex` (pure, shared by every FFmpeg decoder).
public enum FFmpegDecodePlan {
    /// First ordinal to send for `range`, and whether the decoder must drop its state first (a seek). Forward playback
    /// (`range` starts right after the previous call's last frame) continues without flushing, and so does a short jump
    /// ahead whose frames are all still to be sent (or `carried`) when a seek would not start later (the Mac
    /// `VideoDecoder.plan`). A seek to a leading picture of an open GOP starts one GOP earlier
    /// (`SampleIndex.freshDecodeStart`): FFmpeg drops the RASL pictures of a CRA it starts at.
    public static func start(for range: ClosedRange<Int>, in index: SampleIndex, cursor: FFmpegDecodeCursor?,
                             carried: Set<Int> = []) -> (ordinal: Int, flush: Bool) {
        let fresh = index.syncDecodeOrdinal(for: index.freshDecodeStart(for: range.lowerBound))
        if let c = cursor {
            if range.lowerBound == c.lastPresented + 1 { return (c.nextOrdinal, false) }
            if fresh <= c.nextOrdinal,
               range.allSatisfy({ index.entries[$0].decodeOrdinal >= c.nextOrdinal || carried.contains($0) }) {
                return (c.nextOrdinal, false)
            }
        }
        return (fresh, true)
    }

    /// The frames of `range` the caller expects back (zero-duration entries the edit list hides are left out).
    public static func wanted(_ range: ClosedRange<Int>, in index: SampleIndex) -> Set<Int> {
        Set(range.filter { index.entries[$0].duration > .zero })
    }
}
