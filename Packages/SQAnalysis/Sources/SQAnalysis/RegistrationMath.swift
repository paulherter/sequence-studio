import Foundation
import SQCore

/// Portable registration maths (the Vision and CoreVideo parts extend it in Stabilization.swift).
enum Registration {
    /// Least-squares similarity q = [a -b; b a] p + t through point pairs (Umeyama without reflection).
    static func fitSimilarity(_ src: [Vec2], _ dst: [Vec2]) -> CameraMotion? {
        let n = Double(min(src.count, dst.count))
        guard n >= 2 else { return nil }
        var mp = Vec2.zero, mq = Vec2.zero
        for i in 0..<Int(n) { mp = mp + src[i]; mq = mq + dst[i] }
        mp = mp * (1 / n); mq = mq * (1 / n)
        var sa = 0.0, sb = 0.0, ss = 0.0
        for i in 0..<Int(n) {
            let p = src[i] - mp, q = dst[i] - mq
            sa += p.x * q.x + p.y * q.y
            sb += p.x * q.y - p.y * q.x
            ss += p.x * p.x + p.y * p.y
        }
        guard ss > 0 else { return nil }
        let a = sa / ss, b = sb / ss
        let t = mq - Vec2(a * mp.x - b * mp.y, b * mp.x + a * mp.y)
        let s = (a * a + b * b).squareRoot()
        guard s.isFinite, s > 0, t.x.isFinite, t.y.isFinite else { return nil }
        // [a -b; b a] = s [cos -sin; sin cos] in y-down coordinates: positive angle = clockwise on screen.
        return CameraMotion(dx: t.x, dy: t.y, rotation: atan2(b, a) * 180 / .pi, scale: s)
    }

    /// A frame-to-frame motion a camera can make: under half the frame, under 20 degrees, under 25 % zoom.
    static func plausible(_ m: CameraMotion, _ w: Int, _ h: Int) -> Bool {
        abs(m.dx) < Double(w) / 2 && abs(m.dy) < Double(h) / 2 && abs(m.rotation) < 20 && m.scale > 0.8 && m.scale < 1.25
    }

    static func scaled(_ m: CameraMotion, by f: Double) -> CameraMotion {
        CameraMotion(dx: m.dx * f, dy: m.dy * f, rotation: m.rotation, scale: m.scale)
    }

    /// Own factor per axis: with non-square pixels (anamorphic) the picture is wider than the stored frame, not taller.
    static func scaled(_ m: CameraMotion, x: Double, y: Double) -> CameraMotion {
        CameraMotion(dx: m.dx * x, dy: m.dy * y, rotation: m.rotation, scale: m.scale)
    }

    /// A frame-to-frame scale a camera can make.
    static func plausibleScale(_ m: CameraMotion) -> Bool { m.scale > 0.8 && m.scale < 1.25 && abs(m.rotation) < 20 }
}

/// Small deterministic generator: the same frames always give the same motion.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
