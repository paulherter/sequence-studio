import Foundation
import SQCore

// Sync by audio (Create Angles Clip, Sync Audio to Reference): portable, so the Windows app reads the envelope from its
// FFmpeg waveform.

extension WaveformData {
    /// Steps per second of the sync envelopes: 10 ms, finer than a frame at any usual rate (`AnglesSync.envelopeRate`).
    public static let envelopeRate = 100

    /// Loudness envelope for sync by audio: the peak over all channels per step, `rate` values per second.
    /// Built from the finest waveform level (256 samples per bucket: finer than one step at any usual sample rate).
    public func envelope(rate: Int = WaveformData.envelopeRate) -> [Float] {
        guard sampleRate > 0, channelCount > 0, rate > 0, totalFrames > 0, let base = levels.first else { return [] }
        let buckets = base.count / (2 * channelCount)
        let count = Int((Int64(totalFrames) * Int64(rate) + Int64(sampleRate) - 1) / Int64(sampleRate))
        guard buckets > 0, count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for b in 0..<buckets {
            let step = Int(Int64(b) * Int64(baseBucketSize) * Int64(rate) / Int64(sampleRate))
            guard step < count else { break }
            var peak: Float = 0
            for ch in 0..<channelCount {
                let i = (b * channelCount + ch) * 2
                peak = max(peak, abs(base[i]), abs(base[i + 1]))
            }
            if peak > out[step] { out[step] = peak }
        }
        return out
    }
}

extension AudioGainPlan {
    /// Loudest sample of the clip's source range as linear 0...1 (Audio Gain's Normalize Peak), from the waveform.
    public static func peak(of data: WaveformData, source: TimeRange) -> Double {
        let p = data.peaks(in: source, buckets: 1)
        return p.reduce(0.0) { m, ch in max(m, ch.map { Double(max(abs($0.min), abs($0.max))) }.max() ?? 0) }
    }
}
