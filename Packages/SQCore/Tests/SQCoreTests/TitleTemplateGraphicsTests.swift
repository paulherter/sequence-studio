import Foundation
import Testing
@testable import SQCore

// G10: template fields on the text layers of a graphics clip (`TemplateSlot.graphicsLayer`).

private let fd = Time(1, 30)
private func s(_ x: Int64) -> Time { Time(x, 1) }

private func textRef(_ text: String) -> GeneratorRef {
    let obj: [String: Any] = ["template": ["text": text, "name": "T",
                                           "style": ["fontName": "Inter", "size": 80.0,
                                                     "color": ["red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0]]]]
    return GeneratorRef(kind: GeneratorRef.text, payload: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
}

private func textOf(_ l: GraphicsLayer?) -> String? {
    guard case let .text(ref)? = l?.content,
          let o = (try? JSONSerialization.jsonObject(with: ref.payload)) as? [String: Any] else { return nil }
    return (o["template"] as? [String: Any])?["text"] as? String
}

private func fixture() throws -> (Project, Timeline.ID, Clip.ID, [UUID], Track.ID) {
    let l1 = GraphicsLayer(name: "Title", content: .text(ref: textRef("Title")))
    let box = GraphicsLayer(name: "Box", content: .shape(kind: .rectangle))
    let l2 = GraphicsLayer(name: "Sub", content: .text(ref: textRef("Sub")))
    let src = Track(kind: .video)
    let dst = Track(kind: .video)
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [src, dst])
    var p = Project(name: "P", timelines: [tl])
    let id = try p.addGraphicsClip(in: tl.id, at: s(10), track: src.id, duration: s(5), layers: [l1, box, l2])
    return (p, tl.id, id, [l1.id, box.id, l2.id], dst.id)
}

private func clipNamed(_ id: Clip.ID, in p: Project, _ tl: Timeline.ID) -> Clip? {
    p.timeline(tl)?.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first
}

@Suite struct TitleTemplateGraphicsTests {
    @Test func captureMakesSlotsForTextLayersOfGraphicsClips() throws {
        let (p, tl, id, layers, _) = try fixture()
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "G")
        #expect(t.slots.map(\.name) == ["Text 1", "Text 2"])
        #expect(t.slots.map(\.graphicsLayer) == [layers[0], layers[2]])
        #expect(t.slots.allSatisfy { $0.layer == id && $0.path == "template.text" })
        #expect(t.slots.map(\.value) == [.text("Title"), .text("Sub")])
    }

    @Test func applyAndSetRewriteTheLayer() throws {
        let (p0, tl, id, layers, dst) = try fixture()
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p0, name: "G")
        var p = p0
        let placed = try p.applyTitleTemplate(t, in: tl, track: dst, at: s(20), values: [t.slots[0].id: .text("Hello")])
        func inner(_ p: Project) throws -> GraphicsDocument {
            let c = try #require(clipNamed(placed, in: p, tl))
            let seq = try #require(c.sequence.flatMap(p.timeline))
            return try #require(seq.tracks.lazy.flatMap(\.clips).first { $0.isGraphics }?.graphics)
        }
        #expect(textOf(try inner(p).layer(layers[0])) == "Hello")
        #expect(textOf(try inner(p).layer(layers[2])) == "Sub")
        let slot = try #require(clipNamed(placed, in: p, tl)?.templateSlots?[1])
        var h = History(p)
        try h.commit("Edit Text") { try $0.setTemplateSlot(slot.id, to: .text("World"), clip: placed) }
        #expect(textOf(try inner(h.current).layer(layers[2])) == "World")
        #expect(textOf(try inner(h.current).layer(layers[0])) == "Hello")
        _ = h.undo()
        #expect(h.current == p)
        // The source graphics clip is untouched.
        #expect(textOf(clipNamed(id, in: p, tl)?.graphics?.layer(layers[0])) == "Title")
    }

    @Test func missingLayerThrows() throws {
        let (p0, tl, id, _, dst) = try fixture()
        var t = try TitleTemplate.capture(clips: [id], in: tl, of: p0, name: "G")
        t.slots[0].graphicsLayer = UUID()
        var p = p0
        #expect(throws: TitleTemplateError.slotPathNotFound("template.text")) {
            try p.applyTitleTemplate(t, in: tl, track: dst, at: s(20), values: [t.slots[0].id: .text("x")])
        }
    }

    @Test func slotCodableRoundTripKeepsGraphicsLayer() throws {
        let (p, tl, id, _, _) = try fixture()
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "G")
        let back = try JSONDecoder().decode(TitleTemplate.self, from: try JSONEncoder().encode(t))
        #expect(back.slots == t.slots)
    }
}
