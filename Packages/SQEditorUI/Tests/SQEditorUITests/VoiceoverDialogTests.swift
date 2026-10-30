import AppKit
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct VoiceoverDialogTests {
    private let voices = [VoiceoverVoiceChoice(id: "a", title: "A"), VoiceoverVoiceChoice(id: "b", title: "B")]

    @Test func requestNeedsTextAndUsesTheChosenVoiceAndRate() {
        let ui = VoiceoverDialog.makeView(voices: voices, initialVoice: "b", initialRate: 0.3)
        #expect(ui.controller.request == nil)
        ui.controller.field.stringValue = "  Hello   there "
        let r = ui.controller.request
        #expect(r?.text == "Hello there" && r?.voiceID == "b")
        #expect(abs((r?.rate ?? 0) - 0.3) < 0.011)
    }

    @Test func noVoicesMeansNoRequestAndAnExplainingHint() {
        let ui = VoiceoverDialog.makeView(voices: [], initialVoice: nil, initialRate: 0.5)
        ui.controller.field.stringValue = "Hi"
        #expect(ui.controller.request == nil)
        #expect(VoiceoverFieldsController.hintText(for: "Hi", rate: 0.5, hasVoices: false).contains("No voices"))
        #expect(VoiceoverFieldsController.hintText(for: "", rate: 0.5, hasVoices: true) == "Type the text first.")
    }
}
