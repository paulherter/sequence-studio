import Foundation
import SQCore

/// Search in the transcript and in the caption list (Premiere: type the term, the instances are marked, the arrows move
/// between them). Pure functions; the views only draw and select.
public enum TranscriptSearch {
    /// UTF-16 ranges of every non-overlapping occurrence of `find` in `text`, in order.
    public static func matches(in text: String, find: String, caseSensitive: Bool) -> [NSRange] {
        guard !find.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while from < ns.length {
            let r = ns.range(of: find, options: opts, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound || r.length == 0 { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }

    /// Index of the match after (or before) `location`, wrapping at the ends. A match that starts at `location` counts
    /// as the current one, so repeated "next" moves on and "previous" goes back. Nil without matches.
    public static func step(_ matches: [NSRange], from location: Int, forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward { return matches.firstIndex { $0.location > location } ?? 0 }
        return matches.lastIndex { $0.location < location } ?? matches.count - 1
    }
}

extension Timeline {
    /// The caption of the next or previous match relative to the time `t` (a caption starting exactly at `t` is the
    /// current one), wrapping around. Nil without matches.
    public func captionMatch(find: String, caseSensitive: Bool, from t: Time, forward: Bool) -> CaptionItem.ID? {
        let ids = captionMatches(find: find, caseSensitive: caseSensitive)
        guard !ids.isEmpty else { return nil }
        let items = captionTracks.flatMap(\.items)
        func start(_ id: CaptionItem.ID) -> Time { items.first { $0.id == id }?.range.start ?? .zero }
        if forward { return ids.first { start($0) > t } ?? ids[0] }
        return ids.last { start($0) < t } ?? ids[ids.count - 1]
    }
}
