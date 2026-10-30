import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Edit page main-thread suspects: a playhead tick must not rebuild the Graphics panel while it is hidden, nor
/// refresh every property row when no layer is animated.
@MainActor @Suite struct GraphicsPanelTickTests {
    func rig() -> (EditorSession, GraphicsPanelView, GraphicsEditor) {
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: session)
        let v = GraphicsPanelView(editor: e)
        e.newGraphicsClip()
        e.addText()
        v.sync([.project, .selection])
        return (session, v, e)
    }

    private func perf(_ label: String, _ ms: Double) {
        guard let dir = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] else { return }
        let line = "graphicsView.sync playhead tick \(label): \(ms) ms\n"
        let h = FileHandle(forWritingAtPath: dir) ?? { FileManager.default.createFile(atPath: dir, contents: nil); return FileHandle(forWritingAtPath: dir)! }()
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    }

    private func run(_ session: EditorSession, _ v: GraphicsPanelView, _ label: String) {
        let n = 3000
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<n { session.seek(to: Time(Int64(i % 90), 30)); v.sync([.playhead]) }
        perf(label, (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n))
    }

    @Test func hiddenPanelSkipsTicksAndCatchesUp() {
        let (session, v, _) = rig()
        let host = NSView(); host.addSubview(v)
        host.isHidden = true
        run(session, v, "hidden")
        #expect(v.skippedTicks == 3000)
        host.isHidden = false
        #expect(v.skippedTicks == 3000)
    }

    @Test func visibleTicksWithoutAnimationShortCut() {
        let (session, v, e) = rig()
        run(session, v, "visible, nothing animated")
        #expect(v.shortCutTicks > 2000)
        #expect(e.clip != nil)
    }
}
