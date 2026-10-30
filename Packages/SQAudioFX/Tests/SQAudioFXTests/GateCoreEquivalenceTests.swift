import Foundation
import Testing
import SQCore
@testable import SQAudioFX

/// Frozen copies of the two gate implementations as they were before they shared `GateCore` (2026-10-12). The shared core
/// must reproduce both sample for sample.
private struct LegacyTrackGate {
    var active = false
    var openLevel = 1.0, closeLevel = 1.0, floorGain = 1.0, attack = 0.0, release = 0.0, decay = 0.0
    var holdSamples = 0
    var env = 0.0, gain = 1.0, hold = 0, isOpen = true

    init(settings s: NoiseGateSettings, sampleRate: Double) {
        active = s.enabled && s.reductionDB > 0
        openLevel = pow(10, s.thresholdDB / 20)
        closeLevel = openLevel * 0.7079457843841379
        floorGain = pow(10, -s.reductionDB / 20)
        attack = exp(-1 / (s.attackMs / 1000 * sampleRate))
        release = exp(-1 / (s.releaseMs / 1000 * sampleRate))
        decay = exp(-1 / (0.005 * sampleRate))
        holdSamples = Int(s.holdMs / 1000 * sampleRate)
    }

    mutating func process(_ buf: inout [[Float]]) {
        guard active, let n = buf.first?.count, n > 0 else { return }
        for i in 0..<n {
            var peak = 0.0
            for ch in 0..<buf.count { peak = max(peak, Double(abs(buf[ch][i]))) }
            env = max(peak, env * decay)
            if isOpen {
                if env < closeLevel {
                    if hold > 0 { hold -= 1 } else { isOpen = false }
                } else { hold = holdSamples }
            } else if env >= openLevel {
                isOpen = true; hold = holdSamples
            }
            let target = isOpen ? 1.0 : floorGain
            let k = target > gain ? attack : release
            gain = k * gain + (1 - k) * target
            let g = Float(gain)
            for ch in 0..<buf.count { buf[ch][i] *= g }
        }
    }
}

private struct LegacyClipGate {
    var env: Float = 0, gain: Float = 1, holdLeft = 0
    let fs: Double
    let decay: Float
    init(sampleRate: Double) { fs = sampleRate; decay = Float(exp(-1 / (0.010 * sampleRate))) }

    mutating func process(_ x: inout [[Float]], thresholdFrom t0: Double, to t1: Double, attackMs: Double, releaseMs: Double,
                          rangeFrom r0: Double, to r1: Double, holdMs: Double) {
        let n = x[0].count, chs = x.count
        let holdSamples = Int((holdMs.isNaN ? 0 : min(max(holdMs, 0), 1_000)) / 1000 * fs)
        var holdLeft = min(self.holdLeft, holdSamples)
        let atk = Float(exp(-1 / (max(0.0001, attackMs / 1000) * fs)))
        let rel = Float(exp(-1 / (max(0.0001, releaseMs / 1000) * fs)))
        let inv = 1 / Double(n)
        var env = env, gain = gain
        for i in 0..<n {
            let t = Double(i) * inv
            let thr = Float(pow(10, (t0 + (t1 - t0) * t) / 20))
            let floorGain = Float(pow(10, -abs(r0 + (r1 - r0) * t) / 20))
            var peak: Float = 0
            for c in 0..<chs { peak = max(peak, abs(x[c][i])) }
            env = peak > env ? peak : env * decay + peak * (1 - decay)
            var open = env >= thr
            if open { holdLeft = holdSamples } else if holdLeft > 0 { holdLeft -= 1; open = true }
            let target: Float = open ? 1 : floorGain
            let k = target > gain ? atk : rel
            gain = target + (gain - target) * k
            for c in 0..<chs { x[c][i] *= gain }
        }
        self.env = env; self.gain = gain; self.holdLeft = holdLeft
    }
}

/// Deterministic speech-like input: tone bursts with an attack/decay shape, pauses with low noise, two channels.
private func speechLike(frames: Int, sampleRate: Double = 48_000) -> [[Float]] {
    var seed: UInt64 = 0x2545F4914F6CDD1D
    func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
    }
    var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
    let burst = Int(0.18 * sampleRate), pause = Int(0.22 * sampleRate)
    for i in 0..<frames {
        let pos = i % (burst + pause)
        var v = 0.002 * noise()
        if pos < burst {
            let env = min(1, Double(pos) / 200) * exp(-Double(pos) / (0.12 * sampleRate)) * (0.2 + 0.5 * Double((i / (burst + pause)) % 3) / 2)
            v += env * (sin(Double(i) * 0.07) + 0.4 * sin(Double(i) * 0.31)) * 0.6
        }
        out[0][i] = Float(v)
        out[1][i] = Float(v * 0.8 + 0.001 * noise())
    }
    return out
}

@Suite struct GateCoreEquivalenceTests {
    private func pointers(_ x: [[Float]]) -> (UnsafeMutablePointer<UnsafeMutablePointer<Float>>, () -> [[Float]], () -> Void) {
        let n = x[0].count
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: x.count)
        for c in 0..<x.count { ptrs[c] = .allocate(capacity: n); ptrs[c].initialize(from: x[c], count: n) }
        return (ptrs, { (0..<x.count).map { Array(UnsafeBufferPointer(start: ptrs[$0], count: n)) } },
                { for c in 0..<x.count { ptrs[c].deallocate() }; ptrs.deallocate() })
    }

    @Test(arguments: [
        (-30.0, 40.0, 2.0, 80.0, 150.0), (-45.0, 20.0, 0.5, 0.0, 60.0), (-20.0, 60.0, 10.0, 300.0, 400.0),
        (-35.0, 12.0, 1.0, 1000.0, 20.0), (-60.0, 40.0, 5.0, 40.0, 100.0),
    ])
    func trackGateMatchesLegacy(p: (Double, Double, Double, Double, Double)) {
        let settings = NoiseGateSettings(enabled: true, thresholdDB: p.0, reductionDB: p.1, attackMs: p.2, holdMs: p.3, releaseMs: p.4)
        let x = speechLike(frames: 48_000 * 2)
        var legacy = LegacyTrackGate(settings: settings.normalizedForTest, sampleRate: 48_000)
        var want = x
        legacy.process(&want)
        var gate = NoiseGate(settings: settings, sampleRate: 48_000)
        var got = x
        gate.process(&got)
        #expect(got == want)
        #expect(got != x)
        // Chunking does not change the output.
        var chunked = NoiseGate(settings: settings, sampleRate: 48_000)
        var parts: [[Float]] = [[], []]
        var pos = 0
        for size in [1, 17, 480, 1000, 333] {
            let end = min(x[0].count, pos + size)
            var piece = x.map { Array($0[pos..<end]) }
            if !piece[0].isEmpty { chunked.process(&piece) }
            for c in 0..<2 { parts[c] += piece[c] }
            pos = end
        }
        for c in 0..<2 { #expect(Array(want[c][0..<pos]) == parts[c]) }
    }

    @Test(arguments: [
        (-30.0, 2.0, 150.0, 40.0, 80.0), (-45.0, 0.5, 60.0, 20.0, 0.0), (-20.0, 10.0, 400.0, 60.0, 300.0),
        (-35.0, 1.0, 20.0, 12.0, 1000.0), (-60.0, 5.0, 100.0, 40.0, 40.0),
    ])
    func clipGateMatchesLegacy(p: (Double, Double, Double, Double, Double)) throws {
        let x = speechLike(frames: 48_000 * 2)
        var legacy = LegacyClipGate(sampleRate: 48_000)
        let stage = NoiseGateStage(sampleRate: 48_000)
        let (ptrs, read, free) = pointers(x)
        defer { free() }
        var want = x
        let block = 960
        var pos = 0
        var k = 0
        while pos < x[0].count {
            let m = min(block, x[0].count - pos)
            // A moving threshold and range exercise the per-sample ramps; the hold changes between blocks.
            let thr0 = p.0 + Double(k % 3), thr1 = p.0 - Double(k % 2) * 4
            var piece = want.map { Array($0[pos..<pos + m]) }
            legacy.process(&piece, thresholdFrom: thr0, to: thr1, attackMs: p.1, releaseMs: p.2, rangeFrom: p.3, to: p.3 + 6, holdMs: p.4 * (k % 5 == 4 ? 0.5 : 1))
            for c in 0..<2 { want[c].replaceSubrange(pos..<pos + m, with: piece[c]) }
            let view = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            for c in 0..<2 { view[c] = ptrs[c] + pos }
            stage.process(view, channels: 2, frames: m, thresholdFrom: thr0, to: thr1, attackMs: p.1, releaseMs: p.2,
                          rangeFrom: p.3, to: p.3 + 6, holdMs: p.4 * (k % 5 == 4 ? 0.5 : 1))
            view.deallocate()
            pos += m; k += 1
        }
        #expect(read() == want)
        #expect(want != x)
    }
}

private extension NoiseGateSettings {
    /// The settings as the legacy copy saw them (all test values are inside the limits).
    var normalizedForTest: NoiseGateSettings { self }
}
