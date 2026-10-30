import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }

// Item lanes: every item of a Graphic can show for only a part of the clip (clip-local range, nil = whole clip).

@Suite struct GraphicsItemRangeTests {
    private static func item(_ name: String, _ range: TimeRange?) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        l.range = range
        return l
    }

    /// A 10 s Graphic at 2 s holding `items`.
    private static func project(_ items: [GraphicsLayer]) throws -> (Project, Timeline.ID, Clip.ID) {
        let v = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10), layers: items)
        return (p, t.id, id)
    }

    private static func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    private static func ranges(_ c: Clip) -> [String: TimeRange?] {
        Dictionary(uniqueKeysWithValues: (c.graphics?.layers ?? []).map { ($0.name, $0.range) })
    }

    // MARK: File

    @Test func anOldLayerReadsAsWholeClip() throws {
        let l = GraphicsLayer(name: "L", content: .shape(kind: .rectangle))
        let data = try JSONEncoder().encode(l)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"range\""))
        #expect(try JSONDecoder().decode(GraphicsLayer.self, from: data).range == nil)
    }

    @Test func aRangeSurvivesTheFile() throws {
        let (p, tl, id) = try Self.project([Self.item("a", r(1, 4)), Self.item("b", nil)])
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        #expect(Self.ranges(Self.clip(back, tl, id)) == ["a": r(1, 4), "b": nil])
    }

    @Test func onlyAFileWithARangeIsWrittenAsV74() throws {
        let (plain, _, _) = try Self.project([Self.item("a", nil)])
        #expect(!plain.containsV74Content)
        #expect(ProjectFile.writtenVersion(for: plain) < 74)
        let (ranged, _, _) = try Self.project([Self.item("a", nil), Self.item("b", r(0, 1))])
        #expect(ranged.containsV74Content)
        #expect(ProjectFile.writtenVersion(for: ranged) == 74)
        #expect(ProjectFile.currentVersion >= 74)
    }

    // MARK: Render

    @Test func anItemOutsideItsRangeIsNotRendered() throws {
        let a = Self.item("a", r(1, 4)), b = Self.item("b", nil)
        let (p, tl, _) = try Self.project([a, b])
        let t = p.timeline(tl)!
        func shown(_ time: Time) -> [UUID] { t.videoLayers(at: time).map(\.clip) }
        #expect(shown(s(2)) == [b.id])                       // local 0: before the range
        #expect(shown(s(3)) == [a.id, b.id])                 // local 1: the first frame of the range
        #expect(shown(Time(179, 30)) == [a.id, b.id])        // local 4 minus one frame
        #expect(shown(s(6)) == [b.id])                       // local 4: the end is exclusive
    }

    @Test func aHiddenItemIsNotHitInTheMonitor() throws {
        var doc = GraphicsDocument(layers: [Self.item("a", r(1, 4))])
        #expect(doc.hitTest(Vec2(0, 0), atLocal: s(2)) == doc.layers[0].id)
        #expect(doc.hitTest(Vec2(0, 0), atLocal: s(5)) == nil)
        doc.layers[0].range = nil
        #expect(doc.hitTest(Vec2(0, 0), atLocal: s(5)) == doc.layers[0].id)
    }

    /// Evaluating a Graphic of 20 ranged items costs no more than one of 20 unranged items (the gate is one compare each;
    /// items outside their range are skipped before any work).
    @Test func twentyRangedItemsCostNoMoreThanTwentyUnranged() throws {
        func timeline(ranged: Bool) throws -> Timeline {
            let items = (0..<20).map { Self.item("i\($0)", ranged ? TimeRange(start: .zero, end: s(10) - Time(Int64($0), 30)) : nil) }
            let (p, tl, _) = try Self.project(items)
            return p.timeline(tl)!
        }
        let plain = try timeline(ranged: false), ranged = try timeline(ranged: true)
        func round(_ t: Timeline) -> Double {
            SQTiming.bestMs(runs: 1) { for i in 0..<100 { _ = t.videoLayers(at: s(2) + Time(Int64(i % 60), 30)) } } / 100
        }
        // All 20 show in both (the ranges end in the last second), so the two do the same render work.
        #expect(ranged.videoLayers(at: s(3)).count == 20)
        // Wall time, best of interleaved rounds: the process CPU clock counts the other tests of a parallel run, and
        // rounds taken in turn see the same machine load.
        _ = round(plain); _ = round(ranged)                                      // warm-up
        var a = Double.infinity, b = Double.infinity
        for _ in 0..<12 { a = min(a, round(plain)); b = min(b, round(ranged)) }
        if let path = ProcessInfo.processInfo.environment["SQ_PERF_LOG"] {      // report only, e.g. SQ_PERF_LOG=/tmp/perf.txt
            try? "item ranges: evaluation of 20 items, unranged \(a) ms, ranged \(b) ms\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        // The slack is relative only (an absolute term would swallow the bound on a fast machine); best of 12 interleaved
        // rounds of 100 evaluations keeps the two within a few percent under load.
        #expect(b < a * 1.25, "unranged \(a) ms, ranged \(b) ms")
        #expect(b < SQTiming.budget(4), "ranged \(b) ms")
    }

    // MARK: Trim

    @Test func aHeadTrimKeepsItemsOnTheirFramesAndClamps() throws {
        let (p, tl, id) = try Self.project([Self.item("in", r(4, 6)), Self.item("cut", r(1, 5)), Self.item("gone", r(0, 2)),
                                            Self.item("whole", nil)])
        var c = Self.clip(p, tl, id)
        c.extendHead(by: -s(3))                               // 3 s shorter at the head
        #expect(c.duration == s(7))
        #expect(Self.ranges(c) == ["in": r(1, 3), "cut": r(0, 2), "gone": r(0, 0), "whole": nil])
        c.extendHead(by: s(2))                                // longer again: ranges move with their frames
        #expect(Self.ranges(c) == ["in": r(3, 5), "cut": r(2, 4), "gone": r(2, 2), "whole": nil])
    }

    @Test func aTailTrimClamps() throws {
        let (p, tl, id) = try Self.project([Self.item("in", r(1, 3)), Self.item("cut", r(5, 9)), Self.item("gone", r(8, 10)),
                                            Self.item("whole", nil)])
        var c = Self.clip(p, tl, id)
        c.extendTail(by: -s(4))
        #expect(c.duration == s(6))
        #expect(Self.ranges(c) == ["in": r(1, 3), "cut": r(5, 6), "gone": r(6, 6), "whole": nil])
        c.extendTail(by: s(4))                                // a clamped range does not grow back by itself
        #expect(Self.ranges(c) == ["in": r(1, 3), "cut": r(5, 6), "gone": r(6, 6), "whole": nil])
    }

    @Test func anItemClampedToNothingIsNeverRendered() throws {
        let gone = Self.item("gone", r(0, 0))
        let (p, tl, _) = try Self.project([gone])
        #expect(p.timeline(tl)!.videoLayers(at: s(2)).isEmpty)
    }

    // MARK: Split

    @Test func aSplitDividesRangesAcrossTheHalves() throws {
        let (p, tl, _) = try Self.project([Self.item("left", r(1, 3)), Self.item("right", r(6, 9)), Self.item("both", r(2, 7)),
                                           Self.item("whole", nil)])
        var track = p.timeline(tl)!.tracks[0]
        try track.split(at: s(6))                             // local 4
        #expect(track.clips.count == 2)
        #expect(Self.ranges(track.clips[0]) == ["left": r(1, 3), "both": r(2, 4), "whole": nil])
        #expect(Self.ranges(track.clips[1]) == ["right": r(2, 5), "both": r(0, 3), "whole": nil])
    }

    @Test func aSplitDropsAnItemClampedToNothing() throws {
        let (p, tl, _) = try Self.project([Self.item("stub", r(4, 4)), Self.item("whole", nil)])
        var track = p.timeline(tl)!.tracks[0]
        try track.split(at: s(6))
        #expect(Self.ranges(track.clips[0]) == ["whole": nil])
        #expect(Self.ranges(track.clips[1]) == ["whole": nil])
    }

    @Test func aDroppedItemTakesItsFollowLinkAlong() throws {
        var a = Self.item("a", r(0, 2)), b = Self.item("b", nil)
        a.id = UUID()
        b.follow = GraphicsFollow(target: .layer(id: a.id))
        let (p, tl, id) = try Self.project([a, b])
        let right = try #require(Self.clip(p, tl, id).cropped(to: TimeRange(start: s(7), end: s(12))))
        #expect(right.graphics?.layers.map(\.name) == ["b"])
        #expect(right.graphics?.layers[0].follow == nil)
    }

    // MARK: Speed

    @Test func aRetimeScalesRanges() throws {
        let (p, tl, id) = try Self.project([Self.item("a", r(2, 6)), Self.item("whole", nil)])
        var c = Self.clip(p, tl, id)
        c.rescaleKeys(from: s(10), to: s(5), mirror: false)
        #expect(Self.ranges(c) == ["a": r(1, 3), "whole": nil])
        c.rescaleKeys(from: s(5), to: s(5), mirror: true)     // reversed: mirrored inside the clip
        #expect(Self.ranges(c) == ["a": r(2, 4), "whole": nil])
    }

    // MARK: Editing

    @Test func movingKeepsTheLengthAndStaysInsideTheClip() throws {
        var doc = GraphicsDocument(layers: [Self.item("a", r(2, 5)), Self.item("whole", nil)])
        let a = doc.layers[0].id, whole = doc.layers[1].id
        doc.moveItemRange(a, toStart: s(4), clipDuration: s(10))
        #expect(doc.layers[0].range == r(4, 7))
        doc.moveItemRange(a, toStart: s(9), clipDuration: s(10))
        #expect(doc.layers[0].range == r(7, 10))
        doc.moveItemRange(a, toStart: -s(3), clipDuration: s(10))
        #expect(doc.layers[0].range == r(0, 3))
        doc.moveItemRange(whole, toStart: s(3), clipDuration: s(10))   // fills the clip: nowhere to go
        #expect(doc.layers[1].range == nil)
    }

    @Test func trimmingKeepsOneFrameAndStaysInsideTheClip() throws {
        let fd = Time(1, 30)
        var doc = GraphicsDocument(layers: [Self.item("a", r(2, 5)), Self.item("whole", nil)])
        let a = doc.layers[0].id, whole = doc.layers[1].id
        doc.trimItemRange(a, edge: .head, to: s(3), clipDuration: s(10), minimum: fd)
        #expect(doc.layers[0].range == r(3, 5))
        doc.trimItemRange(a, edge: .head, to: s(8), clipDuration: s(10), minimum: fd)
        #expect(doc.layers[0].range == TimeRange(start: s(5) - fd, end: s(5)))
        doc.trimItemRange(a, edge: .tail, to: s(20), clipDuration: s(10), minimum: fd)
        #expect(doc.layers[0].range == TimeRange(start: s(5) - fd, end: s(10)))
        doc.trimItemRange(a, edge: .head, to: -s(1), clipDuration: s(10), minimum: fd)
        #expect(doc.layers[0].range == nil)                   // fills the clip again: whole clip
        doc.trimItemRange(whole, edge: .tail, to: s(6), clipDuration: s(10), minimum: fd)
        #expect(doc.layers[1].range == r(0, 6))
        #expect(doc.shownRange(of: doc.layers[0], clipDuration: s(10)) == r(0, 10))
    }
}

@Suite struct GraphicsItemRangeSetTests {
    @Test func setRangeClampsAndTargetsOnlyIds() {
        var a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        let b = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        a.range = nil
        var doc = GraphicsDocument(layers: [a, b])
        doc.setRange(TimeRange(start: Time(2, 1), end: Time(20, 1)), for: [a.id], clipDuration: Time(10, 1))
        #expect(doc.layers[0].range == TimeRange(start: Time(2, 1), end: Time(10, 1)))
        #expect(doc.layers[1].range == nil)
        doc.setRange(nil, for: [a.id], clipDuration: Time(10, 1))
        #expect(doc.layers[0].range == nil)
    }
}
