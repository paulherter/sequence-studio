import Foundation
import Testing
import SQAnalysis
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct SubjectMaskQualityMenuTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "sq.test.subjectMaskQuality.\(UUID().uuidString)")! }

    @Test func theDefaultIsQualityOnAppleSiliconAndAnUnknownValueIsTheDefault() {
        let d = defaults()
        #if arch(arm64)
        #expect(SubjectMaskQuality.stored(in: d) == .quality)
        #else
        #expect(SubjectMaskQuality.stored(in: d) == .speed)
        #endif
        d.set("ultra", forKey: SubjectMaskQuality.defaultsKey)
        #expect(SubjectMaskQuality.stored(in: d) == SubjectMaskQuality.standard)
        #expect(SubjectMaskQuality.defaultsKey == "sq.subjectMask.quality")
    }

    @Test func theMenuChecksTheStoredChoiceAndAChoiceIsStored() {
        let d = defaults()
        SubjectMaskQuality.quality.store(in: d)
        var told: [SubjectMaskQuality] = []
        let item = SubjectMaskQualityMenu.item(defaults: d) { told.append($0) }
        #expect(item.title == "Subject Mask Edges")
        let rows = item.submenu ?? []
        #expect(rows.map(\.title) == ["Quality", "Speed"])
        #expect(rows.map(\.isChecked) == [true, false])
        #expect(rows.allSatisfy { $0.help?.isEmpty == false })
        rows[1].action?()
        #expect(SubjectMaskQuality.stored(in: d) == .speed)
        #expect(told == [.speed])
        #expect((SubjectMaskQualityMenu.item(defaults: d).submenu ?? []).map(\.isChecked) == [false, true])
    }

    @Test func qualityReadsFramesAtTwiceTheTrackingSizeUpTo1920() {
        #expect(SubjectMaskQuality.quality.frameDimension(analysis: 960) == 1920)
        #expect(SubjectMaskQuality.quality.frameDimension(analysis: 640) == 1280)
        #expect(SubjectMaskQuality.quality.frameDimension(analysis: 540) == 1080)
        #expect(SubjectMaskQuality.speed.frameDimension(analysis: 960) == 960)
    }
}
