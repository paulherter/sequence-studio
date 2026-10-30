import Testing
import Foundation
import SQCore
@testable import SQExport

/// Loudness correction after peak limiting: when the true-peak ceiling stops the plain gain short of the target, a
/// bounded search raises the gain behind a peak limiter until the target is reached or no more can be had.
@Suite struct LoudnessLimitingTests {
    /// 1 kHz sine at `base`, with a ~1 ms burst at `burst` every half second (a crest the limiter can take off).
    final class PeakySource: RewindableAudioSource, @unchecked Sendable {
        let sampleRate = 48_000, channels = 2
        let base: Float, burst: Float, total: Int
        private(set) var passes = 0
        private var pos = 0
        init(base: Float, burst: Float, seconds: Int = 6) { self.base = base; self.burst = burst; total = seconds * 48_000 }
        func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
            guard pos < total else { passes += 1; return nil }
            let n = min(maxFrames, total - pos)
            var s = [Float](repeating: 0, count: n * 2)
            for i in 0..<n {
                let f = pos + i
                let a = (f % 24_000) < 48 ? burst : base
                let v = a * Float(sin(2 * Double.pi * 1000 * Double(f) / 48_000))
                s[i * 2] = v; s[i * 2 + 1] = v
            }
            pos += n
            return AudioChunk(samples: s, channels: 2)
        }
        func rewind() async throws { pos = 0 }
    }

    @Test func limiterRecoversLoudnessThePeakCostUnderPlainGain() async throws {
        let settings = LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)
        let src = PeakySource(base: 0.1, burst: 0.8)
        let m = try await LoudnessNormalizer.measure(src)
        let plain = LoudnessNormalizer.gainDB(for: m, settings: settings)
        #expect(m.integratedLUFS + plain < -17 - 1.5)           // the premise: the ceiling alone leaves it too quiet

        let n = try await NormalizedAudioSource.make(PeakySource(base: 0.1, burst: 0.8), settings: settings)
        #expect(n.limiterCeilingDB != nil)
        #expect(n.gainDB > plain)
        let out = try await LoudnessNormalizer.measure(n)
        #expect(abs(out.integratedLUFS - -17) < 0.5, "got \(out.integratedLUFS)")
        #expect(out.truePeakDB <= -1 + LoudnessReport.verifyToleranceDB, "peak \(out.truePeakDB)")
        // The source's own prediction matches what the chain really does.
        #expect(abs(n.result.integratedLUFS - out.integratedLUFS) < 0.05)
    }

    @Test func searchIsBounded() async throws {
        let src = PeakySource(base: 0.1, burst: 0.8)
        _ = try await NormalizedAudioSource.make(src, settings: LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1))
        // One measuring pass plus at most `maxSearchPasses` limited passes.
        #expect(src.passes >= 2)
        #expect(src.passes <= 1 + LoudnessNormalizer.maxSearchPasses)
    }

    @Test func extraGainIsCapped() async throws {
        // A pure sine under a very low ceiling: the limiter can never win the loudness back, the search stops, and the
        // gain never runs more than `maxExtraGainDB` above the plain one.
        let src = PeakySource(base: 0.25, burst: 0.25)
        let s = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -20)
        let m = try await LoudnessNormalizer.measure(src)
        let plain = LoudnessNormalizer.gainDB(for: m, settings: s)
        let before = src.passes
        let n = try await NormalizedAudioSource.make(src, settings: s)
        #expect(n.gainDB <= plain + LoudnessNormalizer.maxExtraGainDB + 1e-9)
        #expect(src.passes - before <= 1 + LoudnessNormalizer.maxSearchPasses)
        let out = try await LoudnessNormalizer.measure(n)
        #expect(out.truePeakDB <= -20 + LoudnessReport.verifyToleranceDB)
    }

    @Test func noExtraPassWhenTheTargetIsReached() async throws {
        let src = PeakySource(base: 0.9, burst: 0.9)             // loud: the gain is a cut, the ceiling plays no part
        let n = try await NormalizedAudioSource.make(src, settings: LoudnessNormalization())
        #expect(n.limiterCeilingDB == nil)
        #expect(src.passes == 1)
    }

    @Test func reportNamesTheLimiterAndTheRealResult() async throws {
        let s = LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)
        let n = try await NormalizedAudioSource.make(PeakySource(base: 0.1, burst: 0.8), settings: s)
        let r = LoudnessReport(normalized: n, settings: s)
        #expect(r.limiterUsed)
        #expect(abs(r.outputLUFS - n.result.integratedLUFS) < 1e-9)
        #expect(r.summary.contains("limiter"))
    }

    @Test func preflightPredictsTheLimiterAssistedLoudness() async throws {
        let settings = LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)
        let a = try await AudioPreflight.analyze(PeakySource(base: 0.1, burst: 0.8))
        let plain = AudioPreflight.evaluate(a, target: settings, normalizing: true)
        let plan = try await AudioPreflight.predict(PeakySource(base: 0.1, burst: 0.8), analysis: a, target: settings)
        #expect(plan.limiterUsed)
        let planned = AudioPreflight.evaluate(a, target: settings, normalizing: true, predicted: plan)
        let loud = try #require(planned.first { $0.kind == .loudness })
        // Same number the export reaches (see limiterRecoversLoudnessThePeakCostUnderPlainGain), not the ceiling-limited one.
        #expect(abs(plan.outputLUFS - -17) < 0.5)
        #expect(loud.message.contains("peak limiter"))
        #expect(loud.message != plain.first { $0.kind == .loudness }?.message)
        #expect(planned.first { $0.kind == .truePeak }?.severity == .pass)
    }
}

@Suite struct LoudnessChainEmptyChunkTests {
    @Test func emptyChunkThroughLimiterDoesNotCrash() {
        var chain = LoudnessChain(gainDB: -3, limiterCeilingDB: -1, sampleRate: 48_000)
        var chunk = AudioChunk(samples: [], channels: 2)
        chain.apply(&chunk)
        #expect(chunk.samples.isEmpty)
    }
}
