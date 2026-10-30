import Foundation

/// EBU Tech 3342 loudness range from a stream of short-term readings: samples at most every 0.1 s of measured time,
/// absolute gate -70 LUFS, relative gate 20 LU below the power mean, LRA = P95 - P10 of what passes.
/// Values under `minimumSeconds` of measured signal are not trustworthy: `value` is nil and the meter greys the number.
public struct LoudnessRangeTracker: Sendable, Equatable {
    public static let minimumSeconds: Double = 60
    public static let sampleInterval: Double = 0.1
    private static let maxSamples = 36_000 // one hour

    public private(set) var measuredSeconds: Double = 0
    private var samples: [Double] = []
    private var pending: Double = 0

    public init() {}

    /// Feed one poll: `shortTermLUFS` (nil = no signal yet) and `dt`, the measured time since the previous poll.
    public mutating func add(shortTermLUFS: Double?, dt: Double) {
        guard let v = shortTermLUFS, v.isFinite, dt > 0 else { return }
        pending += dt
        guard pending >= Self.sampleInterval else { return }
        let n = Int(pending / Self.sampleInterval)
        pending -= Double(n) * Self.sampleInterval
        measuredSeconds += Double(n) * Self.sampleInterval
        if samples.count < Self.maxSamples { samples.append(v) }
    }

    public mutating func reset() { self = LoudnessRangeTracker() }

    /// Enough signal for a meaningful number (otherwise the UI greys the value out).
    public var isReliable: Bool { measuredSeconds >= Self.minimumSeconds - 0.001 }

    /// The loudness range in LU, nil until `isReliable` and something passes the gates.
    public var value: Double? { isReliable ? range : nil }

    /// The range regardless of the 60 s rule (nil when nothing passes the gates).
    public var range: Double? {
        let gated = samples.filter { $0 > -70 }
        guard !gated.isEmpty else { return nil }
        let power = gated.map { pow(10, $0 / 10) }.reduce(0, +) / Double(gated.count)
        let relative = 10 * log10(power) - 20
        let kept = gated.filter { $0 > relative }.sorted()
        guard kept.count >= 2 else { return kept.isEmpty ? nil : 0 }
        func percentile(_ p: Double) -> Double {
            let pos = p * Double(kept.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(lo + 1, kept.count - 1)
            return kept[lo] + (kept[hi] - kept[lo]) * (pos - Double(lo))
        }
        return percentile(0.95) - percentile(0.10)
    }

    /// "LRA 7.2 LU", or "LRA --" while under a minute of signal.
    public var text: String {
        guard let v = value else { return "LRA --" }
        return String(format: "LRA %.1f LU", v)
    }
}
