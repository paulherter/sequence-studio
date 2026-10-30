import Foundation
import SQCore
import SQLibrary
import Testing
@testable import SQTimelineUI

@MainActor
@Suite struct KeystoneSelectionTests {
    @Test func selectionOfAHiddenBuiltInSurvivesDeletingItsSavedChanges() throws {
        var punch = try #require(Keystone.builtIn(named: "Punch In"))
        punch.easing = .easeInOut
        let model = KeystonesPanelModel()
        model.presets = [try KeystoneLibrary.presetItem(for: punch)]
        model.selectedID = punch.id
        #expect(model.selected?.easing == .easeInOut)
        model.presets = []   // the changes are deleted; Punch In is hidden again
        #expect(!model.keystones.contains { $0.id == punch.id })
        #expect(model.selected == Keystone.builtIn(named: "Punch In"))
    }
}
