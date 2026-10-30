import Foundation
import Testing
import SQText
@testable import SQInspectorUI

/// N4: the "Second line style" controls of the Text inspector. Every change is one undo step (begin, change, end).
@MainActor @Suite struct TextInspectorSecondLineTests {
    final class Log { var events: [String] = []; var styles: [TextStyle] = [] }

    func make(_ style: TextStyle = TextStyle(fontName: "Helvetica", size: 40)) -> (TextInspectorModel, Log) {
        let m = TextInspectorModel(style: style, animations: AnimationSet(in: nil, out: nil),
                                   library: .builtIn, fontFamilies: { ["Helvetica", "Menlo"] })
        let log = Log()
        m.onBeginEditing = { log.events.append("begin") }
        m.onEndEditing = { log.events.append("end") }
        m.onChange = { s, _ in log.events.append("change"); log.styles.append(s) }
        return (m, log)
    }

    @Test func enablingStartsBigAndBoldFromTheClipStyle() throws {
        let (m, log) = make()
        #expect(!m.secondLineEnabled)
        m.setSecondLineEnabled(true)
        let l = try #require(m.style.secondLine)
        #expect(m.secondLineEnabled)
        #expect(l.fontName == "Helvetica" && l.color == m.style.color)
        #expect(l.size == 80)                                  // twice the top line: the product-title look
        #expect(l.weight == .bold)
        #expect(log.events == ["begin", "change", "end"])
    }

    @Test func disablingRemembersTheLastLookForTheNextEnable() throws {
        let (m, _) = make()
        m.setSecondLineEnabled(true)
        m.setSecondLineSize(150)
        m.setSecondLineEnabled(false)
        #expect(m.style.secondLine == nil)
        m.setSecondLineEnabled(true)
        #expect(m.style.secondLine?.size == 150)
    }

    @Test func eachSecondLineValueIsOneEdit() {
        let (m, log) = make()
        m.setSecondLineEnabled(true)
        log.events.removeAll()
        m.setSecondLineFont("Menlo")
        m.setSecondLineWeight(.black)
        m.setSecondLineSize(0)                                 // clamped to 1
        m.setSecondLineColor(RGBAColor(red: 1, green: 0, blue: 0))
        m.setSecondLineItalic(true)
        #expect(log.events == Array(repeating: ["begin", "change", "end"], count: 5).flatMap { $0 })
        let l = m.style.secondLine
        #expect(l?.fontName == "Menlo" && l?.weight == .black && l?.size == 1 && l?.italic == true)
        #expect(l?.color == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(m.style.fontName == "Helvetica" && m.style.size == 40)   // the top line is untouched
    }

    @Test func secondLineSettersDoNothingWhileOff() {
        let (m, log) = make()
        m.setSecondLineSize(90)
        m.setSecondLineColor(.black)
        #expect(m.style.secondLine == nil)
        #expect(log.events.isEmpty)
    }

    @Test func loadingAStyleWithASecondLineShowsIt() {
        let (m, log) = make()
        var s = TextStyle(size: 30)
        s.secondLine = TextLineStyle(fontName: "Menlo", size: 99, weight: .heavy, color: .white)
        m.load(style: s, animations: AnimationSet(in: nil, out: nil))
        #expect(m.secondLineEnabled && m.style.secondLine?.size == 99)
        #expect(log.events.isEmpty)
    }
}
