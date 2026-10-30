import Synchronization
import SQAudioFX

/// Peak/RMS of the last metered buffer, written by the tap thread, read by the UI.
public final class AudioMeterStore: Sendable {
    public init() {}
    private struct State { var snapshot = AudioMeterSnapshot(); var loudness = LoudnessMeter(sampleRate: 48_000, channelCount: 2) }
    private let value = Mutex(State())
    public var snapshot: AudioMeterSnapshot { value.withLock { $0.snapshot } }

    func measure(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, count: Int) {
        func level(_ p: UnsafePointer<Float>) -> AudioMeterLevel {
            var peak: Float = 0, sum: Float = 0
            for i in 0..<count { let v = p[i]; peak = max(peak, abs(v)); sum += v * v }
            return AudioMeterLevel(peak: peak, rms: count > 0 ? (sum / Float(count)).squareRoot() : 0)
        }
        let a = level(l), b = level(r)
        let left = Array(UnsafeBufferPointer(start: l, count: count)), right = Array(UnsafeBufferPointer(start: r, count: count))
        value.withLock { s in
            s.snapshot.left = a; s.snapshot.right = b; s.snapshot.sequence += 1
            s.loudness.process([left, right])            // same BS.1770 meter the export normalizer uses
            s.snapshot.loudness = Self.levels(s.loudness)
        }
    }

    /// Restarts the integrated value and the true-peak hold (the loudness meter's reset).
    public func resetLoudness() {
        value.withLock { s in s.loudness.reset(); s.snapshot.loudness = Self.levels(s.loudness) }
    }

    private static func levels(_ m: LoudnessMeter) -> LoudnessLevels {
        var out = LoudnessLevels()
        out.momentary = m.momentary; out.shortTerm = m.shortTerm
        let i = m.integrated
        out.integrated = i.isFinite ? i : nil
        out.truePeakDB = m.truePeakDB.max() ?? -.infinity
        return out
    }
}
