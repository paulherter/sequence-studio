import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

// Lane drag-out: layers move between Graphics (or onto a new Graphic) through absolute time, in one mutation.

@Suite struct GraphicsMoveOutTests {
    private static func item(_ name: String, _ range: TimeRange? = nil) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        l.range = range
        return l
    }

    /// Source: 10 s at 2 s on V1 (A, B); other: 6 s at 5 s on V2 (empty); V3 free.
    private static func setup() throws -> (p: Project, src: Clip.ID, other: Clip.ID, v3: Track.ID, a: UUID, b: UUID) {
        let v1 = Track(kind: .video), v2 = Track(kind: .video), v3 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2, v3])
        var p = Project(name: "P", timelines: [t])
        let a = item("A", TimeRange(start: s(1), end: s(4)))   // absolute 3..6
        let b = item("B")
        let src = try p.addGraphicsClip(in: t.id, at: s(2), track: v1.id, duration: s(10), layers: [a, b])
        let other = try p.addGraphicsClip(in: t.id, at: s(5), track: v2.id, duration: s(6), layers: [item("X")])
        return (p, src, other, v3.id, a.id, b.id)
    }

    private static func clip(_ p: Project, _ id: Clip.ID) -> Clip? { p.timelines[0].tracks.flatMap(\.clips).first { $0.id == id } }

    @Test func extractAndInsertShiftRangesThroughAbsoluteTime() {
        var doc = GraphicsDocument(layers: [Self.item("A", TimeRange(start: s(1), end: s(4))), Self.item("B")])
        let ids = doc.layers.map(\.id)
        let out = doc.extractLayers(ids, clipStart: s(2), clipDuration: s(10))
        #expect(doc.layers.isEmpty)
        #expect(out[0].span == TimeRange(start: s(3), end: s(6)))
        #expect(out[1].span == TimeRange(start: s(2), end: s(12)))
        var dest = GraphicsDocument()
        dest.insertLayers(out, clipStart: s(5), clipDuration: s(6))
        #expect(dest.layers[0].range == TimeRange(start: .zero, end: s(1)))
        #expect(dest.layers[1].range == TimeRange(start: .zero, end: s(6)) || dest.layers[1].range == nil)
    }

    @Test func moveToAnotherGraphicKeepsTimesAndRemovesFromSource() throws {
        var (p, src, other, _, a, b) = try Self.setup()
        let r = try p.moveGraphicsLayers([a], from: src, to: .graphic(other, index: nil))
        #expect(r.clip == other && r.layers == [a])
        #expect(Self.clip(p, src)?.graphics?.layers.map(\.id) == [b])
        let doc = Self.clip(p, other)?.graphics
        #expect(doc?.layers.map(\.name) == ["X", "A"])
        #expect(doc?.layer(a)?.range == TimeRange(start: .zero, end: s(1)))   // 3..6 clamped to 5..11, shown 5..6
    }

    @Test func wholeClipLayerBecomesRangeSpanOfSource() throws {
        var (p, src, other, _, _, b) = try Self.setup()
        try p.moveGraphicsLayers([b], from: src, to: .graphic(other, index: 0))
        let doc = Self.clip(p, other)?.graphics
        #expect(doc?.layers.first?.id == b)
        #expect(doc?.layer(b)?.range == nil)   // source span 2..12 covers 5..11
    }

    @Test func moveToNewGraphicOnAnotherTrack() throws {
        var (p, src, _, v3, a, _) = try Self.setup()
        let r = try p.moveGraphicsLayers([a], from: src, to: .newGraphic(track: v3))
        let c = Self.clip(p, r.clip)
        #expect(c?.timeline == TimeRange(start: s(3), end: s(6)))
        #expect(c?.graphics?.layers.map(\.id) == [a])
        #expect(c?.graphics?.layer(a)?.range == nil)
        #expect(Self.clip(p, src)?.graphics?.layers.count == 1)
    }

    @Test func movingTheLastLayerRemovesTheEmptyGraphic() throws {
        var (p, src, _, v3, a, b) = try Self.setup()
        try p.moveGraphicsLayers([a, b], from: src, to: .newGraphic(track: v3))
        #expect(Self.clip(p, src) == nil)
    }

    @Test func copyKeepsTheOriginalAndGivesFreshIDs() throws {
        var (p, src, other, _, a, _) = try Self.setup()
        let r = try p.moveGraphicsLayers([a], from: src, to: .graphic(other, index: nil), copy: true)
        #expect(r.layers != [a])
        #expect(Self.clip(p, src)?.graphics?.layers.count == 2)
        #expect(Self.clip(p, other)?.graphics?.layers.count == 2)
    }

    @Test func refusedDropsChangeNothing() throws {
        var (p, src, other, v3, a, _) = try Self.setup()
        let before = p
        #expect(throws: EditError.self) { try p.moveGraphicsLayers([a], from: src, to: .graphic(src, index: nil)) }
        #expect(throws: EditError.self) { try p.moveGraphicsLayers([a], from: src, to: .newGraphic(track: p.timelines[0].tracks[0].id)) }
        #expect(throws: EditError.self) { try p.moveGraphicsLayers([UUID()], from: src, to: .newGraphic(track: v3)) }
        #expect(p == before)
        // No overlap in time: a Graphic at 20 s.
        let far = try p.addGraphicsClip(in: p.timelines[0].id, at: s(20), track: p.timelines[0].tracks[1].id, duration: s(2),
                                        layers: [Self.item("F")])
        let b2 = p
        #expect(throws: EditError.self) { try p.moveGraphicsLayers([a], from: src, to: .graphic(far, index: nil)) }
        #expect(p == b2)
        _ = other
    }

    @Test func keysTravelOnTheirTimelineTimes() throws {
        var (p, src, other, _, a, _) = try Self.setup()
        try p.editGraphics(clipID: src) { d in
            d.update(a) { $0.animation.opacity.track.insert(Keyframe(time: s(2), value: 0.5)) }   // absolute 4
        }
        try p.moveGraphicsLayers([a], from: src, to: .graphic(other, index: nil))
        let l = Self.clip(p, other)?.graphics?.layer(a)
        #expect(l?.animation.opacity.track.keys.first?.time == s(-1))   // absolute 4 is -1 s in the clip starting at 5
    }
}
