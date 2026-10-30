import AppKit
import Testing
@testable import SQUIKit

@Suite struct SQModalEditingKeysTests {
    typealias M = SQDialogModel
    private let m = M(buttons: [M.Button(title: "Create", role: .default), M.Button(title: "Cancel", role: .normal)])

    @Test func returnAndEscapeBelongToAFieldBeingEdited() {
        #expect(SQModal.response(for: m, keyCode: 36, command: false, otherModifiers: false, character: nil, editingText: true) == nil)
        #expect(SQModal.response(for: m, keyCode: 76, command: false, otherModifiers: false, character: nil, editingText: true) == nil)
        #expect(SQModal.response(for: m, keyCode: 53, command: false, otherModifiers: false, character: nil, editingText: true) == nil)
    }

    @Test func withoutAnEditingFieldReturnConfirmsAndEscapeCancels() {
        #expect(SQModal.response(for: m, keyCode: 36, command: false, otherModifiers: false, character: nil) == m.response(forReturn: true))
        #expect(SQModal.response(for: m, keyCode: 53, command: false, otherModifiers: false, character: nil) == m.response(forReturn: false))
    }

    @MainActor @Test func menuPanelWorksInsideModalSessions() {
        #expect(SQMenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true).worksWhenModal)
    }

    @MainActor @Test func fieldEditorCountsAsEditing() {
        #expect(SQModal.isEditingText(NSTextView()))
        #expect(!SQModal.isEditingText(NSView()))
    }
}
