import Foundation
import Testing
import CoreGraphics
import SQCore
import SQPlayback
import SQUIKit
@testable import SQMonitorUI

@MainActor @Suite struct SafeMarginsSingleValueTests {
    @Test func monitorMenuAndViewMenuShareOneStoredValue() {
        let d = UserDefaults.standard
        let old = d.object(forKey: MonitorPanelModel.safeMarginsKey)
        defer { if let old { d.set(old, forKey: MonitorPanelModel.safeMarginsKey) } else { d.removeObject(forKey: MonitorPanelModel.safeMarginsKey) } }
        d.set(false, forKey: MonitorPanelModel.safeMarginsKey)
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        #expect(!m.safeMargins)
        // View menu writes through the model (EditorPanels.toggleSafeMargins); the monitor menu reads the same value.
        m.safeMargins.toggle()
        #expect(MonitorPanelModel.storedSafeMargins)
        let panel = MonitorPanelView(model: m)
        #expect(panel.optionItems().first { $0.title == "Safe Margins" }?.isChecked == true)
        m.safeMargins.toggle()    // the monitor menu runs the same toggle in EditorPanels
        #expect(panel.optionItems().first { $0.title == "Safe Margins" }?.isChecked == false)
        #expect(!m.safeMargins)
        #expect(!MonitorPanelModel.storedSafeMargins)
        #expect(!MonitorPanelModel(frameDuration: Time(1, 30), mode: .program).safeMargins)
        d.set(true, forKey: MonitorPanelModel.safeMarginsKey)
        #expect(MonitorPanelModel(frameDuration: Time(1, 30), mode: .program).safeMargins)
    }
}

@MainActor @Suite struct ViewerFrameMenuTests {
    @Test func aspectFrameAndMarginRowsDriveTheModel() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        let panel = MonitorPanelView(model: m)
        let frame = panel.optionItem("Aspect Frame")
        #expect(frame?.submenu?.count == AspectFrame.allCases.count)
        frame?.submenu?.first { $0.title == "9:16" }?.action?()
        #expect(m.aspectFrame == .vertical9x16)
        let sizes = panel.optionItem("Safe Margin Sizes")
        sizes?.submenu?.first { $0.title == "Action Safe" }?.submenu?.first { $0.title == "95%" }?.action?()
        #expect(m.safeMarginSizes.action == 95)
    }

    @Test func previewSpeedRowOnlyWithAHostAndReportsChanges() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        let panel = MonitorPanelView(model: m)
        #expect(panel.optionItem("Preview Speed") == nil)
        var got: [PreviewRate] = []
        m.onPreviewRateChange = { got.append($0) }
        let row = panel.optionItem("Preview Speed")
        #expect(row?.submenu?.count == PreviewRate.presets.count)
        row?.submenu?.last?.action?()
        m.setPreviewRate(PreviewRate.presets.last!)   // same value: no second report
        #expect(got == [PreviewRate.presets.last!])
    }
}

extension MonitorPanelView {
    /// A row of the "..." menu by title, also inside the Overlays / Playback / Compare submenus.
    func optionItem(_ title: String) -> SQMenuItem? {
        func find(_ rows: [SQMenuItem]) -> SQMenuItem? {
            for r in rows {
                if r.title == title { return r }
                if let sub = r.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        return find(optionItems())
    }
}

@MainActor @Suite struct MonitorMenuGroupsTests {
    @Test func programMenuGroupsOverlaysPlaybackAndCompare() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        m.onPreviewRateChange = { _ in }
        let panel = MonitorPanelView(model: m)
        let top = panel.optionItems()
        let titles = top.map(\.title)
        #expect(titles.contains("Overlays") && titles.contains("Playback") && titles.contains("Compare"))
        // Rows that moved are no longer in the flat list.
        for moved in ["Rulers", "Transparency Grid", "Aspect Frame", "Frame Format", "View Gamma", "Preview Speed"] { #expect(!titles.contains(moved)) }
        #expect(top.first { $0.title == "Overlays" }?.submenu?.contains { $0.title == "Rulers" } == true)
        #expect(top.first { $0.title == "Compare" }?.submenu?.map(\.title) == ["Frame Format", "Aspect Frame"])
        #expect(top.first { $0.title == "Playback" }?.submenu?.map(\.title) == ["Preview Speed", "View Gamma", "Display View"])
    }

    @Test func aGroupOfOneRowIsInlined() {
        let rows = MonitorMenus.grouped(base: [SQMenuItem(title: "Zoom")], overlays: [SQMenuItem(title: "Resolution Badge")],
                                        playback: [SQMenuItem(title: "A"), SQMenuItem(title: "B")], compare: [])
        #expect(rows.map(\.title) == ["Zoom", "", "Resolution Badge", "Playback"])
        #expect(rows[1].kind == .separator)
    }

    @Test func sourceMonitorKeepsItsShortList() {
        let panel = MonitorPanelView(model: MonitorPanelModel(frameDuration: Time(1, 30), mode: .source))
        #expect(!panel.optionItems().contains { $0.title == "Compare" || $0.title == "Overlays" })
    }
}
