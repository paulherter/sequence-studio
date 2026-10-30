import SQCore

/// Frames of a range at a frame duration (rounded up: the last, partial frame is still written).
enum ExportFrameCount {
    static func of(range: TimeRange, frameDuration: Time) -> Int {
        let n = Int128(range.duration.value) * Int128(frameDuration.timescale)
        let d = Int128(range.duration.timescale) * Int128(frameDuration.value)
        guard d > 0, n > 0 else { return 0 }
        return Int(n / d + (n % d > 0 ? 1 : 0))
    }
}
