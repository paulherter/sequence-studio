import Foundation
import Testing
import SSCore
import SSMedia
@testable import SSEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> (EditorSession, StubProgramEngine, MediaRef) {
    let engine = StubProgramEngine()
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
    let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("ss-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, engine, m)
}

@MainActor @Suite struct SourceEditSessionTests {
    @Test func overwriteUsesMarksPlayheadAndAdvances() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)
        session.seek(to: s(10))
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { $0.start == s(10) && $0.source == TimeRange(start: s(2), end: s(5)) })
        #expect(session.playhead == s(13))
    }

    @Test func sequenceInOverridesPlayhead() {
        let (session, _, m) = makeSession()
        session.perform("In") { _ = try? $0.edit(session.activeTimelineID!) { $0.inOut = TimeRange(start: s(4), end: s(8)) } }
        session.seek(to: s(1))
        #expect(session.sourceEdit(media: m.id, mode: .insert))
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).allSatisfy { $0.start == s(4) })
        #expect(session.playhead == s(14))
    }

    @Test func videoOnlyPlacesNoAudio() {
        let (session, _, m) = makeSession()
        #expect(session.sourceEdit(media: m.id, streams: .videoOnly, mode: .overwrite))
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).map(\.kind) == [.video])
    }

    @Test func marksAreNotUndoSteps() {
        let (session, _, m) = makeSession()
        let name = session.undoName
        session.setSourceMarks(SourceMarks(markIn: s(1)), for: m.id)
        #expect(session.undoName == name)
        session.undo()
        #expect(session.project.sourceMarks(for: m.id).markIn == s(1))
        session.setSourceMarks(nil, for: m.id)
        #expect(session.project.sourceMarks[m.id] == nil)
    }
}
