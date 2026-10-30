import Foundation
import Testing
@testable import SQEditorSession

// AUDIT A7: Snapping and Linked Selection are remembered per Mac, not in the project and not in undo.
struct ToolToggleStorageTests {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "sq-test-\(UUID().uuidString)")!
        return d
    }

    @Test func missingValuesKeepBothOn() {
        var s = ToolState(snapping: false, linkedSelection: false)
        s.applyStoredToggles(defaults())
        #expect(s.snapping && s.linkedSelection)
    }

    @Test func storedTogglesComeBack() {
        let d = defaults()
        var off = ToolState()
        off.snapping = false
        off.linkedSelection = false
        off.storeToggles(d)
        var next = ToolState()
        next.applyStoredToggles(d)
        #expect(!next.snapping && !next.linkedSelection)
        var one = ToolState(); one.linkedSelection = false; one.storeToggles(d)
        next.applyStoredToggles(d)
        #expect(next.snapping && !next.linkedSelection)
    }
}
