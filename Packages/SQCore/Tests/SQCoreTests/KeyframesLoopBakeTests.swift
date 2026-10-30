import Foundation
import Testing
@testable import SQCore

private func track() -> KeyframeTrack<Double> {
    KeyframeTrack(keys: [
        Keyframe(time: Time(0, 1), value: 0), Keyframe(time: Time(1, 1), value: 10), Keyframe(time: Time(2, 1), value: 0),
    ])
}

@Test func loopRepeatsPattern() {
    var t = track()
    t.loop(cycles: 2)
    #expect(t.keys.map(\.time) == (0...6).map { Time(Int64($0), 1) })
    #expect(t.keys.map(\.value) == [0, 10, 0, 10, 0, 10, 0])
    #expect(Set(t.keys.map(\.id)).count == 7)
}

@Test func loopNeedsTwoKeys() {
    var t = KeyframeTrack<Double>(keys: [Keyframe(time: .zero, value: 1)])
    t.loop(cycles: 3)
    #expect(t.keys.count == 1)
}

@Test func bakeSamplesKeepsEndsAndOutsideKeys() {
    var t = track()
    let ok = t.bakeSamples(from: Time(0, 1), to: Time(1, 1), samplesPerSecond: 4)
    #expect(ok)
    #expect(t.keys.count == 6)   // 5 samples in 0...1 plus the key at 2 s
    #expect(t.value(at: Time(1, 2)) == 5)
    #expect(t.keys.last?.value == 0)
}

@Test func wiggleIsDeterministicAndBounded() {
    let base = track()
    var a = track(), b = track()
    a.wiggle(from: Time(0, 1), to: Time(2, 1), perSecond: 10, amount: 3, seed: 7)
    b.wiggle(from: Time(0, 1), to: Time(2, 1), perSecond: 10, amount: 3, seed: 7)
    #expect(a.keys.map(\.value) == b.keys.map(\.value))
    #expect(a.keys.count == 21)
    #expect(a.keys.first?.value == 0 && a.keys.last?.value == 0)
    for k in a.keys { #expect(abs(k.value - (base.value(at: k.time) ?? 0)) <= 3) }
    var c = track()
    c.wiggle(from: Time(0, 1), to: Time(2, 1), perSecond: 10, amount: 3, seed: 8)
    #expect(c.keys.map(\.value) != a.keys.map(\.value))
}
