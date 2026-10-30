import Foundation

public enum ClipEdge: Sendable { case head, tail }

/// A sequence of tracks. (Named `Timeline` so it does not shadow `Swift.Sequence`.)
/// Ripple edits work timeline-wide like Premiere: every track with sync lock on shifts together,
/// locked tracks never shift, and an edit that touches a locked track is refused.
public struct SequenceFormat: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var frameDuration: Time
    public var audioSampleRate: Int
    /// Pixel shape (v82): stored only when not square, so square sequences encode as before (see SequencePixelShape.swift).
    var pixelAspectStore: PixelAspect? = nil

    public init(width: Int = 1920, height: Int = 1080, frameDuration: Time, audioSampleRate: Int = 48_000) {
        self.width = width; self.height = height
        self.frameDuration = frameDuration; self.audioSampleRate = audioSampleRate
    }

    private enum CodingKeys: String, CodingKey { case width, height, frameDuration, audioSampleRate
        case pixelAspectStore = "pixelAspect" }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let fd = try c.decode(Time.self, forKey: .frameDuration)
        guard fd > .zero else {
            throw DecodingError.dataCorruptedError(forKey: .frameDuration, in: c,
                debugDescription: "frame duration must be positive, got \(fd.value)/\(fd.timescale)")
        }
        let w = try c.decode(Int.self, forKey: .width), h = try c.decode(Int.self, forKey: .height)
        let rate = try c.decode(Int.self, forKey: .audioSampleRate)
        guard w > 0, h > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "frame size must be positive, got \(w)x\(h)")
        }
        guard rate > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .audioSampleRate, in: c, debugDescription: "sample rate must be positive, got \(rate)")
        }
        self.init(width: w, height: h, frameDuration: fd, audioSampleRate: rate)
        // A broken or square value opens as square (nothing stored).
        if let a = try? c.decodeIfPresent(PixelAspect.self, forKey: .pixelAspectStore), !a.isSquare { pixelAspectStore = a }
    }
}

public enum InOutKind: String, Sendable, Hashable, Codable { case inOnly, outOnly, both }

public struct Timeline: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var format: SequenceFormat
    public var tracks: [Track]
    public var inOut: TimeRange?
    public var markers: [Marker]
    /// Caption tracks, shown above the video tracks. Ripple edits shift them like sync-locked tracks.
    public var captionTracks: [CaptionTrack]
    /// Label color of the sequence in the Project panel and of its nested clips; nil = default.
    public var label: LabelColor?
    /// False only for an auto-created sequence nobody configured: the first clip placed into it may adopt that clip's
    /// format. Sequence Settings and New Sequence lock it (Premiere). Files without the key decode as locked.
    public var formatLocked: Bool
    /// Which ends of `inOut` the user actually marked (project v19, optional on decode). `inOut` always holds both ends;
    /// an In without Out ends at the sequence end, an Out without In starts at 0. nil = unknown (older file): both are
    /// taken as marked unless the range reaches the sequence end (then In only). Kept consistent by `markIn`, `markOut`,
    /// `setMarkedRange`, `clearIn`/`clearOut` and `shiftInOut`.
    public var inOutKind: InOutKind?
    /// Platform and loudness target the sequence is made for (optional on decode; no project version bump).
    public var deliveryTarget: DeliveryTarget? = nil
    /// Extra frame sizes of this sequence (v26), sharing its edit; see FormatVariants.swift. Empty = base size only.
    public var variants: [FormatVariant] = []
    /// Set when this sequence is the inside of a Group (v30, W7.6; see Grouping.swift). nil = an ordinary sequence.
    public var group: TimelineGroup? = nil
    /// Sequence Volume (v66): stored only when not 0 dB, so untouched sequences encode as before. See `masterVolumeDB`.
    var masterLevel: Double? = nil
    /// Sequence Volume keys (v86), dB in sequence time: stored only when keyed (see `isMasterVolumeKeyed`).
    var masterKeysStore: KeyframeTrack<Double>? = nil
    /// Fast Cut (v67): stored only when not Normal, so Normal sequences encode as before. See `editMode` (ClipAttachment.swift).
    var editModeStore: TimelineEditMode? = nil
    /// Timecode start, display and preview quality (v81): each stored only when not the default (see SequenceTimecode.swift).
    var timecodeStartStore: Time? = nil
    var timecodeDisplayStore: TimecodeDisplay? = nil
    var previewQualityStore: SequencePreviewQuality? = nil
    /// Output channels (v82): stored only when not Stereo (see SequenceChannels.swift).
    var channelLayoutStore: ChannelLayout? = nil
    /// Source patch (v88): stored only when not the default (video to V1, audio to A1, both connected). See `sourcePatch`.
    var sourcePatchStore: SourcePatch? = nil
    /// Snapping and Linked Selection (v91): stored only when off (the default is on). See `snappingOn`, `linkedSelectionOn`.
    var snappingOffStore: Bool? = nil
    var linkedSelectionOffStore: Bool? = nil
    /// Set when this sequence is the inside of an Angles clip (v71, Angles.swift). nil = an ordinary sequence.
    public var angles: AnglesSetup? = nil
    /// Preview render cache (RenderCacheSubstitution.swift): spans of the visible video that playback reads from a rendered
    /// file instead of compositing. Playback-only view state: never encoded, never part of a saved or undone project.
    public var renderCacheSpans: [RenderCacheSpan] = []

    /// Sequence Volume in dB (clamped to the fader range on every set, NaN = 0): the output level of the whole sequence, after every track fader and before the delivery
    /// limiter (playback, scrubbing and export read it through the one mix path). Same range as a track fader; 0 = unity.
    /// A nested sequence's level applies to its sound inside the parent too.
    public var masterVolumeDB: Double {
        get { masterLevel ?? 0 }
        set {
            // NaN = unity; anything else (-inf = silence) is clamped to the fader range.
            let db = newValue.isNaN ? 0 : min(max(newValue, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
            masterLevel = db == 0 ? nil : db
        }
    }

    /// Linear gain of `masterVolumeDB` (1 at 0 dB, 0 at or below the fader floor).
    public var masterGain: Double { masterLevel.map { TrackPan.linear(volumeDB: $0) } ?? 1 }

    /// The Sequence Volume is keyed (v86): its level follows `masterVolumeKeys`; `masterVolumeDB` is then only the level
    /// shown while the keys are cleared.
    public var isMasterVolumeKeyed: Bool { !(masterKeysStore?.isEmpty ?? true) }
    public var masterVolumeKeys: KeyframeTrack<Double> { masterKeysStore ?? KeyframeTrack() }

    /// Sequence Volume in dB at sequence time `t` (the keys' curve, held outside them; the static level when not keyed).
    public func masterVolumeDB(at t: Time) -> Double {
        guard let track = masterKeysStore, !track.isEmpty, let v = track.value(at: t) else { return masterVolumeDB }
        return v.isNaN ? 0 : min(max(v, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
    }

    /// Linear gain at sequence time `t`, the one the audio mix reads (playback, scrub and export).
    public func masterGain(at t: Time) -> Double {
        isMasterVolumeKeyed ? TrackPan.linear(volumeDB: masterVolumeDB(at: t)) : masterGain
    }

    /// Adds (or replaces the key at the same time) a level key; clamped to the fader range, NaN = 0 dB. Returns its id.
    @discardableResult
    public mutating func setMasterVolumeKey(at t: Time, db: Double) -> Keyframe<Double>.ID {
        let v = db.isNaN ? 0 : min(max(db, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
        let k = Keyframe<Double>(time: t, value: v)
        var track = masterKeysStore ?? KeyframeTrack()
        track.insert(k)
        masterKeysStore = track
        return k.id
    }

    public mutating func removeMasterVolumeKey(_ id: Keyframe<Double>.ID) {
        guard var track = masterKeysStore else { return }
        track.remove(id)
        masterKeysStore = track.isEmpty ? nil : track
    }

    /// Drops every key and keeps `db` as the constant Sequence Volume.
    public mutating func clearMasterVolumeKeys(keeping db: Double) {
        masterKeysStore = nil
        masterVolumeDB = db
    }

    /// Sets the Sequence Volume, clamped to the fader range (`TrackPan.minVolumeDB ... maxVolumeDB`); NaN means 0 dB.
    /// Same as assigning `masterVolumeDB` (the property clamps too, decoding included).
    public mutating func setMasterVolume(_ db: Double) { masterVolumeDB = db }

    public var frameDuration: Time {
        get { format.frameDuration }
        set { format.frameDuration = newValue }
    }

    public init(id: UUID = UUID(), name: String, format: SequenceFormat, tracks: [Track] = [],
                inOut: TimeRange? = nil, markers: [Marker] = [], captionTracks: [CaptionTrack] = [], label: LabelColor? = nil,
                formatLocked: Bool = true) {
        self.label = label
        self.formatLocked = formatLocked
        self.id = id; self.name = name; self.format = format; self.tracks = tracks
        self.inOut = inOut; self.markers = markers; self.captionTracks = captionTracks
    }

    /// Premiere-like default track set for a new sequence: `video` video tracks then `audio` audio tracks, the first
    /// of each kind targeted. Empty tracks are allowed.
    public static func defaultTracks(video: Int = SequenceDefaults.videoTrackCount, audio: Int = SequenceDefaults.audioTrackCount) -> [Track] {
        (0..<max(video, 0)).map { Track(kind: .video, isTargeted: $0 == 0) }
            + (0..<max(audio, 0)).map { Track(kind: .audio, isTargeted: $0 == 0) }
    }

    public init(id: UUID = UUID(), name: String, frameDuration: Time, tracks: [Track] = []) {
        self.init(id: id, name: name, format: SequenceFormat(frameDuration: frameDuration), tracks: tracks)
    }

    private enum CodingKeys: String, CodingKey { case id, name, format, tracks, inOut, markers, captionTracks, label, formatLocked, inOutKind, deliveryTarget, variants, group, angles
        case masterLevel = "masterVolumeDB"
        case masterKeysStore = "masterVolumeKeys"
        case editModeStore = "editMode"
        case timecodeStartStore = "timecodeStart", timecodeDisplayStore = "timecodeDisplay", previewQualityStore = "previewQuality"
        case channelLayoutStore = "channelLayout"
        case sourcePatchStore = "sourcePatch"
        case snappingOffStore = "snappingOff", linkedSelectionOffStore = "linkedSelectionOff" }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decode(SequenceFormat.self, forKey: .format)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        inOut = try c.decodeIfPresent(TimeRange.self, forKey: .inOut)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        captionTracks = try c.decodeIfPresent([CaptionTrack].self, forKey: .captionTracks) ?? []
        label = try c.decodeIfPresent(LabelColor.self, forKey: .label)
        formatLocked = try c.decodeIfPresent(Bool.self, forKey: .formatLocked) ?? true
        inOutKind = try c.decodeIfPresent(InOutKind.self, forKey: .inOutKind)
        deliveryTarget = try c.decodeIfPresent(DeliveryTarget.self, forKey: .deliveryTarget)
        variants = try c.decodeIfPresent([FormatVariant].self, forKey: .variants) ?? []
        group = try c.decodeIfPresent(TimelineGroup.self, forKey: .group)
        angles = try c.decodeIfPresent(AnglesSetup.self, forKey: .angles)
        masterVolumeDB = try c.decodeIfPresent(Double.self, forKey: .masterLevel) ?? 0
        if let keys = try c.decodeIfPresent(KeyframeTrack<Double>.self, forKey: .masterKeysStore), !keys.isEmpty {
            masterKeysStore = keys
        }
        editMode = (try? c.decodeIfPresent(TimelineEditMode.self, forKey: .editModeStore)) ?? .normal
        timecodeStartStore = try? c.decodeIfPresent(Time.self, forKey: .timecodeStartStore)
        timecodeDisplayStore = try? c.decodeIfPresent(TimecodeDisplay.self, forKey: .timecodeDisplayStore)
        previewQualityStore = try? c.decodeIfPresent(SequencePreviewQuality.self, forKey: .previewQualityStore)
        channelLayoutStore = try? c.decodeIfPresent(ChannelLayout.self, forKey: .channelLayoutStore)
        if let p = try? c.decodeIfPresent(SourcePatch.self, forKey: .sourcePatchStore), p != SourcePatch() { sourcePatchStore = p }
        if (try? c.decodeIfPresent(Bool.self, forKey: .snappingOffStore)) == true { snappingOffStore = true }
        if (try? c.decodeIfPresent(Bool.self, forKey: .linkedSelectionOffStore)) == true { linkedSelectionOffStore = true }
    }

    public func track(_ id: Track.ID) -> Track? { tracks.first { $0.id == id } }

    // MARK: Ripple delete

    /// Deletes clips (and their linked partners) and closes the gap on all tracks that follow ripple.
    /// Other tracks can block the gap: it closes only as far as nothing collides.
    /// Returns the total time closed, summed over the deleted clips.
    @discardableResult
    public mutating func rippleDelete(_ ids: [Clip.ID]) throws -> Time {
        try rippleDeleteDetailed(ids).closed
    }

    /// `rippleDelete`, also naming the clamp: the track (index) that kept the most gap open and the total shortfall.
    mutating func rippleDeleteDetailed(_ ids: [Clip.ID]) throws -> (closed: Time, clamp: RippleClamp?) {
        var work = self
        var primaries = try ids.map { id -> Clip in
            guard let c = work.find(id)?.clip else { throw EditError.clipNotFound }
            return c
        }
        primaries.sort { $0.start > $1.start }        // right to left: earlier pivots stay valid
        var closed = Time.zero
        var clamp: RippleClamp?
        for p in primaries {
            guard work.find(p.id) != nil else { continue }   // already gone with a linked partner
            let one = try work.rippleDeleteOne(p.id)
            closed += one.closed
            if let c = one.clamp {
                clamp = RippleClamp(track: clamp?.track ?? c.track, shortfall: (clamp?.shortfall ?? .zero) + c.shortfall)
            }
        }
        self = work
        return (closed, clamp)
    }

    /// Removes the group and closes the gap by ONE amount on every involved track, so later material
    /// stays in sync (Premiere): the span of the group's union. Each track closes from its own member's
    /// end (tracks without a member from the group's latest end). If any track lacks room, all close less.
    /// `clamp`: the track with the least room and how much less than the span was closed.
    mutating func rippleDeleteOne(_ id: Clip.ID) throws -> (closed: Time, clamp: RippleClamp?) {
        let group = try linkedGroup(id)
        let ids = Set(group.map(\.clip.id))
        let involved = try involvedTracks(group)
        let minStart = group.map { $0.clip.start }.min() ?? .zero
        let maxEnd = group.map { $0.clip.timeline.end }.max() ?? .zero
        let span = maxEnd - minStart
        var pivot: [Int: Time] = [:]
        for i in involved { pivot[i] = maxEnd }
        // A track with several members shifts from the latest member's end, whichever member was clicked.
        var own: [Int: Time] = [:]
        for m in group { own[m.track] = max(own[m.track] ?? m.clip.timeline.end, m.clip.timeline.end) }
        for (i, e) in own { pivot[i] = e }
        pivot = Self.followingStraddlers(tracks, pivot, excluding: ids)
        var shortfall = Time.zero
        var limiting: Int?
        for i in involved {
            if let room = tracks[i].leftRoom(pivot: pivot[i]!, excluding: ids), span - room > shortfall {
                shortfall = span - room; limiting = i
            }
        }
        for m in group { tracks[m.track].remove(m.clip.id) }
        let d = max(span - shortfall, .zero)
        for i in involved { tracks[i].shift(from: pivot[i]!, by: .zero - d) }
        // Times off every frame grid can need more than Int64 and round: a shift that no longer lands exactly is refused.
        guard tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        closeCaptionSpan(TimeRange(start: maxEnd - d, duration: d))
        return (d, limiting.map { RippleClamp(track: $0, shortfall: span - d) })
    }

    // MARK: Ripple trim

    /// Moves `edge` of a clip by `delta` (timeline direction: tail + = longer, head + = shorter) and
    /// ripples the rest of the sequence. Linked partners follow. The clip's start stays put, like Premiere.
    /// Clamped by the media, by collisions on other tracks when shortening, and refuses to empty a clip.
    /// Returns how far the edge actually moved.
    @discardableResult
    public mutating func rippleTrim(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        try rippleTrim([(id, delta)], edge: edge).moved
    }

    /// Ripple-trims several clips (each with its linked partners) as ONE edit with ONE amount `G`, so every
    /// track, the captions, markers and In/Out shift by the same amount and nothing desyncs.
    ///
    /// Picks with a zero amount are dropped (their clips just ride the ripple). The primary is the pick with the
    /// smallest amount, i.e. the edit nearest the playhead for Q/W; ties break by edge time, so the result does
    /// not depend on track order. Only picks whose edge sits at the primary's edge with the same amount are
    /// trimmed; the others straddle the removed span and behave like any other clip there (they stay put and
    /// limit the trim through the room check). `G` is clamped by every member's media and by the room on every
    /// affected track; a smaller head trim moves the pivot left, so the room check repeats until stable.
    /// Pivots: member tracks shift what follows their member's original end; every other ripple track shifts
    /// from the edit point (tail: the primary's end; head: its start plus the removed span).
    /// `limitedBy`: the track whose clips shortened the trim (not the media).
    /// `shortfall`: how much less the edge moved because of that track (zero when not limited by a clip).
    mutating func rippleTrim(_ picks: [(id: Clip.ID, delta: Time)], edge: ClipEdge) throws
        -> (moved: Time, limitedBy: Int?, shortfall: Time) {
        func amount(_ delta: Time) -> Time { edge == .tail ? delta : .zero - delta }   // change of duration
        func edgeTime(_ c: Clip) -> Time { edge == .head ? c.start : c.timeline.end }
        var cands: [(clip: Clip, g: Time)] = []
        for p in picks {
            guard let m = find(p.id) else { throw EditError.clipNotFound }
            let g = amount(p.delta)
            if g != .zero || picks.count == 1 { cands.append((m.clip, g)) }
        }
        guard let primary = cands.min(by: { a, b in
            let x = a.g < .zero ? .zero - a.g : a.g, y = b.g < .zero ? .zero - b.g : b.g
            return x != y ? x < y : edgeTime(a.clip) < edgeTime(b.clip)
        }) else { return (.zero, nil, .zero) }
        var G = primary.g
        let kept = cands.filter { $0.g == G && edgeTime($0.clip) == edgeTime(primary.clip) }
            .sorted { $0.clip.start < $1.clip.start || ($0.clip.start == $1.clip.start && $0.clip.id.uuidString < $1.clip.id.uuidString) }

        var members: [Member] = []
        var owned = Set<Int>()
        for k in kept {
            let group = try linkedGroup(k.clip.id)
            if group.contains(where: { owned.contains($0.track) }) { continue }   // same group or a clashing one
            if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
            members += group
            for m in group { owned.insert(m.track) }
        }
        for m in members {
            let c = m.clip
            G = c.clampingShortening(G, frame: frameDuration)
            if G <= .zero - c.duration { throw EditError.emptyClip }
            let room: Time? = edge == .tail ? c.tailRoom?.flooredToFrame(frameDuration) : c.headHandle?.flooredToFrame(frameDuration)
            if let room, G > room { G = room }
        }
        let ids = Set(members.map(\.clip.id))
        let others = tracks.indices.filter { tracks[$0].followsRipple && !owned.contains($0) }
        // Other tracks shift from the edit point; for a head trim that depends on how much is removed.
        func cut(_ g: Time) -> Time { edge == .head ? primary.clip.start + max(.zero - g, .zero) : primary.clip.timeline.end }

        // Pivot per shifting track: a member's track from its member's end, the others from the edit point, each moved
        // left to a straddling split-edit partner (`followingStraddlers`).
        func pivots(_ g: Time) -> [Int: Time] {
            var p: [Int: Time] = [:]
            for m in members { p[m.track] = m.clip.timeline.end }
            for i in others { p[i] = cut(g) }
            return Self.followingStraddlers(tracks, p, excluding: ids)
        }
        var limitedBy: Int?
        let beforeRoom = G
        var stable = false
        while !stable && G < .zero {
            stable = true
            let p = pivots(G)
            var checks = members.map { ($0.track, $0.clip.timeline.end) }
            checks += others.map { ($0, p[$0]!) }
            for (i, pivot) in checks {
                if let room = tracks[i].leftRoom(pivot: pivot, excluding: ids), G < .zero - room {
                    G = .zero - room; limitedBy = i; stable = false
                }
            }
        }
        let shortfall = limitedBy == nil ? Time.zero : G - beforeRoom
        if G == .zero { return (.zero, limitedBy, shortfall) }

        var work = tracks
        var ownPivot: [Int: Time] = [:]                    // one shift per track, from its member's end
        for m in members {
            var c = m.clip
            if edge == .head { c.extendHead(by: G) } else { c.extendTail(by: G) }
            work[m.track].replace(c)
            ownPivot[m.track] = m.clip.timeline.end
        }
        for (i, p) in ownPivot { work[i].shift(from: p, by: G, excluding: ids) }
        let p = pivots(G)
        for i in others { work[i].shift(from: p[i]!, by: G, excluding: ids) }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        let at = edgeTime(primary.clip)
        if G < .zero {
            closeCaptionSpan(TimeRange(start: edge == .head ? at : at + G, duration: .zero - G))
        } else {
            openCaptionGap(at: at, by: G)
        }
        return (edge == .tail ? G : .zero - G, limitedBy, shortfall)
    }

    // MARK: Insert

    /// Insert edit: places clips (each on its target track), splits and pushes everything at or
    /// after `at` later by the span of the placements on all ripple tracks. Other tracks get a gap.
    /// Placements keep their start offsets relative to the earliest placement start (J/L cuts): the
    /// earliest lands at `at`, the others at `at` plus their offset. Span = earliest start to latest end.
    /// A time before 0 throws `.collision`; nothing changes then.
    public mutating func insert(_ placements: [(clip: Clip, track: Track.ID)], at t: Time) throws {
        guard let first = placements.map(\.clip.start).min() else { throw EditError.emptyClip }
        guard t >= .zero else { throw EditError.collision }
        guard let d = placements.map({ ($0.clip.start - first) + $0.clip.timeline.duration }).max(), d > .zero
        else { throw EditError.emptyClip }
        var work = tracks
        var targets = Set<Int>()
        for p in placements {
            guard let i = work.firstIndex(where: { $0.id == p.track }) else { throw EditError.clipNotFound }
            if work[i].isLocked { throw EditError.trackLocked }
            guard p.clip.kind == work[i].kind else { throw EditError.wrongTrackKind }
            targets.insert(i)
        }
        var relinks: [UUID: UUID] = [:]
        for i in work.indices where targets.contains(i) || work[i].followsRipple {
            try work[i].split(at: t, relinks: &relinks)
            work[i].shift(from: t, by: d)
        }
        for p in placements {
            var c = p.clip; c.start = t + (p.clip.start - first)
            let i = work.firstIndex { $0.id == p.track }!
            try work[i].overwrite(c, relinks: &relinks)
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        work.clearMainTrackAttachments()
        tracks = work
        openCaptionGap(at: t, by: d)
    }

    // MARK: Helpers

    struct Member { var track: Int; var clip: Clip }

    func find(_ id: Clip.ID) -> Member? {
        for (i, t) in tracks.enumerated() { if let c = t.clip(id) { return Member(track: i, clip: c) } }
        return nil
    }

    /// The clip first, then every clip sharing its link.
    func linkedGroup(_ id: Clip.ID) throws -> [Member] {
        guard let m = find(id) else { throw EditError.clipNotFound }
        var out = [m]
        if let link = m.clip.link {
            for (i, t) in tracks.enumerated() {
                for c in t.clips where c.link == link && c.id != id { out.append(Member(track: i, clip: c)) }
            }
        }
        return out
    }

    /// Tracks that shift: those following ripple plus the group's own. The group's tracks must be unlocked.
    private func involvedTracks(_ group: [Member]) throws -> [Int] {
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        var s = Set(group.map(\.track))
        for i in tracks.indices where tracks[i].followsRipple { s.insert(i) }
        return s.sorted()
    }

    /// Split edits (J/L cuts): a linked clip that straddles its track's pivot while a partner on another shifting track
    /// starts at or after that track's pivot must move with the partner, or the pair desyncs. Its track then shifts
    /// from the straddler's start, so its room limits the ripple like any other clip (a real collision is still a
    /// clamp). Repeats until no pivot moves; pivots only move left to clip starts, so this ends. `pivot`: track index
    /// to the time from which that track shifts. Clips in `ids` (being removed or trimmed) are ignored.
    static func followingStraddlers(_ tracks: [Track], _ pivot: [Int: Time], excluding ids: Set<Clip.ID>) -> [Int: Time] {
        var p = pivot
        var moved = true
        while moved {
            moved = false
            var shifting = Set<UUID>()
            for (i, t) in p {
                for c in tracks[i].clips where c.start >= t && !ids.contains(c.id) { if let l = c.link { shifting.insert(l) } }
            }
            guard !shifting.isEmpty else { break }
            for (i, t) in p {
                if let c = tracks[i].clips.first(where: { $0.start < t && $0.timeline.end > t && !ids.contains($0.id) }),
                   let l = c.link, shifting.contains(l) {
                    p[i] = c.start; moved = true
                }
            }
        }
        return p
    }
}


/// The one place that decides how many tracks a new sequence starts with (new project, new sequence, templates that
/// don't specify tracks). Existing projects and saved templates keep their own counts.
public enum SequenceDefaults {
    public static let videoTrackCount = 4
    public static let audioTrackCount = 4
}
