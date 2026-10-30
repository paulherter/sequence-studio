import AppKit
import Testing
@testable import SQUIKit

@MainActor @Suite struct ScrubFieldTests {
    @Test func displayAndFormatter() {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.unit = "%"; f.value = 42
        #expect(f.displayText == "42 %")
        f.valueFormatter = { "\($0)!" }
        #expect(f.displayText == "42.0!")
    }

    @Test func accessibilityStepIsOneTriple() {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.range = 0...10; f.value = 10
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("changed \($0)") }
        f.onEnd = { log.append("end \($0)") }
        _ = f.accessibilityPerformDecrement()
        #expect(log == ["begin", "changed 9.0", "end 9.0"])
        f.value = 10
        log = []
        _ = f.accessibilityPerformIncrement()   // clamped: no change, no undo step
        #expect(log.isEmpty)
    }

    private func press(at p: NSPoint, in w: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func makeEditing() -> (NSWindow, ScrubField, [Double]) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let f = ScrubField(frame: NSRect(x: 10, y: 10, width: 80, height: 20))
        w.contentView?.addSubview(f)
        f.range = 0...100; f.value = 50
        f.beginEditing()
        return (w, f, [])
    }

    @Test func pressOutsideEditorCommitsTypedValue() {
        let (w, f, _) = makeEditing()
        var ended: [Double] = []
        f.onEnd = { ended.append($0) }
        let editor = f.subviews.compactMap { $0 as? NSTextField }.first!
        editor.stringValue = "55"
        // Far away from the field, on a view that does not take focus.
        f.commitForPress(press(at: NSPoint(x: 250, y: 50), in: w))
        #expect(!f.isEditing)
        #expect(f.value == 55)
        #expect(ended == [55])
    }

    @Test func pressInsideEditorKeepsEditing() {
        let (w, f, _) = makeEditing()
        let editor = f.subviews.compactMap { $0 as? NSTextField }.first!
        editor.stringValue = "55"
        let inside = f.convert(NSPoint(x: editor.frame.midX, y: editor.frame.midY), to: nil)
        f.commitForPress(press(at: inside, in: w))
        #expect(f.isEditing)
        #expect(f.value == 50)
    }
}
