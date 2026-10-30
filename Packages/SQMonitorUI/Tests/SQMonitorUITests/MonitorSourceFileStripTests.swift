import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

/// The scrub strip under the Program monitor appears while the Color page shows a clip's whole source file.
@MainActor @Suite struct MonitorSourceFileStripTests {
    private func program() -> MonitorPanelModel { MonitorPanelModel(frameDuration: Time(1, 30), mode: .program) }

    @Test func programHasTheStripOnTheSequence() {
        #expect(program().showsScrubStrip)      // v9: the scrub bar sits under the Program picture too
    }

    @Test func programShowsStripOnSourceFile() {
        let m = program()
        m.sourceFileView = true
        #expect(m.showsScrubStrip)
    }

    @Test func sourceMonitorAlwaysHasStrip() {
        #expect(MonitorPanelModel(frameDuration: Time(1, 30), mode: .source).showsScrubStrip)
    }

    @Test func marksStayLockedOnSourceFile() {
        let m = program()
        m.onMarkEdit = { _, _ in }
        #expect(m.marksEditable)
        m.sourceFileView = true
        #expect(!m.marksEditable)   // the marks are the clip's In/Out in the file, not the sequence's
    }
}
