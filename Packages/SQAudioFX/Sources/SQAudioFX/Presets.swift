import Foundation

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

    public init(id: String, name: String, isBuiltIn: Bool = false, compressor: MultibandCompressorSettings, noiseReduction: Double = 0.5) {
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
