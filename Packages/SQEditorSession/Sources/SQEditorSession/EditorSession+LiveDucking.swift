import Foundation
import SQCore
import SQPlayback

extension EditorSession {
    static let projectLiveDuckingUndoName = "Set Project Live Ducking"

    /// N8b: the project's own live ducking (nil = follow Preferences > Audio), one undo step. Playback, scrub and export use it.
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) {
        guard project.liveDucking != setting else { return }
        perform(Self.projectLiveDuckingUndoName) { $0.liveDucking = setting }
    }

    /// N8b: excludes an audio track from live ducking (or takes it back in), one undo step.
    @discardableResult
    public func setTrackExcludedFromLiveDucking(_ id: Track.ID, _ excluded: Bool) -> Bool {
        guard let tr = activeTimeline?.tracks.first(where: { $0.id == id }), tr.kind == .audio,
              tr.isExcludedFromLiveDucking != excluded else { return false }
        return attempt(excluded ? "Exclude from Live Ducking" : "Include in Live Ducking") { t in
            guard let i = t.tracks.firstIndex(where: { $0.id == id }) else { return }
            t.tracks[i].isExcludedFromLiveDucking = excluded
        }
    }

    /// N8b: bakes the live duck curve into volume keys (one undo step). The same path as Clip > Bake Live Duck to Keys
    /// (`bakeLiveDuckToKeys(live:)`), kept for the Live Ducking dialog: `ducking` default is the project's effective setting;
    /// off (nil or amount 0) bakes nothing. Returns the number of keys written.
    @discardableResult
    public func bakeLiveDucking(_ ducking: LiveDucking? = nil, silences: (any DialogueSilenceProvider)? = nil) -> Int {
        guard let d = ducking ?? effectiveLiveDucking, !d.isOff else { return 0 }
        return bakeLiveDuckToKeys(live: d, silences: silences)
    }

    /// The live ducking the active project plays with now (its own setting, else Preferences).
    public var effectiveLiveDucking: LiveDucking? { LiveDucking.resolved(project: project.liveDucking) }
}

/// N8b: the choices of "Live Ducking for This Project…": follow Preferences, off, or one of the Preferences amounts (plus the
/// stored amount when it is not one of them).
public enum ProjectLiveDuckingChoices {
    public struct Choice: Equatable, Sendable {
        public var title: String
        public var setting: ProjectLiveDucking?
    }

    public static func choices(current: ProjectLiveDucking?, preferences: LiveDucking?) -> [Choice] {
        let pref = preferences.map { "\(format($0.amountDB)) dB" } ?? "Off"
        var out = [Choice(title: "Use Preferences (\(pref))", setting: nil),
                   Choice(title: "Off for This Project", setting: ProjectLiveDucking(isOn: false))]
        var amounts = LiveDucking.amountChoices
        if let c = current, c.isOn, !amounts.contains(c.amountDB) { amounts = (amounts + [c.amountDB]).sorted() }
        for db in amounts { out.append(Choice(title: "Duck Music by \(format(db)) dB", setting: ProjectLiveDucking(isOn: true, amountDB: db))) }
        return out
    }

    /// Index of `current` in `choices` (an "off" setting matches Off whatever amount it keeps).
    public static func index(of current: ProjectLiveDucking?, in choices: [Choice]) -> Int {
        guard let current else { return 0 }
        if !current.isOn { return 1 }
        return choices.firstIndex { $0.setting?.isOn == true && $0.setting?.amountDB == current.amountDB } ?? 0
    }

    public static func format(_ db: Double) -> String { db == db.rounded() ? String(Int(db)) : String(format: "%.1f", db) }
}

/// Timing presets of the live duck, shared by Preferences and "Live Ducking for This Project…" (one system, two places).
public enum DuckTimingChoices {
    public struct Preset: Equatable, Sendable {
        public var title: String
        public var timing: DuckTiming
    }

    public static let presets: [Preset] = [
        Preset(title: "Classic (300 ms fades)", timing: .classic),
        Preset(title: "Ducker (15 / 10 / 150 / 750 ms)", timing: .resolve),
        Preset(title: "Speech (bridges breaths)", timing: .speech),
    ]
    /// Shown when the five values match no preset.
    public static let customTitle = "Custom"

    /// Popup titles: the presets, then Custom.
    public static var titles: [String] { presets.map(\.title) + [customTitle] }

    /// Popup index of `timing`: a preset, or `presets.count` (Custom).
    public static func index(of timing: DuckTiming) -> Int { presets.firstIndex { $0.timing == timing.clamped } ?? presets.count }
}

