import Foundation
import SQCore

// Audio repair stages of the per-clip chain: De-Hum, Low Cut, Dialogue Leveler. Plain DSP, state preallocated, `process`
// never allocates, zero latency.

/// One RBJ biquad (direct form II transposed) per channel.
struct RepairBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    static func peak(hz: Double, gainDB: Double, q: Double, fs: Double) -> RepairBiquad {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * min(max(hz, 5), fs * 0.45) / fs
        let alpha = sin(w) / (2 * max(q, 0.1)), cw = cos(w), a0 = 1 + alpha / a
        return RepairBiquad(b0: (1 + alpha * a) / a0, b1: -2 * cw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cw / a0, a2: (1 - alpha / a) / a0)
    }
    static func lowPass(hz: Double, q: Double, fs: Double) -> RepairBiquad {
        let w = 2 * Double.pi * min(max(hz, 5), fs * 0.45) / fs
        let alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return RepairBiquad(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0, a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }
    static func highPass(hz: Double, q: Double, fs: Double) -> RepairBiquad {
        let w = 2 * Double.pi * min(max(hz, 5), fs * 0.45) / fs
        let alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
        return RepairBiquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0, a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }
}

/// Notch bank (RBJ peak cuts) at the root and its harmonics. Harmonic k (0 = root) gets `gain x weight(k)`: slope 0.5 = equal,
/// 0 = root only, 1 = deeper towards the higher partials (clamped to -80 dB). Listen = the removed part only.
final class DeHumStage {
    private let fs: Double, channels: Int
    private var bank: [RepairBiquad] = []
    private var mem: [Double]
    private var key: [Double] = []
    var wasOff = false
    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        mem = [Double](repeating: 0, count: channels * 8 * 2)
    }
    func reset() { for i in mem.indices { mem[i] = 0 } }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 frequencyHz: Double, q: Double, gainDB: Double, harmonics: Int, slope: Double, listen: Bool) {
        if wasOff { reset(); wasOff = false }
        let k = [frequencyHz, q, gainDB, Double(harmonics), slope]
        if k != key {
            key = k
            bank.removeAll(keepingCapacity: true)
            let count = min(8, max(1, harmonics))
            for h in 0..<count {
                let hz = frequencyHz * Double(h + 1)
                if hz >= fs * 0.45 { break }
                let t = count > 1 ? Double(h) / Double(count - 1) : 0
                let w = max(0, 1 + (2 * slope - 1) * t)
                bank.append(.peak(hz: hz, gainDB: max(-80, gainDB * w), q: q, fs: fs))
            }
        }
        for c in 0..<min(chs, channels) {
            let p = buf[c]
            for i in 0..<n {
                let x = Double(p[i]); var y = x
                for (b, f) in bank.enumerated() {
                    let m = (c * 8 + b) * 2
                    let o = f.b0 * y + mem[m]
                    mem[m] = f.b1 * y - f.a1 * o + mem[m + 1]
                    mem[m + 1] = f.b2 * y - f.a2 * o
                    y = o
                }
                p[i] = Float(listen ? x - y : y)
            }
        }
    }
}

/// Butterworth high-pass, order 1...3 biquads (12, 24, 48 dB/oct).
final class LowCutStage {
    private let fs: Double, channels: Int
    private var bank = [RepairBiquad](repeating: RepairBiquad(), count: 4)
    private var active = 0, keyHz = -1.0, keySections = 0
    private var mem: [Double]
    var wasOff = false
    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        mem = [Double](repeating: 0, count: channels * 4 * 2)
    }
    func reset() { for i in mem.indices { mem[i] = 0 } }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, frequencyHz: Double, order: Int) {
        if wasOff { reset(); wasOff = false }
        let sections = min(4, max(1, order == 3 ? 4 : order == 2 ? 2 : 1))
        if frequencyHz != keyHz || sections != keySections {
            keyHz = frequencyHz; keySections = sections; active = sections
            for i in 0..<sections {
                // Butterworth pole pairs of a 2*sections order filter.
                let q = 1 / (2 * cos(Double.pi * (Double(2 * i + 1)) / Double(4 * sections)))
                bank[i] = .highPass(hz: frequencyHz, q: q, fs: fs)
            }
        }
        for c in 0..<min(chs, channels) {
            let p = buf[c]
            for i in 0..<n {
                var y = Double(p[i])
                for b in 0..<active {
                    let f = bank[b]
                    let m = (c * 4 + b) * 2
                    let o = f.b0 * y + mem[m]
                    mem[m] = f.b1 * y - f.a1 * o + mem[m + 1]
                    mem[m + 1] = f.b2 * y - f.a2 * o
                    y = o
                }
                p[i] = Float(y)
            }
        }
    }
}

/// Butterworth low-pass, order 1...3 biquads (12, 24, 48 dB/oct): `LowCutStage`'s counterpart.
final class HighCutStage {
    private let fs: Double, channels: Int
    private var bank = [RepairBiquad](repeating: RepairBiquad(), count: 4)
    private var active = 0, keyHz = -1.0, keySections = 0
    private var mem: [Double]
    var wasOff = false
    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        mem = [Double](repeating: 0, count: channels * 4 * 2)
    }
    func reset() { for i in mem.indices { mem[i] = 0 } }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, frequencyHz: Double, order: Int) {
        if wasOff { reset(); wasOff = false }
        let sections = min(4, max(1, order == 3 ? 4 : order == 2 ? 2 : 1))
        if frequencyHz != keyHz || sections != keySections {
            keyHz = frequencyHz; keySections = sections; active = sections
            for i in 0..<sections {
                let q = 1 / (2 * cos(Double.pi * (Double(2 * i + 1)) / Double(4 * sections)))
                bank[i] = .lowPass(hz: frequencyHz, q: q, fs: fs)
            }
        }
        for c in 0..<min(chs, channels) {
            let p = buf[c]
            for i in 0..<n {
                var y = Double(p[i])
                for b in 0..<active {
                    let f = bank[b]
                    let m = (c * 4 + b) * 2
                    let o = f.b0 * y + mem[m]
                    mem[m] = f.b1 * y - f.a1 * o + mem[m + 1]
                    mem[m + 1] = f.b2 * y - f.a2 * o
                    y = o
                }
                p[i] = Float(y)
            }
        }
    }
}

/// Dialogue Leveler: a slow gain ride on the stereo-linked level (RMS, 150 ms). Gain = strength x (target - level), limited
/// to the preset's range, smoothed (400 ms to go up, 120 ms to go down), and held (not lifted) when the level is under the
/// speech floor, so pauses and room noise are not pumped up. Background Reduction pulls the pauses down by up to 6 dB.
final class DialogueLevelerStage {
    private let fs: Double
    private var ms: Double = 0       // mean square
    private var gainDB: Double = 0
    private var bgDB: Double = 0
    private let msCoef: Double, upCoef: Double, downCoef: Double, bgCoef: Double
    var wasOff = false
    init(sampleRate: Double) {
        fs = sampleRate
        msCoef = exp(-1 / (0.150 * sampleRate)); upCoef = exp(-1 / (0.400 * sampleRate))
        downCoef = exp(-1 / (0.120 * sampleRate)); bgCoef = exp(-1 / (0.300 * sampleRate))
    }
    func reset() { ms = 0; gainDB = 0; bgDB = 0 }

    /// `depth` 0...1 scales the gain ride (Enhance Speech's Amount); 1 = the effect as set.
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, values v: AudioLevelerValues,
                 depth: Double = 1) {
        if wasOff { reset(); wasOff = false }
        let p = v.params
        let out = GainMath.linear(fromDB: v.outputGainDB)
        var ms = ms, gainDB = gainDB, bgDB = bgDB
        for i in 0..<n {
            var e = 0.0
            for c in 0..<chs { let s = Double(buf[c][i]); e = max(e, s * s) }
            ms = msCoef * ms + (1 - msCoef) * e
            let levelDB = 10 * log10(max(ms, 1e-12))
            if levelDB > p.floorDB {
                var target = p.strength * (p.targetDB - levelDB)
                target = min(max(target, -p.maxDownDB), p.maxUpDB)
                if !v.reduceLoud { target = max(target, 0) }
                if !v.liftSoft { target = min(target, 0) }
                let k = target > gainDB ? upCoef : downCoef
                gainDB = target + (gainDB - target) * k
            }
            let bgTarget = v.background && levelDB < p.floorDB ? -6.0 : 0
            bgDB = bgTarget + (bgDB - bgTarget) * bgCoef
            let g = Float(GainMath.linear(fromDB: (gainDB + bgDB) * depth) * out)
            for c in 0..<chs { buf[c][i] *= g }
        }
        self.ms = ms; self.gainDB = gainDB; self.bgDB = bgDB
    }
}
