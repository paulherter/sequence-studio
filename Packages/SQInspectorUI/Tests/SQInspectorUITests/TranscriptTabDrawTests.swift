import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQTranscribe
@testable import SQInspectorUI

private final class Words: TranscriptionService, @unchecked Sendable {
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        Transcript(language: "de-DE", words: (0..<40).map {
            TranscriptWord(text: "Wort\($0)", range: TimeRange(start: Time(Int64($0), 2), end: Time(Int64($0) + 1, 2)))
        })
    }
}

/// The shared-toolkit Transcribe tab (`TranscriptTabDraw`) against the same `CaptionsPanelModel` as the Mac view.
@MainActor @Suite(.serialized) struct TranscriptTabDrawTests {
    func ready() async -> (TranscriptTabDraw, CaptionsPanelModel) {
        let m = CaptionsPanelModel(service: Words())
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        let tab = TranscriptTabDraw()
        tab.size = CGSize(width: 320, height: 480)
        tab.model = m
        m.transcribe(); await m.waitForTranscription()
        var c = Canvas(width: 320, height: 480, atlas: nil, scale: 1)
        tab.draw(&c)
        return (tab, m)
    }

    func press(_ t: TranscriptTabDraw, _ p: CGPoint, count: Int = 1) {
        t.mouseDown(at: p, clickCount: count); t.mouseUp(at: p)
    }

    @Test func withoutASequenceTheTabShowsTheEmptyState() {
        let tab = TranscriptTabDraw()
        tab.size = CGSize(width: 320, height: 480)
        #expect(tab.showsEmptyState)
        var c = Canvas(width: 320, height: 480, atlas: nil, scale: 1)
        tab.draw(&c)
        tab.model = CaptionsPanelModel(service: Words())
        #expect(!tab.showsEmptyState)
    }

    @Test func idleShowsTheTranscribeButtonOnly() {
        let m = CaptionsPanelModel(service: Words())
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        let tab = TranscriptTabDraw()
        tab.model = m
        #expect(tab.isIdle && tab.transcribeTitle == "Transcribe" && tab.transcribeIsAccent)
        #expect(tab.control(at: CGPoint(x: 20, y: 11)) == .transcribe)
        #expect(tab.control(at: CGPoint(x: 100, y: 40)) == nil)
    }

    @Test func transcribeThenTheWordsAreLaidOutAndTheTitleChanges() async {
        let (tab, m) = await ready()
        #expect(tab.isReady && tab.transcribeTitle == "Transcribe Again" && !tab.transcribeIsAccent)
        #expect(tab.statusText == "40 words")
        #expect(m.transcript?.words.count == 40)
    }

    @Test func clickSeeksDoubleClickEditsReturnKeeps() async {
        let (tab, m) = await ready()
        var seeked: Time?
        m.onSeek = { seeked = $0 }
        // First word: top-left of the text area (8 pt pad, 5 pt line pad, 4 pt inset).
        let f = tab.frameForTests(.text)
        let p = CGPoint(x: f.minX + 5 + 8, y: f.minY + 4 + 11)
        press(tab, p)
        #expect(seeked == Time(0, 2) || seeked == .zero)
        press(tab, p, count: 2)
        #expect(tab.editing?.index == 0)
        for ch in "Hi" { _ = tab.key(.character(ch), modifiers: []) }
        _ = tab.key(.enter, modifiers: [])
        #expect(tab.editing == nil)
        #expect(m.transcript?.words.first?.text == "Hi" || m.transcript?.text.hasPrefix("Hi") == true || m.transcript?.words.first?.text.hasSuffix("Hi") == true)
    }

    @Test func searchMarksAndStepsThroughTheMatches() async {
        let (tab, m) = await ready()
        var marks: ([Time], String)?
        tab.onMarkHits = { marks = ($0, $1) }
        let f = tab.frameForTests(.search)
        press(tab, CGPoint(x: f.midX, y: f.midY))
        for ch in "Wort3" { _ = tab.key(.character(ch), modifiers: []) }   // Wort3, Wort30...Wort39: 11 hits
        _ = tab.key(.enter, modifiers: [])
        #expect(m.currentWordID != nil)
        tab.markAll()
        #expect(marks?.1 == "Wort3")
        #expect(marks?.0.count == 11)
    }

    @Test func languageMenuListsTheModelLanguages() async {
        let (tab, m) = await ready()
        var items: [SQMenuItem] = []
        tab.onMenu = { i, _ in items = i }
        let f = tab.frameForTests(.language)
        press(tab, CGPoint(x: f.midX, y: f.midY))
        #expect(items.count == m.languages.count)
        #expect(items.filter(\.isChecked).count == 1)
    }

    @Test func languagePopupIsWideEnoughForItsWidestTitleLikeTheMac() async {
        let (tab, m) = await ready()
        let f = tab.frameForTests(.language)
        let canvas = Canvas(width: 320, height: 400, atlas: nil, scale: 1)
        let fs = CGFloat(DrawTheme.TypeSize.body)
        let widest = m.languages.map { canvas.size(of: tab.languageTitle($0), fontSize: fs).width }.max() ?? 0
        #expect(f.width >= ceil(widest + 32))
        #expect(f.width >= 120)
    }

    @Test func createCaptionsNeedsAFreshTranscript() async {
        let (tab, _) = await ready()
        var n = 0
        tab.onCreateCaptions = { n += 1 }
        let f = tab.frameForTests(.create)
        press(tab, CGPoint(x: f.midX, y: f.midY))
        // The model needs a sequence source before it lets captions be created; the button must not fire without it.
        #expect(n == (tab.model?.canCreateCaptions == true ? 1 : 0))
    }

    @Test func textPanelShowsTranscribeFirstOnlyWithAService() throws {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])]))
        let panel = TextPanelDraw(session: s)
        #expect(panel.tabs == [.captions, .style, .templates] && panel.tab == .captions)
        panel.useTranscription { Words() }
        #expect(panel.tabs == [.transcript, .captions, .style, .templates] && panel.tab == .transcript)
        #expect(panel.transcript.model != nil)
        #expect(panel.transcript.model === panel.transcriptModel(for: try #require(s.activeTimeline?.id)))
    }
}
