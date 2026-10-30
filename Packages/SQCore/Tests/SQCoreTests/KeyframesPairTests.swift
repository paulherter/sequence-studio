import Foundation
import Testing
@testable import SQCore

private func prop(_ keys: [Keyframe<Double>], _ v: Double = 0) -> AnimatedProperty<Double> {
    AnimatedProperty(v, track: KeyframeTrack(keys: keys))
}

private func eased(_ s: Int64, _ v: Double, out: EaseHandle = .linear, in inH: EaseHandle = .linear) -> Keyframe<Double> {
    Keyframe(time: kfT(s), value: v, interpolation: .bezier, inHandle: inH, outHandle: out)
}

// MARK: Catalog

@Test func pairsDeclaredForTransformAndReframe() {
    for spec in [EffectTransformStage.transformSpec, EffectTransformStage.reframeSpec] {
        let keys = spec.pairs.map { [$0.x, $0.y] }
        #expect(keys == [[ClipEffect.stagePositionXKey, ClipEffect.stagePositionYKey],
                         [ClipEffect.stageScaleKey, ClipEffect.stageScaleYKey],
                         [ClipEffect.stageAnchorXKey, ClipEffect.stageAnchorYKey]])
        #expect(spec.pairs.map(\.title) == ["Position", "Scale", "Anchor"])
        // Every member is a real parameter of the spec.
        let params = Set(spec.params.map(\.key))
        #expect(spec.pairs.allSatisfy { params.contains($0.x) && params.contains($0.y) })
        #expect(spec.pair(containing: ClipEffect.stagePositionYKey)?.x == ClipEffect.stagePositionXKey)
        #expect(spec.pair(containing: ClipEffect.stageScaleKey)?.linkable == true)
        #expect(spec.pair(containing: ClipEffect.stageRotationKey) == nil)
    }
    #expect(EffectCatalog.spec(for: ClipEffect.gaussianBlurKind)?.pairs.isEmpty == true)
}

// MARK: isAligned

@Test func pairAlignedWhenTimesAndEasingMatch() {
    let x = prop([eased(0, 0, out: EaseHandle(dx: 0.4, dy: 0)), kfKey(2, 10)])
    let y = prop([eased(0, 5, out: EaseHandle(dx: 0.4, dy: 0)), kfKey(2, -3)])
    #expect(KeyframesPair.isAligned(x, y))
    #expect(KeyframesPair.isAligned(prop([]), prop([])))
}

@Test func pairNotAlignedOnDifferentTimesOrEasing() {
    #expect(!KeyframesPair.isAligned(prop([kfKey(0, 0), kfKey(2, 1)]), prop([kfKey(0, 0), kfKey(3, 1)])))
    #expect(!KeyframesPair.isAligned(prop([kfKey(0, 0), kfKey(2, 1)]), prop([kfKey(0, 0, .hold), kfKey(2, 1)])))
    #expect(!KeyframesPair.isAligned(prop([eased(0, 0, out: EaseHandle(dx: 0.4, dy: 0)), kfKey(2, 1)]),
                                     prop([eased(0, 0, out: EaseHandle(dx: 0.3, dy: 0)), kfKey(2, 1)])))
    #expect(!KeyframesPair.isAligned(prop([kfKey(0, 0)]), prop([])))
}

// MARK: aligning

/// Stabilizer-style: X and Y written with different key times.
@Test func pairAligningDivergedTracksUnionsTimes() {
    let x = prop([kfKey(0, 0), kfKey(2, 20), kfKey(4, 0)])
    let y = prop([kfKey(0, 100), kfKey(3, 130)])
    #expect(!KeyframesPair.isAligned(x, y))
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(KeyframesPair.isAligned(ax, ay))
    #expect(ax.track.keys.map(\.time) == [kfT(0), kfT(2), kfT(3), kfT(4)])
    // Original keys kept (ids and values), missing ones interpolated.
    #expect(ax.track.keys[0].id == x.track.keys[0].id && ax.track.keys[1].id == x.track.keys[1].id)
    #expect(ax.track.keys.map(\.value) == [0, 20, 10, 0])
    #expect(ay.track.keys.map(\.value) == [100, 120, 130, 130])
    // Linear curves are unchanged by the split.
    for s in stride(from: 0.0, through: 4.0, by: 0.25) {
        let t = Time(Int64(s * 4), 4)
        #expect(abs(ax.value(atLocal: t) - x.value(atLocal: t)) < 1e-9)
        #expect(abs(ay.value(atLocal: t) - y.value(atLocal: t)) < 1e-9)
    }
}

@Test func pairAligningCopiesEasingToMissingMember() {
    let ease = EaseHandle(dx: 0.5, dy: 0)
    var hold = kfKey(2, 7, .hold); hold.inHandle = EaseHandle(dx: 0.2, dy: 0.1)
    let x = prop([eased(0, 0, out: ease, in: ease), hold])
    let y = prop([], 42)
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(KeyframesPair.isAligned(ax, ay))
    #expect(ay.track.keys.map(\.value) == [42, 42])
    #expect(ay.track.keys[0].interpolation == .bezier && ay.track.keys[0].outHandle == ease && ay.track.keys[0].inHandle == ease)
    #expect(ay.track.keys[1].interpolation == .hold && ay.track.keys[1].inHandle == EaseHandle(dx: 0.2, dy: 0.1))
    #expect(ax == x)   // the full member is untouched
    // New keys get fresh ids.
    #expect(Set(ay.track.keys.map(\.id)).isDisjoint(with: Set(ax.track.keys.map(\.id))))
}

/// Both change over the stretch with different easing: aligning keeps both curves (unaligned); a pair row edit then
/// gives Y X's shape.
@Test func pairAligningSameTimeDifferentEasingFollowsX() {
    let x = prop([eased(0, 0, out: EaseHandle(dx: 0.4, dy: 0)), kfKey(2, 1)])
    let y = prop([kfKey(0, 5), kfKey(2, 6)])
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(ax == x && ay == y && !KeyframesPair.isAligned(ax, ay))
    var ex = x, ey = y
    KeyframesPair.edit(&ex, &ey) { _ in }
    #expect(KeyframesPair.isAligned(ex, ey) && ex == x)
    #expect(ey.track.keys.map(\.value) == [5, 6])
    #expect(ey.track.keys.map(\.id) == y.track.keys.map(\.id))
    #expect(ey.track.keys[0].outHandle == EaseHandle(dx: 0.4, dy: 0))
}

@Test func pairAligningAlignedIsIdentity() {
    let x = prop([kfKey(0, 0), kfKey(2, 10)]), y = prop([kfKey(0, 1), kfKey(2, 2)])
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(ax == x && ay == y)
}

// MARK: zipped

@Test func pairZippedOnlyWhenAligned() {
    #expect(KeyframesPair.zipped(prop([kfKey(0, 0), kfKey(2, 1)]), prop([kfKey(1, 0)])) == nil)
    let z = KeyframesPair.zipped(prop([], 3), prop([], 4))
    #expect(z?.value == Vec2(3, 4) && z?.isAnimated == false)
}

@Test func pairZippedEvaluatesLikeMembers() throws {
    let e = EaseHandle(dx: 0.6, dy: 0.1)
    let x = prop([eased(0, 0, out: e, in: e), eased(2, 30, out: e, in: e), kfKey(4, 30, .hold)])
    let y = prop([eased(0, 0, out: e, in: e), eased(2, 40, out: e, in: e), kfKey(4, 0, .hold)])
    let z = try #require(KeyframesPair.zipped(x, y))
    #expect(z.track.keys.map(\.id) == x.track.keys.map(\.id))
    for i in 0...16 {
        let t = Time(Int64(i), 4)
        let v = z.value(atLocal: t)
        #expect(abs(v.x - x.value(atLocal: t)) < 1e-9 && abs(v.y - y.value(atLocal: t)) < 1e-9)
    }
}

/// Speed of the zipped track = |delta| / duration x ease'(t): one curve for an aligned pair.
@Test func pairZippedSpeedIsDeltaLengthTimesEaseSlope() throws {
    let out = EaseHandle(dx: 0.5, dy: 0), inH = EaseHandle(dx: 0.25, dy: 0)
    let x = prop([eased(0, 0, out: out), eased(2, 30, in: inH)])
    let y = prop([eased(0, 0, out: out), eased(2, 40, in: inH)])
    let z = try #require(KeyframesPair.zipped(x, y))
    let samples = z.track.speedGraph(samples: 21)[0].samples
    let dur = 2.0, delta = 50.0
    for s in samples {
        let tn = s.time / dur, h = 1e-4
        let lo = max(0, tn - h), hi = min(1, tn + h)
        let slope = (KeyframeMath.bezierProgress(hi, out: out, in: inH) - KeyframeMath.bezierProgress(lo, out: out, in: inH)) / (hi - lo)
        #expect(abs(s.speed - delta / dur * slope) < 1e-3)
    }
    #expect(samples.first!.speed < 0.5 && samples[10].speed > delta / dur)
}

// MARK: aligning keeps each member's own curve

private func expectSameCurve(_ a: AnimatedProperty<Double>, _ b: AnimatedProperty<Double>, through end: Int64 = 4,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    for i in -4...(Int(end) * 20 + 4) {
        let t = Time(Int64(i), 20)
        #expect(abs(a.value(atLocal: t) - b.value(atLocal: t)) < 1e-6, "t = \(Double(i) / 20)", sourceLocation: sourceLocation)
    }
}

/// A partner's Hold key must not turn a key inserted into this member into a Hold (x(3s) stays 30, not 20).
@Test func pairAligningPartnerHoldKeepsOwnRamp() {
    let x = prop([kfKey(0, 0), kfKey(4, 40)])
    let y = prop([kfKey(0, 5), kfKey(2, 7, .hold), kfKey(4, 9)])
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(ax.track.keys.map(\.time) == [kfT(0), kfT(2), kfT(4)])
    #expect(ax.value(atLocal: kfT(3)) == 30)
    expectSameCurve(ax, x); expectSameCurve(ay, y)
}

/// A key inserted into this member's own Hold segment stays Hold (no ramp).
@Test func pairAligningOwnHoldSegmentStaysHold() {
    let x = prop([kfKey(0, 0, .hold), kfKey(4, 40)])
    // No shared time with a different shape (there Y would take X's Hold by design).
    let y = prop([kfKey(1, 0), kfKey(2, 5), kfKey(4, 9)])
    let (ax, ay) = KeyframesPair.aligning(x, y)
    #expect(ax.track.keys.map(\.time) == [kfT(0), kfT(1), kfT(2), kfT(4)])
    // The key before the jump holds; a flat stretch before it may take Y's linear (same curve).
    #expect(ax.track.keys[2].interpolation == .hold)
    #expect(ax.value(atLocal: kfT(3)) == 0)
    expectSameCurve(ax, x); expectSameCurve(ay, y)
}

/// A key inserted into an eased segment splits it: both halves get renormalised handles, the curve is unchanged.
@Test func pairAligningSplitsEasedSegmentExactly() {
    for (out, inH) in [(EaseHandle(dx: 0.5, dy: 0), EaseHandle(dx: 0.25, dy: 0)),
                       (EaseHandle(dx: 0.3, dy: 0.6), EaseHandle(dx: 0.7, dy: -0.2)),
                       (EaseHandle(dx: 0.9, dy: 0.1), EaseHandle(dx: 0.05, dy: 0.4))] {
        let x = prop([eased(0, 0, out: out), eased(4, 40, in: inH)])
        let y = prop([kfKey(1, 1), kfKey(3, 2)])   // no shared time (there Y would take X's easing by design)
        let (ax, ay) = KeyframesPair.aligning(x, y)
        #expect(ax.track.keys.map(\.time) == [kfT(0), kfT(1), kfT(3), kfT(4)])
        #expect(ax.track.keys.first?.id == x.track.keys.first?.id && ax.track.keys.last?.id == x.track.keys.last?.id)
        expectSameCurve(ax, x); expectSameCurve(ay, y)
    }
}

// MARK: Pair row edits (editable / split)

@Test func pairEditableReadsBothMembersAsOneVec2() {
    let x = prop([kfKey(0, 0), kfKey(4, 40)], 1)
    let y = prop([kfKey(0, 10), kfKey(2, 30)], 2)                  // other key times (Stabilizer-like)
    let v = KeyframesPair.editable(x, y)
    #expect(v.track.keys.map(\.time) == [kfT(0), kfT(2), kfT(4)])
    for s in [0.0, 1, 2, 3, 4] {
        let t = Time(Int64(s * 10), 10)
        #expect(abs(v.value(atLocal: t).x - x.value(atLocal: t)) < 1e-9)
        #expect(abs(v.value(atLocal: t).y - y.value(atLocal: t)) < 1e-9)
    }
    #expect(v.track.keys.first?.id == x.track.keys.first?.id)       // X's ids lead
    let still = KeyframesPair.editable(prop([], 3), prop([], 4))
    #expect(still.value == Vec2(3, 4) && !still.isAnimated)
}

@Test func pairSplitRoundTripKeepsIDsAndCurves() {
    let x = prop([kfKey(0, 0), kfKey(2, 20)])
    let y = prop([kfKey(0, 5), kfKey(2, 7)])
    let (sx, sy) = KeyframesPair.split(KeyframesPair.editable(x, y), yIDsFrom: y)
    #expect(sx == x && sy == y)
}

@Test func pairEditThroughVec2WritesBothMembersAligned() {
    var x = prop([eased(0, 0, out: EaseHandle(dx: 0.5, dy: 0)), kfKey(4, 40)])
    var y = prop([kfKey(0, 10), kfKey(4, 10)])
    KeyframesPair.edit(&x, &y) { v in
        v.track.insert(Keyframe(time: kfT(2), value: Vec2(99, 77)))
    }
    #expect(KeyframesPair.isAligned(x, y))
    #expect(x.track.keys.map(\.time) == [kfT(0), kfT(2), kfT(4)])
    #expect(x.value(atLocal: kfT(2)) == 99 && y.value(atLocal: kfT(2)) == 77)
    let newX = x.track.keys[1].id, newY = y.track.keys[1].id
    #expect(newX != newY)                                           // members never share key ids
    #expect(y.track.keys[0].outHandle == x.track.keys[0].outHandle) // Y follows X's easing on a pair edit
}

@Test func pairEditStaticValue() {
    var x = prop([], 1), y = prop([], 2)
    KeyframesPair.edit(&x, &y) { $0.value = Vec2(5, 6) }
    #expect(x.value == 5 && y.value == 6 && !x.isAnimated && !y.isAnimated)
}

@Test func transformEffectParamsFollowMotionOrder() {
    // Same order as Transform (Motion): Position, Scale, Rotation, Anchor, Opacity, Shutter Angle.
    #expect(EffectTransformStage.transformSpec.params.map(\.key) == [
        ClipEffect.stagePositionXKey, ClipEffect.stagePositionYKey, ClipEffect.stageScaleKey, ClipEffect.stageScaleYKey, ClipEffect.stageRotationKey,
        ClipEffect.stageAnchorXKey, ClipEffect.stageAnchorYKey, ClipEffect.stageOpacityKey, ClipEffect.stageShutterAngleKey,
    ])
}
