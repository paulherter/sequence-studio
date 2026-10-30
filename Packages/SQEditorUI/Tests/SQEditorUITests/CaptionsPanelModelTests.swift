import AppKit
import Foundation
import Synchronization
import Testing
import SQCore
import SQTranscribe
@testable import SQEditorUI
@testable import SQInspectorUI

private func w(_ text: String, _ s: Int64, _ e: Int64) -> TranscriptWord {
    TranscriptWord(text: text, range: TimeRange(start: Time(s, 10), end: Time(e, 10)))
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}

private final class FakeService: TranscriptionService, @unchecked Sendable {
    let result: Locked<Result<Transcript, Error>>
    let calls = Locked<[String]>([])
    init(_ r: Result<Transcript, Error>) { result = Locked(r) }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        calls.mutate { $0.append(locale.identifier) }
        progress(0.5)
        return try result.value.get()
    }
}

private let sample = Transcript(language: "de-DE", words: [
    w("Hallo", 0, 5), w("liebe", 6, 10), w("Welt.", 10, 15), w("Weiter", 30, 35),
])

/// A debounce timer the test fires by hand: every `sleep` suspends until `fire()`. `fire()` opens the gate for good, so a
/// debounce task that only reaches its `sleep` after the fire (the task is scheduled, not run, by `textChanged`) still ends.
final class ManualTimer: @unchecked Sendable {
    private let state = Mutex<(fired: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    func sleep(_ d: Duration) async {
        await withCheckedContinuation { c in
            let now = state.withLock { s -> Bool in
                if s.fired { return true }
                s.waiting.append(c); return false
            }
            if now { c.resume() }
        }
    }
    func fire() {
        for c in state.withLock({ s -> [CheckedContinuation<Void, Never>] in s.fired = true; let w = s.waiting; s.waiting = []; return w }) { c.resume() }
    }
}

@MainActor private func makeModel(_ r: Result<Transcript, Error> = .success(sample),
                                  timer: ManualTimer = ManualTimer()) -> (CaptionsPanelModel, FakeService) {
    let s = FakeService(r)
    let m = CaptionsPanelModel(service: s, debounce: .milliseconds(20), sleeper: { await timer.sleep($0) })
    m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
    return (m, s)
}

/// Waits (main actor stays free) until `condition` holds, at most `timeout`: debounce timers run late on a loaded machine,
/// so the tests wait for the effect instead of sleeping a fixed time. A debounce that never fires still fails after `timeout`.
@MainActor private func eventually(timeout: Duration = .seconds(120), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

private struct LanguageService: TranscriptionService {
    let langs: [String]
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript { sample }
    func supportedLanguages() async -> [String] { langs }
}

@MainActor @Suite struct CaptionsPanelModelTests {
    @Test func languagesComeFromRecogniser() async {
        let m = CaptionsPanelModel(service: LanguageService(langs: ["sv-SE", "en-US", "ja-JP"]))
        await m.loadSupportedLanguages()
        #expect(Set(m.languages) == ["sv-SE", "en-US", "ja-JP", "de-DE"])   // the selected language stays
        let empty = CaptionsPanelModel(service: LanguageService(langs: []))
        await empty.loadSupportedLanguages()
        #expect(empty.languages == CaptionsPanelModel.defaultLanguages)
    }

    @Test func transcribeSuccessUsesLocale() async {
        let (m, s) = makeModel()
        #expect(m.state == .idle)
        m.transcribe()
        if case .transcribing = m.state {} else { Issue.record("not transcribing") }
        await m.waitForTranscription()
        #expect(m.state == .ready)
        #expect(m.transcript == sample)
        #expect(s.calls.value == ["de-DE"])
        m.language = "en-US"; m.transcribe(confirmed: true); await m.waitForTranscription()
        #expect(s.calls.value == ["de-DE", "en-US"])
    }

    @Test func autoLanguageRetriesOnceInTheSpokenLanguage() async {
        let long = ["Today", "we", "show", "you", "how", "to", "cut", "a", "film", "and", "save", "a", "lot", "of", "time", "while", "doing", "it."]
        let english = Transcript(language: "en-US", words: long.enumerated().map { w($1, Int64($0) * 5, Int64($0) * 5 + 4) })
        let (m, s) = makeModel(.success(english))
        m.autoDetectLanguage = true
        m.language = "de-DE"
        m.transcribe()
        await eventually { s.calls.value.count >= 2 && m.state == .ready }
        #expect(s.calls.value.first == "de-DE")
        #expect(s.calls.value.count == 2)
        #expect(m.language.hasPrefix("en"))
        #expect(s.calls.value.last == m.language)
    }

    @Test func autoLanguageOffKeepsTheChosenLanguage() async {
        let (m, s) = makeModel(.success(sample))
        m.language = "en-US"
        m.transcribe(); await m.waitForTranscription()
        #expect(s.calls.value == ["en-US"])
    }

    @Test func failureState() async {
        let (m, _) = makeModel(.failure(TranscriptionError.noAudio))
        m.transcribe(); await m.waitForTranscription()
        if case .failed(let msg) = m.state { #expect(msg.contains("no audio")) } else { Issue.record("not failed") }
        #expect(m.transcript == nil)
    }

    // Review finding 7: every observed change while the overwrite question was open queued another sheet.
    @Test func overwriteSheetIsPresentedOnce() async throws {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        let view = CaptionsPanelView(model: m)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        m.transcribe()                                    // raises the question: first sheet
        await eventually { window.sqAttachedSheet != nil }
        for i in 0..<3 { m.language = i % 2 == 0 ? "en-US" : "de-DE"; try await Task.sleep(for: .milliseconds(30)) }   // observed changes
        let sheet = try #require(window.sqAttachedSheet)
        (sheet as? SQDialogWindow)?.cancelOperation(nil)                                  // Cancel
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.sqAttachedSheet == nil)              // a queued duplicate would show up now
        #expect(!m.needsOverwriteConfirmation)
    }

    @Test func noSourceCannotTranscribe() {
        let (m, _) = makeModel(); m.sourceURL = nil
        m.transcribe()
        #expect(m.state == .idle)
    }

    @Test func retranscribeNeedsConfirmation() async {
        let (m, s) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        m.transcribe()
        #expect(m.needsOverwriteConfirmation)
        #expect(m.state == .ready)
        #expect(s.calls.value.count == 1)
        m.cancelOverwrite()
        #expect(!m.needsOverwriteConfirmation)
        m.transcribe(); m.confirmOverwrite()
        #expect(!m.needsOverwriteConfirmation)
        await m.waitForTranscription()
        #expect(s.calls.value.count == 2)
    }

    @Test func overwriteDropsEdits() async {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Leute. Weiter"); m.flushEdits()
        #expect(!m.editedWordIDs.isEmpty)
        m.confirmOverwrite(); await m.waitForTranscription()
        #expect(m.editedWordIDs.isEmpty)
    }

    @Test func editDebouncesAndFlagsWords() async throws {
        let timer = ManualTimer()
        let (m, _) = makeModel(timer: timer)
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Leute. Weiter")
        #expect(m.transcript == sample)  // not yet applied
        timer.fire()
        await eventually { m.transcript?.text == "Hallo liebe Leute. Weiter" }
        let t = try #require(m.transcript)
        #expect(t.text == "Hallo liebe Leute. Weiter")
        #expect(t.words[2].isEdited)
        #expect(t.words[2].range == sample.words[2].range)
        #expect(m.editedWordIDs == [t.words[2].id])
        #expect(!t.words[0].isEdited)
    }

    @Test func rapidEditsCoalesce() async throws {
        let timer = ManualTimer()
        let (m, _) = makeModel(timer: timer)
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Welt. Weite")
        m.textChanged("Hallo liebe Welt. Weiter geht")
        timer.fire()
        await eventually { m.transcript?.text == "Hallo liebe Welt. Weiter geht" }
        #expect(m.transcript?.text == "Hallo liebe Welt. Weiter geht")
    }

    @Test func wordMapping() async {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        #expect(m.wordRanges == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5),
                                 NSRange(location: 12, length: 5), NSRange(location: 18, length: 6)])
        #expect(m.wordIndex(atCharacter: 0) == 0)
        #expect(m.wordIndex(atCharacter: 5) == 0)   // separator
        #expect(m.wordIndex(atCharacter: 7) == 1)
        #expect(m.wordIndex(atCharacter: 999) == 3)
    }

    @Test func clickSeeksToWordStart() async {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        var got: Time?
        m.onSeek = { got = $0 }
        m.seek(toCharacter: 13)
        #expect(got == Time(10, 10))
        m.seek(toCharacter: 20)
        #expect(got == Time(30, 10))
    }

    @Test func seekAfterPendingEditUsesNewText() async {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        var got: Time?
        m.onSeek = { got = $0 }
        m.textChanged("Hallo Welt. Weiter")
        m.seek(toCharacter: 6)
        #expect(m.transcript?.words.count == 3)
        #expect(got != nil)
    }

    @Test func playheadHighlight() async {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        m.updatePlayhead(Time(7, 10))
        #expect(m.currentWordID == sample.words[1].id)
        m.updatePlayhead(Time(17, 10))   // gap
        #expect(m.currentWordID == nil)
        m.updatePlayhead(Time(35, 10))   // end is exclusive
        #expect(m.currentWordID == nil)
        m.updatePlayhead(Time(30, 10))
        #expect(m.currentWordID == sample.words[3].id)
    }

    @Test func createCaptionsDeliversSegments() async {
        let (m, _) = makeModel()
        #expect(!m.canCreateCaptions)
        m.transcribe(); await m.waitForTranscription()
        var received: [Caption] = []
        m.onCreateCaptions = { received = $0 }
        let out = m.createCaptions()
        #expect(out == received)
        #expect(!received.isEmpty)
        #expect(received.flatMap { Array($0.wordIndices) } == [0, 1, 2, 3])
        #expect(received[0].styleRef == CaptionPreset.standard.styleRef)
    }

    @Test func createCaptionsUsesSelectedPreset() async {
        let (m, _) = makeModel()
        var tight = CaptionPreset.standard
        tight.maxCharsPerLine = 5; tight.maxLines = 1
        m.presets.append(.init(name: "Tight", preset: tight))
        m.selectedPresetIndex = m.presets.count - 1
        m.transcribe(); await m.waitForTranscription()
        #expect(m.createCaptions().count == 4)
    }
}


@MainActor @Suite struct CaptionsPanelStaleTests {
    private func source(start: Int64) -> CaptionsPanelModel.SequenceSource {
        let m = UUID()
        let clip = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)),
                        start: Time(start, 1), mediaDuration: Time(60, 1))
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .audio, clips: [clip])])
        return .init(timeline: tl, urls: [m: URL(fileURLWithPath: "/tmp/a.wav")])
    }

    @Test func transcriptGoesOutdatedWhenTheAudioLayoutChanges() async {
        let svc = FakeService(.success(sample))
        let m = CaptionsPanelModel(service: svc, debounce: .milliseconds(20))
        let src = source(start: 0)
        m.setSequenceSource(src)
        m.transcribe(); await m.waitForTranscription()
        #expect(m.state == .ready && !m.isOutdated && m.canCreateCaptions)
        var seeks = 0
        m.onSeek = { _ in seeks += 1 }
        m.seek(toCharacter: 0)
        #expect(seeks == 1)
        // Same layout again: still current.
        m.setSequenceSource(src)
        #expect(!m.isOutdated)
        // The clip moved: outdated, no seek, no captions.
        let moved = CaptionsPanelModel.SequenceSource(timeline: {
            var tl = src.timeline
            tl.tracks[0] = Track(kind: .audio, clips: [{ var c = tl.tracks[0].clips[0]; c.start = Time(5, 1); return c }()])
            return tl
        }(), urls: src.urls)
        m.setSequenceSource(moved)
        #expect(m.isOutdated && !m.canCreateCaptions)
        m.seek(toCharacter: 0)
        #expect(seeks == 1)
        // Transcribing again makes it current.
        m.transcribe(confirmed: true); await m.waitForTranscription()
        #expect(!m.isOutdated && m.canCreateCaptions)
    }

    @Test func transcriptGoesOutdatedWhenTheChannelMapChanges() async {
        let svc = FakeService(.success(sample))
        let m = CaptionsPanelModel(service: svc, debounce: .milliseconds(20))
        let src = source(start: 0)
        m.setSequenceSource(src)
        m.transcribe(); await m.waitForTranscription()
        #expect(!m.isOutdated)
        let id = src.urls.keys.first!
        var mapped = src
        mapped.channelMaps = [id: .mono(1)!]
        m.setSequenceSource(mapped)
        #expect(m.isOutdated && !m.canCreateCaptions)
        // Back to the maps it was made with: current again.
        m.setSequenceSource(src)
        #expect(!m.isOutdated)
        // A map of media the sequence does not play changes nothing.
        var other = src
        other.channelMaps[UUID()] = .mono(0)
        m.setSequenceSource(other)
        #expect(!m.isOutdated)
    }
}
