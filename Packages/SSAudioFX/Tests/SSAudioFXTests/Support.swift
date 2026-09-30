import Foundation

enum Sig {
    static func sine(freq: Double, amplitudeDB: Double, seconds: Double, rate: Int = 48000,
                     channels: Int = 2, phase: Double = 0) -> [[Float]] {
        let n = Int(seconds * Double(rate))
        let a = pow(10, amplitudeDB / 20)
        let ch = (0..<n).map { Float(a * sin(2 * .pi * freq * Double($0) / Double(rate) + phase)) }
        return Array(repeating: ch, count: channels)
    }

    /// Deterministic white noise, uniform in +-amp.
    static func noise(amplitude: Float, count: Int, seed: UInt64 = 1) -> [Float] {
        var s = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<count).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = Float((s >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            return (u * 2 - 1) * amplitude
        }
    }

    /// Room/fan-like noise: white noise through a one-pole low-pass (RNNoise passes flat white noise, see PHASE5.md).
    static func lowNoise(amplitude: Float, count: Int, seed: UInt64 = 1) -> [Float] {
        let x = noise(amplitude: amplitude, count: count, seed: seed)
        var s: Float = 0
        return x.map { s += 0.1 * ($0 - s); return s * 3 }
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func chunked(_ x: [[Float]], sizes: [Int]) -> [[[Float]]] {
        var out: [[[Float]]] = []
        var pos = 0, i = 0
        let n = x[0].count
        while pos < n {
            let len = min(sizes[i % sizes.count], n - pos)
            out.append(x.map { Array($0[pos..<pos + len]) })
            pos += len; i += 1
        }
        return out
    }

    static func concat(_ parts: [[[Float]]], channels: Int) -> [[Float]] {
        (0..<channels).map { c in parts.flatMap { $0[c] } }
    }
}
