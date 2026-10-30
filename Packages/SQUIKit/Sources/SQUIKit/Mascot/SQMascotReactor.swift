import Foundation

/// Reactions of a sleeping Pip, clock-free like the player: M3 (a file is dragged over: wakes, eyes and head follow it,
/// hops away on drop or goes back to sleep) and R2 (the pointer is over the monitor: one eye opens, falls shut again on
/// leave). Only a `sleep` animation reacts. The view feeds events and frame deltas and draws `advance`'s pose.
public struct SQMascotReactor: Sendable {
    public enum Mode: Sendable { case base, waking, following, leaving, opening, open, dozing }

    public private(set) var mode = Mode.base
    /// What is drawn now (the base animation, or a reaction part with its own view box).
    public private(set) var animation: SQMascotAnimation
    public private(set) var player: SQMascotPlayer
    public var restPause: ClosedRange<Double>? {
        didSet { player.restPause = restPause }
    }

    private let base: SQMascotAnimation
    private let library: SQMascotLibrary
    private var follower: SQMascotFollower
    private var offset = (dx: 0.0, dy: 0.0)
    private var shown: SQMascotPose
    private var seed: UInt64

    public init(base: SQMascotAnimation, library: SQMascotLibrary, seed: UInt64, reacts: Bool) {
        self.reacts = reacts
        self.base = base
        self.library = library
        self.seed = seed
        animation = base
        player = SQMascotPlayer(animation: base, idle: library.idle, seed: seed)
        follower = SQMascotFollower(look: library.look)
        shown = player.pose
    }

    /// Only the sleeping Pip reacts (the places that show him asleep are the empty Project panel and monitor).
    public let reacts: Bool

    public var pose: SQMascotPose { shown }
    public mutating func start() { player.start(); shown = player.pose }

    /// 30 fps is enough when nothing moves but breathing.
    public var isCalm: Bool { player.resting && !player.isBusy && mode != .following }

    // MARK: events

    /// A drag entered the place. Returns false when this Pip does not react.
    @discardableResult
    public mutating func dragBegan() -> Bool {
        guard reacts, mode == .base || mode == .opening || mode == .open || mode == .dozing else { return false }
        swap(to: library.animation(.dragWake), playing: true)
        follower = SQMascotFollower(look: library.look)
        mode = .waking
        return true
    }

    /// Where the dragged item is, as an offset from Pip's center in points (y grows down).
    public mutating func dragMoved(dx: Double, dy: Double) {
        offset = (dx, dy)
    }

    /// The drag ended: `dropped` hops Pip away, else he goes back to sleep.
    public mutating func dragEnded(dropped: Bool) {
        guard mode == .waking || mode == .following else { return }
        if dropped {
            swap(to: library.animation(.dragAway), playing: true)
            mode = .leaving
        } else {
            returnToBase()
        }
    }

    public mutating func hoverChanged(_ inside: Bool) {
        guard reacts else { return }
        if inside, mode == .base || mode == .dozing {
            swap(to: library.animation(.hoverOpen), playing: true)
            mode = .opening
        } else if !inside, mode == .opening || mode == .open {
            swap(to: library.animation(.hoverClose), playing: true)
            mode = .dozing
        }
    }

    /// Back to the plain animation (view hidden, shown again).
    public mutating func reset(seed: UInt64) {
        self.seed = seed
        mode = .base
        animation = base
        player = SQMascotPlayer(animation: base, idle: library.idle, seed: seed)
        player.restPause = restPause
        shown = player.pose
    }

    @discardableResult
    public mutating func advance(_ dt: Double) -> SQMascotPose {
        switch mode {
        case .following:
            shown = follower.advance(dt, dx: offset.dx, dy: offset.dy)
        case .waking:
            shown = player.advance(dt)
            if player.resting { mode = .following }
        case .opening:
            shown = player.advance(dt)
            if player.resting { mode = .open }
        case .dozing:
            shown = player.advance(dt)
            if player.resting { returnToBase() }
        case .base, .open, .leaving:
            shown = player.advance(dt)
        }
        return shown
    }

    private mutating func returnToBase() {
        swap(to: base, playing: false)
        player.restPause = restPause
        player.start()
        shown = player.pose
        mode = .base
    }

    private mutating func swap(to a: SQMascotAnimation, playing: Bool) {
        seed &+= 1
        animation = a
        player = SQMascotPlayer(animation: a, idle: library.idle, seed: seed, startPose: shown)
        if playing { player.playOnce() }
    }
}
