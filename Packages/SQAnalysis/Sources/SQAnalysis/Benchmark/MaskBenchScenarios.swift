import Foundation

/// Score of one labeled frame (for the windowed scenario reports of the mask benchmark).
public struct MaskFrameScore: Sendable, Equatable {
    public var frame: Int
    public var j: Double, f: Double
    public init(frame: Int, j: Double, f: Double) { self.frame = frame; self.j = j; self.f = f }
    public var jf: Double { (j + f) / 2 }
}

/// Helpers for the benchmark's mid-clip prompt and occlusion scenarios. Pure math, no media or model.
public enum MaskBenchScenarios {
    /// Mean J, F, J&F over the labeled frames in `range` (nil when none was scored there).
    public static func window(_ frames: [MaskFrameScore], _ range: Range<Int>) -> (j: Double, f: Double, jf: Double, count: Int)? {
        let inside = frames.filter { range.contains($0.frame) }
        guard !inside.isEmpty else { return nil }
        let n = Double(inside.count)
        let j = inside.reduce(0) { $0 + $1.j } / n, f = inside.reduce(0) { $0 + $1.f } / n
        return (j, f, (j + f) / 2, inside.count)
    }

    /// Frames from `end` (the first picture without the occlusion) to the first labeled frame at or after it whose J reaches
    /// `threshold`; nil when none does. The resolution is the labels' spacing.
    public static func framesToRecover(_ frames: [MaskFrameScore], end: Int, threshold: Double = 0.5) -> Int? {
        frames.filter { $0.frame >= end && $0.j >= threshold }.map(\.frame).min().map { $0 - end }
    }

    /// A click inside the subject, away from its edge: the centroid of the part of the mask that is at least half as far
    /// from the edge as its deepest point (the eroded interior); when the centroid falls outside it, the nearest eroded pixel.
    /// Returns pixel coordinates of the grid, nil for an empty mask.
    public static func interiorClick(_ mask: [Bool], width: Int, height: Int) -> (x: Double, y: Double)? {
        guard width > 0, height > 0, mask.count == width * height, mask.contains(true) else { return nil }
        // City-block distance to the nearest outside pixel (the frame edge counts as outside), two passes.
        var d = [Int](repeating: 0, count: mask.count)
        let far = width + height
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let up = y > 0 ? d[(y - 1) * width + x] : 0, left = x > 0 ? d[y * width + x - 1] : 0
                d[y * width + x] = min(up, left, far) + 1
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where mask[y * width + x] {
                let down = y < height - 1 ? d[(y + 1) * width + x] : 0, right = x < width - 1 ? d[y * width + x + 1] : 0
                d[y * width + x] = min(d[y * width + x], down + 1, right + 1)
            }
        }
        let deepest = d.max() ?? 0
        let cut = max(1, (deepest + 1) / 2)
        var sx = 0.0, sy = 0.0, n = 0.0
        for i in d.indices where d[i] >= cut { sx += Double(i % width); sy += Double(i / width); n += 1 }
        guard n > 0 else { return nil }
        let cx = sx / n, cy = sy / n
        let ix = min(max(Int(cx.rounded()), 0), width - 1), iy = min(max(Int(cy.rounded()), 0), height - 1)
        if d[iy * width + ix] >= cut { return (Double(ix), Double(iy)) }
        var best = -1, bestDist = Double.infinity
        for i in d.indices where d[i] >= cut {
            let dx = Double(i % width) - cx, dy = Double(i / width) - cy
            if dx * dx + dy * dy < bestDist { bestDist = dx * dx + dy * dy; best = i }
        }
        return (Double(best % width), Double(best / width))
    }

    /// Horizontal picture shift (fraction of the width, negative = left) that takes a subject spanning `x0...x1` out of
    /// the frame through the nearer side, with a margin of 0.02.
    public static func exitDistance(x0: Double, x1: Double) -> Double {
        (x0 + x1) / 2 < 0.5 ? -(x1 + 0.02) : (1 - x0) + 0.02
    }

    /// The exit scenario's shift at `frame`: over `start..<start+length` the picture slides out by `distance` in the
    /// first third, stays out for the middle third and slides back in the last third; 0 outside.
    public static func exitShift(frame: Int, start: Int, length: Int, distance: Double) -> Double {
        let k = frame - start
        guard k >= 0, k < length else { return 0 }
        let third = max(length / 3, 1), back = exitReturn(start: start, length: length) - start
        if k < third { return distance * Double(k + 1) / Double(third) }
        if k < back { return distance }
        return distance * Double(length - k) / Double(length - back + 1)
    }

    /// First frame of the exit scenario's way back in (the last third of `start..<start+length`).
    public static func exitReturn(start: Int, length: Int) -> Int { start + length - max(length / 3, 1) }

    /// Horizontal shift (fraction of the width) of the "moved" scenario: 0.3 toward the side with more room, at most as
    /// far as the subject `x0...x1` stays in the frame.
    public static func moveDistance(x0: Double, x1: Double) -> Double {
        x0 > 1 - x1 ? -min(0.3, x0) : min(0.3, 1 - x1)
    }

    /// `values` (width x height) moved right by `dx` pixels (left when negative); uncovered pixels take `fill`.
    public static func shifted<T>(_ values: [T], width: Int, height: Int, by dx: Int, fill: T) -> [T] {
        guard dx != 0 else { return values }
        var out = [T](repeating: fill, count: values.count)
        guard abs(dx) < width else { return out }
        for y in 0..<height {
            for x in max(0, dx)..<min(width, width + dx) { out[y * width + x] = values[y * width + x - dx] }
        }
        return out
    }

    /// Frames from `from` to the first frame at or after it (up to `last`) the tracker did not answer lost; nil when none.
    public static func framesToReacquire(lost: [Int], from: Int, last: Int) -> Int? {
        let gone = Set(lost)
        return from <= last ? (from...last).first { !gone.contains($0) }.map { $0 - from } : nil
    }

    /// Bounding box (x0, y0, x1, y1 as pixel bounds, x1/y1 exclusive) of the mask grown by `margin` of its size on every side.
    public static func grownBox(_ mask: [Bool], width: Int, height: Int, margin: Double) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for i in mask.indices where mask[i] {
            let x = i % width, y = i / width
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        guard x1 >= 0 else { return nil }
        let gx = Int((Double(x1 - x0 + 1) * margin).rounded(.up)), gy = Int((Double(y1 - y0 + 1) * margin).rounded(.up))
        return (max(0, x0 - gx), max(0, y0 - gy), min(width, x1 + 1 + gx), min(height, y1 + 1 + gy))
    }
}
