import Foundation
import Testing
@testable import SQCore

// Q-BRL1 rec 1: Place on Top picks the video track above the topmost one that has a clip in the range.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func vtrack(_ clips: [Clip] = [], locked: Bool = false) throws -> Track {
    var t = Track(kind: .video, isLocked: locked)
    for c in clips { try t.overwrite(c) }
    return t
}
private func atrack() -> Track { Track(kind: .audio) }
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }

@Suite struct PlaceOnTopTests {
    @Test func fastCutNeverPicksTheMainTrack() throws {
        let v1 = try vtrack([clip(0, 10)]), v2 = try vtrack()
        var tl = timeline(v1, v2)
        tl.setEditMode(.magnetic)
        #expect(tl.placeOnTopTarget(in: r(12, 15)) == .existing(v2.id))   // beyond V1's end: still above V1
        var empty = timeline(try vtrack(), v2)
        empty.setEditMode(.magnetic)
        #expect(empty.placeOnTopTarget(in: r(2, 5)) == .existing(empty.tracks[0].id))   // empty main track: V1 itself
        var only = timeline(v1)
        only.setEditMode(.magnetic)
        #expect(only.placeOnTopTarget(in: r(12, 15)) == .newTrack)
    }

    @Test func landsOnTrackAboveTheTopmostOccupiedOne() throws {
        let v1 = try vtrack([clip(0, 10)]), v2 = try vtrack(), v3 = try vtrack()
        let tl = timeline(v1, v2, v3, atrack())
        #expect(tl.placeOnTopTarget(in: r(2, 5)) == .existing(v2.id))
    }

    @Test func skipsOccupiedUpperTrackAndGoesAboveIt() throws {
        let v1 = try vtrack([clip(0, 10)]), v2 = try vtrack([clip(3, 2)]), v3 = try vtrack()
        #expect(timeline(v1, v2, v3).placeOnTopTarget(in: r(2, 5)) == .existing(v3.id))
    }

    @Test func clipsOutsideTheRangeDoNotCount() throws {
        let v1 = try vtrack([clip(0, 10)]), v2 = try vtrack([clip(20, 2)]), v3 = try vtrack()
        #expect(timeline(v1, v2, v3).placeOnTopTarget(in: r(2, 5)) == .existing(v2.id))
    }

    @Test func createsATrackWhenTheTopOneIsTaken() throws {
        let tl = timeline(try vtrack([clip(0, 10)]), try vtrack([clip(0, 10)]))
        #expect(tl.placeOnTopTarget(in: r(2, 5)) == .newTrack)
    }

    @Test func lockedTracksAreSkipped() throws {
        let v1 = try vtrack([clip(0, 10)]), v2 = try vtrack(locked: true), v3 = try vtrack()
        #expect(timeline(v1, v2, v3).placeOnTopTarget(in: r(2, 5)) == .existing(v3.id))
    }

    @Test func emptySequenceUsesTheFirstVideoTrack() throws {
        let v1 = try vtrack(), v2 = try vtrack()
        #expect(timeline(v1, v2).placeOnTopTarget(in: r(0, 4)) == .existing(v1.id))
    }

    @Test func noVideoTrackCreatesOne() {
        #expect(timeline(atrack()).placeOnTopTarget(in: r(0, 4)) == .newTrack)
    }

    @Test func freeTrackBelowTheTopmostOccupiedIsNotChosen() throws {
        let v1 = try vtrack(), v2 = try vtrack([clip(0, 10)]), v3 = try vtrack()
        #expect(timeline(v1, v2, v3).placeOnTopTarget(in: r(2, 5)) == .existing(v3.id))
    }
}
