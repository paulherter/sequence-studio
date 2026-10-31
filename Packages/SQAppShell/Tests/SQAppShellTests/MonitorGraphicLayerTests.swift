import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import Testing

/// A click and a drag on a layer of the selected graphic (text or shape) act on that layer alone, never on the clip.
@MainActor
struct MonitorGraphicLayerTests {
    @Test func dragMovesOnlyTheLayerAndLeavesTheClipTransformAlone() throws {
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(),
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost(), qualityDefaults: nil)
        let tl = try #require(s.activeTimeline)
        let cw = Int(tl.format.width), ch = Int(tl.format.height)
        let layer = GraphicsLayer.shape(.rectangle, box: GraphicsRect(minX: -100, minY: -50, maxX: 100, maxY: 50),
                                        canvasWidth: cw, canvasHeight: ch)
        let clipID = try #require(s.addGraphicsClip(duration: Time(5, 1), layers: [layer], neverOverwrite: true))
        s.select(clips: [clipID])
        let editor = GraphicsEditor(session: s)
        host.graphics = { editor }
        editor.sync()
        let m = host.monitor
        m.layout(DrawRect(x: 0, y: 0, w: 1200, h: 800), scale: 1, playhead: .zero, isPlaying: false, hasPicture: true)
        var c = Canvas(width: 1200, height: 800, atlas: nil, scale: 1)
        m.panel.draw(&c)
        let r = m.panel.canvasRect, k = Double(r.width) / Double(tl.format.displayWidth)
        let press = CGPoint(x: Double(r.midX), y: Double(r.midY))
        let before = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clipID })
        let beforeLayer = try #require(before.graphics?.layers.first)

        _ = m.panel.handle(.mouseDown(x: Float(press.x), y: Float(press.y), modifiers: []))
        #expect(editor.selectedLayers == [layer.id])             // the layer, not just the clip
        let to = CGPoint(x: press.x + 60 * k, y: press.y + 30 * k)
        _ = m.panel.handle(.mouseDragged(x: Float(to.x), y: Float(to.y)))
        _ = m.panel.handle(.mouseUp(x: Float(to.x), y: Float(to.y)))

        let after = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clipID })
        let afterLayer = try #require(after.graphics?.layers.first)
        #expect(afterLayer.animation != beforeLayer.animation)    // the layer moved
        #expect(after.renderTransform(at: .zero, frame: editor.canvas) == before.renderTransform(at: .zero, frame: editor.canvas))              // the clip did not
        // Next frame: the selected layer has its own box and handles.
        m.layout(DrawRect(x: 0, y: 0, w: 1200, h: 800), scale: 1, playhead: .zero, isPlaying: false, hasPicture: true)
        #expect(m.panel.layerOverlay.source?.handled?.id == layer.id)
    }
}
