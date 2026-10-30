import Foundation
import Testing
@testable import SQCore

// Magic mask tracking quality on a synthetic shot with a known answer: a person-like subject (still body, head swinging
// fast from side to side) next to a still background object. The fake segmenter gives the subject one label with a
// wobbling edge (like Vision), so the follower has to follow without trailing the motion and without letting background in.
// Measured per frame against the true subject: soft IoU (sum of min / sum of max, what the composite shows), hard IoU at
// 0.5, and leak (matte outside the subject / subject area).

/// Deterministic pseudo random numbers (LCG).
struct QualityRNG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func symmetric() -> Double { next() * 2 - 1 }
}

/// The synthetic shot.
struct SwingShot {
    static let w = 192, h = 108
    var rng = QualityRNG(s: 99)
    /// The segmenter merges the lamp into the subject (one object), like Vision does with things touching a person.
    var mergeLamp = false
    /// A red hat on the head that the segmenter misses (background label).
    var hat = false
    static func inHat(_ x: Double, _ y: Double, head c: Vec2) -> Bool { abs(x - c.x) <= 10 && y >= 8 && y < 18 }
    /// Head center at frame `f`: swings 34 px either side in 16 frames (peak ~6.7 px per frame).
    static func head(_ f: Int) -> Vec2 { Vec2(96 + 34 * sin(2 * .pi * Double(f) / 16), 30) }
    static let headRadius = 13.0
    /// Signed distance (px, negative inside) to the subject: body rectangle 76...116 x 46...108 and the head disc.
    static func subjectDistance(_ x: Double, _ y: Double, head c: Vec2, wobble: (Double) -> Double = { _ in 0 }) -> Double {
        let dx = max(76 - x, x - 116, 0), dy = max(46 - y, 0)
        let inBody = x >= 76 && x <= 116 && y >= 46
        let body = inBody ? -min(x - 76, 116 - x, y - 46) : (dx * dx + dy * dy).squareRoot()
        let hx = x - c.x, hy = y - c.y
        let disc = (hx * hx + hy * hy).squareRoot() - (headRadius + wobble(atan2(hy, hx)))
        return min(body, disc)
    }
    /// Background object (a still lamp) right of the body: 124...150 x 20...100.
    static func lamp(_ x: Double, _ y: Double) -> Bool { x >= 124 && x < 150 && y >= 20 && y < 100 }

    /// The true subject at frame `f` (anti-aliased).
    static func truth(_ f: Int) -> SubjectMatte {
        let c = head(f)
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            v[y * w + x] = Float(min(max(0.5 - subjectDistance(Double(x) + 0.5, Double(y) + 0.5, head: c), 0), 1))
        } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    /// The true subject with the hat.
    static func truthWithHat(_ f: Int) -> SubjectMatte {
        var m = truth(f)
        let c = head(f)
        for y in 0..<h { for x in 0..<w where inHat(Double(x) + 0.5, Double(y) + 0.5, head: c) { m.values[y * w + x] = 1 } }
        return m
    }

    /// What the segmenter sees at frame `f`: labels (subject 1, lamp 2, their numbers swap every frame) with a wobbling
    /// subject edge (peak 2 px), the soft matte of any label set (the hard labels, Vision-like), and the picture.
    mutating func frame(_ f: Int) -> InstanceFrame {
        var harmonics: [(Double, Double, Double)] = []
        for k in [2.0, 3.0, 5.0] { harmonics.append((k, rng.symmetric(), rng.next() * 2 * .pi)) }
        let total = harmonics.map { abs($0.1) }.reduce(0, +)
        let amp = total > 0 ? 2 / total : 0
        let wob: (Double) -> Double = { th in harmonics.reduce(0) { $0 + $1.1 * amp * sin($1.0 * th + $1.2) } }
        let c = Self.head(f)
        let subject: UInt8 = f % 2 == 0 ? 1 : 2, other: UInt8 = f % 2 == 0 ? 2 : 1
        var l = [UInt8](repeating: 0, count: Self.w * Self.h)
        var rgb = [Float](repeating: 0, count: Self.w * Self.h * 3)
        for y in 0..<Self.h { for x in 0..<Self.w {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let i = y * Self.w + x
            if Self.lamp(px, py) { l[i] = mergeLamp ? subject : other }
            if Self.subjectDistance(px, py, head: c, wobble: wob) <= 0 { l[i] = subject }
            // Picture: wall gray, lamp yellow, skin/shirt (truth, no wobble).
            var col: (Float, Float, Float) = (0.45, 0.45, 0.47)
            if Self.lamp(px, py) { col = (0.85, 0.8, 0.3) }
            if Self.subjectDistance(px, py, head: c) <= 0 { col = py < 46 ? (0.8, 0.6, 0.5) : (0.2, 0.3, 0.7) }
            if hat, Self.inHat(px, py, head: c), Self.subjectDistance(px, py, head: c) > 0 { col = (0.8, 0.1, 0.1) }
            rgb[i * 3] = col.0; rgb[i * 3 + 1] = col.1; rgb[i * 3 + 2] = col.2
        } }
        let labels = InstanceLabels(width: Self.w, height: Self.h, labels: l)
        return InstanceFrame(labels: labels, guide: MagicGuide(width: Self.w, height: Self.h, rgb: rgb))
    }
}

/// Soft IoU, hard IoU (0.5) and leak of `m` against `truth`.
func matteScores(_ m: SubjectMatte, _ truth: SubjectMatte) -> (soft: Double, hard: Double, leak: Double) {
    var mn = 0.0, mx = 0.0, hi = 0.0, hu = 0.0, leak = 0.0, area = 0.0
    for i in 0..<truth.values.count {
        let a = Double(m.values[i]), b = Double(truth.values[i])
        mn += min(a, b); mx += max(a, b)
        let ha = a >= 0.5, hb = b >= 0.5
        if ha && hb { hi += 1 }
        if ha || hb { hu += 1 }
        leak += max(a - b, 0); area += b
    }
    return (mx > 0 ? mn / mx : 1, hu > 0 ? hi / hu : 1, area > 0 ? leak / area : 0)
}

@Suite struct MagicTrackQualityTests {
    /// Tracks the swing shot from a click on the face and returns mean / worst per-frame scores (frames 1...47).
    static func run() -> (soft: Double, hard: Double, worstSoft: Double, leak: Double) {
        var shot = SwingShot()
        var follower = MagicFollower()
        let click = [MagicPoint(position: Vec2(96.0 / 192, 30.0 / 108), subtract: false, sourceTime: .zero)]
        var soft = 0.0, hard = 0.0, worst = 1.0, leak = 0.0, n = 0.0
        for f in 0..<48 {
            guard let m = follower.step(shot.frame(f), points: click) else { Issue.record("lost at \(f)"); break }
            guard f > 0 else { continue }
            let s = matteScores(m, SwingShot.truth(f))
            soft += s.soft; hard += s.hard; worst = min(worst, s.soft); leak += s.leak; n += 1
        }
        return (soft / n, hard / n, worst, leak / n)
    }

    @Test func swingingHeadIsFollowedWithoutTrailOrLeak() {
        let r = Self.run()
        let line = "[MagicQuality] soft IoU mean \(r.soft) worst \(r.worstSoft) hard IoU mean \(r.hard) leak \(r.leak)"
        print(line)
        try? line.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-quality.txt"), atomically: true, encoding: .utf8)
        // Before the motion gate (plain 0.5 blend, 2026-10-07): soft 0.859, worst 0.799, hard 0.975, leak 0.077.
        // Without any blend of the frame before (2026-10-09): soft 0.979, worst 0.972, hard 0.980, leak 0.011.
        #expect(r.soft > 0.97, "soft IoU \(r.soft)")
        #expect(r.worstSoft > 0.96, "worst soft IoU \(r.worstSoft)")
        #expect(r.hard > 0.97, "hard IoU \(r.hard)")
        #expect(r.leak < 0.02, "leak \(r.leak)")
    }

    /// The raw segmentation alone (no follower): the floor the wobble leaves.
    @Test func rawSegmentationReference() {
        var shot = SwingShot()
        var soft = 0.0
        for f in 0..<48 {
            let fr = shot.frame(f)
            let id = fr.labels.label(at: Vec2(96.0 / 192, 60.0 / 108))
            if f > 0 { soft += matteScores(fr.labels.matte(of: [id]), SwingShot.truth(f)).soft }
        }
        let line = "[MagicQuality] raw soft IoU mean \(soft / 47)"
        print(line)
        try? line.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-quality-raw.txt"), atomically: true, encoding: .utf8)
        #expect(soft / 47 > 0.9)
    }

    /// A frame's matte is that frame's own: the same picture gives the same matte whatever was tracked before it, so
    /// nothing trails a motion and forward and backward tracking agree.
    @Test func aFrameMatteDoesNotDependOnTheFramesBefore() {
        let click = [MagicPoint(position: Vec2(96.0 / 192, 30.0 / 108), subtract: false, sourceTime: .zero)]
        var shot = SwingShot()
        let frames = (0..<12).map { shot.frame($0) }
        var forward = MagicFollower()
        var up: [SubjectMatte] = []
        for f in frames {
            guard let m = forward.step(f, points: click) else { Issue.record("lost"); return }
            up.append(m)
        }
        // Backward from the last frame's matte over the same pictures.
        var backward = MagicFollower(start: up[11])
        for i in (0..<12).reversed() {
            guard let m = backward.step(frames[i], points: click) else { Issue.record("lost at \(i)"); return }
            #expect(m == up[i], "frame \(i) differs by direction")
        }
    }
}
