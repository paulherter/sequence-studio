import Foundation
import Testing
@testable import SQCore

// Item lanes review: a title or project template whose Graphic has an item with a range is written in a format a build
// without item ranges refuses (title template) or drops the content of (project template), never draws for the whole
// clip. Without a range the format numbers and bytes stay as before. Also: text In/Out on the item's range, a cut never
// empties a piece, a slot that addresses an item dropped by a cut fails cleanly.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }

private func textItem(_ name: String, _ range: TimeRange?) -> GraphicsLayer {
    var l = GraphicsLayer(name: name, content: .text(ref: GeneratorRef(kind: GeneratorRef.text,
                                                                      payload: Data(#"{"template":{"text":"Hi"}}"#.utf8))))
    l.range = range
    return l
}

/// A 10 s Graphic at 2 s on V1 holding `items`.
private func project(_ items: [GraphicsLayer]) throws -> (Project, Timeline.ID, Clip.ID) {
    let v1 = Track(kind: .video)
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
    var p = Project(name: "P", timelines: [tl])
    let id = try p.addGraphicsClip(in: tl.id, at: s(2), track: v1.id, duration: s(10), layers: items)
    return (p, tl.id, id)
}

private func json(_ v: some Encodable) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
}

@Suite struct TemplateItemRangeFormatTests {
    @Test func titleTemplateWithARangeIsFormat5AndRoundTrips() throws {
        let (p, tl, id) = try project([textItem("a", r(1, 4)), textItem("b", nil)])
        let t = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "Ranged")
        #expect(t.content.containsItemRanges)
        #expect(t.writtenFormatVersion == 5 && TitleTemplate.formatVersion == 5)
        #expect(try json(t)["formatVersion"] as? Int == 5)
        let back = try JSONDecoder().decode(TitleTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        let ranges = back.content.tracks.flatMap(\.clips).flatMap { $0.graphics?.layers ?? [] }.map(\.range)
        #expect(ranges == [r(1, 4), nil])
        // A build that reads up to format 4 (it compares with its own constant) refuses format 5.
        let err = #expect(throws: TitleTemplateError.self) {
            var o = try json(t); o["formatVersion"] = TitleTemplate.formatVersion + 1
            _ = try JSONDecoder().decode(TitleTemplate.self, from: JSONSerialization.data(withJSONObject: o))
        }
        #expect(err == .newerFormat(found: 6, supported: 5))
    }

    @Test func titleTemplateWithoutARangeKeepsItsOldFormat() throws {
        let (p, tl, id) = try project([textItem("a", nil), textItem("b", nil)])
        let plain = try TitleTemplate.capture(clips: [id], in: tl, of: p, name: "Plain")
        #expect(!plain.content.containsItemRanges)
        #expect(plain.writtenFormatVersion == 2)                    // text slots address graphics layers: format 2 as before
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("\"range\""))
        // The file an older build wrote (format 2, no range key) loads unchanged.
        let o = try json(plain)
        #expect(o["formatVersion"] as? Int == 2)
        #expect(try JSONDecoder().decode(TitleTemplate.self, from: JSONSerialization.data(withJSONObject: o)) == plain)
        var bare = plain; bare.slots = []
        #expect(bare.writtenFormatVersion == 1)

        var follower = textItem("f", nil)
        let target = textItem("t", nil)
        follower.follow = GraphicsFollow(target: .layer(id: target.id), padding: 8)
        let (p2, tl2, id2) = try project([follower, target])
        #expect(try TitleTemplate.capture(clips: [id2], in: tl2, of: p2, name: "Follow").writtenFormatVersion == 3)
    }

    @Test func projectTemplateWithARangeIsFormat4AndAnOlderBuildDropsItsContent() throws {
        let (p, tl, _) = try project([textItem("a", r(1, 4)), textItem("b", nil)])
        let t = ProjectTemplate(capturing: p.timeline(tl)!, name: "Ranged")
        #expect(t.writtenFormatVersion == 4 && ProjectTemplate.formatVersion == 4)
        let o = try json(t)
        #expect(o["formatVersion"] as? Int == 4)
        #expect(o["content"] == nil && o["contentV2"] != nil)
        let back = try JSONDecoder().decode(ProjectTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t && back.content?.containsItemRanges == true)
        // A newer format than this build reads: the content is dropped, the template still loads.
        var newer = o; newer["formatVersion"] = ProjectTemplate.formatVersion + 1
        let n = try JSONDecoder().decode(ProjectTemplate.self, from: JSONSerialization.data(withJSONObject: newer))
        #expect(n.content == nil && n.name == "Ranged")
    }

    @Test func projectTemplateWithoutARangeKeepsItsOldBytes() throws {
        let (p, tl, _) = try project([textItem("a", nil)])
        let t = ProjectTemplate(capturing: p.timeline(tl)!, name: "Plain")
        #expect(t.writtenFormatVersion == 1)
        let o = try json(t)
        #expect(o["formatVersion"] == nil && o["content"] != nil && o["contentV2"] == nil)
        #expect(try JSONDecoder().decode(ProjectTemplate.self, from: JSONEncoder().encode(t)) == t)
    }
}

@Suite struct ItemRangeReviewTests {
    /// A text item's In and Out run on its range: the generator gets range-local time and the range's length; keyframes
    /// and the shape style stay on clip time. An unranged item is as before.
    @Test func aRangedTextItemAnimatesOnItsRange() throws {
        let a = textItem("a", r(2, 6)), b = textItem("b", nil)
        let (p, tl, _) = try project([a, b])
        let layers = p.timeline(tl)!.videoLayers(at: s(5))          // clip-local 3
        let ra = try #require(layers.first { $0.clip == a.id }), rb = try #require(layers.first { $0.clip == b.id })
        #expect(ra.localTime == s(1) && ra.clipDuration == s(4))
        #expect(ra.sourceTime == s(3))
        #expect(rb.localTime == s(3) && rb.clipDuration == s(10) && rb.sourceTime == s(3))
        // The last frame of the range is the last frame of the Out animation.
        let last = try #require(p.timeline(tl)!.videoLayers(at: Time(239, 30)).first { $0.clip == a.id })
        #expect(last.localTime == Time(119, 30) && last.clipDuration == s(4))
    }

    /// The measure of a text item gets the time render draws it with: range-local time and the range's length for a ranged
    /// item (so its In/Out slide moves the box with the picture), clip time and no own length otherwise. A box following
    /// the text sits on that box, mid In and at the range's Out.
    @Test func theTextMeasureRunsOnTheSameTimeAsRender() throws {
        // A fake text whose box slides with its time base: x from the local time, width from the length it is given.
        let measure: GraphicsTextMeasure = { _, t in
            let x = Double(t.local.value) / Double(t.local.timescale) * 100
            let w = t.duration.map { Double($0.value) / Double($0.timescale) * 50 } ?? 10
            return GraphicsRect(minX: x, minY: -20, maxX: x + w, maxY: 20)
        }
        let ranged = textItem("a", r(2, 4)), plain = textItem("b", nil)
        for t in [Time(21, 10), Time(39, 10)] {
            let time = ranged.textTime(atLocal: t)
            #expect(time == GraphicsTextTime(local: t - s(2), duration: s(2)))
            #expect(ranged.contentRect(atLocal: t, text: measure) == measure(GeneratorRef(kind: "x", payload: Data()), time))
            #expect(plain.textTime(atLocal: t) == GraphicsTextTime(local: t, duration: nil))
            #expect(plain.contentRect(atLocal: t, text: measure)?.width == 10)

            // Render asks the generator for exactly that time.
            let (p, tl, _) = try project([ranged, plain])
            let req = try #require(p.timeline(tl)!.videoLayers(at: s(2) + t).first { $0.clip == ranged.id })
            #expect(req.localTime == time.local && req.clipDuration == time.duration)

            // Follow: the box is placed on the text's box at that time.
            var box = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
            box.follow = GraphicsFollow(target: .layer(id: ranged.id), padding: 0)
            let doc = GraphicsDocument(layers: [box, ranged]).resolvingFollow(atLocal: t, canvas: Vec2(1920, 1080), text: measure)
            let tb = try #require(doc.bounds(of: ranged.id, atLocal: t, text: measure))
            let bb = try #require(doc.bounds(of: box.id, atLocal: t, text: measure))
            #expect(abs(bb.minX - tb.minX) < 1e-6 && abs(bb.maxX - tb.maxX) < 1e-6)
            #expect(abs(tb.width - 100) < 1e-6)                          // the range's 2 s, not the clip's length
        }
    }

    /// Every item shows in the first 2 s; the right half of a cut at 5 s keeps them as empty stubs instead of becoming a
    /// Graphic without items. The left half is unchanged.
    @Test func aCutNeverLeavesAPieceWithoutItems() throws {
        let (p, tl, _) = try project([textItem("a", r(0, 2)), textItem("b", r(0, 2))])
        var track = p.timeline(tl)!.tracks[0]
        try track.split(at: s(7))                                    // clip-local 5
        #expect(track.clips.count == 2)
        #expect(track.clips[0].graphics?.layers.map(\.range) == [r(0, 2), r(0, 2)])
        #expect(track.clips[1].graphics?.layers.map(\.name) == ["a", "b"])
        #expect(track.clips[1].graphics?.layers.map(\.range) == [r(0, 0), r(0, 0)])
        // Nothing of the stubs is drawn.
        var t = p.timeline(tl)!
        t.tracks[0] = track
        #expect(t.videoLayers(at: s(8)).isEmpty)
        // One item survives: the others are dropped as before.
        let (p2, tl2, id2) = try project([textItem("a", r(0, 2)), textItem("b", r(0, 2)), textItem("c", r(1, 8))])
        let c = try #require(p2.timeline(tl2)!.tracks[0].clips.first { $0.id == id2 })
        let right = try #require(c.cropped(to: TimeRange(start: s(7), end: s(12))))
        #expect(right.graphics?.layers.map(\.name) == ["c"])
    }

    /// A template slot that addresses an item a cut dropped: setting it throws and changes nothing.
    @Test func aSlotOfAnItemDroppedByACutFailsCleanly() throws {
        let a = textItem("a", r(6, 9)), b = textItem("b", nil)
        let (src, stl, sid) = try project([a, b])
        var t = try TitleTemplate.capture(clips: [sid], in: stl, of: src, name: "T")
        let inside = try #require(t.content.tracks.flatMap(\.clips).first { $0.isGraphics })
        let item = try #require(inside.graphics?.layers.first { $0.name == "a" })
        t.slots = [TemplateSlot(name: "Text", kind: .text, layer: inside.id, graphicsLayer: item.id, path: "template.text",
                                value: .text("Hi"))]

        let v1 = Track(kind: .video)
        let host = Timeline(name: "H", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
        var p = Project(name: "P", timelines: [host])
        let clip = try p.applyTitleTemplate(t, in: host.id, track: v1.id, at: .zero)
        let applied = try #require(p.timeline(host.id)!.tracks[0].clips.first { $0.id == clip })
        let slot = try #require(applied.templateSlots?.first)
        try p.setTemplateSlot(slot.id, to: .text("Yo"), clip: clip)     // works while the item is there

        // Cut the Graphic inside the template at clip-local 4 s and keep the left piece: item "a" (6..<9 s) is gone.
        let ii = try #require(p.timelines.firstIndex { $0.id == applied.sequence })
        let ti = try #require(p.timelines[ii].tracks.firstIndex { tr in tr.clips.contains { $0.id == slot.layer } })
        let g = try #require(p.timelines[ii].tracks[ti].clips.first { $0.id == slot.layer })
        var left = try #require(g.cropped(to: TimeRange(start: g.start, duration: s(4))))
        left.id = g.id
        #expect(left.graphics?.layers.map(\.name) == ["b"])
        p.timelines[ii].tracks[ti].replace(left)
        let before = p
        #expect(throws: TitleTemplateError.self) { try p.setTemplateSlot(slot.id, to: .text("No"), clip: clip) }
        #expect(p == before)
    }
}
