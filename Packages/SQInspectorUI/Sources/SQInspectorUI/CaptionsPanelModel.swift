import Foundation
import Observation
import SQCore
import SQEditorSession
import SQUIKit
import SQTranscribe

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
    public var language: String = AppSettings.defaultCaptionLanguage { didSet { if language != oldValue { onLanguageChanged?(language) } } }
    /// Called when the language changes (the host stores it as the project's override).
    @ObservationIgnored public var onLanguageChanged: (@MainActor (String) -> Void)?
    public var languages: [String] = CaptionsPanelModel.defaultLanguages
    /// Auto language: when the text of a finished run is clearly another supported language, the model switches to it and
    /// transcribes once more (the host sets this from Settings).
    public var autoDetectLanguage = false
    private var retriedForLanguage = false
    public var presets: [NamedPreset] = [NamedPreset(name: "Standard", preset: .standard),
                                         NamedPreset(name: "Short Video", preset: .shortVideo)]
    public var selectedPresetIndex: Int = 0
    /// Audio source to transcribe: one file, words in that file's time (tests and single-file hosts).
    public var sourceURL: URL?
    /// The whole active sequence: the audible clips' media files; words come back in sequence time. Wins over `sourceURL`.
    public struct SequenceSource: Sendable {
        public var timeline: Timeline
        public var urls: [UUID: URL]
        /// Media whose clips play chosen channels (F7.10): transcribed from those channels.
        public var channelMaps: [UUID: AudioChannelMap]
        /// Channel count each map was chosen against (the item's stored count): a file that now counts another number
        /// is transcribed with its own layout.
        public var expectedChannels: [UUID: Int]
        public init(timeline: Timeline, urls: [UUID: URL], channelMaps: [UUID: AudioChannelMap] = [:],
                    expectedChannels: [UUID: Int] = [:]) {
            self.timeline = timeline; self.urls = urls; self.channelMaps = channelMaps; self.expectedChannels = expectedChannels
        }
    }
    public private(set) var sequenceSource: SequenceSource?
    /// True when the audio layout of the sequence changed after the transcript was made (trim, move, ripple, speed):
    /// its words no longer match the timeline, so seek and Create Captions are off until Transcribe is run again.
    public private(set) var isOutdated = false
    @ObservationIgnored private var transcribedLayout: TimelineTranscription.Layout?
    @ObservationIgnored private var transcribedMaps: [UUID: AudioChannelMap] = [:]
    @ObservationIgnored private var ranMaps: [UUID: AudioChannelMap] = [:]

    /// Hands the model the current sequence. Does nothing when audio layout and media files are unchanged, so a running
    /// edit in the transcript is not disturbed by unrelated project changes.
    public func setSequenceSource(_ new: SequenceSource?) {
        if let old = sequenceSource, let new, old.urls == new.urls, old.channelMaps == new.channelMaps,
           TimelineTranscription.layout(of: old.timeline) == TimelineTranscription.layout(of: new.timeline) { return }
        sequenceSource = new
        if let new, let t = transcribedLayout {
            // Other channels are other words: a changed map of any media the sequence plays outdates the transcript too.
            isOutdated = transcript != nil && (TimelineTranscription.layout(of: new.timeline) != t
                                               || Self.usedMaps(new) != transcribedMaps)
        }
    }
    private static func usedMaps(_ s: SequenceSource) -> [UUID: AudioChannelMap] { s.channelMaps.filter { s.urls[$0.key] != nil } }
    /// Frame duration of the sequence: the gap in Create Captions is counted in frames.
    public var frameDuration = Time(1, 30)
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
    @ObservationIgnored private var ranLayout: TimelineTranscription.Layout?

    /// Waits out one debounce interval; injectable so tests fire the timer by hand instead of racing a clock.
    public typealias Sleeper = @Sendable (Duration) async -> Void
    @ObservationIgnored private let sleeper: Sleeper

    public init(service: any TranscriptionService, debounce: Duration = .milliseconds(400),
                sleeper: Sleeper? = nil) {
        self.service = service
        self.debounce = debounce
        // nil (not an async closure as default argument: that miscompiles and aborts with a task-dealloc fatal error)
        self.sleeper = sleeper ?? { d in try? await Task.sleep(for: d) }
    }

    // MARK: Derived

    public var canTranscribe: Bool {
        if case .transcribing = state { return false }
        return sourceURL != nil || sequenceSource != nil
    }

    public var canCreateCaptions: Bool {
        guard state == .ready, !isOutdated, let t = transcript else { return false }
        return !t.words.isEmpty
    }

    public var editedWordIDs: Set<UUID> {
        Set((transcript?.words ?? []).filter(\.isEdited).map(\.id))
    }

    public var selectedPreset: CaptionPreset? {
        presets.indices.contains(selectedPresetIndex) ? presets[selectedPresetIndex].preset : nil
    }

    // MARK: Languages

    /// Replaces the language list with the locales the recognizer reports (sorted by display name). An empty report keeps
    /// the defaults; the selected language stays in the list so the pop-up never loses it.
    public func loadSupportedLanguages() async {
        let reported = await service.supportedLanguages()
        applySupportedLanguages(reported)
    }

    public func applySupportedLanguages(_ reported: [String]) {
        guard !reported.isEmpty else { return }
        var list = Array(Set(reported))
        if !list.contains(language) { list.append(language) }
        languages = list.sorted {
            let a = Locale.current.localizedString(forIdentifier: $0) ?? $0, b = Locale.current.localizedString(forIdentifier: $1) ?? $1
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    // MARK: Transcribe

    /// Starts transcription. With an existing transcript this only raises `needsOverwriteConfirmation`
    /// (re-transcribe overwrites, including manual edits) unless `confirmed` is true.
    public func transcribe(confirmed: Bool = false) {
        guard canTranscribe else { return }
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
        statusNote = SQL10n.format("Preparing the %@ language model", Locale.current.localizedString(forIdentifier: language) ?? language)
        let service = self.service
        let url = sourceURL
        let sequence = sequenceSource
        ranLayout = sequence.map { TimelineTranscription.layout(of: $0.timeline) }
        ranMaps = sequence.map(Self.usedMaps) ?? [:]
        // A run that was canceled may still be winding down: the new one waits for it, so two never overlap.
        let previous = transcribeTask
        previous?.cancel()
        transcribeTask = Task { [weak self] in
            await previous?.value
            let sink = ProgressSink(model: self)
            do {
                if Task.isCancelled { throw CancellationError() }
                try await service.prepare(locale: locale) { p in sink.preparing(p, run: id) }
                self?.preparationDone(run: id)
                let result: Transcript
                if let sequence {
                    result = try await TimelineTranscription.transcribe(timeline: sequence.timeline, urls: sequence.urls, channelMaps: sequence.channelMaps,
                                                                        expectedChannels: sequence.expectedChannels,
                                                                        service: service,
                                                                        locale: locale) { p in sink.report(p, run: id) }
                } else if let url {
                    result = try await service.transcribe(url: url, locale: locale) { p in sink.report(p, run: id) }
                } else { throw TranscriptionError.noAudio }
                self?.finish(.success(result), run: id)
            } catch {
                self?.finish(.failure(error), run: id)
            }
        }
    }

    private struct ProgressSink: Sendable {
        weak var model: CaptionsPanelModel?
        func preparing(_ p: Double, run: Int) {
            let model = self.model
            Task { @MainActor in model?.reportPreparation(p, run: run) }
        }
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
        retriedForLanguage = false
        statusNote = nil
        state = transcript == nil ? .idle : .ready
    }

    private func reportProgress(_ p: Double, run: Int) {
        guard run == runID, case .transcribing = state else { return }
        state = .transcribing(progress: min(1, max(0, p)))
    }

    /// A model download reports its share: the note says "Downloading the German language model: 42 %".
    private func reportPreparation(_ p: Double, run: Int) {
        guard run == runID, case .transcribing = state, statusNote != nil, p > 0, p < 1 else { return }
        statusNote = SQL10n.format("Downloading the %@ language model: %@", Locale.current.localizedString(forIdentifier: language) ?? language,
                                   "\(Int((p * 100).rounded())) %")
    }

    private func preparationDone(run: Int) { if run == runID { statusNote = nil } }

    /// shortcut: NaturalLanguage is Apple-only, so on Windows the language is never re-guessed; upgrade when a portable
    /// language identifier exists.
    private static func guessedRetryLanguage(text: String, used: String, supported: [String]) -> String? {
        #if canImport(NaturalLanguage)
        return CaptionLanguageGuess.retryLanguage(text: text, used: used, supported: supported)
        #else
        return nil
        #endif
    }

    private func finish(_ result: Result<Transcript, Error>, run: Int) {
        guard run == runID else { return }
        statusNote = nil
        switch result {
        case .success(let t):
            if autoDetectLanguage, !retriedForLanguage,
               let other = Self.guessedRetryLanguage(text: t.words.map(\.text).joined(separator: " "), used: language, supported: languages) {
                retriedForLanguage = true
                language = other
                state = .idle                       // `transcribe` refuses while a run is shown
                transcribe(confirmed: true)
                return
            }
            retriedForLanguage = false
            transcript = t; currentWordID = nil; state = .ready
            transcribedLayout = ranLayout
            transcribedMaps = ranMaps
            isOutdated = false
        case .failure(let e): retriedForLanguage = false; state = .failed(Self.message(for: e))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TranscriptionError.localeUnsupported(let l): return SQL10n.format("Language %@ is not supported for on-device transcription.", l)
        case TranscriptionError.noAudio: return SQL10n.string("There is no audio to transcribe: no audible clips in this sequence.")
        default: return SQL10n.errorText(error)
        }
    }

    // MARK: Editing

    /// Called on every keystroke; applies after `debounce` of quiet.
    public func textChanged(_ text: String) {
        guard transcript != nil else { return }
        pendingText = text
        debounceTask?.cancel()
        let delay = debounce, sleeper = self.sleeper
        debounceTask = Task { [weak self] in
            await sleeper(delay)
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
        guard !isOutdated, let i = wordIndex(atCharacter: offset), let w = transcript?.words[i] else { return }
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

    /// Create Captions dialog: changes the limits of the selected preset (for this session; presets are not persisted).
    public func setOptions(maxCharsPerLine: Int, lines: Int, minDuration: Time, gapFrames: Int) {
        guard presets.indices.contains(selectedPresetIndex) else { return }
        presets[selectedPresetIndex].preset = presets[selectedPresetIndex].preset
            .with(maxCharsPerLine: maxCharsPerLine, lines: lines, minDuration: minDuration, gapFrames: min(gapFrames, 3600),
                  frameDuration: frameDuration)
    }

    /// Create Captions dialog: the typed "Minimum duration" in seconds as time, clamped to 0...1 hour (a typed 1e30 or
    /// "inf" must not overflow the conversion).
    public static func minDuration(seconds: Double) -> Time {
        guard !seconds.isNaN else { return .zero }
        return Time(Int64((min(max(seconds, 0), 3600) * 1000).rounded()), 1000)
    }

    /// The gap of the selected preset in frames (rounded).
    public var gapFrames: Int {
        guard let p = selectedPreset, frameDuration > .zero else { return 0 }
        return Int((Double(p.gap.value) / Double(p.gap.timescale)) / (Double(frameDuration.value) / Double(frameDuration.timescale)) + 0.5)
    }


    /// Segments the transcript with the selected preset and hands the result to `onCreateCaptions`.
    @discardableResult
    public func createCaptions() -> [Caption] {
        flushEdits()
        guard canCreateCaptions, let t = transcript, let preset = selectedPreset else { return [] }
        let captions = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(t, preset: preset), preset: preset)
        onCreateCaptions?(captions)
        return captions
    }
}
