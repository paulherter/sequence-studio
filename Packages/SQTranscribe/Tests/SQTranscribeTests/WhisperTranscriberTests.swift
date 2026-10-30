import Foundation
import SQCore
import Testing
@testable import SQTranscribe

@Suite struct WhisperTranscriberTests {
    final class FakeEngine: WhisperEngine, @unchecked Sendable {
        var available: String? = nil
        var tokens: [WhisperToken] = []
        var sawLanguage = "", sawSamples = 0, sawPath = ""
        var waitForCancel = false
        func unavailableReason() -> String? { available }
        func recognize(modelPath: String, samples: [Float], language: String, progress: @Sendable (Double) -> Void,
                       isCancelled: @Sendable () -> Bool) throws -> [WhisperToken] {
            sawLanguage = language; sawSamples = samples.count; sawPath = modelPath
            progress(0.5)
            if waitForCancel {
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
                throw CancellationError()
            }
            return tokens
        }
    }

    private func installed() throws -> (WhisperModelStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-wt-\(UUID().uuidString)")
        let m = WhisperModel(name: "t", fileName: "m.bin", url: URL(string: "https://example.com/m.bin")!, byteCount: 4)
        let store = WhisperModelStore(folder: dir, model: m)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 4).write(to: store.modelURL)
        return (store, dir)
    }

    @Test func wordsLanguageAndProgressComeThrough() async throws {
        let (store, dir) = try installed(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine()
        engine.tokens = [WhisperToken(bytes: Array(" Hallo".utf8), isSpecial: false, startCs: 0, endCs: 50, probability: 0.9)]
        let t = WhisperTranscriber(store: store, engine: engine, downloader: nil, audio: { _ in [Float](repeating: 0, count: 16_000) })
        let seen = Seen()
        let r = try await t.transcribe(url: URL(fileURLWithPath: "/x.wav"), locale: Locale(identifier: "de-DE")) { seen.add($0) }
        #expect(r.words.map(\.text) == ["Hallo"])
        #expect(engine.sawLanguage == "de" && engine.sawSamples == 16_000 && engine.sawPath == store.modelURL.path)
        #expect(seen.values.contains(0.5) && seen.values.last == 1)
    }

    @Test func emptyAudioIsNoAudioAndAnUnknownLanguageIsRefused() async throws {
        let (store, dir) = try installed(); defer { try? FileManager.default.removeItem(at: dir) }
        let t = WhisperTranscriber(store: store, engine: FakeEngine(), downloader: nil, audio: { _ in [] })
        await #expect(throws: TranscriptionError.noAudio) { try await t.transcribe(url: URL(fileURLWithPath: "/x"), locale: Locale(identifier: "de")) { _ in } }
        await #expect(throws: TranscriptionError.localeUnsupported("tlh")) { try await t.transcribe(url: URL(fileURLWithPath: "/x"), locale: Locale(identifier: "tlh")) { _ in } }
    }

    @Test func aMissingEngineSaysSoInPrepare() async throws {
        let (store, dir) = try installed(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(); engine.available = "whisper.dll not found"
        let t = WhisperTranscriber(store: store, engine: engine, downloader: nil, audio: { _ in [0] })
        await #expect(throws: TranscriptionError.engineMissing("whisper.dll not found")) { try await t.prepare(locale: Locale(identifier: "de-DE"), progress: { _ in }) }
    }

    @Test func prepareDownloadsAMissingModelWithProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-wt-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = WhisperModel(name: "t", fileName: "m.bin", url: URL(string: "https://example.com/m.bin")!, byteCount: 100)
        let store = WhisperModelStore(folder: dir, model: m)
        let t = WhisperTranscriber(store: store, engine: FakeEngine(), downloader: WhisperModelStoreTests.Fake(bytes: 100), audio: { _ in [0] })
        let seen = Seen()
        try await t.prepare(locale: Locale(identifier: "en-US")) { seen.add($0) }
        #expect(store.isInstalled && seen.values.last == 1)
    }

    @Test func cancelingTheTaskStopsTheEngine() async throws {
        let (store, dir) = try installed(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(); engine.waitForCancel = true
        let t = WhisperTranscriber(store: store, engine: engine, downloader: nil, audio: { _ in [0, 0] })
        let task = Task { try await t.transcribe(url: URL(fileURLWithPath: "/x"), locale: Locale(identifier: "de")) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
