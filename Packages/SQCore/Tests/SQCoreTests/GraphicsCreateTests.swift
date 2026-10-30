import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct GraphicsCreateTests {
    // MARK: Drag geometry

    @Test func boxSpansTheDragInAnyDirection() {
        let r = CreateDrag.box(from: Vec2(10, 20), to: Vec2(-30, 80), square: false, fromCenter: false)
        #expect(r == GraphicsRect(minX: -30, minY: 20, maxX: 10, maxY: 80))
    }

    @Test func shiftMakesASquareOnTheLongerSide() {
        let r = CreateDrag.box(from: .zero, to: Vec2(-40, 100), square: true, fromCenter: false)
        #expect(r == GraphicsRect(minX: -100, minY: 0, maxX: 0, maxY: 100))
    }

    @Test func optionDrawsFromTheCenter() {
        let r = CreateDrag.box(from: Vec2(50, 50), to: Vec2(80, 60), square: false, fromCenter: true)
        #expect(r == GraphicsRect(minX: 20, minY: 40, maxX: 80, maxY: 60))
        let q = CreateDrag.box(from: Vec2(50, 50), to: Vec2(80, 60), square: true, fromCenter: true)
        #expect(q == GraphicsRect(minX: 20, minY: 20, maxX: 80, maxY: 80))
    }

    @Test func shiftSnapsALineTo45DegreeSteps() {
        let h = CreateDrag.line(from: .zero, to: Vec2(100, 8), constrain: true, fromCenter: false)
        #expect(abs(h.b.y) < 1e-9)
        #expect(abs(h.b.x - Vec2(100, 8).length) < 1e-9)
        let d = CreateDrag.line(from: .zero, to: Vec2(90, -110), constrain: true, fromCenter: false)
        #expect(abs(d.b.x + d.b.y) < 1e-9)
        #expect(d.b.x > 0)
        let free = CreateDrag.line(from: Vec2(1, 2), to: Vec2(100, 8), constrain: false, fromCenter: false)
        #expect(free.a == Vec2(1, 2))
        #expect(free.b == Vec2(100, 8))
    }

    @Test func optionGrowsALineBothWays() {
        let l = CreateDrag.line(from: Vec2(10, 10), to: Vec2(40, 10), constrain: false, fromCenter: true)
        #expect(l.a == Vec2(-20, 10))
        #expect(l.b == Vec2(40, 10))
    }

    // MARK: Layers from a drag

    @Test func aShapeLayerFillsTheDraggedBox() throws {
        let box = GraphicsRect(minX: -100, minY: 50, maxX: 300, maxY: 150)
        for kind in [ShapeKind.rectangle, .ellipse] {
            let l = GraphicsLayer.shape(kind, box: box, canvasWidth: 1920, canvasHeight: 1080)
            let doc = GraphicsDocument(layers: [l])
            #expect(doc.bounds(of: l.id, atLocal: .zero) == box)
            #expect(l.name == kind.title)
        }
    }

    @Test func aLineLayerRunsBetweenTheTwoPoints() throws {
        let l = GraphicsLayer.line(from: Vec2(0, 0), to: Vec2(300, 400), canvasWidth: 1920, canvasHeight: 1080)
        #expect(l.animation.position.value == Vec2(150, 200))
        let e = try #require(l.shapeEffect)
        #expect(abs((e.parameters[ClipEffect.shapeWidthKey]?.value ?? 0) - 500) < 1e-9)
        #expect(abs(l.animation.rotation.value - atan2(400, 300) * 180 / .pi) < 1e-9)
        guard case .shape(.line) = l.content else { Issue.record("not a line"); return }
    }

    // MARK: Draw smoothing

    private func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let d = b - a, l2 = d.x * d.x + d.y * d.y
        guard l2 > 0 else { return (p - a).length }
        let t = min(max(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0), 1)
        return (p - (a + d * t)).length
    }

    @Test func aShakyStraightStrokeBecomesTwoPoints() {
        let pts = (0...100).map { i in Vec2(Double(i) * 4, i % 2 == 0 ? 0.6 : -0.6) }
        let out = PathSmoothing.smooth(pts, tolerance: 2)
        #expect(out.count == 2)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    @Test func aCurveKeepsItsShapeWithFarFewerPoints() {
        let pts = (0...360).map { i -> Vec2 in
            let a = Double(i) * .pi / 180 * 0.75
            let jitter = i % 2 == 0 ? 0.8 : -0.8
            return Vec2(cos(a) * (200 + jitter), sin(a) * (200 + jitter))
        }
        let out = PathSmoothing.smooth(pts, tolerance: 2)
        #expect(out.count < pts.count / 5)
        #expect(out.count >= 6)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
        // Every recorded point stays close to the reduced stroke (tolerance plus the jitter that smoothing removed).
        for p in pts {
            let d = zip(out, out.dropFirst()).map { distance(p, toSegment: $0, $1) }.min() ?? .infinity
            #expect(d <= 2 + 0.8 + 1e-6)
        }
    }

    @Test func shortInputsPassThrough() {
        #expect(PathSmoothing.smooth([], tolerance: 2).isEmpty)
        let two = [Vec2(0, 0), Vec2(5, 5)]
        #expect(PathSmoothing.smooth(two, tolerance: 2) == two)
        // A corner survives: the turn is far larger than the tolerance.
        let corner = (0...20).map { Vec2(Double($0) * 5, 0) } + (1...20).map { Vec2(100, Double($0) * 5) }
        let out = PathSmoothing.smooth(corner, tolerance: 2)
        #expect(out.count >= 3)
        #expect(out.contains { abs($0.x - 100) < 3 && abs($0.y) < 3 })
    }

    // MARK: Which graphic a new item goes into

    private func timeline() -> (Timeline, graphicTop: Clip, graphicLow: Clip, video: Clip) {
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30),
                                                         tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])])
        let tl = p.timelines[0].id
        let v1 = p.timelines[0].tracks[0].id, v2 = p.timelines[0].tracks[1].id
        let low = try! p.addGraphicsClip(in: tl, at: s(0), track: v1, duration: s(5))
        let top = try! p.addGraphicsClip(in: tl, at: s(2), track: v2, duration: s(5))
        let other = try! p.addGeneratorClip(kind: GeneratorRef.graphics, payload: Data(), name: "Late", in: tl, at: s(10), track: v1, duration: s(2))
        let t = p.timelines[0]
        func c(_ id: Clip.ID) -> Clip { t.tracks.flatMap(\.clips).first { $0.id == id }! }
        return (t, c(top), c(low), c(other))
    }

    @Test func aSelectedGraphicUnderThePlayheadTakesTheItem() {
        let (t, top, low, _) = timeline()
        #expect(t.graphicCreateTarget(selection: [low.id], at: s(3)) == low.id)
        #expect(t.graphicCreateTarget(selection: [top.id], at: s(3)) == top.id)
    }

    @Test func aSelectedGraphicAwayFromThePlayheadDoesNot() {
        let (t, _, _, late) = timeline()
        #expect(t.graphicCreateTarget(selection: [late.id], at: s(3)) == nil)
    }

    @Test func withoutSelectionTheGraphicOnATargetedTrackTakesIt() {
        var (t, top, low, _) = timeline()
        #expect(t.graphicCreateTarget(selection: [], at: s(3)) == nil)   // no track targeted
        t.tracks[0].isTargeted = true
        #expect(t.graphicCreateTarget(selection: [], at: s(3)) == low.id)
        t.tracks[1].isTargeted = true
        #expect(t.graphicCreateTarget(selection: [], at: s(3)) == top.id)   // the upper targeted track wins
        #expect(t.graphicCreateTarget(selection: [], at: s(1)) == low.id)
        #expect(t.graphicCreateTarget(selection: [], at: s(8)) == nil)
        t.tracks[1].isLocked = true
        #expect(t.graphicCreateTarget(selection: [], at: s(3)) == low.id)
        #expect(t.graphicCreateTarget(selection: [top.id], at: s(3)) == low.id)   // a locked graphic takes nothing
    }
}
