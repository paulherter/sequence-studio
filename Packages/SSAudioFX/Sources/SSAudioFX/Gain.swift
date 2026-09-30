import Foundation
import SSCore

public enum AudioFXError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Int)
    case invalidChannelCount(Int)
}

public enum AudioGain {
    /// At or below this the gain is exact silence.
    public static let silenceFloorDB: Double = -120

    public static func linear(fromDB db: Double) -> Double {
        if db.isNaN || db <= silenceFloorDB { return 0 }
        return pow(10, db / 20)
    }

    public static func dB(fromLinear g: Double) -> Double {
        g <= 0 ? -.infinity : 20 * log10(g)
    }
}

/// Clip/track volume in dB (static or keyframed) plus optional constant-power pan.
///
/// Gain is evaluated on an absolute-sample control grid (every `controlInterval` samples) and
/// interpolated linearly per sample, so the result is sample-accurate, free of zipper noise,
/// and independent of how the audio is chunked.
public struct VolumeAutomation: Sendable, Hashable, Codable {
    public var staticDB: Double
    public var track: KeyframeTrack<Double>?
    /// -1 (left) ... +1 (right); nil = no pan processing. Stereo only.
    public var pan: Double?
    public var panTrack: KeyframeTrack<Double>?

    public static let controlInterval = 64

    public init(staticDB: Double = 0, track: KeyframeTrack<Double>? = nil, pan: Double? = nil) {
        self.staticDB = staticDB; self.track = track; self.pan = pan
    }

    public func dB(at t: Time) -> Double {
        if let v = track?.value(at: t) { return v }
        return staticDB
    }

    func panValue(at t: Time) -> Double? {
        if let v = panTrack?.value(at: t) { return min(1, max(-1, v)) }
        return pan.map { min(1, max(-1, $0)) }
    }

    /// (left, right) gains, unity at centre, constant power.
    static func panGains(_ p: Double) -> (Double, Double) {
        let a = (p + 1) * .pi / 4
        return (cos(a) * 2.0.squareRoot(), sin(a) * 2.0.squareRoot())
    }

    /// Applies gain (and pan) in place. `start` is the timeline time of sample 0 of `buffer`.
    public func apply(to buffer: inout [[Float]], start: Time, sampleRate: Int) {
        guard let n = buffer.first?.count, n > 0, sampleRate > 0 else { return }
        let startSample = Self.sampleIndex(start, rate: Int64(sampleRate))
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: buffer.count)
        defer { ptrs.deallocate() }
        for c in 0..<buffer.count {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(from: buffer[c], count: n)
            (ptrs + c).initialize(to: p)
        }
        apply(channels: ptrs, channelCount: buffer.count, frames: n, startSample: startSample, sampleRate: sampleRate)
        for c in 0..<buffer.count {
            buffer[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n))
            ptrs[c].deallocate()
        }
    }

    /// Allocation-free core (realtime path). `startSample` = absolute sample index of sample 0.
    func apply(channels buffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channelCount: Int,
               frames n: Int, startSample: Int64, sampleRate: Int) {
        guard n > 0, sampleRate > 0 else { return }
        let rate = Int64(sampleRate)
        let step = Int64(Self.controlInterval)
        let stereoPan = channelCount == 2 && (pan != nil || panTrack != nil)

        func gains(at abs: Int64) -> (Double, Double) {
            let t = Time(abs, rate)
            let g = AudioGain.linear(fromDB: dB(at: t))
            if stereoPan, let p = panValue(at: t) {
                let (l, r) = Self.panGains(p)
                return (g * l, g * r)
            }
            return (g, g)
        }

        var k = Int64(floor(Double(startSample) / Double(step)))      // control point index
        var g0 = gains(at: k * step)
        var g1 = gains(at: (k + 1) * step)
        for i in 0..<n {
            let abs = startSample + Int64(i)
            while abs >= (k + 1) * step { k += 1; g0 = g1; g1 = gains(at: (k + 1) * step) }
            let f = Double(abs - k * step) / Double(step)
            let gl = g0.0 + (g1.0 - g0.0) * f
            let gr = g0.1 + (g1.1 - g0.1) * f
            for c in 0..<channelCount {
                buffer[c][i] *= Float(c == 1 ? gr : gl)
            }
        }
    }

    static func sampleIndex(_ t: Time, rate: Int64) -> Int64 {
        let num = Int128(t.value) * Int128(rate)
        let den = Int128(t.timescale)
        let q = num / den, r = num % den
        var res = q
        if r * 2 >= den { res += 1 } else if r * 2 <= -den { res -= 1 }
        return Int64(res)
    }
}
