import Foundation
import Synchronization

/// Live music ducking (N8): the music tracks follow the dialogue tracks while mixing, so a dialogue edit (trim, move, delete,
/// mute) changes the duck immediately and nothing goes stale. Evaluated by the one mix path (playback and export). Which tracks:
/// clips with role Music are ducked, audible clips with role Dialogue are what ducks them (role = clip tag, else track role,
/// `Timeline.role(of:)`, audit C18). Needs no stored field; amount and on/off come from a user setting (`sq.audio.liveDuckingDB`, 0 = off).
/// `Ducking` (the baked volume keys) stays as the optional bake.
public struct LiveDucking: Sendable, Equatable {
    public static let defaultsKey = "sq.audio.liveDuckingDB"
    public var amountDB: Double
    /// Timing of the duck (lookahead, attack, hold, recovery, minimum pause). `DuckTiming.classic` = the original symmetric fade.
    public var timing: DuckTiming
    /// The ramp down into the duck (the original single "fade"; recovery is `timing.recovery`).
    public var fade: Time { timing.attack }
    /// The ramp back up after the duck.
    public var recovery: Time { timing.recovery }

    public init(amountDB: Double = Ducking.defaultAmountDB, fade: Time = Ducking.defaultFade) {
        self.amountDB = amountDB; timing = .classic(fade: fade)
    }

    public init(amountDB: Double, timing: DuckTiming) {
        self.amountDB = amountDB; self.timing = timing.clamped
    }

    public var isOff: Bool { amountDB <= 0 }
    /// Linear gain at full duck.
    public var floorGain: Float { factor }
    var factor: Float { Float(pow(10, -amountDB / 20)) }

    /// The setting (0 or missing = off).
    public static func current(_ defaults: UserDefaults = .standard) -> LiveDucking? {
        let db = defaults.double(forKey: defaultsKey)
        return db > 0 ? LiveDucking(amountDB: min(db, 40), timing: DuckTiming.stored(defaults)) : nil
    }

    /// Amounts offered in Preferences (dB).
    public static let amountChoices: [Double] = [6, 9, 12, 15, 18, 24]

    /// Stores the setting; nil, 0, negative or non-finite removes it (off). Amounts above 40 dB are clamped.
    public static func setAmount(_ db: Double?, defaults: UserDefaults = .standard) {
        if let db, db.isFinite, db > 0 { defaults.set(min(db, 40), forKey: defaultsKey) }
        else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// The live ducking a project plays and exports with: its own stored setting when it has one (N8b), else Preferences.
    public static func resolved(project: ProjectLiveDucking?, defaults: UserDefaults = .standard) -> LiveDucking? {
        if let project { return project.liveDucking }
        return current(defaults)
    }

    /// Whether live ducking acts on `clip`, a top-level clip sitting on `track`: an audio track not excluded from live ducking
    /// (N8b), the clip's role (clip tag, else track role; audit C18) is Music, and it carries no keys of an earlier Auto Duck /
    /// bake (`duckKeyIDs`) unless the track's own role is Music. Old projects sound as before: a Music-tagged clip off a Music
    /// track was keyed and never live-ducked, and stays so; keys on a Music-role track still duck twice (`clipsDuckingTwice`
    /// warns). Cheap and allocation-free: the mix asks it per segment.
    @inline(__always)
    public static func ducks(_ clip: Clip, on track: Track) -> Bool {
        track.kind == .audio && !track.isExcludedFromLiveDucking && track.role(of: clip) == .music
            && (clip.duckKeyIDs.isEmpty || track.audioRole == .music)
    }

    /// The clips live ducking acts on (`ducks(_:on:)`), for the UI and checks; the mix decides per segment.
    public static func duckedClipIDs(in t: Timeline) -> Set<Clip.ID> {
        var out = Set<Clip.ID>()
        for tr in t.tracks where tr.kind == .audio {
            for c in tr.clips where ducks(c, on: tr) { out.insert(c.id) }
        }
        return out
    }

    /// The clips a bake keys: Music-role audio clips on audio tracks still in live ducking, including ones keyed by an earlier
    /// run (their keys are replaced). A superset of `duckedClipIDs` without generators.
    public static func bakeTargetIDs(in t: Timeline) -> Set<Clip.ID> {
        var out = Set<Clip.ID>()
        for tr in t.tracks where tr.kind == .audio && !tr.isExcludedFromLiveDucking {
            for c in tr.clips where c.kind == .audio && !c.isGenerator && tr.role(of: c) == .music { out.insert(c.id) }
        }
        return out
    }

    /// Where dialogue is heard: enabled, non-generator clips with role Dialogue (clip tag, else track role) on audible audio
    /// tracks (not muted, not excluded from live ducking; solo respected), merged.
    /// `window` limits the work to clips near it (pass the block range widened by two fades).
    /// `silences` (N8b): pauses inside a clip release the duck there (as the baked Auto Duck does); a clip without silence
    /// data yet ducks over its whole length.
    public static func dialogueRanges(in t: Timeline, window: TimeRange? = nil,
                                      silences: (any DialogueSilenceProvider)? = nil) -> [TimeRange] {
        dialogueRanges(in: t, window: window) { c, track in silences?.silences(of: c, trackVolumeDB: track.volumeDB) }
    }

    /// Same, with the pauses from a closure (nil or empty = the whole clip). Iterates the tracks in place, window check first.
    public static func dialogueRanges(in t: Timeline, window: TimeRange? = nil,
                                      pauses: (Clip, Track) -> [TimeRange]?) -> [TimeRange] {
        // Per mix block: indexed access (no Clip copies), the cheap role field first, then the window; a clip is copied only
        // when it ducks and has pauses to look up.
        var out: [TimeRange] = []
        let tracks = t.tracks
        let solo = tracks.contains { $0.kind == .audio && !$0.isMuted && $0.isSolo }
        for ti in tracks.indices {
            guard tracks[ti].kind == .audio, !tracks[ti].isMuted, !solo || tracks[ti].isSolo, !tracks[ti].isExcludedFromLiveDucking else { continue }
            let clips = tracks[ti].clips, role = tracks[ti].audioRole
            for i in clips.indices where (clips[i].audioTag ?? role) == .dialogue && clips[i].isEnabled {
                let r = clips[i].timeline
                if let w = window, r.end < w.start || r.start > w.end { continue }
                guard !clips[i].isGenerator else { continue }
                if let s = pauses(clips[i], tracks[ti]), !s.isEmpty {
                    out += activeRanges(of: r, silences: s)
                } else {
                    out.append(r)
                }
            }
        }
        guard !out.isEmpty else { return out }
        var merged: [TimeRange] = []
        for r in out.sorted(by: { $0.start < $1.start }) where !r.isEmpty {
            if let last = merged.last, r.start <= last.end { merged[merged.count - 1] = TimeRange(start: last.start, duration: max(last.end, r.end) - last.start) }
            else { merged.append(r) }
        }
        return merged
    }

    /// Media of the clips that duck the music (export and bake analyze these before mixing, N8b).
    public static func dialogueMedia(in t: Timeline) -> Set<UUID> {
        var out = Set<UUID>()
        let solo = t.tracks.contains { $0.kind == .audio && !$0.isMuted && $0.isSolo }
        for track in t.tracks where track.kind == .audio && !track.isMuted && (!solo || track.isSolo) && !track.isExcludedFromLiveDucking {
            for c in track.clips where c.isEnabled && !c.isGenerator && track.role(of: c) == .dialogue { out.insert(c.media) }
        }
        return out
    }

    /// Where dialogue is heard on `clip`: its range minus the pauses (sorted output; pauses may overlap or stick out).
    public static func activeRanges(of clip: TimeRange, silences: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        var cursor = clip.start
        for s in silences.sorted(by: { $0.start < $1.start }) {
            let a = max(s.start, clip.start), b = min(s.end, clip.end)
            guard b > a else { continue }
            if a > cursor { out.append(TimeRange(start: cursor, duration: a - cursor)) }
            cursor = max(cursor, b)
        }
        if clip.end > cursor { out.append(TimeRange(start: cursor, duration: clip.end - cursor)) }
        return out
    }

    /// The dialogue ranges as the duck sees them: each starts `lookahead` earlier and ends `hold` later; ranges whose gap is at
    /// most the minimum pause become one. Returned unchanged for the classic timing (no allocation).
    public func expanded(_ ranges: [TimeRange]) -> [TimeRange] {
        let tm = timing
        guard tm.lookaheadMs > 0 || tm.holdMs > 0 || tm.minPauseMs > 0 else { return ranges }
        let look = tm.lookahead, hold = tm.hold, pause = tm.minPause
        var out: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            let e = TimeRange(start: r.start - look, end: r.end + hold)
            if let last = out.last, e.start - last.end <= pause { out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, e.end)) }
            else { out.append(e) }
        }
        return out
    }

    /// Linear gain at `time`: full ducking inside a range, linear ramps (attack before, recovery after) on both sides, ranges
    /// closer than attack + recovery hold the duck in between (same rule as the baked keys).
    public func gain(at time: Time, ranges: [TimeRange]) -> Float {
        guard !isOff else { return 1 }
        return rawGain(at: time, ranges: expanded(ranges))
    }

    func rawGain(at time: Time, ranges: [TimeRange]) -> Float {
        let f = factor
        let attack = timing.attack, recovery = timing.recovery
        let attackD = Double(attack.value) / Double(attack.timescale), recoveryD = Double(recovery.value) / Double(recovery.timescale)
        var best: Float = 1
        for (i, r) in ranges.enumerated() {
            if i + 1 < ranges.count, ranges[i + 1].start - r.end <= recovery + attack, time >= r.end, time <= ranges[i + 1].start { return f }
            if time >= r.start && time <= r.end { return f }
            let g: Float
            if time < r.start {
                let d = r.start - time
                if d >= attack { continue }
                g = f + (1 - f) * Float(Double(d.value) / Double(d.timescale) / attackD)
            } else {
                let d = time - r.end
                if d >= recovery { continue }
                g = f + (1 - f) * Float(Double(d.value) / Double(d.timescale) / recoveryD)
            }
            best = min(best, g)
        }
        return best
    }

    /// How far outside the dialogue ranges the duck reaches (window padding for callers that fetch ranges near a block).
    public var reach: Time { timing.lookahead + timing.hold + timing.attack + timing.recovery + timing.minPause }

    /// One breakpoint of the duck curve: linear gain (1 = untouched) at a timeline time.
    public struct CurvePoint: Sendable, Equatable { public var time: Time; public var gain: Float }

    /// N8b: the duck as a polyline over `window` (what the timeline draws on a Music track): the gain at the window edges and at
    /// every ramp corner inside it; linear in between, exactly `gain(at:ranges:)`. Empty when ducking is off.
    public func curve(ranges: [TimeRange], in window: TimeRange) -> [CurvePoint] {
        guard !isOff, !window.isEmpty else { return [] }
        let ranges = expanded(ranges)
        var times: [Time] = [window.start, window.end]
        for r in ranges {
            for t in [r.start - timing.attack, r.start, r.end, r.end + timing.recovery] where t > window.start && t < window.end { times.append(t) }
        }
        times.sort()
        var out: [CurvePoint] = []
        for t in times where out.last?.time != t { out.append(CurvePoint(time: t, gain: rawGain(at: t, ranges: ranges))) }
        return out
    }

    /// N8b bake: writes the live duck curve as volume keys (`Clip.applyDucking`, same ranges, amount, fade and merge rule)
    /// on every bake target (`bakeTargetIDs`: Music-role clips on tracks still in live ducking), then excludes every Music-ROLE
    /// track still in live ducking (as before C18, also empty ones). Other tracks are never excluded (a Dialogue track must keep
    /// ducking): their keyed Music clips leave live ducking through their keys (`ducks(_:on:)`). Without dialogue nothing
    /// changes. Returns the number of keys added.
    /// `silences`: the same pause data live playback uses, so the bake matches what was heard.
    @discardableResult
    public func bake(into t: inout Timeline, silences: (any DialogueSilenceProvider)? = nil) -> Int {
        guard !isOff else { return 0 }
        let ranges = Self.dialogueRanges(in: t, silences: silences)
        guard !ranges.isEmpty else { return 0 }
        let bakeRanges = expanded(ranges)
        let targets = Self.bakeTargetIDs(in: t)
        var added = 0
        for i in t.tracks.indices where t.tracks[i].kind == .audio && !t.tracks[i].isExcludedFromLiveDucking {
            for var c in t.tracks[i].clips where targets.contains(c.id) {
                let n = c.applyDucking(dialogue: bakeRanges, amountDB: amountDB, fade: timing.attack, recovery: timing.recovery)
                if (try? t.replaceClip(c)) != nil { added += n }      // same id, place and length: cannot fail
            }
            if t.tracks[i].audioRole == .music { t.tracks[i].isExcludedFromLiveDucking = true }
        }
        return added
    }

    /// Clips that would duck twice: they carry keys of an earlier Auto Duck / bake (`duckKeyIDs`) and live ducking still ducks
    /// them. Live ducking must be on for this to matter, so the caller only asks while it is. Nothing is rewritten on load.
    public static func clipsDuckingTwice(in t: Timeline) -> [Clip.ID] {
        let ducked = duckedClipIDs(in: t)
        return t.tracks.flatMap(\.clips).filter { ducked.contains($0.id) && !$0.duckKeyIDs.isEmpty }.map(\.id)
    }

    /// Removes those keys again (the clip's own volume line stays), leaving live ducking as the only duck. Returns the clips fixed.
    @discardableResult
    public static func removeKeysDuckingTwice(from t: inout Timeline) -> Int {
        let ids = clipsDuckingTwice(in: t)
        for id in ids {
            guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
            c.removeDuckKeys()                      // drops exactly the generated keys, adds none
            _ = try? t.replaceClip(c)
        }
        return ids.count
    }

    /// Per-frame gains of `[startFrame, startFrame + count)` into `out`.
    public func fill(_ out: UnsafeMutablePointer<Float>, startFrame: Int64, count: Int, rate: Int64, ranges: [TimeRange]) {
        guard !isOff, !ranges.isEmpty else { out.update(repeating: 1, count: count); return }
        let ranges = expanded(ranges)
        for i in 0..<count { out[i] = rawGain(at: Time(startFrame + Int64(i), rate), ranges: ranges) }
    }
}

/// N8b: pauses inside dialogue clips, so the live duck releases there. Implementations read analyzed media (SQPlayback
/// `WaveformSilences`); they are called from the mix thread and must never block on decoding: nil = not known yet (the
/// whole clip then ducks).
public protocol DialogueSilenceProvider: Sendable {
    /// Pauses of `clip` in timeline time as heard through a track fader of `trackVolumeDB`, or nil when not known yet.
    func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]?
}

/// N8b: a project's own live ducking setting, stored in the project file (v43). Overrides Preferences > Audio for that
/// project in playback, scrub and export alike.
public struct ProjectLiveDucking: Sendable, Hashable, Codable {
    public var isOn: Bool
    /// Ducking depth in dB (clamped to 1...40 when used).
    public var amountDB: Double
    /// Timing; nil (older files, or never changed) = `DuckTiming.classic`.
    public var timing: DuckTiming?

    public init(isOn: Bool, amountDB: Double = Ducking.defaultAmountDB, timing: DuckTiming? = nil) {
        self.isOn = isOn; self.amountDB = amountDB; self.timing = timing == .classic ? nil : timing
    }

    /// What the mix uses: nil when off.
    public var liveDucking: LiveDucking? {
        guard isOn, amountDB.isFinite, amountDB > 0 else { return nil }
        return LiveDucking(amountDB: min(max(amountDB, 1), 40), timing: timing ?? .classic)
    }
}

extension Project {
    /// A stored project ducking setting or a track excluded from live ducking (gates ProjectFile v43).
    public var containsLiveDuckingSettings: Bool {
        liveDucking != nil || timelines.contains { $0.tracks.contains(where: \.isExcludedFromLiveDucking) }
    }
}

/// Re-reads `sq.audio.liveDuckingDB` whenever `defaults` changes and reports the new setting (nil = off), so playback follows
/// it live. `onChange` fires only on a real change, on the writing thread: keep it to an atomic store.
public final class LiveDuckingObserver: @unchecked Sendable {
    private let defaults: UserDefaults
    private let onChange: @Sendable (LiveDucking?) -> Void
    private let last: Mutex<LiveDucking?>
    private var token: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard, onChange: @escaping @Sendable (LiveDucking?) -> Void) {
        self.defaults = defaults; self.onChange = onChange
        last = Mutex(LiveDucking.current(defaults))
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    public func refresh() {
        let now = LiveDucking.current(defaults)
        let changed = last.withLock { old -> Bool in defer { old = now }; return old != now }
        if changed { onChange(now) }
    }
}

/// Timing of the live duck, in milliseconds (the Resolve Ducker's controls on our one ducking system). `classic` is what every
/// project did before these controls existed: a 300 ms fade each way, nothing else, so old projects sound the same.
/// `resolve` = the Resolve manual's Ducker defaults (lookahead 15 ms, rise 10 ms, hold 150 ms, recovery 750 ms;
/// docs/research/AUDIO-EFFECTS.md). Mapping of "rise" to our attack ramp is our reading of the manual (unsourced).
public struct DuckTiming: Sendable, Hashable, Codable {
    /// The duck starts this early before dialogue (0...500).
    public var lookaheadMs: Double
    /// Ramp down into the duck (0...2000).
    public var attackMs: Double
    /// The duck stays this long after dialogue before it recovers (0...2000).
    public var holdMs: Double
    /// Ramp back up (0...5000).
    public var recoveryMs: Double
    /// Pauses shorter than this do not release the duck (0...2000): the sensitivity to gaps in speech. Our own control
    /// (the dialogue pauses come from the waveform analysis, whose threshold is fixed).
    public var minPauseMs: Double

    public init(lookaheadMs: Double = 0, attackMs: Double = 300, holdMs: Double = 0, recoveryMs: Double = 300, minPauseMs: Double = 0) {
        self.lookaheadMs = lookaheadMs; self.attackMs = attackMs; self.holdMs = holdMs
        self.recoveryMs = recoveryMs; self.minPauseMs = minPauseMs
    }

    public static let classic = DuckTiming()
    public static let resolve = DuckTiming(lookaheadMs: 15, attackMs: 10, holdMs: 150, recoveryMs: 750, minPauseMs: 0)
    /// Ours (unsourced): bridges short breaths so speech does not pump the music.
    public static let speech = DuckTiming(lookaheadMs: 30, attackMs: 80, holdMs: 250, recoveryMs: 900, minPauseMs: 400)

    static func classic(fade: Time) -> DuckTiming {
        let ms = Double(fade.value) * 1000 / Double(fade.timescale)
        return DuckTiming(attackMs: ms, recoveryMs: ms).clamped
    }

    public var clamped: DuckTiming {
        func c(_ v: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, 0), hi) : 0 }
        return DuckTiming(lookaheadMs: c(lookaheadMs, 500), attackMs: c(attackMs, 2000), holdMs: c(holdMs, 2000),
                          recoveryMs: c(recoveryMs, 5000), minPauseMs: c(minPauseMs, 2000))
    }

    /// Converts back from milliseconds without losing a frame: a value that is a whole number of frames at a common frame
    /// rate becomes exactly that fraction (1/30, 1001/30000), anything else keeps microsecond precision.
    static func time(_ ms: Double) -> Time {
        let sec = ms / 1000
        if sec.isFinite, abs(sec) < 1_000_000 {
            for d: Int64 in [1000, 24, 25, 30, 50, 60, 120, 24_000, 30_000, 60_000] {
                let n = (sec * Double(d)).rounded()
                if abs(sec * Double(d) - n) < 1e-6 { return Time(Int64(n), d) }
            }
        }
        return Time(Int64((ms * 1000).rounded()), 1_000_000)
    }
    var lookahead: Time { Self.time(lookaheadMs) }
    var attack: Time { Self.time(attackMs) }
    var hold: Time { Self.time(holdMs) }
    var recovery: Time { Self.time(recoveryMs) }
    var minPause: Time { Self.time(minPauseMs) }

    // Preferences (user defaults), next to `LiveDucking.defaultsKey`.
    public static let lookaheadKey = "sq.audio.liveDuckingLookaheadMs", attackKey = "sq.audio.liveDuckingAttackMs"
    public static let holdKey = "sq.audio.liveDuckingHoldMs", recoveryKey = "sq.audio.liveDuckingRecoveryMs"
    public static let minPauseKey = "sq.audio.liveDuckingMinPauseMs"

    /// The stored preference; a missing key keeps the classic value.
    public static func stored(_ d: UserDefaults = .standard) -> DuckTiming {
        func v(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        return DuckTiming(lookaheadMs: v(lookaheadKey, 0), attackMs: v(attackKey, 300), holdMs: v(holdKey, 0),
                          recoveryMs: v(recoveryKey, 300), minPauseMs: v(minPauseKey, 0)).clamped
    }

    /// Stores the preference (classic removes the keys).
    public static func store(_ t: DuckTiming, defaults d: UserDefaults = .standard) {
        let t = t.clamped
        if t == .classic { for k in [lookaheadKey, attackKey, holdKey, recoveryKey, minPauseKey] { d.removeObject(forKey: k) }; return }
        d.set(t.lookaheadMs, forKey: lookaheadKey); d.set(t.attackMs, forKey: attackKey); d.set(t.holdMs, forKey: holdKey)
        d.set(t.recoveryMs, forKey: recoveryKey); d.set(t.minPauseMs, forKey: minPauseKey)
    }
}
