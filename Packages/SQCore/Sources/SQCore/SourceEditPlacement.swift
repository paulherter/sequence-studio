import Foundation

/// Sequence In/Out marks and where a Source edit lands (Premiere: In and Out both include their own frame, so
/// In = 10 and Out = 20 cover 11 frames; the range is stored half-open, `end = Out + one frame`).
extension Timeline {
    /// Where a Source edit of `sourceDuration` starts on the sequence (three-point rule): at the sequence In when one is
    /// set; else, with only a sequence Out, back-timed so the clip ends at the Out (`markOut` is the stored end, one
    /// frame past the Out frame; never before 0); else at the playhead.
    public static func sourceEditPlacement(sourceDuration: Time, markIn: Time?, markOut: Time?, playhead: Time) -> Time {
        if let i = markIn { return i }
        if let o = markOut { return max(.zero, o - sourceDuration) }
        return playhead
    }

    /// The explicit sequence marks. `inOut` always has both ends; an Out set without In is remembered by `outOnlyEnd`,
    /// an In set without Out ends at the sequence end.
    public var explicitMarks: (markIn: Time?, markOut: Time?) {
        guard let io = inOut else { return (nil, nil) }
        if io.start == .zero, outOnlyEnd == io.end { return (nil, io.end) }
        return (io.start, nil)
    }

    /// Start of an edit of `sourceDuration` using this sequence's marks (see the static function).
    public func sourceEditPlacement(sourceDuration: Time, playhead: Time) -> Time {
        let m = explicitMarks
        return Timeline.sourceEditPlacement(sourceDuration: sourceDuration, markIn: m.markIn, markOut: m.markOut, playhead: playhead)
    }

    /// Mark In at `t`. A later Out stays; an Out at or before the new In jumps to the end of the sequence. Allowed
    /// at any frame (Premiere).
    public mutating func markIn(at t: Time) {
        let end = inOut.map(\.end).flatMap { $0 > t ? $0 : nil } ?? max(duration, t + frameDuration)
        inOut = TimeRange(start: t, end: end)
        outOnlyEnd = nil
    }

    /// Mark Out at `t`: the frame at `t` is the last frame inside the range, so the stored end is `t + one frame`
    /// (allowed at frame 0: a one-frame range). An In after the new Out is dropped (In falls back to 0).
    public mutating func markOut(at t: Time) {
        let end = t + frameDuration
        let m = explicitMarks
        if let i = m.markIn, i <= t {
            inOut = TimeRange(start: i, end: end)
            outOnlyEnd = nil
        } else {
            inOut = TimeRange(start: .zero, end: end)
            outOnlyEnd = end
        }
    }
}
