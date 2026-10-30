import AppKit
import SwiftUI

/// SQ tooltip and SQ context menu for SwiftUI views (instead of `.help` and `.contextMenu`, which would show system UI).
private final class SQAnchorView: NSView {
    var menuItems: (() -> [SQMenuItem])?
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only a right-click (or Ctrl-click) lands here; everything else falls through to the SwiftUI view below.
        guard menuItems != nil, let e = NSApp.currentEvent else { return nil }
        let isMenuClick = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        return isMenuClick ? super.hitTest(point) : nil
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    override func mouseDown(with event: NSEvent) { showMenu(event) }
    private func showMenu(_ event: NSEvent) {
        guard let items = menuItems?(), !items.isEmpty else { return }
        let p = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        SQMenuController.shared.present(items: items, at: p)
    }
}

private struct SQAnchor: NSViewRepresentable {
    var tip: String?
    var menu: (() -> [SQMenuItem])?
    func makeNSView(context: Context) -> NSView { SQAnchorView() }
    func updateNSView(_ v: NSView, context: Context) {
        guard let v = v as? SQAnchorView else { return }
        v.menuItems = menu
        v.sqToolTip = tip
    }
}

public extension View {
    /// Own tooltip window (never the system tooltip).
    func sqHelp(_ text: String) -> some View { overlay(SQAnchor(tip: text, menu: nil)) }
    /// Own context menu for a right-click (never the system menu).
    func sqContextMenu(_ items: @escaping () -> [SQMenuItem]) -> some View { overlay(SQAnchor(tip: nil, menu: items)) }
}
