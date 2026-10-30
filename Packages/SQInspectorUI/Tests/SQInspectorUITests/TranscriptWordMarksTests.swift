import AppKit
import Foundation
import Testing
import SQCore
import SQTranscribe
import SQUIKit
@testable import SQInspectorUI

/// The transcript panel's per-word marks (`CaptionsPanelView.wordMarks`): unsure words get the warning underline,
/// the same rule as the timeline word boxes.
@MainActor @Suite struct TranscriptWordMarksTests {
    private func word(_ c: Float?, edited: Bool = false) -> TranscriptWord {
        TranscriptWord(text: "a", range: TimeRange(start: .zero, end: Time(1, 1)), isEdited: edited, confidence: c)
    }

    @Test func unsureWordIsUnderlinedInWarningColor() {
        let m = CaptionsPanelView.wordMarks(for: word(0.3))
        #expect(m[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(m[.underlineColor] as? NSColor == Theme.Colors.warning)
    }

    @Test func sureAndUnknownWordsHaveNoMark() {
        #expect(CaptionsPanelView.wordMarks(for: word(0.5)).isEmpty)
        #expect(CaptionsPanelView.wordMarks(for: word(nil)).isEmpty)
    }

    @Test func editedWordIsYellowAndHandTypedIsNeverUnsure() {
        let m = CaptionsPanelView.wordMarks(for: word(nil, edited: true))
        #expect(m[.underlineColor] as? NSColor == Theme.Colors.yellow)
    }

    @Test func attributedTextCarriesTheMarkOnTheWordRange() {
        let words = [word(0.9), word(0.2), word(nil)]
        let s = NSMutableAttributedString(string: "aa bb cc")
        CaptionsPanelView.applyWordMarks(to: s, words: words, ranges: [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2), NSRange(location: 6, length: 2)])
        #expect(s.attribute(.underlineColor, at: 0, effectiveRange: nil) == nil)
        #expect(s.attribute(.underlineColor, at: 3, effectiveRange: nil) as? NSColor == Theme.Colors.warning)
        #expect(s.attribute(.underlineColor, at: 6, effectiveRange: nil) == nil)
    }
}
