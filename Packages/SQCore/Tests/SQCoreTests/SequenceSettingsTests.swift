import Foundation
import Testing
@testable import SQCore

struct SequenceSettingsTests {
    private func project() -> (Project, Timeline.ID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        return (Project(name: "P", timelines: [t]), t.id)
    }

    @Test func appliesFormatNameAndMode() throws {
        var (p, id) = project()
        var s = p.timelines[0].settings
        s.name = "  Reel  "
        s.format = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25), audioSampleRate: 44_100)
        s.editMode = .magnetic
        try p.setSettings(s, of: id)
        let t = p.timelines[0]
        #expect(t.name == "Reel" && t.format.width == 1080 && t.format.audioSampleRate == 44_100)
        #expect(t.editMode == .magnetic && t.formatLocked)
    }

    @Test func blankNameKeepsOldAndInvalidFormatThrows() throws {
        var (p, id) = project()
        var s = p.timelines[0].settings
        s.name = "   "
        try p.setSettings(s, of: id)
        #expect(p.timelines[0].name == "Main")
        s.format.width = 0
        #expect(throws: EditError.invalidFormat) { try p.setSettings(s, of: id) }
    }

    @Test func unknownSequenceThrows() {
        var (p, _) = project()
        #expect(throws: EditError.timelineNotFound) { try p.setSettings(p.timelines[0].settings, of: UUID()) }
    }
}
