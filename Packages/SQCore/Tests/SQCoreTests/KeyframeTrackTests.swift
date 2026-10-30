import Foundation
import Testing
@testable import SQCore

func kfT(_ s: Int64) -> Time { Time(s, 1) }

func kfKey(_ s: Int64, _ v: Double, _ i: Interpolation = .linear) -> Keyframe<Double> {
    Keyframe(time: kfT(s), value: v, interpolation: i)
}

@Test func kfLinearInterpolation() {
    let tr = KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 10)])
    #expect(tr.value(at: kfT(1)) == 5)
    #expect(tr.value(at: Time(1, 2)) == 2.5)
}

@Test func kfClampAndConstant() {
    let tr = KeyframeTrack(keys: [kfKey(1, 3), kfKey(3, 7)])
    #expect(tr.value(at: kfT(0)) == 3)
    #expect(tr.value(at: kfT(9)) == 7)
    #expect(tr.value(at: kfT(3)) == 7)
    #expect(KeyframeTrack(keys: [kfKey(5, 4)]).value(at: kfT(0)) == 4)
    #expect(KeyframeTrack<Double>().value(at: kfT(0)) == nil)
}

@Test func kfHoldKeepsLeftValueUntilNextKey() {
    let tr = KeyframeTrack(keys: [kfKey(0, 1, .hold), kfKey(2, 9), kfKey(4, 9)])
    #expect(tr.value(at: Time(19, 10)) == 1)
    #expect(tr.value(at: kfT(2)) == 9)
}

@Test func kfBezierEasyEaseIsSymmetricAndSlowAtEnds() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    var b = kfKey(2, 10); b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    let tr = KeyframeTrack(keys: [a, b])
    #expect(abs(tr.value(at: kfT(1))! - 5) < 1e-9)
    #expect(tr.value(at: Time(1, 2))! < 2.5)
    #expect(tr.value(at: Time(3, 2))! > 7.5)
}

@Test func kfBezierLinearHandlesEqualLinear() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 1.0 / 3, dy: 1.0 / 3)
    var b = kfKey(4, 8); b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 1.0 / 3)
    let tr = KeyframeTrack(keys: [a, b])
    for n in 0...8 {
        let t = Time(Int64(n), 2)
        #expect(abs(tr.value(at: t)! - Double(n)) < 1e-7)
    }
}

@Test func kfBezierOvershootAllowed() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 0.3, dy: 1.6)
    var b = kfKey(2, 10); b.inHandle = EaseHandle(dx: 0.3, dy: 0)
    let tr = KeyframeTrack(keys: [a, b])
    let peak = (1..<20).map { tr.value(at: Time(Int64($0), 10))! }.max()!
    #expect(peak > 10)
}

@Test func kfInsertKeepsSortedUniqueTimes() {
    var tr = KeyframeTrack<Double>()
    tr.insert(kfKey(4, 4)); tr.insert(kfKey(0, 0)); tr.insert(kfKey(2, 2))
    #expect(tr.keys.map(\.time) == [kfT(0), kfT(2), kfT(4)])
    tr.insert(kfKey(2, 99))
    #expect(tr.keys.count == 3)
    #expect(tr.value(at: kfT(2)) == 99)
}

@Test func kfRemoveMoveSet() {
    let k0 = kfKey(0, 0), k1 = kfKey(2, 2), k2 = kfKey(4, 4)
    var tr = KeyframeTrack(keys: [k0, k1, k2])
    tr.set(k1.id, value: 7)
    #expect(tr.key(id: k1.id)?.value == 7)
    tr.move(k0.id, to: kfT(6))
    #expect(tr.keys.map(\.id) == [k1.id, k2.id, k0.id])
    // moved key wins on collision
    tr.move(k1.id, to: kfT(4))
    #expect(tr.keys.count == 2)
    #expect(tr.key(id: k2.id) == nil)
    #expect(tr.key(id: k1.id)?.time == kfT(4))
    tr.remove(k1.id)
    #expect(tr.keys.count == 1)
}

@Test func kfNextPrevious() {
    let k0 = kfKey(0, 0), k1 = kfKey(2, 2), k2 = kfKey(4, 4)
    let tr = KeyframeTrack(keys: [k0, k1, k2])
    #expect(tr.nextKey(of: k1.id)?.id == k2.id)
    #expect(tr.previousKey(of: k1.id)?.id == k0.id)
    #expect(tr.nextKey(of: k2.id) == nil)
    #expect(tr.previousKey(of: k0.id) == nil)
    #expect(tr.nextKey(after: kfT(1))?.id == k1.id)
    #expect(tr.previousKey(before: kfT(2))?.id == k0.id)
}

@Test func kfTrackCodableRoundTrip() throws {
    var a = kfKey(0, 1, .bezier); a.outHandle = EaseHandle(dx: 0.2, dy: 0.9)
    let tr = KeyframeTrack(keys: [a, kfKey(3, 2)])
    let back = try JSONDecoder().decode(KeyframeTrack<Double>.self, from: JSONEncoder().encode(tr))
    #expect(back == tr)
}

/// init(keys:) gives the same track on every path: empty, one key, sorted unique, unsorted, duplicate time/id.
@Test func kfInitKeysMatchesInsertingOneByOne() {
    func inserted(_ keys: [Keyframe<Double>]) -> KeyframeTrack<Double> {
        var t = KeyframeTrack<Double>(); for k in keys { t.insert(k) }; return t
    }
    let a = kfKey(0, 1), b = kfKey(2, 3), c = kfKey(4, 5)
    var sameID = kfKey(6, 9); sameID.id = a.id
    for keys in [[], [b], [a, b, c], [c, a, b], [a, kfKey(2, 7), b], [a, sameID]] {
        #expect(KeyframeTrack(keys: keys) == inserted(keys))
    }
    #expect(KeyframeTrack<Double>(keys: []).isEmpty)
    #expect(KeyframeTrack(keys: [b]).keys == [b])
}
