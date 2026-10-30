import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// Pure rules of the eyedropper loupe (Dialogs board "Eyedropper loupe"): a round 84 pt loupe over the picture,
/// 12 x 12 magnified pixels at 7 pt each, a ring, a marked center cell and the hex value underneath.
public enum SQLoupeLogic {
    public static let cells = 12
    public static let cellSize: CGFloat = 7
    public static let diameter: CGFloat = CGFloat(cells) * cellSize
    /// Index (0...11) of the cell under the pointer: the loupe has no exact center cell, the picked one is left/above it.
    public static let pickedCell = 5

    /// Rect to capture, in global display coordinates (origin top-left of the primary display, points):
    /// `cells` device pixels with the pixel under `pointer` at index `pickedCell`.
    public static func captureRect(pointer: CGPoint, scale: CGFloat) -> CGRect {
        let s = max(scale, 1)
        let px = (pointer.x * s).rounded(.down), py = (pointer.y * s).rounded(.down)
        let side = CGFloat(cells) / s
        return CGRect(x: (px - CGFloat(pickedCell)) / s, y: (py - CGFloat(pickedCell)) / s, width: side, height: side)
    }

    /// Cocoa screen point (origin bottom-left of the primary display) to CoreGraphics display point (origin top-left).
    public static func displayPoint(fromCocoa p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Row-major colors of a `cells` x `cells` RGBA8 buffer (alpha ignored). Nil when the buffer has the wrong size.
    public static func colors(rgba: [UInt8], cells n: Int = cells) -> [SQColorValue]? {
        guard rgba.count == n * n * 4 else { return nil }
        return (0..<(n * n)).map { i in
            SQColorValue(r: Double(rgba[i * 4]) / 255, g: Double(rgba[i * 4 + 1]) / 255, b: Double(rgba[i * 4 + 2]) / 255)
        }
    }

    /// The color a click picks.
    public static func picked(from colors: [SQColorValue]) -> SQColorValue? {
        let i = pickedCell * cells + pickedCell
        return colors.indices.contains(i) ? colors[i] : nil
    }

    public static func readout(_ v: SQColorValue) -> String { "#" + v.hex }

    /// Window origin (Cocoa, bottom-left) that puts the loupe circle's center on `pointer`, keeping the whole window on `screen`.
    public static func windowOrigin(pointer: CGPoint, windowSize: CGSize, circleTopInset: CGFloat, screen: CGRect) -> CGPoint {
        var o = CGPoint(x: pointer.x - windowSize.width / 2, y: pointer.y - (windowSize.height - circleTopInset - diameter / 2))
        o.x = min(max(o.x, screen.minX), screen.maxX - windowSize.width)
        o.y = min(max(o.y, screen.minY), screen.maxY - windowSize.height)
        return o
    }
}

/// Samples display pixels around a point as sRGB RGBA8 through ScreenCaptureKit, leaving the loupe's own windows out.
/// ScreenCaptureKit needs the Screen Recording permission; without it `prepare` fails and the loupe falls back to
/// drawing the app's own window content (`SQLoupeSampler.ownWindowRGBA`), which cannot see Metal layers (the monitor).
@MainActor
final class SQLoupeSampler {
    private var filters: [CGDirectDisplayID: (filter: SCContentFilter, frame: CGRect)] = [:]
    private(set) var isAvailable = false

    /// Looks up the displays and our windows to exclude. Call after the loupe windows are on screen.
    func prepare(excluding windowIDs: [CGWindowID]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ours = content.windows.filter { windowIDs.contains($0.windowID) }
            filters = Dictionary(uniqueKeysWithValues: content.displays.map {
                ($0.displayID, (SCContentFilter(display: $0, excludingWindows: ours), $0.frame))
            })
            isAvailable = !filters.isEmpty
        } catch {
            isAvailable = false
        }
    }

    func rgba(around pointer: CGPoint, scale: CGFloat) async -> [UInt8]? {
        guard let entry = filters.first(where: { $0.value.frame.contains(pointer) })?.value else { return nil }
        let n = SQLoupeLogic.cells
        let rect = SQLoupeLogic.captureRect(pointer: pointer, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - entry.frame.minX, y: rect.minY - entry.frame.minY, width: rect.width, height: rect.height)
        config.width = n; config.height = n
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: entry.filter, configuration: config) else { return nil }
        return Self.rgba(from: image)
    }

    /// Fallback without the permission: the content views under the pointer draw themselves into a bitmap.
    static func ownWindowRGBA(around cocoa: CGPoint, scale: CGFloat, excluding: [NSWindow]) -> [UInt8]? {
        let n = SQLoupeLogic.cells
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        guard let w = NSApp.windows.first(where: { $0.windowNumber == number && !excluding.contains($0) })
                ?? NSApp.windows.first(where: { $0.isVisible && !excluding.contains($0) && $0.frame.contains(cocoa) }),
              let view = w.contentView?.superview ?? w.contentView else { return nil }
        let side = CGFloat(n) / max(scale, 1)
        let inWindow = w.convertPoint(fromScreen: cocoa)
        let local = view.convert(inWindow, from: nil)
        let rect = CGRect(x: local.x - side / 2, y: local.y - side / 2, width: side, height: side)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let cg = rep.cgImage else { return nil }
        return rgba(from: cg)
    }

    static func rgba(from image: CGImage) -> [UInt8]? {
        let n = SQLoupeLogic.cells
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? buf : nil
    }
}

private final class SQLoupeOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Transparent catcher over a whole screen: takes every click and key while the loupe runs.
private final class SQLoupeOverlayView: NSView {
    var onMove: (() -> Void)?
    var onClick: (() -> Void)?
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Nearly invisible, but not clear: a fully clear pixel would let the click through.
        Theme.black(0.01).setFill(); bounds.fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { onMove?() }
    override func mouseDragged(with event: NSEvent) { onMove?() }
    override func mouseDown(with event: NSEvent) { onMove?(); onClick?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } }
}

/// The loupe itself: circle of magnified pixels with grid, ring, marked center cell, hex readout below.
private final class SQLoupeView: NSView {
    static let margin: CGFloat = 14
    static let tipGap: CGFloat = 8
    static let tipHeight: CGFloat = 20
    static var size: CGSize {
        CGSize(width: SQLoupeLogic.diameter + 2 * margin, height: margin + SQLoupeLogic.diameter + tipGap + tipHeight + margin)
    }
    var colors: [SQColorValue] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let n = SQLoupeLogic.cells, cs = SQLoupeLogic.cellSize, d = SQLoupeLogic.diameter
        let circle = CGRect(x: Self.margin, y: Self.margin, width: d, height: d)
        // Shadow under the ring (0 6 16 black 60 %).
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = Theme.black(0.6); sh.shadowBlurRadius = 16; sh.shadowOffset = NSSize(width: 0, height: -6)
        sh.set()
        Theme.black(1).setFill(); NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Pixels.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        for i in 0..<min(colors.count, n * n) {
            colors[i].nsColor.setFill()
            CGRect(x: circle.minX + CGFloat(i % n) * cs, y: circle.minY + CGFloat(i / n) * cs, width: cs, height: cs).fill()
        }
        Theme.black(0.28).setFill()
        for k in 1..<n {
            CGRect(x: circle.minX + CGFloat(k) * cs - 0.5, y: circle.minY, width: 1, height: d).fill()
            CGRect(x: circle.minX, y: circle.minY + CGFloat(k) * cs - 0.5, width: d, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Ring: 2 pt white, 1 pt black outside it.
        Theme.OnPicture.stroke.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -1, dy: -1)); ring.lineWidth = 2; ring.stroke()
        Theme.black(1).setStroke()
        let outer = NSBezierPath(ovalIn: circle.insetBy(dx: -2.5, dy: -2.5)); outer.lineWidth = 1; outer.stroke()
        // Marked center cell: white 1 pt inside black 1 pt.
        let c = SQLoupeLogic.pickedCell
        let cell = CGRect(x: circle.minX + CGFloat(c) * cs, y: circle.minY + CGFloat(c) * cs, width: cs, height: cs)
        Theme.black(1).setStroke()
        let b = NSBezierPath(rect: cell.insetBy(dx: -1.5, dy: -1.5)); b.lineWidth = 1; b.stroke()
        Theme.OnPicture.stroke.setStroke()
        let w = NSBezierPath(rect: cell.insetBy(dx: -0.5, dy: -0.5)); w.lineWidth = 1; w.stroke()
        // Readout tip.
        if let v = SQLoupeLogic.picked(from: colors) {
            let text = NSAttributedString(string: SQLoupeLogic.readout(v), attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label])
            let ts = text.size()
            let tip = CGRect(x: bounds.midX - (ts.width + 12) / 2, y: circle.maxY + Self.tipGap, width: ts.width + 12, height: Self.tipHeight)
            Theme.Colors.overlay.setFill()
            NSBezierPath(roundedRect: tip, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
            Theme.Colors.overlayEdge.setStroke()
            let e = NSBezierPath(roundedRect: tip.insetBy(dx: 0.25, dy: 0.25), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control); e.lineWidth = 0.5; e.stroke()
            text.draw(at: CGPoint(x: tip.minX + 6, y: tip.minY + (tip.height - ts.height) / 2))
        }
    }
}

/// Own eyedropper (replaces NSColorSampler): a transparent catcher over each screen and a round loupe that follows the pointer.
/// Click picks, Esc (or the app losing focus) cancels. Keep the returned object until a callback fires.
@MainActor
public final class SQLoupe {
    private var overlays: [(window: NSWindow, screen: NSScreen)] = []
    private let panel: NSPanel
    private let loupeView = SQLoupeView()
    private var onPick: ((SQColorValue) -> Void)?
    private var onCancel: (() -> Void)?
    private var resignObserver: NSObjectProtocol?
    private var finished = false
    private var cursorHidden = false
    private let sampler = SQLoupeSampler()
    private var prepared = false
    private var sampling = false
    private var pending: (point: CGPoint, scale: CGFloat)?

    @discardableResult
    public static func begin(onPick: @escaping (SQColorValue) -> Void, onCancel: @escaping () -> Void) -> SQLoupe {
        let l = SQLoupe(onPick: onPick, onCancel: onCancel)
        l.start()
        return l
    }

    private init(onPick: @escaping (SQColorValue) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick; self.onCancel = onCancel
        let size = SQLoupeView.size
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isReleasedWhenClosed = false
        loupeView.frame = CGRect(origin: .zero, size: size)
        panel.contentView = loupeView
    }

    private func start() {
        for screen in NSScreen.screens {
            let w = SQLoupeOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = .popUpMenu
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            let v = SQLoupeOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.onMove = { [weak self] in self?.update() }
            v.onClick = { [weak self] in self?.finish(pick: true) }
            v.onEscape = { [weak self] in self?.finish(pick: false) }
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.makeKeyAndOrderFront(nil)
            overlays.append((w, screen))
        }
        for o in overlays { o.window.makeFirstResponder(o.window.contentView) }     // Esc cancels on any screen
        panel.orderFrontRegardless()
        NSCursor.hide(); cursorHidden = true
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(pick: false) }
        }
        update()
        let ids = overlays.map { CGWindowID($0.window.windowNumber) } + [CGWindowID(panel.windowNumber)]
        Task { @MainActor in
            await sampler.prepare(excluding: ids)
            prepared = true
            update()
        }
    }

    private func update() {
        guard !finished else { return }
        let p = NSEvent.mouseLocation
        guard let entry = overlays.first(where: { $0.screen.frame.contains(p) }) ?? overlays.first else { return }
        panel.setFrameOrigin(SQLoupeLogic.windowOrigin(pointer: p, windowSize: SQLoupeView.size, circleTopInset: SQLoupeView.margin, screen: entry.screen.frame))
        pending = (p, entry.screen.backingScaleFactor)
        guard !sampling else { return }
        sampling = true
        Task { @MainActor in
            while let job = pending, !finished {
                pending = nil
                await sample(cocoa: job.point, scale: job.scale)
            }
            sampling = false
        }
    }

    private func sample(cocoa: CGPoint, scale: CGFloat) async {
        guard let primary = NSScreen.screens.first else { return }
        var raw: [UInt8]?
        if sampler.isAvailable {
            raw = await sampler.rgba(around: SQLoupeLogic.displayPoint(fromCocoa: cocoa, primaryHeight: primary.frame.height), scale: scale)
        } else if prepared {
            raw = SQLoupeSampler.ownWindowRGBA(around: cocoa, scale: scale, excluding: overlays.map(\.window) + [panel])
        }
        if !finished, let raw, let cols = SQLoupeLogic.colors(rgba: raw) { loupeView.colors = cols }
    }

    /// The owner let go mid-pick: restore the cursor, drop the observer and close the overlays.
    isolated deinit { finish(pick: false) }

    /// Cancels a running pick (no callback result besides `onCancel`).
    public func cancel() { finish(pick: false) }

    private func finish(pick: Bool) {
        guard !finished else { return }
        finished = true
        let result = pick ? SQLoupeLogic.picked(from: loupeView.colors) : nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        panel.orderOut(nil)
        for o in overlays { o.window.orderOut(nil); o.window.contentView = nil }
        overlays.removeAll()
        let pickCB = onPick, cancelCB = onCancel
        onPick = nil; onCancel = nil
        if let result { pickCB?(result) } else { cancelCB?() }
    }
}
