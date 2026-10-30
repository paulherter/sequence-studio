import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct DisguiseVoiceExportHintTests {
    private func model(nested: [Bool]) -> ExportDialogModel {
        let items = nested.enumerated().map {
            ExportDialogModel.SequenceItem(name: "Seq \($0.offset)", duration: Time(seconds: 10), nestedUnderDisguiseVoice: $0.element)
        }
        return ExportDialogModel(sequences: items) { _, _ in throw CancellationError() }
    }

    @Test func hintOnlyForACheckedNestedSequenceAndNeverBlocks() {
        let m = model(nested: [false, true])
        #expect(m.disguiseVoiceHint == nil)
        m.checkedIDs = [m.sequences[1].id]
        #expect(m.disguiseVoiceHint != nil)
        #expect(m.canExport)                                   // a note, not a block
        m.checkedIDs = [m.sequences[0].id, m.sequences[1].id]
        #expect(m.disguiseVoiceHint != nil)
        #expect(model(nested: [false, false]).disguiseVoiceHint == nil)
    }
}
