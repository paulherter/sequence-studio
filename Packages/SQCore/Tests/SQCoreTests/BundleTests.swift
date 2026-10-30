import Foundation
import Testing
@testable import SQCore

// Bundles (Premiere's Clip > Group, v57): clips that stay on their own tracks but select, move, trim at shared outer edges
// and delete together. Separate from links (A/V sync) and from Groups (W7.6 layer groups, which nest).

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)),
         start: s(start), link: link, mediaDuration: s(100))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, locked: Bool = false) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    t.isLocked = locked
    return t
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func bundleOf(_ t: Timeline, _ id: Clip.ID) -> UUID? { t.find(id)?.clip.bundle }

@Suite struct BundleTests {
    @Test func bundlesClipsOnSeveralTracks() throws {
        let a = clip(0, 10), b = clip(2, 5)
        var t = timeline([track([a]), track([b])])
        let id = try t.bundle([a.id, b.id])
        #expect(bundleOf(t, a.id) == id)
        #expect(bundleOf(t, b.id) == id)
        #expect(t.containsBundles)
    }

    @Test func linkedPartnersJoinTheBundle() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l), title = clip(0, 4)
        var t = timeline([track([v]), track([title]), track([a], kind: .audio)])
        let id = try t.bundle([v.id, title.id])
        #expect(bundleOf(t, a.id) == id)
        #expect(t.find(a.id)?.clip.link == l)          // the link stays as it was
        #expect(t.expandingBundles([title.id]) == [v.id, a.id, title.id])
    }

    @Test func oneLinkedPairAloneIsNotABundle() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var t = timeline([track([v]), track([a], kind: .audio)])
        #expect(throws: EditError.clipNotFound) { try t.bundle([v.id]) }
        #expect(throws: EditError.clipNotFound) { try t.bundle([v.id, a.id]) }
        #expect(!t.containsBundles)
    }

    @Test func bundlingMembersOfBundlesMergesThem() throws {
        let a = clip(0, 5), b = clip(10, 5), c = clip(20, 5), d = clip(30, 5)
        var t = timeline([track([a, b, c, d])])
        let first = try t.bundle([a.id, b.id])
        _ = try t.bundle([c.id, d.id])
        let merged = try t.bundle([b.id, c.id])
        #expect(merged != first)
        #expect([a, b, c, d].allSatisfy { bundleOf(t, $0.id) == merged })
    }

    @Test func lockedTrackRefuses() {
        let a = clip(0, 5), b = clip(0, 5)
        var t = timeline([track([a]), track([b], locked: true)])
        #expect(throws: EditError.trackLocked) { try t.bundle([a.id, b.id]) }
        #expect(!t.containsBundles)
    }

    @Test func unbundleClearsEveryTouchedBundle() throws {
        let a = clip(0, 5), b = clip(10, 5), c = clip(20, 5), d = clip(30, 5)
        var t = timeline([track([a, b, c, d])])
        _ = try t.bundle([a.id, b.id])
        let keep = try t.bundle([c.id, d.id])
        #expect(try t.unbundle([a.id]))
        #expect(bundleOf(t, a.id) == nil && bundleOf(t, b.id) == nil)
        #expect(bundleOf(t, c.id) == keep)
        #expect(try !t.unbundle([a.id]))                  // nothing bundled any more: no change
    }

    @Test func orphanBundlesAreDropped() throws {
        let a = clip(0, 5), b = clip(10, 5)
        var t = timeline([track([a, b])])
        _ = try t.bundle([a.id, b.id])
        t.tracks[0].remove(b.id)
        t.dropOrphanBundles()
        #expect(bundleOf(t, a.id) == nil)
    }

    @Test func expandingBundlesWithoutBundlesIsIdentity() {
        let a = clip(0, 5)
        let t = timeline([track([a])])
        #expect(t.expandingBundles([a.id]) == [a.id])
    }

    @Test func edgePeersShareTheEdgeTime() throws {
        let base = clip(0, 10), top = clip(0, 10), short = clip(2, 6), late = clip(4, 6)
        var t = timeline([track([base]), track([top]), track([short]), track([late])])
        _ = try t.bundle([base.id, top.id, short.id, late.id])
        #expect(t.bundleEdgePeers(of: base.id, edge: .head) == [top.id])
        #expect(t.bundleEdgePeers(of: base.id, edge: .tail) == [top.id, late.id])
        #expect(t.bundleEdgePeers(of: short.id, edge: .head).isEmpty)
        let lone = clip(30, 5)
        #expect(timeline([track([lone])]).bundleEdgePeers(of: lone.id, edge: .head).isEmpty)
    }

    @Test func splitKeepsBothHalvesInTheBundle() throws {
        let a = clip(0, 10), b = clip(0, 10)
        var t = timeline([track([a]), track([b])])
        let id = try t.bundle([a.id, b.id])
        try t.tracks[0].split(at: s(5))
        #expect(t.tracks[0].clips.count == 2)
        #expect(t.tracks[0].clips.allSatisfy { $0.bundle == id })
    }

    @Test func pastedCopiesGetTheirOwnBundle() throws {
        let a = clip(0, 5), b = clip(0, 5)
        var t = timeline([track([a]), track([b])])
        let id = try t.bundle([a.id, b.id])
        let both = try #require(t.clipboard(copying: [a.id, b.id]))
        let made = try t.paste(both, at: s(20))
        let copies = made.compactMap { t.find($0)?.clip.bundle }
        #expect(copies.count == 2 && Set(copies).count == 1 && copies[0] != id)
        let one = try #require(t.clipboard(copying: [a.id]))
        let lone = try t.paste(one, at: s(40))
        #expect(t.find(lone[0])?.clip.bundle == nil)
    }

    @Test func optionDragCopyLeavesTheBundle() throws {
        let a = clip(0, 5), b = clip(0, 5)
        var t = timeline([track([a]), track([b])])
        let id = try t.bundle([a.id, b.id])
        let copyID = UUID()
        try t.move(a.id, to: s(20), copy: CopySpec(ids: [a.id: copyID]))
        #expect(t.find(copyID)?.clip.bundle == nil)
        #expect(bundleOf(t, a.id) == id)
    }

    @Test func indexListsBundleMembers() throws {
        let a = clip(0, 5), b = clip(0, 5)
        var t = timeline([track([a]), track([b])])
        let id = try t.bundle([a.id, b.id])
        let index = TimelineClipIndex(t)
        #expect(Set(index.clips(bundledBy: id)) == [a.id, b.id])
    }

    @Test func bundleRoundTripsAndOldClipsDecodeWithout() throws {
        var c = clip(0, 5)
        c.bundle = UUID()
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.bundle == c.bundle)
        let plain = try JSONEncoder().encode(clip(0, 5))
        let obj = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(obj["bundle"] == nil)
        #expect(try JSONDecoder().decode(Clip.self, from: plain).bundle == nil)
    }
}
