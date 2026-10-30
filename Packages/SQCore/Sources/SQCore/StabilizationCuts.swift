import Foundation

// W9.7 (2b) Scene cuts in edited footage. A registration nearly always "matches" two frames, even across a cut (Vision
// returned zoom 0.84 / 8 degree turns there), so a cut is also recognized from how the picture changed: a jump in the
// color histogram, a jump in the photometric residual left after aligning the frames, or a frame-to-frame zoom / turn no
// hand-held camera makes. Jumps are judged against the neighboring frames (local median), so a busy scene or a whip pan
// that changes a lot on every frame is no cut.
public enum StabilizationCuts {
    /// Neighbors on each side for the local median (the frame itself and its direct neighbors are left out).
    static let window = 15
    /// Histogram distance (0...1, half L1 of normalized histograms): a cut needs at least `histogramFloor` and more than
    /// `jumpFactor` x the local median + `histogramMargin`.
    static let histogramFloor = 0.15, histogramMargin = 0.08
    /// Mean absolute gray difference (0...255) after alignment: at least `residualFloor`, more than `jumpFactor` x the
    /// local median + `residualMargin`.
    static let residualFloor = 10.0, residualMargin = 4.0
    static let jumpFactor = 3.0
    /// Frame-to-frame zoom (|log scale| beyond the local median) and turn (degrees) no camera makes in one frame.
    static let maxLogScaleStep = 0.1, maxTurnStep = 5.0

    /// Frame indices (> 0) where a new shot starts. Scores are per frame (index i: frame i-1 to frame i, index 0
    /// ignored); an empty or short score array is not used.
    ///
    /// A cut only matters to the stabilizer where the camera path cannot be followed across it, so two refinements
    /// (W9.7 2c; both off when the arrays are empty):
    /// - `confidence[k]` (Vision and the independent check agree, `Stabilizer.minConfidence`): a histogram or residual
    ///   jump on a pair both registrations agree on is a light / exposure change or a passing subject, no cut (C2160 7.07 s).
    /// - `checks[k]` (the check's own motion, nil where it could not measure): a zoom / turn jump only Vision sees, while
    ///   the check measures the steady camera, is Vision's error (low confidence replaces it), no cut (IMG_1281 0.6 s).
    public static func detect(motions: [CameraMotion], histogram: [Double], residual: [Double],
                              checks: [CameraMotion?] = [], confidence: [Double] = []) -> [Int] {
        detectWithReasons(motions: motions, histogram: histogram, residual: residual, checks: checks, confidence: confidence)
            .map(\.index)
    }

    /// Which score found a cut (the first that fires, in this order). Diagnostics (EngineBench).
    public enum Reason: String, Sendable { case histogram, residual, motion }

    /// `detect` with the score that fired per cut.
    public static func detectWithReasons(motions: [CameraMotion], histogram: [Double], residual: [Double],
                                         checks: [CameraMotion?] = [], confidence: [Double] = [])
        -> [(index: Int, reason: Reason)] {
        let n = motions.count
        guard n > 1 else { return [] }
        func logOf(_ m: CameraMotion) -> Double { m.scale.isFinite && m.scale > 0 ? log(m.scale) : 0 }
        let logScale = motions.map(logOf)
        let turn = motions.map(\.rotation)
        func jumpsInMotion(_ m: CameraMotion, _ k: Int) -> Bool {
            abs(logOf(m) - localMedian(logScale, k)) > maxLogScaleStep || abs(m.rotation - localMedian(turn, k)) > maxTurnStep
        }
        var cuts: [(index: Int, reason: Reason)] = []
        for k in 1..<n {
            let agreed = k < confidence.count && confidence[k] >= Stabilizer.minConfidence
            if !agreed {
                if jumps(histogram, k, floor: histogramFloor, margin: histogramMargin) { cuts.append((k, .histogram)); continue }
                if jumps(residual, k, floor: residualFloor, margin: residualMargin) { cuts.append((k, .residual)); continue }
            }
            if jumpsInMotion(motions[k], k) {
                if k < checks.count, let c = checks[k], !jumpsInMotion(c, k) { continue }
                cuts.append((k, .motion))
            }
        }
        return cuts
    }

    /// The local median a score at `k` is judged against (diagnostics).
    public static func localReference(_ xs: [Double], at k: Int) -> Double { localMedian(xs, k) }

    static func jumps(_ xs: [Double], _ k: Int, floor: Double, margin: Double) -> Bool {
        guard k < xs.count, xs[k].isFinite, xs[k] >= floor else { return false }
        return xs[k] > jumpFactor * localMedian(xs, k) + margin
    }

    /// Median of xs[k-window ... k+window] without k-1, k, k+1 (a one-frame flash flags both its frames); 0 when empty.
    static func localMedian(_ xs: [Double], _ k: Int) -> Double {
        var v: [Double] = []
        v.reserveCapacity(2 * window)
        let lo = max(1, k - window), hi = min(xs.count - 1, k + window)
        guard lo <= hi else { return 0 }          // fewer than two scores: a bare range would trap
        for i in lo...hi where abs(i - k) > 1 && xs[i].isFinite { v.append(xs[i]) }
        guard !v.isEmpty else { return 0 }
        v.sort()
        return v[v.count / 2]
    }
}
