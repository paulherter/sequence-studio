import Foundation
import SQCore

/// Four-band compressor settings (Premiere-style Multiband Compressor), run by `MultibandCompressor`.
public struct MultibandCompressorSettings: Sendable, Hashable, Codable {
    public struct Band: Sendable, Hashable, Codable {
        public var thresholdDB: Double
        public var ratio: Double
        public var attackMs: Double
        public var releaseMs: Double
        public var gainDB: Double
        public init(thresholdDB: Double, ratio: Double, attackMs: Double, releaseMs: Double, gainDB: Double = 0) {
            self.thresholdDB = thresholdDB; self.ratio = ratio
            self.attackMs = attackMs; self.releaseMs = releaseMs; self.gainDB = gainDB
        }
    }

    public var bypass: Bool
    /// Exactly 3 crossover frequencies in Hz, ascending.
    public var crossoversHz: [Double]
    /// Exactly 4 bands, low to high.
    public var bands: [Band]
    public var preGainDB: Double
    public var makeupGainDB: Double

    public init(bypass: Bool = false, crossoversHz: [Double], bands: [Band], preGainDB: Double = 0, makeupGainDB: Double = 0) {
        self.bypass = bypass; self.crossoversHz = crossoversHz; self.bands = bands
        self.preGainDB = preGainDB; self.makeupGainDB = makeupGainDB
    }

    /// Transparent: ratio 1, no gain, bypassed.
    public static let neutral = MultibandCompressorSettings(
        bypass: true, crossoversHz: [120, 700, 3000],
        bands: Array(repeating: Band(thresholdDB: 0, ratio: 1, attackMs: 10, releaseMs: 100), count: 4))
}

public struct TrackAudioPreset: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public var compressor: MultibandCompressorSettings
    /// Denoiser strength = wet/dry mix: 0 = denoiser off, 1 = fully denoised. Default 0.5.
    public var noiseReduction: Double
    /// Noise gate, runs after the denoiser and before the compressor. Off by default.
    public var gate: NoiseGateSettings
    /// Saturation ("warmth"), runs after the de-esser. Off by default.
    public var saturation: SaturationSettings
    /// Split-band de-esser after the compressor (the Voice role turns it on). Optional on decode: older presets have none.
    public var deEss: Bool

    public init(id: String, name: String, isBuiltIn: Bool = false, compressor: MultibandCompressorSettings, noiseReduction: Double = 0.5,
                deEss: Bool = false, gate: NoiseGateSettings = .off, saturation: SaturationSettings = .off) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn
        self.compressor = compressor; self.noiseReduction = min(1, max(0, noiseReduction)); self.deEss = deEss
        self.gate = gate; self.saturation = saturation
    }

    private enum CodingKeys: String, CodingKey { case id, name, isBuiltIn, compressor, noiseReduction, deEss, gate, saturation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        compressor = try c.decode(MultibandCompressorSettings.self, forKey: .compressor)
        noiseReduction = try c.decode(Double.self, forKey: .noiseReduction)
        deEss = try c.decodeIfPresent(Bool.self, forKey: .deEss) ?? false
        gate = try c.decodeIfPresent(NoiseGateSettings.self, forKey: .gate) ?? .off
        saturation = try c.decodeIfPresent(SaturationSettings.self, forKey: .saturation) ?? .off
    }

    public static let off = TrackAudioPreset(id: "builtin.off", name: "Off", isBuiltIn: true,
                                             compressor: .neutral, noiseReduction: 0)

    public static let voice = TrackAudioPreset(
        id: "builtin.voice", name: "Voice", isBuiltIn: true,
        compressor: MultibandCompressorSettings(
            crossoversHz: [120, 900, 4500],
            bands: [
                .init(thresholdDB: -30, ratio: 2.5, attackMs: 15, releaseMs: 150, gainDB: -3),
                .init(thresholdDB: -26, ratio: 3, attackMs: 8, releaseMs: 120, gainDB: 1),
                .init(thresholdDB: -28, ratio: 3, attackMs: 5, releaseMs: 100, gainDB: 2),
                .init(thresholdDB: -32, ratio: 2, attackMs: 3, releaseMs: 80, gainDB: 0),
            ],
            makeupGainDB: 3),
        noiseReduction: 0.8)

    public static let music = TrackAudioPreset(
        id: "builtin.music", name: "Music", isBuiltIn: true,
        compressor: MultibandCompressorSettings(
            crossoversHz: [150, 1000, 6000],
            bands: [
                .init(thresholdDB: -20, ratio: 1.8, attackMs: 30, releaseMs: 250),
                .init(thresholdDB: -22, ratio: 1.6, attackMs: 20, releaseMs: 200),
                .init(thresholdDB: -24, ratio: 1.6, attackMs: 10, releaseMs: 150),
                .init(thresholdDB: -26, ratio: 1.4, attackMs: 5, releaseMs: 120),
            ],
            makeupGainDB: 1.5),
        noiseReduction: 0)

    public static let builtIns: [TrackAudioPreset] = [off, voice, music]
}

public struct PresetLibrary: Sendable, Hashable, Codable {
    public private(set) var userPresets: [TrackAudioPreset] = []
    public init() {}

    public var all: [TrackAudioPreset] { TrackAudioPreset.builtIns + userPresets }

    /// Also finds the role presets (`TrackAudioPreset.forRole`), which are picked by role, not listed in `all`.
    public func preset(id: String) -> TrackAudioPreset? { all.first { $0.id == id } ?? TrackAudioPreset.rolePresets.first { $0.id == id } }

    /// Stores a copy as a user preset with a fresh id and returns it.
    @discardableResult
    public mutating func saveUser(_ preset: TrackAudioPreset) -> TrackAudioPreset {
        var p = preset
        p.id = "user." + UUID().uuidString
        p.isBuiltIn = false
        userPresets.append(p)
        return p
    }

    public mutating func rename(_ id: String, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[i].name = name
    }

    public mutating func remove(_ id: String) { userPresets.removeAll { $0.id == id } }
}

/// The voicing of one track role (Dialogue / Music / SFX): a 4-band EQ at the compressor's crossovers, the compressor's dynamics,
/// a level offset and the denoiser amount. Values tuned by ear for social and YouTube delivery (Premiere's Essential Sound as the
/// reference): dialogue clear with presence, music scooped where speech lives, SFX untouched in tone.
///
/// Level: all offsets and makeup gains are 0 dB (review W4.5). Clip Match Loudness already places each clip at its tag's
/// target (`AudioTag.targetLUFS`: dialogue -14, music/SFX -20 LUFS), so a role offset would stack on top of it, and makeup
/// would push matched dialogue above -14. The voicing therefore only shapes tone and dynamics; `levelDB` stays as a knob
/// (the maintainer can set e.g. music -6 for unmatched material).
///
/// The multiband compressor carries all of it, so the voicing runs in the one existing FX path (playback and export):
/// EQ = per-band gain, level offset = added to the makeup gain.
public struct RoleVoicing: Sendable, Hashable {
    public struct Dynamics: Sendable, Hashable {
        public var thresholdDB: Double, ratio: Double, attackMs: Double, releaseMs: Double
    }
    public var role: AudioTag
    public var crossoversHz: [Double]
    /// Band gains low to high in dB (the EQ).
    public var eqDB: [Double]
    public var bands: [Dynamics]
    public var makeupGainDB: Double
    /// Role level relative to dialogue, in dB.
    public var levelDB: Double
    public var noiseReduction: Double

    public static func forRole(_ role: AudioTag) -> RoleVoicing {
        switch role {
        case .dialogue:
            RoleVoicing(role: role, crossoversHz: [120, 900, 4500], eqDB: [-6, 0, 3, 1],
                        bands: [.init(thresholdDB: -30, ratio: 2, attackMs: 15, releaseMs: 150),
                                .init(thresholdDB: -24, ratio: 3, attackMs: 8, releaseMs: 120),
                                .init(thresholdDB: -26, ratio: 3, attackMs: 5, releaseMs: 100),
                                .init(thresholdDB: -30, ratio: 2, attackMs: 3, releaseMs: 80)],
                        makeupGainDB: 0, levelDB: 0, noiseReduction: 0.6)
        case .music:
            RoleVoicing(role: role, crossoversHz: [150, 1000, 5000], eqDB: [0, -2, -3, 0],
                        bands: [.init(thresholdDB: -18, ratio: 1.5, attackMs: 30, releaseMs: 250),
                                .init(thresholdDB: -20, ratio: 1.4, attackMs: 20, releaseMs: 200),
                                .init(thresholdDB: -22, ratio: 1.4, attackMs: 10, releaseMs: 150),
                                .init(thresholdDB: -24, ratio: 1.3, attackMs: 5, releaseMs: 120)],
                        makeupGainDB: 0, levelDB: 0, noiseReduction: 0)
        case .sfx:
            RoleVoicing(role: role, crossoversHz: [120, 1000, 6000], eqDB: [0, 0, 0, 0],
                        bands: [.init(thresholdDB: -14, ratio: 2, attackMs: 20, releaseMs: 150),
                                .init(thresholdDB: -14, ratio: 2, attackMs: 15, releaseMs: 120),
                                .init(thresholdDB: -14, ratio: 2, attackMs: 10, releaseMs: 100),
                                .init(thresholdDB: -14, ratio: 2, attackMs: 10, releaseMs: 80)],
                        makeupGainDB: 0, levelDB: 0, noiseReduction: 0)
        }
    }

    /// The voicing as a track preset for the FX chain.
    public var preset: TrackAudioPreset {
        let b = zip(bands, eqDB).map { d, g in
            MultibandCompressorSettings.Band(thresholdDB: d.thresholdDB, ratio: d.ratio, attackMs: d.attackMs,
                                             releaseMs: d.releaseMs, gainDB: g)
        }
        return TrackAudioPreset(id: "builtin.role." + role.rawValue, name: role.title, isBuiltIn: true,
                                compressor: MultibandCompressorSettings(crossoversHz: crossoversHz, bands: b,
                                                                        makeupGainDB: makeupGainDB + levelDB),
                                noiseReduction: noiseReduction, deEss: role == .dialogue)
    }
}

extension TrackAudioPreset {
    /// The voiced preset of a track role.
    public static func forRole(_ role: AudioTag) -> TrackAudioPreset { RoleVoicing.forRole(role).preset }
    public static let rolePresets: [TrackAudioPreset] = AudioTag.allCases.map(forRole)
}
