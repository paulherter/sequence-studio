import Foundation

/// What the end of a play range does while a monitor plays: stop at the end (default), or wrap around (Loop).
/// `range` limits playback to an In..Out span (Premiere "Play In to Out"); nil = the whole sequence / clip.
public struct PlaybackBounds: Sendable, Hashable {
    public var loop = false
    public var range: TimeRange? { didSet { if range == nil { returnTo = nil } } }
    /// Where the playhead goes when a non-looping range ends (Play Around: back to where it started). nil = stay at the end.
    public var returnTo: Time?

    public init(loop: Bool = false, range: TimeRange? = nil, returnTo: Time? = nil) {
        self.loop = loop; self.range = range; self.returnTo = returnTo
    }

    /// Preroll / postroll defaults (Premiere: 3 s before, 2 s after; Preferences > Playback).
    public static let defaultPreroll = Time(3, 1)
    public static let defaultPostroll = Time(2, 1)

    /// `range` extended by `preroll` before and `postroll` after, clamped to 0...`duration` (Shift+Space: Play In to Out
    /// with preroll and postroll). nil when the result is empty.
    public static func extended(_ range: TimeRange, preroll: Time, postroll: Time, duration: Time) -> TimeRange? {
        let start = max(.zero, range.start - max(preroll, .zero))
        let end = min(duration, range.end + max(postroll, .zero))
        return end > start ? TimeRange(start: start, end: end) : nil
    }

    /// Play Around (Shift+K): `preroll` before to `postroll` after the playhead, clamped to 0...`duration`.
    public static func playAround(at t: Time, preroll: Time, postroll: Time, duration: Time) -> TimeRange? {
        extended(TimeRange(start: t, duration: .zero), preroll: preroll, postroll: postroll, duration: duration)
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Pause and park the playhead here.
        case stop(at: Time)
        /// Continue from here at the same rate.
        case wrap(to: Time)
        /// Pause and put the playhead back at `to` (Play Around ended).
        case stopAndReturn(to: Time)
    }

    /// Decides what to do after frame `t` was shown. `duration` is the end of the content. Forward playback ends when
    /// the next frame would pass the end; reverse playback ends at the range start (or 0).
    public func action(at t: Time, rate: PlaybackRate, frameDuration fd: Time, duration: Time) -> Action {
        let start = range?.start ?? .zero
        let end = min(range?.end ?? duration, duration)
        guard end > start else { return .none }
        if rate.isForward, t + fd >= end {
            if loop { return .wrap(to: start) }
            if range != nil, let back = returnTo { return .stopAndReturn(to: back) }
            return .stop(at: end)
        }
        if rate.isReverse, t <= start, range != nil || loop {
            if loop { return .wrap(to: max(start, end - fd)) }
            if let back = returnTo { return .stopAndReturn(to: back) }
            return .stop(at: start)
        }
        return .none
    }
}
