import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
@testable import SQDrawMonitor

/// The Program monitor's Type tool press, the text double-click and the on-canvas text field.
@MainActor
@Suite struct MonitorTextToolTests {
    func program() -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        m.duration = Time(250, 25)
        let p = MonitorPanel(model: m)
        p.sequenceSize = CGSize(width: 1920, height: 1080)
        p.hasPicture = true
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        return p
    }

    func press(_ p: MonitorPanel, _ a: CGPoint, to b: CGPoint? = nil) {
        _ = p.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []))
        if let b { _ = p.handle(.mouseDragged(x: Float(b.x), y: Float(b.y))) }
        let e = b ?? a
        _ = p.handle(.mouseUp(x: Float(e.x), y: Float(e.y)))
    }

    @Test func typeToolClickPlacesPointTextAtTheCanvasCenter() {
        let p = program()
        p.typeToolOn = { true }
        var clicks: [Vec2] = []
        var picks = 0
        p.onTypeClick = { clicks.append($0) }
        p.onPickClip = { _ in picks += 1 }
        let c = p.canvasRect
        press(p, CGPoint(x: c.midX, y: c.midY))
        #expect(clicks.count == 1)
        #expect(abs(clicks[0].x) < 2 && abs(clicks[0].y) < 2)
        #expect(picks == 0)                                  // the Type tool does not pick
        #expect(!p.isDragging)
    }

    @Test func typeToolDragDrawsABoxInSequencePixels() {
        let p = program()
        p.typeToolOn = { true }
        var boxes: [(Vec2, Vec2)] = []
        var clicks = 0
        p.onTypeBox = { boxes.append(($0, $1)) }
        p.onTypeClick = { _ in clicks += 1 }
        let c = p.canvasRect
        let a = CGPoint(x: c.minX + c.width * 0.25, y: c.minY + c.height * 0.25)
        let b = CGPoint(x: c.minX + c.width * 0.75, y: c.minY + c.height * 0.75)
        _ = p.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []))
        _ = p.handle(.mouseDragged(x: Float(b.x), y: Float(b.y)))
        #expect(p.typeDragRect != nil)
        _ = p.handle(.mouseUp(x: Float(b.x), y: Float(b.y)))
        #expect(clicks == 0)
        #expect(boxes.count == 1)
        #expect(abs(boxes[0].0.x) < 2 && abs(boxes[0].0.y) < 2)          // centered
        #expect(abs(boxes[0].1.x - 960) < 4 && abs(boxes[0].1.y - 540) < 4)  // half the sequence
    }

    @Test func escCancelsTheTypePress() {
        let p = program()
        p.typeToolOn = { true }
        var calls = 0
        p.onTypeClick = { _ in calls += 1 }
        let c = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(c.midX), y: Float(c.midY), modifiers: []))
        #expect(p.handle(.keyDown(.escape, modifiers: [])))
        _ = p.handle(.mouseUp(x: Float(c.midX), y: Float(c.midY)))
        #expect(calls == 0)
    }

    @Test func doubleClickOnThePictureAsksForTextEditing() {
        let p = program()
        var now = 10.0
        p.clock = { now }
        var edits: [Vec2] = []
        p.onTextDoubleClick = { edits.append($0) }
        let c = p.canvasRect
        press(p, CGPoint(x: c.midX, y: c.midY))
        now += 0.2
        press(p, CGPoint(x: c.midX + 1, y: c.midY))
        #expect(edits.count == 1)
        now += 1                                             // slow second press: no double-click
        press(p, CGPoint(x: c.midX, y: c.midY))
        now += 1
        press(p, CGPoint(x: c.midX, y: c.midY))
        #expect(edits.count == 1)
    }

    func target(width: CGFloat = 800, height: CGFloat = 200) -> OverlayTarget {
        OverlayTarget(clip: UUID(), size: CGSize(width: width, height: height), isText: true, baseTransform: ClipTransform(),
                      shift: .zero, positionTrack: KeyframeTrack<Vec2>())
    }

    @Test func textFieldTypesEndsOnEscAndTogglesStyle() {
        let f = MonitorTextField()
        var edited: [String] = []
        var ended: [String] = []
        var styles: [MonitorTextField.StyleToggle] = []
        f.onEdited = { edited.append($0) }
        f.onEnded = { ended.append($0) }
        f.onStyleToggle = { styles.append($0) }
        f.begin(text: "Text", target: target(), selectAll: true)
        #expect(f.key(.character("H"), modifiers: []))
        #expect(f.key(.character("i"), modifiers: []))
        #expect(f.key(.enter, modifiers: []))               // Return breaks the line
        #expect(f.key(.character("b"), modifiers: [.command]))
        #expect(edited == ["H", "Hi", "Hi\n"])
        #expect(styles == [.bold])
        #expect(f.key(.escape, modifiers: []))
        #expect(ended == ["Hi\n"])
        #expect(!f.isEditing)
        #expect(!f.key(.character("x"), modifiers: []))     // closed: keys go on
    }

    @Test func layoutCentersLinesAndIndexFindsTheNearestCharacter() {
        let f = MonitorTextField()
        f.begin(text: "ab\ncd", target: target(), selectAll: false)
        f.fontSize = 100
        // 10 pt per character in the UI font, "M" 10 pt: k = fontView * 0.8 / 10.
        let l = f.layout(size: CGSize(width: 800, height: 200), viewPerPixel: 1) { CGFloat($0.count) * 10 }
        #expect(l.lines.count == 2)
        #expect(l.lines[0].height == 120)
        #expect(l.lines[0].top == -20)                       // (200 - 240) / 2: centered vertically
        #expect(l.carets.count == 6)
        let xs = l.carets[0...2].map(\.x)
        #expect(abs((xs[0] + xs[2]) / 2 - 400) < 0.01)       // centered horizontally
        #expect(l.index(at: CGPoint(x: xs[2] + 5, y: 0)) == 2)
        #expect(l.index(at: CGPoint(x: l.carets[4].x, y: 110)) == 4)
    }

    /// A caret map in layer px: "abc" on one 100 px line, carets every 50 px from x 10.
    private func map() -> MonitorTextField.Carets {
        MonitorTextField.Carets(lines: [.init(top: 0, height: 100)], carets: (0...3).map { .init(line: 0, x: 10 + CGFloat($0) * 50) })
    }

    @Test func openingAtAClickPutsTheCaretAtThatCharacter() {
        let f = MonitorTextField()
        f.sequenceSize = CGSize(width: 1920, height: 1080)
        f.caretSource = { [map] text in text == "abc" ? map() : nil }
        // The layer is 200 x 100 px centered on the canvas: its top-left at (-100, -50) from the center.
        let t = target(width: 200, height: 100)
        f.begin(text: "abc", target: t, selectAll: false, caretAt: Vec2(-100 + 62, 0))   // nearest caret: x 60
        #expect(f.edit?.caret == 1 && f.edit?.selection.isEmpty == true)
        f.begin(text: "abc", target: t, selectAll: false, caretAt: Vec2(90, 0))           // past the end
        #expect(f.edit?.caret == 3)
        f.begin(text: "abc", target: t, selectAll: false)
        #expect(f.edit?.caret == 3)
        f.begin(text: "abc", target: t, selectAll: true, caretAt: Vec2(-100 + 62, 0))      // a new text selects all
        #expect(f.edit?.selection == 0..<3)
    }

    @Test func pressUsesTheCaretMapScaledToTheView() {
        let p = program()
        let f = p.textField
        f.sequenceSize = CGSize(width: 1920, height: 1080)
        f.caretSource = { [map] text in text == "abc" ? map() : nil }
        f.begin(text: "abc", target: target(width: 200, height: 100), selectAll: false)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        let q = f.quad(canvasRect: p.canvasRect)
        let k = (q[1].x - q[0].x) / 200                       // view points per layer px
        let at = CGPoint(x: q[0].x + 112 * k, y: q[0].y + 50 * k)  // layer x 112: caret 2 (x 110)
        _ = p.handle(.mouseDown(x: Float(at.x), y: Float(at.y), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(at.x), y: Float(at.y)))
        #expect(f.edit?.caret == 2)
    }

    @Test func pressInsideMovesTheCaretOutsideEnds() {
        let p = program()
        let f = p.textField
        var ended = 0
        f.onEnded = { _ in ended += 1 }
        f.sequenceSize = CGSize(width: 1920, height: 1080)
        f.begin(text: "Hello", target: target(), selectAll: true)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        let q = f.quad(canvasRect: p.canvasRect)
        #expect(q.count == 4)
        let mid = CGPoint(x: (q[0].x + q[2].x) / 2, y: (q[0].y + q[2].y) / 2)
        _ = p.handle(.mouseDown(x: Float(mid.x), y: Float(mid.y), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(mid.x), y: Float(mid.y)))
        #expect(f.isEditing)
        #expect(f.edit?.selection.isEmpty == true)           // the press placed the caret
        let out = CGPoint(x: p.canvasRect.minX + 4, y: p.canvasRect.minY + 4)
        _ = p.handle(.mouseDown(x: Float(out.x), y: Float(out.y), modifiers: []))
        #expect(!f.isEditing)
        #expect(ended == 1)
    }
}
