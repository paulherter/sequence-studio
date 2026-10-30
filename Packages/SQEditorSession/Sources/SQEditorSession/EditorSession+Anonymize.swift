import Foundation
import SQCore

/// What an Anonymize run works on, captured when the command starts (the analysis runs off the main thread; the clip may
/// be edited meanwhile).
public struct AnonymizeRequest: Sendable, Hashable {
    public var timeline: Timeline.ID
    public var clip: Clip.ID
    public var clipName: String
    public var media: UUID
    public var path: String
    /// Source seconds of the clip's first and last frame.
    public var first: Double
    public var last: Double
    /// Source seconds of the frame the people are picked on (the playhead's, else the clip's first).
    public var anchor: Double
    /// Seconds between two frames of the sequence.
    public var frameGap: Double
    public var pictureWidth: Int
    public var pictureHeight: Int
    /// Which source frames the clip showed when the run started: the result is applied only to a clip that still shows them.
    public var timing: AnonymizeTiming
}

/// What decides which source frames a clip shows.
public struct AnonymizeTiming: Sendable, Hashable {
    public var source: TimeRange
    public var speed: ClipSpeed
    public var reversed: Bool
    public var speedKeys: SpeedKeys?
    public var holdFrame: Time?

    public init(_ c: Clip) {
        source = c.source; speed = c.speed; reversed = c.reversed; speedKeys = c.speedKeys; holdFrame = c.holdFrame
    }
}

/// What `applyAnonymize` did. Anything but `.applied` changed nothing.
public enum AnonymizeApplyResult: Sendable, Hashable {
    case applied
    /// The clip is gone, on a locked track or shows other media now.
    case clipGone
    /// The clip was trimmed, slipped, retimed or reversed during the run: the followed frames are not the ones it shows.
    case clipRetimed

    public var applied: Bool { self == .applied }

    /// What the user reads when nothing was written.
    public var message: String {
        switch self {
        case .applied: ""
        case .clipGone: "Anonymize: the clip was removed or locked meanwhile. Nothing was changed."
        case .clipRetimed: "The clip was trimmed, slipped or retimed while Anonymize was following the people, so the result does not fit the frames it shows now. Nothing was changed. Run Anonymize again."
        }
    }
}

/// One line of the list for a manual check after Anonymize.
public struct AnonymizeCheckLine: Sendable, Hashable {
    /// Sequence time of the first frame.
    public var time: Time
    public var text: String
    /// The person may be outside the cover here (`AnonymizeCheck.Reason.isCritical`): listed first, never cut from the list.
    public var critical: Bool

    public init(time: Time, text: String, critical: Bool = false) { self.time = time; self.text = text; self.critical = critical }

    /// The lines a list of at most `limit` uncritical lines shows: every critical line, first, then the others in time
    /// order up to `limit`; `more` = how many uncritical lines are left out.
    public static func shown(_ lines: [AnonymizeCheckLine], limit: Int) -> (lines: [AnonymizeCheckLine], more: Int) {
        let critical = lines.filter(\.critical).sorted { $0.time < $1.time }
        let rest = lines.filter { !$0.critical }.sorted { $0.time < $1.time }
        return (critical + rest.prefix(max(limit, 0)), max(rest.count - max(limit, 0), 0))
    }
}

/// F7.11 Anonymize: covers people of one clip with a Mosaic or a blur limited to tracked Magic masks. The analysis
/// (SQAnalysis `Anonymizer`) runs in the host; this is the clip choice and the one undo step that writes the result.
extension EditorSession {
    /// The clip Anonymize works on: of the command clips with media video (selection, else under the playhead) the one
    /// under the playhead, else the first.
    public var anonymizeTarget: Clip? {
        let c = reframeTargets
        return c.first { $0.timeline.contains(playhead) } ?? c.first
    }

    public func anonymizeRequest() -> AnonymizeRequest? {
        guard let t = activeTimeline, let c = anonymizeTarget, let m = project.media(c.media),
              let size = project.pictureSize(of: c) else { return nil }
        func seconds(_ local: Time) -> Double { let s = c.sourceInstant(atLocal: local); return Double(s.value) / Double(max(s.timescale, 1)) }
        let fd = t.frameDuration
        let lastLocal = max(c.duration - fd, .zero)
        var lo = min(seconds(.zero), seconds(lastLocal)), hi = max(seconds(.zero), seconds(lastLocal))
        // A speed ramp can run backward in the middle of the clip: the earliest and latest source frame it shows are then
        // not its edge frames, so every frame is asked.
        if c.speedKeys != nil, fd > .zero {
            var local = Time.zero
            while local <= lastLocal {
                let v = seconds(local)
                lo = min(lo, v); hi = max(hi, v)
                local = local + fd
            }
        }
        let at = c.timeline.contains(playhead) ? seconds(playhead - c.start) : seconds(.zero)
        return AnonymizeRequest(timeline: t.id, clip: c.id, clipName: c.name, media: m.id, path: m.path, first: lo, last: hi,
                                anchor: min(max(at, lo), hi), frameGap: Double(fd.value) / Double(max(fd.timescale, 1)),
                                pictureWidth: size.width, pictureHeight: size.height, timing: AnonymizeTiming(c))
    }

    /// Writes the masks and the cover into the clip as one undo step. Nothing is written when the clip is gone, on a locked
    /// track, shows other media now, or shows other source frames than when the run started (trim, slip, speed, reverse).
    @discardableResult
    public func applyAnonymize(_ picks: [MagicSelection], target: AnonymizeTarget, cover: AnonymizeCover, subjectWidth: Double,
                               request r: AnonymizeRequest) -> AnonymizeApplyResult {
        guard !picks.isEmpty, let t = project.timeline(r.timeline),
              let now = t.tracks.first(where: { tr in !tr.isLocked && tr.clips.contains { $0.id == r.clip && $0.media == r.media } })?
                .clips.first(where: { $0.id == r.clip }) else { return .clipGone }
        guard AnonymizeTiming(now) == r.timing else { return .clipRetimed }
        var applied = false
        do {
            try perform("Anonymize") { p in
                try p.edit(r.timeline) { t in
                    applied = false
                    for tr in t.tracks where !tr.isLocked {
                        guard let c = tr.clips.first(where: { $0.id == r.clip }) else { continue }
                        var n = c
                        n.addAnonymize(picks, target: target, cover: cover, subjectWidth: subjectWidth,
                                       frameWidth: r.pictureWidth, frameHeight: r.pictureHeight)
                        try t.replaceClip(n)
                        applied = true
                    }
                }
            }
        } catch { return .clipGone }
        return applied ? .applied : .clipGone
    }

    /// The check list as sequence times (a range that lies outside the clip now is left out). Ranges where the person may
    /// be outside the cover come first, then by time.
    public func anonymizeCheckLines(_ checks: [AnonymizeCheck], request r: AnonymizeRequest) -> [AnonymizeCheckLine] {
        guard let t = project.timeline(r.timeline), let c = t.tracks.flatMap(\.clips).first(where: { $0.id == r.clip }) else { return [] }
        let fd = t.frameDuration
        func time(_ s: Double) -> Time { c.timelineTime(forSource: Time(Int64((s * 90_000).rounded()), 90_000), frameDuration: fd) }
        return checks.compactMap { k in
            let a = time(k.from), b = time(k.to)
            let from = min(a, b), to = max(a, b)
            guard to >= c.start, from < c.start + c.duration else { return nil }
            let tc = MarkersPanelModel.timecode(from, frameDuration: fd)
            let range = to > from ? "\(tc) to \(MarkersPanelModel.timecode(to, frameDuration: fd))" : tc
            return AnonymizeCheckLine(time: max(from, c.start), text: "\(range)  Person \(k.person + 1): \(k.reason.text)",
                                      critical: k.reason.isCritical)
        }.sorted { $0.critical != $1.critical ? $0.critical : $0.time < $1.time }
    }
}
