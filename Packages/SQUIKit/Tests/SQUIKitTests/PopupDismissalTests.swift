import AppKit
import Testing
@testable import SQUIKit

/// The shared dismissal rules of the SQ popups: one popover at a time, a press on a menu's own control closes it for good,
/// another window taking over closes popovers, no tooltip or command behind a dialog.
@MainActor @Suite(.serialized) struct PopupDismissalTests {
    private func host() -> (NSWindow, NSControl) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let anchor = NSControl(frame: NSRect(x: 20, y: 250, width: 60, height: 20))
        w.contentView?.addSubview(anchor)
        w.orderFront(nil)
        return (w, anchor)
    }

    private func press(in window: NSWindow, at p: NSPoint, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func popover() -> SQPopover { SQPopover(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))) }

    @Test func openingAPopoverClosesTheOtherOne() {
        let (w, anchor) = host()
        defer { w.close() }
        let a = popover(), b = popover()
        a.show(relativeTo: anchor.bounds, of: anchor)
        #expect(a.isShown)
        b.show(relativeTo: anchor.bounds, of: anchor)
        #expect(b.isShown && !a.isShown)
        b.close()
    }

    @Test func aPopoverOpenedFromInsideAnotherKeepsIt() {
        let (w, anchor) = host()
        defer { w.close() }
        let inner = NSControl(frame: NSRect(x: 5, y: 5, width: 40, height: 20))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        content.addSubview(inner)
        let outer = SQPopover(contentView: content)
        outer.show(relativeTo: anchor.bounds, of: anchor)
        let nested = popover()
        nested.show(relativeTo: inner.bounds, of: inner)
        #expect(outer.isShown && nested.isShown)
        nested.close(); outer.close()
    }

    @Test func anotherKeyWindowClosesTransientPopoversOnly() {
        let (w, anchor) = host()
        defer { w.close() }
        let other = NSWindow(contentRect: NSRect(x: 700, y: 200, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let sticky = popover()
        sticky.mode = .applicationDefined
        sticky.show(relativeTo: anchor.bounds, of: anchor)
        sticky.windowBecameKey(other)
        #expect(sticky.isShown)
        sticky.mode = .transient
        sticky.windowBecameKey(sticky.popoverWindow)       // its own window taking key is not "another window"
        #expect(sticky.isShown)
        sticky.windowBecameKey(other)
        #expect(!sticky.isShown)
    }

    @Test func parentResizeClosesThePopover() {
        let (w, anchor) = host()
        defer { w.close() }
        let p = popover()
        p.show(relativeTo: anchor.bounds, of: anchor)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: w)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the observer is queued on the main queue
        #expect(!p.isShown)
    }

    @Test func pressOnTheMenusOwnControlClosesAndIsSwallowed() {
        let (w, anchor) = host()
        defer { w.close(); SQMenuController.shared.dismiss() }
        let items = [SQMenuItem(title: "One", action: {}), SQMenuItem(title: "Two", action: {})]
        SQMenuController.shared.present(items: items, at: CGPoint(x: 600, y: 600), anchor: anchor)
        #expect(SQMenuController.shared.isOpen)
        let onAnchor = anchor.convert(NSPoint(x: 10, y: 5), to: nil)
        #expect(SQMenuController.shared.handle(press(in: w, at: onAnchor)) == nil)
        #expect(!SQMenuController.shared.isOpen)
        // A press elsewhere in the window closes the menu and still reaches its target.
        SQMenuController.shared.present(items: items, at: CGPoint(x: 600, y: 600), anchor: anchor)
        let elsewhere = press(in: w, at: NSPoint(x: 300, y: 40))
        #expect(SQMenuController.shared.handle(elsewhere) === elsewhere)
        #expect(!SQMenuController.shared.isOpen)
    }

    @Test func menuClosesWhenItsWindowResizesButNotWhenAPanelDoes() {
        let (w, _) = host()
        defer { w.close(); SQMenuController.shared.dismiss() }
        SQMenuController.shared.present(items: [SQMenuItem(title: "One", action: {})], at: CGPoint(x: 600, y: 600))
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(SQMenuController.shared.isOpen)
        // A hidden window (no menu over it, e.g. another suite's off-screen window) leaves the menu open.
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        hidden.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: hidden)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(SQMenuController.shared.isOpen)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: w)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!SQMenuController.shared.isOpen)
    }

    @Test func tooltipAndCommandGates() {
        #expect(SQTooltip.suppressed(menuOpen: true, modal: false, blockedBySheet: false))
        #expect(SQTooltip.suppressed(menuOpen: false, modal: true, blockedBySheet: false))
        #expect(SQTooltip.suppressed(menuOpen: false, modal: false, blockedBySheet: true))
        #expect(!SQTooltip.suppressed(menuOpen: false, modal: false, blockedBySheet: false))
        #expect(SQModalGate.blocksCommands(attachedSheet: true, appModal: false))
        #expect(SQModalGate.blocksCommands(attachedSheet: false, appModal: true))
        #expect(!SQModalGate.blocksCommands(attachedSheet: false, appModal: false))
    }
}
