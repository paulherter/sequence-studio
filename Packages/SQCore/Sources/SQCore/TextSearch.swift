import Foundation

/// Find-in-text for the transcript and caption panels: case and diacritic insensitive ("o-ton" finds "O-Ton", "cafe"
/// finds "Café"). The text is one string, so a search term with spaces matches across word boundaries.
public enum TextSearch {
    /// UTF-16 ranges (in `text`) of every non-overlapping occurrence of `find`, in order.
    public static func matches(in text: String, find: String, caseSensitive: Bool = false,
                               diacriticSensitive: Bool = false) -> [NSRange] {
        guard !find.isEmpty else { return [] }
        let ns = text as NSString
        var opts: NSString.CompareOptions = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        if !diacriticSensitive { opts.insert(.diacriticInsensitive) }
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: find, options: opts, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound || r.length == 0 { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }
}

extension Timeline {
    /// Mark All for search hits: one marker per distinct hit time, named after the search text. A marker with the same name
    /// on the same frame is not added twice, so pressing it again changes nothing. Returns how many were added.
    @discardableResult
    public mutating func addSearchHitMarkers(at times: [Time], name: String) -> Int {
        var added = 0
        for t in times {
            let frame = max(.zero, t.snapped(to: frameDuration))
            if markers.contains(where: { $0.time == frame && $0.name == name }) { continue }
            addMarker(at: frame, name: name)
            added += 1
        }
        return added
    }
}
