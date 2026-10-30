import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(5), duration: s(dur)),
         start: s(start), link: link)
}
private func pair() throws -> (Timeline, Clip, Clip) {
    let l = UUID()
    let v = clip(10, 10, link: l), a = clip(10, 10, kind: .audio, link: l)
    var vt = Track(kind: .video); try vt.overwrite(v)
    var at = Track(kind: .audio); try at.overwrite(a)
    return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: [vt, at]), v, a)
}

/// Premiere "selected unlinked" (Option-click): only the selected clips are edited, linked partners outside the
/// selection stay put.
@Suite struct SoloEditTests {
    @Test func heldBackPartners() throws {
        let (tl, v, a) = try pair()
        #expect(tl.heldBackPartners(of: [v.id]) == [a.id])
        #expect(tl.heldBackPartners(of: [v.id, a.id]).isEmpty)
    }

    @Test func trimAloneLeavesPartnerAndKeepsLink() throws {
        var (tl, v, a) = try pair()
        try tl.editing(only: [v.id]) { try $0.trim(v.id, edge: .tail, by: s(-3)) }
        #expect(tl.tracks[0].clips[0].duration == s(7))
        #expect(tl.tracks[1].clips[0].duration == s(10))
        #expect(tl.tracks[1].clips[0].link == v.link)
        #expect(tl.tracks[0].clips[0].link == v.link)
        _ = a
    }

    @Test func moveAloneLeavesPartner() throws {
        var (tl, v, _) = try pair()
        try tl.editing(only: [v.id]) { try $0.move(v.id, to: s(14)) }
        #expect(tl.tracks[0].clips[0].start == s(14))
        #expect(tl.tracks[1].clips[0].start == s(10))
    }

    @Test func liftAloneKeepsPartnerUnlinked() throws {
        var (tl, v, _) = try pair()
        try tl.editing(only: [v.id]) { try $0.lift([v.id]) }
        #expect(tl.tracks[0].clips.isEmpty)
        #expect(tl.tracks[1].clips.count == 1)
        #expect(tl.tracks[1].clips[0].link == nil)
    }

    @Test func nudgeAlone() throws {
        var (tl, v, _) = try pair()
        try tl.editing(only: [v.id]) { _ = try $0.nudge([v.id], by: s(2)) }
        #expect(tl.tracks[0].clips[0].start == s(12))
        #expect(tl.tracks[1].clips[0].start == s(10))
    }

    @Test func fullSelectionBehavesLinked() throws {
        var (tl, v, a) = try pair()
        try tl.editing(only: [v.id, a.id]) { try $0.trim(v.id, edge: .tail, by: s(-3)) }
        #expect(tl.tracks[1].clips[0].duration == s(7))
    }

    @Test func failureLeavesTimelineUnchanged() throws {
        var (tl, v, _) = try pair()
        let before = tl
        #expect(throws: EditError.self) { try tl.editing(only: [v.id]) { try $0.trim(v.id, edge: .tail, by: s(-10)) } }
        #expect(tl == before)
    }
}
