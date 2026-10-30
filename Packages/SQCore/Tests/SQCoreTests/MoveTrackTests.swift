import Foundation
import Testing
@testable import SQCore

@Suite struct MoveTrackTests {
    private func timeline() -> Timeline {
        Timeline(name: "T", frameDuration: Time(1, 30),
                 tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .video), Track(kind: .audio), Track(kind: .audio)])
    }

    @Test func videoMovesUpByRisingIndex() {
        var t = timeline()
        let v1 = t.tracks[0].id, v2 = t.tracks[1].id
        let r1 = t.moveTrack(v1, up: true)
        #expect(r1)
        #expect(t.tracks[1].id == v1 && t.tracks[0].id == v2)
    }

    @Test func audioMovesUpByFallingIndex() {
        var t = timeline()
        let a2 = t.tracks[4].id, a1 = t.tracks[3].id
        let r2 = t.moveTrack(a2, up: true)
        #expect(r2)
        #expect(t.tracks[3].id == a2 && t.tracks[4].id == a1)
    }

    @Test func endsAndKindBordersStay() {
        var t = timeline()
        let top = t.tracks[2].id, a1 = t.tracks[3].id, a2 = t.tracks[4].id
        let r3 = t.moveTrack(top, up: true)
        #expect(!r3)
        let r4 = t.moveTrack(a1, up: true)
        #expect(!r4)
        let r5 = t.moveTrack(a2, up: false)
        #expect(!r5)
        #expect(t.moveTrackNeighbor(of: top, up: false) == 1)
    }

    @Test func clipsTravelWithTheTrack() throws {
        var t = timeline()
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, end: Time(2, 1)), start: .zero,
                        mediaDuration: Time(10, 1))
        try t.tracks[0].overwrite(clip)
        t.moveTrack(t.tracks[0].id, up: true)
        #expect(t.tracks[1].clips.map(\.id) == [clip.id])
    }

    @Test func fastCutKeepsTheMainTrackInPlace() {
        var t = timeline()
        t.editMode = .magnetic
        let v1 = t.tracks[0].id, v2 = t.tracks[1].id, v3 = t.tracks[2].id
        let r6 = t.moveTrack(v1, up: true)
        #expect(!r6)
        let r7 = t.moveTrack(v2, up: false)
        #expect(!r7)
        let r8 = t.moveTrack(v2, up: true)
        #expect(r8)
        #expect(t.tracks[2].id == v2 && t.tracks[1].id == v3)
    }
}
