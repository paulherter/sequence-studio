import Foundation

/// What the end of a play range does while a monitor plays: stop at the end (default), or wrap around (Loop).
/// `range` limits playback to an In..Out span (Premiere "Play In to Out"); nil = the whole sequence / clip.
public struct PlaybackBounds: Sendable, Hashable {
    public var loop = false
    public var range: TimeRange?

    public init(loop: Bool = false, range: TimeRange? = nil) { self.loop = loop; self.range = range }

    public enum Action: Sendable, Equatable {
        case none
        /// Pause and park the playhead here.
        case stop(at: Time)
        /// Continue from here at the same rate.
        case wrap(to: Time)
    }

    /// Decides what to do after frame `t` was shown. `duration` is the end of the content. Forward playback ends when
    /// the next frame would pass the end; reverse playback ends at the range start (or 0).
    public func action(at t: Time, rate: PlaybackRate, frameDuration fd: Time, duration: Time) -> Action {
        let start = range?.start ?? .zero
        let end = min(range?.end ?? duration, duration)
        guard end > start else { return .none }
        if rate.isForward, t + fd >= end { return loop ? .wrap(to: start) : .stop(at: end) }
        if rate.isReverse, t <= start, range != nil || loop { return loop ? .wrap(to: max(start, end - fd)) : .stop(at: start) }
        return .none
    }
}
