import Foundation

public enum TrackKind: String, Sendable, Codable { case video, audio }

public enum EditError: Error, Equatable {
    case wrongTrackKind
    case emptyClip
    case trackLocked
    case clipNotFound
    case collision
}

public struct Clip: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Imported media item (resolved by SSMedia, not by SSCore).
    public var media: UUID
    public var kind: TrackKind
    /// Portion of the media used.
    public var source: TimeRange
    /// Position on the track; duration equals `source.duration` until speed changes exist.
    public var start: Time
    /// Linked A/V partners share a link ID.
    public var link: UUID?
    /// Length of the whole media, when known. `nil` = unbounded (only the start of the media limits trims).
    public var mediaDuration: Time?

    public var timeline: TimeRange { TimeRange(start: start, duration: source.duration) }

    public init(id: UUID = UUID(), name: String, media: UUID, kind: TrackKind,
                source: TimeRange, start: Time, link: UUID? = nil, mediaDuration: Time? = nil) {
        self.id = id; self.name = name; self.media = media; self.kind = kind
        self.source = source; self.start = start; self.link = link; self.mediaDuration = mediaDuration
    }

    /// Keeps the part of the clip inside `range` (timeline coordinates), source offset follows.
    func cropped(to range: TimeRange) -> Clip? {
        guard let r = timeline.intersection(range) else { return nil }
        var c = self
        c.source = TimeRange(start: source.start + (r.start - start), duration: r.duration)
        c.start = r.start
        return c
    }
}

public struct Track: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TrackKind
    /// Locked tracks refuse edits and never shift.
    public var isLocked: Bool
    /// Sync-locked tracks shift together with ripple edits made on other tracks.
    public var syncLock: Bool
    /// Sorted by start, never overlapping.
    public private(set) var clips: [Clip]

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = [],
                isLocked: Bool = false, syncLock: Bool = true) {
        self.id = id; self.kind = kind; self.clips = clips
        self.isLocked = isLocked; self.syncLock = syncLock
    }

    /// Takes part in ripple edits made on other tracks.
    public var followsRipple: Bool { syncLock && !isLocked }

    public var end: Time { clips.last?.timeline.end ?? .zero }

    /// Places `clip`, replacing whatever it covers.
    public mutating func overwrite(_ clip: Clip) throws {
        try check(clip)
        clear(clip.timeline)
        clips.append(clip)
        clips.sort { $0.start < $1.start }
    }

    /// Removes everything inside `hole` and leaves a gap. Straddling clips are cut; when a clip is
    /// cut in two, only the left half keeps the identity.
    public mutating func clear(_ hole: TimeRange) {
        var out: [Clip] = []
        for c in clips {
            if !c.timeline.overlaps(hole) { out.append(c); continue }
            let keepsLeft = hole.start > c.start
            if keepsLeft, let left = c.cropped(to: TimeRange(start: c.start, end: hole.start)) {
                out.append(left)
            }
            if hole.end < c.timeline.end,
               var right = c.cropped(to: TimeRange(start: hole.end, end: c.timeline.end)) {
                if keepsLeft { right.id = UUID() }
                out.append(right)
            }
        }
        clips = out.sorted { $0.start < $1.start }
    }

    /// Places `clip` and pushes everything at or after its start later by its duration.
    public mutating func insert(_ clip: Clip) throws {
        try check(clip)
        try split(at: clip.start)
        let d = clip.timeline.duration
        for i in clips.indices where clips[i].start >= clip.start { clips[i].start += d }
        clips.append(clip)
        clips.sort { $0.start < $1.start }
    }

    /// Cuts the clip under `t` in two. No-op on edges and in gaps. The left half keeps the ID.
    public mutating func split(at t: Time) throws {
        guard let i = clips.firstIndex(where: { $0.timeline.contains(t) && $0.start < t }) else { return }
        let c = clips[i]
        clips[i] = c.cropped(to: TimeRange(start: c.start, end: t))!
        var right = c.cropped(to: TimeRange(start: t, end: c.timeline.end))!
        right.id = UUID()
        clips.insert(right, at: i + 1)
    }

    /// Removes a clip and leaves a gap.
    public mutating func remove(_ id: Clip.ID) { clips.removeAll { $0.id == id } }

    /// Removes a clip and pulls later clips left by its duration.
    public mutating func rippleDelete(_ id: Clip.ID) {
        guard let c = clips.first(where: { $0.id == id }) else { return }
        remove(id)
        for i in clips.indices where clips[i].start >= c.timeline.end { clips[i].start -= c.timeline.duration }
    }

    // MARK: Building blocks for Timeline-wide edits

    func clip(_ id: Clip.ID) -> Clip? { clips.first { $0.id == id } }

    mutating func replace(_ c: Clip) {
        if let i = clips.firstIndex(where: { $0.id == c.id }) { clips[i] = c }
    }

    /// Moves every clip starting at or after `pivot` by `delta`, except `excluding`.
    mutating func shift(from pivot: Time, by delta: Time, excluding: Set<Clip.ID> = []) {
        for i in clips.indices where clips[i].start >= pivot && !excluding.contains(clips[i].id) {
            clips[i].start += delta
        }
    }

    /// How far clips at or after `pivot` can move left before touching the clip before them.
    /// `nil` = nothing after `pivot`, no limit.
    func leftRoom(pivot: Time, excluding: Set<Clip.ID>) -> Time? {
        let rest = clips.filter { !excluding.contains($0.id) }
        guard let next = rest.first(where: { $0.start >= pivot }) else { return nil }
        let prevEnd = rest.filter { $0.start < pivot }.map { $0.timeline.end }.max() ?? .zero
        return next.start - prevEnd
    }

    var isConsistent: Bool {
        zip(clips, clips.dropFirst()).allSatisfy { $0.timeline.end <= $1.start } && clips.first.map { $0.start >= .zero } ?? true
    }

    private func check(_ clip: Clip) throws {
        guard clip.kind == kind else { throw EditError.wrongTrackKind }
        guard !clip.timeline.isEmpty else { throw EditError.emptyClip }
    }
}
