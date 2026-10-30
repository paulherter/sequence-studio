import Foundation

/// Loudness readout shown next to the Voice Chain: how far the selected dialogue clips are from the Dialogue target
/// (-14 LUFS, `AudioTag.dialogue.targetLUFS`). Pure value; the measurement itself is `EditorSession.measureLoudness`.
public struct VoiceChainReadout: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case quiet, onTarget, loud }

    /// Within this many LU of the target counts as on target.
    public static let toleranceLU = 1.0

    /// Loudness of the clips mixed by energy (an estimate of what playing them together measures).
    public let lufs: Double
    public let targetLUFS: Double

    /// nil when no clip has a measurable loudness (all silent, unmeasured, or empty).
    public init?(measuredLUFS: [Double?], targetLUFS: Double = AudioTag.dialogue.targetLUFS) {
        let v = measuredLUFS.compactMap { $0 }.filter { $0.isFinite && $0 > AudioGain.silentLUFS }
        guard !v.isEmpty else { return nil }
        let energy = v.reduce(0) { $0 + pow(10, $1 / 10) } / Double(v.count)
        lufs = 10 * log10(energy)
        self.targetLUFS = targetLUFS
    }

    /// Measured minus target (negative = quieter than the target).
    public var deltaLU: Double { lufs - targetLUFS }

    public var status: Status {
        abs(deltaLU) <= Self.toleranceLU ? .onTarget : (deltaLU < 0 ? .quiet : .loud)
    }

    public var lufsText: String { String(format: "%.1f", lufs) }
    public var deltaText: String { String(format: "%+.1f", deltaLU) }
}
