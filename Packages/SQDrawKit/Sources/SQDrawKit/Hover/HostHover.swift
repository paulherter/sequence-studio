import Foundation

/// What the drawn panels ask of the window about the pointer (the Mac AppKit views do this through cursor rects and
/// `SQTooltip`): the pointer shape at the pointer and the tooltip of the control under it.
///
/// The host brackets every input event: `beginEvent` before it routes the event to the panels, `endEvent` after. While a
/// move or drag is routed, the panel under the pointer calls `request(_:)` with its cursor and `offerTip(_:)` with the
/// tip of the control there (the first offer wins: hosts route top-most first). The host reads `cursor` for its window
/// cursor, draws `drawTooltip` after the panels and before the menus, and redraws while `needsFrame` says a tip is due.
/// The UI runs on one thread; tests bind their own instance with `HostHover.$current.withValue`.
public final class HostHover: @unchecked Sendable {
    /// The shape the panel under the pointer asked for during the last mouse event (nil: the host's own rules, the arrow).
    public private(set) var cursor: DrawCursor?
    public private(set) var tooltip = TooltipState()
    private var offer: String?
    private var collecting = false

    public init() {}

    public static let shared = HostHover()
    @TaskLocal public static var current: HostHover = shared

    /// A panel's shape at the pointer for this event.
    public func request(_ c: DrawCursor?) { if let c { cursor = c } }
    /// Replaces the request outside a mouse event (a tool key changed the shape under a resting pointer; nil: none).
    public func replace(_ c: DrawCursor?) { cursor = c }

    /// The tip of the control under the pointer (nil or empty: none there). Only while a move is routed.
    public func offerTip(_ text: String?) {
        guard collecting, offer == nil, let text, !text.isEmpty else { return }
        offer = text
    }

    /// Before the host routes `e`: mouse events start a fresh cursor request; a press, wheel or key hides the tip.
    public func beginEvent(_ e: InputEvent) {
        switch e {
        case .mouseMoved:
            cursor = nil
            offer = nil
            collecting = true
        case .mouseDragged, .mouseUp: cursor = nil
        case .mouseDown, .scroll:
            cursor = nil
            tooltip.dismiss()
        case .keyDown: tooltip.dismiss()
        }
    }

    /// After the host routed `e` (`now`: seconds of a steady clock).
    public func endEvent(_ e: InputEvent, now: Double) {
        guard case .mouseMoved(let x, let y) = e else { return }
        collecting = false
        tooltip.hover(offer, pointer: (x, y), now: now)
    }

    /// The pointer left the window: no tip, no request.
    public func pointerExited(now: Double) {
        cursor = nil
        tooltip.hover(nil, pointer: (0, 0), now: now)
    }

    /// A tip waits for its delay: the host keeps drawing frames until it shows.
    public func needsFrame(now: Double) -> Bool { tooltip.pending(now: now) }

    /// The tip once its delay passed, near the pointer and inside the canvas (SQ design B `.tip`).
    public func drawTooltip(_ c: inout Canvas, theme t: DrawTheme, now: Double) {
        tooltip.draw(&c, theme: t, now: now)
    }
}

/// One tooltip at a time, the Mac `SQTooltip` rules: shown `TooltipLayout.delay` after the pointer came to rest on a
/// control with a tip, at once when the previous tip closed by leaving its control within `handOverWindow`; hidden on
/// exit, press, wheel or key, and after a press it stays hidden until the pointer reaches another control.
public struct TooltipState: Sendable, Equatable {
    /// The tip of the control under the pointer.
    public private(set) var text: String?
    /// Window pixels of the pointer when the control was entered (the tip's anchor).
    public private(set) var anchor: (x: Float, y: Float) = (0, 0)
    public private(set) var showAt: Double = 0
    public private(set) var shown = false
    /// Hidden by a press, wheel or key until the control changes.
    public private(set) var suppressed = false
    var lastExit: Double?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.anchor == b.anchor && a.showAt == b.showAt && a.shown == b.shown && a.suppressed == b.suppressed
            && a.lastExit == b.lastExit
    }

    mutating func hover(_ offer: String?, pointer: (Float, Float), now: Double) {
        guard offer != text else { return }
        if shown { lastExit = now }
        shown = false
        suppressed = false
        text = offer
        anchor = pointer
        showAt = now + TooltipLayout.showDelay(now: now, lastExit: lastExit)
    }

    mutating func dismiss() {
        shown = false
        lastExit = nil
        if text != nil { suppressed = true }
    }

    /// A tip that will show once `now` reaches `showAt`.
    public func pending(now: Double) -> Bool { text != nil && !suppressed && !shown }

    /// The tip is on screen at `now`.
    public func isVisible(now: Double) -> Bool { text != nil && !suppressed && (shown || now >= showAt) }

    mutating func draw(_ c: inout Canvas, theme t: DrawTheme, now: Double) {
        guard isVisible(now: now), let text else { return }
        shown = true
        let k = CGFloat(max(c.scale, 0.01))
        let bounds = CGSize(width: CGFloat(c.list.width) / k, height: CGFloat(c.list.height) / k)
        TooltipLayout.draw(text, &c, pointer: CGPoint(x: CGFloat(anchor.x) / k, y: CGFloat(anchor.y) / k), bounds: bounds, theme: t)
    }
}

/// Size, place and look of a tip (the Mac `SQTooltipLayout` / `SQTooltipView`: 12 pt `label2` on `overlay`, padding 8 x 12,
/// radius 8, a 0.5 ink edge, a trailing "(key)" as a keycap chip).
public enum TooltipLayout {
    public static let delay: Double = 0.8
    public static let handOverWindow: Double = 0.5
    public static let paddingX: CGFloat = 12, paddingY: CGFloat = 8
    public static let radius: CGFloat = 8
    public static let fontSize: CGFloat = 12
    /// Offset of the tip's top-left from the pointer, and the gap kept to the window edge.
    public static let pointerOffset = CGSize(width: 10, height: 18)
    public static let margin: CGFloat = 4
    /// Longer tips wrap at this width.
    public static let maxTextWidth: CGFloat = 320
    public static let chipHeight: CGFloat = 14, chipMinWidth: CGFloat = 14, chipPadding: CGFloat = 3, chipRadius: CGFloat = 3,
                      chipGap: CGFloat = 4, chipFont: CGFloat = 10

    /// `SQTooltipLayout.showDelay`.
    public static func showDelay(now: Double, lastExit: Double?) -> Double {
        if let lastExit, now - lastExit >= 0, now - lastExit <= handOverWindow { return 0 }
        return delay
    }

    /// `SQTooltipLayout.split`: "Snap (N)" -> ("Snap", "N").
    public static func split(_ text: String) -> (name: String, key: String?) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, nil) }
        let key = String(text[open.upperBound...].dropLast())
        guard !key.isEmpty, key.count <= 12, !key.contains("(") else { return (text, nil) }
        return (String(text[..<open.lowerBound]), key)
    }

    /// Below-right of the pointer; flipped above / to the left where it would leave `bounds`, then clamped.
    public static func frame(size: CGSize, pointer: CGPoint, bounds: CGSize) -> CGRect {
        var x = pointer.x + pointerOffset.width, y = pointer.y + pointerOffset.height
        if x + size.width > bounds.width - margin { x = pointer.x - size.width - 2 }
        if y + size.height > bounds.height - margin { y = pointer.y - size.height - 4 }
        x = min(max(x, margin), max(bounds.width - size.width - margin, margin))
        y = min(max(y, margin), max(bounds.height - size.height - margin, margin))
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    static func draw(_ text: String, _ c: inout Canvas, pointer: CGPoint, bounds: CGSize, theme t: DrawTheme) {
        let (name, key) = split(text)
        let line = max(c.size(of: "Ag", fontSize: fontSize).height, 14)
        let nameW = c.size(of: name, fontSize: fontSize).width
        let keyW = key.map { max(chipMinWidth, ceil(c.size(of: $0, fontSize: chipFont).width) + chipPadding * 2) } ?? 0
        // A long tip wraps whole (its key stays in the text); a short one gets the keycap chip.
        let wraps = nameW + (key == nil ? 0 : chipGap + keyW) > maxTextWidth
        let textW = wraps ? maxTextWidth : ceil(nameW) + (key == nil ? 0 : chipGap + keyW)
        let lines = wraps ? max(c.wrap(text, width: maxTextWidth, fontSize: fontSize).count, 1) : 1
        let size = CGSize(width: textW + paddingX * 2, height: ceil(line * CGFloat(lines)) + paddingY * 2)
        let box = frame(size: size, pointer: pointer, bounds: bounds)
        c.fill(roundedRect: box, radius: radius, t.overlay)
        let i = t.palette.ink
        c.stroke(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5,
                 DrawColor(Float(i.r) / 255, Float(i.g) / 255, Float(i.b) / 255, 0.14))
        let inner = box.insetBy(dx: paddingX, dy: paddingY)
        if wraps {
            c.drawWrapped(text, in: inner, fontSize: fontSize, lineHeight: line, t.label2)
        } else {
            c.draw(name, in: CGRect(x: inner.minX, y: inner.minY, width: ceil(nameW) + 1, height: inner.height), fontSize: fontSize, t.label2)
        }
        guard let key, !wraps else { return }
        let chip = CGRect(x: inner.minX + ceil(nameW) + chipGap, y: (box.midY - chipHeight / 2).rounded(), width: keyW, height: chipHeight)
        c.fill(roundedRect: chip, radius: chipRadius, t.inkFill(0.06))
        c.stroke(roundedRect: chip.insetBy(dx: 0.25, dy: 0.25), radius: chipRadius, width: 0.5, t.inkFill(0.10))
        c.draw(key, in: chip, fontSize: chipFont, t.label2, align: .center)
    }
}
