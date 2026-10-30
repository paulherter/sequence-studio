import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Where a new graphic, text or shape goes: the lowest video track that is free and above everything under it.
@MainActor @Suite struct GeneratorTrackPlacementTests {
    private struct Case: Sendable { let name: String; let busy: [Int]; let locked: [Int]; let expected: Int? }   // 0-based video tracks

    /// Six video tracks; `busy` tracks hold a clip over 0..5 s, plus one clip on V5 later in time (never overlapping).
    private func timeline(busy: [Int], locked: [Int]) -> Timeline {
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30),
                                                         tracks: (0..<6).map { _ in Track(kind: .video) } + [Track(kind: .audio)])])
        let tl = p.timelines[0].id
        for i in busy { _ = try! p.addGraphicsClip(in: tl, at: s(0), track: p.timelines[0].tracks[i].id, duration: s(5)) }
        _ = try! p.addGraphicsClip(in: tl, at: s(20), track: p.timelines[0].tracks[4].id, duration: s(2))
        for i in locked { p.timelines[0].tracks[i].isLocked = true }
        return p.timelines[0]
    }

    @Test(arguments: [
        Case(name: "Case: V1 and V2 busy, V3 free", busy: [0, 1], locked: [], expected: 2),
        Case(name: "empty sequence: V1", busy: [], locked: [], expected: 0),
        Case(name: "only V1 busy", busy: [0], locked: [], expected: 1),
        Case(name: "gap below footage is skipped (V2 free, V3 busy)", busy: [2], locked: [], expected: 3),
        Case(name: "V3 locked: next free above", busy: [0, 1], locked: [2], expected: 3),
        Case(name: "all but V6 busy: V6", busy: [0, 1, 2, 3, 4], locked: [], expected: 5),
        Case(name: "everything busy: none qualifies", busy: [0, 1, 2, 3, 4, 5], locked: [], expected: nil),
        Case(name: "V6 busy: nothing above it", busy: [5], locked: [], expected: nil),
        Case(name: "locked tracks above footage", busy: [0], locked: [1, 2, 3, 4, 5], expected: nil),
    ])
    private func lowestFreeTrackAboveTheFootage(_ c: Case) {
        let t = timeline(busy: c.busy, locked: c.locked)
        let video = t.tracks.filter { $0.kind == .video }
        let got = EditorSession.generatorTrack(in: t, for: TimeRange(start: s(1), duration: s(3)), preferred: nil, allowOverwrite: false)
        #expect(got == c.expected.map { video[$0].id }, Comment(rawValue: c.name))
    }

    @Test func overwriteFallbackIsTheTopmostUnlockedTrack() {
        let t = timeline(busy: [0, 1, 2, 3, 4, 5], locked: [5])
        let video = t.tracks.filter { $0.kind == .video }
        #expect(EditorSession.generatorTrack(in: t, for: TimeRange(start: s(1), duration: s(3)), preferred: nil) == video[4].id)
    }

    @Test func aPreferredVideoTrackWins() {
        let t = timeline(busy: [0], locked: [])
        let video = t.tracks.filter { $0.kind == .video }
        #expect(EditorSession.generatorTrack(in: t, for: TimeRange(start: s(1), duration: s(3)), preferred: video[0].id) == video[0].id)
    }

    @Test func aClipElsewhereInTimeDoesNotRaiseTheTrack() {
        let t = timeline(busy: [], locked: [])   // only the V5 clip at 20 s exists
        let video = t.tracks.filter { $0.kind == .video }
        #expect(EditorSession.generatorTrack(in: t, for: TimeRange(start: s(1), duration: s(3)), preferred: nil) == video[0].id)
        #expect(EditorSession.generatorTrack(in: t, for: TimeRange(start: s(20), duration: s(1)), preferred: nil) == video[5].id)
    }

    @Test func aNewGraphicStaysTheTargetOfTheNextCreatedItemAndUndoesInOneStep() throws {
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30),
                                                                                     tracks: [Track(kind: .video), Track(kind: .video)])]))
        let depth = session.undoDepth
        let id = try #require(session.addGraphicsClip(duration: s(4), neverOverwrite: true))
        #expect(session.selection == [id])
        #expect(session.activeTimeline?.graphicCreateTarget(selection: session.selection, at: session.playhead) == id)
        session.undo()
        #expect(session.undoDepth == depth)
    }

    @Test func newGraphicLandsOnTheFirstFreeTrackAboveTheFootage() throws {
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: (0..<6).map { _ in Track(kind: .video) })])
        let tl = p.timelines[0].id
        _ = try p.addGraphicsClip(in: tl, at: s(0), track: p.timelines[0].tracks[0].id, duration: s(5))
        _ = try p.addGraphicsClip(in: tl, at: s(0), track: p.timelines[0].tracks[1].id, duration: s(5))
        let session = EditorSession(project: p)
        let id = try #require(session.addGraphicsClip(duration: s(2)))
        #expect(session.activeTimeline?.tracks[2].clips.contains { $0.id == id } == true)
    }
}
