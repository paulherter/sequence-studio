import Foundation
import SQCore

/// Enhance Speech: one stage that runs the existing repair blocks as one recipe (`AudioEnhanceSpeechValues.recipe`):
/// Low Cut (Butterworth, 24 dB/oct) -> Noise Reduction (RNNoise wet/dry, the chain's `Denoise`) -> De-Reverb
/// (`DeReverbStage`) -> dialogue EQ (mud cut, presence, air peaks) -> Dialogue Leveler (`DialogueLevelerStage`, depth = recipe).
///
/// Real-time safe: every buffer is allocated in `init`, coefficients are rewritten in place, `process` never allocates.
/// Delay: exactly `AudioEnhanceSpeechValues.latencySamples` (RNNoise frame + De-Reverb window), also while off or at 0 %.
/// Disabled = the delay only (denoiser at 0 % mix, De-Reverb at 0 %, filters and leveler skipped).
final class EnhanceSpeechStage {
    private static let sections = 5                 // 2 high-pass biquads + 3 EQ peaks
    private let fs: Double, channels: Int
    private let denoise: ClipAudioFXChain.Denoise
    private let dereverb: DeReverbStage
    private let leveler: DialogueLevelerStage
    private var bank = [RepairBiquad](repeating: RepairBiquad(), count: EnhanceSpeechStage.sections)
    private var mem: [Double]
    private var recipe: AudioEnhanceSpeechValues.Recipe?
    private var wasOff = false

    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        denoise = ClipAudioFXChain.Denoise(channels: channels)
        dereverb = DeReverbStage(sampleRate: sampleRate, channels: channels)
        leveler = DialogueLevelerStage(sampleRate: sampleRate)
        mem = [Double](repeating: 0, count: channels * Self.sections * 2)
    }

    func free() { denoise.free() }

    func reset() {
        denoise.reset(); dereverb.reset(); leveler.reset()
        for i in mem.indices { mem[i] = 0 }
    }

    /// Coefficients for `r`, written in place (no allocation).
    private func set(_ r: AudioEnhanceSpeechValues.Recipe) {
        guard recipe != r else { return }
        recipe = r
        typealias R = AudioEnhanceSpeechValues.Recipe
        // 4th-order Butterworth high-pass as two biquads (pole pair Qs 0.541, 1.307).
        for i in 0..<2 {
            let q = 1 / (2 * cos(Double.pi * Double(2 * i + 1) / 8))
            bank[i] = .highPass(hz: r.lowCutHz, q: q, fs: fs)
        }
        bank[2] = .peak(hz: R.mudHz, gainDB: r.mudDB, q: R.mudQ, fs: fs)
        bank[3] = .peak(hz: R.presenceHz, gainDB: r.presenceDB, q: R.presenceQ, fs: fs)
        bank[4] = .peak(hz: R.airHz, gainDB: r.airDB, q: R.airQ, fs: fs)
    }

    /// Runs sections `range` of the bank over the block, per channel (direct form II transposed).
    private func filter(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, _ range: Range<Int>) {
        for c in 0..<min(chs, channels) {
            let p = buf[c]
            for s in range {
                let f = bank[s], m = (c * Self.sections + s) * 2
                var z1 = mem[m], z2 = mem[m + 1]
                for i in 0..<n {
                    let x = Double(p[i])
                    let y = f.b0 * x + z1
                    z1 = f.b1 * x - f.a1 * y + z2
                    z2 = f.b2 * x - f.a2 * y
                    p[i] = Float(y)
                }
                mem[m] = z1; mem[m + 1] = z2
            }
        }
    }

    /// Only the Low Cut and the dialogue EQ of `r` (no denoiser, De-Reverb or leveler, no delay): the filter curve in tests.
    func filtersOnly(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, recipe r: AudioEnhanceSpeechValues.Recipe) {
        set(r)
        filter(buf, channels: chs, frames: n, 0..<Self.sections)
    }

    /// `v0` at the first sample, `v1` one block later: the denoiser mix ramps across the block, the rest follows `v0`
    /// (filters and De-Reverb change per block, which is inaudible for automation speeds).
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from v0: AudioEnhanceSpeechValues, to v1: AudioEnhanceSpeechValues, enabled: Bool) {
        guard enabled else {
            wasOff = true
            denoise.process(buf, channels: chs, frames: n, mixFrom: 0, to: 0)
            dereverb.process(buf, channels: chs, frames: n, amount: 0, decay: 0.6, tone: 0, enabled: false)
            return
        }
        if wasOff {
            wasOff = false
            leveler.reset()
            for i in mem.indices { mem[i] = 0 }
        }
        let r = v0.recipe, r1 = v1.recipe
        set(r)
        filter(buf, channels: chs, frames: n, 0..<2)
        denoise.process(buf, channels: chs, frames: n, mixFrom: Float(r.denoise), to: Float(r1.denoise))
        dereverb.process(buf, channels: chs, frames: n, amount: r.dereverb, decay: r.decaySeconds, tone: 0, enabled: true)
        filter(buf, channels: chs, frames: n, 2..<5)
        if r.leveling > 0 {
            leveler.process(buf, channels: chs, frames: n,
                            values: AudioLevelerValues(preset: AudioEnhanceSpeechValues.levelerPreset, reduceLoud: true, liftSoft: true,
                                                       background: false, outputGainDB: 0),
                            depth: r.leveling)
        }
    }
}
