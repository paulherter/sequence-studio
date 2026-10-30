import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

@MainActor @Suite struct VoiceoverSessionTests {
    private func makeSession() -> (EditorSession, MediaRef) {
        let a = AudioTrackInfo(sampleRate: 22_050, channels: 1, codec: "lpcm")
        let m = MediaRef(name: "VO", path: "/nonexistent/VO.caf", fingerprint: MediaFingerprint(size: 1),
                         duration: Time(4, 1), info: MediaInfo(duration: Time(4, 1), video: nil, audio: a))
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { $0.add(m) }
        return (session, m)
    }

    @Test func placesAtThePlayheadSelectsAndUndoesInOneStep() {
        let (session, m) = makeSession()
        session.seek(to: Time(3, 1))
        let before = session.activeTimeline!
        let r = session.placeVoiceover(media: m.id, name: "VO", duration: Time(4, 1))
        #expect(r != nil)
        let t = session.activeTimeline!
        let track = t.tracks.first { $0.id == r?.track }
        #expect(track?.audioRole == .dialogue)
        #expect(track?.clips.first?.start == Time(3, 1).ceiled(to: session.activeTimeline!.frameDuration))
        #expect(session.selection == [r!.clip])
        session.undo()
        #expect(session.activeTimeline! == before)
    }

    @Test func refusesAZeroLength() {
        let (session, m) = makeSession()
        #expect(session.placeVoiceover(media: m.id, name: "VO", duration: .zero) == nil)
    }
}
