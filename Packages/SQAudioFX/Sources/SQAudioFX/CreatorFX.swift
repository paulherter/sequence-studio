import Foundation

/// Noise gate ("hush" for room noise between words): ducks the signal to `-reductionDB` while the linked
/// level stays under the threshold. Off by default.
public struct NoiseGateSettings: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var thresholdDB: Double
    /// How far the closed gate pulls the signal down (positive dB).
    public var reductionDB: Double
    public var attackMs: Double
    public var holdMs: Double
    public var releaseMs: Double

    public init(enabled: Bool = false, thresholdDB: Double = -45, reductionDB: Double = 40,
                attackMs: Double = 2, holdMs: Double = 80, releaseMs: Double = 150) {
        self.enabled = enabled; self.thresholdDB = thresholdDB; self.reductionDB = reductionDB
        self.attackMs = attackMs; self.holdMs = holdMs; self.releaseMs = releaseMs
    }

    public static let off = NoiseGateSettings()

    public enum Limits {
        public static let thresholdDB: ClosedRange<Double> = -80...0
        public static let reductionDB: ClosedRange<Double> = 0...80
        public static let attackMs: ClosedRange<Double> = 0.1...100
        public static let holdMs: ClosedRange<Double> = 0...1000
        public static let releaseMs: ClosedRange<Double> = 5...2000
    }

    func normalized() -> NoiseGateSettings {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isNaN ? r.lowerBound : min(r.upperBound, max(r.lowerBound, v)) }
        var s = self
        s.thresholdDB = c(thresholdDB, Limits.thresholdDB)
        s.reductionDB = c(reductionDB, Limits.reductionDB)
        s.attackMs = c(attackMs, Limits.attackMs)
        s.holdMs = c(holdMs, Limits.holdMs)
        s.releaseMs = c(releaseMs, Limits.releaseMs)
        return s
    }
}

/// Soft-clip saturation ("warmth", tape-like): tanh curve, level-normalized so full-scale peaks stay at full
/// scale, blended with the dry signal. Off by default.
public struct SaturationSettings: Sendable, Hashable, Codable {
    public var enabled: Bool
    /// Input drive before the curve, 0...24 dB.
    public var driveDB: Double
    /// Dry/wet 0...1.
    public var mix: Double

    public init(enabled: Bool = false, driveDB: Double = 6, mix: Double = 1) {
        self.enabled = enabled; self.driveDB = driveDB; self.mix = mix
    }

    public static let off = SaturationSettings()

    public enum Limits {
        public static let driveDB: ClosedRange<Double> = 0...24
        public static let mix: ClosedRange<Double> = 0...1
    }
}

/// Sample-by-sample, all state in the value (output never depends on chunking). Zero latency.
struct NoiseGate {
    struct Config {
        fileprivate var active = false
        fileprivate var openLevel = 1.0, closeLevel = 1.0     // linear, hysteresis of 3 dB
        fileprivate var floorGain = 1.0
        fileprivate var attack = 0.0, release = 0.0, decay = 0.0
        fileprivate var holdSamples = 0

        init() {}

        init(settings raw: NoiseGateSettings, sampleRate: Double) {
            let s = raw.normalized()
            active = s.enabled && s.reductionDB > 0
            openLevel = pow(10, s.thresholdDB / 20)
            closeLevel = openLevel * 0.7079457843841379      // -3 dB
            floorGain = pow(10, -s.reductionDB / 20)
            attack = exp(-1 / (s.attackMs / 1000 * sampleRate))
            release = exp(-1 / (s.releaseMs / 1000 * sampleRate))
            decay = exp(-1 / (0.005 * sampleRate))           // 5 ms peak detector
            holdSamples = Int(s.holdMs / 1000 * sampleRate)
        }
    }

    private var c = Config()
    private var core = GateCore<Double>(detector: .peakDecay, smoothing: .blend)

    init(settings: NoiseGateSettings, sampleRate: Double) { c = Config(settings: settings, sampleRate: sampleRate) }

    /// Installs new settings; envelope, gain and hold state survive. Allocation-free.
    mutating func apply(_ config: Config) {
        c = config
        if !c.active { core.bypass() }
    }

    mutating func reset() { core.reset() }

    mutating func process(channels buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames n: Int) {
        guard c.active, n > 0 else { return }
        for i in 0..<n {
            var peak = 0.0
            for ch in 0..<channelCount { peak = max(peak, Double(abs(buf[ch][i]))) }
            let g = Float(core.step(peak: peak, openLevel: c.openLevel, closeLevel: c.closeLevel, floorGain: c.floorGain,
                                    decay: c.decay, attack: c.attack, release: c.release, holdSamples: c.holdSamples))
            for ch in 0..<channelCount { buf[ch][i] *= g }
        }
    }

    mutating func process(_ buf: inout [[Float]]) {
        guard c.active, let n = buf.first?.count, n > 0 else { return }
        let chans = buf.count
        withChannelPointers(&buf) { process(channels: $0, channelCount: chans, frames: n) }
    }
}

struct Saturator {
    struct Config {
        fileprivate var active = false
        fileprivate var drive: Float = 1, norm: Float = 1, mix: Float = 1

        init() {}

        init(settings s: SaturationSettings) {
            let d = s.driveDB.isNaN ? 0 : min(24, max(0, s.driveDB))
            let m = s.mix.isNaN ? 0 : min(1, max(0, s.mix))
            active = s.enabled && m > 0
            drive = Float(pow(10, d / 20))
            norm = 1 / tanhf(drive)
            mix = Float(m)
        }
    }

    private var c = Config()
    init(settings: SaturationSettings) { c = Config(settings: settings) }
    mutating func apply(_ config: Config) { c = config }

    func process(channels buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames n: Int) {
        guard c.active, n > 0 else { return }
        let drive = c.drive, norm = c.norm, mix = c.mix
        for ch in 0..<channelCount {
            let p = buf[ch]
            for i in 0..<n {
                let x = p[i]
                p[i] = x + mix * (tanhf(x * drive) * norm - x)
            }
        }
    }

    func process(_ buf: inout [[Float]]) {
        guard c.active, let n = buf.first?.count, n > 0 else { return }
        let chans = buf.count
        withChannelPointers(&buf) { process(channels: $0, channelCount: chans, frames: n) }
    }
}

/// Offline helper: copies `buf` to temporary channel pointers, runs `body`, copies back.
private func withChannelPointers(_ buf: inout [[Float]], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> Void) {
    let n = buf[0].count
    let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: buf.count)
    defer { ptrs.deallocate() }
    for c in 0..<buf.count {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        p.initialize(from: buf[c], count: n)
        (ptrs + c).initialize(to: p)
    }
    body(ptrs)
    for c in 0..<buf.count {
        buf[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n))
        ptrs[c].deallocate()
    }
}
