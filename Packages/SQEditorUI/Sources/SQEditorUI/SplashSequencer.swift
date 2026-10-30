import Foundation

/// Time model of the splash (DECISIONS 2026-10-14): the travel is purely time-based, one smootherstep over `minDisplay`
/// (2.2 s), independent of real startup progress. Real startup only decides when "Ready" may begin: at the end of the
/// travel and once the app asked to finish (until then Pip rests at the end). Then Ready with the joy jump for 0.65 s
/// and a 0.2 s fade. Pure: `advance(to:)` takes the seconds since the splash appeared, no clock, no UI.
public struct SplashSequencer: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case loading, ready, fading, done }
    public static let minDisplay: TimeInterval = 2.2
    public static let readyHold: TimeInterval = 0.65
    public static let fade: TimeInterval = 0.2

    public private(set) var progress: Double = 0
    public private(set) var phase: Phase = .loading
    public private(set) var alpha: Double = 1
    /// Seconds into `.ready` (0 before it).
    public private(set) var readyElapsed: TimeInterval = 0
    private var finishRequested = false
    private var lastTime: TimeInterval = 0
    private var readyAt: TimeInterval = 0

    public init() {}

    /// Travel progress at `time`: smootherstep (ease in and out) from 0 to 1 over `minDisplay`.
    public static func pace(_ time: TimeInterval) -> Double {
        let u = min(1, max(0, time / minDisplay))
        return u * u * u * (u * (u * 6 - 15) + 10)
    }

    /// Startup finished: the clips grow to 100 %, then Ready, then the fade.
    public mutating func requestFinish() { finishRequested = true }

    public var isFinishRequested: Bool { finishRequested }

    public mutating func advance(to time: TimeInterval) {
        let dt = max(0, time - lastTime)
        lastTime = max(lastTime, time)
        if phase == .done { return }
        _ = dt
        progress = max(progress, Self.pace(time))
        switch phase {
        case .loading:
            if finishRequested, progress >= 1, time >= Self.minDisplay { phase = .ready; readyAt = time }
        case .ready:
            readyElapsed = time - readyAt
            if readyElapsed >= Self.readyHold { phase = .fading }
        case .fading:
            let f = (time - readyAt - Self.readyHold) / Self.fade
            alpha = max(0, 1 - f)
            if f >= 1 { phase = .done; alpha = 0 }
        case .done: break
        }
    }
}
