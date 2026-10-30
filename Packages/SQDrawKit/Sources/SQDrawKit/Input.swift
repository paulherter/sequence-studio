/// Keys the portable UI handles (the host maps its virtual key codes onto these).
public enum InputKey: Sendable, Equatable, Hashable {
    case space, left, right, up, down, home, end, delete, backspace, escape, enter, plus, minus
    case pageUp, pageDown
    /// F1...F12.
    case function(Int)
    /// Tab is `.character("\t")`.
    case character(Character)
}

public struct InputModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = InputModifiers(rawValue: 1)
    /// Ctrl on Windows, Command on the Mac: the command modifier of shortcuts.
    public static let command = InputModifiers(rawValue: 2)
    public static let option = InputModifiers(rawValue: 4)
    /// The secondary button (right click; Control-click on the Mac): the host sends a `mouseDown` with this flag and the
    /// matching `mouseUp` at once, so a panel opens its context menu on the press (as `rightMouseDown` does).
    public static let secondary = InputModifiers(rawValue: 8)
}

/// One input event in pixels (y down).
public enum InputEvent: Sendable, Equatable {
    case mouseDown(x: Float, y: Float, modifiers: InputModifiers)
    case mouseDragged(x: Float, y: Float)
    case mouseUp(x: Float, y: Float)
    case mouseMoved(x: Float, y: Float)
    /// Wheel: `dx`/`dy` in pixels with AppKit's `scrollingDelta` signs (positive dy = content moves down, the view shows
    /// earlier content; positive dx = content moves right). Lists scroll by `offset -= dy`. The device data (trackpad
    /// phases, raw deltas, pinch) is in `ScrollGesture.current(pixelsX:pixelsY:)`.
    case scroll(x: Float, y: Float, dx: Float, dy: Float, modifiers: InputModifiers)
    case keyDown(InputKey, modifiers: InputModifiers)
}
