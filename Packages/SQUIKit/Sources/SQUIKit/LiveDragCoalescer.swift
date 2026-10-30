import Foundation

/// K6: a pointer drag on a number control (ScrubField, SQSlider, LumetriSlider) moves the control on every mouse event,
/// but hands the value to its owner (model edit, session commit, Program re-render, every panel's sync) at most once per
/// display frame. The first change of a drag goes out at once, later ones wait until a frame has passed since the last
/// one ended and then send only the newest value; `flush()` before `onEnd` sends what is still waiting, so the final
/// value and the gesture's one undo step are exactly as without coalescing. `drop()` (Esc) forgets what is waiting.
///
/// The gap is measured from the END of the previous hand-off, so a slow owner (say 30 ms per edit) still leaves the main
/// thread a full frame between two edits to draw the control and read the pointer.
@MainActor
public final class LiveDragCoalescer {
    /// Spacing between two hand-offs (one 60 Hz frame).
    public static let frame: TimeInterval = 1.0 / 60

    /// Seconds, monotonic. Replaceable in tests.
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs `body` after `delay` seconds on the main actor, in every run-loop mode (a slider's own tracking loop runs in
    /// event-tracking mode). Replaceable in tests.
    public var schedule: (_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }

    private let emit: @MainActor (Double) -> Void
    private var lastEnd: TimeInterval = -.infinity
    /// Newest value not handed off yet.
    public private(set) var pending: Double?
    private var scheduled = false
    /// Bumped by `begin` / `drop`, so a delayed flush of an earlier drag does nothing.
    private var generation = 0
    /// Hand-offs so far (tests).
    public private(set) var emitted = 0
    /// True once the open drag has handed any value to the owner (after `begin`). On Esc the owner may hold a value the
    /// control no longer shows, so the start value must be sent again even when the control is already at it.
    public private(set) var sentInDrag = false

    public init(emit: @escaping @MainActor (Double) -> Void) { self.emit = emit }

    /// A new drag: its first value goes out at once.
    public func begin() {
        generation &+= 1
        lastEnd = -.infinity
        pending = nil
        scheduled = false
        sentInDrag = false
    }

    /// A new value of the open drag.
    public func submit(_ v: Double) {
        let t = now()
        let wait = Self.frame - (t - lastEnd)
        if wait <= 0, !scheduled {
            pending = nil
            fire(v)
            return
        }
        pending = v
        guard !scheduled else { return }
        scheduled = true
        let g = generation
        schedule(max(wait, 0)) { [weak self] in
            guard let self, g == generation else { return }
            scheduled = false
            flush()
        }
    }

    /// Sends the waiting value now (drag end, before `onEnd`).
    public func flush() {
        guard let v = pending else { return }
        pending = nil
        fire(v)
    }

    /// Forgets the waiting value (Esc: the control restores the start value itself).
    public func drop() {
        generation &+= 1
        pending = nil
        scheduled = false
    }

    private func fire(_ v: Double) {
        emitted += 1
        sentInDrag = true
        emit(v)
        lastEnd = now()
    }
}
