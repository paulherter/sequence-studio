import Foundation
import Testing
import SQCore
import SQUIKit
@testable import SQMonitorUI

@MainActor @Suite struct MonitorRangeAndTransportTests {
    @Test func transportIsSymmetricWithPlayInTheMiddle() {
        for mode in [MonitorMode.program, .source] {
            let bar = MonitorAction.buttonBar(for: mode)
            #expect(bar.first == .markIn && bar.last == .markOut)
            #expect(bar[bar.count / 2] == .playPause && bar.count % 2 == 1)
        }
    }

    @Test func zoomedPictureHasNoMarginSoTheBackdropIsOneColor() {
        #expect(MonitorPanelView.viewerMargin(for: .fit) == Theme.Spacing.md)
        #expect(MonitorPanelView.viewerMargin(for: .percent(100)) == 0)
        #expect(MonitorPanelView.viewerMargin(for: .percent(200)) == 0)
    }

    @Test func markMenuRowsFollowTheMarks() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25))
        var log: [MonitorAction] = []
        m.onAction = { log.append($0) }
        #expect(m.markMenu().filter { !$0.title.isEmpty && $0.isEnabled }.isEmpty)
        m.duration = Time(10, 1); m.markIn = Time(2, 1)
        let rows = m.markMenu()
        #expect(rows.first { $0.title == "Remove In" }?.isEnabled == true)
        #expect(rows.first { $0.title == "Remove Out" }?.isEnabled == false)
        rows.first { $0.title == "Remove In" }?.action?()
        rows.first { $0.title == "Go to In" }?.action?()
        #expect(log == [.clearIn, .goToIn])
        m.markOut = Time(5, 1)
        #expect(m.markMenu().first { $0.title == "Remove In and Out" }?.isEnabled == true)
    }

    @Test func lockedSourceFileViewCannotClearMarks() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .source)
        m.markIn = Time(1, 1); m.sourceFileView = true
        #expect(m.markMenu().first { $0.title == "Remove In" }?.isEnabled == false)
    }

    @Test func sequencePopupListsOpenSequencesOnly() {
        let a = UUID(), b = UUID()
        let items = [MonitorPanelModel.SequenceItem(id: a, name: "Main"), .init(id: b, name: "Intro")]
        var picked: UUID?
        let rows = MonitorMenus.sequenceItems(items, current: b) { picked = $0 }
        #expect(rows.map(\.title) == ["Main", "Intro"])
        #expect(rows.filter(\.isChecked).map(\.title) == ["Intro"])
        rows[0].action?()
        #expect(picked == a)
        #expect(MonitorMenus.sequenceTitle(items, current: b, fallback: "") == "Intro")
    }
}
