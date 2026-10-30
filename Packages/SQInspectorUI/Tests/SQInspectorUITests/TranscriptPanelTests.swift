import AppKit
import Foundation
import Testing
import SQCore
import SQTranscribe
@testable import SQInspectorUI

private final class ThirtyWords: TranscriptionService, @unchecked Sendable {
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        Transcript(language: "de-DE", words: (0..<30).map {
            TranscriptWord(text: "Wort\($0)", range: TimeRange(start: Time(Int64($0), 2), end: Time(Int64($0) + 1, 2)))
        })
    }
}

/// FB-M bug 1: after transcribing, the status said "30 words" but the transcript editor showed nothing.
@MainActor @Suite struct TranscriptPanelTests {
    @Test func transcriptTextIsVisibleInTheEditor() async throws {
        let m = CaptionsPanelModel(service: ThirtyWords())
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        let view = CaptionsPanelView(model: m)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        m.transcribe(); await m.waitForTranscription()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.transcriptTextView.string.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        window.contentView?.layoutSubtreeIfNeeded()
        let tv = view.transcriptTextView
        #expect(tv.string == m.transcript?.text)
        // The text view must be big enough to show its text: as wide as the scroll view and as tall as the laid-out text.
        let lm = try #require(tv.layoutManager), tc = try #require(tv.textContainer)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        #expect(used.width > 100, "text laid out in a \(used.width) pt wide container")
        #expect(tv.frame.width > 200, "text view is \(tv.frame.width) pt wide")
        #expect(tv.frame.height >= used.height, "text view is \(tv.frame.height) pt tall, text needs \(used.height)")
        #expect(!tv.visibleRect.isEmpty)
    }
}
