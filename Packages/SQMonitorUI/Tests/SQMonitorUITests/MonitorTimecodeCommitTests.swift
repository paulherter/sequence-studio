import Foundation
import SQCore
import Testing
@testable import SQMonitorUI

@MainActor
struct MonitorTimecodeCommitTests {
    @Test func typedTimecodeSeeksAndInvalidTextDoesNot() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30))
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        #expect(m.commitTimecodeText("00:00:05:00"))
        #expect(m.commitTimecodeText("1:15"))
        #expect(!m.commitTimecodeText("abc"))
        #expect(seeks == [Time(5, 1), Time(45, 30)])
    }

    @Test func absoluteEntryPastTheEndLandsOnTheLastFrame() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30))
        m.duration = Time(10, 1)
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        #expect(m.commitTimecodeText("00:01:00:00"))
        #expect(m.commitTimecodeText("00:00:02:00"))
        #expect(seeks == [Time(10, 1) - Time(1, 30), Time(2, 1)])
    }
}
