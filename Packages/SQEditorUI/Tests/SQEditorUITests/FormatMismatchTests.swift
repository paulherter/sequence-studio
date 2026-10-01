import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct FormatMismatchTests {
    private func media(w: Int, h: Int, fd: Time) -> MediaRef {
        let v = VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false)
        return MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1),
                        info: MediaInfo(duration: Time(4, 1), video: v, audio: nil))
    }

    private func session(with m: MediaRef) -> EditorSession {
        var p = EditorSession.makeUntitled()
        p.add(m)
        p.timelines[0].format = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mm-\(UUID().uuidString)")
        return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
    }

    @Test func differentClipReportsTheFormatItWouldAdopt() throws {
        let m = media(w: 1080, h: 1920, fd: Time(1, 60))
        let s = session(with: m)
        let f = try #require(s.formatMismatch(placing: [m.id]))
        #expect(f.width == 1080 && f.height == 1920 && f.frameDuration == Time(1, 60))
    }

    @Test func matchingClipAsksNothing() {
        let m = media(w: 1920, h: 1080, fd: Time(1, 30))
        #expect(session(with: m).formatMismatch(placing: [m.id]) == nil)
    }

    @Test func keepExistingSettingsPlacesWithoutChangingTheSequence() throws {
        let m = media(w: 3840, h: 2160, fd: Time(1, 25))
        let s = session(with: m)
        #expect(s.formatMismatch(placing: [m.id]) != nil)
        #expect(s.placeMedia([m.id], mode: .overwrite, adoptFormat: false))
        let f = try #require(s.activeTimeline?.format)
        #expect(f.width == 1920 && f.height == 1080 && f.frameDuration == Time(1, 30))
        // Not empty any more: no further question.
        #expect(s.formatMismatch(placing: [m.id]) == nil)
    }

    @Test func configuredOrFilledSequenceNeverAsks() {
        let m = media(w: 3840, h: 2160, fd: Time(1, 25))
        let s = session(with: m)
        #expect(s.setSequenceFormat(SequenceFormat(width: 1080, height: 1080, frameDuration: Time(1, 30))))
        #expect(s.formatMismatch(placing: [m.id]) == nil)
    }
}
