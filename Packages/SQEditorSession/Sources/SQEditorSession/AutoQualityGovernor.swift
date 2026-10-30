import Foundation
import SQCore

/// Playback quality "Auto": starts every play run at `base` and steps one quality down (never below 1/4, the decoder
/// floor) each time `dropsPerStep` more frames were dropped. Pure: the host feeds the engine's running drop total.
public struct AutoQualityGovernor: Sendable, Equatable {
    public static let dropsPerStep = 6
    /// The quality a run starts at (the Mac's `MemoryBudget` pick).
    public var base: MonitorQuality
    public private(set) var current: MonitorQuality
    private var runBase = 0
    private var stepped = 0
    private var wasPlaying = false

    private static let ladder: [MonitorQuality] = [.full, .half, .quarter]

    public init(base: MonitorQuality = .full) {
        self.base = base.fixed
        current = base.fixed
    }

    /// Re-bases the ladder (settings or budget changed). Keeps the current step when it is still below the new base.
    public mutating func setBase(_ q: MonitorQuality) {
        base = q.fixed
        current = base.fixed
        stepped = 0
    }

    /// One poll. A new play run resets to `base`; drops while paused count for nothing.
    public mutating func update(dropped: Int, isPlaying: Bool) {
        if dropped < runBase { runBase = dropped }
        if isPlaying && !wasPlaying { runBase = dropped; stepped = 0; current = base }
        wasPlaying = isPlaying
        guard isPlaying else { return }
        let steps = max(0, dropped - runBase) / Self.dropsPerStep
        guard steps > stepped else { return }
        stepped = steps
        let start = Self.ladder.firstIndex(of: base) ?? 0
        current = Self.ladder[min(start + steps, Self.ladder.count - 1)]
    }
}

extension MonitorQuality {
    /// `.auto` as a concrete quality (full); every other case is itself. 
    var fixed: MonitorQuality {
        switch self { case .auto: .full; default: self }
    }
}

/// The monitor's "Media offline" card: which file to name for the picture at `time`.
public enum MediaOfflineCard {
    /// File name of the topmost visible video clip under `time` whose media is offline, or the topmost offline one when
    /// several lie under it. `offlineName` returns the file name for an offline media id and nil for online media.
    public static func fileName(in timeline: Timeline, at time: Time, offlineName: (UUID) -> String?) -> String? {
        for track in timeline.tracks.reversed() where track.kind == .video && track.isVisible {
            guard let clip = track.clips.first(where: { $0.timeline.contains(time) }) else { continue }
            if let name = offlineName(clip.media) { return name }
        }
        return nil
    }
}
