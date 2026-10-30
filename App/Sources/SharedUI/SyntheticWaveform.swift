import Foundation
import SQMedia

/// A speech-like waveform for the shot harness (the demo media is offline, so nothing decodes): 0.7 s of sound, then a
/// 0.48 s pause, over 90 s at 48 kHz. Remove Silences finds the same pauses for every clip range.
enum SyntheticWaveform {
    static let speech: WaveformData = {
        let rate = 48_000, bucket = 256, seconds = 90
        let total = rate * seconds, buckets = total / bucket
        let period = 1.18, sound = 0.7
        var level = [Float](repeating: 0, count: buckets * 2)
        for i in 0..<buckets {
            let t = Double(i * bucket) / Double(rate)
            let phase = t.truncatingRemainder(dividingBy: period)
            if phase < sound { let a = Float(0.25 + 0.2 * abs(sin(t * 7))); level[i * 2] = -a; level[i * 2 + 1] = a }
        }
        var levels = [level]
        // Coarser mip levels the way the reader builds them: min / max of neighbour pairs.
        while let last = levels.last, last.count / 2 > 1, levels.count < 12 {
            var next = [Float](); next.reserveCapacity(last.count / 2)
            var i = 0
            while i + 3 < last.count { next.append(min(last[i], last[i + 2])); next.append(max(last[i + 1], last[i + 3])); i += 4 }
            levels.append(next)
        }
        return WaveformData(sampleRate: rate, channelCount: 1, totalFrames: total, baseBucketSize: bucket, levels: levels)
    }()
}
