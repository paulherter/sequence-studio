import Foundation
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct CaptionShortVideoTests {
    /// The maintainer-like speech: ~108 words/min, mixed lengths, tiny words, German compounds, pauses.
    static func paulTranscript() -> Transcript {
        let vocab = ["Ich", "habe", "heute", "ein", "neues", "Video", "geschnitten", "und", "es", "ist",
                     "a", "Geschwindigkeitsbegrenzung", "Bildschirmaufnahme", "so", "schnell", "wie", "nie",
                     "Zusammenarbeit", "ja,", "Wahnsinn!", "Kaffeemaschinenreiniger", "du", "ok"]
        var words: [TranscriptWord] = []
        var ms: Int64 = 0
        for i in 0..<108 {
            let text = vocab[(i * 7 + i / 5) % vocab.count]
            // Short words are spoken fast (0.11 to 0.17 s) and often run straight into the next one.
            let dur: Int64 = text.count <= 3 ? 110 + Int64(i % 4) * 20 : 400 + Int64(text.count) * 12
            words.append(w(text, ms, ms + dur))
            ms += dur + (i % 9 == 8 ? 700 : (i % 3 == 0 ? 0 : 60))
        }
        return transcript(words)
    }

    @Test func presetDefaults() {
        let p = CaptionPreset.shortVideo
        #expect(p.maxWordsPerCaption == 1)
        #expect(p.minDuration == t(200))
        #expect(p.maxCharsPerLine == 11)
        #expect(p.emphasis == .pill)
    }

    @Test func paulTranscriptMeetsAcceptance() {
        let tr = Self.paulTranscript()
        let preset = CaptionPreset.shortVideo
        let caps = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(tr, preset: preset), preset: preset)
        #expect(!caps.isEmpty)
        for c in caps {
            #expect(c.range.end - c.range.start >= t(200), "caption \(c.lines) too short")
            // FB-M: words are never split; only a single word may be longer than a line.
            #expect(c.lines.allSatisfy { $0.count <= 11 || !$0.contains(" ") }, "caption \(c.lines) too long")
        }
        for (a, b) in zip(caps, caps.dropFirst()) { #expect(a.range.end <= b.range.start) }
        var covered = Set<Int>()
        for c in caps { covered.formUnion(c.wordIndices) }
        #expect(covered == Set(tr.words.indices))
        let joined = caps.map { $0.lines.joined(separator: " ") }.joined(separator: " ")
        #expect(joined == tr.text)
    }

    @Test func oneWordPerCaptionWhenTimingAllows() {
        let tr = transcript([w("Hallo", 0, 500), w("Welt", 600, 1100), w("heute", 1200, 1700)])
        let caps = CaptionSegmenter.segment(tr, preset: .shortVideo)
        #expect(caps.map { $0.lines } == [["Hallo"], ["Welt"], ["heute"]])
    }

    @Test func longWordStaysWhole() {
        let tr = transcript([w("Geschwindigkeitsbegrenzung", 0, 2600)])
        let caps = CaptionSegmenter.segment(tr, preset: .shortVideo)
        #expect(caps.map(\.lines) == [["Geschwindigkeitsbegrenzung"]])
        #expect(caps.first?.range == TimeRange(start: t(0), end: t(2600)))
    }

    @Test func noCaptionEverCarriesAPieceOfAWord() {
        let tr = Self.paulTranscript()
        let words = Set(tr.words.map(\.text))
        for preset in [CaptionPreset.shortVideo, .standard] {
            let caps = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(tr, preset: preset), preset: preset)
            for c in caps { for l in c.lines { for piece in l.split(separator: " ") { #expect(words.contains(String(piece)), "\(piece)") } } }
        }
    }

    @Test func dashJoinsThePreviousWordInsteadOfStandingAlone() {
        let tr = transcript([w("ausprobieren", 0, 600), w("\u{2013}", 600, 650), w("das", 700, 900), w("Rennen", 950, 1400)])
        let caps = CaptionSegmenter.segment(tr, preset: .shortVideo)
        #expect(caps.map(\.lines) == [["ausprobieren \u{2013}"], ["das"], ["Rennen"]])
        #expect(caps[0].words.map(\.text) == ["ausprobieren", "\u{2013}"])
    }

    @Test func tooShortWordBetweenTightNeighboursIsNotLeftUnderMinimum() {
        let tr = transcript([w("Hallo", 0, 500), w("a", 500, 600), w("Welt", 600, 1100)])
        let preset = CaptionPreset.shortVideo
        let caps = CaptionSegmenter.applyTiming(CaptionSegmenter.segment(tr, preset: preset), preset: preset)
        #expect(caps.allSatisfy { $0.range.end - $0.range.start >= t(200) })
        var covered = Set<Int>(); for c in caps { covered.formUnion(c.wordIndices) }
        #expect(covered == [0, 1, 2])
    }

    @Test func oldPresetJSONDecodesWithDefaults() throws {
        let data = try JSONEncoder().encode(CaptionPreset.standard)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "maxWordsPerCaption"); obj.removeValue(forKey: "emphasis")
        let p = try JSONDecoder().decode(CaptionPreset.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(p.maxWordsPerCaption == nil && p.emphasis == .none)
    }

    private func allValid(_ caps: [Caption], words: Int) -> Bool {
        var covered = Set<Int>(); for c in caps { covered.formUnion(c.wordIndices) }
        return covered == Set(0..<words)
            && caps.allSatisfy { $0.range.end - $0.range.start >= t(200) && $0.lines.allSatisfy { $0.count <= 11 || !$0.contains(" ") } }
            && zip(caps, caps.dropFirst()).allSatisfy { $0.range.end <= $1.range.start }
    }

    @Test func lastShortWordExtendsIntoTrailingTime() {
        let tr = transcript([w("Hallo", 0, 500), w("ja", 600, 650)])
        let caps = CaptionSegmenter.segment(tr, preset: .shortVideo)
        #expect(allValid(caps, words: 2))
        #expect(caps.last?.range.start == t(600))
    }

    @Test func twoTinyNeighboursThatCannotMergeKeepTheMinimum() {
        let tr = transcript([w("Hello", 0, 50), w("wonderful", 50, 100)])
        let caps = CaptionSegmenter.segment(tr, preset: .shortVideo)
        #expect(caps.count == 2)
        #expect(allValid(caps, words: 2))
        let cascade = transcript([w("Hello", 0, 50), w("wonderful", 50, 100), w("amazing", 100, 150), w("stuff", 150, 200)])
        #expect(allValid(CaptionSegmenter.segment(cascade, preset: .shortVideo), words: 4))
    }

}
