import Foundation

public enum TrackKind: String, Sendable, Codable { case video, audio }

public enum EditError: Error, Equatable {
    case wrongTrackKind
    case emptyClip
    case trackLocked
    case clipNotFound
    case collision
    /// A sequence would contain itself, directly or through other nested sequences.
    case nestingCycle
    case timelineNotFound
}

/// What a clip plays: imported media, or another sequence of the project (nested sequence).
public enum ClipSource: Sendable, Hashable {
    case media(UUID)
    case sequence(Timeline.ID)
    case generator(GeneratorRef)
}

/// A clip that renders itself instead of playing media (text layer, later shapes, solids, ...).
/// SSCore treats `payload` as opaque bytes; the owner of `kind` (e.g. SSText for "text") encodes and decodes it.
public struct GeneratorRef: Sendable, Hashable, Codable {
    /// Which generator renders this clip, e.g. "text".
    public var kind: String
    /// Opaque, versioned content (e.g. an encoded text template).
    public var payload: Data
    /// Version of the payload's own format, owned by the generator.
    public var payloadVersion: Int

    public static let text = "text"

    public init(kind: String, payload: Data, payloadVersion: Int = 1) {
        self.kind = kind; self.payload = payload; self.payloadVersion = payloadVersion
    }
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
    /// Animatable transform, opacity and volume (keyframe times are clip-local, relative to `start`).
    public var animation: ClipAnimation
    /// Set for a nested-sequence clip: the sequence it plays. `media` then equals this ID (so code keyed on
    /// `media` never sees a nil), `source` is a range of the inner sequence's timeline, and
    /// `mediaDuration` is the inner sequence's duration when nested.
    public var sequence: Timeline.ID?
    /// Set for a generator clip (text layer): it has no media. `media` is then the clip's own ID, `mediaDuration`
    /// is nil and `source` is a free clip-local range: it may start below 0 after a head trim, so a generator
    /// can grow in both directions (only the >= 1 frame rule and neighbours limit it). Video tracks only.
    public var generator: GeneratorRef?
    /// Static per-clip colour (source override, correction, LUTs). Default = automatic from media, neutral.
    public var color: ClipColor = .default
    /// Label colour of this clip; nil = inherit from its media / sequence (then the type default).
    public var label: LabelColor?

    /// Media, nested sequence or generator.
    public var clipSource: ClipSource {
        if let g = generator { return .generator(g) }
        return sequence.map(ClipSource.sequence) ?? .media(media)
    }
    public var isNested: Bool { sequence != nil }
    public var isGenerator: Bool { generator != nil }
    /// How far the head can still grow (source handle before `source.start`); nil = unbounded (generator).
    var headHandle: Time? { isGenerator ? nil : source.start }

    public var timeline: TimeRange { TimeRange(start: start, duration: source.duration) }

    public init(id: UUID = UUID(), name: String, media: UUID, kind: TrackKind,
                source: TimeRange, start: Time, link: UUID? = nil, mediaDuration: Time? = nil,
                animation: ClipAnimation = ClipAnimation(), sequence: Timeline.ID? = nil,
                generator: GeneratorRef? = nil, color: ClipColor = .default, label: LabelColor? = nil) {
        self.label = label
        self.color = color
        self.animation = animation
        self.sequence = sequence
        self.generator = generator
        self.id = id; self.name = name; self.media = media; self.kind = kind
        self.source = source; self.start = start; self.link = link; self.mediaDuration = mediaDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, media, kind, source, start, link, mediaDuration, animation, sequence, generator, color, label
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  media: try c.decode(UUID.self, forKey: .media), kind: try c.decode(TrackKind.self, forKey: .kind),
                  source: try c.decode(TimeRange.self, forKey: .source), start: try c.decode(Time.self, forKey: .start),
                  link: try c.decodeIfPresent(UUID.self, forKey: .link),
                  mediaDuration: try c.decodeIfPresent(Time.self, forKey: .mediaDuration),
                  animation: try c.decodeIfPresent(ClipAnimation.self, forKey: .animation) ?? ClipAnimation(),
                  sequence: try c.decodeIfPresent(Timeline.ID.self, forKey: .sequence),
                  generator: try c.decodeIfPresent(GeneratorRef.self, forKey: .generator),
                  color: try c.decodeIfPresent(ClipColor.self, forKey: .color) ?? .default,
                  label: try c.decodeIfPresent(LabelColor.self, forKey: .label))
    }

    /// Moves a split-off right half onto a fresh link shared through `map` (old link to new link).
    mutating func relink(_ map: inout [UUID: UUID]) {
        guard let l = link else { return }
        let n = map[l] ?? UUID()
        map[l] = n
        link = n
    }

    /// Moves `source.start` by `d` and shifts the clip-local keys by -d, so keys stay on the same
    /// source frames (Premiere). Keys pushed outside 0...duration are kept, like in `cropped`.
    /// Not for slip: there keys stay at the same position in the clip.
    mutating func shiftSourceStart(by d: Time) {
        source.start += d
        animation = animation.shifted(by: .zero - d)
    }

    /// Keeps the part of the clip inside `range` (timeline coordinates), source offset follows.
    func cropped(to range: TimeRange) -> Clip? {
        guard let r = timeline.intersection(range) else { return nil }
        var c = self
        c.source = TimeRange(start: source.start + (r.start - start), duration: r.duration)
        c.start = r.start
        c.animation = animation.shifted(by: start - r.start)   // keep keys on the same frames
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
    public var name: String
    /// Eye toggle (video): hidden tracks are not rendered.
    public var isVisible: Bool
    /// Audio: muted tracks are silent. Solo silences every non-solo audio track.
    public var isMuted: Bool
    public var isSolo: Bool
    /// Receives inserts/overwrites from the source monitor.
    public var isTargeted: Bool
    /// Row height in points (UI hint).
    public var height: Double

    public static let defaultHeight: Double = 48

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = [],
                isLocked: Bool = false, syncLock: Bool = true,
                name: String = "", isVisible: Bool = true, isMuted: Bool = false, isSolo: Bool = false,
                isTargeted: Bool = false, height: Double = Track.defaultHeight) {
        self.id = id; self.kind = kind; self.clips = clips
        self.isLocked = isLocked; self.syncLock = syncLock
        self.name = name; self.isVisible = isVisible; self.isMuted = isMuted; self.isSolo = isSolo
        self.isTargeted = isTargeted; self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, clips, isLocked, syncLock, name, isVisible, isMuted, isSolo, isTargeted, height
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  kind: try c.decode(TrackKind.self, forKey: .kind),
                  clips: try c.decodeIfPresent([Clip].self, forKey: .clips) ?? [],
                  isLocked: try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false,
                  syncLock: try c.decodeIfPresent(Bool.self, forKey: .syncLock) ?? true,
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  isVisible: try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
                  isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
                  isSolo: try c.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false,
                  isTargeted: try c.decodeIfPresent(Bool.self, forKey: .isTargeted) ?? false,
                  height: try c.decodeIfPresent(Double.self, forKey: .height) ?? Track.defaultHeight)
    }

    /// Takes part in ripple edits made on other tracks.
    public var followsRipple: Bool { syncLock && !isLocked }

    public var end: Time { clips.last?.timeline.end ?? .zero }

    /// Places `clip`, replacing whatever it covers.
    public mutating func overwrite(_ clip: Clip) throws {
        var relinks: [UUID: UUID] = [:]
        try overwrite(clip, relinks: &relinks)
    }

    /// `overwrite` with a shared old-link to new-link map (see `clear(_:relinks:)`).
    mutating func overwrite(_ clip: Clip, relinks: inout [UUID: UUID]) throws {
        try check(clip)
        clear(clip.timeline, relinks: &relinks)
        clips.append(clip)
        clips.sort { $0.start < $1.start }
    }

    /// Removes everything inside `hole` and leaves a gap. Straddling clips are cut; when a clip is
    /// cut in two, only the left half keeps the identity and link; the right half gets a new link
    /// (see `relinks`).
    public mutating func clear(_ hole: TimeRange) {
        var relinks: [UUID: UUID] = [:]
        clear(hole, relinks: &relinks)
    }

    /// `clear` with a shared old-link to new-link map: right halves cut from one linked group, on this
    /// or other tracks, get the same new link, so each side stays linked with its own partners.
    mutating func clear(_ hole: TimeRange, relinks: inout [UUID: UUID]) {
        var out: [Clip] = []
        for c in clips {
            if !c.timeline.overlaps(hole) { out.append(c); continue }
            let keepsLeft = hole.start > c.start
            if keepsLeft, let left = c.cropped(to: TimeRange(start: c.start, end: hole.start)) {
                out.append(left)
            }
            if hole.end < c.timeline.end,
               var right = c.cropped(to: TimeRange(start: hole.end, end: c.timeline.end)) {
                if keepsLeft { right.id = UUID(); right.relink(&relinks) }
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

    /// Cuts the clip under `t` in two. No-op on edges and in gaps. The left half keeps the ID and link.
    public mutating func split(at t: Time) throws {
        var relinks: [UUID: UUID] = [:]
        try split(at: t, relinks: &relinks)
    }

    /// `split` with a shared old-link to new-link map (see `clear(_:relinks:)`).
    mutating func split(at t: Time, relinks: inout [UUID: UUID]) throws {
        guard let i = clips.firstIndex(where: { $0.timeline.contains(t) && $0.start < t }) else { return }
        let c = clips[i]
        clips[i] = c.cropped(to: TimeRange(start: c.start, end: t))!
        var right = c.cropped(to: TimeRange(start: t, end: c.timeline.end))!
        right.id = UUID()
        right.relink(&relinks)
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
