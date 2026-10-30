import Foundation

/// What drawn controls ask of the host window, read by the host once per frame (the Mac AppKit views do these
/// themselves): pointer lock while a value field scrubs (the Mac ScrubField hides and pins the pointer) and the open text
/// editor's caret (where the host puts the IME composition and candidate windows, and whether IME is on at all).
/// The UI runs on one thread; tests bind their own instance with `HostRequests.$current.withValue` so parallel tests do
/// not share the flags.
public final class HostRequests: @unchecked Sendable {
    /// A scrub drag is running: hide the pointer, keep it in place and deliver virtual drag coordinates.
    public var pointerLock = false
    /// The caret of the text editor drawn this frame, device px of the canvas list (window client px when the canvas
    /// covers the window); nil: no editor drawn. The host clears it before drawing and reads it after.
    public var caret: DrawRect?
    /// The input method's composition (marked text) not yet committed; the host sets it, `drawComposition` shows it.
    public var composition = ""

    public init() {}

    public static let shared = HostRequests()
    @TaskLocal public static var current: HostRequests = shared
}

extension HostRequests {
    /// The composition inline at the caret drawn this frame (the Mac text views' marked text): the uncommitted text on a
    /// field-colored box from the caret, underlined, over what follows. The host calls it after every panel, before the
    /// menus. Nothing without a caret or a composition.
    public func drawComposition(_ c: inout Canvas, theme t: DrawTheme) {
        guard !composition.isEmpty, let caret else { return }
        let k = CGFloat(max(c.scale, 0.01))
        let h = max(CGFloat(caret.h) / k, 12)
        let size = min(max(h * 0.72, CGFloat(DrawTheme.TypeSize.body)), 96)
        let w = c.size(of: composition, fontSize: size).width
        let box = CGRect(x: CGFloat(caret.x) / k, y: CGFloat(caret.y) / k, width: w + 4, height: h)
        c.fill(box, t.overlay)
        c.draw(composition, in: box.insetBy(dx: 2, dy: 0), fontSize: size, t.label)
        c.fill(CGRect(x: box.minX + 2, y: box.maxY - 2, width: w, height: 1), t.accent)
    }
}

/// The virtual pointer of a locked drag (the Mac `ScrubField`: hidden, pinned, raw deltas keep counting, so the drag is
/// not bounded by the screen edge). The Mac host feeds it the event deltas; panels see `virtual` instead of the real spot.
public struct PointerLockTracker: Equatable, Sendable {
    public private(set) var isLocked = false
    public private(set) var virtualX: Float = 0
    public private(set) var virtualY: Float = 0

    public init() {}

    /// A move with the button down. `locked`: `HostRequests.pointerLock`. `dx`/`dy`: the event's raw travel in the same
    /// unit as `x`/`y`. Returns the position the panels see; the first locked move is the pin point itself.
    public mutating func drag(x: Float, y: Float, dx: Float, dy: Float, locked: Bool) -> (x: Float, y: Float) {
        guard locked else { isLocked = false; return (x, y) }
        if !isLocked {
            isLocked = true; virtualX = x; virtualY = y
        } else {
            virtualX += dx; virtualY += dy
        }
        return (virtualX, virtualY)
    }

    /// The button went up: the release point panels see (the virtual one after a locked drag).
    public mutating func release(x: Float, y: Float) -> (x: Float, y: Float) {
        defer { isLocked = false }
        return isLocked ? (virtualX, virtualY) : (x, y)
    }
}

/// The system's text clipboard for the drawn text fields (Cmd-C / X / V inside an open field). The host sets `read` and
/// `write` (Mac `NSPasteboard`, Windows clipboard); until then a field copies into this process only.
public final class TextClipboard: @unchecked Sendable {
    public static let shared = TextClipboard()
    public var readSystem: (() -> String?)?
    public var writeSystem: ((String) -> Void)?
    private var local: String?

    public init() {}

    public func write(_ s: String) {
        local = s
        writeSystem?(s)
    }

    /// The system text with Windows line ends (CRLF) turned into the field's LF; the process's last copy when the system has none.
    public func read() -> String? {
        guard let s = readSystem?() else { return local }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
