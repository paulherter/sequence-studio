import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func seq(_ name: String, secs: Int64, audio: Bool = true) throws -> Timeline {
    var tracks = [try track([clip(0, secs)])]
    if audio { tracks.append(try track([clip(0, secs, kind: .audio)], kind: .audio)) }
    return Timeline(name: name, frameDuration: Time(1, 30), tracks: tracks)
}

@Suite struct ReplaceWithSequenceTests {
    @Test func clipAndPartnerPlaySequenceKeepingPositionAndLength() throws {
        let l = UUID()
        let v = clip(2, 4, link: l), a = clip(2, 4, kind: .audio, link: l)
        let host = Timeline(name: "A", frameDuration: Time(1, 30), tracks: [try track([v]), try track([a], kind: .audio)])
        let b = try seq("B", secs: 6)
        var p = Project(name: "P", timelines: [host, b])
        try p.replaceWithSequence(of: v.id, with: b.id, in: host.id)
        let t = try #require(p.timeline(host.id))
        let nv = try #require(t.tracks[0].clips.first), na = try #require(t.tracks[1].clips.first)
        #expect(nv.id == v.id && nv.start == s(2) && nv.source.duration == s(4) && nv.sequence == b.id)
        #expect(na.id == a.id && na.sequence == b.id && na.link == l)
    }

    @Test func tooShortSequenceAndCycleRefuseWithoutChange() throws {
        let v = clip(0, 4)
        let host = Timeline(name: "A", frameDuration: Time(1, 30), tracks: [try track([v])])
        let b = try seq("B", secs: 2, audio: false)
        var p = Project(name: "P", timelines: [host, b])
        let before = p
        #expect(throws: EditError.insufficientMedia) { try p.replaceWithSequence(of: v.id, with: b.id, in: host.id) }
        #expect(throws: EditError.nestingCycle) { try p.replaceWithSequence(of: v.id, with: host.id, in: host.id) }
        #expect(p == before)
    }
}
