import AVFoundation
import CoreMedia
import Foundation
import SSMediaTestSupport
import Testing
@testable import SSMedia

private func readAll(_ s: any AudioSource, from: Int64, count: Int, channel: Int) throws -> [Float] {
    var buf = [Float](repeating: 0, count: count)
    let n = try buf.withUnsafeMutableBufferPointer { try s.read(from: from, count: count, into: $0.baseAddress!, channel: channel) }
    return Array(buf[0..<n])
}
private func clickPositions(_ a: [Float], base: Int64 = 0, threshold: Float = 0.5) -> [Int64] {
    a.enumerated().filter { abs($0.element) > threshold }.map { base + Int64($0.offset) }
}

@Suite struct AudioSourceTests {
    @Test func memorySourceReadsAndStopsAtEnd() throws {
        let s = MemoryAudioSource(mono: [1, 2, 3, 4])
        #expect(try readAll(s, from: 2, count: 10, channel: 0) == [3, 4])
        #expect(try readAll(s, from: 4, count: 10, channel: 1).isEmpty)
        #expect(try readAll(s, from: -1, count: 2, channel: 0).isEmpty)
    }

    @Test func assetSourceClicksLandOnExactSamples() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 90                          // 3 s
        let times: [CMTime] = [CMTime(value: 1, timescale: 2), CMTime(value: 48_000, timescale: 48_000),
                               CMTime(value: 72_001, timescale: 48_000), CMTime(value: 2, timescale: 1)]
        spec.audioClicks = times
        let expected = times.map(TestClipSpec.sampleIndex(of:))      // 24000, 48000, 72001, 96000
        let url = try await TestClipWriter.write(spec)
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)

        // One sequential pass over 3 s in odd-sized reads (crosses 1 s block seams).
        var found: [Int64] = []
        var pos: Int64 = 0
        for _ in 0..<100 {                            // bounded: 3 s is ~21 reads
            let a = try readAll(src, from: pos, count: 7_001, channel: 0)
            if a.isEmpty { break }
            found += clickPositions(a, base: pos)
            pos += Int64(a.count)
        }
        #expect(found == expected)
        #expect(pos >= 144_000 - 1)                   // full length read, then 0 past the end

        // Right channel identical; click value is full scale.
        let r = try readAll(src, from: expected[1] - 2, count: 5, channel: 1)
        #expect(r == [0, 0, 1, 0, 0])
    }

    @Test func backwardAndRandomAccessReadsAreExact() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 90
        spec.audioClicks = [CMTime(value: 30_000, timescale: 48_000), CMTime(value: 100_000, timescale: 48_000)]
        let url = try await TestClipWriter.write(spec)
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        // Reverse block order, like reverse playback: 1024-frame blocks stepping down across two seams.
        for (from, hit) in [(Int64(99_500), Int64(100_000)), (98_000, nil), (49_152, nil), (29_700, Int64(30_000)), (0, nil)] as [(Int64, Int64?)] {
            let a = try readAll(src, from: from, count: 1024, channel: 0)
            #expect(a.count == 1024)
            #expect(clickPositions(a, base: from) == (hit.map { [$0] } ?? []), "block at \(from)")
        }
        // Jump forward far past the cursor, then back to the start.
        #expect(clickPositions(try readAll(src, from: 100_000 - 10, count: 20, channel: 0), base: 99_990) == [100_000])
        #expect(clickPositions(try readAll(src, from: 30_000 - 10, count: 20, channel: 0), base: 29_990) == [30_000])
    }

    @Test func resampleToOtherRateKeepsClickTimingWithinAFewSamples() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 60
        spec.audioClicks = [CMTime(value: 1, timescale: 2)]     // 0.5 s
        let url = try await TestClipWriter.write(spec)
        let src = try await AssetAudioSource.open(url: url, sampleRate: 96_000)
        let a = try readAll(src, from: 0, count: 96_000, channel: 0)
        let peak = try #require(a.enumerated().max { abs($0.element) < abs($1.element) })
        #expect(abs(peak.offset - 48_000) <= 4, "peak at \(peak.offset)")
    }

    @Test func fileWithoutAudioThrows() async throws {
        let url = try await TestClipWriter.write(TestClipSpec())
        await #expect(throws: MediaError.self) { _ = try await AssetAudioSource.open(url: url, sampleRate: 48_000) }
    }

    @Test func backwardReadOfEvictedBlockWithinReaderRange() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 240                          // 8 s
        spec.audioClicks = [CMTime(value: 60_000, timescale: 48_000)]     // in block 1
        let url = try await TestClipWriter.write(spec)
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        var pos: Int64 = 0
        for _ in 0..<200 {                             // bounded: 8 s is ~80 reads
            guard try readAll(src, from: pos, count: 4_800, channel: 0).count == 4_800 else { break }
            pos += 4_800                               // evicts early blocks
        }
        let a = try readAll(src, from: 59_990, count: 20, channel: 0)
        #expect(a.count == 20)
        #expect(clickPositions(a, base: 59_990) == [60_000])
    }

    @Test func restartPastTheEndDoesNotCorruptTotalLength() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 80                           // 128000 frames
        spec.audioClicks = [CMTime(value: 1, timescale: 2)]
        let url = try await TestClipWriter.write(spec)
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        #expect(try readAll(src, from: 127_990, count: 100, channel: 0).count == 10)
        #expect(try readAll(src, from: 200_000, count: 100, channel: 0).isEmpty)
        #expect(try readAll(src, from: 127_990, count: 100, channel: 0).count == 10)
    }

    @Test func readingPastTheEndReturnsZeroAndTerminates() async throws {
        var spec = TestClipSpec()
        spec.frameCount = 60                           // 2 s
        spec.audioClicks = [CMTime(value: 1, timescale: 2)]
        let url = try await TestClipWriter.write(spec)
        for rate in [48_000, 96_000] {                 // 96 kHz exercises the resampler tail
            let src = try await AssetAudioSource.open(url: url, sampleRate: rate)
            var pos: Int64 = 0
            var reads = 0
            // Drain in fixed reads; a read of 0 is the end of the stream and must end the loop.
            while reads < 1_000 {
                let n = try readAll(src, from: pos, count: 4_096, channel: 0).count
                reads += 1
                if n == 0 { break }
                pos += Int64(n)
            }
            #expect(reads < 1_000, "drain did not terminate at \(rate) Hz")
            #expect(abs(pos - Int64(2 * rate)) <= Int64(rate / 10), "length \(pos) at \(rate) Hz")
            // Past the end stays 0, repeatedly, on both channels, and a read back inside still works.
            for _ in 0..<3 {
                #expect(try readAll(src, from: pos, count: 100, channel: 0).isEmpty)
                #expect(try readAll(src, from: pos + 10_000, count: 100, channel: 1).isEmpty)
            }
            #expect(try readAll(src, from: 0, count: 100, channel: 0).count == 100)
        }
        let mem = MemoryAudioSource(mono: [1, 2, 3])
        #expect(try readAll(mem, from: 3, count: 8, channel: 0).isEmpty)
        #expect(try readAll(mem, from: 1_000, count: 8, channel: 1).isEmpty)
    }
}

@Suite struct MonoAudioTests {
    /// A mono file plays on both sides (not only left) and keeps its level.
    @Test func monoFileFillsLeftAndRightEqually() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mono-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48_000.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000)!
        buf.frameLength = 48_000
        for i in 0..<48_000 { buf.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / rate)) * 0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            try file.write(from: buf)
        }
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        let l = try readAll(src, from: 12_000, count: 4_800, channel: 0)
        let r = try readAll(src, from: 12_000, count: 4_800, channel: 1)
        #expect(l.count == 4_800 && r.count == 4_800)
        let peakL = l.map(abs).max() ?? 0, peakR = r.map(abs).max() ?? 0
        #expect(peakL > 0.45 && peakR > 0.45, "left \(peakL) right \(peakR)")
        #expect(abs(peakL - peakR) < 0.02)
    }
}

