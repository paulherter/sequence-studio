import AppKit
import Testing
import SQAudioFX
@testable import SQMonitorUI

@MainActor @Suite struct MonitorVolumeControlTests {
    /// One suite per test instance; every test removes it again (`defer { cleanUp() }`).
    private let suite = "sq.test.monitorui.\(UUID().uuidString)"
    private func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    private func panel() -> (AudioMeterPanelView, UserDefaults) {
        let d = UserDefaults(suiteName: suite)!
        let p = AudioMeterPanelView(frame: NSRect(x: 0, y: 0, width: 80, height: 300), monitorDefaults: d)
        p.layout()
        return (p, d)
    }

    @Test func sliderAndDimWriteThePreference() {
        defer { cleanUp() }
        let (p, d) = panel()
        p.setMonitor(levelDB: -18)
        p.dimButton.handler?()
        let s = MonitorGain.Setting.current(defaults: d)
        #expect(s.levelDB == -18 && s.dim && p.dimButton.isSelected)
        p.dimButton.handler?()
        #expect(!MonitorGain.Setting.current(defaults: d).dim)
    }

    @Test func controlFitsTheSlimPanelAndHidesWhenTooShort() {
        defer { cleanUp() }
        let (p, _) = panel()
        #expect(!p.monitorSlider.isHidden && p.monitorSlider.frame.maxX <= 80 && p.dimButton.frame.maxY <= 300)
        #expect(p.meter.frame.maxY <= p.monitorSlider.frame.minY)
        p.frame = NSRect(x: 0, y: 0, width: 56, height: 80)
        p.layout()
        #expect(p.monitorSlider.isHidden && p.dimButton.isHidden)
    }

    @Test func slimMeterKeepsVolumeAndDimInItsMenu() {
        defer { cleanUp() }
        let (p, d) = panel()
        p.frame = NSRect(x: 0, y: 0, width: 56, height: 300)
        p.layout()
        #expect(p.monitorSlider.isHidden && p.dimButton.isHidden && p.meter.frame.height == 300)
        let items = p.monitorItems()
        items.first { $0.title == "\u{2212}12 dB" }?.action?()
        items.first { $0.title == "Dim Monitor" }?.action?()
        let s = MonitorGain.Setting.current(defaults: d)
        #expect(s.levelDB == -12 && s.dim)
        #expect(p.monitorItems().first { $0.title == "\u{2212}12 dB" }?.isChecked == true)
    }

    @Test func stripHidesOnVeryNarrowPanelWithoutNegativeWidth() {
        defer { cleanUp() }
        let (p, _) = panel()
        p.frame = NSRect(x: 0, y: 0, width: 10, height: 300)
        p.layout()
        #expect(p.monitorSlider.isHidden && p.dimButton.isHidden && p.monitorSlider.frame.width >= 0)
    }
}
