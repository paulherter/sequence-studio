import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }

// Item lanes: an item's keyframes follow the clip's own keys through trim, cut, retime and reverse, and the halves of a
// cut are independent although they keep the same item ids.

@Suite struct GraphicsItemKeysTests {
    /// What render draws of one item at one instant.
    private struct Drawn: Equatable {
        var transform: ClipTransform
        var shape: ShapeStyle?
    }

    /// A shape item animated in Motion, Opacity and its Shape effect, keys between clip-local 1 s and 9 s.
    private static func item(_ name: String, _ range: TimeRange?) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        l.range = range
        l.animation.position.track = KeyframeTrack(keys: [Keyframe(time: s(2), value: Vec2(0, 0)),
                                                          Keyframe(time: s(8), value: Vec2(600, 300))])
        l.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(1), value: 0.2), Keyframe(time: s(9), value: 1)])
        l.animation.rotation.track = KeyframeTrack(keys: [Keyframe(time: s(3), value: 0), Keyframe(time: s(7), value: 90)])
        let key = l.effects[0].parameters.keys.sorted()[0]
        let base = l.effects[0].parameters[key]!.value
        l.effects[0].parameters[key]!.track = KeyframeTrack(keys: [Keyframe(time: s(2), value: base),
                                                                   Keyframe(time: s(6), value: base * 0.5)])
        return l
    }

    /// A 10 s Graphic at 2 s (timeline 2 s ..< 12 s) with a whole-clip item and one ranged over clip-local 1 s ..< 9 s.
    private static func project() throws -> (Project, Timeline.ID, Clip.ID) {
        let v = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10),
                                       layers: [item("whole", nil), item("ranged", r(1, 9))])
        return (p, t.id, id)
    }

    /// Every item render draws at `t`, by name (names are unique per clip; only one clip is at `t`).
    private static func drawn(_ tl: Timeline, at t: Time) -> [String: Drawn] {
        let names = Dictionary(tl.tracks.flatMap(\.clips).filter { $0.timeline.contains(t) }
            .flatMap { $0.graphics?.layers ?? [] }.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Drawn] = [:]
        for q in tl.videoLayers(at: t) { if let n = names[q.clip] { out[n] = Drawn(transform: q.transform, shape: q.shape) } }
        return out
    }

    /// Timeline times across the clip: both edges, the range's edges, key times and frames between them.
    private static let samples: [Time] = [s(2), s(2) + f(1), s(3), s(3) + f(1), s(4), s(5) - f(1), s(5), s(5) + f(1), s(6) - f(1),
                                          s(6), s(6) + f(7), s(7), s(8) + f(15), s(9), s(10), s(11) - f(1), s(11), s(12) - f(1)]

    private static func clip(_ t: Timeline, _ id: Clip.ID) -> Clip { t.tracks.flatMap(\.clips).first { $0.id == id }! }

    // MARK: Trim

    @Test func aHeadTrimKeepsItemKeysOnTheirFrames() throws {
        let (p, tl, id) = try Self.project()
        let before = p.timeline(tl)!
        var after = before
        try after.trim(id, edge: .head, by: s(3))             // the clip now starts at 5 s
        #expect(Self.clip(after, id).start == s(5))
        for t in Self.samples where t >= s(5) { #expect(Self.drawn(after, at: t) == Self.drawn(before, at: t), "at \(t)") }
        #expect(Self.drawn(after, at: s(5))["whole"] != Self.drawn(before, at: s(2))["whole"])   // not just restarted
        try after.trim(id, edge: .head, by: -s(1))            // longer again: still on the same frames
        for t in Self.samples where t >= s(5) { #expect(Self.drawn(after, at: t) == Self.drawn(before, at: t), "at \(t)") }
        #expect(Self.drawn(after, at: s(4))["whole"] == Self.drawn(before, at: s(4))["whole"])
    }

    @Test func aTailTrimLeavesItemKeysAlone() throws {
        let (p, tl, id) = try Self.project()
        let before = p.timeline(tl)!
        var after = before
        try after.trim(id, edge: .tail, by: -s(4))            // the clip now ends at 8 s
        #expect(Self.clip(after, id).graphics?.layers.map(\.animation) == Self.clip(before, id).graphics?.layers.map(\.animation))
        for t in Self.samples where t < s(8) { #expect(Self.drawn(after, at: t) == Self.drawn(before, at: t), "at \(t)") }
    }

    // MARK: Split

    @Test func bothHalvesOfASplitLookAsBeforeTheCut() throws {
        let (p, tl, _) = try Self.project()
        let before = p.timeline(tl)!
        var after = before
        try after.tracks[0].split(at: s(6))
        #expect(after.tracks[0].clips.count == 2)
        for t in Self.samples { #expect(Self.drawn(after, at: t) == Self.drawn(before, at: t), "at \(t)") }
        // A second cut inside the right half: three pieces, still the same picture.
        try after.tracks[0].split(at: s(9) + f(10))
        #expect(after.tracks[0].clips.count == 3)
        for t in Self.samples { #expect(Self.drawn(after, at: t) == Self.drawn(before, at: t), "at \(t)") }
    }

    // MARK: Speed

    @Test func aRetimeScalesItemKeys() throws {
        let (p, tl, id) = try Self.project()
        let before = Self.clip(p.timeline(tl)!, id)
        var after = before
        after.rescaleKeys(from: s(10), to: s(5), mirror: false)   // twice as fast
        for l in [s(0), s(1), f(45), s(2), f(100), s(4), f(149), s(6), f(250), s(9), s(10)] {
            let half = Time.scaled(l, by: s(5), over: s(10))
            for (a, b) in zip(before.graphics!.layers, after.graphics!.layers) {
                #expect(after.graphicsLayerClip(b).transform(at: after.start + half)
                        == before.graphicsLayerClip(a).transform(at: before.start + l), "at local \(l)")
                #expect(b.shapeStyle(atLocal: half) == a.shapeStyle(atLocal: l), "at local \(l)")
            }
        }
    }

    @Test func aReverseMirrorsItemKeys() throws {
        let (p, tl, id) = try Self.project()
        let before = Self.clip(p.timeline(tl)!, id)
        var after = before
        after.rescaleKeys(from: s(10), to: s(10), mirror: true)
        // Every key lands on its mirrored time with its value: the instant drawn at local l is now drawn at 10 s - l.
        for (a, b) in zip(before.graphics!.layers, after.graphics!.layers) {
            #expect(b.animation.position.track.keys.map(\.time).sorted() == a.animation.position.track.keys.map { s(10) - $0.time }.sorted())
            for k in a.animation.position.track.keys {
                #expect(b.animation.position.value(atLocal: s(10) - k.time) == k.value)
            }
            for k in a.animation.opacity.track.keys { #expect(b.animation.opacity.value(atLocal: s(10) - k.time) == k.value) }
            for k in a.animation.rotation.track.keys { #expect(b.animation.rotation.value(atLocal: s(10) - k.time) == k.value) }
            // Linear keys: the frames between them mirror too.
            for l in [f(75), s(4), f(160), s(7)] {
                #expect(abs(b.animation.rotation.value(atLocal: s(10) - l) - a.animation.rotation.value(atLocal: l)) < 1e-9)
            }
            #expect(b.shapeStyle(atLocal: s(6)) == a.shapeStyle(atLocal: s(4)))
        }
        #expect(after.graphics?.layers[1].range == r(1, 9))   // the range mirrors with them
    }

    // MARK: Split halves share item ids

    /// The halves keep the same item ids (like pasted copies of a Graphic). Ids are resolved inside one clip only: an
    /// edit, a removal or a Follow link in one half never reaches the other.
    @Test func theHalvesOfASplitAreIndependentAlthoughTheyShareItemIDs() throws {
        var (p, tl, _) = try Self.project()
        try p.edit(tl) { try $0.tracks[0].split(at: s(6)) }
        let clips = p.timeline(tl)!.tracks[0].clips
        let left = clips[0], right = clips[1]
        #expect(left.id != right.id)
        #expect(left.graphics?.layers.map(\.id) == right.graphics?.layers.map(\.id))
        let whole = left.graphics!.layers[0].id, ranged = left.graphics!.layers[1].id

        // Follow set in the left half: the right half has no link and draws as before.
        let rightBefore = Self.drawn(p.timeline(tl)!, at: s(8))
        try p.editGraphics(clipID: left.id) { d in
            d.layers[d.index(of: ranged)!].follow = GraphicsFollow(target: .layer(id: whole))
            d.moveItemRange(ranged, toStart: .zero, clipDuration: left.duration)
            d.layers[d.index(of: whole)!].name = "renamed"
        }
        var now = p.timeline(tl)!.tracks[0].clips
        #expect(now[1] == right)
        #expect(now[1].graphics?.hasFollow == false)
        #expect(now[0].graphics?.hasFollow == true)
        #expect(Self.drawn(p.timeline(tl)!, at: s(8)) == rightBefore)

        // Removing the followed item in the right half drops nothing in the left half, and the left half's link still
        // resolves to the left half's own item.
        try p.editGraphics(clipID: right.id) { $0.remove([whole]) }
        now = p.timeline(tl)!.tracks[0].clips
        #expect(now[1].graphics?.layers.map(\.id) == [ranged])
        #expect(now[0].graphics?.layers.map(\.id) == [whole, ranged])
        #expect(now[0].graphics?.layer(ranged)?.follow?.target == .layer(id: whole))
        #expect(now[0].graphics?.followPlan().count == 1)
        #expect(now[1].graphics?.followPlan().isEmpty == true)
    }
}
