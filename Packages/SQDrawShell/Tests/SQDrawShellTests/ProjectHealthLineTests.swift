import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite(.serialized) struct ProjectHealthLineTests {
    static var hosts: [ShellHost] = []

    /// One file inside the project folder, one outside it, one offline.
    func view() throws -> (ProjectListView, ProjectPanelModel) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sq-health-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Project"), elsewhere = root.appendingPathComponent("Elsewhere")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("a.wav"), outside = elsewhere.appendingPathComponent("b.wav")
        try Data([0]).write(to: inside)
        try Data([0]).write(to: outside)
        let media = [inside.path, outside.path, root.appendingPathComponent("gone.wav").path].map {
            MediaRef(name: ($0 as NSString).lastPathComponent, path: $0, fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1))
        }
        let s = EditorSession(project: Project(name: "P", media: media, timelines: [Timeline(name: "Main", frameDuration: Time(1, 30))]))
        let h = ShellHost(session: s, map: .premiereDefault)
        let model = ProjectPanelModel(project: s.project, probe: ShellImportTests.fakeProbe, onEdit: { _, _ in })
        model.projectFolder = { folder }
        model.refreshOffline()
        h.projectModel = model
        Self.hosts.append(h)
        let v = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.health.\(UUID())")!)
        v.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        return (v, model)
    }

    @Test func theLineShowsTheCountsAndShortensTheList() throws {
        let (v, m) = try view()
        #expect(m.health == ProjectHealth(inFolder: 1, outside: 1, missing: 1))
        let line = try #require(v.healthRect)
        #expect(line.maxY == v.frame.maxY && line.height == 24)
        #expect(v.listRect.maxY == line.minY)
        let parts = v.healthLayout(TextMeasure(atlas: nil, scale: 1)).map(\.part)
        #expect(parts == [.inFolder, .outside, .missing, .fix])
        #expect(ProjectListView.healthTexts(m.health).map(\.1) == ["1 in folder", "1 outside", "1 missing"])
    }

    @Test func missingFiltersToOfflineAndFixOffersCollectOnlyWithAHost() throws {
        let (v, m) = try view()
        let layout = v.healthLayout(TextMeasure(atlas: nil, scale: 1))
        let missing = try #require(layout.first { $0.part == .missing }?.rect)
        _ = v.handle(.mouseDown(x: Float(missing.midX), y: Float(missing.midY), modifiers: []), scale: 1)
        #expect(m.mediaFilter == .offline)
        let fix = try #require(layout.first { $0.part == .fix }?.rect)
        _ = v.handle(.mouseDown(x: Float(fix.midX), y: Float(fix.midY), modifiers: []), scale: 1)
        let menu = try #require(v.host?.menuBar.controller.views.first)
        #expect(menu.items.map(\.title) == ["Reconnect 1 missing file…", "Show missing files"])
        v.host?.menuBar.controller.dismiss()
        var collected = 0
        v.onCollect = { collected += 1 }
        _ = v.handle(.mouseDown(x: Float(fix.midX), y: Float(fix.midY), modifiers: []), scale: 1)
        let rows = try #require(v.host?.menuBar.controller.views.first).items
        #expect(rows.first?.title == "Collect 1 file into project")
        rows.first?.action?()
        #expect(collected == 1)
    }

    @Test func aHealthyProjectHasNoLine() {
        let items = ProjectListView.healthMenuItems(for: ProjectHealth(inFolder: 3), canCollect: true, run: { _ in }, collect: {})
        #expect(items.isEmpty)
        let v = ProjectListView(host: ShellHost(session: EditorSession(project: Project(name: "P")), map: .premiereDefault),
                                defaults: UserDefaults(suiteName: "sq.test.health.\(UUID())")!)
        #expect(v.healthRect == nil)
    }
}
