import Foundation

// Notch: one RBJ peak cut (gain = -depth) per channel, zero latency. Parameters move from the block's first sample to
// the next block's (`from` to `to`); the coefficients follow in steps of `subBlock` samples, computed from the swept
// parameters (never by interpolating coefficients), so every step is a stable biquad and a sweep does not click.
// With constant parameters the result does not depend on the block size.

final class NotchStage {
    private let fs: Double, channels: Int
    private static let subBlock = 16
    private var mem: [Double]
    private var coef = RepairBiquad()
    private var keyHz = -1.0, keyQ = -1.0, keyDepth = -1.0
    var wasOff = false

    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        mem = [Double](repeating: 0, count: channels * 2)
    }
    func reset() { for i in mem.indices { mem[i] = 0 } }

    private func design(_ hz: Double, _ q: Double, _ depthDB: Double) -> RepairBiquad {
        if hz != keyHz || q != keyQ || depthDB != keyDepth {
            keyHz = hz; keyQ = q; keyDepth = depthDB
            // `.peak` puts the poles at Q / A (A = 10^(-depth/40)); passing q / A keeps the -3 dB width at f / Q at any depth.
            let a = pow(10, -depthDB / 40)
            coef = .peak(hz: hz, gainDB: -depthDB, q: q / a, fs: fs)
        }
        return coef
    }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from a: (hz: Double, q: Double, depthDB: Double), to b: (hz: Double, q: Double, depthDB: Double)) {
        if wasOff { reset(); wasOff = false }
        let d0 = min(max(a.depthDB, 0), 80), d1 = min(max(b.depthDB, 0), 80)
        // Neutral depth: bypass, bit exact.
        if d0 < 0.01 && d1 < 0.01 { reset(); return }
        let f0 = min(max(a.hz, 20), 20_000), f1 = min(max(b.hz, 20), 20_000)
        let q0 = min(max(a.q, 0.1), 100), q1 = min(max(b.q, 0.1), 100)
        let moving = f0 != f1 || q0 != q1 || d0 != d1
        let chCount = min(chs, channels)
        var pos = 0
        while pos < n {
            let len = min(Self.subBlock, n - pos)
            var f = f0, q = q0, d = d0
            if moving {
                // Parameters at the middle of this step; frequency moves on a log scale.
                let t = (Double(pos) + Double(len) / 2) / Double(n)
                f = f0 * pow(f1 / f0, t); q = q0 + (q1 - q0) * t; d = d0 + (d1 - d0) * t
            }
            let c = design(f, q, d)
            for ch in 0..<chCount {
                let p = buf[ch]
                let m = ch * 2
                var s1 = mem[m], s2 = mem[m + 1]
                for i in pos..<(pos + len) {
                    let x = Double(p[i])
                    let o = c.b0 * x + s1
                    s1 = c.b1 * x - c.a1 * o + s2
                    s2 = c.b2 * x - c.a2 * o
                    p[i] = Float(o)
                }
                mem[m] = s1; mem[m + 1] = s2
            }
            pos += len
        }
    }
}
