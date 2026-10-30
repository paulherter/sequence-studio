import Foundation

// AUDIO-FX-PRO (v46): the two voice-chain audio effects beside Noise Reduction: a 4-band Multiband Compressor and a 5-band
// Parametric EQ (HP, low shelf, 5 peaks, high shelf, LP). The older 3-band `audio.eq` stays as it is. Kinds are stored strings.

extension ClipEffect {
    public static let audioMultibandKind = "audio.multiband"
    public static let mbOutputGainKey = "outGain"
    public static func mbCrossoverKey(_ i: Int) -> String { "x\(i)" }          // i in 1...3
    public static func mbThresholdKey(_ i: Int) -> String { "thr\(i)" }        // i in 1...4
    public static func mbRatioKey(_ i: Int) -> String { "ratio\(i)" }
    public static func mbAttackKey(_ i: Int) -> String { "atk\(i)" }
    public static func mbReleaseKey(_ i: Int) -> String { "rel\(i)" }
    public static func mbGainKey(_ i: Int) -> String { "gain\(i)" }
    /// Output limiter (Premiere's Multiband "Limiter"): off by default. On, the signal is raised by margin - threshold and
    /// peak-limited at the margin (threshold -9 / margin -0.1 = +8.9 dB, peaks at -0.1 dBFS).
    public static let mbLimiterOnKey = "limOn"
    public static let mbLimiterThresholdKey = "limThr"
    public static let mbLimiterMarginKey = "limMargin"
    public static let mbLimiterReleaseKey = "limRel"
    /// Limiter attack (ms): 0 = the gain drops at once (the original brickwall); longer = the gain falls with this time
    /// constant and any overshoot left is clipped at the margin (zero latency, the margin always holds).
    public static let mbLimiterAttackKey = "limAtk"
    /// Per band (i in 1...4). Solo: only soloed bands are heard while any is set (also in export: honest, not a monitor
    /// trick). Bypass: the band passes uncompressed and without its band gain (Premiere's B button).
    public static func mbSoloKey(_ i: Int) -> String { "b\(i)solo" }
    public static func mbBypassKey(_ i: Int) -> String { "b\(i)byp" }
    /// "Link band controls" of the custom setup: a UI option stored with the effect (no sound of its own).
    public static let mbLinkKey = "link"
    /// Edited only in the custom setup popup: not shown as parameter rows.
    public static let mbSetupOnlyKeys: Set<String> = Set((1...4).flatMap { [mbSoloKey($0), mbBypassKey($0)] } + [mbLinkKey])

    public static let audioParametricEQKind = "audio.parametricEQ"
    /// Filter ids of the Parametric EQ: "hp", "lp", "ls", "hs", "b1"..."b5". Keys are `<id>On`, `<id>Freq`, `<id>Gain`, `<id>Q`.
    public static let peqFilterIDs = ["hp", "ls", "b1", "b2", "b3", "b4", "b5", "hs", "lp"]
    public static func peqKey(_ id: String, _ field: String) -> String { id + field }       // field: On, Freq, Gain, Q

    /// Kinds that need project format v46 (older builds would drop them).
    public static let voiceChainKinds: Set<String> = [audioMultibandKind, audioParametricEQKind]
}

extension EffectCatalog {
    public static let voiceChainAudio: [EffectSpec] = [multibandSpec, parametricEQSpec]

    static let multibandSpec: EffectSpec = {
        var p = [EffectParamSpec(key: ClipEffect.mbOutputGainKey, title: "Output Gain", unit: "dB", defaultValue: 0, range: -18...18, step: 0.1, decimals: 1)]
        let xs: [Double] = [120, 700, 3_000]
        for i in 1...3 {
            p.append(EffectParamSpec(key: ClipEffect.mbCrossoverKey(i), title: "Crossover \(i)", unit: "Hz", defaultValue: xs[i - 1],
                                     range: 20...20_000, step: 1, decimals: 0))
        }
        for i in 1...4 {
            p.append(EffectParamSpec(key: ClipEffect.mbThresholdKey(i), title: "Band \(i) Threshold", unit: "dB", defaultValue: -20, range: -60...0, step: 0.1, decimals: 1))
            p.append(EffectParamSpec(key: ClipEffect.mbRatioKey(i), title: "Band \(i) Ratio", unit: ":1", defaultValue: 2, range: 1...30, step: 0.1, decimals: 1))
            p.append(EffectParamSpec(key: ClipEffect.mbAttackKey(i), title: "Band \(i) Attack", unit: "ms", defaultValue: 10, range: 0.1...500, step: 0.1, decimals: 1))
            p.append(EffectParamSpec(key: ClipEffect.mbReleaseKey(i), title: "Band \(i) Release", unit: "ms", defaultValue: 100, range: 5...2_000, step: 1, decimals: 0))
            p.append(EffectParamSpec(key: ClipEffect.mbGainKey(i), title: "Band \(i) Gain", unit: "dB", defaultValue: 0, range: -18...18, step: 0.1, decimals: 1))
        }
        p.append(.checkbox(ClipEffect.mbLimiterOnKey, "Limiter", on: false))
        p.append(EffectParamSpec(key: ClipEffect.mbLimiterThresholdKey, title: "Limiter Threshold", unit: "dB", defaultValue: -10, range: -60...0, step: 0.1, decimals: 1))
        p.append(EffectParamSpec(key: ClipEffect.mbLimiterMarginKey, title: "Limiter Margin", unit: "dB", defaultValue: -0.1, range: -18...0, step: 0.1, decimals: 1))
        p.append(EffectParamSpec(key: ClipEffect.mbLimiterAttackKey, title: "Limiter Attack", unit: "ms", defaultValue: 0, range: 0...500, step: 0.1, decimals: 1))
        p.append(EffectParamSpec(key: ClipEffect.mbLimiterReleaseKey, title: "Limiter Release", unit: "ms", defaultValue: 500, range: 5...5_000, step: 1, decimals: 0))
        for i in 1...4 {
            p.append(.checkbox(ClipEffect.mbSoloKey(i), "Band \(i) Solo"))
            p.append(.checkbox(ClipEffect.mbBypassKey(i), "Band \(i) Bypass"))
        }
        p.append(.checkbox(ClipEffect.mbLinkKey, "Link Band Controls"))
        return EffectSpec(kind: ClipEffect.audioMultibandKind, title: "Multiband Compressor", params: p)
    }()

    static let parametricEQSpec: EffectSpec = {
        var p: [EffectParamSpec] = []
        let titles = ["hp": "High-Pass", "lp": "Low-Pass", "ls": "Low Shelf", "hs": "High Shelf",
                      "b1": "Band 1", "b2": "Band 2", "b3": "Band 3", "b4": "Band 4", "b5": "Band 5"]
        let freqs: [String: Double] = ["hp": 80, "ls": 120, "b1": 100, "b2": 400, "b3": 1_500, "b4": 4_000, "b5": 10_000, "hs": 8_000, "lp": 16_000]
        for id in ClipEffect.peqFilterIDs {
            let t = titles[id]!
            let isCut = id == "hp" || id == "lp"
            p.append(.checkbox(ClipEffect.peqKey(id, "On"), "\(t) On", on: !isCut))
            p.append(EffectParamSpec(key: ClipEffect.peqKey(id, "Freq"), title: "\(t) Frequency", unit: "Hz", defaultValue: freqs[id]!,
                                     range: 20...20_000, step: 1, decimals: 0))
            if !isCut {
                p.append(EffectParamSpec(key: ClipEffect.peqKey(id, "Gain"), title: "\(t) Gain", unit: "dB", defaultValue: 0, range: -24...24, step: 0.1, decimals: 1))
                p.append(EffectParamSpec(key: ClipEffect.peqKey(id, "Q"), title: "\(t) Q", unit: "", defaultValue: id == "ls" || id == "hs" ? 0.71 : 1,
                                         range: 0.1...10, step: 0.01, decimals: 2))
            }
        }
        return EffectSpec(kind: ClipEffect.audioParametricEQKind, title: "EQ", params: p)
    }()
}

/// The Multiband Compressor at one instant: three crossovers (ascending, Hz) and four bands low to high.
public struct AudioMultibandValues: Sendable, Hashable {
    public var outputGainDB: Double
    public var crossoverHz: SIMD3<Double>
    public var thresholdDB: SIMD4<Double>
    public var ratio: SIMD4<Double>
    public var attackMs: SIMD4<Double>
    public var releaseMs: SIMD4<Double>
    public var gainDB: SIMD4<Double>
    /// Output limiter after the output gain: raises by `limiterGainDB` and holds the peaks at `limiterMarginDB`.
    public var limiterOn: Bool
    public var limiterThresholdDB: Double
    public var limiterMarginDB: Double
    public var limiterReleaseMs: Double
    /// 0 = instant gain drop (default, the sound before attack existed).
    public var limiterAttackMs: Double
    /// Bit i (0 = lowest band) set: band i + 1 soloed / bypassed.
    public var bandSolo: UInt8
    public var bandBypass: UInt8
    public init(outputGainDB: Double, crossoverHz: SIMD3<Double>, thresholdDB: SIMD4<Double>, ratio: SIMD4<Double>,
                attackMs: SIMD4<Double>, releaseMs: SIMD4<Double>, gainDB: SIMD4<Double>, limiterOn: Bool = false,
                limiterThresholdDB: Double = -10, limiterMarginDB: Double = -0.1, limiterReleaseMs: Double = 500,
                limiterAttackMs: Double = 0, bandSolo: UInt8 = 0, bandBypass: UInt8 = 0) {
        self.outputGainDB = outputGainDB; self.crossoverHz = crossoverHz; self.thresholdDB = thresholdDB; self.ratio = ratio
        self.attackMs = attackMs; self.releaseMs = releaseMs; self.gainDB = gainDB
        self.limiterOn = limiterOn; self.limiterThresholdDB = limiterThresholdDB; self.limiterMarginDB = limiterMarginDB
        self.limiterReleaseMs = limiterReleaseMs; self.limiterAttackMs = limiterAttackMs
        self.bandSolo = bandSolo & 0xF; self.bandBypass = bandBypass & 0xF
    }

    /// `band` 0...3, low to high.
    public func isSoloed(_ band: Int) -> Bool { bandSolo & (1 << band) != 0 }
    public func isBypassed(_ band: Int) -> Bool { bandBypass & (1 << band) != 0 }

    /// Gain in front of the limiter: the threshold is brought up to the margin (never a cut).
    public var limiterGainDB: Double { max(0, limiterMarginDB - limiterThresholdDB) }
}

/// One filter of the Parametric EQ. `gainDB` is unused by HP / LP; `q` is the peak Q, the shelf Q, and ignored by HP / LP
/// (fixed Butterworth).
public struct AudioPEQBand: Sendable, Hashable {
    public var on: Bool
    public var hz: Double
    public var gainDB: Double
    public var q: Double
    public init(on: Bool, hz: Double, gainDB: Double = 0, q: Double = 1) { self.on = on; self.hz = hz; self.gainDB = gainDB; self.q = q }
}

/// The Parametric EQ at one instant: high-pass, low shelf, five peaks, high shelf, low-pass (processing order).
public struct AudioParametricEQValues: Sendable, Hashable {
    public var hp: AudioPEQBand, lowShelf: AudioPEQBand
    public var b1: AudioPEQBand, b2: AudioPEQBand, b3: AudioPEQBand, b4: AudioPEQBand, b5: AudioPEQBand
    public var highShelf: AudioPEQBand, lp: AudioPEQBand
    public init(hp: AudioPEQBand, lowShelf: AudioPEQBand, b1: AudioPEQBand, b2: AudioPEQBand, b3: AudioPEQBand, b4: AudioPEQBand,
                b5: AudioPEQBand, highShelf: AudioPEQBand, lp: AudioPEQBand) {
        self.hp = hp; self.lowShelf = lowShelf; self.b1 = b1; self.b2 = b2; self.b3 = b3; self.b4 = b4; self.b5 = b5
        self.highShelf = highShelf; self.lp = lp
    }
    /// Filter `i` in processing order: 0 HP, 1 low shelf, 2...6 peaks, 7 high shelf, 8 LP.
    public subscript(i: Int) -> AudioPEQBand {
        switch i { case 0: hp; case 1: lowShelf; case 2: b1; case 3: b2; case 4: b3; case 5: b4; case 6: b5; case 7: highShelf; default: lp }
    }
    public static let bandCount = 9
}

extension ClipEffect {
    func multibandValues(atLocal t: Time) -> AudioMultibandValues {
        func v(_ k: String) -> Double { scalar(k, atLocal: t) }
        func four(_ f: (Int) -> String) -> SIMD4<Double> { SIMD4(v(f(1)), v(f(2)), v(f(3)), v(f(4))) }
        func mask(_ f: (Int) -> String) -> UInt8 { (0..<4).reduce(UInt8(0)) { $0 | (v(f($1 + 1)) >= 0.5 ? UInt8(1) << $1 : 0) } }
        return AudioMultibandValues(
            outputGainDB: v(Self.mbOutputGainKey),
            crossoverHz: SIMD3(v(Self.mbCrossoverKey(1)), v(Self.mbCrossoverKey(2)), v(Self.mbCrossoverKey(3))),
            thresholdDB: four(Self.mbThresholdKey), ratio: four(Self.mbRatioKey), attackMs: four(Self.mbAttackKey),
            releaseMs: four(Self.mbReleaseKey), gainDB: four(Self.mbGainKey),
            limiterOn: v(Self.mbLimiterOnKey) >= 0.5, limiterThresholdDB: v(Self.mbLimiterThresholdKey),
            limiterMarginDB: v(Self.mbLimiterMarginKey), limiterReleaseMs: v(Self.mbLimiterReleaseKey),
            limiterAttackMs: v(Self.mbLimiterAttackKey), bandSolo: mask(Self.mbSoloKey), bandBypass: mask(Self.mbBypassKey))
    }

    func parametricEQValues(atLocal t: Time) -> AudioParametricEQValues {
        func band(_ id: String) -> AudioPEQBand {
            let cut = id == "hp" || id == "lp"
            return AudioPEQBand(on: scalar(Self.peqKey(id, "On"), atLocal: t) >= 0.5, hz: scalar(Self.peqKey(id, "Freq"), atLocal: t),
                                gainDB: cut ? 0 : scalar(Self.peqKey(id, "Gain"), atLocal: t),
                                q: cut ? 0.7071 : scalar(Self.peqKey(id, "Q"), atLocal: t))
        }
        return AudioParametricEQValues(hp: band("hp"), lowShelf: band("ls"), b1: band("b1"), b2: band("b2"), b3: band("b3"),
                                       b4: band("b4"), b5: band("b5"), highShelf: band("hs"), lp: band("lp"))
    }
}

extension Project {
    /// Any timeline holds a clip with a Multiband Compressor or 5-band Parametric EQ: the file must be v46.
    public var containsVoiceChainEffects: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains { c in c.effects.contains { ClipEffect.voiceChainKinds.contains($0.kind) } } } }
    }
}
