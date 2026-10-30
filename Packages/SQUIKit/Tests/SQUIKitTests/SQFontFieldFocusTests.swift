import AppKit
import Testing
@testable import SQUIKit

/// A click into the font name selects the whole name, so typing replaces it instead of appending.
@MainActor
struct SQFontFieldFocusTests {
    @Test func clickSelectsTheWholeName() throws {
        let f = SQFontField(fontName: "Inter Regular")
        f.familiesProvider = { ["Inter", "Helvetica"] }
        f.frame = NSRect(x: 10, y: 10, width: 200, height: 26)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView?.addSubview(f)
        f.layoutSubtreeIfNeeded()
        let tf = f.textFieldForTesting
        let p = tf.convert(NSPoint(x: 30, y: tf.bounds.midY), to: nil)
        let e = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tf.mouseDown(with: e)
        let editor = try #require(tf.currentEditor())
        #expect(f.isEditing)
        #expect(editor.selectedRange == NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(editor.selectedRange.length > 0)
        w.makeFirstResponder(nil)
    }
}
