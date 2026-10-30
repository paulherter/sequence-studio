import AppKit
import Testing
@testable import SQUIKit

/// A panel scrolled under a resting pointer must leave exactly one inspector row hovered (the one under the pointer).
@MainActor
struct InspectorRowHoverScrollTests {
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    @Test func scrollingUnderAnIdlePointerHoversOnlyTheRowUnderIt() {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 240, height: 960))
        var rows: [InspectorRow] = []
        for i in 0..<40 {
            let r = InspectorRow(title: "Row \(i)", control: nil)
            r.frame = NSRect(x: 0, y: CGFloat(i) * 24, width: 240, height: 24)
            doc.addSubview(r); rows.append(r)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        scroll.documentView = doc
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll

        let pointer = NSPoint(x: 100, y: 100)
        for step in 0..<8 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 24))
            scroll.reflectScrolledClipView(scroll.contentView)
            var lit = 0
            for r in rows { r.syncHover(atWindowPoint: pointer); if r.isHovered { lit += 1 } }
            #expect(lit == 1)
        }
    }
}
