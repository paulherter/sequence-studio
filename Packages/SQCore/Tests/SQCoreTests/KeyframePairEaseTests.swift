import Foundation
import Testing
@testable import SQCore

private let flat = EaseHandle(dx: 1.0 / 3, dy: 0)

@Test func pairEaseInOutSetsBothSidesOfSegment() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var t = KeyframeTrack(keys: ks)
    let n = t.applyPairEase(.inOut, to: [ks[0].id, ks[1].id])
    #expect(n == 1)
    #expect(t.keys[0].interpolation == .bezier)
    #expect(t.keys[0].outHandle == flat)
    #expect(t.keys[1].inHandle == flat)
    #expect(t.keys[1].outHandle == .linear)   // far side of the pair untouched
    #expect(t.keys[2] == ks[2])
}

@Test func pairEaseInEasesArrivalOnly() {
    let ks = [kfKey(0, 0), kfKey(2, 5)]
    var t = KeyframeTrack(keys: ks)
    t.applyPairEase(.in, to: Set(ks.map(\.id)))
    #expect(t.keys[0].outHandle == .linear)
    #expect(t.keys[1].inHandle == flat)
}

@Test func pairEaseOutEasesDepartureOnly() {
    let ks = [kfKey(0, 0), kfKey(2, 5)]
    var t = KeyframeTrack(keys: ks)
    t.applyPairEase(.out, to: Set(ks.map(\.id)))
    #expect(t.keys[0].outHandle == flat)
    #expect(t.keys[1].inHandle == .linear)
}

@Test func pairEaseIgnoresNonAdjacentSelection() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var t = KeyframeTrack(keys: ks)
    #expect(t.applyPairEase(.inOut, to: [ks[0].id, ks[2].id]) == 0)
    #expect(t.keys == ks)
}

@Test func pairEaseChainOfThreeEasesBothSegments() {
    let ks = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    var t = KeyframeTrack(keys: ks)
    #expect(t.applyPairEase(.inOut, to: Set(ks.map(\.id))) == 2)
    #expect(t.keys[1].inHandle == flat && t.keys[1].outHandle == flat)
}

@Test func summaryPairEaseCoversEachProperty() {
    let ks = [kfKey(0, 0), kfKey(2, 5)]
    var s = KeyframeSummary(tracks: [PropertyID("opacity"): .scalar(KeyframeTrack(keys: ks))])
    let sel = Set(ks.map { SummaryMember(property: PropertyID("opacity"), keyID: $0.id) })
    #expect(s.hasAdjacentPair(sel))
    #expect(s.applyPairEase(.inOut, to: sel) == 1)
    guard case .scalar(let t)? = s.tracks[PropertyID("opacity")] else { return }
    #expect(t.keys[0].outHandle == flat && t.keys[1].inHandle == flat)
}

@Test func pairEaseInKeepsExistingOutHandle() {
    var ks = [kfKey(0, 0), kfKey(2, 5)]
    let custom = EaseHandle(dx: 0.5, dy: 0.2)
    ks[0].interpolation = .bezier; ks[0].outHandle = custom
    var t = KeyframeTrack(keys: ks)
    t.applyPairEase(.in, to: Set(ks.map(\.id)))
    #expect(t.keys[0].outHandle == custom && t.keys[1].inHandle == flat)
}

@Test func pairEaseOutKeepsExistingInHandle() {
    var ks = [kfKey(0, 0), kfKey(2, 5)]
    let custom = EaseHandle(dx: 0.5, dy: 0.2)
    ks[1].inHandle = custom
    var t = KeyframeTrack(keys: ks)
    t.applyPairEase(.out, to: Set(ks.map(\.id)))
    #expect(t.keys[1].inHandle == custom && t.keys[0].outHandle == flat)
}

@Test func pairEaseKeepsHold() {
    let ks = [kfKey(0, 0, .hold), kfKey(2, 5)]
    var t = KeyframeTrack(keys: ks)
    t.applyPairEase(.inOut, to: Set(ks.map(\.id)))
    #expect(t.keys[0].interpolation == .hold)
}

@Test func summaryChoiceMixesPairAndSingleKeysPerProperty() {
    let a = [kfKey(0, 0), kfKey(2, 5)]
    let b = [kfKey(0, 0), kfKey(2, 5), kfKey(4, 9)]
    let pa = PropertyID("opacity"), pb = PropertyID("scale")
    var s = KeyframeSummary(tracks: [pa: .scalar(KeyframeTrack(keys: a)), pb: .scalar(KeyframeTrack(keys: b))])
    let sel: Set<SummaryMember> = [SummaryMember(property: pa, keyID: a[0].id), SummaryMember(property: pa, keyID: a[1].id),
                                   SummaryMember(property: pb, keyID: b[1].id)]
    s.apply(.easyEase, to: sel)
    guard case .scalar(let ta)? = s.tracks[pa], case .scalar(let tb)? = s.tracks[pb] else { return }
    #expect(ta.keys[0].outHandle == flat && ta.keys[1].inHandle == flat)
    #expect(tb.keys[1].inHandle == flat && tb.keys[1].outHandle == flat)   // single key: both its sides
    #expect(tb.keys[0] == b[0] && tb.keys[2] == b[2])
}
