import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 30)
private let idA = UUID(), idB = UUID(), idC = UUID()

private func key(_ id: UUID, _ sec: Int64, _ v: Double, _ i: Interpolation = .linear,
                 out: EaseHandle = .linear, in h: EaseHandle = .linear) -> Keyframe<Double> {
    Keyframe(id: id, time: Time(sec, 1), value: v, interpolation: i, inHandle: h, outHandle: out)
}

/// 0s -> 0, 2s -> 100, 4s -> 50, all linear.
private func track3() -> KeyframeTrack<Double> {
    KeyframeTrack(keys: [key(idA, 0, 0), key(idB, 2, 100), key(idC, 4, 50)])
}

private func geo(_ t: KeyframeTrack<Double>, _ mode: GraphMode = .value) -> KeyframeGraphGeometry {
    KeyframeGraphGeometry(size: CGSize(width: 440, height: 212), fit: GraphFit.make(track: t, mode: mode), mode: mode)
}

private let limits = GraphEditLimits(frameDuration: fd)

@Suite struct KeyframeGraphGeometryTests {
    @Test func mappingRoundTrips() {
        let g = geo(track3())
        for s in [0.0, 1.3, 4.0] { #expect(abs(g.seconds(atX: g.x(seconds: s)) - s) < 1e-9) }
        for v in [-5.0, 0, 50, 100] { #expect(abs(g.value(atY: g.y(value: v)) - v) < 1e-9) }
        // y grows downward: higher value = smaller y
        #expect(g.y(value: 100) < g.y(value: 0))
    }

    @Test func autoFitCoversKeysWithPaddingAndInsets() {
        let t = track3()
        let g = geo(t)
        #expect(g.fit.time == 0...4)
        #expect(g.fit.value.lowerBound < 0 && g.fit.value.upperBound > 100)
        #expect(abs(g.x(seconds: 0) - g.plot.minX) < 1e-9)
        #expect(abs(g.x(seconds: 4) - g.plot.maxX) < 1e-9)
        #expect(g.y(value: 100) > g.plot.minY)          // headroom: top key not glued to the edge
    }

    @Test func autoFitIncludesOvershootAndFlatTracks() {
        var t = KeyframeTrack(keys: [key(idA, 0, 0, out: EaseHandle(dx: 0.3, dy: 1.5)), key(idB, 1, 10)])
        #expect(GraphFit.make(track: t, mode: .value).value.upperBound > 15)
        t = KeyframeTrack(keys: [key(idA, 0, 5)])
        let f = GraphFit.make(track: t, mode: .value)
        #expect(f.value.lowerBound < 5 && f.value.upperBound > 5)
        #expect(f.time.upperBound > f.time.lowerBound)
    }

    @Test func speedFitIncludesZero() {
        let f = GraphFit.make(track: track3(), mode: .speed)
        #expect(f.value.lowerBound < 0 && f.value.upperBound > 50)   // +50/s then -25/s
    }

    @Test func hitTestPriority() {
        let t = track3()
        let g = geo(t)
        let kb = g.keyPoint(track: t, index: 1)
        #expect(g.hitTest(kb, track: t, selected: []) == .key(idB))
        #expect(g.hitTest(CGPoint(x: kb.x + 3, y: kb.y + 3), track: t, selected: []) == .key(idB))
        // middle of segment A-B
        let mid = g.point(GraphDataPoint(seconds: 1, value: 50))
        #expect(g.hitTest(mid, track: t, selected: []) == .segment(from: idA, to: idB))
        #expect(g.hitTest(CGPoint(x: mid.x, y: mid.y - 40), track: t, selected: []) == .empty)
    }

    @Test func handlesOnlyOnSelectedKeysAndOnlyWhereTheyExist() {
        let t = track3()
        let g = geo(t)
        #expect(g.handlePoint(track: t, keyID: idB, side: .outSide) != nil)
        #expect(g.handlePoint(track: t, keyID: idA, side: .inSide) == nil)     // first key: no in-handle
        #expect(g.handlePoint(track: t, keyID: idC, side: .outSide) == nil)    // last key: no out-handle
        let hp = g.handlePoint(track: t, keyID: idB, side: .outSide)!
        #expect(g.hitTest(hp, track: t, selected: [idB]) == .handle(idB, .outSide))
        #expect(g.hitTest(hp, track: t, selected: []) != .handle(idB, .outSide))
    }

    @Test func holdSegmentHasNoHandles() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0, .hold), key(idB, 2, 100)])
        let g = geo(t)
        #expect(g.handlePoint(track: t, keyID: idA, side: .outSide) == nil)
        #expect(g.handlePoint(track: t, keyID: idB, side: .inSide) == nil)
    }

    @Test func valueHandlePositionMatchesBezierControlPoints() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0, out: EaseHandle(dx: 0.25, dy: 0.5)), key(idB, 2, 100, in: EaseHandle(dx: 0.5, dy: 0.2))])
        let out = GraphMath.handlePoint(track: t, keyID: idA, side: .outSide, mode: .value)!
        #expect(abs(out.seconds - 0.5) < 1e-9 && abs(out.value - 50) < 1e-9)
        let inn = GraphMath.handlePoint(track: t, keyID: idB, side: .inSide, mode: .value)!
        #expect(abs(inn.seconds - 1.0) < 1e-9 && abs(inn.value - 80) < 1e-9)
    }

    @Test func speedHandleMatchesSSCoreConversion() {
        let h = EaseHandle(dx: 0.25, dy: 0.5)
        let t = KeyframeTrack(keys: [key(idA, 0, 0, out: h), key(idB, 2, 100)])
        let p = GraphMath.handlePoint(track: t, keyID: idA, side: .outSide, mode: .speed)!
        let s = h.speedHandle(valueDelta: 100, duration: Time(2, 1))
        #expect(abs(p.value - s.speed) < 1e-9 && abs(p.seconds - 0.5) < 1e-9)
    }

    @Test func marqueeSelectsKeysInsideRect() {
        let t = track3()
        let g = geo(t)
        let a = g.keyPoint(track: t, index: 0), b = g.keyPoint(track: t, index: 1)
        let r = CGRect(x: a.x - 10, y: min(a.y, b.y) - 10, width: (b.x - a.x) + 20, height: abs(a.y - b.y) + 20)
        #expect(g.keys(in: r, track: t) == [idA, idB])
    }

    @Test func niceGrid() {
        let g = KeyframeGraphGeometry(size: CGSize(width: 440, height: 212),
                                      fit: GraphFit(time: 0...1, value: -3...103), mode: .value)
        let v = g.gridValues()
        #expect(v.contains(0) && v.contains(100))
        #expect(v.allSatisfy { $0 >= -3 && $0 <= 103 })
    }
}

@Suite struct KeyframeGraphEditingTests {
    @Test func moveKeysSnapsToFramesAndMovesGroup() {
        let t = track3()
        let r = KeyframeGraphEditing.moveKeys(base: t, selected: [idA, idB], anchor: idB, deltaSeconds: 0.51, limits: GraphEditLimits(frameDuration: fd, minTime: Time(-10, 1)))
        let b = r.key(id: idB)!, a = r.key(id: idA)!
        #expect(b.time == Time(2, 1) + fd * 15)       // 0.5 s = 15 frames
        #expect(a.time == fd * 15)
        #expect(r.key(id: idC)!.time == Time(4, 1))
    }

    @Test func moveClampsAgainstUnselectedNeighbours() {
        let r = KeyframeGraphEditing.moveKeys(base: track3(), selected: [idB], anchor: idB, deltaSeconds: 10, limits: limits)
        #expect(r.key(id: idB)!.time == Time(4, 1) - fd)     // one frame before C, never onto it
        #expect(r.keys.map(\.id) == [idA, idB, idC])
        let l = KeyframeGraphEditing.moveKeys(base: track3(), selected: [idB], anchor: idB, deltaSeconds: -10, limits: limits)
        #expect(l.key(id: idB)!.time == fd)
    }

    @Test func moveClampsAtMinTimeAndMaxTime() {
        let l = KeyframeGraphEditing.moveKeys(base: track3(), selected: [idA, idB, idC], anchor: idA, deltaSeconds: -5, limits: limits)
        #expect(l.key(id: idA)!.time == .zero)
        #expect(l.key(id: idC)!.time == Time(4, 1))          // group keeps its shape
        let lim = GraphEditLimits(frameDuration: fd, maxTime: Time(5, 1))
        let r = KeyframeGraphEditing.moveKeys(base: track3(), selected: [idB, idC], anchor: idC, deltaSeconds: 9, limits: lim)
        #expect(r.key(id: idC)!.time == Time(5, 1))
        #expect(r.key(id: idB)!.time == Time(3, 1))
    }

    @Test func zeroMoveReturnsBase() {
        let t = track3()
        #expect(KeyframeGraphEditing.moveKeys(base: t, selected: [idB], anchor: idB, deltaSeconds: 0.001, limits: limits) == t)
    }

    @Test func offsetValuesIsRelative() {
        let r = KeyframeGraphEditing.offsetValues(base: track3(), selected: [idA, idB], delta: 7)
        #expect(r.key(id: idA)!.value == 7 && r.key(id: idB)!.value == 107 && r.key(id: idC)!.value == 50)
    }

    @Test func valueHandleDragSetsInfluenceAndOvershoot() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0), key(idB, 2, 100)])
        let r = KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide,
                                                to: GraphDataPoint(seconds: 1.0, value: 150), mode: .value)
        let h = r.key(id: idA)!.outHandle
        #expect(abs(h.dx - 0.5) < 1e-9 && abs(h.dy - 1.5) < 1e-9)          // dy free: overshoot allowed
        #expect(r.key(id: idA)!.interpolation == .bezier)
        #expect(r.key(id: idB)!.inHandle == .linear)                        // other side untouched
        let i = KeyframeGraphEditing.dragHandle(base: t, keyID: idB, side: .inSide,
                                                to: GraphDataPoint(seconds: 1.5, value: 90), mode: .value)
        let ih = i.key(id: idB)!.inHandle
        #expect(abs(ih.dx - 0.25) < 1e-9 && abs(ih.dy - 0.1) < 1e-9)
    }

    @Test func handleInfluenceIsClamped() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0), key(idB, 2, 100)])
        let far = KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide, to: GraphDataPoint(seconds: 9, value: 10), mode: .value)
        #expect(far.key(id: idA)!.outHandle.dx == 1)
        let behind = KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide, to: GraphDataPoint(seconds: -3, value: 10), mode: .value)
        #expect(behind.key(id: idA)!.outHandle.dx == KeyframeGraphEditing.minInfluence)
    }

    @Test func speedHandleDragUsesSSCoreConversion() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0), key(idB, 2, 100)])       // linear speed 50/s
        let r = KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide,
                                                to: GraphDataPoint(seconds: 0.5, value: 100), mode: .speed)   // 2x speed, 25 % influence
        let expected = EaseHandle(speedHandle: SpeedHandle(speed: 100, influence: 0.25), valueDelta: 100, duration: Time(2, 1))
        #expect(r.key(id: idA)!.outHandle == expected)
        // Round trip through the graph position.
        let p = GraphMath.handlePoint(track: r, keyID: idA, side: .outSide, mode: .speed)!
        #expect(abs(p.value - 100) < 1e-9 && abs(p.seconds - 0.5) < 1e-9)
    }

    @Test func speedHandleOnFlatSegmentKeepsDyZero() {
        let t = KeyframeTrack(keys: [key(idA, 0, 5), key(idB, 2, 5)])
        let r = KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide, to: GraphDataPoint(seconds: 1, value: 40), mode: .speed)
        #expect(r.key(id: idA)!.outHandle.dy == 0)
    }

    @Test func holdSegmentHandleDragIsIgnored() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0, .hold), key(idB, 2, 100)])
        #expect(KeyframeGraphEditing.dragHandle(base: t, keyID: idA, side: .outSide, to: GraphDataPoint(seconds: 1, value: 1), mode: .value) == t)
    }
}

@Suite struct KeyframeGraphGestureTests {
    private func begin(_ p: CGPoint, shift: Bool = false, track t: KeyframeTrack<Double>, sel: Set<UUID> = [], mode: GraphMode = .value) -> GraphGestureState {
        GraphGestureState(at: p, shift: shift, geometry: geo(t, mode), track: t, selection: sel, limits: limits)
    }

    @Test func clickSelectsAndShiftClickToggles() {
        let t = track3(), g = geo(t)
        let pa = g.keyPoint(track: t, index: 0), pb = g.keyPoint(track: t, index: 1)
        var s = begin(pa, track: t)
        #expect(s.end(at: pa).selection == [idA])
        s = begin(pb, shift: true, track: t, sel: [idA])
        #expect(s.end(at: pb).selection == [idA, idB])
        s = begin(pb, shift: true, track: t, sel: [idA, idB])
        let r = s.end(at: pb)
        #expect(r.selection == [idA] && !r.commit)
    }

    @Test func clickOnEmptyClearsSelection() {
        let t = track3()
        var s = begin(CGPoint(x: 100, y: 5), track: t, sel: [idA])
        let r = s.end(at: CGPoint(x: 100, y: 5))
        #expect(r.selection.isEmpty && !r.commit)
    }

    @Test func clickOnSegmentSelectsBothKeys() {
        let t = track3(), g = geo(t)
        let mid = g.point(GraphDataPoint(seconds: 1, value: 50))
        var s = begin(mid, track: t)
        #expect(s.end(at: mid).selection == [idA, idB])
    }

    @Test func marqueeSelectsAndShiftExtends() {
        let t = track3(), g = geo(t)
        let pb = g.keyPoint(track: t, index: 1), pc = g.keyPoint(track: t, index: 2)
        var s = begin(CGPoint(x: pb.x - 20, y: 2), track: t)
        let mid = s.drag(to: CGPoint(x: pb.x + 20, y: pb.y + 20))
        #expect(mid.selection == [idB] && mid.marquee != nil)
        #expect(s.end(at: CGPoint(x: pb.x + 20, y: pb.y + 20)).selection == [idB])
        s = begin(CGPoint(x: pc.x - 20, y: 2), shift: true, track: t, sel: [idB])
        _ = s.drag(to: CGPoint(x: pc.x + 14, y: pc.y + 20))
        #expect(s.end(at: CGPoint(x: pc.x + 14, y: pc.y + 20)).selection == [idB, idC])
    }

    @Test func keyDragMovesTimeAndValueAndCommitsOnce() {
        let t = track3(), g = geo(t)
        let p0 = g.keyPoint(track: t, index: 1)
        var s = begin(p0, track: t)
        let to = CGPoint(x: p0.x + CGFloat(0.5 * g.pointsPerSecond), y: p0.y - CGFloat(10 * g.pointsPerValue))
        let mid = s.drag(to: to)
        #expect(!mid.commit)                                     // nothing committed while dragging
        let r = s.end(at: to)
        #expect(r.commit)
        let b = r.track.key(id: idB)!
        #expect(b.time == Time(2, 1) + fd * 15)
        #expect(abs(b.value - 110) < 1e-6)
        #expect(r.selection == [idB])
    }

    @Test func speedModeKeyDragMovesTimeOnly() {
        let t = track3(), g = geo(t, .speed)
        let p0 = g.keyPoint(track: t, index: 1)
        var s = begin(p0, track: t, mode: .speed)
        let to = CGPoint(x: p0.x + CGFloat(0.25 * g.pointsPerSecond), y: p0.y - 40)
        let r = s.end(at: to)
        #expect(r.track.key(id: idB)!.value == 100)
        #expect(r.track.key(id: idB)!.time > Time(2, 1))
    }

    @Test func tinyMovementIsAClickNotADrag() {
        let t = track3(), g = geo(t)
        let p0 = g.keyPoint(track: t, index: 1)
        var s = begin(p0, track: t)
        let r = s.end(at: CGPoint(x: p0.x + 1, y: p0.y + 1))
        #expect(!r.commit && r.track == t)
    }

    @Test func pressOnSelectedKeyDragsWholeGroupAndClickCollapses() {
        let t = track3(), g = geo(t)
        let pa = g.keyPoint(track: t, index: 0)
        var s = begin(pa, track: t, sel: [idA, idB])
        #expect(s.end(at: pa).selection == [idA])                // click without drag collapses
        s = begin(pa, track: t, sel: [idA, idB])
        let to = CGPoint(x: pa.x + CGFloat(0.5 * g.pointsPerSecond), y: pa.y)
        let r = s.end(at: to)
        #expect(r.selection == [idA, idB])
        #expect(r.track.key(id: idB)!.time > Time(2, 1) && r.track.key(id: idA)!.time > .zero)
    }

    @Test func handleDragEditsOnlyThatHandle() {
        let t = KeyframeTrack(keys: [key(idA, 0, 0), key(idB, 2, 100)])
        let g = geo(t)
        let hp = g.handlePoint(track: t, keyID: idA, side: .outSide)!
        var s = begin(hp, track: t, sel: [idA])
        let to = CGPoint(x: hp.x + 30, y: hp.y - 20)
        let r = s.end(at: to)
        #expect(r.commit && r.selection == [idA])
        let h = r.track.key(id: idA)!.outHandle
        #expect(h.dx > EaseHandle.linear.dx && h.dy > EaseHandle.linear.dy)
        #expect(r.track.key(id: idB) == t.key(id: idB))
    }
}

@Suite struct EasingMenuSpecTests {
    @Test func listsBuiltInsThenUserCurvesAndSave() {
        var lib = EasingLibrary()
        lib.add(EasingCurve(name: "Mine", interpolation: .bezier, outHandle: .linear, inHandle: .linear))
        let spec = EasingMenuSpec(library: lib, side: .out, hasSelection: true)
        #expect(spec.curveNames == EasingCurve.builtIns.map(\.name) + ["Mine"])
        #expect(spec.entries.contains(.side(.out, title: "Outgoing Only", checked: true)))
        #expect(spec.entries.last == .saveCurve(enabled: true))
    }

    @Test func disabledWithoutSelection() {
        let spec = EasingMenuSpec(library: EasingLibrary(), side: .both, hasSelection: false)
        #expect(spec.entries.last == .saveCurve(enabled: false))
        #expect(spec.entries.allSatisfy { if case .curve(_, let e) = $0 { !e } else { true } })
    }
}
