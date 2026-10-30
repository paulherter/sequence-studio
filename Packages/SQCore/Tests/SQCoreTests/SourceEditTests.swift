import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct SourceEditTests {
    @Test func rangeDefaultsAndClamps() {
        #expect(Timeline.sourceEditRange(marks: SourceMarks(), total: s(10)) == TimeRange(start: s(0), end: s(10)))
        #expect(Timeline.sourceEditRange(marks: SourceMarks(markIn: s(2)), total: s(10)) == TimeRange(start: s(2), end: s(10)))
        #expect(Timeline.sourceEditRange(marks: SourceMarks(markOut: s(4)), total: s(10)) == TimeRange(start: s(0), end: s(4)))
        #expect(Timeline.sourceEditRange(marks: SourceMarks(markIn: s(2), markOut: s(30)), total: s(10))?.end == s(10))
        #expect(Timeline.sourceEditRange(marks: SourceMarks(markIn: s(10)), total: s(10)) == nil)
    }

    @Test func positionPrefersSequenceIn() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        #expect(t.sourceEditPosition(playhead: s(7)) == s(7))
        t.inOut = TimeRange(start: s(3), end: s(9))
        #expect(t.sourceEditPosition(playhead: s(7)) == s(3))
    }

    @Test func targetsFollowTargetedTracks() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        let v1 = t.tracks.first { $0.kind == .video }!.id, a1 = t.tracks.first { $0.kind == .audio }!.id
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true) == [v1, a1])
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true, streams: .videoOnly) == [v1])
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true, streams: .audioOnly) == [a1])
        let vi = t.tracks.firstIndex { $0.id == v1 }!
        t.tracks[vi].isTargeted = false
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: true) == [a1])
        #expect(t.sourceEditTargets(hasVideo: true, hasAudio: false) == nil)
    }

    @Test func noTargetsFallsBackToDefaults() {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let ids = t.sourceEditTargets(hasVideo: true, hasAudio: true)
        #expect(ids?.count == 2)
        #expect(t.tracks.contains { $0.kind == .audio })
    }

    @Test func sourceTimelineHoldsWholeMedia() {
        let m = MediaRef(name: "m", path: "/x", fingerprint: MediaFingerprint(size: 1, modified: nil))
        let f = SequenceFormat(frameDuration: Time(1, 30))
        let tl = Timeline.sourceTimeline(media: m, format: f, hasVideo: true, hasAudio: true, duration: s(5), isStill: false)
        #expect(tl.duration == s(5))
        #expect(tl.tracks.count == 2)
        let audioOnly = Timeline.sourceTimeline(media: m, format: f, hasVideo: false, hasAudio: true, duration: s(5), isStill: false)
        #expect(audioOnly.tracks.map(\.kind) == [.audio])
    }
}
