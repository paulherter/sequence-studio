import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> (EditorSession, StubProgramEngine, MediaRef) {
    let engine = StubProgramEngine()
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
    let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, engine, m)
}

@MainActor @Suite struct SourceFlowSessionTests {
    @Test func sequenceOutOnlyBackTimesTheEdit() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)        // 3 s of source
        session.seek(to: s(20)); session.markOut()                                          // Out frame at 20 s, no In
        let outEnd = session.activeTimeline!.inOut!.end                                     // stored end: one frame past the Out frame
        session.seek(to: s(1))
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        #expect(!clips.isEmpty)
        #expect(clips.allSatisfy { $0.start == outEnd - s(3) })
        #expect(clips.allSatisfy { $0.timeline.end == outEnd })
    }

    @Test func sequenceInStillWinsOverAnOut() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)
        session.seek(to: s(4)); session.markIn()
        let inAt = session.playhead
        session.seek(to: s(30)); session.markOut()
        session.seek(to: .zero)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).allSatisfy { $0.start == inAt })
    }

    @Test func markInAndOutAreOneUndoStepEach() {
        let (session, _, _) = makeSession()
        session.seek(to: s(1)); session.markIn()
        let inAt = session.playhead
        #expect(session.undoName == "Mark In")
        session.seek(to: s(3)); session.markOut()
        #expect(session.undoName == "Mark Out")
        session.undo()
        #expect(session.activeTimeline?.inOut?.start == inAt)
    }

    @Test func markOutAtFrameZeroIsAllowed() {
        let (session, _, _) = makeSession()
        session.markOut()
        #expect(session.activeTimeline?.inOut == TimeRange(start: .zero, end: session.activeTimeline!.frameDuration))
    }

    @Test func playAroundPlaysFromPrerollAndComesBack() {
        let (session, engine, m) = makeSession()
        session.perform("Place") { _ in }
        _ = session.sourceEdit(media: m.id, mode: .overwrite)                              // 10 s on the sequence
        session.seek(to: s(5))
        session.playAround(preroll: s(3), postroll: s(2))
        #expect(session.bounds.range == TimeRange(start: s(2), end: s(7)))
        #expect(session.bounds.returnTo == s(5))
        #expect(session.isPlaying)
        #expect(engine.calls.contains(.seek(s(2))))
    }

    @Test func playInToOutWithRollExtendsTheRange() {
        let (session, _, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        session.seek(to: s(4)); session.markIn()
        session.seek(to: s(6)); session.markOut()
        session.playInToOut(preroll: s(3), postroll: s(2))
        let fd = session.activeTimeline!.frameDuration
        #expect(session.bounds.range == TimeRange(start: s(1), end: s(8) + fd))
        #expect(session.bounds.returnTo == nil)
        session.stopPlayback()
        session.playInToOut()                                                              // plain: exactly In..Out
        #expect(session.bounds.range == TimeRange(start: s(4), end: s(6) + fd))
    }

    @Test func sourceMarkersAreNotUndoSteps() {
        let (session, _, m) = makeSession()
        session.perform("Rename") { $0.name = "Renamed" }
        let name = session.undoName
        var p = session.project
        p.addSourceMarker(at: s(2), frameDuration: Time(1, 30), to: m.id)
        session.setSourceMarkers(p.sourceMarkers(for: m.id), for: m.id)
        #expect(session.undoName == name)
        session.undo()
        #expect(session.project.name != "Renamed")
        #expect(session.project.sourceMarkers(for: m.id).count == 1)       // the undo did not revert the marker
        session.setSourceMarkers(nil, for: m.id)
        #expect(session.project.media(m.id)?.sourceMarkers == nil)
    }

    @Test func gripDragIsOneUndoStep() {
        let (session, _, _) = makeSession()
        session.setInPoint(at: s(2))
        session.setOutPoint(at: s(5))
        #expect(session.activeTimeline?.inOut == TimeRange(start: s(2), end: s(5) + session.activeTimeline!.frameDuration))
        #expect(session.undoName == "Mark Out")
    }

    @Test func reverseRangePlaybackParksOnTheInFrameForwardOnTheOutFrame() {
        let (session, engine, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        session.seek(to: s(4)); session.markIn()
        let inAt = session.playhead
        session.seek(to: s(6)); session.markOut()
        let fd = session.activeTimeline!.frameDuration
        let outFrame = session.playhead
        session.playInToOut()
        // J while playing In to Out: reverse inside the range reaches the In frame and stops exactly there.
        engine.play(PlaybackRate(-1))
        engine.simulatePlayback(advance: .zero - (engine.position - inAt))
        #expect(!session.isPlaying)
        #expect(session.playhead == inAt)
        // Forward ends on the Out frame.
        session.playInToOut()
        engine.simulatePlayback(advance: outFrame - engine.position)
        #expect(!session.isPlaying && session.playhead == outFrame)
        #expect(outFrame + fd == session.activeTimeline!.inOut!.end)
    }

    @Test func reversePlayAroundReturnsToTheStart() {
        let (session, engine, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        session.seek(to: s(5))
        let here = session.playhead
        session.playAround(preroll: s(3), postroll: s(2))
        engine.play(PlaybackRate(-1))
        engine.simulatePlayback(advance: .zero - s(10))
        #expect(!session.isPlaying)
        #expect(session.playhead == here && session.bounds.range == nil)
    }

    /// The engine parks a pause on the frame on the glass, ahead of the position it reported last, and reports it once
    /// it is paused. Close to the end that was taken for "played to the end".
    @Test func aPauseJustBeforeTheEndStaysWhereItPaused() {
        let (session, engine, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)                              // 10 s on the sequence
        let fd = session.activeTimeline!.frameDuration
        session.seek(to: s(9))
        session.playPause()
        engine.simulatePlayback(advance: s(1) - fd * 4)                                     // four frames before the end
        #expect(session.isPlaying)
        engine.pauseParksAhead = fd * 2
        session.playPause()
        #expect(!session.isPlaying && engine.rate.isPaused)
        #expect(session.playhead == s(10) - fd * 2, "not the end: \(session.playhead)")
        #expect(engine.calls.filter { $0 == .pause }.count == 1)
    }

    @Test func aPauseJustBeforeTheEndOfPlayAroundDoesNotJumpBack() {
        let (session, engine, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        let fd = session.activeTimeline!.frameDuration
        session.seek(to: s(5))
        session.playAround(preroll: s(3), postroll: s(2))                                   // plays 2 s ... 7 s
        engine.simulatePlayback(advance: s(5) - fd * 4)
        #expect(session.isPlaying)
        engine.pauseParksAhead = fd * 2
        session.playPause()
        #expect(!session.isPlaying)
        #expect(session.playhead == s(7) - fd * 2, "not back at the origin: \(session.playhead)")
    }

    @Test func changingTheActiveSequenceStopsPlaybackAndClearsTheRange() {
        let (session, engine, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        session.perform("New") { $0.timelines.append(Timeline(name: "Short", frameDuration: Time(1, 30))) }
        session.seek(to: s(6))
        session.playAround(preroll: s(1), postroll: s(1))
        #expect(session.isPlaying && session.bounds.returnTo != nil)
        let other = session.project.timelines.last!.id
        session.setActiveTimeline(other)
        #expect(!session.isPlaying && engine.rate.isPaused)
        #expect(session.bounds.range == nil && session.bounds.returnTo == nil)
        #expect(session.playhead == .zero)                                  // clamped into the empty sequence
    }

    @Test func deletingTheActiveSequenceDoesTheSame() {
        let (session, _, m) = makeSession()
        _ = session.sourceEdit(media: m.id, mode: .overwrite)
        session.perform("New") { $0.timelines.append(Timeline(name: "Short", frameDuration: Time(1, 30))) }
        session.seek(to: s(6))
        session.playInToOut()
        let first = session.activeTimelineID!
        session.perform("Delete") { _ = $0.deleteSequence(first) }
        #expect(session.activeTimelineID != first)
        #expect(!session.isPlaying && session.bounds.range == nil)
        #expect(session.playhead == .zero)
    }

    @Test func outOnlyEditCutsTheSourceHeadWhenThereIsNoRoom() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(8)), for: m.id)       // 6 s
        session.seek(to: s(3)); session.markOut()                                          // Out frame at 3 s: 3 s + 1 frame of room
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let fd = session.activeTimeline!.frameDuration
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        #expect(clips.allSatisfy { $0.start == .zero && $0.timeline.end == s(3) + fd })
        #expect(clips.allSatisfy { $0.source.end == s(8) })
    }

    @Test func fourMarksUseTheSequenceRangeAndSaySo() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(1), markOut: s(9)), for: m.id)
        session.seek(to: s(4)); session.markIn()
        session.seek(to: s(6)); session.markOut()
        let range = session.activeTimeline!.inOut!
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let c = session.activeTimeline!.tracks.flatMap(\.clips)[0]
        let off = c.timeline.duration - range.duration           // the empty sequence adopts the clip's frame grid: within a frame
        #expect(c.start == range.start && c.source.start == s(1) && (off < Time(1, 20) && Time(-1, 20) < off))
        #expect(session.lastError?.contains("Four marks") == true)
    }

    @Test func clearInKeepsTheOutAndClearOutKeepsTheIn() {
        let (session, _, _) = makeSession()
        session.seek(to: s(1)); session.markIn()
        session.seek(to: s(3)); session.markOut()
        session.clearIn()
        #expect(session.activeTimeline?.explicitMarks.markIn == nil && session.activeTimeline?.explicitMarks.markOut != nil)
        session.seek(to: s(1)); session.markIn()
        session.clearOut()
        #expect(session.activeTimeline?.explicitMarks.markIn != nil && session.activeTimeline?.explicitMarks.markOut == nil)
    }
}
