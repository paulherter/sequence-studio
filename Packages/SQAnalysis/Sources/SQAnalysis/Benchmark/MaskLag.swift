import Foundation
import SQCore

/// Where a mask sits against the ground truth on one labeled frame: the lag report of the mask benchmark (the maintainer
/// 2026-10-18: the mask "still lags behind in parts" on a moving face). Pixel coordinates of the frame, y down.
public struct MaskLagSample: Sendable, Equatable {
    /// Source frame index of the clip.
    public var frame: Int
    /// Centroid of the tracked mask; nil when the frame has none (lost).
    public var predicted: Vec2?
    public var truth: Vec2
    /// Width of the truth's bounding box (the subject's size, for speeds in subject widths per second).
    public var truthWidth: Double
    /// Which labeled picture the mask's shape fits best, the one before, its own or the one after (`MaskLag.shapeLag`):
    /// + = the shape is behind. Catches a mask that keeps an old outline while its centroid stays (a head turning).
    public var shapeLag: Double?
    public init(frame: Int, predicted: Vec2?, truth: Vec2, truthWidth: Double, shapeLag: Double? = nil) {
        self.frame = frame; self.predicted = predicted; self.truth = truth; self.truthWidth = truthWidth; self.shapeLag = shapeLag
    }
}

/// How far a tracked mask is behind (or ahead of) the subject, fitted over labeled frames.
public struct MaskLagReport: Sendable, Equatable {
    /// Least-squares fit of error = -lag * velocity, in source frames: + = the mask trails the motion, - = it leads.
    public var lagFrames: Double
    /// Mean distance of the centroids (px).
    public var meanError: Double
    /// Mean signed error along the motion (px): - = behind the subject.
    public var alongError: Double
    /// Mean subject speed (px per source frame) and in subject widths per second.
    public var meanSpeed: Double
    public var widthsPerSecond: Double
    /// Correlation of the along-motion error with the speed (- = the faster, the further behind).
    public var correlation: Double
    public var count: Int
    /// Mean `MaskLagSample.shapeLag` (labeled steps, + = behind) and over how many samples; nil when none has one.
    public var shapeLag: Double? = nil
    public var shapeCount = 0
}

public enum MaskLag {
    /// Centroid (px) of a mask, nil when empty.
    public static func centroid(_ mask: [Bool], width: Int) -> Vec2? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for i in mask.indices where mask[i] { sx += Double(i % width); sy += Double(i / width); n += 1 }
        return n > 0 ? Vec2(sx / n + 0.5, sy / n + 0.5) : nil
    }

    /// Width of a mask's bounding box (px), 0 when empty.
    public static func boxWidth(_ mask: [Bool], width: Int) -> Double {
        var x0 = Int.max, x1 = -1
        for i in mask.indices where mask[i] { let x = i % width; x0 = min(x0, x); x1 = max(x1, x) }
        return x1 >= 0 ? Double(x1 - x0 + 1) : 0
    }

    /// Where between the previous labeled truth (one step back = +1), its own (0) and the next (one step on = -1) a mask
    /// fits best, from its Jaccard against the three: the peak of the parabola through them, clamped to one step.
    /// + = the mask looks like the past. nil when the three fits are the same (nothing to tell them apart by).
    public static func shapeLag(previous: Double, own: Double, next: Double) -> Double? {
        let curve = previous - 2 * own + next
        if curve < -1e-9 { return min(max((previous - next) / (-2 * curve), -1), 1) }
        if previous == own && own == next { return nil }
        return previous > next ? 1 : previous < next ? -1 : 0
    }

    /// The subject's velocity at each sample (px per source frame): central difference of the truth centroids of the
    /// neighboring samples, one-sided at the ends. Samples sorted by frame; fewer than two give none.
    public static func velocities(_ samples: [MaskLagSample]) -> [Vec2] {
        guard samples.count >= 2 else { return [] }
        return samples.indices.map { k in
            let a = samples[max(k - 1, 0)], b = samples[min(k + 1, samples.count - 1)]
            let df = Double(b.frame - a.frame)
            return df > 0 ? (b.truth - a.truth) * (1 / df) : .zero
        }
    }

    /// The report over the samples with a mask, using velocities from all samples (a lost frame still says where the
    /// subject went). `minSpeed` (px per frame): slower samples are left out of the lag fit only (no direction to lag along).
    /// `widthsPerSecond`: keeps only samples whose speed in subject widths per second is in the range.
    public static func report(_ samples: [MaskLagSample], fps: Double, minSpeed: Double = 0.5,
                              widthsPerSecond range: ClosedRange<Double>? = nil) -> MaskLagReport? {
        let sorted = samples.sorted { $0.frame < $1.frame }
        let v = velocities(sorted)
        guard v.count == sorted.count else { return nil }
        var ev = 0.0, vv = 0.0, dist = 0.0, along = 0.0, speed = 0.0, wps = 0.0, n = 0.0
        var speeds: [Double] = [], alongs: [Double] = []
        for (s, vel) in zip(sorted, v) {
            guard let p = s.predicted else { continue }
            let sp = vel.length
            let w = sp * fps / max(s.truthWidth, 1)
            if let range, !range.contains(w) { continue }
            let e = p - s.truth
            dist += e.length; speed += sp; wps += w; n += 1
            guard sp >= minSpeed else { continue }
            ev += e.x * vel.x + e.y * vel.y; vv += sp * sp
            let a = (e.x * vel.x + e.y * vel.y) / sp
            along += a; speeds.append(sp); alongs.append(a)
        }
        guard n > 0 else { return nil }
        let shapes = zip(sorted, v).compactMap { s, vel -> Double? in
            guard s.predicted != nil, let l = s.shapeLag else { return nil }
            if let range, !range.contains(vel.length * fps / max(s.truthWidth, 1)) { return nil }
            return l
        }
        let m = Double(max(speeds.count, 1))
        let ms = speeds.reduce(0, +) / m, ma = alongs.reduce(0, +) / m
        var cov = 0.0, s1 = 0.0, s2 = 0.0
        for (a, b) in zip(speeds, alongs) { cov += (a - ms) * (b - ma); s1 += (a - ms) * (a - ms); s2 += (b - ma) * (b - ma) }
        let corr = s1 > 0 && s2 > 0 ? cov / (s1 * s2).squareRoot() : 0
        return MaskLagReport(lagFrames: vv > 0 ? -ev / vv : 0, meanError: dist / n, alongError: speeds.isEmpty ? 0 : ma,
                             meanSpeed: speed / n, widthsPerSecond: wps / n, correlation: corr, count: Int(n),
                             shapeLag: shapes.isEmpty ? nil : shapes.reduce(0, +) / Double(shapes.count), shapeCount: shapes.count)
    }
}
