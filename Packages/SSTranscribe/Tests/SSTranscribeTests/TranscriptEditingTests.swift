import Testing
import SSCore
@testable import SSTranscribe

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
}
