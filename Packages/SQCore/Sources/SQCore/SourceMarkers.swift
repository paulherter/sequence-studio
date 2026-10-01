import Foundation

/// Markers on a media item (M in the Source monitor). Stored in `MediaRef.sourceMarkers`, sorted by time, one per frame.
extension Project {
    public func sourceMarkers(for media: MediaRef.ID) -> [Marker] { self.media(media)?.sourceMarkers ?? [] }

    private static func sorted(_ list: [Marker]) -> [Marker] {
        list.sorted { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
    }

    /// Adds a marker at `time` (snapped to `frameDuration`, never before 0). A marker already on that frame is
    /// returned instead (`isNew == false`, Premiere: a second M opens the marker's edit dialog). nil for unknown media.
    @discardableResult
    public mutating func addSourceMarker(at time: Time, frameDuration: Time, to media: MediaRef.ID) -> (id: Marker.ID, isNew: Bool)? {
        guard let i = self.media.firstIndex(where: { $0.id == media }) else { return nil }
        let frame = max(.zero, time.snapped(to: frameDuration))
        var list = self.media[i].sourceMarkers ?? []
        if let m = list.first(where: { $0.time == frame }) { return (m.id, false) }
        let m = Marker(time: frame)
        list.append(m)
        self.media[i].sourceMarkers = Self.sorted(list)
        return (m.id, true)
    }

    @discardableResult
    public mutating func removeSourceMarker(_ id: Marker.ID, from media: MediaRef.ID) -> Bool {
        guard let i = self.media.firstIndex(where: { $0.id == media }),
              var list = self.media[i].sourceMarkers, list.contains(where: { $0.id == id }) else { return false }
        list.removeAll { $0.id == id }
        self.media[i].sourceMarkers = list.isEmpty ? nil : list
        return true
    }

    @discardableResult
    public mutating func updateSourceMarker(_ id: Marker.ID, in media: MediaRef.ID, _ body: (inout Marker) -> Void) -> Bool {
        guard let i = self.media.firstIndex(where: { $0.id == media }),
              var list = self.media[i].sourceMarkers, let j = list.firstIndex(where: { $0.id == id }) else { return false }
        body(&list[j])
        self.media[i].sourceMarkers = Self.sorted(list)
        return true
    }

    /// Poster frame (Cmd+P): the thumbnail time of `media`. nil clears it (Option+P).
    @discardableResult
    public mutating func setPosterTime(_ time: Time?, for media: MediaRef.ID) -> Bool {
        guard let i = self.media.firstIndex(where: { $0.id == media }) else { return false }
        self.media[i].posterTime = time.map { max(.zero, $0) }
        return true
    }
}

extension SourceMarks {
    /// Mark Clip (X) in the Source monitor: In at the start, Out at the end of the whole media (the stored Out is one
    /// frame past the last frame). nil for an empty media.
    public static func wholeClip(duration: Time) -> SourceMarks? {
        duration > .zero ? SourceMarks(markIn: .zero, markOut: duration) : nil
    }
}

extension Project {
    /// Mark Clip in the Source monitor: the media's In/Out become the whole clip. False for an empty media.
    @discardableResult
    public mutating func markSourceClip(_ media: MediaRef.ID, duration: Time) -> Bool {
        guard let m = SourceMarks.wholeClip(duration: duration) else { return false }
        sourceMarks[media] = m
        return true
    }
}

/// The Source monitor's list of clips opened earlier (title popup): at most `limit` unique ids, most recent first.
public struct SourceHistory: Sendable, Hashable {
    public static let limit = 20
    public private(set) var ids: [MediaRef.ID] = []

    public init() {}

    /// Moves `id` to the front. When the list is full the oldest entry drops out.
    public mutating func open(_ id: MediaRef.ID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }

    /// Several ids at once (a multi-selection): the first becomes the current one, the rest follow it in order.
    public mutating func open(all list: [MediaRef.ID]) {
        for id in list.reversed() { open(id) }
    }

    public mutating func close(_ id: MediaRef.ID) { ids.removeAll { $0 == id } }
    public mutating func closeAll() { ids.removeAll() }

    /// Drops ids that are no longer in the project.
    public mutating func prune(keeping existing: Set<MediaRef.ID>) { ids.removeAll { !existing.contains($0) } }
}
