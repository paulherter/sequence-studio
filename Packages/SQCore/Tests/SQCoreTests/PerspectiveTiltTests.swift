import Foundation
import Testing
@testable import SQCore

// Perspective tilt (rotationX / rotationY of a layer): one projective geometry for render, overlay and hit-test.
private func tClip() -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(0, 1), duration: Time(10, 1)), start: Time(0, 1))
}

struct PerspectiveTiltTests {
    private func near(_ a: Vec2, _ b: Vec2, _ eps: Double = 1e-9) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

    @Test func identityAtZero() {
        let p = Vec2(123.5, -77.25)
        #expect(PerspectiveTilt.project(p, tiltX: 0, tiltY: 0, focal: 1000) == p)
        #expect(PerspectiveTilt.unproject(p, tiltX: 0, tiltY: 0, focal: 1000) == p)
        #expect(PerspectiveTilt.isIdentity(tiltX: 0, tiltY: 0))
        #expect(!PerspectiveTilt.isIdentity(tiltX: 0, tiltY: 0.5))
    }

    @Test func anchorStaysPut() {
        #expect(PerspectiveTilt.project(.zero, tiltX: 40, tiltY: -30, focal: 900) == .zero)
    }

    @Test func tiltYForeshortensWidthAndShrinksTheFarEdge() {
        // Right edge away (positive tilt Y): it shrinks toward the center, the near (left) edge grows.
        let f = 1000.0
        let right = PerspectiveTilt.project(Vec2(200, 100), tiltX: 0, tiltY: 45, focal: f)
        let left = PerspectiveTilt.project(Vec2(-200, 100), tiltX: 0, tiltY: 45, focal: f)
        #expect(abs(right.x) < 200 && abs(left.x) < 200)         // foreshortened
        #expect(right.y < 100 && left.y > 100)                   // far edge smaller, near edge larger
        // The exact value: z = x sin b, x'' = x cos b, s = f / (f + z).
        let b = 45.0 * .pi / 180
        let s = f / (f + 200 * sin(b))
        #expect(near(right, Vec2(200 * cos(b) * s, 100 * s)))
    }

    @Test func tiltXMovesTheTopAway() {
        let f = 1000.0
        let top = PerspectiveTilt.project(Vec2(100, -100), tiltX: 30, tiltY: 0, focal: f)
        let bottom = PerspectiveTilt.project(Vec2(100, 100), tiltX: 30, tiltY: 0, focal: f)
        #expect(top.x < 100 && bottom.x > 100)
    }

    @Test func unprojectInvertsProject() {
        let cases: [(Double, Double)] = [(0, 0), (20, 0), (0, -35), (50, 40), (-80, 75), (89, -89)]
        for (a, b) in cases {
            for p in [Vec2(0, 0), Vec2(120, 80), Vec2(-300, 40), Vec2(10, -250)] {
                let f = PerspectiveTilt.focal(layerRadius: 400, canvas: Vec2(1920, 1080))
                let q = PerspectiveTilt.project(p, tiltX: a, tiltY: b, focal: f)
                #expect(near(PerspectiveTilt.unproject(q, tiltX: a, tiltY: b, focal: f), p, 1e-6))
            }
        }
    }

    @Test func tiltIsClampedAndTheQuadNeverCrossesTheCameraPlane() {
        #expect(PerspectiveTilt.clamped(200) == 89)
        #expect(PerspectiveTilt.clamped(-200) == -89)
        #expect(PerspectiveTilt.clamped(.nan) == 0)
        // A huge layer (radius 50 000 px) on a small canvas: the focal distance grows with it.
        let f = PerspectiveTilt.focal(layerRadius: 50_000, canvas: Vec2(1920, 1080))
        #expect(f > 50_000)
        for c in [Vec2(50_000, 0), Vec2(-50_000, 0), Vec2(0, 50_000), Vec2(0, -50_000), Vec2(35_000, 35_000)] {
            #expect(PerspectiveTilt.depthDivisor(c, tiltX: 89, tiltY: 89, focal: f) > 0)
        }
        #expect(PerspectiveTilt.focal(layerRadius: 10, canvas: Vec2(1920, 1080)) >= 1920)
    }

    @Test func tiltKeyframesLikeRotation() {
        var c = tClip()
        #expect(c.transform(at: c.start).tiltX == 0)
        c.animation.tiltX = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 60.0)]))
        c.animation.tiltY = AnimatedProperty(25.0)
        let mid = c.transform(at: c.start + Time(1, 1))
        #expect(abs(mid.tiltX - 30) < 1e-9)
        #expect(mid.tiltY == 25)
        c.animation.tiltY = AnimatedProperty(500.0)
        #expect(c.transform(at: c.start).tiltY == 89)    // clamped on evaluation
        let moved = c.animation.shifted(by: Time(1, 1))
        #expect(moved.tiltX.track.keys.map(\.time) == [Time(1, 1), Time(3, 1)])
    }

    @Test func tiltOnlyWritesWhenSetAndGatesV84() throws {
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())])
        #expect(!String(decoding: try ProjectFile.encode(p), as: UTF8.self).contains("tiltX"))
        var c = tClip()
        c.animation.tiltX = AnimatedProperty(20.0)
        try p.timelines[0].tracks[0].insert(c)
        let data = try ProjectFile.encode(p)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["formatVersion"] as? Int == 84)
        for migrations in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: migrations)
            #expect(back.timelines[0].tracks[0].clips[0].animation.tiltX.value == 20)
        }
    }

    @Test func keyedTiltAloneIsMotionForBlur() {
        var c = tClip()
        c.motionEnabled = true
        #expect(c.transformIsStatic)
        c.animation.tiltY = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 60.0)]))
        #expect(!c.transformIsStatic)
        c.motionEnabled = false
        #expect(c.transformIsStatic)   // gated like the other Motion properties
    }

    @Test func pasteMotionCopiesTilt() {
        var src = tClip(), dst = tClip()
        src.animation.tiltX = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 40.0)]))
        src.animation.tiltY = AnimatedProperty(12.0)
        dst.replaceMotion(with: src)
        #expect(dst.animation.tiltX == src.animation.tiltX && dst.animation.tiltY.value == 12)
    }
}
