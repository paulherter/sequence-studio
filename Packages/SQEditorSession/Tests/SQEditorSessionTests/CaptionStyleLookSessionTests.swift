import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}
private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "default")
}

@MainActor @Suite struct CaptionStyleLookSessionTests {
    @Test func aGalleryLookSetsStyleAnimationAndHighlightInOneStep() {
        let session = makeSession()
        let spark = CaptionStyleLooks.look(id: "spark")!
        #expect(!session.applyCaptionStyleLook(spark))                      // no caption track yet
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        let depth = session.undoDepth
        #expect(session.applyCaptionStyleLook(spark))
        #expect(session.undoDepth == depth + 1)
        #expect(session.captionItems.map(\.styleRef) == ["tiktok", "tiktok"])
        #expect(session.captionItems.map(\.animationRef) == ["pop", "pop"])
        #expect(session.captionKaraoke == spark.karaoke)
        #expect(session.currentCaptionStyleLook == spark)
        #expect(session.applyCaptionStyleLook(CaptionStyleLooks.look(id: "wave")!))
        #expect(session.captionKaraoke == nil && session.currentCaptionStyleLook?.id == "wave")
        session.undo()
        #expect(session.currentCaptionStyleLook == spark)
    }

    /// The Style tab's "all captions" edit starts from what the captions show (an applied Look), not from the default.
    @Test func styleAllEditKeepsTheAppliedLookAndChangesOnlyTheEditedField() throws {
        let session = makeSession(), store = LookStore(url: nil)
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        let look = LookLibrary.builtIns[0]
        #expect(session.applyLook(LookRef(scope: .builtIn, id: look.id), store: store))
        let before = try #require(session.captionStyleState(scope: .all)?.style)
        #expect(before.fontName == look.style.fontName && before.color == look.style.color)
        #expect(session.editCaptionStyle(.size(77), scope: .all))
        let after = try #require(session.captionStyleState(scope: .all)?.style)
        var expected = before
        expected.size = 77
        #expect(after == expected)
        #expect(Set(session.captionItems.map(\.styleRef)).count == 1)
        // A second edit continues from that result.
        #expect(session.editCaptionStyle(.allCaps(true), scope: .all))
        let third = try #require(session.captionStyleState(scope: .all)?.style)
        #expect(third.size == 77 && third.allCaps && third.color == before.color)
    }

    @Test func aLookOnlyChangesItsOwnTrack() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1)])
        #expect(session.applyCaptionStyleLook(CaptionStyleLooks.look(id: "spark")!))
        guard let second = session.addCaptionTrack() else { Issue.record("no second track"); return }
        session.addCaptions([item("b", 2, 3)])
        let pop = CaptionStyleLooks.look(id: "pop")!
        #expect(session.applyCaptionStyleLook(pop))                         // focused track = the new one
        let tracks = session.activeTimeline!.captionTracks
        #expect(tracks.count == 2)
        #expect(tracks[1].id == second && tracks[1].styleRef == pop.styleRef && tracks[1].karaoke == nil)
        #expect(tracks[0].styleRef == "tiktok" && tracks[0].karaoke != nil)  // the first track kept its look
        // an explicit track target works and releases the captions' own style
        session.select(clips: [], captions: [tracks[0].items[0].id])
        _ = session.setSelectedCaptionStyle("outline")
        #expect(session.applyCaptionStyleLook(CaptionStyleLooks.look(id: "rise")!, track: tracks[0].id))
        #expect(session.captionItems.first?.styleRef == "sticker")
        #expect(session.activeTimeline!.captionTracks[1].styleRef == pop.styleRef)
    }
}
