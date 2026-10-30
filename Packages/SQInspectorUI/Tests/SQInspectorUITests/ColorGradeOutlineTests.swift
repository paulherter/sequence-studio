import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Color grading UI step 2: the timeline outlines what the Color panel grades (target plus the clips sharing its
/// grade), and the arrow keys step through the Clips strip.
@MainActor @Suite struct ColorGradeOutlineTests {
    func rig() throws -> (EditorSession, ids: [Clip.ID], other: Clip.ID) {
        let m = UUID()
        func clip(_ n: String, _ media: UUID, _ at: Int64) -> Clip {
            Clip(name: n, media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(at, 1))
        }
        let a = clip("A", m, 0), b = clip("B", m, 2), c = clip("C", UUID(), 4)
        var v = Track(kind: .video)
        try v.overwrite(a); try v.overwrite(b); try v.overwrite(c)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])
        let ref = MediaRef(id: m, name: "x.mp4", path: "/x/x.mp4", fingerprint: MediaFingerprint(size: 1))
        let s = EditorSession(project: Project(name: "P", media: [ref], timelines: [t]), engine: StubProgramEngine())
        return (s, [a.id, b.id], c.id)
    }

    @Test func outlineCoversTheTargetAndItsLinkedUses() throws {
        let (s, ids, other) = try rig()
        let r = ColorGradeOutline.clips(.clip(ids[0]), project: s.project)
        #expect(r == Set(ids), "both cuts of the source share the grade before any edit")
        #expect(!r.contains(other))
    }

    @Test func independentClipOutlinesOnlyItself() throws {
        let (s, ids, _) = try rig()
        try s.perform("Setup") { p in _ = p.setGradeLinkedToSource(ids[0], false) }
        #expect(ColorGradeOutline.clips(.clip(ids[0]), project: s.project) == [ids[0]])
    }

    @Test func messageAndSequenceOutline() throws {
        let (s, _, _) = try rig()
        #expect(ColorGradeOutline.clips(.message("x"), project: s.project).isEmpty)
        let layer = UUID()
        let tl = try #require(s.activeTimelineID)
        #expect(ColorGradeOutline.clips(.sequence(tl, layer: layer), project: s.project) == [layer])
        #expect(ColorGradeOutline.clips(.sequence(tl, layer: nil), project: s.project).isEmpty)
    }

    @Test func arrowsStepThroughTilesAndStopAtTheEnds() {
        #expect(ColorClipsPanelView.steppedIndex(from: nil, count: 3, forward: true) == 0)
        #expect(ColorClipsPanelView.steppedIndex(from: nil, count: 3, forward: false) == 2)
        #expect(ColorClipsPanelView.steppedIndex(from: 0, count: 3, forward: true) == 1)
        #expect(ColorClipsPanelView.steppedIndex(from: 2, count: 3, forward: true) == 2)
        #expect(ColorClipsPanelView.steppedIndex(from: 0, count: 3, forward: false) == 0)
        #expect(ColorClipsPanelView.steppedIndex(from: nil, count: 0, forward: true) == nil)
    }
}
