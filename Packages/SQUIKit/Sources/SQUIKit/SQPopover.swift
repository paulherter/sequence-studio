import AppKit

/// Pure placement and dismiss rules of `SQPopover` (screen coordinates, origin bottom-left).
public enum SQPopoverLogic {
    public enum Side: Sendable {
        case above, below, left, right
        var opposite: Side {
            switch self { case .above: .below; case .below: .above; case .left: .right; case .right: .left }
        }
    }
    public enum Mode: Sendable {
        /// Closes on any outside click (in or outside the app), Esc, and when the app deactivates.
        case transient
        /// Closes on outside clicks inside the app and Esc, survives app deactivation.
        case semiTransient
        /// Closes only through `close()` (and Esc).
        case applicationDefined
    }
    public enum Trigger: Sendable { case clickInside, clickOutsideInApp, clickOutsideOtherApp, escape, appDeactivated }

    public static func shouldDismiss(_ mode: Mode, _ trigger: Trigger) -> Bool {
        switch trigger {
        case .escape: return true
        case .clickInside: return false
        case .clickOutsideInApp: return mode != .applicationDefined
        case .clickOutsideOtherApp: return mode == .transient
        case .appDeactivated: return mode == .transient
        }
    }

    /// True when `window` is the popover window itself or one of its descendants (a nested popover or picker
    /// window opened from inside it): clicks there are not "outside". A menu panel counts as inside too: while a
    /// popover is open a menu can only have been opened from it (any other press would have closed the popover first),
    /// and picking an item must not close the popover under it.
    @MainActor
    public static func isInside(_ window: NSWindow?, popover: NSWindow) -> Bool {
        var w = window
        while let cur = w {
            if cur === popover || cur is SQMenuPanel { return true }
            w = cur.parent ?? cur.sheetParent
        }
        return false
    }

    /// Frame of a popover of `size` next to `anchor`. Flips to the opposite side when the preferred one does not fit,
    /// then clamps into `visible` (inset by `margin`) and centers on the anchor along the cross axis.
    public static func frame(size: CGSize, anchor: CGRect, side: Side, visible: CGRect,
                             gap: CGFloat = 4, margin: CGFloat = 6) -> (frame: CGRect, side: Side) {
        let area = visible.insetBy(dx: margin, dy: margin)
        func origin(_ s: Side) -> CGPoint {
            switch s {
            case .below: CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
            case .above: CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
            case .left: CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
            case .right: CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
            }
        }
        func fits(_ s: Side) -> Bool {
            let r = CGRect(origin: origin(s), size: size)
            switch s {
            case .below: return r.minY >= area.minY
            case .above: return r.maxY <= area.maxY
            case .left: return r.minX >= area.minX
            case .right: return r.maxX <= area.maxX
            }
        }
        let chosen = fits(side) ? side : (fits(side.opposite) ? side.opposite : side)
        var o = origin(chosen)
        o.x = max(area.minX, min(o.x, area.maxX - size.width))
        o.y = max(area.minY, min(o.y, area.maxY - size.height))
        return (CGRect(origin: o, size: size), chosen)
    }
}

private final class SQPopoverWindow: NSPanel {
    override var worksWhenModal: Bool { get { true } set {} }
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Flat rounded frame behind the content: opaque panel color, hairline border, no arrow, no vibrancy.
private final class SQPopoverFrameView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        Theme.Overlay.style(layer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Own anchored popover (replaces NSPopover): borderless child window, flat styling, outside-click and Esc dismiss.
/// The window becomes key, so text fields inside keep normal keyboard focus.
@MainActor
public final class SQPopover {
    public var mode: SQPopoverLogic.Mode = .transient
    public var onClose: (() -> Void)?
    public private(set) var isShown = false
    public var contentView: NSView
    /// Content padding inside the frame.
    public var inset: CGFloat = 0

    private var window: SQPopoverWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    /// Every shown popover (weak): one at a time, except a popover opened from inside another one (nested picker).
    private static var open: [WeakPopover] = []
    private struct WeakPopover { weak var popover: SQPopover? }

    private var controller: NSViewController?
    /// What the popover was shown from. A press on it closes the popover and goes no further, so a toggle button does
    /// not see the press, find the popover closed and open it again.
    private weak var anchorView: NSView?
    private var anchorRect: CGRect = .zero

    public init(contentView: NSView) { self.contentView = contentView }

    /// Hosts a view controller's view and forwards its appear/disappear callbacks like NSPopover did.
    public convenience init(controller: NSViewController) {
        self.init(contentView: controller.view)
        self.controller = controller
    }

    public var popoverWindow: NSWindow? { window }

    /// Shows next to `rect` (in `view` coordinates). `preferredEdge` follows NSPopover: `.maxY` is the view's maxY side,
    /// which is visually below the anchor in a flipped view.
    public func show(relativeTo rect: CGRect, of view: NSView, preferredEdge: NSRectEdge = .maxY) {
        guard !isShown, let parent = view.window else { return }
        SQMenuController.shared.dismiss()
        Self.closeOthers(openedFrom: parent, except: self)
        anchorView = view; anchorRect = rect
        let anchorWindow = view.convert(rect, to: nil)
        let anchor = parent.convertToScreen(anchorWindow)
        let flipped = view.isFlipped
        let side: SQPopoverLogic.Side = switch preferredEdge {
        case .maxY: flipped ? .below : .above
        case .minY: flipped ? .above : .below
        case .minX: .left
        case .maxX: .right
        @unknown default: .below
        }
        let fitting = contentView.fittingSize
        let cs = CGSize(width: max(contentView.frame.width, fitting.width), height: max(contentView.frame.height, fitting.height))
        let size = CGSize(width: cs.width + inset * 2, height: cs.height + inset * 2)
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 4000, height: 4000)
        let placed = SQPopoverLogic.frame(size: size, anchor: anchor, side: side, visible: visible)

        let w = SQPopoverWindow(contentRect: placed.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = parent.level
        w.isReleasedWhenClosed = false
        w.appearance = Theme.windowAppearance
        let frameView = SQPopoverFrameView(frame: CGRect(origin: .zero, size: size))
        frameView.autoresizingMask = [.width, .height]
        contentView.frame = CGRect(x: inset, y: inset, width: cs.width, height: cs.height)
        contentView.autoresizingMask = [.width, .height]
        frameView.addSubview(contentView)
        w.contentView = frameView
        w.onEscape = { [weak self] in self?.dismiss(.escape) }
        parent.addChildWindow(w, ordered: .above)
        controller?.viewWillAppear()
        w.makeKeyAndOrderFront(nil)
        window = w
        isShown = true
        Self.open.removeAll { $0.popover == nil || $0.popover === self }
        Self.open.append(WeakPopover(popover: self))
        installMonitors()
        observeWindows(parent: parent)
    }

    /// One popover at a time: closes every other shown popover unless `parent` is that popover's own window (or one of its
    /// descendants), which is how a nested picker opens from inside its popover.
    private static func closeOthers(openedFrom parent: NSWindow, except me: SQPopover) {
        open.removeAll { $0.popover == nil }
        for p in open.compactMap(\.popover) where p !== me {
            guard let w = p.window, !SQPopoverLogic.isInside(parent, popover: w) else { continue }
            p.close()
        }
    }

    /// Windows that take over while the popover is up (a sheet, a file panel, another panel becoming key) or move away
    /// under it (parent resized or closed) close it: it is anchored to a place that no longer holds still.
    private func observeWindows(parent: NSWindow) {
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                nonisolated(unsafe) let other = n.object as? NSWindow
                MainActor.assumeIsolated { self?.windowBecameKey(other) }
            },
        ] + [NSWindow.didResizeNotification, NSWindow.willCloseNotification].map { name in
            nc.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func windowBecameKey(_ other: NSWindow?) {
        guard let w = window, let other, mode != .applicationDefined, !SQPopoverLogic.isInside(other, popover: w) else { return }
        close()
    }

    public func close() {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        Self.open.removeAll { $0.popover == nil || $0.popover === self }
        if let w = window {
            // The popover held the keyboard: give it back to the window it came from (its responder is still set).
            let parent = w.parent
            if w.isKeyWindow, let parent, parent.isVisible { parent.makeKey() }
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
            w.contentView = nil
        }
        window = nil
        controller?.viewDidDisappear()
        onClose?()
    }

    private func dismiss(_ t: SQPopoverLogic.Trigger) {
        if SQPopoverLogic.shouldDismiss(mode, t) { close() }
    }

    /// True when a press at `point` (window coordinates) of `window` lands on the anchor the popover was shown from.
    func isOnAnchor(_ window: NSWindow?, at point: CGPoint) -> Bool {
        guard let v = anchorView, let w = v.window, w === window else { return false }
        return anchorRect.contains(v.convert(point, from: nil))
    }

    /// What the local monitor does with a press or key in the app: the event to pass on, nil when it ends here.
    func handle(_ e: NSEvent) -> NSEvent? {
        guard let w = window else { return e }
        // keyCode only exists on key events: asking a mouse event for it raises, AppKit drops the event, and no press
        // (inside or outside) ever arrives. That was "does not close on outside click, cannot be edited".
        if e.type == .keyDown {
            if e.keyCode == 53, NSApp.keyWindow === w { dismiss(.escape); return nil }
            return e
        }
        guard !SQPopoverLogic.isInside(e.window, popover: w) else { return e }
        // Checked before closing: the anchor is still known.
        let onAnchor = e.type == .leftMouseDown && isOnAnchor(e.window, at: e.locationInWindow)
        dismiss(.clickOutsideInApp)
        // The press that closed it on its own anchor ends here (see `anchorView`).
        return onAnchor && !isShown ? nil : e
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            nonisolated(unsafe) let event = e
            nonisolated(unsafe) var out: NSEvent? = e
            MainActor.assumeIsolated { if let self { out = self.handle(event) } }
            return out
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss(.clickOutsideOtherApp) }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.appDeactivated) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        localMonitor = nil; globalMonitor = nil; resignObserver = nil
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers = []
    }

    /// The popover's chrome around `content` without a window (render harness, `scripts/render-panels.sh`).
    public static func renderedFrame(content: NSView, inset: CGFloat = 0) -> NSView {
        let fitting = content.fittingSize
        let cs = CGSize(width: max(content.frame.width, fitting.width), height: max(content.frame.height, fitting.height))
        let frameView = SQPopoverFrameView(frame: CGRect(x: 0, y: 0, width: cs.width + inset * 2, height: cs.height + inset * 2))
        content.frame = CGRect(x: inset, y: inset, width: cs.width, height: cs.height)
        frameView.addSubview(content)
        return frameView
    }
}
