import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

/// The Color Matte color well (`SQColorWell` in a form row): a swatch that opens the SQ picker and answers its color.
@MainActor
@Suite struct ShellColorRowTests {
    func dialog() -> (ShellDialog, ShellForm) {
        let d = ShellDialog("Form")
        d.addButton("Add")
        d.addButton("Cancel", role: .cancel)
        let f = ShellForm([.field(id: "name", label: "Name", value: "Matte"),
                           .color(id: "color", label: "Color", value: SQColorValue(r: 0.2, g: 0.4, b: 0.6))])
        d.form = f
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        return (d, f)
    }

    @Test func aClickOpensThePickerAndAnEditAnswersTheColor() {
        let (d, f) = dialog()
        #expect(f.color("color")?.hex == "336699")
        var answered: String?
        f.onChange = { id, v in if id == "color", case .text(let h) = v { answered = h } }
        let box = f.controlFrames[1]
        d.handle(.mouseDown(x: Float(box.midX), y: Float(box.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(box.midX), y: Float(box.midY)), scale: 1)
        #expect(f.pickerOpen)
        // A press in the picker's saturation field picks a color; the dialog stays open.
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let pk = ColorPickerControl(value: SQColorValue(r: 0.2, g: 0.4, b: 0.6), showsEyedropper: false)
        let frame = pk.frame(anchor: box, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let p = CGPoint(x: frame.minX + pk.fieldFrame.maxX - 2, y: frame.minY + pk.fieldFrame.minY + 2)
        d.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
        #expect(answered != nil && answered != "336699")
        #expect(f.color("color")?.hex == answered)
        // A press outside closes the picker without leaving the dialog.
        d.handle(.mouseDown(x: 2, y: 2, modifiers: []), scale: 1)
        #expect(!f.pickerOpen)
    }

    /// Dialog fields fill the 28 pt row like `SQDialog.makeField`; a short button title is not padded to a minimum width.
    @Test func dialogFieldsAreFullRowAndButtonsHaveNoMinimumWidth() {
        let (d, f) = dialog()
        #expect(f.fields[0]?.dialogStyle == true)
        let ok = ShellDialog("Note")
        ok.addButton("OK")
        ok.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        #expect((ok.buttonFrames.values.first?.width ?? 99) < 64)
        _ = d
    }
}
