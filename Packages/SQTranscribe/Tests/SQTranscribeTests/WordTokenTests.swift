import CoreMedia
import Foundation
import Speech
import Testing
import SQCore
@testable import SQTranscribe

/// FB-M: recognized text becomes whole words. A dash the recognizer glued between two words ("ausprobieren–das")
/// is its own token, so the words keep their space; a hyphenated compound ("E-Mail") stays one word.
@Suite struct WordTokenTests {
    @Test func whitespaceSeparatesWords() {
        #expect(SpeechAnalyzerTranscriber.tokens("  Hallo   Welt ") == ["Hallo", "Welt"])
    }

    @Test func gluedDashBecomesItsOwnToken() {
        #expect(SpeechAnalyzerTranscriber.tokens("ausprobieren\u{2013}das Rennen") == ["ausprobieren", "\u{2013}", "das", "Rennen"])
        #expect(SpeechAnalyzerTranscriber.tokens("so\u{2014}schnell") == ["so", "\u{2014}", "schnell"])
        #expect(SpeechAnalyzerTranscriber.tokens("ja \u{2013} nein") == ["ja", "\u{2013}", "nein"])
    }

    @Test func hyphenatedCompoundStaysOneWord() {
        #expect(SpeechAnalyzerTranscriber.tokens("die E-Mail") == ["die", "E-Mail"])
    }

    @Test func lineWrapKeepsADashAtTheEndOfItsLine() {
        #expect(CaptionSegmenter.wrap(["eins", "zwei", "\u{2013}", "drei"], maxChars: 9) == ["eins zwei \u{2013}", "drei"])
        #expect(CaptionSegmenter.wrap(["Geschwindigkeitsbegrenzung", "gilt"], maxChars: 9) == ["Geschwindigkeitsbegrenzung", "gilt"])
    }

    @Test func timedRunsSplitIntoWholeWords() {
        var a = AttributedString("ausprobieren\u{2013}das")
        a.audioTimeRange = CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))
        let words = SpeechAnalyzerTranscriber.words(from: a)
        #expect(words.map(\.text) == ["ausprobieren", "\u{2013}", "das"])
        #expect(words.first?.range.start == .zero && words.last?.range.end == Time(3, 1))
    }
}

/// Unsure words: the recognizer's per-run confidence becomes the confidence of every word of the run; no value stays nil.
@Suite struct WordConfidenceTests {
    @Test func aRunsConfidenceReachesItsWords() {
        var a = AttributedString("so schnell")
        a.audioTimeRange = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        a.transcriptionConfidence = 0.3
        let words = SpeechAnalyzerTranscriber.words(from: a)
        #expect(words.count == 2 && words.allSatisfy { $0.confidence == 0.3 })
    }

    @Test func noReportedConfidenceStaysNil() {
        var a = AttributedString("so schnell")
        a.audioTimeRange = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        #expect(SpeechAnalyzerTranscriber.words(from: a).allSatisfy { $0.confidence == nil })
    }

    @Test func confidenceReachesTheCaptionWords() {
        let w = TranscriptWord(text: "eins", range: TimeRange(start: .zero, end: Time(1, 1)), confidence: 0.4)
        let t = Transcript(language: "de-DE", words: [w, TranscriptWord(text: "zwei", range: TimeRange(start: Time(1, 1), end: Time(2, 1)))])
        let caps = CaptionSegmenter.segment(t, preset: .standard)
        #expect(caps.flatMap(\.words).map(\.confidence) == [0.4, nil])
    }
}
