import Foundation
import AudioToolbox

/// AUMultibandCompressor parameter IDs (AudioUnitParameters.h), as plain constants.
enum AUParam {
    static let pregain = UInt32(kMultibandCompressorParam_Pregain), postgain = UInt32(kMultibandCompressorParam_Postgain)
    static let crossover1 = UInt32(kMultibandCompressorParam_Crossover1)
    static let crossover2 = UInt32(kMultibandCompressorParam_Crossover2)
    static let crossover3 = UInt32(kMultibandCompressorParam_Crossover3)
    static let threshold1 = UInt32(kMultibandCompressorParam_Threshold1), threshold2 = threshold1 + 1
    static let threshold3 = threshold1 + 2, threshold4 = threshold1 + 3
    static let headroom1 = UInt32(kMultibandCompressorParam_Headroom1), headroom2 = headroom1 + 1
    static let headroom3 = headroom1 + 2, headroom4 = headroom1 + 3
    static let attackTime = UInt32(kMultibandCompressorParam_AttackTime)
    static let releaseTime = UInt32(kMultibandCompressorParam_ReleaseTime)
    static let eq1 = UInt32(kMultibandCompressorParam_EQ1), eq2 = eq1 + 1, eq3 = eq1 + 2, eq4 = eq1 + 3
}

/// Four-band compressor. Maps onto Apple's AUMultibandCompressor (see `auParameters()`).
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

    /// Reference range used to turn a ratio into the AU's "headroom" (dB). Approximation, see PHASE5.md.
    static let headroomReferenceDB = 24.0

    /// (parameterID, value) pairs for AUMultibandCompressor. Pure data; values clamped to the AU's ranges.
    public func auParameters(sampleRate: Double = 48000) -> [(id: UInt32, value: Double)] {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v.isNaN ? lo : v)) }
        let b = bands.count == 4 ? bands : MultibandCompressorSettings.neutral.bands
        let nyq = sampleRate / 2
        var x = crossoversHz.count == 3 ? crossoversHz : MultibandCompressorSettings.neutral.crossoversHz
        x = x.map { clamp($0, 20, nyq) }
        // keep strictly ascending
        for i in 1..<3 where x[i] <= x[i - 1] { x[i] = min(nyq, x[i - 1] * 1.05) }
        var out: [(id: UInt32, value: Double)] = [
            (AUParam.pregain, clamp(preGainDB, -40, 40)),
            (AUParam.postgain, clamp(makeupGainDB, -40, 40)),
            (AUParam.crossover1, x[0]), (AUParam.crossover2, x[1]), (AUParam.crossover3, x[2]),
        ]
        for i in 0..<4 {
            out.append((AUParam.threshold1 + UInt32(i), clamp(b[i].thresholdDB, -100, 0)))
        }
        for i in 0..<4 {
            let r = max(1, b[i].ratio)
            out.append((AUParam.headroom1 + UInt32(i), clamp(Self.headroomReferenceDB * (1 - 1 / r), 0.1, 40)))
        }
        let attack = b.map(\.attackMs).reduce(0, +) / 4 / 1000
        let release = b.map(\.releaseMs).reduce(0, +) / 4 / 1000
        out.append((AUParam.attackTime, clamp(attack, 0.001, 0.2)))
        out.append((AUParam.releaseTime, clamp(release, 0.01, 3)))
        for i in 0..<4 { out.append((AUParam.eq1 + UInt32(i), clamp(b[i].gainDB, -20, 20))) }
        return out
    }
}

public struct TrackAudioPreset: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    public var compressor: MultibandCompressorSettings
    /// 0 = off ... 1 = full RNNoise output.
    public var noiseReduction: Double

    public init(id: String, name: String, isBuiltIn: Bool = false, compressor: MultibandCompressorSettings, noiseReduction: Double) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn
        self.compressor = compressor; self.noiseReduction = min(1, max(0, noiseReduction))
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

    public func preset(id: String) -> TrackAudioPreset? { all.first { $0.id == id } }

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
