import Foundation

// Pitch Shift and Disguise Voice (F7.8). Both run in one spectral engine (SQAudioFX `PitchVocoder`) and delay the sound by
// `AudioPitchValues.latencySamples`, also while switched off. Stored strings: never rename.
//
// Disguise Voice is not anonymization: it makes a voice harder to recognize and nothing more (docs/ENGINE-NOTES.md,
// "Voice disguise: what it can and cannot do"). No text in the app may promise more than that.

extension ClipEffect {
    public static let audioPitchShiftKind = "audio.pitchShift"
    public static let pitchSemitonesKey = "semitones", pitchCentsKey = "cents", pitchFormantsKey = "formants"
    public static let audioDisguiseVoiceKind = "audio.disguiseVoice"
    public static let disguiseVoiceKey = "voice"
}

extension EffectCatalog {
    static let pitchSpecs: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.audioPitchShiftKind, title: "Pitch Shift", params: [
            EffectParamSpec(key: ClipEffect.pitchSemitonesKey, title: "Semitones", unit: "st", defaultValue: 0, range: -12...12, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.pitchCentsKey, title: "Cents", unit: "ct", defaultValue: 0, range: -100...100, step: 1, decimals: 0),
            .checkbox(ClipEffect.pitchFormantsKey, "Preserve Formants", on: true),
        ]),
        // One choice only on purpose: every other number of the disguise comes from a random stream nobody can dial back.
        EffectSpec(kind: ClipEffect.audioDisguiseVoiceKind, title: "Disguise Voice", params: [
            .choice(ClipEffect.disguiseVoiceKey, "Voice", AudioDisguiseValues.voiceTitles, default: 0),
        ]),
    ]
}

/// Shared numbers of the pitch engine.
public enum AudioPitchValues {
    /// One analysis window: the delay of Pitch Shift and of Disguise Voice in samples, also while the effect is off.
    public static let latencySamples = 2_048
    /// Semitones to a frequency ratio.
    public static func ratio(semitones: Double) -> Double { pow(2, semitones / 12) }
    /// `t` as a sample index at `rate` (nearest, whole-number math; negative before the clip's start).
    public static func sample(_ t: Time, rate: Int64) -> Int64 {
        guard t.timescale > 0, rate > 0 else { return 0 }
        let num = 2 * Int128(t.value) * Int128(rate) + Int128(t.timescale), den = 2 * Int128(t.timescale)
        let q = num / den
        return Int64(clamping: num % den < 0 ? q - 1 : q)
    }
}

public enum AudioDisguiseValues {
    /// Stored as the choice index: never reorder.
    public static let voiceTitles = ["Lower", "Higher"]
    /// The one honest description of the effect, used by every hint, tooltip and status line.
    public static let hint = "Makes the voice harder to recognize. Not a guarantee."
}

/// Why Disguise Voice refused a range.
public enum DisguiseVoiceError: Error, LocalizedError, Equatable {
    /// A linked audio clip that carries the same voice sits on a locked track: disguising the rest would leave it as it is.
    case linkedAudioLocked

    public var errorDescription: String? {
        switch self {
        case .linkedAudioLocked:
            "A linked audio clip in this range is on a locked track, so its voice would stay as it is. Unlock the track or unlink the clip, then run Disguise Voice again."
        }
    }
}

extension ClipEffect {
    /// Pitch Shift and Disguise Voice at clip-local `t`; nil for any other kind.
    func pitchStage(atLocal t: Time) -> AudioFXStage? {
        switch kind {
        case Self.audioPitchShiftKind:
            return .pitchShift(semitones: scalar(Self.pitchSemitonesKey, atLocal: t) + scalar(Self.pitchCentsKey, atLocal: t) / 100,
                               preserveFormants: scalar(Self.pitchFormantsKey, atLocal: t) >= 0.5)
        case Self.audioDisguiseVoiceKind:
            // The random modulation is a function of the clip-local position (the engine counts it in its own samples), so a
            // seek and an export land on the same curve.
            return .disguiseVoice(voice: Int(scalar(Self.disguiseVoiceKey, atLocal: t).rounded()), at: t)
        default: return nil
        }
    }
}

extension Clip {
    public var hasDisguiseVoice: Bool { effects.contains { $0.kind == ClipEffect.audioDisguiseVoiceKind } }
}

extension Timeline {
    /// Disguise Voice on `range` of the audio clips `ids`: each clip is cut at the range's edges (its linked partners with it,
    /// so picture and sound stay one pair per part) and every part inside the range gets the Disguise Voice effect. Audio
    /// clips linked to a named clip carry the same voice (dual mono): their parts inside the range are disguised as well.
    /// There is no blend at the edges: a part is either the processed voice or outside the range, and a clip without the
    /// effect never sounds in a transition handle next to a disguised one (`Track.audioTransitionInfo`).
    /// Links follow the range edits: left pieces keep the link, right pieces share a new one, later partners take it.
    /// Returns the parts that carry the effect now (parts that had it already count, they are not doubled).
    /// Throws `.clipNotFound` when no audio clip of `ids` reaches into the range, `.trackLocked` when one sits on a locked
    /// track, `DisguiseVoiceError.linkedAudioLocked` when a linked audio clip in the range does; nothing changes then.
    @discardableResult
    public mutating func disguiseVoice(range: TimeRange, clips ids: Set<Clip.ID>, voice: Int = 0) throws -> [Clip.ID] {
        guard !range.isEmpty else { throw EditError.emptyClip }
        func carriesVoice(_ c: Clip) -> Bool { c.kind == .audio && !c.isGenerator }
        var links = Set<UUID>()
        var found = false
        for tr in tracks where tr.kind == .audio {
            for c in tr.clips where ids.contains(c.id) && carriesVoice(c) && c.timeline.overlaps(range) {
                if tr.isLocked { throw EditError.trackLocked }
                found = true
                if let l = c.link { links.insert(l) }
            }
        }
        guard found else { throw EditError.clipNotFound }
        // What to disguise: (track, the part of the clip inside the range), for the named clips and their linked audio.
        var parts: [(track: Int, range: TimeRange)] = []
        for (i, tr) in tracks.enumerated() where tr.kind == .audio {
            for c in tr.clips where carriesVoice(c) && (ids.contains(c.id) || c.link.map(links.contains) == true) {
                guard let hit = c.timeline.intersection(range), !hit.isEmpty else { continue }
                if tr.isLocked { throw DisguiseVoiceError.linkedAudioLocked }
                parts.append((i, hit))
            }
        }
        var work = tracks
        for cut in [range.start, range.end] {
            var relinks: [UUID: UUID] = [:]
            for i in work.indices where !work[i].isLocked {
                guard let c = work[i].clips.first(where: { $0.timeline.contains(cut) && $0.start < cut }) else { continue }
                // Parts lie inside their clip, so only a piece of that clip can overlap one.
                let own = parts.contains { $0.track == i && c.timeline.overlaps($0.range) }
                guard own || (c.link.map(links.contains) ?? false) else { continue }
                try work[i].split(at: cut, relinks: &relinks)
            }
            // Partners that start at or after the cut belong to the right piece: they take its link.
            for i in work.indices where !work[i].isLocked {
                var hit = false
                let relinked = work[i].clips.map { c -> Clip in
                    var c = c
                    if c.start >= cut, let l = c.link, let n = relinks[l] { c.link = n; hit = true }
                    return c
                }
                if hit { work[i].setClips(relinked) }
            }
            links.formUnion(relinks.values)
        }
        var out: [Clip.ID] = []
        for p in parts {
            for var c in work[p.track].clips {
                guard carriesVoice(c), c.start >= p.range.start, c.timeline.end <= p.range.end else { continue }
                if !c.hasDisguiseVoice {
                    guard let e = c.addEffect(kind: ClipEffect.audioDisguiseVoiceKind) else { continue }
                    c.setParameter(e, ClipEffect.disguiseVoiceKey, to: Double(voice))
                    work[p.track].replace(c)
                }
                out.append(c.id)
            }
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return out
    }
}

extension Project {
    /// The sequences that play nested somewhere below a clip carrying Disguise Voice (transitively, through any depth).
    /// Exporting such a sequence directly plays its voice undisguised: the effect sits on the nest clip outside it.
    public func sequencesNestedUnderDisguiseVoice() -> Set<Timeline.ID> {
        let byID = Dictionary(timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = Set<Timeline.ID>()
        var queue: [Timeline.ID] = []
        for t in timelines {
            for c in t.tracks.flatMap(\.clips) where c.hasDisguiseVoice {
                if let s = c.sequence, result.insert(s).inserted { queue.append(s) }
            }
        }
        while let id = queue.popLast() {          // everything below a disguised nest clip, whatever clips it holds
            for c in byID[id]?.tracks.flatMap(\.clips) ?? [] {
                if let s = c.sequence, result.insert(s).inserted { queue.append(s) }
            }
        }
        return result
    }
}
