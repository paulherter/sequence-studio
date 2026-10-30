import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

@MainActor
@Suite struct ShellFormTests {
    func dialog(_ rows: [ShellForm.Row]) -> (ShellDialog, ShellForm) {
        let d = ShellDialog("New Project")
        d.addButton("Cancel", role: .cancel)
        d.addButton("Create", role: .default)
        let f = ShellForm(rows)
        d.form = f
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        return (d, f)
    }

    func click(_ d: ShellDialog, _ p: CGPoint) {
        d.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
    }

    func type(_ d: ShellDialog, _ s: String) { for ch in s { d.handle(.keyDown(.character(ch), modifiers: []), scale: 1) } }

    /// The label column fits its longest label (no "Interface Langu..."), within 104...160 pt.
    @Test func theLabelColumnGrowsToItsLongestLabel() {
        let (_, short) = dialog([.field(id: "name", label: "Name", value: "")])
        #expect(short.labelWidth == 104)
        let (_, long) = dialog([.popup(id: "l", label: "Interface Language", options: ["English"], selected: 0)])
        #expect(long.labelWidth == 119)                         // 18 characters at the atlas-free 0.55 em
        let (_, huge) = dialog([.field(id: "x", label: String(repeating: "W", count: 40), value: "")])
        #expect(huge.labelWidth == 160)
    }

    /// The Mac `SQDialog.popupRow` (Save as Preset): an unlabeled popup row is the 22 pt popup, 12 below the 28 pt name field.
    @Test func anUnlabeledPopupRowIsThe22ptPopup() {
        let (_, f) = dialog([.field(id: "name", label: "", value: "My Look"), .popup(id: "a", label: "", options: ["Anchor to In Point"], selected: 0)])
        #expect(f.rowFrames[0].height == 28 && f.controlFrames[1].height == 22)
        #expect(f.controlFrames[1].minY - f.controlFrames[0].maxY == 12)
    }

    /// The Mac note wraps at the 400 pt column by kerned advances; the atlas has none, so the wrap has a few points of slack.
    @Test func aNoteThatFitsTheMacColumnStaysOneLine() {
        let d = ShellDialog("Save as Preset", informative: "Saves Transform, Opacity and effects with their keyframes and easing.")
        d.addButton("Save")
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        // The atlas-free measure is 0.55 em per character: 69 characters at 12 pt = 455 pt, so two lines here.
        #expect(d.noteLines.count == 2)
        let long = ShellDialog("T", informative: String(repeating: "word ", count: 20))
        long.addButton("OK")
        long.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        #expect(long.noteLines.allSatisfy { Double($0.count) * 12 * 0.55 <= 405 + 6 })
    }

    @Test func rowsStackWithTheMacFormMetricsBetweenHeaderAndFooter() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "Untitled"),
                             .popup(id: "t", label: "Template", options: ["Empty", "Vlog"], selected: 0),
                             .check(id: "c", title: "Open after", on: true)])
        #expect(f.rowFrames.count == 3)
        #expect(f.rowFrames[1].minY - f.rowFrames[0].maxY == 12)
        #expect(f.rowFrames[0].height == 28 && f.rowFrames[2].height == 24)
        #expect(f.controlFrames[0].minX == d.card.minX + 20 + 104 + 16 - 2) // labeled fields bleed 2 pt like the Mac NSTextField frame
        #expect(f.controlFrames[0].maxX == d.card.maxX - 20 + 2)
        let footerTop = d.buttonFrames.values.map(\.minY).min() ?? 0
        #expect(f.rowFrames[2].maxY < footerTop)
        #expect(f.rowFrames[0].minY > d.card.minY)
    }

    @Test func typingInAFieldAndReturnAnswersWithTheNewValue() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "")])
        var answer: ShellDialog.Response?
        d.completion = { answer = $0 }
        click(d, CGPoint(x: f.controlFrames[0].midX, y: f.controlFrames[0].midY))
        #expect(f.isEditing)
        type(d, "Trip")
        d.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(f.text("name") == "Trip")
        #expect(answer == ShellDialog.Response(1))
    }

    @Test func escapeInAnOpenFieldCancelsTheEditNotTheDialog() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "A")])
        var answered = false
        d.completion = { _ in answered = true }
        click(d, CGPoint(x: f.controlFrames[0].midX, y: f.controlFrames[0].midY))
        type(d, "BC")
        d.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(f.text("name") == "A")
        #expect(!answered)
        d.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(answered)
    }

    @Test func tabWalksTheRowsAndSpaceTogglesTheCheck() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "X"), .check(id: "c", title: "Open after", on: false)])
        d.handle(.keyDown(InputKey.tab, modifiers: []), scale: 1)
        #expect(f.focused == 0)
        d.handle(.keyDown(InputKey.tab, modifiers: []), scale: 1)
        #expect(f.focused == 1)
        d.handle(.keyDown(.space, modifiers: []), scale: 1)
        #expect(f.bool("c") == true)
        d.handle(.keyDown(InputKey.tab, modifiers: []), scale: 1)
        #expect(f.focused == nil)
        #expect(d.focused == d.model.primaryIndex)
    }

    @Test func popupOpensItsListAndTheChoiceLands() {
        let (d, f) = dialog([.popup(id: "t", label: "Template", options: ["Empty", "Vlog", "Short"], selected: 0)])
        var changed: [String] = []
        f.onChange = { id, _ in changed.append(id) }
        click(d, CGPoint(x: f.controlFrames[0].midX, y: f.controlFrames[0].midY))
        #expect(d.menu.isOpen)
        d.handle(.keyDown(.down, modifiers: []), scale: 1)
        d.handle(.keyDown(.down, modifiers: []), scale: 1)
        d.handle(.keyDown(.enter, modifiers: []), scale: 1)
        #expect(!d.menu.isOpen)
        #expect(f.index("t") != 0)
        #expect(changed == ["t"])
        #expect(!d.finished)
    }

    @Test func sliderDragAndFieldClampToTheRange() {
        let (d, f) = dialog([.slider(id: "q", label: "Quality", value: 50, range: 0...100)])
        let c = f.controlFrames[0]
        d.handle(.mouseDown(x: Float(c.minX), y: Float(c.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(c.minX), y: Float(c.midY)), scale: 1)
        #expect(f.number("q") == 0)
        click(d, CGPoint(x: c.maxX - 10, y: c.midY))
        #expect(f.isEditing)
        for _ in 0..<3 { d.handle(.keyDown(.backspace, modifiers: []), scale: 1) }
        type(d, "250")
        d.handle(.keyDown(InputKey.tab, modifiers: []), scale: 1)
        #expect(f.number("q") == 100)
    }

    /// The Mac `NumericSlider` in a form row: unit column 24, 8, the 72 field, 12, the slider; a slider drag lands on the
    /// field's step and range, the field reads the value under its id.
    @Test func sliderNumberRowIsTheMacNumericSlider() {
        let field = ShellForm.NumberField(id: "vol", value: -3, range: -60...12, step: 0.1, decimals: 1, unit: "dB", defaultValue: 0)
        let (d, f) = dialog([.sliderNumber(label: "Volume", field)])
        let c = f.controlFrames[0]
        let box = f.scrubFrames["vol"] ?? .zero
        #expect(box.width == 72 && box.maxX == c.maxX - 24 - 8)
        #expect(f.number("vol") == -3)
        d.handle(.mouseDown(x: Float(c.minX), y: Float(c.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(c.minX), y: Float(c.midY)), scale: 1)
        #expect(f.number("vol") == -60)
        let mid = box.minX - 12 - (box.minX - 12 - c.minX) / 2
        d.handle(.mouseDown(x: Float(mid), y: Float(c.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(mid), y: Float(c.midY)), scale: 1)
        let v = f.number("vol") ?? 0
        #expect(abs(v - -24) < 0.6 && abs(v * 10 - (v * 10).rounded()) < 1e-9)
        var canvas = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        d.draw(&canvas, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test func radioRowPicksTheClickedOption() {
        let (d, f) = dialog([.radio(id: "r", options: ["Whole sequence", "In to Out"], selected: 0)])
        let c = f.controlFrames[0]
        click(d, CGPoint(x: c.minX + 30, y: c.minY + 24 + 12))
        #expect(f.index("r") == 1)
        #expect(c.height == 48)
    }

    @Test func noteRowWrapsAndDrawingRuns() {
        let (d, f) = dialog([.text("A long note that explains the choice in a few words and wraps when the card is narrow enough to need it."),
                             .field(id: "n", label: "Name", value: "x", unit: "fps")])
        #expect(f.rowFrames[0].height >= 16)
        #expect(f.controlFrames[1].width == 72)
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test func buttonRowAnswersTheClickedButtonAndSkipsDisabledOnes() throws {
        let (d, f) = dialog([.buttons(id: "cache", label: "Cache Folder", detail: "C:/Cache", titles: ["Choose…", "Use Default"],
                                      enabled: [true, false])])
        var got: [ShellForm.Value] = []
        f.onChange = { id, v in if id == "cache" { got.append(v) } }
        let frames = f.buttonFrames(0)
        #expect(frames.count == 2)
        #expect(abs(frames[1].maxX - (d.card.maxX - 20)) < 0.5)
        #expect(frames[0].maxX < frames[1].minX)
        click(d, CGPoint(x: frames[0].midX, y: frames[0].midY))
        click(d, CGPoint(x: frames[1].midX, y: frames[1].midY))
        #expect(got == [.index(0)])
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 800))
    }

    @Test func aFormTallerThanTheWindowScrollsInsideTheCard() throws {
        let rows: [ShellForm.Row] = (0..<30).map { .check(id: "c\($0)", title: "Row \($0)", on: false) }
        let d = ShellDialog("Preferences")
        d.addButton("Done")
        let f = ShellForm(rows)
        d.form = f
        let window = CGRect(x: 0, y: 0, width: 1000, height: 500)
        d.layout(in: window, measure: TextMeasure(atlas: nil, scale: 1))
        #expect(d.formScrolls)
        #expect(d.card.height <= window.height - 48 + 0.5)
        let first = f.rowFrames[0].minY
        d.handle(.scroll(x: Float(d.formViewport.midX), y: Float(d.formViewport.midY), dx: 0, dy: -100, modifiers: []), scale: 1)
        #expect(d.formScroll == 100)
        #expect(f.rowFrames[0].minY == first - 100)
        // A click above the viewport (on a row scrolled out of sight) does nothing.
        let hidden = try #require(f.rowFrames.indices.first { f.rowFrames[$0].maxY < d.formViewport.minY })
        click(d, CGPoint(x: f.controlFrames[hidden].minX + 4, y: f.rowFrames[hidden].midY))
        #expect(f.bool("c\(hidden)") == false)
        // Scrolling stops at the end; Tab back to the top brings the first row into view.
        d.scrollForm(by: 10_000)
        #expect(abs(f.rowFrames.last!.maxY - d.formViewport.maxY) < 0.5)
        d.handle(.keyDown(.tab, modifiers: []), scale: 1)
        #expect(f.focused == 0)
        #expect(f.rowFrames[0].minY >= d.formViewport.minY - 0.5)
        var c = Canvas(width: 1000, height: 500, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: window)
    }

    @Test func aFormThatFitsDoesNotScroll() {
        let (d, _) = dialog([.check(id: "a", title: "A", on: true)])
        #expect(!d.formScrolls)
        d.scrollForm(by: 50)
        #expect(d.formScroll == 0)
    }
}
