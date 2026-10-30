import Testing
import Foundation
import SQCore
@testable import SQText

/// FB-M word rule: a line breaks only at whitespace. A word is never split across lines (not mid-word, not at a hyphen);
/// a word wider than the box gets a line of its own. Captions shrink so their widest word fits the caption box.
@Suite struct WordWrapTests {
    let style = TextStyle(fontName: "Helvetica", size: 40, alignment: .left)

    func width(_ s: String) -> Double { TextLayout.layout(text: s, style: style, maxWidth: nil).lines[0].width }
    func lines(_ s: String, _ w: Double) -> [String] { TextLayout.layout(text: s, style: style, maxWidth: w).lines.map(\.text) }

    @Test func overlongWordStaysOnOneLine() {
        let word = "Geschwindigkeitsbegrenzung"
        #expect(lines(word, width(word) / 3) == [word])
    }

    @Test func overlongWordGetsItsOwnLineBetweenOthers() {
        let word = "Geschwindigkeitsbegrenzung"
        #expect(lines("die \(word) gilt", width(word) / 2) == ["die", word, "gilt"])
    }

    @Test func hyphenatedWordIsNotBrokenAtTheHyphen() {
        // Room for "ausprobieren-" but not for "ausprobieren-das": the compound stays whole on its own line.
        let w = width("ausprobieren-") + 2
        #expect(lines("ausprobieren-das Rennen", w) == ["ausprobieren-das", "Rennen"])
    }

    @Test func greedyFillStillWorks() {
        let w = width("one two") + 1
        #expect(lines("one two three", w) == ["one two", "three"])
        #expect(lines("one two three", width("one two three") + 1) == ["one two three"])
    }

    @Test func wordsAreNeverSplitOrLostAtAnyWidth() {
        let text = "Heute probieren wir Kaffeemaschinenreiniger und Donau-Dampfschifffahrt aus, ganz schnell"
        let words = text.split(separator: " ").map(String.init)
        for w in stride(from: 20.0, through: 900, by: 37) {
            let ls = lines(text, w)
            #expect(ls.flatMap { $0.split(separator: " ").map(String.init) } == words, "width \(w): \(ls)")
        }
    }

    @Test func explicitLineBreaksStay() {
        #expect(lines("eins zwei\ndrei", 2000) == ["eins zwei", "drei"])
    }

    @Test func captionShrinksSoTheWidestWordFits() throws {
        let big = TextStyle(fontName: "Helvetica", size: 200)
        let t = CaptionLayout.template(text: "ein Donaudampfschifffahrtsgesellschaftskapitän", style: big, canvasWidth: 1080, canvasHeight: 1920)
        let box = try #require(t.box)
        #expect(t.style.size < 200)
        let l = TextLayout.layout(text: t.text, style: t.style, maxWidth: box.width, boxHeight: box.height)
        #expect(l.lines.allSatisfy { $0.width <= box.width + 0.5 })
        #expect(l.lines.map(\.text) == ["ein", "Donaudampfschifffahrtsgesellschaftskapitän"])
    }

    @Test func captionThatFitsKeepsItsSize() {
        let s = TextStyle(fontName: "Helvetica", size: 56)
        let t = CaptionLayout.template(text: "Hallo Welt", style: s, canvasWidth: 1920, canvasHeight: 1080)
        #expect(t.style.size == 56)
    }
}
