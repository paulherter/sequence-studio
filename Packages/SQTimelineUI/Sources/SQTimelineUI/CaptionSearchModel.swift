import Foundation
import SQCore

/// Find and replace over the caption tracks of a timeline (the popup on the caption track). Pure: the popup draws it,
/// the timeline view commits what `replacingCurrent` / `replacingAll` return as one undo step each.
public struct CaptionSearchModel: Sendable, Equatable {
    public var find = ""
    public var replacement = ""
    public var caseSensitive = false
    /// Limits the search to one caption track (nil: every track).
    public var track: CaptionTrack.ID?
    /// Matches in time order.
    public private(set) var matches: [CaptionTextMatch] = []
    /// Index of the current match in `matches`.
    public private(set) var current: Int?

    public init(track: CaptionTrack.ID? = nil) { self.track = track }

    public var currentMatch: CaptionTextMatch? { current.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }

    /// "3 of 12", "No matches", or nothing while the find text is empty.
    public var countLabel: String {
        if find.isEmpty { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\((current ?? 0) + 1) of \(matches.count)"
    }

    public var canReplace: Bool { currentMatch != nil && find != replacement }

    /// Searches `timeline` again. The current match stays the same occurrence when it still exists; otherwise it becomes
    /// the first match at or after `time` (the playhead), wrapping to the first one.
    public mutating func refresh(in timeline: Timeline, from time: Time = .zero) {
        let old = currentMatch
        matches = timeline.captionTextMatches(find: find, caseSensitive: caseSensitive, track: track)
        guard !matches.isEmpty else { current = nil; return }
        if let old, let i = matches.firstIndex(of: old) { current = i; return }
        current = matches.firstIndex { $0.time >= time } ?? 0
    }

    /// Next or previous match, wrapping at the ends.
    public mutating func step(forward: Bool) {
        guard !matches.isEmpty else { current = nil; return }
        let n = matches.count, i = current ?? (forward ? -1 : 0)
        current = ((i + (forward ? 1 : -1)) % n + n) % n
    }

    /// The timeline with the current match replaced, nil when there is nothing to replace or the track is locked.
    /// The model then points at the match that followed it.
    public mutating func replacingCurrent(in timeline: Timeline) -> Timeline? {
        guard canReplace, let m = currentMatch, let i = current else { return nil }
        var out = timeline
        guard (try? out.replaceCaptionMatch(m, with: replacement)) != nil, out != timeline else { return nil }
        matches = out.captionTextMatches(find: find, caseSensitive: caseSensitive, track: track)
        // The replacement may contain the find text again: step over it instead of matching it forever.
        let resume = m.range.lowerBound + replacement.count
        let after = matches.firstIndex { n in
            if n.caption == m.caption { return n.line > m.line || (n.line == m.line && n.range.lowerBound >= resume) }
            return n.time > m.time
        }
        current = matches.isEmpty ? nil : (after ?? min(i, matches.count - 1))
        return out
    }

    /// The timeline with every match replaced and how many there were, nil when nothing changes.
    public mutating func replacingAll(in timeline: Timeline) -> (timeline: Timeline, count: Int)? {
        guard !find.isEmpty, find != replacement, !matches.isEmpty else { return nil }
        var out = timeline
        guard let n = try? out.replaceCaptionText(find: find, with: replacement, caseSensitive: caseSensitive, track: track),
              n > 0 else { return nil }
        refresh(in: out)
        return (out, n)
    }
}
