import Foundation
import Testing
@testable import SQCore

// TitleTemplate: several layers (text/shape/graphic) saved as one nested-sequence snapshot with editable slots and
// animation zones; applied as one nested clip whose intro and outro keep their length when trimmed.

private let fd = Time(1, 30)
private func s(_ x: Int64) -> Time { Time(x, 1) }
private func ms(_ x: Int64) -> Time { Time(x, 1000) }

private func textPayload(_ text: String) -> Data {
    let obj: [String: Any] = ["template": ["text": text, "name": "T",
                                           "style": ["fontName": "Inter", "size": 80.0,
                                                     "color": ["red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0]]]]
    return try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}

private func payloadObject(_ c: Clip) throws -> [String: Any] {
    let g = try #require(c.generator)
    return try #require(try JSONSerialization.jsonObject(with: g.payload) as? [String: Any])
}

private func layer(_ kind: String, _ payload: Data, start: Time, duration: Time, keys: [Time] = []) -> Clip {
    var c = Clip(name: kind, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: duration), start: start,
                 generator: GeneratorRef(kind: kind, payload: payload))
    c.animation.opacity.track = KeyframeTrack(keys: keys.map { Keyframe(time: $0, value: 1.0) })
    return c
}

/// Host sequence: three layers at 10 s (two texts, one shape) on V1-V3, plus an empty V4 to apply onto.
private func host() throws -> (Project, Timeline.ID, [Clip.ID], Track.ID) {
    let a = layer(GeneratorRef.text, textPayload("Title"), start: s(10), duration: s(5),
                  keys: [.zero, ms(500), ms(4500), s(5)])
    let b = layer(GeneratorRef.text, textPayload("Subtitle"), start: s(10), duration: s(5), keys: [.zero, s(1)])
    let c = layer(GeneratorRef.shape, Data("{}".utf8), start: s(10), duration: s(5))
    var tracks: [Track] = []
    for x in [a, b, c] { var t = Track(kind: .video); try t.overwrite(x); tracks.append(t) }
    let empty = Track(kind: .video)
    tracks.append(empty)
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: tracks)
    return (Project(name: "P", timelines: [tl]), tl.id, [a.id, b.id, c.id], empty.id)
}

private func template() throws -> TitleTemplate {
    let (p, tl, ids, _) = try host()
    return try TitleTemplate.capture(clips: ids, in: tl, of: p, name: "Intro")
}

private func placed(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) throws -> Clip {
    try #require(p.timeline(tl)?.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first)
}

@Suite struct TitleTemplateTests {
    // MARK: Model

    @Test func captureMakesOneSnapshotFromZero() throws {
        let t = try template()
        #expect(t.duration == s(5))
        #expect(t.layers.map(\.kind) == [.text, .text, .shape])
        #expect(t.content.tracks.allSatisfy { $0.clips.allSatisfy { $0.start == .zero } })
        #expect(t.slots.map(\.name) == ["Text 1", "Text 2"])
        #expect(t.slots.map(\.kind) == [.text, .text])
        #expect(t.slots.map(\.value) == [.text("Title"), .text("Subtitle")])
        // Zones from the first/last keys of all layers.
        #expect(t.zones.introEnd == s(1))
        #expect(t.zones.outroStart(in: t.duration) == ms(4500))
        #expect(t.zones.designDuration == s(5))
    }

    @Test func captureRefusesEmptyAndAudio() throws {
        let (p, tl, _, _) = try host()
        #expect(throws: EditError.clipNotFound) { try TitleTemplate.capture(clips: [UUID()], in: tl, of: p, name: "X") }
        #expect(throws: EditError.emptyClip) { try TitleTemplate.capture(clips: [], in: tl, of: p, name: "X") }
    }

    @Test func codableRoundTrip() throws {
        var t = try template()
        t.slots.append(TemplateSlot(name: "Color", kind: .color, layer: t.layers[0].clip, path: "template.style.color",
                                    value: .color(red: 1, green: 0, blue: 0, alpha: 1)))
        t.slots.append(TemplateSlot(name: "Font", kind: .font, layer: t.layers[0].clip, path: "template.style.fontName",
                                    value: .font("Futura")))
        t.slots.append(TemplateSlot(name: "Size", kind: .number, layer: t.layers[0].clip, path: "template.style.size",
                                    value: .number(120)))
        let back = try JSONDecoder().decode(TitleTemplate.self, from: try JSONEncoder().encode(t))
        #expect(back == t)
        #expect(TitleTemplate.formatVersion >= 1)
    }

    // MARK: Apply

    @Test func applyPlacesOneNestedClipWithSlotValues() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let before = p.timelines.count
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20),
                                          values: [t.slots[0].id: .text("Hello"), t.slots[1].id: .text("World")])
        #expect(p.timelines.count == before + 1)
        let c = try placed(p, tl, id)
        #expect(c.start == s(20) && c.duration == s(5))
        let inner = try #require(c.sequence.flatMap(p.timeline))
        #expect(c.zones == t.zones)
        #expect(c.templateSlots?.map(\.value) == [.text("Hello"), .text("World")])
        let texts = try inner.tracks.compactMap { $0.clips.first }.filter { $0.generator?.kind == GeneratorRef.text }
            .map { try payloadObject($0)["template"] as? [String: Any] }.map { $0?["text"] as? String }
        #expect(texts == ["Hello", "World"])
        // Layer ids are fresh: applying twice never shares a clip id.
        let id2 = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(30))
        let inner2 = try #require(try placed(p, tl, id2).sequence.flatMap(p.timeline))
        let ids1 = Set(inner.tracks.flatMap { $0.clips.map(\.id) }), ids2 = Set(inner2.tracks.flatMap { $0.clips.map(\.id) })
        #expect(ids1.isDisjoint(with: ids2))
        #expect(ids1.isDisjoint(with: Set(t.content.tracks.flatMap { $0.clips.map(\.id) })))
        #expect(p.isNestingAcyclic)
    }

    @Test func applyWithLongerDuration() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20), duration: s(12))
        #expect(try placed(p, tl, id).duration == s(12))
    }

    @Test func applyIsOneUndoStep() throws {
        let t = try template()
        let (p0, tl, _, v4) = try host()
        var h = History(p0)
        try h.commit("Apply Template") { _ = try $0.applyTitleTemplate(t, in: tl, track: v4, at: s(20)) }
        #expect(h.current != p0)
        _ = h.undo()
        #expect(h.current == p0)
    }

    @Test func setSlotReplacesTheTextAndUndoes() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20))
        var h = History(p)
        try h.commit("Edit Text") { try $0.setTemplateSlot(t.slots[1].id, to: .text("New"), clip: id) }
        let c = try placed(h.current, tl, id)
        #expect(c.templateSlots?[1].value == .text("New"))
        let inner = try #require(c.sequence.flatMap(h.current.timeline))
        let layerID = try #require(c.templateSlots?[1].layer)
        let l = try #require(inner.tracks.lazy.compactMap { $0.clips.first { $0.id == layerID } }.first)
        #expect((try payloadObject(l)["template"] as? [String: Any])?["text"] as? String == "New")
        _ = h.undo()
        #expect(h.current == p)
    }

    @Test func editingACopyForksItsInnerSequence() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20))
        // A copy of the applied clip (same inner sequence) further along the same track.
        var copy = try placed(p, tl, id)
        copy.id = UUID(); copy.start = s(40)
        try p.edit(tl) { try $0.tracks[3].overwrite(copy) }
        let seq0 = try #require(copy.sequence)
        var h = History(p)
        try h.commit("Edit Text") { try $0.setTemplateSlot(t.slots[1].id, to: .text("New"), clip: copy.id) }
        let a = try placed(h.current, tl, id), b = try placed(h.current, tl, copy.id)
        #expect(a.sequence == seq0)
        #expect(b.sequence != seq0)
        #expect(a.templateSlots?[1].value != .text("New"))
        #expect(b.templateSlots?[1].value == .text("New"))
        func text(_ c: Clip) throws -> String? {
            let inner = try #require(c.sequence.flatMap(h.current.timeline))
            let layerID = try #require(c.templateSlots?[1].layer)
            let l = try #require(inner.tracks.lazy.compactMap { $0.clips.first { $0.id == layerID } }.first)
            return (try payloadObject(l)["template"] as? [String: Any])?["text"] as? String
        }
        #expect(try text(a) == "Subtitle")
        #expect(try text(b) == "New")
        // A second edit of the (now unshared) copy keeps its sequence.
        try h.commit("Edit Text") { try $0.setTemplateSlot(t.slots[1].id, to: .text("Newer"), clip: copy.id) }
        #expect(try placed(h.current, tl, copy.id).sequence == b.sequence)
        #expect(h.current.timelines.count == 3)
    }

    @Test func setColourFontAndNumberSlots() throws {
        var t = try template()
        let l = t.layers[0].clip
        let colour = TemplateSlot(name: "Color", kind: .color, layer: l, path: "template.style.color",
                                  value: .color(red: 1, green: 1, blue: 1, alpha: 1))
        let font = TemplateSlot(name: "Font", kind: .font, layer: l, path: "template.style.fontName", value: .font("Inter"))
        let size = TemplateSlot(name: "Size", kind: .number, layer: l, path: "template.style.size", value: .number(80))
        t.slots += [colour, font, size]
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20), values: [
            colour.id: .color(red: 1, green: 0, blue: 0, alpha: 0.5), font.id: .font("Futura"), size.id: .number(120)])
        let c = try placed(p, tl, id)
        let inner = try #require(c.sequence.flatMap(p.timeline))
        let first = try #require(inner.tracks[0].clips.first)
        let style = try #require((try payloadObject(first)["template"] as? [String: Any])?["style"] as? [String: Any])
        #expect(style["fontName"] as? String == "Futura")
        #expect(style["size"] as? Double == 120)
        let col = try #require(style["color"] as? [String: Any])
        #expect(col["red"] as? Double == 1 && col["green"] as? Double == 0 && col["alpha"] as? Double == 0.5)
    }

    @Test func slotWithAMissingPathThrows() throws {
        var t = try template()
        t.slots = [TemplateSlot(name: "X", kind: .text, layer: t.layers[0].clip, path: "nope.text", value: .text("a"))]
        var (p, tl, _, v4) = try host()
        #expect(throws: TitleTemplateError.slotPathNotFound("nope.text")) {
            try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20), values: [t.slots[0].id: .text("b")])
        }
    }

    // MARK: Zone-aware trim / stretch of the applied clip

    @Test func stretchedClipKeepsIntroAndOutro() throws {
        let t = try template()       // intro 0...1 s, outro 4.5...5 s
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20))
        try p.edit(tl) { try $0.trim(id, edge: .tail, by: s(5)) }                 // 10 s
        let c = try placed(p, tl, id)
        #expect(c.duration == s(10))
        #expect(c.innerTime(atLocal: ms(500), innerFrameDuration: fd) == ms(500))
        #expect(c.innerTime(atLocal: s(3), innerFrameDuration: fd) == s(3))
        #expect(c.innerTime(atLocal: s(7), innerFrameDuration: fd) == ms(4500))   // middle holds
        #expect(c.innerTime(atLocal: ms(9750), innerFrameDuration: fd) == ms(4750))
        // The renderer sees the same mapping: the inner text layer at outer 29.75 s plays its 4.75 s.
        let layers = p.videoLayers(at: ms(29750), in: tl).filter { !$0.groups.isEmpty }
        #expect(!layers.isEmpty)
        #expect(layers.allSatisfy { $0.localTime == ms(4750) })
    }

    @Test func trimmedClipStillPlaysTheWholeOutro() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20))
        try p.edit(tl) { try $0.trim(id, edge: .tail, by: s(-3)) }                // 2 s
        let c = try placed(p, tl, id)
        #expect(c.innerTime(atLocal: ms(1500), innerFrameDuration: fd) == ms(4500))
        #expect(c.innerTime(atLocal: ms(1750), innerFrameDuration: fd) == ms(4750))
    }

    @Test func headExtendIsUnboundedAndKeepsTheIntroAtTheStart() throws {
        let t = try template()
        var (p, tl, _, v4) = try host()
        let id = try p.applyTitleTemplate(t, in: tl, track: v4, at: s(20))
        let moved = try p.timelines[0].trim(id, edge: .head, by: s(-3))
        #expect(moved == s(-3))
        let c = try placed(p, tl, id)
        #expect(c.start == s(17) && c.duration == s(8))
        #expect(c.source.start == .zero)
        #expect(c.innerTime(atLocal: ms(250), innerFrameDuration: fd) == ms(250))
        #expect(c.innerTime(atLocal: ms(7750), innerFrameDuration: fd) == ms(4750))
    }
}
