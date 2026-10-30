import AppKit

/// Shared shape drawing of the base controls (design B v7): 6 px control corners, 4 px inner corners, inner focus line.
@MainActor enum ControlShape {
    /// Corner radius of a control body of `rect` (6 px, never more than half the height).
    static func radius(_ rect: NSRect) -> CGFloat { min(Theme.Radius.control, rect.height / 2) }
    /// Corner radius of a shape inside a control (selected segment, inner highlight).
    static func innerRadius(_ rect: NSRect) -> CGFloat { min(Theme.Radius.inner, rect.height / 2) }

    /// Control body path (6 px corners) for `rect`. Kept under its old name: every base control draws through it.
    static func capsule(_ rect: NSRect) -> NSBezierPath {
        let r = radius(rect)
        return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    }

    /// A shape inside a control (4 px corners).
    static func inner(_ rect: NSRect) -> NSBezierPath {
        let r = innerRadius(rect)
        return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    }

    /// Keyboard focus (sq.css `.foc`): inner 1.5 px accent line, drawn inside `rect` with corner radius `radius`.
    static func drawFocusLine(in rect: NSRect, radius: CGFloat) {
        let w = Theme.State.focusLineWidth
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: w / 2, dy: w / 2), xRadius: radius - w / 2, yRadius: radius - w / 2)
        path.lineWidth = w
        Theme.State.focusLine.setStroke()
        path.stroke()
    }

    /// Render/test hook (Parts and States board checks): every control draws its keyboard-focus state.
    nonisolated(unsafe) static var forcedFocus = false

    /// True while `view` is the first responder and the user navigates by keyboard.
    static func isFocused(_ view: NSView) -> Bool {
        if forcedFocus { return true }
        return view.window?.firstResponder === view && NSApp.isFullKeyboardAccessEnabled
    }
}
