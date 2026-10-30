import AppKit
import SQCore
import SQExport
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQUIKit

/// WP-C: dialogs use ScrubField / NumericSlider (double-click resets, one value, units) instead of plain text fields.
@MainActor @Suite struct DialogNumericTests {
    @Test func makeNumberFieldIsAScrubFieldWithDefaultAndUnit() {
        let f = SQDialog.makeNumberField(value: 500, range: 0...100, step: 0.5, decimals: 1, unit: "dB", defaultValue: 10)
        #expect(f.value == 100)                                  // clamped into the range
        #expect(f.displayText == "100.0" && f.unit == "dB" && f.unitOutside)   // the unit sits after the capsule (SQDialog.formRow)
        f.resetToDefault()
        #expect(f.value == 10 && f.step == 0.5)
    }

    @Test func speedSheetBuildsAndCountsFrames() {
        let fd = Time(1, 24)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero,
                        speed: ClipSpeed(percent: 200))
        let sheet = SpeedDurationSheet(model: SpeedDialogModel(clips: [clip], frameDuration: fd),
                                       timecode: Timecode(frameDuration: fd, dropFrame: false))
        _ = sheet.buildView()
        #expect(SpeedDurationSheet.frameCount(fd * 24, fd) == 24)
    }

    @Test func trackAudioInspectorBuildsWithNoiseSlider() {
        let m = TrackAudioInspectorModel()
        var begins = 0, ends = 0
        m.onBeginChange = { begins += 1 }
        m.onEndChange = { ends += 1 }
        let v = TrackAudioInspectorView(model: m)
        _ = v
        m.beginChange(); m.setNoiseReductionPercent(40); m.setNoiseReductionPercent(55); m.endChange()
        #expect(begins == 1 && ends == 1 && m.noiseReductionPercent == 55)
    }

    @Test func exportPresetSettingsGiveTheResetTargets() {
        let item = ExportDialogModel.SequenceItem(name: "S", duration: Time(seconds: 10))
        let m = ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
        m.width = 640                                                    // edited by hand: format turns Custom
        #expect(m.presetID == ExportDialogModel.customPresetID)
        #expect(m.presetSettings.video.width != 640)                     // the reset target is the preset's, not the edit
    }
}
