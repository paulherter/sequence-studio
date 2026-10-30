import CoreMedia
import Foundation
import Speech
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct TranscriptWordUnsureTests {
    private func w(_ c: Float?, edited: Bool = false) -> TranscriptWord {
        TranscriptWord(text: "a", range: TimeRange(start: Time(0, 1), end: Time(1, 1)), isEdited: edited, confidence: c)
    }

    @Test func sameRuleAsTheTimelineWords() {
        #expect(w(0.49).isUnsure)
        #expect(!w(0.5).isUnsure)
        #expect(!w(nil).isUnsure)
        #expect(!w(nil, edited: true).isUnsure)
    }
}

@Suite struct WordConfidenceFollowUpTests {
    @Test func twoConfidencesInOneTimeRangeGiveOneWordWithTheLowest() {
        var a = AttributedString("Hallo Welt")
        a.audioTimeRange = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        let split = a.index(a.startIndex, offsetByCharacters: 5)
        a[a.startIndex..<split].transcriptionConfidence = 0.8
        a[split..<a.endIndex].transcriptionConfidence = 0.3
        let words = SpeechAnalyzerTranscriber.words(from: a)
        #expect(words.map(\.text) == ["Hallo", "Welt"])
        #expect(words.allSatisfy { $0.confidence == 0.3 })
        #expect(words.first?.range.start == .zero && words.last?.range.end == Time(2, 1))
        #expect(words[0].range.end == words[1].range.start)
    }

    @Test func aHandCorrectedWordLosesItsConfidence() {
        let w = TranscriptWord(text: "paul", range: TimeRange(start: .zero, end: Time(1, 1)), confidence: 0.3)
        let edited = Transcript(language: "de-DE", words: [w]).applyingText("Anna,")
        #expect(edited.words.first?.text == "Anna,")
        #expect(edited.words.first?.confidence == nil)
        let caps = CaptionSegmenter.segment(edited, preset: .standard)
        #expect(caps.flatMap(\.words).allSatisfy { $0.confidence == nil })
    }
}
