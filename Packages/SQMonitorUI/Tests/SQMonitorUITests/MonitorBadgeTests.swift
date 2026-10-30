import Testing
import SQCore
@testable import SQMonitorUI

@MainActor @Suite struct MonitorBadgeTests {
    private func model() -> MonitorPanelModel { MonitorPanelModel(frameDuration: Time(1, 25)) }

    @Test func zoomAndQualityHaveTheirOwnPopups() {
        let m = model()
        #expect(m.badgeText == "Fit")
        #expect(m.qualityBadgeText == "Full")
        m.setQuality(.half)
        #expect(m.badgeText == "Fit")
        #expect(m.qualityBadgeText == "1/2")
        m.setZoom(.percent(150)); m.setQuality(.quarter)
        #expect(m.badgeText == "150 %")
        #expect(m.qualityBadgeText == "1/4")
    }

    /// Board `.vbadge` on the Edit page: one popup on the picture, "Fit · ½", holding zoom and quality.
    @Test func pictureBadgeCombinesZoomAndQuality() {
        let m = model()
        #expect(m.pictureBadgeText == "Fit · Full")
        m.setQuality(.half)
        #expect(m.pictureBadgeText == "Fit · ½")
        m.setZoom(.percent(150)); m.setQuality(.quarter)
        #expect(m.pictureBadgeText == "150 % · ¼")
        let rows = m.pictureBadgeMenu()
        #expect(rows.filter(\.isChecked).map(\.title) == ["150 %", "1/4"])
        rows.first { $0.title == "1/2" }?.action?()
        #expect(m.quality == .half)
    }

    @Test func menusCheckCurrentAndRunActions() {
        let m = model()
        m.setZoom(.percent(50)); m.setQuality(.half)
        let zoom = m.zoomMenu(), quality = m.qualityMenu()
        #expect(zoom.filter(\.isChecked).map(\.title) == ["50 %"])
        #expect(quality.filter(\.isChecked).map(\.title) == ["1/2"])
        #expect(!zoom.contains { $0.title == "1/4" })
        zoom.first { $0.title == "100 %" }?.action?()
        quality.first { $0.title == "1/4" }?.action?()
        #expect(m.zoom == .percent(100))
        #expect(m.quality == .quarter)
    }

    @Test func qualityChangeReportsToTheHost() {
        let m = model()
        var got: MonitorQuality?
        m.onQualityChange = { got = $0 }
        m.qualityMenu().first { $0.title == "1/2" }?.action?()
        #expect(got == .half)
    }

    /// Color page: zoom and quality merge into one pill on the picture with both menus.
    @Test func badgeOnPictureMergesZoomAndQuality() {
        #expect(MonitorPanelView.pictureBadgeTitle(zoom: "Fit", quality: "1/2") == "Fit · ½")
        #expect(MonitorPanelView.pictureBadgeTitle(zoom: "150 %", quality: "Full") == "150 % · Full")
        let v = MonitorPanelView(model: model())
        v.badgeOnPicture = true
        let titles = v.headerBadgeItemsForTesting
        #expect(titles.contains("Fit") && titles.contains("1/2"))
        v.badgeOnPicture = false
        #expect(!v.headerBadgeItemsForTesting.contains("1/2"))
    }
}
