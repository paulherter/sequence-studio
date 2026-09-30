import AppKit
import Foundation
import Testing
import SSCore
@testable import SSEditorUI

@MainActor @Suite struct ColorPanelEditTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, Clip) {
        let fd = Time(1, 30)
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look"))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        return (session, ColorInspectorPanelView(session: session), clip)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    @Test func inspectorEditsWriteClipColorAsOneUndoStepPerGesture() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        #expect(model.detectedSource == .sLog3SGamut3Cine && model.embeddedLUTName == "Look")

        // A slider drag: begin, several changes, end = one undo step.
        model.onGestureBegan?()
        model.set(.exposure, 0.5); model.set(.exposure, 1); model.set(.exposure, 1.5)
        model.onGestureEnded?()
        #expect(current(session, clip.id).color.correction.exposure == 1.5)
        #expect(session.undoName == "Color")
        session.undo()
        #expect(current(session, clip.id).color.correction.exposure == 0)
        #expect(!session.canUndo)

        // Popup-style edits are each their own gesture.
        model.gesture { model.setSourceOverride(.rec709) }
        model.gesture { model.conversionLUT = .file("/tmp/x.cube") }
        model.gesture { model.creativeLUT = .file("/tmp/c.cube"); model.creativeIntensity = 0.4 }
        let c = current(session, clip.id).color
        #expect(c.source == .rec709 && c.conversionLUT == .file("/tmp/x.cube"))
        #expect(c.creativeLUT == .file("/tmp/c.cube") && c.creativeIntensity == Double(Float(0.4)))
        session.undo(); session.undo(); session.undo()
        #expect(current(session, clip.id).color == .default)
    }

    @Test func undoReloadsTheInspector() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.gesture { model.set(.tint, 20) }
        #expect(model.value(.tint) == 20)
        session.undo()
        panel.sync([.project])
        #expect(model.value(.tint) == 0)
    }

    @Test func engineReceivesEditedColor() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.gesture { model.set(.saturation, 50) }
        let stub = try #require(session.engine as? StubProgramEngine)
        #expect(stub.timeline?.tracks[0].clips[0].color.correction.saturation == 50)
    }

    @Test func resettingDefaultsIsNotAnUndoStep() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        for s in ColorInspectorModel.Section.allCases { model.reset(s) }
        model.resetAll()
        #expect(!session.canUndo)
        #expect(current(session, clip.id).color == .default)
        // A real edit, then reset: back to the default, two steps.
        model.gesture { model.conversionLUT = nil }
        #expect(current(session, clip.id).color.conversionLUT == nil)
        model.reset(.conversionLUT)
        #expect(current(session, clip.id).color == .default)
    }
}
