import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Log handling, delivery space and HDR conform on the Color page's input rows.
@MainActor @Suite struct ColorFootageModeTests {
    func rig() throws -> (EditorSession, ColorInspectorModel, Clip.ID) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1), detectedColorSpace: .sLog3SGamut3Cine))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        let panel = ColorInspectorPanelView(session: session)
        return (session, try #require(panel.colorModels[clip.id]), clip.id)
    }

    func footage(_ s: EditorSession, _ id: Clip.ID) -> ClipFootageColor {
        s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!.footageColor
    }

    @Test func settersWriteTheClip() throws {
        let (session, model, id) = try rig()
        #expect(model.logMode == .cameraLUT && model.targetSpace == .rec709 && model.hdrConform)
        model.setLogMode(.builtIn)
        model.setTargetSpace(.rec2020HLG)
        model.setHDRConform(false)
        let f = footage(session, id)
        #expect(f.logMode == .builtIn && f.targetSpace == .rec2020HLG && !f.hdrConform)
    }

    @Test func resetAllKeepsTheFootageSettings() throws {
        let (session, model, id) = try rig()
        model.setLogMode(.off); model.setHDRConform(false)
        model.set(1, .exposure, 1)
        model.resetAll()
        let f = footage(session, id)
        #expect(f.logMode == .off && !f.hdrConform)
        let clip = session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!
        #expect(clip.color.effects[0].basic.isNeutral)
    }
}
