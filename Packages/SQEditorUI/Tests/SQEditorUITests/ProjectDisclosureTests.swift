import AppKit
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// A single click on a folder's disclosure arrow in the Project list toggles it (no double click needed).
@MainActor
struct ProjectDisclosureTests {
    @Test func singleClickOnArrowTogglesTheFolder() throws {
        var p = Project(name: "P")
        let m = MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1))
        p.add(m)
        let model = ProjectPanelModel(project: p, onEdit: { _, _ in })
        let bin = try #require(model.newBin())
        _ = model.move([.media(m.id)], to: bin)
        let suite = UserDefaults(suiteName: "sq-test-\(UUID().uuidString)")!
        let view = ProjectPanelView(model: model, defaults: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        view.layoutSubtreeIfNeeded()

        let o = view.outlineForTesting
        let row = try #require((0..<o.numberOfRows).first { o.isExpandable(o.item(atRow: $0)) })
        let item = try #require(o.item(atRow: row))
        #expect(!o.isItemExpanded(item))
        let button = try #require(view.disclosureButtonForTesting(row: row))
        // The arrow's center hits the button, not the row or cell.
        let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(window.contentView!.convert(centre, from: nil)) === button)
        #expect(button.target != nil && button.action != nil, "the arrow must be wired to toggle on a single click")
        button.performClick(nil)
        #expect(o.isItemExpanded(item))
        button.performClick(nil)
        #expect(!o.isItemExpanded(item))
    }
}

/// The Project list shows what the project holds: no automatic Footage / Audio categories. Real folders hold their
/// items one level in, loose items sit at the top, and the Name column leaves room for Format and Duration at panel width.
@MainActor
struct ProjectGroupOpenTests {
    private func project() -> Project {
        var p = Project(name: "P")
        p.add(MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1)))
        p.add(MediaRef(name: "b.mp3", path: "/nonexistent/b.mp3", fingerprint: MediaFingerprint(size: 1)))
        return p
    }

    @Test func noAutomaticCategoryRows() async throws {
        let model = ProjectPanelModel(project: project(), onEdit: { _, _ in })
        let view = ProjectPanelView(model: model, defaults: UserDefaults(suiteName: "sq-test-\(UUID().uuidString)")!)
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        view.layoutSubtreeIfNeeded()
        let o = view.outlineForTesting
        #expect(o.numberOfRows == 2)                                            // the two loose items, nothing else
        #expect((0..<o.numberOfRows).allSatisfy { !o.isExpandable(o.item(atRow: $0)) })
        let bin = try #require(model.newBin())
        _ = model.move([model.project.rootBin.children[0].ref], to: bin)
        for _ in 0..<5 { await Task.yield() }
        #expect(o.numberOfRows == 2)                                            // folder + the loose item
        let folderRow = try #require((0..<o.numberOfRows).first { o.isExpandable(o.item(atRow: $0)) })
        o.expandItem(o.item(atRow: folderRow))
        #expect(o.numberOfRows == 3)
        #expect(o.level(forItem: o.item(atRow: folderRow + 1)) == 1)
        let used = o.tableColumns.reduce(0) { $0 + $1.width + o.intercellSpacing.width }
        #expect(o.tableColumns.count == 3 && used <= 340 + 1)
    }
}
