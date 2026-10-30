import Foundation
import Testing
@testable import SQCore

/// Long-track drift: a track runs between the path keys the user already set and spreads the end error over the stretch.
@Suite struct MaskReAnchorTests {
    func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { (a - b).length < tol }

    func square(_ x: Double) -> MaskPath { .rectangle(Vec2(x, 0.4), Vec2(x + 0.2, 0.6)) }

    /// 3 s clip at 10 fps; a mask whose path has a key (frame, left edge x) per entry.
    func clip(keys: [(Int, Double)]) -> (Clip, ClipMask.ID) {
        var m = ClipMask.make(.rectangle, name: "M")
        m.path = AnimatedProperty(square(0.1))
        for (f, x) in keys { m.path.track.insert(Keyframe(time: Time(Int64(f), 10), value: square(x))) }
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        c.masks = [m]
        return (c, m.id)
    }
    func times(_ n: Int) -> [Time] { (0..<n).map { Time(Int64($0), 10) } }
    func shift(_ dx: Double) -> MaskMotion? { MaskMotion(translation: Vec2(dx, 0)) }

    @Test func noKeysIsOneSegment() {
        let (c, id) = clip(keys: [])
        #expect(c.maskTrackSegments(id, times: times(10)) == [0..<10])
    }

    @Test func aLoneKeySplitsTheTrack() {
        let (c, id) = clip(keys: [(5, 0.5)])
        #expect(c.maskTrackSegments(id, times: times(10)) == [0..<6, 5..<10])
    }

    @Test func aTrackedRunIsNotAnAnchor() {
        // Keys on every frame 2...8 are an earlier tracking result: re-tracking replaces them, no anchors.
        let (c, id) = clip(keys: (2...8).map { ($0, Double($0) / 10) })
        #expect(c.maskTrackSegments(id, times: times(10)) == [0..<10])
    }

    @Test func backwardTrackSplitsInVisitOrder() {
        let (c, id) = clip(keys: [(4, 0.4)])
        #expect(c.maskTrackSegments(id, times: Array(times(10).reversed())) == [0..<6, 5..<10])
    }

    @Test func endErrorIsSpreadOverTheStretch() {
        // Frames 0...5: key at 0 (x 0.1) and an anchor key at 5 (x 0.5). The tracker drifts to x 0.3 at frame 5.
        var (c, id) = clip(keys: [(0, 0.1), (5, 0.5)])
        let ts = times(6)
        let segs = c.maskTrackSegments(id, times: ts)
        #expect(segs == [0..<6])
        let n = c.applyMaskTrack(id, times: ts, segments: segs, motions: [(0..<6).map { shift(0.04 * Double($0)) }])
        #expect(n == 6)
        let keys = c.mask(id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(keys.count == 6)
        #expect(near(keys[0].value.vertices[0].point, Vec2(0.1, 0.4)))
        // Tracked 0.1 + 0.12 at frame 3, plus 3/5 of the end error (0.5 - 0.3).
        #expect(near(keys[3].value.vertices[0].point, Vec2(0.1 + 0.12 + 0.2 * 3 / 5, 0.4)))
        #expect(near(keys[5].value.vertices[0].point, Vec2(0.5, 0.4)))
    }

    @Test func eachSegmentStartsFromItsAnchorAndChains() {
        var (c, id) = clip(keys: [(0, 0.1), (3, 0.3)])
        let ts = times(7)
        let segs = c.maskTrackSegments(id, times: ts)
        #expect(segs == [0..<4, 3..<7])
        let a = (0..<4).map { shift(0.1 * Double($0)) }       // ends at 0.4, the key says 0.3
        let b = (0..<4).map { shift(0.01 * Double($0)) }      // starts from the key
        #expect(c.applyMaskTrack(id, times: ts, segments: segs, motions: [a, b]) == 7)
        let keys = c.mask(id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(near(keys[3].value.vertices[0].point, Vec2(0.3, 0.4)))      // pulled onto the anchor
        #expect(near(keys[6].value.vertices[0].point, Vec2(0.33, 0.4)))     // last stretch has no end anchor: raw
    }

    @Test func lostObjectStopsTheWholeRun() {
        var (c, id) = clip(keys: [(0, 0.1), (3, 0.3)])
        let ts = times(7)
        let segs = c.maskTrackSegments(id, times: ts)
        let a: [MaskMotion?] = [.identity, shift(0.01), nil, nil]
        let b: [MaskMotion?] = Array(repeating: .identity, count: 4)
        #expect(c.applyMaskTrack(id, times: ts, segments: segs, motions: [a, b]) == 2)    // frames 0 and 1 only
    }
}
