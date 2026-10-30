import Testing
@testable import SQInspectorUI

@Suite struct EaseHandleDragMathTests {
    @Test func staysHorizontalInsideTheDeadZone() {
        #expect(!EaseHandleDragMath.isVertical(wasVertical: false, pressY: 50, y: 55.9, shift: false))
        #expect(!EaseHandleDragMath.isVertical(wasVertical: false, pressY: 50, y: 44.1, shift: false))
    }
    @Test func followsVerticallyPastTheDeadZoneAndLatches() {
        #expect(EaseHandleDragMath.isVertical(wasVertical: false, pressY: 50, y: 56.5, shift: false))
        #expect(EaseHandleDragMath.isVertical(wasVertical: true, pressY: 50, y: 50, shift: false))
    }
    @Test func shiftForcesHorizontal() {
        #expect(!EaseHandleDragMath.isVertical(wasVertical: true, pressY: 50, y: 90, shift: true))
        #expect(!EaseHandleDragMath.isVertical(wasVertical: false, pressY: 50, y: 90, shift: true))
    }
    @Test func speedKeepsOrFollowsAndClamps() {
        #expect(EaseHandleDragMath.speed(vertical: false, pointer: 9, kept: 1.5, reach: 0.5, valueRange: -2...3) == 1.5)
        #expect(EaseHandleDragMath.speed(vertical: true, pointer: 2, kept: 1, reach: 0.5, valueRange: -2...3) == 2)
        #expect(EaseHandleDragMath.speed(vertical: true, pointer: 99, kept: 1, reach: 0.5, valueRange: -2...3) == 6)
        #expect(EaseHandleDragMath.speed(vertical: true, pointer: -99, kept: 1, reach: 0.5, valueRange: 0...1) == 0)
        #expect(EaseHandleDragMath.speed(vertical: true, pointer: 99, kept: 1, reach: 1, valueRange: nil) == 99)
    }
}
