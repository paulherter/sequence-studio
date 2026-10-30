import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

@MainActor @Suite struct TrimDynamicTests {
    private func f(_ n: Int64) -> Time { Time(n, 30) }

    private func make() -> (EditorSession, TrimModeModel) {
        func c(_ start: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start),
                 mediaDuration: f(600))
        }
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c(0)); try! v.overwrite(c(60)); try! v.overwrite(c(150))
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
        let ses = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        ses.seek(to: f(60))
        let m = TrimModeModel(session: ses)
        m.enterNearestPlayhead()
        return (ses, m)
    }

    @Test func lTrimsForwardAndRepeatedPressesSpeedUp() {
        let (ses, m) = make(); defer { withExtendedLifetime(ses) {} }
        #expect(m.dynamicTrim(.l)); #expect(m.point?.time == f(61))
        #expect(m.dynamicTrim(.l)); #expect(m.point?.time == f(63))
        #expect(m.dynamicTrim(.l)); #expect(m.point?.time == f(68))
        #expect(m.dynamicTrim(.l)); #expect(m.point?.time == f(78))
        #expect(m.dynamicTrim(.l)); #expect(m.point?.time == f(88))   // top speed stays 10
    }

    @Test func jGoesBackAndTurningAroundRestartsSlow() {
        let (ses, m) = make(); defer { withExtendedLifetime(ses) {} }
        _ = m.dynamicTrim(.l); _ = m.dynamicTrim(.l)
        #expect(m.point?.time == f(63))
        _ = m.dynamicTrim(.j); #expect(m.point?.time == f(62))
        _ = m.dynamicTrim(.j); #expect(m.point?.time == f(60))
    }

    @Test func kStopsAndNextPressStartsSlow() {
        let (ses, m) = make()
        _ = m.dynamicTrim(.l); _ = m.dynamicTrim(.l)
        let undo = ses.undoName
        #expect(m.dynamicTrim(.k)); #expect(m.point?.time == f(63)); #expect(ses.undoName == undo)
        _ = m.dynamicTrim(.l); #expect(m.point?.time == f(64))
    }

    @Test func offWhenTrimModeIsClosed() {
        let (ses, m) = make(); defer { withExtendedLifetime(ses) {} }
        m.exit()
        #expect(!m.dynamicTrim(.l))
    }
}
