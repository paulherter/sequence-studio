import Foundation

/// Segmentation metrics of the mask benchmark (REPORT.md section 5): J (region IoU), F (boundary F-measure, DAVIS
/// style with a tolerance of 0.8% of the diagonal) and J&F. Pure math on Bool grids, no media or model.
public enum MaskMetrics {
    /// Region similarity. Two empty masks are a perfect match.
    public static func jaccard(_ a: [Bool], _ b: [Bool]) -> Double {
        precondition(a.count == b.count, "mask size mismatch")
        var inter = 0, union = 0
        for i in a.indices {
            if a[i] && b[i] { inter += 1 }
            if a[i] || b[i] { union += 1 }
        }
        return union == 0 ? 1 : Double(inter) / Double(union)
    }

    /// Pixels of the mask with at least one 4-neighbor outside it (the frame edge counts as inside).
    public static func boundary(_ m: [Bool], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: m.count)
        for y in 0..<height {
            for x in 0..<width where m[y * width + x] {
                let edge = (x > 0 && !m[y * width + x - 1]) || (x < width - 1 && !m[y * width + x + 1])
                    || (y > 0 && !m[(y - 1) * width + x]) || (y < height - 1 && !m[(y + 1) * width + x])
                if edge { out[y * width + x] = true }
            }
        }
        return out
    }

    /// `m` grown by `radius` px (square window, separable).
    static func dilated(_ m: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var h = [Bool](repeating: false, count: m.count)
        for y in 0..<height {
            for x in 0..<width where m[y * width + x] {
                for xx in max(0, x - radius)...min(width - 1, x + radius) { h[y * width + xx] = true }
            }
        }
        var v = [Bool](repeating: false, count: m.count)
        for y in 0..<height {
            for x in 0..<width where h[y * width + x] {
                for yy in max(0, y - radius)...min(height - 1, y + radius) { v[yy * width + x] = true }
            }
        }
        return v
    }

    /// Boundary F-measure. Both boundaries empty: 1; one empty: 0.
    public static func boundaryF(_ pred: [Bool], _ gt: [Bool], width: Int, height: Int, tolerance: Double = 0.008, pixels: Int? = nil) -> Double {
        precondition(pred.count == width * height && gt.count == pred.count, "mask size mismatch")
        let bp = boundary(pred, width: width, height: height), bg = boundary(gt, width: width, height: height)
        let np = bp.filter { $0 }.count, ng = bg.filter { $0 }.count
        if np == 0 && ng == 0 { return 1 }
        if np == 0 || ng == 0 { return 0 }
        let r = pixels ?? max(1, Int((tolerance * (Double(width * width + height * height)).squareRoot()).rounded()))
        let nearG = dilated(bg, width: width, height: height, radius: r)
        let nearP = dilated(bp, width: width, height: height, radius: r)
        var hitP = 0, hitG = 0
        for i in bp.indices {
            if bp[i] && nearG[i] { hitP += 1 }
            if bg[i] && nearP[i] { hitG += 1 }
        }
        let precision = Double(hitP) / Double(np), recall = Double(hitG) / Double(ng)
        return precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
    }

    /// Mean absolute difference of the soft matte to the truth in the band of `radius` px around the truth's edge: how
    /// close the edge pixels are to the real alpha (a blobby or hand-drawn edge scores high, a keyed one low).
    public static func bandError(alpha: [Float], truth: [Float], width: Int, height: Int, radius: Int = 6) -> Double {
        let t = truth.map { $0 >= 0.5 }
        let band = dilated(boundary(t, width: width, height: height), width: width, height: height, radius: radius)
        var sum = 0.0, n = 0
        for i in band.indices where band[i] { sum += Double(abs(alpha[i] - truth[i])); n += 1 }
        return n == 0 ? 0 : sum / Double(n)
    }

    /// Nearest-neighbor shrink so the metrics stay cheap on 4K frames (longest side at most `longSide`).
    public static func downscaled(_ values: [Float], width: Int, height: Int, longSide: Int = 480) -> (mask: [Bool], width: Int, height: Int) {
        let scale = min(1, Double(longSide) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let sy = min(height - 1, Int((Double(y) + 0.5) / scale))
            for x in 0..<w {
                let sx = min(width - 1, Int((Double(x) + 0.5) / scale))
                out[y * w + x] = values[sy * width + sx] >= 0.5
            }
        }
        return (out, w, h)
    }
}

/// Scores of one variant on one clip, averaged over the labeled frames that were scored.
public struct MaskBenchScore: Sendable, Equatable {
    public var j = 0.0, f = 0.0
    /// Strict edge scores at the frame's full size: boundary F within 2 px, and the soft matte's mean error in the 6 px band around the true edge.
    public var f2 = 0.0, bandError = 0.0
    /// J and strict F of the first labeled frame (the pick itself, before any tracking).
    public var firstJ = 0.0, firstF2 = 0.0
    public var scored = 0
    /// Frames the tracker answered "lost" or "nothing".
    public var lostFrames = 0
    /// Scripted corrections given (strokes variant).
    public var corrections = 0
    /// Wall time of the tracker's steps and how many were taken (ms per frame).
    public var stepSeconds = 0.0, steps = 0
    /// Per scored frame, when asked for (the benchmark's details).
    public var notes: [String] = []
    /// J and F of every scored labeled frame, in order (the scenario reports cut windows out of it).
    public var perFrame: [MaskFrameScore] = []
    /// Frame indices the tracker answered "lost", "nothing" or threw on.
    public var lostFrameIndices: [Int] = []
    /// Mask and truth centroids of every scored labeled frame (the lag report, `MaskLag`).
    public var lagSamples: [MaskLagSample] = []
    /// The clip's frame rate (the lag report's speeds per second).
    public var fps = 0.0
    public var msPerFrame: Double { steps > 0 ? stepSeconds * 1000 / Double(steps) : 0 }
    public var jf: Double { (j + f) / 2 }

    public init() {}

    public mutating func add(j: Double, f: Double, f2: Double = 0, bandError: Double = 0) {
        let n = Double(scored)
        self.f2 = (self.f2 * n + f2) / (n + 1); self.bandError = (self.bandError * n + bandError) / (n + 1)
        self.j = (self.j * n + j) / (n + 1); self.f = (self.f * n + f) / (n + 1)
        scored += 1
    }

    /// The compact table written to build/mask-bench.md: one row per clip and variant.
    public static func table(_ rows: [(clip: String, variant: String, score: MaskBenchScore)]) -> String {
        var s = "| clip | variant | J | F | J&F | lost | corr | scored | ms/frame | F2px | band err | J@0 | F2@0 |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            s += "| \(r.clip) | \(r.variant) | \(String(format: "%.3f | %.3f | %.3f", r.score.j, r.score.f, r.score.jf)) | \(r.score.lostFrames) | \(r.score.corrections) | \(r.score.scored) | \(String(format: "%.0f", r.score.msPerFrame)) | \(String(format: "%.3f | %.4f", r.score.f2, r.score.bandError)) | \(String(format: "%.3f | %.3f", r.score.firstJ, r.score.firstF2)) |\n"
        }
        return s
    }
}
