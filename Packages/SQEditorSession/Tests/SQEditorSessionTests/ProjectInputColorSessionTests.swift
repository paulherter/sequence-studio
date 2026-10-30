import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// W9.3 review: `Project.inputColorSpace` is set through one undoable session action that reaches the renderer.
@MainActor @Suite struct ProjectInputColorSessionTests {
    private static func video(tagged: Bool) -> VideoTrackInfo {
        VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false,
                       colorPrimaries: tagged ? "ITU_R_709_2" : nil, transfer: tagged ? "ITU_R_709_2" : nil)
    }

    private static func ref(_ name: String, tagged: Bool) -> MediaRef {
        MediaRef(name: name, path: "/nowhere/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                 info: MediaInfo(duration: Time(2, 1), video: video(tagged: tagged), detectedColorSpace: .rec709))
    }

    private func makeSession() -> (EditorSession, StubProgramEngine, MediaRef, MediaRef) {
        var p = EditorSession.makeUntitled()
        let untagged = Self.ref("vlog.mov", tagged: false), phone = Self.ref("phone.mov", tagged: true)
        p.add(untagged); p.add(phone)
        let engine = StubProgramEngine()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-input-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = EditorSession(project: p, engine: engine, autosaveStore: AutosaveStore(base: dir))
        return (session, engine, untagged, phone)
    }

    @Test func settingTheProjectDefaultIsOneUndoStepAndReachesTheResolver() {
        let (session, engine, untagged, phone) = makeSession()
        #expect(session.media.info(of: untagged.id)?.colorSpace == .rec709)
        let redraws = engine.redrawCount

        session.setProjectInputColorSpace(.vLogVGamut)
        #expect(session.project.inputColorSpace == .vLogVGamut)
        #expect(session.canUndo)
        #expect(session.undoName == EditorSession.projectInputColorUndoName)
        #expect(session.isDirty)
        #expect(session.media.info(of: untagged.id)?.colorSpace == .vLogVGamut)
        #expect(session.media.info(of: phone.id)?.colorSpace == .rec709)       // tagged Rec.709 keeps its space
        #expect(session.project.media.first { $0.id == untagged.id }?.info?.detectedColorSpace == .rec709)  // stored detection untouched
        #expect(engine.redrawCount > redraws)

        let afterSet = engine.redrawCount
        _ = session.undo()
        #expect(session.project.inputColorSpace == nil)
        #expect(session.media.info(of: untagged.id)?.colorSpace == .rec709)
        #expect(engine.redrawCount > afterSet)                                  // undo redraws too
        _ = session.redo()
        #expect(session.project.inputColorSpace == .vLogVGamut)
        #expect(session.media.info(of: untagged.id)?.colorSpace == .vLogVGamut)
    }

    @Test func settingTheSameValueAddsNoUndoStep() {
        let (session, _, _, _) = makeSession()
        session.setProjectInputColorSpace(nil)
        #expect(!session.canUndo)
        session.setProjectInputColorSpace(.appleLog)
        session.setProjectInputColorSpace(.appleLog)
        _ = session.undo()
        #expect(!session.canUndo)
        #expect(session.project.inputColorSpace == nil)
    }
}
