import Foundation
import Testing
import SQCore
@testable import SQMedia

@Suite struct ToneAudioSourceTests {
    private func read(_ s: ToneAudioSource, _ from: Int64, _ n: Int) throws -> [Float] {
        var out = [Float](repeating: 9, count: n)
        let got = try out.withUnsafeMutableBufferPointer { try s.read(from: from, count: n, into: $0.baseAddress!, channel: 0) }
        #expect(got == n)
        return out
    }

    @Test func oneKilohertzAtMinusTwelveHasTheRightSamples() throws {
        let s = ToneAudioSource(.default)
        let x = try read(s, 0, 96)
        let a = Float(pow(10.0, -12.0 / 20))
        #expect(x[0] == 0)
        for k in 0..<96 { #expect(abs(x[k] - a * Float(sin(2 * Double.pi * Double(k) / 48))) < 1e-6) }   // 48 samples per cycle
        #expect(abs(x[12] - a) < 1e-6 && abs(x[36] + a) < 1e-6)                                           // peaks at quarter cycles
        #expect(x.map(abs).max()! <= a + 1e-6)
    }

    @Test func phaseIsContinuousAcrossBlocksAndSeeks() throws {
        let s = ToneAudioSource(ToneSpec(frequencyHz: 997.3, levelDB: -12))
        let whole = try read(s, 1_000_000, 4096)
        var pieces: [Float] = []
        for st in stride(from: 0, to: 4096, by: 333) { pieces += try read(s, 1_000_000 + Int64(st), min(333, 4096 - st)) }
        #expect(pieces == whole)
        let step = zip(whole, whole.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(step < 0.2512 * 2 * Float.pi * 997.3 / 48_000 * 1.01)            // never steeper than the sine itself
    }

    @Test func lateFramesStayExact() throws {
        // Ten hours in: integer phase keeps the sample equal to the one a whole number of cycles earlier.
        let s = ToneAudioSource(.default)
        let late: Int64 = 48_000 * 36_000
        #expect(try read(s, late, 64) == read(s, 0, 64))
    }

    @Test func onlyToneIDsResolve() {
        #expect(ToneAudioSource.source(for: ToneSpec.default.mediaID)?.spec == .default)
        #expect(ToneAudioSource.source(for: UUID()) == nil)
        #expect(ToneAudioSource(.default).isMono)
    }
}
