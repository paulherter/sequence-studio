import AppKit
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQEditorUI
import SQUIKit

/// Floating panels on the shared UI (the design notes "floating panels"): the portable `ShellFloating` decides which panels
/// float and where; this file opens one borderless panel window per entry. Each window shows its rectangle of the one
/// canvas the editor frame draws (`DrawList.region`) and sends its mouse events moved to that rectangle, so the panel hosts
/// run unchanged. A floating window takes the keyboard like the AppKit panel does (`FloatingPanelWindow`: it becomes key, the
/// app activates when it is clicked): its view sends keys, IME text and shortcuts into the one controller, which routes them
/// by the panel focus as it does for the main window. Its content is a root view holding the window's view and, when a
/// monitor floats, the viewer under it.
@MainActor
final class SharedUIFloatingWindow: NSPanel {
    var onFrame: ((CGRect) -> Void)?
    /// The window became key (the owner moves the panel focus here, the AppKit `onActivate`).
    var onActivate: (() -> Void)?
    let uiView: SharedUIView
    let root: NSView
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(panel: PanelID, controller: SharedUIController, frame: CGRect) {
        uiView = SharedUIView(controller: controller, role: .floating(panel))
        root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        appearance = Theme.windowAppearance
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        root.wantsLayer = true
        if let layer = root.layer { Theme.Overlay.style(layer) }        // the rounding and hairline of every floating layer
        uiView.frame = root.bounds
        uiView.autoresizingMask = [.width, .height]
        root.addSubview(uiView)
        contentView = root
        setFrame(frame, display: false)
        initialFirstResponder = uiView
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(nc.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.onFrame?(self.frame) } }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Key and in front, with the keyboard on the view.
    func bringToFront() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(uiView)
    }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(uiView)
        onActivate?()
    }

    /// An unhandled Delete is swallowed silently like the other editor windows (`SQUnhandledKey`).
    override func keyDown(with event: NSEvent) {
        if SQUnhandledKey.isSilent(keyCode: event.keyCode) { return }
        super.keyDown(with: event)
    }
}

extension SharedUIController {
    /// Hooks the portable floating state to this host: the display list, the main window's frame, `floating-panels.json`.
    func wireFloating() {
        let f = shell.dock.floating
        f.screens = { NSScreen.screens.map(\.visibleFrame) }
        f.mainScreenFrame = { [weak self] in self?.window.map { $0.contentRect(forFrameRect: $0.frame) } }
        f.save = { s in do { try s.save() } catch { SQLog.error("floating panels save failed: \(error.localizedDescription)") } }
        f.raise = { [weak self] p in self?.floatingWindows[p]?.bringToFront() }
        if ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] == nil, !Self.floatProbeEnabled { f.load(FloatingPanelState.load()) }
        shell.dock.floatPanel = { [weak self] p in self?.shell.dock.floating.float(p) }
    }

    /// The editor frame: the whole canvas, then the main window's part of it; the floating windows show theirs from `canvasFrame`.
    func mainFrame(width: Int, height: Int) -> DrawList {
        let f = shell.dock.floating
        f.flush()
        if Self.floatProbeEnabled { floatingProbe() }
        var list = editorFrame(width: width, height: height)
        shell.menuBar.controller.regions = f.windows.map(\.rect)
        syncFloatingWindows()
        guard !f.windows.isEmpty else { canvasFrame = nil; return list }
        canvasFrame = list
        return list.region(DrawRect(x: 0, y: 0, w: Float(width), h: Float(height)))
    }

    /// The draw scale follows the displays of all windows (mixed DPI, the design notes "Floating panels in the shared app").
    func syncDrawScale() {
        let main = Float(window?.backingScaleFactor ?? 2)
        setScale(ShellFloating.drawScale(main: main, floating: floatingWindows.values.map { Float($0.backingScaleFactor) }))
        view?.markDirty()
    }

    /// Makes room right of the window for the floating rectangles (pixels).
    func extendForFloating(_ list: inout DrawList, scale: Float) {
        let e = shell.dock.floating.canvasExtent
        guard e.width > 0 else { return }
        list.extendCanvas(width: Float(e.width) * scale, height: Float(e.height) * scale)
    }

    /// One floating window's part of the last editor frame.
    func floatingFrame(_ p: PanelID, width: Int, height: Int) -> DrawList {
        let k = screen.theme.scale
        guard let full = canvasFrame, let w = shell.dock.floating.window(of: p) else { return DrawList(width: Float(width), height: Float(height)) }
        return full.region(DrawRect(x: Float(w.rect.minX) * k, y: Float(w.rect.minY) * k, w: Float(width), h: Float(height)))
    }

    /// The floating window whose rectangle holds `canvasRect`'s center, if any.
    func floatingWindow(containing canvasRect: CGRect) -> (SharedUIFloatingWindow, CGPoint)? {
        let c = CGPoint(x: canvasRect.midX, y: canvasRect.midY)
        guard let win = shell.dock.floating.windows.first(where: { $0.rect.contains(c) }), let w = floatingWindows[win.panel] else { return nil }
        return (w, win.rect.origin)
    }

    /// Where a floating window's view starts on the canvas, points.
    func floatingOrigin(_ p: PanelID) -> CGPoint { shell.dock.floating.window(of: p)?.rect.origin ?? .zero }

    /// Opens, closes and follows the OS windows so they match `ShellFloating.windows`.
    private func syncFloatingWindows() {
        let f = shell.dock.floating
        for (p, w) in floatingWindows where f.window(of: p) == nil {
            w.onFrame = nil
            w.onActivate = nil
            for clip in [viewerClip, sourceClip] where clip.superview === w.root { clip.removeFromSuperview() }     // the viewer is placed again
            w.orderOut(nil)
            w.close()
            floatingWindows[p] = nil
            syncDrawScale()
        }
        for win in f.windows where floatingWindows[win.panel] == nil {
            let w = SharedUIFloatingWindow(panel: win.panel, controller: self, frame: win.frame)
            let p = win.panel
            w.onFrame = { [weak self] frame in self?.shell.dock.floating.setFrame(frame, of: p); self?.view?.markDirty() }
            w.onActivate = { [weak self] in self?.shell.dock.focused = p; self?.view?.markDirty() }
            floatingWindows[p] = w
            syncDrawScale()
            // A panel the user just floated or asked for takes the keyboard; windows restored at launch stay behind the editor's focus.
            if shell.dock.focused == p { w.bringToFront() } else { w.orderFront(nil) }
        }
        // The shell moved or sized a window (Maximize Panel, a restored frame): follow; the user's own moves already agree.
        if f.revision != floatingRevision {
            floatingRevision = f.revision
            for win in f.windows { if let w = floatingWindows[win.panel], w.frame != win.frame { w.setFrame(win.frame, display: true) } }
        }
    }
}

extension SharedUIView {
    /// A press in a floating window: the title row drags the OS window, the corner grip resizes it. False = the press goes
    /// to the shell like any other (the Dock and Close buttons, the panel).
    func floatingMouseDown(_ e: NSEvent, _ panel: PanelID) -> Bool {
        let o = controller.floatingOrigin(panel)
        let q = convert(e.locationInWindow, from: nil)
        let p = CGPoint(x: q.x + o.x, y: q.y + o.y)
        let floating = controller.shell.dock.floating
        guard let win = window, let hit = floating.hit(at: p), !MacKeys.secondaryClick(flags: e.modifierFlags.rawValue) else { return false }
        switch hit {
        case .title:
            controller.shell.dock.focused = panel
            win.performDrag(with: e)
            return true
        case .grip:
            controller.shell.dock.focused = panel
            let start = NSEvent.mouseLocation, size = win.frame
            let m = floating.window(of: panel).map { _ in panel.minSize } ?? (width: 200, height: 120)
            while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
                let now = NSEvent.mouseLocation
                let w = max(size.width + now.x - start.x, CGFloat(m.width))
                let h = max(size.height - (now.y - start.y), CGFloat(m.height) + ShellFloating.titleBar)
                win.setFrame(CGRect(x: size.minX, y: size.maxY - h, width: w, height: h), display: true)
            }
            return true
        default:
            return false
        }
    }
}
