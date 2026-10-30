import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video, sync: Bool = true) throws -> Track {
    var t = Track(kind: kind, syncLock: sync)
    for c in clips { try t.overwrite(c) }
    return t
}
private func spans(_ t: Track) -> [[Int64]] {
    t.clips.map { [$0.start.value / $0.start.timescale, $0.timeline.end.value / $0.timeline.end.timescale] }
}

@Suite struct ExtractPartnerTests {
    /// V1 targeted, its linked audio on an untargeted A1 without sync lock: the audio is cut with the picture, its right
    /// piece closes the gap with it and the halves keep a shared link.
    @Test func untargetedPartnerOfSplitClipRightPieceFollows() throws {
        let l = UUID()
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([clip(0, 10, link: l)]), try track([clip(0, 10, kind: .audio, link: l)], kind: .audio, sync: false)])
        try tl.extract(r(2, 4), tracks: [tl.tracks[0].id])
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 8]])
        #expect(spans(tl.tracks[1]) == [[0, 2], [2, 8]])
        #expect(tl.tracks[0].clips[1].link == tl.tracks[1].clips[1].link)
        #expect(tl.tracks[0].clips[1].link != nil)
    }
}
