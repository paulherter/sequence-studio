import AppKit
import SQUIKit

/// A dock panel popped out into its own window (second display editing). Own SQ chrome, no system window frame:
/// 28 pt title bar (panel name, Dock and Close buttons), the panel view below, a resize grip in the bottom-right
/// corner. Same card look as `SQFloatingPanel` (overlay style, panel fill) but resizable. Moves and resizes are
/// reported through `onFrameChange` so the owner can remember them per workspace.
@MainActor
public final class FloatingPanelWindow {
    public let panel: PanelID
    public let content: NSView
    /// Dock button: the panel goes back to its place in the layout.
    public var onDock: (() -> Void)?
    /// Close button: the panel is hidden like "Close Panel" in the tab menu.
    public var onClose: (() -> Void)?
    public var onFrameChange: ((CGRect) -> Void)?
    /// Window gained key status (the owner moves keyboard focus to this panel).
    public var onActivate: (() -> Void)?
    public private(set) var window: NSWindow?

    private let card: FloatingPanelCardView
    private var observers: [NSObjectProtocol] = []

    public init(panel: PanelID, title: String, content: NSView) {
        self.panel = panel; self.content = content
        card = FloatingPanelCardView(title: title, content: content)
        card.onDock = { [weak self] in self?.onDock?() }
        card.onClose = { [weak self] in self?.onClose?() }
    }

    public static func minSize(for panel: PanelID) -> NSSize {
        NSSize(width: panel.minSize.width, height: panel.minSize.height + SQFloatingPanel.titleBarHeight)
    }

    public func show(frame: CGRect) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = FloatingPanelNSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.appearance = Theme.windowAppearance
        w.level = .floating
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.minSize = Self.minSize(for: panel)
        w.contentView = card
        w.onEscape = { [weak self] in self?.onDock?() }
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let f = self?.window?.frame { self?.onFrameChange?(f) } }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActivate?() }
        })
        window = w
        card.window?.makeFirstResponder(content)
        w.makeKeyAndOrderFront(nil)
    }

    /// Takes the panel view away (the dock owns it again) and closes the window without reporting a frame.
    public func close() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        card.releaseContent()
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
    }

    private var unzoomedFrame: CGRect?
    public var isZoomed: Bool { unzoomedFrame != nil }

    /// Fills the visible area of the window's screen; a second call restores the frame from before.
    public func toggleZoom() {
        guard let w = window else { return }
        if let back = unzoomedFrame {
            unzoomedFrame = nil
            w.setFrame(back, display: true, animate: false)
        } else if let visible = (w.screen ?? NSScreen.main)?.visibleFrame {
            unzoomedFrame = w.frame
            w.setFrame(visible, display: true, animate: false)
        }
    }

    public func bringToFront() { window?.makeKeyAndOrderFront(nil) }
}

private final class FloatingPanelNSWindow: SQEditorPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Card: overlay look, title bar on top, panel view below, resize grip over the bottom-right corner.
private final class FloatingPanelCardView: NSView {
    var onDock: (() -> Void)?
    var onClose: (() -> Void)?
    private let titleBar: FloatingPanelTitleBar
    private let grip = FloatingPanelResizeGrip()
    private var content: NSView?

    override var isFlipped: Bool { true }

    init(title: String, content: NSView) {
        titleBar = FloatingPanelTitleBar(title: title)
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        Theme.Overlay.style(layer)
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        addSubview(content); addSubview(titleBar); addSubview(grip)
        titleBar.onDock = { [weak self] in self?.onDock?() }
        titleBar.onClose = { [weak self] in self?.onClose?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func releaseContent() {
        if content?.superview === self { content?.removeFromSuperview() }
        content = nil
    }

    override func layout() {
        super.layout()
        let h = SQFloatingPanel.titleBarHeight
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        content?.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
        let g = FloatingPanelResizeGrip.size
        grip.frame = NSRect(x: bounds.width - g, y: bounds.height - g, width: g, height: g)
    }
}

private final class FloatingPanelTitleBar: NSView {
    var onDock: (() -> Void)?
    var onClose: (() -> Void)?
    private let titleLabel: NSTextField
    private var dockButton: IconButton!
    private var closeButton: IconButton!

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(title: String) {
        titleLabel = makeLabel(title, font: Theme.Typography.bodyStrong, color: Theme.Colors.label)
        super.init(frame: .zero)
        dockButton = IconButton(symbol: .minimize, label: "Dock Panel") { [weak self] in self?.onDock?() }
        closeButton = IconButton(symbol: .close, label: "Close Panel") { [weak self] in self?.onClose?() }
        addSubview(titleLabel); addSubview(dockButton); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds, s = Theme.Metrics.pushButton, pad = Theme.Spacing.md
        closeButton.frame = NSRect(x: b.width - pad / 2 - s, y: (b.height - s) / 2, width: s, height: s)
        dockButton.frame = NSRect(x: closeButton.frame.minX - s, y: (b.height - s) / 2, width: s, height: s)
        titleLabel.frame = NSRect(x: pad, y: (b.height - 14) / 2, width: max(dockButton.frame.minX - pad - Theme.Spacing.sm, 0), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titlebar.setFill(); bounds.fill()
        Theme.Colors.divider.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Invisible corner handle: drag to resize (a borderless window has no system resize edges).
private final class FloatingPanelResizeGrip: NSView {
    static let size = Theme.Spacing.lg
    private var start: (mouse: NSPoint, frame: NSRect)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        start = (NSEvent.mouseLocation, w.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let s = start else { return }
        let m = NSEvent.mouseLocation
        let minS = w.minSize
        let width = max(s.frame.width + (m.x - s.mouse.x), minS.width)
        let height = max(s.frame.height - (m.y - s.mouse.y), minS.height)
        // Top-left stays put: y grows upward on screen.
        w.setFrame(NSRect(x: s.frame.minX, y: s.frame.maxY - height, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) { start = nil }
}
