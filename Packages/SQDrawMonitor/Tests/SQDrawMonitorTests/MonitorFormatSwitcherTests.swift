import Foundation
import SQCore
import SQEditorSession
import SQDrawKit
import Testing
@testable import SQDrawMonitor

@MainActor @Suite struct MonitorFormatSwitcherTests {
    private func session() -> EditorSession {
        EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    }

    @Test func syncConnectsTheSwitcherToTheSession() throws {
        let s = session(), m = MonitorPanelModel(frameDuration: Time(1, 25))
        m.syncFormats(from: s)
        let add = try #require(m.onAddFormat)
        add(SequenceConform.aspectPresets[0])
        m.syncFormats(from: s)
        #expect(m.formatItems.count == 1)
        #expect(m.formatCurrent == m.formatItems[0].id)          // adding shows the new format
        m.onPickFormat?(UUID?.none)
        m.syncFormats(from: s)
        #expect(m.formatCurrent == nil)
        m.onPickFormat?(m.formatItems[0].id)
        #expect(s.activeVariantID == m.formatItems[0].id)
        m.onRemoveFormat?(m.formatItems[0].id)
        m.syncFormats(from: s)
        #expect(m.formatItems.isEmpty)
    }

    @Test func programTitleAndPopupNameTheVariant() {
        let seq = UUID(), v = UUID()
        let items = [MonitorPanelModel.SequenceItem(id: seq, name: "Main")]
        let fmts = [MonitorPanelModel.FormatItem(id: v, name: "Vertical")]
        #expect(MonitorMenus.programTitle(items, current: seq, fallback: "", formats: fmts, format: nil) == "Main")
        #expect(MonitorMenus.programTitle(items, current: seq, fallback: "", formats: fmts, format: v) == "Main · Vertical")
        let rows = MonitorMenus.formatItems(base: "16:9", fmts, current: v, pick: { _ in }, add: { _ in }, remove: { _ in })
        #expect(rows.map(\.title).prefix(2) == ["16:9", "Vertical"])
    }
}
