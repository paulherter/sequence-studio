import Foundation
import Testing
import SQText
@testable import SQInspectorUI

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

    // Review finding 6: a session left open (color well timer never ran) merged later edits, even those of another clip.
    @Test func loadingAnotherClipClosesAnOpenSession() {
        let (m, log) = make()
        m.beginEditing()
        m.setSize(60)
        m.load(style: TextStyle(), animations: AnimationSet(in: nil, out: nil))      // another clip selected
        #expect(log.events == ["begin", "change", "end"])
        log.events.removeAll()
        m.setSize(80)                                                                // an edit of the new clip is its own step
        #expect(log.events == ["begin", "change", "end"])
        m.endEditing()                                                               // the stale timer firing later is harmless
        #expect(log.events == ["begin", "change", "end"])
    }

    @Test func singleEditWrapsInBeginEnd() {
        let (m, log) = make()
        m.setSize(72)
        #expect(m.style.size == 72)
        #expect(log.events == ["begin", "change", "end"])
    }

    @Test func directionEditIsOneStepAndAutoClears() {
        let (m, log) = make()
        m.setDirection(.rightToLeft)
        #expect(m.style.direction == .rightToLeft)
        #expect(log.events == ["begin", "change", "end"])
        m.setDirection(nil)
        #expect(m.style.direction == nil)
        m.setDirection(nil)                               // no change, no step
        #expect(log.events.count == 6)
    }

    @Test func fontAxisEditsKeepOverridesOnly() throws {
        var s = TextStyle(); s.fontName = "Inter"
        let (m, _) = make(s)
        let wght = try #require(m.fontAxes.first { $0.tag == "wght" })
        #expect(m.axisValue(wght) == wght.defaultValue)
        m.setFontAxis(wght, wght.maximum + 1000)          // clamped
        #expect(m.style.fontAxes == ["wght": wght.maximum])
        #expect(m.axisValue(wght) == wght.maximum)
        m.setFontAxis(wght, wght.defaultValue)            // back to the default: no override left
        #expect(m.style.fontAxes == nil)
        m.setFontAxis(wght, wght.maximum)
        m.resetFontAxes()
        #expect(m.style.fontAxes == nil)
    }

    @Test func staticFontHasNoAxes() {
        var s = TextStyle(); s.fontName = "Georgia"
        let (m, _) = make(s)
        #expect(m.fontAxes.isEmpty)
    }

    @Test func dragSessionCoalesces() {
        let (m, log) = make()
        m.beginEditing()
        m.setSize(60); m.setSize(61); m.setSize(62)
        m.endEditing()
        #expect(log.events == ["begin", "change", "change", "change", "end"])
        #expect(m.style.size == 62)
    }

    @Test func allCapsAndStrokePositionAreOneEditEach() {
        let (m, log) = make()
        m.setAllCaps(true)
        #expect(m.style.allCaps && log.events == ["begin", "change", "end"])
        m.setStrokeEnabled(true)
        m.setStrokePosition(.centre)
        #expect(m.style.stroke?.position == .centre)
        m.setStrokePosition(.centre)                      // no change, no event
        #expect(log.events.filter { $0 == "change" }.count == 3)
    }

    @Test func footageFillIsOneEditAndGoesBackToColor() {
        let (m, log) = make()
        m.setFootageFill(.stencil)
        #expect(m.style.footageFill == .stencil && log.events == ["begin", "change", "end"])
        m.setFootageFill(.stencil)                        // no change, no event
        m.setFootageFill(.inverted)
        #expect(m.style.footageFill == .inverted)
        m.setFootageFill(nil)
        #expect(m.style.footageFill == nil && log.events.filter { $0 == "change" }.count == 3)
    }

    @Test func lineStylesAreOneEditEach() {
        let (m, log) = make()
        m.setUnderline(true)
        #expect(m.style.underline && log.events == ["begin", "change", "end"])
        m.setStrikethrough(true); m.setOverline(true)
        #expect(m.style.strikethrough && m.style.overline)
        m.setUnderline(false)
        #expect(!m.style.underline && m.style.strikethrough)
    }

    @Test func alignButtonsGoToTheHost() {
        let (m, _) = make()
        var got: [FrameAlignment] = []
        m.onAlignToFrame = { got.append($0) }
        for a in FrameAlignment.allCases { m.alignToFrame(a) }
        #expect(got == [.left, .centerHorizontally, .right, .top, .centerVertically, .bottom])
    }

    @Test func premiereTextControlsEditTheStyle() {
        let (m, _) = make()
        m.setTracking(12); m.setItalic(true); m.setVerticalAlignment(.bottom)
        #expect(m.style.tracking == 12 && m.style.italic && m.style.verticalAlignment == .bottom)
        m.setShadowEnabled(true)
        m.setShadowAngle(45, distance: 10)
        #expect(abs(m.style.shadow!.angle - 45) < 1e-6 && abs(m.style.shadow!.distance - 10) < 1e-9)
        m.setShadowOpacity(0.25)
        #expect(m.style.shadow!.color.alpha == 0.25 && abs(m.style.shadow!.distance - 10) < 1e-9)
        m.setBackgroundEnabled(true)
        m.setBackgroundOpacity(0.5)
        #expect(m.style.background!.color.alpha == 0.5)
    }

    @Test func shadowSizeIsTheSpreadAndSurvivesAngleEdits() {
        let (m, _) = make()
        m.setShadowEnabled(true)
        m.setShadowSpread(6)
        #expect(m.style.shadow?.spread == 6)
        m.setShadowAngle(90, distance: 4)
        #expect(m.style.shadow?.spread == 6 && abs((m.style.shadow?.distance ?? 0) - 4) < 1e-9)
        m.setShadowSpread(-3)
        #expect(m.style.shadow?.spread == 0)
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

    @Test func zoneLengthsAreBoundedByTheClipAndKeepThePreset() {
        let (m, _) = make()
        m.setInAnimation("pop-in"); m.setOutAnimation("fade-out")
        m.clipDuration = Time(2, 1)
        let out = m.zoneMilliseconds(.outro) ?? 0
        #expect(out > 0 && m.zoneMilliseconds(.intro) != nil)
        m.setZoneLength(milliseconds: 5_000, side: .intro)             // more than the clip minus the outro: held back
        #expect(m.zoneMilliseconds(.intro) == 2_000 - out)
        #expect(m.zoneMilliseconds(.outro) == out)
        m.setZoneLength(milliseconds: 10, side: .outro)                // under the minimum
        #expect(m.zoneMilliseconds(.outro) == TextInspectorModel.minimumZoneMilliseconds)
        #expect(m.selectedInID == "pop-in" && m.selectedOutID == "fade-out")   // still the same preset, only another length
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

@MainActor @Suite struct TextInspectorLookTests {
    private func make() -> TextInspectorModel {
        TextInspectorModel(style: TextStyle(), animations: AnimationSet(in: nil, out: nil), library: .builtIn,
                           fontFamilies: { ["Helvetica"] })
    }

    @Test func applyingALookIsOneUndoStepAndSetsStyleAndAnimation() {
        let m = make()
        var events: [String] = []
        m.onBeginEditing = { events.append("begin") }
        m.onEndEditing = { events.append("end") }
        m.onChange = { _, _ in events.append("change") }
        let pop = CaptionStyleLooks.look(id: "pop")!
        m.applyLook(pop)
        #expect(events == ["begin", "change", "end"])
        #expect(m.style == CaptionPresetLibrary.builtIn.style(for: "title"))
        #expect(m.animations.animationIn == CaptionPresetLibrary.builtIn.animation(for: "pop"))
        #expect(m.currentLookID == "pop")
        m.applyLook(pop)                                   // same again: no new step
        #expect(events.count == 3)
    }

    @Test func anExitLookKeepsTheEntranceAndEditingLeavesTheLook() {
        let m = make()
        m.applyLook(CaptionStyleLooks.look(id: "pop")!)
        m.applyLook(CaptionStyleLooks.look(id: "shrink-out")!)
        #expect(m.animations.animationIn != nil && m.animations.animationOut?.anchor == .end)
        m.setSize(12)                                      // editable afterwards
        #expect(m.style.size == 12 && m.currentLookID == nil)
    }
}
