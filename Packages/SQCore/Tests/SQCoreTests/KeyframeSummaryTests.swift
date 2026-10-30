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
    let applied = f.summary.move(sel, by: kfT(2), frame: frame)
    #expect(applied == kfT(2))
    guard case .scalar(let o) = f.summary.tracks[op], case .vector(let p) = f.summary.tracks[pos] else { return }
    #expect(o.keys.map(\.time) == [kfT(2), kfT(4)])
    #expect(p.keys.map(\.time) == [kfT(2)])
}

private let frame = Time(1, 30)

@Test func kfSummaryMovePassesNonSelectedNeighboursAndKeepsBothKeys() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    // opacity has a neighbor at 4: the group moves past it to 10, nobody is replaced.
    let applied = f.summary.move(sel, by: kfT(10), frame: frame)
    #expect(applied == kfT(10))
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.map(\.id) == [f.o1, f.o0])               // re-sorted: the neighbor is now first
    #expect(o.keys.map(\.time) == [kfT(4), kfT(10)])
}

@Test func kfSummaryMoveBackwardsPastANeighbour() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(4))
    let applied = f.summary.move(sel, by: kfT(-6), frame: frame)
    #expect(applied == kfT(-6))
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.map(\.id) == [f.o1, f.o0])
    #expect(o.keys.map(\.time) == [kfT(-2), kfT(0)])
}

@Test func kfSummaryMoveOntoTheSameTimeSnapsOneFrameInsteadOfDeleting() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    let applied = f.summary.move(sel, by: kfT(4), frame: frame)        // would land exactly on the key at 4
    #expect(applied == kfT(4) + frame)
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.count == 2)
    #expect(o.keys.map(\.time) == [kfT(4), kfT(4) + frame])
    var g = Fixture()
    let down = g.summary.move(g.summary.members(at: kfT(4)), by: kfT(-4), frame: frame)   // downwards: one frame before
    #expect(down == kfT(-4) - frame)
    guard case .scalar(let o2) = g.summary.tracks[op] else { return }
    #expect(o2.keys.count == 2 && o2.keys.map(\.time).sorted() == o2.keys.map(\.time).sorted())
    #expect(o2.keys.map(\.time) == [kfT(-4) + kfT(4) - frame, kfT(0)])
}

@Test func kfSummaryMoveRespectsDeltaLimits() {
    var f = Fixture()
    let sel = f.summary.members(at: kfT(0))
    let applied = f.summary.move(sel, by: kfT(100), frame: frame, limits: kfT(-5) ... kfT(7))
    #expect(applied == kfT(7))
    var g = Fixture()
    // Landing on 4 would nudge to 4 + frame, which is outside the limits: the other direction is tried.
    let nudged = g.summary.move(g.summary.members(at: kfT(0)), by: kfT(4), frame: frame, limits: kfT(-5) ... kfT(4))
    #expect(nudged == kfT(4) - frame)
}

@Test func kfSummaryMoveWithEveryKeySelectedKeepsRelativeOrder() {
    var f = Fixture()
    var all = Set<SummaryMember>()
    for (p, t) in f.summary.tracks { for id in t.keyIDs { all.insert(SummaryMember(property: p, keyID: id)) } }
    #expect(f.summary.move(all, by: kfT(3), frame: frame) == kfT(3))
    guard case .scalar(let o) = f.summary.tracks[op] else { return }
    #expect(o.keys.map(\.time) == [kfT(3), kfT(7)])
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
    let r8 = f.summary.move([], by: kfT(3), frame: frame)
    #expect(r8 == .zero)
    let back = try JSONDecoder().decode(KeyframeSummary.self, from: JSONEncoder().encode(f.summary))
    #expect(back == f.summary)
}
