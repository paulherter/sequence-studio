import Foundation

/// How a Fast Cut replace fits the new media into the replaced main-track clip (docs/NEXT F2). All four keep the
/// replaced clip's length and its id, so nothing ripples and attached clips stay attached.
public enum ReplaceMode: String, Sendable, CaseIterable, Codable {
    /// The source frame `sourceAnchor` lands on the timeline playhead.
    case atPlayhead
    /// The source In point fills the clip from its start.
    case fromStart
    /// The source Out point fills the clip up to its end.
    case fromEnd
    /// The whole source range is sped up or slowed down to the clip's length.
    case withRetime

    public var title: String {
        switch self {
        case .atPlayhead: "Replace at Playhead"
        case .fromStart: "Replace from Start"
        case .fromEnd: "Replace from End"
        case .withRetime: "Replace with Retime"
        }
    }
}

/// What a replace did that the user should hear about.
public struct ReplaceOutcome: Sendable, Equatable {
    /// How much shorter than the replaced clip the new media came out (zero = it filled the clip). The clip keeps
    /// the shorter length then.
    public var shortBy: Time
    public var isShort: Bool { shortBy > .zero }

    public var warning: String? {
        isShort ? "The new media is shorter than the clip it replaces; the clip got shorter." : nil
    }
}

extension Timeline {
    /// Replace on the main track in one of the four `ReplaceMode`s. `playhead` and `sourceAnchor` (the media time
    /// that sits on the playhead) matter for `.atPlayhead` only. Short media is not an error: the result is cropped
    /// to what exists and the outcome says by how much.
    @discardableResult
    public mutating func replaceOnMainTrack(_ id: Clip.ID, with clips: [Clip], mode: ReplaceMode,
                                            playhead: Time = .zero, sourceAnchor: Time = .zero) throws -> ReplaceOutcome {
        guard let old = find(id)?.clip, old.kind == .video else { throw EditError.clipNotFound }
        guard let v = clips.first(where: { $0.kind == .video }) else { throw EditError.wrongTrackKind }
        let target = old.timeline.duration
        var src = clips
        var headCut = Time.zero
        var short = Time.zero
        switch mode {
        case .fromStart:
            short = max(.zero, target - v.timeline.duration)
        case .fromEnd:
            headCut = max(.zero, v.timeline.duration - target)
            short = max(.zero, target - v.timeline.duration)
        case .atPlayhead:
            let into = min(max(playhead - old.start, .zero), target)
            let delta = sourceAnchor - v.source.start
            let offset = v.speed.isNormal ? delta : v.speed.unscale(delta)
            let w = offset - into
            headCut = max(.zero, w)
            short = max(.zero, target - (v.timeline.duration - headCut))
            if w.isNegative { short = max(short, .zero - w) }
        case .withRetime:
            let (n, o1) = v.source.duration.value.multipliedReportingOverflow(by: Int64(target.timescale))
            let (d, o2) = Int64(v.source.duration.timescale).multipliedReportingOverflow(by: target.value)
            let speed = o1 || o2 || target.value <= 0 ? ClipSpeed.normal : ClipSpeed(num: n, den: d)
            for i in src.indices where src[i].speedKeys == nil && !src[i].isGenerator && !src[i].isStill { src[i].speed = speed }
        }
        if headCut > .zero {
            src = src.compactMap { $0.cropped(to: TimeRange(start: $0.start + headCut, end: $0.timeline.end)) }
        }
        try replaceOnMainTrack(id, with: src, keepLength: true)
        return ReplaceOutcome(shortBy: short)
    }
}
