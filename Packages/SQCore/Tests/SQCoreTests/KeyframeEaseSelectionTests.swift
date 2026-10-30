import Foundation
import Testing
@testable import SQCore

private func vKey(_ s: Int64, _ v: Double, _ i: Interpolation = .linear) -> Keyframe<Vec2> {
    Keyframe(time: kfT(s), value: Vec2(v, v), interpolation: i)
}

/// Position (vector) with keys at 0/2/4 and Scale (scalar) with keys at 0/2/4.
private func fixture() -> (KeyframeSummary, pos: [Keyframe<Vec2>], scale: [Keyframe<Double>]) {
    let pos = [vKey(0, 0), vKey(2, 50), vKey(4, 100)]
    let scale = [kfKey(0, 100), kfKey(2, 120), kfKey(4, 80)]
    let s = KeyframeSummary(tracks: ["position": .vector(KeyframeTrack(keys: pos)),
                                     "scale": .scalar(KeyframeTrack(keys: scale))])
    return (s, pos, scale)
}

private func m(_ p: PropertyID, _ id: UUID) -> SummaryMember { SummaryMember(property: p, keyID: id) }

private let snappy = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.9), in: EaseHandle(dx: 0.5, dy: -0.2))

// MARK: Selection

@Test func easeSelectionUsesFullySelectedSegmentsAcrossProperties() {
    let (s, pos, scale) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[0].id), m("position", pos[1].id),
                                                  m("scale", scale[0].id), m("scale", scale[1].id)])
    #expect(Set(sel.segments) == [EaseSegment(property: "position", from: pos[0].id, to: pos[1].id),
                                  EaseSegment(property: "scale", from: scale[0].id, to: scale[1].id)])
}

@Test func easeSelectionThreeKeysGivesTwoSegments() {
    let (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: Set(pos.map { m("position", $0.id) }))
    #expect(sel.segments.count == 2)
}

@Test func easeSelectionLoneKeyUsesOutgoingSegment() {
    let (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[1].id)])
    #expect(sel.segments == [EaseSegment(property: "position", from: pos[1].id, to: pos[2].id, side: .out)])
}

@Test func easeSelectionLoneLastKeyUsesIncomingSegment() {
    let (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[2].id)])
    #expect(sel.segments == [EaseSegment(property: "position", from: pos[1].id, to: pos[2].id, side: .in)])
}

// MARK: Review fixes: handles count whatever the interpolation; unselected keys stay untouched

@Test func easeReadingSeesPremiereEaseInOnLinearKey() {
    // Premiere "Ease In" on B: only B.inHandle changes, A stays .linear. Playback eases, so the reading must too.
    let a = kfKey(0, 0)
    var b = kfKey(2, 5); b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    let s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [a, b]))])
    let r = EaseSelection(summary: s, members: [m("opacity", a.id), m("opacity", b.id)]).reading(in: s)
    #expect(r == .common(EaseShape(interpolation: .bezier, out: .linear, in: EaseHandle(dx: 1.0 / 3, dy: 0))))
}

@Test func easeReadingMixedWhenOnlyHandlesDifferOnLinearKeys() {
    let a = kfKey(0, 0), c = kfKey(4, 0)
    var b = kfKey(2, 5); b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    let s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [a, b, c]))])
    let r = EaseSelection(summary: s, members: [m("opacity", a.id), m("opacity", b.id), m("opacity", c.id)]).reading(in: s)
    guard case .mixed(let shapes) = r else { Issue.record("expected mixed, got \(r)"); return }
    #expect(shapes.count == 2)
}

@Test func easeLoneLastKeyWritesOnlyItsOwnInHandle() {
    var (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[2].id)])
    #expect(sel.apply(snappy, to: &s) == 1)
    guard case .vector(let t)? = s.tracks["position"] else { Issue.record("track"); return }
    #expect(t.keys[1] == pos[1])                       // unselected left key untouched
    #expect(t.keys[2].inHandle == snappy.in)
}

@Test func easeLoneKeyWritesOnlyItsOwnOutSide() {
    var (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[1].id)])
    sel.apply(snappy, to: &s)
    guard case .vector(let t)? = s.tracks["position"] else { Issue.record("track"); return }
    #expect(t.keys[2] == pos[2])                       // unselected right key untouched
    #expect(t.keys[1].outHandle == snappy.out && t.keys[1].interpolation == .bezier)
    #expect(t.keys[1].inHandle == pos[1].inHandle)
}

@Test func easeLoneLastKeyAfterUnselectedHoldIsSkipped() {
    let a = kfKey(0, 0), b = kfKey(2, 5, .hold), c = kfKey(4, 9)
    var s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [a, b, c]))])
    let before = s
    let sel = EaseSelection(summary: s, members: [m("opacity", c.id)])
    #expect(sel.isEmpty)
    #expect(sel.apply(snappy, to: &s) == 0)
    #expect(s == before)
}

@Test func easeSelectionPairWinsOverLoneKeyInSameProperty() {
    let (s, pos, _) = fixture()
    // keys 0 and 1 are a pair; nothing else in this property is a lone key, so only the pair segment counts.
    let sel = EaseSelection(summary: s, members: [m("position", pos[0].id), m("position", pos[1].id)])
    #expect(sel.segments == [EaseSegment(property: "position", from: pos[0].id, to: pos[1].id)])
}

@Test func easeSelectionEmptyForSingleKeyTrackOrNoSelection() {
    let k = kfKey(0, 1)
    let s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [k]))])
    #expect(EaseSelection(summary: s, members: [m("opacity", k.id)]).isEmpty)
    #expect(EaseSelection(summary: s, members: []).isEmpty)
    #expect(EaseSelection(summary: s, members: []).reading(in: s) == .empty)
}

// MARK: Reading

@Test func easeReadingCommonWhenAllSegmentsLinear() {
    let (s, pos, scale) = fixture()
    let sel = EaseSelection(summary: s, members: Set(pos.map { m("position", $0.id) } + scale.map { m("scale", $0.id) }))
    #expect(sel.reading(in: s) == .common(.linear))
}

@Test func easeReadingMixedListsDistinctShapes() {
    var (s, pos, scale) = fixture()
    let all = Set(pos.map { m("position", $0.id) } + scale.map { m("scale", $0.id) })
    let first = EaseSelection(summary: s, members: [m("scale", scale[0].id), m("scale", scale[1].id)])
    first.apply(snappy, to: &s)
    let reading = EaseSelection(summary: s, members: all).reading(in: s)
    guard case .mixed(let shapes) = reading else { Issue.record("expected mixed, got \(reading)"); return }
    #expect(shapes.count == 2)
    #expect(shapes.contains(.linear))
    #expect(shapes.contains { $0.isApproximatelyEqual(to: snappy) })
}

@Test func easeReadingTreatsBezierWithLinearHandlesAsLinear() {
    let a = kfKey(0, 0, .bezier), b = kfKey(2, 5)
    let s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [a, b]))])
    #expect(EaseSelection(summary: s, members: [m("opacity", a.id), m("opacity", b.id)]).reading(in: s) == .common(.linear))
}

@Test func easeReadingHoldIgnoresStoredHandles() {
    var a = kfKey(0, 0, .hold); a.outHandle = EaseHandle(dx: 0.1, dy: 0.7)
    let b = kfKey(2, 5)
    let s = KeyframeSummary(tracks: ["opacity": .scalar(KeyframeTrack(keys: [a, b]))])
    #expect(EaseSelection(summary: s, members: [m("opacity", a.id), m("opacity", b.id)]).reading(in: s) == .common(.hold))
}

// MARK: Apply

@Test func easeApplyGivesIdenticalHandlesOnPositionAndScale() {
    var (s, pos, scale) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[0].id), m("position", pos[1].id),
                                                  m("scale", scale[0].id), m("scale", scale[1].id)])
    let n = sel.apply(snappy, to: &s)
    #expect(n == 2)
    guard case .vector(let pt)? = s.tracks["position"], case .scalar(let st)? = s.tracks["scale"] else { Issue.record("tracks"); return }
    for (a, b) in [(pt.keys[0].outHandle, st.keys[0].outHandle), (pt.keys[1].inHandle, st.keys[1].inHandle)] { #expect(a == b) }
    #expect(pt.keys[0].outHandle == snappy.out)
    #expect(pt.keys[1].inHandle == snappy.in)
    #expect(pt.keys[0].interpolation == .bezier && st.keys[0].interpolation == .bezier)
    // Outside the segments nothing changes.
    #expect(pt.keys[1].outHandle == .linear && pt.keys[1].interpolation == .linear)
    #expect(pt.keys[2] == pos[2] && st.keys[2] == scale[2])
    #expect(sel.reading(in: s) == .common(snappy))
}

@Test func easeApplyKeepsOvershootAndClampsTimeInfluence() {
    var (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[0].id), m("position", pos[1].id)])
    sel.apply(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 1.4, dy: 1.6), in: EaseHandle(dx: -0.2, dy: -0.5)), to: &s)
    guard case .vector(let pt)? = s.tracks["position"] else { Issue.record("track"); return }
    #expect(pt.keys[0].outHandle == EaseHandle(dx: 1, dy: 1.6))
    #expect(pt.keys[1].inHandle == EaseHandle(dx: 0, dy: -0.5))
}

@Test func easeApplyLinearAndHold() {
    var (s, pos, _) = fixture()
    let sel = EaseSelection(summary: s, members: [m("position", pos[0].id), m("position", pos[1].id)])
    sel.apply(snappy, to: &s)
    sel.apply(.hold, to: &s)
    guard case .vector(let held)? = s.tracks["position"] else { Issue.record("track"); return }
    #expect(held.keys[0].interpolation == .hold)
    #expect(held.keys[0].outHandle == snappy.out)       // hold keeps the stored handles, like toggleHold
    sel.apply(.linear, to: &s)
    guard case .vector(let lin)? = s.tracks["position"] else { Issue.record("track"); return }
    #expect(lin.keys[0].interpolation == .linear)
    #expect(lin.keys[0].outHandle == .linear && lin.keys[1].inHandle == .linear)
}

@Test func easeApplyOnEmptySelectionChangesNothing() {
    var (s, _, _) = fixture()
    let before = s
    #expect(EaseSelection(summary: s, members: []).apply(snappy, to: &s) == 0)
    #expect(s == before)
}

// MARK: Curves and presets

@Test func easingCurveShapeRoundTrip() {
    let c = EasingCurve(shape: snappy, name: "Snappy")
    #expect(c.shape == snappy)
    #expect(EasingCurve.easeInOut.shape == EaseShape(interpolation: .bezier, out: EaseHandle(dx: 1.0 / 3, dy: 0),
                                                     in: EaseHandle(dx: 1.0 / 3, dy: 0)))
    #expect(EasingCurve.linear.shape == .linear)
    #expect(EasingCurve.hold.shape == .hold)
}

@Test func easingCurvePresetPayloadRoundTrip() throws {
    let c = EasingCurve(shape: snappy, name: "Snappy")
    let back = try EasingCurve(presetPayload: c.presetPayload(), name: "Renamed", id: c.id)
    #expect(back.shape == snappy)
    #expect(back.name == "Renamed")
    #expect(back.id == c.id)
    #expect(throws: (any Error).self) { try EasingCurve(presetPayload: Data("x".utf8), name: "n", id: UUID()) }
}

// MARK: Merge with v24 effect colors: color tracks ease, stepped (checkbox / choice) tracks are skipped

@Test func easeSelectionWritesColorTracks() {
    let ck = [Keyframe(time: kfT(0), value: EffectColor.black), Keyframe(time: kfT(2), value: EffectColor.white)]
    var s = KeyframeSummary(tracks: ["shadowColor": .color(KeyframeTrack(keys: ck))])
    let sel = EaseSelection(summary: s, members: Set(ck.map { m("shadowColor", $0.id) }))
    #expect(sel.segments.count == 1)
    #expect(sel.apply(snappy, to: &s) == 1)
    #expect(sel.reading(in: s) == .common(snappy.effective))
}

@Test func easeSelectionSkipsSteppedTracks() {
    let (base, pos, _) = fixture()
    let onOff = [kfKey(0, 0, .hold), kfKey(2, 1, .hold)]
    var s = base
    s.tracks["shadowOnly"] = .scalar(KeyframeTrack(keys: onOff))
    let members: Set<SummaryMember> = [m("position", pos[0].id), m("position", pos[1].id),
                                       m("shadowOnly", onOff[0].id), m("shadowOnly", onOff[1].id)]
    let sel = EaseSelection(summary: s, members: members, stepped: ["shadowOnly"])
    #expect(sel.segments == [EaseSegment(property: "position", from: pos[0].id, to: pos[1].id)])
    #expect(sel.apply(snappy, to: &s) == 1)
    #expect(s.tracks["shadowOnly"]?.interpolation(of: onOff[0].id) == .hold)
}
