import Foundation
import Testing
@testable import SSEditorUI

@Suite struct LayoutMetricsTests {
    @Test func fractionsAboveMinimumsAreKept() {
        let f = LayoutMetrics.clampedFractions([0.5, 0.5], length: 1000, mins: [100, 100])
        #expect(abs(f[0] - 0.5) < 1e-9 && abs(f[1] - 0.5) < 1e-9)
    }

    @Test func smallPaneIsRaisedAndOthersGiveWay() {
        let f = LayoutMetrics.clampedFractions([0.02, 0.48, 0.5], length: 1000, mins: [200, 100, 100])
        #expect(abs(f.reduce(0, +) - 1) < 1e-9)
        #expect(f[0] * 1000 >= 200 - 1e-6)
        #expect(f[1] * 1000 >= 100 && f[2] * 1000 >= 100)
        // The two big panes keep their ratio.
        #expect(abs(f[1] / f[2] - 0.48 / 0.5) < 1e-9)
    }

    @Test func cascadingMinimums() {
        // Shrinking the window: every pane ends at its minimum or above, total stays the window.
        let mins = [300.0, 240, 200]
        for length in stride(from: 740.0, through: 2000, by: 37) {
            let f = LayoutMetrics.clampedFractions([0.6, 0.25, 0.15], length: length, mins: mins)
            #expect(abs(f.reduce(0, +) - 1) < 1e-9)
            for (i, m) in mins.enumerated() { #expect(f[i] * length >= m - 1e-6, "pane \(i) at \(length)") }
        }
    }

    @Test func minimumsThatDoNotFitShareProportionally() {
        let f = LayoutMetrics.clampedFractions([0.5, 0.5], length: 100, mins: [300, 100])
        #expect(abs(f[0] - 0.75) < 1e-9 && abs(f[1] - 0.25) < 1e-9)
    }

    @Test func degenerateInputs() {
        #expect(LayoutMetrics.clampedFractions([], length: 100, mins: []).isEmpty)
        let zero = LayoutMetrics.clampedFractions([0.5, 0.5], length: 0, mins: [10, 10])
        #expect(zero == [0.5, 0.5])
        let nan = LayoutMetrics.clampedFractions([.nan, 1], length: 400, mins: [50, 50])
        #expect(abs(nan.reduce(0, +) - 1) < 1e-9 && nan[0] * 400 >= 50 - 1e-6)
    }

    @Test func dividerClamp() {
        #expect(LayoutMetrics.clampedDivider(10, start: 0, end: 500, minBefore: 100, minAfter: 100) == 100)
        #expect(LayoutMetrics.clampedDivider(450, start: 0, end: 500, minBefore: 100, minAfter: 100) == 400)
        #expect(LayoutMetrics.clampedDivider(250, start: 0, end: 500, minBefore: 100, minAfter: 100) == 250)
        #expect(LayoutMetrics.clampedDivider(0, start: 0, end: 150, minBefore: 100, minAfter: 100) == 75)
    }

    @Test func minSizeRollsUpTheTree() {
        let group = LayoutNode.tabs(panels: [.timeline], selected: .timeline)
        let s = LayoutMetrics.minSize(of: group)
        #expect(s.width == PanelID.timeline.minSize.width)
        #expect(s.height == PanelID.timeline.minSize.height + PanelID.headerHeight)
        let row = LayoutNode.split(axis: .horizontal, children: [group, group], fractions: [0.5, 0.5])
        #expect(LayoutMetrics.minSize(of: row).width == 2 * s.width + LayoutMetrics.dividerThickness)
        #expect(LayoutMetrics.minSize(of: row).height == s.height)
        let col = LayoutNode.split(axis: .vertical, children: [group, group], fractions: [0.5, 0.5])
        #expect(LayoutMetrics.minSize(of: col).height == 2 * s.height + LayoutMetrics.dividerThickness)
    }

    @Test func builtInLayoutsFitTheWindowMinimum() {
        for w in Workspace.builtIns + [Workspace.color] {
            let m = w.minimumContentSize
            #expect(m.width > 0 && m.width <= 1000, "\(w.name) width \(m.width)")
            #expect(m.height > 0 && m.height <= 600, "\(w.name) height \(m.height)")
        }
    }

    @Test func maximizedPanelNeedsOnlyItself() {
        var w = Workspace.editingPC
        w.toggleMaximize(.timeline)
        #expect(w.minimumContentSize.width == PanelID.timeline.minSize.width)
    }
}

@Suite struct WorkspaceMigrationTests {
    private func legacyJSON() -> Data {
        Data("""
        {"name":"Old","hidden":["properties","effects"],"maximized":"properties",
         "root":{"tabs":{"panels":["effectControls","text","properties"],"selected":"properties"}}}
        """.utf8)
    }

    @Test func propertiesIsDroppedEverywhere() throws {
        let fixed = WorkspaceMigration.dropUnknownPanels(legacyJSON())
        let w = try JSONDecoder().decode(Workspace.self, from: fixed)
        #expect(w.root == .tabs(panels: [.effectControls, .text], selected: .effectControls))
        #expect(w.hidden == [.effects])
        #expect(w.maximized == nil)
    }

    @Test func currentLayoutsPassThroughUnchanged() throws {
        let data = try JSONEncoder().encode(Workspace.editingPC)
        let back = try JSONDecoder().decode(Workspace.self, from: WorkspaceMigration.dropUnknownPanels(data))
        #expect(back == Workspace.editingPC)
    }

    @Test func storeWithLegacyPanelsLoads() throws {
        let store = WorkspaceStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ss-mig-\(UUID().uuidString)/workspaces.json")
        try store.save(to: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        // Re-introduce the removed panel into the saved file (first tab group that lists effectControls).
        text = text.replacingOccurrences(of: "\"text\"", with: "\"text\", \"properties\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = WorkspaceStore.load(from: url)
        #expect(loaded.current.validationProblems.isEmpty)
        #expect(loaded.library.all.count == Workspace.builtIns.count)
        #expect(!loaded.current.allPanels.map(\.rawValue).contains("properties"))
    }

    @Test func oldColorPageIsReplacedByTheNewLayout() throws {
        var store = WorkspaceStore()
        store.colorWorkspace = Workspace(name: "Color", root: .tabs(panels: [.programMonitor, .timeline], selected: .timeline))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ss-mig-\(UUID().uuidString)/workspaces.json")
        try store.save(to: url)
        #expect(WorkspaceStore.load(from: url).colorWorkspace == Workspace.color)
    }

    @Test func windowMenuCanShowAPanelTheLayoutLacks() {
        var w = Workspace(name: "Mine", root: .split(axis: .horizontal, children: [
            .tabs(panels: [.effectControls], selected: .effectControls),
            .tabs(panels: [.timeline], selected: .timeline),
        ], fractions: [0.5, 0.5]))
        #expect(!w.isVisible(.colorInspector))
        w.toggle(.colorInspector)
        #expect(w.isVisible(.colorInspector))
        #expect(w.validationProblems.isEmpty)
        w.toggle(.colorInspector)
        #expect(!w.isVisible(.colorInspector))
    }
}

@Suite struct WindowMenuTests {
    @Test func everyPanelHasAMenuItemOnce() {
        #expect(Set(EditorMenus.windowPanels) == Set(PanelID.allCases))
        #expect(EditorMenus.windowPanels.count == PanelID.allCases.count)
    }
}
