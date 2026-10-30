import Foundation
import Testing
@testable import SQCore

/// One definition of a "word" for captions, karaoke, text animators and burn-in: whitespace separates, and every CJK
/// character is its own word (closing marks stay with the character before, opening marks join the one after).
@Suite struct WordSegmentationTests {
    @Test func latinIsUnchanged() {
        #expect(WordSegmentation.words("  Hallo,   (Welt)  E-Mail! ") == ["Hallo,", "(Welt)", "E-Mail!"])
        #expect(WordSegmentation.words("a - b") == ["a", "-", "b"])
        #expect(WordSegmentation.words("") == [])
    }

    @Test func cjkSplitsPerCharacter() {
        #expect(WordSegmentation.words("你好世界") == ["你", "好", "世", "界"])
        #expect(WordSegmentation.words("こんにちは") == ["こ", "ん", "に", "ち", "は"])
    }

    @Test func mixedLatinAndCJK() {
        #expect(WordSegmentation.words("Hello世界 ok") == ["Hello", "世", "界", "ok"])
        #expect(WordSegmentation.words("用iPhone拍") == ["用", "iPhone", "拍"])
    }

    @Test func punctuationAttaches() {
        #expect(WordSegmentation.words("你好。世界") == ["你", "好。", "世", "界"])
        #expect(WordSegmentation.words("他说「好」吗") == ["他", "说", "「好」", "吗"])
        #expect(WordSegmentation.words("(漢字)") == ["(漢", "字)"])
        #expect(WordSegmentation.words("。") == ["。"])
    }

    @Test func spansAreCharacterRanges() {
        #expect(WordSegmentation.spans(of: "ab 你好") == [0..<2, 3..<4, 4..<5])
    }

    @Test func joinKeepsCJKTight() {
        #expect(WordSegmentation.join(["你", "好", "world", "ok", "世"]) == "你好world ok世")
        #expect(WordSegmentation.join(["a", "b"]) == "a b")
    }

    @Test func captionTokensAndTimingsStayAligned() {
        var c = CaptionItem(lines: ["你好 world"], range: TimeRange(start: Time(0, 1), end: Time(3, 1)))
        #expect(c.tokens == ["你", "好", "world"])
        c.words = [CaptionWord(text: "你", range: TimeRange(start: Time(0, 1), end: Time(1, 1))),
                   CaptionWord(text: "好", range: TimeRange(start: Time(1, 1), end: Time(2, 1))),
                   CaptionWord(text: "world", range: TimeRange(start: Time(2, 1), end: Time(3, 1)))]
        #expect(c.hasWordTimings)
        c.replaceTokens(2..<3, with: ["earth"])
        #expect(c.lines == ["你好 earth"])
        c.replaceTokens(0..<1, with: ["您"])
        #expect(c.lines == ["您好 earth"])
    }

    @Test func textUnitsFollowTheSameWords() {
        let u = TextUnits.segment(text: "你好 ab", lines: [NSRange(location: 0, length: 5)])
        #expect(u.wordCount == 3)
        #expect(u.characters.map(\.word) == [0, 1, 2, 2])
    }
}
