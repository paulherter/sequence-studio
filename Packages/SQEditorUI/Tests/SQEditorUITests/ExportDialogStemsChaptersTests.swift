import Foundation
import Testing
import SQCore
@testable import SQExport
@testable import SQEditorUI

@MainActor
private func makeModel(markers: [Marker] = [], duration: Time = Time(seconds: 120)) -> (ExportDialogModel, UUID) {
    let item = ExportDialogModel.SequenceItem(name: "Main", duration: duration, markers: markers)
    return (ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }, item.id)
}

@MainActor @Suite struct ExportDialogStemsChaptersTests {
    @Test func noMarkersMeansNoChapters() {
        let (m, _) = makeModel()
        #expect(m.chapters == nil)
    }

    @Test func chaptersFollowMarkersAndWarn() throws {
        let marks = [Marker(time: .zero, name: "Intro"), Marker(time: Time(seconds: 30), name: "Middle")]
        let (m, _) = makeModel(markers: marks)
        let c = try #require(m.chapters)
        #expect(c.text == "0:00 Intro\n0:30 Middle")
        #expect(!c.warnings.isEmpty)   // fewer than three chapters
    }

    @Test func chaptersShiftWithTheExportRange() throws {
        let marks = [Marker(time: Time(seconds: 10), name: "A"), Marker(time: Time(seconds: 40), name: "B"),
                     Marker(time: Time(seconds: 70), name: "C")]
        let (m, _) = makeModel(markers: marks)
        m.edit { $0.range = .inOut(TimeRange(start: Time(seconds: 10), duration: Time(seconds: 100))) }
        let c = try #require(m.chapters)
        #expect(c.text == "0:00 A\n0:30 B\n1:00 C")
        #expect(c.warnings.isEmpty)
    }

    @Test func stemsNeedAProviderAndAPlan() {
        let (m, id) = makeModel()
        #expect(!m.canExportStems)
        m.stemPlans[id] = [StemPlan.Stem(id: "dialogue", title: "Dialogue", fileSuffix: "dialogue", timeline: Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30))))]
        #expect(!m.canExportStems)
        m.stemAudio = { _, _, _ in throw CancellationError() }
        #expect(m.canExportStems)
    }

    @Test func exportStemsReportsTheFailure() async {
        let (m, id) = makeModel()
        m.stemPlans[id] = [StemPlan.Stem(id: "dialogue", title: "Dialogue", fileSuffix: "dialogue", timeline: Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30))))]
        struct Boom: Error {}
        m.stemAudio = { _, _, _ in throw Boom() }
        await m.exportStems(to: FileManager.default.temporaryDirectory)
        #expect(m.stemStatus != nil)
        #expect(!m.isExportingStems)
    }
}

@MainActor @Suite struct ExportDialogCutDownTests {
    private func marks() -> [Marker] {
        [Marker(time: Time(seconds: 10), name: "cut-down 30", duration: Time(seconds: 15)),
         Marker(time: Time(seconds: 50), name: "cut-down 6", duration: Time(seconds: 6))]
    }

    @Test func noCutDownMarkersMeansNoPlans() {
        let (m, _) = makeModel(markers: [Marker(time: .zero, name: "Intro")])
        #expect(m.cutDownPlans.isEmpty)
        #expect(m.buildCutDownJobs(outputDirectory: URL(fileURLWithPath: "/tmp")).isEmpty)
    }

    @Test func oneJobPerCheckedRangeWithSuffix() {
        let (m, _) = makeModel(markers: marks())
        let dir = URL(fileURLWithPath: "/tmp")
        #expect(m.cutDownPlans.map(\.targetSeconds) == [30, 6])
        #expect(m.buildCutDownJobs(outputDirectory: dir).map(\.name) == ["Main_30s", "Main_6s"])
        m.setCutDownChecked(.init(target: 30, index: 0), false)
        let jobs = m.buildCutDownJobs(outputDirectory: dir)
        #expect(jobs.map(\.name) == ["Main_6s"])
        #expect(jobs[0].settings.range == .inOut(TimeRange(start: Time(seconds: 50), duration: Time(seconds: 6))))
    }
}
