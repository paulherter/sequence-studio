import Foundation

/// Pure progress / ETA math for the export progress window. Time is passed in (seconds, any monotonic origin) so it is
/// testable. The rate is an exponential moving average of progress-per-second, so one slow frame does not make the
/// estimate jump.
public struct ExportProgressTracker: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preparing, rendering, finishing
        public var title: String {
            switch self { case .preparing: "Preparing"; case .rendering: "Rendering and encoding"; case .finishing: "Finishing" }
        }
    }

    /// The estimate needs this much progress and time first; before that the rate is too noisy.
    static let minProgress = 0.01
    static let minElapsed = 2.0
    /// Weight of the newest sample per second of elapsed time (capped at 1).
    static let smoothing = 0.15

    public private(set) var progress: Double = 0
    public private(set) var rate: Double?        // progress per second, smoothed
    private var start: Double?
    private var lastTime: Double?
    private var lastProgress: Double = 0

    public init() {}

    public mutating func record(progress p: Double, at time: Double) {
        let p = min(max(p, 0), 1)
        guard let s = start else { start = time; lastTime = time; lastProgress = p; progress = p; return }
        guard p > progress else { return }
        progress = p
        guard let lt = lastTime, time > lt else { return }
        let dt = time - lt
        if let r = rate {
            let inst = (p - lastProgress) / dt
            rate = r + min(Self.smoothing * dt, 1) * (inst - r)
        } else if time - s >= Self.minElapsed, p >= Self.minProgress {
            rate = p / (time - s)      // seed with the average since the start
        }
        lastTime = time; lastProgress = p
    }

    /// Seconds left, nil until there is enough data.
    public var remaining: Double? {
        if progress >= 1 { return 0 }
        guard let r = rate, r > 0 else { return nil }
        return (1 - progress) / r
    }

    public static func phase(progress: Double, running: Bool) -> Phase {
        guard running else { return .preparing }
        return progress >= 0.99 ? .finishing : .rendering
    }

    public static func format(seconds: Double) -> String {
        let s = Int(max(seconds, 0).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func remainingText(_ seconds: Double?) -> String {
        guard let s = seconds else { return "Calculating…" }
        return s < 1 ? "Almost done" : "\(format(seconds: s)) left"
    }
}

/// Lets at most one progress update per `minInterval` through (the UI needs <= 10 Hz); the final value always passes.
public struct ProgressThrottle: Sendable {
    public let minInterval: Double
    private var last: Double?
    public init(minInterval: Double = 0.1) { self.minInterval = minInterval }
    public mutating func accept(progress: Double, at time: Double) -> Bool {
        if progress >= 1 || last == nil || time - (last ?? 0) >= minInterval { last = time; return true }
        return false
    }
}
