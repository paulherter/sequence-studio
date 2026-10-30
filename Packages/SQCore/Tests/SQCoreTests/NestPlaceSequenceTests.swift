import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func seq(_ name: String, secs: Int64, audio: Bool = true, fd: Time = Time(1, 30)) throws -> Timeline {
    var tracks = [try track([clip(0, secs)])]
    if audio { tracks.append(try track([clip(0, secs, kind: .audio)], kind: .audio)) }
    return Timeline(name: name, frameDuration: fd, tracks: tracks)
}
private func host(_ name: String, fd: Time = Time(1, 30)) -> Timeline {
    Timeline(name: name, frameDuration: fd, tracks: [Track(kind: .video, isTargeted: true), Track(kind: .audio, isTargeted: true)])
}

@Suite struct NestPlaceSequenceTests {
    @Test func droppingSequenceMakesLinkedNestedClipsWithItsDuration() throws {
        let b = try seq("B", secs: 6), a = host("A")
        var p = Project(name: "P", timelines: [a, b])
        let end = try p.placeSequences([b.id], in: a.id, at: s(2), mode: .overwrite)
        #expect(end == s(8))
        let t = try #require(p.timeline(a.id))
        let v = try #require(t.tracks[0].clips.first), au = try #require(t.tracks[1].clips.first)
        #expect(v.sequence == b.id && au.sequence == b.id)
        #expect(v.start == s(2) && v.source.duration == s(6) && au.source.duration == s(6))
        #expect(v.link != nil && v.link == au.link)
    }

    @Test func videoOnlySequenceHasNoAudioPart() throws {
        let b = try seq("B", secs: 3, audio: false), a = host("A")
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequences([b.id], in: a.id, at: .zero, mode: .overwrite)
        #expect(p.timeline(a.id)!.tracks[1].clips.isEmpty)
        #expect(p.timeline(a.id)!.tracks[0].clips.count == 1)
    }

    @Test func droppingNestedSequenceWorks() throws {
        let c = try seq("C", secs: 4), b = host("B"), a = host("A")
        var p = Project(name: "P", timelines: [a, b, c])
        try p.placeSequences([c.id], in: b.id, at: .zero, mode: .overwrite)     // C into B
        try p.placeSequences([b.id], in: a.id, at: s(1), mode: .overwrite)      // B (containing C) into A
        #expect(p.nestedSequences(of: a.id) == [b.id])
        #expect(p.reachableSequences(from: a.id) == [b.id, c.id])
        #expect(p.timeline(a.id)!.tracks[0].clips[0].source.duration == s(4))
    }

    @Test func selfDropIsRefused() throws {
        let a = try seq("A", secs: 4)
        var p = Project(name: "P", timelines: [a])
        let before = p
        #expect(throws: EditError.nestingCycle) { try p.placeSequences([a.id], in: a.id, at: .zero, mode: .insert) }
        #expect(p == before)
    }

    @Test func transitiveCycleIsRefused() throws {
        let a = host("A"), b = try seq("B", secs: 4)
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequences([b.id], in: a.id, at: .zero, mode: .overwrite)     // B in A
        let before = p
        #expect(throws: EditError.nestingCycle) { try p.placeSequences([a.id], in: b.id, at: s(10), mode: .overwrite) }
        #expect(p == before)
        #expect(p.isNestingAcyclic)
    }

    @Test func insertShiftsAndUndoRestores() throws {
        let b = try seq("B", secs: 2)
        var a = host("A")
        try a.tracks[0].overwrite(clip(0, 5))
        var p = Project(name: "P", timelines: [a, b])
        let before = p
        try p.placeSequences([b.id], in: a.id, at: s(1), mode: .insert)
        let t = p.timeline(a.id)!
        #expect(t.tracks[0].clips.count == 3)           // left half, nested, right half
        #expect(t.duration == s(7))
        p = before                                       // snapshot undo
        #expect(p.timeline(a.id)!.duration == s(5))
    }

    @Test func frameRateRoundingIsWholeHostFrames() throws {
        // 30 fps sequence of 1001/30000 * 30 = 1.001 s in a 25 fps host: 25 frames = 1 s.
        let fd30 = Time(1001, 30000)
        let b = Timeline(name: "B", frameDuration: fd30, tracks: [Track(kind: .video)])
        var bb = b
        try bb.tracks[0].overwrite(Clip(name: "c", media: UUID(), kind: .video,
                                        source: TimeRange(start: .zero, duration: fd30 * 30), start: .zero))
        let fd25 = Time(1, 25)
        var p = Project(name: "P", timelines: [host("A", fd: fd25), bb])
        let a = p.timelines[0].id
        try p.placeSequences([bb.id], in: a, at: .zero, mode: .overwrite)
        let c = p.timeline(a)!.tracks[0].clips[0]
        #expect(c.source.duration == fd25 * 25)
        #expect(c.timeline.duration == fd25 * 25)
        #expect(c.source.duration <= bb.duration)
    }

    @Test func emptyOrUnknownSequenceIsRefused() throws {
        let e = Timeline(name: "E", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        var p = Project(name: "P", timelines: [host("A"), e])
        let a = p.timelines[0].id
        #expect(throws: EditError.emptyClip) { try p.placeSequences([e.id], in: a, at: .zero, mode: .overwrite) }
        #expect(throws: EditError.emptyClip) { try p.placeSequences([UUID()], in: a, at: .zero, mode: .overwrite) }
    }

    @Test func severalSequencesFollowEachOther() throws {
        let b = try seq("B", secs: 2), c = try seq("C", secs: 3), a = host("A")
        var p = Project(name: "P", timelines: [a, b, c])
        let end = try p.placeSequences([b.id, c.id], in: a.id, at: s(1), mode: .overwrite)
        #expect(end == s(6))
        #expect(p.timeline(a.id)!.tracks[0].clips.map(\.start) == [s(1), s(3)])
    }
}
