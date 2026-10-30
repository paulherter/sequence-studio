import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQDrawShell

/// The Mac settings and dialog pieces the shared form draws beside its rows: number grids, a field after a check title,
/// the status line, the shot-length chart, the multi-line box and popup color dots.
@MainActor
@Suite struct ShellFormExtrasTests {
    func dialog(_ rows: [ShellForm.Row], _ setup: (ShellForm) -> Void = { _ in }) -> (ShellDialog, ShellForm) {
        let d = ShellDialog("Form")
        d.addButton("Cancel", role: .cancel)
        d.addButton("OK", role: .default)
        let f = ShellForm(rows)
        setup(f)
        d.form = f
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 800), measure: TextMeasure(atlas: nil, scale: 1))
        return (d, f)
    }

    func click(_ d: ShellDialog, _ p: CGPoint, count: Int = 1) {
        d.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
    }

    func key(_ d: ShellDialog, _ k: InputKey) { d.handle(.keyDown(k, modifiers: []), scale: 1) }

    func field(_ id: String, _ v: Double) -> ShellForm.NumberField {
        ShellForm.NumberField(id: id, value: v, range: 0...600, step: 0.05, decimals: 2)
    }

    /// `SQFormRow.unitGrid` under the row line: title | 72 pt field | unit, 8 apart, 4 under the line, rows 8 apart; the
    /// row grows by the grid.
    @Test func aGridSitsUnderTheRowLineAndGrowsTheRow() {
        let (_, f) = dialog([.label(id: "offset", label: "J / L Offset")]) {
            $0.setGrid("offset", [.init(title: "Dialogue", field: field("o.d", 0.5), unit: "s"),
                                  .init(title: "Music", field: field("o.m", 1), unit: "s")])
        }
        let a = f.scrubFrames["o.d"]!, b = f.scrubFrames["o.m"]!
        #expect(a.minY == f.rowFrames[0].minY + 28 + 4)
        #expect(b.minY == a.maxY + 8)
        #expect(a.width == 72 && a.minX == b.minX)
        #expect(a.minX > f.controlFrames[0].minX)          // after the title column
        #expect(f.rowFrames[0].maxY == b.maxY)
        #expect(f.number("o.m") == 1)
    }

    @Test func aGridFieldTakesClicksArrowsAndAnswersItsOwnID() {
        var changes: [(String, ShellForm.Value)] = []
        let (d, f) = dialog([.label(id: "offset", label: "J / L Offset")]) {
            $0.setGrid("offset", [.init(title: "Dialogue", field: field("o.d", 0.5), unit: "s")])
        }
        f.onChange = { changes.append(($0, $1)) }
        let box = f.scrubFrames["o.d"]!
        click(d, CGPoint(x: box.midX, y: box.midY))
        #expect(f.focused == 0)
        key(d, .escape)                                      // leave the click's edit
        key(d, .up)
        #expect(changes.last?.0 == "o.d")
        #expect((f.number("o.d") ?? 0) > 0.5)
    }

    /// The Live Ducking amount: a 92 pt field 8 after the check title on the row line, dimmed and deaf while the check is off.
    @Test func aCheckFieldFollowsTheTitleAndOnlyWorksWhileTheCheckIsOn() {
        let amount = ShellForm.NumberField(id: "duckAmount", value: 12, range: 0.5...40, step: 0.5, decimals: 1, defaultValue: 12)
        let (d, f) = dialog([.check(id: "liveDuck", title: "Duck", on: false)]) {
            $0.checkLabels["liveDuck"] = "Live Ducking"
            $0.setCheckField("liveDuck", amount, width: 92)
        }
        let box = f.scrubFrames["duckAmount"]!
        #expect(box.width == 92 && box.height == 28)
        #expect(box.minX == f.controlFrames[0].minX + 14 + 6 + ceil(TextMeasure(atlas: nil, scale: 1).width("Duck", size: 12)) + 8)
        #expect(f.scrubOff("duckAmount"))
        click(d, CGPoint(x: box.midX, y: box.midY))
        #expect(f.bool("liveDuck") == false)                 // the click on the dimmed field does not toggle the check
        #expect(!f.isEditing)
        click(d, CGPoint(x: f.controlFrames[0].minX + 7, y: f.controlFrames[0].midY))
        #expect(f.bool("liveDuck") == true)
        #expect(!f.scrubOff("duckAmount"))
        click(d, CGPoint(x: box.midX, y: box.midY))
        #expect(f.bool("liveDuck") == true)
    }

    /// The Edit API line under the row: dot, text, a Copy button that answers "<id>.status"; the help follows it.
    @Test func aStatusLineSitsUnderTheRowAndItsButtonAnswers() {
        var answered: String?
        let (d, f) = dialog([.check(id: "api", title: "Allow local tools", on: true)]) {
            $0.checkLabels["api"] = "Edit API"
            $0.statuses["api"] = .init(text: "Listening on 127.0.0.1:7341", tone: .ok, button: "Copy address", buttonIcon: .copy)
            $0.helps["api"] = "Only programs on this Mac can connect."
        }
        f.onChange = { id, _ in answered = id }
        #expect(abs(f.rowFrames[0].height - (28 + 4 + 28 + 4 + 16)) < 0.01)   // line, status, one help line (dialog 16 pt lines)
        let p = CGPoint(x: f.controlFrames[0].minX + 8 + 8 + 179 + 8 + 10, y: f.rowFrames[0].minY + 28 + 4 + 14)
        click(d, p)
        #expect(answered == "api.status", "\(p) \(f.rowFrames[0]) \(f.controlFrames[0])")
        #expect(f.bool("api") == true)
    }

    /// `CutCheckSheetView`: note lines, 8, the title, 8, a 110 pt chart, all in the control column.
    @Test func theChartRowStacksNoteTitleAndChartInTheControlColumn() {
        let bars = [ShellForm.Bar(label: "<1s", count: 3), ShellForm.Bar(label: "1-2s", count: 5)]
        let (_, f) = dialog([.segmented(id: "p", label: "Safe Zone", options: ["A", "B"], selected: 0, segmentWidth: 52),
                             .chart(note: "5 cuts", title: "Shot length", bars: bars)])
        #expect(f.controlFrames[1].minX == f.controlFrames[0].minX)
        #expect(abs(f.rowFrames[1].height - (16 + 8 + 14 + 8 + 110)) < 0.01)
        f.setChart(1, note: "", bars: [])
        f.layout(origin: .zero, width: 440)
        #expect(abs(f.rowFrames[1].height - (14 + 8 + 110)) < 0.01)
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        f.draw(&c, theme: DrawTheme())
    }

    /// Project Notes: a full-width box; Return breaks the line, typing edits, Esc goes to the dialog (Cancel).
    @Test func theTextBoxTakesLineBreaksAndLeavesEscToTheDialog() {
        var answer: ShellDialog.Response?
        let (d, f) = dialog([.textBox(id: "notes", value: "Hi", height: 180)])
        d.completion = { answer = $0 }
        #expect(f.controlFrames[0].height == 180)
        #expect(f.controlFrames[0].minX == d.card.minX + 20 && f.controlFrames[0].maxX == d.card.maxX - 20)
        f.beginEditing("notes")
        #expect(f.isEditing)
        key(d, .enter)
        #expect(answer == nil)
        key(d, .character("x"))
        #expect(f.text("notes") == "Hi\nx")
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        f.draw(&c, theme: DrawTheme())
        key(d, .escape)
        #expect(answer != nil)
    }

    @Test func aClickInTheTextBoxPlacesTheCaretOnTheClickedLine() {
        let (d, f) = dialog([.textBox(id: "notes", value: "one\ntwo", height: 180)])
        let box = f.controlFrames[0]
        click(d, CGPoint(x: box.maxX - 10, y: box.minY + 6 + 14 + 7))     // end of line two
        key(d, .character("!"))
        #expect(f.text("notes") == "one\ntwo!")
    }

    /// The marker Color popup: each option carries its color dot in the list.
    @Test func popupDotsBecomeSwatchesInTheOpenList() {
        var items: [SQMenuItem] = []
        let (d, f) = dialog([.popup(id: "color", label: "Color", options: ["Green", "Red"], selected: 0)]) {
            $0.popupStyles["color"] = .init(dots: [0x30D158, 0xED4D47])
        }
        f.openPopup = { _, list, _ in items = list }
        click(d, CGPoint(x: f.controlFrames[0].midX, y: f.controlFrames[0].midY))
        #expect(items.map(\.icon) == [.swatch(0x30D158), .swatch(0xED4D47)])
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        f.draw(&c, theme: DrawTheme())
    }

    /// The Mac Find dialog: `NSStackView([field, popup])` on one line at the card's inner edge; the popup as wide as its
    /// longest option (`SQPopup` intrinsic: 32 pt chrome), 8 after the field; the check row under them.
    @Test func anInlinePopupSharesTheFieldLine() {
        let (_, f) = dialog([.field(id: "text", label: "", value: ""),
                             .popup(id: "field", label: "", options: ["Name", "Label"], selected: 0),
                             .check(id: "offline", title: "Offline media only", on: false)]) {
            $0.inlinePopups = ["field"]
            $0.controlWidths = ["field": 80]
            $0.placeholders = ["text": "Text"]
        }
        let field = f.controlFrames[0], popup = f.controlFrames[1]
        #expect(popup.minY == field.minY && popup.height == field.height)
        #expect(popup.width == 80 && popup.minX == field.maxX + 8)
        #expect(field.minX == f.rowFrames[0].minX + 18)                // no label column; the Mac field's 2 pt bleed
        #expect(popup.maxX == f.rowFrames[0].maxX - 20)
        #expect(f.rowFrames[2].minY == f.rowFrames[0].maxY + 12)       // the check row follows the shared line
        #expect(f.row(at: CGPoint(x: popup.midX, y: popup.midY)) == 1)
        var opened: [String] = []
        f.openPopup = { _, items, _ in opened = items.map(\.title) }
        _ = f.mouseDown(CGPoint(x: popup.midX, y: popup.midY))
        #expect(opened == ["Name", "Label"])
    }

    @Test func aPopupWithoutAWidthFitsItsLongestOption() {
        let (_, f) = dialog([.field(id: "text", label: "", value: ""),
                             .popup(id: "field", label: "", options: ["Name", "Label"], selected: 0)]) { $0.inlinePopups = ["field"] }
        let w = f.controlFrames[1].width
        #expect(w == ceil(32 + max(f.measure.width("Name", size: CGFloat(DrawTheme.TypeSize.body)), f.measure.width("Label", size: CGFloat(DrawTheme.TypeSize.body)))))
    }

    /// The Mac NSTextField bleeds 2 pt past its alignment rect; the unlabeled popup chrome sits 5 pt left of it.
    @Test func unlabeledFieldAndPopupBleedLikeTheMac() {
        let (_, f) = dialog([.field(id: "name", label: "", value: "x"),
                             .popup(id: "a", label: "", options: ["One"], selected: 0)]) {
            $0.controlWidths = ["name": 400, "a": 400]
        }
        let row = f.rowFrames[0]
        #expect(f.controlFrames[0].minX == row.minX + 18)
        #expect(f.controlFrames[0].width == 404)
        #expect(f.controlFrames[1].minX == row.minX + 15)
        #expect(f.controlFrames[1].width == 405)
    }

    /// Per-form overrides for the Mac sheets: the side padding moves the controls, and an overridden field height wins.
    @Test func sidePadAndFieldHeightOverridesApply() {
        let rows: [ShellForm.Row] = [.field(id: "name", label: "Name", value: "x")]
        let (_, plain) = dialog(rows)
        let (_, padded) = dialog(rows) { $0.sidePad = 24; $0.fieldHeights["name"] = 22 }
        #expect(padded.controlFrames[0].height == 22)
        #expect(padded.controlFrames[0].minX != plain.controlFrames[0].minX || padded.controlFrames[0].height != plain.controlFrames[0].height)
    }

    /// Dragging the mouse inside a single-line field selects text (the Mac field editor); a drag from the first press
    /// (editor not open yet) starts the selection at the press point.
    @Test func draggingInAFieldSelectsText() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "hello world")])
        let box = f.controlFrames[0]
        func at(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: box.midY) }
        click(d, at(box.minX + 8))                              // opens the editor (all selected)
        d.handle(.mouseDown(x: Float(box.minX + 8), y: Float(box.midY), modifiers: []), scale: 1)    // caret to the start
        d.handle(.mouseDragged(x: Float(box.maxX - 2), y: Float(box.midY)), scale: 1)
        d.handle(.mouseUp(x: Float(box.maxX - 2), y: Float(box.midY)), scale: 1)
        let e = f.textEditor(forRow: 0)
        #expect(e?.selection.count ?? 0 > 0, "the drag selected a range")
        #expect(e?.selection.lowerBound == 0)
    }

    @Test func dragFromTheFirstPressStartsAtThePress() {
        let (d, f) = dialog([.field(id: "name", label: "Name", value: "hello world")])
        let box = f.controlFrames[0]
        d.handle(.mouseDown(x: Float(box.minX + 8), y: Float(box.midY), modifiers: []), scale: 1)
        d.handle(.mouseDragged(x: Float(box.minX + 40), y: Float(box.midY)), scale: 1)
        d.handle(.mouseUp(x: Float(box.minX + 40), y: Float(box.midY)), scale: 1)
        let e = f.textEditor(forRow: 0)
        #expect(e != nil)
        #expect(e.map { $0.selection.count < $0.text.count } == true, "not everything stays selected after a drag")
    }
}
