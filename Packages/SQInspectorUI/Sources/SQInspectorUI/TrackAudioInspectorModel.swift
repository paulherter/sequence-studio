import Foundation
import Observation
import SQAudioFX
import SQCore

/// Crossover limits shared by the inspector model and the bands view.
public enum CrossoverRules {
    public static let minHz: Double = 20
    public static let maxHz: Double = 20_000
    /// Minimum distance between neighboring crossovers as a frequency ratio (about 1/4 octave).
    public static let minRatio: Double = 1.2

    /// Clamps crossover `index` of `current` (3 ascending values) to `hz`, keeping order and spacing.
    public static func clamp(_ hz: Double, index: Int, in current: [Double]) -> Double {
        let lower = index > 0 ? current[index - 1] * minRatio : minHz
        let upper = index < current.count - 1 ? current[index + 1] / minRatio : maxHz
        return min(max(hz, lower), max(lower, upper))
    }
}

public enum BandLimits {
    public static let thresholdDB: ClosedRange<Double> = -60...0
    public static let ratio: ClosedRange<Double> = 1...20
    public static let attackMs: ClosedRange<Double> = 0.5...500
    public static let releaseMs: ClosedRange<Double> = 5...2000
    public static let gainDB: ClosedRange<Double> = -24...24
    public static let overallGainDB: ClosedRange<Double> = -24...24
}

private func clamped(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }

/// State behind the track audio inspector (preset popup, noise reduction, 4-band compressor).
/// Every mutation reports `onChange`; changes are bracketed by `onBeginChange` / `onEndChange`
/// so the host can open and close one undo group per gesture. Discrete edits bracket themselves;
/// slider drags call `beginChange()` / `endChange()` around the gesture (nesting is counted).
@MainActor @Observable
public final class TrackAudioInspectorModel {
    public private(set) var library: PresetLibrary
    /// Preset the current values were loaded from; nil after deleting it or for unsaved custom values.
    public private(set) var selectedPresetID: String?
    public private(set) var compressor: MultibandCompressorSettings
    /// Denoiser wet/dry mix 0...1.
    public private(set) var noiseReduction: Double
    public private(set) var gate: NoiseGateSettings
    public private(set) var saturation: SaturationSettings
    /// Track role (Dialogue / Music / SFX); picking one loads its voiced preset.
    public private(set) var role: AudioTag?

    @ObservationIgnored public var onBeginChange: (() -> Void)?
    @ObservationIgnored public var onEndChange: (() -> Void)?
    /// Called after every effective change with the resulting values.
    @ObservationIgnored public var onChange: ((TrackAudioPreset) -> Void)?
    /// Called when the user picks a role (inside one change bracket). The host saves it and drops any explicit preset.
    @ObservationIgnored public var onRoleChange: ((AudioTag?) -> Void)?
    @ObservationIgnored private var depth = 0

    /// Without an explicit `preset`, a `role` starts on its voiced preset.
    public init(library: PresetLibrary = PresetLibrary(), preset: TrackAudioPreset? = nil, role: AudioTag? = nil) {
        let preset = preset ?? role.map(TrackAudioPreset.forRole) ?? .off
        self.library = library
        self.role = role
        selectedPresetID = preset.id
        compressor = preset.compressor
        noiseReduction = preset.noiseReduction
        gate = preset.gate
        saturation = preset.saturation
    }

    // MARK: Derived

    /// Library presets, plus the current role's voiced preset.
    public var presets: [TrackAudioPreset] { library.all + (role.map { [TrackAudioPreset.forRole($0)] } ?? []) }
    /// Role popup titles: "None" then every role.
    public static let roleTitles = ["None"] + AudioTag.allCases.map(\.title)
    public var noiseReductionPercent: Double { (noiseReduction * 100).rounded() }
    public var selectedPreset: TrackAudioPreset? { selectedPresetID.flatMap { library.preset(id: $0) } }
    public var isModified: Bool {
        guard let p = selectedPreset else { return true }
        return p.compressor != compressor || p.noiseReduction != noiseReduction
            || p.gate != gate || p.saturation != saturation
    }
    public var canEditSelectedPreset: Bool { selectedPreset.map { !$0.isBuiltIn } ?? false }
    /// Current values as an anonymous preset (what the engine should apply).
    public var currentValues: TrackAudioPreset {
        TrackAudioPreset(id: selectedPresetID ?? "custom", name: selectedPreset?.name ?? "Custom",
                         compressor: compressor, noiseReduction: noiseReduction,
                         gate: gate, saturation: saturation)
    }

    // MARK: Change bracketing

    public func beginChange() {
        if depth == 0 { onBeginChange?() }
        depth += 1
    }

    public func endChange() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { onEndChange?() }
    }

    private func edit(_ body: () -> Void) {
        let oldC = compressor, oldN = noiseReduction, oldG = gate, oldS = saturation
        beginChange()
        body()
        if compressor != oldC || noiseReduction != oldN || gate != oldG || saturation != oldS { onChange?(currentValues) }
        endChange()
    }

    // MARK: Presets

    public func selectPreset(id: String) {
        guard let p = library.preset(id: id) else { return }
        edit {
            selectedPresetID = p.id
            compressor = p.compressor
            noiseReduction = p.noiseReduction
            gate = p.gate
            saturation = p.saturation
        }
        // Selecting the same preset with modified values resets them; selecting it unchanged is a no-op.
    }

    /// Sets the track role and shows its voiced preset (nil: back to Off). One change bracket; same role is a no-op.
    /// Reports only `onRoleChange`, never `onChange`: the role is the single source of truth and the engine resolves
    /// role -> preset itself, so the role preset is never stored as an explicit preset (undo of the role stays exact).
    public func setRole(_ newRole: AudioTag?) {
        guard newRole != role else { return }
        beginChange()
        load(role: newRole)
        onRoleChange?(newRole)
        endChange()
    }

    /// Follows a role changed elsewhere (undo/redo, another view): shows its preset, no callbacks.
    public func syncRole(_ newRole: AudioTag?) {
        guard newRole != role else { return }
        load(role: newRole)
    }

    private func load(role newRole: AudioTag?) {
        let p = newRole.map(TrackAudioPreset.forRole) ?? .off
        role = newRole
        selectedPresetID = p.id
        compressor = p.compressor
        noiseReduction = p.noiseReduction
        gate = p.gate
        saturation = p.saturation
    }

    /// Saves the current values as a new user preset and selects it.
    public func saveAsUserPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        beginChange()
        let saved = library.saveUser(TrackAudioPreset(id: "", name: trimmed, compressor: compressor,
                                                      noiseReduction: noiseReduction,
                                                      gate: gate, saturation: saturation))
        selectedPresetID = saved.id
        onChange?(currentValues)
        endChange()
    }

    public func renameSelectedPreset(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canEditSelectedPreset, !trimmed.isEmpty, let id = selectedPresetID else { return }
        beginChange()
        library.rename(id, to: trimmed)
        endChange()
    }

    /// Deletes the selected user preset; the values stay as custom.
    public func deleteSelectedPreset() {
        guard canEditSelectedPreset, let id = selectedPresetID else { return }
        beginChange()
        library.remove(id)
        selectedPresetID = nil
        endChange()
    }

    // MARK: Values

    public func setNoiseReductionPercent(_ percent: Double) {
        let v = clamped(percent, 0...100).rounded() / 100
        edit { noiseReduction = v }
    }

    public func setBypass(_ bypass: Bool) { edit { compressor.bypass = bypass } }

    public func setCrossover(_ index: Int, hz: Double) {
        guard compressor.crossoversHz.indices.contains(index) else { return }
        let v = CrossoverRules.clamp(hz, index: index, in: compressor.crossoversHz)
        edit { compressor.crossoversHz[index] = v }
    }

    /// Edits one band; all fields are clamped to `BandLimits` afterwards.
    public func setBand(_ index: Int, _ body: (inout MultibandCompressorSettings.Band) -> Void) {
        guard compressor.bands.indices.contains(index) else { return }
        var b = compressor.bands[index]
        body(&b)
        b.thresholdDB = clamped(b.thresholdDB, BandLimits.thresholdDB)
        b.ratio = clamped(b.ratio, BandLimits.ratio)
        b.attackMs = clamped(b.attackMs, BandLimits.attackMs)
        b.releaseMs = clamped(b.releaseMs, BandLimits.releaseMs)
        b.gainDB = clamped(b.gainDB, BandLimits.gainDB)
        edit { compressor.bands[index] = b }
    }

    public func setPreGainDB(_ db: Double) {
        let v = clamped(db, BandLimits.overallGainDB)
        edit { compressor.preGainDB = v }
    }

    public func setMakeupGainDB(_ db: Double) {
        let v = clamped(db, BandLimits.overallGainDB)
        edit { compressor.makeupGainDB = v }
    }

    // MARK: Noise gate and warmth

    public func setGateEnabled(_ on: Bool) { edit { gate.enabled = on } }

    public func setGateThresholdDB(_ db: Double) {
        let v = clamped(db, NoiseGateSettings.Limits.thresholdDB)
        edit { gate.thresholdDB = v }
    }

    public func setGateReductionDB(_ db: Double) {
        let v = clamped(db, NoiseGateSettings.Limits.reductionDB)
        edit { gate.reductionDB = v }
    }

    public func setGateAttackMs(_ ms: Double) {
        let v = clamped(ms, NoiseGateSettings.Limits.attackMs)
        edit { gate.attackMs = v }
    }

    public func setGateHoldMs(_ ms: Double) {
        let v = clamped(ms, NoiseGateSettings.Limits.holdMs)
        edit { gate.holdMs = v }
    }

    public func setGateReleaseMs(_ ms: Double) {
        let v = clamped(ms, NoiseGateSettings.Limits.releaseMs)
        edit { gate.releaseMs = v }
    }

    public func setWarmthEnabled(_ on: Bool) { edit { saturation.enabled = on } }

    public func setWarmthDriveDB(_ db: Double) {
        let v = clamped(db, SaturationSettings.Limits.driveDB)
        edit { saturation.driveDB = v }
    }

    public func setWarmthMixPercent(_ percent: Double) {
        let v = clamped(percent, 0...100).rounded() / 100
        edit { saturation.mix = v }
    }
}
