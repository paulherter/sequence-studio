import Foundation
import SQCore

// F7.16 Angles clip: several recordings of one event cut like one clip. The model and the edits are SQCore
// (`Angles.swift`); this is what the commands, the dialog and the menus call.

/// One angle Create Angles Clip would build: its name and the media whose file the sync reads (nil: no file).
public struct AngleCandidate: Equatable, Sendable {
    public var name: String
    public var media: MediaRef.ID?
    public var hasAudio: Bool

    public init(name: String, media: MediaRef.ID?, hasAudio: Bool) { self.name = name; self.media = media; self.hasAudio = hasAudio }
}

/// How the angles of a new Angles clip are lined up in time, and the choices the sheet offers (the Mac `AnglesDialog` and the
/// shared shell's dialog read the same rules).
public enum AngleSyncMode: Equatable, Sendable, CaseIterable {
    case inPoints, timecode, audio, timelinePositions

    public var title: String {
        switch self {
        case .inPoints: "In Points"
        case .timecode: "Timecode"
        case .audio: "Audio"
        case .timelinePositions: "Timeline Positions"
        }
    }

    /// The sync choices on offer: Timeline Positions only for clips of a timeline (and then first: it is what the
    /// editor already lined up); Audio only when at least two angles have sound.
    public static func choices(angles: [AngleCandidate], fromTimeline: Bool) -> [AngleSyncMode] {
        var out: [AngleSyncMode] = fromTimeline ? [.timelinePositions, .inPoints, .timecode] : [.inPoints, .timecode]
        if angles.filter(\.hasAudio).count >= 2 { out.append(.audio) }
        return out
    }

    /// The angle whose sound plays by default: the first with sound.
    public static func defaultAudioAngle(_ angles: [AngleCandidate]) -> Int { angles.firstIndex(where: \.hasAudio) ?? 0 }

    /// First free "Angles NN" among `existing` names.
    public static func defaultName(existing: [String]) -> String {
        let names = Set(existing)
        var n = 1
        while names.contains(String(format: "Angles %02d", n)) { n += 1 }
        return String(format: "Angles %02d", n)
    }
}

/// What a number key did.
public enum AngleSwitchResult: Equatable, Sendable {
    case switched
    /// The piece already shows that angle.
    case unchanged
    case noAnglesClip
    /// The Angles clip has only `count` angles.
    case noSuchAngle(count: Int)
    /// Refused (locked track...): `lastError` says why.
    case refused
}

/// What the Angle rows of the timeline menu show for one piece.
public struct AngleMenuState: Equatable, Sendable {
    public var clip: Clip.ID
    public var names: [String]
    public var active: Int
    /// The clicked piece is the sound half: its rows choose the sound's angle.
    public var isAudio: Bool
    /// Audio Follows Video of the piece's sound (nil: the piece has no sound).
    public var followsVideo: Bool?
}

extension EditorSession {
    // MARK: Create

    /// The selected timeline clips in a stable order: what Create Angles Clip works on. The app takes this list once
    /// when the sheet opens, so a selection change during the sync does not change which clips become the Angles clip.
    public var angleSelection: [Clip.ID] { activeTimeline.map { orderedSelection(in: $0) } ?? [] }

    /// The angles the selected timeline clips would become, in angle order (empty: fewer than two).
    public var angleCandidatesOfSelection: [AngleCandidate] { angleCandidates(clips: angleSelection) }

    /// The angles the timeline clips `ids` would become, in angle order (empty: fewer than two).
    public func angleCandidates(clips ids: [Clip.ID]) -> [AngleCandidate] {
        guard let t = activeTimeline, let groups = try? t.angleCandidates(of: ids), groups.count >= 2 else { return [] }
        return groups.map { g in
            let lead = g.first { $0.kind == .video } ?? g[0]
            return AngleCandidate(name: lead.name, media: lead.media, hasAudio: g.contains { $0.kind == .audio })
        }
    }

    /// The angles the media items would become (items without a known length are left out).
    public func angleCandidates(media ids: [MediaRef.ID]) -> [AngleCandidate] {
        ids.compactMap { id in
            guard let ref = project.media(id), ref.info?.isStill != true, (ref.info?.duration ?? ref.duration) != nil else { return nil }
            return AngleCandidate(name: ref.name, media: id, hasAudio: ref.info?.audio != nil)
        }
    }

    /// Selection in a stable order (track, then start), so the same selection always gives the same angles.
    private func orderedSelection(in t: Timeline) -> [Clip.ID] {
        t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }.map(\.id)
    }

    /// Create Angles Clip from media items of the Project panel: one angle per item (its In/Out range, else the whole
    /// file), filed next to the first item. `origins`: where each file's time 0 lies on the common clock (start
    /// timecode, or the shift the audio sync found); empty = sync by In point. Returns the new sequence.
    @discardableResult
    public func createAnglesSequence(media ids: [MediaRef.ID], name: String? = nil, origins: [MediaRef.ID: Time] = [:],
                                     audioAngle: Int = 0, audioFollowsVideo: Bool = false) -> Timeline.ID? {
        let refs = ids.compactMap { project.media($0) }.filter { $0.info?.isStill != true }
        let marks = project.sourceMarks
        let lead = refs.first { $0.info?.video != nil }?.info?.video
        let base = activeTimeline?.format ?? SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30), audioSampleRate: 48_000)
        let format = lead.map {
            SequenceFormat(width: $0.displayWidth, height: $0.displayHeight, frameDuration: $0.nominalFrameDuration,
                           audioSampleRate: base.audioSampleRate).sanitized(fallback: base)
        } ?? base
        var inputs: [AngleInput] = []
        var placing: [(origin: Time?, inPoint: Time)] = []
        for ref in refs {
            guard let total = ref.info?.duration ?? ref.duration,
                  let range = Timeline.sourceEditRange(marks: marks[ref.id] ?? SourceMarks(), total: total) else { continue }
            let source = TimeRange(start: range.start, duration: range.duration.snapped(to: format.frameDuration))
            guard !source.isEmpty else { continue }
            let video = ref.info?.video != nil || ref.info == nil
            let audio = ref.info?.audio != nil
            let link: UUID? = video && audio ? UUID() : nil
            var clips: [Clip] = []
            if video {
                var c = Clip(name: ref.name, media: ref.id, kind: .video, source: source, start: .zero, link: link, mediaDuration: total)
                let fit = ref.info?.video.map { format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
                if abs(fit - 1) > 1e-12 { c.animation.scale = AnimatedProperty(Vec2(fit, fit)) }
                clips.append(c)
            }
            if audio {
                clips.append(Clip(name: ref.name, media: ref.id, kind: .audio, source: source, start: .zero, link: link, mediaDuration: total))
            }
            guard !clips.isEmpty else { continue }
            inputs.append(AngleInput(name: ref.name, clips: clips))
            placing.append((origins[ref.id], source.start))
        }
        for (i, start) in AnglesOffsets.starts(placing).enumerated() { inputs[i].offset = start }
        guard inputs.count >= 2 else { setError("An Angles clip needs at least two clips."); return nil }
        let bin = refs.first.flatMap { project.rootBin.parent(of: .media($0.id)) }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var made: Timeline.ID?
        do {
            try perform("Create Angles Clip") { p in
                made = try p.makeAnglesSequence(name: trimmed.isEmpty ? nil : trimmed, format: format, angles: inputs,
                                                audioAngle: audioAngle, audioFollowsVideo: audioFollowsVideo, bin: bin)
            }
        } catch { setError(Self.message(for: error)); return nil }
        return made
    }

    /// Create Angles Clip from the selected timeline clips: the Angles clip takes their place. `origins` as in
    /// `createAnglesSequence`; nil = the clips keep the positions they have in the timeline.
    @discardableResult
    public func createAnglesClipFromSelection(name: String? = nil, origins: [MediaRef.ID: Time]?, audioAngle: Int = 0,
                                              audioFollowsVideo: Bool = false) -> Timeline.ID? {
        createAnglesClip(from: angleSelection, name: name, origins: origins, audioAngle: audioAngle, audioFollowsVideo: audioFollowsVideo)
    }

    /// Create Angles Clip from the timeline clips `ids` of the active sequence (see `createAnglesClipFromSelection`).
    @discardableResult
    public func createAnglesClip(from ids: [Clip.ID], name: String? = nil, origins: [MediaRef.ID: Time]?, audioAngle: Int = 0,
                                 audioFollowsVideo: Bool = false) -> Timeline.ID? {
        guard let id = activeTimelineID, let t = activeTimeline else { return nil }
        guard let groups = try? t.angleCandidates(of: ids), groups.count >= 2 else {
            setError("An Angles clip needs at least two clips."); return nil
        }
        var offsets: [Clip.ID: Time]?
        if let origins {
            let firsts = groups.map { g in g.min { $0.start < $1.start } }
            let starts = AnglesOffsets.starts(firsts.map { (origin: $0.flatMap { origins[$0.media] }, inPoint: $0?.source.start ?? .zero) })
            var o: [Clip.ID: Time] = [:]
            for (g, at) in zip(groups, starts) { for c in g { o[c.id] = at } }
            offsets = o
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var made: Timeline.ID?
        do {
            try perform("Create Angles Clip") { p in
                made = try p.makeAnglesClip(from: ids, in: id, name: trimmed.isEmpty ? nil : trimmed, offsets: offsets,
                                            audioAngle: audioAngle, audioFollowsVideo: audioFollowsVideo)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let made, let now = activeTimeline {
            select(clips: Set(now.tracks.flatMap(\.clips).filter { $0.sequence == made }.map(\.id)))
        }
        return made
    }

    // MARK: Switch

    /// Number key `n` (1...9). Playing: the Angles piece under the playhead is cut there and shows angle `n` from there
    /// on (one undo step per switch). Stopped: the selected Angles pieces take angle `n` (picture pieces first: their
    /// sound follows or stays as set; only sound pieces selected: their sound switches), else the piece under the playhead.
    @discardableResult
    public func switchAngle(_ n: Int) -> AngleSwitchResult {
        guard n >= 1, let t = activeTimeline else { return .noAnglesClip }
        let index = n - 1
        // A picture piece has as many angles as the Angles sequence has video tracks, a sound piece as it has audio tracks.
        func count(_ c: Clip) -> Int { c.sequence.flatMap { project.timeline($0) }?.tracks.filter { $0.kind == c.kind }.count ?? 0 }
        func silent(_ c: Clip) -> Set<Int> { c.sequence.flatMap { project.timeline($0) }?.silentAngles ?? [] }
        if isPlaying {
            let at = playhead.snapped(to: t.frameDuration)
            guard let piece = t.anglesClip(at: at) else { return .noAnglesClip }
            guard index < count(piece) else { return .noSuchAngle(count: count(piece)) }
            let mute = silent(piece)   // read before the edit: the closure runs inside `project`'s write access
            return commitAngle(t) { try $0.switchAngle(index, at: at, clip: piece.id, silent: mute) }
        }
        let chosen = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.isAnglesClip }
        var pieces = chosen.filter { $0.kind == .video }
        if pieces.isEmpty { pieces = chosen }
        if pieces.isEmpty, let under = t.anglesClip(at: playhead) { pieces = [under] }
        guard !pieces.isEmpty else { return .noAnglesClip }
        let fits = pieces.filter { index < count($0) }
        guard !fits.isEmpty else { return .noSuchAngle(count: pieces.map(count).max() ?? 0) }
        let mutes = fits.map { ($0.id, silent($0)) }   // read before the edit (see above)
        return commitAngle(t) { tl in for (id, mute) in mutes { try tl.setAngle(index, on: id, silent: mute) } }
    }

    /// Tries the switch on a copy first: a key that changes nothing cuts nothing and adds no undo step.
    private func commitAngle(_ t: Timeline, _ body: (inout Timeline) throws -> Void) -> AngleSwitchResult {
        clearError()
        var trial = t
        do { try body(&trial) } catch { setError(Self.message(for: error)); return .refused }
        guard trial != t else { return .unchanged }
        if attempt("Switch Angle", body) { return .switched }
        return lastError == nil ? .unchanged : .refused
    }

    /// Angle `index` (0-based) for the piece `id`: the timeline menu's Angle rows.
    @discardableResult
    public func setAngle(_ index: Int, on id: Clip.ID) -> Bool {
        let seq = activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.sequence
        let mute = seq.flatMap { project.timeline($0) }?.silentAngles ?? []   // read before the edit's write access
        return attempt("Switch Angle") { tl in
            _ = try tl.setAngle(index, on: id, silent: mute)
        }
    }

    /// Audio Follows Video for the piece `id` and its linked pieces.
    @discardableResult
    public func setAudioFollowsVideo(_ on: Bool, on id: Clip.ID) -> Bool {
        attempt("Audio Follows Video") { try $0.setAudioFollowsVideo(on, on: id) }
    }

    /// Flatten Angles Clip: the piece `id` and its linked pieces become the plain clips of the angles they show.
    @discardableResult
    public func flattenAngles(clip id: Clip.ID) -> Bool {
        guard let tid = activeTimelineID else { return false }
        clearError()
        do { try perform("Flatten Angles Clip") { try $0.flattenAngles(clip: id, in: tid) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    /// The Angle rows for the piece `id` (nil: not an Angles clip).
    public func angleMenuState(for id: Clip.ID) -> AngleMenuState? {
        guard let t = activeTimeline, let c = t.tracks.flatMap(\.clips).first(where: { $0.id == id }), c.isAnglesClip,
              let angle = c.angle, let inner = c.sequence.flatMap({ project.timeline($0) }) else { return nil }
        let names = inner.angleNames
        // The linked sound part; on a locked sound track the live switch left the sound whole, linked to an earlier part:
        // then the sound of the same Angles sequence that plays where this part starts.
        let sounds = t.tracks.flatMap(\.clips).filter { $0.kind == .audio && $0.isAnglesClip }
        let sound: Clip? = c.kind == .audio ? c
            : sounds.first { $0.link != nil && $0.link == c.link }
            ?? sounds.first { $0.sequence == c.sequence && $0.start <= c.start && c.start < $0.timeline.end }
        return AngleMenuState(clip: id, names: names, active: min(max(angle.index, 0), max(names.count - 1, 0)),
                              isAudio: c.kind == .audio, followsVideo: sound?.angle?.followsVideo)
    }
}
