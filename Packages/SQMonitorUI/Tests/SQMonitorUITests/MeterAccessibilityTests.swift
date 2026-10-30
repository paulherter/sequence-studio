import AppKit
import Testing
@testable import SQMonitorUI

@MainActor
@Suite struct MeterAccessibilityTests {
    @Test func silentMeterSaysSilent() {
        let m = AudioMeterView(frame: .zero)
        #expect(m.accessibilityLevels == "Left, silent. Right, silent")
        #expect(m.accessibilityRole() == .levelIndicator)
    }

    @Test func levelAndClipAreSpoken() {
        let m = AudioMeterView(frame: .zero)
        m.update(peaks: [0.25, 1.0])
        #expect(m.accessibilityLevels == "Left, minus 12.0 dB. Right, clipped")
    }

    @Test func monoUsesOneChannel() {
        let m = AudioMeterView(frame: .zero)
        m.isMono = true
        #expect(m.accessibilityLevels == "Mono, silent")
    }
}
