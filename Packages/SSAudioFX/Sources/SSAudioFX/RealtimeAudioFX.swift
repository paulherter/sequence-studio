import Foundation
import CRNNoise
import SSCore
import Synchronization

/// Realtime denoise -> 4-band compressor -> gain/pan/volume chain for the playback audio engine.
///
/// Same DSP as `OfflineAudioFX` (same code for the compressor and the gain, the denoiser is the same RNNoise
/// frame logic), on deinterleaved Float channel pointers, in place, fixed 48 kHz. Non-48 kHz material is
/// resampled upstream by the feeder, not here.
///
/// Threading contract:
/// - `process` and `reset` effects happen on ONE render thread (a Core Audio render callback). `process` never
///   allocates, never blocks, never messages ObjC and never frees memory.
/// - `setPreset`, `setDenoiseMix`, `setVolume`, `setBypass` may be called from any thread at any time. They
///   build the new parameter set on the caller's thread (allocation happens there) and hand it over through
///   a mutex the render thread only ever *tries* (non-blocking); the new set is applied at the start of the
///   next `process` call. If a setter holds the lock at that instant, the update lands one block later.
/// - `reset()` may be called from any thread; it is applied at the start of the next `process` call.
///
/// Latency: 480 samples while a denoiser exists (`denoiser: true`), else 0. The latency stays constant even
/// at denoise mix 0 or bypass (the dry path is delayed too), so moving the mix never makes the audio jump.
/// The timeline sample handed to `process` is the position of the first INPUT sample; volume is evaluated for
/// the input time of each output sample (like `OfflineAudioFX`).
public final class RealtimeAudioFX: @unchecked Sendable {
    public static let sampleRate = 48000
    static let frame = RNNoiseDenoiser.frameSize

    /// Everything the render thread needs; plain value, built off the render thread.
    private struct Params {
        var compressor: MultibandCompressor.Config
        var mix: Float
        var bypass: Bool
        var volume: VolumeAutomation
    }

    private struct Mailbox {
        var desired: Params          // setter side, authoritative
        var outbox: Params           // swapped with the render thread's copy
        var dirty = false
    }

    private struct DenoiseChannel {
        var state: OpaquePointer
        var inFrame: UnsafeMutablePointer<Float>
        var wet: UnsafeMutablePointer<Float>
        var dry: UnsafeMutablePointer<Float>
        var pos = 0
    }

    /// RNNoise initialises unsynchronised globals lazily on its first frame (`check_init`: allocates the FFT
    /// twiddles). Forced once per process here (swift_once serialises it), so it never runs on the render thread.
    private static let rnnoiseGlobalInit: Bool = {
        let st = rnnoise_create(nil)!
        var inF = [Float](repeating: 0, count: RNNoiseDenoiser.frameSize)
        var out = inF
        _ = rnnoise_process_frame(st, &out, &inF)
        rnnoise_destroy(st)
        return true
    }()

    public let channelCount: Int
    public let maxFrames: Int
    /// 480 while a denoiser exists, else 0. Constant for the lifetime of the object.
    public let latencySamples: Int

    private let mailbox: Mutex<Mailbox>
    private let resetRequested = Atomic<Bool>(false)

    // Render-thread state
    private var params: Params
    private var compressor: MultibandCompressor
    private var denoise: [DenoiseChannel]
    private let channelPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>   // scratch for gain stage

    /// - Parameters:
    ///   - preset: compressor settings and initial denoise mix (`noiseReduction`).
    ///   - denoiser: allocate the RNNoise path (default true). Without it latency is 0 and the mix is ignored.
    public init(preset: TrackAudioPreset, volume: VolumeAutomation, channelCount: Int, maxFrames: Int,
                denoiser: Bool = true) throws {
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        if denoiser { _ = Self.rnnoiseGlobalInit }
        self.channelCount = channelCount
        self.maxFrames = max(1, maxFrames)
        latencySamples = denoiser ? RNNoiseDenoiser.latencySamples : 0
        let p = Params(compressor: .init(settings: preset.compressor, sampleRate: Double(Self.sampleRate)),
                       mix: Float(min(1, max(0, preset.noiseReduction))), bypass: false, volume: volume)
        params = p
        mailbox = Mutex(Mailbox(desired: p, outbox: p))
        compressor = MultibandCompressor(settings: preset.compressor, sampleRate: Double(Self.sampleRate), channels: channelCount)
        channelPtrs = .allocate(capacity: channelCount)
        denoise = []
        if denoiser {
            let f = Self.frame
            for _ in 0..<channelCount {
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: 3 * f)
                buf.initialize(repeating: 0, count: 3 * f)
                denoise.append(DenoiseChannel(state: rnnoise_create(nil)!, inFrame: buf, wet: buf + f, dry: buf + 2 * f))
            }
        }
    }

    deinit {
        for d in denoise { rnnoise_destroy(d.state); d.inFrame.deallocate() }
        channelPtrs.deallocate()
    }

    // MARK: parameters (any thread)

    private func update(_ body: (inout Params) -> Void) {
        mailbox.withLock { m in
            body(&m.desired)
            m.outbox = m.desired
            m.dirty = true
        }
    }

    /// New compressor settings and denoise mix (= `preset.noiseReduction`). Detector state is kept.
    public func setPreset(_ preset: TrackAudioPreset) {
        let cfg = MultibandCompressor.Config(settings: preset.compressor, sampleRate: Double(Self.sampleRate))
        let mix = Float(min(1, max(0, preset.noiseReduction)))
        update { $0.compressor = cfg; $0.mix = mix }
    }

    /// Denoiser wet/dry mix 0...1 (no effect without a denoiser). Latency does not change.
    public func setDenoiseMix(_ mix: Double) {
        let m = Float(min(1, max(0, mix)))
        update { $0.mix = m }
    }

    public func setVolume(_ volume: VolumeAutomation) { update { $0.volume = volume } }

    /// Bypass = compressor off and denoiser dry (still delayed by `latencySamples`). Volume/pan stay active:
    /// they are clip properties, not effects.
    public func setBypass(_ bypass: Bool) { update { $0.bypass = bypass } }

    /// Clears all DSP state (filters, detectors, denoiser history). Use on seeks; applied at the next `process`.
    public func reset() { resetRequested.store(true, ordering: .releasing) }

    // MARK: render thread

    /// In place. `buffers[c]` points at `frameCount` Floats of channel c (`frameCount <= maxFrames`).
    /// `timelineSample` = timeline position (48 kHz samples) of the first sample of this block.
    public func process(_ buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frameCount: Int, timelineSample: Int64) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFrames, "frameCount exceeds maxFrames")

        if resetRequested.exchange(false, ordering: .acquiringAndReleasing) { resetState() }
        mailbox.withLockIfAvailable { m in
            if m.dirty {
                swap(&params, &m.outbox)          // old value parks in the mailbox, freed by the next setter
                m.dirty = false
                compressor.apply(params.compressor)
            }
        }

        if !denoise.isEmpty { runDenoise(buffers, frameCount) }
        compressor.process(channels: buffers, channelCount: channelCount, frames: frameCount)
        params.volume.apply(channels: buffers, channelCount: channelCount, frames: frameCount,
                            startSample: timelineSample - Int64(latencySamples), sampleRate: Self.sampleRate)
    }

    private func runDenoise(_ buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ n: Int) {
        let mix: Float = params.bypass ? 0 : min(1, max(0, params.mix))
        let f = Self.frame
        let scale: Float = 32768, inv: Float = 1 / 32768
        for c in 0..<channelCount {
            let buf = buffers[c]
            var pos = denoise[c].pos
            let inF = denoise[c].inFrame, wet = denoise[c].wet, dry = denoise[c].dry
            for i in 0..<n {
                inF[pos] = buf[i] * scale
                buf[i] = (wet[pos] * mix + dry[pos] * (1 - mix)) * inv
                pos += 1
                if pos == f {
                    _ = rnnoise_process_frame(denoise[c].state, wet, inF)
                    dry.update(from: inF, count: f)
                    pos = 0
                }
            }
            denoise[c].pos = pos
        }
    }

    private func resetState() {
        compressor.reset()
        let f = Self.frame
        for c in 0..<denoise.count {
            rnnoise_reset(denoise[c].state)
            denoise[c].inFrame.update(repeating: 0, count: f)
            denoise[c].wet.update(repeating: 0, count: f)
            denoise[c].dry.update(repeating: 0, count: f)
            denoise[c].pos = 0
        }
    }
}
