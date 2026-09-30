import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}

@Suite struct MirroredMoveTests {
    @Test func retargetMovesLinkedPartnerToItsOwnTrack() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v]), Track(kind: .video), try track([a], kind: .audio), Track(kind: .audio)])
        let (v2, a2) = (tl.tracks[1].id, tl.tracks[3].id)
        try tl.move(v.id, to: s(0), track: v2, retarget: [a.id: a2])
        #expect(tl.tracks[1].clips.map(\.id) == [v.id])
        #expect(tl.tracks[3].clips.map(\.id) == [a.id])
        #expect(tl.tracks[0].clips.isEmpty && tl.tracks[2].clips.isEmpty)
    }

    @Test func retargetToWrongKindThrows() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v]), Track(kind: .video), try track([a], kind: .audio)])
        let wrong = tl.tracks[1].id
        #expect(throws: EditError.wrongTrackKind) {
            try tl.move(v.id, to: s(0), retarget: [a.id: wrong])
        }
    }
}
