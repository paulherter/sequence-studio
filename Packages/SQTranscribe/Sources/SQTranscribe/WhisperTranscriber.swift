import Foundation
import SQCore

/// The recognizer behind `WhisperTranscriber`: blocking, runs on a background thread. `WhisperRuntime` (whisper.cpp, loaded at
/// run time) is the real one, tests use a fake.
public protocol WhisperEngine: Sendable {
    /// nil when the engine can run, else a short reason for the status line ("whisper.dll not found").
    func unavailableReason() -> String?
    /// Recognizes 16 kHz mono `samples` in `language` (a Whisper code). `progress` reports 0...1, `isCancelled` is polled and
    /// ends the run (throw `CancellationError`). Words come back as tokens with word-level timing.
    func recognize(modelPath: String, samples: [Float], language: String, progress: @Sendable (Double) -> Void,
                   isCancelled: @Sendable () -> Bool) throws -> [WhisperToken]
}

/// `TranscriptionService` over a local Whisper model (the Windows port plan, seam 5): the model downloads once into
/// `WhisperModelStore`, the audio comes from `audio` as 16 kHz mono floats (FFmpeg on Windows), the words get their timing from
/// `WhisperWords`. Used by Auto Captions, the transcript search and Remove Silences' word cuts, as the Mac engine is.
public struct WhisperTranscriber: TranscriptionService {
    public let store: WhisperModelStore
    let engine: any WhisperEngine
    let downloader: (any ModelDownloader)?
    let audio: @Sendable (URL) throws -> [Float]

    public init(store: WhisperModelStore = WhisperModelStore(), engine: any WhisperEngine,
                downloader: (any ModelDownloader)? = URLSessionDownloader(), audio: @escaping @Sendable (URL) throws -> [Float]) {
        self.store = store; self.engine = engine; self.downloader = downloader; self.audio = audio
    }

    public func supportedLanguages() async -> [String] { WhisperLanguages.supported }

    public func prepare(locale: Locale) async throws { try await prepare(locale: locale, progress: { _ in }) }

    public func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard WhisperLanguages.code(for: locale) != nil else { throw TranscriptionError.localeUnsupported(locale.identifier) }
        if let why = engine.unavailableReason() { throw TranscriptionError.engineMissing(why) }
        guard !store.isInstalled else { return }
        guard let downloader else { throw TranscriptionError.modelDownloadFailed("no connection") }
        do { try await store.install(downloader: downloader, progress: progress) }
        catch let e as TranscriptionError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw TranscriptionError.modelDownloadFailed(error.localizedDescription) }
    }

    public func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        guard let code = WhisperLanguages.code(for: locale) else { throw TranscriptionError.localeUnsupported(locale.identifier) }
        try await prepare(locale: locale)
        let engine = self.engine, audio = self.audio, modelPath = store.modelURL.path
        let flag = CancelFlag()
        let work = Task.detached(priority: .userInitiated) { () -> [WhisperToken] in
            let samples = try audio(url)
            guard !samples.isEmpty else { throw TranscriptionError.noAudio }
            return try engine.recognize(modelPath: modelPath, samples: samples, language: code, progress: { progress(min(1, max(0, $0))) },
                                        isCancelled: { flag.isSet })
        }
        let tokens = try await withTaskCancellationHandler { try await work.value } onCancel: { flag.set(); work.cancel() }
        progress(1)
        return Transcript(language: locale.identifier(.bcp47), words: WhisperWords.words(from: tokens))
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
