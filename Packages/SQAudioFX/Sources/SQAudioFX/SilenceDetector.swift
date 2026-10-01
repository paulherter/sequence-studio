import Foundation
import SQCore

/// Finds pauses in audio from a level curve (one linear peak per equal window, e.g. waveform buckets). Pure.
/// The result feeds `SilenceRemoval` in SQCore, which turns it into frame-aligned ripple cuts.
public enum SilenceDetector {
    /// Ranges (relative to the first window, `window` apart) whose level stays below `thresholdDB` for at least
    /// `minimumLength`. A pause touching the start or end of the curve counts.
    public static func silences(levels: [Float], window: Time, thresholdDB: Double, minimumLength: Time) -> [TimeRange] {
        guard window > .zero, !levels.isEmpty else { return [] }
        let limit = Float(GainMath.linear(fromDB: thresholdDB))
        var out: [TimeRange] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let s = runStart else { return }
            runStart = nil
            let r = TimeRange(start: window * Int64(s), duration: window * Int64(end - s))
            if r.duration >= minimumLength { out.append(r) }
        }
        for (i, l) in levels.enumerated() {
            if l < limit { if runStart == nil { runStart = i } } else { close(at: i) }
        }
        close(at: levels.count)
        return out
    }
}
