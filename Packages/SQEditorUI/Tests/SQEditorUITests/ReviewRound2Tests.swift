import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession(duration: Time = s(10), fps: Time = Time(1, 30)) -> (EditorSession, StubProgramEngine, MediaRef) {
    let engine = StubProgramEngine()
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: fps, isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: duration, info: MediaInfo(duration: duration, video: v, audio: a))
    let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, engine, m)
}

@MainActor @Suite struct ReviewRound2Tests {
    // Review finding 2: placeMedia kept raw (off-grid) source durations.
    @Test func placeMediaStaysOnFrameGrid() {
        let (session, _, m) = makeSession(duration: Time(1001, 100))
        #expect(session.placeMedia([m.id, m.id], at: .zero))
        let fd = session.activeTimeline!.frameDuration
        for c in session.activeTimeline!.tracks.flatMap(\.clips) {
            #expect(c.start == c.start.snapped(to: fd))
            #expect(c.source.duration == c.source.duration.snapped(to: fd))
        }
    }
}
