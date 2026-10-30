import AppKit
import QuartzCore

/// What a mascot view shows: an animation (plays by its kind) or one of the twelve still moods (idle only).
public enum SQMascotContent: Equatable, Sendable {
    case animation(SQMascotAnim)
    case mood(SQMascotMood)
}

/// The twelve Pip moods (design `svg/pip-<mood>.svg`).
public enum SQMascotMood: String, CaseIterable, Sendable {
    case happy, cheer, wink, proud, inLove, amazed, think, focus, search, sleep, oops, sad

    var source: SQMascotAnim? {
        switch self {
        case .happy, .amazed: return nil
        case .cheer: return .cheer
        case .wink: return .wink
        case .proud: return .proud
        case .inLove: return .peek
        case .think: return .think
        case .focus: return .work
        case .search: return .search
        case .sleep: return .sleep
        case .oops: return .oops
        case .sad: return .sad
        }
    }
}

/// Pip. Draws with Core Graphics on every display-link frame; the per-frame work is one pose mix and ~10 paths, nothing
/// else on the main thread. The link is paused while hidden, off screen, occluded or under Reduce Motion (then the
/// still pose is drawn once). At rest between actions the frame rate drops to 30 (breathing is sub-pixel).
@MainActor
public final class SQMascotView: NSView {
    public let content: SQMascotContent
    public let side: CGFloat
    private var animation: SQMascotAnimation
    private var reactor: SQMascotReactor
    private var player: SQMascotPlayer { reactor.player }
    private var shown: SQMascotPose
    private var hoverArea: NSTrackingArea?
    private weak var hoverHost: NSView?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var tight: Bool
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let library = SQMascotLibrary.shared
    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// Seconds of rest between repeats; nil keeps the design value (`rest` animations only).
    public var restPause: ClosedRange<Double>? {
        didSet { reactor.restPause = restPause }
    }

    public init(_ content: SQMascotContent, side: CGFloat, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        let lib = SQMascotLibrary.shared
        self.content = content
        self.side = side
        var anim: SQMascotAnimation
        switch content {
        case .animation(let a): anim = lib.animation(a)
        case .mood(let m):
            if let src = m.source {
                anim = lib.animation(src)
                anim.kind = .part
                anim.steps = []
                anim.rest = anim.still
            } else {
                anim = lib.animation(.wink)
                anim.kind = .part
                anim.steps = []
                anim.clipBottom = nil
                anim.rest = m == .amazed ? lib.amazed : lib.defaultPose
                anim.still = anim.rest
                anim.tight = false
                anim.viewBox = CGRect(x: 47, y: 172, width: 930, height: 930)
            }
        }
        // Up to 24 pt the tight artwork (thicker edge, no hand or marks) reads better, as the design's "-klein" files.
        if side <= 24 { anim.tight = true; anim.viewBox = CGRect(x: 125, y: 268, width: 774, height: 774) }
        animation = anim
        tight = anim.tight
        var isSleep = false
        if case .animation(.sleep) = content { isSleep = true }
        reactor = SQMascotReactor(base: anim, library: lib, seed: seed, reacts: isSleep)
        shown = reduceMotion ? anim.still : reactor.player.pose
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: Self.height(side, anim)))
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func height(_ side: CGFloat, _ a: SQMascotAnimation) -> CGFloat {
        guard let c = a.clipBottom else { return side }
        return side * CGFloat((c - Double(a.viewBox.minY)) / Double(a.viewBox.height))
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: side, height: Self.height(side, animation)) }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { loggedFrame = nil; stopLink(); return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionPreferenceChanged() }
        })
        updateRunning()
        logShownIfVisible()
    }

    public override func viewDidHide() { super.viewDidHide(); loggedFrame = nil; updateRunning() }
    public override func viewDidUnhide() { super.viewDidUnhide(); restart(); logShownIfVisible() }

    /// The place this view serves (set by `SQMascotPlace.makeView`); only used for the `[Pip]` log line.
    public var place: SQMascotPlace?
    private var loggedFrame: NSRect?

    /// True when Pip can be seen: in a window, no hidden ancestor, a non-empty frame.
    public var isShownWithSize: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
    }

    /// One line per time Pip becomes visible (or moves while visible): `[Pip] place=projectEmpty shown frame=...`.
    /// A run can be checked from the log; the frame is in window coordinates.
    func logShownIfVisible() {
        guard let place, isShownWithSize else { return }
        let f = convert(bounds, to: nil)
        guard loggedFrame != f else { return }
        loggedFrame = f
        NSLog("[Pip] place=%@ shown frame=%@", place.rawValue, NSStringFromRect(f))
    }

    public override func layout() { super.layout(); logShownIfVisible() }

    /// Plays the animation from its start again (a once animation replays).
    public func restart() {
        reactor.reset(seed: UInt64.random(in: 1...UInt64.max))
        reactor.restPause = restPause
        started = false
        updateRunning()
    }

    private func motionPreferenceChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        restart()
    }

    private var shouldRun: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && (window?.occlusionState.contains(.visible) ?? false)
    }

    private func updateRunning() {
        if reduceMotion {
            stopLink()
            shown = animation.still
            needsDisplay = true
            return
        }
        guard shouldRun else { stopLink(); return }
        if !started { started = true; reactor.start(); shown = reactor.pose }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = 0
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = lastTimestamp == 0 ? 1000.0 / 60 : min(64, (now - lastTimestamp) * 1000)
        lastTimestamp = now
        shown = reactor.advance(dt)
        let calm = reactor.isCalm
        l.preferredFrameRateRange = calm ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
                                         : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        needsDisplay = true
    }

    // MARK: reactions (sleeping Pip only)

    /// M3: a drag with files entered the place. Returns false when this Pip does not react (or motion is reduced).
    @discardableResult
    public func dragBegan() -> Bool {
        guard !reduceMotion, reactor.dragBegan() else { return false }
        wakeFrame()
        return true
    }

    /// The dragged item is at `point` (this view's coordinates, flipped: y grows down).
    public func dragMoved(to point: NSPoint) {
        reactor.dragMoved(dx: Double(point.x - bounds.midX), dy: Double(point.y - bounds.midY))
    }

    /// The drag ended: `dropped` hops Pip away, else he goes back to sleep.
    public func dragEnded(dropped: Bool) {
        reactor.dragEnded(dropped: dropped)
        wakeFrame()
    }

    /// R2: one eye opens while the pointer is over `host` (the empty monitor), falls shut when it leaves.
    public func reactToHover(in host: NSView) {
        if let a = hoverArea { hoverHost?.removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        host.addTrackingArea(a)
        hoverArea = a
        hoverHost = host
    }

    public override func mouseEntered(with event: NSEvent) {
        guard !reduceMotion else { return }
        reactor.hoverChanged(true)
        wakeFrame()
    }

    public override func mouseExited(with event: NSEvent) {
        reactor.hoverChanged(false)
        wakeFrame()
    }

    /// A reaction needs frames now (the link may idle at 30 fps or be stopped).
    private func wakeFrame() {
        updateRunning()
        needsDisplay = true
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let drawn = reactor.animation
        let vb = side <= 24 ? CGRect(x: 125, y: 268, width: 774, height: 774) : drawn.viewBox
        let s = side / vb.width
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -vb.minX, y: -vb.minY)
        if let c = drawn.clipBottom { ctx.clip(to: CGRect(x: -400, y: -900, width: 1900, height: c + 900)) }
        SQMascotArt.draw(shown, tight: tight, in: ctx)
        ctx.restoreGState()
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            if let a = hoverArea { hoverHost?.removeTrackingArea(a) }
        }
    }
}
