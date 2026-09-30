import Foundation
import Testing
import SSText
@testable import SSEditorUI

@MainActor @Suite struct TextInspectorModelTests {
    final class Log { var events: [String] = []; var styles: [TextStyle] = []; var sets: [AnimationSet] = [] }

    func make(_ style: TextStyle = TextStyle()) -> (TextInspectorModel, Log) {
        let m = TextInspectorModel(style: style, animations: AnimationSet(in: nil, out: nil),
                                   library: .builtIn, fontFamilies: { ["Helvetica", "Menlo"] })
        let log = Log()
        m.onBeginEditing = { log.events.append("begin") }
        m.onEndEditing = { log.events.append("end") }
        m.onChange = { s, a in log.events.append("change"); log.styles.append(s); log.sets.append(a) }
        return (m, log)
    }

    @Test func singleEditWrapsInBeginEnd() {
        let (m, log) = make()
        m.setSize(72)
        #expect(m.style.size == 72)
        #expect(log.events == ["begin", "change", "end"])
    }

    @Test func dragSessionCoalesces() {
        let (m, log) = make()
        m.beginEditing()
        m.setSize(60); m.setSize(61); m.setSize(62)
        m.endEditing()
        #expect(log.events == ["begin", "change", "change", "change", "end"])
        #expect(m.style.size == 62)
    }

    @Test func noChangeNoCallback() {
        let (m, log) = make()
        m.setSize(m.style.size)
        #expect(log.events.isEmpty)
    }

    @Test func basicSetters() {
        let (m, _) = make()
        m.setFontFamily("Menlo"); m.setWeight(.bold); m.setColor(RGBAColor(red: 1, green: 0, blue: 0))
        m.setAlignment(.left); m.setLineSpacing(6)
        #expect(m.style.fontName == "Menlo" && m.style.weight == .bold && m.style.alignment == .left)
        #expect(m.style.color.red == 1 && m.style.lineSpacing == 6)
    }

    @Test func sizeClamped() {
        let (m, _) = make()
        m.setSize(-5)
        #expect(m.style.size == 1)
    }

    @Test func strokeToggleRemembersValues() {
        let (m, _) = make()
        #expect(m.style.stroke == nil && !m.strokeEnabled)
        m.setStrokeEnabled(true)
        #expect(m.style.stroke != nil)
        m.setStrokeWidth(9); m.setStrokeColor(RGBAColor(red: 0, green: 1, blue: 0))
        m.setStrokeEnabled(false)
        #expect(m.style.stroke == nil)
        m.setStrokeEnabled(true)
        #expect(m.style.stroke?.width == 9 && m.style.stroke?.color.green == 1)
    }

    @Test func strokeSettersIgnoredWhenOff() {
        let (m, log) = make()
        m.setStrokeWidth(4)
        #expect(m.style.stroke == nil && log.events.isEmpty)
    }

    @Test func backgroundAndShadow() {
        let (m, _) = make()
        m.setBackgroundEnabled(true)
        m.setBackgroundPadding(horizontal: 10, vertical: 5); m.setBackgroundRadius(8)
        #expect(m.style.background?.padding == BoxPadding(horizontal: 10, vertical: 5))
        #expect(m.style.background?.cornerRadius == 8)
        m.setShadowEnabled(true)
        m.setShadowOffset(x: 1, y: 3); m.setShadowBlur(7)
        #expect(m.style.shadow?.offsetX == 1 && m.style.shadow?.offsetY == 3 && m.style.shadow?.blur == 7)
        m.setShadowEnabled(false)
        #expect(m.style.shadow == nil)
    }

    @Test func presetsApplyAndSelect() {
        let (m, log) = make()
        m.applyPreset("outline")
        #expect(m.style == CaptionPresetLibrary.builtIn.style(for: "outline"))
        #expect(m.selectedPresetID == "outline")
        #expect(log.events == ["begin", "change", "end"])
        m.setSize(99)
        #expect(m.selectedPresetID == nil)
        let before = log.events.count
        m.applyPreset("does-not-exist")
        #expect(log.events.count == before)
    }

    @Test func savePreset() {
        let (m, _) = make()
        var saved: [CaptionPresetLibrary] = []
        m.onPresetsChanged = { saved.append($0) }
        m.setSize(33)
        let id = m.saveCurrentAsPreset(named: "My Look")
        #expect(id == "my-look")
        #expect(m.library.style(for: "my-look").size == 33)
        #expect(m.selectedPresetID == "my-look")
        #expect(saved.count == 1)
        m.setSize(34)
        let id2 = m.saveCurrentAsPreset(named: "My Look")
        #expect(id2 != nil && id2 != id && m.library.hasStyle(id2!))
        #expect(m.saveCurrentAsPreset(named: "   ") == nil)
    }

    @Test func animationPickers() {
        let (m, log) = make()
        #expect(m.inAnimationIDs.contains("pop-in") && m.inAnimationIDs.contains("none"))
        #expect(m.outAnimationIDs.contains("fade-out") && !m.outAnimationIDs.contains("pop-in"))
        #expect(m.selectedInID == "none" && m.selectedOutID == "none")
        m.setInAnimation("pop-in")
        #expect(m.animations.animationIn == CaptionPresetLibrary.builtIn.animation(for: "pop-in"))
        #expect(m.selectedInID == "pop-in")
        m.setOutAnimation("fade-out")
        #expect(m.selectedOutID == "fade-out")
        m.setOutAnimation("none")
        #expect(m.animations.animationOut == nil)
        #expect(log.sets.last?.animationIn != nil)
        #expect(log.events.filter { $0 == "begin" }.count == 3)
    }

    @Test func fontFamiliesIncludesCurrentIfMissing() {
        let (m, _) = make(TextStyle(fontName: "Helvetica-Bold"))
        #expect(m.fontFamilies == ["Helvetica-Bold", "Helvetica", "Menlo"])
    }

    @Test func externalUpdateDoesNotFireCallbacks() {
        let (m, log) = make()
        m.load(style: TextStyle(size: 20), animations: AnimationSet(in: nil, out: nil))
        #expect(m.style.size == 20 && log.events.isEmpty)
    }
}
