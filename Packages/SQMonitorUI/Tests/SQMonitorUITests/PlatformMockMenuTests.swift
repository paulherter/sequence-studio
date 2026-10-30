import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

@MainActor
@Suite struct PlatformMockMenuTests {
    @Test func rowIsDisabledWithoutAVerticalPlatformAndTogglesWithOne() {
        var set: Bool?
        let off = MonitorMenus.platformMockItems(isOn: true, available: false, set: { set = $0 })
        #expect(off.map(\.title) == ["", "Show platform UI"])
        #expect(off[1].isEnabled == false && off[1].isChecked == false)
        let on = MonitorMenus.platformMockItems(isOn: false, available: true, set: { set = $0 })
        #expect(on[1].isEnabled)
        on[1].action?()
        #expect(set == true)
    }

    @Test func choiceIsRemembered() {
        let d = UserDefaults.standard
        let old = d.object(forKey: SafeZoneChoice.mockDefaultsKey)
        defer { if let old { d.set(old, forKey: SafeZoneChoice.mockDefaultsKey) } else { d.removeObject(forKey: SafeZoneChoice.mockDefaultsKey) } }
        d.removeObject(forKey: SafeZoneChoice.mockDefaultsKey)
        #expect(SafeZoneChoice.storedMock == false)
        SafeZoneChoice.rememberMock(true)
        #expect(SafeZoneChoice.storedMock)
    }
}
