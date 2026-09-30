import Foundation
import SSCore

/// Offline gain -> denoise -> compressor chain on plain `[[Float]]` buffers (no playback needed).
///
/// Streaming use: `process` (keeps state; denoise adds `RNNoiseDenoiser.latencySamples` of delay).
/// One-shot use: `render` (whole clip, latency compensated, same length out as in).
public struct OfflineAudioFX {
    public struct Result {
        public var channels: [[Float]]
        /// False if noise reduction was requested but the sample rate is not 48 kHz.
        public var denoiseApplied: Bool
    }

    public var volume: VolumeAutomation
    public var preset: TrackAudioPreset
    public let sampleRate: Int
    public let channelCount: Int

    private let denoiser: RNNoiseDenoiser?
    private var compressor: PlaceholderCompressor
    private var position: Int64 = 0      // samples processed since `start` of the first call

    public var latencySamples: Int { denoiser == nil ? 0 : RNNoiseDenoiser.latencySamples }

    public init(volume: VolumeAutomation, preset: TrackAudioPreset, sampleRate: Int, channelCount: Int) throws {
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        self.volume = volume; self.preset = preset
        self.sampleRate = sampleRate; self.channelCount = channelCount
        if preset.noiseReduction > 0 && sampleRate == RNNoiseDenoiser.sampleRate {
            let d = try RNNoiseDenoiser(channelCount: channelCount, sampleRate: sampleRate)
            d.mix = Float(preset.noiseReduction)
            denoiser = d
        } else {
            denoiser = nil
        }
        compressor = PlaceholderCompressor(settings: preset.compressor, sampleRate: Double(sampleRate), channels: channelCount)
    }

    /// Streaming step. `start` = timeline time of the first sample of `input`.
    public mutating func process(_ input: [[Float]], start: Time) -> [[Float]] {
        var b = input
        volume.apply(to: &b, start: start, sampleRate: sampleRate)
        if let d = denoiser { b = d.process(b) }
        compressor.process(&b)
        return b
    }

    /// Whole-buffer render, denoise latency removed.
    public mutating func render(_ input: [[Float]], start: Time) -> Result {
        let n = input.first?.count ?? 0
        var out = process(input, start: start)
        if let d = denoiser {
            let tail = d.flush()
            var t = tail
            compressor.process(&t)
            let lat = RNNoiseDenoiser.latencySamples
            for c in 0..<out.count { out[c] = Array((out[c] + t[c]).dropFirst(lat).prefix(n)) }
        }
        let wanted = preset.noiseReduction > 0
        return Result(channels: out, denoiseApplied: wanted && denoiser != nil)
    }
}

/// Wideband feed-forward compressor, settings averaged over the four bands. Placeholder until
/// the real multiband path (AU or own DSP) is wired; see docs/PHASE5.md.
struct PlaceholderCompressor {
    private let active: Bool
    private let thresholdDB: Double, ratio: Double, makeup: Float
    private let attackCoef: Double, releaseCoef: Double
    private var env = 0.0          // linked level follower (linear amplitude)

    init(settings s: MultibandCompressorSettings, sampleRate: Double, channels: Int) {
        active = !s.bypass
        let b = s.bands
        func mean(_ f: (MultibandCompressorSettings.Band) -> Double) -> Double { b.isEmpty ? 0 : b.map(f).reduce(0, +) / Double(b.count) }
        thresholdDB = mean(\.thresholdDB)
        ratio = max(1, mean(\.ratio))
        makeup = Float(AudioGain.linear(fromDB: s.makeupGainDB + s.preGainDB * 0))
        attackCoef = exp(-1 / (max(0.0001, mean(\.attackMs) / 1000) * sampleRate))
        releaseCoef = exp(-1 / (max(0.0001, mean(\.releaseMs) / 1000) * sampleRate))
    }

    mutating func process(_ buf: inout [[Float]]) {
        guard active, let n = buf.first?.count else { return }
        for i in 0..<n {
            var peak = 0.0
            for c in 0..<buf.count { peak = max(peak, abs(Double(buf[c][i]))) }
            let coef = peak > env ? attackCoef : releaseCoef
            env = coef * env + (1 - coef) * peak
            let levelDB = AudioGain.dB(fromLinear: env)
            var gr = 0.0
            if levelDB > thresholdDB { gr = (levelDB - thresholdDB) * (1 - 1 / ratio) }
            let g = Float(pow(10, -gr / 20)) * makeup
            for c in 0..<buf.count { buf[c][i] *= g }
        }
    }
}
