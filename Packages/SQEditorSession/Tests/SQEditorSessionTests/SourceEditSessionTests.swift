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

    @Test func durationIsSnappedToSequenceFrames() {
        // 24 fps source of 10 s, sequence 30 fps (default makeSession media is 30 fps): marks give 1.01 s.
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(0), markOut: Time(101, 100)), for: m.id)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let c = session.activeTimeline!.tracks.flatMap(\.clips).first!
        #expect(c.source.duration == c.source.duration.snapped(to: Time(1, 30)))
        #expect(session.playhead == c.start + c.source.duration)
    }

    @Test func sixtyInTwentyFiveStaysOnTheGrid() {
        let (session, _, m) = makeSession()
        session.perform("fmt") { _ = try? $0.setFormat(SequenceFormat(frameDuration: Time(1, 25)), of: $0.timelines[0].id) }
        session.setSourceMarks(SourceMarks(markIn: .zero, markOut: Time(103, 100)), for: m.id)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let c = session.activeTimeline!.tracks.flatMap(\.clips).first!
        #expect(c.source.duration == c.source.duration.snapped(to: Time(1, 25)))
        #expect(c.source.duration == Time(26, 25))
    }
}

@MainActor @Suite struct FitToFillSessionTests {
    @Test func fourMarksRetimeTheSourceIntoTheSequenceRange() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(1), markOut: s(9)), for: m.id)
        session.perform("In") { _ = try? $0.edit(session.activeTimelineID!) { $0.inOut = TimeRange(start: s(2), end: s(6)); $0.inOutKind = .both } }
        #expect(session.sourceEdit(media: m.id, mode: .overwrite, fitToFill: true))
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        #expect(!clips.isEmpty)
        #expect(clips.allSatisfy { $0.source == TimeRange(start: s(1), end: s(9)) && $0.speed == ClipSpeed(num: 2, den: 1) })
        #expect(clips.allSatisfy { $0.timeline == TimeRange(start: s(2), end: s(6)) })
        #expect(session.playhead == s(6))
    }

    @Test func withoutSequenceRangeNothingIsPlacedAndTheReasonIsReported() {
        let (session, _, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(1), markOut: s(3)), for: m.id)
        #expect(!session.sourceEdit(media: m.id, mode: .overwrite, fitToFill: true))
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).isEmpty)
        #expect(session.lastError?.contains("Fit to Fill") == true)
    }
}
