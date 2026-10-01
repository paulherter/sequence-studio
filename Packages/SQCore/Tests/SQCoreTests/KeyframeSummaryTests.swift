import Foundation
import Testing
@testable import SQCore

private let op = PropertyID("opacity"), pos = PropertyID("position"), rot = PropertyID("rotation")

private struct Fixture {
    var summary: KeyframeSummary
    let o0, o1, p0, r0: UUID
    init() {
        let o0k = kfKey(0, 0), o1k = kfKey(4, 1), r0k = kfKey(1, 5)
        let p0k = Keyframe(time: kfT(0), value: Vec2(1, 1))
        o0 = o0k.id; o1 = o1k.id; p0 = p0k.id; r0 = r0k.id
        summary = KeyframeSummary(tracks: [op: .scalar(KeyframeTrack(keys: [o0k, o1k])),
                                           pos: .vector(KeyframeTrack(keys: [p0k])),
                                           rot: .scalar(KeyframeTrack(keys: [r0k]))])
    }
}

@Test func kfSummaryGroupsByTime() {
    let f = Fixture()
    let g = f.summary.groups()
    #expect(g.map(\.time) == [kfT(0), kfT(1), kfT(4)])
    #expect(g[0].members == [SummaryMember(property: op, keyID: f.o0), SummaryMember(property: pos, keyID: f.p0)])
    #expect(f.summary.groups(of: [rot]).count == 1)
    #expect(f.summary.members(at: kfT(0)).count == 2)
    #expect(f.summary.members(at: kfT(0), properties: [op]).count == 1)
}

@Test func kfSummaryMoveKeepsGroupAligned() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    let applied = f.summary.move(sel, by: kfT(2))
    #expect(applied == kfT(2))
    guard case .scalar(let o) = f.summary.tracks[op], case .vector(let p) = f.summary.tracks[pos] else { return }
    #expect(o.keys.map(\.time) == [kfT(2), kfT(4)])
    #expect(p.keys.map(\.time) == [kfT(2)])
}

@Test func kfSummaryMoveClampsAtNonSelectedNeighbour() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    // opacity has a neighbour at 4: moving by 10 clamps so the group lands on 4 (collision: moved wins).
    let applied = f.summary.move(sel, by: kfT(10))
    #expect(applied == kfT(4))
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.count == 1)
    #expect(o.keys[0].id == f.o0 && o.keys[0].time == kfT(4))
}

@Test func kfSummaryMoveNegativeClamps() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(4))
    let applied = f.summary.move(sel, by: kfT(-10))
    #expect(applied == kfT(-4))  // lands on o0 at 0: moved wins
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.map(\.id) == [f.o1])
}

@Test func kfSummaryEaseActsOnAllMembers() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    f.summary.apply(.easeInOut, to: sel)
    guard case .scalar(let o) = f.summary.tracks[op], case .vector(let p) = f.summary.tracks[pos] else { return }
    #expect(o.keys[0].outHandle == EasingCurve.easeInOut.outHandle)
    #expect(p.keys[0].interpolation == .bezier)
    f.summary.toggleHold(sel)
    guard case .scalar(let o2) = f.summary.tracks[op] else { return }
    #expect(o2.keys[0].interpolation == .hold)
}

@Test func kfSummaryMoveEmptyAndCodable() throws {
    var f = Fixture()
    let r8 = f.summary.move([], by: kfT(3))
    #expect(r8 == .zero)
    let back = try JSONDecoder().decode(KeyframeSummary.self, from: JSONEncoder().encode(f.summary))
    #expect(back == f.summary)
}
