import Foundation

extension Project {
    /// Media whose spoken words contain `text` (case and diacritic insensitive). Media carry no transcript of their own:
    /// the words are the caption items that sit over a clip of that media in any sequence. Empty text = none.
    /// shortcut: only media already captioned in a sequence are found; upgrade when transcripts are stored per media.
    public func mediaIDs(spoken text: String) -> Set<MediaRef.ID> {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var found = Set<MediaRef.ID>()
        for tl in timelines {
            let hits = tl.captionTracks.flatMap(\.items).filter { !TextSearch.matches(in: $0.text, find: q).isEmpty }.map(\.range)
            guard !hits.isEmpty else { continue }
            for track in tl.tracks { for c in track.clips where !c.isNested && !c.isGenerator && !found.contains(c.media) {
                let r = c.timeline
                if hits.contains(where: { $0.start < r.end && r.start < $0.end }) { found.insert(c.media) }
            } }
        }
        return found
    }
}
