import Foundation

/// The state of the Magic mask's explicit tracking controls. A pick only stores its matte on the frame it was made on;
/// nothing follows it until the user asks: one frame back / forward (`step`), back to the clip's start / on to its end
/// (`run`, continuous until it ends or Stop). One piece at a time.
public struct MagicTrackControl: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Tracking `forward`; `frame` is the source time of the frame being done, `done` the frames finished.
        case tracking(forward: Bool, step: Bool, frame: Double, done: Int, total: Int)
        /// The user pressed Stop; `done` frames were kept.
        case stopped(done: Int)
    }
    public enum Command: Equatable, Sendable {
        case step(forward: Bool)
        case run(forward: Bool)
    }
    /// What to track: source seconds, `from` to `to`.
    public struct Leg: Equatable, Sendable {
        public var from: Double, to: Double, forward: Bool, frames: Int
    }

    public private(set) var phase: Phase = .idle
    private var leg: Leg?
    public init() {}

    public var isTracking: Bool { if case .tracking = phase { true } else { false } }

    /// A pick was stored. It never starts tracking: the matte is the keyframe of the frame it was made on.
    public mutating func pickStored() {
        if !isTracking { phase = .idle }
    }

    /// Starts `command` from source time `playhead`; `edge` is the clip's last (forward) or first (backward) source time,
    /// `frame` one source frame in seconds. nil (and no change) while tracking or when there is no frame to go to.
    public mutating func begin(_ command: Command, playhead: Double, edge: Double, frame: Double) -> Leg? {
        guard !isTracking, frame > 0 else { return nil }
        let forward: Bool, step: Bool
        switch command {
        case .step(let f): forward = f; step = true
        case .run(let f): forward = f; step = false
        }
        var to = step ? playhead + (forward ? frame : -frame) : edge
        to = forward ? min(to, edge) : max(to, edge)
        let distance = forward ? to - playhead : playhead - to
        guard distance > frame * 0.25 else { return nil }
        let frames = max(Int((distance / frame).rounded()) + 1, 2)
        let l = Leg(from: playhead, to: to, forward: forward, frames: frames)
        leg = l
        phase = .tracking(forward: forward, step: step, frame: playhead, done: 0, total: frames)
        return l
    }

    /// `fraction` (0...1) of the running leg is done.
    public mutating func progress(_ fraction: Double) {
        guard case .tracking(let f, let step, _, _, let total) = phase, let l = leg else { return }
        let p = min(max(fraction, 0), 1)
        phase = .tracking(forward: f, step: step, frame: l.from + (l.to - l.from) * p, done: Int((p * Double(total)).rounded(.down)), total: total)
    }

    /// The user's Stop. False when nothing was tracking.
    @discardableResult
    public mutating func stop() -> Bool {
        guard case .tracking(_, _, _, let done, _) = phase else { return false }
        phase = .stopped(done: done)
        leg = nil
        return true
    }

    /// The leg ended by itself (all frames, the object was lost, an error). A stop stays `stopped`.
    public mutating func finish() {
        if case .tracking = phase { phase = .idle }
        leg = nil
    }

    /// One line for the track row.
    public var statusText: String {
        switch phase {
        case .idle: "Idle"
        case .tracking(let forward, _, _, let done, let total): "Tracking \(forward ? "forward" : "backward"): \(done) of \(total) frames"
        case .stopped(let done): "Stopped after \(done) frames"
        }
    }
}
