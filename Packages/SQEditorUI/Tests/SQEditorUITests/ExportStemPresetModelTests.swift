import Foundation
import Testing
import SQCore
@testable import SQExport
@testable import SQEditorUI

@MainActor @Suite struct ExportStemPresetModelTests {
    private func make() -> (ExportDialogModel, UUID) {
        let item = ExportDialogModel.SequenceItem(name: "Main", duration: Time(seconds: 60), markers: [])
        let m = ExportDialogModel(sequences: [item]) { _, _ in throw CancellationError() }
        let tl = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)))
        m.stemPlans[item.id] = ["dialogue", "music", "me"].map { StemPlan.Stem(id: $0, title: $0.capitalized, fileSuffix: $0, timeline: tl) }
        return (m, item.id)
    }

    @Test func uncheckingNarrowsStemsAndEstimate() {
        let (m, _) = make()
        #expect(m.activeStems.count == 3)
        let all = m.stemEstimatedBytes
        m.setStemChecked("music", false)
        #expect(m.activeStems.map(\.id) == ["dialogue", "me"])
        #expect(m.stemEstimatedBytes == all / 3 * 2)
    }

    @Test func presetsApplyAndSaved() throws {
        let (m, _) = make()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stemmodel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        m.stemPresetStore = StemPresetStore(url: dir.appendingPathComponent("p.json"))
        let meOnly = try #require(m.stemPresets.first { $0.name == "Music and Effects only" })
        m.applyStemPreset(meOnly)
        #expect(m.activeStems.map(\.id) == ["me"])
        m.setStemChecked("dialogue", true)
        m.saveStemSelection()
        #expect(m.userStemPresets.map(\.name) == ["Dialogue + Me"])
        m.applyStemPreset(m.stemPresets.first { $0.name == "All roles" }!)
        #expect(m.activeStems.count == 3)
        m.applyStemPreset(m.userStemPresets[0])
        #expect(m.activeStems.map(\.id) == ["dialogue", "me"])
    }
}
