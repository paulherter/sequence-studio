import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct ToneBleepSessionTests {
    @Test func commandsAreRegistered() {
        #expect(CommandSupport.isSupported(.bleep) && CommandSupport.isSupported(.newTone) && CommandSupport.isSupported(.toneSettings))
    }

    @Test func dialogReflectsTheTone() {
        let v = ToneDialog.makeView(ToneSpec(frequencyHz: 800, levelDB: -6))
        #expect(v.frequency.value == 800 && v.level.value == -6)
    }

    @Test func newToneNeverOverwritesSoundAndSetsTheTone() throws {
        let talk = Clip(name: "Talk", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)),
                        start: .zero, mediaDuration: Time(10, 1))
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [talk])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let id = try #require(s.addToneClip(ToneSpec(frequencyHz: 440, levelDB: -6)))
        let tl = try #require(s.activeTimeline)
        #expect(tl.tracks.count == 2 && tl.tracks[0].clips == [talk] && tl.tracks[1].clips.first?.id == id)
        #expect(s.selectedTone?.spec == ToneSpec(frequencyHz: 440, levelDB: -6))
        s.setTone(id, .default)
        #expect(s.selectedTone?.spec == .default)
    }
}
