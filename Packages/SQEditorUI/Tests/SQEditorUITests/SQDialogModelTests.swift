import AppKit
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQUIKit

@Suite struct SQDialogModelTests {
    typealias M = SQDialogModel

    private func model(_ b: [(String, M.Role)]) -> M { M(buttons: b.map { M.Button(title: $0.0, role: $0.1) }) }

    @Test func explicitDefaultAndCancelWin() {
        let m = model([("Save", .normal), ("Discard", .default), ("Stop", .cancel)])
        #expect(m.returnIndex == 1)
        #expect(m.escapeIndex == 2)
    }

    @Test func nsAlertStyleFallbackFirstIsDefaultCancelByTitle() {
        let m = model([("OK", .normal), ("Cancel", .normal)])
        #expect(m.returnIndex == 0)
        #expect(m.escapeIndex == 1)
        #expect(m.response(forReturn: true) == .first)
        #expect(m.response(forReturn: false) == .second)
    }

    @Test func destructiveIsNotImplicitReturnWhenSafeButtonExists() {
        let m = model([("Delete", .destructive), ("Keep", .normal), ("Cancel", .cancel)])
        #expect(m.returnIndex == 1)
    }

    @Test func destructiveConfirmReturnsCancel() {
        let m = model([("Delete", .destructive), ("Cancel", .cancel)])
        #expect(m.returnIndex == 1)           // Return never deletes; focus starts on Cancel
        #expect(m.initialFocusIndex == 1)
        #expect(m.escapeIndex == 1)
    }

    @Test func infoDialogEscPressesTheOnlyButton() {
        let m = model([("OK", .default)])
        #expect(m.escapeIndex == 0)
    }

    @Test func choiceWithoutCancelIgnoresEsc() {
        let m = model([("A", .default), ("B", .normal)])
        #expect(m.escapeIndex == nil)
        #expect(m.response(forReturn: false) == nil)
    }

    @Test func onlyCancelHasNoReturn() {
        let m = model([("Cancel", .cancel)])
        #expect(m.returnIndex == nil)
    }

    @Test func firstAddedButtonIsRightmost() {
        let m = model([("OK", .default), ("Cancel", .cancel), ("Delete", .destructive)])
        #expect(m.displayOrder == [2, 1, 0])
    }

    @Test func responseIndices() {
        #expect(M.Response.first.rawValue == 0)
        #expect(M.Response.third.rawValue == 2)
        #expect(SQDialog.optionIndex(.second, count: 2) == 1)
        #expect(SQDialog.optionIndex(.second, count: 1) == nil)      // the cancel button after one option
        #expect(SQDialog.optionIndex(.dismissed, count: 3) == nil)
    }

    @MainActor @Test func buttonlessDialogGetsDismissibleOK() {
        let d = SQDialog()
        d.messageText = "Could not open"
        var got: M.Response?
        let w = d.layout()
        d.completion = { got = $0 }
        #expect(d.model.buttons.map(\.title) == ["OK"])
        w.onResponse?(w.model.response(forReturn: true)!)       // Return closes it
        #expect(got == .first)
        #expect(w.model.response(forReturn: false) != nil)      // Esc closes it too
    }

    @MainActor @Test func dialogReportsPressedButtonThroughItsWindow() {
        let d = SQDialog()
        d.messageText = "Delete?"
        d.addButton("Delete", role: .destructive)
        d.addButton("Cancel", role: .cancel)
        var got: M.Response?
        let w = d.layout()
        d.completion = { got = $0 }
        w.onResponse?(w.model.response(forReturn: false)!)
        #expect(got == .second)
        #expect(w.contentView != nil)
    }
}

@Suite @MainActor struct UnsupportedImportMessageTests {
    @Test func namesFileAndCodec() {
        let m = ProjectPanelView.unsupportedMessage([("clip.webm", "VP8")])
        #expect(m.title == "This file can't be opened")
        #expect(m.message.contains("clip.webm") && m.message.contains("VP8") && m.message.contains("MP4"))
    }

    @Test func audioFileGetsAudioAdvice() {
        let m = ProjectPanelView.unsupportedMessage([("take.ogg", "Vorbis")])
        #expect(m.message.contains("take.ogg") && m.message.contains("WAV") && !m.message.contains("MP4"))
    }
}

@Suite @MainActor struct AudioDroppedMessageTests {
    @Test func namesFileAndCodec() {
        let m = ProjectPanelView.audioDroppedMessage([("talk.webm", "ac-3")])
        #expect(m.title == "Imported without sound")
        #expect(m.message.contains("talk.webm") && m.message.contains("ac-3"))
    }
}
