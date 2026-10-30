import Foundation
import SQCore

// Graphic EQ: ten RBJ peaking biquads at fixed octave centers (constant Q 1.41, the Parametric EQ's `PEQBiquad.peak`), then
// the output gain. A band at exactly 0 dB is skipped once its memory is empty (it rings out first); all bands and the output at 0 dB leave the
// buffer untouched (bit exact). Gains move from the block's first sample to the next block's in steps of `rampChunk`
// samples (coefficients from the interpolated gains), so a sweep does not click. Zero latency; no allocation in `process`.

final class GraphicEQStage {
    private static let n = 10
    private let channels: Int
    private let coefs: UnsafeMutablePointer<PEQBiquad.Coef>      // n
    private let gains: UnsafeMutablePointer<Double>              // n, the dB the coefficients were made for
    private let mem: UnsafeMutablePointer<PEQBiquad.Mem>         // channels * n
    private let centers: UnsafeMutablePointer<Double>
    var wasOff = false

    init(channels: Int) {
        self.channels = channels
        coefs = .allocate(capacity: Self.n); coefs.initialize(repeating: PEQBiquad.Coef(), count: Self.n)
        gains = .allocate(capacity: Self.n); gains.initialize(repeating: 0, count: Self.n)
        centers = .allocate(capacity: Self.n)
        for i in 0..<Self.n { centers[i] = AudioGraphicEQValues.bandHz[i] }
        mem = .allocate(capacity: channels * Self.n); mem.initialize(repeating: PEQBiquad.Mem(), count: channels * Self.n)
    }
    deinit { coefs.deallocate(); gains.deallocate(); mem.deallocate(); centers.deallocate() }
    func reset() { mem.update(repeating: PEQBiquad.Mem(), count: channels * Self.n) }

    private static func clamp(_ g: Double) -> Double { g.isNaN ? 0 : min(max(g, -12), 12) }

    /// Gain of band `i` at position `t` (0...1) of the block.
    private static func at(_ a: AudioGraphicEQValues, _ b: AudioGraphicEQValues, _ i: Int, _ t: Double) -> Double {
        clamp(a[i] + (b[i] - a[i]) * t)
    }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from a: AudioGraphicEQValues, to b: AudioGraphicEQValues, sampleRate fs: Double) {
        if wasOff { reset(); wasOff = false }
        let outA = a.outputDB.isNaN ? 0 : min(max(a.outputDB, -24), 24), outB = b.outputDB.isNaN ? 0 : min(max(b.outputDB, -24), 24)
        var s = 0
        while s < n {
            let k = min(ClipAudioFXChain.rampChunk, n - s)
            // Static gains need no interpolation; a moving one is evaluated at the end of the chunk (complete when the block ends).
            let t = a == b ? 0.0 : Double(s + k) / Double(n)
            for i in 0..<Self.n {
                let g = Self.at(a, b, i, t)
                if g != gains[i] {
                    coefs[i] = PEQBiquad.peak(hz: centers[i], gainDB: g, q: AudioGraphicEQValues.q, fs: fs)
                    gains[i] = g
                }
            }
            run(buf, chs, s, k)
            s += k
        }
        GraphicEQStage.outputGain(buf, channels: min(chs, channels), frames: n, fromDB: outA, toDB: outB)
    }

    private func run(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ chs: Int, _ from: Int, _ n: Int) {
        for c in 0..<min(chs, channels) {
            let p = buf[c] + from
            for k in 0..<Self.n {
                // A band at 0 dB is the identity: skipped once its memory is empty (never cut while it still rings).
                let flat = gains[k] == 0
                var m = mem[c * Self.n + k]
                if flat && m.z1 == 0 && m.z2 == 0 { continue }
                let q = coefs[k]
                for i in 0..<n {
                    let x = Double(p[i])
                    let y = q.b0 * x + m.z1
                    m.z1 = q.b1 * x - q.a1 * y + m.z2
                    m.z2 = q.b2 * x - q.a2 * y
                    p[i] = Float(y)
                }
                if flat && abs(m.z1) < 1e-9 && abs(m.z2) < 1e-9 { m = PEQBiquad.Mem() }
                mem[c * Self.n + k] = m
            }
        }
    }

    private static func outputGain(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels: Int, frames n: Int,
                                   fromDB: Double, toDB: Double) {
        ClipAudioFXChain.ramp(buf, channels: channels, frames: n, fromDB: fromDB, toDB: toDB)
    }
}
