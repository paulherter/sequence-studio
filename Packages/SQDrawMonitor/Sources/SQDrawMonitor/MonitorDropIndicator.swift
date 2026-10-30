import Foundation

/// State of the quiet dot in the Program monitor chrome: amber for `holdSeconds` after the engine dropped a frame while
/// playing, plus the number of drops of the last play run for the tooltip. Pure: the host feeds the engine's cumulative
/// `droppedFrames` and the clock.
public struct DropIndicator: Sendable, Equatable {
    public static let holdSeconds: Double = 2
    /// Drops within one play run from which the run counts as "realtime not achieved" (persists until the next run).
    public static let realtimeThreshold = 5

    private var lastCount = 0
    private var runBase = 0
    private var wasPlaying = false
    private var amberUntil: Double?
    /// Drops since the current (or most recent) play run started.
    public private(set) var lastRunDrops = 0
    /// True once any play run was seen.
    public private(set) var hasRun = false

    public init() {}

    /// One poll. `dropped` is the engine's running total (a smaller value means a new engine: rebase).
    public mutating func update(dropped: Int, isPlaying: Bool, now: Double) {
        if dropped < lastCount { runBase = dropped; lastCount = dropped; lastRunDrops = 0 }
        if isPlaying && !wasPlaying { runBase = dropped; lastRunDrops = 0; amberUntil = nil; hasRun = true }
        if isPlaying {
            if dropped > lastCount { amberUntil = now + Self.holdSeconds }
            lastRunDrops = max(0, dropped - runBase)
        }
        lastCount = dropped
        wasPlaying = isPlaying
    }

    /// The last (or current) play run dropped at least `realtimeThreshold` frames.
    public var realtimeNotAchieved: Bool { hasRun && lastRunDrops >= Self.realtimeThreshold }

    /// Text of the indicator pill: nil while nothing was dropped in the last run.
    public var badgeText: String? {
        guard hasRun, lastRunDrops > 0 else { return nil }
        return realtimeNotAchieved ? "Realtime not achieved · \(lastRunDrops) dropped" : "\(lastRunDrops) dropped"
    }

    public func isAmber(now: Double) -> Bool { amberUntil.map { now < $0 } ?? false }

    /// Hover text with the count of the last play run.
    public var tooltip: String {
        guard hasRun else { return "Dropped frames: none yet" }
        return lastRunDrops == 0 ? "Last play: no dropped frames"
            : "Last play: \(lastRunDrops) dropped frame\(lastRunDrops == 1 ? "" : "s")"
    }
}

/// What the Source viewer shows: nothing, the picture, or the waveform of audio-only media (MON-36).
public enum SourceViewerMode: Sendable, Equatable {
    case empty, picture, waveform

    /// Media with sound but no picture shows its waveform; unknown streams (not probed yet) count as picture.
    public static func resolve(isOpen: Bool, hasVideo: Bool, hasAudio: Bool) -> SourceViewerMode {
        guard isOpen else { return .empty }
        return !hasVideo && hasAudio ? .waveform : .picture
    }
}
