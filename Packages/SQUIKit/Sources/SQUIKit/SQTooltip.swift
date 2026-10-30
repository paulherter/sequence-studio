import AppKit
import ObjectiveC

/// Pure placement and sizing (design B `.tip`: 12 pt, padding 8 x 12, radius 8, overlay fill, 0.5 edge).
public enum SQTooltipLayout {
    /// Seconds to wait before showing a tip. `lastExit`: when the previous tip closed by the pointer leaving its button
    /// (nil if none did, or it closed by click, key or scroll); `shownNow`: a tip is on screen already.
    public static func showDelay(now: TimeInterval, lastExit: TimeInterval?, shownNow: Bool = false) -> TimeInterval {
        if shownNow { return 0 }
        if let lastExit, now - lastExit >= 0, now - lastExit <= handOverWindow { return 0 }
        return delay
    }

    public static let padding = NSSize(width: 12, height: 8)
    public static let radius: CGFloat = Theme.Sheet.buttonRadius   // design B `.tip`: 8
    /// Wait before the first tip (Premiere-like, about a second; the system tip took 2 to 3 s).
    public static let delay: TimeInterval = 0.8
    /// A tip that closed by leaving its button this recently hands over: the neighbor shows at once.
    public static let handOverWindow: TimeInterval = 0.5
    /// Offset of the tip's top-left from the pointer.
    public static let pointerOffset = NSSize(width: 10, height: 18)
    public static let screenMargin: CGFloat = 4

    public static func size(forText text: NSSize) -> NSSize {
        NSSize(width: ceil(text.width) + padding.width * 2, height: ceil(text.height) + padding.height * 2)
    }

    /// "Snap (N)" -> ("Snap", "N"): the key shows as a keycap chip (sq.css `.kc`). Texts without a trailing "(key)" stay whole.
    public static func split(_ text: String) -> (name: String, key: String?) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, nil) }
        let key = String(text[open.upperBound...].dropLast())
        guard !key.isEmpty, key.count <= 12, !key.contains("(") else { return (text, nil) }
        return (String(text[..<open.lowerBound]), key)
    }
    /// sq.css `.kc`: min width 14, height 14, padding 0 3, radius 3, 10 pt; gap to the name 4.
    public static let chipHeight: CGFloat = 14
    public static let chipMinWidth: CGFloat = 14
    public static let chipPadding: CGFloat = 3
    public static let chipRadius: CGFloat = 3
    public static let chipGap: CGFloat = 4

    /// Frame (screen coordinates, y up) below-right of `pointer`, flipped/clamped to stay inside `screen`.
    public static func frame(size: NSSize, pointer: NSPoint, screen: NSRect) -> NSRect {
        var x = pointer.x + pointerOffset.width
        var y = pointer.y - pointerOffset.height - size.height
        if x + size.width > screen.maxX - screenMargin { x = pointer.x - pointerOffset.width - size.width }
        if y < screen.minY + screenMargin { y = pointer.y + pointerOffset.height }
        x = min(max(x, screen.minX + screenMargin), max(screen.maxX - screenMargin - size.width, screen.minX))
        y = min(max(y, screen.minY + screenMargin), max(screen.maxY - screenMargin - size.height, screen.minY))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

final class SQTooltipContent: NSView {
    private(set) var name = ""
    private(set) var key: String?
    private var attrs: [NSAttributedString.Key: Any] { [.font: Theme.Menu.font, .foregroundColor: Theme.Colors.label2] }

    override var isFlipped: Bool { false }

    func set(text: String) {
        (name, key) = SQTooltipLayout.split(text)
        needsDisplay = true
    }

    /// Content size for `text` (name, then an optional keycap chip).
    static func size(for text: String) -> NSSize {
        let (n, k) = SQTooltipLayout.split(text)
        let font = [NSAttributedString.Key.font: Theme.Menu.font]
        var ts = (n as NSString).size(withAttributes: font)
        if let k {
            let kw = max(SQTooltipLayout.chipMinWidth, ceil((k as NSString).size(withAttributes: [.font: Theme.Typography.caption]).width) + SQTooltipLayout.chipPadding * 2)
            ts.width = ceil(ts.width) + SQTooltipLayout.chipGap + kw
            ts.height = max(ts.height, SQTooltipLayout.chipHeight - SQTooltipLayout.padding.height)
        }
        return SQTooltipLayout.size(forText: ts)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: SQTooltipLayout.radius, yRadius: SQTooltipLayout.radius)
        Theme.Colors.overlay.setFill()
        p.fill()
        Theme.Colors.tooltipEdge.setStroke()
        p.lineWidth = 0.5
        p.stroke()
        let ns = name as NSString
        let nsize = ns.size(withAttributes: attrs)
        ns.draw(at: NSPoint(x: SQTooltipLayout.padding.width, y: ((bounds.height - nsize.height) / 2).rounded()), withAttributes: attrs)
        guard let key else { return }
        let font = [NSAttributedString.Key.font: Theme.Typography.caption]
        let ksize = (key as NSString).size(withAttributes: font)
        let kw = max(SQTooltipLayout.chipMinWidth, ceil(ksize.width) + SQTooltipLayout.chipPadding * 2)
        let chip = NSRect(x: SQTooltipLayout.padding.width + ceil(nsize.width) + SQTooltipLayout.chipGap,
                          y: ((bounds.height - SQTooltipLayout.chipHeight) / 2).rounded(), width: kw, height: SQTooltipLayout.chipHeight)
        let cp = NSBezierPath(roundedRect: chip, xRadius: SQTooltipLayout.chipRadius, yRadius: SQTooltipLayout.chipRadius)
        Theme.Colors.fill2.setFill()
        cp.fill()
        Theme.Colors.fieldEdge.setStroke()
        let ring = NSBezierPath(roundedRect: chip.insetBy(dx: 0.25, dy: 0.25), xRadius: SQTooltipLayout.chipRadius, yRadius: SQTooltipLayout.chipRadius)
        ring.lineWidth = 0.5
        ring.stroke()
        (key as NSString).draw(at: NSPoint(x: chip.midX - ksize.width / 2, y: chip.midY - ksize.height / 2), withAttributes: font)
    }
}

/// Own tooltip. `view.sqToolTip = "..."` replaces `toolTip =` one to one. Shown after `SQTooltipLayout.delay` near the pointer,
/// hidden on exit, click, key or scroll. Never two at once.
@MainActor
public final class SQTooltip {
    public static let shared = SQTooltip()

    private var panel: NSPanel?
    private let content = SQTooltipContent(frame: .zero)
    private var timer: Timer?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var watchTimer: Timer?
    private weak var shownAnchor: NSView?
    public private(set) var currentText: String?
    /// Uptime when the last shown tip closed because the pointer left its button; cleared by every other hide.
    private var lastExit: TimeInterval?
    public var isShown: Bool { panel?.isVisible ?? false }

    /// `attach(to:text:)` with an empty text removes the tooltip.
    public static func attach(to view: NSView, text: String) {
        let existing = view.sqTooltipTracker
        if text.isEmpty {
            existing?.detach()
            view.sqTooltipTracker = nil
            return
        }
        if let existing {
            if existing.text != text { existing.text = text; if SQTooltip.shared.isShown { SQTooltip.shared.hide() } }
            existing.ensureArea()
            return
        }
        view.sqTooltipTracker = SQTooltipTracker(view: view, text: text)
    }

    /// `anchor`: the view the tip belongs to; if it left its window or was hidden before the delay ran out, nothing shows.
    func schedule(text: String, anchor: NSView? = nil) {
        let wait = SQTooltipLayout.showDelay(now: ProcessInfo.processInfo.systemUptime, lastExit: lastExit, shownNow: isShown)
        hide()
        guard !Self.isSuppressed(anchorWindow: anchor?.window) else { return }
        if wait == 0 { show(text: text, anchor: anchor); return }
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self, weak anchor] _ in
            MainActor.assumeIsolated {
                if let a = anchor, a.window == nil || a.isHiddenOrHasHiddenAncestor || Self.isSuppressed(anchorWindow: a.window) { self?.hide(); return }
                self?.show(text: text, anchor: anchor)
            }
        }
        installMonitor()
    }

    /// No tip over a window that is blocked (an app-modal dialog or a sheet is up) or while an SQ menu is open.
    static func isSuppressed(anchorWindow: NSWindow?) -> Bool {
        suppressed(menuOpen: SQMenuController.shared.isOpen, modal: NSApp.modalWindow != nil, blockedBySheet: anchorWindow?.sqAttachedSheet != nil)
    }

    nonisolated static func suppressed(menuOpen: Bool, modal: Bool, blockedBySheet: Bool) -> Bool { menuOpen || modal || blockedBySheet }

    public func show(text: String, anchor: NSView? = nil) {
        timer?.invalidate(); timer = nil
        shownAnchor = anchor
        let size = SQTooltipContent.size(for: text)
        let pointer = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = SQTooltipLayout.frame(size: size, pointer: pointer, screen: screen)
        let p = panel ?? makePanel()
        panel = p
        content.frame = NSRect(origin: .zero, size: size)
        content.set(text: text)
        content.needsDisplay = true
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        currentText = text
        installMonitor()
        startWatching()
    }

    /// Hides a shown tip whose anchor was hidden, left its window or whose window closed or hid: no mouseExited comes then.
    func validateAnchor() {
        guard isShown, let a = shownAnchor else { return }
        if a.window == nil || a.isHiddenOrHasHiddenAncestor || a.window?.isVisible == false || a.window?.isMiniaturized == true { hide() }
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validateAnchor() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            let closing = n.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let w = closing, self.shownAnchor?.window === w else { return }
                self.hide()
            }
        }
    }

    /// `byExit`: the pointer left the button; a neighbor entered soon after shows its tip at once.
    public func hide(byExit: Bool = false) {
        lastExit = byExit && isShown ? ProcessInfo.processInfo.systemUptime : nil
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        currentText = nil
        shownAnchor = nil
        watchTimer?.invalidate(); watchTimer = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // board `.tip`: no outer shadow, only the 0.5 edge
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.contentView = content
        return p
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.hide() }
            return e
        }
    }
}

/// Owns the tracking area of one attached view. Retained by the view (associated object).
@MainActor
final class SQTooltipTracker: NSResponder {
    weak var view: NSView?
    var text: String
    private var area: NSTrackingArea?

    init(view: NSView, text: String) {
        self.view = view
        self.text = text
        super.init()
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        view.addTrackingArea(a)
        area = a
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Re-adds the area if the host view dropped it (a `trackingAreas.forEach(removeTrackingArea)` in its `updateTrackingAreas`).
    func ensureArea() {
        guard let view, let area, !view.trackingAreas.contains(where: { $0 === area }) else { return }
        view.addTrackingArea(area)
    }
    func detach() {
        if let a = area { view?.removeTrackingArea(a) }
        area = nil
        SQTooltip.shared.hide()
    }
    override func mouseEntered(with event: NSEvent) { SQTooltip.shared.schedule(text: text, anchor: view) }
    override func mouseMoved(with event: NSEvent) {
        // A shown tip stays until exit or click; while pending, movement restarts the delay.
        if !SQTooltip.shared.isShown { SQTooltip.shared.schedule(text: text, anchor: view) }
    }
    override func mouseExited(with event: NSEvent) { SQTooltip.shared.hide(byExit: true) }
}

nonisolated(unsafe) private var sqTooltipKey: UInt8 = 0

extension NSView {
    /// For a host's `updateTrackingAreas`: removes the view's own tracking areas but keeps the one of its SQ tooltip.
    @MainActor public func removeOwnTrackingAreas() {
        let keep = sqTooltipTracker
        for a in trackingAreas where a.owner !== keep || keep == nil { removeTrackingArea(a) }
    }

    /// Re-adds the tooltip's area when a host removed it. Called by `SQTooltipHost`-style views after their own relayout.
    @MainActor public func restoreSQTooltipArea() { sqTooltipTracker?.ensureArea() }

    fileprivate var sqTooltipTracker: SQTooltipTracker? {
        get { objc_getAssociatedObject(self, &sqTooltipKey) as? SQTooltipTracker }
        set { objc_setAssociatedObject(self, &sqTooltipKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Drop-in for `toolTip`: own tooltip window instead of the system one.
    @MainActor public var sqToolTip: String? {
        get { sqTooltipTracker?.text }
        set { SQTooltip.attach(to: self, text: newValue.map { SQL10n.string($0) } ?? "") }
    }
}
