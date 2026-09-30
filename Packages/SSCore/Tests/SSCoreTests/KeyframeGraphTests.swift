import Foundation
import Testing
@testable import SSCore

@Test func kfValueGraphLinear() {
    let tr = KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 10), kfKey(4, 10)])
    let g = tr.valueGraph(samples: 3)
    #expect(g.count == 2)
    #expect(g[0].samples.map(\.time) == [0, 1, 2])
    #expect(g[0].samples.map(\.value) == [0, 5, 10])
    #expect(g[1].samples.map(\.value) == [10, 10, 10])
    #expect(g[0].fromID == tr.keys[0].id && g[0].toID == tr.keys[1].id)
}

@Test func kfSpeedGraphLinearIsConstant() {
    let tr = KeyframeTrack(keys: [kfKey(0, 0), kfKey(2, 10)])
    for s in tr.speedGraph(samples: 5)[0].samples { #expect(abs(s.speed - 5) < 1e-5) }
}

@Test func kfSpeedGraphHoldIsZeroAndNegativeIsSigned() {
    let tr = KeyframeTrack(keys: [kfKey(0, 0, .hold), kfKey(2, 10), kfKey(4, 0)])
    #expect(tr.speedGraph(samples: 3)[0].samples.allSatisfy { $0.speed == 0 })
    #expect(tr.speedGraph(samples: 3)[1].samples.allSatisfy { $0.speed < 0 })
}

@Test func kfSpeedGraphEasyEaseStartsAtZero() {
    var a = kfKey(0, 0, .bezier); a.outHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    var b = kfKey(2, 10); b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    let s = KeyframeTrack(keys: [a, b]).speedGraph(samples: 11)[0].samples
    #expect(s.first!.speed < 0.2)
    #expect(s.last!.speed < 0.2)
    #expect(s[5].speed > 5)
}

@Test func kfSpeedGraphVec2IsMagnitude() {
    let a = Keyframe(time: kfT(0), value: Vec2(0, 0))
    let b = Keyframe(time: kfT(10), value: Vec2(30, 40))
    let s = KeyframeTrack(keys: [a, b]).speedGraph(samples: 3)[0].samples
    #expect(s.allSatisfy { abs($0.speed - 5) < 1e-5 })
}

@Test func kfSpeedHandleConversion() {
    let h = EaseHandle(dx: 1.0 / 3, dy: 1.0 / 3)
    let sh = h.speedHandle(valueDelta: 10, duration: kfT(2))
    #expect(abs(sh.speed - 5) < 1e-9)
    #expect(abs(sh.influence - 1.0 / 3) < 1e-9)
    let back = EaseHandle(speedHandle: SpeedHandle(speed: 10, influence: 0.5), valueDelta: 10, duration: kfT(2))
    #expect(abs(back.dx - 0.5) < 1e-9)
    #expect(abs(back.dy - 1.0) < 1e-9) // slope 10 / (10/2) = 2, times dx 0.5
    #expect(EaseHandle(speedHandle: SpeedHandle(speed: 3, influence: 0.4), valueDelta: 0, duration: kfT(2)).dy == 0)
    #expect(EaseHandle(dx: 0, dy: 1).speedHandle(valueDelta: 10, duration: kfT(2)).speed == 0)
}
