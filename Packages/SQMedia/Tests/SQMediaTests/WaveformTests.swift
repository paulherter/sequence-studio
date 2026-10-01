import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

private func clip(clicks: [CMTime], frames: Int = 120) async throws -> URL {
    var spec = TestClipSpec()
    spec.frameCount = frames   // 4 s at 30 fps
    spec.audioClicks = clicks
    return try await TestClipWriter.write(spec)
}

@Test func waveformClickLandsInRightBucket() async throws {
    let url = try await clip(clicks: [CMTime(value: 1, timescale: 1), CMTime(value: 5, timescale: 2)])
    let wf = try await WaveformBuilder.build(url: url)
    #expect(wf.sampleRate == 48_000)
    #expect(wf.channelCount == 2)
    #expect(wf.totalFrames >= 192_000 - 4800)
    let base = wf.baseBucketSize
    #expect(base == 256)
    for sample in [48_000, 120_000] {
        let b = sample / base
        for ch in 0..<2 {
            let p = wf.bucket(level: 0, index: b, channel: ch)
            #expect(p.max == 1 && p.min == 0)
            #expect(wf.bucket(level: 0, index: b - 1, channel: ch) == WaveformPeak(min: 0, max: 0))
            #expect(wf.bucket(level: 0, index: b + 1, channel: ch) == WaveformPeak(min: 0, max: 0))
        }
    }
}

@Test func waveformPeaksInRange() async throws {
    let url = try await clip(clicks: [CMTime(value: 44, timescale: 25)])   // 1.76 s
    let wf = try await WaveformBuilder.build(url: url)
    // 0..4 s in 8 buckets of 0.5 s: the click (1.76 s) is inside bucket 3 (1.5..2.0 s).
    let peaks = wf.peaks(in: TimeRange(start: .zero, duration: Time(4, 1)), buckets: 8)
    #expect(peaks.count == 2 && peaks[0].count == 8)
    for i in 0..<8 { #expect(peaks[0][i].max == (i == 3 ? 1 : 0)) }
    // Zoomed in on 1.7..1.8 s (4 buckets of 25 ms): 1.76 s lands in bucket 2.
    let z = wf.peaks(in: TimeRange(start: Time(17, 10), end: Time(18, 10)), buckets: 4)
    #expect(z[0].map(\.max) == [0, 0, 1, 0])
    // Outside the clip: silence, no crash.
    let out = wf.peaks(in: TimeRange(start: Time(100, 1), duration: Time(1, 1)), buckets: 3)
    #expect(out[0].allSatisfy { $0.max == 0 && $0.min == 0 })
}

@Test func waveformMipLevelsAgree() async throws {
    let url = try await clip(clicks: [CMTime(value: 2, timescale: 1)])
    let wf = try await WaveformBuilder.build(url: url)
    #expect(wf.levelCount > 3)
    for level in 1..<wf.levelCount {
        let size = wf.bucketSize(level: level)
        #expect(size == wf.baseBucketSize << level)
        #expect(wf.bucket(level: level, index: 96_000 / size, channel: 0).max == 1)
    }
    #expect(wf.bucketCount(level: wf.levelCount - 1) <= 2)
}

@Test func waveformBinaryRoundTripAndVersion() async throws {
    let url = try await clip(clicks: [CMTime(value: 1, timescale: 2)], frames: 30)
    let wf = try await WaveformBuilder.build(url: url)
    let data = wf.serialized()
    #expect(try WaveformData(serialized: data) == wf)
    var bad = data
    bad[4] = 99   // version byte
    #expect(throws: WaveformData.FormatError.self) { try WaveformData(serialized: bad) }
    #expect(throws: WaveformData.FormatError.self) { try WaveformData(serialized: data.prefix(10)) }
    #expect(throws: WaveformData.FormatError.self) { try WaveformData(serialized: data.dropLast(3)) }
    let enc = try JSONEncoder().encode(wf)
    #expect(try JSONDecoder().decode(WaveformData.self, from: enc) == wf)
}

@Test func waveformNoAudioThrows() async throws {
    var spec = TestClipSpec()
    spec.frameCount = 10
    let url = try await TestClipWriter.write(spec)
    await #expect(throws: WaveformError.self) { try await WaveformBuilder.build(url: url) }
}

@Test func waveformCancellation() async throws {
    let url = try await clip(clicks: [], frames: 30)
    let t = Task { try await WaveformBuilder.build(url: url) }
    t.cancel()
    await #expect(throws: (any Error).self) { try await t.value }
}
