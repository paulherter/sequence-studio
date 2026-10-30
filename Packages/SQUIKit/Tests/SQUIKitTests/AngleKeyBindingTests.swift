import Testing
@testable import SQUIKit

/// F7.16: the digits 1-9 switch the angle in the Timeline and the Program monitor only; other panels keep them for typing.
@Suite struct AngleKeyBindingTests {
    @Test func digitsSwitchAnglesOnlyInTimelineAndProgram() {
        let map = CommandMap.premiereDefault
        for n in 1...9 {
            let b = KeyBinding(.char(Character(String(n))))
            #expect(map.command(for: b, focus: .timeline) == .switchAngle(n))
            #expect(map.command(for: b, focus: .programMonitor) == .switchAngle(n))
            #expect(map.command(for: b, focus: .effects) != .switchAngle(n))
            #expect(map.command(for: b, focus: nil) != .switchAngle(n))
        }
        #expect(map.duplicates.isEmpty)
    }
}
