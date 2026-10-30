import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func ms(_ n: Int64) -> Time { Time(n, 1000) }
private let frame = Vec2(1920, 1080)
private let easeOut = EaseHandle(dx: 0.6, dy: 0)
private let easeIn = EaseHandle(dx: 0.4, dy: 0.1)

private func clip(seconds: Int64 = 6, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(seconds)), start: s(10))
}

/// Scale 1.5 → 1.8 and Position 100 → 292 px (x) between 2 s and 3 s, eased.
private func animatedClip() -> Clip {
    var c = clip()
    c.animation.scale.track = KeyframeTrack(keys: [
        Keyframe(time: s(2), value: Vec2(1.5, 1.5), interpolation: .bezier, outHandle: easeOut),
        Keyframe(time: s(3), value: Vec2(1.8, 1.8), interpolation: .bezier, inHandle: easeIn),
    ])
    c.animation.position.track = KeyframeTrack(keys: [
        Keyframe(time: s(2), value: Vec2(100, 50)),
        Keyframe(time: s(3), value: Vec2(292, 50)),
    ])
    c.animation.rotation.track = KeyframeTrack(keys: [Keyframe(time: s(2), value: 10.0), Keyframe(time: s(3), value: 40.0)])
    return c
}

@Suite struct KeystoneTests {
    // MARK: Capture

    @Test func captureNormalisesTimeAndValues() throws {
        let k = try #require(Keystone.capture(from: animatedClip(), properties: [.scale, .position, .rotation],
                                              frameSize: frame, name: "Mine"))
        #expect(k.name == "Mine")
        #expect(k.duration == s(1))
        let sc = try #require(k.scale)
        #expect(sc.keys.map(\.time) == [.zero, s(1)])
        #expect(sc.keys[0].value == Vec2(1, 1))
        #expect(abs(sc.keys[1].value.x - 1.2) < 1e-12)
        #expect(sc.keys[0].outHandle == easeOut && sc.keys[1].inHandle == easeIn && sc.keys[0].interpolation == .bezier)
        let p = try #require(k.position)
        #expect(p.keys[0].value == .zero)
        #expect(abs(p.keys[1].value.x - 0.1) < 1e-12 && p.keys[1].value.y == 0)
        #expect(k.rotation?.keys.map(\.value) == [0, 30])
        #expect(k.opacity == nil)
    }

    @Test func captureOpacityStaysAbsolute() throws {
        var c = clip()
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(1), value: 0.0), Keyframe(time: ms(1500), value: 0.8)])
        let k = try #require(Keystone.capture(from: c, properties: [.opacity], frameSize: frame, name: "Fade"))
        #expect(k.opacity?.keys.map(\.value) == [0, 0.8])
        #expect(k.duration == ms(500))
    }

    @Test func captureWithoutKeysIsNil() {
        #expect(Keystone.capture(from: clip(), properties: [.scale, .position], frameSize: frame, name: "x") == nil)
        #expect(Keystone.capture(from: animatedClip(), properties: [.opacity], frameSize: frame, name: "x") == nil)
    }

    @Test func captureOfASingleKeyIsNil() {
        var c = clip()
        c.animation.rotation.track = KeyframeTrack(keys: [Keyframe(time: s(1), value: 5.0)])
        #expect(Keystone.capture(from: c, properties: [.rotation], frameSize: frame, name: "x") == nil)
    }

    // MARK: Apply

    @Test func applyPlacesStretchedKeysAndKeepsEasing() throws {
        let k = try #require(Keystone.capture(from: animatedClip(), properties: [.scale], frameSize: frame, name: "k"))
        var c = clip()
        let span = c.applyKeystone(k, at: s(1), duration: s(2), frameSize: frame)
        #expect(span == KeystoneSpan(start: s(1), duration: s(2), properties: [.scale]))
        let keys = c.animation.scale.track.keys
        #expect(keys.map(\.time) == [s(1), s(3)])
        #expect(keys[0].value == Vec2(1, 1))
        #expect(abs(keys[1].value.x - 1.2) < 1e-12)
        #expect(keys[0].outHandle == easeOut && keys[1].inHandle == easeIn)
        #expect(c.animation.position.track.isEmpty && c.animation.rotation.track.isEmpty)
    }

    @Test func applyIsRelativeToTheClipsOwnValues() throws {
        let k = try #require(Keystone.capture(from: animatedClip(), properties: [.scale, .position, .rotation],
                                              frameSize: frame, name: "k"))
        var c = clip()
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.animation.position = AnimatedProperty(Vec2(10, 20))
        c.animation.rotation = AnimatedProperty(5.0)
        c.applyKeystone(k, at: .zero, duration: k.duration, frameSize: Vec2(3840, 2160))
        #expect(c.animation.scale.track.keys.map(\.value.x).map { ($0 * 1000).rounded() } == [2000, 2400])
        #expect(c.animation.position.track.keys.map(\.value) == [Vec2(10, 20), Vec2(10 + 384, 20)])
        #expect(c.animation.rotation.track.keys.map(\.value) == [5, 35])
    }

    @Test func applyTwiceGivesFreshKeyIDs() throws {
        let k = Keystone.builtIn(named: "Shake")!
        var c = clip()
        c.applyKeystone(k, at: .zero, duration: k.duration, frameSize: frame)
        let first = Set(c.animation.position.track.keys.map(\.id))
        c.applyKeystone(k, at: s(3), duration: k.duration, frameSize: frame)
        let all = c.animation.position.track.keys.map(\.id)
        #expect(Set(all).count == all.count)
        #expect(first.isSubset(of: Set(all)))
    }

    @Test func easingOverrideReplacesEveryKeysEasing() throws {
        var k = try #require(Keystone.capture(from: animatedClip(), properties: [.scale, .position], frameSize: frame, name: "k"))
        k.easing = .premiereDefault
        var c = clip()
        c.applyKeystone(k, at: .zero, duration: k.duration, frameSize: frame)
        for key in c.animation.scale.track.keys {
            #expect(key.interpolation == .bezier)
            #expect(key.outHandle == EasingCurve.premiereDefault.outHandle && key.inHandle == EasingCurve.premiereDefault.inHandle)
        }
        #expect(c.animation.position.track.keys.allSatisfy { $0.outHandle == EasingCurve.premiereDefault.outHandle })
    }

    // MARK: Placement (drop ghost)

    @Test func placementCentresOnTheDropPointAndStaysInsideTheClip() {
        let k = Keystone(name: "k", duration: s(2), rotation: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0),
                                                                                   Keyframe(time: s(2), value: 9.0)]))
        #expect(k.placement(dropAt: s(3), clipDuration: s(6)) == KeystoneSpan(start: s(2), duration: s(2), properties: [.rotation]))
        #expect(k.placement(dropAt: ms(200), clipDuration: s(6)).start == .zero)
        #expect(k.placement(dropAt: s(6), clipDuration: s(6)).start == s(4))
        // Longer than the clip: the clip's length.
        #expect(k.placement(dropAt: s(1), clipDuration: s(1)) == KeystoneSpan(start: .zero, duration: s(1), properties: [.rotation]))
    }

    @Test func placementAnchorsInAndOutKeystonesToTheClipEnds() {
        var k = Keystone(name: "k", duration: s(1), opacity: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0),
                                                                                  Keyframe(time: s(1), value: 1.0)]))
        k.anchor = .clipStart
        #expect(k.placement(dropAt: s(4), clipDuration: s(6)).start == .zero)
        k.anchor = .clipEnd
        #expect(k.placement(dropAt: s(1), clipDuration: s(6)).start == s(5))
    }

    // MARK: Restretch (edge drag)

    @Test func restretchScalesOnlyTheSpansKeys() throws {
        let k = try #require(Keystone.capture(from: animatedClip(), properties: [.scale], frameSize: frame, name: "k"))
        var c = clip()
        c.animation.rotation.track = KeyframeTrack(keys: [Keyframe(time: s(1), value: 3.0)])
        c.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: s(5), value: Vec2(3, 3))])
        let span = c.applyKeystone(k, at: s(1), duration: s(1), frameSize: frame)
        let ok = c.restretchKeystone(span, to: KeystoneSpan(start: s(1), duration: s(3), properties: span.properties))
        #expect(ok)
        // Keys at 1 and 2 → 1 and 4; the clip's own key at 5 (outside the span) stays.
        #expect(c.animation.scale.track.keys.map(\.time) == [s(1), s(4), s(5)])
        #expect(c.animation.scale.track.keys[0].outHandle == easeOut)
        #expect(c.animation.rotation.track.keys.map(\.time) == [s(1)])   // other property untouched
    }

    @Test func restretchRefusesAnEmptySpan() throws {
        var c = clip()
        let span = KeystoneSpan(start: .zero, duration: s(1), properties: [.scale])
        let ok = c.restretchKeystone(span, to: KeystoneSpan(start: .zero, duration: .zero, properties: [.scale]))
        #expect(!ok)
    }

    // MARK: Timeline

    @Test func timelineApplyUsesTheSequenceFrameAndChecksTheTrack() throws {
        let vc = clip(), ac = clip(kind: .audio)
        var v = Track(kind: .video), a = Track(kind: .audio)
        try v.overwrite(vc); try a.overwrite(ac)
        var tl = Timeline(name: "t", format: SequenceFormat(width: 1000, height: 500, frameDuration: Time(1, 25)), tracks: [v, a])
        let k = Keystone(name: "Slide", duration: s(1), position: KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-1, 0)),
                                                                                         Keyframe(time: s(1), value: .zero)]))
        let span = try tl.applyKeystone(k, to: vc.id, at: .zero, duration: s(1))
        #expect(span.properties == [.position])
        #expect(tl.find(vc.id)!.clip.animation.position.track.keys.map(\.value) == [Vec2(-1000, 0), .zero])
        var refused: EditError?
        do { try tl.applyKeystone(k, to: ac.id, at: .zero, duration: s(1)) } catch { refused = error as? EditError }
        #expect(refused == .wrongTrackKind)
        try tl.restretchKeystone(on: vc.id, span, to: KeystoneSpan(start: .zero, duration: s(2), properties: span.properties))
        #expect(tl.find(vc.id)!.clip.animation.position.track.keys.map(\.time) == [.zero, s(2)])
    }

    // MARK: Built-ins and payload

    @Test func builtInsAreUsable() {
        #expect(Keystone.builtIns.count >= 8)
        #expect(Set(Keystone.builtIns.map(\.id)).count == Keystone.builtIns.count)
        #expect(Set(Keystone.builtIns.map(\.name)).count == Keystone.builtIns.count)
        for k in Keystone.builtIns {
            #expect(k.duration > .zero, "\(k.name)")
            #expect(!k.properties.isEmpty, "\(k.name)")
            #expect(k.isBuiltIn)
            var c = clip()
            let span = c.applyKeystone(k, at: .zero, duration: k.duration, frameSize: frame)
            #expect(span.properties == k.properties)
        }
    }

    @Test func payloadRoundTripsAndRejectsNewerVersions() throws {
        var k = Keystone.builtIn(named: "Punch In")!
        k.easing = .easeInOut
        let back = try Keystone(payload: try k.payload(), version: Keystone.payloadVersion)
        #expect(back == k)
        #expect(throws: Keystone.PayloadError.newerVersion(found: 99, supported: Keystone.payloadVersion)) {
            try Keystone(payload: try k.payload(), version: 99)
        }
    }
}
