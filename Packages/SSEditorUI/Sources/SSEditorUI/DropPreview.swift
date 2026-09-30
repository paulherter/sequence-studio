import CoreGraphics
import Foundation
import SSCore

/// One item being dragged into the timeline (media from Project or Library, or a text template).
public struct DropItem: Sendable, Hashable {
    public var name: String
    public var duration: Time
    public var hasVideo: Bool
    public var hasAudio: Bool
    public init(name: String, duration: Time, hasVideo: Bool = true, hasAudio: Bool = false) {
        self.name = name; self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio
    }
}

/// A ghost clip: where the dropped item would land.
public struct DropGhost: Sendable, Hashable {
    public var track: Track.ID
    public var range: TimeRange
    public var kind: TrackKind
    public var name: String
}

/// Live preview of a drop onto the timeline (Premiere): pure reducer, the view feeds it the pointer.
/// Items are laid out one after another from the snapped start. Command switches overwrite to insert.
/// `cancel()` (drag left the timeline, Esc) clears everything; nothing is ever written to the model here.
public struct DropPreview: Sendable {
    public private(set) var items: [DropItem] = []
    public private(set) var isActive = false
    public private(set) var insert = false
    /// Snapped drop time (valid while active).
    public private(set) var start: Time = .zero
    /// Video track under the pointer (nil = host default: targeted or first).
    public private(set) var videoTrack: Track.ID?
    public private(set) var ghosts: [DropGhost] = []
    /// Time the start or end snapped to (snap line), nil when free.
    public private(set) var snapTime: Time?

    public init() {}

    public var totalDuration: Time { items.reduce(.zero) { $0 + $1.duration } }

    public mutating func begin(items: [DropItem]) {
        self.items = items
        isActive = !items.isEmpty
    }

    public mutating func cancel() {
        self = DropPreview()
    }

    /// Pointer at `point` (view coordinates). Outside the track area (ruler, tool column) the ghost disappears.
    public mutating func update(point: CGPoint, insert: Bool, timeline: Timeline, geometry: TimelineGeometry,
                                snapping: Bool, playhead: Time) {
        guard isActive else { return }
        self.insert = insert
        guard point.y >= TimelineGeometry.rulerHeight, point.x >= TimelineGeometry.toolColumnWidth else {
            ghosts = []; snapTime = nil; return
        }
        var t = max(geometry.time(atX: max(point.x, TimelineGeometry.contentOriginX)), .zero)
        snapTime = nil
        if snapping, totalDuration > .zero {
            let r = snapMove(start: t, duration: totalDuration,
                             to: timeline.snapPoints(playhead: playhead, markers: timeline.markers.map(\.time)),
                             threshold: geometry.snapThreshold(), frameDuration: geometry.frameDuration)
            t += r.delta
            snapTime = r.hit?.time
        }
        start = max(t, .zero)
        videoTrack = Self.videoTrack(at: point, timeline: timeline, geometry: geometry)
        ghosts = layout(timeline: timeline)
    }

    /// The video track under the pointer; nil over audio tracks or empty space.
    static func videoTrack(at p: CGPoint, timeline: Timeline, geometry: TimelineGeometry) -> Track.ID? {
        let id: Track.ID?
        switch geometry.hitTest(p, in: timeline) {
        case .clip(let cid, _): id = timeline.tracks.first { $0.clips.contains { $0.id == cid } }?.id
        case .gap(let t, _): id = t
        case .header(let t): id = t
        default: id = nil
        }
        return id.flatMap { timeline.track($0)?.kind == .video ? $0 : nil }
    }

    /// Same target rules as `EditorSession.placeMedia`: video on the pointer's track (else targeted, else first),
    /// audio on the targeted or first audio track.
    private func layout(timeline t: Timeline) -> [DropGhost] {
        let v = videoTrack ?? t.tracks.first { $0.kind == .video && $0.isTargeted }?.id ?? t.tracks.first { $0.kind == .video }?.id
        let a = t.tracks.first { $0.kind == .audio && $0.isTargeted }?.id ?? t.tracks.first { $0.kind == .audio }?.id
        var at = start
        var out: [DropGhost] = []
        for item in items {
            let r = TimeRange(start: at, duration: item.duration)
            if item.hasVideo, let v { out.append(DropGhost(track: v, range: r, kind: .video, name: item.name)) }
            if item.hasAudio, let a { out.append(DropGhost(track: a, range: r, kind: .audio, name: item.name)) }
            at += item.duration
        }
        return out
    }

    /// What a release commits: start time and video track, or nil when nothing is previewed.
    public var commitTarget: (time: Time, track: Track.ID?, insert: Bool)? {
        isActive && !ghosts.isEmpty ? (start, videoTrack, insert) : nil
    }
}
