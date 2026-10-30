import Foundation
import Testing
import SQCore
@testable import SQText

@Suite struct TemplateTextStyleTests {
    private let fd = Time(1, 30)
    private func fade(_ anchor: AnimationAnchor = .start) -> KeyframeTemplate {
        KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                         duration: Time(1, 5), anchor: anchor)
    }
    private func textClip(_ text: String, size: Double, start: Time, anims: AnimationSet?) throws -> Clip {
        let t = TextTemplate(name: "T", text: text, style: TextStyle(size: size))
        let ref = try TextGenerator.makeRef(template: t, animations: anims)
        return Clip(name: text, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: start, generator: ref)
    }
    private func template(_ tracks: [[Clip]]) throws -> TitleTemplate {
        var ts: [Track] = []
        for clips in tracks { var t = Track(kind: .video); for c in clips { try t.overwrite(c) }; ts.append(t) }
        return TitleTemplate(name: "X", content: Timeline(name: "C", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: ts))
    }

    @Test func readsFirstTextLayerStyleAndBothAnimations() throws {
        let anims = AnimationSet(in: fade(), out: fade(.end))
        let tpl = try template([[try textClip("A", size: 90, start: .zero, anims: anims)], [try textClip("B", size: 20, start: .zero, anims: nil)]])
        let s = try #require(TemplateTextStyle(template: tpl))
        #expect(s.style.size == 90)
        #expect(s.animations?.animationIn != nil && s.animations?.animationOut != nil)
    }

    @Test func templateWithoutTextHasNoStyle() throws {
        let tpl = try template([[Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                                      start: .zero, generator: GeneratorRef(kind: GeneratorRef.shape, payload: Data("{}".utf8)))]])
        #expect(TemplateTextStyle(template: tpl) == nil)
    }

    @Test func givingKeepsTextAndBoxAndClearsLook() {
        let box = TextBox(width: 800, height: 200)
        var t = TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 30), box: box)
        t.lookID = "clean"
        let s = TemplateTextStyle(style: TextStyle(size: 77), animations: AnimationSet(in: fade(), out: nil))
        let ownOut = fade(.end)
        let r = s.giving(to: t, animations: AnimationSet(in: nil, out: ownOut))
        #expect(r.template.text == "Hello" && r.template.box == box && r.template.style.size == 77 && r.template.lookID == nil)
        #expect(r.animations?.animationIn != nil)
        #expect(r.animations?.animationOut == AnimationSet(in: nil, out: ownOut).animationOut)   // a side the template lacks stays
    }
}
