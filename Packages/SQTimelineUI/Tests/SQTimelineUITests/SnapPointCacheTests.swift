#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// The per-gesture snap point cache must give exactly what recomputing `Timeline.snapPoints` on every event gives:
/// two interactions run in lockstep (cache on / off) over random timelines, tools, drags, ripple and magnetic.
private let fd = Time(1, 24)

private struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ n: Int) -> Bool { int(n) == 0 }
}

private func randomTimeline(_ rng: inout RNG) -> Timeline {
    var tracks: [Track] = []
    var links: [UUID] = []
    for kind in [TrackKind.video, .video, .audio, .audio] {
        var clips: [Clip] = []
        var at: Int64 = Int64(rng.int(6))
        for _ in 0..<(3 + rng.int(6)) {
            let len = Int64(4 + rng.int(30))
            var link: UUID?
            if kind == .video, rng.chance(3) { link = UUID(); links.append(link!) }
            if kind == .audio, !links.isEmpty, rng.chance(2) { link = links.removeFirst() }
            var c = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 40, duration: fd * len),
                         start: fd * at, link: link, mediaDuration: fd * 200)
            if rng.chance(2) { c.animation.opacity.track.insert(Keyframe(time: fd * Int64(rng.int(Int(len))), value: 0.3)) }
            if rng.chance(3) { c.animation.volume.track.insert(Keyframe(time: fd * Int64(rng.int(Int(len))), value: 0.5)) }
            clips.append(c)
            at += len + (rng.chance(3) ? 0 : Int64(1 + rng.int(12)))
        }
        tracks.append(Track(kind: kind, clips: clips))
    }
    return Timeline(name: "t", frameDuration: fd, tracks: tracks)
}

private func randomModifiers(_ rng: inout RNG) -> GestureModifiers {
    var m: GestureModifiers = []
    if rng.chance(4) { m.insert(.command) }
    if rng.chance(4) { m.insert(.option) }
    if rng.chance(5) { m.insert(.shift) }
    return m
}

/// A point on a random clip: middle, near the head or near the tail (edge handles).
private func randomPoint(_ rng: inout RNG, _ i: TimelineInteraction) -> CGPoint {
    let rows = i.geometry.rows(for: i.timeline)
    let clips = i.timeline.tracks.flatMap { t in t.clips.map { (t.id, $0) } }
    if clips.isEmpty || rng.chance(8) { return CGPoint(x: CGFloat(130 + rng.int(500)), y: CGFloat(20 + rng.int(140))) }
    let (tid, c) = clips[rng.int(clips.count)]
    let row = rows.first { $0.track == tid }!
    let x0 = i.geometry.x(for: c.timeline.start), x1 = i.geometry.x(for: c.timeline.end)
    let x: CGFloat = switch rng.int(3) {
    case 0: x0 + 1
    case 1: x1 - 1
    default: (x0 + x1) / 2
    }
    return CGPoint(x: x, y: row.y + row.height / 2)
}

/// Timeline without identities: splits, copies and new tracks mint fresh UUIDs in each interaction.
private func shape(_ tl: Timeline) -> [String] {
    tl.tracks.map { t in
        "\(t.kind):" + t.clips.map { c in
            "\(c.kind) \(c.timeline.start) \(c.timeline.duration) \(c.source.start) \(c.link != nil)"
        }.joined(separator: ",")
    }
}

private func expectSame(_ a: TimelineInteraction, _ b: TimelineInteraction) {
    #expect(shape(a.preview) == shape(b.preview))
    #expect(a.snapTime == b.snapTime)
    #expect(a.pendingEdits.count == b.pendingEdits.count)
    #expect(a.selection.count == b.selection.count)
    #expect(a.isRejected == b.isRejected)
}

@Suite struct SnapPointCacheTests {
    @Test func cachedSnappingEqualsRecomputedOverRandomGestures() {
        let tools: [TimelineTool] = [.selection, .selection, .rippleEdit, .rollEdit, .slip, .slide, .razor]
        var snapsSeen = 0
        for seed in 0..<60 {
            var rng = RNG(s: UInt64(seed) &* 7919)
            var tl = randomTimeline(&rng)
            if seed % 2 == 1 { tl.setEditMode(.magnetic) }      // Fast Cut: magnetic verbs, attachments, keepAttached
            let geo = TimelineGeometry(frameDuration: fd, pointsPerFrame: CGFloat(2 + rng.int(6)))
            var cached = TimelineInteraction(timeline: tl, geometry: geo)
            var plain = TimelineInteraction(timeline: tl, geometry: geo)
            plain.snapCacheEnabled = false
            for _ in 0..<6 {
                var ts = ToolState(tool: tools[rng.int(tools.count)], snapping: !rng.chance(6), linkedSelection: !rng.chance(4))
                ts.keepAttached = rng.chance(3)
                let playhead: Time? = rng.chance(4) ? nil : fd * Int64(rng.int(120))
                let markers = (0..<rng.int(3)).map { _ in fd * Int64(rng.int(120)) }
                for k in 0..<2 {
                    var i = k == 0 ? cached : plain
                    i.toolState = ts; i.playhead = playhead; i.markers = markers
                    if k == 0 { cached = i } else { plain = i }
                }
                // Optional pre-selection click so multi-clip moves happen.
                if rng.chance(2) {
                    let p = randomPoint(&rng, cached), m: GestureModifiers = rng.chance(2) ? [.shift] : []
                    cached.mouseDown(p, modifiers: m); _ = cached.mouseUp(p, modifiers: m)
                    plain.mouseDown(p, modifiers: m); _ = plain.mouseUp(p, modifiers: m)
                }
                let down = randomPoint(&rng, cached)
                var m = randomModifiers(&rng)
                cached.mouseDown(down, modifiers: m); plain.mouseDown(down, modifiers: m)
                #expect(cached.razorCutTime(atX: down.x) == plain.razorCutTime(atX: down.x))
                var p = down
                for _ in 0..<(2 + rng.int(10)) {
                    p.x += CGFloat(rng.int(41) - 20)
                    if rng.chance(3) { p.y += CGFloat(rng.int(41) - 20) }
                    if rng.chance(4) { m = randomModifiers(&rng) }
                    if rng.chance(6) {      // the playhead or markers move mid-gesture
                        let ph = fd * Int64(rng.int(120))
                        cached.playhead = ph; plain.playhead = ph
                        if rng.chance(2) { cached.markers.append(ph + fd); plain.markers.append(ph + fd) }
                    }
                    if rng.chance(5) { cached.snapInverted.toggle(); plain.snapInverted.toggle() }
                    cached.mouseDragged(p, modifiers: m); plain.mouseDragged(p, modifiers: m)
                    if cached.snapTime != nil { snapsSeen += 1 }
                    expectSame(cached, plain)
                }
                let a = cached.mouseUp(p, modifiers: m), b = plain.mouseUp(p, modifiers: m)
                #expect(shape(a?.timeline ?? cached.timeline) == shape(b?.timeline ?? plain.timeline))
                #expect(a?.undoName == b?.undoName)
                #expect(shape(cached.timeline) == shape(plain.timeline))
                plain.reset(timeline: cached.timeline)      // same identities again for the next gesture
                plain.setSelection(cached.selection)
                plain.snapInverted = cached.snapInverted        // reset() cleared it; a press without a gesture keeps it
                // The razor guide reads the cache too: sweep it across the committed timeline.
                for x in stride(from: TimelineGeometry.contentOriginX, to: TimelineGeometry.contentOriginX + 1200, by: 1) {
                    #expect(cached.razorCutTime(atX: x) == plain.razorCutTime(atX: x))
                }
                if rng.chance(5) {      // undo / external edit swaps the timeline
                    let other = randomTimeline(&rng)
                    cached.reset(timeline: other); plain.reset(timeline: other)
                }
            }
        }
        #expect(snapsSeen > 100)
    }

    @Test func externalTimelineChangeInvalidatesTheCache() {
        var rng = RNG(s: 42)
        let tl = randomTimeline(&rng)
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .razor, snapping: true, linkedSelection: true)
        let p = CGPoint(x: i.geometry.x(for: fd * 2000) + 3, y: 40)
        i.mouseDown(p, modifiers: [.shift]); i.cancel()      // razor press fills the cache, no cut
        #expect(i.razorCutTime(atX: p.x) != fd * 2000)
        let far = Clip(name: "far", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 10),
                       start: fd * 2000, mediaDuration: fd * 100)
        let moved = Timeline(name: "t", frameDuration: fd, tracks: tl.tracks + [Track(kind: .video, clips: [far])])
        i.reset(timeline: moved)
        i.mouseDown(p, modifiers: [.shift]); i.cancel()      // razor press fills the cache, no cut
        #expect(moved.snapPoints().contains { $0.time == fd * 2000 })
        #expect(i.timeline.snapPoints().contains { $0.time == fd * 2000 })
        #expect(i.razorCutTime(atX: p.x) == fd * 2000)
    }
}
