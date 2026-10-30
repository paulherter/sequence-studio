import Foundation
import SQAppShell
import SQCore
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

/// Sequence > New Shape through the Create tool (`MonitorHost.createShapeAtCenter`, the Mac `createShapeAtCenter`).
@MainActor
struct MonitorNewShapeTests {
    @Test func newShapeMakesTheCreateToolsCenteredItemInANewGraphic() throws {
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(),
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost(), qualityDefaults: nil)
        let tl = try #require(s.activeTimeline)
        host.monitor.createShapeAtCenter(.ellipse, graphics: nil)
        let docs = try #require(s.activeTimeline).tracks.flatMap(\.clips).compactMap(\.graphics)
        #expect(docs.count == 1)
        let layer = try #require(docs.first?.layers.first)
        #expect(layer.content == .shape(kind: .ellipse))
        let canvas = Vec2(Double(tl.format.width), Double(tl.format.height))
        let drag = GraphicsEditor.menuShapeDrag(.ellipse, canvas: canvas)
        let expected = GraphicsEditor.createdShape(.ellipse, from: drag.from, to: drag.to,
                                                   mapping: GraphicsCanvasMapping(transform: ClipTransform()), canvas: canvas)
        #expect(layer.animation == expected.animation && layer.effects.count == expected.effects.count)
    }
}
