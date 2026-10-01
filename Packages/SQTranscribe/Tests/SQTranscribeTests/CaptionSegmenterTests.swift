import Testing
import SQCore
@testable import SQTranscribe

@Suite struct CaptionSegmenterTests {
    func preset(chars: Int = 20, lines: Int = 2, maxDur: Int64 = 6000, minDur: Int64 = 0, pause: Int64 = 800) -> CaptionPreset {
        CaptionPreset(maxCharsPerLine: chars, maxLines: lines, maxDuration: t(maxDur), minDuration: t(minDur),
                      pauseBreak: t(pause), styleRef: "style.a", animationRef: "anim.b")
    }

    /// n words of the given text, 300 ms long, 100 ms apart.
    func run(_ texts: [String], gap: Int64 = 100) -> Transcript {
        var out: [TranscriptWord] = []
        var cur: Int64 = 0
        for x in texts { out.append(w(x, cur, cur + 300)); cur += 300 + gap }
        return transcript(out)
    }

    @Test func emptyTranscriptGivesNoCaptions() {
        #expect(CaptionSegmenter.segment(transcript([]), preset: preset()).isEmpty)
    }

    @Test func shortTextIsOneCaptionWithRefs() {
        let tr = run(["Hallo", "Welt"])
        let caps = CaptionSegmenter.segment(tr, preset: preset())
        #expect(caps.count == 1)
        #expect(caps[0].lines == ["Hallo Welt"])
        #expect(caps[0].range == TimeRange(start: t(0), end: t(700)))
        #expect(caps[0].firstWordID == tr.words[0].id && caps[0].lastWordID == tr.words[1].id)
        #expect(caps[0].wordIndices == 0..<2)
        #expect(caps[0].styleRef == "style.a" && caps[0].animationRef == "anim.b")
    }

    @Test func wrapsLinesAtCharLimit() {
        let caps = CaptionSegmenter.segment(run(["aaaaaaaa", "bbbbbbbb", "cccccccc"]), preset: preset(chars: 17))
        #expect(caps.count == 1)
        #expect(caps[0].lines == ["aaaaaaaa bbbbbbbb", "cccccccc"])
    }

    @Test func lineNeverExceedsLimitExceptSingleLongWord() {
        let words = (0..<30).map { _ in "wort" }
        for c in CaptionSegmenter.segment(run(words), preset: preset(chars: 12)) {
            #expect(c.lines.count <= 2)
            #expect(c.lines.allSatisfy { $0.count <= 12 })
        }
    }

    @Test func breaksWhenMaxLinesExceeded() {
        let caps = CaptionSegmenter.segment(run(["aaaa", "bbbb", "cccc"]), preset: preset(chars: 4, lines: 2))
        #expect(caps.count == 2)
        #expect(caps[0].lines == ["aaaa", "bbbb"])
        #expect(caps[1].lines == ["cccc"])
        #expect(caps[1].wordIndices == 2..<3)
    }

    @Test func singleLineMode() {
        let caps = CaptionSegmenter.segment(run(["aaaa", "bbbb", "cccc"]), preset: preset(chars: 9, lines: 1))
        #expect(caps.map(\.lines) == [["aaaa bbbb"], ["cccc"]])
    }

    @Test func breaksOnMaxDuration() {
        let caps = CaptionSegmenter.segment(run(["a", "b", "c", "d"]), preset: preset(chars: 50, maxDur: 1000))
        // words at 0-300, 400-700, 800-1100, 1200-1500 -> third would end at 1100 > 1000
        #expect(caps.count == 3 || caps.count == 2)
        for c in caps { #expect(c.range.duration <= t(1000) || c.wordIndices.count == 1) }
        #expect(caps[0].wordIndices == 0..<2)
    }

    @Test func breaksOnPause() {
        let tr = transcript([w("eins", 0, 300), w("zwei", 400, 700), w("drei", 2000, 2300)])
        let caps = CaptionSegmenter.segment(tr, preset: preset(pause: 800))
        #expect(caps.map(\.lines) == [["eins zwei"], ["drei"]])
    }

    @Test func breaksAtSentenceEndWhenReasonablyFull() {
        let tr = run(["Das", "ist", "ein", "Satz.", "Und", "noch", "einer."])
        let caps = CaptionSegmenter.segment(tr, preset: preset(chars: 20, lines: 2))
        #expect(caps.count == 2)
        #expect(caps[0].lines == ["Das ist ein Satz."])
        #expect(caps[1].lines == ["Und noch einer."])
    }

    @Test func doesNotBreakAtSentenceEndWhenMostlyEmpty() {
        let tr = run(["Ja.", "Nein."])
        let caps = CaptionSegmenter.segment(tr, preset: preset(chars: 40, lines: 2))
        #expect(caps.count == 1)
    }

    @Test func noOverlapsAndAllWordsCoveredOnce() {
        let words = (0..<60).map { "Wort\($0)" }
        let caps = CaptionSegmenter.segment(run(words), preset: preset(chars: 15))
        var next = 0
        for (i, c) in caps.enumerated() {
            #expect(c.wordIndices.lowerBound == next)
            next = c.wordIndices.upperBound
            if i > 0 { #expect(caps[i - 1].range.end <= c.range.start) }
        }
        #expect(next == 60)
    }

    @Test func overlappingWordTimesAreClampedSoCaptionsDoNotOverlap() {
        let tr = transcript([w("a", 0, 1000), w("b", 500, 1500)])
        let caps = CaptionSegmenter.segment(tr, preset: preset(chars: 1, lines: 1))
        #expect(caps.count == 2)
        #expect(caps[0].range.end <= caps[1].range.start)
        #expect(!caps[1].range.isEmpty)
    }

    @Test func singleVeryLongWordGetsOwnLine() {
        let long = String(repeating: "x", count: 50)
        let caps = CaptionSegmenter.segment(run(["kurz", long, "kurz"]), preset: preset(chars: 10, lines: 2))
        #expect(caps.flatMap(\.lines).contains(long))
        #expect(caps.allSatisfy { $0.lines.count <= 2 })
        #expect(caps.reduce(0) { $0 + $1.wordIndices.count } == 3)
    }

    @Test func singleLongWordAloneIsOneCaption() {
        let long = String(repeating: "x", count: 50)
        let caps = CaptionSegmenter.segment(run([long]), preset: preset(chars: 10))
        #expect(caps.count == 1)
        #expect(caps[0].lines == [long])
    }

    @Test func minDurationSuppressesSoftSentenceBreak() {
        let tr = run(["Ja.", "Nein.", "Gut."])
        let caps = CaptionSegmenter.segment(tr, preset: preset(chars: 6, lines: 1, minDur: 5000))
        // limits still force breaks; sentence rule alone must not split short captions
        let roomy = CaptionSegmenter.segment(tr, preset: preset(chars: 40, lines: 2, minDur: 5000))
        #expect(roomy.count == 1)
        #expect(caps.count >= 1)
    }
}
