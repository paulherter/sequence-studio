import Foundation

/// Stereo-linked master peak limiter at the sequence's true-peak ceiling (`DeliveryTarget.truePeakDB`).
///
/// Zero latency (no look-ahead), so the playback clock and export alignment do not change: the gain drops instantly to
/// exactly what the loudest channel needs (`ceiling / peak`), is held for `holdMs`, then recovers exponentially towards
/// unity with the `releaseMs` time constant. The sample peak of the output therefore never exceeds the ceiling; the
/// export's loudness pass still measures true peak and keeps its own ceiling. Below the ceiling the signal passes bit-exact.
///
/// Realtime-safe: a plain value, `process` never allocates or locks. One instance per mix thread.
public struct MasterLimiter: Sendable {
    public let sampleRate: Int
    public let ceilingDB: Double
    /// Linear ceiling, rounded down to the nearest Float so the Float output can never land above it.
    public let ceiling: Double
    private let ceilingF: Float
    private let holdSamples: Int
    private let releaseCoef: Double
    /// 0 = the gain drops at once (default). Above 0 the gain falls towards what the peak needs with this one-pole
    /// coefficient; what it has not caught yet is clipped at the ceiling, so the ceiling still holds (zero latency).
    private let attackCoef: Double
    /// Attack time (ms) the limiter was built with.
    public let attackMs: Double
    /// Current linear gain (1 = no reduction).
    public private(set) var gain = 1.0
    private var hold = 0

    public init(sampleRate: Int, ceilingDB: Double, releaseMs: Double = 100, holdMs: Double = 5, attackMs: Double = 0) {
        self.sampleRate = sampleRate
        self.ceilingDB = ceilingDB
        let exact = GainMath.linear(fromDB: ceilingDB)
        var f = Float(exact)
        if Double(f) > exact { f = f.nextDown }
        ceilingF = f
        ceiling = Double(f)
        holdSamples = max(0, Int((Double(sampleRate) * holdMs / 1000).rounded()))
        releaseCoef = exp(-1 / max(1, Double(sampleRate) * releaseMs / 1000))
        let atk = attackMs.isNaN ? 0 : max(0, attackMs)
        self.attackMs = atk
        attackCoef = atk > 0 ? exp(-1 / max(1, Double(sampleRate) * atk / 1000)) : 0
    }

    /// Gain that brings `peak` down to `ceiling`; 1 when it is already at or below.
    public static func requiredGain(peak: Double, ceiling: Double) -> Double {
        peak > ceiling ? ceiling / peak : 1
    }

    /// Current gain reduction in dB (0 or negative).
    public var gainReductionDB: Double { gain >= 1 ? 0 : GainMath.dB(fromLinear: gain) }

    public mutating func reset() { gain = 1; hold = 0 }

    /// In place, both channels with one gain.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var g = gain, h = hold
        let ac = attackCoef
        for i in 0..<count {
            let peak = Double(max(abs(left[i]), abs(right[i])))
            let need = Self.requiredGain(peak: peak, ceiling: ceiling)
            if need < g {
                g = ac == 0 ? need : need + (g - need) * ac; h = holdSamples
            } else if h > 0 {
                h -= 1
            } else if g < 1 {
                g = min(need, 1 - (1 - g) * releaseCoef)
                if g > 0.999_999_9 { g = 1 }
            }
            if g < 1 {
                // Float rounding of x * g can land one ulp above the ceiling: clamp so |out| <= ceiling holds in Float.
                left[i] = min(max(Float(Double(left[i]) * g), -ceilingF), ceilingF)
                right[i] = min(max(Float(Double(right[i]) * g), -ceilingF), ceilingF)
            }
        }
        gain = g; hold = h
    }

    /// In place, interleaved frames of any channel count, all channels linked to one gain (same math as the left/right
    /// version; used by the export's loudness correction on whatever channel count the mix has).
    public mutating func process(interleaved s: UnsafeMutablePointer<Float>, channels: Int, count: Int) {
        let ch = max(1, channels)
        var g = gain, h = hold
        let ac = attackCoef
        for i in 0..<count {
            let base = i * ch
            var p: Float = 0
            for c in 0..<ch { p = max(p, abs(s[base + c])) }
            let need = Self.requiredGain(peak: Double(p), ceiling: ceiling)
            if need < g {
                g = ac == 0 ? need : need + (g - need) * ac; h = holdSamples
            } else if h > 0 {
                h -= 1
            } else if g < 1 {
                g = min(need, 1 - (1 - g) * releaseCoef)
                if g > 0.999_999_9 { g = 1 }
            }
            if g < 1 {
                for c in 0..<ch { s[base + c] = min(max(Float(Double(s[base + c]) * g), -ceilingF), ceilingF) }
            }
        }
        gain = g; hold = h
    }

    /// The same limiter at another ceiling, keeping its current gain reduction (a changed ceiling causes no jump).
    public func withCeiling(dB: Double, releaseMs: Double = 100, attackMs: Double = 0) -> MasterLimiter {
        var n = MasterLimiter(sampleRate: sampleRate, ceilingDB: dB, releaseMs: releaseMs, attackMs: attackMs)
        n.gain = gain; n.hold = hold
        return n
    }
}
