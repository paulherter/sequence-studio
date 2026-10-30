import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func f(_ n: Int64) -> Time { Time(n, 30) }

// A reverse mirrors a key track: each segment keeps its shape, turned around (ease sides, spatial tangents and the hold
// of a segment move to the key that now leads it). Clip keys and the keys of a Graphic's items go through the same remap.

@Suite struct KeyRemapMirrorTests {
    private let mirror: @Sendable (Time) -> Time = { s(10) - $0 }
    private let samples: [Time] = [s(0), s(1), s(2), s(2) + f(1), s(3), f(100), s(4), s(5), f(170), s(6), f(200), s(7),
                                   s(8) - f(1), s(8), s(9), s(10)]

    private func eased() -> AnimatedProperty<Double> {
        AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(2), value: 0, interpolation: .bezier, outHandle: EaseHandle(dx: 0.8, dy: 0)),
            Keyframe(time: s(6), value: 100, interpolation: .bezier, inHandle: EaseHandle(dx: 0.15, dy: 0.4),
                     outHandle: EaseHandle(dx: 0.1, dy: 0.5)),
            Keyframe(time: s(8), value: 40, inHandle: EaseHandle(dx: 0.9, dy: 0)),
        ]))
    }

    @Test func anEasedSegmentKeepsItsEaseMirrored() {
        let a = eased(), b = a.remapped(mirror)
        #expect(b.track.keys.map(\.time) == [s(2), s(4), s(8)])
        for t in samples { #expect(abs(b.value(atLocal: s(10) - t) - a.value(atLocal: t)) < 1e-6, "at \(t)") }
        // Not symmetric: the plain time flip without the sides swapped would be off.
        #expect(abs(a.value(atLocal: s(3)) - (100 - a.value(atLocal: s(5)))) > 1)
        #expect(b.track.keys[1].inHandle == a.track.keys[1].outHandle && b.track.keys[1].outHandle == a.track.keys[1].inHandle)
        #expect(b.remapped(mirror) == a)                       // twice is the original, nothing lost
    }

    @Test func aSpatialPathIsWalkedBackwards() {
        let a = AnimatedProperty(Vec2.zero, track: KeyframeTrack(keys: [
            Keyframe(time: s(2), value: Vec2(0, 0), interpolation: .bezier, outHandle: EaseHandle(dx: 0.7, dy: 0.1),
                     outTangent: Vec2(200, 0)),
            Keyframe(time: s(8), value: Vec2(300, 300), inHandle: EaseHandle(dx: 0.2, dy: 0.3), inTangent: Vec2(0, -50)),
        ]))
        let b = a.remapped(mirror)
        for t in samples {
            let x = a.value(atLocal: t), y = b.value(atLocal: s(10) - t)
            #expect(abs(x.x - y.x) < 1e-3 && abs(x.y - y.y) < 1e-3, "at \(t)")
        }
        #expect(b.track.keys[0].outTangent == Vec2(0, -50) && b.track.keys[1].inTangent == Vec2(200, 0))
        #expect(b.remapped(mirror) == a)
    }

    // MARK: Holds

    /// Every frame of the 10 s span: the reverse shows at `10 s - t` what the original shows at `t`, and a second
    /// reverse shows the original again.
    private func expectExactMirror(_ a: AnimatedProperty<Double>, _ name: String) {
        let b = a.remapped(mirror), c = b.remapped(mirror)
        for i in 0...300 {
            let t = f(Int64(i))
            #expect(abs(b.value(atLocal: s(10) - t) - a.value(atLocal: t)) < 1e-6, "\(name), frame \(i)")
            #expect(abs(c.value(atLocal: t) - a.value(atLocal: t)) < 1e-6, "\(name) twice, frame \(i)")
        }
        #expect(c == a, "\(name): twice is the original")
    }

    private func track(_ keys: [Keyframe<Double>]) -> AnimatedProperty<Double> { AnimatedProperty(0.0, track: KeyframeTrack(keys: keys)) }

    private var holdTracks: [(String, AnimatedProperty<Double>)] {
        let ease = EaseHandle(dx: 0.8, dy: 0), soft = EaseHandle(dx: 0.2, dy: 0.6)
        return [
            ("hold", track([Keyframe(time: s(0), value: 1, interpolation: .hold), Keyframe(time: s(10), value: 5)])),
            ("hold inside", track([Keyframe(time: s(2), value: 1, interpolation: .hold), Keyframe(time: s(7), value: 5)])),
            ("hold then linear", track([Keyframe(time: s(0), value: 1, interpolation: .hold), Keyframe(time: s(4), value: 5),
                                        Keyframe(time: s(10), value: 11)])),
            ("linear then hold", track([Keyframe(time: s(1), value: 1), Keyframe(time: s(4), value: 5, interpolation: .hold),
                                        Keyframe(time: s(9), value: 11)])),
            ("hold then hold", track([Keyframe(time: s(0), value: 1, interpolation: .hold),
                                      Keyframe(time: s(4), value: 5, interpolation: .hold), Keyframe(time: s(10), value: 9)])),
            ("eased neighbors", track([
                Keyframe(time: s(0), value: 0, interpolation: .bezier, outHandle: ease),
                Keyframe(time: s(3), value: 100, interpolation: .hold, inHandle: soft, outHandle: ease),
                Keyframe(time: s(7), value: 40, interpolation: .bezier, inHandle: soft, outHandle: EaseHandle(dx: 0.1, dy: 0.5)),
                Keyframe(time: s(10), value: -20, inHandle: EaseHandle(dx: 0.9, dy: 0))])),
            ("hold on one value", track([Keyframe(time: s(1), value: 3, interpolation: .hold), Keyframe(time: s(5), value: 3),
                                         Keyframe(time: s(9), value: 8)])),
            ("a last key that holds", track([Keyframe(time: s(1), value: 3, interpolation: .hold),
                                             Keyframe(time: s(5), value: 6, interpolation: .hold)])),
        ]
    }

    @Test func aHoldIsMirroredExactlyOnEveryFrame() {
        for (name, a) in holdTracks { expectExactMirror(a, name) }
    }

    /// The picture, spelled out: A held from 0 s, B at 10 s. Reversed, B shows on the first frame only and A on every
    /// frame after it.
    @Test func aReversedHoldShowsTheHeldValueOverTheSpan() {
        let a = track([Keyframe(time: s(0), value: 1, interpolation: .hold), Keyframe(time: s(10), value: 5)])
        let b = a.remapped(mirror)
        #expect(b.value(atLocal: s(0)) == 5)
        for i in 1...300 { #expect(b.value(atLocal: f(Int64(i))) == 1, "frame \(i)") }
        // The same two keys: the one that now comes first says it (Hold Ahead), no key is added.
        #expect(b.track.keys.map(\.id) == [a.track.keys[1].id, a.track.keys[0].id])
        #expect(b.track.keys.map(\.interpolation) == [.holdAhead, .linear] && b.track.keys.map(\.value) == [5, 1])
        #expect(KeyframeTrack(keys: b.track.keys) == b.track)
        let flat = track([Keyframe(time: s(1), value: 3, interpolation: .hold), Keyframe(time: s(5), value: 3)]).remapped(mirror)
        #expect(flat.track.keys.count == 2 && flat.value(atLocal: s(7)) == 3)
    }

    /// Clip keys and item keys alike, through the clip's reverse.
    @Test func aClipReverseMirrorsHoldsOfClipAndItemKeys() throws {
        for (name, a) in holdTracks {
            let v = Track(kind: .video)
            let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
            var p = Project(name: "P", timelines: [t])
            var item = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
            item.animation.rotation = a
            let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10), layers: [item])
            var before = p.timeline(t.id)!.tracks[0].clips.first { $0.id == id }!
            before.animation.rotation = a
            var after = before
            after.rescaleKeys(from: s(10), to: s(10), mirror: true)
            var twice = after
            twice.rescaleKeys(from: s(10), to: s(10), mirror: true)
            for i in 0...300 {
                let l = f(Int64(i))
                #expect(abs(after.animation.rotation.value(atLocal: s(10) - l) - a.value(atLocal: l)) < 1e-6, "\(name), clip, frame \(i)")
                #expect(abs(after.graphics!.layers[0].animation.rotation.value(atLocal: s(10) - l) - a.value(atLocal: l)) < 1e-6,
                        "\(name), item, frame \(i)")
            }
            #expect(twice.animation.rotation == a && twice.graphics!.layers[0].animation.rotation == a, "\(name)")
        }
    }

    // MARK: A reversed hold through other remaps

    private func scale(_ from: Time, _ to: Time) -> (Time) -> Time { { Time.scaled($0, by: to, over: from) } }

    /// Reverse, a speed change (200 %, 50 %, 33 %), reverse back: the original keys and the
    /// reversed picture on every frame in between.
    @Test func aSpeedChangeBetweenTwoReversesLeavesNoPhantomKey() {
        for (name, a) in holdTracks {
            let b = a.remapped(mirror)
            for (d, frames) in [(s(5), 150), (s(20), 600), (s(30), 900)] {
                let fast = b.remapped(scale(s(10), d))
                #expect(fast.track.keys.count == a.track.keys.count, "\(name) to \(d)")
                #expect(fast.track.keys.map(\.interpolation) == b.track.keys.map(\.interpolation), "\(name) to \(d)")
                let back = fast.remapped { d - $0 }
                #expect(back.track.keys.count == a.track.keys.count, "\(name) to \(d): no phantom key")
                for i in 0...frames {
                    let t = f(Int64(i)), original = Time.scaled(t, by: s(10), over: d)
                    #expect(abs(fast.value(atLocal: d - t) - a.value(atLocal: original)) < 1e-6, "\(name) to \(d), reversed, frame \(i)")
                    #expect(abs(back.value(atLocal: t) - a.value(atLocal: original)) < 1e-6, "\(name) to \(d), frame \(i)")
                }
                #expect(back.remapped(scale(d, s(10))) == a, "\(name) to \(d)")
                // Direction and speed in one remap (the speed dialog with Reverse toggled).
                #expect(b.remapped { d - Time.scaled($0, by: d, over: s(10)) }.remapped(scale(d, s(10))) == a, "\(name) to \(d), one step")
            }
        }
    }

    /// The same through a zone remap (a trim of a clip with animation zones).
    @Test func aZoneRemapBetweenTwoReversesLeavesNoPhantomKey() {
        for (name, a) in holdTracks {
            let b = a.remapped(mirror)
            for introEnd in [s(0), s(3), s(6)] {
                for middle in [AnimationZones.Middle.hold, .stretch] {
                    for edge in [ClipEdge.head, .tail] {
                        let z = AnimationZones(introEnd: introEnd, outroLength: s(2), middle: middle)
                        let label = "\(name), intro \(introEnd), \(middle), \(edge)"
                        let trimmed = b.remapped { z.keyTime($0, from: s(10), to: s(14), edge: edge) }
                        #expect(trimmed.track.keys.count == a.track.keys.count, "\(label)")
                        #expect(trimmed.track.keys.map(\.interpolation) == b.track.keys.map(\.interpolation), "\(label)")
                        let back = trimmed.remapped { s(14) - $0 }
                        #expect(back.track.keys.count == a.track.keys.count, "\(label): no phantom key")
                        #expect(back.track.keys.map(\.id) == a.track.keys.map(\.id), "\(label)")
                        for i in 0...420 {
                            let t = f(Int64(i))
                            #expect(abs(back.value(atLocal: t) - trimmed.value(atLocal: s(14) - t)) < 1e-6, "\(label), frame \(i)")
                        }
                    }
                }
            }
        }
    }

    /// Through the clip's own retime and zone trim, clip keys and item keys alike.
    @Test func aClipRetimeAndZoneTrimKeepReversedHoldsWhole() throws {
        let a = track([Keyframe(time: s(2), value: 1, interpolation: .hold), Keyframe(time: s(7), value: 5)])
        let v = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        var item = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        item.animation.rotation = a
        let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10), layers: [item])
        var clip = p.timeline(t.id)!.tracks[0].clips.first { $0.id == id }!
        clip.animation.rotation = a
        var c = clip
        c.rescaleKeys(from: s(10), to: s(10), mirror: true)
        #expect(c.animation.rotation.track.keys.count == 2 && c.graphics!.layers[0].animation.rotation.track.keys.count == 2)
        c.rescaleKeys(from: s(10), to: s(5), mirror: false)                 // 200 %
        c.rescaleKeys(from: s(5), to: s(20), mirror: false)                 // 50 %
        c.remapKeysThroughZones(AnimationZones(introEnd: s(6), outroLength: s(2), middle: .stretch),
                                from: s(20), to: s(30), edge: .tail)
        for r in [c.animation.rotation, c.graphics!.layers[0].animation.rotation] {
            #expect(r.track.keys.map(\.interpolation) == [.holdAhead, .linear])
        }
        c.rescaleKeys(from: s(30), to: s(30), mirror: true)
        for r in [c.animation.rotation, c.graphics!.layers[0].animation.rotation] {
            #expect(r.track.keys.map(\.id) == a.track.keys.map(\.id))
            #expect(r.track.keys.map(\.interpolation) == [.hold, .linear] && r.track.keys.map(\.value) == [1, 5])
        }
    }

    // MARK: A Hold Ahead is one key everywhere

    @Test func aReversedHoldIsTwoKeysInEveryKeyList() throws {
        let a = track([Keyframe(time: s(2), value: 1, interpolation: .hold), Keyframe(time: s(7), value: 5)])
        let b = a.remapped(mirror)
        #expect(b.track.keys.map(\.time) == [s(3), s(8)])
        let pt = PropertyTrack.scalar(b.track)
        #expect(pt.times.map(\.time) == [s(3), s(8)] && pt.keyIDs == b.track.keys.map(\.id))
        let summary = KeyframeSummary(tracks: ["r": pt])
        #expect(summary.groups().map(\.time) == [s(3), s(8)])
        let v = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10),
                                       layers: [GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)])
        var clip = p.timeline(t.id)!.tracks[0].clips.first { $0.id == id }!
        clip.animation.rotation = b
        #expect(clip.keyframeTimes.sorted() == [s(3), s(8)])
        // Moving the key moves the step with it.
        var moved = summary
        moved.move([SummaryMember(property: "r", keyID: b.track.keys[0].id)], by: f(15), frame: f(1))
        guard case .scalar(let m)? = moved.tracks["r"] else { Issue.record("no track"); return }
        #expect(m.keys.map(\.time) == [s(3) + f(15), s(8)] && m.keys[0].interpolation == .holdAhead)
        #expect(m.value(at: s(3) + f(15)) == 5 && m.value(at: s(3) + f(16)) == 1 && m.value(at: s(3)) == 5)
    }

    @Test func keysCollapsedOntoOneTickKeepTheirMirroredOrder() {
        let k = [Keyframe(time: s(1), value: 1.0), Keyframe(time: s(1) + f(12), value: 2.0), Keyframe(time: s(5), value: 3.0)]
        let a = AnimatedProperty(0.0, track: KeyframeTrack(keys: k))
        // A mirror onto whole seconds: the first two keys land on 9 s.
        let b = a.remapped { $0 == s(5) ? s(5) : s(9) }
        #expect(b.track.keys.map(\.id) == [k[2].id, k[1].id, k[0].id])      // exactly the reverse, no key dropped
        #expect(b.track.keys.map(\.time) == [s(5), s(9), s(9)])
        // A remap that is neither rising nor falling is put in time order.
        let c = a.remapped { $0 == s(1) ? s(4) : ($0 == s(5) ? s(3) : s(2)) }
        #expect(c.track.keys.map(\.time) == [s(2), s(3), s(4)])
        // A rising remap (a shift, a retime) leaves order and sides alone.
        let e = eased()
        let g = e.remapped { $0 + s(1) }
        #expect(g.track.keys.map(\.id) == e.track.keys.map(\.id))
        #expect(g.track.keys.map(\.outHandle) == e.track.keys.map(\.outHandle))
    }

    /// Clip keys and item keys alike, through the clip's reverse.
    @Test func aClipReverseMirrorsEasedClipAndItemKeys() throws {
        let v = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        var item = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        item.animation.rotation = eased()
        let id = try p.addGraphicsClip(in: t.id, at: s(2), track: v.id, duration: s(10), layers: [item])
        var before = p.timeline(t.id)!.tracks[0].clips.first { $0.id == id }!
        before.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: eased().track.keys.map {
            var k = $0; k.value = k.value / 100; return k }))
        var after = before
        after.rescaleKeys(from: s(10), to: s(10), mirror: true)
        for l in samples {
            #expect(abs(after.animation.opacity.value(atLocal: s(10) - l) - before.animation.opacity.value(atLocal: l)) < 1e-6)
            #expect(abs(after.graphics!.layers[0].animation.rotation.value(atLocal: s(10) - l)
                        - before.graphics!.layers[0].animation.rotation.value(atLocal: l)) < 1e-6)
        }
    }
}
