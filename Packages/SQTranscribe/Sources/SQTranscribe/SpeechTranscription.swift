import AVFoundation
import CoreMedia
import Foundation
import Speech
import SQCore

public enum TranscriptionError: Error, Sendable, Equatable {
    case localeUnsupported(String)
    case noAudio
}

public protocol TranscriptionService: Sendable {
    /// Transcribes the audio of `url`. `progress` reports 0...1 (analysed time / file duration).
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
    /// Makes `locale` ready (on-device model download and install). May take a while: the UI shows a note meanwhile.
    func prepare(locale: Locale) async throws
}

extension TranscriptionService {
    public func prepare(locale: Locale) async throws {}
}

/// On-device transcription with SpeechAnalyzer / SpeechTranscriber (macOS 26).
/// Non-volatile results only; word timing from the `.audioTimeRange` attribute, converted from `CMTime` to rational `Time`.
public struct SpeechAnalyzerTranscriber: TranscriptionService {
    public init() {}

    /// True when the on-device model for `locale` is installed.
    public static func isModelInstalled(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// Downloads and installs the model if it is missing. Throws `localeUnsupported` when the locale has no model.
    public static func installAssetsIfNeeded(for locale: Locale) async throws {
        let transcriber = makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: throw TranscriptionError.localeUnsupported(locale.identifier)
        case .installed: return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default: return
        }
    }

    public func prepare(locale: Locale) async throws { try await Self.installAssetsIfNeeded(for: locale) }

    public func transcribe(url: URL, locale: Locale = Locale(identifier: "de-DE"),
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        try await Self.installAssetsIfNeeded(for: locale)
        let source = try await AudioExtraction.readableAudio(at: url)
        defer { if source.isTemporary { try? FileManager.default.removeItem(at: source.url) } }
        let file = try AVAudioFile(forReading: source.url)
        let total = Double(file.length) / file.processingFormat.sampleRate
        guard total > 0 else { throw TranscriptionError.noAudio }

        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words += Self.words(from: result.text)
                progress(min(1, max(0, result.range.end.seconds / total)))
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        progress(1)
        return Transcript(language: locale.identifier(.bcp47), words: words)
    }

    /// Splits an attributed result into words. A run holding several tokens shares its range proportionally to character count.
    static func words(from text: AttributedString) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        for run in text.runs {
            guard let cm = run.audioTimeRange, let range = timeRange(cm) else { continue }
            let tokens = String(text[run.range].characters).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { continue }
            let total = Int64(tokens.reduce(0) { $0 + $1.count })
            var cum: Int64 = 0
            var cursor = range.start
            for (i, token) in tokens.enumerated() {
                cum += Int64(token.count)
                let end = i == tokens.count - 1 ? range.end
                    : range.start + Time(range.duration.value * cum, range.duration.timescale * total)
                out.append(TranscriptWord(text: token, range: TimeRange(start: cursor, end: max(end, cursor))))
                cursor = max(end, cursor)
            }
        }
        return out
    }

    static func timeRange(_ cm: CMTimeRange) -> TimeRange? {
        guard cm.start.isNumeric, cm.duration.isNumeric, cm.start.timescale > 0, cm.duration.timescale > 0 else { return nil }
        let start = Time(cm.start.value, Int64(cm.start.timescale))
        let dur = Time(max(cm.duration.value, 0), Int64(cm.duration.timescale))
        return TimeRange(start: start, duration: dur)
    }
}
