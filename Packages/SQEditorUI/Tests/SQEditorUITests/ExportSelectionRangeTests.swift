import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI

@MainActor
private func makeModel(clips: [ExportDialogModel.SelectedClipRange]) -> ExportDialogModel {
    let item = ExportDialogModel.SequenceItem(name: "Seq", duration: Time(seconds: 30), selectedClips: clips)
    return ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
}

private func r(_ a: Int, _ b: Int) -> TimeRange { TimeRange(start: Time(seconds: Int64(a)), end: Time(seconds: Int64(b))) }

@MainActor @Suite struct ExportSelectionRangeTests {
    @Test func selectionRangeIsTheUnionOfTheClips() {
        let m = makeModel(clips: [.init(name: "B", range: r(10, 14)), .init(name: "A", range: r(2, 5))])
        #expect(m.canUseSelection)
        m.rangeMode = 3
        #expect(m.rangeMode == 3)
        #expect(m.settings.range == .inOut(r(2, 14)))
        #expect(m.effectiveDuration(of: m.selectedID) == Time(seconds: 12))
        m.rangeMode = 0
        #expect(m.settings.range == .entireSequence)
    }

    @Test func noSelectionDisablesTheMode() {
        let m = makeModel(clips: [])
        #expect(!m.canUseSelection)
        m.rangeMode = 3
        #expect(m.settings.range == .entireSequence)
    }

    @Test func onePerClipMakesOneJobPerClipWithUniqueNames() {
        let m = makeModel(clips: [.init(name: "Take", range: r(0, 3)), .init(name: "Take", range: r(5, 8)), .init(name: "Other", range: r(9, 10))])
        m.rangeMode = 3
        m.oneFilePerClip = true
        let jobs = m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(jobs.map(\.name) == ["Seq - 1 Take", "Seq - 2 Take", "Seq - 3 Other"])
        #expect(jobs.map(\.settings.range) == [.inOut(r(0, 3)), .inOut(r(5, 8)), .inOut(r(9, 10))])
    }

    @Test func onePerClipIgnoredOutsideSelectionMode() {
        let m = makeModel(clips: [.init(name: "A", range: r(0, 3)), .init(name: "B", range: r(5, 8))])
        m.oneFilePerClip = true
        #expect(m.buildJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).count == 1)
    }
}
