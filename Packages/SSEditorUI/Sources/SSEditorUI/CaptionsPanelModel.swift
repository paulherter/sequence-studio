import Foundation
import Observation
import SSCore
import SSTranscribe

/// State and logic of the transcript / captions panel. Text edits never touch media (DECISIONS):
/// they only rewrite the transcript via `Transcript.applyingText`.
@MainActor @Observable
public final class CaptionsPanelModel {
    public enum State: Equatable, Sendable {
        case idle
        case transcribing(progress: Double)
        case ready
        case failed(String)
    }

    public struct NamedPreset: Sendable, Hashable {
        public var name: String
        public var preset: CaptionPreset
        public init(name: String, preset: CaptionPreset) { self.name = name; self.preset = preset }
    }

    public static let defaultLanguages = ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"]

    public private(set) var state: State = .idle
    public private(set) var transcript: Transcript?
    /// Shown next to the progress while the language model is downloaded and installed (first use of a language).
    public private(set) var statusNote: String?
    /// BCP-47 identifier of the recognition language.
    public var language: String = "de-DE"
    public var languages: [String] = CaptionsPanelModel.defaultLanguages
    public var presets: [NamedPreset] = [NamedPreset(name: "Standard", preset: .standard)]
    public var selectedPresetIndex: Int = 0
    /// Audio source to transcribe (set by the host from the selected clip).
    public var sourceURL: URL?
    /// Word under the playhead (nil between words).
    public private(set) var currentWordID: UUID?
    /// True when Transcribe was requested while a transcript exists: the view asks, then calls `confirmOverwrite()`.
    public private(set) var needsOverwriteConfirmation = false

    /// Click-to-seek: source time of the clicked word's start.
    @ObservationIgnored public var onSeek: (@MainActor (Time) -> Void)?
    /// Result of "Create Captions"; the caption track model does not exist yet.
    @ObservationIgnored public var onCreateCaptions: (@MainActor ([Caption]) -> Void)?

    @ObservationIgnored private let service: any TranscriptionService
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pendingText: String?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    public init(service: any TranscriptionService, debounce: Duration = .milliseconds(400)) {
        self.service = service
        self.debounce = debounce
    }

    // MARK: Derived

    public var canTranscribe: Bool {
        if case .transcribing = state { return false }
        return sourceURL != nil
    }

    public var canCreateCaptions: Bool {
        guard state == .ready, let t = transcript else { return false }
        return !t.words.isEmpty
    }

    public var editedWordIDs: Set<UUID> {
        Set((transcript?.words ?? []).filter(\.isEdited).map(\.id))
    }

    public var selectedPreset: CaptionPreset? {
        presets.indices.contains(selectedPresetIndex) ? presets[selectedPresetIndex].preset : nil
    }

    // MARK: Transcribe

    /// Starts transcription. With an existing transcript this only raises `needsOverwriteConfirmation`
    /// (re-transcribe overwrites, including manual edits) unless `confirmed` is true.
    public func transcribe(confirmed: Bool = false) {
        guard canTranscribe, let url = sourceURL else { return }
        if transcript != nil, !confirmed {
            needsOverwriteConfirmation = true
            return
        }
        needsOverwriteConfirmation = false
        debounceTask?.cancel(); pendingText = nil
        runID += 1
        let id = runID
        let locale = Locale(identifier: language)
        state = .transcribing(progress: 0)
        statusNote = "Preparing the \(Locale.current.localizedString(forIdentifier: language) ?? language) language model"
        let service = self.service
        transcribeTask = Task { [weak self] in
            let sink = ProgressSink(model: self)
            do {
                try await service.prepare(locale: locale)
                self?.preparationDone(run: id)
                let result = try await service.transcribe(url: url, locale: locale) { p in sink.report(p, run: id) }
                self?.finish(.success(result), run: id)
            } catch {
                self?.finish(.failure(error), run: id)
            }
        }
    }

    private struct ProgressSink: Sendable {
        weak var model: CaptionsPanelModel?
        func report(_ p: Double, run: Int) {
            let model = self.model
            Task { @MainActor in model?.reportProgress(p, run: run) }
        }
    }

    public func confirmOverwrite() { transcribe(confirmed: true) }
    public func cancelOverwrite() { needsOverwriteConfirmation = false }

    /// Awaits the running transcription (tests and hosts that need completion).
    public func waitForTranscription() async { await transcribeTask?.value }

    public func cancelTranscription() {
        guard case .transcribing = state else { return }
        runID += 1
        transcribeTask?.cancel()
        statusNote = nil
        state = transcript == nil ? .idle : .ready
    }

    private func reportProgress(_ p: Double, run: Int) {
        guard run == runID, case .transcribing = state else { return }
        state = .transcribing(progress: min(1, max(0, p)))
    }

    private func preparationDone(run: Int) { if run == runID { statusNote = nil } }

    private func finish(_ result: Result<Transcript, Error>, run: Int) {
        guard run == runID else { return }
        statusNote = nil
        switch result {
        case .success(let t): transcript = t; currentWordID = nil; state = .ready
        case .failure(let e): state = .failed(Self.message(for: e))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TranscriptionError.localeUnsupported(let l): return "Language \(l) is not supported for on-device transcription."
        case TranscriptionError.noAudio: return "This clip has no audio to transcribe."
        default: return error.localizedDescription
        }
    }

    // MARK: Editing

    /// Called on every keystroke; applies after `debounce` of quiet.
    public func textChanged(_ text: String) {
        guard transcript != nil else { return }
        pendingText = text
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushEdits()
        }
    }

    /// Applies a pending edit immediately.
    public func flushEdits() {
        debounceTask?.cancel()
        guard let text = pendingText, let t = transcript else { pendingText = nil; return }
        pendingText = nil
        let updated = t.applyingText(text)
        if updated != t { transcript = updated }
    }

    // MARK: Word <-> time / text

    /// UTF-16 ranges of every word in `transcript.text` (words joined by single spaces).
    public var wordRanges: [NSRange] {
        var out: [NSRange] = []
        var location = 0
        for w in transcript?.words ?? [] {
            let len = (w.text as NSString).length
            out.append(NSRange(location: location, length: len))
            location += len + 1
        }
        return out
    }

    /// Index of the word containing UTF-16 offset `offset`; a separator maps to the preceding word,
    /// offsets past the end to the last word.
    public func wordIndex(atCharacter offset: Int) -> Int? {
        let ranges = wordRanges
        guard !ranges.isEmpty else { return nil }
        var result = 0
        for (i, r) in ranges.enumerated() {
            if r.location <= offset { result = i } else { break }
        }
        return result
    }

    /// Click-to-seek: moves the playhead to the start of the word at `offset`.
    public func seek(toCharacter offset: Int) {
        flushEdits()
        guard let i = wordIndex(atCharacter: offset), let w = transcript?.words[i] else { return }
        onSeek?(w.range.start)
    }

    /// Updates the highlighted word from the playhead (source time). Binary search over sorted words.
    public func updatePlayhead(_ time: Time) {
        guard let words = transcript?.words, !words.isEmpty else { currentWordID = nil; return }
        var lo = 0, hi = words.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = words[mid].range
            if time < r.start { hi = mid - 1 }
            else if time >= r.end { lo = mid + 1 }
            else { found = mid; break }
        }
        let id = found.map { words[$0].id }
        if id != currentWordID { currentWordID = id }
    }

    // MARK: Captions

    /// Segments the transcript with the selected preset and hands the result to `onCreateCaptions`.
    @discardableResult
    public func createCaptions() -> [Caption] {
        flushEdits()
        guard canCreateCaptions, let t = transcript, let preset = selectedPreset else { return [] }
        let captions = CaptionSegmenter.segment(t, preset: preset)
        onCreateCaptions?(captions)
        return captions
    }
}
