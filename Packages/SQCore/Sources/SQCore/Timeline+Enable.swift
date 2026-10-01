import Foundation

extension Timeline {
    /// Enable / Disable Clip (Shift+Cmd+E) on the clips and their linked partners as one group. When any of them is
    /// disabled, all are enabled; otherwise all are disabled. Locked tracks refuse. Returns the new state.
    @discardableResult
    public mutating func toggleEnabled(_ ids: Set<Clip.ID>) throws -> Bool {
        var group: [Member] = []
        var seen = Set<Clip.ID>()
        for id in ids {
            for m in try linkedGroup(id) where seen.insert(m.clip.id).inserted { group.append(m) }
        }
        guard !group.isEmpty else { throw EditError.clipNotFound }
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let enable = group.contains { !$0.clip.isEnabled }
        for m in group {
            var c = m.clip
            c.isEnabled = enable
            tracks[m.track].replace(c)
        }
        return enable
    }
}
