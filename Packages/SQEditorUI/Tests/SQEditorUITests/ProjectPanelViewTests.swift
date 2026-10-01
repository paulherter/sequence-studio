import AppKit
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct ProjectPanelViewTests {
    @Test func buildsAndReloads() {
        var p = Project(name: "P")
        p.add(MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1)))
        let model = ProjectPanelModel(project: p, onEdit: { _, _ in })
        let view = ProjectPanelView(model: model)
        view.layoutSubtreeIfNeeded()
        #expect(model.isOffline(p.media[0].id))
        _ = model.newBin()
        #expect(model.project.rootBin.children.count == 2)
    }

    // Review finding 10: switching list -> icons while a sub-bin was current showed the sub-bin without a way out.
    @Test func switchingToIconsShowsTheBrowsedBin() throws {
        let model = ProjectPanelModel(project: Project(name: "P"), onEdit: { _, _ in })
        let sub = try #require(model.newBin())
        model.currentBin = sub
        let suite = UserDefaults(suiteName: "sq-test-\(UUID().uuidString)")!
        let view = ProjectPanelView(model: model, defaults: suite)
        view.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSSegmentedControl? {
            if let s = v as? NSSegmentedControl, s.segmentCount == 2 { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        let toggle = try #require(find(view))
        toggle.selectedSegment = 1
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        #expect(model.currentBin == model.browseBin)
    }
}
