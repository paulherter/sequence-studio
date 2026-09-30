import Foundation
import Testing
@testable import SSCore

private func posKey(_ s: Int64, _ x: Double, _ y: Double, inT: Vec2 = .zero, outT: Vec2 = .zero,
                    _ i: Interpolation = .linear) -> Keyframe<Vec2> {
    Keyframe(time: kfT(s), value: Vec2(x, y), interpolation: i, inTangent: inT, outTangent: outT)
}

@Test func kfVec2ZeroTangentsIsStraight() {
    let tr = KeyframeTrack(keys: [posKey(0, 0, 0), posKey(2, 100, 50)])
    #expect(tr.value(at: kfT(1)) == Vec2(50, 25))
}

@Test func kfSpatialCurveHasArcAndSymmetry() {
    let tr = KeyframeTrack(keys: [posKey(0, 0, 0, outT: Vec2(0, 100)), posKey(2, 100, 0, inT: Vec2(0, 100))])
    let mid = tr.value(at: kfT(1))!
    #expect(abs(mid.x - 50) < 1e-6)
    #expect(mid.y > 10)
    #expect(tr.value(at: kfT(0)) == Vec2(0, 0))
    #expect(tr.value(at: kfT(2)) == Vec2(100, 0))
}

@Test func kfSpatialLinearIsConstantSpeedAlongArc() {
    let tr = KeyframeTrack(keys: [posKey(0, 0, 0, outT: Vec2(0, 100)), posKey(4, 100, 0, inT: Vec2(0, 100))])
    let speeds = tr.speedGraph(samples: 9)[0].samples.map(\.speed)
    let mean = speeds.reduce(0, +) / Double(speeds.count)
    for s in speeds { #expect(abs(s - mean) / mean < 0.03) }
}

@Test func kfSpatialEaseMapsToArcLength() {
    var a = posKey(0, 0, 0, outT: Vec2(0, 100), .bezier)
    a.outHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    var b = posKey(2, 100, 0, inT: Vec2(0, 100))
    b.inHandle = EaseHandle(dx: 1.0 / 3, dy: 0)
    let tr = KeyframeTrack(keys: [a, b])
    let early = tr.value(at: Time(1, 10))!
    let late = tr.value(at: Time(19, 10))!
    #expect(early.y < 5)  // eased start barely moves
    #expect(abs(early.x - (100 - late.x)) < 1e-6)
}

@Test func kfMotionPathSampling() {
    let tr = KeyframeTrack(keys: [posKey(0, 0, 0, outT: Vec2(0, 100)), posKey(2, 100, 0, inT: Vec2(0, 100)),
                                  posKey(4, 100, 50, outT: .zero, .hold), posKey(6, 0, 0)])
    let path = tr.motionPath(samplesPerSegment: 16)
    #expect(path.count == 3)
    #expect(path[0].points.count == 16)
    #expect(path[0].points.first == Vec2(0, 0) && path[0].points.last == Vec2(100, 0))
    #expect(path[2].points == [Vec2(100, 50)]) // hold: no path
}

@Test func kfSpatialPathLength() {
    let p = SpatialPath(p0: Vec2(0, 0), p1: Vec2(10, 0), p2: Vec2(20, 0), p3: Vec2(30, 0))
    #expect(abs(p.length - 30) < 1e-6)
    #expect(abs(p.point(atArcFraction: 0.5).x - 15) < 1e-6)
}
