import Foundation

// Angles clip (v71, F7.16): several recordings of one event, cut like one clip.
//
// It is a nested sequence, not a second mechanism: the Angles sequence holds one video track and one audio track per
// angle (angle n = the n-th video track from the bottom and the n-th audio track; a track may be empty when an angle has
// no picture or no sound). The clip that plays it carries `Clip.angle`: which angle this piece shows (video clip) or
// sounds (audio clip). Evaluation reads the inner sequence through `Clip.angleView(of:)`, which keeps only that angle's
// track, so playback and export never request (or decode) the other angles.
//
// Switching is an ordinary edit: blade the clip and give a piece another angle. The pieces stay normal clips (trim, roll,
// ripple, transitions); two butted pieces with the same angle are a through edit and can be joined.

/// Which angle a piece of an Angles clip plays.
public struct AngleChoice: Sendable, Hashable, Codable {
    /// Angle index, 0-based: the n-th track of the clip's kind in the Angles sequence.
    public var index: Int
    /// Audio clips only: Audio Follows Video. True = switching the picture angle of the linked video clip switches this
    /// sound too; false = the sound stays on its angle (one microphone for the whole clip).
    public var followsVideo: Bool

    public init(index: Int, followsVideo: Bool = false) { self.index = index; self.followsVideo = followsVideo }

    private enum CodingKeys: String, CodingKey { case index, followsVideo }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        followsVideo = try c.decodeIfPresent(Bool.self, forKey: .followsVideo) ?? false
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        if followsVideo { try c.encode(true, forKey: .followsVideo) }
    }
}

/// Marks a sequence as the inside of an Angles clip and holds what a newly placed Angles clip starts with.
public struct AnglesSetup: Sendable, Hashable, Codable {
    /// The angle whose sound a new Angles clip uses (ignored with `audioFollowsVideo`).
    public var audioAngle: Int
    /// Audio Follows Video for a new Angles clip.
    public var audioFollowsVideo: Bool

    public init(audioAngle: Int = 0, audioFollowsVideo: Bool = false) {
        self.audioAngle = audioAngle; self.audioFollowsVideo = audioFollowsVideo
    }

    /// The choice a freshly placed clip of `kind` starts with: picture on angle 1, sound on the chosen angle.
    public func firstChoice(for kind: TrackKind) -> AngleChoice {
        kind == .video ? AngleChoice(index: 0)
            : AngleChoice(index: audioFollowsVideo ? 0 : audioAngle, followsVideo: audioFollowsVideo)
    }
}

/// One angle for `Project.makeAnglesSequence`.
public struct AngleInput: Sendable {
    public var name: String
    /// The angle's clips (usually one video clip and its linked audio clip). Their starts are kept relative to each other.
    public var clips: [Clip]
    /// Where the angle's earliest clip starts on the common clock (any origin, may be negative): the angles are shifted
    /// so the earliest starts at 0.
    public var offset: Time

    public init(name: String, clips: [Clip], offset: Time = .zero) { self.name = name; self.clips = clips; self.offset = offset }
}

extension Clip {
    /// True for a piece of an Angles clip.
    public var isAnglesClip: Bool { angle != nil && sequence != nil }

    /// The Angles sequence as this piece plays it: of the tracks of the clip's kind only the active angle's stays
    /// (an index past the last angle plays the last). Not an Angles clip: `inner` unchanged.
    public func angleView(of inner: Timeline) -> Timeline {
        guard let angle else { return inner }
        let count = inner.tracks.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
        guard count > 1 else { return inner }
        let wanted = min(max(angle.index, 0), count - 1)
        var out = inner
        var n = 0
        out.tracks = inner.tracks.filter { t in
            guard t.kind == kind else { return true }
            defer { n += 1 }
            return n == wanted
        }
        return out
    }
}

extension Timeline {
    /// Number of angles of an Angles sequence (its video tracks; at least its audio tracks).
    public var angleCount: Int {
        max(tracks.reduce(0) { $0 + ($1.kind == .video ? 1 : 0) }, tracks.reduce(0) { $0 + ($1.kind == .audio ? 1 : 0) })
    }

    /// Display names of the angles: the angle's video track name, else its audio track name, else "Angle n".
    public var angleNames: [String] {
        let v = tracks.filter { $0.kind == .video }, a = tracks.filter { $0.kind == .audio }
        return (0..<angleCount).map { i in
            let name = (i < v.count ? v[i].name : nil) ?? (i < a.count ? a[i].name : nil) ?? ""
            return name.isEmpty ? "Angle \(i + 1)" : name
        }
    }

    /// Angles whose sound track is missing or empty: a sound piece is not switched to one of these (it keeps its previous
    /// sound), so a camera without a microphone never mutes the cut.
    public var silentAngles: Set<Int> {
        let audio = tracks.filter { $0.kind == .audio }
        return Set((0..<angleCount).filter { $0 >= audio.count || audio[$0].clips.isEmpty })
    }

    /// The Angles clip piece under `t`: on the topmost video track that has one, else on the first audio track.
    public func anglesClip(at t: Time) -> Clip? {
        func hit(_ track: Track) -> Clip? {
            track.clips.first { $0.isAnglesClip && $0.isEnabled && $0.start <= t && t < $0.timeline.end }
        }
        for track in tracks.reversed() where track.kind == .video { if let c = hit(track) { return c } }
        for track in tracks where track.kind == .audio { if let c = hit(track) { return c } }
        return nil
    }

    /// Gives the piece `id` another angle. On a video piece: the picture switches, and so does the sound of every linked
    /// audio piece that follows the video. On an audio piece: only the sound (of it and its linked audio pieces) switches.
    /// Returns false when nothing changed. Throws `.clipNotFound` if `id` is no Angles clip, `.trackLocked` if a piece
    /// that would change is on a locked track.
    @discardableResult
    public mutating func setAngle(_ index: Int, on id: Clip.ID, silent: Set<Int> = []) throws -> Bool {
        let group = try linkedGroup(id)
        guard let target = group.first, target.clip.isAnglesClip, index >= 0 else { throw EditError.clipNotFound }
        let changed = angleChanges(index, in: group, silent: silent)
        if changed.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        for x in changed { tracks[x.track].replace(x.clip) }
        return !changed.isEmpty
    }

    /// The pieces of `group` whose angle changes when its first piece takes angle `index`, with the new angle set: the
    /// one rule both the whole-piece switch and the live switch use (a sound that keeps its angle is not in the list).
    /// `silent`: angles without sound (`Timeline.silentAngles` of the Angles sequence): a sound piece does not switch to
    /// one of them and keeps its previous sound.
    private func angleChanges(_ index: Int, in group: [Member], silent: Set<Int>) -> [(track: Int, clip: Clip)] {
        guard let target = group.first else { return [] }
        var changed: [(track: Int, clip: Clip)] = []
        for m in group {
            guard var a = m.clip.angle, m.clip.sequence == target.clip.sequence else { continue }
            let follows = target.clip.kind == .video ? (m.clip.kind == .video || a.followsVideo) : m.clip.kind == .audio
            guard follows, a.index != index, !(m.clip.kind == .audio && silent.contains(index)) else { continue }
            a.index = index
            var c = m.clip
            c.angle = a
            changed.append((m.track, c))
        }
        return changed
    }

    /// Audio Follows Video for the piece `id` and its linked pieces: on, the sound takes the picture's angle now and on
    /// every later switch; off, it stays where it is. Returns false when nothing changed.
    @discardableResult
    public mutating func setAudioFollowsVideo(_ on: Bool, on id: Clip.ID) throws -> Bool {
        let group = try linkedGroup(id)
        guard let target = group.first, target.clip.isAnglesClip else { throw EditError.clipNotFound }
        let picture = group.first { $0.clip.kind == .video && $0.clip.isAnglesClip }?.clip.angle?.index
        var changed: [(track: Int, clip: Clip)] = []
        for m in group where m.clip.kind == .audio {
            guard var a = m.clip.angle, m.clip.sequence == target.clip.sequence else { continue }
            a.followsVideo = on
            if on, let picture { a.index = picture }
            guard a != m.clip.angle else { continue }
            var c = m.clip
            c.angle = a
            changed.append((m.track, c))
        }
        if changed.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        for x in changed { tracks[x.track].replace(x.clip) }
        return !changed.isEmpty
    }

    /// Cuts the piece `id` (and its linked pieces under `t` that switch with it) at `t` and gives the part from `t` on another angle: the
    /// live switch of the number keys. At or before the piece's start the whole piece switches without a cut. Returns the
    /// piece that now plays from `t`, or nil when the piece already shows that angle (nothing changes) or `t` is at or
    /// past its end.
    @discardableResult
    public mutating func switchAngle(_ index: Int, at t: Time, clip id: Clip.ID, silent: Set<Int> = []) throws -> Clip.ID? {
        let group = try linkedGroup(id)
        guard let target = group.first, target.clip.isAnglesClip, index >= 0 else { throw EditError.clipNotFound }
        guard target.clip.angle?.index != index, t < target.clip.timeline.end else { return nil }
        if t <= target.clip.start { return try setAngle(index, on: id, silent: silent) ? id : nil }
        // Every linked piece under `t` is cut with the picture (a normal blade), so each part keeps its own linked sound
        // part and later ripple edits stay in sync. Only a piece that changes its angle needs an unlocked track: a sound
        // that keeps its angle on a locked track stays whole and does not stop the switch.
        let changing = Set(angleChanges(index, in: group, silent: silent).map(\.clip.id))
        let under = group.filter { $0.clip.start < t && t < $0.clip.timeline.end }
        if under.contains(where: { changing.contains($0.clip.id) && tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let cut = under.filter { !tracks[$0.track].isLocked }
        var work = self
        var relinks: [UUID: UUID] = [:]
        for i in Set(cut.map(\.track)).sorted() { try work.tracks[i].split(at: t, relinks: &relinks) }
        guard let right = work.tracks[target.track].clips.first(where: { $0.start == t }) else { throw EditError.collision }
        try work.setAngle(index, on: right.id, silent: silent)
        self = work
        return right.id
    }
}

extension Timeline {
    /// The angles `makeAnglesClip` builds from `ids`: every clip with its linked partners is one angle, ordered by video
    /// track from the bottom (sound-only angles last), then by start.
    func angleGroups(of ids: [Clip.ID]) throws -> [[Member]] {
        var groups: [[Member]] = []
        var seen = Set<Clip.ID>()
        for id in ids where !seen.contains(id) {
            let g = try linkedGroup(id)
            g.forEach { seen.insert($0.clip.id) }
            groups.append(g)
        }
        func order(_ g: [Member]) -> (Int, Int, Time) {
            let v = g.filter { $0.clip.kind == .video }.map(\.track).min()
            return (v == nil ? 1 : 0, v ?? g.map(\.track).min() ?? 0, g.map(\.clip.start).min() ?? .zero)
        }
        return groups.sorted { order($0) < order($1) }
    }

    /// The clips of each angle Create Angles Clip would build from `ids`, in angle order (for the dialog and the sync).
    public func angleCandidates(of ids: [Clip.ID]) throws -> [[Clip]] {
        try angleGroups(of: ids).map { $0.map(\.clip) }
    }
}

extension Project {
    /// Builds an Angles sequence: one video and one audio track per angle (audio tracks only when an angle has sound),
    /// each angle shifted by its offset so the earliest starts at 0 (on the frame grid of `format`). Filed in `bin`
    /// (root when nil) and named "Angles NN" unless `name` is given. `audioAngle` falls back to the first angle with
    /// sound. Throws `.emptyClip` without clips, `.collision` if an angle's own clips overlap.
    @discardableResult
    public mutating func makeAnglesSequence(name: String? = nil, format: SequenceFormat, angles: [AngleInput],
                                            audioAngle: Int = 0, audioFollowsVideo: Bool = false,
                                            bin: Bin.ID? = nil) throws -> Timeline.ID {
        let used = angles.filter { !$0.clips.isEmpty }
        guard !used.isEmpty, let earliest = used.map(\.offset).min() else { throw EditError.emptyClip }
        let fd = format.frameDuration
        let hasAudio = used.contains { $0.clips.contains { $0.kind == .audio } }
        var video: [Track] = [], audio: [Track] = []
        for (i, angle) in used.enumerated() {
            let name = angle.name.isEmpty ? "Angle \(i + 1)" : angle.name
            var v = Track(kind: .video, name: name, isTargeted: i == 0), a = Track(kind: .audio, name: name, isTargeted: i == 0)
            let base = angle.clips.map(\.start).min() ?? .zero
            let shift = (angle.offset - earliest).snapped(to: fd)
            for var c in angle.clips {
                c.start = shift + (c.start - base)
                c.attachment = nil
                if c.kind == .video {
                    guard !v.clips.contains(where: { $0.timeline.overlaps(c.timeline) }) else { throw EditError.collision }
                    try v.overwrite(c)
                } else {
                    guard !a.clips.contains(where: { $0.timeline.overlaps(c.timeline) }) else { throw EditError.collision }
                    try a.overwrite(c)
                }
            }
            video.append(v)
            if hasAudio { audio.append(a) }
        }
        let withSound = audio.indices.filter { !audio[$0].clips.isEmpty }
        let sound = withSound.contains(audioAngle) ? audioAngle : (withSound.first ?? 0)
        let id = UUID()
        var seq = Timeline(id: id, name: name ?? nextAnglesName(), format: format, tracks: video + audio)
        seq.angles = AnglesSetup(audioAngle: sound, audioFollowsVideo: audioFollowsVideo)
        guard seq.duration > .zero else { throw EditError.emptyClip }
        timelines.append(seq)
        let target = bin ?? rootBin.id
        if !rootBin.modify(target, { $0.children.append(.sequence(id)) }) { rootBin.children.append(.sequence(id)) }
        return id
    }

    /// Create Angles Clip from timeline clips: every selected clip with its linked partners becomes one angle (ordered by
    /// track from the bottom, then by start) and the Angles clip takes their place: at the earliest start, on the lowest
    /// involved video and audio track.
    /// `offsets`: where each angle starts on the common clock, keyed by any of its clips; nil = the positions the clips
    /// have in the timeline. An angle without an entry starts at 0.
    /// Throws `.trackLocked`, `.collision` (an unselected clip lies where the Angles clip goes), `.emptyClip` (fewer than
    /// two angles) or `.clipNotFound`. Returns the new sequence.
    @discardableResult
    public mutating func makeAnglesClip(from ids: [Clip.ID], in timelineID: Timeline.ID, name: String? = nil,
                                        offsets: [Clip.ID: Time]? = nil, audioAngle: Int = 0,
                                        audioFollowsVideo: Bool = false) throws -> Timeline.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        var tl = timelines[ti]
        let groups = try tl.angleGroups(of: ids)
        let selected = Set(groups.flatMap { $0 }.map(\.clip.id))
        guard groups.count >= 2 else { throw EditError.emptyClip }
        if groups.contains(where: { $0.contains { tl.tracks[$0.track].isLocked } }) { throw EditError.trackLocked }
        let inputs = groups.map { g -> AngleInput in
            let start = g.map(\.clip.start).min() ?? .zero
            let offset = offsets.map { o in g.compactMap { o[$0.clip.id] }.first ?? .zero } ?? start
            return AngleInput(name: g.first { $0.clip.kind == .video }?.clip.name ?? g[0].clip.name, clips: g.map(\.clip), offset: offset)
        }
        var work = self
        let bin = rootBin.parent(of: .sequence(timelineID))
        let seqID = try work.makeAnglesSequence(name: name, format: tl.format, angles: inputs, audioAngle: audioAngle,
                                                audioFollowsVideo: audioFollowsVideo, bin: bin)
        guard let s = groups.flatMap({ $0 }).map(\.clip.start).min(), let made = work.sequenceClips(of: seqID, at: s) else {
            throw EditError.emptyClip
        }
        let involved = Set(groups.flatMap { $0 }.map(\.track)).sorted()
        for i in involved {
            for id in selected { tl.tracks[i].remove(id) }
            tl.tracks[i].transitions.removeAll { tr in
                tr.outgoing.map(selected.contains) == true || tr.incoming.map(selected.contains) == true
            }
        }
        var placedVideo: Clip.ID?
        for c in made {
            guard let target = involved.first(where: { tl.tracks[$0].kind == c.kind }) else { continue }
            if tl.tracks[target].clips.contains(where: { $0.timeline.overlaps(c.timeline) }) { throw EditError.collision }
            try tl.tracks[target].overwrite(c)
            if c.kind == .video { placedVideo = c.id }
        }
        if let placedVideo {
            tl.remapAttachments(Dictionary(uniqueKeysWithValues: selected.map { ($0, placedVideo) }), keepUnmapped: true)
        }
        work.timelines[ti] = tl
        self = work
        return seqID
    }

    private func nextAnglesName() -> String {
        let names = Set(timelines.map(\.name))
        var n = 1
        while names.contains(String(format: "Angles %02d", n)) { n += 1 }
        return String(format: "Angles %02d", n)
    }
}

/// Where the angles of a new Angles clip start, for every sync mode.
public enum AnglesOffsets {
    /// The start of each angle on the common clock (`AngleInput.offset`). `origin`: where the angle's file time 0 lies on
    /// that clock (start timecode, the shift the sound match found), nil when nothing places the file. `inPoint`: the
    /// source time of the angle's first frame.
    /// An origin places the file's time 0, so that angle starts at origin + In point. An angle without an origin starts
    /// with the earliest placed angle: its In point is at 0 of the Angles sequence. No origin at all: every In point is at 0.
    public static func starts(_ angles: [(origin: Time?, inPoint: Time)]) -> [Time] {
        let placed = angles.map { a in a.origin.map { $0 + a.inPoint } }
        let earliest = placed.compactMap { $0 }.min() ?? .zero
        return placed.map { $0 ?? earliest }
    }
}
