import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

// AUDIT A7: overlay toggles a user sets on purpose survive a relaunch (per Mac): rulers, hidden guide layers, aspect frame,
// safe-margin sizes. The Source monitor stores nothing.
@MainActor @Suite(.serialized) struct MonitorOverlayPersistenceTests {
    private static let keys = [MonitorPanelModel.rulersKey, MonitorPanelModel.overlaysHiddenKey, MonitorPanelModel.aspectFrameKey,
                               MonitorPanelModel.safeMarginActionKey, MonitorPanelModel.safeMarginTitleKey]
    private func reset() { for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) } }

    @Test func overlaySettingsComeBackInTheNextModel() {
        reset(); defer { reset() }
        let first = MonitorPanelModel(frameDuration: Time(1, 30))
        #expect(!first.showsRulers && !first.overlaysHidden && first.aspectFrame == .off)
        first.showsRulers = true
        first.overlaysHidden = true
        first.aspectFrame = .vertical9x16
        first.safeMarginSizes = SafeMarginSizes(action: 93, title: 85)
        let next = MonitorPanelModel(frameDuration: Time(1, 30))
        #expect(next.showsRulers && next.overlaysHidden && next.aspectFrame == .vertical9x16)
        #expect(next.safeMarginSizes == SafeMarginSizes(action: 93, title: 85))
    }

    @Test func theSourceMonitorStoresAndReadsNothing() {
        reset(); defer { reset() }
        let source = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        source.showsRulers = true
        source.aspectFrame = .square1x1
        #expect(UserDefaults.standard.object(forKey: MonitorPanelModel.rulersKey) == nil)
        let program = MonitorPanelModel(frameDuration: Time(1, 30))
        #expect(!program.showsRulers && program.aspectFrame == .off)
    }

    @Test func aBrokenStoredFrameFallsBackToOff() {
        reset(); defer { reset() }
        UserDefaults.standard.set("nonsense", forKey: MonitorPanelModel.aspectFrameKey)
        #expect(MonitorPanelModel(frameDuration: Time(1, 30)).aspectFrame == .off)
    }
}
