import SQCore
import SQMedia

/// Engine counters, snapshot per read (ARCHITECTURE §6).
public struct PlaybackStats: Sendable, Equatable {
    /// Composites handed to the presenter (a new frame position, or a re-render after an edit / arriving frame).
    public var presentedFrames = 0
    /// Frame positions shown with at least one layer not at its exact frame (nearest earlier frame or loading).
    public var droppedFrames = 0
    /// seek/step call -> first complete composite of the target frame.
    public var stepLatencies: [Duration] = []
    /// |presented video time - audio clock| over the run (read right after each composite while playing on the audio
    /// clock). Stays 0 while the engine runs on the host clock.
    public var maxAVDrift: Time = .zero
    /// Render-loop iterations (display-link ticks, or `tick()` calls when headless). Presents per tick well below
    /// the display rate with no drops means the driver is ticking slowly (e.g. the window is hidden or occluded).
    public var renderTicks = 0
    /// Bytes held by the frame cache.
    public var cacheBytes = 0

    public init() {}
}

extension DecodedFrame: CacheCost {}

/// Scrub latency in milliseconds (seek/step call to the first complete composite of the target frame), for the debug HUD.
public struct LatencySummary: Sendable, Equatable {
    public var count: Int
    public var last: Double
    public var median: Double
    public var p95: Double
    public var max: Double

    /// One line for the HUD, e.g. `scrub 18 ms (median 21, p95 40, n 57)`.
    public var text: String {
        "scrub \(Int(last.rounded())) ms (median \(Int(median.rounded())), p95 \(Int(p95.rounded())), n \(count))"
    }
}

extension PlaybackStats {
    /// Millisecond summary of the newest `window` step latencies (default 100); nil without any measurement.
    public func latencySummary(window: Int = 100) -> LatencySummary? {
        let recent = stepLatencies.suffix(max(window, 1))
        guard !recent.isEmpty else { return nil }
        func ms(_ d: Duration) -> Double {
            let c = d.components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        let values = recent.map(ms)
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)] }
        return LatencySummary(count: values.count, last: values[values.count - 1], median: percentile(0.5), p95: percentile(0.95),
                              max: sorted[sorted.count - 1])
    }
}
