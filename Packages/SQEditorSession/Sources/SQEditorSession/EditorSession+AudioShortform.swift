import Foundation
import SQAudioFX
import SQCore
import SQExport
import SQMedia
import SQPlayback

/// Pure helpers for the audio short-form tools (testable without a session).
public enum AudioShortform {
    /// Where dialogue is heard on `clip`: its timeline range minus the pauses.
    public static func activeRanges(of clip: TimeRange, silences: [TimeRange]) -> [TimeRange] {
        LiveDucking.activeRanges(of: clip, silences: silences)
    }

    /// Sorted, with overlapping or touching ranges joined.
    public static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where !r.isEmpty {
            if let last = out.last, r.start <= last.end { out[out.count - 1] = TimeRange(start: last.start, duration: max(last.end, r.end) - last.start) }
            else { out.append(r) }
        }
        return out
    }

    /// Pauses of `clip` in timeline time, as heard: the source level goes through the clip's time mapping (reverse, speed,
    /// ramps), Audio Gain, the volume line and the track fader before it is compared with the threshold. `sourcePeak` is the
    /// linear peak of the media in a source range.
    public static func silences(of clip: Clip, trackVolumeDB: Double = 0, thresholdDB: Double, minimumLength: Time,
                                sourcePeak: (TimeRange) -> Float) -> [TimeRange] {
        let (levels, window) = ClipLevels.audible(of: clip, trackVolumeDB: trackVolumeDB, sourcePeak: sourcePeak)
        return SilenceDetector.silences(levels: levels, window: window, thresholdDB: thresholdDB, minimumLength: minimumLength)
            .map { TimeRange(start: clip.start + $0.start, duration: $0.duration) }
    }

    /// Same, reading the peaks from a decoded waveform.
    public static func silences(of clip: Clip, in data: WaveformData, trackVolumeDB: Double = 0, thresholdDB: Double,
                                minimumLength: Time) -> [TimeRange] {
        WaveformSilences.pauses(of: clip, in: data, trackVolumeDB: trackVolumeDB, thresholdDB: thresholdDB, minimumLength: minimumLength)
    }

    /// Pauses of several overlapping or touching clips together: a range is silent only where EVERY clip covering it is
    /// silent (the others are still heard there). Where clips do not overlap this is the plain union of their pauses.
    /// Gaps between clips are not pauses.
    public static func combinedSilences(_ clips: [(range: TimeRange, silences: [TimeRange])]) -> [TimeRange] {
        let coverage = merged(clips.map(\.range))
        let active = merged(clips.flatMap { activeRanges(of: $0.range, silences: $0.silences) })
        return subtract(active, from: coverage)
    }

    /// `ranges` (sorted, disjoint) minus `cut` (sorted, disjoint).
    public static func subtract(_ cut: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges {
            var cursor = r.start
            for c in cut where c.end > r.start && c.start < r.end {
                if c.start > cursor { out.append(TimeRange(start: cursor, duration: c.start - cursor)) }
                cursor = max(cursor, c.end)
            }
            if r.end > cursor { out.append(TimeRange(start: cursor, duration: r.end - cursor)) }
        }
        return out
    }
}

extension AudioShortform {
    /// Audio tracks that are heard: not muted, and only the solo ones when any audio track is solo.
    public static func audibleTracks(_ t: Timeline) -> [Track] {
        let audio = t.tracks.filter { $0.kind == .audio && !$0.isMuted }
        return audio.contains { $0.isSolo } ? audio.filter(\.isSolo) : audio
    }
}

extension EditorSession {
    /// Selected audio clips (video clips are ignored, also when linked): what the `[` / `]` keys and the tags act on.
    public var selectedAudioClips: [Clip] {
        guard let t = activeTimeline else { return [] }
        return t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && $0.kind == .audio && !$0.isGenerator }
    }

    /// `[` / `]`: Audio Gain of the selected audio clips changes by `db`, one undo step. Never goes below the gain floor.
    @discardableResult
    public func nudgeAudioGain(byDB db: Double) -> Bool {
        let clips = selectedAudioClips
        guard !clips.isEmpty else { return false }
        var gains: [Clip.ID: Double] = [:]
        for c in clips { if let g = AudioGain.apply(.adjust(db), to: c.audioGainDB, peak: nil) { gains[c.id] = g } }
        return setAudioGain(gains)
    }

    /// `nudgeAudioGain` plus the words for the status line ("Gain +1 dB (now +3 dB)"; several clips with different gains say
    /// "Gain +1 dB on 3 clips"). nil = nothing selected or nothing changed. Gain is not the Volume level, so the volume line
    /// does not move; this line is the feedback (parity audit 15).
    public func nudgeAudioGainReport(byDB db: Double) -> String? {
        let selected = selectedAudioClips
        guard !selected.isEmpty else { return nil }
        let before = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.audioGainDB) })
        guard nudgeAudioGain(byDB: db) else { return "Gain at limit" }       // every selected clip is already at the floor / ceiling
        let after = selectedAudioClips
        // The step actually applied: the largest move among the clips (a clip near the limit moves less than asked).
        let moves = after.compactMap { c in before[c.id].map { c.audioGainDB - $0 } }.filter { $0 != 0 }
        let moved = moves.max { abs($0) < abs($1) } ?? db
        let now = Set(after.map(\.audioGainDB))
        let delta = "Gain \(Self.signedDB(moved)) dB"
        if now.count == 1, let g = now.first { return "\(delta) (now \(Self.signedDB(g)) dB)" }
        return "\(delta) on \(after.count) clips"
    }

    private static func signedDB(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        let body = r == r.rounded() ? String(Int(abs(r))) : String(format: "%.1f", abs(r))
        return (r < 0 ? "-" : r > 0 ? "+" : "") + body
    }

    /// Tags the selected audio clips; choosing the tag they all have already removes it. Tag, track role and the clip's
    /// own tag are one system (audit C18): when the selection holds every clip of an audio track, the Tag is that track's
    /// role (its clips inherit it and lose their own tag); clips of tracks only partly selected get their own tag.
    @discardableResult
    public func toggleAudioTag(_ tag: AudioTag) -> Bool {
        let clips = selectedAudioClips
        guard !clips.isEmpty, let tl = activeTimeline else { return false }
        let ids = Set(clips.map(\.id))
        let whole = Self.wholeTracks(of: ids, in: tl)
        let remove = clips.allSatisfy { tl.role(of: $0) == tag }
        if remove, !Self.removalClearsRole(tag, clips: clips, whole: whole, in: tl) { return false }
        return attempt(remove ? "Remove Tag" : "Tag as \(tag.title)") { t in
            for i in t.tracks.indices {
                if whole.contains(t.tracks[i].id) {
                    if remove { if t.tracks[i].audioRole == tag { t.tracks[i].audioRole = nil } }
                    else { t.tracks[i].audioRole = tag }
                }
                for j in t.tracks[i].clips.indices where ids.contains(t.tracks[i].clips[j].id) {
                    var c = t.tracks[i].clips[j]
                    if whole.contains(t.tracks[i].id) { if !remove || c.audioTag == tag { c.audioTag = nil } }
                    else { c.audioTag = remove ? nil : tag }
                    try t.replaceClip(c)
                }
            }
        }
    }

    /// Removing `tag` from clips that all have it must leave them without any role: no clip may end up with another one
    /// (its track's role showing through), and none may keep `tag` (an inherited role has no own tag to clear, and there is
    /// no "no role" tag to give a clip on a partly selected track).
    static func removalClearsRole(_ tag: AudioTag, clips: [Clip], whole: Set<Track.ID>, in tl: Timeline) -> Bool {
        for c in clips {
            guard let tr = tl.tracks.first(where: { $0.clips.contains { $0.id == c.id } }) else { continue }
            let isWhole = whole.contains(tr.id)
            let trackRole = isWhole && tr.audioRole == tag ? nil : tr.audioRole
            let own = c.audioTag == tag ? nil : c.audioTag
            if (own ?? trackRole) != nil { return false }
        }
        return true
    }

    /// What the Clip > Audio Options > Dialogue / Music / SFX items show for the selection.
    public func audioTagMenuState(_ tag: AudioTag) -> AudioTagMenuState {
        let clips = selectedAudioClips
        guard !clips.isEmpty, let tl = activeTimeline, clips.allSatisfy({ tl.role(of: $0) == tag }) else {
            return AudioTagMenuState(checked: false, inherited: false)
        }
        let whole = Self.wholeTracks(of: Set(clips.map(\.id)), in: tl)
        return AudioTagMenuState(checked: true, inherited: clips.allSatisfy { $0.audioTag == nil },
                                 enabled: Self.removalClearsRole(tag, clips: clips, whole: whole, in: tl))
    }

    /// Audio tracks whose every clip is in `ids` (an empty or locked track is never whole).
    static func wholeTracks(of ids: Set<Clip.ID>, in t: Timeline) -> Set<Track.ID> {
        Set(t.tracks.filter { $0.kind == .audio && !$0.isLocked && !$0.clips.isEmpty && $0.clips.allSatisfy { ids.contains($0.id) } }.map(\.id))
    }

    /// Music clips Auto Duck works on: the selected ones with role Music (clip tag, else track role; audit C18), else every
    /// Music clip of the sequence.
    public var musicDuckTargets: [Clip] {
        guard let t = activeTimeline else { return [] }
        let music = t.tracks.filter { $0.kind == .audio }.flatMap { tr in tr.clips.filter { $0.kind == .audio && tr.role(of: $0) == .music } }
        let chosen = music.filter { selection.contains($0.id) }
        return chosen.isEmpty ? music : chosen
    }

    /// Dialogue activity on the timeline: `LiveDucking.dialogueRanges` (enabled, non-generator clips with role Dialogue = clip
    /// tag, else track role, on audible tracks still in live ducking; solo respected) minus the pauses `silences` gives per clip.
    public func dialogueRanges(silences: (Clip) -> [TimeRange]) -> [TimeRange] {
        guard let t = activeTimeline else { return [] }
        return LiveDucking.dialogueRanges(in: t) { c, _ in silences(c) }
    }

    /// Bake Live Duck to Keys (was Auto Duck Music), one undo step. Returns the number of keys written (0 = no dialogue or no
    /// music, and no undo step). Never ducks twice: with live ducking on (`live`, default the project's effective setting) the
    /// keys are the ones live ducking would produce (`LiveDucking.bake`, dialogue = role-Dialogue clips with the playback pauses
    /// in `silences`) and the Music-role tracks leave live ducking in the same step (keyed clips elsewhere leave it through
    /// their keys). Music clips on already excluded tracks get keys from the same live ranges, amount and timing. With live ducking off it is the old Auto Duck on `musicDuckTargets`, `amountDB` / `fade`.
    /// Role everywhere = clip tag, else track role (`Timeline.role(of:)`, audit C18).
    @discardableResult
    public func bakeLiveDuckToKeys(live: LiveDucking? = nil, silences: (any DialogueSilenceProvider)? = nil,
                                   clipSilences: @escaping (Clip) -> [TimeRange] = { _ in [] },
                                   amountDB: Double = Ducking.defaultAmountDB, fade: Time = Ducking.defaultFade) -> Int {
        bakeDuck(live: live, silences: silences, clipSilences: clipSilences, amountDB: amountDB, fade: fade).keysAdded
    }

    /// What a bake did: `keysAdded` new keys; `changed` also when only stale keys went (the dialogue left the clip).
    public struct DuckBakeResult: Equatable, Sendable {
        public var keysAdded = 0
        public var changed = false
    }

    /// `bakeLiveDuckToKeys` with the full result, the one bake behind the Clip menu and the Live Ducking dialog. Without any
    /// dialogue nothing is touched (earlier keys stay, no undo step); with dialogue, keys of clips it no longer reaches are
    /// replaced and reported as `changed`.
    @discardableResult
    public func bakeDuck(live: LiveDucking? = nil, silences: (any DialogueSilenceProvider)? = nil,
                         clipSilences: @escaping (Clip) -> [TimeRange] = { _ in [] },
                         amountDB: Double = Ducking.defaultAmountDB, fade: Time = Ducking.defaultFade) -> DuckBakeResult {
        let run = duckBakeRun(live: live, silences: silences, clipSilences: clipSilences, amountDB: amountDB, fade: fade)
        guard var probe = activeTimeline, let first = try? run(&probe), first.changed else { return DuckBakeResult() }
        var result = DuckBakeResult()
        _ = attempt("Bake Live Duck to Keys") { t in result = try run(&t) }
        return result
    }

    /// Music clips that carry duck keys from an earlier bake which a new bake with the same inputs would change: the dialogue
    /// was edited since (stale), or a key was moved or changed by hand. Bake Again replaces exactly these keys, so the caller
    /// asks first. Never changes the sequence; empty when nothing was baked before or the keys still match.
    public func clipsWithChangedDuckKeys(live: LiveDucking? = nil, silences: (any DialogueSilenceProvider)? = nil,
                                         clipSilences: @escaping (Clip) -> [TimeRange] = { _ in [] },
                                         amountDB: Double = Ducking.defaultAmountDB, fade: Time = Ducking.defaultFade) -> [Clip.ID] {
        guard let before = activeTimeline else { return [] }
        let run = duckBakeRun(live: live, silences: silences, clipSilences: clipSilences, amountDB: amountDB, fade: fade)
        var after = before
        guard (try? run(&after)) != nil else { return [] }
        func duck(_ c: Clip) -> [KeyFingerprint] {
            let ids = Set(c.duckKeyIDs)
            return c.animation.volume.track.keys.filter { ids.contains($0.id) }.map { KeyFingerprint(time: $0.time, value: $0.value) }
                .sorted { $0.time < $1.time }
        }
        let now = Dictionary(after.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return before.tracks.flatMap(\.clips).filter { !$0.duckKeyIDs.isEmpty }.compactMap { c in
            guard let n = now[c.id] else { return nil }
            return duck(c) == duck(n) ? nil : c.id
        }
    }

    private struct KeyFingerprint: Equatable { var time: Time; var value: Double }

    /// The bake as a function of the timeline, shared by the bake itself and the "would it change anything" check.
    private func duckBakeRun(live: LiveDucking?, silences: (any DialogueSilenceProvider)?, clipSilences: @escaping (Clip) -> [TimeRange],
                             amountDB: Double, fade: Time) -> (inout Timeline) throws -> DuckBakeResult {
        let d = (live ?? effectiveLiveDucking).flatMap { $0.isOff ? nil : $0 }
        let pauses = (silences as? WaveformSilences)?.forExport ?? silences
        let targets = musicDuckTargets.map(\.id)
        // With live ducking on, the same ranges as live (playback pauses, lookahead/hold/min pause), so Bake Again keys what is heard.
        let dialogue: [TimeRange]
        if let d, let t = activeTimeline { dialogue = d.expanded(LiveDucking.dialogueRanges(in: t, silences: pauses)) }
        else { dialogue = dialogueRanges(silences: clipSilences) }
        return { t in
            var out = DuckBakeResult()
            // No dialogue at all: nothing to bake, and earlier keys are not wiped as a side effect.
            guard !dialogue.isEmpty else { return out }
            // Clips the live bake keys below: never keyed here as well.
            let liveClips = d == nil ? [] : LiveDucking.bakeTargetIDs(in: t)
            if let d {
                let n = d.bake(into: &t, silences: pauses)
                out.keysAdded += n
                if n > 0 { out.changed = true }
            }
            let amount = d?.amountDB ?? amountDB, attack = d?.fade ?? fade, recovery = d?.recovery
            for id in targets where !liveClips.contains(id) {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                let hadKeys = !c.duckKeyIDs.isEmpty
                let n = c.applyDucking(dialogue: dialogue, amountDB: amount, fade: attack, recovery: recovery)
                out.keysAdded += n
                if n > 0 || hadKeys { out.changed = true }
                try t.replaceClip(c)
            }
            return out
        }
    }

    /// Whether Bake Live Duck to Keys has something to work on: Music clips (clip tag, else track role). Every clip live ducking
    /// acts on is one of them.
    public var canBakeLiveDuck: Bool { !musicDuckTargets.isEmpty }

    /// Clips of the active sequence that live ducking and old Auto Duck keys would duck twice (empty while live ducking is off).
    public var clipsDuckingTwice: [Clip.ID] {
        guard effectiveLiveDucking != nil, let t = activeTimeline else { return [] }
        return LiveDucking.clipsDuckingTwice(in: t)
    }

    /// Removes the old Auto Duck keys from those clips so live ducking is the only duck, one undo step. Returns the clips fixed.
    @discardableResult
    public func removeKeysDuckingTwice() -> Int {
        guard !clipsDuckingTwice.isEmpty else { return 0 }
        var n = 0
        _ = attempt("Remove Duck Keys") { t in n = LiveDucking.removeKeysDuckingTwice(from: &t) }
        return n
    }

    // MARK: Match loudness

    /// Integrated loudness of the clip's audio as heard from its source (no gain, no volume line), nil for silence.
    public func measureLoudness(of clip: Clip) async -> Double? { await measureLoudness(ofRun: [clip]) }

    /// Integrated loudness of a run of clips of one track heard as one piece (gaps stay silent, so they do not count): cut
    /// dialogue measures as a whole instead of per piece. Same source rules as `measureLoudness(of:)`.
    public func measureLoudness(ofRun run: [Clip]) async -> Double? {
        guard let format = activeTimeline?.format, let origin = run.map(\.start).min() else { return nil }
        let clips = run.map { clip -> Clip in
            var c = clip
            c.start = clip.start - origin; c.link = nil; c.audioGainDB = 0
            c.animation.volume = AnimatedProperty(1.0)
            c.audioTag = nil; c.duckKeyIDs = []
            return c
        }
        guard let end = clips.map({ $0.timeline.end }).max() else { return nil }
        var track = Track(kind: .audio)
        for c in clips { try? track.overwrite(c) }
        let tl = Timeline(name: "", format: format, tracks: [track])
        let source = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, end: end), resolver: media)
        guard let m = try? await LoudnessNormalizer.measure(source), m.integratedLUFS.isFinite else { return nil }
        return m.integratedLUFS
    }

    /// Match Loudness on the selected audio clips: Audio Gain is set so each reaches its role's target (clip tag, else track
    /// role, else Dialogue; Dialogue -14 LUFS, Music and SFX 6 dB lower). Returns the number of clips changed; silent clips
    /// stay as they are.
    @discardableResult
    public func matchLoudness() async -> Int {
        let clips = selectedAudioClips
        guard let t = activeTimeline else { return 0 }
        // Adjacent same-role clips of a track are measured as one run and get one gain (cut dialogue stays even).
        let selected = Set(clips.map(\.id))
        let runs = AudioGain.loudnessRuns(of: selected, in: t)
        let targets = runs.map { AudioGain.targetLUFS(for: $0[0], in: t) }   // roles before the awaits
        var gains: [Clip.ID: Double] = [:]
        for (run, target) in zip(runs, targets) {
            let lufs = await measureLoudness(ofRun: run)
            if let g = AudioGain.matchLoudness(measuredLUFS: lufs, targetLUFS: target) {
                for c in run where selected.contains(c.id) { gains[c.id] = g }
            }
        }
        return setAudioGain(gains) ? gains.count : 0
    }

    // MARK: Remove silences

    /// Frame-aligned cuts for the clips' pauses (timeline time). Only audible clips count (enabled, on an unmuted track,
    /// solo respected); where selected clips overlap, a range is a pause only if all of them are silent there.
    public func silenceCuts(for clips: [Clip], silences: (Clip) -> [TimeRange], padding: Time) -> [TimeRange] {
        guard let t = activeTimeline else { return [] }
        let heard = Set(AudioShortform.audibleTracks(t).flatMap(\.clips).filter(\.isEnabled).map(\.id))
        let parts = clips.filter { heard.contains($0.id) }.map { (range: $0.timeline, silences: silences($0)) }
        return SilenceRemoval.cuts(silences: AudioShortform.combinedSilences(parts), padding: padding, frameDuration: t.frameDuration)
    }

    /// Ripple-deletes the cuts through the sequence (`Timeline.removeSilences`): the tracks of `clips` and their linked
    /// partners plus every sync-locked track, so nothing slips out of sync. One undo step, all or nothing.
    @discardableResult
    public func removeSilences(cuts: [TimeRange], from clips: [Clip], crossfade: Bool = true) -> Bool {
        guard !cuts.isEmpty, let fd = activeTimeline?.frameDuration else { return false }
        let ids = Set(clips.map(\.id)), fade = crossfade ? fd : Time.zero
        return attemptRipple("Remove Silences") { _ = try $0.removeSilences(cuts, around: ids, joinFade: fade) }
    }

    // MARK: Proposed cuts (review step of Remove Silences)

    /// Puts `cuts` on the timeline as "proposed cut" markers (replacing earlier proposals of that kind). One undo step.
    @discardableResult
    public func proposeCuts(_ cuts: [TimeRange], kind: ProposedCutKind = .silence) -> Bool {
        attempt("Propose Cuts") { $0.proposeCuts(cuts, kind: kind) }
    }

    /// Puts scene changes (timeline times) on the timeline as point proposals; accepting razors the clips there. One undo step.
    @discardableResult
    public func proposeSceneCuts(_ times: [Time]) -> Bool {
        attempt("Find Scene Changes") { $0.proposeSceneCuts(times) }
    }

    /// Scene-change analysis of `clips` (video clips only; `detect` gets a clip and returns media-time changes, e.g.
    /// `SceneCutAnalyzer.detect` on the clip's file, off the main thread, canceled with the task). The changes strictly
    /// inside each clip's source range are mapped to the timeline and proposed as razor cuts. The proposal is one undo step;
    /// accepting it is another (`acceptProposedCuts`). Returns the number of proposed cuts, nil when canceled or failed.
    public func findSceneChanges(in clips: [Clip], detect: (Clip) async throws -> [Time]) async -> Int? {
        guard let fd = activeTimeline?.frameDuration else { return nil }
        var found: [Time] = []
        for c in clips where c.kind == .video && !c.isGenerator {
            do {
                let times = try await detect(c)
                if Task.isCancelled { return nil }
                found += Self.sceneTimes(of: c, mediaTimes: times, frameDuration: fd)
            } catch { if !(error is CancellationError) { setError(Self.message(for: error)) }; return nil }
        }
        let unique = Array(Set(found)).sorted()
        return proposeSceneCuts(unique) ? unique.count : (unique.isEmpty ? 0 : nil)
    }

    /// Clips Find Scene Changes looks at: the selected (else playhead) video clips that come from a file.
    public var sceneChangeTargets: [Clip] { commandClips(kind: .video).filter { !$0.isGenerator } }

    /// Timeline times of the media-time changes that fall strictly inside `clip`, on the frame grid.
    public static func sceneTimes(of clip: Clip, mediaTimes: [Time], frameDuration fd: Time) -> [Time] {
        mediaTimes.filter { $0 > clip.source.start && $0 < clip.source.end }
            .map { clip.timelineTime(forSource: $0, frameDuration: fd).snapped(to: fd) }
            .filter { $0 > clip.start && $0 < clip.timeline.end }
    }

    /// Accepts the proposals in `ids` (nil = all): ripple cuts through the sequence, one undo step, all or nothing. Cuts the
    /// tracks of the selected audio clips, or of every audible audio clip when none is selected.
    @discardableResult
    public func acceptProposedCuts(_ ids: Set<Marker.ID>?, crossfade: Bool = true) -> Bool {
        guard let t = activeTimeline, !t.proposedCuts.isEmpty else { return false }
        let fade = crossfade ? t.frameDuration : Time.zero
        let chosen = t.proposedCuts.filter { ids?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { return false }
        let hasScenes = chosen.contains { $0.kind == .scene }
        let hasRemovals = chosen.contains { $0.kind != .scene }
        var clips = Set(selectedAudioClips.map(\.id))
        if clips.isEmpty {
            clips = Set(AudioShortform.audibleTracks(t).flatMap(\.clips).filter { $0.kind == .audio && !$0.isGenerator }.map(\.id))
        }
        if hasRemovals, clips.isEmpty { return false }
        // Scene points cut the selected clips (any kind), else every clip.
        var sceneClips = selection.intersection(Set(t.tracks.flatMap(\.clips).map(\.id)))
        if sceneClips.isEmpty { sceneClips = Set(t.tracks.flatMap(\.clips).map(\.id)) }
        if hasScenes, !hasRemovals {
            return attempt("Cut at Scene Changes") { _ = try $0.acceptProposedCuts(ids, around: [], sceneClips: sceneClips, joinFade: fade) }
        }
        let name = chosen.allSatisfy({ $0.kind == .filler }) ? "Remove Filler Words" : "Remove Silences"
        return attemptRipple(name) { _ = try $0.acceptProposedCuts(ids, around: clips, sceneClips: sceneClips, joinFade: fade) }
    }

    /// Result of the review list: cuts the proposals in `accepted` and rejects every other one, as one undo step. Nothing
    /// accepted: the same as rejecting all.
    @discardableResult
    public func reviewProposedCuts(accepted: Set<Marker.ID>, crossfade: Bool = true) -> Bool {
        guard let t = activeTimeline, !t.proposedCuts.isEmpty else { return false }
        let all = Set(t.proposedCuts.map(\.id))
        let keep = accepted.intersection(all)
        if keep.isEmpty { return rejectProposedCuts(nil) }
        let chosen = t.proposedCuts.filter { keep.contains($0.id) }
        let hasRemovals = chosen.contains { $0.kind != .scene }
        var clips = Set(selectedAudioClips.map(\.id))
        if clips.isEmpty {
            clips = Set(AudioShortform.audibleTracks(t).flatMap(\.clips).filter { $0.kind == .audio && !$0.isGenerator }.map(\.id))
        }
        if hasRemovals, clips.isEmpty { return false }
        var sceneClips = selection.intersection(Set(t.tracks.flatMap(\.clips).map(\.id)))
        if sceneClips.isEmpty { sceneClips = Set(t.tracks.flatMap(\.clips).map(\.id)) }
        let fade = crossfade ? t.frameDuration : Time.zero
        let drop = all.subtracting(keep)
        let name = chosen.allSatisfy({ $0.kind == .filler }) ? "Remove Filler Words"
            : (hasRemovals ? "Remove Silences" : "Cut at Scene Changes")
        return attemptRipple(name) { tl in
            for id in drop { tl.rejectProposedCut(id) }
            _ = try tl.acceptProposedCuts(keep, around: hasRemovals ? clips : [], sceneClips: sceneClips, joinFade: fade)
        }
    }

    @discardableResult
    public func rejectProposedCuts(_ ids: Set<Marker.ID>?) -> Bool {
        guard let t = activeTimeline, !t.proposedCuts.isEmpty else { return false }
        return attempt("Reject Proposed Cuts") { tl in
            if let ids { for id in ids { tl.rejectProposedCut(id) } } else { tl.rejectAllProposedCuts() }
        }
    }

    /// The proposal under the playhead, else the next one after it, else the last one before it.
    public func proposedCutAtPlayhead() -> Marker.ID? {
        guard let ps = activeTimeline?.proposedCuts, !ps.isEmpty else { return nil }
        if let under = ps.first(where: { $0.range.start <= playhead && playhead < $0.range.end }) { return under.id }
        return (ps.first { $0.range.start > playhead } ?? ps.last)?.id
    }
}

extension EditorSession {
    /// Track fader (dB, clamped to the fader range) and pan (-1...1) of an audio track, one undo step. Playback, scrubbing and
    /// export read the same fields.
    @discardableResult
    public func setTrackMix(_ id: Track.ID, volumeDB: Double, pan: Double) -> Bool {
        attempt("Track Volume and Pan") { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }), t.tracks[i].kind == .audio else { return }
            // NaN reads as unity / center: it would poison the mix and make the project unsavable (JSON has no NaN).
            t.tracks[i].volumeDB = volumeDB.isNaN ? 0 : min(max(volumeDB, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
            t.tracks[i].pan = pan.isNaN ? 0 : min(max(pan, -1), 1)
        }
    }

    /// Sequence Volume of the active sequence (dB, clamped to the fader range), one undo step; false when unchanged.
    /// Applied after every track and before the delivery limiter, in playback, scrubbing and export alike.
    @discardableResult
    public func setSequenceVolume(_ db: Double) -> Bool {
        guard var probe = activeTimeline else { return false }
        let was = probe.masterVolumeDB
        probe.setMasterVolume(db)
        guard probe.masterVolumeDB != was else { return false }
        return attempt("Sequence Volume") { $0.setMasterVolume(db) }
    }

    /// Sequence Volume as the level dialog applies it (v86, keyable). `animate`: the level becomes a key at the playhead
    /// (same fader range, replaces a key at that time). Not `animate` on a keyed sequence: the keys go and `db` is the
    /// constant level. One undo step; false when nothing changed.
    @discardableResult
    public func setSequenceVolume(_ db: Double, animate: Bool) -> Bool {
        guard let current = activeTimeline else { return false }
        if !animate {
            guard current.isMasterVolumeKeyed else { return setSequenceVolume(db) }
            return attempt("Sequence Volume") { $0.clearMasterVolumeKeys(keeping: db) }
        }
        let at = playhead
        let clamped = db.isNaN ? 0 : min(max(db, TrackPan.minVolumeDB), TrackPan.maxVolumeDB)
        guard !current.masterVolumeKeys.keys.contains(where: { $0.time == at && $0.value == clamped }) else { return false }
        return attempt("Sequence Volume Keyframe") { $0.setMasterVolumeKey(at: at, db: db) }
    }
}

/// Check mark and label of a Tag menu item: every selected clip has this role; `inherited` = none carries its own tag
/// (the role comes from the track).
public struct AudioTagMenuState: Equatable, Sendable {
    public var checked: Bool
    public var inherited: Bool
    /// False for a checked item whose removal would not remove the role (it would stay or turn into another one).
    public var enabled: Bool
    public init(checked: Bool, inherited: Bool, enabled: Bool = true) {
        self.checked = checked; self.inherited = inherited; self.enabled = enabled
    }

    public func title(for tag: AudioTag) -> String { inherited ? "\(tag.title) (inherits track role)" : tag.title }
}
