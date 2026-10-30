import Foundation
import Testing
@testable import SQCore

private func vk(_ s: Int64, _ x: Double) -> Keyframe<Vec2> {
    Keyframe(id: UUID(), time: kfT(s), value: Vec2(x, 0), interpolation: .linear)
}

@Test func kfRoveEvensOutSpeedAlongPath() {
    // Middle key at 90 % of the distance but 5 s in: roving puts it at 9 s of 10.
    let a = vk(0, 0), b = vk(5, 90), c = vk(10, 100)
    var tr = KeyframeTrack(keys: [a, b, c])
    let r1 = tr.rove([b.id])
    #expect(r1)
    #expect(tr.keys[1].time == kfT(9))
    #expect(tr.keys.map(\.value) == [a.value, b.value, c.value])
}

@Test func kfRoveKeepsFirstLastAndUnselected() {
    let ks = [vk(0, 0), vk(2, 10), vk(4, 50), vk(10, 90)]
    var tr = KeyframeTrack(keys: ks)
    let r2 = tr.rove([ks[0].id, ks[3].id])
    #expect(!r2)
    let r3 = tr.rove([ks[2].id])
    #expect(r3)
    #expect(tr.keys[1].time == kfT(2))
    #expect(tr.keys[2].time == kfT(6))
}

@Test func kfScaleTimesAboutPivot() {
    let ks = [kfKey(0, 0), kfKey(2, 1), kfKey(4, 2)]
    var tr = KeyframeTrack(keys: ks)
    let s1 = tr.scaleTimes([ks[1].id, ks[2].id], by: 2, over: 1, about: kfT(0))
    #expect(s1)
    #expect(tr.keys.map(\.time) == [kfT(0), kfT(4), kfT(8)])
    let s2 = tr.scaleTimes([ks[1].id], by: 1, over: 1, about: kfT(0))
    #expect(!s2)
}

@Test func kfVelocityRoundTrip() {
    let h = KeyVelocity.handle(speed: 300, influence: 0.5, averageSpeed: 100)
    #expect(h == EaseHandle(dx: 0.5, dy: 1.5))
    let n = KeyVelocity.numbers(of: h!, averageSpeed: 100)
    #expect(n.speed == 300 && n.influence == 0.5)
    #expect(KeyVelocity.handle(speed: 1, influence: 0.5, averageSpeed: 0) == nil)
}
