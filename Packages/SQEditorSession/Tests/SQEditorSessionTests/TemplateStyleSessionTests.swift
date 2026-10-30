import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

@MainActor @Suite struct TemplateStyleSessionTests {
    private func fade(_ a: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                         duration: Time(1, 5), anchor: a)
    }

    @Test func templateStyleReachesSelectedTextAndKeepsItsWords() throws {
        let fd = Time(1, 30)
        let tl = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .video)])
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let id = try #require(session.addTextClip(template: TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 40))))
        // A template: one text layer, size 99, in and out animation.
        let src = TextTemplate(name: "T", text: "Sample", style: TextStyle(size: 99))
        let ref = try TextGenerator.makeRef(template: src, animations: AnimationSet(in: fade(.start), out: fade(.end)))
        let layer = Clip(name: "L", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero, generator: ref)
        var track = Track(kind: .video)
        try track.overwrite(layer)
        let tpl = TitleTemplate(name: "TikTok text", content: Timeline(name: "C", frameDuration: fd, tracks: [track]))

        session.select(clips: [id])
        #expect(session.canApplyTemplateStyle)
        let depth = session.undoDepth
        #expect(session.applyTemplateStyle(tpl))
        #expect(session.undoDepth == depth + 1)
        let clip = try #require(session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        let (t, a) = try TextGenerator.decode(try #require(clip.generator))
        #expect(t.text == "Hello" && t.style.size == 99)
        #expect(a?.animationIn != nil && a?.animationOut != nil)
    }
}
