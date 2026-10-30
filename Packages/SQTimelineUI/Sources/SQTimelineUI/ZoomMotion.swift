import Foundation

/// "Zoom in motion": while zoom steps keep arriving the timeline may draw at 1x backing scale (about a quarter of the
/// pixels to fill); a short quiet period after the last step it goes back to full scale with one redraw.
/// Pure state with injected time, so the rules are testable; `TimelineView` owns the layer scale and the timer.
struct ZoomMotion: Equatable {
    /// Quiet time after the last step that ends the motion (one constant).
    static let quietPeriod: TimeInterval = 0.1
    /// Off: always full scale (measurement only; env `SQ_NO_ZOOM_1X`).
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["SQ_NO_ZOOM_1X"] == nil

    enum Step { case continuous, discrete }

    private(set) var active = false
    private var lastStep: TimeInterval?
    /// When the quiet period ends, while `active`.
    private(set) var deadline: TimeInterval?

    /// A zoom step arrived (pinch, scroll zoom, slider: `.continuous`; a key press: `.discrete`). Returns true when this
    /// step enters the motion. A discrete step enters only as the second within the quiet period, so one key press
    /// never flashes a soft frame.
    mutating func step(_ kind: Step, now: TimeInterval) -> Bool {
        guard Self.enabled else { return false }
        defer { lastStep = now }
        let enter = kind == .continuous || (lastStep.map { now - $0 < Self.quietPeriod } ?? false)
        if enter || active {
            let entered = !active
            active = true
            deadline = now + Self.quietPeriod
            return entered
        }
        return false
    }

    /// A frame of a running zoom animation: keeps an active motion alive; never starts one.
    mutating func animationFrame(now: TimeInterval) {
        if active { deadline = now + Self.quietPeriod; lastStep = now }
    }

    /// Timer or any later event. Returns true when the motion ended now.
    mutating func tick(now: TimeInterval) -> Bool {
        guard active, let d = deadline, now >= d else { return false }
        return end()
    }

    /// Gesture end, window resigned or hidden, or the sharp redraw is wanted now. Returns true if it was active.
    @discardableResult
    mutating func end() -> Bool {
        let was = active
        active = false; deadline = nil; lastStep = nil
        return was
    }
}
