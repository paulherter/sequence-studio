#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)
private func frames(_ n: Int64) -> Time { fd * n }

@Suite struct TimelineFollowTests {
    // View content spans x 160...1000, 24 pt margin.
    private func page(_ f: TimelineFollow, playheadX: CGFloat, scrollX: CGFloat = 0) -> CGFloat? {
        f.pageScroll(playheadX: playheadX, scrollX: scrollX, viewLeft: 160, viewRight: 1000)
    }

    @Test func insideTheViewDoesNotScroll() {
        #expect(page(TimelineFollow(), playheadX: 500) == nil)
    }

    @Test func leavingTheRightEdgeJumpsAPage() {
        // Playhead at x 995 (within 12 pt of the edge): the playhead moves to 24 pt from the left edge.
        #expect(page(TimelineFollow(), playheadX: 995, scrollX: 100) == CGFloat(911))
    }

    @Test func leavingTheLeftEdgeJumpsAPage() {
        #expect(page(TimelineFollow(), playheadX: 100, scrollX: 400) == CGFloat(316))
    }

    @Test func manualScrollWinsWhilePlayingUntilPlaybackRestarts() {
        var f = TimelineFollow()
        f.playbackStarted(playheadVisible: true)
        f.userScrolled(whilePlaying: true)
        #expect(page(f, playheadX: 2000) == nil)                 // the user looks elsewhere: no forced follow
        f.playbackStarted(playheadVisible: true)
        #expect(page(f, playheadX: 2000) != nil)                 // restart: following again
    }

    @Test func scrollingWhilePausedDoesNotDisableFollow() {
        var f = TimelineFollow()
        f.userScrolled(whilePlaying: false)
        f.playbackStarted(playheadVisible: true)
        #expect(page(f, playheadX: 2000) != nil)
    }

    @Test func startingPlaybackWithThePlayheadOffScreenDoesNotYankTheView() {
        var f = TimelineFollow()
        f.playbackStarted(playheadVisible: false)
        #expect(page(f, playheadX: 2000) == nil)
    }
}

@Suite struct PlayheadSnapTests {
    private func timeline() -> Timeline {
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: frames(20)), start: frames(10))
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: frames(20)), start: frames(50))
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [a, b])])
        t.markers = [Marker(time: frames(100))]
        return t
    }
    private let geo = TimelineGeometry(frameDuration: fd, pointsPerSecond: 96)   // 4 pt per frame

    @Test func snapsToClipEdgesWithinTenPoints() {
        let r = PlayheadSnap.resolve(frames(31), timeline: timeline(), geometry: geo)   // 1 frame = 4 pt from a's end (30)
        #expect(r.time == frames(30))
        #expect(r.hit?.kind == .clipEdge)
        #expect(PlayheadSnap.resolve(frames(48), timeline: timeline(), geometry: geo).time == frames(50))
    }

    @Test func snapsToMarkers() {
        let r = PlayheadSnap.resolve(frames(101), timeline: timeline(), geometry: geo)
        #expect(r.time == frames(100))
        #expect(r.hit?.kind == .marker)
    }

    @Test func farFromEverythingKeepsTheFrame() {
        let r = PlayheadSnap.resolve(frames(40), timeline: timeline(), geometry: geo)
        #expect(r.time == frames(40))
        #expect(r.hit == nil)
    }

    @Test func zeroIsATarget() {
        #expect(PlayheadSnap.resolve(frames(1), timeline: timeline(), geometry: geo).time == .zero)
    }
}
