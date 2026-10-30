import Foundation
import Testing
@testable import SQAudioFX

@Suite struct LoudnessTests {
    @Test func sine1kStereoMinus23() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 10))
        let i = m.integrated
        #expect(abs(i - -23.0) < 0.1, "integrated \(i)")
        #expect(abs((m.momentary ?? 0) - -23.0) < 0.1)
        #expect(abs((m.shortTerm ?? 0) - -23.0) < 0.1)
    }

    @Test func sineLevelShiftsLinearly() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -33, seconds: 5))
        #expect(abs(m.integrated - -33.0) < 0.1)
    }

    @Test func monoIsThreeDbBelowStereo() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 1)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 5, channels: 1))
        #expect(abs(m.integrated - -26.0) < 0.1)
    }

    @Test func kWeightingAttenuatesLowFrequencies() {
        var lo = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        lo.process(Sig.sine(freq: 40, amplitudeDB: -23, seconds: 5))
        #expect(lo.integrated < -24.5)           // 40 Hz is ~ -1.5 dB after the RLB filter
        var hi = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        hi.process(Sig.sine(freq: 8000, amplitudeDB: -23, seconds: 5))
        #expect(hi.integrated > -21.5)           // high shelf ~ +3.7 dB at 8 kHz
    }

    @Test func worksAt44100() {
        var m = LoudnessMeter(sampleRate: 44100, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 5, rate: 44100))
        #expect(abs(m.integrated - -23.0) < 0.1)
    }

    @Test func chunkingDoesNotMatter() {
        let x = Sig.sine(freq: 440, amplitudeDB: -20, seconds: 6)
        var a = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        a.process(x)
        var b = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        for p in Sig.chunked(x, sizes: [1, 100, 4799, 4800, 4801, 77]) { b.process(p) }
        #expect(abs(a.integrated - b.integrated) < 1e-9)
        #expect(a.momentary == b.momentary)
    }

    @Test func absoluteGateIgnoresQuietBlocks() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 5))
        m.process(Sig.sine(freq: 1000, amplitudeDB: -90, seconds: 6))   // below -70 LUFS
        #expect(abs(m.integrated - -23.0) < 0.3)   // transition blocks legitimately count
    }

    @Test func relativeGateIgnoresBlocksMoreThan10LUBelow() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 10))
        m.process(Sig.sine(freq: 1000, amplitudeDB: -45, seconds: 10))   // -25 LU below: gated out
        #expect(abs(m.integrated - -20.0) < 0.15)
        // ungated mean would be ~ -23
    }

    @Test func shortTermNeedsThreeSeconds() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 1))
        #expect(m.momentary != nil)
        #expect(m.shortTerm == nil)
        var short = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        short.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 0.3))
        #expect(short.momentary == nil)
        #expect(short.integrated == -.infinity)
    }

    @Test func silenceIsMinusInfinity() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Array(repeating: [Float](repeating: 0, count: 48000 * 2), count: 2))
        #expect(m.integrated == -.infinity)
        #expect(m.samplePeakDB == [-.infinity, -.infinity])
    }

    @Test func samplePeak() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        var x = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 1)
        x[1][100] = 0.5
        m.process(x)
        #expect(abs(m.samplePeakDB[0] - -20) < 0.05)
        #expect(abs(m.samplePeakDB[1] - -6.0206) < 0.01)
    }

    @Test func truePeakFindsIntersamplePeak() {
        // fs/4 sine at 45 degrees: every sample is +-0.7071 (-3 dBFS), true peak is 1.0 (0 dBTP)
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 1)
        m.process(Sig.sine(freq: 12000, amplitudeDB: 0, seconds: 0.5, channels: 1, phase: .pi / 4))
        #expect(abs(m.samplePeakDB[0] - -3.01) < 0.05)
        #expect(abs(m.truePeakDB[0] - 0) < 0.3, "true peak \(m.truePeakDB[0])")
    }

    @Test func truePeakNeverBelowSamplePeak() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 1)
        m.process([Sig.noise(amplitude: 0.8, count: 20000)])
        #expect(m.truePeakDB[0] >= m.samplePeakDB[0] - 1e-9)
    }

    @Test func reset() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 5))
        m.reset()
        #expect(m.integrated == -.infinity)
        #expect(m.momentary == nil)
    }

    /// Regression 2026-10-13: the loudness pass of an export took minutes in Debug (Range iterators per sample).
    @Test func fortyFiveSecondsStereoMeasuresQuickly() {
        let signal = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 45)
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        let start = ContinuousClock.now
        let block = 4096
        var at = 0
        while at < signal[0].count {
            let end = min(at + block, signal[0].count)
            m.process(signal.map { Array($0[at..<end]) })
            at = end
        }
        let elapsed = ContinuousClock.now - start
        #expect(abs(m.integrated - -20.0) < 0.1)
        #expect(elapsed < .seconds(8), "took \(elapsed)")
    }

    @Test func truePeakBlockPushEqualsSamplePush() {
        let xs = Sig.noise(amplitude: 0.9, count: 1000).map(Double.init)
        var a = TruePeakDetector(), b = TruePeakDetector()
        for x in xs { a.push(x) }
        xs.withUnsafeBufferPointer { b.push(contentsOf: $0) }
        #expect(a.peak == b.peak)
        #expect(a.peak >= xs.map { abs($0) }.max()! * 0.99)
    }

    // EBU Tech 3342 style: a constant level has range 0; a 20 LU step half and half gives LRA of about 20.
    @Test func loudnessRangeOfConstantToneIsZero() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 20))
        #expect(abs((m.loudnessRange ?? 99)) < 0.1)
    }

    @Test func loudnessRangeOfTenLUStepIsAboutTen() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -33, seconds: 20))
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 20))
        #expect(abs((m.loudnessRange ?? 0) - 10) < 0.3)
    }

    @Test func loudnessRangeGatesQuietPassages() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 30))
        m.process(Sig.sine(freq: 1000, amplitudeDB: -60, seconds: 3))   // more than 20 LU below: ignored
        #expect((m.loudnessRange ?? 99) < 0.5)
    }

    @Test func loudnessRangeNeedsThreeSecondsAndSound() {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: 2)
        m.process(Sig.sine(freq: 1000, amplitudeDB: -23, seconds: 2))
        #expect(m.loudnessRange == nil)
        m.reset()
        m.process(Array(repeating: [Float](repeating: 0, count: 48000 * 5), count: 2))
        #expect(m.loudnessRange == nil)
    }
}
