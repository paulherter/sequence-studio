import AppKit
import SQEditorUI

/// What a tab drag ended in.
enum DockDragResult {
    case click
    case cancelled
    case reorder(PanelID, toIndex: Int)
    case dock(PanelID, onto: PanelID, zone: DropZone)
    /// Released outside the window (screen point): the panel pops out into its own window there.
    case tearOff(PanelID, screenPoint: CGPoint)
}

/// Premiere-style drag of a panel tab. Runs its own tracking loop from the tab's `mouseDown`: below a 4 pt
/// movement it is a plain click; beyond that a translucent copy of the capsule follows the pointer and an overlay
/// over the panel under the pointer shows the five drop zones (center = add as tab, edge band = split). Dropping on
/// a tab strip adds/reorders tabs. Esc or releasing outside every panel cancels. Geometry comes from `DropZone`
/// and `TabReorder` in SQEditorUI.
@MainActor
enum DockDragSession {
    static let threshold: CGFloat = 4

    static func run(panel: PanelID, button: NSView, event: NSEvent, host: WorkspaceHostView) -> DockDragResult {
        guard let window = button.window else { return .click }
        let startPoint = event.locationInWindow
        var dragging = false
        var ghost: NSWindow?
        let overlay = DockOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        var result = DockDragResult.cancelled
        defer {
            ghost?.orderOut(nil)
            overlay.removeFromSuperview()
            NSCursor.arrow.set()
        }

        loop: while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch e.type {
            case .keyDown:
                if e.keyCode == 53 { result = .cancelled; break loop }
            case .leftMouseDragged:
                let p = e.locationInWindow
                if !dragging {
                    guard hypot(p.x - startPoint.x, p.y - startPoint.y) >= threshold else { continue }
                    dragging = true
                    ghost = makeGhost(of: button)
                    host.addSubview(overlay)
                }
                moveGhost(ghost, to: p, in: window)
                overlay.state = hitTest(host.convert(p, from: nil), panel: panel, host: host)
            case .leftMouseUp:
                if !dragging { result = .click; break loop }
                let screen = window.convertPoint(toScreen: e.locationInWindow)
                if PanelID.dockable.contains(panel), !RenderPanels.isRequested,
                   FloatingPanelState.isTornOff(screen, window: window.frame) {
                    result = .tearOff(panel, screenPoint: screen)
                    break loop
                }
                result = outcome(of: hitTest(host.convert(e.locationInWindow, from: nil), panel: panel, host: host), panel: panel)
                break loop
            default: break
            }
        }
        return result
    }

    // MARK: Hit testing

    private static func hitTest(_ p: CGPoint, panel: PanelID, host: WorkspaceHostView) -> DockOverlayView.State {
        for c in host.containers() {
            let rect = host.convert(c.bounds, from: c)
            guard rect.contains(p) else { continue }
            let own = c.panels.contains(panel)
            if p.y < rect.minY + TabStrip.height {
                // Tab strip: reorder inside the own group, otherwise join as a tab.
                let frames = c.strip.tabFrames.map { host.convert($0, from: c.strip) }
                if own, let cur = c.panels.firstIndex(of: panel) {
                    let to = TabReorder.finalIndex(current: cur, x: Double(p.x), midXs: frames.map { Double($0.midX) })
                    let slot = frames.filter { $0.midX < p.x }.count
                    let lineX = slot < frames.count ? frames[slot].minX - 2 : (frames.last?.maxX ?? rect.minX) + 2
                    return .init(container: rect, zone: nil, insertionX: lineX, stripRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: TabStrip.height),
                                 action: .reorder(panel, to))
                }
                guard let anchor = Workspace.dockAnchor(group: c.panels, selected: c.selected, dragging: panel) else { return .none }
                return .init(container: rect, zone: .center, insertionX: nil, stripRect: nil, action: .dock(panel, anchor, .center), stripHighlight: true)
            }
            guard let zone = DropZone.zone(for: (Double(p.x), Double(p.y)), in: (Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))),
                  let anchor = Workspace.dockAnchor(group: c.panels, selected: c.selected, dragging: panel) else {
                return .init(container: rect, zone: nil, insertionX: nil, stripRect: nil, action: nil)
            }
            // Dropping a lone panel back onto its own group does nothing.
            if own, zone == .center { return .init(container: rect, zone: nil, insertionX: nil, stripRect: nil, action: nil) }
            return .init(container: rect, zone: zone, insertionX: nil, stripRect: nil, action: .dock(panel, anchor, zone))
        }
        return .none
    }

    private static func outcome(of s: DockOverlayView.State, panel: PanelID) -> DockDragResult {
        switch s.action {
        case .reorder(let p, let i)?: return .reorder(p, toIndex: i)
        case .dock(let p, let a, let z)?: return .dock(p, onto: a, zone: z)
        case nil: return .cancelled
        }
    }

    // MARK: Drag image

    private static func makeGhost(of button: NSView) -> NSWindow {
        let size = button.bounds.size
        let image = NSImage(size: size)
        if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: rep)
            image.addRepresentation(rep)
        }
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.level = .floating
        w.alphaValue = 0.85
        let iv = NSImageView(frame: CGRect(origin: .zero, size: size))
        iv.image = image
        w.contentView = iv
        w.orderFront(nil)
        return w
    }

    private static func moveGhost(_ ghost: NSWindow?, to p: CGPoint, in window: NSWindow) {
        guard let ghost else { return }
        let s = window.convertPoint(toScreen: p)
        ghost.setFrameOrigin(CGPoint(x: s.x - ghost.frame.width / 2, y: s.y - ghost.frame.height / 2))
    }
}

/// The translucent layer over the window content while a tab is dragged. Never takes mouse events.
@MainActor
final class DockOverlayView: NSView {
    struct State {
        enum Action { case reorder(PanelID, Int), dock(PanelID, PanelID, DropZone) }
        var container: CGRect?
        var zone: DropZone?
        var insertionX: CGFloat?
        var stripRect: CGRect?
        var action: Action?
        var stripHighlight = false

        static let none = State(container: nil, zone: nil, insertionX: nil, stripRect: nil, action: nil)
    }

    var state = State.none { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = state.container else { return }
        NSColor.black.withAlphaComponent(0.28).setFill()
        c.fill()
        let box = (Double(c.minX), Double(c.minY), Double(c.width), Double(c.height))
        for z in DropZone.allCases where z != state.zone {
            let h = DropZone.highlightRect(z, in: box)
            let r = CGRect(x: h.x, y: h.y, width: h.width, height: h.height).insetBy(dx: 2, dy: 2)
            Theme.Colors.accentTint.withAlphaComponent(0.10).setFill()
            r.fill()
            Theme.Colors.accentRing.withAlphaComponent(0.35).setStroke()
            NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).stroke()
        }
        if let z = state.zone {
            let h = DropZone.highlightRect(z, in: box)
            let r = CGRect(x: h.x, y: h.y, width: h.width, height: h.height).insetBy(dx: 2, dy: 2)
            Theme.Colors.accentTint.withAlphaComponent(0.55).setFill()
            r.fill()
            Theme.Colors.accent.setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            path.lineWidth = 2
            path.stroke()
        }
        if state.stripHighlight {
            Theme.Colors.accentTint.withAlphaComponent(0.55).setFill()
            CGRect(x: c.minX, y: c.minY, width: c.width, height: TabStrip.height).fill()
        }
        if let x = state.insertionX, let s = state.stripRect {
            Theme.Colors.accent.setFill()
            CGRect(x: x - 1, y: s.minY + 3, width: 2, height: s.height - 6).fill()
        }
    }
}
