import Foundation
import Testing
@testable import SQCore

private let prop = PropertyID("scale")

@Test func springBakeReplacesSegmentWithLinearKeys() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 0.3, dy: 0)
    var b = kfKey(2, 100); b.inHandle = EaseHandle(dx: 0.4, dy: 0)
    let c = kfKey(4, 50)
    var s = KeyframeSummary(tracks: [prop: .scalar(KeyframeTrack(keys: [a, b, c]))])
    let sel = EaseSelection(summary: s, members: [SummaryMember(property: prop, keyID: a.id), SummaryMember(property: prop, keyID: b.id)])
    let n = sel.bake(SpringEasing(bounce: 0.7), in: &s)
    #expect(n == 1)
    guard case .scalar(let t)? = s.tracks[prop] else { Issue.record("track"); return }
    #expect(t.keys.count > 3)
    #expect(t.keys.first?.id == a.id && t.key(id: b.id) != nil && t.keys.last?.id == c.id)
    #expect(t.keys.allSatisfy { $0.interpolation == .linear && $0.outHandle == .linear && $0.inHandle == .linear })
    #expect(t.value(at: kfT(2)) == 100)
    #expect(t.keys.contains { $0.value > 100 })     // bouncy: overshoots
    #expect(t.value(at: kfT(4)) == 50)              // next segment untouched
}

@Test func springBakeLeavesOriginalSummaryIntact() {
    let a = kfKey(0, 0), b = kfKey(1, 10)
    let s0 = KeyframeSummary(tracks: [prop: .scalar(KeyframeTrack(keys: [a, b]))])
    var s1 = s0
    let sel = EaseSelection(summary: s0, members: [SummaryMember(property: prop, keyID: a.id)])
    #expect(sel.bake(SpringEasing(bounce: 0), in: &s1) == 1)
    #expect(s1 != s0)
    guard case .scalar(let t0)? = s0.tracks[prop] else { return }
    #expect(t0.keys.count == 2)
}
