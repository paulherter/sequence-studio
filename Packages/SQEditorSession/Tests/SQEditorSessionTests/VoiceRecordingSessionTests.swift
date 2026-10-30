import Foundation
import Testing
import SQCore
import SQMedia
import SQPlayback
@testable import SQEditorSession

@MainActor private final class Mic: MicrophoneCapturing {
    var allow = true
    var length = Time(3, 1)
    private(set) var stopCount = 0
    var elapsed: Double { 0 }
    func requestAccess() async -> Bool { allow }
    func start(to url: URL) throws { FileManager.default.createFile(atPath: url.path, contents: Data([1])) }
    func stop() -> Time? { stopCount += 1; return length }
}

@MainActor @Suite struct VoiceRecordingSessionTests {
    private func makeSession(mic: Mic) -> EditorSession {
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.voiceRecorder = VoiceRecorder(capture: mic, countdown: 0, sleep: { _ in })
        return session
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("vo-\(UUID().uuidString)") }
    private func importer(_ session: EditorSession) -> (URL) async -> MediaRef.ID? {
        { url in
            let a = AudioTrackInfo(sampleRate: 48_000, channels: 1, codec: "lpcm")
            let m = MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: MediaFingerprint(size: 1),
                             duration: Time(3, 1), info: MediaInfo(duration: Time(3, 1), video: nil, audio: a))
            session.perform("Import") { $0.add(m) }
            return m.id
        }
    }

    @Test func firstPressRecordsSecondPressPlacesAtTheStartPlayhead() async {
        let mic = Mic()
        let session = makeSession(mic: mic)
        session.seek(to: Time(2, 1))
        let dir = folder()
        let first = await session.toggleVoiceRecording(folder: dir, importer: importer(session))
        #expect(first == .started)
        session.seek(to: Time(9, 1))
        let second = await session.toggleVoiceRecording(folder: dir, importer: importer(session))
        guard case .placed(let p) = second else { Issue.record("expected placed, got \(second)"); return }
        let clip = session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == p.clip }
        #expect(clip?.start == Time(2, 1).ceiled(to: session.activeTimeline!.frameDuration))
        #expect(clip?.duration == Time(3, 1))
        #expect(session.selection == [p.clip])
        #expect(session.voiceRecorder.state == .idle)
    }

    @Test func deniedAccessReportsDeniedAndPlacesNothing() async {
        let mic = Mic(); mic.allow = false
        let session = makeSession(mic: mic)
        let before = session.activeTimeline
        let r = await session.toggleVoiceRecording(folder: folder(), importer: importer(session))
        #expect(r == .denied)
        #expect(session.activeTimeline == before)
    }

    @Test func tooShortTakeIsDroppedWithAMessage() async {
        let mic = Mic(); mic.length = Time(1, 50)
        let session = makeSession(mic: mic)
        let dir = folder()
        _ = await session.toggleVoiceRecording(folder: dir, importer: importer(session))
        let r = await session.toggleVoiceRecording(folder: dir, importer: importer(session))
        #expect(r == .failed("The recording was too short."))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    @Test func cancelDropsTheTake() async {
        let mic = Mic()
        let session = makeSession(mic: mic)
        let dir = folder()
        _ = await session.toggleVoiceRecording(folder: dir, importer: importer(session))
        session.cancelVoiceRecording()
        #expect(session.voiceRecorder.state == .idle)
        #expect(mic.stopCount == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }
}
