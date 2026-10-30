import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

/// Sequence > Add Title (Cmd+T): one Graphic clip with two lines and an emoji as text layers.
@MainActor @Suite struct AddTitleTests {
    private func session(withHead: Bool = true) -> EditorSession {
        var tracks = Timeline.defaultTracks(video: 2, audio: 1)
        if withHead {
            try! tracks[0].overwrite(Clip(name: "head", media: UUID(), kind: .video,
                                          source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero))
        }
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: tracks)
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip? { s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id } }
    private func track(_ s: EditorSession, of id: Clip.ID) -> Track? { s.activeTimeline?.tracks.first { $0.clips.contains { $0.id == id } } }

    private func defaults() -> UserDefaults {
        let name = "sq.test.addTitle.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func addsOneGraphicClipAsOneUndoStep() throws {
        let s = session()
        let depth = s.undoDepth
        let ids = s.addTitle(lookDefaults: defaults())
        #expect(ids.count == 1)
        #expect(s.undoDepth == depth + 1)
        let c = try #require(clip(s, ids[0]))
        #expect(c.isGraphics)
        #expect(c.graphics?.layers.count == 3)
        #expect(s.activeTimeline?.tracks.count == 3)               // V2 was free: no new track
        #expect(track(s, of: ids[0])?.id != s.activeTimeline!.tracks[0].id)      // never on the talking head
        let texts = try c.graphics!.layers.map { l -> String in
            guard case .text(let ref) = l.content else { throw EditError.clipNotFound }
            return try TextGenerator.decode(ref).0.text
        }
        #expect(texts == TitleBuilder.placeholderTexts)
        #expect(s.selection == [ids[0]])
        #expect(s.graphicLayerSelection == GraphicLayerSelection(clip: ids[0], layers: [c.graphics!.layers[0].id]))
        s.undo()
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).count == 1)
        #expect(s.activeTimeline?.tracks.count == 3)
    }

    @Test func usesTheLastUsedLook() throws {
        let s = session()
        let d = defaults()
        let store = LookStore.shared
        let look = try #require(LookLibrary.builtIns.first)
        s.rememberTextLook(LookRef(scope: .builtIn, id: look.id), defaults: d)
        let ids = s.addTitle(lookDefaults: d, store: store)
        let c = try #require(clip(s, ids[0]))
        guard case .text(let ref)? = c.graphics?.layers.first?.content else { Issue.record("no text"); return }
        let t = try TextGenerator.decode(ref).0
        #expect(t.lookID == look.id)
        #expect(t.style == look.style)
    }

    @Test func layoutStacksTheLinesUnderTheEmoji() throws {
        let s = session()
        let ids = s.addTitle(lookDefaults: defaults())
        let y = try #require(clip(s, ids[0])?.graphics?.layers).map { $0.animation.position.value.y }
        #expect(y[2] < y[0] && y[0] < y[1])    // emoji above line 1, line 2 below it (y grows down)
        #expect(y.allSatisfy { abs($0) < 960 })
    }

    @Test func emptySequenceStartsOnV1() {
        let s = session(withHead: false)
        let ids = s.addTitle(lookDefaults: defaults())
        #expect(track(s, of: ids[0])?.id == s.activeTimeline!.tracks[0].id)
    }
}
