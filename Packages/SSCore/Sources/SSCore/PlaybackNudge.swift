import Foundation

extension PlaybackRate {
    /// Shift+L / Shift+J (Premiere "Shuttle Slow Right / Left"): a fine change of the playing speed by 1/4.
    /// From a stop it starts at 1.25x in that direction. In the key's own direction it speeds up (at most 8x); against the
    /// current direction it slows down and stops when the speed reaches zero.
    public func nudged(forward: Bool) -> PlaybackRate {
        let dir: Int32 = forward ? 1 : -1
        if isPaused { return PlaybackRate(dir * 5, 4) }
        let signed = num * 4 + dir * den              // (num/den + dir/4) * 4 * den, reduced by the initializer
        let r = PlaybackRate(signed, den * 4)
        if r.isPaused || (r.isForward != isForward) { return .zero }
        return Int64(abs(r.num)) > 8 * Int64(r.den) ? self : r
    }
}
