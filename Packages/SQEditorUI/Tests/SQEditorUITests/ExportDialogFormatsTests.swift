import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
private func makeModel(_ n: Int = 3) -> ExportDialogModel {
    let items = (1...n).map { ExportDialogModel.SequenceItem(name: "Seq \($0)", duration: Time(seconds: 10)) }
    return ExportDialogModel(sequences: items) { _, _ in throw CancellationError() }
}

/// Several format presets per sequence, several sequences at once (docs/DECISIONS 2026-10-03, C4).
@MainActor @Suite struct ExportDialogFormatsTests {
    @Test func everySequenceStartsWithOneFormat() {
        let m = makeModel()
        for s in m.sequences { #expect(m.formats(for: s.id).count == 1) }
        #expect(m.selectedFormatID == m.formats(for: m.selectedID)[0].id)
    }

    @Test func addFormatAppendsAndSelectsIt() {
        let m = makeModel()
        let first = m.formats(for: m.selectedID)[0].id
        m.addFormat(presetID: ExportPreset.proRes.id)
        let fs = m.formats(for: m.selectedID)
        #expect(fs.count == 2)
        #expect(m.selectedFormatID == fs[1].id)
        #expect(m.presetID == ExportPreset.proRes.id)
        #expect(m.codec == .prores422HQ)
        // The first format is untouched.
        #expect(fs[0].id == first)
        #expect(fs[0].settings == ExportDialogModel.withDialogDefaults(ExportPreset.default.settings))
    }

    @Test func addFormatWithoutPresetPicksAnUnusedOne() {
        let m = makeModel()
        m.addFormat()
        let ids = m.formats(for: m.selectedID).map(\.presetID)
        #expect(Set(ids).count == 2)
    }

    @Test func editsOnlyTouchTheSelectedFormat() {
        let m = makeModel()
        m.addFormat(presetID: ExportPreset.youtube1080.id)
        m.codec = .hevc
        let fs = m.formats(for: m.selectedID)
        #expect(fs[0].settings.video.codec == .h264)
        #expect(fs[1].settings.video.codec == .hevc)
        #expect(fs[1].presetID == ExportDialogModel.customPresetID)
        m.selectFormat(fs[0].id)
        #expect(m.codec == .h264)
        #expect(m.presetID == ExportPreset.default.id)
    }

    @Test func formatsArePerSequence() {
        let m = makeModel()
        m.addFormat(presetID: ExportPreset.proRes.id)
        m.selectedID = m.sequences[1].id
        #expect(m.formats(for: m.selectedID).count == 1)
        #expect(m.presetID == ExportPreset.default.id)
    }

    @Test func removeKeepsAtLeastOneFormat() {
        let m = makeModel()
        let only = m.formats(for: m.selectedID)[0].id
        m.removeFormat(only)
        #expect(m.formats(for: m.selectedID).count == 1)
        m.addFormat()
        let added = m.selectedFormatID
        m.removeFormat(added)
        #expect(m.formats(for: m.selectedID).count == 1)
        #expect(m.selectedFormatID == only)
    }

    @Test func duplicateCopiesSettings() {
        let m = makeModel()
        m.codec = .hevc
        m.duplicateFormat(m.selectedFormatID)
        let fs = m.formats(for: m.selectedID)
        #expect(fs.count == 2)
        #expect(fs[1].settings == fs[0].settings)
        #expect(fs[1].id != fs[0].id)
        #expect(m.selectedFormatID == fs[1].id)
    }

    @Test func jobsPerCheckedSequenceAndEnabledFormat() {
        let m = makeModel()
        m.addFormat(presetID: ExportPreset.proRes.id)            // Seq 1: two formats
        m.setChecked(m.sequences[1].id, true)                    // Seq 2: one format
        #expect(m.jobCount == 3)
        let jobs = m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp/out"))
        #expect(jobs.count == 3)
        #expect(jobs[0].name.hasPrefix("Seq 1 ") && jobs[1].name.hasPrefix("Seq 1 "))
        #expect(jobs[0].name != jobs[1].name)
        #expect(jobs[2].name == "Seq 2")                         // single format: plain name
        #expect(jobs[0].settings.video.codec == .h264)
        #expect(jobs[1].settings.video.codec == .prores422HQ)
    }

    @Test func disabledFormatIsSkippedAndNamesStayPlain() {
        let m = makeModel()
        m.addFormat(presetID: ExportPreset.proRes.id)
        m.setFormatEnabled(m.selectedFormatID, false)
        #expect(m.jobCount == 1)
        #expect(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp"))[0].name == "Seq 1")
    }

    @Test func sizeEstimateSumsAllEnabledFormats() {
        let m = makeModel()
        let one = m.estimatedBytes
        m.addFormat(presetID: ExportPreset.preset(.tiktok, .h264).id)   // same rate again
        #expect(m.estimatedBytes == one * 2)
        m.setFormatEnabled(m.selectedFormatID, false)
        #expect(m.estimatedBytes == one)
    }

    @Test func nothingEnabledCannotExport() {
        let m = makeModel()
        m.setFormatEnabled(m.selectedFormatID, false)
        #expect(m.jobCount == 0)
        #expect(!m.canExport)
        #expect(!m.validationMessages.isEmpty)
    }

    @Test func validationCoversNonSelectedFormats() {
        let m = makeModel()
        m.addFormat()
        m.width = 1081                                           // odd, on the selected (second) format
        m.selectFormat(m.formats(for: m.selectedID)[0].id)
        #expect(!m.canExport)
    }

    @Test func footerLabelCountsFiles() {
        let m = makeModel()
        #expect(m.exportButtonTitle == "Export")
        m.addFormat()
        #expect(m.exportButtonTitle == "Export 2 files")
    }

    // MARK: Advanced settings

    @Test func maxBitrateToggleKeepsAverage() {
        let m = makeModel()
        m.hasMaxBitrate = false
        #expect(m.settings.video.bitrate.maxBitsPerSecond == nil)
        m.hasMaxBitrate = true
        #expect(m.settings.video.bitrate.maxBitsPerSecond != nil)
        m.maxBitrateMbps = 30
        #expect(m.settings.video.bitrate.maxBitsPerSecond == 30_000_000)
        #expect(m.settings.video.bitrate.averageBitsPerSecond == 12_000_000)
        m.hasMaxBitrate = false
        #expect(m.settings.video.bitrate.maxBitsPerSecond == nil)
    }

    @Test func advancedEditMarksCustom() {
        let m = makeModel()
        m.edit { $0.video.keyframeInterval = 120 }
        #expect(m.presetID == ExportDialogModel.customPresetID)
        #expect(m.settings.video.keyframeInterval == 120)
    }

    @Test func audioEditsKeepPreset() {
        let m = makeModel()
        m.edit { $0.audio.sampleRate = 44_100 }
        #expect(m.presetID == ExportPreset.default.id)           // audio is not part of the preset's look
        #expect(m.settings.audio.sampleRate == 44_100)
    }

    // MARK: Preview maths

    @Test func previewFrameIndexFromFraction() {
        #expect(ExportPreviewMath.index(fraction: 0, count: 300) == 0)
        #expect(ExportPreviewMath.index(fraction: 1, count: 300) == 299)
        #expect(ExportPreviewMath.index(fraction: 0.5, count: 300) == 150)
        #expect(ExportPreviewMath.index(fraction: -2, count: 300) == 0)
        #expect(ExportPreviewMath.index(fraction: 0.5, count: 0) == 0)
        #expect(ExportPreviewMath.fraction(index: 150, count: 301) == 0.5)
    }

    @Test func previewSettingsAreSmallEvenAndSilent() {
        var s = ExportPreset.youtube4K.settings
        s.video.width = 3840; s.video.height = 2160
        s.audio.loudness = LoudnessNormalization()
        s.range = .inOut(TimeRange(start: Time(seconds: 1), duration: Time(seconds: 2)))
        let p = ExportPreviewMath.previewSettings(from: s, maxSide: 640)
        #expect(p.video.width == 640 && p.video.height == 360)
        #expect(!p.audio.enabled)
        #expect(p.audio.loudness == nil)
        #expect(p.range == s.range)            // the preview shows what is exported
        var tall = s; tall.video.width = 1080; tall.video.height = 1920
        let t = ExportPreviewMath.previewSettings(from: tall, maxSide: 640)
        #expect(t.video.width == 360 && t.video.height == 640)
        var small = s; small.video.width = 320; small.video.height = 180
        let q = ExportPreviewMath.previewSettings(from: small, maxSide: 640)
        #expect(q.video.width == 320 && q.video.height == 180)   // never scaled up
    }
}

/// Encoder speed is a per-Mac choice: one value for every format, kept across preset changes, never "Custom".
@MainActor @Suite struct ExportEncoderSpeedModelTests {
    @Test func speedAppliesToEveryFormatAndSurvivesPresets() {
        let m = makeModel(2)
        #expect(m.encoderSpeed == .quality)
        m.addFormat(presetID: ExportPreset.proRes.id)
        let before = m.presetID
        m.encoderSpeed = .balanced
        #expect(m.presetID == before)        // not turned into Custom
        for s in m.sequences { for f in m.formats(for: s.id) { #expect(f.settings.encoderSpeed == .balanced) } }
        m.presetID = ExportPreset.default.id
        #expect(m.settings.encoderSpeed == .balanced)
        m.addFormat()
        #expect(m.settings.encoderSpeed == .balanced)
    }

    @Test func suggestionTextOnlyOnSmallMacsAtQuality() {
        let gib: UInt64 = 1 << 30
        #expect(ExportDialogModel.encoderSpeedHint(.quality, physicalMemory: 8 * gib) != nil)
        #expect(ExportDialogModel.encoderSpeedHint(.balanced, physicalMemory: 8 * gib) == nil)
        #expect(ExportDialogModel.encoderSpeedHint(.quality, physicalMemory: 32 * gib) == nil)
    }
}
