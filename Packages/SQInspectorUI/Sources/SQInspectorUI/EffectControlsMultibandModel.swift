import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQAudioFX
import SQCore
import SQDrawKit

/// Multiband Compressor custom setup: a row under the effect header opens a popup editor with preset menu, link toggle,
/// output gain, a band display (draggable crossovers, live band input level and gain reduction), crossover frequencies,
/// per-band Solo / Bypass, four band columns (threshold, ratio, attack, release, gain) and the output limiter (Brickwall
/// on/off, threshold, margin, attack, release, live reduction). Everything maps to the effect's real parameters
/// (`ClipEffect.mb*Key`); the generic rows below keep the keyframe controls. The band display draws the live spectrum of
/// the effect's output, or its input with "Spectrum at Input" (`AudioSpectrumTap`, real engine feed).
/// This file is the portable part (presets, meter display, model calls) shared by the Mac window
/// (`EffectControlsMultiband.swift`) and the shared-toolkit editor (`Draw/MultibandEditorDraw.swift`).
public enum MultibandEditor {
    public static let bandCount = 4
    public static let rowHeight: CGFloat = ControlsMetrics.multibandRow

    /// The band settings rows (caption, parameter key of band n) and the limiter rows, top to bottom / left to right.
    static let bandRows: [(title: String, key: @Sendable (Int) -> String)] = [
        ("Threshold (dB)", ClipEffect.mbThresholdKey), ("Gain (dB)", ClipEffect.mbGainKey), ("Ratio (:1)", ClipEffect.mbRatioKey),
        ("Attack (ms)", ClipEffect.mbAttackKey), ("Release (ms)", ClipEffect.mbReleaseKey)]
    static let limiterRows: [(title: String, key: String)] = [
        ("Threshold (dB)", ClipEffect.mbLimiterThresholdKey), ("Margin (dB)", ClipEffect.mbLimiterMarginKey),
        ("Attack (ms)", ClipEffect.mbLimiterAttackKey), ("Release (ms)", ClipEffect.mbLimiterReleaseKey)]

    /// A band's range label ("20 - 137 Hz"): frequencies above 1 kHz in kHz with one decimal.
    static func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: "%.0f", v) }
    static func rangeText(band n: Int, crossovers xs: [Double]) -> String {
        let lo = n == 0 ? 20 : xs[n - 1], hi = n == bandCount - 1 ? 20_000 : xs[n]
        return "\(hz(lo)) - \(hz(hi)) Hz"
    }

    public struct Preset: Sendable, Equatable {
        public var name: String
        public var values: [String: Double]
    }

    /// Values of one preset as effect parameters.
    static func values(crossovers: [Double], bands: [MultibandCompressorSettings.Band], outputGainDB: Double) -> [String: Double] {
        var v: [String: Double] = [ClipEffect.mbOutputGainKey: outputGainDB]
        for (i, hz) in crossovers.enumerated() { v[ClipEffect.mbCrossoverKey(i + 1)] = hz }
        for (i, b) in bands.enumerated() {
            let n = i + 1
            v[ClipEffect.mbThresholdKey(n)] = b.thresholdDB; v[ClipEffect.mbRatioKey(n)] = b.ratio
            v[ClipEffect.mbAttackKey(n)] = b.attackMs; v[ClipEffect.mbReleaseKey(n)] = b.releaseMs; v[ClipEffect.mbGainKey(n)] = b.gainDB
        }
        return v
    }

    /// The maintainer's Broadcast setup: bands plus the limiter (threshold -9, ceiling -0.1, attack 4 ms, release 500 ms, Brickwall on).
    public static let broadcast: [String: Double] = values(
        crossovers: [137, 1147, 6910],
        bands: [.init(thresholdDB: -15, ratio: 3, attackMs: 1, releaseMs: 100, gainDB: 4),
                .init(thresholdDB: -11, ratio: 2, attackMs: 1, releaseMs: 100, gainDB: -2),
                .init(thresholdDB: -17, ratio: 2, attackMs: 1, releaseMs: 100, gainDB: -4),
                .init(thresholdDB: -15, ratio: 3, attackMs: 1, releaseMs: 100, gainDB: -2)],
        outputGainDB: 0).merging([
            ClipEffect.mbLimiterOnKey: 1, ClipEffect.mbLimiterThresholdKey: -9, ClipEffect.mbLimiterMarginKey: -0.1,
            ClipEffect.mbLimiterAttackKey: 4, ClipEffect.mbLimiterReleaseKey: 500]) { $1 }

    /// Solo and link are listening / editing aids, not part of a sound: presets neither set nor compare them.
    static let presetExcludedKeys: Set<String> = Set((1...4).map(ClipEffect.mbSoloKey) + [ClipEffect.mbLinkKey])

    /// "Default" (catalog defaults), "Broadcast", and the three role voicings of the engine, clamped to the ranges.
    /// Every preset is complete (all sound keys, limiter and bypass included), so loading one never leaves the last one's
    /// limiter or bypass behind.
    public static let presets: [Preset] = {
        guard let spec = EffectCatalog.spec(for: ClipEffect.audioMultibandKind) else { return [] }
        let defaults = Dictionary(uniqueKeysWithValues: spec.params.filter { !presetExcludedKeys.contains($0.key) }.map { ($0.key, $0.defaultValue) })
        func complete(_ v: [String: Double]) -> [String: Double] {
            var out = defaults.merging(v) { $1 }
            for p in spec.params { if let x = out[p.key] { out[p.key] = min(max(x, p.range.lowerBound), p.range.upperBound) } }
            return out.filter { defaults[$0.key] != nil }
        }
        var out = [Preset(name: "Default", values: defaults), Preset(name: "Broadcast", values: complete(broadcast))]
        for role in AudioTag.allCases {
            let r = RoleVoicing.forRole(role)
            let bands = zip(r.bands, r.eqDB).map {
                MultibandCompressorSettings.Band(thresholdDB: $0.thresholdDB, ratio: $0.ratio, attackMs: $0.attackMs,
                                                 releaseMs: $0.releaseMs, gainDB: $1)
            }
            out.append(Preset(name: role.title, values: complete(values(crossovers: r.crossoversHz, bands: bands, outputGainDB: r.makeupGainDB + r.levelDB))))
        }
        return out
    }()

    /// Index of the preset whose values equal `current` (within display precision), nil for custom values.
    public static func matchingPreset(_ current: [String: Double]) -> Int? {
        presets.firstIndex { p in p.values.allSatisfy { k, v in abs((current[k] ?? .nan) - v) < 0.05 } }
    }

    /// Every parameter of the effect (snapshot keys).
    static let allKeys: [String] = EffectCatalog.spec(for: ClipEffect.audioMultibandKind)?.params.map(\.key) ?? []

    static func spec(_ key: String) -> EffectParamSpec? {
        EffectCatalog.spec(for: ClipEffect.audioMultibandKind)?.params.first { $0.key == key }
    }

}

/// What the popup's meters show, from successive `MultibandMeterReading`s (pure, testable). A new sequence feeds the
/// bars (input level with the meter ballistics, reduction as read); the same sequence again means no new audio: the
/// input bars fall. Nothing new for `staleSeconds` (stopped, or the playhead left the clip): no reading is shown.
public struct MultibandMeterDisplay: Sendable, Equatable {
    public static let staleSeconds = 0.3
    private var bands = [MeterBallistics](repeating: MeterBallistics(), count: MultibandEditor.bandCount)
    public private(set) var gainReductionDB: [Float] = [0, 0, 0, 0]
    public private(set) var limiterReductionDB: Float = 0
    public private(set) var isLive = false
    private var lastSequence: UInt64 = 0
    private var lastNewAt = -Double.infinity

    public init() {}

    public var inputDB: [Float] { bands.map(\.levelDB) }

    public mutating func update(_ r: MultibandMeterReading?, at time: Double) {
        if let r, r.sequence != 0, r.sequence != lastSequence {
            lastSequence = r.sequence; lastNewAt = time; isLive = true
            for i in bands.indices { bands[i].update(peak: r.inputPeak[i], at: time) }
            gainReductionDB = (0..<4).map { max(0, r.gainReductionDB[$0]) }
            limiterReductionDB = max(0, r.limiterReductionDB)
            return
        }
        if time - lastNewAt > Self.staleSeconds {
            guard isLive || bands.contains(where: { !$0.isSettled }) else { return }
            isLive = false
            for i in bands.indices { bands[i].silence() }
            gainReductionDB = [0, 0, 0, 0]; limiterReductionDB = 0
        } else {
            for i in bands.indices { bands[i].update(peak: 0, at: time) }
        }
    }
}

extension EffectControlsModel {
    private func mbProperty(_ effect: ClipEffect.ID, _ key: String) -> EffectProperty { .fx(effect, kind: ClipEffect.audioMultibandKind, key: key) }

    /// Shown value of one Multiband parameter at the playhead.
    public func multibandValue(_ effect: ClipEffect.ID, _ key: String) -> Double { scalarValue(mbProperty(effect, key)) }
    public func multibandProperty(_ effect: ClipEffect.ID, _ key: String) -> EffectProperty { mbProperty(effect, key) }

    /// All parameter values at the playhead, by key.
    public func multibandSnapshot(_ effect: ClipEffect.ID) -> [String: Double] {
        var v: [String: Double] = [:]
        for k in MultibandEditor.allKeys { v[k] = multibandValue(effect, k) }
        return v
    }

    public func crossovers(_ effect: ClipEffect.ID) -> [Double] { (1...3).map { multibandValue(effect, ClipEffect.mbCrossoverKey($0)) } }

    /// One crossover, kept in order and spaced (`CrossoverRules`).
    public func setCrossover(_ effect: ClipEffect.ID, index: Int, hz: Double) {
        let c = CrossoverRules.clamp(hz, index: index, in: crossovers(effect))
        setValue(mbProperty(effect, ClipEffect.mbCrossoverKey(index + 1)), to: c)
    }

    /// Loads a preset: every parameter in one undo step (animated parameters get a key at the playhead).
    public func applyMultibandPreset(_ effect: ClipEffect.ID, index: Int) {
        guard MultibandEditor.presets.indices.contains(index) else { return }
        let pairs = MultibandEditor.presets[index].values.sorted { $0.key < $1.key }.map { (mbProperty(effect, $0.key), $0.value) }
        setValues(pairs, name: "Multiband Preset")
    }

    // MARK: Solo / Bypass / Link (band is 0-based)

    public func multibandSolo(_ effect: ClipEffect.ID, band: Int) -> Bool { multibandValue(effect, ClipEffect.mbSoloKey(band + 1)) >= 0.5 }
    public func multibandBypass(_ effect: ClipEffect.ID, band: Int) -> Bool { multibandValue(effect, ClipEffect.mbBypassKey(band + 1)) >= 0.5 }
    public func multibandLinked(_ effect: ClipEffect.ID) -> Bool { multibandValue(effect, ClipEffect.mbLinkKey) >= 0.5 }

    public func toggleMultibandSolo(_ effect: ClipEffect.ID, band: Int) {
        let on = multibandSolo(effect, band: band)
        setValues([(mbProperty(effect, ClipEffect.mbSoloKey(band + 1)), on ? 0 : 1)], name: on ? "Unsolo Band \(band + 1)" : "Solo Band \(band + 1)")
    }

    public func toggleMultibandBypass(_ effect: ClipEffect.ID, band: Int) {
        let on = multibandBypass(effect, band: band)
        setValues([(mbProperty(effect, ClipEffect.mbBypassKey(band + 1)), on ? 0 : 1)], name: on ? "Enable Band \(band + 1)" : "Bypass Band \(band + 1)")
    }

    public func setMultibandLink(_ effect: ClipEffect.ID, _ on: Bool) {
        setValues([(mbProperty(effect, ClipEffect.mbLinkKey), on ? 1 : 0)], name: on ? "Link Band Controls" : "Unlink Band Controls")
    }

    /// One band value (threshold, ratio, attack, release or gain). Linked: every band moves by the same delta from its
    /// current value, each clamped to its range, in one commit (so one undo step, or part of the running gesture).
    public func setMultibandBandValue(_ effect: ClipEffect.ID, key: (Int) -> String, band: Int, to v: Double) {
        guard (0..<MultibandEditor.bandCount).contains(band), let s = MultibandEditor.spec(key(band + 1)) else { return }
        func clamp(_ x: Double) -> Double { min(max(x, s.range.lowerBound), s.range.upperBound) }
        let target = clamp(v)
        guard multibandLinked(effect) else { setValue(mbProperty(effect, key(band + 1)), to: target); return }
        let delta = target - multibandValue(effect, key(band + 1))
        let pairs = (1...MultibandEditor.bandCount).map { n in
            (mbProperty(effect, key(n)), n == band + 1 ? target : clamp(multibandValue(effect, key(n)) + delta))
        }
        setValues(pairs, name: "Change \(s.title.replacingOccurrences(of: "Band \(band + 1) ", with: "")) (Linked)")
    }
}
