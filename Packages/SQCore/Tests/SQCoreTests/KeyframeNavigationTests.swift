import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil, keys: [Int64] = []) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)),
                 start: s(start), link: link, mediaDuration: s(1000))
    if !keys.isEmpty { c.animation.opacity.track = KeyframeTrack(keys: keys.map { Keyframe(time: s($0), value: 1.0) }) }
    return c
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func spans(_ t: Track) -> [[Int64]] {
    t.clips.map { [$0.start.value / $0.start.timescale, $0.timeline.end.value / $0.timeline.end.timescale] }
}

@Suite struct KeyframeNavigationTests {
    @Test func nextAndPreviousUseTimelineTimeOfClipKeys() throws {
        let c = clip(10, 20, keys: [2, 5, 9])
        let tl = timeline(try track([c]))
        #expect(tl.nextKeyframe(after: s(0), clips: [c.id]) == s(12))
        #expect(tl.nextKeyframe(after: s(12), clips: [c.id]) == s(15))
        #expect(tl.nextKeyframe(after: s(19), clips: [c.id]) == nil)
        #expect(tl.previousKeyframe(before: s(19), clips: [c.id]) == s(15))
        #expect(tl.previousKeyframe(before: s(12), clips: [c.id]) == nil)
    }
}

@Suite struct SoloSelectionTests {
    @Test func soloesAudioTracksOfSelectionAndLinkedPartners() throws {
        let l = UUID()
        let v = clip(0, 5, link: l), a = clip(0, 5, kind: .audio, link: l), other = clip(0, 5, kind: .audio)
        var tl = timeline(try track([v]), try track([a], kind: .audio), try track([other], kind: .audio))
        #expect(tl.toggleSolo(forClips: [v.id]) == true)
        #expect(tl.tracks.map(\.isSolo) == [false, true, false])
        #expect(tl.toggleSolo(forClips: [v.id]) == false)
        #expect(tl.tracks.map(\.isSolo) == [false, false, false])
    }
    @Test func videoOnlySelectionChangesNothing() throws {
        let v = clip(0, 5)
        var tl = timeline(try track([v]))
        #expect(tl.toggleSolo(forClips: [v.id]) == nil)
    }
}

@Suite struct TrimToRangeTests {
    @Test func trimsBothEndsKeepingPosition() throws {
        let c = clip(0, 20)
        var tl = timeline(try track([c]))
        let n = try tl.trimToRange([c.id], range: r(5, 15))
        #expect(n == 1)
        #expect(spans(tl.tracks[0]) == [[5, 15]])
    }
    @Test func clipsInsideOrOutsideAreLeftAlone() throws {
        let inside = clip(6, 4), outside = clip(30, 4)
        var tl = timeline(try track([inside, outside]))
        #expect(try tl.trimToRange([inside.id, outside.id], range: r(5, 15)) == 0)
    }
}
