import Foundation
import Testing
@testable import SQCore

/// A saved title block (generator clips + element transitions) is placed on free tracks above, never overwriting.
@Suite struct TitleBlockPlacementTests {
    private let fd = Time(1, 30)

    private func text(_ start: Time, _ d: Time) -> Clip {
        let id = UUID()
        return Clip(id: id, name: "t", media: id, kind: .video, source: TimeRange(start: .zero, duration: d), start: start,
                    generator: GeneratorRef(kind: GeneratorRef.text, payload: Data([1])))
    }

    private func media(_ start: Time, _ d: Time) -> Clip {
        Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: d), start: start)
    }

    /// Two text clips on V2 / V3 with a head transition on the first, copied as a block.
    private func block() throws -> TimelineClipboard {
        var t = Timeline(name: "src", frameDuration: fd, tracks: Timeline.defaultTracks(video: 3, audio: 1))
        let a = text(Time(10, 1), Time(3, 1)), b = text(Time(10, 1) + Time(1, 2), Time(3, 1))
        try t.tracks[1].overwrite(a)
        try t.tracks[2].overwrite(b)
        _ = try t.addElementTransitions(kind: .move, track: t.tracks[1].id, clip: a.id, edges: [.head], duration: Time(6, 30))
        return try #require(t.clipboard(copying: [a.id, b.id]))
    }

    @Test func isMediaFreeOnlyForGenerators() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let g = text(.zero, Time(1, 1)), m = media(Time(2, 1), Time(1, 1))
        try t.tracks[0].overwrite(g)
        try t.tracks[1].overwrite(m)
        #expect(t.isMediaFree([g.id]))
        #expect(!t.isMediaFree([g.id, m.id]))
        #expect(!t.isMediaFree([]))
    }

    @Test func placesAboveTheTalkingHeadWithOffsetsAndTransitions() throws {
        let cb = try block()
        var t = Timeline(name: "dst", frameDuration: fd, tracks: Timeline.defaultTracks(video: 4, audio: 1))
        try t.tracks[0].overwrite(media(.zero, Time(20, 1)))
        let ids = try t.placeBlock(cb, at: Time(5, 1))
        #expect(ids.count == 2)
        let v = t.tracks.filter { $0.kind == .video }
        let first = try #require(v[1].clips.first), second = try #require(v[2].clips.first)
        #expect(first.id == ids[0] && second.id == ids[1])
        #expect(first.start == Time(5, 1) && second.start == Time(5, 1) + Time(1, 2))
        #expect(first.media == first.id)
        #expect(v[0].clips.count == 1 && v[0].clips[0].timeline.duration == Time(20, 1))   // untouched
        #expect(v[1].transitions.count == 1)
        #expect(v[1].transitions[0].incoming == first.id && v[1].transitions[0].kind == .move)
        #expect(!cb.entries.map(\.clip.id).contains(first.id))                              // new IDs
    }

    @Test func addsTracksWhenNoneIsFreeAndPlacesTwiceWithoutOverwriting() throws {
        let cb = try block()
        var t = Timeline(name: "dst", frameDuration: fd, tracks: Timeline.defaultTracks(video: 1, audio: 1))
        let a = try t.placeBlock(cb, at: .zero), b = try t.placeBlock(cb, at: .zero)
        #expect(Set(a + b).count == 4)
        let v = t.tracks.filter { $0.kind == .video }
        #expect(v.count == 4)
        #expect(v.dropFirst().allSatisfy { $0.clips.count == 1 })
    }

    @Test func refusesMediaTracksAndEmptyBlocks() throws {
        var t = Timeline(name: "dst", frameDuration: fd, tracks: Timeline.defaultTracks(video: 2, audio: 1))
        #expect(throws: EditError.self) { try t.placeBlock(TimelineClipboard(entries: []), at: .zero) }
        var audio = media(.zero, Time(1, 1)); audio.kind = .audio
        #expect(throws: EditError.self) { try t.placeBlock(TimelineClipboard(entries: [.init(clip: audio, offset: .zero, lane: 0)]), at: .zero) }
    }

    @Test func clipboardRoundTripsThroughJSON() throws {
        let cb = try block()
        let back = try JSONDecoder().decode(TimelineClipboard.self, from: JSONEncoder().encode(cb))
        #expect(back == cb)
    }
}
