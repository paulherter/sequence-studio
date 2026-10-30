import Foundation
import Testing
@testable import SQCore

// G10 review: template format 2 only with graphics-layer slots; reorder/delete of inner layers.

private func textRef(_ text: String) -> GeneratorRef {
    let obj: [String: Any] = ["template": ["text": text]]
    return GeneratorRef(kind: GeneratorRef.text, payload: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
}

private func textOf(_ l: GraphicsLayer?) -> String? {
    guard case let .text(ref)? = l?.content,
          let o = (try? JSONSerialization.jsonObject(with: ref.payload)) as? [String: Any] else { return nil }
    return (o["template"] as? [String: Any])?["text"] as? String
}

private func fixture() throws -> (Project, Timeline.ID, Clip.ID, [UUID], Track.ID) {
    let l1 = GraphicsLayer(name: "Title", content: .text(ref: textRef("Title")))
    let l2 = GraphicsLayer(name: "Sub", content: .text(ref: textRef("Sub")))
    let src = Track(kind: .video), dst = Track(kind: .video)
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [src, dst])
    var p = Project(name: "P", timelines: [tl])
    let id = try p.addGraphicsClip(in: tl.id, at: Time(10, 1), track: src.id, duration: Time(5, 1), layers: [l1, l2])
    return (p, tl.id, id, [l1.id, l2.id], dst.id)
}

@Suite struct TitleTemplateFormatTests {
    private func encoded(_ t: TitleTemplate) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(t)) as? [String: Any])
    }

    @Test func plainTemplateStaysFormat1AndGraphicsTemplateIsFormat2() throws {
        let (p, tl, id, _, _) = try fixture()
        let g = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "G")
        #expect(try encoded(g)["formatVersion"] as? Int == 2)
        var plain = g
        plain.slots = [TemplateSlot(name: "T", kind: .text, layer: id, path: "template.text", value: .text("x"))]
        #expect(try encoded(plain)["formatVersion"] as? Int == 1)
        plain.slots = []
        #expect(try encoded(plain)["formatVersion"] as? Int == 1)
    }

    @Test func olderBuildRefusesANewerFormat() throws {
        let (p, tl, id, _, _) = try fixture()
        let g = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "G")
        var obj = try encoded(g)
        obj["formatVersion"] = TitleTemplate.formatVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: TitleTemplateError.newerFormat(found: TitleTemplate.formatVersion + 1, supported: TitleTemplate.formatVersion)) {
            _ = try JSONDecoder().decode(TitleTemplate.self, from: data)
        }
    }

    @Test func reorderKeepsSlotsAndDeleteBreaksThemCleanly() throws {
        let (p0, tl, id, layers, dst) = try fixture()
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p0, name: "G")
        var p = p0
        let placed = try p.applyTitleTemplate(t, in: tl, track: dst, at: Time(20, 1))
        let c = try #require(p.timeline(tl)?.tracks.lazy.compactMap { $0.clips.first { $0.id == placed } }.first)
        let seq = try #require(c.sequence)
        let slotID = try #require(c.templateSlots?[1].id)
        func editDoc(_ p: inout Project, _ f: (inout GraphicsDocument) -> Void) throws {
            let ti = try #require(p.timelines.firstIndex { $0.id == seq })
            for i in p.timelines[ti].tracks.indices {
                for var gc in p.timelines[ti].tracks[i].clips where gc.isGraphics {
                    var d = try #require(gc.graphics); f(&d); gc.graphics = d
                    p.timelines[ti].tracks[i].replace(gc)
                }
            }
        }
        var reordered = p
        try editDoc(&reordered) { $0.layers.reverse() }
        try reordered.setTemplateSlot(slotID, to: .text("New"), clip: placed)
        let doc = try #require(reordered.timeline(seq)?.tracks.lazy.flatMap(\.clips).first { $0.isGraphics }?.graphics)
        #expect(textOf(doc.layer(layers[1])) == "New")
        #expect(textOf(doc.layer(layers[0])) == "Title")

        var deleted = p
        try editDoc(&deleted) { $0.layers.removeAll { $0.id == layers[1] } }
        let before = deleted
        #expect(throws: TitleTemplateError.slotPathNotFound("template.text")) {
            try deleted.setTemplateSlot(slotID, to: .text("x"), clip: placed)
        }
        #expect(deleted == before)
    }
}
