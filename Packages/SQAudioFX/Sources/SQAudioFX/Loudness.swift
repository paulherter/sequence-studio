import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness and peak meter.
///
/// Feed audio with `process`. Momentary (400 ms) and short-term (3 s) are evaluated on 100 ms steps;
/// integrated uses 400 ms blocks with 75 % overlap, absolute gate -70 LUFS and relative gate -10 LU.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let weights: [Double]

    private var filters: [KWeighting]
    private var truePeak: [TruePeakDetector]
    private var stepLength: Int
    private var stepEnergy = 0.0            // weighted sum of squares in the current 100 ms step
    private var stepFill = 0
    private var steps: [Double] = []        // mean weighted energy per 100 ms step (only last 30 kept)
    private var blockEnergies: [Double] = []   // 400 ms block energies (for gating)
    private var samplePeak: [Double]

    public static func defaultWeights(channelCount: Int) -> [Double] {
        switch channelCount {
        case 6: return [1, 1, 1, 0, 1.41253754, 1.41253754]     // L R C LFE Ls Rs
        default: return Array(repeating: 1, count: channelCount)
        }
    }

    public init(sampleRate: Int, channelCount: Int, weights: [Double]? = nil) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        let w = weights ?? Self.defaultWeights(channelCount: channelCount)
        self.weights = w.count == channelCount ? w : Self.defaultWeights(channelCount: channelCount)
        filters = Array(repeating: KWeighting(sampleRate: Double(sampleRate)), count: channelCount)
        truePeak = Array(repeating: TruePeakDetector(), count: channelCount)
        samplePeak = Array(repeating: 0, count: channelCount)
        stepLength = max(1, Int((Double(sampleRate) * 0.1).rounded()))
    }

    public mutating func reset() {
        self = LoudnessMeter(sampleRate: sampleRate, channelCount: channelCount, weights: weights)
    }

    public mutating func process(_ input: [[Float]]) {
        precondition(input.count == channelCount, "channel count mismatch")
        let n = input.first?.count ?? 0
        for i in 0..<n {
            var e = 0.0
            for c in 0..<channelCount {
                let x = Double(input[c][i])
                let a = abs(x)
                if a > samplePeak[c] { samplePeak[c] = a }
                truePeak[c].push(x)
                if weights[c] != 0 {
                    let y = filters[c].process(x)
                    e += weights[c] * y * y
                }
            }
            stepEnergy += e
            stepFill += 1
            if stepFill == stepLength {
                steps.append(stepEnergy / Double(stepLength))
                stepEnergy = 0; stepFill = 0
                if steps.count >= 4 {
                    blockEnergies.append(steps.suffix(4).reduce(0, +) / 4)
                }
                if steps.count > 30 { steps.removeFirst(steps.count - 30) }
            }
        }
    }

    static func lufs(fromEnergy z: Double) -> Double { z > 0 ? -0.691 + 10 * log10(z) : -.infinity }

    /// Momentary loudness (LUFS) of the last 400 ms; nil until 400 ms have been seen.
    public var momentary: Double? {
        steps.count >= 4 ? Self.lufs(fromEnergy: steps.suffix(4).reduce(0, +) / 4) : nil
    }

    /// Short-term loudness (LUFS) of the last 3 s; nil until 3 s have been seen.
    public var shortTerm: Double? {
        steps.count >= 30 ? Self.lufs(fromEnergy: steps.suffix(30).reduce(0, +) / 30) : nil
    }

    /// Gated integrated loudness (LUFS); -inf if nothing passes the gates.
    public var integrated: Double {
        let absGate = blockEnergies.filter { Self.lufs(fromEnergy: $0) > -70 }
        guard !absGate.isEmpty else { return -.infinity }
        let relThreshold = Self.lufs(fromEnergy: absGate.reduce(0, +) / Double(absGate.count)) - 10
        let passed = absGate.filter { Self.lufs(fromEnergy: $0) > relThreshold }
        guard !passed.isEmpty else { return -.infinity }
        return Self.lufs(fromEnergy: passed.reduce(0, +) / Double(passed.count))
    }

    /// Per-channel sample peak in dBFS.
    public var samplePeakDB: [Double] { samplePeak.map(GainMath.dB(fromLinear:)) }

    /// Per-channel true peak in dBTP (4x oversampled).
    public var truePeakDB: [Double] {
        zip(truePeak, samplePeak).map { GainMath.dB(fromLinear: max($0.peak, $1)) }
    }
}

/// BS.1770 K-weighting: high-shelf pre-filter followed by the RLB high-pass, derived from the
/// standard's f0/Q/gain so it is valid for any sample rate (reproduces the 48 kHz table).
struct KWeighting: Sendable {
    private var s1 = Biquad(), s2 = Biquad()

    init(sampleRate fs: Double) {
        // Stage 1: high shelf (bilinear transform of the standard's analog prototype)
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var k = tan(Double.pi * 1681.974450955533 / fs), q = 0.7071752369554196
        var a0 = 1 + k / q + k * k
        s1 = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                    b2: (vh - vb * k / q + k * k) / a0,
                    a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        // Stage 2: RLB high-pass, numerator [1, -2, 1]
        k = tan(Double.pi * 38.13547087602444 / fs); q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        s2 = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    mutating func process(_ x: Double) -> Double { s2.process(s1.process(x)) }
}

struct Biquad: Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0
    init() {}
    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }
    mutating func process(_ x: Double) -> Double {       // transposed direct form II
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// 4x oversampling true-peak detector: 48-tap windowed-sinc, 4 polyphase branches of 12 taps.
struct TruePeakDetector: Sendable {
    static let taps: [[Double]] = {
        let n = 48
        var h = (0..<n).map { i -> Double in
            let x = (Double(i) - Double(n - 1) / 2) / 4
            let s = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return s * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 * 4 / sum }
        return (0..<4).map { p in (0..<12).map { h[4 * $0 + p] } }
    }()

    private var history = [Double](repeating: 0, count: 12)   // history[0] = newest
    private(set) var peak = 0.0

    mutating func push(_ x: Double) {
        history.removeLast()
        history.insert(x, at: 0)
        for phase in Self.taps {
            var acc = 0.0
            for k in 0..<12 { acc += phase[k] * history[k] }
            if abs(acc) > peak { peak = abs(acc) }
        }
    }
}
