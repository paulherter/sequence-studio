import Foundation
import Testing
@testable import SQCore

/// Reference cubic bezier progress (0,0)(x1,y1)(x2,y2)(1,1) via dense bisection, independent of KeyframeMath.
private func refBezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    func b(_ s: Double, _ a: Double, _ c: Double) -> Double {
        let u = 1 - s; return 3 * u * u * s * a + 3 * u * s * s * c + s * s * s
    }
    var lo = 0.0, hi = 1.0
    for _ in 0..<80 { let m = (lo + hi) / 2; if b(m, x1, x2) < t { lo = m } else { hi = m } }
    return b((lo + hi) / 2, y1, y2)
}

private func eased(_ c: EasingCurve, _ t: Double) -> Double {
    var a = kfKey(0, 0), b = kfKey(100, 100)
    c.apply(to: &a, side: .out); c.apply(to: &b, side: .in)
    return KeyframeTrack(keys: [a, b]).value(at: Time(Int64((t * 100000).rounded()), 1000))!
}

@Test func easingNewBuiltInsListed() {
    let names = EasingLibrary().all.map(\.name)
    #expect(names.contains("Classic"))
    #expect(names.contains("Ease-out 100%"))
    #expect(names.contains("Ease-in 100%"))
    #expect(Set(EasingCurve.builtIns.map(\.id)).count == EasingCurve.builtIns.count)
}

@Test func easingPremiereDefaultMatchesBezierMath() {
    let c = EasingCurve.premiereDefault
    #expect(c.interpolation == .bezier)
    #expect(abs(c.outHandle.dx - 0.167) < 1e-9 && abs(c.inHandle.dx - 0.167) < 1e-9)
    for t in stride(from: 0.1, through: 0.9, by: 0.1) {
        let ref = refBezier(t, 0.167, 0, 1 - 0.167, 1)
        #expect(abs(eased(c, t) - 100 * ref) < 0.5)
    }
}

@Test func easingOut100DeceleratesToTarget() {
    let c = EasingCurve.easeOut100
    for t in stride(from: 0.1, through: 0.9, by: 0.1) {
        let ref = refBezier(t, 1.0 / 3, 1.0 / 3, 0, 1)   // out linear handle, in handle dx 100% dy 0
        #expect(abs(eased(c, t) - 100 * ref) < 0.5)
    }
    #expect(eased(c, 0.5) > 50)          // fast start
    #expect(eased(c, 1.0) == 100)
}

@Test func easingIn100AcceleratesFromStart() {
    #expect(eased(.easeIn100, 0.5) < 50)
}

@Test func springEndsExactlyOnTarget() {
    for bounce in [0.0, 0.25, 0.5, 0.8, 1.0] {
        let s = SpringEasing(bounce: bounce)
        #expect(s.progress(0) == 0)
        #expect(s.progress(1) == 1)
        #expect(s.progress(1.5) == 1)
        #expect(s.progress(-1) == 0)
    }
}

@Test func springBounceOvershootsOnlyWhenBouncy() {
    let flat = SpringEasing(bounce: 0)
    let peakFlat = stride(from: 0.0, through: 1.0, by: 0.01).map { flat.progress($0) }.max()!
    #expect(peakFlat <= 1.0 + 1e-9)
    let bouncy = SpringEasing(bounce: 0.7)
    let peak = stride(from: 0.0, through: 1.0, by: 0.01).map { bouncy.progress($0) }.max()!
    #expect(peak > 1.05)
    let more = SpringEasing(bounce: 0.95)
    #expect(stride(from: 0.0, through: 1.0, by: 0.01).map { more.progress($0) }.max()! > peak)
}

@Test func springBakeLandsOnTargetAndAddsOvershootKeys() {
    let keys = SpringEasing(bounce: 0.6).bakedKeys(from: 100.0, to: 120.0, start: Time(0, 1), end: Time(1, 1), samplesPerSecond: 30)
    #expect(keys.first?.time == Time(0, 1) && keys.first?.value == 100)
    #expect(keys.last?.time == Time(1, 1) && keys.last?.value == 120)
    #expect(keys.count == 31)
    #expect(keys.map(\.value).max()! > 120)
    #expect(keys.allSatisfy { $0.interpolation == .linear })
    let tr = KeyframeTrack(keys: keys)
    #expect(tr.value(at: Time(1, 1)) == 120)
}

@Test func springBakeVec2() {
    let keys = SpringEasing(bounce: 0.5).bakedKeys(from: Vec2(0, 0), to: Vec2(10, -4), start: Time(0, 1), end: Time(1, 2), samplesPerSecond: 24)
    #expect(keys.last?.value == Vec2(10, -4))
    #expect(keys.count == 13)
}

@Test func curvePreviewSamples() {
    let s = EasingCurve.premiereDefault.previewSamples(count: 5)
    #expect(s.count == 5)
    #expect(s.first == 0 && s.last == 1)
    #expect(abs(s[2] - 0.5) < 1e-6)
    #expect(EasingCurve.linear.previewSamples(count: 3) == [0, 0.5, 1])
    #expect(EasingCurve.hold.previewSamples(count: 3) == [0, 0, 1])
    let sp = SpringEasing(bounce: 0.6).previewSamples(count: 40)
    #expect(sp.last == 1 && sp.max()! > 1)
}

@Test func springBakeDegenerateRanges() {
    let s = SpringEasing(bounce: 0.5)
    #expect(s.bakedKeys(from: 0.0, to: 5.0, start: Time(2, 1), end: Time(1, 1)).isEmpty)
    let one = s.bakedKeys(from: 0.0, to: 5.0, start: Time(2, 1), end: Time(2, 1))
    #expect(one.count == 1 && one[0].value == 5 && one[0].time == Time(2, 1))
}

@Test func springBakeHugeTimescaleAndLongSpan() {
    let s = SpringEasing(bounce: 0.5)
    let huge = Int64.max / 4
    let a = s.bakedKeys(from: 0.0, to: 1.0, start: Time(0, huge), end: Time(huge / 2, huge), samplesPerSecond: 30)
    #expect(a.last?.value == 1)
    #expect(zip(a, a.dropFirst()).allSatisfy { $0.time < $1.time })
    let h = s.bakedKeys(from: 0.0, to: 1.0, start: Time(0, 1), end: Time(3600, 1), samplesPerSecond: 30)
    #expect(h.count == 601)
    #expect(h.last?.time == Time(3600, 1) && h.last?.value == 1)
    #expect(zip(h, h.dropFirst()).allSatisfy { $0.time < $1.time })
    let b = s.bakedKeys(from: 0.0, to: 1.0, start: Time(Int64.max / 3, 1000), end: Time(Int64.max / 2, 1000), samplesPerSecond: 30)
    #expect(zip(b, b.dropFirst()).allSatisfy { $0.time < $1.time })
}

@Test func springPresetsInLibrary() {
    let p = EasingLibrary.springPresets
    #expect(p.count >= 2)
    #expect(p.map(\.name).contains("Spring bounce"))
    #expect(Set(p.map(\.name)).count == p.count)
}
