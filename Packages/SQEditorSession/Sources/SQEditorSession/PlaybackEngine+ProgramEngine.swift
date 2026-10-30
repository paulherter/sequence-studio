import Foundation
import SQCore
import SQPlayback

/// The real Program engine (Mac: Metal render loop, CoreAudio output).
extension PlaybackEngine: ProgramEngine {
    public var cachedSpans: [TimeRange] { cachedRanges() }
    public var droppedFrames: Int { stats.droppedFrames }
    public var scrubLatencyText: String? {
        let parts = [stats.scrubLatencySummary()?.text, stats.latencySummary()?.text].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    public var meterReading: (sequence: Int, peaks: [Float])? {
        guard let s = audio?.meterSnapshot() else { return nil }
        return (s.sequence, [s.left.peak, s.right.peak])
    }
    public var loudnessLevels: LoudnessLevels? { audio?.meterSnapshot().loudness }
    public func resetLoudnessMeter() { audio?.resetLoudnessMeter() }
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) { audio?.setProjectLiveDucking(setting) }
    public func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) { audio?.setDialogueSilences(provider) }
}
