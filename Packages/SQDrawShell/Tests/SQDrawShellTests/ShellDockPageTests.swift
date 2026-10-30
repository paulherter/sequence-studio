import Foundation
import Testing
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellDockPageTests {
    @Test func colorPageShowsItsPanelsAndEditComesBack() {
        let d = ShellDock()
        d.frame = CGRect(x: 0, y: 44, width: 1600, height: 900)
        var saved = 0
        d.save = { _ in saved += 1 }
        d.layout()
        #expect(!d.shows(.colorInspector))
        d.setPage(.color)
        #expect(d.store.page == .color && saved == 1)
        #expect(d.shows(.colorInspector) && d.shows(.scopes) && d.shows(.programMonitor))
        d.setPage(.color)
        #expect(saved == 1)   // no change, no save
        d.setPage(.edit)
        #expect(!d.shows(.colorInspector) && d.shows(.effectControls))
    }

    @Test func transientlyHiddenStepsLeaveTheLayoutAndTheStoredWorkspace() {
        let d = ShellDock()
        d.frame = CGRect(x: 0, y: 44, width: 1600, height: 900)
        var saved = 0
        d.save = { _ in saved += 1 }
        d.setPage(.color)
        d.show(.steps)
        #expect(d.shows(.steps))
        let stored = d.store.current
        saved = 0
        d.transientlyHidden = [.steps]
        #expect(!d.shows(.steps) && !d.visiblePanels.contains(.steps))
        #expect(d.store.current == stored && saved == 0, "shown, not stored")
        d.toggle(.steps); d.show(.steps)
        #expect(!d.shows(.steps) && saved == 0, "the Window row and the shortcut leave it hidden")
        d.transientlyHidden = []
        #expect(d.shows(.steps))
        var state = ShellMenuState()
        state.unavailablePanels = [.steps]
        let window = ShellMenuBar.build(state: state, map: .premiereDefault, platform: .windows) { _ in }
            .first { $0.title == "Window" }?.items ?? []
        let more = window.first { $0.title == "More Panels" }?.submenu ?? []
        let steps = (window + more).first { $0.title == EditorCommand.localizedPanelTitle(.steps) }
        #expect(steps?.isEnabled == false)
    }
}
