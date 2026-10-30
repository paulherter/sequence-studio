import Foundation

/// Clip ID -> (track, position) lookup for one timeline value, plus link groups. Built once per timeline value
/// (O(clips)); every lookup is then O(1) instead of a scan over all tracks. A value type: the owner rebuilds it whenever
/// it assigns a new timeline (an index of an older value is simply stale, never shared).
public struct TimelineClipIndex: Sendable, Equatable {
    public struct Location: Sendable, Hashable {
        /// Index into `Timeline.tracks`.
        public var track: Int
        /// Index into that track's `clips`.
        public var clip: Int
        public var trackID: Track.ID
    }

    private var locations: [Clip.ID: Location] = [:]
    private var links: [UUID: [Clip.ID]] = [:]
    private var bundles: [UUID: [Clip.ID]] = [:]

    public init() {}

    public init(_ timeline: Timeline) {
        let count = timeline.tracks.reduce(0) { $0 + $1.clips.count }
        locations.reserveCapacity(count)
        for (ti, t) in timeline.tracks.enumerated() {
            for (ci, c) in t.clips.enumerated() {
                locations[c.id] = Location(track: ti, clip: ci, trackID: t.id)
                if let l = c.link { links[l, default: []].append(c.id) }
                if let b = c.bundle { bundles[b, default: []].append(c.id) }
            }
        }
    }

    public var count: Int { locations.count }

    public func location(of id: Clip.ID) -> Location? { locations[id] }

    public func trackID(of id: Clip.ID) -> Track.ID? { locations[id]?.trackID }

    public func contains(_ id: Clip.ID) -> Bool { locations[id] != nil }

    /// The clip in `timeline`, which must be the value this index was built from.
    public func clip(_ id: Clip.ID, in timeline: Timeline) -> Clip? {
        guard let l = locations[id] else { return nil }
        return timeline.tracks[l.track].clips[l.clip]
    }

    /// Every clip carrying `link`, in track then position order.
    public func clips(linkedBy link: UUID) -> [Clip.ID] { links[link] ?? [] }

    /// Every clip carrying `bundle` (v57), in track then position order.
    public func clips(bundledBy bundle: UUID) -> [Clip.ID] { bundles[bundle] ?? [] }
}
