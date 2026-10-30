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
    /// Scrub-gesture move (`scrub(to:)`) -> first composite where every layer shows its keyframe or exact frame (W6.6).
    public var scrubLatencies: [Duration] = []
    /// |presented video time - audio clock| over the run (read right after each composite while playing on the audio
    /// clock). Stays 0 while the engine runs on the host clock.
    public var maxAVDrift: Time = .zero
    /// Render-loop iterations (display-link ticks, or `tick()` calls when headless). Presents per tick well below
    /// the display rate with no drops means the driver is ticking slowly (e.g. the window is hidden or occluded).
    public var renderTicks = 0
    /// Bytes held by the frame cache.
    public var cacheBytes = 0
    /// Presented composites with a picture layer drawn as the gray "loading" placeholder (no frame of it at all).
    public var placeholderComposites = 0
    /// Source pts of the frame the bottom picture layer showed in the last composite (nil: none, e.g. a placeholder).
    public var lastShownPTS: Time?
    /// Q-PERF2 rec 1: max - min interval (ms) between frames presented while playing, over the last 120 since the last
    /// `play()` (display-link driven only; nil before two). 0 = one constant cadence; ~16.7 on a 60 Hz panel = 2:3 judder.
    public var presentIntervalSpread: Double?
    /// Caption rasters that were not ready when their frame was drawn and were rendered on the render thread instead of
    /// leaving the caption out of that frame, and the slowest of those renders.
    public var captionSyncRenders = 0
    public var maxCaptionSyncRender: Duration = .zero

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
    /// "step" (exact-frame steps) or "scrub" (drag/keyframe-snap scrubbing).
    public var label: String = "step"

    /// One line for the HUD, e.g. `scrub 18 ms (median 21, p95 40, n 57)`.
    public var text: String {
        "\(label) \(Int(last.rounded())) ms (median \(Int(median.rounded())), p95 \(Int(p95.rounded())), n \(count))"
    }
}

extension PlaybackStats {
    /// Millisecond summary of the newest `window` step latencies (default 100); nil without any measurement.
    public func latencySummary(window: Int = 100) -> LatencySummary? {
        Self.summary(stepLatencies, window: window, label: "step")
    }

    /// Same for the scrub latencies (drag scrubbing), recorded apart from the steps.
    public func scrubLatencySummary(window: Int = 100) -> LatencySummary? {
        Self.summary(scrubLatencies, window: window, label: "scrub")
    }

    static func summary(_ all: [Duration], window: Int, label: String) -> LatencySummary? {
        let recent = all.suffix(max(window, 1))
        guard !recent.isEmpty else { return nil }
        func ms(_ d: Duration) -> Double {
            let c = d.components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        let values = recent.map(ms)
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)] }
        return LatencySummary(count: values.count, last: values[values.count - 1], median: percentile(0.5), p95: percentile(0.95),
                              max: sorted[sorted.count - 1], label: label)
    }
}

/// Cost of one render-loop iteration (playback profiling, `PlaybackEngine.lastTickProfile`; docs/PLAYBACK-PERF.md).
/// `build`: layer requests, layers and caption rasters on the CPU; `encode`: compositor + present encoding; `gpuWait`: headless
/// wait for the GPU (zero with a presenter); `gpu`: GPU execution of the composite's command buffer (nil until it completed).
public struct TickProfile: Sendable, Equatable {
    public var time: Time = .zero
    public var presented = false
    public var build: Duration = .zero
    public var encode: Duration = .zero
    public var gpuWait: Duration = .zero
    /// Decode planning after the composite (planner + scheduler submit).
    public var prefetch: Duration = .zero
    public var gpu: Duration?
    /// Picture layers in the composite, those not at their exact frame, those without any picture.
    public var layers = 0
    public var missing = 0
    public var noFrame = 0
    /// Media layers left out because an opaque picture covers them (`LayerOcclusion`); not in `layers`.
    public var hidden = 0
    /// Held the last picture instead of compositing (decode outstanding).
    public var held = false
    public init() {}
}
