import AppKit

/// Remembers where each floating panel was left, per session (not persisted). Keyed by a panel id such as the effect id.
@MainActor
public final class SQFloatingPanelMemory {
    public static let shared = SQFloatingPanelMemory()
    private var origins: [String: NSPoint] = [:]
    public init() {}
    public func origin(for key: String) -> NSPoint? { origins[key] }
    public func remember(_ origin: NSPoint, for key: String) { origins[key] = origin }
    public func forget(_ key: String) { origins[key] = nil }
}

/// Own-design floating window: a 28 pt title bar (title, optional subtitle, close button) over a content view. Drag by the
/// title bar, stays above the editor (floating level) without blocking it, stays open while the playhead moves, Esc or the
/// close button closes it. Fixed size. Position is remembered per `key` for the session (`SQFloatingPanelMemory`).
/// No system window chrome, no vibrancy: Theme tokens only.
@MainActor
public final class SQFloatingPanel {
    public static let titleBarHeight: CGFloat = 28

    public private(set) var isShown = false
    public var onClose: (() -> Void)?
    public let key: String
    public let content: NSView
    public var title: String { didSet { titleBar.title = title } }
    public var subtitle: String { didSet { titleBar.subtitle = subtitle } }
    public var memory: SQFloatingPanelMemory = .shared
    public var window: NSWindow? { panel }

    private let titleBar: SQFloatingTitleBar
    private let frameView: SQFloatingFrameView
    private var panel: SQFloatingWindow?
    private var moveObserver: NSObjectProtocol?

    public init(key: String, title: String, subtitle: String = "", content: NSView) {
        self.key = key; self.title = title; self.subtitle = subtitle; self.content = content
        titleBar = SQFloatingTitleBar(title: title, subtitle: subtitle)
        let size = NSSize(width: content.frame.width, height: content.frame.height + Self.titleBarHeight)
        frameView = SQFloatingFrameView(frame: NSRect(origin: .zero, size: size))
        frameView.addSubview(titleBar); frameView.addSubview(content)
        frameView.titleBar = titleBar; frameView.content = content
        titleBar.onClose = { [weak self] in self?.close() }
    }

    public var size: NSSize { frameView.frame.size }

    /// Resizes the content to `height` (title bar excluded). The top edge stays where it is.
    public func setContentHeight(_ height: CGFloat) {
        let total = height + Self.titleBarHeight
        guard abs(total - frameView.frame.height) > 0.5 else { return }
        if let panel {
            var f = panel.frame
            f.origin.y += f.height - total
            f.size.height = total
            panel.setFrame(f, display: true)
        } else {
            frameView.setFrameSize(NSSize(width: frameView.frame.width, height: total))
        }
    }
    /// The card (title bar and content) as one view, for offscreen rendering (`scripts/render-panels.sh`).
    public var renderedView: NSView { frameView }

    /// Shows the panel at its remembered origin, else near `anchor` (screen coordinates: left of it, top aligned).
    public func show(near anchor: NSRect?, in screen: NSScreen? = nil) {
        if let panel, isShown { panel.makeKeyAndOrderFront(nil); return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        var origin = memory.origin(for: key) ?? Self.defaultOrigin(size: size, anchor: anchor, visible: visible)
        origin = Self.clamp(origin, size: size, visible: visible)
        let w = SQFloatingWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.appearance = Theme.windowAppearance
        w.level = .floating
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // The OS can grow a borderless window by 1 pt at init; pin the frame to the card size.
        w.setFrame(NSRect(origin: origin, size: size), display: false)
        w.contentView = frameView
        w.onEscape = { [weak self] in self?.close() }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remember() }
        }
        panel = w; isShown = true
        w.makeKeyAndOrderFront(nil)
    }

    private func remember() { if let f = panel?.frame { memory.remember(f.origin, for: key) } }

    public func close() {
        guard isShown else { return }
        remember()
        isShown = false
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
        onClose?()
    }

    static func defaultOrigin(size: NSSize, anchor: NSRect?, visible: NSRect) -> NSPoint {
        guard let a = anchor else { return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2) }
        let x = a.minX - size.width - Theme.Spacing.md
        return NSPoint(x: x >= visible.minX ? x : a.maxX + Theme.Spacing.md, y: a.maxY - size.height)
    }

    /// Keeps at least the title bar on screen.
    static func clamp(_ o: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        NSPoint(x: min(max(o.x, visible.minX - size.width + 80), visible.maxX - 80),
                y: min(max(o.y, visible.minY), visible.maxY - size.height))
    }
}

private final class SQFloatingWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Card: overlay look (opaque, radius 8, hairline); title bar on top, content below.
private final class SQFloatingFrameView: NSView {
    var titleBar: NSView?
    var content: NSView?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        Theme.Overlay.style(layer)
        layer?.backgroundColor = Theme.Colors.panel.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let h = SQFloatingPanel.titleBarHeight
        titleBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        content?.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
    }
}

private final class SQFloatingTitleBar: NSView {
    var onClose: (() -> Void)?
    var title: String { didSet { titleLabel.stringValue = title } }
    var subtitle: String { didSet { subtitleLabel.stringValue = subtitle } }
    private let titleLabel = makeLabel("", font: Theme.Typography.bodyStrong, color: Theme.Colors.label)
    private let subtitleLabel = makeLabel("", font: Theme.Typography.body, color: Theme.Colors.label3)
    private var closeButton: IconButton!

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(title: String, subtitle: String) {
        self.title = title; self.subtitle = subtitle
        super.init(frame: .zero)
        titleLabel.stringValue = title; subtitleLabel.stringValue = subtitle
        closeButton = IconButton(symbol: .close, label: "Close") { [weak self] in self?.onClose?() }
        addSubview(titleLabel); addSubview(subtitleLabel); addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds, s = Theme.Metrics.pushButton, pad = Theme.Spacing.md
        closeButton.frame = NSRect(x: b.width - pad / 2 - s, y: (b.height - s) / 2, width: s, height: s)
        let tw = min(ceil((title as NSString).size(withAttributes: [.font: Theme.Typography.bodyStrong]).width) + 10, max(b.width - 2 * pad - s, 0))
        titleLabel.frame = NSRect(x: pad, y: (b.height - 14) / 2, width: tw, height: 14)
        let sx = titleLabel.frame.maxX + Theme.Spacing.sm
        subtitleLabel.frame = NSRect(x: sx, y: (b.height - 14) / 2, width: max(closeButton.frame.minX - sx - Theme.Spacing.sm, 0), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titlebar.setFill(); bounds.fill()
        Theme.Colors.divider.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
