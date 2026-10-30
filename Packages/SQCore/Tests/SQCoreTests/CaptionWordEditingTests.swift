import Foundation
import Testing
@testable import SQCore

private func t(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }
private func r(_ a: Time, _ b: Time) -> TimeRange { TimeRange(start: a, end: b) }

/// "one two three" at 10 s ... 16 s, spoken at 10-11, 11-12 and (after a pause) 13-14.
private func timed() -> CaptionItem {
    CaptionItem(lines: ["one two three"], range: r(t(10), t(16)), styleRef: "style", animationRef: "anim",
                words: [CaptionWord(text: "one", range: r(t(0), t(1))), CaptionWord(text: "two", range: r(t(1), t(2))),
                        CaptionWord(text: "three", range: r(t(3), t(4)))])
}
private func timeline(_ items: [CaptionItem]) throws -> Timeline {
    var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    try tl.replaceCaptions(items)
    return tl
}
private func items(_ tl: Timeline) -> [CaptionItem] { tl.captionTracks[0].items }
private func ranges(_ c: CaptionItem) -> [TimeRange] { c.effectiveWords.map(\.range) }

@Suite struct CaptionWordEditingTests {
    // MARK: Edit, delete, insert

    @Test func editingAWordKeepsEveryTiming() throws {
        var tl = try timeline([timed()])
        let before = ranges(items(tl)[0])
        #expect(try tl.setCaptionWord(items(tl)[0].id, index: 1, text: "too") == 1)
        #expect(items(tl)[0].text == "one too three")
        #expect(items(tl)[0].hasWordTimings && ranges(items(tl)[0]) == before)
        #expect(items(tl)[0].range == r(t(10), t(16)))
    }

    @Test func aWordTypedWithASpaceBecomesTwoWordsSharingItsTime() throws {
        var tl = try timeline([timed()])
        #expect(try tl.setCaptionWord(items(tl)[0].id, index: 1, text: "to do") == 2)
        let c = items(tl)[0]
        #expect(c.text == "one to do three" && c.hasWordTimings)
        #expect(ranges(c) == [r(t(10), t(11)), r(t(11), t(23, 2)), r(t(23, 2), t(12)), r(t(13), t(14))])
    }

    @Test func emptyTextDeletesTheWordAndLeavesAPause() throws {
        var tl = try timeline([timed()])
        try tl.setCaptionWord(items(tl)[0].id, index: 1, text: "  ")
        #expect(items(tl)[0].text == "one three")
        #expect(ranges(items(tl)[0]) == [r(t(10), t(11)), r(t(13), t(14))])
        try tl.deleteCaptionWord(items(tl)[0].id, index: 0)
        try tl.deleteCaptionWord(items(tl)[0].id, index: 0)
        #expect(items(tl).isEmpty)   // the caption goes with its last word
    }

    @Test func identicalNeighborsDeleteTheRightTiming() throws {
        var c = timed(); c.lines = ["the the three"]
        var tl = try timeline([c])
        try tl.deleteCaptionWord(c.id, index: 0)
        #expect(ranges(items(tl)[0]) == [r(t(11), t(12)), r(t(13), t(14))])
    }

    @Test func anInsertedWordTakesThePauseOrHalfOfItsNeighbor() throws {
        var tl = try timeline([timed()])
        let id = items(tl)[0].id
        try tl.insertCaptionWord(id, at: 2, text: "and")          // pause 12-13
        #expect(items(tl)[0].text == "one two and three")
        #expect(ranges(items(tl)[0])[2] == r(t(12), t(13)))
        try tl.insertCaptionWord(id, at: 1, text: "x")            // no pause between one and two: half of "one"
        #expect(ranges(items(tl)[0])[0] == r(t(10), t(21, 2)) && ranges(items(tl)[0])[1] == r(t(21, 2), t(11)))
        try tl.insertCaptionWord(id, at: 0, text: "so")           // at the very start: first half of the first word
        #expect(ranges(items(tl)[0])[0] == r(t(10), t(41, 4)) && ranges(items(tl)[0])[1] == r(t(41, 4), t(21, 2)))
        try tl.insertCaptionWord(id, at: 6, text: "end")          // after the last word: up to the caption's end
        #expect(items(tl)[0].text == "so one x two and three end" && ranges(items(tl)[0])[6] == r(t(14), t(16)))
        #expect(items(tl)[0].hasWordTimings)
    }

    @Test func untimedCaptionsStayUntimedAndKeepTheirLines() throws {
        let c = CaptionItem(lines: ["one two", "three four"], range: r(t(0), t(4)))
        var tl = try timeline([c])
        try tl.setCaptionWord(c.id, index: 2, text: "3")
        try tl.insertCaptionWord(c.id, at: 2, text: "and")
        try tl.deleteCaptionWord(c.id, index: 0)
        #expect(items(tl)[0].lines == ["two and", "3 four"] && items(tl)[0].words.isEmpty)
    }

    @Test func wordEditsOnALockedTrackOrUnknownWordAreRefused() throws {
        var tl = try timeline([timed()])
        let id = items(tl)[0].id
        #expect(throws: EditError.self) { try tl.setCaptionWord(id, index: 3, text: "x") }
        #expect(throws: EditError.self) { try tl.insertCaptionWord(id, at: 4, text: "x") }
        tl.captionTracks[0].isLocked = true
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.setCaptionWord(id, index: 0, text: "x") }
        #expect(throws: EditError.trackLocked) { try tl.retimeCaptionWord(id, index: 0, edge: .tail, to: t(11)) }
        #expect(throws: EditError.trackLocked) { try tl.splitCaption(id, beforeWord: 1) }
        #expect(tl == before)
    }

    // MARK: Split and join

    @Test func splitBeforeAWordCutsWhereItStartsAndKeepsTimings() throws {
        var tl = try timeline([timed()])
        let before = ranges(items(tl)[0])
        let (a, b) = try tl.splitCaption(items(tl)[0].id, beforeWord: 2)
        let i = items(tl)
        #expect(i.map(\.id) == [a, b] && i.map(\.text) == ["one two", "three"])
        #expect(i[0].range == r(t(10), t(13)) && i[1].range == r(t(13), t(16)))   // the halves touch
        #expect(i[0].hasWordTimings && i[1].hasWordTimings)
        #expect(ranges(i[0]) + ranges(i[1]) == before)
        #expect(i[1].styleRef == "style")
        #expect(throws: EditError.self) { try tl.splitCaption(a, beforeWord: 0) }
        #expect(throws: EditError.self) { try tl.splitCaption(a, beforeWord: 2) }
    }

    @Test func splitOfAnUntimedCaptionCutsAtTheSpreadWord() throws {
        let c = CaptionItem(lines: ["aa bb", "cc dd"], range: r(t(0), t(8)))
        var tl = try timeline([c])
        try tl.splitCaption(c.id, beforeWord: 1)
        #expect(items(tl).map(\.lines) == [["aa"], ["bb", "cc dd"]])
        #expect(items(tl).map(\.range) == [r(t(0), t(2)), r(t(2), t(8))])
        #expect(items(tl).allSatisfy { $0.words.isEmpty })
    }

    @Test func joinWithNextAndPreviousKeepsTimings() throws {
        var tl = try timeline([timed()])
        let before = ranges(items(tl)[0])
        let (a, b) = try tl.splitCaption(items(tl)[0].id, beforeWord: 1)
        #expect(try tl.joinCaption(a, with: .next) == a)
        #expect(items(tl).count == 1 && items(tl)[0].text == "one two three" && ranges(items(tl)[0]) == before)
        #expect(items(tl)[0].range == r(t(10), t(16)))
        _ = b
        let (c, d) = try tl.splitCaption(a, beforeWord: 2)
        #expect(try tl.joinCaption(d, with: .previous) == c)
        #expect(ranges(items(tl)[0]) == before)
        #expect(throws: EditError.self) { try tl.joinCaption(c, with: .next) }       // no neighbor
        #expect(throws: EditError.self) { try tl.joinCaption(c, with: .previous) }
    }

    @Test func joinWithAnUntimedCaptionKeepsTheTimedWordsInPlace() throws {
        let typed = CaptionItem(lines: ["ab cd"], range: r(t(20), t(24)))
        var tl = try timeline([timed(), typed])
        let before = ranges(items(tl)[0]) + ranges(items(tl)[1])
        try tl.joinCaption(typed.id, with: .previous)
        #expect(items(tl).count == 1 && items(tl)[0].hasWordTimings)
        #expect(ranges(items(tl)[0]) == before)   // nothing moved, the typed words keep their spread
        #expect(items(tl)[0].range == r(t(10), t(24)))
    }

    // MARK: Retime

    @Test func aWordEdgeStopsAtItsNeighborAndNothingRipples() throws {
        var tl = try timeline([timed()])
        let id = items(tl)[0].id
        // "three" starts after a pause: its head stops where "two" ends, "two" does not move.
        #expect(try tl.retimeCaptionWord(id, index: 2, edge: .head, to: t(5)) == r(t(12), t(14)))
        #expect(ranges(items(tl)[0]) == [r(t(10), t(11)), r(t(11), t(12)), r(t(12), t(14))])
        // The last word's tail stops at the caption's end, the first word's head at its start.
        #expect(try tl.retimeCaptionWord(id, index: 2, edge: .tail, to: t(99)).end == t(16))
        #expect(try tl.retimeCaptionWord(id, index: 0, edge: .head, to: t(0)).start == t(10))
        // One frame minimum.
        #expect(try tl.retimeCaptionWord(id, index: 0, edge: .tail, to: t(0), rolling: false) == r(t(10), t(10) + Time(1, 30)))
        #expect(items(tl)[0].range == r(t(10), t(16)))   // the caption itself never moves
    }

    @Test func aSharedEdgeOfTouchingWordsMovesBoth() throws {
        var tl = try timeline([timed()])
        let id = items(tl)[0].id
        #expect(try tl.retimeCaptionWord(id, index: 1, edge: .head, to: t(21, 2)) == r(t(21, 2), t(12)))
        #expect(ranges(items(tl)[0])[0] == r(t(10), t(21, 2)))
        // The neighbor keeps one frame.
        try tl.retimeCaptionWord(id, index: 0, edge: .tail, to: t(15))
        #expect(ranges(items(tl)[0])[0].end == t(12) - Time(1, 30) && ranges(items(tl)[0])[1] == r(t(12) - Time(1, 30), t(12)))
        // Without rolling only the grabbed edge moves and a pause opens.
        try tl.retimeCaptionWord(id, index: 0, edge: .tail, to: t(11), rolling: false)
        #expect(ranges(items(tl)[0])[0].end == t(11) && ranges(items(tl)[0])[1].start == t(12) - Time(1, 30))
    }

    @Test func retimingAnUntimedCaptionGivesItTimings() throws {
        let c = CaptionItem(lines: ["aa bb"], range: r(t(0), t(4)))
        var tl = try timeline([c])
        try tl.retimeCaptionWord(c.id, index: 1, edge: .head, to: t(3))
        #expect(items(tl)[0].hasWordTimings && ranges(items(tl)[0]) == [r(t(0), t(3)), r(t(3), t(4))])
    }

    // MARK: Search and replace

    @Test func matchesComeInTimeOrderWithTheirWords() throws {
        let a = CaptionItem(lines: ["The cat", "sat on the mat"], range: r(t(4), t(6)))
        let b = CaptionItem(lines: ["at the end"], range: r(t(0), t(2)))
        let tl = try timeline([a, b])
        let all = tl.captionTextMatches(find: "the", caseSensitive: false)
        #expect(all.map(\.caption) == [b.id, a.id, a.id])
        #expect(all.map(\.words) == [1...1, 0...0, 4...4])
        #expect(all.map(\.line) == [0, 0, 1] && all[2].range == 7..<10)
        #expect(tl.captionTextMatches(find: "the", caseSensitive: true).count == 2)
        #expect(tl.captionTextMatches(find: "at", caseSensitive: false).count == 4)   // inside words too
        #expect(tl.captionTextMatches(find: "cat sat", caseSensitive: false).isEmpty)  // not across lines
        #expect(tl.captionTextMatches(find: "on the", caseSensitive: false).first?.words == 3...4)
        #expect(tl.captionTextMatches(find: "", caseSensitive: false).isEmpty)
    }

    @Test func replacingOneMatchKeepsEveryOtherTiming() throws {
        var tl = try timeline([timed()])
        let before = ranges(items(tl)[0])
        let m = try #require(tl.captionTextMatches(find: "TWO", caseSensitive: false).first)
        try tl.replaceCaptionMatch(m, with: "2")
        #expect(items(tl)[0].text == "one 2 three" && ranges(items(tl)[0]) == before)
        // A replacement with more words shares the old word's time.
        let n = try #require(tl.captionTextMatches(find: "2", caseSensitive: true).first)
        try tl.replaceCaptionMatch(n, with: "to do")
        #expect(ranges(items(tl)[0]) == [r(t(10), t(11)), r(t(11), t(23, 2)), r(t(23, 2), t(12)), r(t(13), t(14))])
    }

    @Test func replaceAllCountsAndKeepsTimings() throws {
        var c = timed(); c.lines = ["one one three"]
        let other = CaptionItem(lines: ["One more"], range: r(t(20), t(22)))
        var tl = try timeline([c, other])
        let before = ranges(items(tl)[0])
        #expect(tl.captionTextMatches(find: "one", caseSensitive: false).count == 3)
        #expect(try tl.replaceCaptionText(find: "one", with: "1", caseSensitive: false) == 3)
        #expect(items(tl).map(\.text) == ["1 1 three", "1 more"])
        #expect(items(tl)[0].hasWordTimings && ranges(items(tl)[0]) == before)
        #expect(try tl.replaceCaptionText(find: "1", with: "", caseSensitive: true, track: tl.captionTracks[0].id) == 3)
        #expect(items(tl).map(\.text) == ["  three", " more"])                // captions stay, even emptied of a word
        #expect(ranges(items(tl)[0]) == [r(t(13), t(14))])
    }

    // MARK: Review fixes

    @Test func replaceThatEmptiesACaptionRemovesItAndDropsEmptyLines() throws {
        let um = CaptionItem(lines: ["um"], range: r(t(1), t(2)))
        let two = CaptionItem(lines: ["um", "yes"], range: r(t(5), t(6)),
                              words: [CaptionWord(text: "um", range: r(t(0), t(1, 2))), CaptionWord(text: "yes", range: r(t(1, 2), t(1)))])
        var tl = try timeline([um, two])
        #expect(try tl.replaceCaptionText(find: "um", with: "", caseSensitive: false) == 2)
        #expect(items(tl).count == 1)
        #expect(items(tl)[0].lines == ["yes"] && items(tl)[0].range == r(t(5), t(6)))
        #expect(items(tl)[0].hasWordTimings && ranges(items(tl)[0]) == [r(t(11, 2), t(6))])

        // The same rule one match at a time.
        var one = try timeline([um, two])
        let first = try #require(one.captionTextMatches(find: "um", caseSensitive: false).first)
        try one.replaceCaptionMatch(first, with: "")
        #expect(items(one).map(\.lines) == [["um", "yes"]])
        let second = try #require(one.captionTextMatches(find: "um", caseSensitive: false).first)
        try one.replaceCaptionMatch(second, with: "")
        #expect(items(one).map(\.lines) == [["yes"]])
        #expect(ranges(items(one)[0]) == [r(t(11, 2), t(6))])
    }

    @Test func repeatedWordsKeepTheirTimingByPosition() throws {
        var c = timed(); c.lines = ["the the cat"]
        c.words = [CaptionWord(text: "the", range: r(t(0), t(1))), CaptionWord(text: "the", range: r(t(1), t(2))),
                   CaptionWord(text: "cat", range: r(t(3), t(4)))]
        var a = try timeline([c])
        let found = a.captionTextMatches(find: "the ", caseSensitive: true)
        #expect(found.count == 2)
        try a.replaceCaptionMatch(found[0], with: "")                       // the first "the" goes: the second keeps its own time
        #expect(items(a)[0].text == "the cat" && items(a)[0].hasWordTimings)
        #expect(ranges(items(a)[0]) == [r(t(11), t(12)), r(t(13), t(14))])
        var b = try timeline([c])
        try b.replaceCaptionMatch(b.captionTextMatches(find: "the ", caseSensitive: true)[1], with: "")
        #expect(items(b)[0].text == "the cat")
        #expect(ranges(items(b)[0]) == [r(t(10), t(11)), r(t(13), t(14))])
    }

    @Test func splitNeverCutsInsideAWord() throws {
        // A pause that holds a frame: the cut is on that frame.
        var gap = timed(); gap.lines = ["one two"]
        gap.words = [CaptionWord(text: "one", range: r(t(0), t(99, 100))), CaptionWord(text: "two", range: r(t(51, 50), t(2)))]
        var tl = try timeline([gap])
        var before = ranges(items(tl)[0])
        try tl.splitCaption(items(tl)[0].id, beforeWord: 1)
        #expect(items(tl)[0].range.end == t(11) && items(tl)[1].range.start == t(11))
        #expect(items(tl).flatMap { ranges($0) } == before)

        // Words that touch off the frame grid: the cut is the word boundary, no word loses time.
        var touch = timed(); touch.lines = ["one two"]
        touch.words = [CaptionWord(text: "one", range: r(t(0), t(101, 100))), CaptionWord(text: "two", range: r(t(101, 100), t(2)))]
        tl = try timeline([touch])
        before = ranges(items(tl)[0])
        try tl.splitCaption(items(tl)[0].id, beforeWord: 1)
        #expect(items(tl)[0].range.end == t(1101, 100) && items(tl)[1].range.start == t(1101, 100))
        #expect(items(tl).flatMap { ranges($0) } == before)
        #expect(items(tl).flatMap { ranges($0) }.allSatisfy { $0.duration > .zero })
    }

    @Test func refitNeverLeavesAWordWithoutTime() throws {
        // A word without time typed into two: it and its neighbors share the neighbors' span evenly.
        var c = timed()
        c.words = [CaptionWord(text: "one", range: r(t(0), t(1))), CaptionWord(text: "two", range: r(t(1), t(1))),
                   CaptionWord(text: "three", range: r(t(1), t(2)))]
        var tl = try timeline([c])
        #expect(try tl.setCaptionWord(items(tl)[0].id, index: 1, text: "to do") == 2)
        #expect(items(tl)[0].hasWordTimings)
        #expect(ranges(items(tl)[0]) == [r(t(10), t(21, 2)), r(t(21, 2), t(11)), r(t(11), t(23, 2)), r(t(23, 2), t(12))])

        // No time anywhere: the whole caption is shared.
        var flat = timed()
        flat.words = flat.words.map { CaptionWord(text: $0.text, range: r(t(0), t(0))) }
        tl = try timeline([flat])
        #expect(try tl.setCaptionWord(items(tl)[0].id, index: 1, text: "to do") == 2)
        #expect(ranges(items(tl)[0]) == [r(t(10), t(23, 2)), r(t(23, 2), t(13)), r(t(13), t(29, 2)), r(t(29, 2), t(16))])
        #expect(ranges(items(tl)[0]).allSatisfy { $0.duration >= CaptionItem.wordTick })

        // A span too short for its words by length still gives every word a tick.
        let tiny = CaptionItem.spread(["a", "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"], over: r(t(0), t(1, 50)))
        #expect(tiny.allSatisfy { $0.range.duration >= CaptionItem.wordTick } && tiny.last?.range.end == t(1, 50))
    }
}
