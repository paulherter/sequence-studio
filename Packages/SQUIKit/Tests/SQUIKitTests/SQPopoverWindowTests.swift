import AppKit
import Testing
@testable import SQUIKit

/// The live popover window: a press outside closes it, a press inside does not.
///
/// The presses go straight to the popover's event handler (`SQPopover.handle`, what its local monitor calls). Do NOT
/// pump them through `NSApp.nextEvent` / `sendEvent`: that stops the main run loop the test process sits in, the
/// process then exits 0 in the middle of the run, and every failure of the package goes unreported.
@MainActor @Suite(.serialized) struct SQPopoverWindowTests {
    private func host() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 20, y: 250, width: 60, height: 20))
        w.contentView?.addSubview(anchor)
        w.orderFront(nil)
        return (w, anchor)
    }

    private func press(in window: NSWindow, at p: NSPoint, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A mouse event has no keyCode: reading it raised, AppKit dropped the event, and no press ever arrived.
    @Test func pressOutsideClosesPressInsideDoesNot() throws {
        let (w, anchor) = host()
        defer { w.close() }
        let pop = SQPopover(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80)))
        pop.show(relativeTo: anchor.bounds, of: anchor)
        #expect(pop.isShown)
        let pw = try #require(pop.popoverWindow)
        let inside = press(in: pw, at: NSPoint(x: 10, y: 10))
        #expect(pop.handle(inside) === inside)                              // passed on to the content
        #expect(pop.isShown)
        let outside = press(in: w, at: NSPoint(x: 300, y: 40))
        #expect(pop.handle(outside) === outside)                            // closes, and what was pressed still gets it
        #expect(!pop.isShown)
    }

    /// A toggle button reopened its popover: the press closed it, went on to the button, which found it closed and
    /// showed it again. The press on the anchor now closes and stops there.
    @Test func pressOnTheAnchorClosesAndIsNotPassedOn() throws {
        let (w, anchor) = host()
        defer { w.close() }
        let pop = SQPopover(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80)))
        let onAnchor = anchor.convert(NSPoint(x: 30, y: 10), to: nil)
        pop.show(relativeTo: anchor.bounds, of: anchor)
        #expect(pop.isShown && pop.isOnAnchor(w, at: onAnchor) && !pop.isOnAnchor(w, at: NSPoint(x: 300, y: 40)))
        #expect(pop.handle(press(in: w, at: onAnchor)) == nil)              // consumed: the button never sees it
        #expect(!pop.isShown)
        // A right press on the anchor closes too but is passed on (it opens a context menu, not the popover).
        pop.show(relativeTo: anchor.bounds, of: anchor)
        let right = press(in: w, at: onAnchor, type: .rightMouseDown)
        #expect(pop.handle(right) === right && !pop.isShown)
        // A popover that only closes through close() stays, and its anchor keeps getting presses.
        pop.mode = .applicationDefined
        pop.show(relativeTo: anchor.bounds, of: anchor)
        let kept = press(in: w, at: onAnchor)
        #expect(pop.handle(kept) === kept && pop.isShown)
        pop.close()
    }

    @Test func aMenuPanelOpenedFromAPopoverCountsAsInside() throws {
        let (w, anchor) = host()
        defer { w.close() }
        let pop = SQPopover(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80)))
        pop.show(relativeTo: anchor.bounds, of: anchor)
        defer { pop.close() }
        let pw = try #require(pop.popoverWindow)
        let menu = SQMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(SQPopoverLogic.isInside(menu, popover: pw))
        #expect(SQPopoverLogic.isInside(pw, popover: pw) && !SQPopoverLogic.isInside(w, popover: pw))
    }
}
