import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct ExportCoverImageTests {
    private func model(coverTime: Time?) -> ExportDialogModel {
        let item = ExportDialogModel.SequenceItem(name: "Seq", duration: Time(seconds: 10), coverTime: coverTime)
        return ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
    }

    @Test func offByDefault() {
        let m = model(coverTime: Time(seconds: 4))
        #expect(m.coverImage == nil)
        #expect(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).allSatisfy { $0.settings.coverImage == nil && $0.settings.coverTime == nil })
    }

    @Test func jobCarriesFormatAndMarkerTime() {
        let m = model(coverTime: Time(seconds: 4))
        m.coverImage = .jpg
        let jobs = m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(jobs.count == 1)
        #expect(jobs[0].settings.coverImage == .jpg)
        #expect(jobs[0].settings.coverTime == Time(seconds: 4))
    }

    @Test func withoutMarkerFallsBackToFirstFrame() {
        let m = model(coverTime: nil)
        m.coverImage = .png
        #expect(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp"))[0].settings.coverTime == nil)
        #expect(m.coverFrameText.hasPrefix("First frame"))
    }

    @Test func choosingAPresetKeepsTheCoverChoice() {
        let m = model(coverTime: nil)
        m.coverImage = .png
        m.presetID = ExportPreset.feedPortrait.id
        #expect(m.coverImage == .png)
        #expect(m.settings.video.height == 1350)
    }

    @Test func markerTextNamesTheMarker() {
        let m = model(coverTime: Time(seconds: 5))
        #expect(m.coverFrameText.contains("Cover"))
    }
}
