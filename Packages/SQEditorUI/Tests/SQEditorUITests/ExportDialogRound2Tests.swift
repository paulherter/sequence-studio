import Foundation
import Testing
import SQCore
import SQExport
import SQUIKit
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor
private func makeModel(names: [String] = ["Main"], format: SequenceFormat? = nil, duration: Time = Time(seconds: 10),
                       preset: ExportPreset? = .default) -> ExportDialogModel {
    let items = names.map { ExportDialogModel.SequenceItem(name: $0, duration: duration, format: format) }
    return ExportDialogModel(sequences: items, initialPreset: preset) { _, _ in throw CancellationError() }
}

/// Export dialog, redesign round 2: the summary shows what is written, captions burn in by default, the flat output
/// list, the size estimate and the file-name field.
@MainActor @Suite struct ExportDialogRound2Tests {
    // MARK: Frame rate (summary == writer)

    private func writerRate(_ m: ExportDialogModel) throws -> String {
        let job = try #require(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).first)
        return ExportDialogModel.frameRateText(job.settings.video.frameDuration)
    }

    @Test func summaryFrameRateIsTheRateHandedToTheWriter() throws {
        // A 59.94 sequence on Match Source / YouTube follows the source rate; TikTok keeps it too (24-60 fps).
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1001, 60000))
        for preset in [ExportPreset.default, .matchSource, .youtube1080, .hevc10, .proRes] {
            let m = makeModel(format: f, preset: preset)
            #expect(m.summaryText.contains("\(try writerRate(m)) fps"), "\(preset.id): \(m.summaryText)")
        }
    }

    @Test func thirtyFpsPresetSummarySaysThirty() {
        // 59.94 is within the social range and kept; rates above 60 fall back to 30.
        let m = makeModel(format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 120)))
        #expect(m.settings.video.frameDuration == Time(1, 30))
        #expect(m.summaryText.contains(" 30 fps"))
        #expect(!m.summaryText.contains("59"))
    }

    @Test func ntscRatesAreNotRoundedToThreeDigits() {
        #expect(ExportDialogModel.frameRateText(Time(1001, 60000)) == "59.94")
        #expect(ExportDialogModel.frameRateText(Time(1001, 30000)) == "29.97")
        #expect(ExportDialogModel.frameRateText(Time(1001, 24000)) == "23.976")
        #expect(ExportDialogModel.frameRateText(Time(1, 30)) == "30")
    }

    @Test func summaryFollowsEditedFrameRate() throws {
        let m = makeModel()
        m.fps = 59.94
        #expect(m.summaryText.contains("59.94 fps"))
        #expect(try writerRate(m) == "59.94")
    }

    // MARK: Captions

    @Test func captionsBurnInByDefault() {
        let m = makeModel(names: ["A", "B"])
        for s in m.sequences { #expect(m.settings(for: s.id).captions == .burnIn) }
        m.addFormat()
        #expect(m.captions == .burnIn)
        m.presetID = ExportPreset.youtube4K.id            // a preset never resets the caption choice
        #expect(m.captions == .burnIn)
        m.captions = .none
        m.presetID = ExportPreset.youtube1080.id
        #expect(m.captions == .none)
    }

    // MARK: Output list

    @Test func aspectNames() {
        #expect(ExportDialogModel.aspectName(width: 1080, height: 1920) == "Vertical 9:16")
        #expect(ExportDialogModel.aspectName(width: 1920, height: 1080) == "Horizontal 16:9")
        #expect(ExportDialogModel.aspectName(width: 1080, height: 1080) == "Square 1:1")
        #expect(ExportDialogModel.aspectName(width: 1080, height: 1350) == "Portrait 4:5")
        #expect(ExportDialogModel.aspectName(width: 1234, height: 700) == "1234 × 700")
    }

    @Test func oneFlatRowPerOutputFile() {
        let m = makeModel(names: ["Main", "Combined"])
        m.addFormat(presetID: ExportPreset.youtube1080.id)
        let rows = m.outputRows
        #expect(rows.count == 3)
        #expect(rows[0].title == "Main · Vertical 9:16")
        #expect(rows[0].sizeText == "1080 × 1920")
        #expect(rows[1].title == "Main · Horizontal 16:9")
        #expect(rows[2].title == "Combined · Vertical 9:16")
        #expect(rows.map(\.isChecked) == [true, true, false])
        #expect(m.jobCount == 2)
    }

    @Test func checkingRowsDrivesJobs() {
        let m = makeModel(names: ["Main", "Combined"])
        m.addFormat(presetID: ExportPreset.youtube1080.id)
        let rows = m.outputRows
        m.setOutputChecked(rows[1].id, false)
        #expect(m.jobCount == 1)
        m.setOutputChecked(rows[2].id, true)
        #expect(m.jobCount == 2)
        #expect(m.isChecked(m.sequences[1].id))
        m.setOutputChecked(rows[0].id, false)
        m.setOutputChecked(rows[2].id, false)
        #expect(m.jobCount == 0)
        #expect(!m.canExport)
    }

    @Test func tickingOneOutputOfAnUncheckedSequenceTicksOnlyThatOutput() {
        let m = makeModel(names: ["A", "B"])
        m.selectOutput(m.outputRows[1].id)                       // B becomes the edited sequence (still unticked)
        m.addFormat(presetID: ExportPreset.youtube1080.id)
        let b = m.outputRows.filter { $0.sequenceID == m.sequences[1].id }
        #expect(b.count == 2)
        #expect(!m.isChecked(m.sequences[1].id))
        m.setOutputChecked(b[0].id, true)
        let after = m.outputRows.filter { $0.sequenceID == m.sequences[1].id }
        #expect(after.map(\.isChecked) == [true, false])
        #expect(m.jobCount == 2)                                  // A's output and B1, not B2
    }

    @Test func selectingARowSelectsItsFormat() {
        let m = makeModel(names: ["Main", "Combined"])
        let row = m.outputRows[1]
        m.selectOutput(row.id)
        #expect(m.selectedID == m.sequences[1].id)
        #expect(m.outputRows.filter(\.isSelected).map(\.id) == [row.id])
    }

    @Test func summaryLine() {
        let m = makeModel(names: ["Main", "Combined"], duration: Time(seconds: 18))
        #expect(m.outputSummaryText.hasPrefix("1 file · about "))
        #expect(m.outputSummaryText.hasSuffix("00:00:18:00"))
        m.setChecked(m.sequences[1].id, true)
        #expect(m.outputSummaryText.hasPrefix("2 files · about "))
        #expect(m.outputSummaryText.hasSuffix("00:00:18:00 each"))
    }

    // MARK: Estimated size

    @Test func estimatedSizeIsBitrateTimesDurationPlusAudio() {
        let m = makeModel(duration: Time(seconds: 10))
        m.bitrateMbps = 12
        // 12 Mbit/s video + 192 kbit/s audio over 10 s.
        let expected = Int64((12_000_000 + 192_000) * 10 / 8)
        #expect(m.estimatedBytes == expected)
        m.edit { $0.audio.enabled = false }
        #expect(m.estimatedBytes == Int64(12_000_000 * 10 / 8))
    }

    @Test func estimatedSizeUsesTheInOutRange() {
        let item = ExportDialogModel.SequenceItem(name: "Main", duration: Time(seconds: 60),
                                                  inOut: TimeRange(start: Time(seconds: 2), duration: Time(seconds: 4)))
        let m = ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
        #expect(m.useInOut)                                              // default with In/Out set
        let ranged = m.estimatedBytes
        m.useInOut = false
        let whole = m.estimatedBytes
        m.useInOut = true
        #expect(m.estimatedBytes == ranged)
        #expect(m.estimatedBytes * 15 == whole || abs(m.estimatedBytes * 15 - whole) < 20)
    }

    @Test func estimatedSizeText() {
        let m = makeModel(duration: Time(seconds: 30))
        m.bitrateMbps = 12.8
        #expect(m.estimatedSizeText.hasPrefix("~ "))
        #expect(m.estimatedSizeText.hasSuffix(" MB"))
        #expect(m.estimatedSizeText == "~ " + SQByteSize.string(m.estimatedBytes))
    }

    // MARK: File name

    @Test func fileNameDefaultsFromSequenceName() {
        let m = makeModel(names: ["TikTok Schnitt-Tricks"])
        #expect(m.fileName == "TikTok Schnitt-Tricks")
        #expect(m.fileExtension == "mp4")
        m.codec = .prores422HQ
        #expect(m.fileExtension == "mov")
    }

    @Test func illegalCharactersAreStripped() {
        #expect(ExportDialogModel.sanitizedFileName("a/b:c\\d?e*f|g\"h<i>j") == "abcdefghij")
        #expect(ExportDialogModel.sanitizedFileName("  .hidden name. ") == "hidden name")
        #expect(ExportDialogModel.sanitizedFileName("tab\there") == "tabhere")
        #expect(ExportDialogModel.sanitizedFileName("///") == "")
        let m = makeModel(names: ["Cut: 1/2?"])
        #expect(m.fileName == "Cut 12")
    }

    @Test func editedFileNameGoesIntoTheJobAndEmptyResets() throws {
        let m = makeModel(names: ["Main"])
        m.fileName = "My / Film"
        #expect(m.fileName == "My  Film")
        let job = try #require(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).first)
        #expect(job.name == "My  Film")
        m.fileName = "   "
        #expect(m.fileName == "Main")
        #expect(try #require(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).first).name == "Main")
    }

    @Test func maximumFollowsTargetUntilEditedByHand() {
        let m = makeModel()
        m.hasMaxBitrate = true
        m.bitrateMbps = 10
        #expect(m.maxBitrateMbps == 15)
        m.maxBitrateMbps = 40
        m.bitrateMbps = 12
        #expect(m.maxBitrateMbps == 40)
        m.bitrateMbps = 50
        #expect(m.maxBitrateMbps == 50)
        m.presetID = ExportPreset.youtube1080.id
        m.hasMaxBitrate = true
        m.bitrateMbps = 10
        #expect(m.maxBitrateMbps == 15)
    }

    @Test func bitrateKindIsStoredAndConstantResetsTheHandEditedMaximum() throws {
        let m = makeModel()
        m.presetID = ExportPreset.youtube1080.id
        #expect(m.bitrateKind == .vbr)
        m.hasMaxBitrate = true
        m.bitrateMbps = 10
        m.maxBitrateMbps = 40
        m.bitrateKind = .cbr
        #expect(m.bitrateKind == .cbr && m.settings.video.usesConstantBitrate)
        #expect(m.presetID == ExportDialogModel.customPresetID)
        #expect(!m.bitrateKind.showsMaximum)
        // The Maximum is no longer hand-edited: it follows the target again, also while CBR hides it.
        #expect(m.maxBitrateMbps == 15)
        m.bitrateMbps = 20
        m.bitrateKind = .vbr
        #expect(m.hasMaxBitrate && m.maxBitrateMbps == 30)
        // A preset brings VBR back; the built job carries the mode.
        m.bitrateKind = .cbr
        #expect(try #require(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).first).settings.video.bitrateKind == .cbr)
        m.presetID = ExportPreset.youtube1080.id
        #expect(m.bitrateKind == .vbr)
    }
}

@MainActor @Suite struct ExportRangeAndLimitsTests {
    @Test func customRangeIsSnappedClampedAndKept() {
        let m = makeModel(duration: Time(seconds: 10))
        m.rangeMode = 2
        #expect(m.rangeMode == 2)
        m.setCustomRange(startSeconds: 2.01, endSeconds: 7)
        let r = m.rangeSeconds
        #expect(abs(r.start - 2) < 0.04 && r.end == 7)
        #expect(m.effectiveDuration(of: m.selectedID) > Time(49, 10))
        m.setCustomRange(endSeconds: 99)
        #expect(m.rangeSeconds.end == 10)
        m.setCustomRange(startSeconds: 50)
        #expect(m.rangeSeconds.start < m.rangeSeconds.end)
        m.rangeMode = 0
        #expect(m.settings.range == .entireSequence)
    }

    @Test func xPresetBlocksExportsOver140Seconds() {
        let m = makeModel(duration: Time(seconds: 200), preset: .xPost)
        #expect(m.platformLimitMessages.count == 1)
        #expect(!m.canExport)
        m.rangeMode = 2
        m.setCustomRange(startSeconds: 0, endSeconds: 60)
        #expect(m.platformLimitMessages.isEmpty)
    }

    @Test func otherPresetsHaveNoLimits() {
        #expect(makeModel(duration: Time(seconds: 4000), preset: .facebook).platformLimitMessages.isEmpty)
    }
}
