import AppKit
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

@MainActor
struct ToolColumnViewTests {
    private func makeView(height: CGFloat = 300) -> TimelineView {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: height))
    }

    private func buttons(_ v: TimelineView) -> [NSButton] { v.subviews.compactMap { $0 as? NSButton } }

    @Test func columnHasRealButtonsWithSelectionActive() {
        let v = makeView()
        let b = buttons(v)
        #expect(b.count == TimelineView.toolColumnOrder.count)
        #expect(b.filter { $0.state == .on }.count == 1)
        #expect(b.first?.state == .on)                      // Selection is first and default
        #expect(b.allSatisfy { !$0.isHidden && $0.frame.maxX <= TimelineGeometry.toolColumnWidth })
    }

    @Test func clickingRazorButtonSwitchesToolAndHighlight() throws {
        let v = makeView()
        var reported: TimelineTool?
        v.onToolChange = { reported = $0 }
        let razorIndex = try #require(TimelineView.toolColumnOrder.firstIndex(of: .razor))
        buttons(v)[razorIndex].performClick(nil)
        #expect(v.toolState.tool == .razor && reported == .razor)
        #expect(buttons(v).enumerated().filter { $0.element.state == .on }.map(\.offset) == [razorIndex])
    }

    @Test func keyboardToolChangeMovesTheHighlight() throws {
        let v = makeView()
        v.toolState.tool = .razor                           // what the C key does
        let razorIndex = try #require(TimelineView.toolColumnOrder.firstIndex(of: .razor))
        #expect(buttons(v)[razorIndex].state == .on)
        #expect(buttons(v)[0].state == .off)
    }

    @Test func pointerDownIsReported() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        let v = makeView()
        window.contentView?.addSubview(v)
        var downs = 0
        v.onPointerDown = { downs += 1 }
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: v.convert(CGPoint(x: 400, y: 60), to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        v.mouseDown(with: e)
        #expect(downs == 1)
    }

    @Test func tracksFillThePanel() {
        let v = makeView(height: 300)
        let rows = v.geometry.rows(for: v.timeline)
        #expect(abs(rows.last!.maxY - 300) < 0.5)
    }
}
