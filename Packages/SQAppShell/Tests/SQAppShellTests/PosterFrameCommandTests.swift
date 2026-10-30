import Foundation
import SQAppShell
import SQCore
import SQEditorSession
import Testing

@MainActor
struct PosterFrameCommandTests {
    private func model() -> (ProjectPanelModel, MediaRef.ID, MediaRef.ID) {
        var p = EditorSession.makeUntitled()
        let a = MediaRef(name: "a", path: "/tmp/a.mov", fingerprint: MediaFingerprint(size: 0)), b = MediaRef(name: "b", path: "/tmp/b.mov", fingerprint: MediaFingerprint(size: 0))
        p.media = [a, b]
        let m = ProjectPanelModel(project: p, onEdit: { _, _ in })
        return (m, a.id, b.id)
    }

    @Test func setTakesTheSourceFrameOfTheSelectedClipOnly() {
        let (m, a, b) = model()
        let t = Time(3, 1)
        #expect(PosterFrameCommand.run(clear: false, selected: [.media(a)], source: (b, t), model: m) != nil)
        #expect(m.project.media(a)?.posterTime == nil)
        #expect(PosterFrameCommand.run(clear: false, selected: [.media(a), .media(b)], source: (b, t), model: m) == nil)
        #expect(m.project.media(b)?.posterTime == t)
        #expect(m.project.media(a)?.posterTime == nil)
    }

    @Test func clearResetsEverySelectedClipAndNothingSelectedSaysSo() {
        let (m, a, b) = model()
        _ = PosterFrameCommand.run(clear: false, selected: [.media(a)], source: (a, Time(1, 1)), model: m)
        #expect(m.project.media(a)?.posterTime == Time(1, 1))
        #expect(PosterFrameCommand.run(clear: true, selected: [.media(a), .media(b)], source: nil, model: m) == nil)
        #expect(m.project.media(a)?.posterTime == nil)
        #expect(PosterFrameCommand.run(clear: false, selected: [], source: (a, .zero), model: m) == "Select a clip first.")
    }
}
