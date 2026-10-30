import Foundation

public enum TranscriptionError: Error, Sendable, Equatable {
    case localeUnsupported(String)
    case noAudio
    /// No speech engine on this system (Windows until an engine plugs into `TranscriptionService`).
    case unavailable
    /// The engine's library is missing or does not start (message for the status line).
    case engineMissing(String)
    /// The language model could not be downloaded.
    case modelDownloadFailed(String)
}

/// What the status line says: the default text of a plain enum is "(SQTranscribe.TranscriptionError error 2.)".
extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .localeUnsupported(let id): "Speech recognition does not support the language \(id)."
        case .noAudio: "There is no audio to transcribe."
        case .unavailable: "Transcription is not available on this system yet."
        case .engineMissing(let why): "The speech engine is not available: \(why)."
        case .modelDownloadFailed(let why): "The language model could not be downloaded: \(why)."
        }
    }
}

/// The speech engine seam (the Windows port plan, seam 5). The Mac engine is `SpeechAnalyzerTranscriber` (Speech framework,
/// Mac-only file); another system plugs its own engine in here.
public protocol TranscriptionService: Sendable {
    /// Transcribes the audio of `url`. `progress` reports 0...1 (analyzed time / file duration).
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
    /// Makes `locale` ready (on-device model download and install). May take a while: the UI shows a note meanwhile.
    func prepare(locale: Locale) async throws
    /// Same, reporting 0...1 while a model downloads (engines without a download ignore it).
    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
    /// BCP-47 identifiers of the languages the recognizer supports on this Mac; empty = unknown (the UI keeps its defaults).
    func supportedLanguages() async -> [String]
}

extension TranscriptionService {
    public func supportedLanguages() async -> [String] { [] }
    public func prepare(locale: Locale) async throws {}
    public func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws { try await prepare(locale: locale) }
}

/// Stand-in where no speech engine exists: every call throws `unavailable`.
public struct UnavailableTranscriptionService: TranscriptionService {
    public init() {}
    public func prepare(locale: Locale) async throws { throw TranscriptionError.unavailable }
    public func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        throw TranscriptionError.unavailable
    }
}
