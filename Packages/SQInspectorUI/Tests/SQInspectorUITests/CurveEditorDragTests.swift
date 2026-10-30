import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// FB-C: the curve editor gets its points back from the inspector asynchronously (observation -> Task). A drag that
/// starts on an empty spot (adds a point) must keep moving that point even when the drag events arrive before the
/// round trip: it used to move the stale list's point at the new index (an end point) and drop the added one, so the
/// picture jumped between two grades while dragging.
@MainActor @Suite struct CurveEditorDragTests {
    func rig() -> (NSWindow, CurveEditorView) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 162), styleMask: [.titled],
                           backing: .buffered, defer: false)
        let v = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 212, height: 162))
        win.contentView = v
        return (win, v)
    }

    /// Data (0…1, y up) to an event in the window.
    func event(_ type: NSEvent.EventType, _ v: CurveEditorView, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
        let r = v.bounds.insetBy(dx: 6, dy: 6)
        let p = v.convert(NSPoint(x: r.minX + x * r.width, y: r.minY + (1 - y) * r.height), to: nil)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: v.window!.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func dragAfterAddingAPointMovesThatPointWithoutWaitingForTheModel() {
        let (_, v) = rig()
        var sent: [[CurvePoint]] = []
        v.onChange = { sent.append($0) }          // no write-back: the inspector's refresh has not run yet
        v.mouseDown(with: event(.leftMouseDown, v, 0.5, 0.5))
        v.mouseDragged(with: event(.leftMouseDragged, v, 0.5, 0.6))
        v.mouseDragged(with: event(.leftMouseDragged, v, 0.5, 0.7))
        v.mouseUp(with: event(.leftMouseUp, v, 0.5, 0.7))
        #expect(sent.count == 3)
        for pts in sent { #expect(pts.count == 3) }
        let last = sent.last!
        #expect(last.first == CurvePoint(0, 0) && last.last == CurvePoint(1, 1))   // end points untouched
        #expect(abs(last[1].x - 0.5) < 0.01 && abs(last[1].y - 0.7) < 0.01)
        #expect(v.points == last)
    }

    @Test func removingAPointShowsAtOnce() {
        let (_, v) = rig()
        v.points = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        var sent: [[CurvePoint]] = []
        v.onChange = { sent.append($0) }
        v.mouseDown(with: event(.leftMouseDown, v, 0.5, 0.7, clicks: 2))
        #expect(sent == [RGBCurves.diagonal])
        #expect(v.points == RGBCurves.diagonal)
    }
}
