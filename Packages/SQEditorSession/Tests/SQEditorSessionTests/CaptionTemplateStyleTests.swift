import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

@MainActor @Suite struct CaptionTemplateStyleTests {
    private func template(_ fd: Time) throws -> TitleTemplate {
        let shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.7), offsetX: 0, offsetY: 3, blur: 5)
        let anim = KeyframeTemplate(tracks: [AnimationTrack(property: "scale", keys: [(.zero, 0.8, .easeOut), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5), anchor: .start)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "x", style: TextStyle(size: 77, shadow: shadow)),
                                            animations: AnimationSet(in: anim, out: nil))
        let layer = Clip(name: "L", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero, generator: ref)
        var track = Track(kind: .video)
        try track.overwrite(layer)
        return TitleTemplate(name: "Pop", content: Timeline(name: "C", frameDuration: fd, tracks: [track]))
    }

    @Test func templateBecomesTrackStyleOfOneTrack() throws {
        let fd = Time(1, 30)
        var a = CaptionTrack(name: "A"), b = CaptionTrack(name: "B")
        try a.replaceAll([CaptionItem(lines: ["hi"], range: TimeRange(start: .zero, duration: Time(1, 1)))])
        try b.replaceAll([CaptionItem(lines: ["yo"], range: TimeRange(start: .zero, duration: Time(1, 1)))])
        var tl = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video)])
        tl.captionTracks = [a, b]
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        #expect(session.canApplyTemplateStyle)
        let depth = session.undoDepth
        #expect(session.applyTemplateStyle(try template(fd), captionTrack: a.id))
        #expect(session.undoDepth == depth + 1)
        let tracks = try #require(session.activeTimeline?.captionTracks)
        #expect(tracks[0].styleRef == CaptionLook.styleID(for: StyleKit.lookID("template-Pop")))
        #expect(tracks[0].animationRef.isEmpty == false)
        #expect(tracks[0].items[0].styleRef == tracks[0].styleRef)
        #expect(tracks[1].styleRef != tracks[0].styleRef)
        let lib = CaptionLookRegistry.shared.library(for: session.project)
        let style = lib.style(for: tracks[0].styleRef)
        #expect(style.size == 77 && style.shadow != nil)
    }
}
