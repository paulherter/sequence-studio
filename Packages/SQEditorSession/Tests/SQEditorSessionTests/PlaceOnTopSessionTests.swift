import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> (EditorSession, MediaRef) {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
    let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, m)
}

@MainActor @Suite struct PlaceOnTopSessionTests {
    @Test func placedMediaIsExactlyTheSelection() {
        let (session, m) = makeSession()
        #expect(session.placeMedia([m.id], at: .zero))
        let first = Set(session.activeTimeline!.tracks.flatMap { $0.clips.map(\.id) })
        #expect(session.selection == first)
        #expect(session.placeMedia([m.id], at: s(20)))
        let all = Set(session.activeTimeline!.tracks.flatMap { $0.clips.map(\.id) })
        #expect(session.selection == all.subtracting(first))
    }

    @Test func sourceEditGoesAboveTheOccupiedTrackVideoOnlyHonouringMarks() {
        let (session, m) = makeSession()
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))            // V1 + A1 at 0..10
        session.seek(to: s(2))
        session.setSourceMarks(SourceMarks(markIn: s(1), markOut: s(4)), for: m.id)
        let before = session.activeTimeline!
        #expect(session.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true))
        let tl = session.activeTimeline!
        let video = tl.tracks.filter { $0.kind == .video }
        #expect(video[0].clips.count == 1 && video[1].clips.count == 1)
        let c = video[1].clips[0]
        #expect(c.start == s(2) && c.source == TimeRange(start: s(1), end: s(4)))
        #expect(tl.tracks.filter { $0.kind == .audio }.flatMap(\.clips).count == 1)   // no audio of the overlay
        session.undo()
        #expect(session.activeTimeline! == before)                                     // one undo step
    }

    @Test func fullStackAddsATrackInTheSameUndoStep() {
        let (session, m) = makeSession()
        let n = session.activeTimeline!.tracks.filter { $0.kind == .video }.count
        for _ in 0..<n { #expect(session.sourceEdit(media: m.id, streams: .videoOnly, mode: .overwrite, placeOnTop: true)); session.seek(to: .zero) }
        #expect(session.activeTimeline!.tracks.filter { $0.kind == .video }.count == n)
        let before = session.activeTimeline!
        #expect(session.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true))
        #expect(session.activeTimeline!.tracks.filter { $0.kind == .video }.count == n + 1)
        session.undo()
        #expect(session.activeTimeline! == before)
    }

    @Test func placeMediaFromTheProjectPanelAlsoGoesOnTop() {
        let (session, m) = makeSession()
        #expect(session.placeMedia([m.id], at: .zero, mode: .overwrite))
        #expect(session.placeMedia([m.id], at: s(3), mode: .overwrite, placeOnTop: true))
        let video = session.activeTimeline!.tracks.filter { $0.kind == .video }
        #expect(video[1].clips.map(\.start) == [s(3)])
    }
}
