import Foundation

/// The Tone generator: a sine on an audio track (line-up tone, bleep). A generator clip like any other (`Clip.generator`,
/// kind `GeneratorRef.tone`); its frequency and level live in the payload, so nothing in the saved format changes.
///
/// The sound is identified by `mediaID`, a UUID that carries the two values (see `init?(mediaID:)`). The audio mixer
/// recognizes such an ID and synthesizes the sine itself (`ToneAudioSource`, SQMedia): no file, no lookup, and an edit of
/// frequency or level makes a new ID, so no cached source can be stale. Playback, scrubbing and export share this one path.
public struct ToneSpec: Sendable, Hashable, Codable {
    /// 20 Hz ... 20 kHz in millihertz (integers: no rounding drift between save and load).
    public var frequencyMilliHz: Int
    /// -60 ... 0 dB (full scale) in hundredths of a dB.
    public var levelCentiDB: Int

    public static let frequencyRange = 20_000...20_000_000
    public static let levelRange = -6_000...0
    /// 1 kHz at -12 dB: the line-up tone broadcasters expect.
    public static let `default` = ToneSpec(frequencyMilliHz: 1_000_000, levelCentiDB: -1_200)

    public init(frequencyMilliHz: Int, levelCentiDB: Int) {
        self.frequencyMilliHz = min(max(frequencyMilliHz, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        self.levelCentiDB = min(max(levelCentiDB, Self.levelRange.lowerBound), Self.levelRange.upperBound)
    }

    public init(frequencyHz: Double, levelDB: Double) {
        self.init(frequencyMilliHz: Int((frequencyHz * 1000).rounded()), levelCentiDB: Int((levelDB * 100).rounded()))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frequencyMilliHz: try c.decode(Int.self, forKey: .frequencyMilliHz),
                  levelCentiDB: try c.decode(Int.self, forKey: .levelCentiDB))
    }

    public var frequencyHz: Double { Double(frequencyMilliHz) / 1000 }
    public var levelDB: Double { Double(levelCentiDB) / 100 }
    /// Peak amplitude, 0...1.
    public var amplitude: Double { pow(10, levelDB / 20) }

    // MARK: Identity

    private static let magic: [UInt8] = [0x53, 0x51, 0x54, 0x4E]     // "SQTN"

    /// bytes 0-3 magic, 4-7 millihertz, 8-11 centi-dB (offset by 6000, so unsigned), 12-15 zero.
    public var mediaID: UUID {
        var b = Self.magic
        b += Self.bytes(UInt32(frequencyMilliHz))
        b += Self.bytes(UInt32(levelCentiDB - Self.levelRange.lowerBound))
        b += [0, 0, 0, 0]
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// nil when `mediaID` is not a tone ID (an ordinary media UUID).
    public init?(mediaID: UUID) {
        let u = mediaID.uuid
        let b = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        guard Array(b[0..<4]) == Self.magic, b[12...].allSatisfy({ $0 == 0 }) else { return nil }
        let f = Int(Self.word(b, 4)), l = Int(Self.word(b, 8)) + Self.levelRange.lowerBound
        guard Self.frequencyRange.contains(f), Self.levelRange.contains(l) else { return nil }
        self.init(frequencyMilliHz: f, levelCentiDB: l)
    }

    private static func bytes(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    private static func word(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    // MARK: Generator payload

    public var generator: GeneratorRef {
        GeneratorRef(kind: GeneratorRef.tone, payload: (try? JSONEncoder().encode(self)) ?? Data())
    }

    /// The tone of a generator; nil for any other generator or a damaged payload.
    public init?(generator: GeneratorRef) {
        guard generator.kind == GeneratorRef.tone, let s = try? JSONDecoder().decode(ToneSpec.self, from: generator.payload) else { return nil }
        self = s
    }
}

extension GeneratorRef {
    /// A sine tone on an audio track (`ToneSpec`).
    public static let tone = "tone"
}

extension Clip {
    /// The tone this clip plays; nil for any other clip.
    public var tone: ToneSpec? { generator.flatMap(ToneSpec.init(generator:)) }

    /// What the audio mixer opens for this clip: a tone's synthetic ID, else `media`.
    var audioMediaID: UUID { tone?.mediaID ?? media }

    static func makeTone(_ spec: ToneSpec, start: Time, duration: Time, name: String = "Tone") -> Clip {
        Clip(name: name, media: spec.mediaID, kind: .audio, source: TimeRange(start: .zero, duration: duration), start: start,
             generator: spec.generator)
    }
}

extension Project {
    /// Places a tone clip on an audio track of `timeline` at `start` (overwrite, like a drag onto the track).
    /// Throws `.wrongTrackKind` (video track), `.trackLocked`, `.emptyClip` (duration not above zero), `.clipNotFound` (track),
    /// `.timelineNotFound`. Returns the new clip's ID.
    @discardableResult
    public mutating func addToneClip(_ spec: ToneSpec = .default, in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                     duration: Time) throws -> Clip.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        guard let tr = timelines[ti].tracks.firstIndex(where: { $0.id == track }) else { throw EditError.clipNotFound }
        guard timelines[ti].tracks[tr].kind == .audio else { throw EditError.wrongTrackKind }
        guard !timelines[ti].tracks[tr].isLocked else { throw EditError.trackLocked }
        guard duration > .zero, start >= .zero else { throw EditError.emptyClip }
        let clip = Clip.makeTone(spec, start: start, duration: duration)
        try edit(timeline) { try $0.tracks[tr].overwrite(clip) }
        return clip.id
    }

    /// Changes frequency and level of a tone clip. One mutation (one undo step). Throws `.clipNotFound` for an unknown clip
    /// or one that is not a tone, `.trackLocked` on a locked track.
    public mutating func setTone(clipID: Clip.ID, _ spec: ToneSpec) throws {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                guard var c = timelines[ti].tracks[tr].clips.first(where: { $0.id == clipID }) else { continue }
                guard c.tone != nil else { throw EditError.clipNotFound }
                if timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
                c.generator = spec.generator
                c.media = spec.mediaID
                timelines[ti].tracks[tr].replace(c)
                return
            }
        }
        throw EditError.clipNotFound
    }
}

extension Timeline {
    public static let bleepTrackName = "Bleep"

    /// Bleep: silences `range` on the targeted audio tracks and lays a tone over it. The sound under the range is kept, only
    /// switched off (the pieces are disabled, so enabling them again undoes the bleep for that part); the tone goes on a track
    /// named "Bleep" (an existing one if it is free over the range, else a new audio track). Pieces keep their link, so
    /// picture and sound keep their sync. One mutation. Returns the tone clip.
    /// Throws `.emptyClip` for an empty range or when nothing sounds in it, `.wrongTrackKind` for a video track,
    /// `.trackLocked` for a locked target, `.clipNotFound` (no target).
    @discardableResult
    public mutating func bleep(_ range: TimeRange, tracks ids: [Track.ID], tone spec: ToneSpec = .default) throws -> Clip.ID {
        guard !range.isEmpty else { throw EditError.emptyClip }
        guard !ids.isEmpty else { throw EditError.clipNotFound }
        let targets = try targetIndices(ids).filter { tracks[$0].name != Self.bleepTrackName }
        guard !targets.isEmpty else { throw EditError.clipNotFound }
        guard targets.allSatisfy({ tracks[$0].kind == .audio }) else { throw EditError.wrongTrackKind }
        var work = self
        var relinks: [UUID: UUID] = [:]
        var muted = false
        // Linked partners (the picture) are cut at both edges too, with the shared relink map, exactly like an add-edit:
        // the pieces of one cut keep one link each, so linked trim and Enable Clip keep working. The picture plays through.
        let links = Set(targets.flatMap { work.tracks[$0].clips.filter { $0.timeline.overlaps(range) }.compactMap(\.link) })
        let partners = work.tracks.indices.filter { i in
            !targets.contains(i) && !work.tracks[i].isLocked
                && work.tracks[i].clips.contains { $0.link.map(links.contains) ?? false }
        }
        for i in targets + partners {
            try work.tracks[i].split(at: range.start, relinks: &relinks)
            try work.tracks[i].split(at: range.end, relinks: &relinks)
        }
        for i in targets {
            for var c in work.tracks[i].clips where c.isEnabled && c.tone == nil {
                if range.start <= c.start, c.timeline.end <= range.end {
                    c.isEnabled = false; muted = true
                    work.tracks[i].replace(c)
                }
            }
        }
        guard muted else { throw EditError.emptyClip }
        let clip = Clip.makeTone(spec, start: range.start, duration: range.duration, name: "Bleep")
        let free = work.tracks.indices.first {
            let t = work.tracks[$0]
            return t.kind == .audio && t.name == Self.bleepTrackName && !t.isLocked && !targets.contains($0)
                && !t.clips.contains { $0.timeline.overlaps(range) }
        }
        if let free {
            try work.tracks[free].overwrite(clip)
        } else {
            var t = Track(kind: .audio, name: Self.bleepTrackName, isTargeted: false)
            try t.overwrite(clip)
            work.tracks.append(t)
        }
        guard work.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        self = work
        return clip.id
    }
}
