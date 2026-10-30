import AppKit
import Testing
import SQCore
import SQUIKit
@testable import SQEditorUI

/// A fresh project from a template already has one sequence; Pip (M3) must still show in the Project panel, list and icons.
@MainActor @Suite struct ProjectEmptyPipTests {
    private func pips(in v: NSView) -> [SQMascotView] {
        (v as? SQMascotView).map { [$0] } ?? v.subviews.flatMap { pips(in: $0) }
    }

    private func freshProjectPanel(mode: ProjectPanelView.ViewMode) -> (ProjectPanelView, NSWindow) {
        let t = Timeline(name: "Sequence 1", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [Track(kind: .video)])
        let model = ProjectPanelModel(project: Project(name: "P", timelines: [t]), onEdit: { _, _ in })
        let suite = UserDefaults(suiteName: "sq-test-\(UUID().uuidString)")!
        let view = ProjectPanelView(model: model, defaults: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.setViewMode(mode)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @Test func showsOnlyWithoutMediaEvenWhenASequenceExists() {
        let s = BinItemRef.sequence(UUID()), m = BinItemRef.media(UUID())
        #expect(ProjectPanelView.showsEmptyState([s], searching: false))
        #expect(ProjectPanelView.showsEmptyState([], searching: false))
        #expect(!ProjectPanelView.showsEmptyState([s, m], searching: false))
        #expect(!ProjectPanelView.showsEmptyState([s], searching: true))
        #expect(ProjectPanelView.showsEmptyState([], searching: true))
    }

    @Test func listViewShowsPipWithSizeForFreshProject() {
        let (view, window) = freshProjectPanel(mode: .list)
        _ = window
        let e = view.emptyStateForTesting
        #expect(!e.isHidden)
        let pip = pips(in: e).first
        #expect(pip?.place == .projectEmpty)
        #expect((pip?.frame.width ?? 0) > 0 && (pip?.frame.height ?? 0) > 0)
        #expect(pip?.isShownWithSize == true)
    }

    @Test func iconViewShowsPipWithSizeForFreshProject() {
        let (view, window) = freshProjectPanel(mode: .icons)
        _ = window
        view.layoutSubtreeIfNeeded()
        let e = view.gridForTesting.emptyStateForTesting
        #expect(!e.isHidden)
        let pip = pips(in: e).first
        #expect(pip?.place == .projectEmpty)
        #expect(pip?.isShownWithSize == true)
    }
}
