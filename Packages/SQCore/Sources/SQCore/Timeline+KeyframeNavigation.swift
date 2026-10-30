import Foundation

/// Keyframe stepping, Solo and Trim to Range: small verbs the key commands call.
extension Timeline {
    /// Timeline times of every key of the given clips that lie inside the clip.
    public func keyframeTimes(of ids: Set<Clip.ID>) -> [Time] {
        var out: [Time] = []
        for c in tracks.lazy.flatMap(\.clips) where ids.contains(c.id) {
            for k in c.keyframeTimes where c.timeline.contains(c.start + k) { out.append(c.start + k) }
        }
        return Array(Set(out)).sorted()
    }

    /// First key of `clips` after `t` (timeline time), nil when there is none.
    public func nextKeyframe(after t: Time, clips ids: Set<Clip.ID>) -> Time? {
        keyframeTimes(of: ids).first { $0 > t }
    }

    /// Last key of `clips` before `t`, nil when there is none.
    public func previousKeyframe(before t: Time, clips ids: Set<Clip.ID>) -> Time? {
        keyframeTimes(of: ids).last { $0 < t }
    }

    /// Solo of the audio tracks that hold the given clips or their linked partners. All of them already solo: Solo goes off
    /// for them; otherwise it goes on. Returns the new state, nil when no audio track was involved.
    @discardableResult
    public mutating func toggleSolo(forClips ids: Set<Clip.ID>) -> Bool? {
        let links = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.link))
        var touched: [Int] = []
        for (i, t) in tracks.enumerated() where t.kind == .audio {
            if t.clips.contains(where: { ids.contains($0.id) || ($0.link.map(links.contains) ?? false) }) { touched.append(i) }
        }
        guard !touched.isEmpty else { return nil }
        let on = !touched.allSatisfy { tracks[$0].isSolo }
        for i in touched { tracks[i].isSolo = on }
        return on
    }

    /// Trim to Range (Final Cut's Trim to Selection): every given clip is cut back to `range`. Position is kept (a gap
    /// stays), Fast Cut closes up. Linked partners follow through the plain trim. Returns how many clips changed.
    @discardableResult
    public mutating func trimToRange(_ ids: Set<Clip.ID>, range: TimeRange) throws -> Int {
        func find(_ id: Clip.ID) -> Clip? { tracks.lazy.flatMap(\.clips).first { $0.id == id } }
        var changed = 0
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var c = find(id) else { continue }
            var did = false
            if c.timeline.start < range.start, range.start < c.timeline.end {
                let d = range.start - c.timeline.start
                if isFastCut { _ = try magneticRippleTrim(id, edge: .head, by: d) } else { try trim(id, edge: .head, by: d) }
                did = true
                guard let n = find(id) else { continue }
                c = n
            }
            if c.timeline.end > range.end, range.end > c.timeline.start {
                let d = range.end - c.timeline.end
                if isFastCut { _ = try magneticRippleTrim(id, edge: .tail, by: d) } else { try trim(id, edge: .tail, by: d) }
                did = true
            }
            if did { changed += 1 }
        }
        return changed
    }
}
