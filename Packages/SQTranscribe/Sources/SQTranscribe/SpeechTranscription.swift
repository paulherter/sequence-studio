import AVFoundation
import CoreMedia
import Foundation
import Speech
import SQCore

/// On-device transcription with SpeechAnalyzer / SpeechTranscriber (macOS 26).
/// Non-volatile results only; word timing from the `.audioTimeRange` attribute, converted from `CMTime` to rational `Time`.
public struct SpeechAnalyzerTranscriber: TranscriptionService {
    /// Optional stage timing hook (`SQ_BENCH_CAPTIONS`): called with ("assets" | "extract" | "recognize", seconds).
    public var onStage: (@Sendable (String, Double) -> Void)?
    public init() {}

    /// True when the on-device model for `locale` is installed.
    public static func isModelInstalled(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Locales whose model this process already confirmed as installed: later calls skip the asset inventory round trip.
    private actor ReadyLocales {
        static let shared = ReadyLocales()
        private var ids: Set<String> = []
        func contains(_ id: String) -> Bool { ids.contains(id) }
        func insert(_ id: String) { ids.insert(id) }
    }

    /// Downloads and installs the model if it is missing. Throws `localeUnsupported` when the locale has no model.
    public static func installAssetsIfNeeded(for locale: Locale) async throws {
        let id = locale.identifier(.bcp47)
        if await ReadyLocales.shared.contains(id) { return }
        let transcriber = makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: throw TranscriptionError.localeUnsupported(locale.identifier)
        case .installed: break
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default: return
        }
        await ReadyLocales.shared.insert(id)
    }

    /// Loads the on-device model for `locale` ahead of the first transcription (call when media is imported or the app
    /// starts): the first analysis of a cold process otherwise pays the model load. Best effort, never throws, never
    /// downloads (an uninstalled model is left for the first real transcription, which shows the progress note).
    @discardableResult
    public static func warmUp(locale: Locale) async -> Bool {
        guard await isModelInstalled(for: locale), (try? await installAssetsIfNeeded(for: locale)) != nil else { return false }
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        return true
    }

    public func prepare(locale: Locale) async throws { try await Self.installAssetsIfNeeded(for: locale) }

    public func supportedLanguages() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
    }

    public func transcribe(url: URL, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let clock = ContinuousClock()
        var mark = clock.now
        let stage = onStage
        func lap(_ name: String) {
            let now = clock.now, d = now - mark
            mark = now
            stage?(name, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        try await Self.installAssetsIfNeeded(for: locale)
        lap("assets")
        let source = try await AudioExtraction.readableAudio(at: url)
        lap("extract")
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
        lap("recognize")
        progress(1)
        return Transcript(language: locale.identifier(.bcp47), words: words)
    }

    /// Splits an attributed result into words. A run holding several tokens shares its range proportionally to character count.
    static func words(from text: AttributedString) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        // One run per time range (a change of confidence inside it does not split it); the lowest confidence wins.
        for (cm, runRange) in text.runs[\.audioTimeRange] {
            guard let cm, let range = timeRange(cm) else { continue }
            let confidence = text[runRange].runs.compactMap(\.transcriptionConfidence).min().map { Float(min(1, max(0, $0))) }
            let tokens = Self.tokens(String(text[runRange].characters))
            guard !tokens.isEmpty else { continue }
            let total = Int64(tokens.reduce(0) { $0 + $1.count })
            var cum: Int64 = 0
            var cursor = range.start
            for (i, token) in tokens.enumerated() {
                cum += Int64(token.count)
                let end = i == tokens.count - 1 ? range.end
                    : range.start + Time(range.duration.value * cum, range.duration.timescale * total)
                out.append(TranscriptWord(text: token, range: TimeRange(start: cursor, end: max(end, cursor)), confidence: confidence))
                cursor = max(end, cursor)
            }
        }
        return out
    }

    /// Whole words of recognized text: split at whitespace, and an en or em dash glued between two words
    /// ("ausprobieren–das") becomes its own token so the words around it stay apart. A hyphen ("E-Mail") stays in its word.
    static func tokens(_ s: String) -> [String] {
        let dashes: Set<Character> = ["\u{2013}", "\u{2014}"]
        var out: [String] = []
        for piece in s.split(whereSeparator: { $0.isWhitespace }) {
            var cur = ""
            func flush() { if !cur.isEmpty { out += WordSegmentation.words(cur); cur = "" } }
            for ch in piece {
                if dashes.contains(ch) {
                    flush()
                    out.append(String(ch))
                } else { cur.append(ch) }
            }
            flush()
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
