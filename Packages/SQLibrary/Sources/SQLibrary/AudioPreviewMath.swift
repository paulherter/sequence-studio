import SQCore

/// Pure mapping between a 0...1 scrub fraction and rational time.
public enum PreviewTimeMap {
    /// Fraction is quantised to 1/1_000_000 so the result stays rational.
    static let resolution: Int64 = 1_000_000

    public static func time(fraction: Double, duration: Time) -> Time {
        guard fraction.isFinite, duration > .zero else { return .zero }
        let f = min(max(fraction, 0), 1)
        let step = Int64((f * Double(resolution)).rounded())
        let t = Time(duration.value * step, duration.timescale * resolution)
        return min(t, duration)
    }

    public static func fraction(time: Time, duration: Time) -> Double {
        guard duration > .zero else { return 0 }
        if time <= .zero { return 0 }
        if time >= duration { return 1 }
        let num = Double(time.value) * Double(duration.timescale)
        let den = Double(time.timescale) * Double(duration.value)
        return min(max(num / den, 0), 1)
    }
}

/// In/out selection on a library item; the part that gets dragged to the timeline.
public struct PreviewRange: Sendable, Hashable {
    public var duration: Time { didSet { reclamp() } }
    public private(set) var inPoint: Time
    public private(set) var outPoint: Time

    public init(duration: Time) {
        self.duration = max(duration, .zero)
        inPoint = .zero
        outPoint = max(duration, .zero)
    }

    public init(duration: Time, inFraction: Double, outFraction: Double) {
        self.init(duration: duration)
        // Dragging a selection right-to-left gives in > out: order them.
        let a = PreviewTimeMap.time(fraction: inFraction, duration: duration)
        let b = PreviewTimeMap.time(fraction: outFraction, duration: duration)
        setIn(min(a, b))
        setOut(max(a, b))
    }

    public var isWhole: Bool { inPoint == .zero && outPoint == duration }

    /// Range dragged with the item, nil when empty (in == out).
    public var timeRange: TimeRange? {
        outPoint > inPoint ? TimeRange(start: inPoint, end: outPoint) : nil
    }

    public mutating func setIn(_ t: Time) { inPoint = min(max(t, .zero), duration) }
    public mutating func setOut(_ t: Time) { outPoint = max(min(t, duration), inPoint) }
    public mutating func reset() { inPoint = .zero; outPoint = duration }

    public func clamp(_ t: Time) -> Time { min(max(t, inPoint), outPoint) }

    private mutating func reclamp() {
        inPoint = min(max(inPoint, .zero), duration)
        outPoint = max(min(outPoint, duration), inPoint)
    }
}
