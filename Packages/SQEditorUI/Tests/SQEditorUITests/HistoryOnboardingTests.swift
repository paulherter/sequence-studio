import AppKit
import Testing
import SQEditorSession
@testable import SQEditorUI

@MainActor
@Suite struct HistoryOnboardingTests {
    @Test func listViewReportsPickedRowAndReloads() {
        let v = HistoryListView(list: HistoryList(undoNames: ["A", "B"], redoNames: ["C"]), width: 300)
        #expect(v.list.rows.count == 4)
        v.reload(HistoryList(undoNames: ["A", "B", "C"], redoNames: []))
        #expect(v.list.position == 3)
        #expect(v.frame.height == HistoryListView.height)
    }

    @Test func onboardingIsShortAndComplete() {
        #expect(OnboardingContent.tips.count <= 6)
        #expect(OnboardingContent.tips.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        let body = OnboardingDialog.makeBody(width: 360)
        body.layoutSubtreeIfNeeded()
        #expect(body.fittingSize.height > 0)
    }
}
