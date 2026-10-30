import Foundation
import Testing
@testable import SQCore

// Fast Cut phase 2: the edit entry points the app calls (three-point edits, placing sequences) pick the Fast Cut verbs by
// the sequence's stored mode, so every source edit in a Fast Cut sequence is magnetic; Normal stays byte-identical.
//
// V1: c1 0-4 | c2 4-8
// V2: title 5-7, attached to c2 at point 0 (attach time 5)
// A1: empty

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private let fd = Time(1, 30)

private struct F {
    var tl: Timeline
    let c1 = UUID(), c2 = UUID(), title = UUID()
    init(mode: TimelineEditMode = .magnetic) {
        func clip(_ id: UUID, _ start: Double, _ len: Double) -> Clip {
            Clip(id: id, name: "x", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: s(start),
                 mediaDuration: s(100))
        }
        var t = clip(title, 5, 2)
        if mode == .magnetic { t.attachment = ClipAttachment(host: c2, point: .zero) }
        tl = Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(c1, 0, 4), clip(c2, 4, 4)]),
                                                              Track(kind: .video, clips: [t]), Track(kind: .audio)])
        tl.editMode = mode
    }
    var v1: Track.ID { tl.tracks[0].id }
    var v2: Track.ID { tl.tracks[1].id }
    var a1: Track.ID { tl.tracks[2].id }
}

private func start(_ t: Timeline, _ id: Clip.ID) -> Time? { t.find(id)?.clip.start }
private func encoded(_ t: Timeline) throws -> Data {
    let e = JSONEncoder(); e.outputFormatting = .sortedKeys
    return try e.encode(t)
}

@Suite struct FastCutRoutingTests {
    @Test func sourceInsertOnTheMainTrackRipplesAndAttachedClipsFollow() throws {
        var f = F()
        try f.tl.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), targets: [f.v1, f.a1], at: s(2), mode: .insert)
        let main = f.tl.tracks[0].clips
        #expect(main.map(\.start) == [.zero, s(2), s(4), s(6)])          // c1 cut at 2, 2 s inserted, rest pushed
        #expect(f.tl.tracks[2].clips.map(\.start) == [s(2)])            // its audio on A1
        #expect(start(f.tl, f.title) == s(7))                           // follows c2 (4 -> 6)
        #expect(f.tl.find(f.title)?.clip.attachment?.host == f.c2)
    }

    @Test func sourceInsertPastTheMainTrackEndLandsAtItsEnd() throws {
        var f = F()
        try f.tl.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), targets: [f.v1], at: s(20), mode: .insert)
        #expect(f.tl.tracks[0].clips.map(\.start) == [.zero, s(4), s(8)])   // no hole on V1
    }

    @Test func sourceOverwriteKeepsAttachedClipsOnTheirFrame() throws {
        var f = F()
        try f.tl.threePointEdit(source: TimeRange(start: .zero, duration: s(4)), media: UUID(), targets: [f.v1], at: s(4), mode: .overwrite)
        #expect(start(f.tl, f.title) == s(5))
        #expect(f.tl.find(f.c2) == nil)
        let host = try #require(f.tl.find(f.title)?.clip.attachment?.host)
        #expect(f.tl.tracks[0].clip(host) != nil)                        // re-attached to the new clip under it
    }

    @Test func sourceEditOffTheMainTrackAttachesAndNeverCovers() throws {
        var f = F()
        // Patched to V2 where the title already sits: the new clip goes on the nearest free track and attaches.
        try f.tl.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), targets: [f.v2], at: s(5), mode: .overwrite)
        #expect(start(f.tl, f.title) == s(5))
        let made = try #require(f.tl.tracks.flatMap(\.clips).first { $0.id != f.title && !f.tl.isOnMainTrack($0.id) && $0.kind == .video })
        #expect(made.start == s(5))
        #expect(made.attachment?.host == f.c2)
        #expect(f.tl.tracks[0].clips.map(\.start) == [.zero, s(4)])     // V1 untouched
    }

    @Test func normalSourceInsertIsUnchanged() throws {
        var f = F(mode: .normal)
        try f.tl.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), targets: [f.v2], at: s(5), mode: .overwrite)
        #expect(f.tl.tracks[1].clips.map(\.start) == [s(5)])            // Normal overwrite on V2 covers the title
        #expect(f.tl.find(f.title) == nil)
        #expect(f.tl.tracks.allSatisfy { $0.clips.allSatisfy { $0.attachment == nil } })
    }

    @Test func placingASequenceInsertsOnTheMainTrack() throws {
        let f = F()
        let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [Clip(name: "i", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)),
                                             start: .zero, mediaDuration: s(2))])])
        var p = Project(name: "P", timelines: [f.tl, inner])
        try p.placeSequences([inner.id], in: f.tl.id, at: s(4), videoTrack: f.v1, mode: .insert)
        let t = try #require(p.timeline(f.tl.id))
        #expect(t.tracks[0].clips.map(\.start) == [.zero, s(4), s(6)])
        #expect(t.tracks[0].clips[1].sequence == inner.id)
        #expect(start(t, f.title) == s(7))
    }

    @Test func placingSequenceClipsInsertsWithAttachedClipsFollowing() throws {
        let f = F()
        let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [Clip(name: "i", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)),
                                             start: .zero, mediaDuration: s(2))])])
        var p = Project(name: "P", timelines: [f.tl, inner])
        try p.placeSequenceClips([inner.id], in: f.tl.id, at: s(4), videoTrack: f.v1, mode: .insert)
        let t = try #require(p.timeline(f.tl.id))
        #expect(t.tracks[0].clips.map(\.start) == [.zero, s(4), s(6)])
        #expect(start(t, f.title) == s(7))
        #expect(t.find(f.title)?.clip.attachment?.host == f.c2)
    }

    @Test func normalPlaceSequenceIsByteIdenticalToBefore() throws {
        // Normal mode never runs a Fast Cut path: the same call twice gives the same file (and no attachments).
        let f = F(mode: .normal)
        let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [Clip(name: "i", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)),
                                             start: .zero, mediaDuration: s(2))])])
        var p = Project(name: "P", timelines: [f.tl, inner])
        try p.placeSequenceClips([inner.id], in: f.tl.id, at: s(4), videoTrack: f.v1, mode: .insert)
        let t = try #require(p.timeline(f.tl.id))
        #expect(t.tracks.allSatisfy { $0.clips.allSatisfy { $0.attachment == nil } })
        #expect(t.editMode == .normal)
        #expect(try encoded(t).count > 0)
    }
}
