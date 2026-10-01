import Foundation
import SQAudioFX

public struct LoudnessMeasurement: Sendable, Equatable {
    /// Gated integrated loudness; -infinity for silence.
    public var integratedLUFS: Double
    /// Maximum true peak over all channels in dBTP.
    public var truePeakDB: Double
}

/// Two-pass loudness normalisation. Pass 1 measures (BS.1770 via `LoudnessMeter`), pass 2 applies one linear gain.
public enum LoudnessNormalizer {
    /// Reads the whole source (from its start) and rewinds it afterwards.
    public static func measure(_ source: some RewindableAudioSource) async throws -> LoudnessMeasurement {
        try await source.rewind()
        var meter = LoudnessMeter(sampleRate: source.sampleRate, channelCount: source.channels)
        while let chunk = try await source.nextChunk(maxFrames: 4096) {
            try Task.checkCancellation()
            let n = chunk.frameCount, ch = chunk.channels
            var planar = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
            for i in 0..<n { for c in 0..<ch { planar[c][i] = chunk.samples[i * ch + c] } }
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
}

/// Applies a constant gain to another source. Build with `make`, which runs the measuring pass.
public final class NormalizedAudioSource: RewindableAudioSource {
    private let base: any RewindableAudioSource
    public let gainDB: Double
    public let measurement: LoudnessMeasurement
    private let gain: Float
    public var sampleRate: Int { base.sampleRate }
    public var channels: Int { base.channels }

    private init(base: any RewindableAudioSource, measurement: LoudnessMeasurement, gainDB: Double) {
        self.base = base; self.measurement = measurement; self.gainDB = gainDB
        self.gain = Float(GainMath.linear(fromDB: gainDB))
    }

    public static func make(_ base: some RewindableAudioSource, settings: LoudnessNormalization) async throws -> NormalizedAudioSource {
        let m = try await LoudnessNormalizer.measure(base)
        return NormalizedAudioSource(base: base, measurement: m, gainDB: LoudnessNormalizer.gainDB(for: m, settings: settings))
    }

    public func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        guard var chunk = try await base.nextChunk(maxFrames: maxFrames) else { return nil }
        for i in chunk.samples.indices { chunk.samples[i] *= gain }
        return chunk
    }

    public func rewind() async throws { try await base.rewind() }
}
