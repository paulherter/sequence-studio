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
}
