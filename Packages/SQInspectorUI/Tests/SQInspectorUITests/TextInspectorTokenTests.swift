import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

@MainActor @Suite struct TextInspectorTokenTests {
    func make(kit: StyleKit? = .starter, style: TextStyle = TextStyle(fontName: "Menlo", color: .black)) -> TextInspectorModel {
        let m = TextInspectorModel(style: style, library: .builtIn, fontFamilies: { ["Helvetica", "Menlo"] })
        m.kit = kit
        return m
    }

    @Test func tokenNamesComeFromTheKit() {
        let m = make()
        #expect(m.tokenNames(for: .font) == [StyleKit.brandFontToken])
        #expect(m.tokenNames(for: .color) == [StyleKit.pillColorToken, StyleKit.textColorToken])
        #expect(make(kit: nil).tokenNames(for: .font).isEmpty)
    }

    @Test func bindingTakesTheTokenValueAndRecordsTheBinding() {
        let m = make()
        m.bindToken(.font, to: StyleKit.brandFontToken)
        m.bindToken(.color, to: StyleKit.textColorToken)
        #expect(m.style.fontName == TextStyle.defaultFontName && m.style.color == .white)
        #expect(m.boundToken(.font) == StyleKit.brandFontToken && m.boundToken(.color) == StyleKit.textColorToken)
    }

    @Test func manualChoiceReleasesAndNilReleases() {
        let m = make()
        m.bindToken(.color, to: StyleKit.textColorToken)
        m.bindToken(.color, to: nil)
        #expect(m.boundToken(.color) == nil && m.style.color == .white)          // value stays as a literal
        m.bindToken(.font, to: StyleKit.brandFontToken)
        m.setFontFamily("Menlo")
        #expect(m.boundToken(.font) == nil && m.style.tokens == nil)
    }

    @Test func unknownTokenAndMissingStrokeAreIgnored() {
        let m = make()
        m.bindToken(.font, to: "nope")
        m.bindToken(.strokeColor, to: StyleKit.textColorToken)                   // no stroke
        #expect(m.style.tokens == nil)
        m.setStrokeEnabled(true)
        m.bindToken(.strokeColor, to: StyleKit.textColorToken)
        #expect(m.style.stroke?.color == .white && m.boundToken(.strokeColor) == StyleKit.textColorToken)
    }

    @Test func bindingIsOneUndoStep() {
        let m = make()
        var events: [String] = []
        m.onBeginEditing = { events.append("begin") }
        m.onEndEditing = { events.append("end") }
        m.bindToken(.font, to: StyleKit.brandFontToken)
        #expect(events == ["begin", "end"])
    }
}
