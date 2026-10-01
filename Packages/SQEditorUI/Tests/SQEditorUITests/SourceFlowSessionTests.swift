import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI

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
        session.seek(to: s(1))
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        let fd = session.activeTimeline!.frameDuration
        // The clip ends with the Out frame: [20 s + 1 frame - 3 s, 20 s + 1 frame).
        #expect(clips.allSatisfy { $0.start == s(20) + fd - s(3) })
        #expect(clips.allSatisfy { $0.timeline.end == s(20) + fd })
    }

    @Test func sequenceInStillWinsOverAnOut() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)
        session.seek(to: s(4)); session.markIn()
        session.seek(to: s(30)); session.markOut()
        session.seek(to: .zero)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).allSatisfy { $0.start == s(4) })
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
}
