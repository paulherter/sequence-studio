import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellModalKeysTests {
    @Test func quickApplyOwnsTheKeyboardUntilItCloses() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        h.size = CGSize(width: 1280, height: 800)
        h.quickApplyItems = { QuickApplyCatalog.items(effects: [(ClipEffect.gaussianBlurKind, "Gaussian Blur")], builtInPresets: [], presets: []) }
        #expect(!h.ownsKeyboard)
        #expect(h.execute(.quickApply))
        #expect(h.ownsKeyboard)
        #expect(h.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(h.quickApply == nil)
        #expect(!h.ownsKeyboard)
    }
}
