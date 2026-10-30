import Foundation
import SQCore

/// Order of automatic proxy jobs: media the active timeline uses come before bin-only media, then by the earliest
/// timeline position of a clip, then by the bin order (stable).
public enum ProxyOrdering {
    /// Earliest clip start per media ID in `timeline` (nil = no active timeline: everything is bin-only).
    public static func firstUse(in timeline: Timeline?) -> [UUID: Time] {
        var out: [UUID: Time] = [:]
        for track in timeline?.tracks ?? [] {
            for clip in track.clips where out[clip.media].map({ clip.start < $0 }) ?? true { out[clip.media] = clip.start }
        }
        return out
    }

    /// `ids` sorted timeline-first; media without a use keep their relative (bin) order at the end.
    public static func sorted(_ ids: [UUID], firstUse: [UUID: Time]) -> [UUID] {
        ids.enumerated().sorted { a, b in
            switch (firstUse[a.element], firstUse[b.element]) {
            case let (x?, y?): x != y ? x < y : a.offset < b.offset
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }
}
