import Foundation
import CRNNoise
import SQCore

/// The audio effect stack of one clip (AUDIO-FX): its `audio.*` effects in list order, on deinterleaved Float channels, in
/// place, at 48 kHz. One instance per clip and mix thread; the layout (which effects, in which order) is fixed, the values
/// (`AudioFXStep`s, evaluated by the caller per block) can change every block without losing state.
///
/// Stages: Noise Reduction (RNNoise wet/dry, as in `RealtimeAudioFX`), Parametric EQ (RBJ low shelf, peak, high shelf),
/// Compressor (single band, the 4-band compressor's detector), De-Esser (`DeEsser`), Gain, Hard Limiter (`MasterLimiter`), Noise Gate, Delay (2 s line), Reverb (Freeverb): see SpaceAndGateStages.swift.
/// A disabled step passes the sound through; a disabled Noise Reduction (and De-Reverb) still delays it, so the latency never changes.
///
/// Latency: 480 samples when the layout holds a Noise Reduction, plus `MultibandStage.latency` (240) per Multiband
/// Compressor, `AudioDeReverbValues.latencySamples` per De-Reverb and `AudioEnhanceSpeechValues.latencySamples` per Enhance Speech, `AudioPitchValues.latencySamples` per Pitch Shift and Disguise Voice, else 0. The caller compensates it (reads ahead).
/// `process` does not allocate (state is preallocated in `init`, stages are classes); it is not thread-safe.
public final class ClipAudioFXChain: @unchecked Sendable {
    public static let sampleRate = 48_000
    /// Sub-block length over which ramped parameters (EQ, compressor, limiter ceiling) are re-evaluated.
    static let rampChunk = 32
    public let layout: [AudioFXSlot]
    public let channelCount: Int
    public let maxFrames: Int
    public let latencySamples: Int

    private let stages: [Stage]
    /// Slot ids pre-split for the spectrum tap (one compare per stage and block decides whether to publish).
    private let slotKeys: [(UInt64, UInt64)]
    private let spectrumTap: AudioSpectrumTap

    public init(layout: [AudioFXSlot], channelCount: Int, maxFrames: Int, spectrumTap: AudioSpectrumTap = .shared) throws {
        guard channelCount > 0 else { throw AudioFXError.invalidChannelCount(channelCount) }
        self.layout = layout
        self.channelCount = channelCount
        self.maxFrames = max(1, maxFrames)
        self.spectrumTap = spectrumTap
        slotKeys = layout.map { MultibandMeterTap.split($0.id) }
        let fs = Double(Self.sampleRate)
        stages = layout.map { s in
            switch s.kind {
            case ClipEffect.audioNoiseReductionKind: .denoise(Denoise(channels: channelCount))
            case ClipEffect.audioEQKind: .eq(EQ(channels: channelCount))
            case ClipEffect.audioCompressorKind: .compressor(Compressor(sampleRate: fs))
            case ClipEffect.audioDeEsserKind: .deEsser(DeEsserStage(sampleRate: Self.sampleRate, channels: channelCount))
            case ClipEffect.audioDeReverbKind: .deReverb(DeReverbStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioGainKind: .gain
            case ClipEffect.audioParametricEQKind: .parametricEQ(ParametricEQStage(channels: channelCount))
            case ClipEffect.audioMultibandKind: .multiband(MultibandStage(sampleRate: fs, channels: channelCount, maxFrames: maxFrames, id: s.id))
            case ClipEffect.audioNoiseGateKind: .gate(NoiseGateStage(sampleRate: fs))
            case ClipEffect.audioDelayKind: .delay(DelayStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioReverbKind: .reverb(ReverbStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioLimiterKind: .limiter(LimiterStage(sampleRate: Self.sampleRate, maxFrames: maxFrames))
            case ClipEffect.audioDeHumKind: .deHum(DeHumStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioLowCutKind: .lowCut(LowCutStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioDialogueLevelerKind: .leveler(DialogueLevelerStage(sampleRate: fs))
            case ClipEffect.audioEnhanceSpeechKind: .enhance(EnhanceSpeechStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioHighCutKind: .highCut(HighCutStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioStereoWidthKind: .stereoWidth(StereoWidthStage())
            case ClipEffect.audioChorusKind: .chorus(ChorusStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioNotchKind: .notch(NotchStage(sampleRate: fs, channels: channelCount))
            case ClipEffect.audioGraphicEQKind: .graphicEQ(GraphicEQStage(channels: channelCount))
            case ClipEffect.audioPitchShiftKind: .pitchShift(PitchShiftStage(channels: channelCount))
            case ClipEffect.audioDisguiseVoiceKind: .disguiseVoice(DisguiseVoiceStage(sampleRate: fs, channels: channelCount, id: s.id))
            default: .none
            }
        }
        // Noise Reduction: one RNNoise frame; every Multiband Compressor: its limiter's look-ahead (also while disabled).
        latencySamples = (layout.contains { $0.kind == ClipEffect.audioNoiseReductionKind } ? RNNoiseDenoiser.latencySamples : 0)
            + layout.filter { $0.kind == ClipEffect.audioMultibandKind }.count * MultibandStage.latency
            + layout.filter { $0.kind == ClipEffect.audioDeReverbKind }.count * AudioDeReverbValues.latencySamples
            + layout.filter { $0.kind == ClipEffect.audioEnhanceSpeechKind }.count * AudioEnhanceSpeechValues.latencySamples
            // Pitch Shift and Disguise Voice: one analysis window each (also while disabled).
            + layout.filter { $0.kind == ClipEffect.audioPitchShiftKind || $0.kind == ClipEffect.audioDisguiseVoiceKind }.count
                * AudioPitchValues.latencySamples
    }

    deinit {
        for case .denoise(let d) in stages { d.free() }
        for case .enhance(let e) in stages { e.free() }
    }

    /// Clears all filter, detector and denoiser history (a seek, or the clip starts again).
    public func reset() {
        for st in stages {
            switch st {
            case .denoise(let d): d.reset()
            case .eq(let e): e.reset()
            case .compressor(let c): c.reset()
            case .deEsser(let d): d.reset()
            case .deReverb(let d): d.reset()
            case .limiter(let l): l.reset()
            case .parametricEQ(let e): e.reset()
            case .multiband(let m): m.reset()
            case .gate(let g): g.reset()
            case .delay(let d): d.reset()
            case .reverb(let r): r.reset()
            case .deHum(let d): d.reset()
            case .lowCut(let d): d.reset()
            case .leveler(let d): d.reset()
            case .enhance(let e): e.reset()
            case .highCut(let d): d.reset()
            case .stereoWidth(let d): d.reset()
            case .chorus(let d): d.reset()
            case .notch(let d): d.reset()
            case .graphicEQ(let d): d.reset()
            case .pitchShift(let p): p.reset()
            case .disguiseVoice(let d): d.reset()
            case .gain, .none: break
            }
        }
    }

    /// In place. `steps` are the values at the first sample (same ids and order as `layout`; a missing or mismatched step
    /// silences the block, never passes it dry), `endSteps` the values one block later: every parameter moves towards them across the block
    /// (gains and the denoiser amount per sample, EQ, compressor and limiter ceiling every `rampChunk` samples).
    public func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frameCount n: Int,
                        steps: [AudioFXStep], endSteps: [AudioFXStep]? = nil) {
        guard n > 0 else { return }
        precondition(n <= maxFrames, "frameCount exceeds maxFrames")
        let chs = channelCount
        for i in stages.indices {
            // Fail closed: a stage without its matching step would pass the voice dry (Disguise Voice must never leak it).
            guard i < steps.count, steps[i].id == layout[i].id else {
                for c in 0..<chs { buf[c].update(repeating: 0, count: n) }
                return
            }
            let step = steps[i]
            var end = step
            if let e = endSteps, i < e.count, e[i].id == step.id { end = e[i] }
            let tapped = spectrumTap.isWatched(hi: slotKeys[i].0, lo: slotKeys[i].1)
            let tapInput = tapped && spectrumTap.atInput
            if tapInput { spectrumTap.push(buf, channels: chs, frames: n) }
            runStage(i, step, end, buf, chs, n)
            if tapped && !tapInput { spectrumTap.push(buf, channels: chs, frames: n) }
        }
    }

    /// One stage over the block (`step` at the first sample, `end` one block later).
    @inline(__always)
    private func runStage(_ i: Int, _ step: AudioFXStep, _ end: AudioFXStep,
                          _ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ chs: Int, _ n: Int) {
        switch (stages[i], step.stage) {
        case (.denoise(let d), .noiseReduction(let amount)):
            var amountEnd = amount
            if case .noiseReduction(let a) = end.stage { amountEnd = a }
            let m0 = step.enabled ? Float(min(1, max(0, amount))) : 0
            let m1 = step.enabled ? Float(min(1, max(0, amountEnd))) : 0
            d.process(buf, channels: chs, frames: n, mixFrom: m0, to: m1)
        case (.eq(let e), .eq(let v)):
            guard step.enabled else { e.wasOff = true; return }
            var v1 = v
            if case .eq(let x) = end.stage { v1 = x }
            e.process(buf, channels: chs, frames: n, from: v, to: v1, sampleRate: Double(Self.sampleRate))
        case (.compressor(let c), .compressor(let th, let ratio, let atk, let rel, let makeup)):
            guard step.enabled else { c.wasOff = true; return }
            var to = (th, ratio, makeup)
            if case .compressor(let t1, let r1, _, _, let m1) = end.stage { to = (t1, r1, m1) }
            c.process(buf, channels: chs, frames: n, from: (th, ratio, makeup), to: to, attackMs: atk, releaseMs: rel)
        case (.deEsser(let d), .deEsser(let red, let sens, let freq, let range, let speed, let listen)):
            guard step.enabled else { d.wasOff = true; return }
            var to = (red, sens)
            if case .deEsser(let r1, let s1, _, _, _, _) = end.stage { to = (r1, s1) }
            d.setTarget(frequencyHz: freq, range: range, speed: speed, listen: listen)
            d.process(buf, channels: chs, frames: n, from: (red, sens), to: to)
        case (.deReverb(let d), .deReverb(let amount, let decay, let tone)):
            d.process(buf, channels: chs, frames: n, amount: amount, decay: decay, tone: tone, enabled: step.enabled)
        case (.gain, .gain(let a)):
            guard step.enabled else { return }
            var b = a
            if case .gain(let e) = end.stage { b = e }
            Self.ramp(buf, channels: chs, frames: n, fromDB: a, toDB: b)
        case (.limiter(let l), .limiter(let input, let ceiling)):
            guard step.enabled else { l.wasOff = true; return }
            var inEnd = input, ceilEnd = ceiling
            if case .limiter(let e, let c) = end.stage { inEnd = e; ceilEnd = c }
            Self.ramp(buf, channels: chs, frames: n, fromDB: input, toDB: inEnd)
            l.process(buf, channels: chs, frames: n, ceilingFrom: ceiling, to: ceilEnd)
        case (.parametricEQ(let e), .parametricEQ(let v)):
            guard step.enabled else { e.wasOff = true; return }
            var v1 = v
            if case .parametricEQ(let x) = end.stage { v1 = x }
            e.process(buf, channels: chs, frames: n, from: v, to: v1, sampleRate: Double(Self.sampleRate))
        case (.multiband(let m), .multiband(let v)):
            guard step.enabled else { m.bypass(buf, channels: chs, frames: n); return }
            var v1 = v
            if case .multiband(let x) = end.stage { v1 = x }
            m.process(buf, channels: chs, frames: n, from: v, to: v1)
        case (.gate(let g), .noiseGate(let th, let atk, let rel, let range, let hold)):
            guard step.enabled else { g.wasOff = true; return }
            var to = (th, range)
            if case .noiseGate(let t1, _, _, let r1, _) = end.stage { to = (t1, r1) }
            g.process(buf, channels: chs, frames: n, thresholdFrom: th, to: to.0, attackMs: atk, releaseMs: rel, rangeFrom: range, to: to.1,
                      holdMs: hold)
        case (.delay(let d), .delay(let time, let fb, let mix)):
            guard step.enabled else { d.wasOff = true; return }
            var to = (time, fb, mix)
            if case .delay(let t1, let f1, let m1) = end.stage { to = (t1, f1, m1) }
            d.process(buf, channels: chs, frames: n, timeFrom: time, to: to.0, feedbackFrom: fb, to: to.1, mixFrom: mix, to: to.2)
        case (.reverb(let r), .reverb(let room, let damp, let mix)):
            guard step.enabled else { r.wasOff = true; return }
            var to = (room, damp, mix)
            if case .reverb(let a, let b, let m1) = end.stage { to = (a, b, m1) }
            r.process(buf, channels: chs, frames: n, room: to.0, damping: to.1, mixFrom: mix, to: to.2)
        case (.deHum(let d), .deHum(let hz, let q, let g, let h, let slope, let listen)):
            guard step.enabled else { d.wasOff = true; return }
            d.process(buf, channels: chs, frames: n, frequencyHz: hz, q: q, gainDB: g, harmonics: h, slope: slope, listen: listen)
        case (.lowCut(let d), .lowCut(let hz, let order)):
            guard step.enabled else { d.wasOff = true; return }
            d.process(buf, channels: chs, frames: n, frequencyHz: hz, order: order)
        case (.highCut(let d), .highCut(let hz, let order)):
            guard step.enabled else { d.wasOff = true; return }
            d.process(buf, channels: chs, frames: n, frequencyHz: hz, order: order)
        case (.stereoWidth(let d), .stereoWidth(let w)):
            guard step.enabled else { return }
            var w1 = w
            if case .stereoWidth(let x) = end.stage { w1 = x }
            d.process(buf, channels: chs, frames: n, from: w, to: w1)
        case (.notch(let d), .notch(let hz, let q, let depth)):
            guard step.enabled else { d.wasOff = true; return }
            var e = (hz, q, depth)
            if case .notch(let h1, let q1, let d1) = end.stage { e = (h1, q1, d1) }
            d.process(buf, channels: chs, frames: n, from: (hz, q, depth), to: e)
        case (.graphicEQ(let d), .graphicEQ(let v)):
            guard step.enabled else { d.wasOff = true; return }
            var v1 = v
            if case .graphicEQ(let x) = end.stage { v1 = x }
            d.process(buf, channels: chs, frames: n, from: v, to: v1, sampleRate: Double(Self.sampleRate))
        case (.chorus(let d), .chorus(let rate, let depth, let mix)):
            guard step.enabled else { d.wasOff = true; return }
            var m1 = mix
            if case .chorus(_, _, let x) = end.stage { m1 = x }
            d.process(buf, channels: chs, frames: n, rateHz: rate, depthMs: depth, mixFrom: mix, to: m1)
        case (.leveler(let d), .dialogueLeveler(let v)):
            guard step.enabled else { d.wasOff = true; return }
            d.process(buf, channels: chs, frames: n, values: v)
        case (.enhance(let e), .enhanceSpeech(let v)):
            var v1 = v
            if case .enhanceSpeech(let x) = end.stage { v1 = x }
            e.process(buf, channels: chs, frames: n, from: v, to: v1, enabled: step.enabled)
        case (.pitchShift(let p), .pitchShift(let semitones, let preserve)):
            var to = semitones
            if case .pitchShift(let s1, _) = end.stage { to = s1 }
            p.process(buf, channels: chs, frames: n, from: semitones, to: to, preserveFormants: preserve, enabled: step.enabled)
        case (.disguiseVoice(let d), .disguiseVoice(let voice, let at)):
            d.process(buf, channels: chs, frames: n, voice: voice, at: at, enabled: step.enabled)
        default: return
        }
    }

    /// Array convenience (tests, offline): `buf[c]` all the same length, at most `maxFrames`.
    public func process(_ buf: inout [[Float]], steps: [AudioFXStep], endSteps: [AudioFXStep]? = nil) {
        let n = buf.first?.count ?? 0
        guard n > 0 else { return }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        defer { ptrs.deallocate() }
        for c in 0..<channelCount {
            ptrs[c] = .allocate(capacity: n)
            ptrs[c].initialize(from: buf[min(c, buf.count - 1)], count: n)
        }
        process(ptrs, frameCount: n, steps: steps, endSteps: endSteps)
        for c in 0..<min(channelCount, buf.count) { buf[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n)) }
        for c in 0..<channelCount { ptrs[c].deallocate() }
    }

    /// Linear gain ramp from `fromDB` (first sample) towards `toDB` (one block later).
    static func ramp(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels: Int, frames n: Int, fromDB: Double, toDB: Double) {
        let g0 = Float(GainMath.linear(fromDB: fromDB)), g1 = Float(GainMath.linear(fromDB: toDB))
        if g0 == 1 && g1 == 1 { return }
        let step = (g1 - g0) / Float(n)
        for c in 0..<channels {
            let p = buf[c]
            if g0 == g1 { for i in 0..<n { p[i] *= g0 } } else { for i in 0..<n { p[i] *= g0 + step * Float(i) } }
        }
    }

    // MARK: stages

    private enum Stage {
        case denoise(Denoise)
        case eq(EQ)
        case compressor(Compressor)
        case deEsser(DeEsserStage)
        case deReverb(DeReverbStage)
        case pitchShift(PitchShiftStage)
        case disguiseVoice(DisguiseVoiceStage)
        case gain
        case limiter(LimiterStage)
        case parametricEQ(ParametricEQStage)
        case multiband(MultibandStage)
        case gate(NoiseGateStage)
        case delay(DelayStage)
        case reverb(ReverbStage)
        case deHum(DeHumStage)
        case lowCut(LowCutStage)
        case leveler(DialogueLevelerStage)
        case enhance(EnhanceSpeechStage)
        case highCut(HighCutStage)
        case stereoWidth(StereoWidthStage)
        case chorus(ChorusStage)
        case notch(NotchStage)
        case graphicEQ(GraphicEQStage)
        case none
    }

    /// RNNoise per channel; the dry path is delayed by the same frame so the mix never shifts.
    /// Also the denoiser inside Enhance Speech.
    final class Denoise {
        struct Channel {
            var state: OpaquePointer
            var inFrame: UnsafeMutablePointer<Float>
            var wet: UnsafeMutablePointer<Float>
            var dry: UnsafeMutablePointer<Float>
            var pos = 0
        }
        var channels: [Channel] = []
        init(channels n: Int) {
            _ = RealtimeAudioFX.rnnoiseGlobalInit
            let f = RNNoiseDenoiser.frameSize
            for _ in 0..<n {
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: 3 * f)
                buf.initialize(repeating: 0, count: 3 * f)
                channels.append(Channel(state: rnnoise_create(nil)!, inFrame: buf, wet: buf + f, dry: buf + 2 * f))
            }
        }
        func free() {
            for c in channels { rnnoise_destroy(c.state); c.inFrame.deallocate() }
            channels = []
        }
        func reset() {
            let f = RNNoiseDenoiser.frameSize
            for i in channels.indices {
                rnnoise_reset(channels[i].state)
                channels[i].inFrame.update(repeating: 0, count: 3 * f)
                channels[i].pos = 0
            }
        }
        /// Wet/dry `m0` at the first sample moving linearly towards `m1` one block later.
        func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                     mixFrom m0: Float, to m1: Float) {
            let f = RNNoiseDenoiser.frameSize
            let scale: Float = 32768, inv: Float = 1 / 32768
            let dm = (m1 - m0) / Float(n)
            for c in 0..<min(chs, channels.count) {
                let p = buf[c]
                var pos = channels[c].pos
                let inF = channels[c].inFrame, wet = channels[c].wet, dry = channels[c].dry
                for i in 0..<n {
                    let mix = m0 + dm * Float(i)
                    inF[pos] = p[i] * scale
                    p[i] = (wet[pos] * mix + dry[pos] * (1 - mix)) * inv
                    pos += 1
                    if pos == f {
                        _ = rnnoise_process_frame(channels[c].state, wet, inF)
                        dry.update(from: inF, count: f)
                        pos = 0
                    }
                }
                channels[c].pos = pos
            }
        }
    }

    /// Low shelf, peak, high shelf (RBJ cookbook, shelf slope 1). Coefficients follow the values, filter memory stays.
    private final class EQ {
        struct Coef: Equatable { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }
        struct Mem { var z1 = 0.0, z2 = 0.0 }
        var low = Coef(), mid = Coef(), high = Coef()
        let mem: UnsafeMutablePointer<Mem>
        let channels: Int
        var values: AudioEQValues?
        var wasOff = false
        init(channels: Int) {
            self.channels = channels
            mem = .allocate(capacity: channels * 3)
            mem.initialize(repeating: Mem(), count: channels * 3)
        }
        deinit { mem.deallocate() }
        func reset() { mem.update(repeating: Mem(), count: channels * 3) }

        private func set(_ v: AudioEQValues, fs: Double) {
            guard values != v else { return }
            values = v
            low = Self.shelf(low: true, hz: v.lowHz, gainDB: v.lowGainDB, fs: fs)
            mid = Self.peak(hz: v.midHz, gainDB: v.midGainDB, q: v.midQ, fs: fs)
            high = Self.shelf(low: false, hz: v.highHz, gainDB: v.highGainDB, fs: fs)
        }

        /// Values `v0` at the first sample moving linearly towards `v1` one block later (coefficients every `rampChunk`).
        func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                     from v0: AudioEQValues, to v1: AudioEQValues, sampleRate fs: Double) {
            if wasOff { reset(); wasOff = false }
            if v0 == v1 { set(v0, fs: fs); run(buf, chs, 0, n); return }
            var s = 0
            while s < n {
                let k = min(ClipAudioFXChain.rampChunk, n - s)
                let t = Double(s) / Double(n)
                func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
                set(AudioEQValues(lowGainDB: l(v0.lowGainDB, v1.lowGainDB), lowHz: l(v0.lowHz, v1.lowHz),
                                  midGainDB: l(v0.midGainDB, v1.midGainDB), midHz: l(v0.midHz, v1.midHz), midQ: l(v0.midQ, v1.midQ),
                                  highGainDB: l(v0.highGainDB, v1.highGainDB), highHz: l(v0.highHz, v1.highHz)), fs: fs)
                run(buf, chs, s, k)
                s += k
            }
        }

        private func run(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ chs: Int, _ from: Int, _ n: Int) {
            guard let v = values else { return }
            for c in 0..<min(chs, channels) {
                let p = buf[c] + from
                for k in 0..<3 {
                    // A band at 0 dB is the identity (b == a): skipped once its memory is empty. A band coming back to 0 dB
                    // keeps running until its memory has drained through the identity (2 samples), never cut (no click).
                    let gain = k == 0 ? v.lowGainDB : k == 1 ? v.midGainDB : v.highGainDB
                    var m = mem[c * 3 + k]
                    if gain == 0 && m.z1 == 0 && m.z2 == 0 { continue }
                    let q = k == 0 ? low : k == 1 ? mid : high
                    for i in 0..<n {
                        let x = Double(p[i])
                        let y = q.b0 * x + m.z1
                        m.z1 = q.b1 * x - q.a1 * y + m.z2
                        m.z2 = q.b2 * x - q.a2 * y
                        p[i] = Float(y)
                    }
                    // At 0 dB the memory is only rounding noise once the input has passed through: drop it.
                    if gain == 0 && abs(m.z1) < 1e-9 && abs(m.z2) < 1e-9 { m = Mem() }
                    mem[c * 3 + k] = m
                }
            }
        }

        static func shelf(low: Bool, hz: Double, gainDB: Double, fs: Double) -> Coef {
            let a = pow(10, gainDB / 40), w = 2 * Double.pi * min(max(hz, 10), fs * 0.45) / fs
            let cw = cos(w), alpha = sin(w) / 2 * 2.0.squareRoot(), sa = 2 * a.squareRoot() * alpha
            let b0, b1, b2, a0, a1, a2: Double
            if low {
                b0 = a * ((a + 1) - (a - 1) * cw + sa); b1 = 2 * a * ((a - 1) - (a + 1) * cw); b2 = a * ((a + 1) - (a - 1) * cw - sa)
                a0 = (a + 1) + (a - 1) * cw + sa; a1 = -2 * ((a - 1) + (a + 1) * cw); a2 = (a + 1) + (a - 1) * cw - sa
            } else {
                b0 = a * ((a + 1) + (a - 1) * cw + sa); b1 = -2 * a * ((a - 1) + (a + 1) * cw); b2 = a * ((a + 1) + (a - 1) * cw - sa)
                a0 = (a + 1) - (a - 1) * cw + sa; a1 = 2 * ((a - 1) - (a + 1) * cw); a2 = (a + 1) - (a - 1) * cw - sa
            }
            return Coef(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }

        static func peak(hz: Double, gainDB: Double, q: Double, fs: Double) -> Coef {
            let a = pow(10, gainDB / 40), w = 2 * Double.pi * min(max(hz, 10), fs * 0.45) / fs
            let alpha = sin(w) / (2 * max(q, 0.01)), cw = cos(w)
            let a0 = 1 + alpha / a
            return Coef(b0: (1 + alpha * a) / a0, b1: -2 * cw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cw / a0, a2: (1 - alpha / a) / a0)
        }
    }

    /// Single-band, stereo-linked peak compressor on the 4-band compressor's detector and smoothing.
    private final class Compressor {
        var band = MultibandCompressor.BandState()
        let hold: Double
        let fs: Double
        var wasOff = false
        init(sampleRate: Double) { fs = sampleRate; hold = exp(-1 / (0.01 * sampleRate)) }
        func reset() { band.env = 0; band.gr = 0 }
        /// Threshold, ratio and makeup (dB, :1, dB) move from `a` to `b` across the block (every `rampChunk` samples).
        func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                     from a: (Double, Double, Double), to b: (Double, Double, Double), attackMs: Double, releaseMs: Double) {
            if wasOff { reset(); wasOff = false }
            band.hold = hold
            band.attack = exp(-1 / (max(0.0001, attackMs / 1000) * fs))
            band.release = exp(-1 / (max(0.0001, releaseMs / 1000) * fs))
            let ramped = a != b
            var s = 0
            while s < n {
                let k = ramped ? min(ClipAudioFXChain.rampChunk, n - s) : n
                let t = Double(s) / Double(n)
                func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
                band.threshold = pow(10, l(a.0, b.0) / 20)
                band.slope = 1 - 1 / max(1, l(a.1, b.1))
                band.gain = GainMath.linear(fromDB: l(a.2, b.2))
                for i in s..<(s + k) {
                    var peak = 0.0
                    for c in 0..<chs { peak = max(peak, Double(abs(buf[c][i]))) }
                    let g = band.step(peak: peak)
                    for c in 0..<chs { buf[c][i] = Float(Double(buf[c][i]) * g) }
                }
                s += k
            }
        }
    }

    private final class DeEsserStage {
        var d: DeEsser
        var wasOff = false
        init(sampleRate: Int, channels: Int) { d = DeEsser(sampleRate: sampleRate, channelCount: channels) }
        func reset() { d.reset() }
        private var key: [Double] = []
        /// Frequency, range and speed only touch the filters when they changed (the 7 kHz / Wide / Medium defaults are the init's).
        func setTarget(frequencyHz: Double, range: Int, speed: Int, listen: Bool) {
            d.listen = listen
            let k = [frequencyHz, Double(range), Double(speed)]
            guard k != key else { return }
            if key.isEmpty && k == [7_000, 1, 1] { key = k; return }
            if key.isEmpty || key[0] != k[0] || key[1] != k[1] { d.configure(centerHz: frequencyHz, range: range) }
            if key.isEmpty || key[2] != k[2] { d.setSpeed(speed) }
            key = k
        }
        /// Reduction (dB) and sensitivity (0...1) move from `a` to `b` across the block (every `rampChunk` samples).
        func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                     from a: (Double, Double), to b: (Double, Double)) {
            if wasOff { d.reset(); wasOff = false }
            var s = 0
            while s < n {
                let k = a == b ? n - s : min(ClipAudioFXChain.rampChunk, n - s)
                let t = Double(s) / Double(n)
                let red = a.0 + (b.0 - a.0) * t, sens = a.1 + (b.1 - a.1) * t
                d.minGain = GainMath.linear(fromDB: -abs(red))
                // Sensitivity 50 % = the voice chain's 0.35 (sibilance 9 dB under broadband); 100 % reacts at 0.1, 0 % at 0.6.
                d.ratioThreshold = 0.6 - 0.5 * min(1, max(0, sens))
                if s == 0 && k == n { d.process(buf, channelCount: chs, frames: n) } else {
                    var ptrs = (0..<chs).map { buf[$0] + s }
                    ptrs.withUnsafeMutableBufferPointer { d.process($0.baseAddress!, channelCount: chs, frames: k) }
                }
                s += k
            }
        }
    }

    /// Stereo-linked on channels 0 and 1 (mono: channel 0 alone); further channels pass.
    private final class LimiterStage {
        var lim: MasterLimiter
        let mono: UnsafeMutablePointer<Float>
        var wasOff = false
        init(sampleRate: Int, maxFrames: Int) {
            lim = MasterLimiter(sampleRate: sampleRate, ceilingDB: -1)
            mono = .allocate(capacity: max(1, maxFrames))
            mono.initialize(repeating: 0, count: max(1, maxFrames))
        }
        deinit { mono.deallocate() }
        func reset() { lim.reset() }
        /// The ceiling moves from `c0` to `c1` across the block (every `rampChunk` samples).
        func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                     ceilingFrom c0: Double, to c1: Double) {
            if wasOff { lim.reset(); wasOff = false }
            var s = 0
            while s < n {
                let k = c0 == c1 ? n - s : min(ClipAudioFXChain.rampChunk, n - s)
                let c = c0 + (c1 - c0) * Double(s) / Double(n)
                if lim.ceilingDB != c { lim = lim.withCeiling(dB: c) }
                if chs >= 2 {
                    lim.process(left: buf[0] + s, right: buf[1] + s, count: k)
                } else {
                    mono.update(from: buf[0] + s, count: k)
                    lim.process(left: buf[0] + s, right: mono, count: k)
                }
                s += k
            }
        }
    }
}
