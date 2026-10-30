import Foundation
import Testing
@testable import SQCore

@Suite struct FollowSelectionTests {
    private let fd = Time(1, 24)
    private func clip(_ s: Int64, _ n: Int64, _ kind: TrackKind = .video) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * n), start: fd * s, mediaDuration: fd * 500)
    }

    @Test func targetedTracksOnly() {
        let a = clip(0, 10), b = clip(0, 10), c = clip(0, 10, .audio)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [a], isTargeted: true), Track(kind: .video, clips: [b]),
            Track(kind: .audio, clips: [c], isTargeted: true)])
        #expect(t.followedClips(at: fd * 3).ids == [a.id, c.id])
    }

    @Test func nothingTargetedSelectsNothing() {
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(0, 10)])])
        #expect(t.followedClips(at: fd * 3).ids.isEmpty)
    }

    @Test func gapAndBoundaries() {
        let a = clip(0, 10), b = clip(20, 10)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [a, b], isTargeted: true)])
        let inA = t.followedClips(at: fd * 9)
        #expect(inA.ids == [a.id] && inA.covers(fd * 0) && !inA.covers(fd * 10))
        let gap = t.followedClips(at: fd * 10)
        #expect(gap.ids.isEmpty && gap.validFrom == fd * 10 && gap.validUntil == fd * 20)
        #expect(t.followedClips(at: fd * 20).ids == [b.id])
        let after = t.followedClips(at: fd * 30)
        #expect(after.ids.isEmpty && after.validUntil == nil)
    }

    @Test func rangeIsIntersectionOfTracks() {
        let a = clip(0, 10), b = clip(5, 10)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [a], isTargeted: true), Track(kind: .video, clips: [b], isTargeted: true)])
        let r = t.followedClips(at: fd * 7)
        #expect(r.validFrom == fd * 5 && r.validUntil == fd * 10)
    }
}
