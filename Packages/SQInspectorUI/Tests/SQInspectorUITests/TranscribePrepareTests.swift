import Foundation
import Testing
import SQCore
import SQTranscribe
@testable import SQInspectorUI

private final class PrepareLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct PreparingService: TranscriptionService {
    let log: PrepareLog
    var prepareError: Error?
    func prepare(locale: Locale) async throws {
        log.add("prepare \(locale.identifier)")
        if let prepareError { throw prepareError }
    }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        log.add("transcribe")
        return Transcript(language: locale.identifier, words: [
            TranscriptWord(text: "Hallo", range: TimeRange(start: .zero, duration: Time(1, 2)))])
    }
}

@MainActor @Suite struct TranscribePrepareTests {
    @Test func languageModelIsPreparedBeforeTranscribing() async {
        let log = PrepareLog()
        let m = CaptionsPanelModel(service: PreparingService(log: log))
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        m.transcribe()
        await m.waitForTranscription()
        #expect(log.value == ["prepare de-DE", "transcribe"])
        #expect(m.state == .ready && m.statusNote == nil)
    }

    @Test func preparationFailureIsShownAndNothingIsTranscribed() async {
        let log = PrepareLog()
        let m = CaptionsPanelModel(service: PreparingService(log: log, prepareError: TranscriptionError.localeUnsupported("xx-XX")))
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        m.transcribe()
        await m.waitForTranscription()
        #expect(log.value == ["prepare de-DE"])
        if case .failed(let msg) = m.state { #expect(msg.contains("xx-XX")) } else { Issue.record("not failed") }
        #expect(m.statusNote == nil)
    }
}

private struct DownloadingService: TranscriptionService {
    let gate: AsyncStream<Void>
    func prepare(locale: Locale) async throws {}
    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        for await _ in gate { break }           // holds the download until the test has looked at the note
    }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        Transcript(language: locale.identifier, words: [])
    }
}

@MainActor @Suite struct TranscribeDownloadNoteTests {
    @Test func theNoteShowsTheDownloadShareAndClearsWhenDone() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let m = CaptionsPanelModel(service: DownloadingService(gate: gate))
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        m.transcribe()
        for _ in 0..<200 where !(m.statusNote ?? "").contains("50 %") { try await Task.sleep(for: .milliseconds(10)) }
        #expect((m.statusNote ?? "").contains("50 %"))
        open.yield()
        await m.waitForTranscription()
        #expect(m.statusNote == nil)
    }
}
