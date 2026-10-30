import Foundation
import Testing
import SQCore
@testable import SQAudioFX

@Suite struct AudioSpectrumTests {
    // MARK: Analyzer

    @Test func sinePeaksAtItsFrequencyWithItsLevel() {
        let a = SpectrumAnalyzer()
        let x = Sig.mono(1_000, amplitudeDB: -20, seconds: 0.2)
        let pts = SpectrumAnalyzer.frequencies(points: 128)
        let db = a.magnitudesDB(Array(x.suffix(SpectrumAnalyzer.size)), sampleRate: 48_000, points: 128)
        #expect(db.count == 128)
        let i1k = pts.indices.min { abs(log(pts[$0] / 1_000)) < abs(log(pts[$1] / 1_000)) }!
        #expect(abs(Double(db[i1k]) + 20) < 1.5, "1 kHz reads \(db[i1k]) dB")
        let i100 = pts.indices.min { abs(log(pts[$0] / 100)) < abs(log(pts[$1] / 100)) }!
        let i8k = pts.indices.min { abs(log(pts[$0] / 8_000)) < abs(log(pts[$1] / 8_000)) }!
        #expect(db[i100] < -70 && db[i8k] < -70, "leak \(db[i100]) \(db[i8k])")
        #expect(db.max() == db[i1k] || abs(Double(db.max()!) - Double(db[i1k])) < 0.5)
    }

    @Test func silenceReadsTheFloorAndFrequenciesAreLogSpaced() {
        let db = SpectrumAnalyzer().magnitudesDB([Float](repeating: 0, count: SpectrumAnalyzer.size), sampleRate: 48_000, points: 64)
        #expect(db.allSatisfy { $0 == SpectrumAnalyzer.floorDB })
        let f = SpectrumAnalyzer.frequencies(points: 64)
        #expect(abs(f.first! - 20) < 1e-9 && abs(f.last! - 20_000) < 1e-6)
        #expect(abs(f[1] / f[0] - f[63] / f[62]) < 1e-9)
    }

    // MARK: Tap

    private func chain(_ kind: String, tap: AudioSpectrumTap) throws -> (ClipAudioFXChain, AudioFXSlot) {
        let s = AudioFXSlot(id: UUID(), kind: kind)
        return (try ClipAudioFXChain(layout: [s], channelCount: 2, maxFrames: 1_024, spectrumTap: tap), s)
    }

    @Test func nothingIsPublishedUnlessWatched() throws {
        let tap = AudioSpectrumTap()
        let (c, s) = try chain(ClipEffect.audioGainKind, tap: tap)
        var b = Sig.sine(freq: 1_000, amplitudeDB: -20, seconds: 0.02)
        c.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: .gain(dB: -20))])
        #expect(tap.sequence == 0)
        var out = [Float]()
        #expect(tap.snapshot(for: s.id, into: &out) == nil)
        tap.watch(UUID())                                   // another effect
        c.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: .gain(dB: -20))])
        #expect(tap.sequence == 0)
    }

    @Test func inputAndOutputTapsSeeBeforeAndAfterTheEffect() throws {
        let tap = AudioSpectrumTap()
        let (c, s) = try chain(ClipEffect.audioGainKind, tap: tap)
        let x = Sig.sine(freq: 1_000, amplitudeDB: -20, seconds: 0.2)
        func feed() {
            for part in Sig.chunked(x, sizes: [512]) {
                var b = part
                c.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: .gain(dB: -20))])
            }
        }
        var out = [Float]()
        tap.watch(s.id, atInput: true)
        feed()
        #expect(tap.sequence > 0)
        #expect(tap.snapshot(for: s.id, into: &out) != nil)
        #expect(out.count == SpectrumAnalyzer.size)
        let rin = Sig.rms(out[...])
        tap.watch(s.id, atInput: false)
        feed()
        _ = tap.snapshot(for: s.id, into: &out)
        let rout = Sig.rms(out[...])
        #expect(abs(Sig.db(rin) - (-23)) < 0.5, "input \(Sig.db(rin))")          // -20 dB peak sine = -23 dB RMS
        #expect(abs(Sig.db(rout) - Sig.db(rin) + 20) < 0.5, "output \(Sig.db(rout))")
    }

    @Test func snapshotIsOldestFirstAndHoldsTheLatestSamples() throws {
        let tap = AudioSpectrumTap()
        let id = UUID()
        tap.watch(id)
        let n = SpectrumAnalyzer.size + 300
        let ramp = (0..<n).map { Float($0) }
        ramp.withUnsafeBufferPointer { p in
            var ptr = UnsafeMutablePointer(mutating: p.baseAddress!)
            withUnsafeMutablePointer(to: &ptr) { tap.push($0, channels: 1, frames: n) }
        }
        var out = [Float]()
        #expect(tap.snapshot(for: id, into: &out) == 1)
        #expect(out.first == Float(n - SpectrumAnalyzer.size) && out.last == Float(n - 1))
    }
}
