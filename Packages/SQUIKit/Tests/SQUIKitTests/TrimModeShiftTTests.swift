import Testing
@testable import SQUIKit

/// Parity audit 16: Premiere's Shift+T opens Trim mode; our own set keeps Shift+T for Keyword at Playhead.
@Suite struct TrimModeShiftTTests {
    private let shiftT = KeyBinding(.char("t"), .shift)
    private let ctrlShiftT = KeyBinding(.char("t"), [.control, .shift])

    @Test func premiereSetUsesShiftTForTrimMode() {
        let m = CommandMap.premiereDefault
        #expect(m.duplicates.isEmpty)
        #expect(m.command(for: shiftT, focus: .timeline) == .toggleTrimMode)
        #expect(m.command(for: shiftT, focus: .programMonitor) == .toggleTrimMode)
        #expect(!m.entries.contains { $0.command == .keywordAtPlayhead && $0.binding == shiftT })
    }

    @Test func sqSetKeepsKeywordOnShiftTAndTrimModeOnCtrlShiftT() {
        let m = CommandMap.sqDefault
        #expect(m.duplicates.isEmpty)
        #expect(m.command(for: shiftT, focus: .timeline) == .keywordAtPlayhead)
        #expect(m.command(for: ctrlShiftT, focus: .timeline) == .toggleTrimMode)
        #expect(m.command(for: ctrlShiftT, focus: .programMonitor) == .toggleTrimMode)
    }
}
