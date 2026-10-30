import Foundation
import Testing
import SQCore
import SQTranscribe
@testable import SQEditorUI
@testable import SQInspectorUI

private final class CountingService: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let result: Result<Transcript, Error>
    init(_ r: Result<Transcript, Error>) { result = r }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        lock.withLock { n += 1 }
        return try result.get()
    }
}

private func w(_ text: String, _ s: Int64, _ e: Int64) -> TranscriptWord {
    TranscriptWord(text: text, range: TimeRange(start: Time(s, 10), end: Time(e, 10)))
}

private let words = Transcript(language: "de-DE", words: [w("Hallo", 0, 5), w("liebe", 6, 10), w("Welt.", 10, 15), w("Weiter", 30, 35)])

/// Sequence > Transcribe and Create Captions (Cmd+Option+C): one command for the maintainer's last step before export.
@MainActor @Suite struct AutoCaptionsTests {
    private func model(_ r: Result<Transcript, Error> = .success(words)) -> (CaptionsPanelModel, CountingService) {
        let s = CountingService(r)
        let m = CaptionsPanelModel(service: s)
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        return (m, s)
    }

    @Test func transcribesThenCreatesCaptions() async {
        let (m, s) = model()
        var handed: [Caption] = []
        m.onCreateCaptions = { handed = $0 }
        let made = await m.transcribeAndCreateCaptions()
        #expect(s.calls == 1)
        #expect(!made.isEmpty)
        #expect(handed == made)
    }

    @Test func aCurrentTranscriptIsReusedWithItsEdits() async {
        let (m, s) = model()
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Welt. Weiter!")
        let made = await m.transcribeAndCreateCaptions()      // flushes the edit, does not transcribe again
        #expect(s.calls == 1)
        #expect(made.flatMap(\.lines).joined(separator: " ").contains("Weiter!"))
    }

    @Test func failedTranscriptionCreatesNothing() async {
        let (m, _) = model(.failure(TranscriptionError.noAudio))
        var called = false
        m.onCreateCaptions = { _ in called = true }
        let made = await m.transcribeAndCreateCaptions()
        #expect(made.isEmpty)
        #expect(!called)
        if case .failed = m.state {} else { Issue.record("not failed") }
    }
}
