import Testing
import SQCore
@testable import SQTranscribe

@Suite struct TranscriptEditingTests {
    let base = transcript([w("Hallo,", 0, 500), w("liebe", 600, 1000), w("Welt.", 1200, 2000)])

    @Test func unchangedTextChangesNothing() {
        let r = base.applyingText("Hallo, liebe Welt.")
        #expect(r == base)
        #expect(r.words.allSatisfy { !$0.isEdited })
    }

    @Test func punctuationAndCaseAreIgnoredForDiffButTextIsVerbatim() {
        let r = base.applyingText("hallo liebe Welt!")
        #expect(r.words.map(\.range) == base.words.map(\.range))
        #expect(r.words.map(\.id) == base.words.map(\.id))
        #expect(r.text == "hallo liebe Welt!")
        #expect(r.words[0].isEdited && r.words[2].isEdited)
        #expect(!r.words[1].isEdited)
    }

    @Test func replacedWordTakesOldSlot() {
        let r = base.applyingText("Hallo, liebe Leute.")
        #expect(r.words.count == 3)
        #expect(r.words[2].text == "Leute.")
        #expect(r.words[2].range == base.words[2].range)
        #expect(r.words[2].isEdited)
        #expect(r.words[0].range == base.words[0].range)
        #expect(r.words[1].range == base.words[1].range)
    }

    @Test func deletedWordsVanish() {
        let r = base.applyingText("Hallo, Welt.")
        #expect(r.words.map(\.text) == ["Hallo,", "Welt."])
        #expect(r.words[0].range == base.words[0].range)
        #expect(r.words[1].range == base.words[2].range)
    }

    @Test func insertedWordsSplitGapProportionallyToCharCount() {
        // gap between "Hallo," (end 500) and "liebe" (start 600) = 100 ms; "ab" = 2 chars, "cdef" = 4 chars
        let r = base.applyingText("Hallo, ab cdef liebe Welt.")
        #expect(r.words.map(\.text) == ["Hallo,", "ab", "cdef", "liebe", "Welt."])
        let ab = r.words[1].range, cd = r.words[2].range
        #expect(ab.start == t(500))
        #expect(ab.duration == Time(100 * 2, 6 * 1000))
        #expect(ab.end == cd.start)
        #expect(cd.end == t(600))
        #expect(r.words[1].isEdited && r.words[2].isEdited)
        #expect(r.words[0].range == base.words[0].range)
        #expect(r.words[3].range == base.words[1].range)
    }

    @Test func insertedWordsStrictlyIncreasingAndNonOverlapping() {
        let r = base.applyingText("Hallo, a bb ccc dddd eeeee liebe Welt.")
        for (a, b) in zip(r.words, r.words.dropFirst()) {
            #expect(a.range.start < b.range.start)
            #expect(a.range.end <= b.range.start)
        }
    }

    @Test func insertAtEndUsesFallbackDurationPerWord() {
        let r = base.applyingText("Hallo, liebe Welt. Und mehr")
        let und = r.words[3].range, mehr = r.words[4].range
        #expect(und.start == t(2000))
        #expect(und.duration == TranscriptEditing.fallbackWordDuration)
        #expect(mehr.start == und.end)
        #expect(mehr.duration == TranscriptEditing.fallbackWordDuration)
        #expect(TranscriptEditing.fallbackWordDuration == Time(1, 3))
    }

    @Test func insertAtStartEndsAtFirstWordStart() {
        let tr = transcript([w("liebe", 2000, 2500)])
        let r = tr.applyingText("Hallo liebe")
        #expect(r.words[0].text == "Hallo")
        #expect(r.words[0].range.end == t(2000))
        #expect(r.words[0].range.duration == TranscriptEditing.fallbackWordDuration)
        #expect(r.words[1].range == tr.words[0].range)
    }

    @Test func insertAtStartNeverGoesNegative() {
        let tr = transcript([w("liebe", 100, 500)])
        let r = tr.applyingText("Hallo liebe")
        #expect(r.words[0].range.start == .zero)
        #expect(r.words[0].range.end == t(100))
    }

    @Test func replacingMoreWordsSpreadsOverOldSpan() {
        let r = base.applyingText("Hallo, liebe große weite Welt.")
        // "Welt." unchanged
        #expect(r.words.last?.range == base.words[2].range)
        #expect(r.words.count == 5)
        for (a, b) in zip(r.words, r.words.dropFirst()) { #expect(a.range.end <= b.range.start) }
    }

    @Test func emptyTranscriptGetsSequentialFallbackWords() {
        let r = transcript([]).applyingText("eins zwei")
        #expect(r.words.count == 2)
        #expect(r.words[0].range.start == .zero)
        #expect(r.words[1].range.start == r.words[0].range.end)
    }

    @Test func deletingEverythingGivesEmptyTranscript() {
        #expect(base.applyingText("  ").words.isEmpty)
    }

    @Test func languageIsPreserved() {
        #expect(base.applyingText("x").language == "de-DE")
    }

    // MARK: zero / tiny gaps share time with neighbours

    private func expectContiguousPositive(_ r: Transcript) {
        for x in r.words { #expect(x.range.duration > .zero) }
        for (a, b) in zip(r.words, r.words.dropFirst()) {
            #expect(a.range.end == b.range.start)
        }
    }

    @Test func zeroGapInsertionSharesTimeWithNeighboursByCharCount() {
        // "abcd" 0..400, "efgh" 400..800, zero gap. Insert "xx" (2 chars): total 10 chars over 0..800.
        let b = transcript([w("abcd", 0, 400), w("efgh", 400, 800)])
        let r = b.applyingText("abcd xx efgh")
        #expect(r.words.map(\.text) == ["abcd", "xx", "efgh"])
        #expect(r.words[0].range.start == t(0))
        #expect(r.words[2].range.end == t(800))
        expectContiguousPositive(r)
        #expect(r.words[1].isEdited)
        #expect(r.words[1].range.duration == Time(800 * 2, 1000 * 10))
        #expect(r.words[0].range.end == Time(800 * 4, 1000 * 10))
    }

    @Test func zeroGapMultipleInsertedWords() {
        let b = transcript([w("aa", 100, 300), w("bb", 300, 500)])
        let r = b.applyingText("aa c dd eee bb")
        #expect(r.words.count == 5)
        #expect(r.words[0].range.start == t(100))
        #expect(r.words[4].range.end == t(500))
        expectContiguousPositive(r)
    }

    @Test func tinyGapIsTreatedLikeZeroGap() {
        let b = transcript([w("abcd", 0, 400), w("efgh", 401, 800)])
        let r = b.applyingText("abcd xx yy efgh")
        #expect(r.words[0].range.start == t(0))
        #expect(r.words[3].range.end == t(800))
        expectContiguousPositive(r)
        for x in r.words { #expect(x.range.duration >= Time(1, 100)) }
    }

    @Test func zeroGapInsertionLeavesOtherWordsUntouched() {
        let b = transcript([w("one", 0, 300), w("abcd", 300, 600), w("efgh", 600, 900), w("two", 900, 1200)])
        let r = b.applyingText("one abcd xx efgh two")
        #expect(r.words[0].range == b.words[0].range)
        #expect(r.words[4].range == b.words[3].range)
        #expect(r.words[0].id == b.words[0].id)
        #expect(r.words[1].id == b.words[1].id)
        #expect(r.words[3].id == b.words[2].id)
    }

    @Test func nonZeroRoomyGapDoesNotTouchNeighbours() {
        let r = base.applyingText("Hallo, ab liebe Welt.")
        #expect(r.words[0].range == base.words[0].range)
        #expect(r.words[2].range == base.words[1].range)
    }
}
