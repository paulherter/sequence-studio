import Foundation
import Testing
@testable import SQMedia

@Suite struct PeakPyramidTests {
    private func noise(_ n: Int, seed: UInt64) -> [Float] {
        var x = seed
        return (0..<n).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: x >> 11) % 2000) / 1000 - 1
        }
    }

    @Test func sourcePeaksMatchAScalarLoopAndThePyramidHalves() throws {
        let l = noise(10_000, seed: 1), r = noise(10_000, seed: 2)
        let wf = try #require(try PeakPyramid.waveform(from: MemoryAudioSource(left: l, right: r), sampleRate: 48_000,
                                                       baseBucketSize: 256, chunk: 1000))
        #expect(wf.channelCount == 2 && wf.totalFrames == 10_000 && wf.baseBucketSize == 256)
        let level0 = wf.levels[0]
        #expect(level0.count == 40 * 4)                       // 40 buckets (the last partial) x 2 channels x min/max
        for b in 0..<40 {
            let s = l[(b * 256)..<min((b + 1) * 256, l.count)]
            #expect(level0[b * 4] == s.min()! && level0[b * 4 + 1] == s.max()!)
        }
        #expect(wf.levels[1].count == 20 * 4)
        #expect(wf.levels[1][0] == min(level0[0], level0[4]) && wf.levels[1][1] == max(level0[1], level0[5]))
        #expect(wf.levels.last!.count / 4 <= 2)
    }

    @Test func monoSourceGivesOneChannelAndCancelStops() throws {
        let wf = try #require(try PeakPyramid.waveform(from: MemoryAudioSource(mono: noise(3000, seed: 3)), sampleRate: 48_000))
        #expect(wf.channelCount == 1)
        #expect(try PeakPyramid.waveform(from: MemoryAudioSource(mono: [0.5]), sampleRate: 48_000, isCancelled: { true }) == nil)
    }

    #if canImport(Accelerate)
    /// The Mac's vDSP accumulator and the portable scalar one give the same level 0.
    @Test func scalarMatchesTheVDSPAccumulator() {
        let l = noise(7777, seed: 4), r = noise(7777, seed: 5)
        var fast = PeakAccumulator(channels: 2, bucketSize: 100)
        var slow = ScalarPeakAccumulator(channels: 2, bucketSize: 100)
        l.withUnsafeBufferPointer { a in r.withUnsafeBufferPointer { b in
            fast.add(planar: [a.baseAddress!, b.baseAddress!], frames: 7777)
            slow.add(planar: [a.baseAddress!, b.baseAddress!], frames: 7777)
        } }
        #expect(fast.finish() == slow.finish())
    }
    #endif
}
