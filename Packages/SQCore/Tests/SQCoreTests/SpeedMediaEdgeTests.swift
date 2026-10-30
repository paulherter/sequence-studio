import Foundation
import Testing
@testable import SQCore

// Found by TimelineFuzz2: a speed edit that leaves less than one timeline frame of media at the new speed forced one
// frame anyway, so the source ran past the media (before 0 when reversed, beyond the end forward).

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

private func clip(from: Int64, frames: Int64, media: Int64, reversed: Bool = false, link: UUID? = nil, start: Int64 = 0) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(media), reversed: reversed)
}

private func insideMedia(_ t: Timeline) -> Bool {
    t.tracks.flatMap(\.clips).allSatisfy { c in c.source.start >= .zero && c.mediaDuration.map { c.source.end <= $0 } ?? true }
}

@Suite struct SpeedMediaEdgeTests {
    @Test func reversedSpeedUpWithLessThanOneFrameOfMediaIsRefused() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(from: 0, frames: 1, media: 300)])])
        let before = t
        #expect(throws: EditError.insufficientMedia) {
            try t.setSpeed(t.tracks[0].clips[0].id, to: ClipSpeed(percent: 400), reversed: true)
        }
        #expect(t == before)
    }

    @Test func forwardSpeedUpAtTheMediaEndIsRefused() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(from: 298, frames: 2, media: 300)])])
        #expect(throws: EditError.insufficientMedia) { try t.setSpeed(t.tracks[0].clips[0].id, to: ClipSpeed(percent: 400)) }
        #expect(insideMedia(t))
    }

    @Test func speedUpWithEnoughMediaStillWorks() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(from: 0, frames: 8, media: 300)])])
        try t.setSpeed(t.tracks[0].clips[0].id, to: ClipSpeed(percent: 400), reversed: true)   // 8 source frames: 2 frames
        #expect(insideMedia(t) && t.tracks[0].clips[0].duration == f(2))
    }

    /// Rate stretch shrinking a clip whose linked partner has little media left: the stretch stops at the shortest length
    /// where the partner still fits instead of pushing the partner past its media.
    @Test func rateStretchStopsWhereAPartnerRunsOutOfMedia() throws {
        let link = UUID()
        let v = clip(from: 0, frames: 60, media: 100, link: link)
        let a = clip(from: 0, frames: 2, media: 10, link: link)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .video, clips: [a])])
        let moved = try t.rateStretch(v.id, edge: .tail, by: f(-59))
        #expect(insideMedia(t))
        let nv = t.tracks[0].clips[0]
        #expect(nv.duration > f(1) && nv.duration < f(60))
        #expect(moved == nv.duration - f(60))
    }
}
