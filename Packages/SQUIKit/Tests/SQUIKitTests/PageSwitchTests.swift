import AppKit
import Testing
@testable import SQUIKit

/// The Edit | Color switch of the top bar: a plain click anywhere on a segment selects it, and each segment is a
/// pressable accessibility element.
@MainActor @Suite struct PageSwitchTests {
    private final class Sink: NSObject {
        var count = 0
        @objc func fired(_ sender: Any?) { count += 1 }
    }

    private func make(_ sink: Sink) -> SQSegmented {
        _ = NSApplication.shared            // NSControl sends its action through the application object
        let s = SQSegmented(labels: ["Edit", "Color"], segmentWidth: 0, target: sink, action: #selector(Sink.fired(_:)))
        s.isPageSwitch = true
        s.setAccessibilityName("Edit page", forSegment: 0)
        s.setAccessibilityName("Color page", forSegment: 1)
        s.frame = NSRect(origin: .zero, size: NSSize(width: s.intrinsicContentSize.width, height: 44))
        return s
    }

    @Test func everyPointOfTheControlBelongsToASegment() {
        let s = make(Sink())
        let w = s.intrinsicContentSize.width
        for x in stride(from: CGFloat(0.5), to: w, by: 1) {
            for y in [CGFloat(0.5), 22, 43.5] { #expect(s.segment(at: NSPoint(x: x, y: y)) != nil, "dead pixel at \(x), \(y)") }
        }
        #expect(s.segment(at: NSPoint(x: 1, y: 22)) == 0)
        #expect(s.segment(at: NSPoint(x: w - 1, y: 22)) == 1)
    }

    @Test func aClickNeverDragsTheWindow() {
        let s = make(Sink())
        #expect(!s.mouseDownCanMoveWindow)
        #expect(s.acceptsFirstMouse(for: nil))
    }

    @Test func pressSelectsAndSendsTheActionOnce() {
        let sink = Sink()
        let s = make(sink)
        s.selectedSegment = 0
        #expect(s.press(1))
        #expect(s.selectedSegment == 1 && sink.count == 1)
        #expect(s.press(1))                 // already selected: no second action
        #expect(sink.count == 1)
    }

    @Test func segmentsArePressableAccessibilityElements() throws {
        let sink = Sink()
        let s = make(sink)
        s.selectedSegment = 0
        let kids = try #require(s.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(kids.map { $0.accessibilityLabel() } == ["Edit page", "Color page"])
        #expect(kids[1].accessibilityPerformPress())
        #expect(s.selectedSegment == 1 && sink.count == 1)
    }
}
