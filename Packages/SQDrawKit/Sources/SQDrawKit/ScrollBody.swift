import Foundation

/// The host side of scrolling physics: the clock, whether the host's own scroll events carry momentum, and the bodies
/// that still move without input (a spring back, a fling). A host redraws while `needsFrame` is true.
public final class HostScroll: @unchecked Sendable {
    public static let shared = HostScroll()
    private let lock = NSLock()
    private var moving: [ObjectIdentifier: ScrollBody] = [:]
    /// True when the system delivers the momentum tail of a fling as scroll events (`NSEvent.momentumPhase`, Mac). Else the
    /// bodies synthesize it from the finger speed at lift-off (Windows precision touchpads).
    public var systemMomentum = false

    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    public func register(_ b: ScrollBody) { lock.lock(); moving[ObjectIdentifier(b)] = b; lock.unlock() }

    /// Moves every running body to `now`; true while one still moves (the host draws another frame).
    public func needsFrame(now: Double = HostScroll.now()) -> Bool {
        lock.lock()
        let bodies = Array(moving.values)
        lock.unlock()
        for b in bodies { b.advance(to: now) }
        lock.lock()
        defer { lock.unlock() }
        for (k, b) in moving where !b.needsFrames(now: now) { moving[k] = nil }
        return !moving.isEmpty
    }
}

/// One scrolling axis with the feel of Apple's trackpad scrolling, written once for Mac and Windows:
/// - Fingers on the pad pull the content 1:1 inside its range; past an end the pull is resisted by the rubber band
///   `f(x, d) = (1 - 1 / (x * 0.55 / d + 1)) * d` (`d` = the viewport length), the formula UIScrollView uses.
/// - Lifting the fingers past an end springs back with a critically damped spring.
/// - A fling keeps going: the Mac delivers the momentum as events (used as they come); where the host sends none the body
///   decelerates by 0.998 per millisecond (UIScrollView `.normal`). A fling that reaches an end bounces off it.
/// - A mouse wheel (not `precise`) scrolls at once and never bounces.
/// Positions are in points along the scroll axis, `offset` 0 ... `maxOffset`. A content that fits (`maxOffset` 0) does not
/// bounce, as in NSScrollView. Physics only (Double); no media time.
/// The `offset` getter advances the body to the clock, so a panel just reads it each frame.
/// Formulas are the published ones (UIScrollView rubber band and deceleration rate); no code borrowed.
public final class ScrollBody: @unchecked Sendable {
    enum Mode { case idle, tracking, momentum, glide, spring }

    /// UIScrollView's rubber band constant.
    public static let rubberCoefficient = 0.55
    /// Velocity decay per millisecond of a fling (`UIScrollView.DecelerationRate.normal`).
    public static let decelerationPerMs = 0.998
    /// Spring back speed (1/s): ~0.45 s from 100 pt out to rest.
    public static let springOmega = 11.0
    /// Share of the speed that reaches the edge a fling bounces off.
    public static let edgeImpact = 0.5
    /// A fling below this speed (pt/s) at lift-off does not glide.
    public static let minFlingSpeed = 120.0
    /// Finger speed is taken over this window before the last message.
    static let velocityWindow = 0.1
    /// A lift-off this long after the last message has no speed.
    static let staleAfter = 0.15

    var mode: Mode = .idle
    var pos = 0.0               // what the panel sees
    private var raw = 0.0               // the unresisted finger position while tracking
    private var samples: [(t: Double, d: Double)] = []
    private var lastMomentumAt: Double?
    // glide: p(t) = p0 + v0 (1 - e^(-k dt)) / k
    private var glideP0 = 0.0, glideV0 = 0.0, glideT0 = 0.0
    // spring: excess x(t) = (x0 + (v0 + w x0) t) e^(-w t) around `edge`
    private var springEdge = 0.0, springX0 = 0.0, springV0 = 0.0, springT0 = 0.0

    /// Scrollable length (content minus viewport). Default: unbounded until the panel says.
    public var maxOffset = Double.infinity
    /// Viewport length along the axis (the rubber band scale).
    public var extent = 600.0
    /// Overrides `HostScroll.systemMomentum` for this body (tests).
    public var systemMomentum: Bool?

    public init(offset: Double = 0) { pos = offset }

    // MARK: Reading

    public var offset: Double {
        advance(to: HostScroll.now())
        return idleClamped()
    }
    /// The offset as the layout wants it (CGFloat).
    public var position: CGFloat {
        get { CGFloat(offset) }
        set { assign(Double(newValue)) }
    }
    /// Past an end (the rubber band is stretched or springing).
    public var isOverscrolled: Bool { pos < 0 || (maxOffset > 0 && pos > maxOffset) }
    // Overlay scroller state (`ScrollerBar.swift`).
    var lastActive = -100.0
    var scrollerDragging = false
    var scrollerHover = false
    var scrollerGrab = 0.0
    /// Frames are still needed: a fling or bounce runs, or the scroller is visible and fades.
    func needsFrames(now: Double) -> Bool { isMoving || scrollerDragging || now - lastActive < ScrollerBar.visibleFor + ScrollerBar.fade }
    func touch(_ now: Double) { lastActive = now; HostScroll.shared.register(self) }

    var isMoving: Bool { mode == .glide || mode == .spring }
    public var isAnimating: Bool { isMoving }

    /// The current position without moving the clock.
    var positionAt: Double { idleClamped() }

    private func idleClamped() -> Double {
        if mode == .idle { pos = min(max(pos, 0), max(maxOffset, 0)) }
        return pos
    }

    // MARK: Program changes

    /// The panel sets the offset (reset, scroll into view). A plain clamp of where the body is (a layout pass) leaves a
    /// running bounce alone.
    public func assign(_ v: Double) {
        if mode != .idle, abs(v - min(max(pos, 0), max(maxOffset, 0))) < 0.01 { return }
        mode = .idle
        samples.removeAll()
        pos = v
    }

    // MARK: Input

    /// One scroll message from the event stream. `delta` moves the offset (positive = later content).
    public func scroll(by delta: Double, gesture g: ScrollGesture, now: Double = HostScroll.now()) {
        advance(to: now)
        guard delta.isFinite else { return }
        if delta != 0 { touch(now) }
        let top = max(maxOffset, 0)
        if !g.precise {
            if delta != 0 { stop(); pos = min(max(pos + delta, 0), top) }
            return
        }
        if g.momentumPhase != .none { momentum(delta, g.momentumPhase, now: now, top: top); return }
        switch g.phase {
        case .mayBegin:
            stop()
        case .began, .changed, .stationary:
            if mode != .tracking { beginTracking() }
            track(delta, now: now, top: top)
        case .ended, .cancelled:
            if mode == .tracking { track(delta, now: now, top: top); release(now: now, top: top) }
            else if delta != 0 { stop(); pos = min(max(pos + delta, 0), top) }
        case .none:
            // A precise device without phases (some mice): direct, clamped.
            if delta != 0 { stop(); pos = min(max(pos + delta, 0), top) }
        }
    }

    /// Convenience for `InputEvent.scroll`: `dy` in host pixels with AppKit signs (positive = content down), `scale` the
    /// pixels per point. Reads the gesture the host published, else a mouse wheel.
    public func wheel(dy: Float, dx: Float = 0, scale: CGFloat, maxOffset: CGFloat, extent: CGFloat) {
        self.maxOffset = Double(maxOffset)
        self.extent = Double(max(extent, 1))
        let g = ScrollGesture.current(pixelsX: dx, pixelsY: dy)
        scroll(by: -Double(dy) / Double(scale), gesture: g)
    }

    /// For panels whose host already converted to points: `dy` with AppKit signs (positive = content down).
    public func feed(dy: CGFloat, maxOffset: CGFloat, extent: CGFloat) {
        self.maxOffset = Double(maxOffset)
        self.extent = Double(max(extent, 1))
        scroll(by: -Double(dy), gesture: ScrollGesture.published ?? ScrollGesture(deltaY: dy < 0 ? -1 : 1))
    }

    // MARK: Gesture steps

    func stop() { mode = .idle; samples.removeAll() }

    private func beginTracking() {
        let top = max(maxOffset, 0)
        raw = pos < 0 ? -Self.unrubber(-pos, extent) : pos > top ? top + Self.unrubber(pos - top, extent) : pos
        mode = .tracking
        samples.removeAll()
    }

    private func track(_ delta: Double, now: Double, top: Double) {
        if delta != 0 {
            raw += delta
            samples.append((now, delta))
            samples.removeAll { now - $0.t > Self.velocityWindow * 2 }
        }
        if top <= 0 { raw = 0 }
        pos = Self.display(raw, top: top, extent: extent)
    }

    private func release(now: Double, top: Double) {
        let v = fingerVelocity(now: now)
        samples.removeAll()
        if pos < 0 { startSpring(edge: 0, x0: pos, v0: 0, now: now) }
        else if pos > top { startSpring(edge: top, x0: pos - top, v0: 0, now: now) }
        else if !(systemMomentum ?? HostScroll.shared.systemMomentum), abs(v) >= Self.minFlingSpeed {
            mode = .glide; glideP0 = pos; glideV0 = v; glideT0 = now
            HostScroll.shared.register(self)
        } else { mode = .idle }
    }

    /// Points per second over the window before the last message; 0 when the fingers rested before lifting.
    private func fingerVelocity(now: Double) -> Double {
        guard let last = samples.last?.t, now - last <= Self.staleAfter else { return 0 }
        let recent = samples.filter { last - $0.t <= Self.velocityWindow }
        guard recent.count >= 2, let first = recent.first else { return 0 }
        let dt = last - first.t
        guard dt > 0.004 else { return 0 }
        return recent.dropFirst().reduce(0) { $0 + $1.d } / dt
    }

    /// System momentum (Mac): used as delivered inside the range; at an end it turns into a bounce.
    private func momentum(_ delta: Double, _ phase: ScrollPhase, now: Double, top: Double) {
        if mode == .spring { return }                    // already bounced during this fling
        if phase == .ended || phase == .cancelled {
            if mode == .momentum { mode = .idle }
            lastMomentumAt = nil
            return
        }
        if mode != .momentum { mode = .momentum; lastMomentumAt = nil }
        let next = pos + delta
        defer { lastMomentumAt = now }
        if next < 0 || next > top {
            let edge = next < 0 ? 0.0 : top
            let dt = lastMomentumAt.map { max(now - $0, 1.0 / 240) } ?? 1.0 / 60
            pos = edge
            guard top > 0 else { mode = .idle; return }
            startSpring(edge: edge, x0: 0, v0: delta / dt * Self.edgeImpact, now: now)
            return
        }
        pos = next
    }

    private func startSpring(edge: Double, x0: Double, v0: Double, now: Double) {
        springEdge = edge; springX0 = x0; springV0 = v0; springT0 = now
        mode = .spring
        HostScroll.shared.register(self)
    }

    // MARK: Time

    /// Runs the glide or the spring to `now`.
    public func advance(to now: Double) {
        switch mode {
        case .glide:
            let k = -log(Self.decelerationPerMs) * 1000
            let dt = max(now - glideT0, 0)
            let decay = exp(-k * dt)
            let p = glideP0 + glideV0 * (1 - decay) / k
            let v = glideV0 * decay
            let top = max(maxOffset, 0)
            if p < 0 || p > top {
                let edge = p < 0 ? 0.0 : top
                pos = edge
                if top > 0 { startSpring(edge: edge, x0: 0, v0: v * Self.edgeImpact, now: now) } else { mode = .idle }
            } else if abs(v) < 2 {
                pos = p; mode = .idle
            } else { pos = p }
        case .spring:
            let w = Self.springOmega, t = max(now - springT0, 0)
            let e = exp(-w * t)
            let x = (springX0 + (springV0 + w * springX0) * t) * e
            // d/dt [(x0 + c t) e^(-w t)] = (c - w (x0 + c t)) e^(-w t), c = v0 + w x0
            let c = springV0 + w * springX0
            let speed = (c - w * (springX0 + c * t)) * e
            if abs(x) < 0.2, abs(speed) < 2 || t > 3 { pos = springEdge; mode = .idle }
            else { pos = springEdge + x }
        default:
            break
        }
    }

    // MARK: Rubber band

    /// The resisted distance for a pull of `x` past an end on a viewport of `d`.
    public static func rubber(_ x: Double, _ d: Double) -> Double {
        guard x > 0, d > 0 else { return 0 }
        return (1 - 1 / (x * rubberCoefficient / d + 1)) * d
    }

    /// The pull that shows `y` of overscroll (inverse of `rubber`).
    static func unrubber(_ y: Double, _ d: Double) -> Double {
        guard y > 0, d > 0 else { return 0 }
        let q = min(y / d, 0.999)
        return d / rubberCoefficient * (1 / (1 - q) - 1)
    }

    static func display(_ raw: Double, top: Double, extent d: Double) -> Double {
        if top <= 0 { return 0 }
        if raw < 0 { return -rubber(-raw, d) }
        if raw > top { return top + rubber(raw - top, d) }
        return raw
    }
}
