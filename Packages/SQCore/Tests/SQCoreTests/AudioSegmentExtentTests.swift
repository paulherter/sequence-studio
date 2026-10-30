import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func aclip(_ start: Int64, _ dur: Int64, src: Int64 = 0, media: UUID = UUID()) -> Clip {
    Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}
private func tl(_ clips: [Clip]) -> Timeline {
    Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: clips)])
}

/// `AudioSegment.extent`: the clip's whole audible span, independent of the queried range (de-click fades key on it).
@Suite struct AudioSegmentExtentTests {
    @Test func extentIsTheWholeClipNotTheQueryRange() throws {
        let t = tl([aclip(2, 10)])
        let seg = try #require(t.audioSegments(in: TimeRange(start: s(5), duration: s(2))).first)
        #expect(seg.timeline == TimeRange(start: s(5), duration: s(2)))
        #expect(seg.extent == TimeRange(start: s(2), duration: s(10)))
    }

    @Test func hardCutBetweenDifferentMediaKeepsBothEdges() throws {
        let t = tl([aclip(0, 4), aclip(4, 4)])
        let segs = t.audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs.map(\.extent) == [TimeRange(start: s(0), duration: s(4)), TimeRange(start: s(4), duration: s(4))])
    }

    @Test func throughEditIsNoEdge() throws {
        // A razor cut that kept source continuity: the two pieces sound like one clip, so neither sees an edge at the cut.
        let m = UUID()
        let t = tl([aclip(0, 4, src: 10, media: m), aclip(4, 4, src: 14, media: m)])
        let segs = t.audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs.count == 2)
        #expect(segs[0].extent.start == s(0) && segs[0].extent.end > s(4))
        #expect(segs[1].extent.start < s(4) && segs[1].extent.end == s(8))
    }

    @Test func sameMediaWithJumpedSourceIsAnEdge() throws {
        let m = UUID()
        let t = tl([aclip(0, 4, src: 10, media: m), aclip(4, 4, src: 30, media: m)])
        let segs = t.audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs[0].extent.end == s(4) && segs[1].extent.start == s(4))
    }

    @Test func nestedSegmentExtentIsCutByTheNestedClip() throws {
        let inner = tl([aclip(0, 20)])
        var outerClip = Clip(name: "n", media: UUID(), kind: .audio, source: TimeRange(start: s(5), duration: s(6)), start: s(100))
        outerClip.sequence = inner.id
        let outer = tl([outerClip])
        let seg = try #require(outer.audioSegments(in: TimeRange(start: s(102), duration: s(1)), sequences: { $0 == inner.id ? inner : nil }).first)
        #expect(seg.extent == TimeRange(start: s(100), duration: s(6)))
    }
    @Test func retimedSameSpeedIsAnEdge() throws {
        // The pitch-keeping stretch restarts its grains at each clip, so a cut between two 2x pieces is not seamless.
        let m = UUID()
        var a = aclip(0, 4, src: 10, media: m), b = aclip(2, 4, src: 14, media: m)
        a.speed = ClipSpeed(num: 2, den: 1); b.speed = ClipSpeed(num: 2, den: 1)
        #expect(a.timeline.end == b.start)
        let segs = tl([a, b]).audioSegments(in: TimeRange(start: s(0), duration: s(4)))
        #expect(segs.count == 2)
        #expect(segs[0].extent.end == s(2) && segs[1].extent.start == s(2))
    }

    @Test func gainDifferenceAtTheCutIsAnEdge() throws {
        let m = UUID()
        var a = aclip(0, 4, src: 10, media: m)
        a.audioGainDB = -6
        let segs = tl([a, aclip(4, 4, src: 14, media: m)]).audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs[0].extent.end == s(4) && segs[1].extent.start == s(4))
    }

    @Test func fadeOutBeforeTheCutIsAnEdge() throws {
        // Razor, then fade A out: B starts at full level and still needs its head fade.
        let m = UUID()
        var a = aclip(0, 4, src: 10, media: m)
        a.setAudioFadeOut(s(1), frameDuration: Time(1, 30))
        let segs = tl([a, aclip(4, 4, src: 14, media: m)]).audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs[0].extent.end == s(4) && segs[1].extent.start == s(4))
    }

    @Test func equalGainOnBothSidesStaysThrough() throws {
        let m = UUID()
        var a = aclip(0, 4, src: 10, media: m), b = aclip(4, 4, src: 14, media: m)
        a.audioGainDB = -6; b.audioGainDB = -6
        let segs = tl([a, b]).audioSegments(in: TimeRange(start: s(0), duration: s(8)))
        #expect(segs[0].extent.end == s(8) && segs[1].extent.start == s(0))
    }

    @Test func throughEditChainSpansAllPieces() throws {
        let m = UUID()
        let t = tl([aclip(0, 4, src: 10, media: m), aclip(4, 4, src: 14, media: m), aclip(8, 4, src: 18, media: m)])
        let segs = t.audioSegments(in: TimeRange(start: s(0), duration: s(12)))
        #expect(segs.map(\.extent) == Array(repeating: TimeRange(start: s(0), duration: s(12)), count: 3))
    }

    @Test func razorOnNestedClipIsThroughEdit() throws {
        // Both halves of a razored nest play the inner sequence continuously: no edge at the cut, same extent from both.
        let inner = tl([aclip(0, 20)])
        var a = Clip(name: "n", media: UUID(), kind: .audio, source: TimeRange(start: s(5), duration: s(3)), start: s(100))
        a.sequence = inner.id
        var b = a
        b.id = UUID(); b.source = TimeRange(start: s(8), duration: s(3)); b.start = s(103)
        let outer = tl([a, b])
        let segs = outer.audioSegments(in: TimeRange(start: s(100), duration: s(6)), sequences: { $0 == inner.id ? inner : nil })
        #expect(segs.count == 2)
        #expect(segs.map(\.extent) == Array(repeating: TimeRange(start: s(100), duration: s(6)), count: 2))
    }
}
