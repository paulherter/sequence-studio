import Foundation

/// A trackpad gesture phase (`NSEvent.Phase`); mouse wheels and Windows report `.none`.
public enum ScrollPhase: Sendable, Equatable {
    case none, mayBegin, began, changed, stationary, ended, cancelled
}

/// The device data behind one `InputEvent.scroll`, in the units and signs AppKit's `scrollingDeltaX/Y` use, so the
/// shared panels can run the Mac view formulas unchanged (TimelineView, ProgramSurfaceView, ScrubField...):
/// - `precise` (trackpad, Magic Mouse): deltas in points; else (mouse wheel) in lines, ~1 a notch.
/// - Signs follow the content: positive deltaY = content moves down (the fingers or the wheel pull earlier content into
///   view). The system's natural-scrolling setting is already applied, as in `scrollingDeltaY`.
/// A pinch (`magnify`) and a two-finger double tap (`smartMagnify`) ride the same route as a scroll of zero pixels, so
/// they reach the panel under the pointer through the existing wheel hit tests; panels that do not know them ignore them.
public struct ScrollGesture: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case scroll
        /// `NSEvent.magnification` (0.1 = 10 % bigger).
        case magnify(Double)
        case smartMagnify
    }

    public var kind: Kind
    public var deltaX: Double
    public var deltaY: Double
    public var precise: Bool
    public var phase: ScrollPhase
    public var momentumPhase: ScrollPhase

    public init(kind: Kind = .scroll, deltaX: Double = 0, deltaY: Double = 0, precise: Bool = false,
                phase: ScrollPhase = .none, momentumPhase: ScrollPhase = .none) {
        self.kind = kind
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.precise = precise
        self.phase = phase
        self.momentumPhase = momentumPhase
    }

    /// Host pixels of one mouse-wheel notch (Windows: WHEEL_DELTA 120 -> 40 px).
    public static let wheelPixelsPerNotch: Double = 40

    /// A plain mouse wheel derived from the event's pixels: what a host that publishes no gesture (Windows, tests) means.
    public static func wheel(pixelsX: Float, pixelsY: Float) -> ScrollGesture {
        ScrollGesture(deltaX: Double(pixelsX) / wheelPixelsPerNotch, deltaY: Double(pixelsY) / wheelPixelsPerNotch)
    }

    /// The gesture of the scroll event being handled: what the host published, else a wheel from its pixels.
    public static func current(pixelsX: Float, pixelsY: Float) -> ScrollGesture {
        HostGesture.current.gesture ?? wheel(pixelsX: pixelsX, pixelsY: pixelsY)
    }

    /// The published gesture only (nil outside a host event): for code that keeps its own fallback.
    public static var published: ScrollGesture? { HostGesture.current.gesture }

    public var isScroll: Bool { kind == .scroll }
}

/// Where the host puts the `ScrollGesture` of the scroll event it is delivering (set before, cleared after).
/// shortcut: the gesture rides beside `InputEvent.scroll` instead of inside it, so the ~40 panels that pattern-match
/// `.scroll` keep compiling untouched; upgrade by moving it into the event when those files are free to change.
public final class HostGesture: @unchecked Sendable {
    public static let shared = HostGesture()
    @TaskLocal public static var current: HostGesture = shared
    public var gesture: ScrollGesture?
    public init() {}

    /// Runs `deliver` with `g` published.
    public func with<T>(_ g: ScrollGesture, _ deliver: () -> T) -> T {
        gesture = g
        defer { gesture = nil }
        return deliver()
    }
}

/// The Mac twin of the Windows wheel route: `NSEvent` scroll data to a `ScrollGesture` and the event's pixels. Pure
/// data (raw `NSEvent.Phase` bits), so it is tested without AppKit; the App's `SharedUIView` passes the event fields.
public enum MacScroll {
    /// `NSScrollView.verticalLineScroll` (10 pt): what one wheel line scrolls a list in the AppKit app.
    public static let lineScrollPoints: Double = 10

    /// `NSEvent.Phase` raw bits, in the order `TimelineView.scrollPhase` tests them.
    public static func phase(raw: UInt) -> ScrollPhase {
        if raw & 0x1 != 0 { return .began }
        if raw & 0x4 != 0 { return .changed }
        if raw & 0x8 != 0 { return .ended }
        if raw & 0x10 != 0 { return .cancelled }
        if raw & 0x20 != 0 { return .mayBegin }
        if raw & 0x2 != 0 { return .stationary }
        return .none
    }

    public static func scroll(deltaX: Double, deltaY: Double, precise: Bool, phase: UInt, momentumPhase: UInt) -> ScrollGesture {
        ScrollGesture(deltaX: deltaX, deltaY: deltaY, precise: precise,
                      phase: Self.phase(raw: phase), momentumPhase: Self.phase(raw: momentumPhase))
    }

    public static func magnify(_ magnification: Double, phase: UInt) -> ScrollGesture {
        ScrollGesture(kind: .magnify(magnification), precise: true, phase: Self.phase(raw: phase))
    }

    /// The pixels of `InputEvent.scroll` for lists: a trackpad moves them 1:1 with the fingers, a wheel line by
    /// `lineScrollPoints` (the AppKit scroll view's distances). Same signs as the deltas.
    public static func pixels(_ g: ScrollGesture, scale: Float) -> (dx: Float, dy: Float) {
        guard g.isScroll else { return (0, 0) }
        let k = Double(scale) * (g.precise ? 1 : lineScrollPoints)
        return (Float(g.deltaX * k), Float(g.deltaY * k))
    }
}

/// The Windows wheel route: `WM_MOUSEWHEEL` / `WM_MOUSEHWHEEL` to a `ScrollGesture` with the Mac meaning, so the shared
/// panels scroll and zoom the same on both systems. Windows sends no device type or phases, so:
/// - A delta that is not a whole `WHEEL_DELTA` (120) is a precision touchpad (or a free-spinning wheel): `precise`,
///   in points (`pointsPerWheelDelta`), with phases made up from the timing (began, changed, and ended after `idleEnd`
///   without a message, delivered by `idle(now:)`). Once a gesture runs, its whole-notch messages stay precise.
/// - Windows turns a touchpad pinch into Ctrl + precise wheel messages: those become `.magnify` (Ctrl + a mouse notch
///   stays a scroll with Ctrl held, which the panels read as the Mac Command + wheel zoom).
/// - Mouse notches: lines (1 a notch), as `ScrollGesture.wheel(pixelsX:pixelsY:)`.
/// Signs: wheel forward (positive delta) = content moves down (positive deltaY); tilt right (positive horizontal delta)
/// = later content (negative deltaX).
public struct WinScroll: Sendable, Equatable {
    public static let wheelDelta = 120
    /// A precision touchpad gesture ends after this long without a message.
    public static let idleEnd: Double = 0.12
    /// Points of one `WHEEL_DELTA` from a precision touchpad (the 40 px a mouse notch scrolls).
    public static let pointsPerWheelDelta = 40.0
    /// Magnification of one `WHEEL_DELTA` of a pinch (`NSEvent.magnification` units: 0.1 = 10 % bigger).
    public static let magnifyPerWheelDelta = 0.1

    /// When the running precise gesture saw its last message (nil: none runs).
    private var lastAt: Double?
    private var pinch = false

    public init() {}

    /// A precise gesture is running (its end is still to come from `idle`).
    public var isActive: Bool { lastAt != nil }

    /// One wheel message: `delta` the signed `WHEEL_DELTA` units of the high word, `control` Ctrl held (`MK_CONTROL`).
    public mutating func wheel(delta: Int, horizontal: Bool, control: Bool, now: Double) -> ScrollGesture {
        let running = lastAt.map { now - $0 <= Self.idleEnd } ?? false
        let d = Double(delta) / Double(Self.wheelDelta)
        guard running || delta % Self.wheelDelta != 0 else {
            lastAt = nil
            return ScrollGesture(deltaX: horizontal ? -d : 0, deltaY: horizontal ? 0 : d)
        }
        if !running { pinch = control && !horizontal }
        lastAt = now
        let phase: ScrollPhase = running ? .changed : .began
        if pinch { return ScrollGesture(kind: .magnify(d * Self.magnifyPerWheelDelta), precise: true, phase: phase) }
        let p = d * Self.pointsPerWheelDelta
        return ScrollGesture(deltaX: horizontal ? -p : 0, deltaY: horizontal ? 0 : p, precise: true, phase: phase)
    }

    /// Call once per frame: the end of a precise gesture after `idleEnd` without a message, else nil.
    public mutating func idle(now: Double) -> ScrollGesture? {
        guard let last = lastAt, now - last > Self.idleEnd else { return nil }
        lastAt = nil
        return ScrollGesture(kind: pinch ? .magnify(0) : .scroll, precise: true, phase: .ended)
    }

    /// The pixels of `InputEvent.scroll` for lists: a touchpad its points at `scale`, a mouse notch 40 px (the pixels
    /// the Windows host always sent, `ScrollGesture.wheelPixelsPerNotch`).
    public static func pixels(_ g: ScrollGesture, scale: Float) -> (dx: Float, dy: Float) {
        guard g.isScroll else { return (0, 0) }
        let k = g.precise ? Double(scale) : ScrollGesture.wheelPixelsPerNotch
        return (Float(g.deltaX * k), Float(g.deltaY * k))
    }
}


/// Scroll deltas rounded to whole device pixels with the remainder carried into the next event (the Mac
/// `TimelineView.wholeDevicePixels`): a slow trackpad drag of 0.3 px steps still moves, and the content cache can shift
/// whole pixels instead of re-drawing blurred half pixels.
public struct ScrollCarry: Sendable, Equatable {
    public private(set) var remainder = 0.0
    public init() {}

    /// `d` points (plus the carried remainder) as whole device pixels at `scale` pixels per point, in points.
    public mutating func whole(_ d: Double, scale: Double) -> Double {
        let s = max(scale, 1)
        let want = d + remainder
        let applied = (want * s).rounded() / s
        remainder = want - applied
        return applied
    }

    public mutating func reset() { remainder = 0 }
}
