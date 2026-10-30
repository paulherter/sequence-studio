import Foundation
import SQCore

/// Offline gain -> denoise -> noise gate -> multiband compressor -> de-esser -> saturation chain on plain `[[Float]]` buffers.
///
/// Gain (incl. pan and keyframed volume) is first: clip volume is a clip property and the compressor/denoiser
/// are track effects, so the track FX see the gained signal (Premiere order: clip -> track FX). Same order as
/// `RealtimeAudioFX` and the playback/export mixer (`AudioFeeder`).
/// Any sample rate: the denoiser runs at 48 kHz through AVAudioConverter and converts back.
///
/// Streaming use: `process` (keeps state; output is delayed by `latencySamples`, call `flushTail`
/// at the end). The volume automation is evaluated on the input at its own time, before the delay.
/// One-shot use: `render` (whole clip, latency compensated, same length out as in).
public struct OfflineAudioFX {
    public struct Result {
        public var channels: [[Float]]
        /// True if the denoiser ran (noise reduction > 0 in the preset), at any sample rate.
        public var denoiseApplied: Bool
    }

    public var volume: VolumeAutomation
    public var preset: TrackAudioPreset
    public let sampleRate: Int
    public let channelCount: Int

    private let denoise: DenoiseStage?
    private var gate: NoiseGate
    private var compressor: MultibandCompressor
    private var deEsser: DeEsser?
    private var saturator: Saturator

    /// Denoiser wet/dry mix, 0 (input, time-aligned) ... 1 (fully denoised). Starts at `preset.noiseReduction`.
    /// No effect if the preset had the denoiser off at init.
    public var denoiseMix: Double {
        get { Double(denoise?.mix ?? 0) }
        set { denoise?.mix = Float(min(1, max(0, newValue))) }
    }

    /// Delay added by the denoiser path, in samples at `sampleRate`.
    public var latencySamples: Int { denoise?.latencySamples ?? 0 }

    public init(volume: VolumeAutomation, preset: TrackAudioPreset, sampleRate: Int, channelCount: Int) throws {
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        guard sampleRate > 0 else { throw AudioFXError.unsupportedSampleRate(sampleRate) }
        self.volume = volume; self.preset = preset
        self.sampleRate = sampleRate; self.channelCount = channelCount
        if preset.noiseReduction > 0 {
            let d = try DenoiseStage(sampleRate: sampleRate, channelCount: channelCount)
            d.mix = Float(min(1, preset.noiseReduction))
            denoise = d
        } else {
            denoise = nil
        }
        gate = NoiseGate(settings: preset.gate, sampleRate: Double(sampleRate))
        compressor = MultibandCompressor(settings: preset.compressor, sampleRate: Double(sampleRate), channels: channelCount)
        deEsser = preset.deEss ? DeEsser(sampleRate: sampleRate, channelCount: channelCount) : nil
        saturator = Saturator(settings: preset.saturation)
    }

    /// Streaming step. `start` = timeline time of the first sample of `input`.
    public mutating func process(_ input: [[Float]], start: Time) -> [[Float]] {
        var g = input
        volume.apply(to: &g, start: start, sampleRate: sampleRate)
        return compress(denoise.map { $0.process(g) } ?? g)
    }

    /// Streaming end: the `latencySamples` still held back. `start` = timeline time just after the last input sample
    /// (unused since the gain runs before the delay; kept for call-site symmetry).
    public mutating func flushTail(start: Time) -> [[Float]] {
        guard let d = denoise else { return Array(repeating: [], count: channelCount) }
        return compress(d.flush())
    }

    private mutating func compress(_ denoised: [[Float]]) -> [[Float]] {
        var b = denoised
        gate.process(&b)
        compressor.process(&b)
        deEsser?.process(&b)
        saturator.process(&b)
        return b
    }

    /// Whole-buffer render, latency removed.
    public mutating func render(_ input: [[Float]], start: Time) -> Result {
        let n = input.first?.count ?? 0
        var out = process(input, start: start)
        if denoise != nil {
            let tail = flushTail(start: start + Time(Int64(n), Int64(sampleRate)))
            let lat = latencySamples
            for c in 0..<out.count { out[c] = Array((out[c] + tail[c]).dropFirst(lat).prefix(n)) }
        }
        return Result(channels: out, denoiseApplied: denoise != nil)
    }
}
