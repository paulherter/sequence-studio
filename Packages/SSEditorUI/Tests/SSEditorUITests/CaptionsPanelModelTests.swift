import Foundation
import Testing
import SSCore
import SSTranscribe
@testable import SSEditorUI

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

@MainActor private func makeModel(_ r: Result<Transcript, Error> = .success(sample)) -> (CaptionsPanelModel, FakeService) {
    let s = FakeService(r)
    let m = CaptionsPanelModel(service: s, debounce: .milliseconds(20))
    m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
    return (m, s)
}

@MainActor @Suite struct CaptionsPanelModelTests {
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

    @Test func failureState() async {
        let (m, _) = makeModel(.failure(TranscriptionError.noAudio))
        m.transcribe(); await m.waitForTranscription()
        if case .failed(let msg) = m.state { #expect(msg.contains("no audio")) } else { Issue.record("not failed") }
        #expect(m.transcript == nil)
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
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Leute. Weiter")
        #expect(m.transcript == sample)  // not yet applied
        try await Task.sleep(for: .milliseconds(150))
        let t = try #require(m.transcript)
        #expect(t.text == "Hallo liebe Leute. Weiter")
        #expect(t.words[2].isEdited)
        #expect(t.words[2].range == sample.words[2].range)
        #expect(m.editedWordIDs == [t.words[2].id])
        #expect(!t.words[0].isEdited)
    }

    @Test func rapidEditsCoalesce() async throws {
        let (m, _) = makeModel()
        m.transcribe(); await m.waitForTranscription()
        m.textChanged("Hallo liebe Welt. Weite")
        m.textChanged("Hallo liebe Welt. Weiter geht")
        try await Task.sleep(for: .milliseconds(150))
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
        m.selectedPresetIndex = 1
        m.transcribe(); await m.waitForTranscription()
        #expect(m.createCaptions().count == 4)
    }
}
