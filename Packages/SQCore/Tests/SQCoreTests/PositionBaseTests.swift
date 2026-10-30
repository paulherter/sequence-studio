import Testing
import Foundation
@testable import SQCore

/// Moving a keyed text or graphic position moves the whole animation (keys keep their offsets from the base).
@Suite struct PositionBaseTests {
    private func flyIn() -> AnimatedProperty<Vec2> {
        var p = AnimatedProperty(Vec2(0, 0))
        p.track.insert(Keyframe(time: .zero, value: Vec2(-500, 0)))
        p.track.insert(Keyframe(time: Time(1, 2), value: Vec2(0, 0)))
        return p
    }

    @Test func keyedPositionShiftsEveryKeyByTheMove() {
        let moved = flyIn().movedBase(to: Vec2(100, 40), atLocal: Time(1, 2))
        #expect(moved.track.keys.map(\.value) == [Vec2(-400, 40), Vec2(100, 40)])
        #expect(moved.track.keys.count == 2)
        #expect(moved.value(atLocal: Time(1, 2)) == Vec2(100, 40))
    }

    @Test func moveFromMidFlightKeepsShape() {
        let p = flyIn()
        let at = Time(1, 4)
        let before = p.value(atLocal: at)
        let moved = p.movedBase(to: before + Vec2(30, 0), atLocal: at)
        #expect(moved.track.keys.map(\.value) == [Vec2(-470, 0), Vec2(30, 0)])
        #expect(moved.track.keys.map(\.time) == p.track.keys.map(\.time))
    }

    @Test func staticPositionTakesTheValue() {
        let moved = AnimatedProperty(Vec2(5, 5)).movedBase(to: Vec2(9, 9), atLocal: .zero)
        #expect(moved.value == Vec2(9, 9))
        #expect(!moved.isAnimated)
    }
}
