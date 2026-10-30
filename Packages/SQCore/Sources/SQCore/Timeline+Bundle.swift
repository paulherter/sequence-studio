import Foundation

// Bundles (v57): Premiere's Clip > Group (Cmd+G there). Our "Group" (W7.6, Grouping.swift) is the layer group that nests its
// clips; a Bundle keeps every clip on its own track and only ties them together for editing:
// - a click on one member selects the whole bundle (and the members' linked partners); Option-click picks one clip;
// - moving, nudging and deleting act on the selection, so the bundle goes as one;
// - dragging an edge also drags the same edge of every member whose edge sits at the same time (the bundle's shared outer
//   edge, e.g. a title on top of its shot); an edge no other member shares trims alone (`bundleEdgePeers`);
// - a split keeps both halves in the bundle, copies (paste, duplicate, Option-drag) never join the original bundle;
// - bundles are flat: bundling members of other bundles merges them into one (Premiere nests groups).
// Links stay untouched: a bundle is a second tag next to `Clip.link`.

extension Timeline {
    /// True when any clip carries a bundle.
    public var containsBundles: Bool { tracks.contains { $0.clips.contains { $0.bundle != nil } } }

    /// `ids` plus every member of their bundles and the linked partners of those members (the selection a click on a
    /// bundled clip makes when Linked Selection is on).
    public func expandingBundles(_ ids: Set<Clip.ID>) -> Set<Clip.ID> {
        let clips = tracks.lazy.flatMap(\.clips)
        let bundles = Set(clips.filter { ids.contains($0.id) }.compactMap(\.bundle))
        guard !bundles.isEmpty else { return ids }
        let members = clips.filter { $0.bundle.map(bundles.contains) == true }
        let links = Set(members.compactMap(\.link))
        var out = ids
        for c in clips where c.bundle.map(bundles.contains) == true || c.link.map(links.contains) == true { out.insert(c.id) }
        return out
    }

    /// Bundles the clips (and their linked partners) into one new bundle and returns its id. Members of other bundles bring
    /// their whole bundle along (bundles are flat). Needs at least two clips that are not one linked group (an A/V pair
    /// alone is already tied by its link): `.clipNotFound` otherwise. A clip on a locked track refuses with `.trackLocked`.
    @discardableResult
    public mutating func bundle(_ ids: Set<Clip.ID>) throws -> UUID {
        let found = ids.filter { find($0) != nil }
        var members = expandingBundles(found)
        members.formUnion(heldBackPartners(of: members))
        let clips = tracks.flatMap(\.clips).filter { members.contains($0.id) }
        // Units: each link group counts once, each unlinked clip counts once.
        var units = Set<UUID>()
        for c in clips { units.insert(c.link ?? c.id) }
        guard units.count >= 2 else { throw EditError.clipNotFound }
        if tracks.contains(where: { t in t.isLocked && t.clips.contains { members.contains($0.id) } }) { throw EditError.trackLocked }
        let b = UUID()
        for i in tracks.indices {
            for c in tracks[i].clips where members.contains(c.id) {
                var n = c; n.bundle = b
                tracks[i].replace(n)
            }
        }
        return b
    }

    /// Breaks up every bundle a clip in `ids` belongs to. Returns false (and changes nothing) when none is bundled.
    /// A clip on a locked track refuses with `.trackLocked`.
    @discardableResult
    public mutating func unbundle(_ ids: Set<Clip.ID>) throws -> Bool {
        let bundles = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.bundle))
        guard !bundles.isEmpty else { return false }
        if tracks.contains(where: { t in t.isLocked && t.clips.contains { $0.bundle.map(bundles.contains) == true } }) {
            throw EditError.trackLocked
        }
        for i in tracks.indices {
            for c in tracks[i].clips where c.bundle.map(bundles.contains) == true {
                var n = c; n.bundle = nil
                tracks[i].replace(n)
            }
        }
        return true
    }

    /// Clears `bundle` on clips whose bundle has fewer than two members left (the rest was deleted).
    public mutating func dropOrphanBundles() {
        var counts: [UUID: Int] = [:]
        for t in tracks { for c in t.clips { if let b = c.bundle { counts[b, default: 0] += 1 } } }
        guard counts.values.contains(where: { $0 < 2 }) else { return }
        for i in tracks.indices {
            for c in tracks[i].clips where c.bundle.map({ counts[$0, default: 0] < 2 }) == true {
                var n = c; n.bundle = nil
                tracks[i].replace(n)
            }
        }
    }

    /// The other members of `id`'s bundle whose `edge` sits at the same time as `id`'s (track order). Dragging that edge
    /// trims them along; empty when the clip is not bundled or no member shares the edge.
    public func bundleEdgePeers(of id: Clip.ID, edge: ClipEdge) -> [Clip.ID] {
        guard let c = find(id)?.clip, let b = c.bundle else { return [] }
        func time(_ x: Clip) -> Time { edge == .head ? x.start : x.timeline.end }
        let at = time(c)
        return tracks.flatMap(\.clips).filter { $0.id != id && $0.bundle == b && time($0) == at }.map(\.id)
    }
}
