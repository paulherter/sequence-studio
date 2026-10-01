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
    case invalidFormat
    /// Speed/Duration on a clip that has no constant speed (nested sequence, generator, still).
    case speedUnsupported
    /// Apply Transition at a place that is not a cut (the clips do not touch).
    case notACut
    /// Not one frame of media beyond the cut(s) is available for the transition.
    case insufficientMedia
}

/// What a clip plays: imported media, or another sequence of the project (nested sequence).
public enum ClipSource: Sendable, Hashable {
    case media(UUID)
    case sequence(Timeline.ID)
    case generator(GeneratorRef)
}

/// A clip that renders itself instead of playing media (text layer, later shapes, solids, ...).
/// SQCore treats `payload` as opaque bytes; the owner of `kind` (e.g. SQText for "text") encodes and decodes it.
public struct GeneratorRef: Sendable, Hashable, Codable {
    /// Which generator renders this clip, e.g. "text".
    public var kind: String
    /// Opaque, versioned content (e.g. an encoded text template).
    public var payload: Data
    /// Version of the payload's own format, owned by the generator.
    public var payloadVersion: Int

    public static let text = "text"
    /// A flat colour layer (transition dips). `payload` = display-encoded RGB bytes.
    public static let solid = "solid"
    public static func solid(rgb: [UInt8]) -> GeneratorRef { GeneratorRef(kind: solid, payload: Data(rgb)) }

    public init(kind: String, payload: Data, payloadVersion: Int = 1) {
        self.kind = kind; self.payload = payload; self.payloadVersion = payloadVersion
    }
}

public struct Clip: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Imported media item (resolved by SQMedia, not by SQCore).
    public var media: UUID
    public var kind: TrackKind
    /// Portion of the media used.
    public var source: TimeRange
    /// Position on the track. Timeline duration is `duration` = `source.duration / speed`.
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
    /// Clip of a still image: free trims in both directions like a generator (the picture has no time axis).
    public var isStill: Bool = false
    /// Explicitly applied effects (v9), in render order. Empty = none applied (nothing shows in Effect Controls).
    public var effects: [ClipEffect] = []
    /// Audio Gain in dB (Clip > Audio Options > Audio Gain), on top of the Volume level. 0 = none.
    public var audioGainDB: Double = 0
    /// Constant speed (v13). 100 % = `.normal`. Only media clips are retimed (nested sequences, generators and stills
    /// stay at 100 %; `Timeline.setSpeed` refuses them).
    public var speed: ClipSpeed = .normal
    /// Plays the source range backwards (v13). The clip's first frame is the last frame of `source`.
    public var reversed: Bool = false
    /// Audio: keep the pitch when speed is not 100 % (time-stretch); false = resample (pitch follows speed).
    public var keepsPitch: Bool = true

    /// Media, nested sequence or generator.
    public var clipSource: ClipSource {
        if let g = generator { return .generator(g) }
        return sequence.map(ClipSource.sequence) ?? .media(media)
    }
    public var isNested: Bool { sequence != nil }
    public var isGenerator: Bool { generator != nil }
    /// Length on the timeline: the source range played at `speed`.
    public var duration: Time { speed.isNormal ? source.duration : speed.unscale(source.duration) }

    /// How far the head can still grow, in timeline time (the source handle that plays first, divided by `speed`:
    /// before `source.start`, or after `source.end` for a reversed clip); nil = unbounded.
    var headHandle: Time? {
        if isGenerator || isStill { return nil }
        if reversed { return mediaDuration.map { speed.unscale($0 - source.end) } }
        return speed.unscale(source.start)
    }
    /// How far the tail can still grow, in timeline time; nil = unbounded.
    var tailRoom: Time? {
        if isGenerator || isStill { return mediaDuration.map { speed.unscale($0 - source.end) } }
        if reversed { return speed.unscale(source.start) }
        return mediaDuration.map { speed.unscale($0 - source.end) }
    }

    public var timeline: TimeRange { TimeRange(start: start, duration: duration) }

    /// Source time shown at timeline time `t` (absolute). Forward: `source.start + local * speed`. Reversed: the clip
    /// plays `source` backwards, so the frame shown for the timeline frame [local, local + frameDuration) is the one
    /// ending at `source.end - local * speed`; its start is `source.end - (local + frameDuration) * speed`.
    /// Generators have no time axis: `local`. Clamped into `source` for reversed clips.
    public func sourceTime(at t: Time, frameDuration: Time) -> Time {
        let local = t - start
        if isGenerator { return local }
        if reversed {
            let s = source.end - speed.scale(local + frameDuration)
            // Outside the clip (a transition reading its handle) the reversed source runs on below `source.start`.
            return timeline.contains(t) ? max(s, source.start) : max(s, .zero)
        }
        return source.start + speed.scale(local)
    }

    /// Timeline time (absolute) at which source time `s` is shown; the inverse of `sourceTime`. Pass the sequence frame
    /// duration for reversed clips (the frame shown starts one frame before the mapped end). Used to map decoded frames back onto the timeline.
    public func timelineTime(forSource s: Time, frameDuration: Time = .zero) -> Time {
        reversed ? start + speed.unscale(source.end - s) - frameDuration : start + speed.unscale(s - source.start)
    }

    public init(id: UUID = UUID(), name: String, media: UUID, kind: TrackKind,
                source: TimeRange, start: Time, link: UUID? = nil, mediaDuration: Time? = nil,
                animation: ClipAnimation = ClipAnimation(), sequence: Timeline.ID? = nil,
                generator: GeneratorRef? = nil, color: ClipColor = .default, label: LabelColor? = nil,
                isStill: Bool = false, effects: [ClipEffect] = [],
                speed: ClipSpeed = .normal, reversed: Bool = false, keepsPitch: Bool = true) {
        self.speed = speed; self.reversed = reversed; self.keepsPitch = keepsPitch
        self.isStill = isStill
        self.effects = effects
        self.label = label
        self.color = color
        self.animation = animation
        self.sequence = sequence
        self.generator = generator
        self.id = id; self.name = name; self.media = media; self.kind = kind
        self.source = source; self.start = start; self.link = link; self.mediaDuration = mediaDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, media, kind, source, start, link, mediaDuration, animation, sequence, generator, color, label, effects, isStill, speed, reversed, keepsPitch, audioGainDB
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
                  label: try c.decodeIfPresent(LabelColor.self, forKey: .label),
                  isStill: try c.decodeIfPresent(Bool.self, forKey: .isStill) ?? false,
                  effects: try c.decodeIfPresent([ClipEffect].self, forKey: .effects) ?? [],
                  speed: try c.decodeIfPresent(ClipSpeed.self, forKey: .speed) ?? .normal,
                  reversed: try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false,
                  keepsPitch: try c.decodeIfPresent(Bool.self, forKey: .keepsPitch) ?? true)
        audioGainDB = try c.decodeIfPresent(Double.self, forKey: .audioGainDB) ?? 0
        // v8 -> v9: a radius that was not the default becomes an applied Rounded Corners effect.
        if let legacy = animation.legacyCornerRadius {
            animation.legacyCornerRadius = nil
            if (legacy.value != 0 || legacy.isAnimated), roundedCorners == nil {
                effects.append(ClipEffect(kind: ClipEffect.roundedCornersKind,
                                          parameters: [ClipEffect.radiusKey: legacy]))
            }
        }
    }

    /// Moves a split-off right half onto a fresh link shared through `map` (old link to new link).
    mutating func relink(_ map: inout [UUID: UUID]) {
        guard let l = link else { return }
        let n = map[l] ?? UUID()
        map[l] = n
        link = n
    }

    /// Makes the clip `g` longer at its head (negative = shorter) without moving `start` (the caller moves it).
    /// The source side that plays first changes by `g * speed`; keys stay on the same frames, so they shift by `g`
    /// (clip-local keys are timeline time). Keys pushed outside 0...duration are kept, like in `cropped`.
    mutating func extendHead(by g: Time) {
        let d = speed.scale(g)
        if reversed { source.duration += d } else { source.start -= d; source.duration += d }
        animation = animation.shifted(by: g)
        effects = effects.map { $0.shifted(by: g) }
    }

    /// Moves the clip-local key times after a retime from `old` to `new` timeline duration: scaled by new/old so keys stay on
    /// the same content; when the direction flipped (`mirror`), mirrored inside the clip as well.
    mutating func rescaleKeys(from old: Time, to new: Time, mirror: Bool) {
        guard old > .zero, old != new || mirror else { return }
        let num = new.value * old.timescale, den = new.timescale * old.value
        let f: (Time) -> Time = { t in
            let s = Time(t.value * num, t.timescale * den)
            return mirror ? new - s : s
        }
        animation = animation.remapped(f)
        effects = effects.map { $0.remapped(f) }
    }

    /// Makes the clip `g` longer at its tail (negative = shorter). The source side that plays last changes by `g * speed`.
    mutating func extendTail(by g: Time) {
        let d = speed.scale(g)
        if reversed { source.start -= d }
        source.duration += d
    }

    /// Keeps the part of the clip inside `range` (timeline coordinates); the source range follows through speed and
    /// direction, keys stay on the same frames.
    func cropped(to range: TimeRange) -> Clip? {
        guard let r = timeline.intersection(range) else { return nil }
        var c = self
        let a = r.start - start, len = speed.scale(r.duration)
        if reversed {
            c.source = TimeRange(start: source.end - speed.scale(a) - len, duration: len)
        } else {
            c.source = TimeRange(start: source.start + speed.scale(a), duration: len)
        }
        c.start = r.start
        c.animation = animation.shifted(by: start - r.start)   // keep keys on the same frames
        c.effects = effects.map { $0.shifted(by: start - r.start) }
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
    /// Transitions at cuts and clip edges of this track (v17). Anchored to clip IDs; see `Transition.swift`.
    public var transitions: [Transition] = []
    /// Row height in points (UI hint).
    public var height: Double

    public static let defaultHeight: Double = 48

    public init(id: UUID = UUID(), kind: TrackKind, clips: [Clip] = [],
                isLocked: Bool = false, syncLock: Bool = true,
                name: String = "", isVisible: Bool = true, isMuted: Bool = false, isSolo: Bool = false,
                isTargeted: Bool = false, height: Double = Track.defaultHeight, transitions: [Transition] = []) {
        self.transitions = transitions
        self.id = id; self.kind = kind; self.clips = clips
        self.isLocked = isLocked; self.syncLock = syncLock
        self.name = name; self.isVisible = isVisible; self.isMuted = isMuted; self.isSolo = isSolo
        self.isTargeted = isTargeted; self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, clips, isLocked, syncLock, name, isVisible, isMuted, isSolo, isTargeted, height, transitions
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
                  height: try c.decodeIfPresent(Double.self, forKey: .height) ?? Track.defaultHeight,
                  transitions: try c.decodeIfPresent([Transition].self, forKey: .transitions) ?? [])
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
        guard !hole.isEmpty else { return }
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
