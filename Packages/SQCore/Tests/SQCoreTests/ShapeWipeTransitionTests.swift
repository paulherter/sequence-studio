import Foundation
import Testing
@testable import SQCore

/// Parity set (Premiere Iris / Wipe / Dissolve, Resolve Shape / Wipe): Additive Dissolve, Clock Wipe, Box / Diamond / Cross
/// Iris, Barn Doors, Blinds. Shapes are one compose mode (`.shape`) with a distance field per shape.
@Suite struct ShapeWipeTransitionTests {
    static let kinds: [TransitionKind] = [.additiveDissolve, .clockWipe, .boxIris, .diamondIris, .crossIris, .barnDoors, .venetianBlinds,
                                          .radialWipe, .wedgeWipe, .pinwheel, .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe, .mosaicDissolve]
    static let shapeKinds: [TransitionKind] = [.clockWipe, .boxIris, .diamondIris, .crossIris, .barnDoors, .venetianBlinds,
                                               .radialWipe, .wedgeWipe, .pinwheel, .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe]

    private func eval(_ k: TransitionKind, _ i: Int, _ n: Int = 11, dir: TransitionDirection = .left, soft: Double = 0.1) -> TransitionRender {
        TransitionRender.evaluate(kind: k, direction: dir, softness: soft, motionBlur: 0, easing: .linear, frameIndex: i, frames: n)
    }

    @Test func kindsAreVideoLayerKindsWithUniqueNames() {
        var names = Set(TransitionKind.allCases.filter { !Self.kinds.contains($0) }.map(\.name))
        for k in Self.kinds {
            #expect(k.trackKind == .video && k.isLayerKind && k.isMotion && !k.isDip && !k.usesMotionBlur)
            #expect(TransitionKind(rawValue: k.rawValue) == k)
            #expect(names.insert(k.name).inserted, "duplicate name \(k.name)")
        }
        for k in Self.shapeKinds { #expect(k.usesSoftness && k.usesEasing) }
        #expect(TransitionKind.barnDoors.usesDirection && !TransitionKind.boxIris.usesDirection)
    }

    @Test func additiveDissolveOverlapsBothPicturesAndEndsClean() {
        let n = 11
        let first = eval(.additiveDissolve, 0, n), mid = eval(.additiveDissolve, 5, n), last = eval(.additiveDissolve, n - 1, n)
        #expect(first.compose == .sum)
        // Around the middle both are (nearly) fully opaque: the sum brightens. A plain dissolve never exceeds 1 in total.
        #expect(mid.outgoing.opacity + mid.incoming.opacity > 1.5)
        #expect(first.outgoing.opacity > 0.9 && first.incoming.opacity < 0.25)
        #expect(last.incoming.opacity > 0.9 && last.outgoing.opacity < 0.25)
        for i in 0..<n {
            let r = eval(.additiveDissolve, i, n)
            #expect((0...1).contains(r.outgoing.opacity) && (0...1).contains(r.incoming.opacity))
        }
    }

    @Test func shapesUseTheShapeComposeAndSweepTheFrontThroughTheWholeRange() {
        for k in Self.shapeKinds {
            let a = eval(k, 0), z = eval(k, 10)
            #expect(a.compose == .shape && z.compose == .shape, "\(k)")
            #expect(a.wipe.front < 0.15 && z.wipe.front > 0.85, "\(k) \(a.wipe.front) \(z.wipe.front)")
            #expect(a.wipe.direction.x == z.wipe.direction.x)
        }
        // Different kinds select different distance fields (Barn Doors shares the id space with its axis in y).
        let ids = Self.shapeKinds.map { eval($0, 3).wipe.direction.x }
        #expect(Set(ids).count == ids.count)
    }

    @Test func distanceFieldsAreZeroAtTheirOriginAndOneAtTheFarEdge() {
        typealias S = TransitionRender.ShapeWipe
        for k in [S.Shape.box, .diamond, .cross, .doorsAcross, .doorsDown] {
            #expect(S.distance(k, u: 0.5, v: 0.5) < 1e-9, "\(k)")
        }
        #expect(abs(S.distance(.box, u: 1, v: 0.5) - 1) < 1e-9 && abs(S.distance(.box, u: 1, v: 1) - 1) < 1e-9)
        #expect(abs(S.distance(.diamond, u: 1, v: 1) - 1) < 1e-9 && abs(S.distance(.diamond, u: 1, v: 0.5) - 0.5) < 1e-9)
        #expect(abs(S.distance(.diamond, u: 0.9, v: 0.5) - 0.4) < 1e-9 && abs(S.distance(.box, u: 0.9, v: 0.5) - 0.8) < 1e-9)
        // Cross: opens along both axes first (min of |x|, |y|).
        #expect(S.distance(.cross, u: 1, v: 0.5) < 1e-9 && S.distance(.cross, u: 0.5, v: 1) < 1e-9)
        #expect(abs(S.distance(.cross, u: 1, v: 1) - 1) < 1e-9)
        // Barn doors: horizontal axis only / vertical only.
        #expect(abs(S.distance(.doorsAcross, u: 1, v: 0.1) - 1) < 1e-9 && S.distance(.doorsAcross, u: 0.5, v: 0) < 1e-9)
        #expect(abs(S.distance(.doorsDown, u: 0.1, v: 1) - 1) < 1e-9 && S.distance(.doorsDown, u: 0, v: 0.5) < 1e-9)
    }

    @Test func clockSweepsClockwiseFromTwelve() {
        typealias S = TransitionRender.ShapeWipe
        func d(_ u: Double, _ v: Double) -> Double { S.distance(.clock, u: u, v: v) }
        #expect(d(0.5, 0.1) < 0.01)                       // 12 o'clock first
        #expect(abs(d(0.9, 0.5) - 0.25) < 1e-9)           // 3 o'clock
        #expect(abs(d(0.5, 0.9) - 0.5) < 1e-9)            // 6
        #expect(abs(d(0.1, 0.5) - 0.75) < 1e-9)           // 9
        #expect(d(0.45, 0.1) > 0.97)                      // just before 12 again
    }

    @Test func blindsRepeatInBands() {
        typealias S = TransitionRender.ShapeWipe
        let n = Double(S.blindCount)
        #expect(S.distance(.blinds, u: 0.3, v: 0) < 1e-9)
        #expect(abs(S.distance(.blinds, u: 0.3, v: 0.5 / n) - 0.5) < 1e-9)
        #expect(abs(S.distance(.blinds, u: 0.3, v: 1 / n + 0.5 / n) - 0.5) < 1e-9)
    }

    @Test func maskIsBWhereDistanceIsBelowTheFront() {
        typealias S = TransitionRender.ShapeWipe
        #expect(S.mask(.box, u: 0.5, v: 0.5, front: 0.5, softness: 0.05) == 1)
        #expect(S.mask(.box, u: 1, v: 0.5, front: 0.5, softness: 0.05) == 0)
        #expect(abs(S.mask(.box, u: 0.75, v: 0.5, front: 0.5, softness: 0.05) - 0.5) < 1e-9)
        #expect(S.mask(.clock, u: 0.5, v: 0.95, front: 1.2, softness: 0.1) == 1)
        #expect(S.mask(.clock, u: 0.5, v: 0.05, front: -0.2, softness: 0.1) == 0)
    }

    @Test func barnDoorsFollowTheDirectionAxis() {
        #expect(eval(.barnDoors, 3, dir: .left).wipe.direction == eval(.barnDoors, 3, dir: .right).wipe.direction)
        #expect(eval(.barnDoors, 3, dir: .up).wipe.direction == eval(.barnDoors, 3, dir: .down).wipe.direction)
        #expect(eval(.barnDoors, 3, dir: .left).wipe.direction != eval(.barnDoors, 3, dir: .up).wipe.direction)
    }

    @Test func secondWipeSetFieldsStayInRangeAndReachBothEnds() {
        typealias S = TransitionRender.ShapeWipe
        let shapes: [S.Shape] = [.radial, .wedge, .pinwheel, .checker, .zigZag, .inset, .random, .slice]
        for sh in shapes {
            var lo = 2.0, hi = -1.0
            for i in 0..<40 { for j in 0..<40 {
                let d = S.distance(sh, u: (Double(i) + 0.5) / 40, v: (Double(j) + 0.5) / 40)
                #expect(d >= -1e-9 && d <= 1 + 1e-9, "\(sh) \(d)")
                lo = min(lo, d); hi = max(hi, d)
            } }
            #expect(lo < 0.1 && hi > 0.9, "\(sh) \(lo) \(hi)")
        }
        #expect(S.distance(.radial, u: 0, v: 1) < 1e-9 && abs(S.distance(.radial, u: 1, v: 0) - 1) < 1e-9)
        #expect(abs(S.distance(.wedge, u: 0.5, v: 0)) < 1e-9 && abs(S.distance(.wedge, u: 0.5, v: 1) - 1) < 1e-9)
        #expect(abs(S.distance(.wedge, u: 0.1, v: 0.5) - S.distance(.wedge, u: 0.9, v: 0.5)) < 1e-9)
        #expect(S.distance(.inset, u: 0, v: 0) == 0 && S.distance(.inset, u: 1, v: 1) == 1)
        // Random Blocks: a whole cell shares one order, neighbours differ, a hash is stable.
        #expect(S.distance(.random, u: 0.01, v: 0.01) == S.distance(.random, u: 0.07, v: 0.1))
        #expect(S.distance(.random, u: 0.01, v: 0.01) != S.distance(.random, u: 0.1, v: 0.01))
        #expect(S.cellOrder(3, 5) == S.cellOrder(3, 5))
        // Slice: neighbouring strips run in opposite directions.
        #expect(S.distance(.slice, u: 0.1, v: 0.05) < S.distance(.slice, u: 0.9, v: 0.05))
        #expect(S.distance(.slice, u: 0.1, v: 0.15) > S.distance(.slice, u: 0.9, v: 0.15))
        let m = eval(.mosaicDissolve, 5)
        #expect(m.compose == .mosaic && abs(m.wipe.front - 0.5) < 0.01)
        // Zig-Zag: row 0 runs left to right, row 1 right to left.
        #expect(S.distance(.zigZag, u: 0.05, v: 0.05) < S.distance(.zigZag, u: 0.95, v: 0.05))
        #expect(S.distance(.zigZag, u: 0.05, v: 0.15) > S.distance(.zigZag, u: 0.95, v: 0.15))
    }
}
