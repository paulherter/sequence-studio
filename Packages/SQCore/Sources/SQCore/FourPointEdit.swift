import Foundation

/// What to do when a Source edit has all four points (source In/Out and sequence In/Out) and they disagree in length.
/// Mirrors Premiere's Edit Range Mismatch choices.
public enum FourPointChoice: String, Sendable, Hashable, CaseIterable {
    /// Change Clip Speed (Fit to Fill): the marked source range plays over the marked sequence range.
    case fitClip
    case ignoreSourceIn, ignoreSourceOut, ignoreSequenceIn, ignoreSequenceOut
}

/// Result of a four-point resolution: the source range played, where the clip starts, its speed and its length on the
/// timeline (`speed.unscale(source.duration)`).
public struct FourPointPlacement: Sendable, Equatable {
    public var source: TimeRange
    public var at: Time
    public var speed: ClipSpeed
    public var duration: Time
}

extension Timeline {
    /// Pure four-point resolution. `source` and `sequence` are the marked ranges (half-open, frame aligned on the
    /// sequence side). `total` is the media length (nil = unbounded, stills). Lengths are whole sequence frames, at least
    /// one. nil when a range is empty, the source is out of the media, or nothing is left to place.
    /// - fitClip: source as marked, at the sequence In, speed = source length / sequence length (clamped to the speed range;
    ///   the resulting length then differs from the sequence range).
    /// - ignoreSourceIn: source Out and the sequence range stand; the source starts as far back as the sequence length
    ///   needs. A source with less material before the Out gives a shorter clip, still starting at the sequence In.
    /// - ignoreSourceOut: source In and the sequence range stand; the source is cut at the media end if it is too short.
    /// - ignoreSequenceOut: source as marked, at the sequence In, speed 100 %.
    /// - ignoreSequenceIn: source as marked, ending at the sequence Out; when that would start before 0 the head of the
    ///   source is cut.
    public static func resolveFourPoint(source: TimeRange, sequence: TimeRange, choice: FourPointChoice,
                                        total: Time?, frameDuration fd: Time) -> FourPointPlacement? {
        guard !source.isEmpty, !sequence.isEmpty, source.start >= .zero else { return nil }
        if let total, source.end > total { return nil }
        func whole(_ t: Time) -> Time { max(t.snapped(to: fd), fd) }
        func floored(_ t: Time) -> Time { Time.frames(t.frameIndex(frameDuration: fd), frameDuration: fd) }
        /// A forward, 100 % placement of `range` at `at`, cut to whole frames and to the media.
        func normal(_ range: TimeRange, at: Time, length: Time) -> FourPointPlacement? {
            var len = length
            if let total, range.start + len > total { len = floored(total - range.start) }
            guard len > .zero, range.start >= .zero else { return nil }
            return FourPointPlacement(source: TimeRange(start: range.start, duration: len), at: at, speed: .normal, duration: len)
        }
        let seqLen = whole(sequence.duration)
        switch choice {
        case .fitClip:
            let d = source.duration
            let speed = ClipSpeed(num: d.value * seqLen.timescale, den: d.timescale * seqLen.value)
            return FourPointPlacement(source: source, at: sequence.start, speed: speed, duration: speed.unscale(d))
        case .ignoreSourceIn:
            let start = max(source.end - seqLen, .zero)
            return normal(TimeRange(start: start, end: source.end), at: sequence.start, length: floored(source.end - start))
        case .ignoreSourceOut:
            return normal(TimeRange(start: source.start, duration: seqLen), at: sequence.start, length: seqLen)
        case .ignoreSequenceOut:
            return normal(source, at: sequence.start, length: whole(source.duration))
        case .ignoreSequenceIn:
            let len = whole(source.duration)
            let at = sequence.end - len
            if at >= .zero { return normal(source, at: at, length: len) }
            let cut = .zero - at
            guard len > cut else { return nil }
            return normal(TimeRange(start: source.start + cut, duration: len - cut), at: .zero, length: len - cut)
        }
    }
}
