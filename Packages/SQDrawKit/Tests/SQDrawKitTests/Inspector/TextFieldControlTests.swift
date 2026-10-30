import Foundation
import Testing
import SQDrawKit
import SQUIKit

@Suite("Text field, button and progress controls")
struct TextFieldControlTests {
    @Test func clickEditsEnterCommitsEscapeCancels() {
        var f = TextFieldControl(text: "00:00:01:00")
        f.mouseDown()
        #expect(f.isEditing)
        for ch in "12" { _ = f.key(.character(ch), modifiers: []) }
        #expect(f.key(.enter, modifiers: []) == "12")
        #expect(!f.isEditing && f.text == "12")
        f.mouseDown()
        _ = f.key(.character("9"), modifiers: [])
        #expect(f.key(.escape, modifiers: []) == nil)
        #expect(!f.isEditing && f.text == "12")
    }

    @Test func aPressInsideTheOpenEditorPlacesTheCaretUnderThePointer() throws {
        let atlas = try #require(GlyphAtlas())
        let c = Canvas(width: 200, height: 40, atlas: atlas, scale: 1)
        var f = TextFieldControl(text: "Balance")
        f.alignment = .left
        let bounds = CGRect(x: 10, y: 0, width: 160, height: 22)
        #expect(f.caretIndex(c, x: 50, in: bounds) == nil, "closed: no caret")
        f.mouseDown()
        let inner = TextFieldControl.textRect(in: bounds)
        #expect(inner.minX == bounds.minX + 6)
        // Left of the text: 0; right of it: the end; between "Bal" and "ance": 3.
        #expect(f.caretIndex(c, x: bounds.minX, in: bounds) == 0)
        #expect(f.caretIndex(c, x: bounds.maxX, in: bounds) == 7)
        let x3 = inner.minX + c.size(of: "Bal", fontSize: f.fontSize).width
        let i = try #require(f.caretIndex(c, x: x3, in: bounds))
        #expect(i == 3)
        f.mouseDown(caret: i)
        #expect(f.editor?.caret == 3 && f.editor?.hasSelection == false)
        _ = f.key(.character("X"), modifiers: [])
        #expect(f.key(.enter, modifiers: []) == "BalXance")
    }

    @Test func tabCommitsWithoutTypingATab() {
        var f = TextFieldControl(text: "a")
        f.mouseDown()
        _ = f.key(.character("b"), modifiers: [])
        #expect(f.key(.tab, modifiers: []) == "b")
        #expect(f.text == "b")
    }

    @Test func disabledFieldDoesNotOpen() {
        var f = TextFieldControl(text: "x")
        f.isEnabled = false
        f.mouseDown()
        #expect(!f.isEditing)
    }

    @Test func buttonAndProgressDraw() {
        var c = Canvas(width: 100, height: 30, atlas: nil, scale: 1)
        let t = DrawTheme()
        InspectorDraw.button(&c, title: "Start", in: CGRect(x: 0, y: 0, width: 60, height: 30), hovering: false, pressed: false,
                             enabled: true, accent: true, t)
        InspectorDraw.progress(&c, fraction: 0.5, in: CGRect(x: 0, y: 26, width: 100, height: 4), t)
        let img = SoftwareRenderer.render(c.list, width: 100, height: 30, clear: .black, atlas: nil)
        let at = { (x: Int, y: Int) in img.pixels[(y * 100 + x) * 4 + 2] }
        #expect(at(30, 15) > 100)      // accent body
        #expect(at(20, 28) > at(80, 28))     // filled share left of the half
    }
}
