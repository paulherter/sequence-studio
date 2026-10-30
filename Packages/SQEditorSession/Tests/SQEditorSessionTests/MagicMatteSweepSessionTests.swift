import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Orphaned Magic matte files: the session hands over the project it lets go of (close, open another, new) and whether it
/// was unsaved, so the app can drop the mattes of picks that changed (`MagicMatteStore.sweep`).
@MainActor @Suite struct MagicMatteSweepSessionTests {
    private func project() throws -> Project {
        var c = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        c.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])]
        var v = Track(kind: .video)
        try v.overwrite(c)
        return Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])])
    }

    @Test func releasingAProjectReportsItAndWhetherItWasUnsaved() throws {
        let p = try project()
        let ses = EditorSession(project: p, engine: StubProgramEngine())
        var got: [(Set<String>, Bool)] = []
        ses.onReleaseProject = { project, dirty in got.append((project.magicMatteCacheKeys, dirty)) }
        ses.newProject(p)
        #expect(got.count == 1)
        #expect(got.first?.0 == p.magicMatteCacheKeys)
        #expect(got.first?.1 == false)
        #expect(!p.magicMatteCacheKeys.isEmpty)
        ses.perform("Rename") { $0.name = "Q" }
        ses.close()
        #expect(got.count == 2)
        #expect(got.last?.1 == true)
    }
}
