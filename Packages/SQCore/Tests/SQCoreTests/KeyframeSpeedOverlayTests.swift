import Foundation
import Testing
@testable import SQCore

// Graph Editor (AE style, speed graph only): one curve per property, several properties overlaid, handles of several
// selected keys edited together.

private let op = PropertyID("opacity"), pos = PropertyID("position")

@Test func speedOverlayLinearScalarIsDirectedAndPeaked() {
    // 0 -> 10 in 2 s (5/s), then 10 -> 0 in 1 s (10/s, falling: still positive in the overlay).
    let tr = PropertyTrack.scalar(KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 10), kfKey(3, 0)]))
    let c = tr.speedOverlay(samples: 5)!
    #expect(c.segments.count == 2)
    #expect(c.segments[0].samples.allSatisfy { abs($0.speed - 5) < 1e-4 })
    #expect(c.segments[1].samples.allSatisfy { abs($0.speed - 10) < 1e-4 })
    #expect(abs(c.peak - 10) < 1e-4)
    #expect(c.keys.map(\.seconds) == [0, 2, 3])
    // A key sits at its outgoing speed, the last key at its arriving speed.
    #expect(abs(c.keys[0].speed - 5) < 1e-4 && abs(c.keys[1].speed - 10) < 1e-4 && abs(c.keys[2].speed - 10) < 1e-4)
}

@Test func speedOverlayHandlesOfEasedKeys() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    var b = kfKey(2, 10, .bezier); b.inHandle = EaseHandle(dx: 0.5, dy: 0.5)
    let c = PropertyTrack.scalar(KeyframeTrack(keys: [a, b])).speedOverlay()!
    #expect(c.handles.count == 2)
    let out = c.handles.first { $0.keyID == a.id }!
    #expect(out.side == .outgoing && abs(out.influence - 1.0 / 3) < 1e-9 && abs(out.speed) < 1e-9)
    #expect(out.span == 10 && out.segmentSeconds == 2)
    let inn = c.handles.first { $0.keyID == b.id }!
    #expect(inn.side == .incoming && abs(inn.speed - 5) < 1e-9)    // slope 1 = the average speed
}

@Test func speedOverlayHoldHasNoHandlesAndZeroSpeed() {
    let c = PropertyTrack.scalar(KeyframeTrack(keys: [kfKey(0, 0, .hold), kfKey(2, 10)])).speedOverlay()!
    #expect(c.handles.isEmpty)
    #expect(c.keys[0].speed == 0)
    #expect(c.peak > 0)     // never zero: the curve still has a height to map to
}

@Test func speedOverlayVectorUsesPathSpeed() {
    let k0 = Keyframe(time: kfT(0), value: Vec2(0, 0)), k1 = Keyframe(time: kfT(1), value: Vec2(3, 4))
    let c = PropertyTrack.vector(KeyframeTrack(keys: [k0, k1])).speedOverlay(samples: 3)!
    #expect(c.segments[0].samples.allSatisfy { abs($0.speed - 5) < 1e-4 })
    #expect(c.handles.allSatisfy { abs($0.span - 5) < 1e-9 })
}

@Test func speedOverlayColourAndSingleKeyHaveNoCurve() {
    #expect(PropertyTrack.color(KeyframeTrack()).speedOverlay() == nil)
    let one = PropertyTrack.scalar(KeyframeTrack(keys: [kfKey(0, 3)])).speedOverlay()!
    #expect(one.segments.isEmpty && one.keys.count == 1)
}

@Test func easeHandleFromDirectedSpeed() {
    // Average speed 5/s; asking for 10/s at influence 0.25 gives slope 2.
    let h = EaseHandle(directedSpeed: 10, influence: 0.25, span: 10, seconds: 2)
    #expect(abs(h.dx - 0.25) < 1e-12 && abs(h.dy - 0.5) < 1e-12)
    #expect(EaseHandle(directedSpeed: 0, influence: 0.4, span: 10, seconds: 2) == EaseHandle(dx: 0.4, dy: 0))
    // Influence is kept inside 0.01...1; a segment without distance gets a flat handle.
    #expect(EaseHandle(directedSpeed: 3, influence: 2, span: 10, seconds: 2).dx == 1)
    #expect(EaseHandle(directedSpeed: 3, influence: 0, span: 10, seconds: 2).dx == 0.01)
    #expect(EaseHandle(directedSpeed: 3, influence: 0.3, span: 0, seconds: 2).dy == 0)
}

@Test func summarySetHandleOnSeveralProperties() {
    let o0 = kfKey(0, 0), o1 = kfKey(2, 1)
    let p0 = Keyframe(time: kfT(0), value: Vec2(0, 0)), p1 = Keyframe(time: kfT(4), value: Vec2(10, 0))
    var s = KeyframeSummary(tracks: [op: .scalar(KeyframeTrack(keys: [o0, o1])),
                                     pos: .vector(KeyframeTrack(keys: [p0, p1]))])
    let smooth = EaseHandle(dx: 1.0 / 3, dy: 0)
    let n = s.setHandle(smooth, side: .outgoing, on: [SummaryMember(property: op, keyID: o0.id),
                                                       SummaryMember(property: pos, keyID: p0.id),
                                                       SummaryMember(property: pos, keyID: p1.id)])  // last key: no out side
    #expect(n == 2)
    guard case .scalar(let ot)? = s.tracks[op], case .vector(let pt)? = s.tracks[pos] else { Issue.record("tracks"); return }
    #expect(ot.keys[0].outHandle == smooth && ot.keys[0].interpolation == .bezier)
    #expect(pt.keys[0].outHandle == smooth && pt.keys[0].interpolation == .bezier)
    #expect(pt.keys[1].outHandle == .linear && pt.keys[1].interpolation == .linear)
}

@Test func summarySetHandleIncomingSkipsHoldSegments() {
    let a = kfKey(0, 0, .hold), b = kfKey(2, 5), c = kfKey(4, 9)
    var s = KeyframeSummary(tracks: [op: .scalar(KeyframeTrack(keys: [a, b, c]))])
    let h = EaseHandle(dx: 0.5, dy: 0)
    let n = s.setHandle(h, side: .incoming, on: [SummaryMember(property: op, keyID: b.id),   // segment a-b is hold
                                                  SummaryMember(property: op, keyID: c.id),
                                                  SummaryMember(property: op, keyID: a.id)])  // first key: no in side
    #expect(n == 1)
    guard case .scalar(let t)? = s.tracks[op] else { Issue.record("track"); return }
    #expect(t.keys[1].inHandle == .linear)
    #expect(t.keys[2].inHandle == h && t.keys[2].interpolation == .bezier)
}
