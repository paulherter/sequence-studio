#if canImport(AppKit)
import AppKit
#endif
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

#if canImport(AppKit)
/// The five timing fields of the live duck (lookahead, attack, hold, recovery, minimum pause) behind a preset popup. One view
/// for Preferences and the project dialog; `timing` reads the fields, `onChange` fires when the user edits.
@MainActor
public final class DuckTimingForm {
    public let preset = SQPopup(frame: .zero, pullsDown: false)
    private let fields: [ScrubField]
    public var onChange: ((DuckTiming) -> Void)?

    public init(timing: DuckTiming) {
        func f(_ max: Double) -> ScrubField { SQDialog.makeNumberField(range: 0...max, step: 5, unit: "ms", defaultValue: 0, width: nil) }
        fields = [f(500), f(2000), f(2000), f(5000), f(2000)]
        preset.addItems(withTitles: DuckTimingChoices.titles)
        preset.target = self; preset.action = #selector(presetPicked)
        for field in fields { field.onEnd = { [weak self] _ in self?.fieldEdited() } }
        set(timing)
    }

    public var timing: DuckTiming {
        get { DuckTiming(lookaheadMs: fields[0].value, attackMs: fields[1].value, holdMs: fields[2].value,
                         recoveryMs: fields[3].value, minPauseMs: fields[4].value).clamped }
        set { set(newValue) }
    }

    public var isEnabled: Bool {
        get { preset.isEnabled }
        set { preset.isEnabled = newValue; for f in fields { f.isEnabled = newValue } }
    }

    private func set(_ t: DuckTiming) {
        let t = t.clamped
        let v = [t.lookaheadMs, t.attackMs, t.holdMs, t.recoveryMs, t.minPauseMs]
        for (f, x) in zip(fields, v) { f.value = x }
        preset.selectItem(at: DuckTimingChoices.index(of: t))
    }

    @objc private func presetPicked() {
        let i = preset.indexOfSelectedItem
        if DuckTimingChoices.presets.indices.contains(i) { set(DuckTimingChoices.presets[i].timing) }
        onChange?(timing)
    }

    private func fieldEdited() {
        preset.selectItem(at: DuckTimingChoices.index(of: timing))
        onChange?(timing)
    }

    /// The five fields with their titles, in order.
    public var titledFields: [(title: String, field: NSView)] {
        [("Lookahead", fields[0]), ("Attack", fields[1]), ("Hold", fields[2]), ("Recovery", fields[3]), ("Minimum pause", fields[4])]
    }

    /// Dialog rows: preset popup, then one labeled field each.
    public var dialogRows: [NSView] {
        [SQDialog.popupRow(preset),
         SQDialog.formRow("Lookahead", fields[0]), SQDialog.formRow("Attack", fields[1]), SQDialog.formRow("Hold", fields[2]),
         SQDialog.formRow("Recovery", fields[3]), SQDialog.formRow("Minimum pause", fields[4])]
    }
}
#endif
