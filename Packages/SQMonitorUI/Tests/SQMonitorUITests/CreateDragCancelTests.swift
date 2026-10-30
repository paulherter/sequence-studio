import AppKit
import SQCore
import Testing
@testable import SQMonitorUI

/// A Create drag on the Program monitor that is interrupted makes nothing: the release that follows a tool change or a
/// move of the view to another window must not add an item.
@MainActor @Suite struct CreateDragCancelTests {
    private func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func surface() -> (ProgramSurfaceView, () -> Int) {
        final class Count { var n = 0 }
        let made = Count()
        let s = ProgramSurfaceView(viewer: NSView())
        s.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
        s.layoutSubtreeIfNeeded()
        s.onCreateShape = { _, _, _ in made.n += 1 }
        s.tool = .create(.rectangle)
        return (s, { made.n })
    }

    private func drag(_ s: ProgramSurfaceView) throws {
        s.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 200, y: 150)))
        s.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 320, y: 260)))
    }

    @Test func aFinishedDragMakesOneShape() throws {
        let (s, made) = surface()
        try drag(s)
        s.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 260)))
        #expect(made() == 1)
    }

    @Test func aToolChangeCancelsTheDrag() throws {
        let (s, made) = surface()
        try drag(s)
        s.tool = .select
        s.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 260)))
        #expect(made() == 0)
        // A change of mode inside the Create slot cancels it too.
        s.tool = .create(.rectangle)
        try drag(s)
        s.tool = .create(.ellipse)
        s.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 260)))
        #expect(made() == 0)
    }

    @Test func aMoveToAnotherWindowCancelsTheDrag() throws {
        let (s, made) = surface()
        try drag(s)
        s.viewWillMove(toWindow: nil)
        s.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 260)))
        #expect(made() == 0)
        // The next drag works again.
        try drag(s)
        s.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 320, y: 260)))
        #expect(made() == 1)
    }
}
