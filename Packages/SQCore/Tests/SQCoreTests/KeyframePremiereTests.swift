import Foundation
import Testing
@testable import SQCore

private let opacity = PropertyID("opacity")

@Test func choiceCurvesMatchPremiereNames() {
    #expect(KeyInterpolationChoice.allCases.map(\.title) == ["Steady", "Bezier", "Auto Bezier", "Continuous Bezier", "Smooth In", "Smooth Out", "Smooth", "Hold", "Hold Ahead"])
    #expect(KeyInterpolationChoice.easeIn.side == .in)
    #expect(KeyInterpolationChoice.easeOut.side == .out)
    #expect(KeyInterpolationChoice.hold.side == .out)
    #expect(KeyInterpolationChoice.easyEase.side == .both)
}

@Test func easeInTouchesOnlyTheInHandle() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var tr = PropertyTrack.scalar(KeyframeTrack(keys: ks))
    tr.apply(KeyInterpolationChoice.easeIn.curve, to: [ks[1].id], side: .in)
    guard case .scalar(let t) = tr else { return }
    #expect(t.keys[1].inHandle.dy == 0)
    #expect(t.keys[1].outHandle == .linear)
    #expect(t.keys[0] == ks[0] && t.keys[2] == ks[2])
}

@Test func bezierChoiceStaysVisuallyLinear() {
    let ks = [kfKey(0, 0), kfKey(2, 10)]
    var tr = KeyframeTrack(keys: ks)
    tr.apply(KeyInterpolationChoice.bezier.curve, to: Set(ks.map(\.id)))
    #expect(abs(tr.value(at: kfT(1))! - 5) < 1e-6)
}

@Test func moveDuplicatingLeavesCopiesBehind() {
    let ks = [kfKey(1, 1), kfKey(3, 3)]
    var s = KeyframeSummary(tracks: [opacity: .scalar(KeyframeTrack(keys: ks))])
    let applied = s.moveDuplicating([SummaryMember(property: opacity, keyID: ks[0].id)], by: kfT(1), frame: Time(1, 30))
    #expect(applied == kfT(1))
    guard case .scalar(let t) = s.tracks[opacity] else { return }
    #expect(t.keys.map(\.time) == [kfT(1), kfT(2), kfT(3)])
    #expect(t.key(id: ks[0].id)?.time == kfT(2))         // the original id moved
    #expect(t.keys[0].id != ks[0].id)                     // a new key stays at 1
    #expect(t.keys[0].value == 1)
}

@Test func moveDuplicatingOntoOccupiedTimeSnapsOneFrameAndKeepsEveryKey() {
    let ks = [kfKey(1, 1), kfKey(3, 3)]
    let f = Time(1, 30)
    var s = KeyframeSummary(tracks: [opacity: .scalar(KeyframeTrack(keys: ks))])
    let applied = s.moveDuplicating([SummaryMember(property: opacity, keyID: ks[0].id)], by: kfT(2), frame: f)
    #expect(applied == kfT(2) + f)
    guard case .scalar(let t) = s.tracks[opacity] else { return }
    #expect(t.keys.map(\.time) == [kfT(1), kfT(3), kfT(3) + f])
    #expect(t.keys[1].value == 3)                        // the key that was there is still there
    #expect(t.keys[2].id == ks[0].id)                    // the moved original
}

@Test func retargetSinglePropertyClipboard() {
    let ks = [kfKey(1, 0.5)]
    let clip = KeyframeClipboard.copy(from: [opacity: .scalar(KeyframeTrack(keys: ks))], selection: [opacity: [ks[0].id]])!
    let r = clip.retargeted(to: PropertyID("rotation"), isVector: false)
    #expect(r?.tracks.keys.first == PropertyID("rotation"))
    #expect(clip.retargeted(to: PropertyID("position"), isVector: true) == nil)   // other value type
}

// MARK: - Auto / Continuous Bezier, smooth spatial paths (KEY-04, KEY-17)

private func posKey(_ s: Int64, _ x: Double, _ y: Double) -> Keyframe<Vec2> { Keyframe(time: kfT(s), value: Vec2(x, y)) }

@Test func autoBezierMakesSmoothPositionPath() {
    let ks = [posKey(0, 0, 0), posKey(2, 100, 100), posKey(4, 200, 0)]
    var tr = PropertyTrack.vector(KeyframeTrack(keys: ks))
    tr.apply(.autoBezier, to: [ks[1].id])
    guard case .vector(let t) = tr else { return }
    let mid = t.keys[1]
    #expect(mid.interpolation == .bezier)
    #expect(mid.outTangent != .zero && mid.inTangent != .zero)
    // continuous through the key: tangents are opposite
    #expect(abs(mid.inTangent.x + mid.outTangent.x) < 1e-9 && abs(mid.inTangent.y + mid.outTangent.y) < 1e-9)
    // path no longer a straight line between key 0 and 1: the midpoint of the segment bulges off the chord
    let p = t.value(at: kfT(1))!
    #expect(abs(p.x - p.y) > 1)
    #expect(t.value(at: kfT(2)) == Vec2(100, 100))
}

@Test func autoBezierOnScalarKeepsStraightSpeed() {
    let ks = [kfKey(0, 0), kfKey(2, 10)]
    var pt = PropertyTrack.scalar(KeyframeTrack(keys: ks))
    pt.apply(.autoBezier, to: Set(ks.map(\.id)))
    guard case .scalar(let tr) = pt else { return }
    #expect(abs(tr.value(at: kfT(1))! - 5) < 1e-6)
}

@Test func continuousBezierEasesTime() {
    let ks = [kfKey(0, 0), kfKey(2, 10)]
    var pt = PropertyTrack.scalar(KeyframeTrack(keys: ks))
    pt.apply(.continuousBezier, to: Set(ks.map(\.id)))
    guard case .scalar(let tr) = pt else { return }
    #expect(tr.keys[0].outHandle.dy == 0 && tr.keys[1].inHandle.dy == 0)
    #expect(KeyInterpolationChoice.autoBezier.side == .both && KeyInterpolationChoice.continuousBezier.side == .both)
}

@Test func summaryApplyAutoBezierSmoothsPosition() {
    let ks = [posKey(0, 0, 0), posKey(2, 100, 100), posKey(4, 200, 0)]
    let p = PropertyID("position")
    var s = KeyframeSummary(tracks: [p: .vector(KeyframeTrack(keys: ks))])
    s.apply(.autoBezier, to: [SummaryMember(property: p, keyID: ks[1].id)])
    guard case .vector(let t) = s.tracks[p] else { return }
    #expect(t.keys[1].outTangent != .zero)
}

@Test func insertSmoothGivesNewMiddleKeyTangents() {
    var t = KeyframeTrack(keys: [posKey(0, 0, 0), posKey(4, 200, 0)])
    t.insertSmooth(posKey(2, 100, 100))
    #expect(t.keys[1].outTangent != .zero && t.keys[1].inTangent != .zero)
    #expect(t.keys[0].outTangent == .zero)          // endpoints stay straight on their outer side
}

@Test func insertSmoothKeepsHandPlacedNeighbourTangents() {
    var a = posKey(0, 0, 0); a.outTangent = Vec2(7, 7)
    var t = KeyframeTrack(keys: [a, posKey(4, 200, 0)])
    t.insertSmooth(posKey(2, 100, 100))
    #expect(t.keys[0].outTangent == Vec2(7, 7))
}

@Test func firstAndSecondKeyStayStraight() {
    var t = KeyframeTrack<Vec2>()
    t.insertSmooth(posKey(0, 0, 0)); t.insertSmooth(posKey(2, 100, 100))
    #expect(t.keys.allSatisfy { $0.inTangent == .zero && $0.outTangent == .zero })
}

// MARK: - Spatial Interpolation menu (Linear = straight path)

@Test func straightenSpatialZeroesTangentsOfSelectedVectorKeysOnly() {
    let ks = [posKey(0, 0, 0), posKey(2, 100, 100), posKey(4, 200, 0), posKey(6, 300, 100)]
    let p = PropertyID("position"), o = PropertyID("opacity")
    var t = KeyframeTrack(keys: ks)
    t.smoothTangents(Set(ks.map(\.id)))
    var s = KeyframeSummary(tracks: [p: .vector(t), o: .scalar(KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 1)]))])
    s.straightenSpatial([SummaryMember(property: p, keyID: ks[1].id), SummaryMember(property: o, keyID: UUID())])
    guard case .vector(let out) = s.tracks[p] else { return }
    #expect(out.keys[1].inTangent == .zero && out.keys[1].outTangent == .zero)
    #expect(out.keys[2].outTangent != .zero)          // not selected: untouched
}
