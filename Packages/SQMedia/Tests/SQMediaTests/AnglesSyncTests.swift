import Foundation
import Testing
import SQCore
@testable import SQMedia

@Suite struct AnglesSyncTests {
    /// Waveform of `seconds` at 48 kHz: silent except bursts (seconds, level). No audio is decoded or played.
    private func waveform(seconds: Int, bursts: [(ClosedRange<Double>, Float)], channels: Int = 2) -> WaveformData {
        let rate = 48_000, bucket = 256
        let frames = seconds * rate
        let buckets = (frames + bucket - 1) / bucket
        var level = [Float](repeating: 0, count: buckets * channels * 2)
        for b in 0..<buckets {
            let t = Double(b * bucket) / Double(rate)
            guard let hit = bursts.first(where: { $0.0.contains(t) }) else { continue }
            // Only the last channel is loud: the envelope takes the peak over all channels.
            let i = (b * channels + channels - 1) * 2
            level[i] = -hit.1; level[i + 1] = hit.1 / 2
        }
        return WaveformData(sampleRate: rate, channelCount: channels, totalFrames: frames, baseBucketSize: bucket, levels: [level])
    }

    @Test func envelopeHasOneValuePerStepAndFollowsThePeaks() {
        let e = waveform(seconds: 4, bursts: [(1.0...2.0, 0.8)]).envelope(rate: 100)
        #expect(e.count == 400)
        #expect(e[50] == 0)
        #expect(e[150] == 0.8)          // the larger of |min| and |max|
        #expect(e[250] == 0)
    }

    @Test func envelopesOfShiftedRecordingsMatchAtTheShift() throws {
        // The same sounds, 1.5 s later in the second recording: the second one started 1.5 s earlier.
        let a = waveform(seconds: 20, bursts: [(3.0...3.4, 0.5), (6.0...7.3, 0.8), (11.0...11.2, 0.3)]).envelope()
        let b = waveform(seconds: 20, bursts: [(4.5...4.9, 0.5), (7.5...8.8, 0.8), (12.5...12.7, 0.3)]).envelope()
        let m = try #require(AnglesAudioSync.match(reference: a, other: b))
        #expect(abs(m.lag - -150) <= 1)
        #expect(AnglesAudioSync.time(lag: -150, rate: AnglesSync.envelopeRate) == Time(-3, 2))
    }

    @Test func emptyWaveformGivesNoEnvelope() {
        #expect(WaveformData(sampleRate: 48_000, channelCount: 2, totalFrames: 0, baseBucketSize: 256, levels: [[]]).envelope().isEmpty)
    }

    @Test func timecodeFramesBecomeTime() {
        #expect(AnglesSync.time(frames: 90_000, base: 25, slowed: false) == Time(3600, 1))          // 01:00:00:00 at 25 fps
        #expect(AnglesSync.time(frames: 30, base: 30, slowed: true) == Time(1001, 1000))            // 29.97: 30 frames last 1.001 s
        #expect(AnglesSync.time(frames: 1, base: 0, slowed: false) == nil)
    }

    @Test func aMissingFileHasNoTimecode() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-angles-none-\(UUID().uuidString).mov")
        #expect(await AnglesSync.startTimecode(url: url) == nil)
    }
}
