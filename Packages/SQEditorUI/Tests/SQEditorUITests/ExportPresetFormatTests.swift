import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct ExportPresetFormatTests {
    @Test func matchSourceAndYouTubePresetsFollowTheSequence() {
        let f = SequenceFormat(width: 2560, height: 1440, frameDuration: Time(1001, 24000))
        let item = ExportDialogModel.SequenceItem(name: "S", duration: Time(seconds: 10), format: f)
        let m = ExportDialogModel(sequences: [item], initialPreset: .matchSource) { _, _ in throw CancellationError() }
        #expect(m.presetID == ExportPreset.matchSource.id)
        #expect(m.width == 2560 && m.height == 1440)
        #expect(m.summaryText.hasPrefix("2560×1440 · 23.976 fps · H.264"))
        m.presetID = ExportPreset.youtube1080.id
        #expect(m.width == 1920 && m.height == 1080 && abs(m.fps - 23.976) < 0.001)
        m.presetID = ExportPreset.proRes.id
        #expect(m.codec == .prores422HQ && !m.summaryText.contains("Mbit"))
    }
}
