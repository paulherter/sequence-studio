import Foundation
import Testing
import SQCore
@testable import SQPlayback

@MainActor final class FakeMicrophone: MicrophoneCapturing {
    var allow = true
    var startError: Error?
    var length = Time(5, 2)
    private(set) var startedURL: URL?
    private(set) var stopped = false
    var elapsed: Double { 1.5 }
    func requestAccess() async -> Bool { allow }
    func start(to url: URL) throws {
        if let startError { throw startError }
        startedURL = url
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
    }
    func stop() -> Time? { stopped = true; return length }
}

@MainActor @Suite struct VoiceRecorderTests {
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("vr-\(UUID().uuidString).wav") }

    @Test func countsDownThenRecordsAndReturnsTheTake() async throws {
        let mic = FakeMicrophone()
        var seen: [VoiceRecorderState] = []
        let r = VoiceRecorder(capture: mic, countdown: 3, sleep: { _ in })
        r.onChange = { seen.append($0) }
        let u = url()
        try await r.start(to: u, anchor: Time(7, 1))
        #expect(r.state == .recording)
        #expect(seen == [.requestingAccess, .countdown(3), .countdown(2), .countdown(1), .recording])
        #expect(mic.startedURL == u)
        let take = try r.stop()
        #expect(take == VoiceRecording(url: u, duration: Time(5, 2), anchor: Time(7, 1)))
        #expect(r.state == .idle)
        try? FileManager.default.removeItem(at: u)
    }

    @Test func deniedAccessThrowsAndStaysIdle() async {
        let mic = FakeMicrophone(); mic.allow = false
        let r = VoiceRecorder(capture: mic, countdown: 0, sleep: { _ in })
        await #expect(throws: VoiceRecorderError.accessDenied) { try await r.start(to: url(), anchor: .zero) }
        #expect(r.state == .idle)
        #expect(mic.startedURL == nil)
    }

    @Test func cancelDuringCountdownNeverStartsTheMic() async {
        let mic = FakeMicrophone()
        let box = RecorderBox()
        let r = VoiceRecorder(capture: mic, countdown: 3, sleep: { _ in await box.cancel() })
        box.recorder = r
        await #expect(throws: VoiceRecorderError.canceled) { try await r.start(to: url(), anchor: .zero) }
        #expect(r.state == .idle)
        #expect(mic.startedURL == nil)
    }

    @Test func cancelWhileRecordingDeletesTheFile() async throws {
        let mic = FakeMicrophone()
        let r = VoiceRecorder(capture: mic, countdown: 0, sleep: { _ in })
        let u = url()
        try await r.start(to: u, anchor: .zero)
        #expect(FileManager.default.fileExists(atPath: u.path))
        r.cancel()
        #expect(mic.stopped)
        #expect(!FileManager.default.fileExists(atPath: u.path))
        #expect(r.state == .idle)
    }

    @Test func secondStartWhileBusyIsRefusedAndStopWhenIdleThrows() async throws {
        let r = VoiceRecorder(capture: FakeMicrophone(), countdown: 0, sleep: { _ in })
        #expect(throws: VoiceRecorderError.notRecording) { try r.stop() }
        let u = url()
        try await r.start(to: u, anchor: .zero)
        await #expect(throws: VoiceRecorderError.busy) { try await r.start(to: u, anchor: .zero) }
        r.cancel()
    }

    @Test func micFailureSurfacesAndStaysIdle() async {
        let mic = FakeMicrophone(); mic.startError = VoiceRecorderError.failed
        let r = VoiceRecorder(capture: mic, countdown: 0, sleep: { _ in })
        await #expect(throws: VoiceRecorderError.failed) { try await r.start(to: url(), anchor: .zero) }
        #expect(r.state == .idle)
    }
}

@MainActor private final class RecorderBox {
    var recorder: VoiceRecorder?
    func cancel() { recorder?.cancel() }
}
