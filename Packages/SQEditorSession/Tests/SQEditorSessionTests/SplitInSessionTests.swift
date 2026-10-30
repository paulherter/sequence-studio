import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

@MainActor @Suite struct SplitInSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func makeSession() -> (EditorSession, MediaRef) {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
        let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(
            base: FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString)"),
            policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { $0.add(m) }
        return (session, m)
    }

    @Test func audioInBeforeVideoInMakesALinkedJCutOverwrite() {
        let (session, m) = makeSession()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5), audioIn: s(1)), for: m.id)
        session.seek(to: s(10))
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        let v = clips.first { $0.kind == .video }!, a = clips.first { $0.kind == .audio }!
        #expect(v.start == s(10) && v.source == TimeRange(start: s(2), end: s(5)))
        #expect(a.start == s(9) && a.source == TimeRange(start: s(1), end: s(5)))
        #expect(v.link != nil && v.link == a.link)
        #expect(session.playhead == s(13))
    }

    @Test func noSplitWhenBothInsMatch() {
        let m = SourceMarks(markIn: s(2), markOut: s(5), audioIn: s(2))
        #expect(m.splitIns(total: s(10)) == nil)
        #expect(SourceMarks(markIn: s(2), videoIn: s(4)).splitIns(total: s(10))?.video == s(4))
    }

    @Test func plainInClearsSplitIns() {
        var p = Project(name: "P")
        let id = UUID()
        p.setSourceAudioIn(s(1), for: id)
        p.setSourceIn(s(2), for: id)
        #expect(p.sourceMarks(for: id).audioIn == nil)
    }
}
