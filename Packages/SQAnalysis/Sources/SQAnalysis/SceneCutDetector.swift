import Foundation
import SQCore

/// Finds shot changes in a series of per-frame differences. Pure: `SceneCutAnalyzer` produces the differences from decoded
/// frames; the threshold adapts to the activity around each frame so camera moves and flicker do not read as cuts.
public enum SceneCutDetector {
    public struct Settings: Sendable, Equatable {
        /// A change must reach this histogram difference (0...1) whatever the surroundings.
        public var minimumDifference: Double = 0.2
        /// ... and this many times the mean difference of the frames around it.
        public var ratio: Double = 4
        /// Frames looked at on each side for the local activity.
        public var window: Int = 12
        /// Two cuts closer than this many frames: only the stronger one stays.
        public var minimumGapFrames: Int = 8
        public init() {}
    }

    /// `differences[i]` = change between frame i-1 and i (index 0 ignored). Returns the indices of the first frame of each
    /// new shot.
    public static func cutIndices(differences d: [Double], settings s: Settings = Settings()) -> [Int] {
        guard d.count > 2 else { return [] }
        var picked: [Int] = []
        for i in 1..<d.count {
            let v = d[i]
            guard v.isFinite, v >= s.minimumDifference else { continue }
            let lo = max(1, i - s.window), hi = min(d.count - 1, i + s.window)
            var sum = 0.0, n = 0
            for j in lo...hi where j != i && abs(j - i) > 1 || (j != i && hi - lo < 3) {
                sum += d[j].isFinite ? d[j] : 0; n += 1
            }
            let local = n > 0 ? sum / Double(n) : 0
            guard v >= local * s.ratio else { continue }
            let gl = max(1, i - s.minimumGapFrames), gh = min(d.count - 1, i + s.minimumGapFrames)
            // A stronger frame within the gap wins (ties: the earlier one).
            var best = true
            for j in gl...gh where j != i && (d[j] > v || (d[j] == v && j < i)) { best = false; break }
            if best { picked.append(i) }
        }
        return picked
    }

    /// Difference of two normalized-or-not luma histograms of equal size: 0 identical, 1 disjoint.
    public static func histogramDifference(_ a: [Int], _ b: [Int]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ta = a.reduce(0, +), tb = b.reduce(0, +)
        guard ta > 0, tb > 0 else { return 0 }
        var s = 0.0
        for i in a.indices { s += abs(Double(a[i]) / Double(ta) - Double(b[i]) / Double(tb)) }
        return s / 2
    }
}
