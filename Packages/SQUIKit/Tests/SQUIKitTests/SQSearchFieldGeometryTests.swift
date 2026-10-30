import AppKit
import Testing
@testable import SQUIKit

/// Placeholder / text of a search field stays on one centered line whether the field is idle or being edited
/// (clicking used to move the placeholder to the top-left corner: the editing path used rects the cell did not center).
@MainActor
struct SQSearchFieldGeometryTests {
    private func makeField() -> (SQSearchField, NSWindow) {
        let f = SQSearchField(frame: NSRect(x: 10, y: 10, width: 180, height: 22))
        f.setQuietPlaceholder("Search")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView?.addSubview(f)
        return (f, w)
    }

    @Test func allTextRectsAreTheSameCentredLine() throws {
        let (f, _) = makeField()
        let cell = try #require(f.cell as? SQSearchFieldCell)
        let b = NSRect(x: 0, y: 0, width: 180, height: 22)
        let search = cell.searchTextRect(forBounds: b)
        let draw = cell.drawingRect(forBounds: b)
        let title = cell.titleRect(forBounds: b)
        #expect(abs(search.midY - b.midY) <= 1)
        for r in [draw, title] {
            #expect(abs(r.midY - search.midY) <= 1)
            #expect(abs(r.minX - search.minX) <= 1)
            #expect(r.height <= 22)
        }
    }

    @Test func fieldEditorSitsOnTheCentredLineWhenClicked() throws {
        let (f, w) = makeField()
        #expect(w.makeFirstResponder(f))
        let editor = try #require(f.currentEditor() as? NSTextView)
        let cell = try #require(f.cell as? SQSearchFieldCell)
        let want = cell.searchTextRect(forBounds: f.bounds)
        let frame = editor.superview.map { $0.convert(editor.frame, to: f) } ?? editor.frame
        #expect(abs(frame.midY - want.midY) <= 2)
        #expect(abs(frame.minX - want.minX) <= 6)
    }
}
