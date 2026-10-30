import Foundation
import Testing
@testable import SQCore

private let ms = Time(1, 1000)
private func t(_ n: Int64) -> Time { Time(n, 1000) }
private func range(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: t(a), end: t(b)) }

/// A caption with one word per `step` ms, timed (word times relative to the start, like the segmenter writes them).
private func spoken(_ text: String, start: Int64, step: Int64 = 300, style: String = "s") -> CaptionItem {
    let toks = text.split(separator: " ").map(String.init)
    let words = toks.enumerated().map { CaptionWord(text: $1, range: TimeRange(start: t(Int64($0) * step), end: t(Int64($0) * step + step - 50))) }
    let end = start + Int64(toks.count) * step - 50
    return CaptionItem(lines: [text], range: range(start, end), styleRef: style, animationRef: "a", words: words)
}
private func texts(_ items: [CaptionItem]) -> [String] { items.map(\.text) }
private func opts(words: Int = 3, maxMs: Int64 = 10_000, minMs: Int64 = 0, bridgeMs: Int64 = 0, gapMs: Int64 = 0) -> CaptionTidyOptions {
    CaptionTidyOptions(maxWords: words, maxDuration: t(maxMs), minDuration: t(minMs), bridgeGapsUnder: t(bridgeMs), gap: t(gapMs))
}

@Suite struct CaptionTidyTests {
    @Test func longCaptionSplitsIntoShortChunks() {
        let r = CaptionTidy.tidy([spoken("one two three four five six seven eight", start: 0)], options: opts(), frameDuration: ms)
        #expect(texts(r) == ["one two three", "four five six", "seven eight"])
    }

    @Test func chunkRangeAndWordTimingsFollowTheSpeech() {
        let r = CaptionTidy.tidy([spoken("one two three four", start: 1000)], options: opts(words: 2), frameDuration: ms)
        #expect(r.count == 2)
        #expect(r[1].range == range(1600, 2150))            // "three" starts at 1600, "four" ends at 2150
        #expect(r[1].hasWordTimings)
        #expect(r[1].effectiveWords.map(\.range.start) == [t(1600), t(1900)])
    }

    @Test func sentenceEndBreaksTheChunk() {
        let r = CaptionTidy.tidy([spoken("Hi there. How are you", start: 0)], options: opts(), frameDuration: ms)
        #expect(texts(r) == ["Hi there.", "How are you"])
    }

    @Test func maxDurationBreaksTheChunk() {
        let r = CaptionTidy.tidy([spoken("a b c d", start: 0, step: 600)], options: opts(words: 4, maxMs: 1_300), frameDuration: ms)
        #expect(texts(r) == ["a b", "c d"])
    }

    @Test func styleAndAnimationAreKeptAndTheFirstChunkKeepsTheID() {
        let item = spoken("one two three four", start: 0, style: "bold")
        let r = CaptionTidy.tidy([item], options: opts(words: 2), frameDuration: ms)
        #expect(r.allSatisfy { $0.styleRef == "bold" && $0.animationRef == "a" })
        #expect(r[0].id == item.id)
        #expect(r[1].id != item.id)
    }

    @Test func overlapsAreRemoved() {
        let a = CaptionItem(lines: ["first"], range: range(0, 1500)), b = CaptionItem(lines: ["second"], range: range(1000, 2000))
        let r = CaptionTidy.tidy([b, a], options: opts(), frameDuration: ms)
        #expect(r.map(\.range) == [range(0, 1000), range(1000, 2000)])
    }

    @Test func smallGapsAreBridgedLargeOnesStay() {
        let items = [CaptionItem(lines: ["a"], range: range(0, 500)), CaptionItem(lines: ["b"], range: range(600, 1000)),
                     CaptionItem(lines: ["c"], range: range(3000, 3500))]
        let r = CaptionTidy.tidy(items, options: opts(bridgeMs: 250), frameDuration: ms)
        #expect(r.map(\.range) == [range(0, 600), range(600, 1000), range(3000, 3500)])
    }

    @Test func gapIsKeptBetweenBridgedCaptions() {
        let items = [CaptionItem(lines: ["a"], range: range(0, 500)), CaptionItem(lines: ["b"], range: range(600, 1000))]
        let r = CaptionTidy.tidy(items, options: opts(bridgeMs: 250, gapMs: 40), frameDuration: ms)
        #expect(r[0].range == range(0, 560))
    }

    @Test func shortCaptionGrowsIntoTheSilenceButNotOverTheNext() {
        let items = [CaptionItem(lines: ["a"], range: range(0, 200)), CaptionItem(lines: ["b"], range: range(700, 800)),
                     CaptionItem(lines: ["c"], range: range(5000, 5100))]
        let r = CaptionTidy.tidy(items, options: opts(minMs: 500), frameDuration: ms)
        #expect(r.map(\.range) == [range(0, 500), range(700, 1200), range(5000, 5500)])
    }

    @Test func untimedCaptionsSplitToo() {
        let item = CaptionItem(lines: ["alpha beta gamma delta"], range: range(0, 4000))
        let r = CaptionTidy.tidy([item], options: opts(words: 2), frameDuration: ms)
        #expect(texts(r) == ["alpha beta", "gamma delta"])
        #expect(r[0].range.end <= r[1].range.start)
    }

    @Test func emptyCaptionsAreDropped() {
        let r = CaptionTidy.tidy([CaptionItem(lines: [" "], range: range(0, 500)), CaptionItem(lines: ["x"], range: range(600, 900))],
                                 options: opts(), frameDuration: ms)
        #expect(texts(r) == ["x"])
    }

    @Test func resultIsFrameAlignedSortedAndNeverOverlaps() {
        let fd = Time(1001, 30000)
        let items = [spoken("one two three four five six", start: 130), spoken("next one here", start: 2300)]
        let r = CaptionTidy.tidy(items, options: .tikTok, frameDuration: fd)
        for c in r {
            #expect(c.range.start == c.range.start.snapped(to: fd) && c.range.end == c.range.end.snapped(to: fd))
            #expect(!c.range.isEmpty)
        }
        for (a, b) in zip(r, r.dropFirst()) { #expect(a.range.end <= b.range.start) }
    }

    @Test func tidyingTwiceChangesNothing() {
        let fd = Time(1, 30)
        let once = CaptionTidy.tidy([spoken("one two three four five six seven", start: 0)], options: .tikTok, frameDuration: fd)
        #expect(CaptionTidy.tidy(once, options: .tikTok, frameDuration: fd) == once)
    }

    @Test func trackAcceptsTheResult() throws {
        var track = CaptionTrack()
        let r = CaptionTidy.tidy([spoken("one two three four five six", start: 0)], options: .tikTok, frameDuration: Time(1, 30))
        try track.replaceAll(r)
        #expect(track.items.count == r.count)
    }
}
