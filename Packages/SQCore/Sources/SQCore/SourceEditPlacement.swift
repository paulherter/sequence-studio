import Foundation

/// Sequence In/Out marks and where a Source edit lands (Premiere: In and Out both include their own frame, so
/// In = 10 and Out = 20 cover 11 frames; the range is stored half-open, `end = Out frame + one frame`).
extension Timeline {
    /// Where a Source edit of `sourceDuration` starts on the sequence (three-point rule): at the sequence In when one is
    /// set; else, with only a sequence Out, back-timed so the clip ends at the Out (`markOut` is the stored end, one
    /// frame past the Out frame; never before 0); else at the playhead.
    public static func sourceEditPlacement(sourceDuration: Time, markIn: Time?, markOut: Time?, playhead: Time) -> Time {
        if let i = markIn { return i }
        if let o = markOut { return max(.zero, o - sourceDuration) }
        return playhead
    }

    /// The explicit sequence marks (stored Out = one frame past the Out frame).
    public var explicitMarks: (markIn: Time?, markOut: Time?) {
        guard let io = inOut else { return (nil, nil) }
        switch inOutKind {
        case .inOnly: return (io.start, nil)
        case .outOnly: return (nil, io.end)
        case .both: return (io.start, io.end)
        case nil: return io.end >= duration ? (io.start, nil) : (io.start, io.end)
        }
    }

    /// Start of an edit of `sourceDuration` using this sequence's marks (see the static function).
    public func sourceEditPlacement(sourceDuration: Time, playhead: Time) -> Time {
        let m = explicitMarks
        return Timeline.sourceEditPlacement(sourceDuration: sourceDuration, markIn: m.markIn, markOut: m.markOut, playhead: playhead)
    }

    /// Mark In at `t`. A later Out stays; an Out at or before the new In jumps to the end of the sequence. Allowed
    /// at any frame (Premiere).
    public mutating func markIn(at t: Time) {
        if let o = explicitMarks.markOut, o > t {
            inOut = TimeRange(start: t, end: o); inOutKind = .both
        } else {
            inOut = TimeRange(start: t, end: max(duration, t + frameDuration)); inOutKind = .inOnly
        }
    }

    /// Mark Out at `t`: the frame at `t` is the last frame inside the range, so the stored end is `t + one frame`
    /// (allowed at frame 0: a one-frame range). An In after the new Out is dropped (In falls back to 0).
    public mutating func markOut(at t: Time) {
        let end = t + frameDuration
        if let i = explicitMarks.markIn, i <= t {
            inOut = TimeRange(start: i, end: end); inOutKind = .both
        } else {
            inOut = TimeRange(start: .zero, end: end); inOutKind = .outOnly
        }
    }

    /// In and Out both set (Mark Clip, Mark Selection, dragging a range).
    public mutating func setMarkedRange(_ r: TimeRange?) {
        inOut = r
        inOutKind = r == nil ? nil : .both
    }

    /// Clear In: the In goes away, a marked Out stays (the range then starts at 0).
    public mutating func clearIn() {
        guard let io = inOut else { return }
        let m = explicitMarks
        guard m.markIn != nil else { return }
        if m.markOut != nil { inOut = TimeRange(start: .zero, end: io.end); inOutKind = .outOnly } else { setMarkedRange(nil) }
    }

    /// Clear Out: the Out goes away, a marked In stays (the range then runs to the end of the sequence).
    public mutating func clearOut() {
        guard let io = inOut else { return }
        let m = explicitMarks
        guard m.markOut != nil else { return }
        if let i = m.markIn { inOut = TimeRange(start: i, end: max(duration, i + frameDuration)); inOutKind = .inOnly } else { setMarkedRange(nil) }
    }
}

/// What a Source edit places and where (Premiere three- and four-point rules).
public struct SourceEditPlan: Sendable, Equatable {
    public var source: TimeRange
    public var at: Time
    /// Both sequence marks and both source marks were set: Premiere would ask (Fit Clip); we use the sequence In/Out
    /// and the source In and say so.
    public var usedFourPointDefault: Bool
}

extension Timeline {
    /// - Both sequence marks: the sequence range sets the length and position; source In (else Out, else the media start)
    ///   chooses the part of the source. With both source marks too, the source In is used and `usedFourPointDefault` is set.
    /// - Sequence Out only: the source range ends at that Out; when there is less room before it than the source is long,
    ///   the head of the source is cut so the clip starts at 0.
    /// - Sequence In only, or none: the source range lands at the In (else the playhead).
    /// Lengths are whole sequence frames; a source shorter than the wanted length shortens the clip. nil = nothing to place.
    public static func sourceEditPlan(sourceMarks m: SourceMarks, total: Time, sequenceIn: Time?, sequenceOut: Time?,
                                      playhead: Time, frameDuration fd: Time, isStill: Bool = false) -> SourceEditPlan? {
        func whole(_ t: Time) -> Time { max(t.snapped(to: fd), fd) }
        func fit(_ start: Time, _ d: Time) -> TimeRange? {
            var d = d
            if !isStill, start + d > total { d = (total - start).snapped(to: fd); if start + d > total { d = d - fd } }
            return d > .zero ? TimeRange(start: start, duration: d) : nil
        }
        if let si = sequenceIn, let so = sequenceOut, so > si {
            let want = whole(so - si)
            let start: Time
            if let i = m.markIn { start = i } else if let o = m.markOut { start = max(.zero, o - want) } else { start = .zero }
            guard let src = fit(start, want) else { return nil }
            return SourceEditPlan(source: src, at: si, usedFourPointDefault: m.markIn != nil && m.markOut != nil)
        }
        guard let range = isStill ? TimeRange(start: .zero, duration: total) : Timeline.sourceEditRange(marks: m, total: total) else { return nil }
        var d = whole(range.duration)
        if !isStill, range.start + d > total { d = d - fd }
        guard d > .zero else { return nil }
        if let si = sequenceIn { return SourceEditPlan(source: TimeRange(start: range.start, duration: d), at: si, usedFourPointDefault: false) }
        if let so = sequenceOut {
            if so >= d { return SourceEditPlan(source: TimeRange(start: range.start, duration: d), at: so - d, usedFourPointDefault: false) }
            // Not enough room before the Out: cut the head of the source, the clip starts at 0 and still ends at the Out.
            let keep = whole(so)
            let start = range.start + d - keep
            return SourceEditPlan(source: TimeRange(start: start, duration: keep), at: .zero, usedFourPointDefault: false)
        }
        return SourceEditPlan(source: TimeRange(start: range.start, duration: d), at: playhead.snapped(to: fd), usedFourPointDefault: false)
    }
}
