import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct ExportDeliveryTargetTests {
    private func model(_ target: DeliveryTarget?, _ f: SequenceFormat) -> ExportDialogModel {
        let item = ExportDialogModel.SequenceItem(name: "S", duration: Time(seconds: 10), format: f, deliveryTarget: target)
        return ExportDialogModel(sequences: [item], initialPreset: nil) { _, _ in throw CancellationError() }
    }

    @Test func tiktokSequenceDefaultsToVerticalWithLoudness() {
        let m = model(DeliveryTarget(platform: .tiktok), SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)))
        #expect(m.presetID == ExportPreset.preset(.tiktok, .h264).id)
        #expect(m.width == 1080 && m.height == 1920)
        #expect(m.settings.audio.loudness == LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1))
        #expect(m.normalizeLoudness)
    }

    @Test func sequenceWithoutTargetKeepsMatchSourceAndNoLoudness() {
        let m = model(nil, SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)))
        #expect(m.presetID == ExportPreset.matchSource.id)
        #expect(!m.normalizeLoudness)
    }

    @Test func changingPresetKeepsTheTargetCeiling() {
        let m = model(DeliveryTarget(platform: .youtube), SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)))
        m.presetID = ExportPreset.proRes.id
        #expect(m.settings.audio.loudness?.truePeakCeilingDB == -1)
    }
}
