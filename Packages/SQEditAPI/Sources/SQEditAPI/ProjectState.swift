import Foundation
import SQCore

/// Read model of a project for agents: compact, ids and rational times only. Ids are the model's own persisted UUIDs,
/// so they stay valid across undo/redo and save + reopen. File paths and bookmarks are left out.
public struct ProjectState: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var activeSequence: Timeline.ID?
    public var media: [MediaState]
    public var sequences: [SequenceState]

    public init(_ p: Project) {
        id = p.id; name = p.name; activeSequence = p.activeTimeline
        media = p.media.map { MediaState(id: $0.id, name: $0.name, duration: $0.info?.duration ?? $0.duration) }
        sequences = p.timelines.map(SequenceState.init)
    }
}

public struct MediaState: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var duration: Time?
}

public struct SequenceState: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    public var frameDuration: Time
    public var duration: Time
    public var inOut: TimeRange?
    public var tracks: [TrackState]
    public var markers: [MarkerState]

    public init(_ t: Timeline) {
        id = t.id; name = t.name; width = t.format.width; height = t.format.height
        frameDuration = t.frameDuration; duration = t.duration; inOut = t.inOut
        tracks = t.tracks.map(TrackState.init)
        markers = t.markers.map { MarkerState(id: $0.id, time: $0.time, duration: $0.duration, name: $0.name) }
    }
}

public struct TrackState: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var name: String
    public var locked: Bool
    public var clips: [ClipState]

    public init(_ t: Track) {
        id = t.id; kind = t.kind.rawValue; name = t.name; locked = t.isLocked
        clips = t.clips.map { ClipState($0, track: t.id) }
    }
}

public struct MarkerState: Codable, Equatable, Sendable {
    public var id: UUID
    public var time: Time
    public var duration: Time
    public var name: String
}

public struct EffectState: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var enabled: Bool
}

public struct ClipState: Codable, Equatable, Sendable {
    public var id: UUID
    public var track: UUID
    public var name: String
    /// Media item, nested sequence or (generator) the clip's own id.
    public var media: UUID
    /// "media", "sequence", "generator:<kind>".
    public var type: String
    public var start: Time
    public var duration: Time
    /// Portion of the source used.
    public var source: TimeRange
    public var link: UUID?
    public var enabled: Bool
    /// Constant speed as a ratio (`num/den`, 1/1 = 100 %); nil when time-remapped.
    public var speed: ClipSpeed?
    public var effects: [EffectState]

    public init(_ c: Clip, track: UUID) {
        id = c.id; self.track = track; name = c.name; media = c.media
        type = c.sequence != nil ? "sequence" : c.generator.map { "generator:\($0.kind)" } ?? "media"
        start = c.start; duration = c.duration; source = c.source; link = c.link; enabled = c.isEnabled
        speed = c.speedKeys == nil ? c.speed : nil
        effects = c.effects.map { EffectState(id: $0.id, kind: $0.kind, enabled: $0.enabled) }
    }
}
