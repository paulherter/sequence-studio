import AppKit
import Foundation
import Testing
@testable import SQTimelineUI

/// The draw-cost changes of the "UI speed" round 5 (docs/PLAYBACK-PERF.md) must not change a pixel: the cheaper clip-end
/// cutting builds the very same paths as the previous implementation (kept here as the reference), and the faster
/// dirty-rect merge returns the same rects.
@MainActor struct TimelineDrawCostTests {
    // MARK: Reference: the cutting as it was before (one parse per end, point arrays, main-actor closure).

    private enum RefSeg {
        case line(CGPoint, CGPoint), quad(CGPoint, CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint, CGPoint)
        var points: [CGPoint] {
            switch self {
            case let .line(a, b): [a, b]
            case let .quad(a, b, c): [a, b, c]
            case let .cubic(a, b, c, d): [a, b, c, d]
            }
        }
    }

    private static func refSegments(_ path: CGPath) -> [RefSeg] {
        var out: [RefSeg] = []
        var cur = CGPoint.zero, first = CGPoint.zero
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: cur = p[0]; first = p[0]
            case .addLineToPoint: out.append(.line(cur, p[0])); cur = p[0]
            case .addQuadCurveToPoint: out.append(.quad(cur, p[0], p[1])); cur = p[1]
            case .addCurveToPoint: out.append(.cubic(cur, p[0], p[1], p[2])); cur = p[2]
            case .closeSubpath: if cur != first { out.append(.line(cur, first)) }; cur = first
            @unknown default: break
            }
        }
        return out
    }

    private static func refEnd(_ path: CGPath, cut: CGFloat, leftSide: Bool, close: Bool) -> CGPath? {
        func inside(_ x: CGFloat) -> Bool { leftSide ? x <= cut + 1e-9 : x >= cut - 1e-9 }
        var kept: [RefSeg?] = []
        for s in refSegments(path) {
            let pts = s.points
            if pts.allSatisfy({ inside($0.x) }) { kept.append(s); continue }
            if !pts.contains(where: { inside($0.x) }) { kept.append(nil); continue }
            guard case let .line(a, b) = s, a.x != b.x else { return nil }
            let c = CGPoint(x: cut, y: a.y + (b.y - a.y) * (cut - a.x) / (b.x - a.x))
            kept.append(inside(a.x) ? .line(a, c) : .line(c, b))
        }
        let n = kept.count
        guard let begin = (0..<n).first(where: { kept[$0] != nil && kept[($0 + n - 1) % n] == nil }) else { return nil }
        let run = (0..<n).map { kept[(begin + $0) % n] }
        let count = run.prefix { $0 != nil }.count
        guard run.dropFirst(count).allSatisfy({ $0 == nil }), let first = run[0] else { return nil }
        let p = CGMutablePath()
        p.move(to: first.points[0])
        for case let s? in run {
            switch s {
            case let .line(_, b): p.addLine(to: b)
            case let .quad(_, b, c): p.addQuadCurve(to: c, control: b)
            case let .cubic(_, b, c, d): p.addCurve(to: d, control1: b, control2: c)
            }
        }
        if close { p.closeSubpath() }
        return p
    }

    /// Every clip shape, both ends, cuts on and off the curves (including cuts that fail): same path element for element.
    @Test func cutEndsAreTheSamePaths() {
        var g = TimelineFastDrawTests.SeededGenerator(seed: 11)
        var compared = 0, failed = 0
        for i in 0..<3000 {
            let x = CGFloat(Double.random(in: -200...900, using: &g)), w = CGFloat(Double.random(in: 0.3...400, using: &g))
            let y = CGFloat(Double.random(in: 0...300, using: &g)), h = CGFloat(Double.random(in: 4...80, using: &g))
            let drawn = CGRect(x: x, y: y, width: w, height: h)
            let radius = min(Theme.Radius.small, h / 2), strip = min(ClipDrawing.nameStripHeight, h)
            let shapes: [(CGPath, Bool)] = [(ClipDrawing.outlinePath(drawn, radius: radius), true),
                                            (ClipDrawing.edgePath(drawn, radius: radius), false),
                                            (ClipDrawing.stripPath(drawn, radius: radius, strip: strip), true),
                                            (ClipDrawing.selectPath(drawn, radius: radius), false)]
            // Cuts where PixelCuts puts them (both scales), plus arbitrary ones through the corners.
            var cuts: [CGFloat] = [drawn.minX + CGFloat(Double.random(in: -2...12, using: &g)),
                                   drawn.maxX - CGFloat(Double.random(in: -2...12, using: &g))]
            for s: CGFloat in [1, 2] {
                let t = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: CGFloat(i % 3) * 0.5, ty: 600)
                if let c = ClipDrawing.PixelCuts(t, drawn: drawn, radius: radius, strip: strip) { cuts += [c.left, c.right] }
            }
            for (path, close) in shapes {
                let segs = ClipDrawing.PixelCuts.segments(path)
                for cut in cuts {
                    for left in [true, false] {
                        let a = ClipDrawing.PixelCuts.end(segs, cut: cut, leftSide: left, close: close)
                        let b = Self.refEnd(path, cut: cut, leftSide: left, close: close)
                        compared += 1
                        if a != b { failed += 1 }
                    }
                }
            }
        }
        #expect(failed == 0, "\(failed) of \(compared) cut paths differ")
        #expect(compared > 50_000)
    }

    // MARK: Dirty-rect merge

    private static func refMerged(_ rects: [CGRect]) -> [CGRect] {
        var out = rects.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i {
                    let a = out[i], b = out[j], u = a.union(b)
                    let overlap = a.intersection(b)
                    let cost = a.width * a.height + b.width * b.height - (overlap.isNull ? 0 : overlap.width * overlap.height)
                    if a.intersects(b) || a.contains(b) || b.contains(a), u.width * u.height <= cost * 1.05 + 1 {
                        out[i] = u
                        out.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return out
    }

    @Test func mergedRectsAreUnchanged() {
        var g = TimelineFastDrawTests.SeededGenerator(seed: 5)
        for _ in 0..<400 {
            let n = Int.random(in: 0...60, using: &g)
            let rects = (0..<n).map { _ in
                CGRect(x: CGFloat(Double.random(in: 0...1400, using: &g)).rounded(), y: CGFloat(Double.random(in: 0...600, using: &g)).rounded(),
                       width: CGFloat(Double.random(in: 0...300, using: &g)).rounded(), height: CGFloat(Double.random(in: 0...80, using: &g)))
            }
            #expect(TimelineContentCache.merged(rects) == Self.refMerged(rects))
        }
    }
}
