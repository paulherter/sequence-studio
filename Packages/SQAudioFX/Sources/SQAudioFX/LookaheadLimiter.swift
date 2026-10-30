import Foundation

/// Stereo-linked look-ahead brickwall limiter (the Multiband Compressor's output limiter).
///
/// The signal is delayed by `lookahead` samples; the gain that every sample needs (`ceiling / peak`) is known that much
/// earlier, so the gain can fall smoothly *before* a peak arrives instead of clipping it. Gain path per sample:
/// sliding minimum of the needed gain over `lookahead + 1` samples, then release (one-pole back up, instant down), then a
/// moving average over `attack` samples (`attack <= lookahead`). Because every value in the average window already
/// includes the peak that leaves the delay line now, the applied gain is never above what that peak needs: the ceiling
/// holds by construction, without a hard clip. A final clamp at the ceiling catches Float rounding and the first
/// `lookahead` samples after the limiter is switched on (they were already in the delay line). It applies to every sample
/// that entered or leaves while the limiter is active, so switching it off (or `delayOnly`) never lets the driven samples
/// still in the line through.
///
/// Latency: exactly `lookahead` samples, always (also while `active` is false), so a chain's latency never changes.
/// Realtime-safe: all memory is allocated in `init`; `process` never allocates or locks. Not thread-safe.
final class LookaheadLimiter {
    let lookahead: Int
    let channels: Int
    private(set) var ceilingDB = Double.nan
    private var ceiling = 1.0
    private var ceilingF: Float = 1
    private(set) var releaseMs = Double.nan
    private var releaseCoef = 0.0
    private(set) var attackSamples = 1
    /// Current applied gain (1 = no reduction).
    private(set) var gain = 1.0

    private let delay: UnsafeMutablePointer<Float>          // channels x lookahead ring
    private var dPos = 0
    // Sliding minimum: monotonic deque of (sample index, needed gain), ring of lookahead + 2.
    private let dqIdx: UnsafeMutablePointer<Int>
    private let dqVal: UnsafeMutablePointer<Double>
    private let dqCap: Int
    private var dqHead = 0, dqCount = 0
    private var index = 0
    /// Samples that entered at an index below this were taken in while the limiter was active (they stay clamped).
    private var activeEnd = Int.min
    private var released = 1.0
    // Moving average of `released` over `attackSamples`.
    private let box: UnsafeMutablePointer<Double>
    private var bPos = 0, bSum = 0.0

    init(sampleRate: Double, channels: Int, lookaheadMs: Double = 5, ceilingDB: Double = -0.1, releaseMs: Double = 500, attackMs: Double = 5) {
        self.channels = max(1, channels)
        lookahead = max(1, Int((sampleRate * lookaheadMs / 1000).rounded()))
        delay = .allocate(capacity: self.channels * lookahead)
        delay.initialize(repeating: 0, count: self.channels * lookahead)
        dqCap = lookahead + 2
        dqIdx = .allocate(capacity: dqCap); dqIdx.initialize(repeating: 0, count: dqCap)
        dqVal = .allocate(capacity: dqCap); dqVal.initialize(repeating: 1, count: dqCap)
        box = .allocate(capacity: lookahead); box.initialize(repeating: 1, count: lookahead)
        self.sampleRate = sampleRate
        configure(ceilingDB: ceilingDB, releaseMs: releaseMs, attackMs: attackMs)
        reset()
    }
    private let sampleRate: Double

    deinit { delay.deallocate(); dqIdx.deallocate(); dqVal.deallocate(); box.deallocate() }

    /// Gain reduction now, in dB (0 or negative).
    var gainReductionDB: Double { gain >= 1 ? 0 : GainMath.dB(fromLinear: gain) }

    /// Empties the delay line and the gain history. Allocation-free.
    func reset() {
        delay.update(repeating: 0, count: channels * lookahead)
        dPos = 0; dqHead = 0; dqCount = 0; index = 0; activeEnd = Int.min
        released = 1; gain = 1
        box.update(repeating: 1, count: lookahead)
        bPos = 0; bSum = Double(attackSamples)
    }

    /// Ceiling (dB, <= 0), release (ms) and attack (ms, clamped to 1 sample...lookahead). Keeps the gain state: a changed
    /// value never jumps. Allocation-free.
    func configure(ceilingDB c: Double, releaseMs r: Double, attackMs a: Double) {
        if !(c == ceilingDB) {
            ceilingDB = c
            let exact = GainMath.linear(fromDB: c)
            var f = Float(exact)
            if Double(f) > exact { f = f.nextDown }
            ceilingF = f; ceiling = Double(f)
        }
        if !(r == releaseMs) {
            releaseMs = r
            releaseCoef = exp(-1 / max(1, sampleRate * r / 1000))
        }
        let atk = min(lookahead, max(1, Int((sampleRate * (a.isNaN ? 0 : a) / 1000).rounded())))
        if atk != attackSamples {
            // Refill the average at the current gain: no jump, and the ceiling clamp covers the switch.
            attackSamples = atk
            box.update(repeating: gain, count: lookahead)
            bPos = 0; bSum = gain * Double(atk)
        }
    }

    /// In place on `chs` channels (all linked). `active` false: the needed gain is 1 (the gain releases back to unity), the
    /// delay stays.
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, active: Bool = true) {
        let c = min(chs, channels), L = lookahead, A = attackSamples
        let ceil = ceiling, cf = ceilingF, rc = releaseCoef
        var r = released, g = gain, sum = bSum, bp = bPos, dp = dPos
        var head = dqHead, count = dqCount, idx = index, ae = activeEnd
        for i in 0..<n {
            var peak: Float = 0
            for ch in 0..<c { peak = max(peak, abs(buf[ch][i])) }
            let need = active && Double(peak) > ceil ? ceil / Double(peak) : 1
            // Sliding minimum over [idx - L, idx].
            while count > 0 {
                let back = (head + count - 1) % dqCap
                if dqVal[back] >= need { count -= 1 } else { break }
            }
            let slot = (head + count) % dqCap
            dqIdx[slot] = idx; dqVal[slot] = need; count += 1
            while dqIdx[head] < idx - L { head = (head + 1) % dqCap; count -= 1 }
            let h = dqVal[head]
            r = h < r ? h : h + (r - h) * rc
            if h >= 1 && r > 0.999_999_9 { r = 1 }             // snap to unity only when nothing in the window needs less
            if active { ae = idx + 1 }
            let clamp = active || idx - L < ae                  // the sample leaving now entered at idx - L
            sum += r - box[bp]; box[bp] = r
            bp += 1; if bp == A { bp = 0 }
            g = min(1, sum / Double(A))
            for ch in 0..<c {
                let line = delay + ch * L
                let x = buf[ch][i]
                let y = line[dp]
                line[dp] = x
                let o = g >= 1 ? y : Float(Double(y) * g)
                buf[ch][i] = clamp ? min(max(o, -cf), cf) : o
            }
            dp += 1; if dp == L { dp = 0 }
            idx += 1
        }
        // Re-sum the window once per block so rounding in the running sum cannot drift.
        var s = 0.0
        for k in 0..<A { s += box[k] }
        bSum = s
        released = r; gain = g; bPos = bp; dPos = dp; dqHead = head; dqCount = count; index = idx; activeEnd = ae
    }

    /// A disabled stage: keeps the latency. Runs the gain path with nothing needing reduction, so the samples still in the
    /// line from the active limiter leave limited and clamped, and the gain releases smoothly to unity (no click, no
    /// overshoot); after that the output is the plain delayed input.
    func delayOnly(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int) {
        process(buf, channels: chs, frames: n, active: false)
    }
}
