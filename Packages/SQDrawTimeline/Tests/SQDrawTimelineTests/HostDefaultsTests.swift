import Foundation
import SQCore
import SQEditorSession
import Testing
@testable import SQDrawTimeline

private struct FixedPauses: DialogueSilenceProvider {
    func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]? { [] }
}

@MainActor @Suite struct HostDefaultsTests {
    @Test func theDuckCurveGetsTheHostsDialoguePauses() {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])]))
        var p = TimelinePanel()
        p.connectHostDefaults(session: s)
        #expect(p.duckCurve != nil)
        #expect(p.duckCurve?.silences == nil)               // no provider: the duck holds through pauses
        p.connectHostDefaults(session: s, silences: FixedPauses())
        #expect(p.duckCurve?.silences != nil)
    }
}
