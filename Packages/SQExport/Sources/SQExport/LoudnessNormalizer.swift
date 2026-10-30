import Foundation
import SQAudioFX

public struct LoudnessMeasurement: Sendable, Equatable {
    /// Gated integrated loudness; -infinity for silence.
    public var integratedLUFS: Double
    /// Maximum true peak over all channels in dBTP.
    public var truePeakDB: Double
    public init(integratedLUFS: Double, truePeakDB: Double) {
        self.integratedLUFS = integratedLUFS; self.truePeakDB = truePeakDB
    }
}

/// What normalization did to an export: measured values, applied gain and the resulting (predicted) levels.
public struct LoudnessReport: Sendable, Equatable {
    public var measuredLUFS: Double
    public var measuredTruePeakDB: Double
    public var targetLUFS: Double
    public var ceilingDB: Double
    public var gainDB: Double
    /// True when the ceiling, not the target, decided the gain.
    public var limitedByCeiling: Bool
    /// Levels measured in the written file (decoded again after the encode); nil when not checked.
    public var verified: LoudnessMeasurement? = nil
    /// True when a peak limiter behind the gain brought the loudness closer to the target than the ceiling-limited gain.
    public var limiterUsed = false
    /// Levels the chain measured for the output (through gain and limiter); nil = measured + gain.
    public var resultLUFS: Double? = nil
    public var resultTruePeakDB: Double? = nil

    /// Tolerance of the post-encode check: the lossy encoder may move the peak a little (dB).
    public static let verifyToleranceDB = 0.05

    /// How far the written file's true peak is above the ceiling (dB), nil when it is within tolerance or not measured.
    public var overshootDB: Double? {
        guard let v = verified, v.truePeakDB.isFinite else { return nil }
        let over = v.truePeakDB - ceilingDB
        return over > Self.verifyToleranceDB ? over : nil
    }

    public init(measurement m: LoudnessMeasurement, settings: LoudnessNormalization) {
        measuredLUFS = m.integratedLUFS; measuredTruePeakDB = m.truePeakDB
        targetLUFS = settings.targetLUFS; ceilingDB = settings.truePeakCeilingDB
        gainDB = LoudnessNormalizer.gainDB(for: m, settings: settings)
        limitedByCeiling = m.integratedLUFS.isFinite && m.truePeakDB.isFinite
            && settings.targetLUFS - m.integratedLUFS > settings.truePeakCeilingDB - m.truePeakDB
    }

    /// What `NormalizedAudioSource.make` really settled on: gain, limiter and the levels it measured through them.
    public init(normalized n: NormalizedAudioSource, settings: LoudnessNormalization) {
        self.init(measurement: n.measurement, settings: settings)
        gainDB = n.gainDB
        limiterUsed = n.limiterCeilingDB != nil
        resultLUFS = n.result.integratedLUFS; resultTruePeakDB = n.result.truePeakDB
    }

    public var outputLUFS: Double { resultLUFS ?? (measuredLUFS + gainDB) }
    public var outputTruePeakDB: Double { resultTruePeakDB ?? (measuredTruePeakDB + gainDB) }

    public var summary: String {
        guard measuredLUFS.isFinite else { return "Audio is silent, loudness unchanged" }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var s = "\(f(outputLUFS)) LUFS, \(f(outputTruePeakDB)) dBTP (gain \(gainDB >= 0 ? "+" : "")\(f(gainDB)) dB"
        if limiterUsed { s += ", peak limiter at \(f(ceilingDB)) dBTP ceiling)" }
        else { s += limitedByCeiling ? ", limited by \(f(ceilingDB)) dBTP ceiling)" : ")" }
        if let v = verified, v.integratedLUFS.isFinite {
            s += "; in the file \(f(v.integratedLUFS)) LUFS, \(f(v.truePeakDB)) dBTP"
            if let o = overshootDB { s += ", \(f(o)) dB above the ceiling" }
        }
        return s
    }
}

/// One constant gain, then an optional peak limiter: what the export applies to the mix and what the search measures.
struct LoudnessChain {
    let gain: Float
    private(set) var limiter: MasterLimiter?

    init(gainDB: Double, limiterCeilingDB: Double?, sampleRate: Int) {
        gain = Float(GainMath.linear(fromDB: gainDB))
        limiter = limiterCeilingDB.map { MasterLimiter(sampleRate: sampleRate, ceilingDB: $0) }
    }

    mutating func reset() { limiter?.reset() }

    mutating func apply(_ chunk: inout AudioChunk) {
        if gain != 1 {
            let g = gain
            chunk.samples.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < p.count { p[i] *= g; i += 1 }
            }
        }
        guard limiter != nil, chunk.channels > 0 else { return }
        let n = chunk.frameCount, ch = chunk.channels
        guard n > 0 else { return }   // an empty chunk has no buffer address
        chunk.samples.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            limiter?.process(interleaved: base, channels: ch, count: n)
        }
    }
}

/// Loudness normalization. Pass 1 measures (BS.1770 via `LoudnessMeter`), pass 2 applies one linear gain. When the
/// true-peak ceiling stops that gain short of the target (a peaky mix), a bounded search raises the gain behind a peak
/// limiter and keeps the result closest to the target that still holds the ceiling.
public enum LoudnessNormalizer {
    /// Extra measuring passes the search may spend at most (each runs the whole mix again).
    public static let maxSearchPasses = 3
    /// Within this many LU of the target the search stops.
    public static let toleranceLU = 0.1
    /// The search never raises the gain more than this above the ceiling-limited gain (more limiting is audible).
    public static let maxExtraGainDB = 6.0

    /// Reads the whole source (from its start) and rewinds it afterwards.
    public static func measure(_ source: some RewindableAudioSource) async throws -> LoudnessMeasurement {
        try await measure(source, chain: nil)
    }

    static func measure(_ source: some RewindableAudioSource, chain: LoudnessChain?) async throws -> LoudnessMeasurement {
        var chain = chain
        try await source.rewind()
        var meter = LoudnessMeter(sampleRate: source.sampleRate, channelCount: source.channels)
        while var chunk = try await source.nextChunk(maxFrames: 4096) {
            try Task.checkCancellation()
            chain?.apply(&chunk)
            let n = chunk.frameCount, ch = chunk.channels
            var planar = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
            chunk.samples.withUnsafeBufferPointer { src in
                var c = 0
                while c < ch {                  // index loops: Range iterators are ~100x slower in Debug
                    planar[c].withUnsafeMutableBufferPointer { dst in
                        var i = 0
                        while i < n { dst[i] = src[i * ch + c]; i += 1 }
                    }
                    c += 1
                }
            }
            meter.process(planar)
        }
        try await source.rewind()
        return LoudnessMeasurement(integratedLUFS: meter.integrated, truePeakDB: meter.truePeakDB.max() ?? -.infinity)
    }

    /// target - measured, reduced so the true peak after gain is at most the ceiling.
    /// Silence (nothing above the gate) gets 0 dB.
    public static func gainDB(for m: LoudnessMeasurement, settings: LoudnessNormalization) -> Double {
        guard m.integratedLUFS.isFinite else { return 0 }
        let wanted = settings.targetLUFS - m.integratedLUFS
        guard m.truePeakDB.isFinite else { return wanted }
        return min(wanted, settings.truePeakCeilingDB - m.truePeakDB)
    }

    /// The gain (and limiter) the export applies, and the levels measured for it.
    struct Plan { var gainDB: Double; var limiterCeilingDB: Double?; var result: LoudnessMeasurement }

    /// `m` is the measurement of `source` as it is. Plain gain when the ceiling does not decide; otherwise at most
    /// `maxSearchPasses` limited passes. Every candidate is measured through the real chain (true peak included); a
    /// true-peak overshoot (inter-sample peaks the sample limiter cannot see) lowers the limiter ceiling. The
    /// ceiling-limited plain gain stays the answer unless a candidate is clearly closer to the target.
    static func plan(for source: some RewindableAudioSource, measured m: LoudnessMeasurement,
                     settings: LoudnessNormalization) async throws -> Plan {
        let plain = gainDB(for: m, settings: settings)
        var best = Plan(gainDB: plain, limiterCeilingDB: nil,
                        result: LoudnessMeasurement(integratedLUFS: m.integratedLUFS + plain, truePeakDB: m.truePeakDB + plain))
        guard m.integratedLUFS.isFinite, m.truePeakDB.isFinite,
              settings.targetLUFS - best.result.integratedLUFS > toleranceLU else { return best }
        let ceiling = settings.truePeakCeilingDB, target = settings.targetLUFS
        let cap = plain + maxExtraGainDB
        var gain = plain, lastL = best.result.integratedLUFS, limiterCeiling = ceiling
        var passes = 0, first = true
        while passes < maxSearchPasses {
            let next = min(first ? target - m.integratedLUFS : gain + (target - lastL), cap)
            if !first && next <= gain + 0.01 { break }          // the cap (or nothing to add) is reached
            gain = next
            let r = try await measure(source, chain: LoudnessChain(gainDB: gain, limiterCeilingDB: limiterCeiling,
                                                                   sampleRate: source.sampleRate))
            passes += 1
            if r.truePeakDB > ceiling + LoudnessReport.verifyToleranceDB {
                limiterCeiling -= r.truePeakDB - ceiling         // inter-sample overshoot: the limiter needs more room
                lastL = r.integratedLUFS; first = false
                continue
            }
            let err = abs(target - r.integratedLUFS)
            if err < abs(target - best.result.integratedLUFS) - 0.05 {
                best = Plan(gainDB: gain, limiterCeilingDB: limiterCeiling, result: r)
            }
            if err <= toleranceLU { break }
            if !first && r.integratedLUFS - lastL < 0.05 { break }   // more gain no longer comes out louder
            lastL = r.integratedLUFS; first = false
        }
        return best
    }
}

/// Applies the planned gain (and peak limiter) to another source. Build with `make`, which runs the measuring pass(es).
/// `@unchecked Sendable`: the limiter state is touched only by `nextChunk`/`rewind`, which the export calls from one task.
public final class NormalizedAudioSource: RewindableAudioSource, @unchecked Sendable {
    private let base: any RewindableAudioSource
    public let gainDB: Double
    /// Ceiling of the peak limiter behind the gain; nil = gain only.
    public let limiterCeilingDB: Double?
    /// The source as it is.
    public let measurement: LoudnessMeasurement
    /// The levels measured through gain and limiter.
    public let result: LoudnessMeasurement
    private var chain: LoudnessChain
    public var sampleRate: Int { base.sampleRate }
    public var channels: Int { base.channels }

    init(base: any RewindableAudioSource, measurement: LoudnessMeasurement, plan: LoudnessNormalizer.Plan) {
        self.base = base; self.measurement = measurement
        gainDB = plan.gainDB; limiterCeilingDB = plan.limiterCeilingDB; result = plan.result
        chain = LoudnessChain(gainDB: plan.gainDB, limiterCeilingDB: plan.limiterCeilingDB, sampleRate: base.sampleRate)
    }

    public static func make(_ base: some RewindableAudioSource, settings: LoudnessNormalization) async throws -> NormalizedAudioSource {
        let m = try await LoudnessNormalizer.measure(base)
        let plan = try await LoudnessNormalizer.plan(for: base, measured: m, settings: settings)
        return NormalizedAudioSource(base: base, measurement: m, plan: plan)
    }

    public func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        guard var chunk = try await base.nextChunk(maxFrames: maxFrames) else { return nil }
        chain.apply(&chunk)
        return chunk
    }

    public func rewind() async throws { chain.reset(); try await base.rewind() }
}
